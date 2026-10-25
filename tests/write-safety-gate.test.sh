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

echo " · env-file-write, allowlist not denylist (#301): a spelling the old denylist never named"
check_blocked "app/.env.stage" ".env.stage (not on the old denylist, but not a template either)"
check_blocked "app/.env.ci" ".env.ci"
check_blocked "app/.env.qa" ".env.qa"
check_blocked "app/.env.uat" ".env.uat"
check_blocked "app/.env.preview" ".env.preview"
check_blocked "app/.env.local.bak" ".env.local.bak (a backup suffix after a real one, still a secret)"
check_blocked "app/.ENV.STAGE" ".ENV.STAGE (case-insensitive, same gap)"
check_allowed "app/.ENV.EXAMPLE" ".ENV.EXAMPLE (the allowlist, not just the old denylist, is case-insensitive)"

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

echo " · credential STORES, by directory and known file (#272): names a single-name list missed"
# Each was measured writable against the single-name list. A store is matched by its directory (any
# file under it) or by its known file name, with or without a backup suffix (`.bak`, `.old`, `~`).
for p in home/.kube/config.bak home/.kube/cache/discovery/token home/.pypirc app/.yarnrc.yml app/.yarnrc \
         home/.vault-token home/.config/gh/hosts.yml home/.netrc.bak home/_netrc home/.npmrc.old \
         home/.docker/config.json.bak app/.envrc.local app/.envrc.private \
         home/.KUBE/CONFIG.BAK home/.PyPiRc home/.Vault-Token home/.Config/GH/Hosts.yml app/.ENVRC.LOCAL; do
  check_blocked "$p" "credential store $p"
done

echo " · Windows backslash forms of the same stores (#272): one separator before any rule reads the path"
# JSON-escaped (\\) because payload() drops the path into a JSON string; the gate sees one backslash.
for p in 'C:\\Users\\me\\.kube\\config' 'C:\\Users\\me\\.docker\\config.json' 'C:\\Users\\me\\.gnupg\\pubring.kbx' \
         'C:\\Users\\me\\.ssh\\config' 'C:\\Users\\me\\.aws\\config' 'C:\\Users\\me\\.config\\gh\\hosts.yml' \
         'C:\\Users\\me\\.pypirc' 'C:\\Users\\me\\.vault-token' 'C:\\proj\\.envrc.local'; do
  check_blocked "$p" "backslash path $p"
done

echo " · templates and look-alikes stay writable (#272)"
for p in app/.envrc.example app/.envrc.sample app/.envrc.template app/.ENVRC.EXAMPLE \
         app/.pypirc.example home/.netrc.sample; do
  check_allowed "$p" "template $p"
done
for p in docs/kube-config-guide.md src/vault_token_parser.py docs/pypirc.md app/yarnrc-notes.md \
         src/gh/hosts.yml app/envrc_loader.sh docs/netrc-format.md src/npmrc.ts \
         'C:\\Users\\me\\docs\\kube-config-guide.md'; do
  check_allowed "$p" "look-alike $p"
done

echo " · read and write agree on the same names (#272): bash-safety-gate's read verdict = this gate's write verdict"
# The read gate (bash-safety-gate.sh, a Bash `cat <name>` payload) and this gate must give ONE verdict
# per name: a name readable but not writable, or the reverse, is a rule one side forgot. Without
# python3 the read gate cannot strip a template name and fails closed, so the template rows are NOT
# RUN there rather than reported as a disagreement.
READ_GATE="$ROOT/hooks/bash-safety-gate.sh"
read_blocked() {
  local rc
  printf '{"tool_name":"Bash","tool_input":{"command":"cat %s"}}' "$1" | bash "$READ_GATE" >/dev/null 2>"$TMP/rerr"
  rc=$?
  [[ "$rc" == "2" ]] && grep -q '^BLOCKED' "$TMP/rerr"
}
for n in .env .env.local .envrc .envrc.local .envrc.private .ENVRC.LOCAL .env.example.local .env.template.prod \
         .env.sample2 .env.example .envrc.example .ENV.EXAMPLE .ENVRC.SAMPLE; do
  if [[ "$n" =~ \.(example|sample|template|EXAMPLE|SAMPLE|TEMPLATE)$ ]] && ! python3 -c '' >/dev/null 2>&1; then
    printf '  NOT RUN  agreement on %s (no python3: the read gate fails closed on templates)\n' "$n"; continue
  fi
  r=allow; w=allow
  read_blocked "app/$n" && r=block
  blocked "app/$n" && w=block
  [[ "$r" == "$w" ]] && pass "agree on $n ($r)" || fail "disagree on $n: read=$r write=$w"
done

echo " · controls: ordinary files are never blocked"
check_allowed "app/README.md" "an ordinary markdown file"
check_allowed "app/src/main.py" "an ordinary source file"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
