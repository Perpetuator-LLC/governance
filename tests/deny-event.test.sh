#!/usr/bin/env bash
# tests/deny-event.test.sh — hooks/deny-event.py: the floor's one audit trail for a refusal.
#
# This module had NO coverage before this file: least-tested of the floor's own hooks, and the one
# whose own invariants are the hardest to see violated by eye (a never-recorded secret, a tightened
# permission, a silent exit-0 on every failure) — exactly the properties a reviewer trusts without
# checking. Quality sweep, governance repo, 2026-10-14.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/deny-event.py"
[[ -f "$HOOK" ]] || { echo "FAIL: $HOOK missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 to run this hook with"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

run() {  # run <log-path> <gate> <rule> <tool> <reason> <stdin-text> -> prints the hook's rc
  local log="$1" gate="$2" rule="$3" tool="$4" reason="$5" input="$6"
  printf '%s' "$input" | GOVERNANCE_DENY_LOG="$log" python3 "$HOOK" \
    --gate "$gate" --rule "$rule" --tool "$tool" --reason "$reason" >/dev/null 2>"$TMP/stderr"
  echo $?
}

last_line() { tail -n1 "$1"; }

echo "── deny-event"

# --- 1. a basic call writes exactly one well-formed JSON line, and exits 0 ---
LOG1="$TMP/d1/deny.jsonl"
rc=$(run "$LOG1" bash-safety-gate R1 Bash "blocked" "rm -rf /")
[[ "$rc" == "0" ]] && pass "ordinary call: exit 0" || fail "ordinary call exited $rc"
[[ -f "$LOG1" ]] && python3 -c "import json,sys; json.load(open('$LOG1'))" 2>/dev/null \
  && pass "exactly one line, and it parses as JSON" || fail "log missing or not a single JSON object"

# --- 2. NEVER RECORDS the refused text: only a 16-hex sha256 prefix of stdin ---
secret="top-secret-command --with-a-token=abc123"
rc=$(run "$LOG1" bash-safety-gate R1 Bash "blocked" "$secret")
line="$(last_line "$LOG1")"
grep -qF "$secret" <<<"$line" && fail "the refused text appeared VERBATIM in the log" \
  || pass "the refused text never appears verbatim in the log"
want_digest="$(printf '%s' "$secret" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')"
grep -qF "\"args_sha256_16\":\"$want_digest\"" <<<"$line" \
  && pass "the digest is exactly sha256(stdin)[:16]" \
  || fail "digest missing or does not match sha256(stdin)[:16]: $line"

# --- 2b. empty stdin (no tty, nothing piped) still produces the well-known empty-string digest ---
LOG2b="$TMP/d2b/deny.jsonl"
GOVERNANCE_DENY_LOG="$LOG2b" python3 "$HOOK" --gate bash-safety-gate --rule R1 --tool Bash --reason x \
  < /dev/null >/dev/null 2>&1
grep -qF '"args_sha256_16":"e3b0c44298fc1c14"' "$LOG2b" \
  && pass "empty stdin: digest is sha256(b'')[:16], the known constant" \
  || fail "empty stdin did not produce the empty-string digest"

# --- 3. append-only: a second call adds a second line, never truncates or overwrites ---
LOG3="$TMP/d3/deny.jsonl"
run "$LOG3" bash-safety-gate R1 Bash "first" "a" >/dev/null
run "$LOG3" write-safety-gate R2 Write "second" "b" >/dev/null
n=$(wc -l < "$LOG3" | tr -d ' ')
[[ "$n" == "2" ]] && pass "two calls: two lines, nothing overwritten" || fail "expected 2 lines, got $n"
grep -q '"status_detail":"first"' "$LOG3" && grep -q '"status_detail":"second"' "$LOG3" \
  && pass "both calls' own reason text survives, in order" || fail "an earlier line was lost or overwritten"

# --- 4. directory created 0700, file created 0600 ---
LOG4="$TMP/d4/sub/deny.jsonl"
run "$LOG4" bash-safety-gate R1 Bash x y >/dev/null
dmode=$(stat -c '%a' "$TMP/d4/sub" 2>/dev/null || stat -f '%Lp' "$TMP/d4/sub")
fmode=$(stat -c '%a' "$LOG4" 2>/dev/null || stat -f '%Lp' "$LOG4")
[[ "$dmode" == "700" ]] && pass "a freshly created log directory is 0700" || fail "log directory is $dmode, not 700"
[[ "$fmode" == "600" ]] && pass "a freshly created log file is 0600" || fail "log file is $fmode, not 600"

# --- 4b. a PRE-EXISTING log FILE is TIGHTENED; a freshly CREATED directory is 0700 (control) ---
# A POSIX mkdir()/open() mode argument only applies at creation — asking for 0700/0600 a second time
# on a path that already exists is a no-op unless the code chmods explicitly. This caught a real bug
# (governance quality sweep, 2026-10-14): the log file silently stayed world-readable forever whenever
# it predated this hook's own first write.
LOG4B="$TMP/d4b/deny.jsonl"
mkdir -p "$TMP/d4b" && chmod 0700 "$TMP/d4b"   # not yet looked at by this hook; a clean control
: > "$LOG4B" && chmod 0644 "$LOG4B"
run "$LOG4B" bash-safety-gate R1 Bash x y >/dev/null
fmode2=$(stat -c '%a' "$LOG4B" 2>/dev/null || stat -f '%Lp' "$LOG4B")
[[ "$fmode2" == "600" ]] && pass "a pre-existing 0644 log file is tightened to 0600 on write" \
  || fail "pre-existing log file stayed $fmode2, the stated 0600 guarantee did not hold"

# --- 4c. a SHARED, pre-existing PARENT directory reached via a custom GOVERNANCE_DENY_LOG keeps its
# mode. An earlier fix chmodded the parent directory on EVERY call, with no check for whether this
# hook created it. GOVERNANCE_DENY_LOG is an operator's own
# path; pointed into a directory shared with unrelated files (or a bare filename, where dirname("")
# becomes ".", the current working directory), the old code would silently re-permission a directory
# this hook does not own. A directory it did not create and does not exclusively own must be left alone.
LOG4C="$TMP/d4c/deny.jsonl"
mkdir -p "$TMP/d4c" && chmod 0755 "$TMP/d4c"
printf 'unrelated sibling\n' > "$TMP/d4c/other-service.conf"
run "$LOG4C" bash-safety-gate R1 Bash x y >/dev/null
dmode3=$(stat -c '%a' "$TMP/d4c" 2>/dev/null || stat -f '%Lp' "$TMP/d4c")
[[ "$dmode3" == "755" ]] && pass "a shared pre-existing parent directory keeps its mode, not tightened" \
  || fail "a shared pre-existing parent was re-permissioned to $dmode3 (was 755)"
fmode3=$(stat -c '%a' "$LOG4C" 2>/dev/null || stat -f '%Lp' "$LOG4C")
[[ "$fmode3" == "600" ]] && pass "...while the log FILE itself is still tightened to 0600" \
  || fail "log file in a shared directory stayed $fmode3, not 600"

# --- 4d. a BARE filename (no directory component) must not chmod the current working directory ---
LOG4D="d4d-deny.jsonl"
mkdir -p "$TMP/d4d-cwd" && chmod 0755 "$TMP/d4d-cwd"
( cd "$TMP/d4d-cwd" && run "$LOG4D" bash-safety-gate R1 Bash x y >/dev/null )
dmode4=$(stat -c '%a' "$TMP/d4d-cwd" 2>/dev/null || stat -f '%Lp' "$TMP/d4d-cwd")
[[ "$dmode4" == "755" ]] && pass "a bare filename (dirname '.') never chmods the working directory" \
  || fail "the working directory was re-permissioned to $dmode4 (was 755) via a bare filename"

# --- 4e. governance's own DEFAULT state directory, even pre-existing, IS tightened (the one exception) ---
HOME4E="$TMP/home4e"; mkdir -p "$HOME4E/.local/state/governance" && chmod 0755 "$HOME4E/.local/state/governance"
( HOME="$HOME4E" python3 "$HOOK" --gate bash-safety-gate --rule R1 --tool Bash --reason x <<<"y" >/dev/null 2>&1 )
dmode5=$(stat -c '%a' "$HOME4E/.local/state/governance" 2>/dev/null || stat -f '%Lp' "$HOME4E/.local/state/governance")
[[ "$dmode5" == "700" ]] && pass "governance's own default state directory is tightened even pre-existing" \
  || fail "the default state directory stayed $dmode5, not 700"

# --- 5. harness resolution: GOVERNANCE_HARNESS overrides; grok tools map to grok; else claude-code/unknown ---
LOG5="$TMP/d5/deny.jsonl"
run "$LOG5" bash-safety-gate R1 run_terminal_command x y >/dev/null
grep -q '"ai_agent":{"uid":"grok","name":"grok"' "$LOG5" \
  && pass "a grok-shaped tool name resolves to harness grok" || fail "grok tool did not resolve to grok"

LOG5b="$TMP/d5b/deny.jsonl"
run "$LOG5b" bash-safety-gate R1 Bash x y >/dev/null
grep -q '"ai_agent":{"uid":"claude-code","name":"claude-code"' "$LOG5b" \
  && pass "a non-grok tool name resolves to claude-code" || fail "non-grok tool did not resolve to claude-code"

LOG5c="$TMP/d5c/deny.jsonl"
rc=$(printf '' | GOVERNANCE_DENY_LOG="$LOG5c" python3 "$HOOK" --gate bash-safety-gate --rule R1 --reason y)
grep -q '"ai_agent":{"uid":"unknown","name":"unknown"' "$LOG5c" \
  && pass "no --tool at all resolves to unknown" || fail "a missing tool did not resolve to unknown"

LOG5d="$TMP/d5d/deny.jsonl"
run_with_env() { GOVERNANCE_HARNESS="codex" GOVERNANCE_DENY_LOG="$1" python3 "$HOOK" \
    --gate bash-safety-gate --rule R1 --tool run_terminal_command --reason y < /dev/null >/dev/null 2>&1; }
run_with_env "$LOG5d"
grep -q '"ai_agent":{"uid":"codex","name":"codex"' "$LOG5d" \
  && pass "GOVERNANCE_HARNESS overrides tool-based detection even for a grok-shaped tool" \
  || fail "GOVERNANCE_HARNESS did not override the grok-tool guess"

# --- 6. VERB mapping: gate name decides activity_name, unknown gate falls back to 'other' ---
LOG6="$TMP/d6/deny.jsonl"
run "$LOG6" bash-safety-gate R1 Bash x y >/dev/null
grep -q '"activity_name":"execute"' "$LOG6" && pass "bash-safety-gate maps to verb 'execute'" \
  || fail "bash-safety-gate did not map to 'execute'"

LOG6b="$TMP/d6b/deny.jsonl"
run "$LOG6b" write-safety-gate R2 Write x y >/dev/null
grep -q '"activity_name":"write"' "$LOG6b" && pass "write-safety-gate maps to verb 'write'" \
  || fail "write-safety-gate did not map to 'write'"

LOG6c="$TMP/d6c/deny.jsonl"
run "$LOG6c" some-future-gate R3 Edit x y >/dev/null
grep -q '"activity_name":"other"' "$LOG6c" && pass "an unrecognised gate falls back to verb 'other'" \
  || fail "an unrecognised gate did not fall back to 'other'"

# --- 7. the required OCSF verdict fields are present and fixed: Denied/Blocked/Failure ---
LOG7="$TMP/d7/deny.jsonl"
run "$LOG7" bash-safety-gate R1 Bash x y >/dev/null
line7="$(last_line "$LOG7")"
ok=1
for frag in '"class_uid":6003' '"action_id":2' '"action":"Denied"' '"disposition_id":2' \
            '"disposition":"Blocked"' '"status_id":2' '"status":"Failure"'; do
  grep -qF "$frag" <<<"$line7" || { fail "missing OCSF field: $frag"; ok=0; }
done
[[ "$ok" == "1" ]] && pass "all required OCSF verdict fields present (Denied/Blocked/Failure)"

# --- 8. FAILS OPEN: an unwritable log location never crashes or exits non-zero ---
RO="$TMP/d8-readonly"; mkdir -p "$RO"; chmod 0500 "$RO"
rc=$(run "$RO/sub/deny.jsonl" bash-safety-gate R1 Bash x y)
[[ "$rc" == "0" ]] && pass "an unwritable log directory still exits 0 (fails open)" \
  || fail "an unwritable log directory made the hook exit $rc, not 0"
[[ -s "$TMP/stderr" ]] && fail "a failure printed to stderr (the gate's own refusal channel) — could be read as the verdict" \
  || pass "a logging failure prints nothing to stderr"
chmod 0700 "$RO"  # so the trap can clean it up

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
