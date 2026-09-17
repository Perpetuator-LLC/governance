#!/bin/bash
# Hook: SessionEnd — reconcile the worktree this session ran in.
#
# A Claude session usually runs in a linked git worktree. When the session
# ends, that worktree (and its branch) would otherwise pile up forever. This
# hook inspects ONLY the worktree the session ran in and:
#
#   * Ephemeral worktree (under <repo>/.claude/worktrees/<name>):
#       - clean  → remove the worktree; if its branch is merged into the
#                  default branch, delete the branch too. Logged.
#       - dirty/unpushed → leave it, log details, desktop-notify.
#   * Sibling / hand-made worktree (anywhere else):
#       - NEVER auto-removed (you may have it open in your IDE).
#       - clean + merged → noted in the log as reapable.
#       - dirty/unpushed → log details, desktop-notify.
#   * Main worktree → nothing to do.
#
# Bulk cleanup across ALL worktrees is an on-demand job (`git worktree list`,
# then `git worktree remove`), not this hook. The hook never blocks: it always
# exits 0. Disable it per-session with CLAUDE_WORKTREE_AUTOCLEAN=0.

[[ "${CLAUDE_WORKTREE_AUTOCLEAN:-1}" == "0" ]] && exit 0

# --- Resolve the worktree path. SessionEnd hooks receive JSON on stdin with
#     a `.cwd` field; fall back to $PWD. Parse with jq when present, python3
#     otherwise: a parser that is silently absent would make every session
#     reconcile whatever directory the hook happened to start in. ---
worktree_path=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || true)
  if [[ -n "$input" ]]; then
    if command -v jq >/dev/null 2>&1; then
      worktree_path=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
      worktree_path=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("cwd")
except Exception:
    v = None
if isinstance(v, str):
    sys.stdout.write(v)
' 2>/dev/null)
    fi
  fi
fi
worktree_path="${worktree_path:-$PWD}"
[[ -d "$worktree_path" ]] || exit 0

cd "$worktree_path" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# --- Is this a linked worktree? (main worktree: git-dir == git-common-dir) ---
git_dir=$(git rev-parse --git-dir 2>/dev/null)
common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
[[ "$git_dir" == "$common_dir" ]] && exit 0    # main worktree — nothing to clean

# --- Main repo = parent of the shared .git dir (works for any worktree layout) ---
case "$common_dir" in /*) ;; *) common_dir="$worktree_path/$common_dir" ;; esac
parent_repo=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
[[ -n "$parent_repo" && -d "$parent_repo" ]] || exit 0

# --- Gather state (while still inside the worktree) ---
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[[ "$branch" == "HEAD" ]] && branch=""          # detached
uncommitted=$(git status --porcelain 2>/dev/null)

# Default branch + "is this branch merged into it?"
def=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); def="${def#refs/remotes/origin/}"
if [[ -z "$def" ]]; then
  for b in main master trunk; do
    git show-ref --verify --quiet "refs/heads/$b" && { def="$b"; break; }
  done
fi
base="$def"
git show-ref --verify --quiet "refs/remotes/origin/$def" && base="origin/$def"

unpushed=""
if [[ -n "$branch" ]]; then
  if git rev-parse "@{u}" >/dev/null 2>&1; then
    unpushed=$(git log "@{u}..HEAD" --oneline 2>/dev/null)
  elif [[ -n "$base" ]]; then
    # No upstream: commits not on the default base count as unpushed —
    # otherwise a local-only branch with real work reads as clean and the
    # only checkout gets removed.
    unpushed=$(git log "$base..HEAD" --oneline 2>/dev/null)
  fi
fi
merged=0
if [[ -n "$branch" && -n "$base" ]] && git merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
  merged=1
fi

is_clean=0
[[ -z "$uncommitted" && -z "$unpushed" ]] && is_clean=1

case "$worktree_path" in */.claude/worktrees/*) ephemeral=1 ;; *) ephemeral=0 ;; esac

# --- Logging + notification helpers ---
ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
log_dir="$HOME/.claude"; mkdir -p "$log_dir"
clean_log="$log_dir/worktree-cleanup.log"
dirty_log="$log_dir/worktree-needs-attention.log"

notify() {  # $1=message $2=title
  if [[ "$(uname)" == "Darwin" ]]; then
    osascript -e "display notification \"$1\" with title \"${2:-Claude Code}\"" 2>/dev/null
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "${2:-Claude Code}" "$1" 2>/dev/null
  fi
}

log_dirty() {
  {
    echo "$ts ===================="
    echo "$ts worktree: $worktree_path"
    echo "$ts branch:   ${branch:-(detached)}"
    if [[ -n "$uncommitted" ]]; then
      echo "$ts uncommitted changes:"; echo "$uncommitted" | sed "s|^|$ts   |"
    fi
    if [[ -n "$unpushed" ]]; then
      echo "$ts unpushed commits:"; echo "$unpushed" | sed "s|^|$ts   |"
    fi
    echo "$ts inspect:  cd $worktree_path"
    echo "$ts discard:  git -C $parent_repo worktree remove --force $worktree_path"
  } >> "$dirty_log"
}

basename_wt=$(basename "$worktree_path")

if [[ "$ephemeral" -eq 1 ]]; then
  if [[ "$is_clean" -eq 1 ]]; then
    # CLEAN ephemeral worktree — remove it (and its merged branch). cd out first.
    cd "$parent_repo" || exit 0
    if git worktree remove --force "$worktree_path" 2>/dev/null; then
      msg="removed clean worktree: $worktree_path (branch: ${branch:-detached})"
      if [[ -n "$branch" && "$branch" != "$def" && "$merged" -eq 1 ]]; then
        # merged into $base already verified — safe to drop the branch ref
        git branch -D "$branch" >/dev/null 2>&1 && msg="$msg + deleted merged branch '$branch'"
      fi
      echo "$ts $msg" >> "$clean_log"
    else
      echo "$ts FAILED to remove worktree: $worktree_path (branch: ${branch:-detached})" >> "$clean_log"
    fi
  else
    log_dirty
    notify "Worktree '$basename_wt' has uncommitted/unpushed work — see ~/.claude/worktree-needs-attention.log" "Claude Code: cleanup deferred"
  fi
else
  # SIBLING / hand-made worktree — never auto-remove.
  if [[ "$is_clean" -eq 1 && -n "$branch" && "$merged" -eq 1 ]]; then
    echo "$ts reapable sibling (not auto-removed): $worktree_path (branch '$branch' merged into $base) — remove with: git -C $parent_repo worktree remove $worktree_path" >> "$clean_log"
  elif [[ "$is_clean" -ne 1 ]]; then
    log_dirty
    notify "Sibling worktree '$basename_wt' has uncommitted/unpushed work — see ~/.claude/worktree-needs-attention.log" "Claude Code: worktree needs attention"
  fi
fi

exit 0
