#!/usr/bin/env bash
# tests/bash-safety-gate-push.test.sh — bash-safety-gate.sh refuses a push that rewrites or deletes
# remote refs by a spelling other than --force (`--mirror`, `--delete`, `--prune`, a `-fu` bundle, a
# quoted `+`/`:` refspec), and an alias or push-configuration change that would hide one (#268).
#
# The known-answer table is the ticket's (TEST v2 and its two addenda, under the rulings on the ticket):
# every row is copied with its id, and its expected exit code is the ticket's, not the gate's. 2 = refused,
# 0 = allowed. Before the fix every row marked 2 here, except those noted "already" below, exited 0.
#
# Every row runs under BOTH input parsers the gate has: jq when the host has it, and python3 on a PATH
# without jq. A host with no jq runs the python3 leg only and says so.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # keep the audit trail out of the real state directory
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
  "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; }

HOOK_PATH="$PATH"
run() {  # run <command-text> -> exit code; BLOCKED line (if any) in $TMP/err
  printf '%s' "$(bash_json "$1")" | PATH="$HOOK_PATH" bash "$GATE" >"$TMP/out" 2>"$TMP/err"
  echo $?
}

FORCE="Force push"
DEFAULT="default branch"
PUSHCFG="how git push behaves"
ALIAS="git alias"

row() {  # row <id> <expected exit> <expected reason substring, or ""> <command>
  local rc; rc=$(run "$4")
  if [[ "$rc" != "$2" ]]; then
    fail "$1: exit $rc, expected $2 — $4 $(head -c 200 "$TMP/err")"
  elif [[ "$2" == 2 && -n "$3" ]] && ! grep -qi "$3" "$TMP/err"; then
    fail "$1: refused, but not for '$3' ($(cat "$TMP/err")) — $4"
  else
    pass "$1 ($2): $4"
  fi
}

table() {
  echo "── A. quote-aware tokeniser"
  row A1  2 "$FORCE"   "git push origin '+main'"
  row A2  2 "$FORCE"   'git push origin "+main"'
  row A3  2 "$DEFAULT" "git push origin '--mirror'"
  row A4  2 "$FORCE"   'git push origin ":main"'
  row A5  0 ""         "git push origin 'feature+x'"
  row A6  0 ""         'git commit -m "git push --mirror origin"'
  row A7  2 "$FORCE"   "git push origin x -m '--force'"
  row A8  0 ""         'echo git push --mirror'
  row A8a 2 ""         'echo git push --mirror origin | sh'
  row A8b 2 ""         'echo git push --mirror origin | bash'
  row A8c 2 ""         '$(echo git push --mirror origin)'
  row A8d 2 ""         '`echo git push --mirror origin`'
  row A8e 2 ""         'eval "$(echo git push --mirror origin)"'
  row A8f 2 ""         'echo origin | xargs git push --mirror'
  row A8g 2 ""         "bash -c 'git push --mirror origin'"
  row A8h 2 ""         'sh -c "$(echo git push --mirror origin)"'
  row A8i 0 ""         'echo git push --mirror > /tmp/x.txt'

  echo "── B. sh -c / bash -c / eval"
  row B1 2 ""       "sh -c 'git push --mirror origin'"
  row B2 2 "$FORCE" 'bash -c "git push -f origin x"'
  row B3 2 ""       "bash -lc 'cd r && git push --delete origin main'"
  row B4 2 ""       'eval "git push --mirror origin"'
  row B5 0 ""       "sh -c 'git push origin x'"

  echo "── C. chained commands"
  row C1 2 "$DEFAULT" 'true && git push --mirror origin'
  row C2 2 "$FORCE"   "git status; git push origin ':keep'"
  row C3 2 "$FORCE"   'git fetch || git push -fu origin x'
  row C4 2 ""         "(cd r; git push --prune origin 'refs/heads/*:refs/heads/*')"
  row C5 0 ""         'git add a && git commit -m x && git push origin x'
  row C6 2 "$DEFAULT" 'git push origin x & git push --mirror origin'

  echo "── D. mirror / delete / prune / short-flag bundles"
  row D1   2 "$DEFAULT" 'git push --mirror origin'
  row D2   2 "$DEFAULT" 'git push origin --mirror'
  row D3   2 "$FORCE"   'git push --mirror=origin'
  row D4   2 "$DEFAULT" '/usr/bin/git push --mirror'
  row D5   2 "$DEFAULT" 'git -C r push --mirror'
  row D6a  2 "$FORCE"   'git push -fu origin x'
  row D6b  2 "$FORCE"   'git push -uf origin x'
  row D6c  2 "$FORCE"   'git push -nf origin x'
  row D7a  2 "$FORCE"   'git push -d origin feeder/x'
  row D7b  2 "$FORCE"   'git push --delete origin feeder/x'
  row D8   2 ""         'git push --all --prune origin'
  row D8b  2 "$FORCE"   'git push --prune origin feeder/x'
  row D9   0 ""         'git push -u origin x'
  row D10  0 ""         'git push --tags origin'
  row D11  0 ""         'git push origin HEAD:refs/heads/x'
  row D12  0 ""         'git fetch --prune'
  row D13  2 "$FORCE"   'git push -f origin x'

  echo "── E. git aliases: any change refused, reads allowed"
  row E1   2 "$ALIAS" 'git -c alias.p="push --force" p origin x'
  row E2   2 "$ALIAS" "git -c alias.p='!git push --mirror' p"
  row E3   2 "$ALIAS" 'git config alias.yeet "push --force"'
  row E4   2 "$ALIAS" "git config --global alias.m 'push --mirror'"
  row E5   2 "$ALIAS" 'git config alias.st status'
  row E5a  2 "$ALIAS" "git config alias.p 'push --mirror'"
  row E5b  2 "$ALIAS" 'git config --local alias.st status'
  row E5c  2 "$ALIAS" 'git config --global alias.st status'
  row E5d  2 "$ALIAS" 'git config --system alias.st status'
  row E5e  2 "$ALIAS" 'git config --add alias.st status'
  row E5f  2 "$ALIAS" 'git config --replace-all alias.st status'
  row E5g  2 "$ALIAS" 'git config --file .git/config alias.st status'
  row E5h  2 "$ALIAS" 'git config --unset alias.st'
  row E5h1 2 "$ALIAS" 'git config --global --unset alias.st'
  row E5i  2 "$ALIAS" 'git config Alias.ST status'
  row E5n  2 "$ALIAS" 'git config --unset-all alias.st'
  row E5o  2 "$ALIAS" 'git config --remove-section alias'
  row E5p  2 "$ALIAS" 'git config --rename-section alias foo'
  row E5q  2 "$ALIAS" 'git config --rename-section foo alias'
  row E5r  2 "$ALIAS" 'git config --edit'
  row E5s  2 "$ALIAS" 'git config --global --edit'
  row E5s2 2 "$ALIAS" 'git config -e'
  row E5j  0 ""       'git config --get alias.st'
  row E5k  0 ""       "git config --get-regexp '^alias\\.'"
  row E5l  0 ""       'git config --list'
  row E5m  0 ""       'git config --global --get alias.st'
  row E6   2 "$ALIAS" 'git -c alias.st=status st'
  row E7   0 ""       'git yeet origin x'

  echo "── F. -c / config / environment overrides"
  row F1   2 "$PUSHCFG" 'git -c remote.origin.mirror=true push origin'
  row F2   2 "$PUSHCFG" 'git -c Remote.Origin.Mirror=true push origin'
  row F3   2 "$PUSHCFG" 'git -c push.default=matching push origin'
  row F4   2 "$PUSHCFG" 'git -c push.followTags=true push origin x'
  row F4a  2 "$PUSHCFG" 'git -c push.useForceIfIncludes=true push origin x'
  row F4b  2 "$PUSHCFG" 'git -c push.recurseSubmodules=on-demand push origin x'
  row F5   0 ""         'git -c user.name=x push origin x'
  row F6   2 "$PUSHCFG" 'git config remote.origin.mirror true'
  row F7   2 "$PUSHCFG" 'git config remote.origin.mirror true && git push origin'
  row F8   0 ""         'git config --get remote.origin.mirror'
  row F8a  2 "$PUSHCFG" "git config --add remote.origin.push '+refs/heads/*:refs/heads/*'"
  row F8b  2 "$PUSHCFG" 'git config --global --replace-all push.default matching'
  row F8c  2 "$PUSHCFG" "printf '[remote \"origin\"]\\n\\tmirror = true\\n' >> .git/config"
  row F8c2 2 "$PUSHCFG" "sed -i '' 's/fetch =/mirror = true\\n\\tfetch =/' .git/config"
  row F8c3 2 "$PUSHCFG" "echo '[alias] p = push --force' | tee -a .git/config"
  row F8d  0 ""         "git config --get-regexp '^alias\\.'"
  row F8d2 0 ""         'cat .git/config'
  row F9   2 "$PUSHCFG" 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.mirror GIT_CONFIG_VALUE_0=true git push origin'
  row F10  2 "$PUSHCFG" "GIT_CONFIG_PARAMETERS=\"'remote.origin.mirror'='true'\" git push origin"
  row F11  2 "$PUSHCFG" 'GIT_CONFIG_GLOBAL=/tmp/g git push origin x'
  row F12  2 "$PUSHCFG" 'env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=push.default GIT_CONFIG_VALUE_0=mirror git push'
  row F13  0 ""         'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x git status'

  echo "── controls named in the fix spec"
  row X1 0 "" 'git push origin x'
  row X2 0 "" 'git push origin feeder/268-x'
  row X3 0 "" 'git config --get core.hooksPath'
  row X4 0 "" 'git config user.name x'
}

# A PATH with only the commands the gate runs, and no jq: the python3 parser leg on a host that has jq.
nojq_path() {
  local dir="$TMP/nojq" t p
  mkdir -p "$dir"
  for t in bash cat grep tr sed head tail cut paste dirname git env; do
    p=$(command -v "$t") && ln -s "$p" "$dir/$t"
  done
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$dir/python3"   # not a version-manager shim
  printf '%s' "$dir"
}

if command -v jq >/dev/null 2>&1; then
  echo "═══ parser leg: jq"
  HOOK_PATH="$PATH"; table
  echo "═══ parser leg: python3 (PATH without jq)"
  HOOK_PATH="$(nojq_path)"
  PATH="$HOOK_PATH" command -v jq >/dev/null 2>&1 && fail "the no-jq PATH still has jq"
  table
else
  echo "═══ parser leg: python3 (this host has no jq, so the jq leg is not run here)"
  table
fi

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
