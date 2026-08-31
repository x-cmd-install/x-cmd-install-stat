#!/usr/bin/env bash
# .x-cmd/test-repo-card.sh — test suite for `x repo card`.
#
# Run from the repo root:
#     ./.x-cmd/test-repo-card.sh
#     ./.x-cmd/test-repo-card.sh --verbose   # show every assertion
#
# Validates the tool's output against the bugs we hit:
#   - Output is parseable YAML (yq -e .)
#   - Required sections present (about / timeline / popularity / recent)
#   - No raw "?" placeholder for missing values (old card.jq bug)
#   - description containing `--`, `#`, `:`, `"`, newlines parses cleanly
#   - Nonexistent repo returns a graceful empty card, not a crash
#   - Numeric fields stay numeric (not string-quoted)
#   - recent windows: last30d / last90d / last180d / last360d all present
#   - language block + totalBytes sum present
#
# Test design notes:
#   - Numeric comparison (>, <, ==) accepts any numeric type in yq (int/float).
#   - `test("regex")` requires string input; cast with `| tostring` first for
#     dates (which yq auto-tags as !!timestamp).
#   - `.field == ""` matches both null and empty string (yq normalizes).
#   - We test against LOCAL `x repo card` output, not against the cards
#     already in stat/ (those came from upstream, which still runs an
#     older card.jq — see the .x-cmd/sync.sh comment block).

set -u

repo_root="$(cd "$(dirname "$0")" && cd .. && pwd)"
cd "$repo_root"

verbose=0
[ "${1:-}" = "--verbose" ] && verbose=1

pass=0; fail=0; total=0

ok()   { total=$((total+1)); pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { total=$((total+1)); fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { [ "$verbose" = 1 ] && printf '        %s\n' "$1" || true; }

# run_card <owner/repo> -> stdout is the card yaml, stderr dropped
run_card() { x repo card "$1" 2>/dev/null; }

# assert_card <name> <owner/repo> <jq-expr> [expected-output]
# The jq-expr must produce a truthy yq result (use `| not` for negation).
assert_card() {
    local name="$1" repo="$2" expr="$3" expected="${4:-true}"
    local out got
    out=$(run_card "$repo")
    if [ -z "$out" ]; then
        bad "$name — empty output for $repo"
        return
    fi
    got=$(echo "$out" | yq "$expr" 2>&1)
    if [ "$got" = "$expected" ]; then
        ok "$name"
    else
        bad "$name — for $repo"
        note "expr:     $expr"
        note "expected: $expected"
        note "got:      $got"
        note "first 6 lines of output:"
        note "$(echo "$out" | head -6 | sed 's/^/          /')"
    fi
}

echo "==> x repo card test suite"
echo

# --- 1. Basic shape ---
assert_card "1.1 real repo parses cleanly"             jqlang/jq     'true'
assert_card "1.2 about section present"                jqlang/jq     '.about != null'
assert_card "1.3 timeline section present"             jqlang/jq     '.timeline != null'
assert_card "1.4 popularity section present"          jqlang/jq     '.popularity != null'
assert_card "1.5 recent section present"               jqlang/jq     '.recent != null'

# --- 2. Real fields are well-typed ---
# Numeric fields — yq auto-tags unquoted integers as !!int, so use
# arithmetic comparison which works for any numeric type.
assert_card "2.1 popularity.star > 0 (popular repo)"  jqlang/jq     '.popularity.star > 0'
assert_card "2.2 popularity.fork > 0"                  jqlang/jq     '.popularity.fork > 0'
assert_card "2.3 about.head matches hex SHA regex"     jqlang/jq     '.about.head | test("^[0-9a-f]{7,40}$")'
# Dates — yq auto-tags YYYY-MM-DD as !!timestamp; cast to string first.
assert_card "2.4 timeline.created is YYYY-MM-DD"      jqlang/jq     '.timeline.created | tostring | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")'
assert_card "2.5 about.license non-empty"              jqlang/jq     '.about.license | length > 0'

# --- 3. recent windows ---
assert_card "3.1 recent.last30d present"               jqlang/jq     '.recent.last30d != null'
assert_card "3.2 recent.last90d present"               jqlang/jq     '.recent.last90d != null'
assert_card "3.3 recent.last180d present"              jqlang/jq     '.recent.last180d != null'
assert_card "3.4 recent.last360d present"              jqlang/jq     '.recent.last360d != null'
assert_card "3.5 recent.last30d.commit is numeric"     jqlang/jq     '.recent.last30d.commit >= 0'

# --- 4. language + totalBytes ---
# The card tool emits `totalBytes` (sum of language sizes); older versions
# emitted `totalLine`. We pin the current name and fail loudly if it ever
# changes back, so downstream tooling breaks at the test step rather than
# silently.
assert_card "4.1 language block + totalBytes > 0"     jqlang/jq     '.language != null and .totalBytes > 0'

# --- 5. The '?' bug regression ---
# Old card.jq wrote `lastRelease: ?` (raw ?) when the field was unknown,
# which is invalid YAML. New card.jq emits empty string instead.
assert_card "5.1 about.head != '?'"                    jqlang/jq     '.about.head != "?"'
assert_card "5.2 timeline.created != '?'"              jqlang/jq     '.timeline.created != "?"'
assert_card "5.3 timeline.lastCommit != '?'"           jqlang/jq     '.timeline.lastCommit != "?"'
assert_card "5.4 timeline.lastRelease != '?'"          jqlang/jq     '.timeline.lastRelease != "?"'

# --- 6. Special chars in description ---
# HKUDS/CLI-Anything's description has `--` (YAML comment start) and `:` (mapping sep).
# Frooodle/Stirling-PDF's description starts with `#1` (YAML comment char in plain scalar).
# The current implementation uses a literal block scalar (`|`) for description so
# none of these characters are interpreted as YAML structure.
assert_card "6.1 CLI-Anything desc parses AND contains --" HKUDS/CLI-Anything \
    '.about.description | contains("--")'
assert_card "6.2 CLI-Anything star > 0"                HKUDS/CLI-Anything \
    '.popularity.star > 0'
assert_card "6.3 Stirling-PDF desc parses AND starts with #1" Frooodle/Stirling-PDF \
    '.about.description | test("^#1 ")'
assert_card "6.4 Stirling-PDF star > 0"                Frooodle/Stirling-PDF \
    '.popularity.star > 0'

# --- 7. Nonexistent repo ---
# Tool must NOT crash. Output should be a parseable card with all numeric
# fields at 0 and all string fields null. We use `length == 0` because it
# matches both null and empty string (== "" doesn't match null in yq).
assert_card "7.1 nonexistent repo parses cleanly"      x-cmd-install/this-does-not-exist-99999 \
    'true'
assert_card "7.2 nonexistent repo: star == 0"          x-cmd-install/this-does-not-exist-99999 \
    '.popularity.star == 0'
assert_card "7.3 nonexistent repo: description empty"  x-cmd-install/this-does-not-exist-99999 \
    '.about.description | length == 0'
assert_card "7.4 nonexistent repo: head empty"          x-cmd-install/this-does-not-exist-99999 \
    '.about.head | length == 0'
assert_card "7.5 nonexistent repo: created empty"      x-cmd-install/this-does-not-exist-99999 \
    '.timeline.created | length == 0'

# --- 8. Idempotency ---
# Two consecutive runs against the same repo must produce semantically
# identical cards (timestamps may legitimately differ; we ignore those
# fields via yq's object-path filter).
out1=$(run_card jqlang/jq)
out2=$(run_card jqlang/jq)
norm() { yq 'del(.about.collectedAt)' <<<"$1" | yq -P .; }
if [ -n "$out1" ] && [ -n "$out2" ] && [ "$(norm "$out1")" = "$(norm "$out2")" ]; then
    ok "8.1 idempotent (ignoring collectedAt)"
else
    bad "8.1 idempotent (ignoring collectedAt) — runs differ"
    note "diff:"
    note "$(diff <(norm "$out1") <(norm "$out2") 2>&1 | head -10 | sed 's/^/          /')"
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m==> all %d tests passed\033[0m\n' "$total"
    exit 0
else
    printf '\033[31m==> %d/%d tests failed\033[0m\n' "$fail" "$total"
    exit 1
fi
