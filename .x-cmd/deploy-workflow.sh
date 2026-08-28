#!/usr/bin/env bash
# .x-cmd/deploy-workflow.sh — push the daily card workflow into every
# x-cmd-install/<software> repo.
#
# Each target repo gets three files:
#     .github/workflows/card.yml   — schedule + commit step
#     .github/card.sh              — standalone `x repo card` port (curl + jq)
#     .github/card.jq              — the jq filter library it inlines
#
# The cron minute is derived from md5(repo) so the 2500+ repos spread evenly
# across the 00:00-00:59 UTC window. Every repo firing at exactly `0 0 * * *`
# lands in GitHub's most congested scheduler slot, where runs are delayed by
# tens of minutes or silently dropped.
#
# Resume-safe: every repo outcome is appended to .x-cmd/deploy.progress, and
# repos already marked OK/SKIP are not revisited on a rerun.
#
# Usage:
#     ./.x-cmd/deploy-workflow.sh                 # deploy to all org repos
#     ./.x-cmd/deploy-workflow.sh --dry-run       # list actions only
#     ./.x-cmd/deploy-workflow.sh --jobs 4        # parallelism (default 4)
#     ./.x-cmd/deploy-workflow.sh --limit 10      # first N repos (smoke test)
#     ./.x-cmd/deploy-workflow.sh --input FILE    # explicit repo-name list
#     ./.x-cmd/deploy-workflow.sh --force         # redeploy repos already OK
#     ./.x-cmd/deploy-workflow.sh --dispatch      # also trigger a run now

set -u

repo_root="$(cd "$(dirname "$0")" && cd .. && pwd)"
tpl_dir="$repo_root/.x-cmd/workflow"
progress_file="$repo_root/.x-cmd/deploy.progress"
org="x-cmd-install"

jobs=4
limit=0
dry_run=0
force=0
dispatch=0
input_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n)  dry_run=1 ;;
        --force)       force=1 ;;
        --dispatch)    dispatch=1 ;;
        --jobs=*)      jobs="${1#--jobs=}" ;;
        --jobs)        shift; jobs="${1:-4}" ;;
        --limit=*)     limit="${1#--limit=}" ;;
        --limit)       shift; limit="${1:-0}" ;;
        --input=*)     input_file="${1#--input=}" ;;
        --input)       shift; input_file="${1:-}" ;;
        -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

for f in card.yml card.sh card.jq; do
    [ -r "$tpl_dir/$f" ] || { echo "missing template: $tpl_dir/$f" >&2; exit 1; }
done

touch "$progress_file"

# Repo list: names only (the org repo name == the software name).
list_file="$(mktemp -t xcmddeploy.XXXXXX)"
trap 'rm -f "$list_file"' EXIT
if [ -n "$input_file" ]; then
    grep -E '^[A-Za-z0-9._-]+$' "$input_file" | sort -u > "$list_file"
else
    gh repo list "$org" --limit 4000 --json name --jq '.[].name' | sort -u > "$list_file"
fi
[ "$limit" -gt 0 ] && { head -n "$limit" "$list_file" > "$list_file.cut"; mv "$list_file.cut" "$list_file"; }

total=$(wc -l < "$list_file" | tr -d ' ')
done_count=$(awk '$1=="OK"||$1=="SKIP"{print $2}' "$progress_file" | sort -u | grep -c . || true)
echo "==> $total repos in $org; already deployed: $done_count; jobs=$jobs"
[ "$dry_run" = 1 ] && { echo "==> dry run, nothing pushed"; exit 0; }

deploy_one() {
    repo="$1"

    if [ "$force" != 1 ] && grep -q "^OK $repo\$" "$progress_file" 2>/dev/null; then
        return 0
    fi

    # Only per-software install stubs get the card workflow. `gh repo list`
    # also returns the org's own project repos (x-cmd-install, this stat repo)
    # and a few empty leftovers with no upstream at all; card.sh would fail on
    # every scheduled run there, so skip anything without owner-repo yfm.
    upstream=$(curl -fsSL --max-time 25 \
        "https://raw.githubusercontent.com/$org/$repo/main/README.md" 2>/dev/null \
        | awk -F':[[:space:]]*' '/^owner-repo:/{print $2; exit}' | tr -d '[:space:]')
    case "$upstream" in
        */*) : ;;
        *)   printf 'SKIP %s (no owner-repo frontmatter)\n' "$repo" >> "$progress_file"
             return 0 ;;
    esac

    # Spread the cron minute: first byte of md5(repo) mod 60.
    hexbyte=$(printf '%s' "$repo" | md5sum 2>/dev/null | cut -c1-2) \
        || hexbyte=$(printf '%s' "$repo" | md5 | cut -c1-2)
    minute=$(( 0x$hexbyte % 60 ))

    tmpdir="$(mktemp -d -t xcmddeployrepo.XXXXXX)"
    (
        set -e
        cd "$tmpdir"
        git clone -q --depth 1 "https://x-access-token:$GH_PUSH_TOKEN@github.com/$org/$repo.git" r
        cd r
        mkdir -p .github/workflows
        sed "s/__MINUTE__/$minute/" "$tpl_dir/card.yml" > .github/workflows/card.yml
        cp "$tpl_dir/card.sh" "$tpl_dir/card.jq" .github/
        chmod +x .github/card.sh
        git add -A .github
        git diff --cached --quiet && exit 3   # already identical
        git -c user.name="x-cmd-install bot" -c user.email="bot@x-cmd.com" \
            commit -q -m "ci: daily repo card -> data/<date>.yml (00:$(printf '%02d' "$minute") UTC)"
        git push -q origin HEAD:main
    ) >"$tmpdir/log" 2>&1
    rc=$?
    rm -rf "$tmpdir"

    case "$rc" in
        0) printf 'OK   %s (00:%02d)\n' "$repo" "$minute" | tee -a "$progress_file" ;;
        3) printf 'SKIP %s (unchanged)\n' "$repo" >> "$progress_file" ;;
        *) printf 'FAIL %s rc=%d\n' "$repo" "$rc" | tee -a "$progress_file" >&2 ;;
    esac

    [ "$dispatch" = 1 ] && [ "$rc" = 0 ] && \
        gh workflow run card.yml --repo "$org/$repo" >/dev/null 2>&1
    return 0
}

GH_PUSH_TOKEN="$(gh auth token)"
[ -n "$GH_PUSH_TOKEN" ] || { echo "no gh token; run gh auth login" >&2; exit 1; }
export -f deploy_one
export org tpl_dir progress_file force dispatch GH_PUSH_TOKEN

xargs -n1 -P"$jobs" -I{} bash -c 'deploy_one "$@"' _ {} < "$list_file"

echo "==> final tally:"
echo "    OK:   $(grep -c '^OK '   "$progress_file")"
echo "    SKIP: $(grep -c '^SKIP ' "$progress_file")"
echo "    FAIL: $(grep -c '^FAIL ' "$progress_file")"
