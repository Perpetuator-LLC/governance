#!/usr/bin/env bash
# check-frontmatter-paths.test.sh — dead paths in frontmatter must go RED, and a check that could not
# run must never read as either "clean" or "findings".
#
# The built-in --self-test proves the detection logic in-process. This suite proves the COMMAND: the
# exit codes a caller gates on (0 clean · 1 dead paths · 2 the instrument could not run), the named
# root in the report, and the baseline's two irreversible doors — writing one while an alias is
# missing, and suppressing known-bad without hiding a NEW break.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/check-frontmatter-paths"
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run()  { "$CHECK" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

echo "check-frontmatter-paths"
check "the script is executable" "[ -x '$CHECK' ]"
if ! python3 -c 'import yaml' 2>/dev/null; then
  bad "PyYAML is not importable — this suite cannot construct its cases (install python3-yaml)"
  echo; echo "  $pass passed, $fail failed"; exit 1
fi

rc="$(run --self-test)"
check "the built-in self-test passes (exit 0, verdict PASS)" "[ '$rc' = '0' ] && grep -q '^SELF-TEST: PASS' '$TMP/out'"

# --- a vault with one live and one dead path -------------------------------------------------------
V="$TMP/vault"; mkdir -p "$V/Attachments" "$V/notes"
printf 'x' > "$V/Attachments/real.png"
printf -- '---\nid: a\nattachments:\n- path: Attachments/real.png\n---\n\nbody\n' > "$V/notes/good.md"
printf -- '---\nid: b\nrelated_doc: Old/Layout/Gone.md\n---\n\nbody\n' > "$V/notes/dead.md"
printf 'no frontmatter here\n' > "$V/plain.md"

rc="$(run --vault-root "$V")"
check "known-BAD: a dead path exits 1" "[ '$rc' = '1' ]"
check "...names the dead value and its key" "grep -q 'DEAD .*related_doc.*Old/Layout/Gone.md' '$TMP/out'"
check "...names the vault root it actually READ" "grep -q \"^READ $V\" '$TMP/out'"
check "...counts the live path as resolved" "grep -q '^resolved *: 1' '$TMP/out'"

rm "$V/notes/dead.md"
rc="$(run --vault-root "$V")"
check "known-GOOD: every path resolves -> exit 0" "[ '$rc' = '0' ] && grep -q '^FAILING *: 0' '$TMP/out'"

printf -- '---\nid: c\nkey: [unclosed\n---\n' > "$V/notes/broken.md"
rc="$(run --vault-root "$V")"
check "unparseable frontmatter is a FAILURE (exit 1), not a skip" "[ '$rc' = '1' ] && grep -q 'UNPARSEABLE' '$TMP/out'"
rm "$V/notes/broken.md"

# --- a provenance scheme on an absolute path (#136): strip it, then resolve -----------------------
printf 'x' > "$TMP/present.md"
printf -- '---\nid: s1\nsource: scraped:%s\n---\n' "$TMP/present.md" > "$V/notes/scraped-ok.md"
rc="$(run --vault-root "$V")"
check "known-GOOD: scraped:<present absolute path> resolves (it was reported dead)" \
  "[ '$rc' = '0' ] && grep -q '^FAILING *: 0' '$TMP/out'"
printf -- '---\nid: s2\nsource: scraped:%s\n---\n' "$TMP/absent.md" > "$V/notes/scraped-dead.md"
rc="$(run --vault-root "$V")"
check "known-BAD: scraped:<absent absolute path> still fails" "[ '$rc' = '1' ] && grep -q 'DEAD notes/scraped-dead.md :: source' '$TMP/out'"
rm "$V/notes/scraped-ok.md" "$V/notes/scraped-dead.md"
printf -- '---\nid: s3\nsource: https://x.example/doc.md\n---\n' > "$V/notes/url.md"
rc="$(run --vault-root "$V")"
check "a URL is not a path: neither resolved nor failed" "[ '$rc' = '0' ] && grep -q '^FAILING *: 0' '$TMP/out' && grep -q '^resolved *: 1' '$TMP/out'"
rm "$V/notes/url.md"

# --- the instrument refusing is exit 2, never 0 and never the findings code ------------------------
rc="$(run --vault-root "$TMP/does-not-exist")"
check "a missing root exits 2 with the reason on stderr" "[ '$rc' = '2' ] && grep -q 'VAULT ROOT MISSING' '$TMP/err'"
mkdir -p "$TMP/no-md"; printf 'x' > "$TMP/no-md/readme.txt"
rc="$(run --vault-root "$TMP/no-md")"
check "a root with no markdown exits 2 (a broken selector, not an empty vault)" "[ '$rc' = '2' ]"
rc="$(run)"
check "no --vault-root exits 2" "[ '$rc' = '2' ]"
rc="$(run --vault-root "$V" --alias "Other/=$TMP/not-a-dir")"
check "an alias pointing nowhere exits 2" "[ '$rc' = '2' ] && grep -q 'not a directory' '$TMP/err'"

# --- baseline: suppresses known-bad, but a NEW break still fails -----------------------------------
printf -- '---\nid: d\nrelated_doc: Old/Layout/Gone.md\n---\n' > "$V/notes/dead.md"
printf '{"Old/Layout/Gone.md": "moved out of the vault on purpose"}' > "$TMP/reasons.json"
rc="$(run --vault-root "$V" --baseline "$TMP/baseline.json" --write-baseline --reasons "$TMP/reasons.json")"
check "--write-baseline records the dead value with its reason" \
  "[ '$rc' = '0' ] && python3 -c \"import json,sys; kb=json.load(open('$TMP/baseline.json'))['known_bad']; sys.exit(0 if kb=={'Old/Layout/Gone.md':'moved out of the vault on purpose'} else 1)\""
rc="$(run --vault-root "$V" --baseline "$TMP/baseline.json")"
check "a baselined value no longer fails the run" "[ '$rc' = '0' ] && grep -q '^baselined known-bad : 1' '$TMP/out'"
printf -- '---\nid: e\nrelated_doc: Old/Layout/NewlyBroken.md\n---\n' > "$V/notes/new.md"
rc="$(run --vault-root "$V" --baseline "$TMP/baseline.json")"
check "a NEW dead path still fails beside the baseline" "[ '$rc' = '1' ] && grep -q 'NewlyBroken.md' '$TMP/out'"
rm "$V/notes/new.md"

# --- re-running --write-baseline with no --reasons must not ERASE a reason already on record --------
# Real bug, found mutation-testing (governance#240): the reasons dict was built from --reasons alone,
# discarding whatever the baseline file on disk already recorded whenever the flag was simply omitted
# on a later run — the ordinary case, since the reasons were already written last time.
rc="$(run --vault-root "$V" --baseline "$TMP/baseline.json" --write-baseline)"
check "re-running --write-baseline with NO --reasons preserves the reason already on record" \
  "[ '$rc' = '0' ] && python3 -c \"import json,sys; kb=json.load(open('$TMP/baseline.json'))['known_bad']; sys.exit(0 if kb.get('Old/Layout/Gone.md')=='moved out of the vault on purpose' else 1)\""

# --- cross-vault: resolves with an alias; baselining without one is REFUSED ------------------------
S="$TMP/sibling"; mkdir -p "$S/State"; printf 'x' > "$S/State/Doc.md"
printf -- '---\nid: f\nrelated: Other/State/Doc.md\n---\n' > "$V/notes/xref.md"
rc="$(run --vault-root "$V" --vault-root "$S" --baseline "$TMP/b2.json" --write-baseline)"
check "writing a baseline while an alias is MISSING is refused (exit 2), and nothing is written" \
  "[ '$rc' = '2' ] && grep -q 'REFUSING' '$TMP/err' && [ ! -e '$TMP/b2.json' ]"
rc="$(run --vault-root "$V" --baseline "$TMP/baseline.json" --alias "Other/=$S")"
check "with the alias the cross-vault reference resolves and is reported as CROSS-VAULT" \
  "[ '$rc' = '0' ] && grep -q 'CROSS-VAULT (resolved via an --alias): 1' '$TMP/out'"

# --- the LEGACY baseline shape: a bare list of values, from before each entry carried a reason -----
printf '{"known_bad": ["Old/Layout/Gone.md"]}' > "$TMP/legacy-baseline.json"
rc="$(run --vault-root "$V" --baseline "$TMP/legacy-baseline.json" --alias "Other/=$S")"
check "a legacy LIST-form baseline (no per-value reason) still suppresses the known-bad value" \
  "[ '$rc' = '0' ] && grep -q '^baselined known-bad : 1' '$TMP/out'"
check "...and every legacy entry counts as UNEXPLAINED (it never had a reason to begin with)" \
  "grep -q '1 of the baseline is UNEXPLAINED' '$TMP/out'"

# --- --json writes the FULL report, not just the console summary -----------------------------------
rc="$(run --vault-root "$V" --alias "Other/=$S" --json "$TMP/report.json")"
check "--json writes a parseable report naming the same dead value the console output shows" \
  "[ -f '$TMP/report.json' ] && python3 -c \"import json; d=json.load(open('$TMP/report.json')); assert any(f['value']=='Old/Layout/Gone.md' for f in d['failing']), d['failing']\""

# --- TWO --vault-root args are BOTH scanned, not just the first -------------------------------------
V2="$TMP/vault2"; mkdir -p "$V2/notes"
printf -- '---\nid: v2\nrelated: Another/Dead.md\n---\n' > "$V2/notes/dead2.md"
rc="$(run --vault-root "$V" --vault-root "$V2" --alias "Other/=$S")"
check "two --vault-root args: a dead path in the SECOND root is reported too, not only the first" \
  "[ '$rc' = '1' ] && grep -q 'Another/Dead.md' '$TMP/out' && grep -q 'Old/Layout/Gone.md' '$TMP/out'"

# --- present but unreadable is a failure, not a smaller vault --------------------------------------
# Root ignores mode bits (CAP_DAC_OVERRIDE), and CI runs the suites as root, so under root the command
# runs with those capabilities dropped: still uid 0 and owner of $TMP, but the 000 owner bits apply.
# The probe proves the directory is unreadable to the command before the case counts; a probe that
# cannot run reports NOT CHECKED as a failure, never a skip.
nodac=()
[ "$(id -u)" = 0 ] && nodac=(setpriv --inh-caps=-dac_override,-dac_read_search \
                                     --bounding-set=-dac_override,-dac_read_search --)
mkdir -p "$V/locked"; printf -- '---\nid: g\n---\n' > "$V/locked/hidden.md"; chmod 000 "$V/locked"
probe=$(${nodac[@]+"${nodac[@]}"} bash -c '[[ -r "$1" ]] && echo readable || echo unreadable' _ "$V/locked" 2>/dev/null)
if [ "$probe" != unreadable ]; then
  bad "could not make a directory unreadable to the command (uid $(id -u), probe: '${probe:-did not run}'): the unreadable-subtree case is NOT CHECKED"
else
  rc="$(${nodac[@]+"${nodac[@]}"} "$CHECK" --vault-root "$V" --baseline "$TMP/baseline.json" --alias "Other/=$S" >"$TMP/out" 2>"$TMP/err"; echo $?)"
  check "an unreadable subtree fails the run instead of shrinking it" "[ '$rc' = '1' ] && grep -q 'UNREADABLE directory' '$TMP/out'"
fi
chmod 755 "$V/locked"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
