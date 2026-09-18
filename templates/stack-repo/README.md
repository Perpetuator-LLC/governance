# {{name}}

<!-- Scaffolded from the governance stack-repo template. Replace every <placeholder>; keep the four
headings — reviewers and tooling look for them by name. -->

## What it is

<One paragraph: what this stack runs, and who or what depends on it.>

## Hosts it runs on

| host role | environment | deployed by |
|---|---|---|
| <host role> | <staging · production> | the pull deployer — see *How to deploy* |

## Contracts

One line per runtime edge this repository shares with another one. Splitting repositories does not
split the runtime fabric: this list is the only place that coupling stays visible, so a change to any
edge changes this section in the same commit. **Names only** — never a value, never a secret.

- **network joined:** `<network-name>` — external; owned by `<owning-repo>`
- **hostname resolved:** `<hostname>` — a container owned by `<owning-repo>`
- **port exposed:** `<port>/tcp` on `<service>` — consumed by `<consuming-repo>`
- **secret-store prefix read:** `<store-path-prefix>/` — the prefix only; values stay in the store

## How to deploy

1. **Parameters are data.** The deploy parameters — repo slug, watch path, target dir, state file,
   unit name — live in this repository's deploy vars under `deploy/` (start from the example file
   there). Never rely on a shared role's defaults: they name some other repository.
2. **CI is green on the default branch.** The pull deployer is status-gated and reads "no status" as
   "not green", so a commit the gate never reported on is never deployed.
3. **Merge to the default branch.** The deployer on each host picks the change up by itself; nobody
   deploys by hand. Operator scripts for everything else live in `scripts/`, each with the standard
   header (see `scripts/README.md`).
