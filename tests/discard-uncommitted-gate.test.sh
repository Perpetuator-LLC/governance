#!/usr/bin/env bash
# tests/discard-uncommitted-gate.test.sh — bash-safety-gate.sh refuses `git checkout [<rev>] -- <path>`
# and `git restore [--worktree] [--source=<rev>] <path>` when the path holds uncommitted changes (#256).
#
# A throwaway repository holds a modified, a staged, a deleted, a clean and an untracked file. Each form
# is judged in the hook input's `cwd`, under `git -C`, and after a leading `cd`. Before the rule (the gate
# at a5228c2) every BLOCKED case below exited 0. GATE=<path> runs this file against another copy.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${GATE:-$ROOT/hooks/bash-safety-gate.sh}"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # keep the audit trail out of the real state directory
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

R="$TMP/repo"
mkdir -p "$R/sub"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@example.invalid && git config user.name t
  git config commit.gpgsign false
  for f in mod clean staged del gone; do echo "$f" > "$f.txt"; done
  echo s > sub/s.txt
  git add -A && git commit -qm one
  git rm -q gone.txt && git commit -qm two
  echo changed >> mod.txt                 # modified, unstaged
  echo changed >> staged.txt && git add staged.txt
  rm del.txt                              # deleted
  echo new > new.txt                      # untracked, in no commit
  echo back > gone.txt                    # untracked, but HEAD~1 has it
) || { echo "FAIL: could not build the test repository"; exit 1; }

hook_json() {  # hook_json <cwd> <command>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$1" "$2"
}
run() {  # run <cwd> <command> -> exit code; BLOCKED line (if any) in $TMP/err
  hook_json "$1" "$2" | bash "$GATE" >"$TMP/out" 2>"$TMP/err"
  echo $?
}
blocked() {  # blocked <cwd> <command> <expected-substring>
  local rc; rc=$(run "$1" "$2")
  [[ "$rc" == "2" ]] || { fail "exit $rc, not 2 — [${1#$TMP}] $2"; return; }
  grep -q "uncommitted" "$TMP/err" && grep -qF -- "$3" "$TMP/err" \
    || { fail "BLOCKED but not naming '$3' ($(cat "$TMP/err")) — $2"; return; }
  pass "blocked ($3): [${1#$TMP}] $2"
}
allowed() {  # allowed <cwd> <command>
  local rc; rc=$(run "$1" "$2")
  [[ "$rc" == "0" ]] && pass "allowed: [${1#$TMP}] $2" \
    || fail "blocked (should be allowed, rc=$rc: $(cat "$TMP/err")) — [${1#$TMP}] $2"
}

echo "── a path with uncommitted changes, judged in the hook's cwd"
blocked "$R" 'git checkout -- mod.txt' mod.txt
blocked "$R" 'git checkout HEAD -- mod.txt' mod.txt
blocked "$R" 'git checkout -- clean.txt mod.txt' mod.txt
blocked "$R" 'git checkout -- .' mod.txt
blocked "$R" 'git checkout -- staged.txt' staged.txt
blocked "$R" 'git checkout -- del.txt' del.txt
blocked "$R" 'git restore mod.txt' mod.txt
blocked "$R" 'git restore --worktree mod.txt' mod.txt
blocked "$R" 'git restore -W -- mod.txt' mod.txt
blocked "$R" 'git restore --source=HEAD mod.txt' mod.txt
blocked "$R" 'git restore -s HEAD mod.txt' mod.txt
blocked "$R" 'git restore --staged --worktree mod.txt' mod.txt
blocked "$R" 'git restore -SW mod.txt' mod.txt
blocked "$R" 'echo x && git restore "mod.txt"' mod.txt
echo "── an untracked file that a named <rev> would overwrite"
blocked "$R" 'git checkout HEAD~1 -- gone.txt' gone.txt
blocked "$R" 'git restore --source=HEAD~1 gone.txt' gone.txt
echo "── the directory: -C, a leading cd, a subdirectory cwd"
blocked "$TMP" 'git -C repo checkout -- mod.txt' mod.txt
blocked "$TMP" 'git -C repo restore mod.txt' mod.txt
blocked "$TMP" 'cd repo && git restore mod.txt' mod.txt
blocked "$TMP" 'cd repo/sub && git -C .. checkout -- mod.txt' mod.txt
blocked "$R/sub" 'git checkout -- ../mod.txt' mod.txt
echo "── can't tell: refused (fail closed)"
blocked "$TMP" 'git checkout -- mod.txt' "could not be determined"
blocked "$R" 'git checkout -- "$F"' "could not be determined"
blocked "$R" 'cd ~ && git checkout -- mod.txt' "could not be determined"
blocked "$R" 'git --work-tree=. checkout -- clean.txt' "could not be determined"
blocked "$R" 'true $(true) && git restore clean.txt' "could not be determined"
blocked "$R" 'true $(true) && git checkout -- clean.txt' "could not be determined"

echo "── controls: clean paths, a branch switch, the index only"
allowed "$R" 'git checkout -- clean.txt'
allowed "$R" 'git checkout HEAD -- clean.txt sub/s.txt'
allowed "$R" 'git restore clean.txt'
allowed "$R" 'git restore --source=HEAD clean.txt'
allowed "$R" 'git checkout -- new.txt'
allowed "$R" 'git restore new.txt'
allowed "$R" 'git restore --staged mod.txt'
allowed "$R" 'git restore -S staged.txt'
allowed "$R" 'git restore --staged --source=HEAD~1 staged.txt'
allowed "$R" 'git checkout feeder/x'
allowed "$R" 'git checkout -b feeder/y'
allowed "$R" 'git checkout main'
allowed "$TMP" 'git -C repo checkout -- clean.txt'
allowed "$TMP" 'cd repo && git restore clean.txt'
allowed "$R/sub" 'git checkout -- s.txt'
allowed "$R" 'git commit -m "git checkout -- mod.txt"'
allowed "$R" 'true $(true) && git restore --staged mod.txt'

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
