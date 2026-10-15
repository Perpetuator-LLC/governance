#!/usr/bin/env bash
# projects-conformance.test.sh — every class of non-conforming top-level entry is reported, conforming
# entries are not, and nothing is ever moved. Fixture: a throwaway projects root, never a real one.
#
# Hand-derived expectation for the fixture below: 10 non-conforming of 12 top-level entries.
#   conforming (2):  app (one clone, forge name) · acme-tools (org-prefixed clone)
#   not counted:     worktrees/ _ref/ _soak/ (the layout's own dirs)
#   non-conforming:  scratch (plain-dir) · notes.txt (file) · .tmp-build (hidden) · .wt (extra-worktree-root)
#                    · app-feature (top-level-worktree) · local-only (no-remote) · app-copy (duplicate-clone)
#                    · vendored (third-party) · forked (third-party) · broken (unreadable)
# .DS_Store is ignored. Worktrees inside a clone are a separate count: app/.wts/y (nested, 1) and
# app/.claude/worktrees/h (harness-made, listed, 0); .wt/app-x is already .wt's row, not counted again.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PC="$ROOT/bin/projects-conformance"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$TMP/projects"; mkdir -p "$P/worktrees" "$P/_ref" "$P/_soak"
q() { "$@" >/dev/null 2>&1; }
repo() {  # repo <dir> <remote-url or ''>
  q git init -q -b main "$1"; echo x > "$1/f"; q git -C "$1" add f; q git -C "$1" commit -qm base
  [ -z "$2" ] || q git -C "$1" remote add origin "$2"
}
repo "$P/app"        "git@forge.example:org/app.git"
repo "$P/acme-tools" "https://forge.example/acme/tools.git"
repo "$P/app-copy"   "ssh://git@forge.example/org/app"          # same repo as app, other URL shape
repo "$P/local-only" ""
repo "$P/vendored"   "https://github.example/someone/vendored.git"
repo "$P/forked"     "git@forge.example:org/forked.git"         # our own account, still declared third-party
q git -C "$P/app" worktree add -q "$P/app-feature" -b feature
mkdir -p "$P/.wt"; q git -C "$P/app" worktree add -q "$P/.wt/app-x" -b x
mkdir -p "$P/app/.wts"; q git -C "$P/app" worktree add -q "$P/app/.wts/y" -b y              # nested in a clone
mkdir -p "$P/app/.claude/worktrees"; q git -C "$P/app" worktree add -q "$P/app/.claude/worktrees/h" -b h   # harness-made
q git -C "$P/app" worktree add -q "$P/worktrees/app-ok" -b ok                                  # the allowed place
mkdir -p "$P/scratch" "$P/.tmp-build"; echo n > "$P/notes.txt"; : > "$P/.DS_Store"
mkdir -p "$P/broken/.git"   # a .git dir git cannot read: fails for root too (CI runs as root; chmod would not)
printf '# declared third-party\nvendored\nforked   # a fork we only read\n' > "$TMP/ref.txt"

before="$(cd "$P" && find . -maxdepth 2 | sort)"
out="$("$PC" --root "$P" --ref-list "$TMP/ref.txt")"; rc=$?
after="$(cd "$P" && find . -maxdepth 2 | sort)"

echo "classes:"
[ "$rc" -eq 0 ] && ok "a report exits 0 whatever it finds" || bad "exit $rc"
for want in "plain-dir *scratch" "file *notes.txt" "hidden *.tmp-build" "extra-worktree-root *.wt" \
            "top-level-worktree *app-feature" "no-remote *local-only" "duplicate-clone *app-copy .*kept: app" \
            "third-party *vendored" "third-party *forked" "unreadable *broken"; do
  printf '%s\n' "$out" | grep -qE "^$want" && ok "reports: $want" || bad "missing: $want"
done
echo "worktrees inside clones:"
printf '%s\n' "$out" | grep -qE "^nested-worktree +app/.wts/y" && ok "a worktree nested in a clone is reported" || bad "nested missing"
printf '%s\n' "$out" | grep -qE "^harness-worktree +app/.claude/worktrees/h" && ok "a harness-made worktree is listed" || bad "harness missing"
printf '%s\n' "$out" | grep -q "nested worktrees outside worktrees/: 1 · harness-managed (listed, not counted): 1" \
  && ok "nested 1, harness 1, both kept out of the top-level count" || bad "nested/harness line"
printf '%s\n' "$out" | grep -q "app-ok" && bad "a worktree under worktrees/ was reported" || ok "control: worktrees/app-ok is silent"
[ "$(printf '%s\n' "$out" | grep -c '\.wt/app-x')" -eq 0 ] && ok "control: .wt's worktree is not counted again as nested" || bad ".wt double-counted"
echo "controls (conforming entries are silent):"
for name in app acme-tools worktrees _ref _soak .DS_Store; do
  printf '%s\n' "$out" | grep -qE "^[a-z-]+ +$name( |$)" && bad "$name reported" || ok "$name not reported"
done
printf '%s\n' "$out" | grep -q "projects-conformance: 10 non-conforming of 12 top-level entries" \
  && ok "summary: 10 of 12 (hand-derived)" || bad "summary: $(printf '%s\n' "$out" | grep '^projects-conformance')"
[ "$before" = "$after" ] && ok "report-only: the tree is unchanged" || bad "the tree changed"

echo "fails closed:"
out="$("$PC" --root "$P")"
printf '%s\n' "$out" | grep -q "third-party: NOT CHECKED" && ok "no --ref-list → third-party NOT CHECKED, not zero" \
  || bad "no NOT CHECKED line"
"$PC" --root "$TMP/nope" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unreadable root exits 2" || bad "missing root exit $rc"
"$PC" --root "$P" --ref-list "$TMP/nope.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unreadable --ref-list exits 2, never runs unchecked" || bad "missing ref-list exit $rc"
"$PC" --root "$P" --ref-list "$TMP/ref.txt" --json | python3 -c '
import json,sys; d=json.load(sys.stdin); assert d["nonconforming"]==10 and d["top_level"]==12 and d["third_party_checked"], d' \
  && ok "--json carries the same numbers" || bad "json"

echo "norm_remote and duplicate-clone keep selection:"
# --- a 'user@' prefix is stripped: two URLs for the SAME repo, one WITH it and one WITHOUT -----------
P2="$TMP/p2"; mkdir -p "$P2"
repo "$P2/widget"      "https://forge.example/org/widget.git"     # no user@ prefix
repo "$P2/widget-copy" "git@forge.example:org/widget.git"         # user@ prefix: same repo if stripped
out2="$("$PC" --root "$P2")"
printf '%s\n' "$out2" | grep -qE "^duplicate-clone +widget-copy .*kept: widget" \
  && ok "a 'user@'-prefixed URL and a plain one for the SAME repo are recognised as duplicates" \
  || bad "user@ stripping not exercised: $out2"

# --- the CANONICALLY-named clone (matching the repo's own forge name) is kept, never just the one ---
# --- that happens to sort first alphabetically -------------------------------------------------------
P3="$TMP/p3"; mkdir -p "$P3"
repo "$P3/aaa-mirror" "git@forge.example:org/gadget.git"   # sorts FIRST alphabetically, but is not forge-named
repo "$P3/gadget"     "https://forge.example/org/gadget.git"  # forge-named: the one that should be kept
out3="$("$PC" --root "$P3")"
printf '%s\n' "$out3" | grep -qE "^duplicate-clone +aaa-mirror .*kept: gadget" \
  && ok "the forge-NAMED clone is kept even when another copy sorts first alphabetically" \
  || bad "canonical-name preference not exercised: $out3"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
