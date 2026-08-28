#!/usr/bin/env bash
# .x-cmd/update.sh — batch-generate per-repo card YAML files under stat/.
#
# For each GitHub-hosted install entry reported by `x install --ls`,
# run `x repo card <owner>/<repo>` and save the result to
# stat/<repo>/<YYMMDD>.card.yml (e.g. 260828.card.yml for today).
#
# `x repo card` uses 1 GraphQL (16 search counts merged) + 1 REST
# /stats/commit_activity. Default --jobs=2 stays under GitHub's secondary
# rate limit window; bump only if you have a higher budget.
#
# Rate-limit handling: per-repo, --retries attempts with a backoff that
# grows on rate-limit signals; the outer loop re-feeds the fail file with
# a cooldown sleep until the fail list drains (analogous to
# bulk-create-repos.sh's "loop until dry" pattern).
#
# Usage:
#     ./.x-cmd/update.sh                    # regenerate today's cards
#     ./.x-cmd/update.sh --dry-run          # list actions without writing
#     ./.x-cmd/update.sh --jobs 4           # set parallelism (default 2)
#     ./.x-cmd/update.sh --retries 3        # retries per card (default 3)
#     ./.x-cmd/update.sh --cooldown 90      # outer-loop sleep seconds (60)
#     ./.x-cmd/update.sh --input FILE       # run on an explicit owner/repo list
#     ./.x-cmd/update.sh --date 260825      # override the date stamp

set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
stat_dir="$repo_root/stat"

jobs=2
retries=3
cooldown_seconds=60
dry_run=0
date_stamp="$(date +%y%m%d)"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) dry_run=1 ;;
        --jobs=*)      jobs="${1#--jobs=}" ;;
        --jobs)        shift; jobs="${1:-2}" ;;
        --retries=*)   retries="${1#--retries=}" ;;
        --retries)     shift; retries="${1:-3}" ;;
        --cooldown=*)  cooldown_seconds="${1#--cooldown=}" ;;
        --cooldown)    shift; cooldown_seconds="${1:-60}" ;;
        --date=*)      date_stamp="${1#--date=}" ;;
        --date)        shift; date_stamp="${1:-$(date +%y%m%d)}" ;;
        --input=*)     input_file="${1#--input=}" ;;
        --input)       shift; input_file="${1:-}" ;;
        -h|--help)
            sed -n '2,30p' "$0"
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
trap 'rm -f "$repos_file" "$fail_file" "${feed:-}"' EXIT

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

echo "==> $count unique github repos, date stamp $date_stamp, jobs=$jobs, retries=$retries, cooldown=${cooldown_seconds}s"

# Matches GitHub rate-limit responses across REST, GraphQL, and search APIs.
is_rate_limit() {
    grep -qiE 'rate limit|secondary rate|abuse detection|exceeded.*limit|403.*forbidden' "$1" 2>/dev/null
}

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
    saw_rl=0
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

        # If the failure looks like a rate-limit hit, bail out of the local
        # retry loop early so the outer cooldown loop can sleep properly —
        # a 5s sleep won't unblock a 30/min search limit.
        if is_rate_limit "$out.err"; then
            saw_rl=1
            break
        fi

        rm -f "$out.tmp"
        if [ "$local_attempt" -le "$retries" ]; then
            sleep 5
        fi
    done

    if [ "$saw_rl" = 1 ]; then
        printf 'RATE %s (will retry after cooldown)\n' "$ownerrepo" >&2
    else
        printf 'FAIL %s (rc=%d, see %s.err)\n' "$ownerrepo" "$rc" "$out" >&2
    fi
    printf '%s\n' "$ownerrepo" >> "$fail_file"
    return 1
}

export -f run_one is_rate_limit
export stat_dir date_stamp dry_run retries fail_file

# Outer loop: feed the full list on pass 1, then feed the fail file with
# cooldown sleeps until it drains. Stop conditions:
#   - fail_file empty after a pass → success, exit 0
#   - pass produces no new failures AND rate limit was seen → sleep,
#     retry; if a second pass with rate limit still fails, give up
#     (likely an auth/quota problem, not transient)
feed="$repos_file"
wave=0
while : ; do
    wave=$((wave + 1))
    pending=$(wc -l < "$feed" | tr -d ' ')
    if [ "$wave" = 1 ]; then
        echo "==> wave $wave: $pending repos"
    else
        echo "==> wave $wave: $pending repos — sleeping ${cooldown_seconds}s before retry..."
        sleep "$cooldown_seconds"
    fi

    # Truncate fail_file so run_one can re-populate it on this pass.
    : > "$fail_file"

    xargs -n1 -P"$jobs" -I{} bash -c 'run_one "$@"' _ {} < "$feed"

    if [ ! -s "$fail_file" ]; then
        echo "==> wave $wave clean"
        break
    fi

    new_fail=$(wc -l < "$fail_file" | tr -d ' ')
    echo "==> wave $wave: $new_fail failures remain"

    # Re-feed the same set we just tried.
    cp "$fail_file" "$feed"
done

# Final tally — show how many cards landed today.
ok_count=$(find "$stat_dir" -name "${date_stamp}.card.yml" -type f -size +0 | wc -l | tr -d ' ')
err_count=$(find "$stat_dir" -name "${date_stamp}.card.yml.err" | wc -l | tr -d ' ')
echo "==> done: $ok_count card files written under $stat_dir; $err_count .err files left over"

if [ -s "$fail_file" ]; then
    final_fail=$(wc -l < "$fail_file" | tr -d ' ')
    echo "==> $final_fail repos still failing after cooldown retries; see .err files" >&2
    cp "$fail_file" .x-cmd/"${date_stamp}".failed.txt
    exit 1
fi