#!/bin/bash
# Hook: PreToolUse[Write] — Prevent writing to secrets and sensitive files
# Exit 2 = block the tool call with message shown to Claude
# Exit 0 = allow

# Claude Code delivers hook input as JSON on STDIN: {"tool_name": ..., "tool_input": {...}}. This hook
# originally read $CLAUDE_TOOL_INPUT, which the harness never sets, so every check below received an
# empty string and ALLOWED everything, silently, from the first commit. The env var is kept only as a
# fallback for a harness that still uses it.
input=""
[[ ! -t 0 ]] && input=$(cat)

# Every refusal goes through deny(): the one-line reason to the model, then ONE audit event from
# deny-event.py beside this script (OCSF api_activity, security_control). The event carries a hash of the
# refused text, never the text. The trail fails OPEN (no helper, no python3, an unwritable log) and never
# changes the verdict.
DENY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/deny-event.py"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
gate_real_dir() {  # the directory of this script's REAL file, symlinks followed (portable: no readlink -f)
  local src="${BASH_SOURCE[0]}" dir
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)" || return 0
    src="$(readlink "$src")" || return 0
    [[ "$src" == /* ]] || src="$dir/$src"
  done
  cd -P "$(dirname "$src")" 2>/dev/null && pwd
}
# A gate COPIED or SYMLINKED somewhere with no credential-paths.sh beside it must still refuse a known
# credential path, not silently match EVERY path (an empty CRED_PATH makes `grep -qE "$CRED_PATH"`
# match any non-empty string). CRED_PATH gets an embedded default first, then an external
# credential-paths.sh (real dir, then beside the link) overrides it when present.
# tests/credential-path-gates-agree.test.sh diffs this copy against the file.
# >>> embedded copy of credential-paths.sh (code lines only; keep identical)
CRED_PATH='(^|[/~])\.aws/(credentials|config)([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.netrc([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.ssh/(id_[A-Za-z0-9_-]+|[A-Za-z0-9_-]+_key)([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.docker/config\.json([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.kube/config([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.config/gh/hosts\.yml([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.git-credentials([^A-Za-z0-9._/-]|$)'
CRED_PATH+='|(^|[/~])\.pgpass([^A-Za-z0-9._/-]|$)'
# <<< end of embedded copy
for CRED_PATHS_FILE in "$(gate_real_dir)/credential-paths.sh" "$(dirname "${BASH_SOURCE[0]}")/credential-paths.sh"; do
  # shellcheck source=credential-paths.sh
  [[ -f "$CRED_PATHS_FILE" ]] && . "$CRED_PATHS_FILE" && break
done
deny() {  # deny <rule-id> <reason>: refuse, record, exit 2
  echo "BLOCKED: $2" >&2
  if [[ -f "$DENY_HELPER" ]] && python3 -c '' >/dev/null 2>&1; then
    printf '%s' "${path:-}" | python3 "$DENY_HELPER" --gate write-safety-gate --rule "$1" \
      --tool "${tool:-}" --reason "$2" >/dev/null 2>&1 || true
  fi
  exit 2
}
# Parse with jq when present, python3 otherwise: a CI runner or a fresh machine may lack jq, and a
# parser dependency that is silently absent is exactly how this hook read nothing for months.
tool_field() {  # tool_field <json> <.path> [<.path> ...]  -> first non-empty string
  local json="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    local k v
    for k in "$@"; do
      # `strings`: a non-string value is unreadable, as in the python branch. Without it jq printed an
      # array as JSON text, so one payload got two verdicts depending on which parser the host had.
      v=$(printf '%s' "$json" | jq -r "($k | strings) // empty" 2>/dev/null)
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    done
  elif python3 -c '' >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1:]:
    v = d
    for p in k.strip(".").split("."):
        v = v.get(p) if isinstance(v, dict) else None
    if isinstance(v, str) and v:
        sys.stdout.write(v)
        break
' "$@"
  fi
}
is_json() {
  if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -e . >/dev/null 2>&1
  else printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; fi
}
if ! command -v jq >/dev/null 2>&1 && ! python3 -c '' >/dev/null 2>&1; then
  deny no-parser "this safety gate cannot evaluate the call (neither jq nor python3 is installed). Install one, or run the command yourself."
fi
if [[ -n "$input" ]] && ! is_json "$input"; then
  deny unparseable-input "this safety gate received tool input it cannot parse; refusing rather than allowing it unchecked."
fi
if [[ -z "$input" && -z "${CLAUDE_TOOL_INPUT:-}" ]]; then
  echo "safety gate: no tool input on stdin or in CLAUDE_TOOL_INPUT; nothing was checked" >&2
fi
path=$(tool_field "$input" .tool_input.file_path .tool_input.path .toolInput.file_path .toolInput.path)
[[ -z "$path" && -n "${CLAUDE_TOOL_INPUT:-}" ]] && path=$(tool_field "$CLAUDE_TOOL_INPUT" .file_path .path)
tool=$(tool_field "$input" .tool_name .toolName)   # once, for deny()'s event

if [[ -z "$path" ]]; then
  # A write payload with no path this gate can read is a BLIND gate, not a pathless write: refuse.
  # `write` and `search_replace` are Grok's names for Write and Edit (captured 2026-09-25).
  if [[ -n "$input" ]]; then
    tool=$(tool_field "$input" .tool_name .toolName)
    case "$tool" in
      ""|Write|Edit|MultiEdit|write|search_replace)
        deny blind-payload "this safety gate cannot read the file path in this ${tool:-unnamed} tool payload; refusing rather than allowing it unchecked." ;;
    esac
  fi
  exit 0
fi

# A Windows path names the same file with `\` as with `/`, and every directory rule below is written
# with `/`: `C:\Users\me\.ssh\config` and `.kube\config` were writable while the slash forms were
# refused. Canonicalise once, before any match.
path="${path//\\//}"

# Every secret-path match below is CASE-INSENSITIVE (`grep -i`). Windows and default macOS (APFS)
# filesystems are case-insensitive, so `.ENV`, `.Env` or `ID_RSA` open the very same file as the
# lowercase name; a case-sensitive pattern let those spellings write it unrefused.

# Block writes to environment/secrets files, by the SAME name list the read gate uses
# (secret-names.sh, found as below): what bash-safety-gate.sh refuses to read, this refuses to
# write. A DENYLIST of suffixes (`.prod`, `.local`, …) is always one spelling behind: `.env.stage`,
# `.env.ci`, `.env.qa`, `.env.uat`, `.env.preview` and `.env.local.bak` were all measured writable
# (#301). So it is an ALLOWLIST: every `.env`, `.env.<anything>` or `.envrc<anything>` is blocked
# UNLESS it is a whole template name (`.env.example`, `.env.sample`, `.env.template`).
#
# WHERE the list is found: this script's REAL directory (symlinks followed), then beside the link, then
# the copy embedded below. The installer links hooks file by file, so looking only beside the link
# refused every write on a machine whose links predated secret-names.sh. Same loader as
# bash-safety-gate.sh; tests/secret-names-fallback.test.sh diffs this copy against the file.
# >>> embedded copy of secret-names.sh (code lines only; keep identical)
SECRET_NAME='\.[eE][nN][vV]([^A-Za-z]|[rR][cC]|$)'
SECRET_TEMPLATES='example|sample|template'
strip_secret_templates() {
  local s="$1" re="^(.*)\\.env\\.(${SECRET_TEMPLATES})(\$|[[:space:]\"'/;&|<>)].*)\$" nocase=0 mark=$'\001'
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  while [[ "$s" =~ $re ]]; do s="${BASH_REMATCH[1]}${mark}${BASH_REMATCH[3]}"; done
  [ "$nocase" = 1 ] || shopt -u nocasematch
  printf '%s' "${s//$mark/}"
}
# <<< end of embedded copy
for SECRET_NAMES_FILE in "$(gate_real_dir)/secret-names.sh" "$(dirname "${BASH_SOURCE[0]}")/secret-names.sh"; do
  # shellcheck source=secret-names.sh
  [[ -f "$SECRET_NAMES_FILE" ]] && . "$SECRET_NAMES_FILE" && break
done
if [[ -z "${SECRET_NAME:-}" || -z "${SECRET_TEMPLATES:-}" ]]; then
  deny secret-names-missing "this safety gate's secret-name list is empty (secret-names.sh); refusing rather than allowing it unchecked."
fi
if strip_secret_templates "$path" | grep -qE "$SECRET_NAME"; then
  deny env-file-write "Cannot write to environment files. These may contain secrets. Edit manually."
fi

# Block writes to credential/key files. The second line is files whose ordinary use holds a login or
# token: `.netrc` (machine passwords), `.npmrc` (registry auth tokens), `.pgpass` (PostgreSQL
# passwords), the Docker and Kubernetes client configs (registry auths, cluster tokens), and the GnuPG
# home (private keys). `.git-credentials` is already caught by `credentials`.
if echo "$path" | grep -qiE '(credentials|secrets|\.pem$|\.key$|\.p12$|\.pfx$|\.jks$|id_rsa|id_ed25519|\.ssh/|\.aws/|\.gcloud/)' \
  || echo "$path" | grep -qiE '(\.netrc$|\.npmrc$|\.pgpass$|\.docker/config\.json$|\.kube/config$|\.gnupg/)'; then
  deny credential-file-write "Cannot write to credential or key files. Edit manually."
fi

# The same well-known credential PATHS the read gate refuses (hooks/credential-paths.sh, governance#335)
# — named here too so the two gates can't drift apart on exactly this list; tests/credential-path-gates-
# agree.test.sh is the KAT. Most of these already match the broader rule above; ~/.netrc, ~/.docker/
# config.json, ~/.kube/config, ~/.config/gh/hosts.yml, ~/.git-credentials and ~/.pgpass do not.
# An external credential-paths.sh that loaded but blanked CRED_PATH must refuse, not silently skip this
# whole rule (the embedded default above means CRED_PATH is otherwise never actually empty).
if [[ -z "$CRED_PATH" ]]; then
  deny credential-paths-missing "this safety gate's credential-path list is empty (credential-paths.sh); refusing rather than allowing it unchecked."
fi
if echo "$path" | grep -qE "$CRED_PATH"; then
  deny credential-path-write "Cannot write to a well-known credential file (an AWS/SSH/Docker/Kubernetes/git/gh/Postgres credential store, or similar). Edit manually."
fi

# Block writes to CI/CD secrets
if echo "$path" | grep -qiE '(\.github/.*secret|vault\.y[a]?ml|\.vault-pass)'; then
  deny ci-secret-write "Cannot write to CI/CD secrets files. Edit manually."
fi

exit 0
