#!/usr/bin/env bash
# tests/script-audit.test.sh — hooks/script-audit.sh: a PreToolUse[Bash] AUDIT recorder.
#
# This hook never blocks (contract: exit 0 always, nothing to stdout — the script content must not
# re-enter the agent context). So the property worth pinning is not "did it refuse" but "did it
# actually capture the right file, and only the right file, into the log" — every interpreter form,
# every recognised extension, dedup, rotation, and the legacy env-var fallback this whole hook family
# shares with bash-safety-gate.sh (hook-input.test.sh covers that fallback only for the safety gates,
# not for this one).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/script-audit.sh"
[[ -x "$HOOK" ]] || { echo "FAIL: $HOOK missing or not executable"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

# Harness-shaped stdin: {"tool_name":"Bash","tool_input":{"command":"..."}}
bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")"; }

run() {  # run <home> <command-string> -> rc; stdout/stderr captured to $TMP/out,$TMP/err
  local home="$1" cmd="$2"
  bash_json "$cmd" | HOME="$home" env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"
  echo $?
}
logged() { grep -qF "$2" "$1/.claude/audit/scripts.log" 2>/dev/null; }  # logged <home> <marker>

echo "script-audit"

# --- every interpreter form individually, not just bash -----------------------------------------
n=0
for interp in bash sh zsh dash python python2 python3 node; do
  n=$((n+1))
  h="$TMP/home-interp-$n"; mkdir -p "$h"
  f="$TMP/job-$n.task"; printf 'marker-interp-%s\n' "$interp" > "$f"
  rc=$(run "$h" "$interp $f")
  [ "$rc" = 0 ] && logged "$h" "marker-interp-$interp" \
    && ok "interpreter '$interp <file>': captured" \
    || bad "interpreter '$interp <file>': NOT captured (rc=$rc)"
done

# --- source / '.' dot-sourcing: RECORDED, but hash-only (governance#274) ---------------------------
# A sourced file is how dotenv secrets get loaded, so its content is never copied: the record names
# the path with its sha256 and size, and the body stays out of the log.
for interp in source .; do
  n=$((n+1))
  h="$TMP/home-src-$n"; mkdir -p "$h"
  f="$TMP/job-$n.task"; printf 'marker-source-%s\n' "$n" > "$f"
  rc=$(run "$h" "$interp $f")
  [ "$rc" = 0 ] && logged "$h" "script=$f | sha256=" && logged "$h" "content withheld (sourced)" \
    && ! logged "$h" "marker-source-$n" \
    && ok "'$interp <file>' (dot-sourcing): recorded hash-only, content not copied" \
    || bad "'$interp <file>' not recorded hash-only (rc=$rc)"
done

# --- an interpreter FLAG does not break arming: 'bash -x foo.sh' still captures foo.sh -----------
h="$TMP/home-flag"; mkdir -p "$h"
f="$TMP/flagged.sh"; echo 'marker-flag' > "$f"
rc=$(run "$h" "bash -x $f")
[ "$rc" = 0 ] && logged "$h" "marker-flag" \
  && ok "an interpreter flag (bash -x foo.sh) does not break capture" \
  || bad "a flagged invocation was not captured"

# --- direct execution and bare recognisable extensions, one per extension -----------------------
for ext in sh py js mjs cjs ts; do
  n=$((n+1))
  h="$TMP/home-ext-$n"; mkdir -p "$h"
  f="$TMP/direct-$n.$ext"; printf 'marker-ext-%s\n' "$ext" > "$f"
  rc=$(run "$h" "$f")
  [ "$rc" = 0 ] && logged "$h" "marker-ext-$ext" \
    && ok "direct execution of a bare '.$ext' file: captured" \
    || bad "direct execution of a bare '.$ext' file NOT captured"
done

# --- the literal './' and '../' prefixes specifically (relative direct execution) -----------------
h="$TMP/home-relprefix"; mkdir -p "$h" "$TMP/reldir/sub"
echo 'marker-relself' > "$TMP/reldir/self.sh"
echo 'marker-relparent' > "$TMP/reldir/parent.sh"
rc=$( (cd "$TMP/reldir" && bash_json "./self.sh" | HOME="$h" env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"); echo $? )
[ "$rc" = 0 ] && logged "$h" "marker-relself" \
  && ok "'./self.sh' (relative, same dir): captured" || bad "'./self.sh' NOT captured"
rc=$( (cd "$TMP/reldir/sub" && bash_json "../parent.sh" | HOME="$h" env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"); echo $? )
[ "$rc" = 0 ] && logged "$h" "marker-relparent" \
  && ok "'../parent.sh' (relative, parent dir): captured" || bad "'../parent.sh' NOT captured"

# --- an UNRECOGNISED extension is never captured (control) ---------------------------------------
h="$TMP/home-unrec"; mkdir -p "$h"
f="$TMP/plain.txt"; echo 'marker-unrec' > "$f"
rc=$(run "$h" "./$f")
[ "$rc" = 0 ] && ! logged "$h" "marker-unrec" \
  && ok "an unrecognised extension (.txt) is never captured" \
  || bad "an unrecognised extension was captured"

# --- a file that does not resolve (missing, or an unexpanded var) is skipped SILENTLY ------------
h="$TMP/home-missing"; mkdir -p "$h"
rc=$(run "$h" "bash $TMP/does-not-exist.sh")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && ! logged "$h" "" \
  && ok "a missing file is skipped silently (exit 0, nothing logged, nothing printed)" \
  || bad "a missing file was not skipped cleanly (rc=$rc)"

# --- a file that EXISTS but is not READABLE is skipped silently (distinct from "missing") --------
# Checked by the ABSENCE OF A LOG ENTRY ENTIRELY (not just the marker text): without the -r check,
# shasum/cat both fail on the unreadable file, but the header/footer lines still get written around
# the empty content — a malformed entry, not nothing. "no marker text" alone cannot tell that apart
# from "no entry at all", so this asserts the stronger, correct claim: `script=<path>` never appears.
# Root ignores mode bits (CAP_DAC_OVERRIDE), so chmod 000 alone hides nothing from it, and CI runs
# the suites as root. Under root the hook runs with those capabilities dropped: still uid 0 and still
# the owner of $TMP, but now the owner bits (000) apply. The probe proves the file is unreadable to
# the hook before the case counts; a probe that cannot run reports NOT CHECKED as a failure.
nodac=()
[ "$(id -u)" = 0 ] && nodac=(setpriv --inh-caps=-dac_override,-dac_read_search \
                                     --bounding-set=-dac_override,-dac_read_search --)
h="$TMP/home-unreadable"; mkdir -p "$h"
f="$TMP/unreadable.sh"; echo 'marker-unreadable' > "$f"; chmod 000 "$f"
probe=$(${nodac[@]+"${nodac[@]}"} bash -c '[[ -r "$1" ]] && echo readable || echo unreadable' _ "$f" 2>/dev/null)
if [ "$probe" != unreadable ]; then
  bad "could not make a file unreadable to the hook (uid $(id -u), probe: '${probe:-did not run}'): the -r leg is NOT CHECKED"
else
  rc=$(bash_json "bash $f" | HOME="$h" env -u CLAUDE_TOOL_INPUT ${nodac[@]+"${nodac[@]}"} bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; echo $?)
  [ "$rc" = 0 ] && ! grep -qF "script=$f " "$h/.claude/audit/scripts.log" 2>/dev/null \
    && ok "a file that exists but is not readable gets NO log entry at all, not a malformed one" \
    || bad "an unreadable file produced a log entry (or the hook misbehaved)"
fi
chmod 644 "$f"  # restore so the trap's rm -rf can clean it up without a permission fight

# --- separators split multiple commands in ONE call, both captured ------------------------------
h="$TMP/home-multi"; mkdir -p "$h"
f1="$TMP/multi1.sh"; echo 'marker-multi-1' > "$f1"
f2="$TMP/multi2.sh"; echo 'marker-multi-2' > "$f2"
rc=$(run "$h" "bash $f1; bash $f2")
[ "$rc" = 0 ] && logged "$h" "marker-multi-1" && logged "$h" "marker-multi-2" \
  && ok "two commands separated by ';' both captured in one call" \
  || bad "a multi-command line did not capture both scripts"

# --- dedup: the SAME file twice in one command logs it only ONCE ---------------------------------
h="$TMP/home-dedup"; mkdir -p "$h"
f="$TMP/dedup.sh"; echo 'marker-dedup' > "$f"
rc=$(run "$h" "bash $f; bash $f")
n_logged=$(grep -c "script=$f " "$h/.claude/audit/scripts.log" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && [ "$n_logged" = 1 ] \
  && ok "the same file cited twice in one command is logged exactly once (dedup)" \
  || bad "dedup failed: logged $n_logged time(s), expected 1"

# --- never a gate: exit 0 regardless, and NOTHING on stdout once a real candidate is captured ----
h="$TMP/home-stdout"; mkdir -p "$h"
f="$TMP/stdout-check.sh"; echo 'marker-stdout' > "$f"
rc=$(run "$h" "bash $f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] \
  && ok "even when a script IS captured, stdout stays empty (content never re-enters agent context)" \
  || bad "stdout was non-empty after a real capture"

# --- the legacy CLAUDE_TOOL_INPUT fallback, shared with the safety gates but untested for THIS hook ---
h="$TMP/home-legacy"; mkdir -p "$h"
f="$TMP/legacy.sh"; echo 'marker-legacy' > "$f"
rc=$(CLAUDE_TOOL_INPUT="$(python3 -c 'import json,sys;print(json.dumps({"command": sys.argv[1]}))' "bash $f")" \
     HOME="$h" bash "$HOOK" </dev/null >"$TMP/out" 2>"$TMP/err"; echo $?)
[ "$rc" = 0 ] && logged "$h" "marker-legacy" \
  && ok "the legacy \$CLAUDE_TOOL_INPUT env var is still honoured as a fallback" \
  || bad "the legacy env-var fallback did not capture the script"

# --- no input at all: exit 0, nothing logged, nothing printed ------------------------------------
h="$TMP/home-noinput"; mkdir -p "$h"
rc=$(HOME="$h" env -u CLAUDE_TOOL_INPUT bash "$HOOK" </dev/null >"$TMP/out" 2>"$TMP/err"; echo $?)
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -d "$h/.claude/audit" ] \
  && ok "no input at all: exit 0, nothing logged, nothing printed" \
  || bad "no-input case misbehaved (rc=$rc)"

# --- a payload naming ANOTHER tool is not this hook's concern, but note this hook reads ANY .command ---
# (unlike the safety gates it is not tool-name-scoped — it is wired only on PreToolUse[Bash] by the
# settings layer, so this is documenting current behaviour, not asserting a refusal it doesn't make)

# --- the AUDIT_DIR is created 0700 -----------------------------------------------------------------
h="$TMP/home-perm"; mkdir -p "$h"
f="$TMP/perm.sh"; echo 'marker-perm' > "$f"
run "$h" "bash $f" >/dev/null
dmode=$(stat -c '%a' "$h/.claude/audit" 2>/dev/null || stat -f '%Lp' "$h/.claude/audit")
[ "$dmode" = "700" ] && ok "the audit directory is created 0700" || bad "audit dir is $dmode, not 700"

# --- rotation at ~5MB: a log already over the threshold is rotated to .1, and a fresh line starts ---
# Each fixture opens with a FRESH, parseable entry header, so only the SIZE rule can fire: a log with no
# parseable first timestamp rotates fail-closed, which made the boundary control below rotate on Linux.
# Built by the shell, not python3: a native Windows python cannot open a POSIX /tmp path, so there the
# fixture silently never existed and the boundary control passed without testing anything.
fill_log() {  # fill_log <path> <exact-bytes>: a fresh header line, padded with 'x' to exactly N bytes
  local hdr; hdr="===== $(date -u +%Y-%m-%dT%H:%M:%SZ) | cwd=/ | script=/fixture.sh | sha256=0 ====="
  { printf '%s\n' "$hdr"; head -c "$(( $2 - ${#hdr} - 1 ))" /dev/zero | tr '\0' x; } > "$1"
  [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || { echo "fixture $1 is not $2 bytes" >&2; exit 1; }
}
h="$TMP/home-rotate"; mkdir -p "$h/.claude/audit"
LOG="$h/.claude/audit/scripts.log"
fill_log "$LOG" $((5242880 + 1))
f="$TMP/rotate.sh"; echo 'marker-rotate' > "$f"
rc=$(run "$h" "bash $f")
[ "$rc" = 0 ] && [ -f "$LOG.1" ] && [ "$(wc -c < "$LOG.1" | tr -d ' ')" = "$((5242880 + 1))" ] && logged "$h" "marker-rotate" \
  && ok "a log over 5MB is rotated to .1 before the new entry is appended" \
  || bad "rotation did not happen as expected"
# control: just AT the threshold (not over it) does NOT rotate
h="$TMP/home-norotate"; mkdir -p "$h/.claude/audit"
LOG2="$h/.claude/audit/scripts.log"
fill_log "$LOG2" 5242880
f="$TMP/norotate.sh"; echo 'marker-norotate' > "$f"
run "$h" "bash $f" >/dev/null
# not rotated AND appended to: the at-threshold log is still there, grown by the new entry
[ ! -f "$LOG2.1" ] && [ "$(wc -c < "$LOG2" | tr -d ' ')" -gt 5242880 ] && logged "$h" "marker-norotate" \
  && ok "a log exactly AT 5MB (not over) does not rotate (boundary control)" \
  || bad "rotated at exactly the threshold, not just over it"

# ==================================================================================================
# governance#274: secret files are never copied, the log is 0600, and retention is bounded.
# Rows A/B/C/R/F/P are the known-answer table from the issue (v2 c100146, addenda c100154/c100161,
# rulings c100149/c100156). Every case: a fresh mktemp HOME under $TMP, umask 022, cd into a fixture
# dir, then the harness-shaped payload on stdin. Fixture bytes are fake canaries, not secrets. Files
# are built with the shell and hashed over stdin, so no case hands a path to python.
# ==================================================================================================
D=86400
umask 022
mode_of()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
sha_of()   { python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' < "$1"; }
iso_ago()  { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()-int(sys.argv[1]))))' "$1"; }
mtime_ago() {  # mtime_ago <file> <seconds>
  TZ=UTC0 touch -t "$(python3 -c 'import sys,time;print(time.strftime("%Y%m%d%H%M.%S",time.gmtime(time.time()-int(sys.argv[1]))))' "$2")" "$1"
}
old_log()  { printf '===== %s | cwd=/x | script=s.sh | sha256=%s =====\nold-body\n===== end s.sh =====\n\n' "$2" "$(printf '0%.0s' $(seq 64))" > "$1"; }  # 100+ B
newhome()  { local h="$TMP/h274-$1"; mkdir -p "$h/.claude/audit" "$h/w"; fixtures "$h/w"; echo "$h"; }
fixtures() {
  printf 'FAKEKEY=CANARYqq7\n' > "$1/.env"                 # 18 B
  printf 'FAKEKEY=CANARYqq7\n' > "$1/.envrc"
  printf '[db]\nfakepass=CANARYqq9\n' > "$1/creds.ini"
  printf 'export T=CANARYqq8\n' > "$1/s.sh"
  printf 'FAKE-KEY-CANARYqqA\n' > "$1/id_rsa"
}
run274() {  # run274 <home> <command> -> rc (in <home>/w); stdout in $TMP/out
  local home="$1" cmd="$2"
  ( cd "$home/w" && bash_json "$cmd" | HOME="$home" env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; echo $? )
}
quiet() { [ "$1" = 0 ] && [ ! -s "$TMP/out" ]; }   # exit 0 and nothing on stdout
cnt()   { cat "$1" 2>/dev/null | grep -c "$2"; }   # cnt <file> <regex> -> count (0 when absent)
only_a7() {  # the log holds the A7 record and nothing older
  [ "$(cnt "$1" '^===== [0-9]')" = 1 ] && [ "$(cnt "$1" CANARYqq8)" = 1 ] && [ "$(cnt "$1" old-body)" = 0 ] \
    && [ "$(cnt "$1" xxxx)" = 0 ]
}
A7="bash s.sh"

# --- A. the log holds only path + sha256 + size for secret/sourced files ---------------------------
h=$(newhome A); L="$h/.claude/audit/scripts.log"
esha=$(sha_of "$h/w/.env")
rc=$(run274 "$h" "source .env")
quiet "$rc" && [ "$(cnt "$L" CANARYqq7)" = 0 ] && grep -qF "script=.env | sha256=$esha | size=18 |" "$L" \
  && ok "A1 'source .env': canary not copied; record = path + sha256 + size 18" \
  || bad "A1 'source .env': canary copied or hash/size record missing"
rc=$(run274 "$h" ". ./.env")
quiet "$rc" && [ "$(cnt "$L" CANARYqq7)" = 0 ] && grep -qF "script=./.env | sha256=$esha | size=18 |" "$L" \
  && ok "A2 '. ./.env': canary not copied; record = path + sha256 + size" \
  || bad "A2 '. ./.env': canary copied or hash/size record missing"
rc=$(run274 "$h" "wc -l ./creds.ini")
quiet "$rc" && [ "$(cnt "$L" CANARYqq9)" = 0 ] \
  && ok "A3 'wc -l ./creds.ini' (a ./ ARGUMENT, not a command): canary not copied" \
  || bad "A3 'wc -l ./creds.ini': canary copied"
rc=$(run274 "$h" "cp ./creds.ini $TMP/creds-copy")
quiet "$rc" && [ "$(cnt "$L" CANARYqq9)" = 0 ] \
  && ok "A4 'cp ./creds.ini <dst>': canary not copied" || bad "A4 'cp ./creds.ini': canary copied"
rc=$(run274 "$h" "source .envrc")
quiet "$rc" && [ "$(cnt "$L" CANARYqq7)" = 0 ] && grep -qF "script=.envrc | sha256=$esha | size=18 |" "$L" \
  && ok "A5 'source .envrc': canary not copied; hash + size 18" || bad "A5 'source .envrc' leaked or unrecorded"
rc=$(run274 "$h" "bash ./id_rsa")
quiet "$rc" && [ "$(cnt "$L" CANARYqqA)" = 0 ] && grep -qF "script=./id_rsa | sha256=$(sha_of "$h/w/id_rsa") |" "$L" \
  && ok "A6 'bash ./id_rsa': a credential NAME is hash-only even as an interpreter target" \
  || bad "A6 'bash ./id_rsa': canary copied or record missing"
rc=$(run274 "$h" "$A7")
quiet "$rc" && [ "$(cnt "$L" CANARYqq8)" = 1 ] \
  && ok "A7 'bash s.sh': a real script's body is still captured (no regression)" \
  || bad "A7 'bash s.sh': body not captured exactly once"
[ "$(cat "$h/.claude/audit/"scripts.log* | grep -c 'CANARYqq[79A]')" = 0 ] \
  && ok "A8 after A1-A7: no secret canary anywhere in scripts.log*" || bad "A8 a secret canary is in scripts.log*"

# --- B. permissions (umask 022 in the caller) ------------------------------------------------------
# NOTE: on a filesystem without POSIX modes (NTFS under Git Bash) these report 644/755 whatever the
# hook does; Linux CI is the authority for the B rows.
h=$(newhome B1); rm -rf "$h/.claude"; L="$h/.claude/audit/scripts.log"
run274 "$h" "$A7" >/dev/null
[ "$(mode_of "$L")" = 600 ] && [ "$(mode_of "$h/.claude/audit")" = 700 ] \
  && ok "B1 a fresh log is 600 (dir 700) under umask 022" \
  || bad "B1 fresh log is $(mode_of "$L"), dir $(mode_of "$h/.claude/audit"); want 600/700"
h=$(newhome B2); L="$h/.claude/audit/scripts.log"
old_log "$L" "$(iso_ago $D)"; chmod 644 "$L"
run274 "$h" "$A7" >/dev/null
[ "$(mode_of "$L")" = 600 ] && ok "B2 an existing 644 log becomes 600" || bad "B2 existing log stayed $(mode_of "$L")"
h=$(newhome B3); L="$h/.claude/audit/scripts.log"
echo old > "$L.1"; chmod 644 "$L.1"
run274 "$h" "$A7" >/dev/null
[ "$(mode_of "$L.1")" = 600 ] && ok "B3 an existing 644 .1 becomes 600" || bad "B3 existing .1 stayed $(mode_of "$L.1")"
um=$(grep -n '^umask 077' "$HOOK" | head -1 | cut -d: -f1)
w1=$(grep -nE '>>|mkdir|: >' "$HOOK" | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
[ -n "$um" ] && [ -n "$w1" ] && [ "$um" -lt "$w1" ] \
  && ok "B4 'umask 077' precedes the hook's first write (static)" || bad "B4 no 'umask 077' before the first write"

# --- C. size rotation, one generation (B5/B7 checked on the same run) ----------------------------
h=$(newhome C1); L="$h/.claude/audit/scripts.log"
head -c $((5242880 + 1)) /dev/zero | tr '\0' x > "$L"; big=$(sha_of "$L")
rc=$(run274 "$h" "$A7")
quiet "$rc" && [ "$(sha_of "$L.1")" = "$big" ] && only_a7 "$L" \
  && ok "C1 a log over 5MB rotates to .1 (sha256 unchanged); the new log is the A7 record only" \
  || bad "C1 size rotation wrong"
[ "$(mode_of "$L.1")" = 600 ] && ok "B5 a size-rotated .1 is 600 (never inherits 644)" || bad "B5 rotated .1 is $(mode_of "$L.1")"
[ "$(mode_of "$L")" = 600 ] && ok "B7 the log after a rotation is 600" || bad "B7 post-rotation log is $(mode_of "$L")"
rm -rf "$h"
h=$(newhome C3); L="$h/.claude/audit/scripts.log"
echo 'content-X' > "$L.1"
head -c $((5242880 + 1)) /dev/zero | tr '\0' x > "$L"; big=$(sha_of "$L")
run274 "$h" "$A7" >/dev/null
[ "$(sha_of "$L.1")" = "$big" ] && [ "$(cnt "$L.1" content-X)" = 0 ] && [ ! -e "$L.2" ] \
  && ok "C3 rotation replaces an existing .1 outright: old content gone, no .2" || bad "C3 old .1 survived or a .2 exists"
[ "$(ls "$h/.claude/audit" | grep -c '^scripts\.log')" = 2 ] \
  && ok "C4 exactly two files after rotation (scripts.log, scripts.log.1)" || bad "C4 file count is not 2"
rm -rf "$h"

# --- R. the current log's age = its FIRST entry's timestamp, never its mtime ----------------------
age_case() {  # age_case <id> <first-ts-age-s> <log-mtime-age-s> <expect: rotate|keep> <label>
  local h L s0; h=$(newhome "$1"); L="$h/.claude/audit/scripts.log"
  old_log "$L" "$(iso_ago "$2")"; mtime_ago "$L" "$3"; s0=$(sha_of "$L")
  local rc; rc=$(run274 "$h" "$A7")
  if [ "$4" = rotate ]; then
    quiet "$rc" && [ "$(sha_of "$L.1" 2>/dev/null)" = "$s0" ] && only_a7 "$L" \
      && ok "$1 $5: rotated (.1 = old content; log = A7 only)" || bad "$1 $5: did not rotate as expected"
    [ "$(mode_of "$L.1" 2>/dev/null)" = 600 ] && ok "$1 the rotated .1 is 600" || bad "$1 the rotated .1 is $(mode_of "$L.1" 2>/dev/null)"
  else
    quiet "$rc" && [ ! -e "$L.1" ] && [ "$(cnt "$L" old-body)" = 1 ] && [ "$(cnt "$L" CANARYqq8)" = 1 ] \
      && ok "$1 $5: not rotated, A7 appended" || bad "$1 $5: rotated when it should not"
  fi
}
age_case R1 $((29*D + 23*3600)) 0 keep   "first ts N-29d23h"
age_case R2 $((30*D + 3600))    0 rotate "first ts N-30d1h"
age_case R3 $((400*D))          0 rotate "first ts N-400d, mtime N"
age_case R4 $D          $((400*D)) keep  "first ts N-1d, mtime N-400d"

# --- F. a log WITH content but no parseable first timestamp rotates (fail closed); empty never does --
garbage_case() {  # garbage_case <id> <first-line> <label>
  local h L; h=$(newhome "$1"); L="$h/.claude/audit/scripts.log"
  printf '%s\nbody\n' "$2" > "$L"; local s0; s0=$(sha_of "$L")
  run274 "$h" "$A7" >/dev/null
  [ "$(sha_of "$L.1" 2>/dev/null)" = "$s0" ] && only_a7 "$L" \
    && ok "$1 $3: rotated (fail closed)" || bad "$1 $3: not rotated"
}
garbage_case F1 '===== not-a-date | cwd=/x | script=s.sh | sha256=0 =====' "garbage timestamp"
garbage_case F2 '===== | cwd=/x | script=s.sh =====' "timestamp field missing"
garbage_case F3 'hello world' "no header at all"
empty_case() {  # empty_case <id> <log-bytes-printf> <.1-age-s> <trigger> <expect .1: kept|deleted> <label>
  local h L; h=$(newhome "$1"); L="$h/.claude/audit/scripts.log"
  printf "$2" > "$L"; echo 'content-X' > "$L.1"; mtime_ago "$L.1" "$3"
  local l0 m0; l0=$(sha_of "$L"); m0=$(stat -c %Y "$L.1" 2>/dev/null || stat -f %m "$L.1")
  local rc; rc=$(run274 "$h" "$4")
  local good=1
  quiet "$rc" || good=0
  if [ "$5" = kept ]; then
    [ "$(cat "$L.1" 2>/dev/null)" = content-X ] && [ "$(stat -c %Y "$L.1" 2>/dev/null || stat -f %m "$L.1")" = "$m0" ] || good=0
  else
    [ ! -e "$L.1" ] || good=0
  fi
  if [ "$4" = ls ]; then [ "$(sha_of "$L")" = "$l0" ] || good=0; else only_a7 "$L" || good=0; fi
  [ "$good" = 1 ] && ok "$1 $6" || bad "$1 $6"
}
empty_case F4  ''        $((10*D)) "$A7" kept    "0-B log + 10d .1, 'bash s.sh': no rotation, .1 untouched, log = A7 only"
empty_case F4a '\n  \n'  $((10*D)) "$A7" kept    "whitespace-only log counts as empty: no rotation, .1 untouched"
empty_case F4b ''        $((10*D)) ls    kept    "0-B log + 10d .1, 'ls': both untouched"
empty_case F4c ''        $((31*D)) ls    deleted "0-B log + 31d .1, 'ls': log untouched, .1 deleted"
h=$(newhome F5); rm -rf "$h/.claude"; L="$h/.claude/audit/scripts.log"
run274 "$h" "$A7" >/dev/null
[ ! -e "$L.1" ] && only_a7 "$L" \
  && ok "F5 no log at all: no rotation, a new log is created (control)" || bad "F5 no-log control failed"
[ "$(mode_of "$L")" = 600 ] && ok "F5 the new log is 600" || bad "F5 the new log is $(mode_of "$L")"

# --- P. the .1 cap: deleted once its mtime is over 30 days, on EVERY invocation -------------------
p1_case() {  # p1_case <id> <.1-age-s> <trigger> <expect: kept|deleted> <label>
  local h L; h=$(newhome "$1"); L="$h/.claude/audit/scripts.log"
  old_log "$L" "$(iso_ago $D)"; echo 'content-X' > "$L.1"; mtime_ago "$L.1" "$2"
  local l0; l0=$(sha_of "$L")
  local rc; rc=$(run274 "$h" "$3")
  local good=1
  quiet "$rc" || good=0
  if [ "$4" = kept ]; then [ "$(cat "$L.1" 2>/dev/null)" = content-X ] || good=0; else [ ! -e "$L.1" ] || good=0; fi
  if [ "$3" = "$A7" ]; then [ "$(cnt "$L" old-body)" = 1 ] && [ "$(cnt "$L" CANARYqq8)" = 1 ] || good=0
  else [ "$(sha_of "$L")" = "$l0" ] || good=0; fi
  [ "$good" = 1 ] && ok "$1 $5" || bad "$1 $5"
}
p1_case P1  $((29*D + 23*3600)) "$A7" kept    ".1 at N-29d23h: kept, content unchanged"
p1_case P2  $((30*D + 3600))    "$A7" deleted ".1 at N-30d1h: deleted; log only gains the A7 append"
p1_case P3  $((31*D))           "$A7" deleted ".1 at N-31d: deleted"
p1_case P4  $((31*D))           ls    deleted ".1 at N-31d, 'ls' (logs nothing): deleted, log byte-identical"
p1_case P4a $((29*D + 23*3600)) ls    kept    ".1 at N-29d23h, 'ls': kept"
p1_case P4b $((30*D + 3600))    ls    deleted ".1 at N-30d1h, 'ls': deleted"
h=$(newhome P4c); L="$h/.claude/audit/scripts.log"
echo 'content-X' > "$L.1"; mtime_ago "$L.1" $((31*D))
rc=$(run274 "$h" "ls")
quiet "$rc" && [ ! -e "$L.1" ] && [ ! -e "$L" ] \
  && ok "P4c no log, 31d .1, 'ls': .1 deleted and no scripts.log created" || bad "P4c .1 kept or a log was created"
h=$(newhome P4d); L="$h/.claude/audit/scripts.log"
echo 'content-X' > "$L.1"; mtime_ago "$L.1" $((31*D))
rc=$( (cd "$h/w" && bash_json "" | HOME="$h" env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; echo $?) )
quiet "$rc" && [ ! -e "$L.1" ] \
  && ok "P4d an empty command still deletes a 31d .1 (every invocation)" || bad "P4d empty command left the 31d .1"
h=$(newhome P5); L="$h/.claude/audit/scripts.log"
old_log "$L" "$(iso_ago $((30*D + 3600)))"; s0=$(sha_of "$L")
echo 'content-X' > "$L.1"; mtime_ago "$L.1" $((10*D))
rc=$(run274 "$h" "$A7")
quiet "$rc" && [ "$(sha_of "$L.1")" = "$s0" ] && [ ! -e "$L.2" ] && only_a7 "$L" \
  && ok "P5 an age rotation replaces a 10d .1 outright, no .2" || bad "P5 age rotation kept the old .1 or made a .2"
[ "$(mode_of "$L.1")" = 600 ] && ok "B6 an age-rotated .1 is 600" || bad "B6 age-rotated .1 is $(mode_of "$L.1")"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
