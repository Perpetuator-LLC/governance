#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# no-checkout-paths.test.sh — no tracked file hard-codes where a checkout lives.
#
# A path naming one machine's checkout, or one person's home directory, works on the machine that wrote
# it and fails everywhere else — another host, CI, a second clone — or quietly acts on the wrong tree.
# A script derives its root from its own location instead:
#     ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#
# Flagged, in every tracked text file:
#   home      a path into one user's home directory, under the Users or home root
#   checkout  an absolute path running through this repository's own directory name — including one
#             rooted at $HOME or ~
# Exempt: the deploy vars files (the target dir is data there, by design), and a line carrying the
# marker `checkout-path: allow` with its reason (a path inside a container, say).
# The repository's name is its checkout directory's name; set CHECKOUT_NAME when the clone differs.
#
# The lint proves itself first, on a positive fixture it must flag and a negative one it must pass,
# both built here at test time: a lint that matches nothing would report a clean tree forever.
# Exit: 0 proven and clean · 1 a finding, a failed self-proof, or the lint could not run

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/lint.sh
. "$ROOT/tests/lib/lint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

EXEMPT=':!*deploy/vars*.yml'

# lint REPO — print findings; 0 clean · 1 findings · 2 cannot run
lint() {
  local top name rc_home rc_checkout
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repository: $1" >&2; return 2; }
  name="$(repo_name "$top")" || return 2
  [ -n "$(git -C "$top" ls-files)" ] || { echo "no tracked files in $top — refusing to call nothing clean" >&2; return 2; }
  grep_findings "$top" home "$HOME_RX" "$ALLOW" . "$EXEMPT"; rc_home=$?
  grep_findings "$top" checkout "$(checkout_rx "$name")" "$ALLOW" . "$EXEMPT"; rc_checkout=$?
  if [ "$rc_home" = 2 ] || [ "$rc_checkout" = 2 ]; then return 2; fi
  [ "$rc_home" -eq 0 ] && [ "$rc_checkout" -eq 0 ]
}

echo "no-checkout-paths — the lint proves itself (fixtures built at test time)"
yml=yml   # a suffix, not a literal: this file stays free of concrete config filenames
pn=pos-stack; nn=neg-stack   # fixture repository names; the checkout rule keys on them
POS="$TMP/$pn"; NEG="$TMP/$nn"; EMPTY="$TMP/empty-stack"
git init -q "$POS"; git init -q "$NEG"; git init -q "$EMPTY"

put "$POS" scripts/user-home.sh    "cd /$(printf %s Us ers)/someone/src/app"
put "$POS" scripts/server-home.sh  "rsync out/ /$(printf %s ho me)/deploy/cache/"
put "$POS" scripts/checkout.sh     "cd /srv/stacks/$pn/services"
put "$POS" scripts/home-var.sh     "exec \"\$HOME/src/$pn/scripts/run.sh\""
put "$POS" README.md               "Clone it into ~/work/$pn before running anything."
CHECKOUT_NAME="" lint "$POS" > "$TMP/pos.out" 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok "positive fixture: the lint fails (exit 1)"; else bad "positive fixture: the lint should fail with exit 1, got $rc"; fi
for f in scripts/user-home.sh scripts/server-home.sh scripts/checkout.sh scripts/home-var.sh README.md; do
  if grep -qF "  $f:1:" "$TMP/pos.out"; then ok "positive fixture: flags $f"; else bad "positive fixture: missed $f"; fi
done

# shellcheck disable=SC2016  # the $ROOT/$HOME below are fixture TEXT, written unexpanded on purpose
{
  put "$NEG" scripts/ok.sh \
    '#!/usr/bin/env bash' \
    'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"' \
    'cd "$ROOT/services/web" && cat /etc/hosts >/dev/null' \
    'mkdir -p /var/lib/pull-deployer "$HOME/.config/tool" ~/.ssh'
  put "$NEG" README.md \
    "Clone https://git.example.org/org/$nn.git or browse https://git.example.org/org/$nn"
  put "$NEG" "overlay/deploy/vars.$yml" "target_dir: /srv/stacks/$nn"
  put "$NEG" "module/services/web/compose.$yml" \
    "      - ./data:/$(printf %s ho me)/node/app   # $ALLOW — a path inside the container"
}
CHECKOUT_NAME="" lint "$NEG" > "$TMP/neg.out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then
  ok "negative fixture: derived root, system paths, URLs, the deploy vars and an allowed line pass (exit 0)"
else
  bad "negative fixture: should pass with exit 0, got $rc"; sed 's/^/      /' "$TMP/neg.out"
fi

CHECKOUT_NAME="" lint "$EMPTY" > "$TMP/empty.out" 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "a repository with no tracked files cannot run (exit 2), never clean"; else bad "no tracked files should exit 2, got $rc"; fi

echo "no-checkout-paths — this repository"
lint "$ROOT" > "$TMP/root.out" 2>&1; rc=$?
case "$rc" in
  0) ok "no tracked file hard-codes a checkout or home-directory path" ;;
  1) bad "hard-coded paths found — derive the root from the script's own location:"; sed 's/^/      /' "$TMP/root.out" ;;
  *) bad "the lint could not run: $(cat "$TMP/root.out")" ;;
esac

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
