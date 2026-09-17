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

## Defining an initiative

- Start from a **SMART goal as a checkbox list** (Specific/Measurable/Achievable/Relevant/
  Time-bound) — not *ready* until every box is checkable.
- **Meeting kinds drive outputs:** architecture → initiative/epics; planning → tickets;
  implementation → requirements/ADRs (*how to build*); **balance** → a verification checklist mapped
  1:1 to the SMART goal (*how to verify*). Pair an implementation meeting with a balance meeting.
- **Requirements are the source of truth for scope** and live in the initiative repo, versioned
  alongside what they define (`core/AGENTS.md` → *Artifact placement*).
