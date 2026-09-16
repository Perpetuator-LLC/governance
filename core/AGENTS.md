# Core

The part every installation shares. It carries the mechanism — layers, precedence, rendering, the
floor, the path upstream — and, as they are generalised, the rules themselves.

## Layers

| layer | purpose | edited by |
|---|---|---|
| CORE | rules and mechanism that hold for anyone | upstream only |
| ADAPTER | an organisation's own rules, vocabulary, tooling, and the evidence behind its rules | the organisation and its agents |
| LOCAL | one machine or one person | that person and their agents; never committed |
| FLOOR | safety gates | CORE — enforced by the harness, not by text |

**CORE is a pinned dependency, never a template.** Nobody edits these files in place. A template is a
fork from its first day: every file both sides change conflicts on every update, and improvements stop
arriving. Everything an organisation needs to change belongs in its ADAPTER — which is why the adapter
has to be generous enough that nobody is tempted to edit CORE.

**Self-improvement writes to ADAPTER and LOCAL.** An agent that learns something records it there,
freely. A lesson that would hold for anyone is proposed upstream (*Contributing a rule upstream*).

## Precedence

Layers are read CORE → ADAPTER → LOCAL, and **on conflict the later layer wins**: harnesses
concatenate instruction files, and the later, more specific text is what a model follows. Two
exceptions:

- **The floor is not text.** A rule that must hold whatever any layer says is a pre-tool hook or a deny
  rule in the harness settings. Prose can be argued with; a gate that refuses the tool call cannot.
  The gates live in `hooks/`; each is proven to refuse a known-bad call and allow a known-good one,
  on the input channel the harness actually uses, and to say *why* it refused on the channel the
  harness returns to the model.
- **A human's instruction in the session outranks every file.**

## Rendering

**Instruction files are rendered, not linked.** `bin/governance render` concatenates the layers into a
real file at the path each harness reads. Symlinked instruction files and imports that resolve outside
the working directory are skipped by some harness surfaces, and they fail silently: the session runs
without the rules and nothing reports it. A rendered file loads everywhere. Its failure mode is
staleness, which `bin/governance check` detects by comparing the file with the layers it was built
from.

## Contributing a rule upstream

A lesson is recorded in two parts: the **rule**, stated so a stranger at another organisation could
apply it, and the **exhibit** — the incident, the names, the numbers — that gives it force. **Only the
rule travels upstream.** The exhibit stays in the adapter, which may link to CORE; CORE never links
back. A rule that reads as a platitude once its exhibit is removed was an anecdote, and it stays in the
adapter.

`bin/redaction-check` runs on every change. It matches identifier *shapes*, never literal names — a
checker that contained the private names it hunts for would itself be the disclosure. Literal names
live in a private list you pass in, and without that list the check reports the name leg as **not
checked**, never as clean.
