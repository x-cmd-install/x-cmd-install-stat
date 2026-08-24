#!/usr/bin/env bash
# .x-cmd/update.sh — batch-generate per-repo card YAML files under stat/.
#
# For each GitHub-hosted install entry reported by `x install --ls`,
# run `x repo card <owner>/<repo>` and save the result to
# stat/<repo>/<YYMMDD>.card.yml (e.g. 260824.card.yml for today).
#
# `x repo card` issues 8 search queries per call (one per recent.* metric),
# and GitHub's search rate limit is 30 req/min. Default --jobs=2 keeps us
# comfortably under that ceiling; bump it only if you have a higher search
# budget. Cards that fail are retried up to --retries times.
#
# Usage:
#     ./.x-cmd/update.sh                # regenerate today's cards
#     ./.x-cmd/update.sh --dry-run      # list actions without writing
#     ./.x-cmd/update.sh --jobs 4       # set parallelism (default 2)
#     ./.x-cmd/update.sh --retries 3    # retries per card (default 2)
#     ./.x-cmd/update.sh --input FILE   # run on an explicit owner/repo list
#     ./.x-cmd/update.sh --date 260825  # override the date stamp

set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
stat_dir="$repo_root/stat"

jobs=2
retries=2
dry_run=0
date_stamp="$(date +%y%m%d)"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) dry_run=1 ;;
        --jobs=*)      jobs="${1#--jobs=}" ;;
        --jobs)        shift; jobs="${1:-2}" ;;
        --retries=*)   retries="${1#--retries=}" ;;
        --retries)     shift; retries="${1:-2}" ;;
        --date=*)      date_stamp="${1#--date=}" ;;
        --date)        shift; date_stamp="${1:-$(date +%y%m%d)}" ;;
        --input=*)     input_file="${1#--input=}" ;;
        --input)       shift; input_file="${1:-}" ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$stat_dir"

# Pull the GitHub owner/repo list. Default: column 4 of `x install --ls`.
# --input FILE overrides with an explicit owner/repo list (one per line).
repos_file="$(mktemp -t xcmdrepos.XXXXXX)"
fail_file="$(mktemp -t xcmdfail.XXXXXX)"
trap 'rm -f "$repos_file" "$fail_file" "${retry_file:-}"' EXIT

if [ -n "${input_file:-}" ]; then
    if [ ! -r "$input_file" ]; then
        echo "input file not readable: $input_file" >&2
        exit 1
    fi
    grep -E '^[^/]+/[^/]+$' "$input_file" | sort -u > "$repos_file"
else
    x install --ls 2>/dev/null \
        | awk -F'\t' 'NR>1 && $4 ~ /^https?:\/\/github\.com\// {print $4}' \
        | awk -F'/' '{print $4"/"$5}' \
        | sed 's/\.git$//' \
        | grep -E '^[^/]+/[^/]+$' \
        | sort -u \
        > "$repos_file"
fi

count=$(wc -l < "$repos_file" | tr -d ' ')
if [ "$count" -eq 0 ]; then
    echo "no github repos found in x install --ls" >&2
    exit 1
fi

echo "==> $count unique github repos, date stamp $date_stamp, jobs=$jobs, retries=$retries"

run_one() {
    ownerrepo="$1"
    repo="${ownerrepo#*/}"
    out="$stat_dir/$repo/${date_stamp}.card.yml"

    if [ "$dry_run" = 1 ]; then
        printf '[dry-run] %s -> %s\n' "$ownerrepo" "$out"
        return 0
    fi

    # Skip if already populated.
    if [ -s "$out" ] && [ ! -e "$out.err" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$out")"

    local_attempt=0
    while [ "$local_attempt" -le "$retries" ]; do
        local_attempt=$((local_attempt + 1))
        if x repo card "$ownerrepo" > "$out.tmp" 2>"$out.err"; then
            mv "$out.tmp" "$out"
            rm -f "$out.err"
            if [ "$local_attempt" -gt 1 ]; then
                printf 'OK*  %s (attempt %d) -> %s\n' "$ownerrepo" "$local_attempt" "$out"
            else
                printf 'OK   %s -> %s\n' "$ownerrepo" "$out"
            fi
            return 0
        fi
        rc=$?
        rm -f "$out.tmp"
        if [ "$local_attempt" -le "$retries" ]; then
            sleep 5
        fi
    done

    printf 'FAIL %s (rc=%d, see %s.err)\n' "$ownerrepo" "$rc" "$out" >&2
    printf '%s\n' "$ownerrepo" >> "$fail_file"
    return $rc
}

export -f run_one
export stat_dir date_stamp dry_run retries fail_file

echo "==> pass 1"
xargs -n1 -P"$jobs" -I{} bash -c 'run_one "$@"' _ {} < "$repos_file"

if [ -s "$fail_file" ]; then
    # Snapshot fail_file before reading: run_one may keep appending to it,
    # and `< file` keeps the fd open, so xargs would otherwise loop forever.
    retry_file="$(mktemp -t xcmdretry.XXXXXX)"
    cat "$fail_file" > "$retry_file"
    : > "$fail_file"
    fail_count=$(wc -l < "$retry_file" | tr -d ' ')
    echo "==> pass 2: retrying $fail_count failures"
    xargs -n1 -P"$jobs" -I{} bash -c 'run_one "$@"' _ {} < "$retry_file"
    rm -f "$retry_file"
fi

if [ -s "$fail_file" ]; then
    final_fail=$(wc -l < "$fail_file" | tr -d ' ')
    echo "==> $final_fail cards still failing after retries; see *.err files in $stat_dir" >&2
    exit 1
fi

ok_count=$(find "$stat_dir" -name "${date_stamp}.card.yml" -type f | wc -l | tr -d ' ')
echo "==> done: $ok_count card files written under $stat_dir"