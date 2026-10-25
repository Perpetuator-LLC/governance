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

# --- bash 3.2 compatibility (governance#284) -----------------------------------------------------
# This hook runs on macOS, whose /bin/bash is 3.2 (frozen there since the GPLv3 relicense) — not just
# on the Linux CI runner. CI has no bash 3.2 binary, so this is a STATIC check of the hook's own
# source, not a literal run under bash 3.2 semantics. Real runs of this suite under /bin/bash 3.2.57
# with a BSD PATH are on record in the PR reviews (governance#312 c109259, c105323); this check keeps
# the one hard blocker out between such runs. `declare -A`
# (associative arrays) is bash-4.0-only; on bash 3.2 it is a hard "invalid option" error, and every
# candidate reached after that line in the script was never captured — the measured symptom
# (interpreter forms "NOT captured" on macOS) for every form, because the broken line runs once,
# before the per-candidate loop, regardless of which interpreter triggered it.
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE '\bdeclare[[:space:]]+-A\b'; then
  bad "no bash-4-only construct in the hook (found \`declare -A\` — bash 3.2 cannot run this line at all)"
else
  ok "no bash-4-only construct in the hook (\`declare -A\`, bash 3.2's one hard blocker here, is absent)"
fi

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

# --- source / '.' dot-sourcing -------------------------------------------------------------------
for interp in source .; do
  n=$((n+1))
  h="$TMP/home-src-$n"; mkdir -p "$h"
  f="$TMP/job-$n.task"; printf 'marker-source-%s\n' "$n" > "$f"
  rc=$(run "$h" "$interp $f")
  [ "$rc" = 0 ] && logged "$h" "marker-source-$n" \
    && ok "'$interp <file>' (dot-sourcing): captured" \
    || bad "'$interp <file>' NOT captured (rc=$rc)"
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

# --- dedup does not confuse a SPACED filename with a shorter, distinct one (CISA send-back,
#     governance#284 c105838): candidates come from an unquoted `for tok in $(...)`, so pathname
#     expansion on a bare glob can hand back a filename containing a space as ONE token. A dedup
#     keyed on a padded string match (`*" $f "*`) then reads the padding around a longer logged
#     name as also matching a shorter, different name — here, "my a.sh" getting logged makes a
#     later, truly distinct "a.sh" read as already-seen and get silently skipped. ------------------
h="$TMP/home-dedup-space"; mkdir -p "$h"
d="$TMP/space-dir"; mkdir -p "$d"
printf 'marker-space-long\n' > "$d/my a.sh"
printf 'marker-space-short\n' > "$d/a.sh"
rc=$(cd "$d" && run "$h" "bash m*.sh a.sh")
[ "$rc" = 0 ] && logged "$h" "marker-space-long" && logged "$h" "marker-space-short" \
  && ok "a glob-expanded filename with a space does not mask a later, distinct shorter filename" \
  || bad "a spaced filename's dedup entry masked a distinct later candidate (CISA governance#284)"

# --- dedup compares EXACTLY, never as a pattern (coa governance#312 c109259, mutant M4): with an
#     unquoted RHS, `[[ "$s" == $f ]]` treats a candidate named "a?.sh" as a glob, so an earlier
#     "ab.sh" in `seen` matches it and the distinct file "a?.sh" is silently dropped from the audit. --
h="$TMP/home-dedup-pattern"; mkdir -p "$h"
d="$TMP/pattern-dir"; mkdir -p "$d"
printf 'marker-pattern-plain\n' > "$d/ab.sh"
printf 'marker-pattern-glob\n' > "$d/a?.sh"
rc=$(cd "$d" && run "$h" "bash ab.sh a?.sh")
[ "$rc" = 0 ] && logged "$h" "marker-pattern-plain" && logged "$h" "marker-pattern-glob" \
  && ok "a filename with a glob character is compared exactly, not masked by an earlier name it matches" \
  || bad "dedup matched 'a?.sh' as a pattern against 'ab.sh' and dropped it (coa governance#312 M4)"

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
h="$TMP/home-rotate"; mkdir -p "$h/.claude/audit"
LOG="$h/.claude/audit/scripts.log"
python3 -c "open('$LOG','wb').write(b'x' * (5242880 + 1))"
f="$TMP/rotate.sh"; echo 'marker-rotate' > "$f"
rc=$(run "$h" "bash $f")
[ "$rc" = 0 ] && [ -f "$LOG.1" ] && [ "$(wc -c < "$LOG.1" | tr -d ' ')" = "$((5242880 + 1))" ] && logged "$h" "marker-rotate" \
  && ok "a log over 5MB is rotated to .1 before the new entry is appended" \
  || bad "rotation did not happen as expected"
# control: just AT the threshold (not over it) does NOT rotate
h="$TMP/home-norotate"; mkdir -p "$h/.claude/audit"
LOG2="$h/.claude/audit/scripts.log"
python3 -c "open('$LOG2','wb').write(b'x' * 5242880)"
f="$TMP/norotate.sh"; echo 'marker-norotate' > "$f"
run "$h" "bash $f" >/dev/null
[ ! -f "$LOG2.1" ] \
  && ok "a log exactly AT 5MB (not over) does not rotate (boundary control)" \
  || bad "rotated at exactly the threshold, not just over it"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
