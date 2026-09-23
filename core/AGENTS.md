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
Proposing it is part of the work, not a favour: a lesson landed in CORE is paid for once and reaches
every installation on its next update, and this one receives everyone else's the same way. When a
session produces such a lesson, draft the upstream change and offer it to your human.

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

### A rule carries its SCOPE, because generalising is what removes it

**State the conditions under which the rule applies, in the rule.** An unscoped rule is not a
slightly loose rule; it is a different rule, and it will be applied to the situations its author
never saw.

⚠️ **This is the one authoring error that review does not catch, because every sentence in it is
true.** A wrong claim is contradicted by the world. **An over-broad rule is obeyed** — quietly, by
readers who never encounter the case that would have shown them the boundary. Its failure looks
exactly like compliance. A wrong command, by comparison, fails loudly and once.

**The act of contributing is what destroys the scope.** The exhibit is the situation: it says what
was true when the lesson was learned, and a reader of the exhibit can see for themselves where it
stops. Strip the exhibit — as this repository requires — and that boundary leaves with it, **unless
it was written into the rule**. So the generalisation must carry its limits explicitly, precisely
because the context that would have implied them is the part being removed.

**The test, before it goes upstream: name a NEIGHBOURING situation where following this rule would
be wrong.** If you find one, its boundary belongs in the text. If you cannot, either the rule is
genuinely unconditional — rare, and worth saying so — or you have not looked hard enough, which is
the usual answer.

**Exhibit** (kept here because it is about this document's own process): a rule landed reading *find
a natural instance rather than constructing one*. True, and the reason is sound — a constructed case
tells you about your construction. But stated without scope it **forbids building a positive
control**, which this same core requires a few paragraphs away. Two sentences, each true,
contradicting one another, because one omitted the conditions it was about. The correction is a
clause, not a rewrite: *hunt to discover, construct to calibrate.* It was caught by a peer who tried
to apply both.

## Precedence of guidance — the layered merge

The layers above decide which *file* wins. When work is done for someone else — a client, a partner,
another organisation — a second question arises: whose way of working wins. Resolve it top-down;
**higher wins**:

1. **The human's explicit in-session instruction.** Always wins.
2. **Client / engagement governance** — for *that client's deliverables*: how they want THEIR
   product produced (their conventions, definitions, protocols). Declared per engagement (see
   *Engagement layering*). **Wins on the shape of their deliverable.**
3. **Your role governance** (the domain docs) — *how you work*: craft, security posture, process.
   **Always applies and fills any gap** the client didn't specify.
4. **Core operating rules** (the G-rules below) — the universal baseline.

**On client work it is a MERGE, not a switch:** your craft + their product-shape. For the
*deliverable's shape and conventions*, the client wins; for *your professional conduct, security, and
safety*, you hold your standard regardless. **Flag genuine conflicts** — never silently choose between
a client's way and yours; surface it.

### Engagement layering (how a client's governance attaches)

Each engagement declares its client-governance overlay in its own instruction file (a pointer to the
client's governance documents). Inside that engagement's repo or folder, layer the client overlay on
top of your role governance per the precedence above. **Internal work has no client overlay** — your
own governance is the whole stack.

**The artifact taxonomy is part of the governance overlay — it does NOT travel.** Your spine types
(Theme · OKR · KPI · North Star · Initiative · Capability) and their passport frontmatter are
internal; instantiating them in a client repo or vault is a G8 bleed even when every fact inside is
the client's. A dispatch is not a governance vetting, and one engagement's acronym is another's
product name.

## Core operating rules (the G-rules)

- **G1 — Single source of truth, latest-wins.** Each fact has one authoritative home; a
  current-status field reflects the *most-recent* truth and is never regressed by older information.
  Compare the *event date*, not when you processed it.
- **G2 — History is append-only.** Never rewrite immutable records (event logs, journals,
  decisions). Correct by appending a dated update.
- **G3 — Markdown + frontmatter, everywhere.** Every document is portable Markdown with YAML
  frontmatter and `[[wiki-links]]`. Never trap content in a format it can't be exported from.
- **G4 — Draft → review → published.** Nothing an agent authors is authoritative until a human
  publishes it (a `status` gate). Stage high-risk changes for review rather than applying silently.
- **G5 — Every decision is recorded and owned.** A decision gets a stable ID, an owner, a date, and
  its rationale. Link it from where it's enacted up to the strategy it serves.
- **G6 — Every artifact has one home and one owner.** File each in the correct layer (placement
  policy below). Cross-link; never duplicate.
- **G7 — Attribute and make reversible every agent write.** Log who/when/what (human vs. agent).
  Mass edits, moves, deletions must be staged or trivially undoable.
- **G8 — Respect boundaries.** Keep engagement/client/tenant data separated. Never leak secrets,
  tokens, or one client's context into another's surface.
- **G9 — Trace upward and downward.** Work traces up to the requirement/initiative/strategy it
  serves, and down to the evidence that proves it done.
- **G10 — Capture knowledge back.** Reusable procedure or insight boils up into the knowledge layer
  (SOPs / Knowledge Base) so it's never re-derived.
- **G11 — Passport & route-before-create.** Every document carries a frontmatter **passport** whose
  `type` fixes its one canonical home and mutability. Before creating, **route**: find the existing
  canon and update it; a parallel file is the exception and must be justified. Rich canons, thin
  pointers.

## Artifact placement (where each artifact lives)

Work follows one **strategy-to-execution spine**; each layer has a home (roles, not products — map
them to concrete tools in each repo's config):

| Layer | Artifacts | Home |
|---|---|---|
| **Strategy & measurement** | Theme · Objective · Key Result · KPI · Snapshot | **Knowledge vault** (durable, cross-initiative) |
| **Definition & scope** | Initiative · Requirement Package · Requirement · Capability | **Initiative repo** |
| **Build & ship** | Work Item · Release | **Code repo** (the forge's issues + releases) |
| **Cross-cutting** | Decision/ADR · RAID · Responsibility · Evidence | recorded closest to where enacted, linked upward |
| **Registry & knowledge** | Instances · Knowledge Base (rules, protocols, learnings, contributors) | **Knowledge vault** |

**Placement binds AUTHORING and REFERENCING alike:** a doc goes to its canonical home at birth, and a
hand-off that records a path is a routing act — verify the home before propagating it
(`domains/operations.md` → *Placement binds authoring and referencing*).

**Cross-cutting records:** ADRs/Decisions, RAID/Risks, and Evidence/Learnings are **repo-specific**
(they live in the owning repo's docs); RACI/Accountability, Objects
(Instances/People/Organizations/Definitions/Meetings), and Governance
(Rules/Protocols/Best-Practices/SOPs) live in the **knowledge vault as documents**.

**A document that spans initiatives has no initiative repo to live in.** Architecture that explains
how several repos compose into one system, a roadmap across them, an analysis that chooses between
them: none belongs to any single repo, and filing it in the most-related one hides it from the others
and lets it rot there. It belongs in the **knowledge vault, attached under the Strategy Theme it
serves and expressed as Objectives, Key Results or KPIs.** That layer is what *infers* the
initiatives (each one a repo), so a cross-initiative claim is either a strategy statement or a
measure of one. Everything that defines a single initiative (its Capabilities, Requirements
Documents, Requirement Packages, ADRs) lives in that initiative's repo. Routing test: *would a
second repo need this document to make sense?* Yes → knowledge vault, under a Theme. No → the one
repo.

**Before a product's documents move into its repo, extract the rules that bind every project.** A
design doc written for one product often carries a lesson all future work needs: an accessibility
bar, a data-handling constraint, a review practice. Moving the doc wholesale buries that lesson in the
one repo the next project will never open. Split first: the generic rule → governance; the
organisation-specific rule → the knowledge vault; only the product-specific remainder → the product
repo.

A project-management tool MAY *mirror* the spine for tracking, but the **authoritative source** for
each artifact is its home above — the mirror is a convenience, not the record.
