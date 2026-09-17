#!/usr/bin/env bash
# hooks-misc.test.sh — the non-gate hooks must do their job on the input the harness actually sends,
# and must NEVER block.
#
#   reminder-instructions.sh  UserPromptSubmit  emits context in the harness's structured shape
#   notify-complete.sh        Stop              fires a desktop notification when a notifier exists
#   worktree-cleanup.sh       SessionEnd        reconciles the worktree the session ran in
#
# Each hook gets harness-shaped JSON on stdin (never a convenient env var), a known-good and a
# known-bad case, and an assertion that its exit code is not 2: exit 2 from a hook blocks or rewrites
# the harness's flow, and none of these hooks has any business doing that.
#
# ⚠️ NOTHING HERE MAY TOUCH THE REAL DESKTOP OR THE REAL HOME. Notifiers and `uname` are stubs that
# record their calls; HOME is a throwaway directory; git fixtures use their own config. And every
# case runs under each parser the hooks may find: a PATH with jq, a PATH without it (python3
# fallback), and — for the never-blocks property — a PATH with neither.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false

# A PATH holding every command on the current PATH except the named ones.
shim_path() {
  local dir="$TMP/path-$1"; shift
  mkdir -p "$dir"
  local d f n x skip
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"; skip=0
      for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
      [ "$skip" = 1 ] || [ -e "$dir/$n" ] || ln -s "$f" "$dir/$n" 2>/dev/null
    done
  done
  # A version-manager shim (pyenv, asdf) only works with its manager on PATH; link the real
  # interpreter, or the no-jq leg measures a broken python3 instead of a missing jq.
  if [ -L "$dir/python3" ]; then ln -sf "$(python3 -c 'import sys; print(sys.executable)')" "$dir/python3"; fi
  printf '%s' "$dir"
}

# Stubs: a fake `uname` naming the OS, and notifiers that append their arguments to a record file.
# stub_dir <name> <os> [notifier...]
stub_dir() {
  local dir="$TMP/stub-$1" os="$2"; shift 2
  mkdir -p "$dir"
  printf '#!/bin/sh\necho %s\n' "$os" > "$dir/uname"; chmod +x "$dir/uname"
  local n
  for n in "$@"; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/notified"\n' "$n" "$dir" > "$dir/$n"; chmod +x "$dir/$n"
  done
  printf '%s' "$dir"
}

HOOK_PATH="$PATH"
# hook <script> [VAR=value ...] — stdin passes through; stdout/stderr land in $TMP/out, $TMP/err.
hook() { local h="$1"; shift; env PATH="$HOOK_PATH" HOME="$HOOK_HOME" "$@" bash "$ROOT/hooks/$h" >"$TMP/out" 2>"$TMP/err"; echo $?; }
event_json() { printf '{"session_id":"s","transcript_path":"%s/t.jsonl","cwd":"%s","hook_event_name":"%s"%s}' "$TMP" "$2" "$1" "${3:-}"; }

# A real origin plus a clone whose origin/HEAD names main, so "merged" means what it means live.
mkrepo() {
  local d="$TMP/repos/$1"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/repo" 2>/dev/null
  echo base > "$d/repo/f"; git -C "$d/repo" add f; git -C "$d/repo" commit -qm base
  git -C "$d/repo" push -q origin main 2>/dev/null
  git -C "$d/repo" remote set-head origin main >/dev/null 2>&1
  printf '%s' "$d/repo"
}

echo "hooks-misc (reminder-instructions · notify-complete · worktree-cleanup)"

BASE_HOST="$(shim_path host osascript notify-send uname)"
BASE_NOJQ="$(shim_path nojq jq osascript notify-send uname)"
BASE_NEITHER="$(shim_path neither jq python3 osascript notify-send uname)"
check "the no-jq PATH really has no jq" "! PATH='$BASE_NOJQ' command -v jq >/dev/null"
check "the base PATHs carry no real notifier (nothing can reach the desktop)" \
  "! PATH='$BASE_HOST' command -v osascript >/dev/null && ! PATH='$BASE_HOST' command -v notify-send >/dev/null"

for mode in host nojq; do
  case "$mode" in host) BASE="$BASE_HOST";; nojq) BASE="$BASE_NOJQ";; esac
  echo " ── parser: $mode"
  HOOK_HOME="$TMP/home-$mode"; mkdir -p "$HOOK_HOME"
  QUIET="$(stub_dir "quiet-$mode" Linux)"          # no notifier anywhere on this PATH
  HOOK_PATH="$QUIET:$BASE"

  # ── reminder-instructions ─────────────────────────────────────────────────────────────────────
  rc="$(event_json UserPromptSubmit "$TMP" ',"prompt":"fix the build"' | hook reminder-instructions.sh)"
  check "[$mode] reminder: exit 0, nothing on stderr" "[ '$rc' = '0' ] && [ ! -s '$TMP/err' ]"
  check "[$mode] reminder: stdout is the structured UserPromptSubmit context shape" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); h=d[\"hookSpecificOutput\"]; sys.exit(0 if h[\"hookEventName\"]==\"UserPromptSubmit\" and \"autonomous\" in h[\"additionalContext\"] else 1)' '$TMP/out'"
  check "[$mode] reminder: carries NO block decision and no misplaced top-level context" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if set(d) & {\"decision\",\"continue\",\"additionalContext\"} else 0)' '$TMP/out'"
  rc="$(printf 'not json at all' | hook reminder-instructions.sh)"
  check "[$mode] reminder: garbage stdin still yields valid context and exit 0 (never blocks)" \
    "[ '$rc' = '0' ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$TMP/out'"

  # ── notify-complete ───────────────────────────────────────────────────────────────────────────
  MAC="$(stub_dir "mac-$mode" Darwin osascript)"
  HOOK_PATH="$MAC:$BASE"
  rc="$(event_json Stop "$TMP" ',"stop_hook_active":false' | hook notify-complete.sh)"
  check "[$mode] notify: on macOS it calls osascript with a completion message, exit 0" \
    "[ '$rc' = '0' ] && grep -q 'osascript .*Task complete' '$MAC/notified'"
  check "[$mode] notify: prints nothing on stdout (a Stop hook's stdout can be read as a decision)" "[ ! -s '$TMP/out' ]"
  LNX="$(stub_dir "linux-$mode" Linux notify-send)"
  HOOK_PATH="$LNX:$BASE"
  rc="$(event_json Stop "$TMP" ',"stop_hook_active":false' | hook notify-complete.sh)"
  check "[$mode] notify: on Linux it calls notify-send, exit 0" \
    "[ '$rc' = '0' ] && grep -q 'notify-send .*Task complete' '$LNX/notified'"
  HOOK_PATH="$QUIET:$BASE"
  rc="$(event_json Stop "$TMP" ',"stop_hook_active":false' | hook notify-complete.sh)"
  check "[$mode] notify: no notifier installed ⇒ silent no-op, exit 0 (never an error that blocks)" \
    "[ '$rc' = '0' ] && [ ! -e '$QUIET/notified' ] && [ ! -s '$TMP/out' ] && [ ! -s '$TMP/err' ]"
  NOOSA="$(stub_dir "mac-noosa-$mode" Darwin)"
  HOOK_PATH="$NOOSA:$BASE"
  rc="$(event_json Stop "$TMP" | hook notify-complete.sh)"
  check "[$mode] notify: macOS without osascript ⇒ exit 0, nothing recorded" "[ '$rc' = '0' ] && [ ! -e '$NOOSA/notified' ]"

  # ── worktree-cleanup ──────────────────────────────────────────────────────────────────────────
  NOTE="$(stub_dir "wt-$mode" Darwin osascript)"
  HOOK_PATH="$NOTE:$BASE"
  CLEAN_LOG="$HOOK_HOME/.claude/worktree-cleanup.log"
  DIRTY_LOG="$HOOK_HOME/.claude/worktree-needs-attention.log"

  # Known-good: a clean, merged, ephemeral worktree is removed with its branch. The cwd comes ONLY
  # from stdin — the hook is started from a directory that is not a repo, so reading $PWD instead
  # would do nothing and fail this case.
  R="$(mkrepo "clean-$mode")"
  W="$R/.claude/worktrees/done"
  git -C "$R" worktree add -q -b feat/done "$W" origin/main 2>/dev/null
  rc="$(cd "$TMP" && event_json SessionEnd "$W" ',"reason":"other"' | hook worktree-cleanup.sh)"
  check "[$mode] cleanup: exit 0" "[ '$rc' = '0' ]"
  check "[$mode] cleanup: a CLEAN merged ephemeral worktree named on stdin is removed" "[ ! -d '$W' ]"
  check "[$mode] cleanup: ...its merged branch is deleted too" "! git -C '$R' rev-parse --verify --quiet refs/heads/feat/done >/dev/null"
  check "[$mode] cleanup: ...and the removal is logged" "grep -q 'removed clean worktree: $W' '$CLEAN_LOG'"

  # Known-bad: uncommitted work in an ephemeral worktree is KEPT, logged, and notified.
  R="$(mkrepo "dirty-$mode")"
  W="$R/.claude/worktrees/wip"
  git -C "$R" worktree add -q -b feat/wip "$W" origin/main 2>/dev/null
  echo "unsaved" > "$W/new-file.txt"
  rc="$(cd "$TMP" && event_json SessionEnd "$W" ',"reason":"other"' | hook worktree-cleanup.sh)"
  check "[$mode] cleanup: a DIRTY ephemeral worktree is kept (exit $rc, never 2)" "[ '$rc' = '0' ] && [ -f '$W/new-file.txt' ]"
  check "[$mode] cleanup: ...the uncommitted file is named in the needs-attention log" "grep -q 'new-file.txt' '$DIRTY_LOG'"
  check "[$mode] cleanup: ...and a notification was raised" "grep -q 'osascript .*uncommitted/unpushed' '$NOTE/notified'"

  # Known-bad: a local-only commit with no upstream is unpushed work, not a clean tree.
  R="$(mkrepo "unpushed-$mode")"
  W="$R/.claude/worktrees/local"
  git -C "$R" worktree add -q -b feat/local "$W" main 2>/dev/null
  echo more >> "$W/f"; git -C "$W" commit -qam "local only"
  rc="$(cd "$TMP" && event_json SessionEnd "$W" | hook worktree-cleanup.sh)"
  check "[$mode] cleanup: an ephemeral worktree with an UNPUSHED commit is kept" \
    "[ '$rc' = '0' ] && [ -d '$W' ] && git -C '$R' rev-parse --verify --quiet refs/heads/feat/local >/dev/null"

  # Known-bad: a hand-made sibling worktree is never auto-removed, even when clean and merged.
  R="$(mkrepo "sibling-$mode")"
  W="$TMP/repos/sibling-$mode/elsewhere"
  git -C "$R" worktree add -q -b feat/sib "$W" origin/main 2>/dev/null
  rc="$(cd "$TMP" && event_json SessionEnd "$W" | hook worktree-cleanup.sh)"
  check "[$mode] cleanup: a clean merged SIBLING worktree is NOT removed" "[ '$rc' = '0' ] && [ -d '$W' ]"
  check "[$mode] cleanup: ...it is logged as reapable instead" "grep -q 'reapable sibling (not auto-removed): $W' '$CLEAN_LOG'"

  # The main worktree and the opt-out: nothing happens.
  R="$(mkrepo "main-$mode")"
  before="$(cat "$CLEAN_LOG" "$DIRTY_LOG" 2>/dev/null | wc -l)"
  rc="$(cd "$TMP" && event_json SessionEnd "$R" | hook worktree-cleanup.sh)"
  after="$(cat "$CLEAN_LOG" "$DIRTY_LOG" 2>/dev/null | wc -l)"
  check "[$mode] cleanup: the MAIN worktree is left alone and nothing is logged" "[ '$rc' = '0' ] && [ -d '$R/.git' ] && [ '$before' = '$after' ]"
  W="$R/.claude/worktrees/optout"
  git -C "$R" worktree add -q -b feat/optout "$W" origin/main 2>/dev/null
  rc="$(cd "$TMP" && event_json SessionEnd "$W" | hook worktree-cleanup.sh CLAUDE_WORKTREE_AUTOCLEAN=0)"
  check "[$mode] cleanup: CLAUDE_WORKTREE_AUTOCLEAN=0 leaves even a clean worktree in place" "[ '$rc' = '0' ] && [ -d '$W' ]"
  rc="$(cd "$TMP" && printf 'garbage' | hook worktree-cleanup.sh)"
  check "[$mode] cleanup: unparseable stdin from a non-repo directory is a no-op, exit 0" "[ '$rc' = '0' ]"
done

echo " ── parser: neither jq nor python3 (never blocks)"
HOOK_HOME="$TMP/home-neither"; mkdir -p "$HOOK_HOME"
HOOK_PATH="$(stub_dir quiet-neither Linux):$BASE_NEITHER"
rc="$(event_json UserPromptSubmit "$TMP" | hook reminder-instructions.sh)"
check "[neither] reminder exits 0" "[ '$rc' = '0' ]"
rc="$(event_json Stop "$TMP" | hook notify-complete.sh)"
check "[neither] notify exits 0" "[ '$rc' = '0' ]"
R="$(mkrepo neither)"; W="$R/.claude/worktrees/x"
git -C "$R" worktree add -q -b feat/x "$W" origin/main 2>/dev/null
rc="$(cd "$TMP" && event_json SessionEnd "$W" | hook worktree-cleanup.sh)"
check "[neither] cleanup exits 0 and, unable to read the cwd, removes nothing" "[ '$rc' = '0' ] && [ -d '$W' ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
