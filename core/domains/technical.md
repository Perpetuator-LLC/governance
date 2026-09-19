# Technical

How things are built: toolchain, infrastructure as code, deploys, testing, and the checks that prove work done.

A repo's own instruction file wins on repo-local specifics; on client work the client's technical
conventions win on *their deliverable's shape* (`core/AGENTS.md` → *Precedence of guidance*).

## Toolchain — use what exists, never reinvent

Every repo pins its language/dependency tooling; **always use what's there**. Never global-install,
never bare `pip`, never ad-hoc venvs outside the established toolchain.

| Language | Version manager | Dependency manager | Pin file |
|---|---|---|---|
| Python | pyenv (`.python-version`) | **poetry** (`pyproject.toml`) | `poetry.lock` |
| Node | volta / nvm (`package.json`.volta / `.nvmrc`) | **npm** (`package.json`) | `package-lock.json` |

`cd` into a service → the pin auto-activates. Use `poetry install`/`poetry run`, `npm install`/
`npm run`. In monorepos, copy a sibling service's structure. **Prefer building minimal in-house over
adding a dependency**: stdlib-first, reuse already-trusted deps, pin versions.

## Simplest thing that works — last responsible moment

**The rule.** If a thing doesn't add value, and we aren't sure it will, **delay or avoid it until the
last responsible moment** — the point at which deferring the decision costs more than making it now.
This is not procrastination and not "never build it": it is deciding when you have the *most*
information, which is always later than when the idea first appears. The applied test is a single
question — ***what breaks if we add this later?*** If the honest answer is "nothing", defer; if it is
"a rewrite / a migration / a lost customer", that IS the last responsible moment, so build it now.

**Why, mechanically:** every line of code is a **liability, not an asset**. It has to be written once
and then tested, reviewed, kept green through every dependency and framework upgrade, read and
correctly understood by whoever touches it next, and supported in production for as long as it
lives. Speculative code pays that tax forever in exchange for a maybe. A new-code coverage gate
(e.g. 98% of new lines) makes the tax *immediate and visible* rather than deferred — that is a
feature, not friction: it prices speculation at the moment of writing.

**The cycle, applied per change: test fails → code passes → refactor to LESS code that still
passes.** The first two steps are ordinary TDD; the third is the one that gets skipped, and it is
where the liability above actually gets paid down. "Liability" tells you not to write speculative
code; it says nothing about the code that already exists. Making reduction the closing step of every
change turns cleanup from a periodic campaign — which never gets scheduled — into a habit with a
natural trigger.

**Target net-negative PRODUCTION code as features land, and report the split.** Tests growing while
production shrinks is the shape you want, and a single net figure hides exactly that:

```
production code   +33 / -67   = net -34      # the feature, smaller than before
specs             +59 /  -8   = net +51      # what made that reduction safe
```

A new-code coverage gate is what makes this safe rather than reckless: it is the **licence to
delete**, not a tax on writing. A team without one cannot refactor confidently, so its code only
ever grows.

**Order is not ceremony.** Writing the failing test first makes it reproduce the defect *before* a
fix exists, which is the only moment you can prove the test would have caught it. It also pays a
second dividend: *tightening* a passing assertion often exposes a further defect the loose one
passed over — so when a test goes green easily, sharpen it once before believing it.

**A shared component's SHOWCASE must carry every STATE, not just every component.** A variant's
state that exists in code and on no page is one nobody inspects until a customer does — the
absence-as-health class (a missing signal read as a healthy one) pointed at a design vocabulary. When
you add a variant, add its states to the page that exists to be looked at.

**Direction of travel — reduction is a deliverable.** Deleting code, dead branches, unused config,
stale tickets, and options nobody chose is real progress and gets reported as such. Between two
working designs, the smaller diff wins. A change that *removes* more than it adds is usually the
better change. Before adding an abstraction, ask whether deleting the thing that seemed to need it
is cheaper.

**When genuinely unsure, the answer is `don't` — and say why.** "Add it cheaply now and see" is how
untested, unowned surface area accumulates; the cheap add is never the expensive part, the decade of
support is. Surface the deferral explicitly (ticket it as a decision, not as work) so the option
stays visible without the code existing.

**Canon this rests on** (read these, don't re-derive them): **YAGNI** — implement when you actually
need it, never when you merely foresee needing it (Beck/XP). **KISS.** **Beck's four rules of simple
design**, in priority order: passes its tests → reveals intent → no duplication → fewest elements.
**Lean's last responsible moment** (Poppendieck) — keep options open while the cost of keeping them
open is lower than the cost of choosing wrong. **Gall's law** — a working complex system is always
found to have evolved from a working simple one.

**Exhibit:** a 124-commit shared-component migration merged with 29 untested new lines; the new-code
gate caught it at consolidation time and the cleanup cost a full session of spec-writing — the tax
landed on the consolidator, not the author. Same session: three feature branches carrying
492-commits-stale duplicates of already-merged work were deleted outright, which was the
highest-value change of the day and produced zero new code.

## AVAILABILITY is a selection column, not a footnote

**"Can we actually get this hardware on the day we need it?" ranks beside price and specs — a
citable price is not an offer.** A published SKU with committable pricing can be *region-dry*: the
name resolves, the calculator works, the quota looks fine, and there is still no capacity to hand
you. Measured: a GPU instance family was **dry across two regions (placement score 1/10)** while its
Savings-Plan pricing looked perfectly committable.

- **Know which instrument reserves CAPACITY and which only buys a DISCOUNT.** A **Savings Plan
  reserves nothing** — it is a spend commitment in exchange for a rate. The capacity-reserving
  instruments are a **Zonal Reserved Instance** or an **On-Demand Capacity Reservation**, and the
  standard shape is **Capacity Reservation + Savings Plan paired**: the reservation holds the
  hardware, the plan discounts it. Committing to a Savings Plan for capacity you cannot get is the
  worst of both — locked spend, no machine.
- **Check the availability signal BEFORE the price signal drives a decision**: placement scores /
  `describe-instance-type-offerings` per AZ / quota, in the exact regions and AZs you intend to use.
  Record what you measured and when; capacity is a moving target, so an availability check has a
  short shelf life and belongs beside the decision it justified.
- **Per-provider numbers age fast and belong beside the workload; the selection rule does not.** Keep
  the measured figures with the placement decision they justified, and the rule here.
- **Sibling of the catalog-identifier check** (search for a second, competing definition of a name
  before relying on it): that one says the NAME may be retired; this one says the name may be
  perfectly VALID and the hardware still unobtainable. Both fail the same way — a plan that looks
  committed on paper meets reality at apply time — so both want a **plan-time assertion against the
  live API**, not a value copied from a doc.

## IaC-first — production & infra changes

**Production state is only touched through committed, testable, environment-loaded surfaces — never
ad-hoc SQL/shell typed on a box or handed over.** Every read or write against a prod/infra system
goes through, in order: (1) the app's own **committed command surface** (management command, CLI
subcommand, rake task) run under the standard runtime env-injection (the secret store's
exec-injector) so secrets load normally; (2) a **committed script/playbook** (ansible/tofu/repo
`scripts/`), reviewed, versioned, re-runnable; (3) only for genuine one-time break-glass, a hand-over
block — and then the SECOND occurrence gets scripted and the first gets an issue to backfill the
command surface. Schema/data changes belong in migrations. Handing the human an ad-hoc mutation of a
live host (inline `python`/`sed` heredocs against live files, `docker` CLI state changes, console
clicks, hand-edited on-box configs) is a VIOLATION even when it "works" and even for a one-off — it
creates drift the IaC can't see and a step no audit can replay. If the IaC doesn't exist yet, WRITING
it (playbook/role/script, committed and merged) IS the task; then hand over its one-line invocation.
**Litmus:** if the recipe contains inline SQL or a `python -c` against a prod service, stop and write
the command/script instead. Verification counts as interaction — "check how many rows are expired" is
a management command, not a paste-block of SQL. Ad-hoc commands are for read-only diagnosis only.

## A done-when names the COMMITTED SURFACE that takes its receipt

**IaC-first's constructive half.** IaC-first says *don't verify by hand-poking prod*. Stated alone,
that closes the only escape hatch a team had and leaves it with **no legal way to take its own
receipt** — so this says: when you plan the work, make sure something committed can do the verifying.

**The rule.** When you write a ticket's done-when, **name the command, endpoint, or artifact an agent
will run to prove it** — and if none exists, **building it is part of the ticket, not a follow-up.**

**The measured instance** (one release's receipt battery):

| Ticket | Receipt surface | Agent could take it? |
|---|---|---|
| 1 | a migrations-listing management command | ✅ |
| 2 | an analysis management command with `--json` output | ✅ |
| 3 | anonymous HTTP walk | ✅ |
| 4 | a schedule-firing management command | ✅ |
| **5** | **none** | ❌ |

Four of five were verifiable because a committed surface *happened* to exist. The fifth behaviour was
reachable only through the GraphQL schema, so taking its receipt needed either an authenticated
mutation against a live environment — barred by IaC-first *and* by handling a real user's token — or
a management command nobody had written.

The rule in one line:

> **A feature verifiable only by a logged-in human is a feature that will keep being verified by a
> logged-in human.**

> **And its operational twin: a surface reachable only by ssh is a surface that will keep being
> reached by ssh.**

⚠️ **THIS IS A SECOND-RUNG FAILURE, which is why it survives review.** Moving operational work into a
**committed, reviewed command** buys testability, review and auditability — and it buys **no
reachability at all**. A command that can only be invoked from a shell on the box has **MOVED** the
shell requirement, not removed it. Nothing looks wrong, because the first rule was followed correctly;
the gap only appears when someone forbidden to ssh discovers the surface is unreachable. A shop still
writing ad-hoc scripts never gets far enough to find it.

**So when writing or reviewing an operator command, ask: *who can invoke this, and from where?*** If
the answer is *"anyone with a shell on the host"*, the command is **half-built** — and note that the
remote path, being allowlisted and audited, is precisely the property plain shell access never gave
you. Measured cost: a diagnosis that took ~15 queries across logs, analytics, traces and git, when
one existing command would have answered it directly — its exact argument was known within two
minutes and could not be invoked.

Two corollaries from the same session, both about a reading taken from the wrong source:
- **A `/health` version is authoritative ONLY for the service that serves it.** A web host's health
  endpoint returned the FRONTEND's commit; reading backend code at that SHA would have produced a
  confident wrong answer. Get the deployed SHA from the service you are actually asking about.
- **Operational attribution must not route through the analytics pipeline.** If *"which user did this
  failure belong to"* is answerable only from an analytics event, it is unanswerable **exactly when
  analytics is down** — which is when you are debugging.

**The cost is not the one missed receipt.** It is that the fifth ticket shipped **complete-as-built
and unverified**, and every future change to that path inherits the gap — permanently, and invisibly,
because **four of five green receipts read as a verified battery**. That is the *success-shaped
failure* family: a done-when that cannot be executed is not a weaker check, it is an **absent** one,
and a ticket closed without it looks identical to one closed with it.

**Not framework-specific.** The same shape produces an FE feature reachable only through a logged-in
browser session, an infra change verifiable only by SSH-ing in and looking, a gateway capability
exercisable only with a human's token. Each ends the same way: **a human round-trip per verification,
forever.**

**The cheap fix is a dry-run-by-default smoke command committed alongside the feature.** The
expensive one is discovering the gap at release time, when the tool cannot be added without growing a
release-gating PR — which is precisely when it was discovered.

## Tofu/Terraform state is remote-or-nothing

**Never run a first `tofu apply` against a local state file in an ephemeral checkout.** Agent
worktrees, scratch dirs, and un-pushed clones get reaped; a `terraform.tfstate` that lived only
there is gone with them, and the real cloud resources it tracked become unmanaged orphans that can
then only be retired by hand (measured: a root's state was lost to worktree reaping, and its teardown
had to be done via console clicks + raw cloud CLI calls, exactly the ad-hoc surgery IaC-first bans).

- **Backend before first apply.** Declaring a remote backend (S3 + lockfile, or the org's standard)
  is part of scaffolding a new tofu root — the same commit that adds the first resource adds the
  `backend` block. `tofu init` against local state is acceptable ONLY for a plan-never-apply dry run.
- **State never lives in git either** — it carries secrets/IDs; the backend, not the repo, is its home.
- **The litmus at hand-over:** before handing the human any `tofu apply`, run `tofu init
  -backend=false -input=false` mentally against the config — if there is no `backend` block, adding
  one IS the task.
- **Recovery when state is already lost:** don't recreate — `tofu import` each live resource under a
  fresh backend-backed root, verified by a no-op plan; until imported, mutations to those resources
  are break-glass and must be logged in the owning plan doc.

## Tofu plan/apply split — agent plans, human applies the planfile

**The agent runs `tofu plan -out=<planfile>` itself — iterating until the plan is exactly right —
and the human's entire job is one command: `tofu apply <planfile>`.** Never hand over a block where
the human runs a bare `apply` (or worse, `plan && apply`) and is expected to eyeball the diff at the
prompt: the human is the *authorizer*, not the *reviewer of last resort*.

- **Why the planfile matters:** `apply <planfile>` executes the byte-exact change set the agent
  reviewed — tofu refuses the planfile if the state moved underneath it. This structurally prevents
  the stale-context apply (measured: an apply run from a checkout on an old branch destroyed a live
  IAM user and 409'd on two others; a planfile reviewed by the agent, with the human running only
  `apply`, makes that class impossible).
- **Plan is agent-runnable.** `tofu plan` is read-only against the cloud; ambient credentials
  (AWS_PROFILE, rendered credential files) get *used* by the provider, never read into context —
  a ban on secrets in agent context does not apply. Enabling a normally-disabled key (e.g. a
  bootstrap key) is the human's authorization step and comes first; from then on the agent plans,
  reviews, re-plans.
- **The agent REVIEWS the plan, not just runs it:** assert the expected counts and name them in the
  hand-over ("10 add / 0 change / 0 destroy — the 2 destroys you'd see are X, there are none").
  Any unexpected `destroy` stops the line, never ships in a planfile.
- **A plan with MORE changes than you authored is a FINDING — diagnose which side drifted before
  shipping.** Not just destroys: an unexpected **update that WIDENS access** is the dangerous shape,
  because it reads as routine. Mechanism: a decision supersedes an IaC statement, the code is never
  updated, and the next unrelated apply **silently re-applies the superseded grant**. Real case: a
  one-line change to an auditor role planned 3 updates; the third would have re-granted a prod-capable
  restore role read access to a personal write-once bucket — re-crossing a separation boundary the
  human had built 5 days earlier — because a prior agent had codified that statement while it still
  matched live. **Procedure:** (1) enumerate every non-`no-op` change and diff the before/after policy
  actions + Sids, not just the counts; (2) establish **which side is stale** — config-ahead-of-live
  and live-ahead-of-config need opposite fixes, and the tell is that correcting the stale side makes
  the change *vanish* from the plan; (3) when removing a superseded grant, leave a **do-NOT-re-add
  comment naming the supersession**, or the next agent re-codifies it from live drift; (4) any second
  effect that survives review gets **NAMED in the hand-over** so the human approves it knowingly
  rather than having it smuggled in under an unrelated headline.
- **Hand-over shape:** agent output = a committed/scripted plan step + the planfile path + the
  reviewed summary; human input = enable-key (if gated) → `tofu apply <planfile>` → disable-key.
  Wrap both sides in the repo's script (`plan.sh` / `deploy.sh`) when the root is used more than once.
- **The agent-run plan IS the ceremony pre-flight — it exercises the ENTIRE auth path, backend
  included.** `tofu init`+`plan` touch the state bucket AND the lock table before any provider call;
  a hand-over composed without the agent running them first ships untested auth. Measured: a
  bare-`apply` ceremony was handed to the human and died in their hands on an `AccessDenied` writing
  the state-lock table — an agent-run plan would have caught it privately. Compounding it, the
  backend config example named a profile whose backend permissions were never verified, while the
  repo's own backend example named a different one — **the backend profile is part of the auth path
  and gets the same satisfiable-on-target verification as an ssh/sudo prompt**. Note the state-lock
  is bookkeeping, not an infra action — but the human can't tell a lock-denial from a real one
  mid-ceremony, which is exactly why it must fail on the agent first.
- Composes with the two standards above: remote state makes the planfile trustworthy across
  checkouts; IaC-first makes the script the only mutation surface.

## Service topology: software/state split

Every service separates **software** (image/repo, rebuildable) from **state** (ONE named
docker volume: DB data via `PGDATA` subdir + dumps + anything needed for identical
resurrection). The **runnable unit** for DR is: image (or repo@ref) + state volume +
secret store + object storage (media) + edge/DNS — restore = provision box, restore
volume, `up` at the ref. Two hard rules paid for in a prod outage:

- **A stateful-path flip (PGDATA/volume/bind relocation) NEVER ships ahead of its data
  migration.** The migration is atomic with, or precedes, the compose change — otherwise a
  routine deploy silently boots the service on EMPTY storage while the real data sits in
  the abandoned path. Stage-first, and gate on data-present.
- **Image ↔ state is a compatibility contract**, not a pairing: restore is always
  *volume → migrate with this image → verify counts*, never "attach and up".

## Closed-vocabulary values are ENUMS at every boundary, and the INPUT boundary is the one that leaks

A value drawn from a fixed set (a scope, a tier, a status, a kind) is an enum in the database, an enum
type in the API schema **for arguments as well as fields**, and something the UI *iterates from the
schema* rather than re-declares. The typical half-done shape is: the storage column has choices, the
API declares an enum type for output, and then every mutation argument is typed as a free string with
a comment listing the legal values. That shape passes review because "the enum exists" — and it is the
defect, because the boundary that admits data is the string one. Two clients (a UI and an automation
path) then each carry their own idea of the legal set, and a user is shown rows they cannot create.

Rules:
- **Argument types are the gate.** A free-string argument next to an existing enum type is a bug,
  not a shortcut. Test it by introspection (no argument named for the enum is typed `String`), not by
  grep.
- **A list of tokens is a list of enum members**, not a JSON array of strings validated by an `if`
  inside one mutation. Put the validation in the type so every path shares it.
- **The UI enumerates the schema's enum** (codegen or introspection) and renders labels generically;
  a hand-written label map in the client is a second definition of the same vocabulary — exactly what
  a second-definition check is meant to catch.
- **Every writer goes through the same typed boundary.** An automation/agent path that reaches the
  storage layer with a wider vocabulary than the UI is how "impossible" rows appear.

Copy the repo's existing end-to-end enum (there is usually one) rather than inventing a new pattern.

## An invariant with more than one SOURCE is answered by ONE choke-point function

**Money (an allowance pool plus a paid balance), a quota, a permission: when an invariant can be
satisfied from more than one source, exactly one function answers it, and every caller uses that
function.** Adding a source means adding it *inside* that function, and shipping a test that fails
when any caller reads a source directly. The guard is on the **call shape**, not the import: a caller
that imports the helper and then reads a balance itself passes every "does it use the helper?" grep
while bypassing it — calling a shared helper is not using it.

**A feature that adds a source without the choke point is not done.** Its done-when names the
choke-point function and the bypass test **by name**, and its walk exercises the **consuming** path
(spend from the new source), not only the acquiring one (grant or buy it). The failure it prevents is
quiet: the new source is acquired correctly, shown correctly, and never spent, because one consumer
still reads the old source directly.

## Public engine, private config

An IaC repo has two kinds of content, and only one of them can ever go public:

| Layer | Contains | Home | Publishable |
|---|---|---|---|
| **Engine** | playbooks, roles, compose files, scripts, tests — *how* things are done | the main repo | yes, by design |
| **Config** | inventories, host addresses, network policy, per-site values — *what* it's done to | a **private overlay repo** | never |
| **Secrets** | credentials | the secret store only | never, in either repo |

The engine reads the overlay by path (`-e policy_dir=…`), so the public half is complete,
runnable, and reviewable, while the private half stays a small diffable set of data files.
The split is what makes "should this repo be public?" answerable at all — otherwise a single
internal hostname anywhere in the tree vetoes publishing the whole thing forever.

**Private is not a licence to commit secrets.** The overlay is *lower-sensitivity*, not
*safe*; the same secret-scanning gate and the same store-everything-else rule apply. If a value
would burn on disclosure, it belongs in the store even in the private repo.

Do the split **when you create the config**, not when you decide to publish — retrofitting
means rewriting history. Scope of a *policy* is a separate question from location of its *config*;
see `security.md` → *Pick the rung from the CONSUMER*.

## A local checkout names its organisation when repo names collide

A forge namespaces repositories by organisation (`org-a/secrets`, `org-b/secrets`); a local disk does
not. Two same-named repos cloned side by side either collide or are told apart by path accident, and
an agent standing in `~/projects/secrets` will confidently act on whichever org's repo happens to be
there. **Keep the plain name in the forge; prefix the local directory with the organisation**
(`org-a-secrets`, `org-b-secrets`). Never infer which organisation a checkout belongs to from its
directory name: read its remote.

## Deploys & health — pull-based

- **Boxes deploy themselves** (webhook, HMAC-verified, + catch-up timer gated on CI-green
  commit status). CI holds no credential that can reach a box; SSH stays operator-only.
- **Two health surfaces, never conflated**: `/health/` = liveness (shallow, no DB — the
  container healthcheck) and `/health/ready/` = readiness (DB reachable + no unapplied
  migrations, 503 on fail — what MONITORING probes). A liveness-only monitor watched a
  total functional outage stay green.
- **Monitoring must not share fate with what it watches**: in-app dead-men (celery/beat)
  are a layer; the authoritative probe is external (blackbox → Alertmanager).
- **Scripts re-exec'd by path need the git exec bit AND `exec bash "$path"`** — checkout
  restores committed modes; a 0644 script killed a prod deploy with "Permission denied".
- **compose v1→v2 RENAMED the images it builds, so old rollback targets no longer resolve.** v1
  joined project and service with an underscore (`myproj_web`), v2 uses a hyphen (`myproj-web`).
  Nothing warns you: the upgrade is silent, new builds tag the new name, and the break only surfaces
  the day you need it — a rollback to a pre-upgrade tag, or any script/compose file/runbook that
  names an image literally, fails with "no such image" during an incident. Before trusting a
  rollback path after a compose upgrade, `docker image ls` the ACTUAL names on the box and reconcile
  both spellings (retag the survivors, or pin `image:`/`container_name:` explicitly so the name stops
  depending on the compose version).

## A deployable repo stands alone — the stack-repo properties

A repository that something deploys from carries everything needed to deploy it, gate it and find it
**without its former siblings**, and stays publishable later. Each property below is implicit in a
monorepo and breaks silently when a stack is extracted, so each is a review check.
`templates/stack-repo/` is the layout (properties 1–3, 6 and 11–13 ship in it as working files), and
`governance scaffold --template stack-repo --out DIR` creates whatever a repository is missing without
overwriting anything.

1. **CI reports a status on the default branch before anything deploys from the repo.** A status-gated
   pull deployer reads "no status" as "not green" and waits forever, so a new repo without CI is a
   silent deploy stop.
2. **The secret-scan gate proves its rules fire**: a positive fixture caught by a named rule id, and a
   negative fixture of env and template shapes (empty values, `${VAR}` placeholders) that nothing
   catches. A clean scan alone cannot tell "no secrets" from "rules that match nothing".
3. **The README has a `Contracts` section**, one line per cross-repo runtime edge: external networks
   joined (and their owner), hostnames resolved that another repo's containers own, ports exposed to
   others, secret-store path *prefixes* read — names only. Splitting repositories does not split the
   runtime fabric, and this list is the only place that coupling stays visible.
4. **Deploy parameters are data in the repo's own deploy vars**: repo slug, watch path, target dir,
   state file, unit name. A shared role's defaults name some other repository, so inheriting them
   deploys the wrong thing or nothing.
5. **Shared substrate is vendored under drift detection, never hand-copied**: every file copied from a
   shared home is listed in a manifest, and CI fails on unexplained divergence. A hand-copy diverges the
   first time either side changes — and the second hand-carry is the trigger to automate.
6. **No hard-coded checkout paths, home directories or sibling-repo slugs**; a script derives its repo
   root from its own location. Such a path works only on the machine that wrote it, which is why the
   template's lint fails the build on one.
7. **The registry row exists before the repository does** (what / where / why / status), and the
   deploy credential's scope is verified by a read against the new repository, never assumed. A
   credential still scoped to the old repository fails at the first deploy, when nobody is watching.
8. **Extraction is copy → gate → re-point → prove no-op → delete, and the copy is a squash import**
   with a provenance line (donor and commit), never history-preserving when the donor's history holds
   credentials or organisation identifiers — that history stays in the donor. The donor keeps its copy
   (behind a thin `MOVED.md` pointer) and rollback stays "re-run the old deployer" until the new
   repository's deployer has logged an identical-tree no-op and one real change has deployed end to end.
9. **A retire pass precedes any move**: artifacts with no deploy path, roles nothing references and
   decommission playbooks for things already gone are deleted in place first, never migrated. A move
   gives dead weight a new home and the look of being owned.
10. **One decision log per repository**, holding only the decisions it owns; a cross-cutting decision
    stays in the donor's or the platform's log and is linked, not copied — two copies drift, and each
    reads as the authoritative one.
11. **The repository splits into a generic `module/` and a private `overlay/`**: the module is
    parameterised and publishable, the overlay holds the organisation's hosts, inventory, secret paths,
    dashboards, probes and alerts — core, adapter, local, as in a governance render. Publishing later
    is then "publish `module/`, relocate `overlay/`" instead of an audit of every file.
12. **Core services are consumed through declared inputs, never literals** — identity issuer URL,
    secret-store address and path prefix, edge network name, an optional bus URL — listed under
    `Contracts` → *Inputs*, and the module starts with none of them set (a plain env file, no SSO). A
    module that needs one organisation's core services just to start cannot be tried, tested or
    published anywhere else, and a test that renders its config with empty inputs is what proves it.
13. **CI lints `module/` for the organisation's terms** — its domains, private network names and
    secret-path prefixes, from a denylist the overlay owns — and for checkout paths and references into
    `overlay/`; a missing denylist is *not checked*, never clean. Genericness without a gate decays on
    the first urgent fix.

## An integration that MIRRORS external state ships a push handler AND a pull reconcile

**Any code path that copies state owned by an external system into the local store ships three
things in the same change, or it is not done:** a **push handler** (webhook or callback) that applies
the provider's events; a **pull reconcile** — a committed command that re-reads the provider and
repairs local state, **idempotent by the provider's own id**, safe to re-run at any time, runnable per
entity and for all, with a dry-run that reports the diff; and **two tests** — the same push event
delivered twice produces one state change, and the reconcile repairs a missed event (drop the event,
run the reconcile, assert convergence). Whether the reconcile is scheduled is a product decision;
that it *exists* is not.

**Idempotency is keyed on the external id, never on arrival order or local timestamps.** Store the
provider's event id under a unique constraint so a redelivery is a no-op by construction.

**Review rule:** a push path with no pull path is a **defect, not a follow-up**. The reviewer asks:
*if the callback was misrouted, dropped, or the endpoint was down for an hour, which committed command
makes the local store converge?* No answer → request changes. Push-only mirrors fail silently — the
provider believes the change happened, the local store never hears of it, and the absence has no
error state — and the pull path is also what lets every environment converge from the provider by
command instead of by re-firing events.

## The promotion gate is a walked STAGE, and a deploy is fully automated

**Nothing is promoted until the release's headline flows have been walked end to end on the staging
environment, on the EXACT artifact pair being promoted.** The walk record names that pair (every
artifact's build identifier); a re-cut of either side invalidates the walk, and it is repeated on the
new pair. Each lane's own green is a **precondition** for starting the walk, never evidence for the
promotion: each lane proves its half, and the defect lives where the halves meet. A cut receipt links
one walk record — who walked, environment, the artifact pair, steps, observed — and whoever declares
readiness across lanes owns scheduling the walk and may not write *ready* without that link.
*"Unwalked"* in a readiness line is a block, not a caveat.

**A deploy is fully automated: the release pipeline alone sets the planned good state.** Every
post-deploy seed, sync or catalog step lives in the pipeline's post-deploy hook or in infrastructure
code, never as a block a human runs by hand. A hand-run command in a deploy hand-off is a defect to
ticket, not a step to perform: it can only exist on the new build, so it fails on the old one — and
that is exactly when it gets run. The deploy flow is documented as code so it is repeatable and never
depends on one person's memory.

## A merge-ready claim covers EVERY CI run for the head, queried by the full id

**"Green" is a claim about every run the forge made for that exact commit** — typically a push run
and a pull-request run, sometimes more than one workflow — found by querying the **full** commit id,
never a branch name or an abbreviated id (an exact-match filter returns nothing for a short id, which
reads as "no runs"). **A split verdict on one commit is red.** A green push run beside a red
pull-request run on the same commit is not "mostly green"; the red one is the answer until it is
explained.

**A green that queries a live feed ages.** Gates that consult an external, changing source — a
dependency or vulnerability audit, a licence database — can pass and then fail on the same commit
minutes apart, so a green observed earlier is not a current green. For those gates, the merge-ready
claim names the run and its time, and is re-checked at merge.

## A dependent repo's CI must PROVE its API is deployed before it deploys

**The rule.** Where one repo ships against another's live API — any FE→BE pair, any service calling
another's API — the **dependent** repo's CI carries a **blocking pre-deploy assertion that the
matching backend deployment already serves every contract element this build SENDS**. If the backend
hasn't shipped it, the dependent deploy fails loudly instead of going live against a schema that
cannot answer it. Once the backend is updated, the same check passes and the dependent deploy
proceeds.

**Why it is a hard failure, not a degradation — this is the part that surprises people.** An unknown
field or argument fails the **whole operation at request validation**. GraphQL rejects the document
before a resolver runs, so the feature is *dead*, not partial: send a field the API has not deployed
and **the whole mutation stops working.** REST is friendlier but not safe — a 400 on an unexpected
body is the same shape.

**The gap this closes has a name: MERGED IS NOT DEPLOYED.** Two repos merge independently and deploy
independently, and the window between "the BE PR merged" and "the BE is live" is exactly where a
dependent deploy breaks. A human reading two green PRs cannot see that window; a machine checking
the live endpoint can. Measured: an FE change was written against a new field while introspection
showed the deployed schema had it on **neither mutation nor type** — the gate caught it before merge.

**Environment pairing is part of the rule, not a footnote.** Stage FE asserts against **stage** BE;
prod FE against **prod** BE. A gate pointed at the wrong environment is worse than none: it passes
on stage's schema and lets prod ship broken. Take the endpoint from the same config the build will
actually run with.

### Shape of the check

- **Blocking, in the deploy path** — not advisory, and not only on PRs. The PR gate proves the code
  is sound; this proves the *world it is about to enter* is ready.
- **Three outcomes, not two**: present → pass; **absent → FAIL**; **could-not-determine → ALSO
  FAIL.** An unverifiable schema is not a verified one, and a probe that returns "endpoint
  unreachable" as a pass is the absence-as-health trap (a missing signal read as a healthy one) one
  layer up.
- **Add a line when you start SENDING a new field**, not when the backend adds one. The gate's
  subject is this build's requirements, so it stays small and never becomes a schema mirror to
  maintain.

### Reference techniques — pick by whether introspection is enabled

| Introspection on the deployed API | Technique |
|---|---|
| **enabled** | one introspection query; pure shell + curl |
| **disabled** | send the real mutation with a deliberately type-invalid sibling field; coercion aborts before any resolver, and the error list still reveals whether the field is known |

**Do not port the coercion probe where introspection works** — it is a workaround for a constraint
you may not have, and the simple query answers the same question. **Do record which one applies and
why**, because the answer flips the moment an environment disables introspection.

## Evals: a pass on the corpus you tuned against is not evidence

**Hold out a seed the fix never saw.** Tuning against an eval corpus and then scoring on that same
corpus measures memorization, not capability — and it fails in the direction that hurts: it says
*ship*. Measured on a redaction eval: `qwen3:8b` scored **99.39% on the seed it was tuned against and
98.14% on unseen data** — against a 99% bar, the tuned-only gate would have **shipped a false pass**.
Same model, same harness, different seed. (`qwen3-coder:30b` scored 100% on both, which is what a real
pass looks like.)

- **The held-out run is the result**; the tuned run is a debugging aid, not a gate.
- **Re-run on every model, prompt, or pipeline swap** — the eval is the portability contract, not
  the model name. A verdict is per-model and dated, or it is stale.
- This is *verify with the real gate, not a proxy* in eval clothing: scoring the corpus you fitted
  to is the same move as asserting a deploy worked because CI was green.

**And the harness must fail LOUDLY on empty model output.** Same investigation: `/no_think` is inert
through Ollama's OpenAI-compatible endpoint (`think:false` is ignored there too — only native
`/api/chat` honours it), so the model spends its whole budget in a separate `reasoning` field and
returns **empty content**. A harness that quietly scores an empty completion reports its regex/NER
pre-pass's number **as if it were the model's** — a silent regex-only score masquerading as a model
score, which is **absence-as-health in eval flavor**. Assert non-empty output per item and fail the
run; never let a missing answer be scored as an answer.

## A test double must FAIL the way the real collaborator fails

**A double that RETURNS an error where production RAISES one — or returns a shape production never
returns — exercises a branch production cannot reach.** The spec then proves only that the double is
self-consistent with the assertion written beside it. The real path can be absent for the entire life
of the test.

This needs its own line rather than folding into *keep the mocks in sync*, because the ordinary
version is found by reading and **this one actively resists being found**: the evidence you would
reach for — a passing spec, correctly named, asserting exactly the right behaviour — **is the thing
that is wrong.** A green test is standing guard over absent behaviour.

⚠️ **AND THE DEAD BRANCH IS NOT THE HARM — DIVERGENCE between it and the live handler is.** A repo
audit of one instance found **three occurrences of the identical shape: one harmful, two benign** —
and the two are benign only because the dead branch and the live handler happen to produce the same
string *today*. Nothing holds them together. So the defect is not "the real path is untested": it is
that **the spec documents a SECOND implementation of the same behaviour, and nothing checks the two
against each other.** A suite is supposed to be the check on the implementation; here it quietly
becomes a rival one, and the next person to edit one side leaves a green spec asserting behaviour
that has stopped existing.

⚠️ **AND COPY THE SURFACE THE CODE CALLS — never the view you read it through.** Authors inspect
a real system through an intermediary — an agent tool, an SDK, a CLI, a dashboard, a gateway — and
intermediaries rename, derive, flatten and reorder fields for the reader. A double built from what
the author *saw* encodes the intermediary's shape, so the suite passes in full while the code, calling
the raw API, parses nothing. Measured: a self-test passed every case on stubs keyed to a field the
reading tool *derived*; the API itself has no such field, and the first live run matched zero records.
Build the fixture from the called surface's own contract — its published schema, or a captured raw
response — **including the structure a flattening view hides: nesting, field order, envelopes.** A
parser that splits records on a delimiter passes a flat stub and then fails on a nested object sitting
between two fields it needs. Tell: the fixture's field names match your tooling's output, not the
vendor's schema.

**Tells**, cheapest first:
- a spec that passes over a branch you cannot trigger by hand;
- a double returning a success/failure envelope where the real call throws;
- a double returning an unwrapped value where the real API wraps it, or the reverse;
- **a comment on the production branch acknowledging that the doubles take the other path — that
  comment IS the bug report**, already written, already ignored.

⚠️ **The harmful subset has its own tell: the live handler WRAPS the server's message.** Wrapping is
where a true message becomes a false one. The measured case prefixed a refusal with *"Failed to
add <resource>"* when the resource **had** been added — an error message that **causes the damage it
reports**, because a user who believes it retries and double-adds. A dead branch that merely
duplicates a string is debt; a dead branch that wraps one is a live defect.

⚠️ **WRAPPING FALSIFIES THE MESSAGE; REPLACING LOSES IT — same root, different fixes, different
severity.** Both are a generic handler swallowing a specific one, and they are detected the same way,
but the remedy a reader needs differs:

| mode | what the user gets | fix |
|---|---|---|
| **wrapping** — the handler prefixes the real message | an **actively FALSE** statement (*"Failed to add X"* when X was added) | stop prefixing; surface the message verbatim |
| **replacing** — a catch-all substitutes its own text | the specific message is **LOST**, not false (*"Could not create the default …"*) | **order** the specific handler AHEAD of the catch-all |

**Only wrapping produces a false statement, and that is the severity split**: a falsifying handler is
a live defect — it causes the damage it reports — while a replacing one is debt, because the user is
merely uninformed rather than misinformed. Fix the falsifying ones first.

**The proportionate response is an AUDIT, not a sweep.** In the measured repo 20+ methods throw that
way and ~15 spec files stub the returning shape — **only the intersection is a mismatch.** Enumerate
the sites in a table, fix the ones that diverge, and leave the rest; mass-rewriting every double to
"fix" a shape mismatch is a large diff through the exact machinery that is supposed to be catching
your mistakes.

Same principle as *a probe that cannot distinguish the thing from a REFERENCE to it, or its own
FAILURE from a negative, is not evidence* — one layer down, in the suite rather than the probe.

## REACHABILITY IS A LADDER — each rung proves only its own layer

**ICMP proves the kernel answers. It proves nothing about any service.** In a forge outage a host
replied to `ping` while **refusing `:22` and `:443` on BOTH its VPN and its public address**. An
agent reported *"SSH over the VPN should still reach the box"* on the strength of the ICMP reply
alone, and had to retract it minutes later. The box was up; nothing on it was serving.

Climb the rungs explicitly, and name the one you actually tested:

| rung | what a PASS proves | what it does NOT prove |
|---|---|---|
| ICMP `ping` | the kernel is up and routing works | that any process is listening |
| TCP connect | something is bound to that port | that it speaks the protocol |
| TLS handshake | a server is terminating TLS | that the app behind it is healthy |
| HTTP status | the app answered | **that it can do the work you need** |
| the operation itself | the thing you need works | — |

⚠️ **REFUSED and TIMED OUT are different evidence, and the difference is diagnostic.** *Connection
refused* means the packet arrived and nothing was listening — the host is reachable and the service
is down. *Timed out* means it was filtered or the host is gone. Reading one as the other sends the
investigation to the wrong layer on its first move.

**The top rung is the only one that answers the question you asked.** A 200 on a status page does not
prove a forge can serve a push; a healthy TCP connect does not prove a database is accepting writes.

⚠️ **AND THIS RULE EXISTED — in the wrong place.** Two nightly task prompts already carried
*"Reachability only — a 200 here does NOT prove the forge can serve work"*, verbatim and correct, for
weeks. **It bound those two tasks and nobody else**, so during the outage the agent making the call
had never read it. **A rule that lives only in a task prompt binds only that task.** When a
prompt-local note turns out to be general, promote it to the domain doc and leave the prompt
pointing at it — the prompt is where a rule gets USED, never where it should be KEPT.

## A checker that FIRES is not a checker that is RIGHT

The familiar rule is to prove a **zero** — a control probe against a known-bad string, so an empty
result is not a broken selector. That closes the false-negative half and **leaves the mirror open**:
a checker that returns findings has proved only that it is **ALIVE**. Liveness is not correctness.

**A new gate owes TWO demonstrations before anyone acts on its output:** one **known-GOOD** artifact
it **PASSES**, beside one **known-BAD** artifact it **FAILS**. One without the other is half a
calibration — the known-bad alone proves it can fire, which is exactly the evidence a
fires-on-everything checker also produces.

**Measured root cause, because the shape recurs: hand-parsing a structured format.** A line regex
over YAML read a block sequence as empty, so the gate fired on **every correctly-formed record** —
and its remediation would have corrupted them. A checker that is wrong in the FIRING direction is
worse than one that is silent: silence gets ignored, while findings get **acted on**, and the action
is a write. Parse the format with a parser; a regex over a structured file is a second, worse
implementation of that format's grammar.

⚠️ **VERIFY THE ARTIFACT, NOT THE INTERMEDIATE — the same failure wearing its other face.** A repair
validated itself against the **in-memory string it had just built**, while the **file it wrote** was
malformed. Success was reported from **the step performed** rather than **the state produced**, so
the check could not fail no matter what landed on disk: it was asking itself whether it had done the
thing, not whether the thing was true.

**Re-read the artifact back from where it lives** — the file from the filesystem, the row from the
store, the ref from the forge — and assert against *that*. Both rules reduce to one habit: the thing
that confirms must be **independent of the thing that acted**, or it is a rehearsal of your own
intent. Same family as a health field authored by the subject it reports on, and as a test double
that never reaches the real path (above).

## The SEAM is the subject's duty; pinning is only the test's

**Every state path a subject writes must be OVERRIDABLE — whether or not a test exercises it
today.** Pinning that path is the test's job; *providing the override* is the code's, and the two
decay at completely different rates. The subject's half is audited once and stays true. The test's
half must be re-audited on every new test, forever.

| Duty | Owner | Decay |
|---|---|---|
| **Provide the SEAM** — the path is env-overridable, whether or not a test exercises it today | the **subject** | audited **once**; stays true |
| **PIN the seam** — redirect it to the test's own tmp | the **test** | re-audited on **every new test** |

**Origin.** A backup script's test suite pinned 2 of 3 state paths and silently wrote fixture rows
into the operator's PRODUCTION state file on every run, truncating real rows and resetting the
escalation streak the feature under test depended on. **Partial pinning is the dangerous shape
precisely because it reads as isolation.** The audit that followed swept four more suites in another
repo and found no live mutation — and two writers that were one new test away from the same defect,
both of which passed the rule as first stated ("a test that does not pin every state path its
subject writes is mutating production"), because *no test exercised them yet*.

One module hard-coded its saved-window-layouts file under the user's data directory with **no
override at all**. There is no window-layout test, so nothing was being corrupted; a future one
would have written the operator's real saved layouts with no way to redirect it. It failed the seam
form while passing the pinning form, and it is the exhibit for why the seam form is the load-bearing
one. Fixed by adding an environment-variable override, matching the seam its sibling module already
had.

### Auditing it

Enumerate what the SUBJECT writes, then diff against what the tests pin — in that order. Going the
other way (reading the tests first) only ever finds paths the tests already knew about.

Run on the backup script, subject side first: **two authored write paths, both seamed, no hard-coded
absolute targets.** So that script's incident was purely the *test's* half — which is worth
recording, because it shows the two halves fail independently and a repo can be clean on one while
broken on the other.

⚠️ **A fixture pins only the tests that TAKE it.** A fixture that configures a state path and resets
to the production default on teardown leaves every non-fixture test pointed at production. Verify
those tests are genuinely pure rather than assuming it — in the audit, six index tests skipped the
pinning fixture and were confirmed to call only pure parsing functions. That check is the one the
rule implies and does not state.

### Why it is worth a structural fix rather than a recurring audit

A state-path audit is a snapshot; the seam is an invariant. Adding the override before the test
exists is cheaper than discovering it afterwards, and the discovery mode is bad — corrupted local
state usually looks like a UI annoyance or a flaky test rather than a test defect, so it is
attributed to anything except its cause.

Same refusal as *a service isn't deployed until its backups are PROVEN*: **a suite that passes while
mutating production is not a passing suite — it is an unmeasured side effect wearing a tick.**

## An expected value copied from the OUTPUT pins the defect

**A test whose expected value was taken from what the code currently produces is not a test — it is a
lock.** It cannot fail while the bug lives, and it fails the moment someone fixes it, so the suite
argues *for* the defect and against the repair. Four instances in one codebase in a single day, all
found only because a fix made them go red:

| Test | Asserted | Why it could not catch the bug |
|---|---|---|
| `assertIn("/items/<id>", url)` | a substring | satisfied by BOTH the real `/media/items/<id>` and the nonexistent `/items/<id>` |
| `assertEqual(result, ".../items/cfg-1?…")` | the whole URL | the **strongest** form — pinned to the URL that shipped broken |
| a selection test for records with data gaps | a 3-year-stale record must NOT refresh | "complete" was read as "current", so staleness was excluded by design |
| a column-to-metric mapping test | `rows == 1` on a 2-row fixture | the second row was dropped for not being pre-seeded — a one-region-only defect |

**Assertion STRENGTH is not the variable, which is the counter-intuitive part.** The second row is
full equality — the form we normally call rigorous — and it was the most precisely wrong. What
separates a real test from a lock is **where the expected value came from**: a *requirement* ("the
link must resolve", "a stale record must be refreshed") or an *observation* ("this is what it
printed when I wrote it"). Only the first can disagree with the code.

**The tell at authoring time:** if you produced the expected value by running the code and pasting
the result, you have written a change-detector, not a test. Change-detectors are legitimate — golden
files, snapshots — but they must be *labelled* as such, because their green is a statement about
stability, never about correctness.

**The tell at failure time, and this is the one that matters:** when a test breaks right after a
fix, the question is **"was it asserting the requirement or the behaviour?"** The reflex is to
restore green by adjusting the code; three of these four were adjusted the other way, correctly,
only because someone asked that question. A test that fails on a fix has told you something — do not
silence it before reading it.

Sibling of *a name or description that asserts what the code does not check*: there, a claim exists
with nothing enforcing it; here, the enforcement exists and points at the wrong reference. Both
produce an artifact that is confidently, checkably wrong.

## A fix can invalidate the DIAGNOSTIC that found the bug

**When a fix changes a mechanism's TYPE rather than its value, every detector written against the
old type is now measuring the wrong thing — and it was born wrong, from a diagnosis that was
correct.** Re-validate detectors against the FIXED system, never against the broken one you wrote
them in.

**Exhibit.** A timer-disarm incident was diagnosed by reading systemd's `NextElapseUSecMonotonic`. The
fix converted those timers from **monotonic** to **`OnCalendar`** — and systemd stores a calendar
timer's next fire in `NextElapseUSecRealtime`, leaving `NextElapseUSecMonotonic` reading **0** on a
perfectly healthy timer. A monitor built from the diagnosis would therefore ship **permanently lit on
exactly the two timers it watches**, having been written from an accurate investigation of the
pre-fix system.

### Why this is its own rule and not *absence-as-health*

They are opposites, and the difference decides what you look for:

| | *Absence-as-health* | **This rule** |
|---|---|---|
| What happens | a check that matches nothing goes **green** | a check that is now mistyped goes **permanently red** |
| Why it survives | silence reads as success | noise reads as a broken monitor |
| How it is "fixed" | nobody notices | someone widens or mutes it — converting the detector into the blind spot it existed to catch |

The failure mode here is **not** that the alarm is ignored by accident. It is that a permanently-red
detector invites the obvious repair — silence it — and silencing it is indistinguishable from fixing
it.

### The commonest cause is not a mistyped check — it is a monitor outliving or preceding its target

⚠️ **A signal that is ALWAYS red is indistinguishable from no signal — and worse than none, because
it consumes attention and teaches the reader to skip that panel.** A check that is red *sometimes*
carries a bit of information. A check that has been red since the day it was created carries none,
and it degrades every honest signal beside it, because the habit it trains is not "ignore this row"
but "this panel is noisy".

The two lifecycle causes, and neither involves the check being wrong:

1. **Armed BEFORE its target exists.** A collector pointed at an endpoint nobody has deployed yet
   reports the target down, correctly and forever. The monitor is right; there is simply nothing
   there. → **Ship it commented out, with its arm-condition written beside it** — *"enable when X
   is serving"*. A dated arming condition is a to-do; a live red row is a broken instrument.
2. **Outliving its target — the one people miss.** Retiring a probe usually means deleting the
   thing that RUNS it, which feels complete. But where a probe publishes through a file that an
   agent re-serves, **the last value it ever wrote keeps being served**, with nothing left running
   to update it. A failed final run then reports failure indefinitely, attributed to a probe that
   no longer exists. → **Deleting the published artefact is PART OF retiring the probe**, not
   cleanup afterwards; a retirement that stops the writer and leaves the value is not finished.

**The generalisation, which is the part worth carrying to other systems:** a permanently-red signal
is a statement about the MONITORING, not about the system. So read the *duration* of a red before
reading its content — "has this ever been green?" is a cheaper and more decisive question than any
amount of investigation into what it claims. If the answer is no, the bug is in the instrument or
in its lifecycle, and diagnosing the system is time spent on a claim nobody has established.

Same family as the mistyped check above, arrived at from the opposite direction: there the check
stopped matching its subject, here the subject stopped existing on either side of the check.

## Definition of done: a service isn't deployed until its backups are PROVEN

**"Live" means serving traffic AND a verified backup sitting off-box. A service that answers
200 with no proven backup is not done — it is an outage waiting for its first bad day.**
Calling it done is a false claim, not an optimistic one.

- **Proven = both halves, observed**: (1) a backup actually *landed on the offsite target*
  — list the object, check size and timestamp; "the cron is installed" and "the script
  exited 0" are not evidence — and (2) it *restores*, at minimum a rehearsal into a
  throwaway target proving the dump loads and the archive unpacks. An unrestorable backup
  is a backup-shaped file.
- **Why this is a rule**: three services (an identity provider, a git forge, customer chat
  instances) were each declared live and handed over while **not one backup had ever
  offloaded** — scripts existed, crons existed, the storage credentials were never seeded.
  Every "done" was sincere and wrong, because the check performed was "did the deploy play
  go green", which cannot see this class of gap.
- **So the check must be systematic**: backup wiring is the step with no user-visible
  symptom until the data is already gone, which is exactly why it loses the race against
  the next feature. Put the assertion INSIDE the deploy gate (smoke test asserts a fresh
  object exists in the remote bucket), never on a follow-up list.
- **Applies to language in hand-overs**: never write "✅ Live" in a board, changelog, or
  client-facing doc for a service whose backup has not been observed landing. Write "live,
  backups unverified" until it has — that distinction is the entire point of the rule.
- **Corollary — restores break silently on drift**: a rename shipped `backup.sh` writing
  one bucket while `restore.sh` read another, and secret-name drift (`DB_*` → `POSTGRES_*`)
  broke both. Only a restore rehearsal catches that class; no green deploy ever will.

## Fix at the serving layer

When a capability must reach a SET of clients (all LAN devices, all VPN devices, phones
included), fix it in the infrastructure layer each access path already trusts — never by
per-device configuration:

- **LAN name resolution** → the DHCP-advertised DNS (the router hands every client the internal
  resolver).
- **VPN name resolution** → the VPN control plane's split-DNS (its config ships like code): every
  VPN client — laptops AND phones, which have no `/etc/resolver` — resolves the declared internal
  domains via the internal resolver's VPN address (its LAN address is unreachable through the
  tunnel; that asymmetry is the classic failure).
- Per-device overrides (`/etc/resolver/<domain>`) remain the tool for genuine one-machine
  EXCEPTIONS (`security.md` → *DNS conflicts: fix at the narrowest scope that works*) — the two rules
  compose: scope the fix to the consumer set. One machine → device layer. The fleet → serving layer.

Litmus: if the fix would have to be repeated on the next device, it's at the wrong layer.
Measured: an internal DNS name resolved on the LAN but died on the VPN; the answer was VPN
split-DNS + DHCP, and the hand-made per-machine resolver file became removable.

## Configure the GENERATOR, never the artifact it generates

**A service manager that generates its unit file will regenerate it, and a hand-edit disappears with
no error.** The edit appears to work — the service picks it up, the behaviour changes, the check
passes. Then the next restart, upgrade or reconfigure re-renders that file from the manager's own
inputs, and everything the inputs do not describe is silently gone. Nothing fails. The service comes
back up without the setting.

⚠️ **The whole danger is that the FIRST test passes.** A hand-edited unit file is indistinguishable
from a correctly configured one right up until the regeneration event — which may be weeks later and
triggered by something unrelated, an unattended upgrade or a reboot. By then nobody connects the
missing behaviour to the edit, because the edit is no longer there to find. This is absence-as-health
with a delay fuse: the evidence of the cause is destroyed by the same event that causes the symptom.

**Measured:** environment variables hand-added to a generated service definition vanished on the next
restart. The durable path was the manager's own per-service environment input — a file the generator
reads and re-renders *from* — not the definition it writes.

**So establish, before editing any service definition, whether it is authored or generated.** A
generated file usually says so in a header, lives under a path the manager owns, or has an mtime that
tracks package operations rather than your edits. If it is generated, find the input. **If the manager
exposes no input for what you need, that is the finding** — the setting cannot be expressed durably
there, and a wrapper or a hand-authored unit kept outside the manager is the honest fix, not an edit
that will be reverted without telling anyone.

The same shape covers any rendered configuration — templated config, generated container manifests,
rendered dotfiles. **An artifact that has a generator has exactly one durable edit point, and it is
not the artifact.**
