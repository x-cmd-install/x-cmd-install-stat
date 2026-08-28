#!/usr/bin/env bash
# .x-cmd/bulk-create-repos.sh — persistent batch creator for x-cmd-install/<repo>.
#
# Reads TSV from --input FILE (default: built from x install --ls)
# and creates one public repo per line, seeding README.md with yfm frontmatter
# (owner-repo + desc) and `# <software>` body.
#
# Self-throttles on GitHub's "too many repositories, too quickly" secondary rate
# limit. Resume-safe: tracks progress in .x-cmd/repos.progress and re-queues
# rate-limited entries to .x-cmd/repos.paused. The outer while loop drains
# .x-cmd/repos.paused across cooldown windows.
#
# Usage:
#     ./.x-cmd/bulk-create-repos.sh                # create from default list
#     ./.x-cmd/bulk-create-repos.sh --input FILE   # use a custom list
#     ./.x-cmd/bulk-create-repos.sh --dry-run      # print actions, no writes
#     ./.x-cmd/bulk-create-repos.sh --reset        # ignore progress file
#     ./.x-cmd/bulk-create-repos.sh --cooldown 600 # override 30-min default

set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
progress_file="$repo_root/.x-cmd/repos.progress"
paused_file="$repo_root/.x-cmd/repos.paused"
worker="$repo_root/.x-cmd/repo_worker.sh"
org="x-cmd-install"
input_file=""
dry_run=0
reset=0
cooldown_seconds=1800   # 30 min — empirically the cooldown length

# Make sure the worker script exists.
if [ ! -x "$worker" ]; then
    echo "worker not found at $worker" >&2
    echo "(copy it from /tmp/repo_worker.sh or your local checkout)" >&2
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --input=*)      input_file="${1#--input=}" ;;
        --input)        shift; input_file="${1:-}" ;;
        --cooldown=*)   cooldown_seconds="${1#--cooldown=}" ;;
        --cooldown)     shift; cooldown_seconds="${1:-1800}" ;;
        --dry-run|-n)   dry_run=1 ;;
        --reset)        reset=1 ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Build the default list if no input was given.
# Format: ownerrepo<TAB>repo<TAB>desc (one per line)
# desc falls back to the repo name if the card yml has no description.
if [ -z "$input_file" ]; then
    input_file="$(mktemp -t xcmdrepolist.XXXXXX)"
    trap 'rm -f "$input_file"' EXIT
    stat_dir="$repo_root/stat"

    # Index card descriptions by repo name.
    repo_desc=""
    for card in "$stat_dir"/*/260824.card.yml "$stat_dir"/*/260825.card.yml; do
        [ -f "$card" ] || continue
        repo=$(dirname "$card" | sed 's|^.*/||')
        desc=$(awk '/^  description:/{sub(/^  description: /,""); print; exit}' "$card" \
               | tr '\t\n\r' '   ' | head -c 250)
        printf '%s\t%s\n' "$repo" "${desc:-$repo}"
    done | awk -F'\t' '!seen[$1]++' > /tmp/_repo_desc

    x install --ls 2>/dev/null \
        | awk -F'\t' 'NR>1 && $4 ~ /^https?:\/\/github\.com\// {print $4}' \
        | awk -F'/' '{print $4"/"$5}' \
        | sed 's/\.git$//' \
        | grep -E '^[^/]+/[^/]+$' \
        | sort -u \
        | awk -F'/' -v rd=/tmp/_repo_desc '
            BEGIN { while ((getline line < rd) > 0) { n=index(line,"\t"); if (n>0) d[substr(line,1,n-1)]=substr(line,n+1) } close(rd) }
            {
                repo = $2
                gsub(/#.*|\?.*/, "", repo)
                printf "%s\t%s\t%s\n", $0, repo, (d[repo] != "" ? d[repo] : repo)
            }
        ' > "$input_file"
    rm -f /tmp/_repo_desc
fi

[ -r "$input_file" ] || { echo "input not readable: $input_file" >&2; exit 1; }

# Sanitize: drop lines that aren't valid UTF-8 (some x install --ls entries
# have invalid bytes that break `tr '\n' '\0'`).
tmp_clean="$(mktemp -t xcmdrepoclean.XXXXXX)"
python3 -c "
import sys
with open('$input_file', 'rb') as f:
    for line in f:
        text = line.decode('utf-8', errors='replace').replace(chr(0xFFFD), '?')
        sys.stdout.buffer.write(text.encode('utf-8'))
" > "$tmp_clean"
mv "$tmp_clean" "$input_file"

if [ "$reset" = 1 ]; then
    rm -f "$progress_file" "$paused_file"
fi

# Set up progress log (append mode so reruns keep history).
mkdir -p "$(dirname "$progress_file")"
touch "$progress_file"

already_done_count=$(awk '$1 == "OK" || $1 == "SKIP" {print $2}' "$progress_file" | sort -u | grep -c .)
total=$(wc -l < "$input_file" | tr -d ' ')

if [ "$dry_run" = 1 ]; then
    echo "==> dry run: $total unique repos in $input_file"
    echo "==> progress file: $progress_file (already-done entries: $already_done_count)"
    echo "==> org has: $(gh repo list $org --limit 3000 --json name --jq 'length') repos"
    exit 0
fi

echo "==> $total unique repos; already done: $already_done_count"
echo "==> cooldown: ${cooldown_seconds}s; worker: $worker"

export org progress_file paused_file cooldown_seconds

# Process in waves. When rate-limited, sleep cooldown and re-run on the
# paused list until everything is done (or we hit a permanent error).
attempt=0
paused_feed=""
while : ; do
    attempt=$((attempt + 1))
    if [ "$attempt" = 1 ]; then
        feed="$input_file"
    else
        feed="$paused_feed"
        [ -s "$feed" ] || break
        echo "==> retry wave $attempt ($(wc -l < "$feed" | tr -d ' ') repos) — sleeping ${cooldown_seconds}s..."
        sleep "$cooldown_seconds"
    fi

    # Truncate paused_file so the worker can re-populate it on this pass.
    : > "$paused_file"

    # -P 1 to respect the rate limit. null-terminated so tabs survive.
    tr '\n' '\0' < "$feed" | xargs -0 -n1 -P1 "$worker"

    # Snapshot what the worker wrote for the NEXT iteration. This must
    # happen AFTER xargs writes to paused_file but BEFORE the loop check.
    if [ -s "$paused_file" ]; then
        paused_feed="$(mktemp -t xcmdpaused.XXXXXX)"
        cat "$paused_file" > "$paused_feed"
    else
        # Empty paused file — we're done.
        rm -f "$paused_feed"
        break
    fi
done

# Final tally.
echo "==> final tally:"
echo "    OK:    $(grep -c '^OK '   "$progress_file")"
echo "    SKIP:  $(grep -c '^SKIP ' "$progress_file")"
echo "    FAIL:  $(grep -c '^FAIL ' "$progress_file")"
echo "    repos in org: $(gh repo list $org --limit 3000 --json name --jq 'length')"