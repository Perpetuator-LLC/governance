#!/usr/bin/env bash
# install.test.sh — bin/governance install / check --home / restore / discover
#
# An installer is trusted with a live home directory, so the claims that matter are the ones a user
# cannot see from the outside: that it can be undone EXACTLY (a symlink comes back pointing where it
# did, a file comes back byte for byte), that running it again changes nothing, that no adapter can
# remove the floor, and that drift is named for what it is. Every fixture lives under mktemp — never
# the real home.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOV="$ROOT/bin/governance"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
gov()  { python3 "$GOV" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; echo $?; }
put()  { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
backups() { ls "$1/.governance-backup" 2>/dev/null | grep -c 'Z$'; }

# Every path under a tree with its kind and its link target or content hash — the backup store excluded.
snap() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for d, dirs, files in os.walk(root):
    if d == root:
        dirs[:] = [x for x in dirs if x != ".governance-backup"]
    dirs.sort()
    for n in sorted(dirs + files):
        p = os.path.join(d, n); rel = os.path.relpath(p, root)
        if os.path.islink(p):
            print("link", rel, os.readlink(p))
        elif os.path.isdir(p):
            print("dir ", rel)
        else:
            print("file", rel, hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}

# --- fixtures: a core repository, two adapters, a local layer, and a home with prior config ----------
C="$TMP/core-repo"; A1="$TMP/adapter-one"; A2="$TMP/adapter-two"; LOCAL="$TMP/local.md"
put "$C/core/AGENTS.md"              "# core rules"
put "$C/core/domains/security.md"    "# core security"
put "$C/core/domains/ops.md"         "# core ops"
put "$C/skills/shared/SKILL.md"      "core shared skill"
put "$C/skills/core-only/SKILL.md"   "core-only skill"
put "$C/hooks/gate.sh"               "echo gate"
put "$C/agents/reviewer.md"          "reviewer"
put "$C/bin/tool"                    "tool"
put "$C/settings/claude.json" '{"permissions": {"deny": ["Bash(rm -rf *)", "Bash(git push --force*)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/gate.sh"}]}]}}'
put "$A1/AGENTS.md"                  "# adapter one rules"
put "$A1/domains/security.md"        "# adapter security"
put "$A1/domains/org.md"             "# adapter org domain"
put "$A1/skills/shared/SKILL.md"     "adapter shared skill"
put "$A1/skills/a1-only/SKILL.md"    "adapter skill"
put "$A1/hooks/extra.sh"             "echo extra"
put "$A1/agents/helper.md"           "helper"
put "$A1/harness/grok/agents/worker.md"  "grok worker"
put "$A1/harness/grok/agents/helper.md"  "grok helper override"
put "$A1/bin/orgtool"                "orgtool"
put "$A1/scheduled-tasks/daily/SKILL.md" "daily"
put "$A1/settings/claude.json" '{"permissions": {"deny": ["Bash(adapter-deny*)"], "allow": ["Bash(ls*)"]},
 "model": "adapter-model",
 "hooks": {"PreToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/extra.sh"}]}]}}'
put "$A2/AGENTS.md"                  "# adapter two rules"
put "$A2/settings/claude.json"       '{"permissions": {"deny": []}}'     # tries to empty the floor
put "$LOCAL"                         "# local override"

H="$TMP/home"
mkdir -p "$H/.claude"
put "$TMP/elsewhere/OLD.md" "# an older instruction file"
ln -s "$TMP/elsewhere/OLD.md" "$H/.claude/CLAUDE.md"
printf '{"theme": "dark"}\n' > "$H/.claude/settings.json"
cp "$H/.claude/settings.json" "$TMP/settings.before"
# The layout a link-based installer leaves: skills/ one symlink to a directory elsewhere, hooks/ a real
# directory mixing a same-named hook symlink with a hook this installer knows nothing about.
put "$TMP/old-skills/legacy/SKILL.md" "legacy skill"
put "$TMP/old-skills/core-only/SKILL.md" "an old copy of a skill core also provides"
ln -s "$TMP/old-skills" "$H/.claude/skills"
mkdir -p "$H/.claude/hooks"
ln -s "$TMP/elsewhere/OLD.md" "$H/.claude/hooks/gate.sh"
put "$H/.claude/hooks/unrelated.sh" "echo not ours"
snap "$TMP/old-skills" > "$TMP/old-skills.before"
snap "$H" > "$TMP/home.before"
I=(install --home "$H" --repo "$C" --adapter "$A1" --adapter "$A2" --local "$LOCAL")

echo "governance install — refusals and dry run"
check "the script is executable" "[ -x '$GOV' ]"
rc="$(gov install --repo "$C" --adapter "$A1")"
check "install without --home is refused (exit 2) — the real home is never a default" "[ '$rc' = '2' ]"

rc="$(gov "${I[@]}" --dry-run)"
check "--dry-run exits 0" "[ '$rc' = '0' ]"
check "…and says what it would replace" "grep -q 'would replace  .claude/CLAUDE.md (was symlink)' '$TMP/stdout'"
snap "$H" > "$TMP/home.after"
check "…and writes nothing: no output, no backup, no state" \
  "cmp -s '$TMP/home.before' '$TMP/home.after' && [ ! -e '$H/.governance-backup' ] && [ ! -e '$H/.governance-state.json' ]"

refused_clean() {  # label, then install args after --home; asserts exit 2 and an untouched empty home
  local label="$1"; shift
  local h="$TMP/home-refused-$RANDOM"; mkdir -p "$h"
  rc="$(gov install --home "$h" --repo "$C" "$@")"
  check "$label ⇒ refused (exit 2), nothing written" "[ '$rc' = '2' ] && [ -z \"\$(ls -A '$h')\" ]"
}
put "$TMP/a-replace/settings/claude.json" '{"permissions": {"deny": "nothing"}}'
refused_clean "an adapter replacing permissions.deny with a non-list" --adapter "$TMP/a-replace"
check "…naming the key" "grep -q 'permissions.deny' '$TMP/stderr'"
put "$TMP/a-nohooks/settings/claude.json" '{"disableAllHooks": true}'
refused_clean "an adapter setting disableAllHooks" --adapter "$TMP/a-nohooks"
put "$TMP/a-shadow/hooks/gate.sh" "echo not the gate"
refused_clean "an adapter shipping a hook with a core hook's name" --adapter "$TMP/a-shadow"
put "$TMP/a-tasks/scheduled-tasks/other/SKILL.md" "other"
refused_clean "two adapters providing scheduled-tasks" --adapter "$A1" --adapter "$TMP/a-tasks"
check "…naming scheduled-tasks" "grep -q 'scheduled-tasks' '$TMP/stderr'"

echo "governance install — outputs"
rc="$(gov "${I[@]}")"; cp "$TMP/stdout" "$TMP/install.out"
check "install exits 0" "[ '$rc' = '0' ]"
check "CLAUDE.md is a real file, not a link" "[ -f '$H/.claude/CLAUDE.md' ] && [ ! -L '$H/.claude/CLAUDE.md' ]"
order="$(grep -E '^# ' "$H/.claude/CLAUDE.md" | tr '\n' '|')"
check "CLAUDE.md order: core → adapter one → adapter two → local" \
  "[ '$order' = '# core rules|# adapter one rules|# adapter two rules|# local override|' ]"
check "governance/<domain>.md are real files" \
  "[ -f '$H/.claude/governance/security.md' ] && [ ! -L '$H/.claude/governance/security.md' ]"
order="$(grep -E '^# ' "$H/.claude/governance/security.md" | tr '\n' '|')"
check "a domain in core and an adapter renders core first, then the adapter" \
  "[ '$order' = '# core security|# adapter security|' ]"
check "a core-only and an adapter-only domain are both rendered" \
  "grep -q '^# core ops' '$H/.claude/governance/ops.md' && grep -q '^# adapter org domain' '$H/.claude/governance/org.md'"
check "skills/ is a real directory holding core and adapter skills as symlinks" \
  "[ -d '$H/.claude/skills' ] && [ ! -L '$H/.claude/skills' ] && [ -L '$H/.claude/skills/core-only' ] && [ -L '$H/.claude/skills/a1-only' ]"
check "a skill-name collision goes to the later layer" \
  "[ \"\$(readlink '$H/.claude/skills/shared')\" = '$A1/skills/shared' ]"
check "…and is reported" "grep -q 'COLLISION  skills/shared: core overridden by adapter 1' '$TMP/install.out'"
check "hooks, agents and bin hold per-file symlinks from core and adapters" \
  "[ -L '$H/.claude/hooks/gate.sh' ] && [ -L '$H/.claude/hooks/extra.sh' ] && [ -L '$H/.claude/agents/reviewer.md' ] && [ -L '$H/.claude/agents/helper.md' ] && [ -L '$H/.claude/bin/tool' ] && [ -L '$H/.claude/bin/orgtool' ]"
check "a symlinked skills/ is replaced by a real directory without writing through the old link" \
  "snap '$TMP/old-skills' | cmp -s - '$TMP/old-skills.before' && [ ! -e '$H/.claude/skills/legacy' ]"
check "a hook in hooks/ that no layer provides is left alone" \
  "[ -f '$H/.claude/hooks/unrelated.sh' ] && [ \"\$(readlink '$H/.claude/hooks/gate.sh')\" = '$C/hooks/gate.sh' ]"
check "scheduled-tasks links to the one adapter providing it" \
  "[ \"\$(readlink '$H/.claude/scheduled-tasks')\" = '$A1/scheduled-tasks' ]"
settings_ok() {
  python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
deny = s["permissions"]["deny"]
assert deny[:2] == ["Bash(rm -rf *)", "Bash(git push --force*)"], deny
assert "Bash(adapter-deny*)" in deny, deny
assert s["permissions"]["allow"] == ["Bash(ls*)"]
assert s["model"] == "adapter-model"
pre = s["hooks"]["PreToolUse"]
assert pre[0]["hooks"][0]["command"] == "bash ~/.claude/hooks/gate.sh" and len(pre) == 2, pre
PY
}
check "settings.json is a real file merging core then adapters" "[ -f '$H/.claude/settings.json' ] && [ ! -L '$H/.claude/settings.json' ]"
check "…keeping every core deny entry and hook although adapter two sets deny to []" "settings_ok 2>/dev/null"
state_ok() {
  python3 - "$H/.governance-state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert all(len(x["sha256"]) == 64 for x in s["sources"]) and len(s["sources"]) >= 7, s["sources"]
kinds = {o["type"] for o in s["outputs"]}
assert kinds == {"dir", "file", "symlink"}, kinds
assert all(("sha256" in o) == (o["type"] == "file") and ("target" in o) == (o["type"] == "symlink") for o in s["outputs"])
PY
}
check "the state file records sources (path + sha256) and outputs (path + type + sha256/target)" "state_ok 2>/dev/null"
check "one backup, with a manifest" "[ \"\$(backups '$H')\" = '1' ] && [ -f \"\$(ls -d '$H'/.governance-backup/*Z)/manifest.json\" ]"

echo "governance install — idempotence"
rc="$(gov "${I[@]}")"
check "re-install exits 0" "[ '$rc' = '0' ]"
check "…changes nothing and writes no second backup" \
  "grep -q 'nothing to install' '$TMP/stdout' && [ \"\$(backups '$H')\" = '1' ]"

echo "governance check --home"
rc="$(gov check --home "$H")"
check "right after install: in sync (exit 0), every output reported" \
  "[ '$rc' = '0' ] && [ \"\$(grep -c '^in sync' '$TMP/stdout')\" -ge 20 ] && ! grep -qv '^in sync' '$TMP/stdout'"

cp "$A1/AGENTS.md" "$TMP/a1-agents.bak"
echo "# adapter one rules, amended" > "$A1/AGENTS.md"
rc="$(gov check --home "$H")"
check "an edited adapter AGENTS.md ⇒ drift (exit 1)" "[ '$rc' = '1' ]"
check "…reported as LAYERS CHANGED on CLAUDE.md" "grep -q 'LAYERS CHANGED  $H/.claude/CLAUDE.md' '$TMP/stdout'"
cp "$TMP/a1-agents.bak" "$A1/AGENTS.md"
rc="$(gov check --home "$H")"
check "…and in sync again once the layer is put back" "[ '$rc' = '0' ]"

mkdir -p "$A1/skills/new-skill"
rc="$(gov check --home "$H")"
check "a skill added to an adapter ⇒ LAYERS CHANGED (exit 1)" \
  "[ '$rc' = '1' ] && grep -q 'LAYERS CHANGED  $H/.claude/skills/new-skill' '$TMP/stdout'"
rmdir "$A1/skills/new-skill"

printf '\nan edit made directly in the rendered file\n' >> "$H/.claude/CLAUDE.md"
cp "$H/.claude/CLAUDE.md" "$TMP/claude.edited"
rc="$(gov check --home "$H")"
check "a hand edit to rendered CLAUDE.md ⇒ drift (exit 1)" "[ '$rc' = '1' ]"
check "…reported as EDITED BY HAND, not LAYERS CHANGED" \
  "grep -q 'EDITED BY HAND  $H/.claude/CLAUDE.md' '$TMP/stdout' && ! grep -q 'LAYERS CHANGED' '$TMP/stdout'"
rc="$(gov "${I[@]}")"
check "re-installing over a hand edit writes a new backup holding the edit" \
  "[ '$rc' = '0' ] && [ \"\$(backups '$H')\" = '2' ] && cmp -s \"\$(ls -d '$H'/.governance-backup/*Z | sort | tail -1)/files/.claude/CLAUDE.md\" '$TMP/claude.edited'"

rm "$H/.claude/skills/core-only"
rc="$(gov check --home "$H")"
check "a deleted skill symlink ⇒ MISSING (exit 1)" \
  "[ '$rc' = '1' ] && grep -q 'MISSING  $H/.claude/skills/core-only' '$TMP/stdout'"
gov "${I[@]}" >/dev/null

ln -sfn "$TMP/elsewhere/OLD.md" "$H/.claude/hooks/gate.sh"
rc="$(gov check --home "$H")"
check "a repointed hook symlink ⇒ LINK MOVED (exit 1)" \
  "[ '$rc' = '1' ] && grep -q 'LINK MOVED  $H/.claude/hooks/gate.sh' '$TMP/stdout'"
gov "${I[@]}" >/dev/null
rc="$(gov check --home "$H")"
check "re-install repairs it: in sync" "[ '$rc' = '0' ]"

mv "$A2" "$TMP/adapter-two-moved"
rc="$(gov check --home "$H")"
check "a recorded adapter that no longer exists ⇒ cannot run (exit 2)" "[ '$rc' = '2' ]"
mv "$TMP/adapter-two-moved" "$A2"

echo "governance restore"
first="$(ls "$H/.governance-backup" | grep 'Z$' | sort | head -1)"
rc="$(gov restore --home "$H" --backup "$first")"
check "restore --backup <first> exits 0, undoing every install since" "[ '$rc' = '0' ]"
check "CLAUDE.md is the same symlink again" \
  "[ -L '$H/.claude/CLAUDE.md' ] && [ \"\$(readlink '$H/.claude/CLAUDE.md')\" = '$TMP/elsewhere/OLD.md' ]"
check "settings.json is a real file with the same bytes again" \
  "[ -f '$H/.claude/settings.json' ] && [ ! -L '$H/.claude/settings.json' ] && cmp -s '$H/.claude/settings.json' '$TMP/settings.before'"
snap "$H" > "$TMP/home.after"
check "the whole home matches its pre-install snapshot" "cmp -s '$TMP/home.before' '$TMP/home.after'"
check "every backup it applied is marked restored" "[ \"\$(backups '$H')\" = '0' ]"
rc="$(gov restore --home "$H")"
check "restore with nothing left to restore ⇒ exit 2" "[ '$rc' = '2' ]"

gov "${I[@]}" >/dev/null
rc="$(gov restore --home "$H")"
snap "$H" > "$TMP/home.after"
check "install then a bare restore (newest backup) returns the home exactly" \
  "[ '$rc' = '0' ] && cmp -s '$TMP/home.before' '$TMP/home.after'"

echo "governance install — codex and grok"
HG="$TMP/home-codex-grok"; mkdir -p "$HG"
rc="$(gov install --home "$HG" --repo "$C" --adapter "$A1" --harness codex --harness grok)"
check "install --harness codex --harness grok exits 0" "[ '$rc' = '0' ]"
check "codex: AGENTS.md rendered core → adapter" \
  "[ -f '$HG/.codex/AGENTS.md' ] && [ ! -L '$HG/.codex/AGENTS.md' ] && [ \"\$(grep -E '^# ' '$HG/.codex/AGENTS.md' | tr '\n' '|')\" = '# core rules|# adapter one rules|' ]"
check "grok: rules/00-governance.md rendered, skills/ a real directory of symlinks" \
  "[ -f '$HG/.grok/rules/00-governance.md' ] && [ -d '$HG/.grok/skills' ] && [ ! -L '$HG/.grok/skills' ] && [ -L '$HG/.grok/skills/a1-only' ]"
check "grok: agents/ installed — shared from core+adapter, plus harness-specific" \
  "[ -d '$HG/.grok/agents' ] && [ ! -L '$HG/.grok/agents' ] && [ -L '$HG/.grok/agents/reviewer.md' ] && [ -L '$HG/.grok/agents/worker.md' ]"
check "grok: harness/grok/agents OVERRIDES the shared agent of the same name" \
  "[ \"\$(cat '$HG/.grok/agents/helper.md')\" = 'grok helper override' ]"
check "…and no claude output" "[ ! -e '$HG/.claude' ]"
rc="$(gov check --home "$HG")"
check "…in sync" "[ '$rc' = '0' ]"

echo "governance install — THIS repository as core"
HR="$TMP/home-real"; mkdir -p "$HR"
rc="$(gov install --home "$HR" --adapter "$A2")"
check "THIS repository installs" "[ '$rc' = '0' ]"
floor_ok() {
  python3 - "$HR/.claude/settings.json" "$ROOT/settings/claude.json" <<'PY'
import json, sys
s, core = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert core["permissions"]["deny"] and s["permissions"]["deny"] == core["permissions"]["deny"]
wired = json.dumps(s["hooks"])
for hook in ("bash-safety-gate.sh", "write-safety-gate.sh", "script-audit.sh", "post-edit-lint.sh"):
    assert hook in wired, hook
PY
}
check "…its settings carry the floor: every core deny rule and the four hooks" "floor_ok 2>/dev/null"
check "…every hook the settings wire is installed" \
  "( for h in bash-safety-gate.sh write-safety-gate.sh script-audit.sh post-edit-lint.sh; do [ -L '$HR/.claude/hooks/'\$h ] || exit 1; done )"
rc="$(gov check --home "$HR")"
check "…in sync" "[ '$rc' = '0' ]"
rc="$(python3 "$HR/.claude/bin/governance" render --out "$TMP/via-link.md" >/dev/null 2>&1; echo $?)"
check "the installed bin/governance finds its own core through the symlink" "[ '$rc' = '0' ]"

echo "governance discover"
R="$TMP/root"
mkdir -p "$R/repo-one/.git" "$R/repo-one/org-adapter/skills" "$R/vault/.obsidian" "$R/not-adapter" \
         "$R/repo-one/node_modules/dep/.git" "$R/worktree"
touch "$R/repo-one/org-adapter/AGENTS.md" "$R/not-adapter/AGENTS.md"
echo "gitdir: elsewhere" > "$R/worktree/.git"
HD="$TMP/home-discover"; mkdir -p "$HD"
gov install --home "$HD" --repo "$C" --adapter "$R/repo-one/org-adapter" >/dev/null
snap "$R" > "$TMP/root.before"
rc="$(gov discover --root "$R" --home "$HD")"
cp "$TMP/stdout" "$TMP/discover.json"
discover_ok() {
  python3 - "$TMP/discover.json" "$R" <<'PY'
import json, os, sys
d, r = json.load(open(sys.argv[1])), sys.argv[2]
assert d["repos"] == [os.path.join(r, "repo-one"), os.path.join(r, "worktree")], d["repos"]
assert d["vaults"] == [os.path.join(r, "vault")], d["vaults"]
assert d["adapters"] == [{"path": os.path.join(r, "repo-one", "org-adapter"), "parts": ["skills"], "installed": True}], d["adapters"]
PY
}
check "discover exits 0" "[ '$rc' = '0' ]"
check "…lists repos (a .git file too, not inside node_modules), vaults, and adapters with the installed one marked" \
  "discover_ok 2>/dev/null"
snap "$R" > "$TMP/root.after"
check "…and writes nothing under the root" "cmp -s '$TMP/root.before' '$TMP/root.after'"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
