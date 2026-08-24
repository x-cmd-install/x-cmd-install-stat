#!/usr/bin/env bash
# .x-cmd/bulk-create-repos.sh — persistent batch creator for x-cmd-install/<repo>.
#
# Reads TSV from --input FILE (default: .x-cmd/2100.tsv built from x install --ls)
# and creates one public repo per line, seeding README.md with yfm frontmatter
# (owner-repo + desc) and `# <software>` body.
#
# Self-throttles on GitHub's "too many repositories, too quickly" secondary rate
# limit. Resume-safe: tracks progress in .x-cmd/repos.progress so rerunning
# picks up where it left off without re-creating anything that already exists.
#
# Usage:
#     ./.x-cmd/bulk-create-repos.sh                # create from default list
#     ./.x-cmd/bulk-create-repos.sh --input FILE   # use a custom list
#     ./.x-cmd/bulk-create-repos.sh --dry-run     # print actions, no writes
#     ./.x-cmd/bulk-create-repos.sh --reset       # ignore progress file
#
# Output:
#     .x-cmd/repos.progress — one line per repo: OK / SKIP / FAIL

set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
progress_file="$repo_root/.x-cmd/repos.progress"
org="x-cmd-install"
input_file=""
dry_run=0
reset=0
cooldown_seconds=1800   # 30 min — empirically the cooldown length

while [ $# -gt 0 ]; do
    case "$1" in
        --input=*)    input_file="${1#--input=}" ;;
        --input)      shift; input_file="${1:-}" ;;
        --dry-run|-n) dry_run=1 ;;
        --reset)      reset=1 ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Build the default list if no input was given.
if [ -z "$input_file" ]; then
    input_file="$(mktemp -t xcmdrepolist.XXXXXX)"
    trap 'rm -f "$input_file"' EXIT
    x install --ls 2>/dev/null \
        | awk -F'\t' 'NR>1 && $4 ~ /^https?:\/\/github\.com\// {print $4}' \
        | awk -F'/' '{print $4"/"$5}' \
        | sed 's/\.git$//' \
        | grep -E '^[^/]+/[^/]+$' \
        | sort -u > "$input_file"
fi

[ -r "$input_file" ] || { echo "input not readable: $input_file" >&2; exit 1; }

# Sanitize: drop lines that aren't valid UTF-8 (some x install --ls entries
# have invalid bytes that break `tr '\n' '\0'`).
tmp_clean="$(mktemp -t xcmdrepoclean.XXXXXX)"
python3 -c "
import sys
with open('$input_file', 'rb') as f:
    for line in f:
        try:
            sys.stdout.buffer.write(line.decode('utf-8').replace(chr(0xFFFD), '?').encode('utf-8'))
        except UnicodeEncodeError:
            sys.stdout.buffer.write(line.decode('utf-8', errors='replace').replace(chr(0xFFFD), '?').encode('utf-8'))
" > "$tmp_clean" 2>/dev/null
mv "$tmp_clean" "$input_file"

if [ "$reset" = 1 ]; then
    rm -f "$progress_file"
fi

# Set up progress log (append mode so reruns keep history).
mkdir -p "$(dirname "$progress_file")"
touch "$progress_file"

already_done=$(awk '$1 == "OK" || $1 == "SKIP" {print $2}' "$progress_file" | sort -u)
total=$(wc -l < "$input_file" | tr -d ' ')

if [ "$dry_run" = 1 ]; then
    echo "==> dry run: $total unique repos in $input_file"
    echo "==> progress file: $progress_file (already-done entries: $(echo "$already_done" | grep -c .))"
    exit 0
fi

echo "==> $total unique repos; already done: $(echo "$already_done" | grep -c .)"

run_one() {
    local line="$1"
    local ownerrepo repo desc
    ownerrepo=$(printf '%s' "$line" | awk -F'\t' '{print $1}')
    repo=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
    desc=$(printf '%s' "$line" | awk -F'\t' '{$1=""; $2=""; sub(/^\t\t/, ""); print}')

    # Skip if already in progress file (idempotent across runs).
    if printf '%s\n' "$already_done" | grep -qx "$repo"; then
        return 0
    fi

    # Skip if repo exists in the org.
    if gh repo view "$org/$repo" >/dev/null 2>&1; then
        printf 'SKIP %s\n' "$repo" | tee -a "$progress_file"
        return 0
    fi

    # Create the public repo.
    if ! gh repo create "$org/$repo" --public --description "${desc:-$repo}" 2>/tmp/err.$$; then
        local err
        err=$(cat /tmp/err.$$ 2>/dev/null)
        rm -f /tmp/err.$$
        if printf '%s' "$err" | grep -q "too many repositories"; then
            # Rate-limited — sleep and re-queue at end of stdin by writing
            # the line to a "paused" file. Return 75 (EX_TEMPFAIL) so the
            # outer loop knows to back off.
            printf 'RATE_LIMIT %s — sleeping %ds then retrying...\n' "$repo" "$cooldown_seconds" >&2
            printf '%s\n' "$line" >> "$repo_root/.x-cmd/repos.paused"
            rm -f /tmp/err.$$
            return 75
        fi
        printf 'FAIL %s: %s\n' "$repo" "$err" | tee -a "$progress_file" >&2
        rm -f /tmp/err.$$
        return 1
    fi
    rm -f /tmp/err.$$

    # Push README with yfm frontmatter.
    local tmpdir
    tmpdir="$(mktemp -d -t xcmdrepo.XXXXXX)"
    (
        cd "$tmpdir"
        git init -q -b main .
        git config user.email "l@x-cmd.com"
        git config user.name  "x-cmd-install bot"
        cat > README.md <<README
---
owner-repo: $ownerrepo
desc: ${desc:-$repo}
---

# $repo
README
        git add README.md
        git commit -q -m "init: seed README for $ownerrepo"
        if git push -q "https://x-access-token:$(gh auth token)@github.com/$org/$repo.git" main:main 2>/tmp/err.$$; then
            rm -f /tmp/err.$$
            printf 'OK   %s\n' "$repo" | tee -a "$progress_file"
            cd / >/dev/null
            rm -rf "$tmpdir"
            exit 0
        else
            local err
            err=$(cat /tmp/err.$$ 2>/dev/null)
            rm -f /tmp/err.$$
            printf 'FAIL %s push: %s\n' "$repo" "$err" | tee -a "$progress_file" >&2
            cd / >/dev/null
            rm -rf "$tmpdir"
            exit 1
        fi
    )
}

export -f run_one
export org progress_file repo_root cooldown_seconds already_done

# Process in waves. When rate-limited, sleep cooldown and re-run on the
# paused list until everything is done (or we hit a permanent error).
attempt=0
while : ; do
    attempt=$((attempt + 1))
    paused="$repo_root/.x-cmd/repos.paused"
    : > "$paused"

    if [ "$attempt" = 1 ]; then
        # First run: feed the full input.
        feed="$input_file"
    else
        # Subsequent runs: only the paused items.
        feed="$paused"
        [ -s "$feed" ] || break
        echo "==> retry wave $attempt: $(wc -l < "$feed" | tr -d ' ') repos"
        sleep "$cooldown_seconds"
    fi

    # -P 1 to respect the rate limit.
    tr '\n' '\0' < "$feed" | xargs -0 -n1 -P1 bash -c 'run_one "$@"' _ {}

    # If paused file still has anything, the script wrote more entries
    # mid-run. The next iteration handles them.
    if [ ! -s "$paused" ]; then
        break
    fi
done

# Final tally.
echo "==> final tally:"
echo "    OK:    $(grep -c '^OK '   "$progress_file")"
echo "    SKIP:  $(grep -c '^SKIP ' "$progress_file")"
echo "    FAIL:  $(grep -c '^FAIL ' "$progress_file")"
echo "    repos in org: $(gh repo list $org --limit 3000 --json name --jq 'length')"