#!/usr/bin/env bash
# tests/restore-safety.test.sh — governance restore's core promise: a path edited since install is
# DISPLACED, never silently deleted.
#
# Found by mutation (quality sweep, 2026-10-14): removing restore_entry's "does the live file still
# match what was installed?" check in bin/governance — so a changed file is unconditionally
# os.unlink()'d instead of moved aside — passed install.test.sh and reconcile.test.sh unchanged. Both
# files restore cleanly in every scenario they construct, so neither one ever puts a human edit in
# restore's path. This is the literal data-loss case the backup/undo mechanism exists to prevent, and
# it had no test of its own.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOV="$ROOT/bin/governance"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GOVERNANCE_DENY_LOG="$TMP/deny.jsonl"
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
gov()  { python3 "$GOV" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; echo $?; }
put()  { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

C="$TMP/core-repo"; A="$TMP/adapter"
put "$C/core/AGENTS.md"           "# core rules"
put "$C/core/domains/security.md" "# core security"
put "$A/AGENTS.md"                "# adapter rules"
H="$TMP/home"; mkdir -p "$H"

echo "governance restore — a path changed since install is DISPLACED, never deleted"

rc="$(gov install --home "$H" --repo "$C" --adapter "$A" --no-local)"
check "install exits 0" "[ '$rc' = '0' ]"
BACKUP="$(ls "$H/.governance-backup" | grep 'Z$' | head -1)"
ORIG_SHA="$(sha256sum "$H/.claude/CLAUDE.md" | awk '{print $1}')"

# --- 1. a human edit to a rendered file survives restore, moved aside, byte for byte ---
printf '\nHUMAN EDIT, NEVER TO BE LOST\n' >> "$H/.claude/CLAUDE.md"
EDITED_SHA="$(sha256sum "$H/.claude/CLAUDE.md" | awk '{print $1}')"
rc="$(gov restore --home "$H")"
check "restore exits 0" "[ '$rc' = '0' ]"
check "…and says the file was moved aside, not silently deleted" \
  "grep -q 'changed since install, moved aside' '$TMP/stdout'"
DISPLACED="$H/.governance-backup/$BACKUP.restored/displaced/.claude/CLAUDE.md"
check "the displaced copy exists" "[ -f '$DISPLACED' ]"
check "…and its content is EXACTLY the human edit, byte for byte (not the original render)" \
  "[ \"\$(sha256sum '$DISPLACED' | awk '{print \$1}')\" = '$EDITED_SHA' ]"
check "nothing at the original path claims to be the human's edit (it was never installed FROM something, so there is nothing to restore it back to)" \
  "[ ! -e '$H/.claude/CLAUDE.md' ] || [ \"\$(sha256sum '$H/.claude/CLAUDE.md' | awk '{print \$1}')\" != '$EDITED_SHA' ]"

# --- 2. control: an UNCHANGED file restores cleanly, with no displaced copy and no data-loss note ---
rc="$(gov install --home "$H" --repo "$C" --adapter "$A" --no-local)"
check "re-install exits 0" "[ '$rc' = '0' ]"
BACKUP2="$(ls "$H/.governance-backup" | grep 'Z$' | tail -1)"
rc="$(gov restore --home "$H")"
check "restore of an untouched install exits 0" "[ '$rc' = '0' ]"
check "…and names no displaced path (nothing changed, nothing to preserve)" \
  "! grep -q 'changed since install, moved aside' '$TMP/stdout'"
check "…and left no displaced/ directory in this backup at all" \
  "[ ! -d \"$H/.governance-backup/$BACKUP2.restored/displaced\" ]"

# --- 3. a directory that gained files since install is left in place, not displaced or deleted ---
rc="$(gov install --home "$H" --repo "$C" --adapter "$A" --no-local)"
BACKUP3="$(ls "$H/.governance-backup" | grep 'Z$' | tail -1)"
mkdir -p "$H/.claude/skills"
put "$H/.claude/skills/not-ours/extra-file.md" "something the install did not create"
rc="$(gov restore --home "$H")"
check "restore exits 0 even when an install-owned dir gained outside content" "[ '$rc' = '0' ]"
check "…and says the directory was left in place, holding files the install did not create" \
  "grep -q 'left in place, holds files the install did not create' '$TMP/stdout'"
check "…and the outside file itself still exists, untouched" \
  "[ -f '$H/.claude/skills/not-ours/extra-file.md' ] && [ \"\$(cat '$H/.claude/skills/not-ours/extra-file.md')\" = 'something the install did not create' ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
