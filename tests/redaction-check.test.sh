#!/usr/bin/env bash
# redaction-check.test.sh
#
# The failures that would make this check WORSE than none are asserted directly, not just the happy
# path: a missing private list reported as clean; a directory or a bad path scanned as "nothing
# found"; Markdown prose compiled into patterns; and the checker itself carrying literal names.
# Every value below is synthetic.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/redaction-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# HOME is isolated: the machine's own ~/.governance/private-patterns would otherwise answer for the
# fixtures, and "no private list ⇒ exit 3" would pass or fail depending on the machine it ran on.
mkdir -p "$TMP/home"
run()  { HOME="$TMP/home" env -u GOVERNANCE_PRIVATE_PATTERNS python3 "$CHECK" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
kind() { grep -q "\"kind\": \"$1\"" "$TMP/out"; }

echo "redaction-check"
check "the script is executable" "[ -x '$CHECK' ]"

mkdir -p "$TMP/c"
cat > "$TMP/c/dirty.md" <<'EOF'
A rule that leaks: call jira_fetch_board_rows and read the row.
Recorded as widget#412 after the incident, in the file mcp__gw__deploy_status.
The gate is defined in ci.yml on the default branch.
Details in /Users/someone/projects/private-vault/notes.md.
Reply to contact@agency.gov; CAGE code 1AB2C and EIN 12-3456789 are on file.
EOF
cat > "$TMP/c/clean.md" <<'EOF'
A rule that travels: verify against an unfiltered read and key on the artifact.
Co-Authored-By: An Agent <noreply@anthropic.com>; examples use user@example.com.
Clone from git@forge.dev:org/repo and write paths as ~/projects/x.
Never enter SSN/passport/government IDs; dated 2026-09-16.
EOF

rc="$(run --json "$TMP/c/dirty.md")"
for k in vendor-tool-noun mcp-tool-path ticket-ref workflow-filename home-path contact-address registration-id; do
  check "shape caught: $k" "kind $k"
done
check "a keyword registration id AND a bare EIN are both caught" "[ \"\$(grep -c '\"registration-id\"' '$TMP/out')\" -ge 2 ]"

rc="$(run --json "$TMP/c/clean.md")"
check "noreply / example domains / git@ / ~ paths / dates / a bare 'SSN' produce no findings" \
  "grep -q '\"findings\": \[\]' '$TMP/out'"

# --- ⚠️ absence-as-health: no private list must NOT read as clean ---------------
rc="$(run "$TMP/c/clean.md")"
check "no private list ⇒ exit 3, not 0" "[ '$rc' = '3' ]"
check "no private list ⇒ says SKIPPED" "grep -q 'SKIPPED' '$TMP/out'"

printf 'literal:host-01.corp\n' > "$TMP/private.txt"
# The machine-local default engages the leg with no flag and no env var, and says where the list came from.
mkdir -p "$TMP/home/.governance"; ln -s "$TMP/private.txt" "$TMP/home/.governance/private-patterns"
mkdir -p "$TMP/d"; echo 'the box host-01.corp is full' > "$TMP/d/default.md"
rc="$(run --enforce "$TMP/d/default.md")"
check "no flag, no env: ~/.governance/private-patterns engages the name leg (exit 1 on a private name)" \
  "[ '$rc' = '1' ] && grep -q 'ran — 1 pattern(s) from' '$TMP/out'"
rc="$(run "$TMP/c/clean.md")"
check "…and a clean file is CHECKED (exit 0), not SKIPPED" "[ '$rc' = '0' ] && ! grep -q 'SKIPPED' '$TMP/out'"
rm "$TMP/home/.governance/private-patterns"
rc="$(run --private-patterns "$TMP/private.txt" "$TMP/c/clean.md")"
check "with a private list, a clean file exits 0" "[ '$rc' = '0' ]"
echo 'the box host-01.corp is full; hostX01Xcorp is not it' > "$TMP/c/host.md"
rc="$(run --json --private-patterns "$TMP/private.txt" "$TMP/c/host.md")"
check "a private literal name is caught" "grep -q 'instance-name' '$TMP/out'"
check "literal: is escaped — the dot is not a wildcard" "[ \"\$(grep -c 'instance-name' '$TMP/out')\" = '1' ]"

printf -- '---\ntype: note\n---\nSome prose about hosts.\n\n```redaction-instances\nliteral:host-01.corp\n```\n' > "$TMP/note.md"
rc="$(run --json --private-patterns "$TMP/note.md" "$TMP/c/host.md")"
check "a fenced Markdown inventory reads only the fence" "grep -q '1 pattern(s)' '$TMP/out'"
printf -- '---\ntype: note\n---\nSome prose.\n' > "$TMP/nofence.md"
rc="$(run --private-patterns "$TMP/nofence.md" "$TMP/c/clean.md")"
check "Markdown with no fence ⇒ refused (exit 3), never compiled" "[ '$rc' = '3' ]"

# --- report-only vs enforce; paths ------------------------------------------------
rc="$(run --private-patterns "$TMP/private.txt" "$TMP/c/dirty.md")"
check "report-only: findings do not fail" "[ '$rc' = '0' ]"
rc="$(run --enforce --private-patterns "$TMP/private.txt" "$TMP/c/dirty.md")"
check "--enforce: findings fail" "[ '$rc' = '1' ]"
rc="$(run --json "$TMP/c")"
check "a directory argument is expanded, not counted as one file" "grep -q '\"files_scanned\": 3' '$TMP/out'"
rc="$(run "$TMP/c/nope.md")"
check "a nonexistent path ⇒ exit 2" "[ '$rc' = '2' ]"

# --- a private name on a comment line is still a private name ----------------------
mkdir -p "$TMP/cm"; printf '#!/bin/sh\n# deploys to acme-fe after the gate\necho ok\n' > "$TMP/cm/commented.sh"
printf 'literal:acme-fe\n' > "$TMP/mpriv"
rc="$(run --json --private-patterns "$TMP/mpriv" "$TMP/cm/commented.sh")"
check "a private name on a '#' comment line is caught (comment lines skip SHAPES only)" "kind 'instance-name:1'"

# --- commit messages (--commits) ---------------------------------------------------
# Expected values derived by hand from the scratch history and the one-name list (acme-fe):
#   c1 cites widget#12 and names ci.yml   -> 0  (a message may cite its ticket and the files it changed)
#   c2 trailer "Seat: acme-fe"            -> 1 instance-name
#   c3 mentions /Users/someone/notes      -> 1 home-path
#   c4 Co-Authored-By <noreply@...>       -> 0
#   c5 acme-fe on a '#' line              -> 1 instance-name
#   s1 on a side branch, clean            -> 0
#   M  merge of side, names acme-fe       -> 1 instance-name (merges are read)
#   root..HEAD: 7 commits, 4 findings (3 instance, 1 home-path) · c5..HEAD: 2 commits, 1 · HEAD..HEAD: 0
G="$TMP/g"; git init -q "$G"
gc() { git -C "$G" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty --cleanup=verbatim -m "$1"; }
gc "root"; R=$(git -C "$G" rev-parse HEAD)
gc "$(printf 'add x\n\nfor widget#12; edits ci.yml')"
gc "$(printf 'fix y\n\nSeat: acme-fe')"
gc "$(printf 'docs\n\nlogged at /Users/someone/notes')"
gc "$(printf 'chore\n\nCo-Authored-By: An Agent <noreply@anthropic.com>')"
gc "$(printf 'tidy\n\n# carried over from acme-fe')"; C5=$(git -C "$G" rev-parse HEAD)
git -C "$G" checkout -q -b side; gc "side work"; git -C "$G" checkout -q -
git -C "$G" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false merge -q --no-ff --cleanup=verbatim \
  -m "$(printf 'Merge side\n\nInitiated-By: acme-fe lane')" side
cr() { (cd "$G" && run "$@"); }
rc="$(cr --json --private-patterns "$TMP/mpriv" --commits "$R..HEAD")"
check "root..HEAD: 7 commit messages scanned, report-only exit 0" \
  "[ '$rc' = '0' ] && grep -q '\"commits_scanned\": 7' '$TMP/out'"
check "root..HEAD: 4 findings, 3 names and 1 home path" \
  "[ \"\$(grep -c '\"kind\"' '$TMP/out')\" = 4 ] && [ \"\$(grep -c '\"instance-name:1\"' '$TMP/out')\" = 3 ] && kind home-path"
check "a message may cite its ticket and its files: no ticket-ref, no workflow-filename" \
  "! kind ticket-ref && ! kind workflow-filename"
check "a name on a message's '#' line is caught" "grep -q \"commit:\$(echo $C5 | cut -c1-12)\" '$TMP/out'"
rc="$(cr --enforce --private-patterns "$TMP/mpriv" --commits "$R..HEAD")"
check "--enforce: a name in a message fails (exit 1)" "[ '$rc' = '1' ]"
rc="$(cr --json --private-patterns "$TMP/mpriv" --commits "$C5..HEAD")"
check "c5..HEAD: the side commit and the merge, 1 finding (the merge's)" \
  "grep -q '\"commits_scanned\": 2' '$TMP/out' && [ \"\$(grep -c '\"kind\"' '$TMP/out')\" = 1 ]"
rc="$(cr --json --enforce --private-patterns "$TMP/mpriv" --commits "HEAD..HEAD")"
check "an empty range is a clean answer: 0 scanned, exit 0" "[ '$rc' = '0' ] && grep -q '\"commits_scanned\": 0' '$TMP/out'"
rc="$(cr --private-patterns "$TMP/mpriv" --commits "no-such-ref..HEAD")"
check "a range git refuses ⇒ exit 2, never clean" "[ '$rc' = '2' ]"
rc="$(cr --private-patterns "$TMP/mpriv" --commits "$R..HEAD" "$TMP/c/clean.md")"
check "--commits with a path ⇒ exit 2" "[ '$rc' = '2' ]"
rc="$(cr --commits "$R..HEAD")"
check "messages with no private list ⇒ exit 3, SKIPPED" "[ '$rc' = '3' ] && grep -q 'SKIPPED' '$TMP/out'"

# --- the checker must not BE the disclosure ----------------------------------------
check "the checker embeds no quoted dotted hostname" \
  "! grep -qE '\"[a-z0-9-]+\.(internal|lan|local|corp|io|com)\"' '$CHECK'"

# --- the gate: this tree, shape leg enforced (instance leg runs where the list lives) --
rc="$(run --enforce)"
check "THIS TREE: no shape findings (exit 0, or 3 = instance leg not checked here)" "[ '$rc' = '0' ] || [ '$rc' = '3' ]"
[ "$rc" = '0' ] || [ "$rc" = '3' ] || sed 's/^/      /' "$TMP/out"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
