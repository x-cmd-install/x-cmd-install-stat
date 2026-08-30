#!/usr/bin/env bash
# Worker: create one x-cmd-install/<repo> with README.
# Reads TSV from $1 (ownerrepo\trepo\tdesc) and the rest from env.
#
# Required env:
#   org             — GitHub org name (default x-cmd-install)
#   progress_file   — append "OK <repo>" / "SKIP <repo>" / "FAIL <repo>: ..." lines
#   paused_file     — append repo lines that hit the rate limit
#   cooldown_seconds — sleep this long on rate limit before re-queueing

set -u
org="${org:-x-cmd-install}"
progress_file="${progress_file:-}"
paused_file="${paused_file:-}"
cooldown_seconds="${cooldown_seconds:-1800}"

line="$1"
[ -z "$line" ] && exit 0
ownerrepo=$(printf '%s' "$line" | awk -F'\t' '{print $1}')
repo=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
desc=$(printf '%s' "$line" | awk -F'\t' '{$1=""; $2=""; sub(/^\t\t/, ""); print}')
[ -z "$repo" ] && exit 0

# Skip if repo exists in org.
if gh repo view "$org/$repo" >/dev/null 2>&1; then
    [ -n "$progress_file" ] && printf 'SKIP %s\n' "$repo" >> "$progress_file"
    exit 0
fi

# Create the public repo.
if ! gh repo create "$org/$repo" --public --description "${desc:-$repo}" 2>/tmp/err.$$; then
    err=$(cat /tmp/err.$$ 2>/dev/null)
    rm -f /tmp/err.$$
    if printf '%s' "$err" | grep -q "too many repositories"; then
        printf 'RATE_LIMIT %s — sleeping %ds then retrying...\n' "$repo" "$cooldown_seconds" >&2
        [ -n "$paused_file" ] && printf '%s\n' "$line" >> "$paused_file"
        exit 75
    fi
    [ -n "$progress_file" ] && printf 'FAIL %s: %s\n' "$repo" "$err" >> "$progress_file"
    exit 1
fi
rm -f /tmp/err.$$

# Push README with yfm frontmatter.
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
        [ -n "$progress_file" ] && printf 'OK   %s\n' "$repo" >> "$progress_file"
        exit 0
    else
        err=$(cat /tmp/err.$$ 2>/dev/null)
        rm -f /tmp/err.$$
        [ -n "$progress_file" ] && printf 'FAIL %s push: %s\n' "$repo" "$err" >> "$progress_file"
        exit 1
    fi
)
rc=$?
rm -rf "$tmpdir"
exit $rc