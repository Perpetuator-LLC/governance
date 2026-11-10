#!/usr/bin/env bash
# tests/handoff-layout-gate.test.sh — known-answer tests for hooks/handoff-layout-gate.py.
# The exhibit (a bare one-line `for` loop handed to the human) must be refused; a correct block must pass;
# each rule R1–R5 must fire alone (R5 in its untimed and timed forms); the Stop-hook channel must emit {"decision":"block"} and allow a retry.
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
echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'
sudo ./rotate.sh
echo \"■ deploy · #12 B · 2/3 · done rc=\$?\"
${F}"

EXHIBIT="Run this:
${F}bash
for k in a b c; do printf %s \$k; done
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

# R5 (the human, 2026-11-06): the shell itself shows which agent, card, step and request time a block is,
# and that it finished. Each mutation of GOOD's banner must fire R5 alone.
check "R5 fires: no banner line"                             1 "must open with" "$(printf '%s' "$GOOD" | sed "/^echo '▶/d")"
check "R5 fires: no end line"                                1 "must close with" "$(printf '%s' "$GOOD" | sed '/^echo "■/d')"
check "R5 fires: end label differs from the banner"          1 "does not repeat" "$(printf '%s' "$GOOD" | sed 's/■ deploy · #12 B · 2\/3/■ deploy · #12 A · 2\/3/')"
check "R5 fires: step beyond total"                          1 "out of range" "$(printf '%s' "$GOOD" | sed 's/2\/3/4\/3/g')"
check "R5 fires: banner without a time"                      1 "must open with" "$(printf '%s' "$GOOD" | sed 's/ · 11-06 19:20//')"
check "R5: a banner in double quotes is accepted too"        0 "ok" "$(printf '%s' "$GOOD" | sed "s/^echo '▶ \(.*\)'\$/echo \"▶ \1\"/")"

# R5 label injection (cisa SEND-BACK, #395): the label is echoed in the human's shell and the END line is
# double-quoted, so a card taken from a ticket title must not be able to carry an expansion or a quote.
# The payloads are read by python from a QUOTED heredoc: bash never expands them here.
inject() {  # inject <banner|end> <payload>: GOOD with the payload appended to the card label on one line
  python3 - "$GOOD" "$1" "$2" <<'PY'
import sys
good, where, p = sys.argv[1:]
mark = "echo '▶ deploy · #12 B" if where == "banner" else 'echo "■ deploy · #12 B'
print(good.replace(mark, mark + p, 1), end="")
PY
}
while IFS= read -r payload; do
  [ -n "$payload" ] || continue
  check "R5 refuses banner label carrying: $payload" 1 "must open with" "$(inject banner "$payload")"
  check "R5 refuses end label carrying: $payload"    1 "must close with" "$(inject end "$payload")"
done <<'PAYLOADS'
$(id)
`id`
${HOME}
;id
'
"
\
PAYLOADS

# R5 TIMED form (the human, 2026-11-09, governance#403): the shell records when the block actually ran, how long
# it took, and the agent's estimate. Lines are built from QUOTED heredocs so bash never expands them here.
TB=$(cat <<'L'
T0=$(date +%s); echo "▶ deploy · #12 B · 2/3 · asked 11-09 07:10 · est ~2m · start $(date '+%H:%M:%S')"
L
)
TE=$(cat <<'L'
rc=$?; echo "■ deploy · #12 B · 2/3 · done rc=$rc · end $(date '+%H:%M:%S') · took $(( $(date +%s) - T0 ))s"
L
)
# The mutant coa named: a `date` runs before `$?` is read, so the end line reports date's rc, not the block's.
TE_MUT=$(cat <<'L'
echo "■ deploy · #12 B · 2/3 · end $(date '+%H:%M:%S') · done rc=$? · took $(( $(date +%s) - T0 ))s"
L
)
timed() {  # timed <banner> <end>: GOOD with its banner and end lines replaced
  python3 - "$GOOD" "$1" "$2" <<'PY2'
import sys
good, b, e = sys.argv[1:]
out = []
for l in good.split("\n"):
    out.append(b if l.startswith("echo '▶") else e if l.startswith('echo "■') else l)
print("\n".join(out), end="")
PY2
}
GOOD_TIMED=$(timed "$TB" "$TE")
check "R5 timed: banner + end pass"                             0 "ok" "$GOOD_TIMED"
check "R5 timed: rc read after a date (the mutant) is refused"  1 "must close with" "$(timed "$TB" "$TE_MUT")"
check "R5 timed: timed banner with an untimed end is refused"   1 "rc=\$? FIRST" "$(timed "$TB" 'echo "■ deploy · #12 B · 2/3 · done rc=$?"')"
check "R5 timed: untimed banner with a timed end is refused"    1 "must close with" "$(timed "echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'" "$TE")"
check "R5 timed: banner without an estimate is refused"         1 "must open with" "$(timed "${TB/ · est ~2m/}" "$TE")"
check "R5 timed: banner without the start clock is refused"     1 "must open with" "$(timed "${TB/ · start \$(date \'+%H:%M:%S\')/}" "$TE")"
check "R5 timed: end without took is refused"                   1 "must close with" "$(timed "$TB" "${TE/ · took*s\"/\"}")"
check "R5 timed: end label differs from the banner"             1 "does not repeat" "$(timed "$TB" "${TE/\#12 B/#12 A}")"
check "R5 timed: step beyond total"                             1 "out of range" "$(timed "${TB/2\/3/4\/3}" "${TE/2\/3/4\/3}")"
check "R5 timed: any other expansion in the banner is refused"  1 "must open with" "$(timed "${TB/est ~2m/est ~2m \$(id)}" "$TE")"
check "R5 timed: any other expansion in the end is refused"     1 "must close with" "$(timed "$TB" "${TE/done rc=\$rc/done rc=\$rc \$(id)}")"

# Execution: the canonical pair, run around a failing command, must report THAT command's status; the mutant
# must not (this is why the gate insists on `rc=$?` first). Run in every shell a human may paste into.
for sh in bash zsh; do
  command -v "$sh" >/dev/null || { pass "R5 timed exec: $sh not installed, skipped"; continue; }
  out=$(printf '%s\n%s\n%s\n' "$TB" "(exit 3)" "$TE" | "$sh" 2>&1)
  if printf '%s' "$out" | grep -qE '■ deploy · #12 B · 2/3 · done rc=3 · end [0-9]{2}:[0-9]{2}:[0-9]{2} · took [0-9]+s$' \
     && printf '%s' "$out" | grep -qE '^▶ deploy · #12 B · 2/3 · asked 11-09 07:10 · est ~2m · start [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
    pass "R5 timed exec ($sh): end line reports the failing command's rc=3, start/end/took filled"
  else fail "R5 timed exec ($sh): $out"; fi
  out=$(printf '%s\n%s\n%s\n' "$TB" "(exit 3)" "$TE_MUT" | "$sh" 2>&1)
  if printf '%s' "$out" | grep -q 'done rc=0'; then pass "R5 timed exec ($sh): the mutant loses rc=3 (reports 0)"
  else fail "R5 timed exec ($sh): mutant kept the rc, so the test cannot tell them apart: $out"; fi
done

# The header-table form (requested by the human, 2026-10-25): a two-row table directly above the fence,
# in place of the `► user@host · 🔑 PROMPTS · 📝 LOGGED` line.
GOOD_TABLE="## 👤 You
**Rotate the key**
| 🖥️ workstation | 👤 alice | 📝 ~/.local/state/x.log |
| --- | --- | --- |
| 🔑 alice · password · workstation (sudo) | | |
${F}bash
echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'
sudo ./rotate.sh
echo \"■ deploy · #12 B · 2/3 · done rc=\$?\"
${F}"

check "header table alone (no ► line) satisfies R1/R2/R4"    0 "ok" "$GOOD_TABLE"
check "fence with NEITHER the ► line nor a table fails"      1 "R1" "## 👤 You
Run this:
${F}bash
echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'
sudo ./rotate.sh
echo \"■ deploy · #12 B · 2/3 · done rc=\$?\"
${F}"
check "table missing its 🔑 row fails R2 when the block prompts" 1 "R2" "## 👤 You
| 🖥️ workstation | 👤 alice | 📝 no |
| --- | --- | --- |
${F}bash
echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'
sudo ./rotate.sh
echo \"■ deploy · #12 B · 2/3 · done rc=\$?\"
${F}"
check "table's 🔑 row says 'none' but the block prompts: R2 fires" 1 "R2" "$(printf '%s' "$GOOD_TABLE" | sed 's/🔑 alice · password · workstation (sudo)/🔑 none/')"
check "table with 📝 cell 'no' still satisfies R4 (states the answer, need not BE logged)" 0 "ok" "$(printf '%s' "$GOOD_TABLE" | sed 's/📝 ~\/.local\/state\/x.log/📝 no/')"

# The 2-cell header table (requested by the human, same day): user and machine merged into one cell.
GOOD_TABLE2="## 👤 You
**Rotate the key**
| 👤 alice@workstation | 📝 ~/.local/state/x.log |
| --- | --- |
| 🔑 alice · password · workstation (sudo) | |
${F}bash
echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'
sudo ./rotate.sh
echo \"■ deploy · #12 B · 2/3 · done rc=\$?\"
${F}"

check "2-cell table (user@machine merged) satisfies R1/R2/R4"  0 "ok" "$GOOD_TABLE2"
check "2-cell table missing its 🔑 row fails R2 when the block prompts" 1 "R2" "## 👤 You
| 👤 alice@workstation | 📝 no |
| --- | --- |
${F}bash
echo '▶ deploy · #12 B · 2/3 · 11-06 19:20'
sudo ./rotate.sh
echo \"■ deploy · #12 B · 2/3 · done rc=\$?\"
${F}"
check "2-cell table's 🔑 row says 'none' but the block prompts: R2 fires" 1 "R2" "$(printf '%s' "$GOOD_TABLE2" | sed 's/🔑 alice · password · workstation (sudo)/🔑 none/')"
check "2-cell table's identity cell with no '@' (not user@machine) fails R1" 1 "R1" "$(printf '%s' "$GOOD_TABLE2" | sed 's/👤 alice@workstation/👤 alice/')"

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
if [ -s "$TMP/deny.jsonl" ] && ! grep -q 'printf %s' "$TMP/deny.jsonl"; then pass "refusal recorded in the deny trail, without the message text"; else fail "deny trail missing or leaks text"; fi
mk "$TMP/g.jsonl" "$GOOD"
out=$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/g.jsonl" | python3 "$HOOK"); rc=$?
if [ $rc = 0 ] && [ -z "$out" ]; then pass "Stop channel: correct layout -> no block"; else fail "good on Stop channel: rc=$rc out=$out"; fi
out=$(printf 'not json' | python3 "$HOOK"); rc=$?
if [ $rc = 0 ] && [ -z "$out" ]; then pass "malformed event never blocks"; else fail "malformed: rc=$rc out=$out"; fi

echo "handoff-layout-gate: $fails failure(s)"
exit $((fails > 0))
