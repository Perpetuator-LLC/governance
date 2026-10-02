#!/usr/bin/env bash
# tests/check-cadence.test.sh — a document naming a cadence must name its routine (#162).
#
# Fixture, expected values derived by hand:
#   kpi-weekly.md      cadence: weekly, no routine                          -> NO-ROUTINE
#   kpi-armed.md       cadence: weekly, routine: tasks/snap/SKILL.md (exists) -> clean
#   kpi-dangling.md    cadence: daily,  routine: tasks/missing/SKILL.md      -> ROUTINE-NAMES-NOTHING
#   decision-once.md   cadence: once                                         -> not a recurrence, skipped
#   decision-named.md  cadence: monday, routine: nightly-vault (a name)      -> clean (declared)
#   broken.md          frontmatter that will not parse                       -> UNREADABLE (own count)
#   plain.md           no cadence                                            -> clean
#   tasks/snap/SKILL.md  the routine's file, no frontmatter (never yielded)
# => checked 6 · 4 name a cadence · 1 unreadable · 2 findings · exit 1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ROOT/bin/check-cadence"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-cadence.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

V="$TMP/vault"; mkdir -p "$V/tasks/snap"
fm() { printf -- '---\n%s\n---\nbody\n' "$2" > "$V/$1"; }
fm kpi-weekly.md      $'type: kpi\ncadence: weekly'
fm kpi-armed.md       $'type: kpi\ncadence: weekly\nroutine: tasks/snap/SKILL.md'
fm kpi-dangling.md    $'type: kpi\ncadence: daily\nroutine: tasks/missing/SKILL.md'
fm decision-once.md   $'type: decision\ncadence: once'
fm decision-named.md  $'type: decision\ncadence: monday\nroutine: nightly-vault'
fm broken.md          $'cadence: weekly: [unclosed'
fm plain.md           $'type: note'
echo "the task body" > "$V/tasks/snap/SKILL.md"

echo "── check-cadence"
out=$("$CC" --vault-root "$V" 2>&1); rc=$?
[ $rc -eq 1 ] && pass "findings exit 1" || fail "exit $rc, expected 1"
grep -q 'checked 6 frontmatter(s) · 4 name a cadence · 1 unreadable' <<<"$out" \
  && pass "counts: 6 checked, 4 with a cadence, 1 unreadable" || fail "counts wrong: $(grep checked <<<"$out")"
grep -qE 'NO-ROUTINE +kpi-weekly.md' <<<"$out" && pass "a cadence with no routine is a finding" || fail "kpi-weekly not reported"
grep -qE 'ROUTINE-NAMES-NOTHING +kpi-dangling.md' <<<"$out" && pass "a routine path that resolves to nothing is a finding" \
  || fail "kpi-dangling not reported"
grep -qE 'UNREADABLE +broken.md' <<<"$out" && pass "an unparseable frontmatter is reported as UNREADABLE" || fail "broken.md not reported"
! grep -qE '(NO-ROUTINE|NOTHING) +(kpi-armed|decision-once|decision-named|plain)' <<<"$out" \
  && pass "an existing routine, a one-time value, a named routine and no cadence are all clean" \
  || fail "a clean document was reported: $(grep -E 'armed|once|named|plain' <<<"$out")"
[ "$(grep -cE '^  (NO-ROUTINE|ROUTINE-NAMES-NOTHING)' <<<"$out")" = 2 ] && pass "exactly 2 findings" \
  || fail "finding count: $(grep -cE '^  (NO-ROUTINE|ROUTINE-NAMES-NOTHING)' <<<"$out")"

"$CC" --vault-root "$V" --baseline "$TMP/b.json" --write-baseline >/dev/null 2>&1
out=$("$CC" --vault-root "$V" --baseline "$TMP/b.json" 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q 'baseline: 2 entr(ies)' <<<"$out" && pass "a baseline suppresses the known two, and prints its size" \
  || fail "baseline: rc $rc, $(grep baseline <<<"$out")"
grep -q '1 unreadable' <<<"$out" && pass "the unreadable count still shows with a baseline" || fail "unreadable count hidden"
fm kpi-new.md $'type: kpi\ncadence: monthly'
out=$("$CC" --vault-root "$V" --baseline "$TMP/b.json" 2>&1); rc=$?
[ $rc -eq 1 ] && grep -qE 'NO-ROUTINE +kpi-new.md' <<<"$out" && ! grep -q 'kpi-weekly' <<<"$out" \
  && pass "a NEW finding fails through the baseline, alone" || fail "new finding: rc $rc"

"$CC" --vault-root "$TMP/no-such" >/dev/null 2>&1; [ $? -eq 2 ] && pass "a missing root is an instrument fault (exit 2)" \
  || fail "missing root did not exit 2"
mkdir -p "$TMP/empty"; "$CC" --vault-root "$TMP/empty" >/dev/null 2>&1; [ $? -eq 2 ] \
  && pass "a root with no markdown is an instrument fault, never a clean vault" || fail "empty root did not exit 2"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; else echo "  ❌ $fails failed"; fi
exit $(( fails > 0 ))
