#!/usr/bin/env bash
# tests/token-usage.test.sh — the token roll-up must never produce a SILENT WRONG NUMBER.
#
# Every assertion constructs its defect first, because the
# failure mode that matters here is a SILENT WRONG NUMBER: a roll-up that quietly skips records,
# or reports 0 when it found nothing, is worse than no instrument — it turns "we are getting
# worse" into a settled question with the wrong answer.
#
# Run:  bash tests/token-usage.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/token-usage.py"
[[ -x "$BIN" ]] || { echo "FAIL: $BIN missing or not executable"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tokusage.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "── token-usage"

# Seat names are derived from the transcript directory with the encoded HOME stripped (every
# non-alphanumeric character becomes '-', as the harness names these directories). HOME is read, not
# overridden: an interpreter shim can depend on it.
ENC="$(python3 -c 'import os,re; print(re.sub(r"[^A-Za-z0-9]", "-", os.path.expanduser("~")))')"
P="${ENC}-projects-"

mkdir -p "$TMP/proj/${P}seatA" "$TMP/proj/${P}seatB"
turn() { # turn <file> <day> <in> <out> <cache_write> <cache_read>
  printf '{"timestamp":"%sT10:00:00Z","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$2" "$3" "$4" "$5" "$6" >> "$1"
}
A="$TMP/proj/${P}seatA/t.jsonl"
B="$TMP/proj/${P}seatB/t.jsonl"
# seatA: context 100k+0 = 100k per turn -> UNDER a 250k ceiling
for _ in 1 2 3; do turn "$A" 2030-01-15 10 20 100000 0; done
# seatB: context 300k+100k = 400k per turn -> OVER
for _ in 1 2 3; do turn "$B" 2030-01-15 10 20 100000 300000; done

out=$("$BIN" --root "$TMP/proj" --json 2>/dev/null)
get() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" <<<"$out"; }

[[ "$(get 'd["scan"]["turns"]')" == "6" ]] && pass "counts every usage record (6 turns)" \
  || fail "turn count wrong: $(get 'd["scan"]["turns"]')"

# BILLED excludes cache_read on purpose: folding it in makes a well-cached day look like a
# runaway, and that is the exact confusion the KPI exists to remove.
# 6 turns x (10 in + 20 out + 100000 cache_write) = 600,180
[[ "$(get 'd["days"][0]["billed"]')" == "600180" ]] \
  && pass "billed = input+output+cache_creation, EXCLUDING cache_read" \
  || fail "billed wrong: $(get 'd["days"][0]["billed"]') (want 600180)"
[[ "$(get 'd["days"][0]["cache_read"]')" == "900000" ]] \
  && pass "cache_read is reported separately, not folded into billed" \
  || fail "cache_read wrong: $(get 'd["days"][0]["cache_read"]')"

# CONTEXT = cache_read + cache_creation — what the model saw, not what was billed.
[[ "$(get '[s["p50"] for s in d["seats"] if s["seat"]=="seatB"][0]')" == "400000" ]] \
  && pass "context per turn = cache_read + cache_creation" \
  || fail "seatB p50 wrong: $(get '[s["p50"] for s in d["seats"] if s["seat"]=="seatB"][0]')"

# A HALF-WRITTEN FINAL LINE IS THE NORMAL CASE — transcripts are appended to while this runs.
# It must be counted and survived, never aborted on and never silently dropped.
printf '{"timestamp":"2030-01-15T10:00:00Z","message":{"usage":{"input_to' >> "$A"
out=$("$BIN" --root "$TMP/proj" --json 2>/dev/null)
[[ "$(get 'd["scan"]["turns"]')" == "6" ]] && pass "a truncated final line does not corrupt totals" \
  || fail "truncated line changed the totals"
[[ "$(get 'd["scan"]["unparseable"]')" == "1" ]] \
  && pass "...and it is COUNTED, not silently dropped" \
  || fail "unparseable not reported: $(get 'd["scan"]["unparseable"]')"

out=$("$BIN" --root "$TMP/proj" --alarm-p50 350000 --json 2>/dev/null)
over=$(get '[s["seat"] for s in d["rotate"]]')
[[ "$over" == "['seatB']" ]] && pass "only the seat above the ROTATE alarm is flagged" \
  || fail "rotate list wrong: $over"
# TWO TIERS: above-target is PROGRESS, never an action row. seatA is 100k (under both);
# seatB is 400k (over target AND over alarm). A seat between the two must appear in
# above_target and NOT in rotate — collapsing them is the defect the tiers exist to fix.
mkdir -p "$TMP/proj/${P}seatC"
C="$TMP/proj/${P}seatC/t.jsonl"
for _ in 1 2 3; do turn "$C" 2030-01-15 10 20 300000 0; done   # 300k: > target, < alarm
out=$("$BIN" --root "$TMP/proj" --json 2>/dev/null)
[[ "$(get '"seatC" in [s["seat"] for s in d["rotate"]]')" == "False" ]] \
  && pass "a seat between target and alarm is NOT a rotate row" \
  || fail "seatC wrongly flagged for rotation"
[[ "$(get '"seatC" in d["above_target"]')" == "True" ]] \
  && pass "...but IS counted against the target" \
  || fail "seatC missing from above_target"
# The MAX limb: a healthy median hides a turn that nearly filled the window.
mkdir -p "$TMP/proj/${P}seatD"
D="$TMP/proj/${P}seatD/t.jsonl"
turn "$D" 2030-01-15 10 20 100000 0; turn "$D" 2030-01-15 10 20 700000 0; turn "$D" 2030-01-15 10 20 100000 0
out=$("$BIN" --root "$TMP/proj" --json 2>/dev/null)
[[ "$(get '"seatD" in [s["seat"] for s in d["rotate"]]')" == "True" ]] \
  && pass "a low-p50 seat with one huge turn still trips the max limb" \
  || fail "max limb did not fire for seatD"

# --- governance#32: the ceiling is a property of ONE THREAD. A clear starts a new transcript in the
# same directory; grouping by directory blended the pre-clear tail into the live thread and raised
# ROTATE right after the seat had rotated. Replay a clear-day: pre-clear thread hot, post-clear cool.
mkdir -p "$TMP/clr/${P}seatR"
tturn() { # tturn <file> <iso-time> <context>
  printf '{"timestamp":"%s","message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s}}}\n' "$2" "$3" >> "$1"
}
for h in 09 10 11; do tturn "$TMP/clr/${P}seatR/before.jsonl" "2030-02-01T${h}:00:00Z" 700000; done
for h in 13 14; do tturn "$TMP/clr/${P}seatR/after.jsonl" "2030-02-01T${h}:00:00Z" 120000; done
out=$("$BIN" --root "$TMP/clr" --json 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$(get 'd["rotate"]')" == "[]" ]] \
  && pass "clear-day replay: the live (post-clear) thread is under the alarm, so no ROTATE (the hand result)" \
  || fail "clear-day replay raised ROTATE (rc=$rc): $(get 'd["rotate"]')"
[[ "$(get 'sorted((s["transcript"], s["rotated"]) for s in d["seats"])')" == "[('after', False), ('before', True)]" ]] \
  && pass "the pre-clear thread is listed and marked rotated; the ceiling is keyed per transcript" \
  || fail "per-transcript rows wrong: $(get 'sorted((s["transcript"], s["rotated"]) for s in d["seats"])')"
[[ "$(get '[s["transcripts_that_day"] for s in d["seats"] if not s["rotated"]][0]')" == "2" ]] \
  && pass "a multi-transcript day is visibly marked (2 threads)" || fail "multi-transcript day not marked"
"$BIN" --root "$TMP/clr" 2>/dev/null | grep -q '↻ 2 threads today' \
  && pass "…and the text report says so" || fail "text report does not mark the rotation"
# Positive control: the SAME hot thread alone must still raise ROTATE.
mkdir -p "$TMP/hot/${P}seatR"; cp "$TMP/clr/${P}seatR/before.jsonl" "$TMP/hot/${P}seatR/"
"$BIN" --root "$TMP/hot" --json >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "control: the hot thread on its own still raises ROTATE (exit 1)" || fail "control: hot thread did not alarm"
# --since restricts the scan to turns at or after the clear.
out=$("$BIN" --root "$TMP/clr" --since 2030-02-01T12:00 --json 2>/dev/null)
[[ "$(get 'd["scan"]["turns"]')" == "2" && "$(get '[s["transcript"] for s in d["seats"]]')" == "['after']" ]] \
  && pass "--since keeps only turns at or after the given time" || fail "--since wrong: turns=$(get 'd["scan"]["turns"]')"
"$BIN" --root "$TMP/clr" --since yesterday >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "--since refuses a non-ISO value (exit 2)" || fail "--since accepted a non-ISO value"

# Exit code must separate "clean" from "over ceiling" — a tool that always exits 0 cannot gate.
"$BIN" --root "$TMP/proj" --alarm-p50 999999999 --alarm-max 999999999 >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "no seat over the alarm exits 0" || fail "clean run did not exit 0"
"$BIN" --root "$TMP/proj" --alarm-p50 250000 >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "a seat over the alarm exits 1" || fail "over-ceiling run did not exit 1"

# AN EMPTY RESULT IS NOT ZERO USAGE. A wrong --root must refuse, not report a clean result —
# "0 tokens" is the most reassuring possible wrong answer.
mkdir -p "$TMP/empty"
"$BIN" --root "$TMP/empty" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "an empty scan REFUSES (exit 2) rather than reporting 0" \
  || fail "empty scan did not exit 2 — it would report clean usage"
"$BIN" --root "$TMP/nonexistent" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "a missing root exits 2" || fail "missing root did not exit 2"

# SEAT NAMING: the encoded home (and a following `projects-`) is stripped; anything else is kept whole
# rather than guessed at, so two different directories can never collapse into one seat.
mkdir -p "$TMP/names/${ENC}-projects-alpha" "$TMP/names/${ENC}-beta" "$TMP/names/-srv-work-gamma"
turn "$TMP/names/${ENC}-projects-alpha/t.jsonl" 2030-01-15 1 1 1 1
turn "$TMP/names/${ENC}-beta/t.jsonl" 2030-01-15 1 1 1 1
turn "$TMP/names/-srv-work-gamma/t.jsonl" 2030-01-15 1 1 1 1
out=$("$BIN" --root "$TMP/names" --json 2>/dev/null)
[[ "$(get 'sorted(s["seat"] for s in d["seats"])')" == "['-srv-work-gamma', 'alpha', 'beta']" ]] \
  && pass "seat = directory minus the encoded home; a directory outside home is kept whole" \
  || fail "seat naming wrong: $(get 'sorted(s["seat"] for s in d["seats"])')"

echo
[[ $fails -eq 0 ]] && echo "All assertions passed." || echo "$fails assertion(s) FAILED."
exit $((fails > 0))
