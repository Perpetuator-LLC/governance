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

## A published claim is a dependency of the code that makes it true

**A product's published claims (its privacy policy, its terms, what it says it collects, keeps or
shares, which third parties it uses) are true because of specific code and configuration.** A change
to that code can make a claim false while every test still passes, and the person writing the change
is rarely the person who owns the claim. So the dependency is declared where the code lives:

- **The repository declares its sensitive surfaces.** For each: the paths, the change patterns (a new
  data field, a new third-party script or processor, a new outbound destination, a retention setting),
  the claim it supports, and where that claim is tracked.
- **A change that touches a surface gets a comment on its pull request**, naming each claim to re-read
  and linking where it is tracked. The author updates the claim, or says on the pull request why it
  still holds. `bin/claim-check` does this from the pull request's diff against its base; wire it as a
  pull-request step that posts the comment through the forge's API with the job's own token, and
  vendor the script at a pinned commit rather than fetching it at run time.
- **It flags; it blocks only by the claim owner's decision.** A blocking check that raises false
  alarms gets switched off. Start with flags only, measure them, and block only a short named list once
  the flags have proved accurate.
- **"Could not evaluate" is reported, never passed.** A missing declaration, an unreadable diff, or a
  binary file in a checked path says so in the same comment.

**Scope: claims made to people outside the team (users, customers, regulators) that code can
falsify.** **Where it is wrong:** a claim no code touches (an address, a support promise) needs a
calendar review, not a diff check. **The mirror:** a REMOVED line falsifies a claim as surely as an
added one (a deleted retention limit or consent check), so a surface declares both directions. **The
claims, their wording and the register belong to whoever owns them**, not to the code repository: the
check needs only the paths, the patterns and a link.

## A product that lets an agent act on a user's behalf publishes what that agent may and may not do

**Once a product exposes a standardised interface (MCP or its equivalent) that lets a user connect a
third-party AI agent to act on their account, the ordinary Terms/Privacy pair stops being enough.**
Those documents assume the user is the only actor; the day a granted connection can take actions too,
"the user agreed to this" is only true for what they specifically granted — and only if the policy
states the boundary somewhere the user (and a platform reviewing the connector for its own directory)
can actually read it.

**The policy, published where it's reachable without signing in, names four things:**
- **The scope model** — that access is granted per connection, not all-or-nothing, and each scope
  covers one specific capability.
- **A fixed deny list** — actions no connection may ever perform, regardless of what scope it holds.
  The strongest candidates are the irreversible or other-party-affecting ones: moving money, deleting
  the account, changing the user's own consent/privacy settings, reaching a *different* user's data,
  changing sign-in/recovery credentials, or widening another connection's own grant. A capability that
  doesn't exist yet (trading, in the exhibit below) still gets a *standing* entry, so it lands on the
  list automatically the day someone builds it, not after a review nobody scheduled.
- **Logging and attribution** — every action a connection takes is recorded under that connection's
  own identity, separately from the user's own actions, and the record outlives a revocation by a
  bounded window (the same shape as *Rotation is a routine, not a ceremony* in `security.md`, applied
  to a grant instead of a credential: revoking ends the *access*, not the *history of what it once
  had*).
- **Where a user reviews and revokes it** — and, if the product is itself requesting a directory
  listing, a statement of this policy's URL as a submission artifact in its own right, not folded
  silently into the general privacy policy.

**Scope:** applies when *third-party* software can act through a standardised, user-grantable
interface. A product's own first-party automation (background jobs, scheduled tasks the user never
individually grants) isn't this — there's no connection to scope, deny, or revoke.

**Neighbouring case where this would be wrong, or at least lighter:** a *read-only* interface (a
reporting integration that only ever reads) carries much lower stakes than one with write capability
— the deny list matters most where a write exists at all. A read-only policy can be lighter on the
deny list, but still needs the data-sharing disclosure below; dropping the whole policy because "it
only reads" is the over-generalisation to watch for.

**Mirror, and the one most likely to be skipped:** a deny list that covers every *write* says nothing
about *reads* — data a connection is scoped to read still leaves the product's own boundary, to
whatever external AI platform the user connected. That's a different axis (confidentiality, not
authority/integrity) and needs its own disclosure: data a connection reads is sent to and processed by
the platform the user chose to connect, which has its own practices the product doesn't control and
the policy doesn't cover. Clearing the deny list and skipping this is solving half the problem while
reading as having solved all of it.

**Exhibit** (measured, a consumer financial product adding an MCP-style connector): the worked policy
covered — a per-connection, per-scope consent screen naming the tenant boundary explicitly (not just
"full access"); a deny list (payment/checkout, account deletion, consent/privacy changes, cross-user
data export, auth/recovery-credential changes, modifying *another* connection's own grant, and a
standing entry denying automated trade execution pending the product's own investment-adviser
registration question, filed before any brokerage integration existed to deny); grant and usage logs
attributed to the connection, retained past revocation for a bounded audit window; and, for a
write-capable scope specifically (portfolio positions), a disclosure that the risk there is data
integrity, not money movement — no brokerage link exists, so the exposure is a corrupted record
feeding the product's own downstream analysis, not a real trade. The directory-listing half of the
same exhibit: a third-party MCP connector directory requiring a public privacy-policy URL found the
existing policy lacked exactly the four items above, because it predated the connector entirely —
confirming the scope note: this isn't a document you retrofit from the general privacy policy, it's
one the agent-connection feature creates a dependency on the day it ships.
