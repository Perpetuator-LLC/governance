# governance

A generic core for AI-assisted work that improves itself: the rules an agent follows, the mechanism
that layers an organisation's own rules on top, and the checks that keep both honest.

**Status: pre-release.** The layering mechanism and its gates come first; the rules themselves are
being extracted from a working system and generalised section by section. Licensed under the MIT
License — see `LICENSE`.

## Use it, build on it, give back

**Use it directly.** Install this repository as it is and pin it. Put everything your organisation
needs in your own adapter layer (below). Staying on the shared core, rather than a copy you edit, is
what keeps improvements arriving. Every rule, gate and fix that anyone lands here reaches you on your
next update.

**Borrow freely.** The ideas are yours to take into your own systems and to build new ones from:
layered rules, instruction files rendered rather than linked, safety as gates rather than prose, a
rule kept apart from the incident behind it, and redaction checked by shape. The license is MIT.

**Give a little back.** When your agents learn a lesson that would hold for anyone, send it upstream.
A commit or two every now and then is plenty. So is an extension: a new domain, a gate, support for
another harness, a template. See `CONTRIBUTING.md`.

**Why it compounds.** Every team running AI agents pays, in incidents and tokens, to find the same
failures. Alone, each team pays for every lesson itself. On a shared core, a lesson is paid for once
and reaches everyone. Your contributions help every other team, and theirs help you. That pooled
effort is far larger than any single team's rules could be.

## How it fits together

Four layers. They are read in order, and the later layer wins — except the floor:

| layer | what | edited by | lives |
|---|---|---|---|
| **CORE** | this repository | upstream pull requests only | a pinned clone |
| **ADAPTER** | your organisation's rules, vocabulary, tooling and evidence | you and your agents, freely | any directory you choose; git optional |
| **LOCAL** | one machine or one person | you and your agents | `*.local.md`, never committed |
| **FLOOR** | safety gates no layer can relax | CORE | harness hooks and deny rules, not prose |

The model in full — precedence, why instruction files are rendered rather than linked, and how a
lesson travels upstream — is `core/AGENTS.md` → *Layers*.

## What is here

| path | what |
|---|---|
| `core/AGENTS.md` | the layer model and how the pieces fit |
| `core/domains/` | rules, one domain per file, as they are generalised |
| `hooks/` | the floor: pre-tool gates that refuse destructive and secret-exposing calls, plus audit and lint hooks |
| `agents/` | reusable sub-agent definitions (review, exploration, investigation) |
| `bin/` | render, check, scaffold, and the repository's own gates |
| `templates/` | starting layouts for new repositories — `code-repo/` is any repository that holds source (agent instruction files, secret gate, ADR-0001); `stack-repo/` is a deployable stack: a generic `module/`, a private `overlay/`, its CI gate, contracts and lints |

## Checks

| check | proves |
|---|---|
| `bin/redaction-check` | no private identifiers reach this repository: home-directory paths, contact addresses, registration ids, internal ticket references, vendor tool names — plus, where you supply one, your own list of instance names |
| `bin/heading-pointer-check` | every pointer from one doc to a section of another still names text that exists |
| `bin/governance check` | a rendered instruction file still matches the layers it was built from |

Each check is tested against a known-good and a known-bad input in the same pass (`tests/`), and CI
runs every suite plus the first two checks against this tree.

## Starting a new repo

```bash
bin/governance scaffold --template code-repo  --out <dir> [--name <n>]   # a repository that holds source
bin/governance scaffold --template stack-repo --out <dir> [--name <n>]   # a deployable stack
```

Scaffold creates every **missing** file of the layout, never overwrites one, and is a noop on a
repository already in shape — so it is safe to re-run on an existing repository to pick up what a
later version of the template added. `--dry-run` reports without writing; `--name` defaults to the
output directory's name and is substituted into `README.md` and `AGENTS.md`.

**`code-repo`** answers *"what do I put in a new repository so every agent harness behaves?"*
**One file is canonical — `AGENTS.md`** — and `CLAUDE.md`, `.github/copilot-instructions.md`,
`.cursor/rules/` and `.continue/rules/` are pointers to it. That shape is the point, not tidiness: a
second full copy of the conventions drifts from the first within a month and **both files go on
looking maintained**, so the next agent obeys whichever one it happened to read. The template also
ships the secret gate in **both** its layers — the pre-commit hook that catches a secret before it
enters history, and the CI gate that catches what was pushed anyway (a bypassed hook, a hook nobody
installed, a commit from another machine). Shipping only the first would leave a defence-in-depth
story with a hole where its second layer belongs. The CI installer takes the scanner from the
vendor's own release, pinned by version and verified against both the vendor's checksums file and a
digest pinned in the workflow. Also `ADR-0001`, which establishes that decisions are recorded rather
than remembered.

A harness discovers these files by its own convention — each reads the file named for it, and a
session-start hook may additionally probe for the others and list what it found. That is why the
pointers exist at all: a harness that reads only `.cursor/rules/` must still be told where the real
instructions are.

**`stack-repo`** is for a deployable stack; the rules it serves are `technical.md` → *A deployable
repo stands alone — the stack-repo properties*.

## Starting an adapter

An adapter lives **inside your organisation's knowledge vault**, at `<vault>/.governance/` — hidden
from the vault's UI, tracked by the vault's git. Copy `adapter-template/` there. Any other vault
(personal, per-client) is a *member*: it carries a `GOVERNANCE.md` pointer to the adapter and nothing
else.

Then let this repository find your vaults and record what this machine's setup should be, and bring
everything into that state:

    bin/governance discover --root <dir holding your vaults> --home "$HOME" --write
    bin/governance reconcile --home "$HOME"

`discover --write` writes a machine-local manifest (`~/.governance/manifest.json`, never committed):
the core clone, the harness homes present (`.claude`, `.codex`, `.grok`), the one adapter vault and
every member vault. `reconcile` reads it and ensures, item by item — the adapter's shape, the rendered
harness homes, each vault's `GOVERNANCE.md` (managed frontmatter keys and a marker block; everything
else in the file is yours) and its `CLAUDE.md` import line, then drift — reporting each as `ok`,
`fixed` or `refused`. **It is safe to run at any time and is a noop when everything is in state**: no
backup, no rewrite. `--dry-run` shows what would change. `install … --write-manifest` seeds the same
manifest from an explicit install, so later runs need no arguments.

To render one file by hand instead:

    bin/governance render --adapter <adapter-dir> --out <instruction-file>

Run `bin/governance check` with the same arguments to detect drift.
