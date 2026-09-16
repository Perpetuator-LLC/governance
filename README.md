# governance

A generic core for AI-assisted work that improves itself: the rules an agent follows, the mechanism
that layers an organisation's own rules on top, and the checks that keep both honest.

**Status: pre-release.** The layering mechanism and its gates come first; the rules themselves are
being extracted from a working system and generalised section by section. **No license has been
chosen yet** — until a `LICENSE` file exists, nothing here may be redistributed.

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
| `bin/` | render, check, and the repository's own gates |

## Checks

| check | proves |
|---|---|
| `bin/redaction-check` | no private identifiers reach this repository: home-directory paths, contact addresses, registration ids, internal ticket references, vendor tool names — plus, where you supply one, your own list of instance names |
| `bin/heading-pointer-check` | every pointer from one doc to a section of another still names text that exists |
| `bin/governance check` | a rendered instruction file still matches the layers it was built from |

Each check is tested against a known-good and a known-bad input in the same pass (`tests/`), and CI
runs every suite plus the first two checks against this tree.

## Starting an adapter

Copy `adapter-template/` to wherever your organisation keeps its rules, then render the layers into
the file your harness reads:

    bin/governance render --adapter <adapter-dir> --out <instruction-file>

Run `bin/governance check` with the same arguments to detect drift.
