#!/usr/bin/env bash
# tests/handoff-layout-gate.test.sh — known-answer tests for hooks/handoff-layout-gate.py.
# The exhibit (a bare one-line `for` loop handed to the human) must be refused; a correct block must pass;
# each rule R1–R4 must fire alone; the Stop-hook channel must emit {"decision":"block"} and allow a retry.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/handoff-layout-gate.py"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() {  # check <name> <want-rc> <want-substring|-> <message-text>
  printf '%s' "$4" > "$TMP/m.md"
  out=$(python3 "$HOOK" --check "$TMP/m.md"); rc=$?
  if [ "$rc" != "$2" ]; then fail "$1 (rc $rc, want $2): $out"; return; fi
  if [ "$3" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$3"; then fail "$1 (missing '$3'): $out"; return; fi
  pass "$1"
}
F='```'

GOOD="## ✅ Done
- rotated nothing yet

## 👤 You
**Rotate the key**
► alice@workstation · 🔑 PROMPTS: alice · password · workstation (sudo)
📝 LOGGED → ~/.local/state/x.log
${F}bash
sudo ./rotate.sh
${F}"

EXHIBIT="Run this:
${F}bash
for k in a b c; do bao kv put secret/x/\$k v=1; done
${F}"

check "exhibit (bare for-loop, 2026-10-20) is refused"       1 "R1" "$EXHIBIT"
check "a console fence is a shell block too (refused without layout)" 1 "R1" "Run this:
${F}console
for k in a b; do echo \$k; done
${F}"
check "correct layout passes"                                0 "ok" "$GOOD"
check "no shell block at all: nothing to check"              0 "ok" "## Notes
plain text, and a ${F}python
print(1)
${F} block that is not shell"
check "R1 fires alone (no ► host line)"                      1 "R1" "$(printf '%s' "$GOOD" | sed '/►/d')"
check "R2 fires alone (sudo, no 🔑 PROMPTS)"                 1 "R2" "$(printf '%s' "$GOOD" | sed 's/ · 🔑 PROMPTS: alice · password · workstation (sudo)//')"
check "R3 fires: no 👤 You section"                          1 "R3" "$(printf '%s' "$GOOD" | sed 's/## 👤 You/## Steps/')"
check "R3 fires: 👤 You not last"                            1 "must be the LAST" "$GOOD
## ⏭️ Later
- something"
check "R4 fires alone (no LOGGED marker)"                    1 "R4" "$(printf '%s' "$GOOD" | sed '/LOGGED/d')"
check "🚫 NOT LOGGED satisfies R4"                           0 "ok" "$(printf '%s' "$GOOD" | sed 's/📝 LOGGED → ~\/.local\/state\/x.log/🚫 NOT LOGGED (no output)/')"

# The header-table form (requested by Nik, 2026-10-25): a two-row table directly above the fence,
# in place of the `► user@host · 🔑 PROMPTS · 📝 LOGGED` line.
GOOD_TABLE="## 👤 You
**Rotate the key**
| 🖥️ workstation | 👤 alice | 📝 ~/.local/state/x.log |
| --- | --- | --- |
| 🔑 alice · password · workstation (sudo) | | |
${F}bash
sudo ./rotate.sh
${F}"

check "header table alone (no ► line) satisfies R1/R2/R4"    0 "ok" "$GOOD_TABLE"
check "fence with NEITHER the ► line nor a table fails"      1 "R1" "## 👤 You
Run this:
${F}bash
sudo ./rotate.sh
${F}"
check "table missing its 🔑 row fails R2 when the block prompts" 1 "R2" "## 👤 You
| 🖥️ workstation | 👤 alice | 📝 no |
| --- | --- | --- |
${F}bash
sudo ./rotate.sh
${F}"
check "table's 🔑 row says 'none' but the block prompts: R2 fires" 1 "R2" "$(printf '%s' "$GOOD_TABLE" | sed 's/🔑 alice · password · workstation (sudo)/🔑 none/')"
check "table with 📝 cell 'no' still satisfies R4 (states the answer, need not BE logged)" 0 "ok" "$(printf '%s' "$GOOD_TABLE" | sed 's/📝 ~\/.local\/state\/x.log/📝 no/')"

# Stop-hook channel: a transcript whose last assistant text is the exhibit
mk() { python3 - "$1" "$2" <<'PY'
import json,sys
open(sys.argv[1],"w").write(json.dumps({"type":"user","message":{"content":"hi"}})+"\n"+
  json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[2]}]}})+"\n")
PY
}
mk "$TMP/t.jsonl" "$EXHIBIT"
out=$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/t.jsonl" | GOVERNANCE_DENY_LOG="$TMP/deny.jsonl" python3 "$HOOK"); rc=$?
if [ $rc = 0 ] && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["decision"]=="block" and "R1" in d["reason"] else 1)'; then pass "Stop channel: exhibit -> decision block with reason"; else fail "Stop channel block: rc=$rc out=$out"; fi
out=$(printf '{"transcript_path":"%s","stop_hook_active":true}' "$TMP/t.jsonl" | GOVERNANCE_DENY_LOG="$TMP/deny.jsonl" python3 "$HOOK"); rc=$?
if [ $rc = 0 ] && [ -z "$out" ]; then pass "Stop channel: retry (stop_hook_active) is allowed, never loops"; else fail "retry: rc=$rc out=$out"; fi
if [ -s "$TMP/deny.jsonl" ] && ! grep -q 'bao kv put' "$TMP/deny.jsonl"; then pass "refusal recorded in the deny trail, without the message text"; else fail "deny trail missing or leaks text"; fi
mk "$TMP/g.jsonl" "$GOOD"
out=$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/g.jsonl" | python3 "$HOOK"); rc=$?
if [ $rc = 0 ] && [ -z "$out" ]; then pass "Stop channel: correct layout -> no block"; else fail "good on Stop channel: rc=$rc out=$out"; fi
out=$(printf 'not json' | python3 "$HOOK"); rc=$?
if [ $rc = 0 ] && [ -z "$out" ]; then pass "malformed event never blocks"; else fail "malformed: rc=$rc out=$out"; fi

echo "handoff-layout-gate: $fails failure(s)"
exit $((fails > 0))
