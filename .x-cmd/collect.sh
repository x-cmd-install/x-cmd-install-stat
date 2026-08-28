#!/usr/bin/env bash
# .x-cmd/collect.sh — harvest one day of cards from the x-cmd-install org.
#
# Each x-cmd-install/<software> repo runs its own card workflow just after
# 00:00 UTC and commits data/<YYMMDD>.yml. This script pulls those files over
# raw.githubusercontent.com (CDN, unauthenticated, no API rate limit) into
# stat/<software>/<YYMMDD>.card.yml.
#
# Only repos with no published file for the date fall back to a local
# `x repo card` call — which is the expensive, rate-limited path that
# .x-cmd/update.sh used for every repo. That fallback list is written to
# .x-cmd/<date>.missing.txt so you can feed it to update.sh --input.
#
# Usage:
#     ./.x-cmd/collect.sh                    # today (UTC) for all org repos
#     ./.x-cmd/collect.sh --date 260827      # a specific day
#     ./.x-cmd/collect.sh --jobs 16          # fetch parallelism (default 16)
#     ./.x-cmd/collect.sh --no-fallback      # skip the x repo card fallback
#     ./.x-cmd/collect.sh --input FILE       # explicit repo-name list

set -u

repo_root="$(cd "$(dirname "$0")" && cd .. && pwd)"
stat_dir="$repo_root/stat"
org="x-cmd-install"

# UTC, because that is the clock the workflows stamp their filenames with.
date_stamp="$(date -u +%y%m%d)"
jobs=16
fallback=1
input_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --date=*)      date_stamp="${1#--date=}" ;;
        --date)        shift; date_stamp="${1:?}" ;;
        --jobs=*)      jobs="${1#--jobs=}" ;;
        --jobs)        shift; jobs="${1:-16}" ;;
        --no-fallback) fallback=0 ;;
        --input=*)     input_file="${1#--input=}" ;;
        --input)       shift; input_file="${1:-}" ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$stat_dir"
missing_file="$repo_root/.x-cmd/${date_stamp}.missing.txt"
fetched_file="$(mktemp -t xcmdfetched.XXXXXX)"
have_file="$(mktemp -t xcmdhave.XXXXXX)"

list_file="$(mktemp -t xcmdcollect.XXXXXX)"
trap 'rm -f "$list_file" "$fetched_file" "$have_file"' EXIT
if [ -n "$input_file" ]; then
    grep -E '^[A-Za-z0-9._-]+$' "$input_file" | sort -u > "$list_file"
else
    gh repo list "$org" --limit 4000 --json name --jq '.[].name' | sort -u > "$list_file"
fi

total=$(wc -l < "$list_file" | tr -d ' ')
echo "==> $total repos, date $date_stamp (UTC), jobs=$jobs"
: > "$missing_file"

fetch_one() {
    repo="$1"
    out="$stat_dir/$repo/${date_stamp}.card.yml"
    [ -s "$out" ] && { printf '%s\n' "$repo" >> "$have_file"; return 0; }

    url="https://raw.githubusercontent.com/$org/$repo/main/data/${date_stamp}.yml"
    mkdir -p "$(dirname "$out")"
    if curl -fsSL --max-time 30 "$url" -o "$out.tmp" 2>/dev/null && [ -s "$out.tmp" ]; then
        # Guard against a 200 that isn't a card (e.g. an HTML error page).
        if head -1 "$out.tmp" | grep -q '^about:'; then
            mv "$out.tmp" "$out"
            printf '%s\n' "$repo" >> "$fetched_file"
            printf '%s\n' "$repo" >> "$have_file"
            return 0
        fi
    fi
    rm -f "$out.tmp"
    printf '%s\n' "$repo" >> "$missing_file"
    return 0
}

export -f fetch_one
export org stat_dir date_stamp missing_file fetched_file have_file

xargs -n1 -P"$jobs" -I{} bash -c 'fetch_one "$@"' _ {} < "$list_file"

# Report against the repo list this run actually walked. Counting
# stat/*/<date>.card.yml on disk would also sweep in cards left by an earlier
# update.sh run and overstate what the org workflows delivered.
new=$(grep -c . "$fetched_file" 2>/dev/null; true)
have=$(grep -c . "$have_file" 2>/dev/null; true)
miss=$(grep -c . "$missing_file" 2>/dev/null; true)   # grep -c prints 0 and exits 1 when empty
echo "==> of $total repos: $have have a card ($new newly fetched), $miss missing (see $missing_file)"

[ "$miss" = 0 ] && exit 0
[ "$fallback" = 0 ] && { echo "==> --no-fallback: stopping"; exit 0; }

# Fallback: resolve each missing software name back to its upstream owner/repo
# via the install-repo README frontmatter, then let update.sh do the throttled
# `x repo card` work.
echo "==> resolving upstream owner/repo for $miss missing entries..."
upstream_file="$repo_root/.x-cmd/${date_stamp}.fallback.txt"
: > "$upstream_file"
while read -r repo; do
    [ -n "$repo" ] || continue
    ownerrepo=$(curl -fsSL --max-time 20 \
        "https://raw.githubusercontent.com/$org/$repo/main/README.md" 2>/dev/null \
        | awk -F':[[:space:]]*' '/^owner-repo:/{print $2; exit}' | tr -d '[:space:]')
    case "$ownerrepo" in
        */*) printf '%s\n' "$ownerrepo" >> "$upstream_file" ;;
        *)   echo "no owner-repo for $repo" >&2 ;;
    esac
done < "$missing_file"

echo "==> running update.sh on $(grep -c . "$upstream_file") upstream repos"
"$repo_root/.x-cmd/update.sh" --input "$upstream_file" --date "$date_stamp"
