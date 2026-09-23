#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# module-lint.test.sh — module/ stays publishable: nothing in it names the organisation running it.
#
# module/ is the generic half of this repository; publishing it later means publishing that directory
# and relocating overlay/. Genericness without a gate decays on the first urgent fix, so this lint fails
# on any of these UNDER module/ (overlay/ is where they belong):
#   denylist:N   the organisation's own terms — its domains, private network names, secret-path
#                prefixes — one extended regex per line in overlay/lint-denylist.txt, `#` comments
#                allowed. The overlay owns that file; the public template ships only a synthetic example.
#   home / checkout  an absolute home-directory or checkout path (the no-checkout-paths rules)
#   overlay-ref  a path into overlay/: the dependency points one way, overlay → module, never back
# A missing or empty denylist is NOT CHECKED (exit 3), never clean: the organisation's terms are the point.
#
# The lint proves itself first, on fixtures built here from a synthetic organisation: a positive it must
# flag term by term, a negative it must pass, and the refusals.
# Exit: 0 proven and clean · 1 a finding, or a failed self-proof · 3 NOT CHECKED: no denylist

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/lint.sh
. "$ROOT/tests/lib/lint.sh"
DENYLIST_REL="overlay/lint-denylist.txt"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

# lint_module REPO DENYLIST — print findings under module/; 0 clean · 1 findings · 2 cannot run · 3 NOT CHECKED
lint_module() {
  local top="" name denylist="$2" line n=0 rc worst=0
  local -a pats=() lines=()
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repository: $1" >&2; return 2; }
  [ -f "$denylist" ] || { echo "NOT CHECKED — no denylist at $DENYLIST_REL: copy the example beside it and list the organisation's terms" >&2; return 3; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    pats+=("$line"); lines+=("$n")
  done < "$denylist"
  [ "${#pats[@]}" -gt 0 ] || { echo "NOT CHECKED — the denylist holds no patterns, so it would find nothing" >&2; return 3; }
  name="$(repo_name "$top")" || return 2
  [ -n "$(git -C "$top" ls-files -- module/)" ] || { echo "no tracked files under module/ — refusing to call nothing clean" >&2; return 2; }

  record() { [ "$1" = 2 ] && worst=2; [ "$1" = 1 ] && [ "$worst" = 0 ] && worst=1; }
  grep_findings "$top" home "$HOME_RX" "$ALLOW" module/; record $?
  grep_findings "$top" checkout "$(checkout_rx "$name")" "$ALLOW" module/; record $?
  grep_findings "$top" overlay-ref '(^|[^A-Za-z0-9_.-])overlay/' "" module/; record $?
  for i in "${!pats[@]}"; do
    grep_findings "$top" "denylist:${lines[$i]}" "${pats[$i]}" "" module/; rc=$?
    record "$rc"
  done
  return "$worst"
}

echo "module-lint — the lint proves itself (a synthetic organisation, fixtures built at test time)"
yml=yml   # a suffix, not a literal: this file stays free of concrete config filenames
pn=pos-module; nn=neg-module
POS="$TMP/$pn"; NEG="$TMP/$nn"
git init -q "$POS"; git init -q "$NEG"
DENY="$TMP/denylist"
printf '%s\n' \
  '# a synthetic organisation: its domain, its private network, its secret-store prefix' \
  '' \
  'acme-internal\.example' \
  '   acme-edge-net   ' \
  'kv/acme/' > "$DENY"

put "$POS" "module/services/web/compose.$yml" \
  'services:' \
  '  web:' \
  '    environment:' \
  '      OIDC_ISSUER_URL: https://sso.acme-internal.example/realms/main' \
  '      SECRET_STORE_PREFIX: kv/acme/web' \
  "    working_dir: /srv/stacks/$pn/module" \
  "    volumes: [\"/$(printf %s Us ers)/someone/web:/data\"]" \
  "    extends: {file: ../../../overlay/services/web/compose.$yml, service: web}" \
  'networks:' \
  '  default: {name: acme-edge-net, external: true}'
put "$POS" "overlay/inventory.$yml" 'all: {hosts: {web1.acme-internal.example: {}}}'
CHECKOUT_NAME="" lint_module "$POS" "$DENY" > "$TMP/pos.out" 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok "positive fixture: the lint fails (exit 1)"; else bad "positive fixture: should fail with exit 1, got $rc"; fi
f="module/services/web/compose.$yml"
for want in "denylist:3  $f:4:" "denylist:5  $f:5:" "checkout  $f:6:" "home  $f:7:" "overlay-ref  $f:8:" "denylist:4  $f:10:"; do
  if grep -qF "$want" "$TMP/pos.out"; then ok "positive fixture: flags '$want'"
  else bad "positive fixture: missed '$want'"; fi
done
if grep -q 'overlay/inventory' "$TMP/pos.out"; then bad "the organisation's terms under overlay/ must not be flagged"
else ok "the same terms under overlay/ are not flagged — that is where they belong"; fi

# shellcheck disable=SC2016  # the ${…} below are fixture TEXT, written unexpanded on purpose
put "$NEG" "module/services/web/compose.$yml" \
  'services:' \
  '  web:' \
  '    environment:' \
  '      OIDC_ISSUER_URL: ${OIDC_ISSUER_URL:-}' \
  '      SECRET_STORE_PREFIX: ${SECRET_STORE_PREFIX:-}' \
  '    # the overlay binds these inputs to the organisation; docs: https://example.org/docs' \
  'networks:' \
  '  default: {name: "${EDGE_NETWORK:-web-local}"}'
put "$NEG" "overlay/inventory.$yml" 'all: {hosts: {web1.acme-internal.example: {vars: {secret_prefix: kv/acme/}}}}'
CHECKOUT_NAME="" lint_module "$NEG" "$DENY" > "$TMP/neg.out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "negative fixture: parameterised module, organisation terms only under overlay/ (exit 0)"
else bad "negative fixture: should pass with exit 0, got $rc"; sed 's/^/      /' "$TMP/neg.out"; fi

CHECKOUT_NAME="" lint_module "$NEG" "$TMP/no-such-denylist" > "$TMP/missing.out" 2>&1; rc=$?
if [ "$rc" = 3 ] && grep -q 'NOT CHECKED' "$TMP/missing.out"; then ok "a missing denylist is NOT CHECKED (exit 3), never clean"
else bad "a missing denylist should be NOT CHECKED (exit 3), got $rc"; fi
printf '# only comments\n\n' > "$TMP/comments-only"
CHECKOUT_NAME="" lint_module "$NEG" "$TMP/comments-only" > "$TMP/empty.out" 2>&1; rc=$?
if [ "$rc" = 3 ]; then ok "a denylist with no patterns is NOT CHECKED (exit 3)"; else bad "a denylist with no patterns should exit 3, got $rc"; fi
printf 'acme(\n' > "$TMP/broken"
CHECKOUT_NAME="" lint_module "$NEG" "$TMP/broken" > "$TMP/broken.out" 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "a pattern that does not compile cannot run (exit 2) — never read as no match"
else bad "a broken pattern should exit 2, got $rc"; fi

echo "module-lint — this repository's module/"
lint_module "$ROOT" "$ROOT/$DENYLIST_REL" > "$TMP/root.out" 2>&1; real=$?
case "$real" in
  0) ok "module/ names nothing from the denylist, no checkout or home path, no path into overlay/" ;;
  1) bad "module/ is not generic — move these into overlay/ or make them parameters:"; sed 's/^/      /' "$TMP/root.out" ;;
  3) echo "  ⚠️  $(cat "$TMP/root.out")" ;;
  *) bad "the lint could not run: $(cat "$TMP/root.out")" ;;
esac

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
[ "$real" != 3 ] || exit 3
