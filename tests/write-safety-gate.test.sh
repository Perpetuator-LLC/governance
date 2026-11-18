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

# JSON-escape the path's backslashes: a raw one makes the payload unparseable, and the gate refuses it
# for THAT reason, a block that would hide the verdict the row is testing.
payload() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "${1//\\/\\\\}"; }

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

echo " · env-file-write uses the READ gate's name list: what it refuses to read, this refuses to write"
check_blocked "app/.envrc.local" ".envrc.local (direnv secrets; read-blocked, so write-blocked)"
check_blocked "app/.envrc.private" ".envrc.private"
check_blocked "app/.ENVRC.LOCAL" ".ENVRC.LOCAL (case variant)"
check_blocked "app/.env.example.local" ".env.example.local (a template prefix, then a real suffix)"
check_blocked "app/.env.sample2" ".env.sample2 (not exactly a template name)"
check_blocked "app/.env/.env.example" "a template inside a .env directory: the directory name still matches"

echo " · Windows backslash paths: the same file as the slash form, so the same verdict"
check_blocked 'C:\Users\me\.kube\config' 'backslash .kube\config'
check_blocked 'C:\Users\me\.docker\config.json' 'backslash .docker\config.json'
check_blocked 'C:\Users\me\.gnupg\pubring.kbx' 'backslash .gnupg\'
check_blocked 'C:\Users\me\.ssh\config' 'backslash .ssh\'
check_blocked 'C:\Users\me\.aws\config' 'backslash .aws\'
check_blocked 'C:\Users\me\.gcloud\legacy' 'backslash .gcloud\'
check_blocked 'C:\repo\.github\workflows\secret.yml' 'backslash .github\...secret'
check_blocked 'C:\proj\.envrc.local' 'backslash .envrc.local'
check_blocked 'C:\proj\.env' 'backslash .env'
check_allowed 'C:\proj\.env.example' 'backslash .env.example (a template stays allowed)'
check_allowed 'C:\proj\docker\config.json' "backslash docker\\config.json (not the client's .docker)"
check_allowed 'C:\proj\src\main.py' 'backslash ordinary source file'

echo " · Windows path forms: every spelling Windows opens as the same file (win_canon, shared with the #300 fix)"
# `$DATA` sits in single quotes: escaping it (`\$`) would put an invalid JSON escape in the payload, and
# the gate's unparseable-input refusal would pass the check for the wrong reason.
check_blocked 'C:\r\.env.' "trailing dot (Windows strips it)"
check_blocked 'C:\r\.env  ' "trailing spaces (Windows strips them)"
check_blocked 'C:.npmrc.' "drive-relative C: with a trailing dot"
check_blocked 'C:\r\.env::$DATA' "NTFS default stream ::\$DATA"
check_blocked 'C:\Users\x\.npmrc:$DATA' "NTFS stream :\$DATA"
check_blocked 'C:\r\.env:foo:$DATA' "NTFS named stream :foo:\$DATA"
check_blocked 'C:\r\.env:foo' "NTFS named stream :foo"
check_blocked 'C:.env:$DATA' "drive-relative C: with a stream (the drive colon is not the stream colon)"
check_blocked 'C:\Users\x\.kube.\config' "trailing dot on a directory component"
check_blocked 'C:\Users\x\.docker \config.json' "trailing space on a directory component"
check_blocked 'C:\Users\x\.gnupg..\pubring.kbx' "trailing dots on a directory component"
check_blocked 'C:\Users\x\.kube\/config' "mixed separators \\/ (one separator to Windows)"
check_blocked 'C:/Users/x/.kube//config' "doubled separator //"
if command -v cygpath >/dev/null 2>&1; then
  mkdir "$TMP/.kube"
  short=$(cygpath -s -m "$TMP/.kube" 2>/dev/null)
  if [[ "${short##*/}" == *"~"* ]]; then
    check_blocked "$short/config" "8.3 short name ${short##*/} for .kube"
  else
    echo "  SKIP  8.3 short name: this volume generates none"
  fi
else
  echo "  SKIP  8.3 short name: no cygpath (not a Windows host)"
fi
# The env rule is an ALLOWLIST and runs on BOTH spellings, so `.env.example.` is refused: on Linux and
# macOS it is a real file distinct from the template, and not a template name.
check_blocked 'C:\r\.env.example.' "a template with a trailing dot (a distinct non-template name off Windows)"
# The env rule's 8.3 leg, on any host: a stub cygpath expands a `~1` name the way Windows would, to a
# secret name the path as given never spells. Only the Windows spelling can refuse it (it killed the
# mutant that drops that leg, which no other row did).
mkdir -p "$TMP/w83/bin" && : > "$TMP/w83/ABCDEF~1"
printf '#!/bin/sh\nfor a; do :; done\nprintf "%%s" "${a%%/*}/.env.local"\n' > "$TMP/w83/bin/cygpath"
chmod +x "$TMP/w83/bin/cygpath"
if PATH="$TMP/w83/bin:$PATH" blocked "$TMP/w83/ABCDEF~1"; then pass "8.3 name a stub cygpath expands to .env.local: blocked"
else fail "8.3 name a stub cygpath expands to .env.local: NOT blocked (should be)"; fi
# A `\` is read as a Windows `/` AND as written (a real name character off Windows): refused if either
# spelling matches. `.env.example\.local` is one non-template file on Linux; and, fail closed, a Windows
# path inside a template directory is refused too (write it with `/`).
check_blocked 'app/.env.example\.local' "a template name, a backslash, then more name (one real file off Windows)"
check_blocked 'app/.env.sample\2' "a template name, a backslash, then more name"
check_blocked 'C:\proj\.env.example\notes.txt' "a backslash path inside a template directory (fail closed)"
check_allowed 'app/.env.example/notes.txt' "a slash path inside a template directory stays allowed"
check_allowed 'C:\r\notes:2026.md' "a colon in an ordinary name"
check_allowed 'C:\Users\x\project\.\README.md' "a . component stays an ordinary path"

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

echo " · controls: ordinary files are never blocked"
check_allowed "app/README.md" "an ordinary markdown file"
check_allowed "app/src/main.py" "an ordinary source file"

echo
if [[ $fails -eq 0 ]]; then echo "  ✅ all checks passed"; exit 0
else echo "  ❌ $fails failed"; exit 1
fi
