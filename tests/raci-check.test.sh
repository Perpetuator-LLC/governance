#!/usr/bin/env bash
# raci-check.test.sh
#
# Known answers for raci-check: one R and one A pass (the same party in both included); two R's,
# two A's or none are refused with file, line, row and the parties named; a parenthesised note is
# never a party; a table without an R and an A column is ignored, and a scan that finds no RACI
# table at all is NOT CHECKED (exit 3), never clean.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/raci-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run()  { python3 "$CHECK" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

echo "raci-check"
check "the script is executable" "[ -x '$CHECK' ]"

cat > "$TMP/good.md" <<'DOC'
# Ownership

| system | **A**ccountable | **R**esponsible (does the edit) | Consulted |
|---|---|---|---|
| Billing | **Finance lead** | billing-lane (its build twin · a container) | Ops, Legal |
| Search | Product lead | Product lead | |
DOC
rc="$(run "$TMP/good.md")"
check "known-GOOD: one R and one A per row, R = A allowed, a note with separators inside is one party (exit 0)" "[ '$rc' = '0' ]"
check "known-GOOD: the summary counts the table and its rows" "grep -q '1 table(s), 2 row(s), 0 finding(s)' '$TMP/out'"

cat > "$TMP/bad.md" <<'DOC'
| system | A | R | notes |
|---|---|---|---|
| Mail | ops-lead | mail-lane · records-lane | two doers |
| Wiki | — | wiki-lane | nobody answers |
| Chat | lead-a · lead-b | chat-lane | |
| Backups | ops-lead | | |
| Ledger | ops-lead | ledger-lane | fine |
DOC
rc="$(run "$TMP/bad.md")"
check "known-BAD: a bad row fails the file (exit 1)" "[ '$rc' = '1' ]"
check "two R's are refused, naming the line, the row and both parties" "grep -qF 'bad.md:3: Mail: 2 R'\''s: mail-lane, records-lane' '$TMP/out'"
check "a dash is no A" "grep -qF 'bad.md:4: Wiki: no A' '$TMP/out'"
check "two A's are refused" "grep -qF 'bad.md:5: Chat: 2 A'\''s: lead-a, lead-b' '$TMP/out'"
check "an empty R cell is no R" "grep -qF 'bad.md:6: Backups: no R' '$TMP/out'"
check "the one good row among them is not reported" "! grep -q 'Ledger' '$TMP/out'"
check "exactly four findings" "grep -q '5 row(s), 4 finding(s)' '$TMP/out'"

cat > "$TMP/seps.md" <<'DOC'
| item | Responsible | Accountable |
|---|---|---|
| one | a / b | x |
| two | a + b | x |
| three | a & b | x |
| four | `a` | **x** (on leave · y covers) |
| five | whoever creates it, at creation | ops-lead, or a deputy on its direction |
DOC
rc="$(run "$TMP/seps.md")"
check "slash, plus and ampersand separate parties; markup, a note and a prose comma do not" \
  "[ '$rc' = '1' ] && grep -c 'R'\''s:' '$TMP/out' | grep -qx 3 && ! grep -q 'four' '$TMP/out' && ! grep -q 'five' '$TMP/out'"

cat > "$TMP/other.md" <<'DOC'
| name | value |
|---|---|
| retries | 3 |
DOC
rc="$(run "$TMP/other.md")"
check "a table with no R and A column is not checked: NOT CHECKED (exit 3), never clean" "[ '$rc' = '3' ] && grep -q 'NOT CHECKED' '$TMP/err'"
rc="$(run "$TMP/other.md" "$TMP/good.md")"
check "a file without a RACI table beside one with it: the one is checked (exit 0)" "[ '$rc' = '0' ]"

rc="$(run "$TMP/nope.md")"
check "an unreadable path cannot run (exit 2), naming it" "[ '$rc' = '2' ] && grep -q 'cannot read .*nope.md' '$TMP/err'"
rc="$(run)"
check "no paths cannot run (exit 2)" "[ '$rc' = '2' ]"

rc="$(run --json "$TMP/bad.md")"
check "--json lists each finding with its parties" \
  "[ '$rc' = '1' ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"rows\"]==5 and len(d[\"findings\"])==4 and d[\"findings\"][0][\"parties\"]==[\"mail-lane\",\"records-lane\"]' '$TMP/out'"

# Split on the escaped pipe, the row would read R = "a \", A = "—": a false "no A".
printf '| item | R | A |\n|---|---|---|\n| escaped | a \\| — | x |\n' > "$TMP/esc.md"
rc="$(run "$TMP/esc.md")"
check "an escaped pipe stays inside its cell" "[ '$rc' = '0' ]"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
