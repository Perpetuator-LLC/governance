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

echo "── a GIT_* variable moves git elsewhere (CISA c106371 D1): can't tell, refused"
B="$TMP/clean-b"                          # a clean repository as the hook's cwd; the target is dirty $R
mkdir -p "$B" && ( cd "$B" && git init -q . && echo m > mod.txt && git add mod.txt \
  && git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm one ) \
  || { echo "FAIL: could not build the second repository"; exit 1; }
blocked "$B" "GIT_DIR=$R/.git GIT_WORK_TREE=$R git checkout -- mod.txt" "could not be determined"
blocked "$B" "GIT_WORK_TREE=$R git restore mod.txt" "could not be determined"
blocked "$B" "export GIT_DIR=$R/.git; git checkout -- mod.txt" "could not be determined"
blocked "$B" "GIT_INDEX_FILE=/tmp/x git checkout -- mod.txt" "could not be determined"
blocked "$R" "GIT_DIR=$B/.git GIT_WORK_TREE=$B git checkout -- mod.txt" "could not be determined"
blocked "$R" "GIT_CONFIG_GLOBAL=/dev/null git checkout -- clean.txt" "could not be determined"

echo "── the check runs nothing the repository configures (CISA c106371 D2)"
F="$TMP/fsm"                              # core.fsmonitor: a command git runs during status
mkdir -p "$F" && ( cd "$F" && git init -q . && echo c > c.txt && git add c.txt \
  && git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm one \
  && git config core.fsmonitor "touch '$TMP/fsmonitor-ran'; false" \
  && git config core.hooksPath "$TMP/hooks" ) || { echo "FAIL: could not build the fsmonitor repository"; exit 1; }
rc=$(run "$F" 'git checkout -- c.txt')
[[ ! -e "$TMP/fsmonitor-ran" ]] && pass "core.fsmonitor did not run inside the gate (rc=$rc)" \
  || fail "core.fsmonitor ran inside the gate, before the call was approved"
L="$TMP/filt"                             # a clean filter: status may run it on a racily clean file
mkdir -p "$L" && ( cd "$L" && git init -q . && echo '*.txt filter=x' > .gitattributes && echo c > c.txt \
  && echo d > d.dat && git add . \
  && git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm one \
  && git config filter.x.clean "touch '$TMP/filter-ran'; cat" \
  && git config filter.x.smudge cat ) || { echo "FAIL: could not build the filter repository"; exit 1; }
blocked "$L" 'git checkout -- c.txt' "clean or process filter"
blocked "$L" 'git checkout -- .' "clean or process filter"
[[ ! -e "$TMP/filter-ran" ]] && pass "the clean filter did not run inside the gate" \
  || fail "the clean filter ran inside the gate"
allowed "$L" 'git checkout -- d.dat'      # a filter exists, but not for this path

echo "── the refusal names a revert that works (CISA c106371, Decide 2)"
run "$R" 'git checkout -- mod.txt' >/dev/null
grep -q 'keep a copy of the file before you change it' "$TMP/err" && ! grep -q 'stash push' "$TMP/err" \
  && pass "the refusal says to restore from a saved copy, and no longer offers commit or stash" \
  || fail "refusal text: $(cat "$TMP/err")"

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
