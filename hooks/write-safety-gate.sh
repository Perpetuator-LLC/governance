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
# A harness on Windows passes native paths (`C:\Users\x\.ssh\config`). Every directory rule below
# matches `/`, so a backslash path slipped past `.ssh/`, `.aws/`, `.gnupg/`, `.kube/config` and the
# rest (#288). Match on one separator: backslashes become slashes before any rule reads the path.
path=${path//\\//}
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

# Every secret-path match below is CASE-INSENSITIVE (`grep -i`). Windows and default macOS (APFS)
# filesystems are case-insensitive, so `.ENV`, `.Env` or `ID_RSA` open the very same file as the
# lowercase name; a case-sensitive pattern let those spellings write it unrefused.

# Block writes to environment/secrets files. A DENYLIST of suffixes (`.prod`, `.local`, …) is a list
# that is always one spelling behind: `.env.stage`, `.env.ci`, `.env.qa`, `.env.uat`, `.env.preview`
# and `.env.local.bak` were all measured writable (#301), each one more spelling the list hadn't named
# yet. Inverted to an ALLOWLIST instead: every `.env` or `.env.<anything>` is blocked UNLESS the
# `<anything>` is exactly `example`, `sample` or `template` — the only spellings that hold no secret.
# `.envrc` is direnv's, which exports secrets, so it is caught by the same boundary SECRET_NAME uses
# elsewhere (bash-safety-gate.sh): "env" followed by a non-letter, or "rc" followed by ANYTHING. The
# read gate has no end anchor after "rc"; an `rc$` here left `.envrc.local` and `.envrc.private`
# writable while reading them was refused (#272). The template exemption is the read gate's too, and
# covers `.envrc.example` the same way. Both gates must give one verdict per name; the write gate's
# test file runs each name through both.
if echo "$path" | grep -qiE '\.env([^a-zA-Z]|rc|$)' \
  && ! echo "$path" | grep -qiE '\.env(rc)?\.(example|sample|template)$'; then
  deny env-file-write "Cannot write to environment files. These may contain secrets. Edit manually."
fi

# Block writes to credential/key files: names and extensions that hold a key wherever they live.
if echo "$path" | grep -qiE '(credentials|secrets|\.pem$|\.key$|\.p12$|\.pfx$|\.jks$|id_rsa|id_ed25519)'; then
  deny credential-file-write "Cannot write to credential or key files. Edit manually."
fi

# Block writes to credential STORES, matched by directory and known file, not by one name each. A list
# of single file names is always one name behind: `.kube/config.bak`, `.pypirc`, `.yarnrc.yml`,
# `.vault-token` and `.config/gh/hosts.yml` were each measured writable after the list had grown to
# `.kube/config` and its neighbours (#272). Two shapes instead:
#  - a store DIRECTORY, where any file may hold a key or token: `.ssh/`, `.aws/`, `.gcloud/`, `.gnupg/`,
#    `.kube/` (kubeconfigs, their backups, cached cluster tokens);
#  - a store FILE, a tool's known login file, with or without a backup suffix (`.bak`, `.old`, `~`):
#    `.netrc`/`_netrc`, `.npmrc`, `.yarnrc`/`.yarnrc.yml`, `.pypirc`, `.pgpass`, `.vault-token`,
#    `.git-credentials`, `.docker/config.json`, the GitHub CLI's `hosts.yml`. A template suffix
#    (`.example`, `.sample`, `.template`) holds no secret and stays writable, as for the env files.
# Scope: the gate sees the PATH only, never the content. It refuses every `.npmrc` and `.yarnrc.yml`,
# including a project's committed one that holds no token; that cost is the price of not reading the
# file to find out. It does not see a store reached through a symlink or a relocated path
# (`$KUBECONFIG`, `$DOCKER_CONFIG`, `$NETRC`).
CRED_DIR='\.(ssh|aws|gcloud|gnupg|kube)/'
CRED_FILE='(^|/)(\.netrc|_netrc|\.npmrc|\.yarnrc|\.pypirc|\.pgpass|\.vault-token|\.git-credentials|\.docker/config\.json|\.config/gh/hosts\.yml|github cli/hosts\.yml)([.~][^/]*)?$'
if echo "$path" | grep -qiE "$CRED_DIR" \
  || { echo "$path" | grep -qiE "$CRED_FILE" && ! echo "$path" | grep -qiE '\.(example|sample|template)$'; }; then
  deny credential-store-write "Cannot write to a credential store (a login, token or key file or directory). Edit manually."
fi

# Block writes to CI/CD secrets
if echo "$path" | grep -qiE '(\.github/.*secret|vault\.y[a]?ml|\.vault-pass)'; then
  deny ci-secret-write "Cannot write to CI/CD secrets files. Edit manually."
fi

exit 0
