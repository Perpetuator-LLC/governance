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
echo "   names, not only via env -i/-u (cisa SEND-BACK on PR #443, c191198 item 2)"

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

echo " · cisa J1 (PR #443, c191198): widened to http:// (the helper fires for plain http too) and to a"
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
echo "   real credential-helper call (cisa SEND-BACK on PR #443, c191198 item 3). Portable: no real"
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
  rm -f "$L1/marker"
  (
    export HOME="$home"
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_TERMINAL_PROMPT
    local target_dir="$home"
    if [[ "$scope" == global ]]; then
      git config --global credential.helper "$HELPER" >/dev/null 2>&1
    else
      mkdir -p "$repo"; git -C "$repo" init -q >/dev/null 2>&1
      git -C "$repo" config credential.helper "$HELPER" >/dev/null 2>&1
      target_dir="$repo"
    fi
    if [[ "$with_override" == 1 ]]; then
      while IFS='=' read -r k v; do [[ -n "$k" ]] && export "$k=$v"; done < <(read_override_env)
    else
      export GIT_TERMINAL_PROMPT=0   # this test must never hang on an interactive prompt either way
    fi
    timeout 5 git -C "$target_dir" ls-remote "http://127.0.0.1:$SERVER_PORT/x.git" >/dev/null 2>&1
  )
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
