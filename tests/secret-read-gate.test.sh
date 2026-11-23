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

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # the gates now write a deny trail: never the real one
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
    # cross-sub-command false positives: a reader in one command, a secret-shaped NAME in another that
    # does not read it. These still match the whole-string pattern, so they need the per-sub-command check.
    (FP, f"git worktree add ../wt && grep -q foo package.json && cp {E}.example {E}.local"),
    (FP, f"head -5 README.md && ls -la {E}.example"),
    (FP, f"tail -1 log.txt; test -f {E}"),
    (FP, f"head -5 README.md\ncp {E}.example {E}"),
    # RIGHT BOUNDARY: the name still matches with a non-letter after it, `rc`, or the end ...
    (BLOCK, f"cat {E}"), (BLOCK, f"head -1 app/{E}rc"), (BLOCK, f'cat "$D/{E}"'),
    (BLOCK, f"tail {E}_x"), (BLOCK, f"more {E}2"), (BLOCK, f"grep KEY {E}-staging"),
    # ... and a longer word that merely STARTS with the letters is not the file. The whole-string pattern
    # no longer matches, so these are allowed on every leg, python3 or not.
    (ALLOW, "git worktree add ../wt && grep -q foo package.json && cp src/sample.environment.ts src/environment.ts"),
    (ALLOW, "head -5 README.md && ls src/sample.environment.ts"),
    (ALLOW, "tail -1 log.txt; cp sample.environment.ts environment.ts"),
    (ALLOW, "grep -c x a.txt | wc -l && test -f src/sample.environment.ts"),
    (ALLOW, f"grep -n properties{E}ironment config.py"), (ALLOW, f"cat src/sample{E}ironment.ts"),
    (ALLOW, f"head -3 proxy/{E}oy"),
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
    # governance#335: a shell backslash/quote/ANSI-C escape all produce the same final word a reader
    # receives (`.\env` / `.e\nv` / `'.e'nv` / `".en"v` / `$'\x2eenv'` all run as `.env`), which a
    # regex over the RAW text never sees past. Plain BLOCK now, not mode-dependent: cisa's SEND-BACK on
    # PR #436 (c189146 item 6) closed the "allowed without python3" gap a first version of this fix
    # had — the no-python3 fallback below now refuses a reader verb next to any of these markers too,
    # so these five BLOCK on every leg this suite can actually exercise (host and nojq both HAVE
    # python3; only "nopy" lacks it, and that leg is skipped outright on a host with no jq either, same
    # as every other nopy-only assertion in this file).
    (BLOCK, "cat .\\" + "env"), (BLOCK, "cat .e\\nv"), (BLOCK, "cat '.e'nv"), (BLOCK, 'cat ".en"v'),
    (BLOCK, "cat $'\\x2e" + "env'"),
    (ALLOW, "cat README.md"), (ALLOW, "printf 'a\\nb'"),
    # cisa SEND-BACK on PR #436 (c189146 item 1): octal and \u/\U ANSI-C escapes were not decoded.
    (BLOCK, "cat $'\\056" + "env'"), (BLOCK, "cat $'\\u002e" + "env'"),
    # item 1: shlex treated a bare, mid-word "#" as a comment and dropped the rest of the LINE — not
    # just the rest of the word. A "#" sitting earlier in the SAME command silently deleted a later,
    # genuinely escaped .env reference from the decoded text entirely.
    (BLOCK, "echo re#view: cat .\\" + "env"),
    # item 1: a heredoc body that is EXECUTED (not data — strip_data_heredocs leaves it alone), holding
    # an unbalanced-looking apostrophe, used to make decode_shell_words raise and the leg then silently
    # ALLOW. It now fails CLOSED on an undecodable command instead.
    (BLOCK, "bash <<'EOF'\necho it's broken; cat .\\" + "env\nEOF"),
    # item 1: a quoted separator (";", "&&") decoded to a BARE one, so only_across_subcommands's own
    # re-tokenising of the decoded text split there and allowed. Fixed by re-quoting with shlex.join.
    (BLOCK, 'grep ";" .\\' + "env"), (BLOCK, 'grep "&&" .\\' + "env"),
    # control: the cross-subcommand false positive this decode leg must NOT reintroduce — a command
    # with no backslash/quote at all never reaches decode_shell_words in the first place.
    (ALLOW, "head -5 README.md && ls -la " + E + ".example"),
    # governance#335: well-known credential-STORE paths, not just the .env NAME shape, on the SAME
    # reader verbs. A credential-adjacent path that merely shares a short substring (no reader verb
    # directly on a real credential path) stays allowed.
    (BLOCK, "cat ~/.aws/credentials"), (BLOCK, "less ~/.netrc"), (BLOCK, "cat ~/.ssh/id_ed25519"),
    (BLOCK, "head ~/.ssh/deploy_key"), (BLOCK, "cat ~/.docker/config.json"),
    (BLOCK, "cat ~/.kube/config"), (BLOCK, "cat ~/.config/gh/hosts.yml"),
    (BLOCK, "cat ~/.git-credentials"), (BLOCK, "cat ~/.pgpass"),
    (ALLOW, "cat README.aws.md"), (ALLOW, "cat notes/kube-config-migration.md"),
    # cisa SEND-BACK on PR #436 (c189146 item 2): credential-paths.sh's own docstring already promised
    # case-insensitive matching; the read gate's grep had no -i, so an upper-cased spelling read clean
    # on a case-insensitive filesystem.
    (BLOCK, "cat ~/.AWS/CREDENTIALS"), (BLOCK, "cat ~/.Netrc"),
    # item 3: CREDENTIAL_PATH_RX's un-grouped alternation bound a reader verb to only its FIRST
    # alternative; every OTHER path fragment was an ungated top-level match, refusing ordinary,
    # non-reading uses that merely mention one. Grouping fixes both directions at once.
    (ALLOW, "ssh -i ~/.ssh/id_ed25519 host"), (ALLOW, "ssh-keygen -lf ~/.ssh/id_ed25519.pub"),
    (ALLOW, "kubectl --kubeconfig ~/.kube/config get pods"),
    # coa SEND-BACK on PR #436 (c189240 item 1): a public key is not a credential, and main allows
    # reading or installing one. The id_* fragment's \b bound still sat right after the id, so it
    # matched the private-key prefix of a .pub name too — THIS time with the reader verb (cat) that
    # the ssh-keygen/ssh -i rows above never exercised, since neither is on the verb list.
    (ALLOW, "cat ~/.ssh/id_ed25519.pub"), (ALLOW, "cat ~/.ssh/id_rsa.pub >> authorized_keys"),
    (BLOCK, "cat ~/.ssh/id_ed25519_backup"),
    # coa item 2: the case-insensitivity fix (item 2 above) was verified only on the simpler
    # alternatives; these two rows pin it on the id_* fragment specifically, since that's the one
    # whose pattern just changed again for the .pub exclusion.
    (BLOCK, "cat ~/.AWS/credentials"), (BLOCK, "cat ~/.SSH/ID_ED25519"),
    # item 4: a doubled path separator is the same file to the shell (it collapses repeated slashes).
    (BLOCK, "cat ~/.aws//credentials"),
    # item 5: sed/awk/base64 all dump a file's content given its path, same as cat; added to the verb
    # list. python3 -c "open(...)" and an arbitrary interpreter reading its own argv are NOT closed by
    # this — recorded as an accepted limit (c189146 item 5): a regex over reader VERBS cannot see into
    # arbitrary code.
    (BLOCK, f"sed -n p {E}"), (BLOCK, f"awk 1 {E}"), (BLOCK, f"base64 {E}"),
    # controls
    (ALLOW, "ls -la"), (ALLOW, "git status"),
    # item 3's own mirror control: "ls" was never on the reader-verb list (listing a file's metadata is
    # not reading its content) — this is the ONE case from cisa's own report that is NOT a bug to close,
    # named here so the grouping fix above is never mistaken for "ls should now refuse too".
    (ALLOW, "ls ~/.aws/credentials"),
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
