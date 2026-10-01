# Product

How products are defined and traced from strategy down to shipped work.

For a client's product, their requirements and definitions win on *their* product's shape; your
definition discipline and traceability always apply (`core/AGENTS.md` → *Precedence of guidance*).

## The strategy-to-execution spine

Every unit of work traces up and down (G9):
**Theme → Objective → Key Result → Initiative → Requirement Package → Requirement → Capability →
Work Item → Release**, measured by **KPI → Snapshot**, wrapped by **Decisions · RAID ·
Responsibility · Evidence**. Architecture (*when/where*) → Planning (*what/who*) → Implementation
(*how*); each layer traces to the one above.

## Prioritise packages, not work items

**A Requirement Package is the set of Requirements that share a subsystem or a dependency chain, and
so ship together. A release is a set of packages.** Priority is assigned to the package and inherited
by its work items, and each package has one owner and one verification walk. Ranking individual work
items makes a release a bag of unrelated items, where *"ships together"* and *"worth doing next"*
cannot both be stated; the package is the grain where both are true. A package with one work item is
still a package, and a work item in no package is a planning gap. **Scope:** trackers holding far more
work items than a person can rank (roughly fifty or more open) and releases cut on a cadence. A small
single-owner repository does not need the layer.

## Defining an initiative

- Start from a **SMART goal as a checkbox list** (Specific/Measurable/Achievable/Relevant/
  Time-bound) — not *ready* until every box is checkable.
- **Meeting kinds drive outputs:** architecture → initiative/epics; planning → tickets;
  implementation → requirements/ADRs (*how to build*); **balance** → a verification checklist mapped
  1:1 to the SMART goal (*how to verify*). Pair an implementation meeting with a balance meeting.
- **Requirements are the source of truth for scope** and live in the initiative repo, versioned
  alongside what they define (`core/AGENTS.md` → *Artifact placement*).

## Sequencing: order by dependency, then by leverage

**Order work by hard dependency first, then by which work makes the rest cheaper, then everything
else.** An initiative that lowers the cost of every other one is a multiplier: work scheduled before it
pays full price. It loses every urgency contest, so by default it is scheduled late and taxes everything
that runs ahead of it. A hard external deadline is the routine exception. **Where it is wrong:** when
the lever's payoff is uncertain or slow to build, putting deadline work behind it costs more than it
saves.
