#!/usr/bin/env bash
# secret-names-fallback.test.sh — the secret-read and secret-write gates find their name list wherever
# they are installed, and work without it.
#
# The installer links hooks FILE BY FILE into the harness's hooks directory. A gate that looked for
# secret-names.sh only beside its own path found the LINK directory, which on a machine linked before
# the file existed has no such file, and refused every Bash and Write call until a human reconciled
# from a terminal. Each gate now loads the list from its REAL directory (symlinks followed), then
# from beside the link, then from a copy embedded in the gate. This suite proves:
#   1. each embedded copy equals the code in hooks/secret-names.sh (they cannot drift);
#   2. a gate COPIED somewhere with no list beside it still allows an ordinary command and refuses a
#      secret name (the embedded copy);
#   3. a gate SYMLINKED from a directory with no list loads the list beside its real file (a marker
#      template only that list allows);
#   4. an empty, whitespace-only or comment-only list file counts as MISSING: the built-in copy is used
#      and a warning names the ignored file (a blanked file must not lock every seat out);
#   5. a list that loads but leaves a value empty refuses, and the refusal names the file and the way
#      out (a human restores or deletes it from a terminal).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/legs.sh
. "$ROOT/tests/lib/legs.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # never the real deny trail
export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"   # Git Bash: a real symlink, not a silent copy
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  ❌ NOT RUN: python3 is required to build the payloads"; exit 1; }

verdict() {  # verdict <gate> <tool> <field> <value> -> BLOCK | ALLOW | EXIT<n>
  local rc
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' \
    "$2" "$3" "$4" | bash "$1" >/dev/null 2>&1
  rc=$?
  case $rc in 2) echo BLOCK ;; 0) echo ALLOW ;; *) echo "EXIT$rc" ;; esac
}
expect_read()  { local g; g=$(verdict "$2/bash-safety-gate.sh" Bash command "$3");   [ "$g" = "$1" ] && ok "[$4] read  $1  $3" || bad "[$4] read  $3: expected $1, got $g"; }
expect_write() { local g; g=$(verdict "$2/write-safety-gate.sh" Write file_path "$3"); [ "$g" = "$1" ] && ok "[$4] write $1  $3" || bad "[$4] write $3: expected $1, got $g"; }

code_lines() { grep -vE '^[[:space:]]*(#|$)'; }
E="." ; E+="env"   # the secret-file shape, built so this file's own text does not trip the read gate

echo "secret-name list — embedded copies, and gates installed without the file"

echo " ── 1. each gate's embedded copy equals hooks/secret-names.sh"
want="$(code_lines < "$ROOT/hooks/secret-names.sh")"
for g in bash-safety-gate.sh write-safety-gate.sh; do
  got="$(sed -n '/^# >>> embedded copy of secret-names.sh/,/^# <<< end of embedded copy/p' "$ROOT/hooks/$g" | code_lines)"
  if [ -n "$got" ] && [ "$got" = "$want" ]; then ok "$g embeds the same code as secret-names.sh"
  else bad "$g's embedded copy differs from secret-names.sh:"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/      /'; fi
done

echo " ── 2. gates COPIED with no secret-names.sh anywhere near them: the embedded copy"
C="$TMP/copied"; mkdir -p "$C"
cp -p "$ROOT/hooks/bash-safety-gate.sh" "$ROOT/hooks/write-safety-gate.sh" "$ROOT/hooks/deny-event.py" "$C/"
expect_read  ALLOW "$C" "ls -la"                         copied
expect_read  ALLOW "$C" "git status"                     copied
expect_read  BLOCK "$C" "cat $E"                         copied
expect_read  ALLOW "$C" "cat $E.example"                 copied
expect_read  BLOCK "$C" "cat $E.sample$E.example"        copied
expect_read  BLOCK "$C" "cat $E.kat"                     copied   # the marker of leg 3 is not in the real list
expect_write ALLOW "$C" "src/a.py"                       copied
expect_write BLOCK "$C" "app/$E"                         copied
expect_write ALLOW "$C" "app/$E.example"                 copied
expect_write BLOCK "$C" "app/${E}rc.local"               copied

echo " ── 3. gates SYMLINKED from a directory with no secret-names.sh: the list beside the REAL file"
# The "clone" holds the gates and a list with one extra template, `kat`. Only that list allows
# `.env.kat`, so an ALLOW proves the gate followed its link to the list; the embedded copy refuses it.
R="$TMP/clone"; L="$TMP/links"; mkdir -p "$R" "$L"
cp -p "$ROOT/hooks/bash-safety-gate.sh" "$ROOT/hooks/write-safety-gate.sh" "$ROOT/hooks/deny-event.py" "$R/"
sed "s/^SECRET_TEMPLATES='example|sample|template'\$/SECRET_TEMPLATES='example|sample|template|kat'/" \
  "$ROOT/hooks/secret-names.sh" > "$R/secret-names.sh"
if ! grep -q "|kat'" "$R/secret-names.sh"; then
  bad "could not build the marker list (secret-names.sh's SECRET_TEMPLATES line changed shape)"
fi
ln -s "$R/bash-safety-gate.sh" "$L/bash-safety-gate.sh" 2>/dev/null           # absolute target
ln -s "$R/deny-event.py" "$L/deny-event.py" 2>/dev/null
(cd "$L" && ln -s ../clone/write-safety-gate.sh write-safety-gate.sh 2>/dev/null)   # relative target
if [ -L "$L/bash-safety-gate.sh" ] && [ -L "$L/write-safety-gate.sh" ] && ! [ -e "$L/secret-names.sh" ]; then
  expect_read  ALLOW "$L" "ls -la"              linked
  expect_read  ALLOW "$L" "cat $E.kat"          linked
  expect_read  BLOCK "$L" "cat $E"              linked
  expect_write ALLOW "$L" "src/a.py"            linked
  expect_write ALLOW "$L" "app/$E.kat"          linked
  expect_write BLOCK "$L" "app/$E"              linked
else
  leg_not_run "3. symlinked install" "this host cannot create a real symlink, so link-following is unchecked"
fi

stderr_of() {  # stderr_of <gate-dir/gate> <tool> <field> <value>
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))'     "$2" "$3" "$4" | bash "$1" 2>&1 >/dev/null
}

echo " ── 4. an EMPTY or whitespace-only list file is treated as MISSING: the built-in copy, and a warning"
# A truncated or blanked file must not lock every seat out. It holds no list, so the gate ignores it,
# uses its built-in copy (secrets still refused) and says on stderr which file it ignored.
for kind in empty blank comments; do
  X="$TMP/$kind"; mkdir -p "$X"
  cp -p "$ROOT/hooks/bash-safety-gate.sh" "$ROOT/hooks/write-safety-gate.sh" "$ROOT/hooks/deny-event.py" "$X/"
  case $kind in
    empty)    : > "$X/secret-names.sh" ;;
    blank)    printf '  
	

' > "$X/secret-names.sh" ;;
    comments) printf '# secret-names.sh

# (nothing left)
' > "$X/secret-names.sh" ;;
  esac
  expect_read  ALLOW "$X" "ls -la"           "$kind"
  expect_read  BLOCK "$X" "cat $E"           "$kind"
  expect_read  ALLOW "$X" "cat $E.example"   "$kind"
  expect_write ALLOW "$X" "src/a.py"         "$kind"
  expect_write BLOCK "$X" "app/$E"           "$kind"
  for spec in "bash-safety-gate.sh Bash command ls" "write-safety-gate.sh Write file_path src/a.py"; do
    set -- $spec
    why="$(stderr_of "$X/$1" "$2" "$3" "$4")"
    if printf '%s' "$why" | grep -qF "$X/secret-names.sh" && printf '%s' "$why" | grep -q "built-in"; then
      ok "[$kind] $1 warns that it ignored $kind secret-names.sh and used its built-in copy"
    else bad "[$kind] $1 gave no warning naming the ignored file: ${why:-<no stderr>}"; fi
  done
done

echo " ── 5. a list that loads but leaves a value EMPTY refuses, and the refusal names the WAY OUT"
X="$TMP/blanked"; mkdir -p "$X"
cp -p "$ROOT/hooks/bash-safety-gate.sh" "$ROOT/hooks/write-safety-gate.sh" "$ROOT/hooks/deny-event.py" "$X/"
printf "SECRET_NAME=''
" > "$X/secret-names.sh"
expect_read  BLOCK "$X" "ls -la"     blanked
expect_write BLOCK "$X" "src/a.py"   blanked
# Every Bash and Write call is refused, the agent's own repair included, so the message must say which
# file did it and what a human does about it: restore it or delete it, from a terminal.
for spec in "bash-safety-gate.sh Bash command ls" "write-safety-gate.sh Write file_path src/a.py"; do
  set -- $spec
  why="$(stderr_of "$X/$1" "$2" "$3" "$4")"
  miss=""
  for want in "secret-name list is empty" "$X/secret-names.sh" "human" "terminal" "restore" "delete" "built-in copy"; do
    printf '%s' "$why" | grep -qiF -- "$want" || miss="$miss [$want]"
  done
  if [ -z "$miss" ]; then ok "[blanked] $1's refusal names the file and the way out"
  else bad "[blanked] $1's refusal lacks$miss: ${why:-<no stderr>}"; fi
done

echo
echo "  $pass passed, $fail failed"
legs_verdict "$fail"
