#!/usr/bin/env bash
# tests/fleet-idle.test.sh — the fleet-idle check fires ONCE when every lane is idle for two windows
# while a marker says it should be working, and is silent otherwise (#170). Times are fixed with
# GIT_COMMITTER_DATE and --now, so every expected value below is derived by hand.
#
# T0 = 2026-10-02T04:00:00Z, window 30 min, consecutive 2, K = every readable lane (2).
# Lanes alpha and beta: commits at T0-60m, T0-30m and T0-1m (alpha also a "vault backup (timer)" commit
# at T0+45m, which --ignore-subject discounts); both resume at T0+180m.
#   live, marker until T0+5h, state file:
#     now T0+30m  -> idle 2/2, streak 1            -> silent (exit 0)
#     now T0+60m  -> idle 2/2, streak 2            -> FIRES (exit 1), one FINDING per lane
#     now T0+90m  -> still idle                    -> silent, "already reported" (exit 0)
#     now T0+180m -> both active                   -> silent, reset (exit 0)
#   no marker, or marker expired, or idle with the timer commit counted -> silent
#   a marker that will not parse -> exit 2; a list naming no readable repo -> exit 2
#   replay T0-90m .. T0+210m -> STALL T0 → T0+150m (windows ending T0+30 … T0+150: 5), exit 1
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FI="$ROOT/bin/fleet-idle"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-idle.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com; git config --global user.name test
git config --global init.defaultBranch main; git config --global commit.gpgsign false
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

t() { python3 -c 'import datetime as d,sys; b=d.datetime(2026,10,2,4,0,tzinfo=d.timezone.utc); print((b+d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
commit_at() {  # commit_at REPO MINUTES SUBJECT
  echo "$2 $3" >> "$1/log.txt"; git -C "$1" add log.txt
  GIT_COMMITTER_DATE="$(t "$2")" GIT_AUTHOR_DATE="$(t "$2")" git -C "$1" commit -qm "$3"
}
mklane() {
  git init -q --bare "$TMP/$1.git"; git clone -q "$TMP/$1.git" "$TMP/$1" 2>/dev/null
  for m in -60 -30 -1; do commit_at "$TMP/$1" "$m" "work $m"; done
}
mklane alpha; mklane beta
commit_at "$TMP/alpha" 45 "vault backup (timer): snapshot"
git -C "$TMP/alpha" push -q origin HEAD:main; git -C "$TMP/beta" push -q origin HEAD:main
printf '%s\n%s\n' "$TMP/alpha" "$TMP/beta" > "$TMP/repos"
IGN='^vault backup \(timer\)'
run() { "$FI" --repos-from "$TMP/repos" --no-fetch --ignore-subject "$IGN" "$@" > "$TMP/out" 2>&1; echo $? > "$TMP/rc"; }
rc() { cat "$TMP/rc"; }

echo "── fleet-idle"
t5=$(t 300); echo "$t5" > "$TMP/marker"; S="$TMP/state.json"
run --marker "$TMP/marker" --state "$S" --now "$(t 30)"
[ "$(rc)" = 0 ] && ! grep -q FINDING "$TMP/out" && pass "first idle window: streak 1, silent" || fail "window 1: rc $(rc) $(cat "$TMP/out")"
run --marker "$TMP/marker" --state "$S" --now "$(t 60)"
[ "$(rc)" = 1 ] && [ "$(grep -c '^FINDING idle' "$TMP/out")" = 2 ] && grep -q 'FINDING idle alpha' "$TMP/out" && grep -q 'FINDING idle beta' "$TMP/out" \
  && pass "known-bad: two idle windows with the marker set FIRES, one finding per lane" || fail "window 2: rc $(rc) $(cat "$TMP/out")"
run --marker "$TMP/marker" --state "$S" --now "$(t 90)"
[ "$(rc)" = 0 ] && ! grep -q FINDING "$TMP/out" && grep -q 'already reported' "$TMP/out" \
  && pass "fires ONCE: the third idle window is silent" || fail "window 3: rc $(rc) $(cat "$TMP/out")"
commit_at "$TMP/alpha" 170 "resume"; commit_at "$TMP/beta" 175 "resume"
git -C "$TMP/alpha" push -q origin HEAD:main; git -C "$TMP/beta" push -q origin HEAD:main
run --marker "$TMP/marker" --state "$S" --now "$(t 180)"
[ "$(rc)" = 0 ] && grep -q '0 idle' "$TMP/out" && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["fired_at"] is None else 1)' "$S" \
  && pass "known-good: work resumes, silent, and the fired flag resets" || fail "window 4: rc $(rc) $(cat "$TMP/out")"

rm -f "$S"; run --state "$S" --now "$(t 60)"
[ "$(rc)" = 0 ] && grep -q 'no marker' "$TMP/out" && pass "known-good: no marker, silent however idle" || fail "no marker: $(cat "$TMP/out")"
echo "$(t 10)" > "$TMP/marker-old"; run --marker "$TMP/marker-old" --state "$S" --now "$(t 60)"
[ "$(rc)" = 0 ] && grep -q 'marker expired' "$TMP/out" && pass "known-good: an expired marker is silent" || fail "expired: $(cat "$TMP/out")"
rm -f "$S"; "$FI" --repos-from "$TMP/repos" --no-fetch --marker "$TMP/marker" --state "$S" --now "$(t 60)" > "$TMP/out" 2>&1
head -1 "$TMP/out" | grep -q ' · 1 idle · ' \
  && pass "without --ignore-subject the timer commit counts as work: only beta is idle (1 of 2)" \
  || fail "timer commit not counted when not ignored: $(head -1 "$TMP/out")"
echo "next week" > "$TMP/marker-bad"; run --marker "$TMP/marker-bad" --state "$S" --now "$(t 60)"
[ "$(rc)" = 2 ] && pass "a marker that will not parse is an instrument fault, not 'no marker'" || fail "bad marker rc $(rc)"
echo "$TMP/no-such-repo" > "$TMP/repos-bad"
"$FI" --repos-from "$TMP/repos-bad" --no-fetch --marker "$TMP/marker" --now "$(t 60)" >/dev/null 2>&1
[ $? = 2 ] && pass "no readable lane is an instrument fault" || fail "unreadable fleet did not exit 2"

"$FI" --repos-from "$TMP/repos" --no-fetch --ignore-subject "$IGN" --replay "$(t -90)" "$(t 210)" > "$TMP/out" 2>&1; rc=$?
[ $rc = 1 ] && grep -q "STALL $(t 0) → $(t 150) · 5 window(s) · idle throughout: alpha, beta" "$TMP/out" \
  && pass "replay reports the stall span by hand: T0 → T0+150m, 5 windows" || fail "replay: rc $rc $(cat "$TMP/out")"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; else echo "  ❌ $fails failed"; fi
exit $(( fails > 0 ))
