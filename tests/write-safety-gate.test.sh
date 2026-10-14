#!/usr/bin/env bash
# tests/write-safety-gate.test.sh — every pattern in write-safety-gate.sh's secret-file deny list,
# tested individually.
#
# Found by mutation (quality sweep, 2026-10-14): deleting `id_ed25519` from the credential-file-write
# regex passed the WHOLE existing suite — deny-trail.test.sh only exercises env-file-write (as one
# representative path to prove the audit trail works), and hook-input.test.sh's loop covers `.ssh/`
# and `.pem$` but nothing else in that alternation. credential-file-write and ci-secret-write were,
# in effect, covered by at most one or two of their many alternatives each. One surviving mutant per
# untested alternative is the failure mode a long regex invites — this file closes it alternative by
# alternative, not just path by path.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/write-safety-gate.sh"
[[ -f "$GATE" ]] || { echo "FAIL: $GATE missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

payload() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"; }

blocked() {  # blocked <path> -> 0 if the gate refuses this path, 1 if it allows it
  local rc
  printf '%s' "$(payload "$1")" | bash "$GATE" >/dev/null 2>"$TMP/err"
  rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/err"
}

check_blocked() { blocked "$1" && pass "$2: blocked" || fail "$2: NOT blocked (should be) — path $1"; }
check_allowed() { ! blocked "$1" && pass "$2: allowed" || fail "$2: blocked (should be allowed) — path $1"; }

echo "── write-safety-gate: every secret-file pattern, individually"

echo " · env-file-write"
check_blocked "app/.env" "bare .env"
check_blocked "app/.env.production" ".env.production"
check_blocked "app/.env.staging" ".env.staging"
check_blocked "app/.env.live" ".env.live"
check_blocked "app/.env.local" ".env.local"
check_allowed "app/.env.example" ".env.example (a template, not a secret — not in the pattern)"
check_allowed "app/environment.md" "a file merely containing 'env' is not an env file"

echo " · credential-file-write"
check_blocked "app/credentials.json" "bare 'credentials' substring"
check_blocked "app/secrets.yaml" "bare 'secrets' substring"
check_blocked "app/server.pem" ".pem"
check_blocked "app/server.key" ".key"
check_blocked "app/cert.p12" ".p12"
check_blocked "app/cert.pfx" ".pfx"
check_blocked "app/keystore.jks" ".jks"
check_blocked "home/.ssh/id_rsa" "id_rsa"
check_blocked "home/id_ed25519" "id_ed25519 (the mutant that found this file's own gap)"
check_blocked "home/.ssh/config" ".ssh/ directory"
check_blocked "home/.aws/credentials" ".aws/ directory"
check_blocked "home/.gcloud/legacy_credentials" ".gcloud/ directory"
check_allowed "app/keynote.md" "'key' as a substring of an unrelated word is not .key\$"

echo " · ci-secret-write"
check_blocked "repo/.github/workflows/secret-deploy.yml" ".github/ path containing 'secret'"
check_blocked "repo/vault.yml" "vault.yml"
check_blocked "repo/vault.yaml" "vault.yaml"
check_blocked "repo/.vault-pass" ".vault-pass"
check_allowed "repo/.github/workflows/deploy.yml" "an ordinary .github workflow with no 'secret' in its path"
check_allowed "repo/values.yaml" "an ordinary yaml file is not vault.y(a)ml"

echo " · controls: ordinary files are never blocked"
check_allowed "app/README.md" "an ordinary markdown file"
check_allowed "app/src/main.py" "an ordinary source file"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
