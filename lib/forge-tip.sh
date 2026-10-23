# lib/forge-tip.sh — the one way this repo's branch tools ask "what is origin's default branch,
# and where is its tip", per the rule "a fleet audit measures against the FORGE, never
# against refs/remotes/* as found": `origin/HEAD` is a LOCAL symref, set once at clone time (or by
# an explicit `git remote set-head`). `git fetch` never updates it, so it can point at a branch the
# forge renamed or deleted long after the fetch that would otherwise make the repo look current.
#
# Sourced, not executed: `source ".../lib/forge-tip.sh"`. Depends on nothing but `git` and `awk`.
#
# Previously reimplemented, three different ways, in branch-reap, held-branches and orphan-check:
# one read `git remote show origin` and scraped its text for a fallback;
# the other two fell back to guessing "main" or "master" by name, which answers confidently and
# wrongly for a repo whose default branch is neither — and silently skips it instead.

# forge_default_branch <repo>
#   Prints origin's default branch name (no "origin/" prefix) and returns 0, trying the cheap local
#   cache first and asking the forge directly — never guessing from a naming convention — only when
#   that cache is unset. Prints nothing and returns 1 if neither resolves (no "origin" remote, or it
#   could not be reached).
forge_default_branch() {
  local repo="$1" d symref
  d="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  d="${d#origin/}"
  if [ -z "$d" ]; then
    symref="$(git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" { print $2; exit }')"
    d="${symref#refs/heads/}"
  fi
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

# forge_tip <repo> <branch>
#   Prints the forge's current commit sha for refs/heads/<branch> and returns 0. Prints nothing and
#   returns 1 if the forge could not be asked, or does not have that branch — a failed ask is no
#   answer, never read as "the branch is gone".
forge_tip() {
  local repo="$1" branch="$2" sha
  sha="$(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" 2>/dev/null | cut -f1)"
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}
