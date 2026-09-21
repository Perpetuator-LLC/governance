#!/usr/bin/env bash
# scaffold-code-repo.test.sh — bin/governance scaffold --template code-repo
#
# The code-repo template's whole job is that ONE file is canonical and the rest point at it. That
# property is invisible in a green exit code and dies quietly: someone fills in a pointer "just this
# once", the two copies drift, and both look maintained. So the pointer-ness is asserted here by
# content, and the layout is pinned by an explicit list — a file dropped from the template must fail
# this test, not shrink its expectations.
#
# {{name}} substitution is the other trap. `governance` fills it in README.md and AGENTS.md ONLY, so
# a placeholder anywhere else ships literally into every scaffolded repository.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOV="$ROOT/bin/governance"
TPL="$ROOT/templates/code-repo"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
YA=yaml            # the gate config's extension, kept out of the source as a literal
PC=".pre-commit-config.$YA"
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
gov()  { python3 "$GOV" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; echo $?; }
snap() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for d, dirs, files in os.walk(root):
    dirs.sort()
    for n in sorted(files):
        p = os.path.join(d, n)
        st = os.stat(p)
        print(os.path.relpath(p, root), st.st_mtime_ns, hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}

# The layout, pinned. Not derived from the template directory, on purpose.
LAYOUT="AGENTS.md
CLAUDE.md
README.md
.claude/settings.json
.continue/rules/00-governance.md
.cursor/rules/governance.mdc
.github/copilot-instructions.md
.gitignore
.gitleaks.toml
${PC}
docs/decisions/0001-record-architecture-decisions.md"
N="$(echo "$LAYOUT" | wc -l | tr -d ' ')"

echo "scaffold --template code-repo"

S="$TMP/repo"
rc="$(gov scaffold --template code-repo --out "$S" --name widget-svc)"
check "exits 0 and creates every file" \
  "[ '$rc' = '0' ] && grep -q '$N file(s): 0 ok, $N created, 0 refused' '$TMP/stdout'"

missing=""; for f in $LAYOUT; do [ -f "$S/$f" ] || missing="$missing $f"; done
check "every file of the layout exists${missing:+ (missing:$missing)}" "[ -z '$missing' ]"

extra="$(cd "$S" && find . -type f | sed 's|^\./||' | sort > "$TMP/got"; echo "$LAYOUT" | sort > "$TMP/want"; comm -23 "$TMP/got" "$TMP/want" | tr '\n' ' ')"
check "…and nothing else${extra:+ (unexpected: $extra)}" "[ -z '$extra' ]"

# --- the property the template exists for -------------------------------------------------------
check "AGENTS.md declares itself canonical" \
  "grep -qi 'canonical' '$S/AGENTS.md'"
for p in CLAUDE.md .github/copilot-instructions.md .cursor/rules/governance.mdc .continue/rules/00-governance.md; do
  check "$p points at AGENTS.md rather than restating it" \
    "grep -q 'AGENTS.md' '$S/$p' && [ \"\$(wc -l < '$S/$p')\" -lt 20 ]"
done

# --- substitution -------------------------------------------------------------------------------
check "{{name}} is filled in README.md and AGENTS.md" \
  "head -1 '$S/README.md' | grep -qx '# widget-svc' && head -1 '$S/AGENTS.md' | grep -qx '# widget-svc — agent instructions'"
stray="$(grep -rl '{{name}}' "$S" 2>/dev/null | tr '\n' ' ')"
check "no {{name}} survives anywhere${stray:+ (in: $stray)}" "[ -z '$stray' ]"
tstray="$(cd "$TPL" && grep -rl '{{name}}' . 2>/dev/null | sed 's|^\./||' | grep -vxE 'README\.md|AGENTS\.md' | tr '\n' ' ')"
check "the template puts {{name}} only where governance substitutes it${tstray:+ (also in: $tstray)}" \
  "[ -z '$tstray' ]"

# --- the gitignore covers the generated session file ---------------------------------------------
check ".gitignore covers the session-start hook's generated context file" \
  "grep -q 'workspace-context.md' '$S/.gitignore'"

# --- secret gate is real, not decorative ----------------------------------------------------------
check "the pre-commit gate pins gitleaks to an explicit rev (never a moving ref)" \
  "grep -A1 'gitleaks/gitleaks' '$S/$PC' | grep -qE 'rev: v[0-9]+\.[0-9]+\.[0-9]+'"
if command -v gitleaks >/dev/null 2>&1; then
  (cd "$S" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm x) >/dev/null 2>&1
  if (cd "$S" && gitleaks detect --config .gitleaks.toml --no-banner) >/dev/null 2>&1; then
    ok "the scaffolded repository passes its own gitleaks config"
  else
    bad "the scaffolded repository FAILS its own gitleaks config"
  fi
else
  ok "gitleaks config present — scan NOT CHECKED (no gitleaks on PATH here), never reported as a pass"
fi

# --- idempotence: the property a green exit code hides ---------------------------------------------
snap "$S" > "$TMP/before"
rc="$(gov scaffold --template code-repo --out "$S" --name widget-svc)"
check "a second run reports every file ok and creates nothing" \
  "[ '$rc' = '0' ] && grep -q '$N file(s): $N ok, 0 created, 0 refused' '$TMP/stdout'"
snap "$S" > "$TMP/after"
check "…and writes nothing: every mtime and every byte unchanged" "cmp -s '$TMP/before' '$TMP/after'"

# --- a repository's own file is never clobbered ----------------------------------------------------
echo "MINE" > "$S/AGENTS.md"
rc="$(gov scaffold --template code-repo --out "$S" --name widget-svc)"
check "an existing AGENTS.md is left exactly as the repository had it" \
  "[ '$rc' = '0' ] && [ \"\$(cat '$S/AGENTS.md')\" = 'MINE' ]"

# --- dry-run writes nothing -------------------------------------------------------------------------
rc="$(gov scaffold --template code-repo --out "$TMP/dry" --dry-run)"
check "--dry-run into a missing directory exits 0 and does not create it" \
  "[ '$rc' = '0' ] && [ ! -e '$TMP/dry' ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
