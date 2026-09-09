#!/usr/bin/env bash
# Build a single install-size TSV from stat/<software>/latest.report.json.
# Output: stat/.x-cmd/all.tsv
#
# Columns: software / platform / download-size / description
# - platform:     comma-joined darwin/win/linux based on which assets are present.
#                 native/<os>/...       -> os directly
#                 runtime/dmg           -> darwin
#                 runtime/msi           -> win
#                 runtime/(deb|rpm|appimage) -> linux
#                 runtime/whl           -> linux,darwin,win (cross-platform)
# - download-size: reference size picked by priority:
#                 native: linux/x64 > darwin/x64 > win/x64
#                         > linux/arm64 > darwin/arm64 > win/arm64
#                 runtime fallback: deb/x64 > rpm/x64 > appimage/x64
#                         > dmg/x64 > dmg > msi/x64 > msi > whl
#                         > deb/arm64 > rpm/arm64 > deb > rpm > appimage
# - description:  label for the chosen reference (e.g. linux/x64, macos/arm64, dmg)

set -u
cd "$(dirname "$0")/.."

OUT_DIR=".x-cmd"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/all.tsv"
printf 'software\tplatform\tdownload-size\tdescription\n' > "$OUT"

count=0
skipped=0
for d in */; do
    d="${d%/}"
    f="$d/latest.report.json"
    [ -f "$f" ] || continue
    # need ≥4 lines (meta + loc + scorecard + release-with-assets)
    [ "$(wc -l < "$f")" -ge 4 ] || { skipped=$((skipped+1)); continue; }

    classified=$(jq -s '.[3]' "$f" 2>/dev/null | x eget classify --tsv 2>/dev/null)
    [ -n "$classified" ] || { skipped=$((skipped+1)); continue; }

    # derive present platforms (set, ordered linux,darwin,win) — bash 3.2 compatible
    has_linux=""; has_darwin=""; has_win=""
    echo "$classified" | grep -q "native/linux/"  && has_linux=1
    echo "$classified" | grep -q "native/darwin/" && has_darwin=1
    echo "$classified" | grep -q "native/win/"    && has_win=1
    echo "$classified" | grep -q "runtime/dmg"    && has_darwin=1
    echo "$classified" | grep -q "runtime/msi"    && has_win=1
    echo "$classified" | grep -Eq "runtime/(deb|rpm|appimage)" && has_linux=1
    echo "$classified" | grep -q "runtime/whl" \
        && { has_linux=1; has_darwin=1; has_win=1; }
    platforms=""
    [ -n "$has_linux"  ] && platforms="${platforms:+$platforms,}linux"
    [ -n "$has_darwin" ] && platforms="${platforms:+$platforms,}darwin"
    [ -n "$has_win"    ] && platforms="${platforms:+$platforms,}win"

    # pick reference size by priority
    ref_size=""
    ref_label=""
    for pair in \
        "native/linux/x64:linux/x64" \
        "native/darwin/x64:macos/x64" \
        "native/win/x64:win/x64" \
        "native/linux/arm64:linux/arm64" \
        "native/darwin/arm64:macos/arm64" \
        "native/win/arm64:win/arm64" \
        "runtime/deb/x64:deb/x64" \
        "runtime/rpm/x64:rpm/x64" \
        "runtime/appimage/x64:appimage/x64" \
        "runtime/dmg/x64:dmg/x64" \
        "runtime/dmg:dmg" \
        "runtime/msi/x64:msi/x64" \
        "runtime/msi:msi" \
        "runtime/whl:whl" \
        "runtime/deb/arm64:deb/arm64" \
        "runtime/rpm/arm64:rpm/arm64" \
        "runtime/deb:deb" \
        "runtime/rpm:rpm" \
        "runtime/appimage:appimage"; do
        cls="${pair%%:*}"
        lbl="${pair##*:}"
        row=$(printf '%s\n' "$classified" | awk -F'\t' -v c="$cls" '$NF==c {print $3; exit}')
        if [ -n "$row" ]; then
            ref_size="$row"
            ref_label="$lbl"
            break
        fi
    done

    [ -n "$ref_size" ] || { skipped=$((skipped+1)); continue; }

    printf '%s\t%s\t%s\t%s\n' "$d" "$platforms" "$ref_size" "$ref_label" >> "$OUT"
    count=$((count+1))
done

echo "wrote $count rows; skipped $skipped"
echo "output: $OUT"
