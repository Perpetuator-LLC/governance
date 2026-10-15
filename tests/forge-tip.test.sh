#!/usr/bin/env bash
# tests/forge-tip.test.sh — lib/forge-tip.sh, direct unit coverage.
#
# branch-reap, held-branches and orphan-check each source this library and already have their own
# fixtures exercising it indirectly (all of which set up origin/HEAD via `git clone`, so the LIVE
# ls-remote fallback path is only reachable through branch-reap's own "no origin" refusal case —
# never through a repo that genuinely has an origin whose local HEAD cache is merely unset). This
# file tests the library directly, including that fallback.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/forge-tip.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing"; exit 1; }
source "$LIB"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "── lib/forge-tip.sh"

# --- fixture: a bare origin, a clone with a commit on main --------------------------------------
O="$TMP/origin.git"; C="$TMP/clone"
git init -q --bare -b main "$O"
git clone -q "$O" "$C" 2>/dev/null
echo base > "$C/f"; git -C "$C" add f; git -C "$C" commit -qm base
git -C "$C" push -q origin main

# --- 1. forge_default_branch: cache hit (origin/HEAD set by clone) returns it, exit 0 ---
out="$(forge_default_branch "$C")"; rc=$?
[[ "$rc" == "0" && "$out" == "main" ]] && pass "cache hit: returns the clone-set origin/HEAD" \
  || fail "cache hit: rc=$rc out=$out"

# --- 2. forge_default_branch: cache UNSET, falls back to a live ls-remote --symref ---
git -C "$C" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
out="$(forge_default_branch "$C")"; rc=$?
[[ "$rc" == "0" && "$out" == "main" ]] && pass "cache unset: falls back to a live ls-remote --symref" \
  || fail "cache-unset fallback: rc=$rc out=$out"
# restore the cache for later checks
git -C "$C" remote set-head origin main >/dev/null 2>&1

# --- 3. forge_default_branch: a repo's default is NOT named main/master (the whole point of #228) ---
O2="$TMP/origin2.git"; C2="$TMP/clone2"
git init -q --bare -b trunk "$O2"
git clone -q "$O2" "$C2" 2>/dev/null
echo base > "$C2/f"; git -C "$C2" add f; git -C "$C2" commit -qm base
git -C "$C2" push -q origin trunk
git -C "$C2" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
out="$(forge_default_branch "$C2")"; rc=$?
[[ "$rc" == "0" && "$out" == "trunk" ]] && pass "a default branch named neither main nor master: resolved correctly, not guessed" \
  || fail "non-main/master default: rc=$rc out=$out"

# --- 4. forge_default_branch: no origin remote at all -> prints nothing, returns 1 ---
N="$TMP/noorigin"; git init -q -b main "$N"
out="$(forge_default_branch "$N")"; rc=$?
[[ "$rc" == "1" && -z "$out" ]] && pass "no origin remote: prints nothing, returns 1 (never a guess)" \
  || fail "no-origin: rc=$rc out='$out'"

# --- 5. forge_default_branch: origin points nowhere reachable -> fails closed, not a crash ---
B="$TMP/badorigin"; git init -q -b main "$B"
git -C "$B" remote add origin "$TMP/does-not-exist.git"
out="$(forge_default_branch "$B")"; rc=$?
[[ "$rc" == "1" && -z "$out" ]] && pass "an unreachable origin: prints nothing, returns 1" \
  || fail "unreachable origin: rc=$rc out='$out'"

# --- 6. forge_tip: the forge's current sha for an existing branch ---
want="$(git -C "$C" rev-parse main)"
out="$(forge_tip "$C" main)"; rc=$?
[[ "$rc" == "0" && "$out" == "$want" ]] && pass "forge_tip returns the forge's current sha for an existing branch" \
  || fail "forge_tip main: rc=$rc out=$out want=$want"

# --- 7. forge_tip: a branch the forge does not have -> nothing, returns 1 ---
out="$(forge_tip "$C" no-such-branch)"; rc=$?
[[ "$rc" == "1" && -z "$out" ]] && pass "forge_tip on a branch the forge lacks: prints nothing, returns 1" \
  || fail "forge_tip missing branch: rc=$rc out='$out'"

# --- 8. forge_tip: the forge has moved since the local clone's last fetch — the LIVE tip, not stale ---
O3="$TMP/origin3.git"; C3="$TMP/clone3"; C3b="$TMP/clone3b"
git init -q --bare -b main "$O3"
git clone -q "$O3" "$C3" 2>/dev/null
echo base > "$C3/f"; git -C "$C3" add f; git -C "$C3" commit -qm base; git -C "$C3" push -q origin main
git clone -q "$O3" "$C3b" 2>/dev/null   # a second clone, about to fall behind
echo more >> "$C3/f"; git -C "$C3" commit -qam more; git -C "$C3" push -q origin main
new_tip="$(git -C "$C3" rev-parse main)"
out="$(forge_tip "$C3b" main)"; rc=$?   # C3b never fetched the second push
[[ "$rc" == "0" && "$out" == "$new_tip" ]] && pass "forge_tip asks the forge live, not the clone's own stale cache" \
  || fail "forge_tip live-vs-stale: rc=$rc out=$out want=$new_tip"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
