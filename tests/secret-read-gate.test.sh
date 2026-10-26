#!/usr/bin/env bash
# secret-read-gate.test.sh — bash-safety-gate's secret-file check, matched per SUB-COMMAND.
#
# The check ran one regex over the whole command, so `.*` spanned `&&`, `;` and `|`: a reader verb in
# one command and a name merely CONTAINING ".env" in another (`grep -q x a.json && cp
# sample.environment.ts b`) was blocked, several times a session in one lane. An over-broad floor gate
# is one the next person deletes. The fix narrows the MATCH UNIT; a later one gave the name a RIGHT
# BOUNDARY (`.environment` is not `.env`) and removes heredoc BODIES given to cat/tee (prose naming the
# file reads nothing). This suite proves both halves on the channel the harness uses (PreToolUse JSON on
# stdin): every real read stays BLOCKED, including every way a removed body could hide one, and the
# false positives are ALLOWED.
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
#
# ⚠️ #301 dropped the fixed READER-VERB list (`cat`/`grep`/`rg`/`head`/`tail`/`less`/`more`): `sed -n p`,
# `awk 1`, `cp` and `xxd` all read or relocated the file unrefused, and the verb list was itself
# case-SENSITIVE on filesystems where the NAME is matched case-insensitively (`CAT .env`). The match is
# now the bare NAME, any verb — which means a sub-command naming only a TEMPLATE (`.env.example`,
# `.env.sample`, `.env.template`) must be positively exempted, or every `ls .env.example` would also
# block. That exemption is stripped from a COPY used only to test the match, never from the real
# command text, so a sub-command naming a template ALONGSIDE a real secret name still matches on the
# real name. Three cases below changed FROM an "allowed only because two sub-commands got conflated"
# false positive TO an unconditional BLOCK, because under the new bare-name match the secret-bearing
# sub-command no longer needs a reader verb to match at all.
#
# ⚠️ governance#335: a shell removes an UNQUOTED backslash before an ordinary character, and adjacent
# quoted/unquoted word fragments concatenate — so `cat .\env`, `cat .e\nv`, `cat '.e'nv`, `cat ".en"v`
# and `cat $'\x2eenv'` all run as `cat .env`, and every one of them matched nothing (ALLOWED) before
# the normalisation in bash-safety-gate.sh / hooks/lib/shell_normalize.py. Drop that call and every
# PYBLOCK row below fails — that IS the mutant test. The plain backslash cases need no python3 (a sed
# pass alone resolves them); quote concatenation and `$'...'` do, so PYBLOCK is BLOCK only where
# python3 is present and a documented ALLOW (gap, not a silent one) on the jq-only leg.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # the gates now write a deny trail: never the real one
. "$ROOT/tests/lib/legs.sh"
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }

# shim_path <label> <tool>...: a PATH of exec wrappers without the named tools (tests/lib/shim-path.sh).
. "$ROOT/tests/lib/shim-path.sh"

# The cases live in python so a command can hold a literal newline, quote or backslash exactly as the
# harness would deliver it. Columns: expectation · command. E is the secret-file shape.
python3 - "$TMP/cases.jsonl" <<'PY'
import json, sys
E = "." + "env"
BLOCK, ALLOW, FP = "BLOCK", "ALLOW", "FP"   # FP: ALLOW with python3, BLOCK (fail closed) without
PYBLOCK = "PYBLOCK"                         # BLOCK with python3, ALLOW (documented gap) without
cases = [
    # governance#335: backslash escapes and quote concatenation reach the same file as a plain `.env`.
    (BLOCK, "cat ." + "\\env"),              # a sed pass alone resolves a bare backslash: no python3 needed
    (BLOCK, "cat .e" + "\\nv"),
    (PYBLOCK, "cat '.e'nv"),                 # quote concatenation needs the python3 pass
    (PYBLOCK, 'cat ".en"v'),
    (PYBLOCK, "cat $'\\x2e" + "env'"),       # $'...' ANSI-C hex escape
    (ALLOW, "cat README.md"), (ALLOW, "printf 'a\\nb'"),
    # real reads — must stay blocked
    (BLOCK, f"grep KEY {E}"), (BLOCK, f"cat {E} | head"), (BLOCK, f"head {E} && echo ok"),
    (BLOCK, f"tail -n 5 {E}.local"), (BLOCK, f"cd app && grep -r KEY {E}.production"),
    (BLOCK, f"rg TOKEN {E}"), (BLOCK, f"less {E}"), (BLOCK, f"echo start; head -3 {E}"),
    (BLOCK, f"true || cat {E}"), (BLOCK, f"grep KEY < {E}"), (BLOCK, f"grep KEY $(echo {E})"),
    (BLOCK, f"grep KEY {E} &"), (BLOCK, f"ls |& grep KEY {E}"),
    # #301: verbs the old fixed list never named, each measured allowed before this fix —
    # content-dumping (sed/awk/xxd), and a relocation (cp) that stages the same bytes under an
    # allowed-looking name for a later, unrefused read
    (BLOCK, f"sed -n p {E}"), (BLOCK, f"awk 1 {E}"), (BLOCK, f"cp {E} notes.txt"), (BLOCK, f"xxd {E}"),
    # #301: the old verb list was case-SENSITIVE on filesystems where the NAME is matched
    # case-insensitively — `CAT` (uppercase) is the same /bin/cat on one of those
    (BLOCK, f"CAT {E}"),
    # #301: naming the file with NO verb at all — the bare name is now the floor
    (BLOCK, f"{E}"), (BLOCK, f"echo {E}"),
    # #301: a template ALONE, any verb — must stay allowed now that the verb list is gone. FP, not
    # ALLOW: removing the template name needs python3, so without it the gate fails closed (BLOCK).
    (FP, f"cat {E}.example"), (FP, f"sed -n p {E}.sample"), (FP, f"cp {E}.template notes.txt"),
    (FP, f"ls -la {E.upper()}.EXAMPLE"),
    # ... but only a WHOLE template name: a template prefix followed by more name is a real file, and
    # the write gate refuses the same names (one shared list, hooks/secret-names.sh)
    (BLOCK, f"cat {E}.example.local"), (BLOCK, f"cat {E}.template.prod"), (BLOCK, f"cat {E}.sample2"),
    (BLOCK, f"cat app/{E}rc.local"),
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
    # cross-sub-command false positives: a reader in one command, a secret-shaped NAME in another that
    # does not read it. These still match the whole-string pattern, so they need the per-sub-command check.
    (FP, f"head -5 README.md && ls -la {E}.example"),
    # #301 dropped the reader-verb list: a sub-command naming a secret-bearing file AT ALL is now the
    # floor, whatever reads or moves it — so these three are no longer cross-sub-command artifacts: the
    # SAME sub-command names a real (non-template) secret, and must BLOCK unconditionally, with or
    # without python3. `cp .env.example .env.local` is template-exempt on its SOURCE, but `.env.local` is
    # the real name on its OWN; `test -f .env` and `cp .env.example .env` both name the bare file.
    (BLOCK, f"git worktree add ../wt && grep -q foo package.json && cp {E}.example {E}.local"),
    (BLOCK, f"tail -1 log.txt; test -f {E}"),
    (BLOCK, f"head -5 README.md\ncp {E}.example {E}"),
    # RIGHT BOUNDARY: the name still matches with a non-letter after it, `rc`, or the end ...
    (BLOCK, f"cat {E}"), (BLOCK, f"head -1 app/{E}rc"), (BLOCK, f'cat "$D/{E}"'),
    (BLOCK, f"tail {E}_x"), (BLOCK, f"more {E}2"), (BLOCK, f"grep KEY {E}-staging"),
    # CASE (#271): Windows and default macOS filesystems are case-insensitive, so these open the file
    (BLOCK, f"cat {E.upper()}"), (BLOCK, "cat .Env"), (BLOCK, "grep KEY app/.eNv.local"),
    (BLOCK, f"head -1 {E.upper()}RC"), (BLOCK, "tail .Env.Production"), (BLOCK, f"cat {E}RC"),
    (BLOCK, f"docker exec app od -c /srv/{E.upper()}"),   # the container-secret-read rule's name, too
    # ... and a longer word that merely STARTS with the letters is not the file. The whole-string pattern
    # no longer matches, so these are allowed on every leg, python3 or not.
    (ALLOW, "git worktree add ../wt && grep -q foo package.json && cp src/sample.environment.ts src/environment.ts"),
    (ALLOW, "head -5 README.md && ls src/sample.environment.ts"),
    (ALLOW, "tail -1 log.txt; cp sample.environment.ts environment.ts"),
    (ALLOW, "grep -c x a.txt | wc -l && test -f src/sample.environment.ts"),
    (ALLOW, f"grep -n properties{E}ironment config.py"), (ALLOW, f"cat src/sample{E}ironment.ts"),
    (ALLOW, f"head -3 proxy/{E}oy"),
    (ALLOW, "cat src/Sample.Environment.ts"), (ALLOW, "head -3 proxy/.ENVOY.yaml"),  # boundary holds in any case
    # A heredoc BODY given to cat/tee is data. Removing it needs python3, so these fail closed without it.
    # The first is the shape that lost a hand-off: prose with an apostrophe and a parenthesis.
    (FP, "cat <<EOF > notes.md\nremember the " + E + " file\nEOF"),
    (FP, "cat >> notes.md <<'EOF'\nthe checkout's " + E + " file is absent (see the log)\nEOF"),
    (FP, "cd notes && tee -a handoff.md <<'EOF'\nthen cat the " + E + " to check `x`\nEOF"),
    (FP, 'cat > f <<"EOF"\nquoted with "double" delimiter, ' + E + " (named)\nEOF"),
    (FP, "cat > f <<EOF\nunquoted, no substitution: grep KEY " + E + " (prose)\nEOF"),
    (FP, "cat <<-'EOF' > f\n\tindented " + E + " (prose)\n\tEOF"),
    # ... and every way removing a body could OPEN a read stays blocked
    (BLOCK, "cat > f <<EOF\n$(cat " + E + ")\nEOF"),        # unquoted: $( ) runs while the body is built
    (BLOCK, "cat > f <<EOF\n`head " + E + "`\nEOF"),        # unquoted: so does a backtick
    (BLOCK, "bash <<'EOF'\ncat " + E + "\nEOF"),             # an interpreter EXECUTES its body
    (BLOCK, "sh -s <<'EOF'\nhead -3 " + E + "\nEOF"),
    (BLOCK, "cat " + E + " - > out <<'EOF'\nx\nEOF"),        # the reader is on the command line
    (BLOCK, "cat > f <<'EOF'\nx\nEOF\ncat " + E),             # a read AFTER the heredoc
    (BLOCK, "cat > f <<'EOF'\ncat " + E),                     # unterminated: nothing is removed
    (BLOCK, "cat > f <<'EOF'\nx\nEOF2\ncat " + E),            # the terminator must match exactly
    (BLOCK, "cat <<'A' <<'B'\n" + E + "\nA\ncat " + E + "\nB"),  # two heredocs on a line: nothing removed
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
    # The mirror: without python3 the normalisation that SURFACES these as a match cannot run either,
    # so there is nothing for the sub-command check to fail closed ON — a documented gap, not a crash.
    elif want == "PYBLOCK":
        want = "ALLOW" if mode == "failclosed" else "BLOCK"
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
  # A leg that did not run is NOT RUN and fails the suite: a green result must not hide it.
  leg_not_run "parser: jq only" "this host has no jq, so the fail-closed leg is unchecked"
fi

echo
echo "  $pass passed, $fail failed"
legs_verdict "$fail"
