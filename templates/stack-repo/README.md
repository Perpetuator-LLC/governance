# {{name}}

<!-- Scaffolded from the governance stack-repo template. Replace every <placeholder>; keep the headings —
reviewers and tooling look for them by name. -->

## What it is

<One paragraph: what this stack runs, and who or what depends on it.>

### Layout: a generic module and a private overlay

| path | layer | holds |
|---|---|---|
| `module/` | CORE — generic, parameterised, publishable | `services/<name>/` (compose + config + a plain env file), `deploy/` (the roles and playbooks this repository owns), `scripts/` (operator scripts), `tests/` (the module's own tests) |
| `overlay/` | ADAPTER — this organisation's, private | hosts and inventory, deploy parameters, secret-store paths, its own dashboards, probes and alerts, the module lint's denylist |
| `tests/` `.gitea/` | the repository's gates | secret-scan proof, checkout-path lint, module lint; the CI workflow |

The same CORE → ADAPTER → LOCAL shape as a governance render: the module declares inputs, the overlay
binds them, and nothing under `module/` names the overlay or the organisation (the module lint fails
the build if it does). **Publishing later = publish `module/`, relocate `overlay/`** to a private
repository.

## Hosts it runs on

| host role | environment | deployed by |
|---|---|---|
| <host role> | <staging · production> | the pull deployer — see *How to deploy* |

The hosts themselves are inventory, and live in `overlay/`.

## Contracts

Every core service this module consumes and every runtime edge it shares with another repository.
Splitting repositories does not split the runtime fabric: this section is the only place that coupling
stays visible, so a change to any of it changes this section in the same commit. **Names and
parameters only** — never a value, never a secret; the organisation's values live in `overlay/`.

### Inputs

Core services are consumed through these parameters, never literals. The module must also start with
NONE of them set — a plain env file, no SSO — which `module/tests/empty-inputs.test.sh` proves.

| input | parameter | unset means |
|---|---|---|
| identity issuer URL | `OIDC_ISSUER_URL` | local accounts, no SSO |
| secret-store address | `SECRET_STORE_ADDR` | secrets come from the plain env file |
| secret-store path prefix | `SECRET_STORE_PREFIX` | nothing is read from a store |
| edge network name | `EDGE_NETWORK` | a private network of the module's own, no edge routing |
| message bus URL (optional) | `BUS_URL` | no events are published |

### Edges

- **network joined:** the one named by `EDGE_NETWORK` — external; owned by `<owning-repo>`
- **hostname resolved:** `<hostname>` — a container owned by `<owning-repo>`
- **port exposed:** `<port>/tcp` on `<service>` — consumed by `<consuming-repo>`
- **secret-store prefix read:** the one named by `SECRET_STORE_PREFIX` — the prefix only; values stay
  in the store

## How to deploy

1. **Parameters are data.** The deploy parameters — repo slug, watch path, target dir, state file,
   unit name — live in the overlay's deploy vars under `overlay/deploy/` (start from the example file
   there). Never rely on a shared role's defaults: they name some other repository.
2. **CI is green on the default branch.** The pull deployer is status-gated and reads "no status" as
   "not green", so a commit the gate never reported on is never deployed. A fresh repository reports
   NOT CHECKED until `overlay/lint-denylist.txt` exists — copy the example there and list this
   organisation's terms.
3. **Merge to the default branch.** The deployer on each host picks the change up by itself; nobody
   deploys by hand. Operator scripts for everything else live in `module/scripts/`, each with the
   standard header (see `module/scripts/README.md`).
