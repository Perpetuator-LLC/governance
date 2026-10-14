#!/usr/bin/env bash
# tests/worktree-cleanup-branch-safety.test.sh — a CLEAN but UNMERGED branch's worktree is removed,
# its branch is NOT force-deleted.
#
# Found by mutation (quality sweep, 2026-10-14): removing the `merged` half of
# `[[ -n "$branch" && "$branch" != "$def" && "$merged" -eq 1 ]]` — the gate before
# `git branch -D "$branch"` — passed the entire existing hooks-misc.test.sh suite unchanged. Every
# existing "clean ephemeral worktree" fixture there happens to also be merged (built from
# `origin/main` with no further unmerged commit), so "clean" and "merged" were never pulled apart.
# A branch pushed with an open, unmerged PR is "clean" (fully committed and pushed — nothing
# uncommitted, nothing unpushed) without being merged, and that is exactly the gap: `is_clean`
# alone must never be read as license to force-delete the branch ref.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/worktree-cleanup.sh"
[[ -f "$HOOK" ]] || { echo "FAIL: $HOOK missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

HOOK_HOME="$TMP/home"; mkdir -p "$HOOK_HOME/.claude"
CLEAN_LOG="$HOOK_HOME/.claude/worktree-cleanup.log"
event_json() { printf '{"session_id":"s","transcript_path":"%s/t.jsonl","cwd":"%s","hook_event_name":"SessionEnd"}' "$TMP" "$1"; }
hook() { HOME="$HOOK_HOME" bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; echo $?; }

mkrepo() {
  local d="$TMP/repos/$1"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/repo" 2>/dev/null
  echo base > "$d/repo/f"; git -C "$d/repo" add f; git -C "$d/repo" commit -qm base
  git -C "$d/repo" push -q origin main 2>/dev/null
  git -C "$d/repo" remote set-head origin main >/dev/null 2>&1
  printf '%s' "$d/repo"
}

echo "── worktree-cleanup: clean is not merged — a pushed, unmerged branch keeps its ref"

R="$(mkrepo pr-open)"
W="$R/.claude/worktrees/pr-open"
git -C "$R" worktree add -q -b feat/pr-open "$W" origin/main 2>/dev/null
echo "pr content" > "$W/new.txt"
git -C "$W" add new.txt
git -C "$W" commit -qm "feat: open PR, not yet merged"
git -C "$W" push -q -u origin feat/pr-open 2>/dev/null

# Control, asserted before the real check: this branch really is "clean" (nothing uncommitted,
# nothing unpushed relative to its own upstream) and really is NOT merged into main.
[[ -z "$(git -C "$W" status --porcelain)" ]] && [[ -z "$(git -C "$W" log '@{u}..HEAD' --oneline)" ]] \
  && pass "control: the branch is clean (committed and pushed)" \
  || fail "control: fixture is not actually clean — test is not measuring what it claims"
git -C "$R" merge-base --is-ancestor "$W" refs/remotes/origin/main 2>/dev/null \
  && fail "control: fixture branch is already merged — test cannot distinguish clean from merged" \
  || pass "control: the branch is NOT merged into main"

rc="$(cd "$TMP" && event_json "$W" | hook)"
pass_or_fail_rc() { [[ "$rc" == "0" ]] && pass "hook exits 0" || fail "hook exited $rc, not 0"; }
pass_or_fail_rc

[[ ! -d "$W" ]] && pass "the clean worktree is removed" || fail "the clean worktree was NOT removed"
git -C "$R" rev-parse --verify --quiet refs/heads/feat/pr-open >/dev/null \
  && pass "the UNMERGED branch ref still exists — not force-deleted" \
  || fail "the unmerged branch was DELETED — an open PR's only local ref is gone"
grep -q "deleted merged branch" "$CLEAN_LOG" 2>/dev/null \
  && fail "the clean log claims a branch was deleted as merged, but it was not merged" \
  || pass "the clean log does not claim a merge-deletion that didn't happen"
grep -q "removed clean worktree: $W" "$CLEAN_LOG" 2>/dev/null \
  && pass "the worktree removal is still logged" \
  || fail "the worktree removal was not logged"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
