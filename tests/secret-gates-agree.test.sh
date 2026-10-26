#!/usr/bin/env bash
# secret-gates-agree.test.sh — the read gate and the write gate give the SAME verdict on the same name.
#
# They used to keep two lists, and the lists drifted both ways: `.envrc.local` was refused to READ but
# allowed to WRITE (a secret file left writable), and `.env.example.local` / `.env.sample2` were allowed
# to read but refused to write. Both gates now source one definition (hooks/secret-names.sh). This
# table runs each name through BOTH hooks on the harness's stdin channel and asserts each verdict
# against the expected one, so two gates that agree on a WRONG answer still fail.
#
# The read leg runs on the host's PATH. It needs python3 (without it the read gate fails closed on a
# template name, by design; secret-read-gate.test.sh's no-python leg covers that).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READ_GATE="$ROOT/hooks/bash-safety-gate.sh"
WRITE_GATE="$ROOT/hooks/write-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"   # never the real deny trail
pass=0; fail=0

command -v python3 >/dev/null 2>&1 || { echo "  ❌ NOT RUN: python3 is required to build the payloads"; exit 1; }

verdict() {  # verdict <gate> <tool> <field> <value> -> BLOCK | ALLOW | EXIT<n>
  local rc
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' \
    "$2" "$3" "$4" | bash "$1" >/dev/null 2>&1
  rc=$?
  case $rc in 2) echo BLOCK ;; 0) echo ALLOW ;; *) echo "EXIT$rc" ;; esac
}

check() {  # check <expected> <path>
  local r w
  r=$(verdict "$READ_GATE" Bash command "cat $2")
  w=$(verdict "$WRITE_GATE" Write file_path "$2")
  if [[ "$r" == "$1" && "$w" == "$1" ]]; then
    echo "  ✅ $1  $2"; pass=$((pass+1))
  else
    echo "  ❌ $2: expected $1 on both, got READ $r / WRITE $w"; fail=$((fail+1))
  fi
}

echo "secret gates — read and write agree, name by name"
for p in app/.env app/.env.local app/.env.production app/.env.local.bak app/.ENV app/.Env.Stage \
         app/.envrc app/.ENVRC app/.envrc.local app/.envrc.private \
         app/.env.example.local app/.env.template.prod app/.env.sample2 app/.env/.env.example \
         'C:\proj\.env' 'C:\proj\.envrc.local'; do
  check BLOCK "$p"
done
# A template strip that REPEATS removes `.env.example`, then the `.env.sample` it exposed, and lets a
# real name through as nothing. The strip is one pass over the name as given, so these stay refused.
for p in app/.env.sample.env.example app/.env.example.env.example; do
  check BLOCK "$p"
done
# A DIRECTORY named after a template is not a secret file: the strip also ends a name at `/`.
check ALLOW app/.env.example/notes.txt
# A `\` is read as a Windows `/` AND as written (the read gate also as a bash escape), refused if any
# spelling matches. `cat .env.example\.local` reads `.env.example.local` in bash; on Linux the same
# Write path is one non-template file. So these are refused by both gates — including, fail closed, a
# backslash path inside a template directory, which bash reads as `C:proj.env.examplenotes.txt`.
for p in 'app/.env.example\.local' 'app/.env.sample\2' 'app/.env.template\x' 'app/.env.example\.prod' \
         'app/.ENV.EXAMPLE\.LOCAL' 'C:\proj\.env.example\.local' 'C:\proj\.env.example\notes.txt'; do
  check BLOCK "$p"
done
for p in app/.env.example app/.env.sample app/.env.template app/.ENV.EXAMPLE \
         app/environment.md app/.envoy.yaml src/sample.environment.ts 'C:\proj\.env.example'; do
  check ALLOW "$p"
done

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
