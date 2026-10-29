#!/usr/bin/env bash
# tests/id-provenance-gate.test.sh — refuse a body citing an id no earlier transcript entry
# contains; allow one that's genuinely there, or one the user just typed. (governance#203)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/id-provenance-gate.py"
[[ -f "$HOOK" ]] || { echo "FAIL: $HOOK missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 to run this hook with"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

mktranscript() {  # mktranscript <file> <line...> — one JSONL line per arg, already-JSON-encoded strings
  local f="$1"; shift
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}

# A standard declared gated-tool list for this suite's own use — the hook ships with none (see its
# own docstring: a list this repo ships would be a rule for every fleet, so WHICH tools and fields
# apply here can never live in a file this repo carries). tests/*.test.sh is exempt from the shape
# legs redaction-check otherwise applies to every file in this repo, so the concrete tool names a
# mutation-coverage suite needs to prove the gate fires belong here, not in the hook itself.
GATED="$TMP/gated-tools.json"
cat > "$GATED" <<'JSON'
{
  "gitea_comment_on_issue": ["comment"],
  "state_item_upsert": ["notes", "current_step"],
  "SendMessage": ["message"]
}
JSON

run_gate() {  # run_gate <tool_name> <field> <body> <transcript_file> [<user_prompt>] [<gated_list>]
  GOVERNANCE_GATED_TOOLS="${6:-$GATED}" python3 "$HOOK" <<EOF
{"tool_name": "$1", "tool_input": {"$2": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$3")}, "transcript_path": "$4", "prompt": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1] if len(sys.argv) > 1 else ""))' "${5:-}")}
EOF
}

echo "── id-provenance-gate"

# --- 1. an id minted in an EARLIER tool result is allowed ---
T1="$TMP/t1.jsonl"
mktranscript "$T1" '{"type":"tool_result","content":"comment posted: https://forge/x/issues/9#issuecomment-76292"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c76292 for context" "$T1"); rc=$?
[[ $rc -eq 0 ]] && pass "id seen in an earlier tool result: allowed" \
  || fail "id seen in an earlier tool result was blocked: $out"

# --- 1b. the mirror: an #issuecomment- form is cited, only the short c-form exists earlier ---
T1b="$TMP/t1b.jsonl"
mktranscript "$T1b" '{"type":"tool_result","content":"posted as c76292"}'
out=$(run_gate SendMessage message "see https://forge/x#issuecomment-76292" "$T1b"); rc=$?
[[ $rc -eq 0 ]] && pass "issuecomment- form matched against an earlier short c-form: allowed" \
  || fail "issuecomment- form was blocked despite the same id's short form earlier: $out"

# --- 2. the SAME id with no earlier occurrence is refused ---
T2="$TMP/t2.jsonl"
mktranscript "$T2" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c76292 for context" "$T2"); rc=$?
[[ $rc -eq 2 ]] && pass "id with no earlier occurrence: refused" \
  || fail "id with no earlier occurrence was allowed (rc=$rc): $out"

# --- 2b. a DIFFERENT installation's server label still refuses — the suffix match does not depend
#     on which org/instance name sits between the two leading "__" markers ---
T2b="$TMP/t2b.jsonl"
mktranscript "$T2b" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate mcp__some-other-org__gitea_comment_on_issue comment "see c76292 for context" "$T2b"); rc=$?
[[ $rc -eq 2 ]] && pass "a differently-prefixed MCP tool name is still gated by its suffix: refused" \
  || fail "a differently-prefixed MCP tool name was not gated (rc=$rc): $out"

# --- 3. an id the USER typed this turn is allowed ---
T3="$TMP/t3.jsonl"
mktranscript "$T3" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "re your c99999" "$T3" "please reply to c99999"); rc=$?
[[ $rc -eq 0 ]] && pass "id present in the user's own prompt: allowed" \
  || fail "id in the user's prompt was blocked: $out"

# --- 4. a placeholder is refused regardless of transcript content ---
T4="$TMP/t4.jsonl"
mktranscript "$T4" '{"type":"tool_result","content":"#i=PENDING appears right here, verbatim"}'
out=$(run_gate mcp__perpetuator__state_item_upsert notes "card #i=PENDING" "$T4"); rc=$?
[[ $rc -eq 2 ]] && pass "#i=PENDING placeholder: refused even if the literal text is in the transcript" \
  || fail "placeholder was allowed (rc=$rc): $out"

out=$(run_gate SendMessage message "ping <id> when ready" "$T4"); rc=$?
[[ $rc -eq 2 ]] && pass "angle-bracket placeholder <id>: refused" \
  || fail "angle-bracket placeholder was allowed (rc=$rc): $out"

out=$(run_gate SendMessage message "see the <comment-id> once minted" "$T4"); rc=$?
[[ $rc -eq 2 ]] && pass "angle-bracket placeholder <comment-id>: refused" \
  || fail "angle-bracket placeholder <comment-id> was allowed (rc=$rc): $out"

# --- 4b. ordinary Markdown/HTML tags are NOT placeholders — the fleet ships a <sub> footer routinely ---
out=$(run_gate SendMessage message "posted.

<sub>Seat: some-seat</sub>" "$T4"); rc=$?
[[ $rc -eq 0 ]] && pass "a <sub>...</sub> attribution footer: not a placeholder, allowed" \
  || fail "a <sub> footer was refused as a placeholder (rc=$rc): $out"

out=$(run_gate SendMessage message "<details><summary>more</summary>text</details>" "$T4"); rc=$?
[[ $rc -eq 0 ]] && pass "<details><summary> markup: not a placeholder, allowed" \
  || fail "<details>/<summary> markup was refused as a placeholder (rc=$rc): $out"

# --- 4c. a placeholder INSIDE a fenced example is stripped before the placeholder check runs,
#     same as a real id would be (the docstring's own ordering claim) ---
out=$(run_gate SendMessage message 'example: ```see #i=<uuid> in the old format```' "$T4"); rc=$?
[[ $rc -eq 0 ]] && pass "placeholder inside a fenced block: not flagged" \
  || fail "placeholder inside a fenced block was refused (rc=$rc): $out"

# --- 4d. an all-digit run (a date, a count) is not a commit sha ---
T4d="$TMP/t4d.jsonl"
mktranscript "$T4d" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate SendMessage message "landed on 20261028" "$T4d"); rc=$?
[[ $rc -eq 0 ]] && pass "an 8-digit date is not treated as a commit sha: allowed" \
  || fail "an 8-digit date was refused as a commit sha (rc=$rc): $out"

# --- 5. an id inside a FENCED code block the body quotes is not flagged ---
T5="$TMP/t5.jsonl"
mktranscript "$T5" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment 'example: ```see c12345 in the old format```' "$T5"); rc=$?
[[ $rc -eq 0 ]] && pass "id inside a fenced block: not flagged" \
  || fail "id inside a fenced block was blocked: $out"

# --- 6. an ungated tool is never touched ---
T6="$TMP/t6.jsonl"
mktranscript "$T6" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate SomeOtherTool comment "see c76292" "$T6"); rc=$?
[[ $rc -eq 0 ]] && pass "a tool not in the declared list: never checked" \
  || fail "an undeclared tool was blocked: $out"

# --- 7. malformed stdin fails OPEN ---
out=$(printf 'not json' | GOVERNANCE_GATED_TOOLS="$GATED" python3 "$HOOK" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "malformed hook payload: fails open (rc 0), not a refusal" \
  || fail "malformed payload did not fail open (rc=$rc)"

# --- 8. a MISSING gated-tool list fails open, and says so — never a silent allow ---
T8="$TMP/t8.jsonl"
mktranscript "$T8" '{"type":"tool_result","content":"unrelated"}'
MISSING="$TMP/does-not-exist.json"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c76292 for context" "$T8" "" "$MISSING" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "no gated-tool list: fails open (rc 0)" \
  || fail "no gated-tool list did not fail open (rc=$rc)"
[[ "$out" == *"not checking"* ]] && pass "no gated-tool list: says it is NOT CHECKING, not silently clean" \
  || fail "no gated-tool list allowed with no 'not checking' signal: $out"

# --- 9. a VALID but EMPTY gated-tool list ({}) is "checked, nothing gated" — distinct from a missing
#     or unreadable one. Only the stderr note tells the two apart; this is mutant M7 (coa SEND-BACK on
#     #330, `is None` → `not gated` would treat {} the same as "not checking"). ---
T9="$TMP/t9.jsonl"
mktranscript "$T9" '{"type":"tool_result","content":"unrelated"}'
EMPTY="$TMP/empty-gated.json"
printf '{}\n' > "$EMPTY"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c76292 for context" "$T9" "" "$EMPTY" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "an empty-but-valid gated-tool list ({}): allowed (nothing is gated)" \
  || fail "an empty gated-tool list wrongly blocked (rc=$rc): $out"
[[ "$out" != *"not checking"* ]] && pass "an empty-but-valid gated-tool list ({}): no 'not checking' note — it WAS checked" \
  || fail "an empty gated-tool list ({}) wrongly printed 'not checking': $out"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1; fi
