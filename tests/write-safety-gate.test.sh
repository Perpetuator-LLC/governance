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
check_blocked "app/.env.development" ".env.development (#272)"
check_blocked "app/.env.dev" ".env.dev (#272)"
check_blocked "app/.env.test" ".env.test (#272)"
check_blocked "app/.envrc" ".envrc, direnv's secret exports (#272)"
check_allowed "app/.env.sample" ".env.sample (a template, not a secret)"
check_allowed "app/.env.template" ".env.template (a template, not a secret)"

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
check_blocked "home/.netrc" ".netrc (#272)"
check_blocked "home/.npmrc" ".npmrc (#272)"
check_blocked "home/.pgpass" ".pgpass (#272)"
check_blocked "home/.docker/config.json" ".docker/config.json (#272)"
check_blocked "home/.kube/config" ".kube/config (#272)"
check_blocked "home/.gnupg/private-keys-v1.d/x.key" ".gnupg/ directory (#272)"
check_blocked "home/.gnupg/pubring.kbx" ".gnupg/ directory, a file no other pattern names (#272)"
check_blocked "home/.git-credentials" ".git-credentials (via 'credentials')"
check_allowed "app/docker/config.json" "a docker/config.json that is not the client's .docker/ is not a credential file"
check_allowed "app/kube/config.yaml" "an ordinary kube manifest is not .kube/config"

echo " · ci-secret-write"
check_blocked "repo/.github/workflows/secret-deploy.yml" ".github/ path containing 'secret'"
check_blocked "repo/vault.yml" "vault.yml"
check_blocked "repo/vault.yaml" "vault.yaml"
check_blocked "repo/.vault-pass" ".vault-pass"
check_allowed "repo/.github/workflows/deploy.yml" "an ordinary .github workflow with no 'secret' in its path"
check_allowed "repo/values.yaml" "an ordinary yaml file is not vault.y(a)ml"

echo " · case variants (#271): Windows and default macOS filesystems are case-insensitive"
for p in app/.ENV app/.Env app/.eNv app/.ENV.PRODUCTION app/.Env.Local app/.ENVRC app/.ENV.DEVELOPMENT; do
  check_blocked "$p" "env-file-write, case variant $p"
done
for p in home/.SSH/ID_RSA home/ID_ED25519 app/Credentials.json app/SECRETS.yaml app/server.PEM \
         home/.NETRC home/.NpmRc home/.PGPASS home/.Docker/Config.json home/.KUBE/CONFIG home/.GnuPG/x; do
  check_blocked "$p" "credential-file-write, case variant $p"
done
for p in repo/.github/workflows/SECRET.yml repo/.GitHub/Secret-deploy.yml repo/VAULT.YML repo/.Vault-Pass; do
  check_blocked "$p" "ci-secret-write, case variant $p"
done
check_allowed "app/.ENV.EXAMPLE" "a template stays allowed in any case"
check_allowed "app/Environment.md" "a file merely containing 'Env' is not an env file, in any case"

echo " · Windows backslash paths (#288): every directory rule matches them too"
# Written JSON-escaped (\\) because payload() drops the path into a JSON string; the gate sees one
# backslash per separator, as a Windows harness sends it. Each name below is caught ONLY by a directory
# rule, so a gate that matches `/` alone lets it through.
for p in 'C:\\Users\\x\\.ssh\\authorized_keys' 'C:\\Users\\x\\.aws\\config' 'C:\\Users\\x\\.gcloud\\adc.json' \
         'C:\\Users\\x\\.gnupg\\pubring.kbx' 'C:\\Users\\x\\.docker\\config.json' 'C:\\Users\\x\\.kube\\config'; do
  check_blocked "$p" "backslash path $p"
done
check_allowed 'C:\\Users\\x\\project\\README.md' "an ordinary backslash path"
check_allowed 'C:\\Users\\x\\docker\\config.json' "docker\\config.json outside a dot-directory (as with /)"

echo " · controls: ordinary files are never blocked"
check_allowed "app/README.md" "an ordinary markdown file"
check_allowed "app/src/main.py" "an ordinary source file"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
