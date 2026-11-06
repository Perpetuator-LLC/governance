#!/usr/bin/env bash
# tests/authoring-stamp-gate.test.sh — known-answer tests for hooks/authoring-stamp-gate.py
# (governance#392), through the real PreToolUse JSON-on-stdin channel, with an injectable clock
# (GOVERNANCE_STAMP_NOW) so the suite never races the real wall clock.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/authoring-stamp-gate.py"
[[ -f "$HOOK" ]] || { echo "FAIL: $HOOK missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 to run this hook with"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

GATED="$TMP/gated-tools.json"
cat > "$GATED" <<'JSON'
{
  "gitea_comment_on_issue": ["comment"],
  "gitea_create_issue": ["body"],
  "gitea_update_issue": ["body"]
}
JSON

run_gate() {  # run_gate <now HH:MM> <body> [<tool_name>] [<field>] [<gated_list>]
  local now="$1" body="$2" tool="${3:-gitea_comment_on_issue}" field="${4:-comment}" list="${5:-$GATED}"
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' "$tool" "$field" "$body")
  printf '%s' "$payload" | GOVERNANCE_GATED_TOOLS="$list" GOVERNANCE_STAMP_NOW="$now" python3 "$HOOK"
}

check() {  # check <name> <now> <body> <want ALLOW|BLOCK> [<tool>] [<field>] [<list>]
  local name="$1" now="$2" body="$3" want="$4" tool="${5:-}" field="${6:-}" list="${7:-}"
  local out rc got
  out=$(run_gate "$now" "$body" "${tool:-gitea_comment_on_issue}" "${field:-comment}" "${list:-$GATED}" 2>&1)
  rc=$?
  got=$([ "$rc" = 2 ] && echo BLOCK || echo ALLOW)
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name (got $got, want $want, rc=$rc): $out"; fi
}

echo "── authoring-stamp-gate"

# --- REFUSE: an approximate first-line stamp, however close it actually lands ---
check "REFUSE: first-line ~01:30Z when the clock reads 01:39Z" \
  "01:39" "$(printf 'ctr-claude, ~01:30Z: status update')" BLOCK

check "REFUSE: first-line 01:0xZ (placeholder digit)" \
  "01:39" "$(printf 'ctr-claude, 01:0xZ: status update')" BLOCK

check "REFUSE: first-line HH:MMish" \
  "01:39" "$(printf 'ctr-claude, 01:35ish: status update')" BLOCK

check "REFUSE: first-line (now), never a clock reading" \
  "01:39" "$(printf 'ctr-claude (now): status update')" BLOCK

check "REFUSE: first-line (at the time of writing)" \
  "01:39" "$(printf 'ctr-claude (at the time of writing): status update')" BLOCK

# --- ALLOW: an exact first-line stamp within tolerance, including the boundary ---
check "ALLOW: exact first-line stamp, 0 min off" \
  "01:39" "$(printf 'ctr-claude, 01:39Z: status update')" ALLOW

check "ALLOW: exact first-line stamp, 1 min off" \
  "01:39" "$(printf 'ctr-claude, 01:38Z: status update')" ALLOW

check "ALLOW: exact first-line stamp, exactly at the +/-3 min boundary" \
  "01:39" "$(printf 'ctr-claude, 01:42Z: status update')" ALLOW

check "REFUSE: exact first-line stamp, 4 min off (just outside tolerance)" \
  "01:39" "$(printf 'ctr-claude, 01:43Z: status update')" BLOCK

check "ALLOW: exact first-line stamp, tolerance wraps midnight" \
  "00:01" "$(printf 'ctr-claude, 23:59Z: status update')" ALLOW

# --- ALLOW: a past event's time cited in the body, on a LATER line — never in scope ---
check "ALLOW: a past-event ~15:38Z cited on a later line, with a valid first-line stamp" \
  "01:39" "$(printf 'ctr-claude, 01:39Z: status update\nThe hook failed ~15:38Z during run 19588.')" ALLOW

check "ALLOW: a past-event ~15:38Z cited on a later line, with NO first-line stamp" \
  "01:39" "$(printf 'No stamp on this line.\nThe hook failed ~15:38Z during run 19588.')" ALLOW

check "ALLOW: a past-event cited with 'now'-shaped prose on a later line" \
  "01:39" "$(printf 'No stamp on this line.\nIt is running right now, started at 15:38Z.')" ALLOW

# --- ALLOW: no stamp at all ---
check "ALLOW: no stamp anywhere" \
  "01:39" "plain prose, nothing that looks like a time" ALLOW

# --- control: ordinary use of the word 'now', NOT in stamp position, is never flagged ---
check "ALLOW: 'now' used in ordinary prose, not stamp position" \
  "01:39" "$(printf 'ctr-claude: fixing this now, will follow up shortly')" ALLOW

# --- control: a past time on the first line that is NOT a stamp-shaped header is unaffected by
#     scope (this gate only looks for the patterns above; free text is never a false stamp) ---
check "ALLOW: first line is plain prose mentioning no colon-time at all" \
  "01:39" "$(printf 'Starting the rotation now (placeholder word only, no time attached)')" ALLOW

# --- tool scoping: an undeclared tool is never checked; different fields/tools work the same way ---
check "ALLOW: a tool not in the declared list is never checked" \
  "01:39" "$(printf 'ctr-claude, ~01:30Z: status update')" ALLOW "SomeOtherTool" "comment"

check "BLOCK: gitea_create_issue's own 'body' field is checked the same way" \
  "01:39" "$(printf 'ctr-claude, ~01:30Z: status update')" BLOCK "gitea_create_issue" "body"

check "BLOCK: a differently-prefixed MCP tool name is still gated by its suffix" \
  "01:39" "$(printf 'ctr-claude, ~01:30Z: status update')" BLOCK "mcp__some-other-org__gitea_comment_on_issue" "comment"

# --- fail-open paths: loud, never silent ---
out=$(printf 'not json' | GOVERNANCE_GATED_TOOLS="$GATED" GOVERNANCE_STAMP_NOW="01:39" python3 "$HOOK" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "malformed hook payload: fails open (rc 0)" || bad "malformed payload did not fail open (rc=$rc)"
[[ "$out" == *"not checking"* ]] && ok "malformed hook payload: says it is NOT CHECKING" \
  || bad "malformed payload failed open with no 'not checking' signal: $out"

MISSING="$TMP/does-not-exist.json"
check_missing_out=$(run_gate "01:39" "ctr-claude, ~01:30Z: status" gitea_comment_on_issue comment "$MISSING" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "no gated-tool list: fails open (rc 0)" || bad "no gated-tool list did not fail open (rc=$rc)"
[[ "$check_missing_out" == *"not checking"* ]] && ok "no gated-tool list: says it is NOT CHECKING" \
  || bad "no gated-tool list allowed with no 'not checking' signal: $check_missing_out"

echo
if [[ $fail -eq 0 ]]; then echo "  ✅ all checks passed ($pass)"; exit 0
else echo "  ❌ $fail failed, $pass passed"; exit 1; fi
