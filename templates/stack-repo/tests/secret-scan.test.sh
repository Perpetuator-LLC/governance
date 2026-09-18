#!/usr/bin/env bash
# secret-scan.test.sh — the secret scan proves its rules FIRE, not only that a scan came back clean.
#
# A clean scan cannot tell "no secrets" from "rules that match nothing": a config that loads no rules,
# or a scanner that read nothing, is clean forever. So, with THIS repository's scanner config:
#   positive  one synthetic secret per rule, each caught by that NAMED rule id
#   negative  env and template shapes — empty values, ${VAR} placeholders, template expressions —
#             caught by no rule
#   sentinel  the negative example-env file with one real-shaped value appended IS caught: the negative
#             passed because nothing matched, not because the file was never read
# Every fixture is built here, at test time, from parts: nothing committed has a secret's shape, so this
# repository's own scan and a forge's push protection stay quiet about this file.
# Exit: 0 proven · 1 a rule did not fire, or fired on a placeholder · 3 NOT CHECKED: no scanner on PATH

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/.gitleaks.toml"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "NOT CHECKED — scanner not installed (gitleaks is not on PATH); a missing scanner is never a clean scan" >&2
  exit 3
fi
[ -f "$CONFIG" ] || { echo "no scanner config at $CONFIG" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

# scan LABEL DIR — scan DIR with this repository's config; report in $TMP/LABEL.json; 0 clean · 1 found
scan() {
  gitleaks dir "$2" --config "$CONFIG" --no-banner --redact --exit-code 1 \
    --report-format json --report-path "$TMP/$1.json" >"$TMP/$1.log" 2>&1
}
rules() { grep -o '"RuleID": *"[^"]*"' "$TMP/$1.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | sort -u; }
caught_by() {  # LABEL DIR RULE — scan, then assert that exact rule id fired
  scan "$1" "$2"; local rc=$?
  if [ "$rc" = 1 ] && rules "$1" | grep -qx "$3"; then
    ok "positive: $1 is caught by rule '$3'"
  else
    bad "positive: $1 should be caught by rule '$3' (exit $rc; rules fired: $(rules "$1" | tr '\n' ' '))"
  fi
}

echo "secret scan — $(gitleaks version) with $(basename "$CONFIG")"
key_value="$(printf '%s' q7Rz W2mX 9vLk P4nB e8Tj H3cY u6Gs D1fA)"   # synthetic, high-entropy, no vendor format
pem_begin="-----BEGIN RSA PRIV""ATE KEY-----"; pem_end="-----END RSA PRIV""ATE KEY-----"

mkdir -p "$TMP/private-key" "$TMP/generic-api-key" "$TMP/negative"
{
  printf '%s\n' "$pem_begin"
  for i in 1 2 3 4 5 6; do printf 'Zm9yLXRlc3RzLW9ubHktdGhpcy1pcy1maXh0dXJlLWRhdGEtbm90LWEta2V5LS0%s\n' "$i"; done
  printf '%s\n' "$pem_end"
} > "$TMP/private-key/id_fixture"
printf 'api_key = "%s"\n' "$key_value" > "$TMP/generic-api-key/settings.py"
caught_by private-key "$TMP/private-key" private-key
caught_by generic-api-key "$TMP/generic-api-key" generic-api-key

yml=yml   # a suffix, not a literal: this file stays free of concrete config filenames
# shellcheck disable=SC2016  # every ${…} and {{ … }} below is fixture TEXT, written unexpanded on purpose
{
  printf '%s\n' \
    'API_KEY=' \
    'API_TOKEN=${API_TOKEN}' \
    'DB_PASSWORD=${DB_PASSWORD:-}' \
    'SECRET_KEY=changeme' \
    'AUTH_TOKEN=<your-token-here>' \
    'SERVICE_TOKEN=${SERVICE_TOKEN:?read it from the secret store}' > "$TMP/negative/.env.example"
  printf '%s\n' \
    'services:' \
    '  app:' \
    '    environment:' \
    '      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}' \
    '      client_secret: ${OIDC_CLIENT_SECRET}' \
    '      secret_key_base: "${SECRET_KEY_BASE}"' \
    '      api_key: "{{ vault_api_key }}"' \
    "      access_token: \"{{ lookup('env', 'ACCESS_TOKEN') }}\"" > "$TMP/negative/compose.$yml"
}
scan negative "$TMP/negative"; rc=$?
if [ "$rc" = 0 ] && [ -f "$TMP/negative.json" ] && [ -z "$(rules negative)" ]; then
  ok "negative: empty values, \${VAR} placeholders and template expressions are caught by no rule"
else
  bad "negative: env/template shapes must not be caught (exit $rc; rules fired: $(rules negative | tr '\n' ' '))"
fi

cp -R "$TMP/negative" "$TMP/sentinel"
printf 'API_KEY=%s\n' "$key_value" >> "$TMP/sentinel/.env.example"
scan sentinel "$TMP/sentinel"; rc=$?
if [ "$rc" = 1 ] && rules sentinel | grep -qx generic-api-key && grep -q '"File": *"[^"]*\.env\.example"' "$TMP/sentinel.json"; then
  ok "sentinel: the same example-env file with one real-shaped value appended IS caught — it was read"
else
  bad "sentinel: a value appended to the negative example-env file should be caught (exit $rc)"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
