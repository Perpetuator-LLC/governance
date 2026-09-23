#!/usr/bin/env bash
# secret-read-gate.test.sh — bash-safety-gate's secret-file check, matched per SUB-COMMAND.
#
# The check ran one regex over the whole command, so `.*` spanned `&&`, `;` and `|`: a reader verb in
# one command and a name merely CONTAINING ".env" in another (`grep -q x a.json && cp
# sample.environment.ts b`) was blocked, several times a session in one lane. An over-broad floor gate
# is one the next person deletes. The fix narrows the MATCH UNIT, never the pattern — so this suite
# proves both halves on the channel the harness uses (PreToolUse JSON on stdin): every real read stays
# BLOCKED, and the cross-chain false positives are ALLOWED.
#
# ⚠️ Most rows below are ways a naive split would WIDEN the gate. Each was either found by probing or
# is the obvious next attempt: a separator inside quotes, inside `$(…)`/backticks/subshells/groups,
# escaped, or a quoted NEWLINE (which posix-mode tokenising returns as a bare separator — the first
# version of this fix allowed `grep ";" .env` for exactly that reason, and this suite caught it).
#
# ⚠️ And it closes a hole the OLD gate had: `grep -E` matched line by line, so a newline between the
# reader and the file name — `cat "<newline>" .env`, or a backslash-continued line — hid the read.
#
# Run under three PATHs: the host's, one without jq (python3 parser), one without python3 (jq only).
# Without python3 the per-sub-command check cannot run, so the gate must FAIL CLOSED: the false
# positives stay blocked there, and that is asserted, not assumed.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }

# A PATH holding every command on the current PATH except the named ones (as hook-input.test.sh).
shim_path() {
  local dir="$TMP/path-$1"; shift
  mkdir -p "$dir"
  local d f n x skip
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"; skip=0
      for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
      [ "$skip" = 1 ] || [ -e "$dir/$n" ] || ln -s "$f" "$dir/$n" 2>/dev/null
    done
  done
  if [ -L "$dir/python3" ]; then ln -sf "$(python3 -c 'import sys; print(sys.executable)')" "$dir/python3"; fi
  printf '%s' "$dir"
}

# The cases live in python so a command can hold a literal newline, quote or backslash exactly as the
# harness would deliver it. Columns: expectation · command. E is the secret-file shape.
python3 - "$TMP/cases.jsonl" <<'PY'
import json, sys
E = "." + "env"
BLOCK, ALLOW, FP = "BLOCK", "ALLOW", "FP"   # FP: ALLOW with python3, BLOCK (fail closed) without
cases = [
    # real reads — must stay blocked
    (BLOCK, f"grep KEY {E}"), (BLOCK, f"cat {E} | head"), (BLOCK, f"head {E} && echo ok"),
    (BLOCK, f"tail -n 5 {E}.local"), (BLOCK, f"cd app && grep -r KEY {E}.production"),
    (BLOCK, f"rg TOKEN {E}"), (BLOCK, f"less {E}"), (BLOCK, f"echo start; head -3 {E}"),
    (BLOCK, f"true || cat {E}"), (BLOCK, f"grep KEY < {E}"), (BLOCK, f"grep KEY $(echo {E})"),
    (BLOCK, f"grep KEY {E} &"), (BLOCK, f"ls |& grep KEY {E}"),
    # a separator INSIDE quotes is part of a word
    (BLOCK, f'grep "a && b" {E}'), (BLOCK, f"grep 'x; y' {E}"), (BLOCK, f'grep ";" {E}'),
    (BLOCK, f'grep "&&" {E}'), (BLOCK, f"grep '|' {E}"), (BLOCK, f"grep $';' {E}"),
    # nesting and escaping — the tokeniser cannot see into these, so they must fail closed
    (BLOCK, f"head $(echo x; echo {E})"), (BLOCK, f"head `echo x; echo {E}`"),
    (BLOCK, f"(echo x; head -3 {E})"), (BLOCK, "{ head -1; } < " + E),
    (BLOCK, "find . -exec head -1 {} \\; -name '*" + E + "'"), (BLOCK, f"head -1 <(cat {E})"),
    (BLOCK, f'grep "unbalanced {E}'),
    # newlines: a QUOTED one is inside a word; a backslash-newline continues ONE command
    (BLOCK, f'grep "KEY\n" {E}'), (BLOCK, f'cat "\n" {E}'), (BLOCK, f"echo hi\ncat {E}"),
    (BLOCK, f"head -2 \\\n  {E}"),
    # the false positives this change exists for
    (FP, "git worktree add ../wt && grep -q foo package.json && cp src/sample.environment.ts src/environment.ts"),
    (FP, "head -5 README.md && ls src/sample.environment.ts"),
    (FP, "tail -1 log.txt; cp sample.environment.ts environment.ts"),
    (FP, "grep -c x a.txt | wc -l && test -f src/sample.environment.ts"),
    (FP, "head -5 README.md\ncp src/sample.environment.ts src/environment.ts"),
    (FP, "cat <<EOF > notes.md\nremember the " + E + " file\nEOF"),
    # controls
    (ALLOW, "ls -la"), (ALLOW, "git status"),
]
with open(sys.argv[1], "w") as fh:
    for expect, cmd in cases:
        fh.write(json.dumps({"expect": expect, "cmd": cmd,
                             "payload": {"session_id": "s", "transcript_path": "t", "cwd": "/tmp",
                                         "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                         "tool_input": {"command": cmd, "description": "d"}}}) + "\n")
PY

# One driver process per leg: it pipes each payload into the gate under the leg's PATH. (The first
# version parsed every case with three python spawns in bash and took ~2 minutes.) The DRIVER runs on
# the host's python3; only the GATE sees the restricted PATH, which is the thing under test.
run_matrix() {  # run_matrix <label> <PATH> <mode: full|failclosed>
  local out
  out="$(python3 - "$GATE" "$1" "$2" "$3" "$TMP/cases.jsonl" <<'PY'
import json, os, subprocess, sys
gate, label, path, mode, cases = sys.argv[1:6]
env = {k: v for k, v in os.environ.items() if k != "CLAUDE_TOOL_INPUT"}
env["PATH"] = path
for line in open(cases):
    c = json.loads(line)
    want = c["expect"]
    # Without python3 the sub-command check cannot run: every whole-string match must stay BLOCKED.
    if want == "FP":
        want = "BLOCK" if mode == "failclosed" else "ALLOW"
    r = subprocess.run(["bash", gate], input=json.dumps(c["payload"]), env=env,
                       capture_output=True, text=True)
    got = {2: "BLOCK", 0: "ALLOW"}.get(r.returncode, f"EXIT{r.returncode}")
    cmd = repr(c["cmd"])
    if got != want:
        print(f"BAD\t[{label}] expected {want}, got {got}: {cmd}")
    elif got == "BLOCK" and "BLOCKED" not in r.stderr:
        print(f"BAD\t[{label}] {cmd} blocked WITHOUT a reason on stderr (the channel returned to the model)")
    else:
        print(f"OK\t[{label}] {want}  {cmd}")
PY
)"
  local verdict msg
  while IFS=$'\t' read -r verdict msg; do
    if [ "$verdict" = OK ]; then ok "$msg"; else bad "$msg"; fi
  done <<<"$out"
}

NOJQ="$(shim_path nojq jq)"
NOPY="$(shim_path nopy python3)"

echo "secret-read gate — per sub-command, on the harness's stdin channel"
echo " ── parser: host";  run_matrix host "$PATH" full
echo " ── parser: no jq (python3 fallback)";  run_matrix nojq "$NOJQ" full
if PATH="$NOPY" command -v jq >/dev/null 2>&1; then
  echo " ── parser: jq only (no python3) — the sub-command check cannot run, so it must fail CLOSED"
  run_matrix nopy "$NOPY" failclosed
else
  echo " ── parser: jq only — SKIPPED, this host has no jq (the leg is not checked, not passed)"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
