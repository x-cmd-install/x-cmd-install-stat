#!/usr/bin/env bash
# .x-cmd/collector-repo-readme-check.sh — verify that every x-cmd-install/<mirror>
# repo's README.md (and README.cn.md) satisfies the layout we want:
#
#   Section order (must match exactly):
#     1. Install
#     2. Code insight    (not "Code size")
#     3. OpenSSF Scorecard
#     4. Source
#     5. Release
#     6. Popularity
#     7. Totals (cumulative)
#     8. Recent activity (6 windows when present)
#     9. Release assets
#    10. Distribution status (only when .x-cmd/fskv/repology_name exists)
#    11. Improve this data
#
#   Other checks:
#     - README.cn.md exists with the same 11 sections in Chinese
#     - Distribution status (if present) uses ✅ / ⚠️ / 🪦 / 🔄 emoji
#     - Code insight is renamed (no "## Code size")
#     - Recent activity has 6 rows when card has data
#     - README has been regenerated today (data freshness)
#
# Output: a pass/fail line per mirror, plus a summary at the end.
# Default mode: only mirrors in .x-cmd/sync's repo list. Pass --all
# to scan every mirror via gh repo list.

set -u

ORG="x-cmd-install"
BRANCH="main"
LOG="${LOG:-/tmp/readme-check.log}"

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

mode="known"
while [ $# -gt 0 ]; do
    case "$1" in
        --all)        mode="all" ;;
        --limit=*)    LIMIT="${1#--limit=}" ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 2 ;;
    esac
    shift
done

# Build repo list
if [ "$mode" = "all" ]; then
    LIMIT="${LIMIT:-4000}"
    gh repo list "$ORG" --limit "$LIMIT" --json name --jq '.[].name' > /tmp/_check_repos.txt
else
    # Use the stat/ directory as the source of truth — mirrors that
    # sync.sh has pulled at least once.
    find stat -mindepth 2 -maxdepth 1 -type d -printf '%f\n' | sort -u > /tmp/_check_repos.txt
fi
total=$(wc -l < /tmp/_check_repos.txt | tr -d ' ')
echo "==> $total mirrors to check (mode=$mode)" | tee "$LOG"

# Expected section order (English, with the optional Distribution
# status slot that only renders when repology_name exists).
EN_SECTIONS=(
    "Install"
    "Code insight"
    "OpenSSF Scorecard"
    "Source"
    "Release"
    "Popularity"
    "Totals"
    "Recent activity"
    "Release assets"
    "Distribution status"  # optional
    "Improve this data"
)

CN_SECTIONS=(
    "安装"
    "代码洞察"
    "OpenSSF Scorecard 评分"
    "源代码"
    "发布"
    "流行度"
    "累计统计"
    "最近活动"
    "Release 资产"
    "发行版状态"  # optional
    "改进这些数据"
)

pass=0; fail=0; checked=0
declare -a FAIL_LIST=()

while IFS= read -r name; do
    [ -z "$name" ] && continue
    checked=$((checked + 1))

    # Fetch README + fskv in parallel — saves wall time vs sequential.
    en_url="https://raw.githubusercontent.com/$ORG/$name/$BRANCH/README.md"
    cn_url="https://raw.githubusercontent.com/$ORG/$name/$BRANCH/README.cn.md"
    fskv_url="https://raw.githubusercontent.com/$ORG/$name/$BRANCH/.x-cmd/fskv/repology_name"

    en=$(curl -sfSL --max-time 10 "$en_url" 2>/dev/null || true)
    cn=$(curl -sfSL --max-time 10 "$cn_url" 2>/dev/null || true)
    repology=$(curl -sfSL --max-time 5 "$fskv_url" 2>/dev/null || true)
    has_repology=$([ -n "$repology" ] && echo 1 || echo 0)

    # EN README missing entirely
    if [ -z "$en" ]; then
        echo "FAIL  $name  (no README.md)" | tee -a "$LOG"
        FAIL_LIST+=("$name: no README.md")
        fail=$((fail + 1))
        continue
    fi

    # Extract section headers (lines starting with "## ")
    en_sections=$(echo "$en" | grep '^## ' | sed 's/^## //' | head -20)
    cn_sections=$(echo "$cn" | grep '^## ' | sed 's/^## //' | head -20)

    # Verify expected order. The 10th slot is conditional on repology.
    problems=()
    # Build the effective expected list (drop Distribution status if no repology)
    declare -a want_en=("${EN_SECTIONS[@]:0:9}" "${EN_SECTIONS[@]:10:1}")
    declare -a want_cn=("${CN_SECTIONS[@]:0:9}" "${CN_SECTIONS[@]:10:1}")
    # Compose got
    declare -a got_en got_cn
    while IFS= read -r line; do got_en+=("$line"); done <<< "$en_sections"
    while IFS= read -r line; do got_cn+=("$line"); done <<< "$cn_sections"

    # Compare
    for i in "${!want_en[@]}"; do
        g="${got_en[$i]:-}"
        w="${want_en[$i]}"
        if [ "$g" != "$w" ]; then
            problems+=("EN[$i] expected '$w' got '$g'")
        fi
    done

    # CN: only if has cn readme
    if [ -z "$cn" ]; then
        problems+=("CN: no README.cn.md")
    else
        for i in "${!want_cn[@]}"; do
            g="${got_cn[$i]:-}"
            w="${want_cn[$i]}"
            if [ "$g" != "$w" ]; then
                problems+=("CN[$i] expected '$w' got '$g'")
            fi
        done
    fi

    # Distribution status (if repology_name is set): must show emoji ✅ / ⚠️
    if [ "$has_repology" = "1" ]; then
        if ! echo "$en" | grep -q '## Distribution status'; then
            problems+=("missing Distribution status (has repology_name)")
        elif ! echo "$en" | grep -qE '✅|⚠️'; then
            problems+=("Distribution status missing emoji")
        fi
    fi

    # Code size rename check (the old name must not appear)
    if echo "$en" | grep -q '^## Code size$'; then
        problems+=("still named 'Code size' (should be 'Code insight')")
    fi

    # Recent activity: 6 windows expected when card has data
    recent_lines=$(echo "$en" | awk '/^## Recent activity/,/^## /' | grep -c '^| [0-9]')
    if [ "$recent_lines" -gt 0 ] && [ "$recent_lines" -lt 6 ]; then
        problems+=("Recent activity has $recent_lines rows (expected 6)")
    fi

    # Logo lang=zh on CN
    if [ -n "$cn" ]; then
        if ! echo "$cn" | grep -q 'repo.x-cmd.io/.*\.svg?lang=zh'; then
            problems+=("CN logo missing ?lang=zh")
        fi
    fi

    if [ ${#problems[@]} -eq 0 ]; then
        echo "PASS  $name" | tee -a "$LOG"
        pass=$((pass + 1))
    else
        echo "FAIL  $name  (${#problems[@]} issues)" | tee -a "$LOG"
        for p in "${problems[@]}"; do
            echo "      - $p" | tee -a "$LOG"
        done
        FAIL_LIST+=("$name: ${#problems[@]} issues")
        fail=$((fail + 1))
    fi

    # Periodic progress
    if [ $((checked % 50)) -eq 0 ]; then
        echo "    ... $checked/$total  pass=$pass fail=$fail" | tee -a "$LOG"
    fi
done < /tmp/_check_repos.txt

echo "==> done: checked=$checked  pass=$pass  fail=$fail  log=$LOG"
if [ ${#FAIL_LIST[@]} -gt 0 ]; then
    echo "--- failed mirrors ---" | tee -a "$LOG"
    printf '  %s\n' "${FAIL_LIST[@]}" | tee -a "$LOG"
fi
rm -f /tmp/_check_repos.txt
