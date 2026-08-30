#!/usr/bin/env bash
# .x-cmd/sync.sh — pull the freshest card from each x-cmd-install/<software>
# repo and write stat/<software>/latest.card.yml.
#
# Each upstream repo runs its own card workflow just after 00:00 UTC and
# commits data/<YYMMDD>.yml. This script:
#
#   1. Treats the existing stat/<software>/ directories as the repo list
#      (the directory was created when the upstream repo was first
#      registered — no API call needed to enumerate it).
#   2. For each, tries raw.githubusercontent.com for data/<today>.yml,
#      then data/<yesterday>.yml, etc. (lookback) — all CDN, no auth,
#      no API quota.
#   3. Writes the first 200 response to stat/<software>/latest.card.yml.
#      If none of the candidate dates return 200, leaves the previous
#      latest.card.yml untouched.
#
# History is intentionally not mirrored here: stat/<software>/ holds just
# latest.card.yml. Date-stamped snapshots live upstream under data/.
#
# To onboard a new repo: run .x-cmd/bulk-create-repos.sh once (which uses
# gh API for the one-time creation), then sync.sh picks it up forever.
#
# Usage:
#     ./.x-cmd/sync.sh                  # today (UTC) for all known repos
#     ./.x-cmd/sync.sh --lookback 3     # today, fall back to N prior days
#     ./.x-cmd/sync.sh --input FILE     # explicit repo-name list (one per line)
#     ./.x-cmd/sync.sh --dry-run        # list what would be fetched
#     ./.x-cmd/sync.sh --concurrency 16 # parallel workers (default 16)

set -u

repo_root="$(cd "$(dirname "$0")" && cd .. && pwd)"
stat_dir="$repo_root/stat"
org="x-cmd-install"
date_stamp="$(date -u +%y%m%d)"
lookback=2
concurrency=16
input_file=""
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --date=*)          date_stamp="${1#--date=}" ;;
        --date)            shift; date_stamp="${1:?}" ;;
        --lookback=*)      lookback="${1#--lookback=}" ;;
        --lookback)        shift; lookback="${1:-2}" ;;
        --concurrency=*)   concurrency="${1#--concurrency=}" ;;
        --concurrency)     shift; concurrency="${1:-16}" ;;
        --input=*)         input_file="${1#--input=}" ;;
        --input)           shift; input_file="${1:-}" ;;
        --dry-run|-n)      dry_run=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Build the repo-name list (one per line). Prefer an explicit --input
# file; otherwise enumerate the existing stat/ directories.
if [ -n "$input_file" ]; then
    repo_list="$input_file"
else
    repo_list="$(mktemp -t xcmdsync.XXXXXX)"
    trap 'rm -f "$repo_list"' EXIT
    find "$stat_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | sort -u > "$repo_list"
fi

# Pre-compute the candidate dates (newest first) so each worker iterates
# them in order and stops on the first 200.
# `date -d` is GNU; fall back to `python3` so this works on both Linux
# (GitHub Actions) and macOS (local dev).
shift_days() {
    local days="$1"
    if date -u -d "today - $days days" +%y%m%d >/dev/null 2>&1; then
        date -u -d "today - $days days" +%y%m%d
    else
        python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(days=$days)).strftime('%y%m%d'))"
    fi
}
date_list=""
i=0
while [ "$i" -le "$lookback" ]; do
    iso=$(shift_days "$i")
    date_list="$date_list $iso"
    i=$((i+1))
done

count=$(wc -l < "$repo_list" | tr -d ' ')
echo "==> $count repos, dates tried (newest first):$date_list, concurrency=$concurrency"

# Worker: for one repo, try each candidate date until one returns 200.
sync_one() {
    local name="$1"
    local out="$stat_dir/$name/latest.card.yml"
    local url d tmp

    if [ "$dry_run" = 1 ]; then
        for d in $date_list; do
            url="https://raw.githubusercontent.com/${org}/${name}/main/data/${d}.yml"
            printf '[dry-run] %s -> %s\n' "$url" "$out"
        done
        return 0
    fi

    for d in $date_list; do
        url="https://raw.githubusercontent.com/${org}/${name}/main/data/${d}.yml"
        tmp="$(mktemp -t xcmdsync.XXXXXX)"
        if curl -sfS --max-time 15 "$url" -o "$tmp" 2>/dev/null; then
            mv "$tmp" "$out"
            printf 'OK   %-40s %s\n' "$name" "$d"
            return 0
        fi
        rm -f "$tmp"
    done

    printf 'SKIP %-40s (no data/<today-or-prior>.yml yet)\n' "$name" >&2
    return 1
}

export -f sync_one
export stat_dir org date_list dry_run

xargs -n1 -P"$concurrency" -I{} bash -c 'sync_one "$@"' _ {} < "$repo_list"

ok=$(find "$stat_dir" -mindepth 2 -name latest.card.yml -size +0 | wc -l | tr -d ' ')
echo "==> done: $ok latest.card.yml files in stat/"
