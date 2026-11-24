#!/usr/bin/env bash
# tests/git-credential-helper-gate.test.sh — bash-safety-gate's floor-backstop checks for an agent
# riding the operator's own git credential helper: Apple's system gitconfig sets
# credential.helper=osxkeychain, so an agent's own
# `git ls-remote https://<forge>` made macOS ask the OPERATOR to unlock their login keychain for a
# credential the agent's call never needed. The primary fix is settings/claude.json's own `env` block
# (every session starts with the helper reset to empty and GIT_TERMINAL_PROMPT=0); these three checks
# are the backstop for a session that mitigation never reached, or a direct attempt to work around it:
#   1. RE-ENABLING the helper (credential.helper set to a non-empty value, or the credential subsystem
#      invoked directly).
#   2. STRIPPING the env override before running git (`env -i`, or `env -u` on one of its names).
#   3. A RAW https:// URL to one of the installation's OWN forges -- a host list the adapter provides,
#      never a name this core file carries.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

payload() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")"; }

run() {  # run <command> [<env k=v>...] -> exit code; stderr captured in $TMP/err
  local cmd="$1"; shift
  payload "$cmd" | env "$@" bash "$GATE" >/dev/null 2>"$TMP/err"
}

check_blocked() {  # check_blocked <command> <label> [<env k=v>...]
  local cmd="$1" label="$2"; shift 2
  run "$cmd" "$@"; local rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err" \
    && pass "$label: blocked" || fail "$label: NOT blocked (rc=$rc) — $(cat "$TMP/err")"
}
check_allowed() {  # check_allowed <command> <label> [<env k=v>...]
  local cmd="$1" label="$2"; shift 2
  run "$cmd" "$@"; local rc=$?
  [[ "$rc" == "0" ]] && pass "$label: allowed" || fail "$label: blocked (should be allowed) — $(cat "$TMP/err")"
}


mutant() {  # mutant <label> <old> <new> <command>...
  # With <old> replaced by <new> in a copy of the gate, every <command> (each one refused by the real
  # gate in a row above) must be ALLOWED. That proves those rows are what catches the loss. A mutation
  # whose <old> text is gone fails loudly: the gate changed, so re-aim the mutant, never drop it.
  local label="$1" old="$2" new="$3" real="$GATE" c bad=0; shift 3
  if ! python3 - "$GATE" "$TMP/mutant-gate.sh" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new))
PY
  then fail "mutant not built: $label (the gate text it edits is gone; re-aim it)"; return; fi
  GATE="$TMP/mutant-gate.sh"
  for c in "$@"; do
    run "$c"; [[ $? == 0 ]] || { bad=$((bad + 1)); printf '        still refused under the mutant: %s\n' "$c"; }
  done
  GATE="$real"
  [[ $bad == 0 ]] && pass "mutant killed: $label ($# rows go red)" || fail "mutant survived: $label ($bad of $# rows)"
}

echo "── git-credential-helper-gate: refuse RE-ENABLING the helper, or invoking it directly"

check_blocked 'git config credential.helper osxkeychain' "git config credential.helper <value>"
check_blocked 'git config --global credential.helper store' "git config --global credential.helper <value>"
check_blocked 'git -c credential.helper=osxkeychain clone https://example.com/x' "-c credential.helper=<value>"
check_blocked 'git credential fill' "git credential fill"
check_blocked 'git credential approve' "git credential approve"
check_blocked 'git credential reject' "git credential reject"
check_blocked 'git-credential-osxkeychain get' "a helper binary invoked by its own name"
check_blocked 'git credential-manager get' "git credential-<name> (manager)"

echo " · the safe direction: unsetting, or setting to empty, stays allowed"
check_allowed 'git config --unset credential.helper' "git config --unset credential.helper"
check_allowed 'git config --global --unset-all credential.helper' "git config --global --unset-all credential.helper"
check_allowed 'git -c credential.helper= clone https://example.com/x' "-c credential.helper=<empty>"
check_allowed 'git config credential.helper' "a bare read (git config credential.helper, no value)"

echo " · a helper scoped to one URL or host, and a key spelled in capitals (git config keys ignore case)"
U_C='git -c credential.https://forge.example.helper=osxkeychain ls-remote origin'
U_CFG='git config --global credential.forge.example.helper store'
K_H='git -c credential.Helper=osxkeychain ls-remote origin'
K_ALL='git -c CREDENTIAL.HELPER=osxkeychain ls-remote origin'
K_CFG='git config --global Credential.Helper store'
check_blocked "$U_C" "-c credential.<url>.helper=<value>"
check_blocked "$U_CFG" "git config credential.<host>.helper <value>"
check_blocked "$K_H" "-c credential.Helper=<value> (capital H)"
check_blocked "$K_ALL" "-c CREDENTIAL.HELPER=<value>"
check_blocked "$K_CFG" "git config Credential.Helper <value>"
check_blocked 'git config --global Credential.https://forge.example.Helper store' "URL-scoped AND capitalised"
check_allowed 'git config --unset credential.https://forge.example.helper' "unsetting a URL-scoped helper"
check_allowed 'git -c credential.https://forge.example.helper= fetch origin' "a URL-scoped helper set to empty"
check_allowed 'git config credential.Helper' "a bare read of the capitalised key"
check_allowed 'git config credential.https://forge.example.username bot' "another key under the same URL scope"
mutant "the key is matched case-sensitively again" \
  'grep -qiE "$GIT_CRED_HELPER_SET"' 'grep -qE "$GIT_CRED_HELPER_SET"' \
  "$K_H" "$K_ALL" "$K_CFG"
mutant "only the unscoped key credential.helper is matched" \
  'credential(\.[^=[:space:];&|]+)?\.helper(' 'credential\.helper(' \
  "$U_C" "$U_CFG"

echo " · a key written with quotes or a backslash is the same key once the shell has read it"
Q_SQ="git -c 'credential.helper'=osxkeychain fetch origin"
Q_DQ='git -c "credential".helper=osxkeychain fetch origin'
Q_BS='git -c credential.help\er=osxkeychain fetch origin'
check_blocked "$Q_SQ" "-c 'credential.helper'=<value> (single-quoted key)"
check_blocked "$Q_DQ" "-c \"credential\".helper=<value> (half the key double-quoted)"
check_blocked "$Q_BS" "-c credential.help\\er=<value> (a backslash inside the key)"
check_allowed "git -c 'credential.helper'= fetch origin" "a quoted key set to empty stays the safe direction"
mutant "the key checks read the command with its quotes and backslashes left in" \
  'cmd_bare=$(printf '"'"'%s'"'"' "$cmd" | tr -d "\"'"'"'\\\\")' 'cmd_bare=$cmd' \
  "$Q_SQ" "$Q_DQ" "$Q_BS"

echo " · another config file pulled in at command scope (read after the session's own reset)"
I_PATH='git -c include.path=/tmp/x.cfg ls-remote origin'
I_IF='git -c includeIf.gitdir:/.path=/tmp/x.cfg ls-remote origin'
I_CAPS='git -c Include.Path=/tmp/x.cfg fetch origin'
I_ENV='git --config-env=include.path=CFG fetch origin'
I_GLUED='git -cinclude.path=/tmp/x.cfg fetch origin'
check_blocked "$I_PATH" "-c include.path=<file>"
check_blocked "$I_IF" "-c includeIf.<condition>.path=<file>"
check_blocked "$I_CAPS" "-c Include.Path=<file> (keys ignore case)"
check_blocked "$I_ENV" "--config-env=include.path=<VAR>"
check_blocked "$I_GLUED" "-cinclude.path=<file> (glued)"
check_allowed 'git config --get include.path' "a bare read of include.path"
check_allowed 'git -c core.autocrlf=false status' "an unrelated one-off -c setting"
mutant "the include check is removed" \
  'if printf '"'"'%s'"'"' "$cmd_bare" | grep -qiE "$GIT_INCLUDE_KEY"; then' 'if false; then' \
  "$I_PATH" "$I_IF" "$I_CAPS" "$I_ENV" "$I_GLUED"

echo " · GIT_CONFIG_PARAMETERS injects any key at the same scope, with no -c on the line"
P_INC="GIT_CONFIG_PARAMETERS=\"'include.path'='/tmp/x.cfg'\" git fetch origin"
P_EXP='export GIT_CONFIG_PARAMETERS=x; git fetch origin'
P_ENV='env GIT_CONFIG_PARAMETERS=x git fetch origin'
check_blocked "GIT_CONFIG_PARAMETERS=\"'credential.helper'='osxkeychain'\" git ls-remote origin" "GIT_CONFIG_PARAMETERS naming the helper key"
check_blocked "$P_INC" "GIT_CONFIG_PARAMETERS naming an include"
check_blocked "$P_EXP" "export GIT_CONFIG_PARAMETERS"
check_blocked "$P_ENV" "env GIT_CONFIG_PARAMETERS=<value>"
mutant "GIT_CONFIG_PARAMETERS is not one of the guarded names" \
  'GIT_TERMINAL_PROMPT|GIT_CONFIG_PARAMETERS'"'"'' 'GIT_TERMINAL_PROMPT'"'"'' \
  "$P_INC" "$P_EXP" "$P_ENV"

echo " · the helper binary at any path, in any case, and through an alias"
B_FULL='/usr/libexec/git-core/git-credential-osxkeychain get'
B_EXEC='"$(git --exec-path)/git-credential-osxkeychain" get'
B_DOT='./git-credential-store get'
B_CAPS='Git-Credential-Osxkeychain get'
A_BIN='git -c alias.k=credential-osxkeychain k get'
A_SUB="git -c alias.k='credential fill' k"
A_CFG='git config --global alias.k "credential fill"'
check_blocked "$B_FULL" "a helper binary by full path"
check_blocked "$B_EXEC" "a helper binary under \$(git --exec-path)"
check_blocked "$B_DOT" "a helper binary as ./<name>"
check_blocked "$B_CAPS" "a helper binary spelled in capitals"
check_blocked "$A_BIN" "an alias to credential-<name>"
check_blocked "$A_SUB" "an alias to 'credential fill'"
check_blocked "$A_CFG" "an alias written to a config file"
check_allowed 'bash tests/git-credential-helper-gate.test.sh' "running this suite by path (a file name with an extension)"
check_allowed 'git -c alias.st=status st' "an ordinary alias"
check_allowed 'ls docs/git-credential-notes.md' "a document whose name starts alike"
mutant "the helper binary is matched only as a bare word" \
  "GIT_CRED_HELPER_BINARY='(^|[^A-Za-z0-9_-])git-credential-" "GIT_CRED_HELPER_BINARY='(^|[^A-Za-z0-9_/.-])git-credential-" \
  "$B_FULL" "$B_EXEC" "$B_DOT"
mutant "the helper binary is matched case-sensitively" \
  'grep -qiE "$GIT_CRED_HELPER_BINARY"' 'grep -qE "$GIT_CRED_HELPER_BINARY"' \
  "$B_CAPS"
mutant "the alias check is removed" \
  '|| printf '"'"'%s'"'"' "$cmd_bare" | grep -qiE "$GIT_CRED_ALIAS"; then' '; then' \
  "$A_BIN" "$A_SUB"   # $A_CFG is also caught by the subcommand check, so it cannot go red here

echo "── git-credential-helper-gate: refuse STRIPPING the session's own override before running git"

check_blocked 'env -i git ls-remote https://example.com/x' "env -i git"
check_blocked 'env -i FOO=bar git push origin main' "env -i, with an assignment before git"
check_blocked 'env -i -- git status' "env -i --"
check_blocked 'env -u GIT_TERMINAL_PROMPT git ls-remote https://example.com/x' "env -u GIT_TERMINAL_PROMPT"
check_blocked 'env -u GIT_CONFIG_COUNT git push' "env -u GIT_CONFIG_COUNT"
check_blocked 'env -u GIT_CONFIG_KEY_0 git push' "env -u GIT_CONFIG_KEY_0"
check_blocked 'env -u GIT_CONFIG_VALUE_0 git push' "env -u GIT_CONFIG_VALUE_0"

echo " · an ordinary env use, naming neither -i nor one of the four override vars, stays allowed"
check_allowed 'env FOO=bar git push origin main' "env FOO=bar git (no -i)"
check_allowed 'env -u SOME_OTHER_VAR git push origin main' "env -u on an unrelated var"
check_allowed 'git push origin main' "a plain git push, no env wrapper at all"

echo "── git-credential-helper-gate: refuse ANY assignment, export or unset of one of the four override"
echo "   names, not only via env -i/-u"

check_blocked 'GIT_CONFIG_COUNT=0 git ls-remote https://host.example/x' "bare prefix assignment: GIT_CONFIG_COUNT=0"
check_blocked 'GIT_CONFIG_VALUE_0=osxkeychain git status' "bare prefix assignment: GIT_CONFIG_VALUE_0=<value> (never names credential.helper)"
check_blocked 'export GIT_CONFIG_COUNT=0; git status' "export GIT_CONFIG_COUNT=0; git ..."
check_blocked 'unset GIT_CONFIG_COUNT; git status' "unset GIT_CONFIG_COUNT; git ..."
check_blocked 'env GIT_CONFIG_COUNT=0 git status' "env GIT_CONFIG_COUNT=0 git ... (a plain assignment, no -i/-u)"
check_blocked 'GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_COUNT=1 GIT_CONFIG_VALUE_0=/foo git status' \
  "a legitimate-looking override (safe.directory) still refused: shape, not intent, is all a regex can see"
check_blocked 'GIT_TERMINAL_PROMPT=1 git clone https://x.example/y' "GIT_TERMINAL_PROMPT=1 (re-enabling the prompt itself)"
check_blocked 'unset GIT_CONFIG_COUNT GIT_TERMINAL_PROMPT; git status' "unset naming two vars, ours second in the list"

echo " · the safe direction: a one-off -c setting, or an unrelated assignment/unset, stays allowed"
check_allowed 'git -c credential.helper= clone https://example.com/x' "git -c <key>=<value> (the suggested one-off form)"
check_allowed 'git status' "a plain git status"
check_allowed 'MY_GIT_CONFIG_COUNT=5 git status' "a DIFFERENT variable that merely shares a suffix"
check_allowed 'unset SOME_OTHER_VAR; git status' "unset on an unrelated variable"

echo "── git-credential-helper-gate: refuse an explicit https:// URL to one of the installation's OWN"
echo "   forges (GOVERNANCE_OWN_FORGES, an adapter parameter — set here only for this suite's own use)"

OWN='GOVERNANCE_OWN_FORGES=git.example.com,mcp.example.com'
check_blocked 'git ls-remote https://git.example.com/org/repo' "git ls-remote https://<own forge>" "$OWN"
check_blocked 'git clone https://mcp.example.com/git/org/repo.git' "git clone https://<own forge, proxy path>" "$OWN"
check_blocked 'git fetch https://git.example.com/org/repo main' "git fetch https://<own forge>" "$OWN"
check_blocked 'git push https://GIT.EXAMPLE.COM/org/repo main' "case: an upper-cased own-forge host" "$OWN"

echo " · widened to http:// (the helper fires for plain http too) and to a"
echo "   URL carrying userinfo (the host no longer sits immediately after ://)"
check_blocked 'git ls-remote http://git.example.com/org/repo' "git ls-remote http:// (no s) to an own forge" "$OWN"
check_blocked 'git clone https://user@git.example.com/org/repo.git' "https://user@<own forge>/..." "$OWN"
check_blocked 'git clone https://user:pass@git.example.com/org/repo.git' "https://user:pass@<own forge>/..." "$OWN"
check_blocked 'git fetch http://user@mcp.example.com/git/org/repo main' "http://user@<own forge>/... (both widenings at once)" "$OWN"

echo " · the safe direction: a configured remote (no URL at all), or a URL to a DIFFERENT host, or no list configured"
check_allowed 'git push origin main' "a bare git push (configured remote, no URL argument)" "$OWN"
check_allowed 'git fetch origin main' "a bare git fetch (configured remote)" "$OWN"
check_allowed 'git ls-remote origin' "a bare git ls-remote (configured remote)" "$OWN"
check_allowed 'git clone https://github.com/someorg/somerepo' "https:// to a DIFFERENT host, not in the own-forges list" "$OWN"
check_allowed 'git clone http://github.com/someorg/somerepo' "http:// to a DIFFERENT host, not in the own-forges list" "$OWN"
check_allowed 'git ls-remote https://git.example.com/org/repo' "control: with NO own-forges list configured at all, the same URL is not checked"

echo "── git-credential-helper-gate: LAYER 1 ITSELF — settings/claude.json's own env block stops a"
echo "   real credential-helper call. Portable: no real"
echo "   network, no real keychain, no real credential — a fake helper script records only that it"
echo "   was INVOKED (never what it was asked, never a value), and a local HTTP server on 127.0.0.1"
echo "   answers 401 (the shape that makes git's http transport consult a helper at all)."

L1="$TMP/layer1"; mkdir -p "$L1"

# The fake helper: writes a marker, answers nothing useful. Git's own auth attempt fails EITHER way
# (this test never has a real credential to offer) — the only signal read below is the marker file,
# proving the helper was reached, never whether git's own request ultimately succeeded.
HELPER="$L1/fake-helper.sh"
cat > "$HELPER" <<HELPEREOF
#!/bin/sh
echo "invoked \$*" >> "$L1/marker"
exit 1
HELPEREOF
chmod +x "$HELPER"

SERVER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - "$SERVER_PORT" >/dev/null 2>&1 <<'SERVEREOF' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="governance-test"')
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
SERVEREOF
SERVER_PID=$!
trap 'kill '"$SERVER_PID"' 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 0.3

# The ACTUAL override values, read from settings/claude.json ITSELF — never a copy of the same four
# numbers hardcoded here — so that removing the json's own env block (this suite's own mutant target)
# genuinely changes what the "WITH override" probe below does, rather than merely disagreeing with it.
read_override_env() {
  python3 - "$ROOT/settings/claude.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for k, v in (data.get("env") or {}).items():
    print(f"{k}={v}")
PYEOF
}

# layer1_probe <label> <scope: global|local> <with_override: 0|1>
layer1_probe() {
  local label="$1" scope="$2" with_override="$3"
  local home="$TMP/home-$RANDOM-$RANDOM" repo="$TMP/repo-$RANDOM-$RANDOM"
  mkdir -p "$home"
  rm -f "$L1/marker" "$L1/unsafe"
  (
    export HOME="$home"
    # NEVER A REAL HELPER. A desktop OS's system gitconfig can name the operator's own credential store
    # first, and a "no override" control would then query it for real. The system file is excluded,
    # inherited config injection is cleared, and the probe runs only when the fake helper is the ONE
    # helper git lists.
    export GIT_CONFIG_NOSYSTEM=1
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_TERMINAL_PROMPT GIT_CONFIG_PARAMETERS \
          GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_ASKPASS SSH_ASKPASS XDG_CONFIG_HOME
    local target_dir="$home"
    if [[ "$scope" == global ]]; then
      git config --global credential.helper "$HELPER" >/dev/null 2>&1
    else
      mkdir -p "$repo"; git -C "$repo" init -q >/dev/null 2>&1
      git -C "$repo" config credential.helper "$HELPER" >/dev/null 2>&1
      target_dir="$repo"
    fi
    listed=$(git -C "$target_dir" config --get-all credential.helper 2>/dev/null)
    if [[ "$listed" != "$HELPER" ]]; then
      printf '%s\n' "$listed" > "$L1/unsafe"   # another helper is configured: do not probe at all
      exit 0
    fi
    if [[ "$with_override" == 1 ]]; then
      while IFS='=' read -r k v; do [[ -n "$k" ]] && export "$k=$v"; done < <(read_override_env)
    else
      export GIT_TERMINAL_PROMPT=0   # this test must never hang on an interactive prompt either way
    fi
    timeout 5 git -C "$target_dir" ls-remote "http://127.0.0.1:$SERVER_PORT/x.git" >/dev/null 2>&1
  )
  if [[ -f "$L1/unsafe" ]]; then
    fail "$label: NOT PROBED. git lists a helper other than this suite's fake one, so the probe was skipped rather than query it"
    return
  fi
  pass "$label: the fake helper is the only helper git lists (the system config is excluded)"
  if [[ "$with_override" == 1 ]]; then
    [[ ! -f "$L1/marker" ]] && pass "$label: the override in place — no marker, the helper was never invoked" \
      || fail "$label: the override in place, but the helper WAS invoked — $(cat "$L1/marker")"
  else
    [[ -f "$L1/marker" ]] && pass "$label: no override — marker written, the helper WAS invoked (the positive control)" \
      || fail "$label: no override, but the helper was never invoked — the control itself is broken, this proves nothing"
  fi
}

layer1_probe "global ~/.gitconfig helper" global 0
layer1_probe "global ~/.gitconfig helper" global 1
layer1_probe "repo-local .git/config helper" local 0
layer1_probe "repo-local .git/config helper" local 1

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1; fi
