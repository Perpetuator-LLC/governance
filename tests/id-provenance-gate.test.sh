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
  "SendMessage": ["message"],
  "send_message": ["message"]
}
JSON

run_gate() {  # run_gate <tool_name> <field> <body> <transcript_file> [<user_prompt>] [<gated_list>]
  GOVERNANCE_GATED_TOOLS="${6:-$GATED}" python3 "$HOOK" <<EOF
{"tool_name": "$1", "tool_input": {"$2": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$3")}, "transcript_path": "$4", "prompt": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1] if len(sys.argv) > 1 else ""))' "${5:-}")}
EOF
}

echo "── id-provenance-gate"

# --- 0. P1 LIVE regression (cisa c138162): a forge URL anchor "#issuecomment-N" starts with a
#     non-alphanumeric character. Bounding its LEFT side (no digit immediately before "#") refused
#     every citation of a tool's own returned html_url, because a forge URL always puts a PR/issue
#     number directly before the anchor ("…/1368#issuecomment-N"). Digits generated at runtime so
#     "unseen" is never accidentally true by a fixture collision elsewhere in this file.
FULL_N=$(( RANDOM % 900000 + 100000 ))   # 6-digit id, minted and cited in full
TRUNC_N="${FULL_N:0:5}"                  # the same id with its last digit dropped: a different id
UNSEEN_N=$(( RANDOM % 900000 + 100000 )) # minted nowhere in any transcript below
URL_SEEN="https://forge.example/owner/repo/pulls/1368#issuecomment-${FULL_N}"

T0a="$TMP/t0a.jsonl"
mktranscript "$T0a" "{\"type\":\"tool_result\",\"content\":\"posted: $URL_SEEN\"}"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see $URL_SEEN for context" "$T0a"); rc=$?
[[ $rc -eq 0 ]] && pass "(1) a forge URL anchor is cited verbatim after the SAME URL anchor was seen: allowed" \
  || fail "(1) a seen URL anchor cited verbatim was wrongly refused (rc=$rc): $out"

out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c${FULL_N} for context" "$T0a"); rc=$?
[[ $rc -eq 0 ]] && pass "(2) a URL anchor was seen; the short c-form is cited instead: allowed" \
  || fail "(2) the short c-form of a seen URL anchor was wrongly refused (rc=$rc): $out"

T0c="$TMP/t0c.jsonl"
mktranscript "$T0c" "{\"type\":\"tool_result\",\"content\":\"posted as c${FULL_N}\"}"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see https://forge.example/owner/repo/pulls/1368#issuecomment-${FULL_N} for context" "$T0c"); rc=$?
[[ $rc -eq 0 ]] && pass "(3) a short c-form was seen; the forge URL anchor is cited instead: allowed" \
  || fail "(3) a URL anchor citing a seen short c-form id was wrongly refused (rc=$rc): $out"

T0d="$TMP/t0d.jsonl"
mktranscript "$T0d" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see https://forge.example/owner/repo/pulls/1368#issuecomment-${UNSEEN_N} for context" "$T0d"); rc=$?
[[ $rc -eq 2 ]] && pass "(4) an id minted nowhere, cited as a URL anchor: refused" \
  || fail "(4) a wholly unseen id (URL-anchor form) was wrongly allowed (rc=$rc): $out"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c${UNSEEN_N} for context" "$T0d"); rc=$?
[[ $rc -eq 2 ]] && pass "(4b) the same unseen id, cited in short c-form: refused" \
  || fail "(4b) a wholly unseen id (short c-form) was wrongly allowed (rc=$rc): $out"

out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see https://forge.example/owner/repo/pulls/1368#issuecomment-${TRUNC_N} for context" "$T0a"); rc=$?
[[ $rc -eq 2 ]] && pass "(5) a truncated URL anchor (missing the real id's last digit) is refused" \
  || fail "(5) a truncated URL anchor matched inside the longer real one (rc=$rc): $out"

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

# --- 1c. a 6-digit short-comment id is also a valid 7-char hex run ('c' is a-f): it must be read as
#     ONE citation (short-comment), never also flagged as an absent commit-sha (coa SEND-BACK on #330)
T1c="$TMP/t1c.jsonl"
mktranscript "$T1c" '{"type":"tool_result","content":"comment posted: https://forge/x/issues/9#issuecomment-120571"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c120571 for context" "$T1c"); rc=$?
[[ $rc -eq 0 ]] && pass "6-digit short-comment id (c + hex-letter digits) matched against its earlier anchor: allowed" \
  || fail "6-digit short-comment id was wrongly refused, likely double-matched as a commit-sha: $out"

# --- 1d. a TRUNCATED guess must not match inside a longer real id: c13801 is a substring of
#     c138010, but was never itself minted (cisa non-blocking note 2, c138010) ---
T1d="$TMP/t1d.jsonl"
mktranscript "$T1d" '{"type":"tool_result","content":"comment posted: https://forge/x/issues/9#issuecomment-138010"}'
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c13801 for context" "$T1d"); rc=$?
[[ $rc -eq 2 ]] && pass "a 5-digit guess (c13801) is refused even though it is a prefix of the real 6-digit id (c138010)" \
  || fail "a truncated guess matched inside a longer real id (rc=$rc): $out"
# control: the full, correctly-minted id still matches
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c138010 for context" "$T1d"); rc=$?
[[ $rc -eq 0 ]] && pass "control: the full 6-digit id (c138010) still matches its own anchor" \
  || fail "control: the full id was wrongly refused (rc=$rc): $out"

# --- 1e. the MIRROR of 1d: a commit SHA is bounded on the LEFT only, because citing a short PREFIX
#     of a full SHA a tool already returned is the normal, correct form (coa SEND-BACK on #330,
#     c138080) — the right-hand bound added for comment ids must not also apply here.
SHA_FULL="0bf5a697d91234567890abcdef1234567890abcd"     # 40 hex, 'a' and 'f' present
SHA_MIDWORD="9a0bf5a690123456789abcdef0123456789abcde"  # "0bf5a69" sits at offset 2, not at the start
T1e="$TMP/t1e.jsonl"
mktranscript "$T1e" "{\"type\":\"tool_result\",\"content\":\"commit $SHA_FULL\"}"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see $SHA_FULL for context" "$T1e"); rc=$?
[[ $rc -eq 0 ]] && pass "the full 40-hex SHA matches itself (control)" \
  || fail "control: the full SHA was wrongly refused (rc=$rc): $out"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see 0bf5a697 for context" "$T1e"); rc=$?
[[ $rc -eq 0 ]] && pass "an 8-char PREFIX of a full SHA a tool already returned is allowed (coa's exact example)" \
  || fail "a short-SHA prefix of a seen full SHA was wrongly refused (rc=$rc): $out"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see deadbeef for context" "$T1e"); rc=$?
[[ $rc -eq 2 ]] && pass "an 8-hex string that starts no SHA in the transcript is refused" \
  || fail "an unrelated 8-hex string was wrongly allowed (rc=$rc): $out"
T1e2="$TMP/t1e2.jsonl"
mktranscript "$T1e2" "{\"type\":\"tool_result\",\"content\":\"commit $SHA_MIDWORD\"}"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see 0bf5a69 for context" "$T1e2"); rc=$?
[[ $rc -eq 2 ]] && pass "a 7-hex string found only MID-WORD inside a longer SHA (not at its start) is refused" \
  || fail "a mid-word hex substring was wrongly allowed as a SHA prefix (rc=$rc): $out"

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

# --- 2c. the exact surface named in the fleet-wide SEND-BACK request: a peer-DM tool over MCP,
#     citing a guessed forge comment id in the same batch as the post that would create it ---
T2c="$TMP/t2c.jsonl"
mktranscript "$T2c" '{"type":"tool_result","content":"unrelated"}'
out=$(run_gate mcp__ccd_session_mgmt__send_message message "see c120571 for context" "$T2c"); rc=$?
[[ $rc -eq 2 ]] && pass "a guessed comment id cited over an MCP send-message tool: refused" \
  || fail "a guessed comment id over an MCP send-message tool was not gated (rc=$rc): $out"

# --- 2d. the known-good mirror: the SAME tool, citing an id that was actually minted first ---
T2d="$TMP/t2d.jsonl"
mktranscript "$T2d" '{"type":"tool_result","content":"comment posted: https://forge/x/issues/9#issuecomment-120571"}'
out=$(run_gate mcp__ccd_session_mgmt__send_message message "see c120571 for context" "$T2d"); rc=$?
[[ $rc -eq 0 ]] && pass "a REAL comment id cited over an MCP send-message tool, minted first: allowed" \
  || fail "a real, earlier-minted comment id over an MCP send-message tool was wrongly blocked (rc=$rc): $out"

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

# --- 7. malformed stdin fails OPEN, and says so (cisa non-blocking note 1, c138010) ---
out=$(printf 'not json' | GOVERNANCE_GATED_TOOLS="$GATED" python3 "$HOOK" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "malformed hook payload: fails open (rc 0), not a refusal" \
  || fail "malformed payload did not fail open (rc=$rc)"
[[ "$out" == *"not checking"* ]] && pass "malformed hook payload: says it is NOT CHECKING, not silently clean" \
  || fail "malformed hook payload failed open with no 'not checking' signal: $out"

# --- 7b. an UNREADABLE transcript (path given, file absent) fails open, and says so too ---
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c76292 for context" "$TMP/no-such-transcript.jsonl" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "unreadable transcript: fails open (rc 0)" \
  || fail "unreadable transcript did not fail open (rc=$rc)"
[[ "$out" == *"not checking"* ]] && pass "unreadable transcript: says it is NOT CHECKING, not silently clean" \
  || fail "unreadable transcript failed open with no 'not checking' signal: $out"

# --- 7c. no transcript_path AT ALL in the hook payload fails open, and says so ---
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c76292 for context" "" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "no transcript_path in the payload: fails open (rc 0)" \
  || fail "no transcript_path did not fail open (rc=$rc)"
[[ "$out" == *"not checking"* ]] && pass "no transcript_path: says it is NOT CHECKING, not silently clean" \
  || fail "no transcript_path failed open with no 'not checking' signal: $out"

# --- 7d. the transcript read is BOUNDED to a tail window (cisa non-blocking note 3, c138010): an id
#     minted further back than the window is not found (same refusal as never minted); the same id
#     minted inside the window is found. Built with python for speed — bash line-by-line padding of
#     this size is minutes slower for no benefit. ---
T7D_FAR="$TMP/t7d-far.jsonl"
T7D_NEAR="$TMP/t7d-near.jsonl"
python3 - "$T7D_FAR" "$T7D_NEAR" <<'PY'
import json, sys
far, near = sys.argv[1], sys.argv[2]
mint = json.dumps({"type": "tool_result", "content": "comment posted: https://forge/x/issues/9#issuecomment-999001"}) + "\n"
pad = json.dumps({"type": "tool_result", "content": "x" * 500}) + "\n"
pad_count = (11 * 1024 * 1024) // len(pad)  # ~11 MB of padding: past the 10 MB tail window
with open(far, "w") as fh:
    fh.write(mint)              # the real mint sits BEFORE 11 MB of padding -> falls outside the tail window
    for _ in range(pad_count):
        fh.write(pad)
with open(near, "w") as fh:
    for _ in range(pad_count):  # ~11 MB of padding FIRST
        fh.write(pad)
    fh.write(mint)               # the real mint sits in the last few hundred bytes -> inside the tail window
PY
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c999001 for context" "$T7D_FAR"); rc=$?
[[ $rc -eq 2 ]] && pass "an id minted before the tail-read window is treated as not seen (bounded read is live)" \
  || fail "an id minted outside the 10 MB tail window was still found — the read is not actually bounded (rc=$rc): $out"
out=$(run_gate mcp__perpetuator__gitea_comment_on_issue comment "see c999001 for context" "$T7D_NEAR"); rc=$?
[[ $rc -eq 0 ]] && pass "the same id minted INSIDE the tail-read window is still found" \
  || fail "an id minted inside the 10 MB tail window was not found (rc=$rc): $out"

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
