#!/usr/bin/env bash
# tests/post-edit-lint.test.sh — hooks/post-edit-lint.sh: a PostToolUse[Write|Edit] ADVISORY linter.
#
# Advisory only (contract: exit 0 always, whatever the checker underneath finds), so the property
# worth pinning is not "did it block" but "did it run the RIGHT checker for the RIGHT extension, and
# stay silent where it has nothing to say" — one fixture per extension branch, a genuinely broken file
# beside a genuinely clean one so a checker that fires on everything is caught, and the extension
# parsing itself (no dot, a multi-dot name, an unknown extension).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/post-edit-lint.sh"
[[ -x "$HOOK" ]] || { echo "FAIL: $HOOK missing or not executable"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

write_json() { printf '{"tool_name":"Write","tool_input":{"file_path":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")"; }

run() {  # run <path> -> rc; stdout/stderr in $TMP/out,$TMP/err
  write_json "$1" | env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"
  echo $?
}
says() { grep -qi "$1" "$TMP/out" "$TMP/err" 2>/dev/null; }

echo "post-edit-lint"

# --- python: a syntax error is reported; valid python is silent ----------------------------------
f="$TMP/broken.py"; printf 'def broken(:\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && says 'syntax' && ok "python: a syntax error is reported (advisory, exit 0)" \
  || bad "python syntax error not reported (rc=$rc)"
f="$TMP/clean.py"; printf 'def clean():\n    return 1\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "python: valid syntax produces no output (control — a checker that always fires would pass the broken case for the wrong reason)" \
  || bad "valid python produced output: out=$(cat "$TMP/out") err=$(cat "$TMP/err")"

# --- javascript (js/jsx/mjs): node --check, if node is on PATH -----------------------------------
if command -v node >/dev/null 2>&1; then
  for ext in js jsx mjs; do
    f="$TMP/broken.$ext"; printf 'function broken( {\n' > "$f"
    rc=$(run "$f")
    [ "$rc" = 0 ] && says 'error\|syntax' && ok "js ($ext): a syntax error is reported" \
      || bad "js ($ext) syntax error not reported (rc=$rc): $(cat "$TMP/out" "$TMP/err")"
  done
  f="$TMP/clean.js"; printf 'function clean() { return 1; }\n' > "$f"
  rc=$(run "$f")
  [ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
    && ok "js: valid syntax produces no output (control)" \
    || bad "valid js produced output"
else
  echo "  (skip: no node on PATH — js/jsx/mjs branch not exercised)"
fi

# --- ruby: ruby -c, if ruby is on PATH -----------------------------------------------------------
if command -v ruby >/dev/null 2>&1; then
  f="$TMP/broken.rb"; printf 'def broken(\n' > "$f"
  rc=$(run "$f")
  [ "$rc" = 0 ] && says 'syntax' && ok "ruby: a syntax error is reported" \
    || bad "ruby syntax error not reported (rc=$rc)"
  f="$TMP/clean.rb"; printf 'def clean\n  1\nend\n' > "$f"
  rc=$(run "$f")
  [ "$rc" = 0 ] && ! says 'syntax error' \
    && ok "ruby: valid syntax reports no error (control)" \
    || bad "valid ruby reported a syntax error"
else
  echo "  (skip: no ruby on PATH — rb branch not exercised)"
fi

# --- go: gofmt -e, if gofmt is on PATH -------------------------------------------------------------
if command -v gofmt >/dev/null 2>&1; then
  f="$TMP/broken.go"; printf 'package main\nfunc broken( {\n' > "$f"
  rc=$(run "$f")
  [ "$rc" = 0 ] && ok "go: a broken file does not crash the hook (advisory, exit 0 regardless)" \
    || bad "go branch did not exit 0 (rc=$rc)"
else
  echo "  (skip: no gofmt on PATH — go branch not exercised)"
fi

# --- rust: deliberately SKIPPED, not a bug — pin that it stays a no-op ----------------------------
f="$TMP/whatever.rs"; printf 'fn broken( {\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "rust: deliberately a no-op (documented in the script's own comment), not silently broken" \
  || bad "rust produced output even though the script documents it as skipped"

# --- json: jq or python3 json.tool, whichever is present -------------------------------------------
f="$TMP/broken.json"; printf '{"a": }\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && says 'error\|expect\|pars' && ok "json: a malformed file is reported" \
  || bad "malformed json not reported (rc=$rc): $(cat "$TMP/out" "$TMP/err")"
f="$TMP/clean.json"; printf '{"a": 1}\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "json: valid content produces no output (control)" \
  || bad "valid json produced output"

# --- yaml/yml: python3 yaml.safe_load, if PyYAML is importable ------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  for ext in yaml yml; do
    f="$TMP/broken.$ext"; printf 'a: [1, 2\n' > "$f"
    rc=$(run "$f")
    [ "$rc" = 0 ] && says 'error\|expect' && ok "yaml ($ext): a malformed file is reported" \
      || bad "malformed $ext not reported (rc=$rc): $(cat "$TMP/out" "$TMP/err")"
    # Real bug, found by the merge lead on real PyYAML (Debian/macOS): the old code piped the
    # exception's TRACEBACK into `head -5`, and PyYAML's own problem description is the LAST line of
    # a multi-line marked error — a traceback above it (module import, call stack) pushed that line
    # past the cutoff, so the one line anyone wanted was exactly what got cut. A loose grep for
    # "error" still passed, because "ScannerError" appears mid-traceback too. Pin the STRUCTURAL
    # property instead: no "Traceback" text, and the report is exactly one line.
    combined="$(cat "$TMP/out" "$TMP/err")"
    n="$(printf '%s' "$combined" | grep -c . )"
    ! grep -q 'Traceback' <<<"$combined" && [ "$n" -le 1 ] \
      && ok "yaml ($ext): the report is the error message alone, never a traceback" \
      || bad "yaml ($ext) report leaked a traceback or more than one line ($n): $combined"
  done
  f="$TMP/clean.yaml"; printf 'a: 1\nb: 2\n' > "$f"
  rc=$(run "$f")
  [ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
    && ok "yaml: valid content produces no output (control)" \
    || bad "valid yaml produced output"
else
  echo "  (skip: PyYAML not importable here — yaml/yml branch not exercised; pre-existing sandbox gap)"
fi

# --- shell (sh/bash/zsh): bash -n ------------------------------------------------------------------
for ext in sh bash zsh; do
  f="$TMP/broken.$ext"; printf 'if [ 1 -eq 1 ]; then\n' > "$f"
  rc=$(run "$f")
  [ "$rc" = 0 ] && says 'syntax\|unexpected' && ok "shell ($ext): a syntax error is reported" \
    || bad "shell ($ext) syntax error not reported (rc=$rc): $(cat "$TMP/out" "$TMP/err")"
done
f="$TMP/clean.sh"; printf 'echo hi\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "shell: valid syntax produces no output (control)" \
  || bad "valid shell produced output"

# --- extension parsing edge cases ------------------------------------------------------------------
f="$TMP/noextension"; printf 'whatever\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "a file with NO extension (no dot) hits no case arm, silently (never crashes)" \
  || bad "a no-extension file misbehaved (rc=$rc)"
f="$TMP/archive.tar.gz"; printf 'binary-ish\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] \
  && ok "a multi-dot name (archive.tar.gz) uses the LAST extension (gz), hits no arm, exits 0" \
  || bad "a multi-dot filename crashed the hook (rc=$rc)"
f="$TMP/unknown.xyz"; printf 'whatever\n' > "$f"
rc=$(run "$f")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "an unrecognised extension produces no output" \
  || bad "an unrecognised extension produced output"

# --- no path at all, or a path that does not exist, is a silent no-op -----------------------------
rc=$(printf '{"tool_name":"Write","tool_input":{}}' | env -u CLAUDE_TOOL_INPUT bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; echo $?)
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "no file_path at all: exit 0, silent" || bad "no-path case misbehaved (rc=$rc)"
rc=$(run "$TMP/does-not-exist.py")
[ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] \
  && ok "a path that does not exist on disk: exit 0, silent" || bad "nonexistent-path case misbehaved (rc=$rc)"

# --- the legacy CLAUDE_TOOL_INPUT fallback, shared with the safety gates but untested for THIS hook ---
f="$TMP/legacy.py"; printf 'def broken(:\n' > "$f"
rc=$(CLAUDE_TOOL_INPUT="$(python3 -c 'import json,sys;print(json.dumps({"file_path": sys.argv[1]}))' "$f")" \
     bash "$HOOK" </dev/null >"$TMP/out" 2>"$TMP/err"; echo $?)
[ "$rc" = 0 ] && says 'syntax' \
  && ok "the legacy \$CLAUDE_TOOL_INPUT env var is still honoured as a fallback" \
  || bad "the legacy env-var fallback did not run the checker"

# --- output is TRUNCATED to a bounded number of lines (head -10 / -5), never unbounded -------------
f="$TMP/manyerrors.py"
python3 -c "print('\n'.join('    bad%d(' % i for i in range(50)))" > "$f"
rc=$(run "$f")
n=$(wc -l < "$TMP/out" | tr -d ' ')
[ "$rc" = 0 ] && [ "$n" -le 10 ] \
  && ok "python output is bounded (<=10 lines) even for a file with many errors" \
  || bad "python output was not bounded: $n lines"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
