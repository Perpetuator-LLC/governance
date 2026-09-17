#!/usr/bin/env bash
# detect-harness.test.sh — the harness detector must FAIL CLOSED.
#
# A wrong answer files a seat under another harness's row, so the property with the most assertions
# is that the detector never guesses: no signal ⇒ refusal, an invalid declaration ⇒ loud refusal, and
# a marker directory (present on any machine that ran every installer) decides nothing.
#
# ⚠️ EVERY CASE STRIPS THE AMBIENT HARNESS. This suite usually runs inside an agent session, which
# sets the very variables the detector reads. Without `noenv` each case would inherit "claude" and
# the fail-closed assertions would pass for the wrong reason — or pass locally and fail in CI.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT="$ROOT/bin/detect-harness"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

noenv() { env -u CLAUDE_CODE_ENTRYPOINT -u AI_AGENT -u GOVERNANCE_HARNESS "$@"; }

echo "detect-harness"
check "the script is executable" "[ -x '$DETECT' ]"

echo " ── the environment under test is really stripped"
check "noenv removes an inherited harness signal" \
  "[ -z \"\$(CLAUDE_CODE_ENTRYPOINT=x noenv sh -c 'printf %s \"\${CLAUDE_CODE_ENTRYPOINT:-}\"')\" ]"

echo " ── positive evidence is honoured"
for h in claude codex grok; do
  check "a declaration names $h" "[ \"\$(noenv env GOVERNANCE_HARNESS=$h '$DETECT')\" = $h ]"
done
check "a Claude entrypoint signal is detected" \
  "[ \"\$(noenv env CLAUDE_CODE_ENTRYPOINT=cli '$DETECT')\" = claude ]"
check "an AI_AGENT Claude signal is detected" \
  "[ \"\$(noenv env AI_AGENT=claude-code_1-0-0_agent '$DETECT')\" = claude ]"
check "a declaration OUTRANKS a sniffed signal" \
  "[ \"\$(noenv env GOVERNANCE_HARNESS=codex CLAUDE_CODE_ENTRYPOINT=cli '$DETECT')\" = codex ]"
check "--quiet prints nothing on success and exits 0" \
  "out=\$(noenv env GOVERNANCE_HARNESS=grok '$DETECT' --quiet); [ \$? -eq 0 ] && [ -z \"\$out\" ]"
check "--explain names the deciding evidence on stderr, not stdout" \
  "noenv env CLAUDE_CODE_ENTRYPOINT=cli '$DETECT' --explain >'$TMP/o' 2>'$TMP/e'; grep -q CLAUDE_CODE_ENTRYPOINT '$TMP/e' && [ \"\$(cat '$TMP/o')\" = claude ]"

echo " ── no evidence refuses (known-negative)"
check "no signal ⇒ exit 3, never a default" \
  "noenv '$DETECT' --quiet; [ \$? -eq 3 ]"
check "no signal ⇒ nothing on stdout, the remedy on stderr" \
  "noenv '$DETECT' >'$TMP/o' 2>'$TMP/e'; [ ! -s '$TMP/o' ] && grep -q GOVERNANCE_HARNESS '$TMP/e'"
check "a non-Claude AI_AGENT value is NOT read as claude" \
  "noenv env AI_AGENT=some-other-agent '$DETECT' --quiet; [ \$? -eq 3 ]"
check "an EMPTY entrypoint variable is not evidence" \
  "noenv env CLAUDE_CODE_ENTRYPOINT= '$DETECT' --quiet; [ \$? -eq 3 ]"
check "an INVALID declaration refuses loudly (exit 2) instead of falling through to sniffing" \
  "noenv env GOVERNANCE_HARNESS=claude-code CLAUDE_CODE_ENTRYPOINT=cli '$DETECT' >'$TMP/o' 2>'$TMP/e'; [ \$? -eq 2 ] && [ ! -s '$TMP/o' ] && grep -q 'not one of' '$TMP/e'"
check "an unknown argument exits 2" \
  "noenv '$DETECT' --bogus >/dev/null 2>&1; [ \$? -eq 2 ]"

# The rejected detector, asserted as rejected: if detection is ever "fixed" by testing for a marker
# directory, this fails on a home where every overlay exists.
# --- an adapter can declare EXTRA harness names; declared names are accepted, never inferred ---
check "an undeclared extra name is refused (exit 2)" \
  "noenv env GOVERNANCE_HARNESS=custombot '$DETECT' --quiet; [ \$? -eq 2 ]"
check "a declared extra name is accepted from GOVERNANCE_HARNESS" \
  "out=\$(noenv env GOVERNANCE_EXTRA_HARNESSES=custombot GOVERNANCE_HARNESS=custombot '$DETECT'); [ \$? -eq 0 ] && [ \"\$out\" = custombot ]"
check "a declared extra name is never inferred from signals" \
  "out=\$(noenv env GOVERNANCE_EXTRA_HARNESSES=custombot '$DETECT' 2>/dev/null); [ \"\$out\" != custombot ]"

mkdir -p "$TMP/home/.claude" "$TMP/home/.codex" "$TMP/home/.grok"
check "marker directories for every harness decide NOTHING" \
  "noenv env HOME='$TMP/home' '$DETECT' --quiet; [ \$? -eq 3 ]"
check "an installer variable (CODEX_HOME) is not evidence of codex" \
  "noenv env CODEX_HOME='$TMP/home/.codex' '$DETECT' --quiet; [ \$? -eq 3 ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
