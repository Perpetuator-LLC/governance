#!/usr/bin/env bash
# tests/bash-safety-gate-coverage.test.sh — four bash-safety-gate.sh deny rules with ZERO prior
# coverage, found by mutation (quality sweep, 2026-10-14).
#
# Method: each of the gate's ~20 rule ids was checked for a name-match in the existing test files,
# then every rule with no match was actually mutated (its trigger condition replaced with `if false;
# then`, the whole repo's relevant suites re-run) rather than trusting the name-search as a verdict —
# a rule can be exercised by its BEHAVIOUR with no test asserting its rule id by name. Six of the ten
# unnamed rules turned out to be covered that way (process-env-read, stdin-to-interpreter,
# remote-pipe-shell, rm-rf-root, decode-then-execute, decode-to-interpreter — killed, no new test
# needed). These four were not: deleting each one's entire trigger condition left EVERY test in
# hook-input.test.sh, deny-trail.test.sh, zsh-trap-gate.test.sh, terminal-floor.test.sh,
# opaque-payload-gate.test.sh and secret-read-gate.test.sh passing, unchanged.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/bash-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
  "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; }

run() {  # run <command-text> -> exit code; BLOCKED line (if any) in $TMP/err
  printf '%s' "$(bash_json "$1")" | bash "$GATE" >"$TMP/out" 2>"$TMP/err"
  echo $?
}

blocked_as() {  # blocked_as <command> <expected-substring-of-the-BLOCKED-reason>
  local rc; rc=$(run "$1")
  [[ "$rc" == "2" ]] || { fail "$3: exit $rc, not 2 — $1"; return; }
  grep -q "^BLOCKED:" "$TMP/err" || { fail "$3: no BLOCKED line on stderr — $1"; return; }
  if [[ -n "${2:-}" ]]; then
    grep -qi "$2" "$TMP/err" || { fail "$3: BLOCKED but not for the expected reason ($(cat "$TMP/err")) — $1"; return; }
  fi
  pass "$3"
}

allowed() {  # allowed <command> <label>
  local rc; rc=$(run "$1")
  [[ "$rc" == "0" ]] && pass "$2: allowed" || fail "$2: blocked (should be allowed, rc=$rc) — $1"
}

echo "── bash-safety-gate: 4 rules with zero prior coverage"

echo " · keychain-read"
blocked_as 'security find-generic-password -s my-service -w' "keychain" "find-generic-password: blocked"
blocked_as 'security find-internet-password -s example.com -w' "keychain" "find-internet-password: blocked"
allowed 'security list-keychains' "an unrelated 'security' subcommand"

echo " · fork-bomb"
blocked_as ':(){ :|:& };:' "fork-bomb" "the classic literal: blocked"
blocked_as 'x(){ x|x& };x' "fork-bomb" "the same shape under a renamed function: blocked"
allowed 'foo() { echo hi; }; foo' "an ordinary function definition and call"

echo " · container-secret-read"
blocked_as 'docker exec mycontainer env' "container" "docker exec ... env: blocked"
blocked_as 'docker inspect mycontainer | grep -i secret' "container" "docker inspect piped to grep secret: blocked"
blocked_as 'docker exec db printenv DATABASE_PASSWORD' "container" "docker exec ... password: blocked"
allowed 'docker exec mycontainer ls /app' "an ordinary docker exec with no secret-shaped argument"

echo " · database-destroy"
blocked_as 'psql -c "DROP TABLE users;"' "destructive database" "DROP TABLE: blocked"
blocked_as 'mysql -e "DROP DATABASE prod;"' "destructive database" "DROP DATABASE: blocked"
blocked_as 'psql -c "TRUNCATE TABLE sessions;"' "destructive database" "TRUNCATE TABLE: blocked"
blocked_as 'psql -c "DELETE FROM users;"' "destructive database" "unqualified DELETE FROM (no WHERE): blocked"
allowed 'psql -c "DELETE FROM users WHERE id = 1;"' "a qualified DELETE FROM (has a WHERE) is not this rule's shape"
allowed 'psql -c "SELECT * FROM users;"' "an ordinary SELECT"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
