#!/usr/bin/env bash
# settings-write-audit.test.sh — a permission rule silently stripped from settings must be NAMED
#
# The failure this instrument exists to catch is a rule VANISHING from
# settings.json with nothing red anywhere. So the test does not merely assert
# "an event was logged" — it builds a real git repo, commits a settings.json
# with a deny list, strips one rule the way the bug does, and asserts the audit
# log names the missing rule. A watcher that logs writes but cannot tell a
# strip from a harmless touch would pass a weaker test and be useless.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/bin/settings-write-audit.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The fixture repo is built from a known git config, never the developer's: an inherited commit
# signing setting that refuses makes the fixture commit fail, HEAD does not exist, and the reference
# the whole audit compares against cannot be read.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Block until an event actually appears in the log, rather than sleeping a fixed
# interval and hoping.
#
# A fixed `sleep 1` after backgrounding the watcher is a race: on a loaded machine, interpreter
# startup plus the `git` subprocesses in head_permissions() can outlast a fixed budget, so the
# watcher emits NOTHING before being killed — and every assertion in the block then fails without
# saying "the watcher never started", the only fact that mattered. The milder form of the same race
# lets the baseline land AFTER the mutation, so the baseline records the already-stripped file and
# no write is ever detected.
#
# Waiting on the artifact is both deterministic and faster in the common case.
wait_for() {  # wait_for <grep-pattern> <timeout-s> <description>
  local pat="$1" limit="$2" what="$3" waited=0 ticks=$(( $2 * 10 ))
  while ! grep -q "$pat" "$LOG" 2>/dev/null; do
    if [ "$waited" -ge "$ticks" ]; then
      bad "$what — timed out after ${limit}s (watcher pid ${WATCHER:-?})"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

echo "settings-write-audit"

# --- exec bit: a handed-over ./script that is not executable is a defect ------
check "the script is executable" "[ -x '$AUDIT' ]"

# --- build a throwaway repo whose HEAD carries the reference deny list -------
FAKE="$TMP/repo"
mkdir -p "$FAKE/global"
cat > "$FAKE/global/settings.json" <<'JSON'
{
  "permissions": {
    "deny": ["Bash(rm -rf /)", "Bash(git push --force)", "Bash(curl-pipe-sh)"],
    "allow": ["Bash(ls)", "Bash(cat)"]
  }
}
JSON
git -C "$FAKE" init -q
git -C "$FAKE" add global/settings.json
git -C "$FAKE" commit -qm "reference settings"

TARGET="$FAKE/global/settings.json"
LINK="$TMP/settings.json"
LOG="$TMP/audit.jsonl"
ln -sf "$TARGET" "$LINK"

# TARGET is deliberately NOT exported: the default must resolve it from the link, which is the
# common install shape (a live settings path symlinked into a config repo).
unset SETTINGS_AUDIT_TARGET
export SETTINGS_AUDIT_LINK="$LINK"
export SETTINGS_AUDIT_LOG="$LOG"
export SETTINGS_AUDIT_INTERVAL=0.3

# --- oneshot baseline --------------------------------------------------------
"$AUDIT" --oneshot >/dev/null 2>&1
check "oneshot writes a baseline event" \
  "grep -q '\"event\": \"baseline\"' '$LOG'"
check "baseline counts the committed deny rules (3)" \
  "python3 -c \"
import json,sys
r=[json.loads(l) for l in open('$LOG')][0]
sys.exit(0 if r['target']['counts'].get('deny')==3 else 1)\""
check "the target is resolved from the link when not given" \
  "grep -q '\"target\": \"$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$TARGET")\"' '$LOG'"
# A NEGATIVE assertion an empty or broken reference would also satisfy — so the reference is proven
# readable first (counts present, no UNDETERMINED), and only then does "nothing missing" mean clean.
check "a healthy baseline reports nothing missing vs HEAD (reference proven readable)" \
  "grep -q '\"deny\": 3' '$LOG' && ! grep -q 'UNDETERMINED' '$LOG' && ! grep -q 'missing_vs_head' '$LOG'"

# --- the real failure mode: a rule is silently stripped ----------------------
: > "$LOG"
"$AUDIT" >/dev/null 2>&1 &
WATCHER=$!
# The baseline must be on disk BEFORE the mutation, or the baseline snapshots the
# already-stripped file and there is no write left to detect.
wait_for '"event": "baseline"' 20 "watcher reached baseline before the mutation"

python3 - "$TARGET" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
# strip exactly one deny rule, leaving valid JSON — the bug's signature
d["permissions"]["deny"] = [r for r in d["permissions"]["deny"] if "force" not in r]
json.dump(d, open(p, "w"), indent=2)
PY

wait_for '"event": "target_write"' 20 "watcher observed the strip"
kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null

check "the strip is recorded as a target_write" \
  "grep -q '\"event\": \"target_write\"' '$LOG'"
check "content_changed is true (not a bare touch)" \
  "grep -q '\"content_changed\": true' '$LOG'"
check "the MISSING rule is named in the log" \
  "grep -q 'missing_vs_head' '$LOG' && grep -q 'git push --force' '$LOG'"
check "deny count dropped 3 -> 2 in the same record" \
  "python3 -c \"
import json,sys
recs=[json.loads(l) for l in open('$LOG')]
w=[r for r in recs if r['event']=='target_write']
sys.exit(0 if w and w[-1]['before']['counts']['deny']==3 and w[-1]['after']['counts']['deny']==2 else 1)\""

# --- the symlink surface must not be confused with the file surface ----------
# The classic misreading: an installer recreating the link logged as a settings
# rewrite. They must be distinguishable events.
: > "$LOG"
"$AUDIT" >/dev/null 2>&1 &
WATCHER=$!
wait_for '"event": "baseline"' 20 "watcher reached baseline before the relink"
ln -sf "$TARGET" "$LINK"          # recreate the link; target untouched
wait_for '"event": "symlink_recreated"' 20 "watcher observed the relink"
kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null

check "recreating the symlink logs symlink_recreated" \
  "grep -q '\"event\": \"symlink_recreated\"' '$LOG'"
# ⚠️ This one is a NEGATIVE assertion, so an empty log satisfies it — it passes
# for the wrong reason whenever the watcher never started at all. Requiring the symlink_recreated event alongside it means the watcher is proven
# to have been running and looking; only then does "no target_write" mean
# anything. A negative assertion that a dead instrument satisfies is
# absence-as-health.
check "...and does NOT log it as a target_write" \
  "grep -q '\"event\": \"symlink_recreated\"' '$LOG' && ! grep -q '\"event\": \"target_write\"' '$LOG'"

# --- the log must be durable and append-only --------------------------------
before=$(wc -l < "$LOG")
"$AUDIT" --oneshot >/dev/null 2>&1
after=$(wc -l < "$LOG")
check "the log appends rather than truncating" "[ '$after' -gt '$before' ]"
check "--status summarises without error" \
  "'$AUDIT' --status >/dev/null 2>&1"

# --- a target outside any git repo: the reference is UNDETERMINED, never "clean" ---
mkdir -p "$TMP/norepo"
cp "$TARGET" "$TMP/norepo/settings.json"
NOLOG="$TMP/norepo.jsonl"
SETTINGS_AUDIT_LINK="$TMP/norepo/settings.json" SETTINGS_AUDIT_LOG="$NOLOG" "$AUDIT" --oneshot >/dev/null 2>&1
check "a target outside any git repo reports missing_vs_head UNDETERMINED, not an all-clear" \
  "grep -q '\"missing_vs_head\": \"UNDETERMINED\"' '$NOLOG' && grep -q 'head_reference_error' '$NOLOG'"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
