#!/usr/bin/env bash
# legs.test.sh — tests/lib/legs.sh: a skipped leg prints NOT RUN and fails the suite, never green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
check() { if eval "$2"; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1"; fail=$((fail+1)); fi; }

suite() {  # suite <legs-to-skip> <failures> -> runs a fixture suite in a subshell; prints its output, returns its status
  ( . "$ROOT/tests/lib/legs.sh"
    for ((i = 0; i < $1; i++)); do leg_not_run "parser: fixture-$i" "this host has no jq"; done
    legs_verdict "$2" )
}

echo "legs — a leg that did not run is NOT RUN, and the suite fails"
out=$(suite 1 0); rc=$?
check "one skipped leg, zero failures: the suite FAILS (not green)" "[ $rc -ne 0 ]"
check "…and prints NOT RUN for the leg" "grep -q 'fixture-0 — NOT RUN: this host has no jq' <<<\"\$out\""
check "…and says the suite is incomplete" "grep -q 'INCOMPLETE, not passed' <<<\"\$out\""
check "…and never prints SKIPPED" "! grep -q 'SKIPPED' <<<\"\$out\""
out=$(suite 0 0); rc=$?
check "every leg ran, zero failures: the suite passes" "[ $rc -eq 0 ]"
check "…and prints no NOT RUN line" "! grep -q 'NOT RUN' <<<\"\$out\""
out=$(suite 0 3); rc=$?
check "every leg ran, 3 failures: the suite fails" "[ $rc -ne 0 ]"
out=$(suite 2 0); rc=$?
check "two skipped legs are counted" "[ $rc -ne 0 ] && grep -q 'NOT RUN: 2 leg' <<<\"\$out\""

# The suites with a jq-only leg must report it through this helper, not a bare "SKIPPED" echo.
# (Running them here would rebuild their whole PATH shims; the wiring is what this row pins.)
f="$ROOT/tests/secret-read-gate.test.sh"
check "secret-read-gate.test.sh reports its jq-only leg through legs.sh"   "grep -q 'tests/lib/legs.sh' '$f' && grep -q 'leg_not_run' '$f' && grep -q 'legs_verdict' '$f' && ! grep -q 'SKIPPED' '$f'"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
