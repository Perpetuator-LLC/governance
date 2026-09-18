#!/usr/bin/env bash
# empty-inputs.test.sh — the module starts with NONE of its core inputs set.
#
# A module that needs one organisation's identity issuer, secret store, edge network or bus just to
# start cannot be tried, tested or published without them: it is not composable. So every core input
# declared in the README's Contracts → Inputs table is optional, and every service renders from its
# plain env file alone (env.defaults beside its compose file — no SSO, no secret store, no bus):
#   - the plain env file sets no core input;
#   - every reference to a core input carries a default (${X:-…} or ${X-…}) — never bare, never ${X:?…};
#   - every other reference resolves from the plain env file or its own default;
#   - the rendered config parses, and holds a services mapping.
# A stand-in for `docker compose --env-file env.defaults config` with the inputs unset, so it runs
# without docker; where docker exists that command is the stronger check. It proves itself on fixtures
# first — a checker that renders nothing reports nothing.
# Exit: 0 proven · 1 a service needs an input to start, or a failed self-proof ·
#       3 NOT CHECKED: no service config to render, or no YAML parser

set -uo pipefail
MODULE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$MODULE/../README.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

# render_check MODULE_DIR README — print one finding per line; 0 composable · 1 findings · 2 cannot run ·
# 3 NOT CHECKED
render_check() {
  python3 - "$1" "$2" <<'PY'
import os, re, sys
try:
    import yaml
except ImportError:
    print("NOT CHECKED — no YAML parser (python3 PyYAML) to validate the rendered config")
    sys.exit(3)
module, readme = sys.argv[1], sys.argv[2]

# The declared core inputs: backticked names in the second column of the README's Inputs table.
try:
    text = open(readme, encoding="utf-8").read()
except OSError as e:
    print(f"cannot read the contract: {e}"); sys.exit(2)
m = re.search(r"^### Inputs[ \t]*\n(.*?)(?=^#|\Z)", text, re.M | re.S)
inputs = set()
for row in (m.group(1).splitlines() if m else []):
    cells = row.split("|")
    if row.lstrip().startswith("|") and len(cells) > 2:
        inputs.update(re.findall(r"`([A-Z][A-Z0-9_]*)`", cells[2]))
if not inputs:
    print("the README declares no core inputs (### Inputs table, parameter in the second column)"); sys.exit(2)

REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])((?:(?!\$\{)[^}])*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")

def interpolate(value, env, where, findings):
    """Compose's interpolation, innermost reference first; records why a reference cannot start."""
    def one(mt):
        name = mt.group(1) or mt.group(4)
        op, arg = mt.group(2), mt.group(3) or ""
        is_set, val = name in env, env.get(name, "")
        if name in inputs and op not in (":-", "-", ":+", "+"):
            findings.append(f"{where}: core input {name} is " + ("required" if op else "referenced without a default")
                            + " — give it one, so the module starts without it")
        if op in (":-", "-"):
            return val if (is_set and (val or op == "-")) else arg
        if op in (":+", "+"):
            return arg if (is_set and (val or op == "+")) else ""
        if op in (":?", "?") and not (is_set and (val or op == "?")):
            if name not in inputs:
                findings.append(f"{where}: requires {name}, which the plain env file does not set")
            return ""
        if not is_set and name not in inputs:
            findings.append(f"{where}: {name} is unset in the plain env file and has no default")
        return val
    while True:
        out = REF.sub(one, value.replace("$$", "\0"))
        if out == value.replace("$$", "\0"):
            return out.replace("\0", "$")
        value = out.replace("\0", "$$")

def walk(node, env, where, findings):
    if isinstance(node, dict):
        return {k: walk(v, env, f"{where}.{k}", findings) for k, v in node.items()}
    if isinstance(node, list):
        return [walk(v, env, f"{where}[{i}]", findings) for i, v in enumerate(node)]
    return interpolate(node, env, where, findings) if isinstance(node, str) else node

def plain_env(path):
    env = {}
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.removeprefix("export ").split("=", 1)
            v = v.strip()
            env[k.strip()] = v[1:-1] if len(v) > 1 and v[0] == v[-1] and v[0] in "'\"" else v
    return env

findings, rendered = [], 0
services = os.path.join(module, "services")
for d in sorted(os.listdir(services)) if os.path.isdir(services) else []:
    cfg = next((os.path.join(services, d, f) for f in ("compose." + ext for ext in ("yml", "yaml"))
                if os.path.isfile(os.path.join(services, d, f))), None)
    if not cfg:
        continue
    rel = os.path.relpath(cfg, module)
    env = plain_env(os.path.join(services, d, "env.defaults"))
    for name in sorted(inputs & env.keys()):
        findings.append(f"services/{d}/env.defaults sets core input {name} — the plain env file must leave it unset")
        del env[name]
    try:
        doc = yaml.safe_load(open(cfg, encoding="utf-8"))
    except yaml.YAMLError as e:
        findings.append(f"{rel}: does not parse: {e}"); continue
    out = walk(doc, env, rel, findings)
    if not isinstance(out, dict) or not isinstance(out.get("services"), dict) or not out["services"]:
        findings.append(f"{rel}: renders without a services mapping")
    rendered += 1
if not rendered:
    print("NOT CHECKED — no service config (a compose file in services/<name>/) to render"); sys.exit(3)
for f in findings:
    print(f)
print(f"rendered {rendered} service config(s) with {len(inputs)} core input(s) unset: {', '.join(sorted(inputs))}")
sys.exit(1 if findings else 0)
PY
}

echo "empty-inputs — the check proves itself (fixtures built at test time)"
yml=yml   # a suffix, not a literal: this file stays free of concrete config filenames
FX="$TMP/fixture"; mkdir -p "$FX/module"
# shellcheck disable=SC2016  # the backticks are Markdown TEXT
printf '%s\n' '## Contracts' '### Inputs' '| input | parameter |' '|---|---|' \
  '| identity issuer URL | `ISSUER_URL` |' '| edge network name | `EDGE_NET` |' '### Edges' > "$FX/README.md"
svc() {  # NAME ENV-LINE COMPOSE-LINE… — one fixture service
  local d="$FX/module/services/$1"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/env.defaults"; shift 2
  printf '%s\n' "$@" > "$d/compose.$yml"
}
# shellcheck disable=SC2016  # every ${…} below is fixture TEXT, written unexpanded on purpose
{
  svc good 'APP_IMAGE=example/app:1' \
    '# a comment is not config: ${ISSUER_URL} here is never interpolated' \
    'services:' \
    '  app:' \
    '    image: ${APP_IMAGE}' \
    '    environment: {ISSUER: "${ISSUER_URL:-}", PORT: "${PORT:-8080}", COST: "$$5"}' \
    'networks: {edge: {name: "${EDGE_NET:-app-local}"}}'
}
render_check "$FX/module" "$FX/README.md" > "$TMP/good.out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "negative fixture: inputs with defaults, settings from the plain env file (exit 0)"
else bad "negative fixture: should pass with exit 0, got $rc"; sed 's/^/      /' "$TMP/good.out"; fi

# shellcheck disable=SC2016
{
  svc bare 'APP_IMAGE=example/app:1' 'services: {app: {image: "${APP_IMAGE}", environment: {ISSUER: "${ISSUER_URL}"}}}'
  svc required 'APP_IMAGE=example/app:1' 'services: {app: {image: "${APP_IMAGE}", networks: ["${EDGE_NET:?set the edge network}"]}}'
  svc envfile 'ISSUER_URL=https://id.example.org' 'services: {app: {image: "example/app:1", environment: {ISSUER: "${ISSUER_URL:-}"}}}'
  svc unset 'APP_IMAGE=example/app:1' 'services: {app: {image: "${APP_IMAGE}", ports: ["${APP_PORT}:80"]}}'
}
render_check "$FX/module" "$FX/README.md" > "$TMP/bad.out" 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok "positive fixture: the check fails (exit 1)"; else bad "positive fixture: should fail with exit 1, got $rc"; fi
for want in "bare/compose\.$yml.*ISSUER_URL is referenced without a default" \
            "required/compose\.$yml.*EDGE_NET is required" \
            "envfile/env.defaults sets core input ISSUER_URL" \
            "unset/compose\.$yml.*APP_PORT is unset"; do
  if grep -qE "$want" "$TMP/bad.out"; then ok "positive fixture: flags ${want%%/*}"; else bad "positive fixture: missed ${want%%/*}"; fi
done
if grep -q '^services/good\|good/compose' "$TMP/bad.out"; then bad "the good service must stay clean beside the bad ones"
else ok "the good service stays clean beside the bad ones (a YAML comment is never interpolated)"; fi

mkdir -p "$TMP/empty-module/services"
render_check "$TMP/empty-module" "$FX/README.md" > "$TMP/empty.out" 2>&1; rc=$?
if [ "$rc" = 3 ]; then ok "a module with no service config is NOT CHECKED (exit 3), never composable by default"
else bad "a module with nothing to render should exit 3, got $rc"; fi

echo "empty-inputs — this module"
render_check "$MODULE" "$README" > "$TMP/real.out" 2>&1; real=$?
case "$real" in
  0) ok "every service starts from its plain env file with no core input set — $(tail -1 "$TMP/real.out")" ;;
  1) bad "a service needs a core input to start:"; sed 's/^/      /' "$TMP/real.out" ;;
  3) echo "  ⚠️  $(cat "$TMP/real.out")" ;;
  *) bad "the check could not run: $(cat "$TMP/real.out")" ;;
esac

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
[ "$real" != 3 ] || exit 3
