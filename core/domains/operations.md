# Operations

How work flows: initiatives, hand-overs to humans, decision records, routines, and long-lived goals.

On client work, follow the client's process and protocols for *their* delivery; your own operating
system always runs underneath (`core/AGENTS.md` → *Precedence of guidance*).

## Project / initiative creation

Starting an initiative = define its goal as a **SMART checkbox list** (refine until every box is
checkable). New initiative → **its own repository on the forge** (+ a knowledge-vault folder for the
strategy layer); requirements/capabilities land in that repo's `docs/`, work items as its issues.
Record the repo in the initiative's state doc. (Placement: `core/AGENTS.md` → *Artifact placement*.)

## SIMULATE THE SEQUENCE (plan as state transitions)

A plan is **state transitions, not a list**. For each step name what it mutates; re-check later steps
against that world; insert reconciliation (merge-back, rebase, restart, migrate). A first command that
403s because login was not in the script was never simulated.

**The same reflex has a second axis: a precondition that can DRIFT.** Simulate-the-sequence catches a
precondition broken by an **earlier step** (step 1 mutated the world step 3 assumed). The second walk
catches a precondition broken by the **passage of time** between authoring and running. Both are
simulation — one walks the steps, the other walks the clock. A queued hand-over needs both walks, and
only the clock walk is easy to forget, because at write-time the check passed.

**Corollary for whoever CONSOLIDATES hand-overs** (an orchestrator merging several agents' blocks
into one ordered list): inserting a delay in front of a block is a change to that block's risk. The
consolidator inherits the duty to keep the drift-guard attached — and should never add a
"make sure you're up to date" habit-step (`git pull`, `git checkout <branch>`) to someone else's
verified block, which mutates the very state the block asserted.

**And RE-VERIFY AT PRINT TIME — every print, not once at receipt.** A block that arrives verified is
verified *as of its arrival*; if it then sits in a queue, gets re-ordered, or is re-printed in a later
sitting, its preconditions are a fresh claim each time it is put in front of the human. So the moment
before printing — not the moment of receiving — re-assert the cheap ones against the live tree: does
the path still exist, is the branch still what the block says, is the label still unloaded. This costs
seconds and it is the only check positioned *after* the drift.

**Measured:** a block's author had verified a path correctly, and it was the **consolidator's
pre-print existence check that caught the break** — after the author's own later commit invalidated
the path. Note the shape carefully, because it generalises past paths: **the author cannot perform
this check, ever.** By construction the drift happens after they hand over. Print-time
re-verification is therefore not redundancy with the author's write-time check — it is the only place
the check can live.

## A QUALIFIER CREATES THE EXEMPTION IT WAS ADDED TO PREVENT

**When you narrow a rule with an adjective, you have written a carve-out for the case that will
actually bite you.** The adjective describes the CARELESS version of the mistake, so the CAREFUL
version — the one a competent agent reaches for, under exactly the pressure the rule exists for —
reads as excluded. And it reads that way to someone obeying the rule, which is why vigilance cannot
catch it.

Three instances in one week, each caught only after it fired:

| Rule as written | The qualifier | What it exempted |
|---|---|---|
| "never a **bare** `git stash`" | *bare* | `git stash push --keep-index -- <one file>` — judged exempt because it was the narrow, careful form. It renumbers the shared stack identically. |
| ref-discipline, framed around the "**idle glance**" | *idle* | the most careful posture there is — deliberately checking a peer's claim, from a 347-commit-stale checkout. |
| header spec: `<date> (<pre/post-market>)` | an unmeasured assumption | the 94.6% of rows with no timing, so the dominant case rendered an empty paren. |

**The tell shows in a rulebook's own history:** four separate clauses in one instruction file had to
be retrofitted with *"RECENCY IS NOT AN EXEMPTION"*, *"no exemption for short, obvious, follow-up"*,
*"OPTIONAL and deferred items are NOT exempt"*, *"'bare' is NOT the qualifier"*. Every one is a patch
applied AFTER a qualifier let a competent reader through. The pattern is not that people ignore
rules; it is that we keep writing rules with a door in them.

**So, when authoring or sharpening a rule:**

1. **State the MECHANISM, not the careless instance.** Not "never a bare stash" but "any stash push
   renumbers the shared stack". The mechanism has no adjective to argue with, and it tells the
   reader what to check rather than which word they resemble.
2. **Name the most careful version you can imagine and ask whether the wording covers it.** If the
   diligent form reads as excluded, the qualifier is the defect — delete it or state the exception
   explicitly, never leave it implied.
3. **A spec written before the adversarial case was MEASURED is a draft.** The two-state header was
   not wrong through carelessness; nobody had counted the blank field. Measure, then specify.
4. **When you catch one, fix the WORDING, not just the instance** — "X is not an exemption" bolted
   on is a symptom, and the fourth one should have been a rule about rules.

## Hand the human a SCRIPT, not steps — self-logging by design

When the human must run something, the deliverable is **one committed script invoked by one line**
(`bash path/to/thing.sh`), not a pasted block of commands. Measured: a 318-file, 839 MB store
migration was one line for the human; the script carried rsync + sha256 verify + delete + manifest.
Why it wins on every axis:

- **Traceable** — committed beside the work; what ran is exactly what's in git, reviewable later.
- **Self-logging** — the script writes its evidence to a FILE (manifest, log, TSV) that the agent
  reads back itself, extracting only the parts it cares about. The human never hand-carries
  terminal output into chat, and big outputs never enter context wholesale.
- **Verifiable mid-flight** — the agent polls the artifact (`wc -l` a manifest) while the human's
  terminal runs; no "paste me the output so far".
- **Idempotent + fail-safe** by construction (checksum-before-delete, guards) — properties a pasted
  block can't reliably carry.

**A pasted `&&` chain is not a script.** The test: is there a committed path, `test -x`, that the
human invokes in **one** line? If the "script" only exists in the chat fence, it is steps wearing
backslashes. Measured: a credential mint handed over as a `/tmp` `&&` chain — the human had to log in
to the secret store out of band, then re-run; the second `ssh-keygen` overwrote the deploy key
(`Overwrite (y/n)?`), so the public key already pasted into the forge no longer matched the store.

**The script file itself must be idempotent** — not just "some future automation." Re-running from
any partial state converges on the same secret material / the same end-state, and **does not mint a
second key, password, or token.** `ssh-keygen`/`openssl`/store writes that clobber on rerun are
defects. Prefer a patching store write for missing fields; if a key already exists in the store, print
its **public** half and stop — never regenerate. Auth preflight **inside** the script (check the
store session → log in if missing) so a 403 is not a second human-invented ceremony. Simulate the
sequence before hand-over: a first command that 403s because login wasn't a preflight was never
simulated.

Mechanics: the script lives in the owning repo (committed BEFORE the human runs it); writes a
machine-readable progress artifact from the first seconds (a silent multi-minute script is a
hand-off defect — the human can't tell hung from working; measured: a migration script printed
nothing until done and the human asked whether it was hung); prints an explicit end-state summary;
the agent reads the artifact, never asks for the scrollback.

## Git refs in human-facing text

- ⚠️ **The test is ACTIONABILITY, not FORMAT: not "is this ref a link?" but "can the reader reach
  the thing from this line alone?"** Every clause below keys on an identifier being PRESENT and
  asks whether it is linked — so all of them miss the null case, a line that names no artifact at
  all. **A demonstrative standing in for an artifact — "that doc", "the ticket", "the file above"
  — fails before the linking rule is even reached**, and it is strictly worse than a bare ref: a
  bare ref at least names the object, so a reader can search for it, while a demonstrative makes
  them first reconstruct WHICH object from the surrounding conversation and only then go find it.
  **Name the artifact, then link it.** This binds hardest in a human-action row, where the line
  IS the work order — and note the asymmetry that keeps it invisible: the writer, who has the
  object in mind, cannot feel the gap, because to them the demonstrative resolves instantly.
- **A ref is a LINK — a forge URL — never bare.** A branch or tag written as plain text renders as
  a dead file path; issues, PRs and commits are the same. The reader cannot click an identifier,
  and cannot tell a live object from one that was never created.
- ⚠️ **Never fabricate a ref.** Quote a number or SHA only after the tool that mints it answered in
  THIS turn. A plausible-looking issue number or short SHA is worse than a bare one: correct in shape,
  rendered as a link, and therefore trusted — resolving either to nothing or to a real and
  unrelated object. The tell is always the same: **the ref was written before the tool that mints
  it had answered.** If it must be written before it exists, write it in words ("filed as a
  follow-up, number to come"), never as a plausible number.
  **It binds tool ARGUMENTS as hard as prose, and fails more quietly there:** a made-up SHA passed
  to an exact-match filter returns an EMPTY result, which reads as a real absence ("no CI run for
  this commit") rather than as a bad query. Resolve the full id with the tool that mints it
  (`git rev-parse`) in the same step that uses it; before believing an empty answer, re-run it
  unfiltered and match on the result side.
  **The mechanical cause is almost always PARALLELISM:** the call that mints the id (create a PR, an
  issue, a comment) and the message that cites it go out in the same batch of tool calls, so the
  message is written before the id exists and the author fills the gap with the number they expect.
  Hedging ("confirm the number") does not help — the reader acts on the number. **Never batch an
  id-minting call with anything that cites its result;** send the citing message in the next step.
- **A FILE link resolves only for a path UNDER the working directory, written relative.** Absolute
  paths outside it, `file://` URLs, and symlinks inside it all fail to open.

## A dictated name is EVIDENCE, not IDENTIFICATION

**A proper noun you reconstructed from speech is your best guess at what was said — not a fact
about what exists.** Product, company, person, repo, library: when the name reached you through
dictation, a voice note, a transcript, or a hand-off that itself transcribed one, it carries a
transcription risk that nothing downstream can detect.

**The rule, as a step to run:** mark it `confirm-before-use` and get **one word** from the human
before that name enters a requirement, a ticket, a hand-over, a spec, or the conclusion of any
research done on it. One word is the whole gate — the cheapest one there is.

**Both directions were measured the same night, and the failure direction is the teaching part:**

| Dictated | Reconstruction | Verdict |
|---|---|---|
| "Brauk" | Grok | **right** |
| "Airgap It" | AirgapAI | **WRONG** — the referent is **AirGap** (`airgap.it`, MIT-licensed, air-gapped crypto signing) |

The wrong one did not fail loudly. Research proceeded on *AirgapAI*, found it closed-source and
commercial, and concluded — correctly, for that entity — **"EXITS the candidate list."** Unchecked,
that would have **deleted a candidate the human was seriously considering**, and the deletion would
have looked like diligence: sourced, reasoned, internally consistent, and confidently wrong.

**Why no amount of care substitutes for the confirm.** Every downstream check operated on the wrong
referent and passed. The research was sound; the *subject* was wrong. Reconstruction quality is not
the failure surface, so improving it cannot help — this is the wrong-noun failure in its most literal
form: the noun itself was wrong, and everything asserted about it was true of something else.

**Scope.** Binds dispatches, requirement packages, tickets, hand-overs, and research conclusions
alike. A name that arrives already written in a peer's dispatch is **not** thereby confirmed — if
its origin was dictation, the transcription risk travelled with it and the confirm is still owed.

## A decision record LEADS with what the decision does NOT satisfy

⚠️ **A record written as advocacy is worse than no record at all.** With none, the next reader
knows they are looking at an undocumented choice and goes and asks. With an advocacy record they
inherit the choice *without its limits*, and then do one of two expensive things: re-litigate a
decision that was already made correctly, or "fix" the gap it deliberately accepted — paying to
remove a property someone chose on purpose.

**The remedy is PLACEMENT, not completeness.** The limits belong in the reader's path *before* the
section they came for — before the how-to-run, the config, the API. A record can contain every
caveat and still fail, because caveats at the bottom are read by people who already stopped
reading. Lead with the limit and it is the one thing nobody can miss.

**Five properties. All five, or it decays into a disclaimer:**

1. **Name the SPECIFIC requirement the choice fails — quoted.** *"Some risk remains"* is not a
   limit, it is a hedge; it warns nobody and commits to nothing. Quote the requirement so a reader
   can match it against their own.
2. **Show it CONCRETELY, and CLASSIFY BY PRINCIPAL RATHER THAN BY FEATURE.** *"Does the platform
   support <control>?"* answers **Yes** and is useless — the control exists and the exposure is
   still there. The question that decides the design is *"who can perform the forbidden action,
   inside the window?"*, and it answers **per credential**. So the artefact is a
   *principal → can-they-do-it* table, and **that table IS the finding**, not a presentation of
   it: it forces the author to enumerate cases a paragraph waves at, it lets a reader find their
   own case instead of inferring it, and it is **invisible from any feature list** — which is why
   a capability-shaped review keeps returning a clean answer to the wrong question.
3. **The mitigation is a PRECONDITION of the design, not optional hardening.** A mitigation stated
   as advice is a mitigation that will be skipped by whoever inherits the system and reads the
   advice as a nice-to-have. If the design is only sound with it, say the design *requires* it.
4. **Say the risk is ACCEPTED AND RECORDED.** Without that sentence a later reader finds the gap
   and reads it as an oversight — someone's mistake to correct — rather than a decision with an
   owner. This is the property that stops a documented trade-off from being re-opened as a bug.
5. **The escape hatch names its TRIGGERS — plural, and AT LEAST ONE THE DECIDER DID NOT RAISE.**
   "Revisit if circumstances change" triggers nothing. Name the observable events that should
   reopen the decision, so the reopening does not depend on someone happening to feel uneasy.
   ⚠️ **A single-trigger exit is the dangerous shape**, because the one trigger is always the axis
   the decider was already watching — and the axis someone is already watching is not the one that
   turns a recorded residual risk into an incident. So the second trigger is the load-bearing one
   precisely because it came from somebody else. If every trigger on the list is the decider's own
   concern, the list is a restatement of their attention, not a tripwire.

**The test, and it is the whole rule in one line:** *could a reader who DISAGREES with the decision
find their own objection already stated in it?* If not, the record is advocacy — however accurate
every sentence in it happens to be. A record that survives its own strongest objection is the only
kind a stranger can act on, and it is also the only kind that stops costing you arguments later.

**What this technique does NOT satisfy — stated here because a rule of this shape has no standing
to omit it:** it needs a **written requirement to quote**. Property 1 is unusable where the
requirement lives only in somebody's head or in a conversation, so the whole technique is
downstream of having a numbered requirement register. Without one, the honest move is to write the
requirement down first and accept that the record is weaker until then — not to substitute a
paraphrase, which reintroduces the hedge property 1 exists to forbid.

Same family as refusing an unmeasured rationale below: both are about a document whose confidence
exceeds its evidence, and in both the damage lands on whoever reads it next.

## Refuse to write a RATIONALE you have not measured, even when the CONCLUSION is right

**An unmeasured rationale is a durable liability in a way an unmeasured conclusion is not — because
the conclusion gets tested by use and the rationale never does.** A decision is exercised: it ships,
it breaks or it holds. Its stated *reason* is exercised by nobody. It is cited in reviews, inherited
by successors, and used to justify complexity the true reason would not support, long after the
decision itself is settled and safe. **A rationale outlives the decision it justified.**

**Exhibit — four agents, one hour, nobody wrong about what to do.** The conclusion *"derive dates
from the source platform's timestamp, not the relay server's `origin_server_ts`"* was **correct**. Its
stated reason — *"they differ by months on a re-bridge"* — came from a unit confusion (bridge DB in
nanoseconds, `origin_server_ts` in milliseconds) and **was never measured**. It propagated intact:
authored by one agent, amplified as load-bearing by a second, written into a module docstring as fact
by a third, and published into a ticket as a severity escalation by a fourth. Measurement then killed
it in one read — an event predating its own room's creation by twelve days, which only timestamp
massaging on import explains.

Everybody inherited a wrong reason for a right decision, and the reason was already hardening into
code comments and a ticket's severity before anyone checked it.

⚠️ **The tell that it is a rationale rather than a conclusion: nothing downstream fails if it is
wrong.** That is exactly why it survives, and exactly why it must be measured *before* it is written
rather than after it is challenged.

**So, when writing the "because" clause of any decision — commit message, docstring, ADR, ticket,
review comment — mark each one:**

| Kind | How it is written |
|---|---|
| **Measured** | state the measurement and how to re-run it |
| **Inferred** | say so IN the sentence — "inferred, unmeasured" — so the next reader can price it |
| **Inherited** | name the source, so a retraction there can find it here |

**And a hedge must survive the trip into the durable artifact.** Hedging in the conversation and
asserting in the ticket is the same failure wearing better manners — the careful version goes to the
one peer who could check it, the confident version goes to the record everyone else builds on.
Measured in this same incident, by the agent writing this entry.

**When a rationale IS retracted, the retraction must chase every copy** — docstring, ticket, commit
message, hand-off — because each one is now a durable wrong reason that reads as settled. This is why
"name the source" is not bookkeeping.

⚠️ **And the chase can only reach copies that already exist.** A draft authored *after* a correction
is **not downstream of it** — nothing links the two, so the sweep that caught every existing copy
cannot reach a document written next month from the same stale recollection. **Authoring order is not
knowledge order**, and a late draft looks *more* current than the correction it contradicts. So a new
draft that restates a mechanism **cites the correction it post-dates**; where the drafter can find no
such citation, that is the signal to re-read the source rather than the memory. Measured: a filing
written three weeks after a mechanism had been retracted *three separate times* led with that
mechanism, and nothing in the authoring caught it.

## Routines are infrastructure — they migrate, or they silently die

**Every scheduled task and skill is migration payload, equal to threads and tickets.** A migration
that carries threads but not routines hands the destination a crew that has stopped doing everything
nightly — and it fails *silently*, because a routine that never fires emits nothing to notice.

**Measured:** the scheduled-task directory was a plain directory that nothing versioned or installed —
14 tasks existed on exactly one machine; bodies migrated, schedules did not. The fix versioned the
prompt bodies with a manifest beside the rest of the installed config, and installed them exactly as
hooks and skills already were. **What is still NOT versioned is the schedule registration itself**
(it lives in the scheduler, not on disk), so a fresh machine gets every body but zero armed schedules —
the manifest is what it re-arms from, and the acceptance check below (armed AND fired once) is what
proves it.

Two durable rules:

1. **A routine declares its own portability.** Frontmatter carries `scope`
   (`portable` · `host-local` · `engagement:<name>`), `canon_origin`, `canon_version`, `schedule`, and
   `retired:` for tombstones. Without these the destination can only guess, and guessing either drops
   work or clones machine-specific junk onto every host.
2. **Reconcile, never copy.** At the destination each routine resolves to exactly one of: **ADD**
   (missing + portable) · **UPDATE** (stale) · **ADOPT UPWARD** (destination is newer → propose it
   back upstream *before* the migration closes) · **INVESTIGATE → adopt or stop** (present here,
   unknown upstream) · **STOP** (tombstoned — disarm, keep the body) · **LEAVE ALONE** (host-local) ·
   **LEAVE DORMANT** (inactive engagement). **Never delete during a migration** — disarm and
   tombstone; a deleting migration is unrecoverable. **Adoption is bidirectional**: migration is
   exactly when host-local improvements get promoted, and an undecided destination routine is a
   defect.

**Authoring** (as opposed to migrating) a routine has its own two rules — repo-touching routines
work only in a worktree they create, and one-time tasks are a lifecycle that ends in DISABLED — in
*Routine authoring: repo isolation + one-time lifecycle* below. Read both sections together; the
migration sweep is where a never-disabled one-time task gets caught.

Acceptance is behavioral, not documentary: every portable routine **armed and fired once** at the
destination.

## Routine authoring: repo isolation + one-time lifecycle

Two rules that exist because a scheduled task deleted a live agent's worktree twice — a one-time task
whose prompt ordered a reset/rebase **inside another agent's interactive worktree**, and which never
auto-disabled, so it re-fired on every app launch for five days past its date. Work was pushed both
times; an unpushed state would have been destroyed silently.

1. **A repo-touching routine works ONLY in a worktree it creates.** The prompt bakes this in at
   authoring time, not as an afterthought: `git worktree add <fresh self-created path>` (e.g.
   under `/tmp`, suffixed with `$$`), never an existing checkout, and it deletes ONLY what this
   run created. **Harness-managed worktrees and every standing checkout are live interactive
   sessions' working state — never touch, reset, rebase, or delete them.** A routine that names an
   existing worktree path in its procedure text is a defect at review time, before it ever runs.
2. **One-time tasks are a lifecycle, not a fire-and-forget.** A past-due one-time task still
   `enabled` is a repeat-fire hazard (runs on every app launch). At completion the task is
   DISABLED and its prompt replaced with a safe stub (verify-already-done → STOP; the original
   procedure preserved via its ticket). **Every routines reconcile sweep checks `enabled` on
   past-due one-time tasks** — the platform does not auto-disable reliably, so the sweep is the
   backstop.

## North Star — enduring goals that outlive a session

A **North Star** is a human-set, agent-immutable enduring goal that orients work across sessions and
threads — the *why we're doing all this* a worker checks its work against. Document type
**`northstar`**. Each engagement/vault declares its own; a worker consults the one that governs its
work.

**The immutability contract (the whole point).** A North Star is **SET BY A HUMAN and is
AGENT-IMMUTABLE.** Once `locked: true`, an agent MUST NOT change its statement, goals, or targets
without the human's **explicit in-session permission**. Agents may only **append** to its check-in log
and mark a goal *reached* (G2 append-only). If an agent believes a target is wrong, stale, or already
met, it **surfaces that to the human and waits** — it never edits a locked North Star. This is a harder
gate than G4 (draft→publish): a North Star is *published-and-locked*; changing it is a human act, always.

**The check-in contract.** Every worker thread, at orientation (session start, a resume command, or a
periodic cadence), reads the North Star(s) governing its engagement/vault and confirms its active work
**traces to one — or flags honestly that it doesn't.** Don't force a match: infrastructure work that
merely *serves* a goal is allowed to say so. Append a dated line to the North Star's check-in log. A
North Star with no recent check-ins is drifting — that is itself the signal to re-orient.

**Lifecycle.** `horizon: perpetual` (persists indefinitely — e.g. "reduce spending") or `until-goal`
(retires when met — e.g. "fund college"). Goals inside carry their own status; a met goal is marked done
by append, and the North Star is set `status: archived` when its until-goal goals are all met or the
human retires it. **Never delete — archive** (G2).

**Frontmatter (`northstar`):**
```yaml
type: northstar
locked: true                 # agent-immutable once set
set_by: <human>
set_date: <YYYY-MM-DD>
horizon: perpetual | until-goal
scope: <vault / engagement>
review_cadence: "per worker-thread orientation + quarterly"
```

**Home:** the instance lives in its domain's canonical place (e.g. a personal vault's finance North
Star lives with its finance notes); the vault's instruction file points to it so every session finds
it. Relation to the spine: a North Star sits at the Theme/Objective (strategy) layer of the artifact
spine (`core/AGENTS.md` → *Artifact placement*) — lighter than full OKR machinery, but the same "trace
work upward" intent (G9).

## Placement binds authoring and referencing

**A doc goes to its canonical home at BIRTH.** A requirements or spec doc drafted mid-flight — by
dictation or by an agent — is placed by its type, and *"it went where the dispatch pointed"* is not a
placement decision. **A hand-off, seed block or epic that RECORDS a doc's path is a routing act too:**
confirm the path is the artifact's canonical home before propagating it, because every copy of a
wrong path makes the move more expensive and the misplacement more authoritative. Measured: a redesign
spec was authored into the knowledge vault instead of the initiative repo, and its path was copied
into an epic and two hand-off blocks before a human caught it.

## A record's coverage ends at its LAST CITED EVENT, not at when it was WRITTEN

**"The record is recent" is not evidence that it is current.** A hand-off, status or summary is
written from a read of its sources, and that read finishes before the writing does. Anything that
arrives in the gap is absent from the record and *looks covered*, because the record's own timestamp
is newer than the event's. So recency is not a weaker form of currency — it actively **defeats** the
check a successor would otherwise run, which is to ask how old the record is.

**Measured:** a hand-off written *after* new messages had already landed on a source channel still
missed them. Nothing about the document looked wrong — it was hours old, thorough, and every item in
it was true.

⚠️ **The tell: a reader can date the RECORD but cannot date its COVERAGE.** Those are two different
timestamps — when the record was written, and the newest event it actually consumed — and only the
first one is visible. A record carrying just the first is unfalsifiable about what it missed, which
is why this survives review: there is nothing in it to catch.

| side | obligation |
|---|---|
| **author** | per source channel, cite the last event consumed — an id, a timestamp, a message ref. That citation is the **watermark**, and it is the only thing that makes the record's coverage falsifiable. |
| **consumer** | before acting on the record, re-read each source channel for the window **since that watermark** — not since the record's write time. A channel with no watermark is re-read in full for the plausible window, and the missing watermark is reported back to the author. |

**This is a third distinct cause in the hand-off family, and the other two cannot catch it.**
Staleness — the artifact moved while the record stood still — is defeated by the record being
recent. A dropped precondition — the record was incomplete at birth — is defeated by the record
being complete as far as it read. **A freshness check that asks only *"how old is this?"* passes
this case every time.**
