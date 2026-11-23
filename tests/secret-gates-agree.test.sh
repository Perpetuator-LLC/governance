#!/usr/bin/env bash
# tests/secret-gates-agree.test.sh — bash-safety-gate.sh (read) and write-safety-gate.sh (write) share
# CREDENTIAL_PATH_RX from hooks/credential-paths.sh (governance#335), so a path either gate refuses
# can never drift from the other's list. This feeds the SAME credential-store path through both gates
# and asserts they AGREE it is refused — the two gates check different SHAPES of command (a reader
# verb near a path, vs. the path a Write targets), so this is not "identical verdicts on every input,"
# only "neither one's path list is missing an entry the other one has."

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READ_GATE="$ROOT/hooks/bash-safety-gate.sh"
WRITE_GATE="$ROOT/hooks/write-safety-gate.sh"
LIB="$ROOT/hooks/credential-paths.sh"
[[ -f "$READ_GATE" ]] || { echo "FAIL: $READ_GATE missing"; exit 1; }
[[ -f "$WRITE_GATE" ]] || { echo "FAIL: $WRITE_GATE missing"; exit 1; }
[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing"; exit 1; }

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

read_blocks() {  # read_blocks <path> -> 0 iff `cat <path>` is refused by the read gate
  local cmd="cat $1"
  printf '%s' "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")" \
    | bash "$READ_GATE" >/dev/null 2>/dev/null
  [[ $? -eq 2 ]]
}

write_blocks() {  # write_blocks <path> -> 0 iff writing to <path> is refused by the write gate
  printf '%s' "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1]}}))' "$1")" \
    | bash "$WRITE_GATE" >/dev/null 2>/dev/null
  [[ $? -eq 2 ]]
}

agree() {  # agree <path> <label>: both gates refuse <path>, read via `cat`, write via file_path
  local path="$1" label="$2"
  if read_blocks "$path" && write_blocks "$path"; then
    pass "$label: both gates refuse it"
  else
    fail "$label: gates disagree (read_blocks=$(read_blocks "$path"; echo $?) write_blocks=$(write_blocks "$path"; echo $?)) — path $path"
  fi
}

echo "── secret-gates-agree: the shared CREDENTIAL_PATH_RX list, on both gates"
agree "$HOME/.aws/credentials" ".aws/credentials"
agree "$HOME/.aws/config" ".aws/config"
agree "$HOME/.netrc" ".netrc"
agree "$HOME/.ssh/id_ed25519" ".ssh/id_ed25519"
agree "$HOME/.ssh/deploy_key" ".ssh/*_key"
agree "$HOME/.docker/config.json" ".docker/config.json"
agree "$HOME/.kube/config" ".kube/config"
agree "$HOME/.config/gh/hosts.yml" ".config/gh/hosts.yml"
agree "$HOME/.git-credentials" ".git-credentials"
agree "$HOME/.pgpass" ".pgpass"

# control: both gates agree an ORDINARY path is allowed, the same way
if ! read_blocks "README.md" && ! write_blocks "README.md"; then
  pass "control: an ordinary path is allowed by both gates"
else
  fail "control: an ordinary path was refused by one gate or the other"
fi

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1; fi
