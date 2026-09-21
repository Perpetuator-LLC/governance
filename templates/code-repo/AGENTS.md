# {{name}} — agent instructions

**This file is canonical for every AI agent in this repository, whatever harness you are.**
`CLAUDE.md`, `.github/copilot-instructions.md`, `.cursor/rules/` and `.continue/rules/` are
POINTERS to it. They are pointers deliberately: a second full copy drifts from the first within a
month, and nothing detects the drift because both files look maintained.

> **Governance.** This repository inherits the core governance and role-domain documents rendered
> into the agent home directory (`AGENTS.md`/`CLAUDE.md` plus `governance/<domain>.md`). Consult the
> matching domain doc **before** substantive work in it. On client work, layer the client's
> governance per the precedence ladder: human instruction > client deliverable-shape > role
> governance > core.

## What this repository is

<!-- One paragraph. What it produces, who consumes it, what breaks without it. -->

## Orientation, in reading order

| Read | For |
|---|---|
| `README.md` | the feature index — what lives here and which file is its manual |
| `AGENTS.md` (this file) | conventions, tripwires, the decisions that are closed |
| `docs/decisions/` | ADRs — why the repo is shaped the way it is |

## Lane and flow

- **Lane:** `{{name}}`. One agent seat owns changes here; anyone else proposes through their own
  branch and a pull request — never in the owner's checkout.
- **Feature branch → this lane's integration branch → ONE open pull request → the default branch.**
  Never push the default branch directly. **Read the integration branch** (`git ls-remote --heads
  origin 'merge/*'`); never compute its name.
- **Stage explicit pathspecs.** Never `git add -A`, `git add .` or `git commit -a`.
- **Commit → push in the same turn.** Unpushed commits are invisible to every other seat.
- Every agent commit carries its attribution trailers.

## Tripwires

<!-- Things that bite BEFORE you would know to look them up. Delete the examples; keep the shape.
     Each line: the trap, then the consequence. A tripwire with no consequence is a preference. -->

- 🔴 *(example — replace)* A config label in this repo is inert on the production host; routing is
  static. Adding one and assuming it routes ships an unreachable service that looks deployed.

## Do not reopen

<!-- Decisions already made, with their ADR or decision id. An agent that relitigates these is
     spending tokens to arrive where the repo already is. -->

## Secrets

Never read, display, or write a secret — not into code, not into a commit, not into a log, not into
a hand-off block. Code reports **presence**, never a value or a fragment. Secrets come from the
secret store by path; a path is safe to name, a value never is.

## Hand-off

The first agent seat to work this lane writes `docs/handoff/HANDOFF-{{name}}-worker-continuation.md`
— the repo-local pointer a fresh seat reads first. It records the topology no one can infer:
integration branch, open pull request, foreign uncommitted edits, and the landmines already paid for.
