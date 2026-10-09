#!/usr/bin/env bash
# reconcile.test.sh — bin/governance discover --write / reconcile / install --write-manifest
#
# A reconciler earns trust by what it does NOT do: a second run over a home and vaults already in
# state must write nothing (no backup, no rewrite, no mtime bump), and a vault file it manages must
# keep every byte it does not own. Those two claims are the ones a user cannot see from a green
# exit code, so they are asserted here by mtime, by backup-directory count and by byte comparison.
# Every fixture lives under mktemp — never the real home or a real vault.

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
status_of() { grep -E "^$1 +.*$2( — .*)?\$" "$TMP/stdout" >/dev/null; }
count_status() { grep -cE "^$1 " "$TMP/stdout"; }
# Every regular file under a tree with its mtime (ns) and content hash — the backup store excluded.
snap() {
  python3 - "$@" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x != ".governance-backup")
        for n in sorted(files):
            p = os.path.join(d, n)
            if os.path.islink(p):
                continue
            st = os.stat(p)
            print(os.path.relpath(p, root), st.st_mtime_ns, hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}

# --- fixtures: a core repository, a root holding an adapter vault and two member vaults, a home ------
C="$TMP/core-repo"
put "$C/core/AGENTS.md"           "# core rules"
put "$C/core/domains/security.md" "# core security"
put "$C/hooks/gate.sh"            "echo gate"
put "$C/settings/claude.json"     '{"permissions": {"deny": ["Bash(rm -rf *)"]}}'
R="$TMP/root"; ORG="$R/org-vault"; ME="$R/personal-vault"; CL="$R/client-vault"
mkdir -p "$ORG/.obsidian" "$ORG/.governance" "$ME/.obsidian" "$CL"
put "$ORG/.governance/AGENTS.md" "# organisation rules"
put "$CL/GOVERNANCE.md"          "# a vault with only a pointer file, no .obsidian"
put "$ME/CLAUDE.md"              "# personal vault notes for agents"
H="$TMP/home"; mkdir -p "$H/.claude" "$H/.codex"

echo "governance discover — classification and the manifest"
rc="$(gov discover --root "$R" --home "$H")"
cp "$TMP/stdout" "$TMP/discover.json"
discover_ok() {
  python3 - "$TMP/discover.json" "$R" "$H" <<'PY'
import json, os, sys
d, r, h = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
m = d["manifest"]
roles = {v["name"]: v["role"] for v in m["vaults"]}
assert roles == {"org-vault": "adapter", "personal-vault": "member", "client-vault": "member"}, roles
assert m["adapter"] == {"vault": os.path.join(r, "org-vault"), "path": os.path.join(r, "org-vault", ".governance")}, m["adapter"]
assert m["harnesses"] == ["claude", "codex"], m["harnesses"]
assert m["version"] == 1 and m["home"] == h and m["local"] is None and m["updated"].endswith("Z")
assert d["manifest_path"] == os.path.join(h, ".governance", "manifest.json")
PY
}
check "discover exits 0" "[ '$rc' = '0' ]"
check "…classifies the vault holding .governance/AGENTS.md as adapter, the others (one by .obsidian, one by GOVERNANCE.md) as member" \
  "discover_ok 2>/dev/null"
check "…detects the harness homes present (.claude, .codex; no .grok)" "discover_ok 2>/dev/null"
check "…and without --write writes no manifest" "[ ! -e '$H/.governance' ]"
rc="$(gov discover --root "$R" --write)"
check "--write without --home is refused (exit 2)" "[ '$rc' = '2' ]"

mkdir -p "$R/second-org/.governance" "$R/second-org/.obsidian"
put "$R/second-org/.governance/AGENTS.md" "# a second organisation"
rc="$(gov discover --root "$R" --home "$H" --write)"
check "two adapter vaults ⇒ --write refused (exit 2), naming both" \
  "[ '$rc' = '2' ] && grep -q 'org-vault' '$TMP/stderr' && grep -q 'second-org' '$TMP/stderr' && [ ! -e '$H/.governance/manifest.json' ]"
rm -r "$R/second-org"

echo "governance reconcile — no manifest"
rc="$(gov reconcile --home "$H")"
check "reconcile without a manifest ⇒ exit 2, saying to run discover --write" \
  "[ '$rc' = '2' ] && grep -q 'discover --write' '$TMP/stderr'"

echo "governance reconcile — first run brings everything into state"
rc="$(gov discover --root "$R" --home "$H" --write)"
check "discover --write exits 0 and writes the manifest" "[ '$rc' = '0' ] && [ -f '$H/.governance/manifest.json' ]"
# The manifest names THIS repository as core; point it at the fixture core so the test owns every input.
python3 - "$H/.governance/manifest.json" "$C" <<'PY'
import json, sys
p, core = sys.argv[1], sys.argv[2]
m = json.load(open(p)); m["core"] = core
json.dump(m, open(p, "w"), indent=2)
PY
rc="$(gov reconcile --home "$H")"; cp "$TMP/stdout" "$TMP/run1.out"
check "first reconcile exits 0" "[ '$rc' = '0' ]"
check "…every item ok or fixed, none refused" "[ \"\$(count_status refused)\" = '0' ]"
check "…the adapter already had AGENTS.md: ok" "status_of ok 'org-vault/.governance/AGENTS.md'"
check "…the home was installed: fixed" "status_of fixed \"$H\" && [ -f '$H/.claude/CLAUDE.md' ] && [ -f '$H/.codex/AGENTS.md' ]"
check "…GOVERNANCE.md fixed in all three vaults, CLAUDE.md fixed in all three" \
  "[ \"\$(grep -c 'fixed .*GOVERNANCE.md' '$TMP/run1.out')\" = '3' ] && [ \"\$(grep -c 'fixed .*CLAUDE.md' '$TMP/run1.out')\" = '3' ]"
check "…drift after the install: ok" "status_of ok \"drift $H\""
gov_md_ok() {  # file, expected role, expected adapter ref
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
assert t.startswith("---\n"); fm = t[4:t.index("\n---\n")]
keys = dict(l.split(": ", 1) for l in fm.split("\n") if ": " in l)
assert keys["type"] == "governance" and keys["canonical_home"] == "governance", keys
assert keys["role"] == sys.argv[2] and keys["adapter"] == sys.argv[3], keys
assert t.count("<!-- governance:begin -->") == 1 and t.count("<!-- governance:end -->") == 1
block = t[t.index("<!-- governance:begin -->"):t.index("<!-- governance:end -->")]
assert "core:" in block and "adapter:" in block and "reconcile" in block
PY
}
check "the adapter vault's GOVERNANCE.md: managed keys, role adapter, adapter .governance, marker block" \
  "gov_md_ok '$ORG/GOVERNANCE.md' adapter .governance 2>/dev/null"
check "a member vault's GOVERNANCE.md: role member, adapter a relative path to the org layer" \
  "gov_md_ok '$ME/GOVERNANCE.md' member ../org-vault/.governance 2>/dev/null"
check "a member vault that HAD a GOVERNANCE.md without frontmatter keeps its prose and gains frontmatter + block" \
  "gov_md_ok '$CL/GOVERNANCE.md' member ../org-vault/.governance 2>/dev/null && grep -q '^# a vault with only a pointer file' '$CL/GOVERNANCE.md'"
check "CLAUDE.md: @GOVERNANCE.md appended once after existing content" \
  "[ \"\$(grep -c '^@GOVERNANCE.md$' '$ME/CLAUDE.md')\" = '1' ] && [ \"\$(head -1 '$ME/CLAUDE.md')\" = '# personal vault notes for agents' ]"
check "CLAUDE.md: created holding only the import where there was none" "[ \"\$(cat '$CL/CLAUDE.md')\" = '@GOVERNANCE.md' ]"
check "one backup from the install" "[ \"\$(backups '$H')\" = '1' ]"

echo "governance reconcile — second run is a noop"
snap "$R" "$H" > "$TMP/state.before"
rc="$(gov reconcile --home "$H")"
check "second reconcile exits 0" "[ '$rc' = '0' ]"
# Eleven items: the nine below plus the two render sources (core, adapter), which this fixture does not
# version, so each reads `ok — merged state not checked` (#101), visible, never silently skipped.
check "…every line ok" "[ \"\$(count_status ok)\" = '11' ] && [ \"\$(count_status fixed)\" = '0' ] && [ \"\$(count_status refused)\" = '0' ]"
check "…an unversioned source says its merged state was NOT checked" \
  "[ \"\$(grep -c '^ok *source .*merged state not checked: not in a git repository' '$TMP/stdout')\" = '2' ]"
snap "$R" "$H" > "$TMP/state.after"
check "…zero writes: no backup added, every file's mtime and bytes unchanged under the root and the home" \
  "[ \"\$(backups '$H')\" = '1' ] && cmp -s '$TMP/state.before' '$TMP/state.after'"
rc="$(gov reconcile --home "$H" --json)"
check "--json reports the same eleven items as ok" \
  "[ '$rc' = '0' ] && python3 -c \"import json,sys; r=json.load(open('$TMP/stdout'))['results']; assert len(r)==11 and all(x['status']=='ok' for x in r)\" 2>/dev/null"

echo "governance reconcile — repairs one item, leaves the rest"
rm "$CL/GOVERNANCE.md"
snap "$R" "$H" > "$TMP/state.before"
rc="$(gov reconcile --home "$H")"
check "a deleted member GOVERNANCE.md ⇒ that item fixed, exit 0" "[ '$rc' = '0' ] && status_of fixed 'client-vault/GOVERNANCE.md'"
check "…and only that item: ten ok, one fixed" "[ \"\$(count_status ok)\" = '10' ] && [ \"\$(count_status fixed)\" = '1' ]"
snap "$R" "$H" > "$TMP/state.after"
check "…every other file untouched (mtime and bytes)" \
  "[ \"\$(diff '$TMP/state.before' '$TMP/state.after' | grep -c '^[<>]' )\" = '1' ]"

echo "governance reconcile — preserves what it does not manage"
python3 - "$ME/GOVERNANCE.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
fm_end = t.index("\n---\n")
t = t[:fm_end] + "\nowner: someone-in-the-org\ntags: [vault, notes]" + t[fm_end:]
t = t.replace("\n<!-- governance:begin -->", "\nProse written by hand ABOVE the block.\n\n<!-- governance:begin -->", 1)
t += "\nProse written by hand BELOW the block, with a trailing line and no final newline"
open(p, "w").write(t)
PY
cp "$ME/GOVERNANCE.md" "$TMP/me-gov.edited"
rc="$(gov reconcile --home "$H")"
check "hand edits outside the block and an unmanaged key ⇒ ok, the file byte-identical" \
  "[ '$rc' = '0' ] && status_of ok 'personal-vault/GOVERNANCE.md' && cmp -s '$ME/GOVERNANCE.md' '$TMP/me-gov.edited'"
sed -i.bak 's/^role: member$/role: adapter/' "$ME/GOVERNANCE.md" && rm "$ME/GOVERNANCE.md.bak"
rc="$(gov reconcile --home "$H")"
check "a managed key edited by hand ⇒ fixed back, and every unmanaged byte preserved" \
  "[ '$rc' = '0' ] && status_of fixed 'personal-vault/GOVERNANCE.md' && cmp -s '$ME/GOVERNANCE.md' '$TMP/me-gov.edited'"
printf '\ntext inside the block, by hand\n' > "$TMP/inject"
python3 - "$ORG/GOVERNANCE.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(t.replace("<!-- governance:end -->", "hand edit inside the managed block\n<!-- governance:end -->", 1))
PY
rc="$(gov reconcile --home "$H")"
check "an edit INSIDE the block is overwritten (the block is managed)" \
  "[ '$rc' = '0' ] && status_of fixed 'org-vault/GOVERNANCE.md' && ! grep -q 'hand edit inside' '$ORG/GOVERNANCE.md'"

echo "governance reconcile — home drift"
printf '\nan edit made directly in the rendered file\n' >> "$H/.claude/CLAUDE.md"
rc="$(gov check --home "$H")"
check "a hand edit to the rendered CLAUDE.md is drift for check --home (exit 1)" "[ '$rc' = '1' ]"
rc="$(gov reconcile --home "$H" --dry-run)"
check "--dry-run reports the home as would-fix and exits 0" "[ '$rc' = '0' ] && grep -q \"^would fix home \" '$TMP/stdout'"
check "…and writes nothing: the edit is still there, no backup added" \
  "grep -q 'an edit made directly' '$H/.claude/CLAUDE.md' && [ \"\$(backups '$H')\" = '1' ]"
rc="$(gov reconcile --home "$H")"
check "reconcile fixes it: home fixed, drift ok, a backup holding the edit" \
  "[ '$rc' = '0' ] && status_of fixed \"$H\" && status_of ok \"drift $H\" && [ \"\$(backups '$H')\" = '2' ] && ! grep -q 'an edit made directly' '$H/.claude/CLAUDE.md'"
rc="$(gov check --home "$H")"
check "…and check --home is in sync again" "[ '$rc' = '0' ]"

# A DEAD HOOK in a config the install does not own is its own item, never "refused drift": a peer read
# that wording as "reconcile refused to render" while the render had in fact landed.
mkdir -p "$H/.codex"; printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.codex/hooks/gone.sh"}]}]}}\n' > "$H/.codex/hooks.json"
rc="$(gov reconcile --home "$H")"
check "a dead hook outside the install: drift is ok, a separate hooks item refuses (exit 1)" \
  "[ '$rc' = '1' ] && status_of ok \"drift $H\" && grep -q '^refused *hooks .*OUTSIDE this install' '$TMP/stdout'"
rm "$H/.codex/hooks.json"
rc="$(gov reconcile --home "$H")"
check "…and without it, no hooks item and exit 0 (control)" "[ '$rc' = '0' ] && ! grep -q 'hooks ' '$TMP/stdout'"

echo "governance reconcile — adapter shape and refusals"
mv "$ORG/.governance/AGENTS.md" "$TMP/org-agents.bak"
rc="$(gov reconcile --home "$H")"
check "a missing adapter AGENTS.md is created from adapter-template" \
  "[ '$rc' = '0' ] && status_of fixed 'org-vault/.governance/AGENTS.md' && cmp -s '$ORG/.governance/AGENTS.md' '$ROOT/adapter-template/AGENTS.md'"
mv "$TMP/org-agents.bak" "$ORG/.governance/AGENTS.md"
gov reconcile --home "$H" >/dev/null
put "$ORG/.governance/skills" "not a directory"
rc="$(gov reconcile --home "$H")"
check "an adapter part that is a file, not a directory ⇒ refused (exit 1)" \
  "[ '$rc' = '1' ] && status_of refused 'org-vault/.governance/skills'"
rm "$ORG/.governance/skills"
printf '@GOVERNANCE.md\n' >> "$CL/CLAUDE.md"
rc="$(gov reconcile --home "$H")"
check "@GOVERNANCE.md twice in a CLAUDE.md ⇒ refused, never rewritten" \
  "[ '$rc' = '1' ] && status_of refused 'client-vault/CLAUDE.md' && [ \"\$(grep -c '^@GOVERNANCE.md$' '$CL/CLAUDE.md')\" = '2' ]"
printf '@GOVERNANCE.md\n' > "$CL/CLAUDE.md"
rc="$(gov reconcile --home "$H")"
check "…and back in state once corrected by hand" "[ '$rc' = '0' ]"

echo "governance install --write-manifest"
H2="$TMP/home-seeded"; mkdir -p "$H2"
rc="$(gov install --home "$H2" --repo "$C" --adapter "$ORG/.governance" --harness claude --write-manifest)"
manifest_ok() {
  python3 - "$H2/.governance/manifest.json" "$C" "$H2" "$ORG" <<'PY'
import json, os, sys
m, c, h, org = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
assert m["core"] == c and m["home"] == h and m["harnesses"] == ["claude"] and m["local"] is None
assert m["adapter"] == {"vault": org, "path": os.path.join(org, ".governance")}
assert m["vaults"] == [{"path": org, "role": "adapter", "name": "org-vault"}], m["vaults"]
PY
}
check "install --write-manifest exits 0 and seeds the manifest from its arguments" "[ '$rc' = '0' ] && manifest_ok 2>/dev/null"
rc="$(gov reconcile --home "$H2")"
check "…so reconcile then needs no arguments: every item ok or fixed, exit 0" \
  "[ '$rc' = '0' ] && [ \"\$(count_status refused)\" = '0' ]"
rc="$(gov reconcile --home "$H2")"
check "…and the run after that is all ok with no second backup" \
  "[ '$rc' = '0' ] && [ \"\$(count_status fixed)\" = '0' ] && [ \"\$(backups '$H2')\" = '1' ]"
rc="$(gov install --home "$H2" --repo "$C" --adapter "$ORG/.governance" --adapter "$C" --write-manifest)"
check "--write-manifest with two adapters is refused (exit 2)" "[ '$rc' = '2' ]"

echo "governance reconcile — a render source must be at merged canon (#101)"
# A render from a checkout BEHIND its origin omits merged rules; one AHEAD, or dirty, publishes unmerged
# ones. Both have happened (21 hours of stale rules once). Each case builds the state, then requires the
# verdict, and the first case is the control: in sync, it renders.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G="$TMP/git"; mkdir -p "$G"
mkrepo() { # mkrepo <name> <populate-cmd>: a bare origin and a clone of it holding one pushed commit
  git init -q --bare -b main "$G/$1.git"; git clone -q "$G/$1.git" "$G/$1" 2>/dev/null
  ( cd "$G/$1" && eval "$2" && git add -A && git commit -qm base --no-gpg-sign && git push -q origin main ) >/dev/null 2>&1
  git -C "$G/$1" remote set-head origin main >/dev/null 2>&1
}
mkrepo core 'mkdir -p core/domains hooks settings && echo "# core rules" > core/AGENTS.md && echo "# sec" > core/domains/security.md && echo "echo gate" > hooks/gate.sh && echo "{\"permissions\": {\"deny\": [\"Bash(rm -rf *)\"]}}" > settings/claude.json'
mkrepo vault 'mkdir -p .obsidian .governance && echo "# org rules" > .governance/AGENTS.md && echo note > note.md'
H3="$TMP/home3"; mkdir -p "$H3/.claude" "$H3/.governance"
python3 - "$H3/.governance/manifest.json" "$G/core" "$G/vault" "$H3" <<'PY'
import json, sys
p, core, vault, home = sys.argv[1:]
json.dump({"version": 1, "core": core, "home": home, "harnesses": ["claude"], "local": None,
           "adapter": {"vault": vault, "path": vault + "/.governance"},
           "vaults": [{"name": "vault", "path": vault, "role": "adapter"}]}, open(p, "w"), indent=2)
PY
rc="$(gov reconcile --home "$H3")"
check "in sync with origin: exit 0, both sources at merged canon, the home installed (the control)" \
  "[ '$rc' = '0' ] && [ \"\$(grep -c '^ok *source .*at merged canon (origin/main @' '$TMP/stdout')\" = '2' ] && status_of fixed \"$H3\""
# BEHIND: a merged rule lands on origin from elsewhere; this checkout has fetched but not pulled it.
git clone -q "$G/core.git" "$G/core-peer" 2>/dev/null
( cd "$G/core-peer" && echo "# core rules + a merged rule" > core/AGENTS.md && git commit -qam merged --no-gpg-sign && git push -q origin main ) >/dev/null 2>&1
git -C "$G/core" fetch -q origin
snap "$H3" > "$TMP/h3.before"
rc="$(gov reconcile --home "$H3")"
snap "$H3" > "$TMP/h3.after"
check "core BEHIND origin: exit 1, its source refused as omitting merged canon, the home NOT installed, nothing written" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*core.* 1 commit(s) on origin/main touching it are not here: a render would omit merged canon' '$TMP/stdout' && status_of refused \"$H3\" && cmp -s '$TMP/h3.before' '$TMP/h3.after'"
git -C "$G/core" pull -q --ff-only origin main >/dev/null 2>&1
rc="$(gov reconcile --home "$H3")"
check "…after a pull: exit 0 and the merged rule is rendered" \
  "[ '$rc' = '0' ] && grep -q 'a merged rule' '$H3/.claude/CLAUDE.md'"
# AHEAD: a local commit to the core that origin has not merged.
( cd "$G/core" && echo "# draft" >> core/domains/security.md && git commit -qam draft --no-gpg-sign ) >/dev/null 2>&1
rc="$(gov reconcile --home "$H3")"
check "core AHEAD of origin: exit 1, refused as publishing unmerged canon" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*core.* 1 commit(s) touching it are not on origin/main: a render would publish unmerged canon' '$TMP/stdout'"
rc="$(gov reconcile --home "$H3" --allow-unmerged)"
check "…--allow-unmerged renders anyway and says so on the source line" \
  "[ '$rc' = '0' ] && grep -q '^ok *source .*UNMERGED, rendered anyway by --allow-unmerged' '$TMP/stdout' && grep -q '# draft' '$H3/.claude/governance/security.md'"
( cd "$G/core" && git reset -q --keep origin/main ) >/dev/null 2>&1
# DIRTY adapter subtree: an untracked file inside the layer counts.
echo "# half-written" > "$G/vault/.governance/new-rule.md"
rc="$(gov reconcile --home "$H3")"
check "an untracked file inside the adapter subtree: exit 1, refused as uncommitted" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*vault/.governance.* 1 uncommitted change(s) in it' '$TMP/stdout'"
rm "$G/vault/.governance/new-rule.md"
# The mirrors that must stay quiet: what is OUTSIDE the source is not the source.
echo "edited" >> "$G/vault/note.md"
( cd "$G/vault" && echo more > note2.md && git add note2.md && git commit -qm "notes only" --no-gpg-sign ) >/dev/null 2>&1
mkdir -p "$G/core/.claude" && echo x > "$G/core/.claude/state.json"
rc="$(gov reconcile --home "$H3")"
check "a vault note edited, a notes-only commit ahead, and an untracked dir in the core: none of them refuse" \
  "[ '$rc' = '0' ] && [ \"\$(grep -c '^ok *source .*at merged canon' '$TMP/stdout')\" = '2' ]"

echo "governance reconcile — the desktop app's save of a routine is not unmerged canon (#204)"
# The app rewrites a routine's SKILL.md in place (through the scheduled-tasks link) and runs that file:
# it strips the frontmatter to name + description and keeps the body. That change is live the moment
# it is saved, so refusing the whole render over it protects nothing and blocks every other rule.
SK="$G/vault/.governance/scheduled-tasks/sweep/SKILL.md"; mkdir -p "$(dirname "$SK")"
BODY=$'\nSweep every due item.\n\n## Steps\n1. Read the table.\n'
printf -- '---\nname: sweep\ndescription: Monthly sweep of due items\nregistration: armed\ntaskId: sweep\ncron: "0 9 1 * *"\nenabled: true\n---\n%s' "$BODY" > "$SK"
( cd "$G/vault" && git add -A && git commit -qm "routine" --no-gpg-sign && git push -q origin main ) >/dev/null 2>&1
printf -- '---\nname: sweep\ndescription: Monthly sweep of due items\n---\n%s' "$BODY" > "$SK"
rc="$(gov reconcile --home "$H3")"
check "the app's exact rewrite (frontmatter cut to name + description, body unchanged): exit 0, rendered, reported by name" \
  "[ '$rc' = '0' ] && grep -q '^ok *source .*vault/.governance.*tool-managed rewrite of sweep' '$TMP/stdout' && ! grep -q '^refused' '$TMP/stdout'"
printf -- '---\nname: sweep\ndescription: Monthly sweep of due items\n---\n%s\nA new step.\n' "$BODY" > "$SK"
rc="$(gov reconcile --home "$H3")"
check "…the control: the same strip plus a body edit is refused as uncommitted" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*vault/.governance.* 1 uncommitted change(s) in it' '$TMP/stdout'"
printf -- '---\nname: sweep\ndescription: Monthly sweep of due items\nregistration: armed\ntaskId: sweep\ncron: "0 9 2 * *"\nenabled: true\n---\n%s' "$BODY" > "$SK"
rc="$(gov reconcile --home "$H3")"
check "…the mirror: a canon key edited, not stripped (cron changed), is refused" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*vault/.governance.* 1 uncommitted change(s) in it' '$TMP/stdout'"
printf -- '---\nname: sweep\ndescription: Monthly sweep: every due item\n---\n%s' "$BODY" > "$SK"
rc="$(gov reconcile --home "$H3")"
check "…a strip whose description holds an unquoted ': ' does not parse: refused, naming the routine and the fix" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*scheduled task sweep: .*description does not parse as YAML.*quote the value' '$TMP/stdout'"
printf -- '---\nname: sweep\ndescription: "Monthly sweep: every due item"\n---\n%s' "$BODY" > "$SK"
echo "# half-written" > "$G/vault/.governance/new-rule.md"
rc="$(gov reconcile --home "$H3")"
check "…a quoted strip beside another uncommitted file: refused for the other file only, the rewrite still named" \
  "[ '$rc' = '1' ] && grep -q '^refused *source .*vault/.governance.* 1 uncommitted change(s) in it.*tool-managed rewrite of sweep' '$TMP/stdout'"
rm "$G/vault/.governance/new-rule.md"; git -C "$G/vault" checkout -q -- "$SK"

# Outside git entirely: never refused, and says it was not checked (the fixture above already shows it).

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
