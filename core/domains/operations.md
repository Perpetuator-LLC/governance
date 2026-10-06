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

## A report's CLASSIFICATION is computed from the value the reader ACTS on

**A report that labels its rows must derive each label from the same value the reader's action
depends on.** If a row's action is *"lift this constraint"*, its label comes from what the constraint
actually blocks, not from the newest, largest or most striking related value. A label computed from a
different value is not a summary of the finding; it is **a different finding in the same row**, and
its label tells the reader to skip the real one.

**The test, for a report you did not write:** name the value the reader will act on, then name the
value the label was computed from. If they differ, the report can route a live finding into the
"no action" bucket, and it will do so on every run.

- **One row, one action.** When a row genuinely carries two facts with two actions, print two lines.
  A row that stands for both lets the cheaper action absorb the urgent one.
- **Why it survives:** such a report is usually informational, so it is always green, and every row
  is individually true. What is missing is the line that was never printed. Measured: a
  dependency-constraint report labelled each row by the newest version overall, usually a major jump,
  and so read as an optional migration. 13 of 15 such rows were in fact blocking a same-line patch
  release that had been available for about twelve days. A ticket opened about the ignored report
  copied the mislabel in as a finding; only re-deriving the values from the source exposed it.
- **Binds the report's AUTHOR.** The careful reader is the one who got captured, so "read reports
  carefully" does not help. Make the classification and the action share an input.
- **An actionable count excludes what a standing decision already settled.** A count meant to drive
  action (*liftable*, *outstanding*, *untriaged*) that includes items someone deliberately decided to
  keep never reaches zero, stops meaning "act now", and gets skimmed. Count decided items in their own
  bucket, store each decision as data the report reads (naming its ticket), and flag a decision whose
  subject has disappeared. Measured: once one deliberate pin moved into such a file, a nightly
  report's actionable count went to 0, and a non-zero meant something again.
- **Scope:** reports whose rows carry an action. A pure inventory that asks nothing of its reader has
  no action for a label to disagree with.
- **Sibling:** an instrument that inspects nothing must not read green. There the population is empty;
  here the population is right and its **description** is wrong.

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

**A credential the script holds is checked at the moment of USE, not only at its head.** Renewing a
perishable credential (a short-lived token, a login, a lease) at the head of the chain is necessary,
and not sufficient when the script then waits for a person: a run that sits at a prompt longer than
the credential lives reaches its next step with an expired token. Measured: a run held a token for
about 20 hours at a prompt, against an 18-hour lifetime, and the secret fetch after the prompt was
refused; that step's output was suppressed, so the refusal showed no error. Re-validate after every
wait, immediately before the call that needs it, and stop with the reason when it fails. Re-validate
the **same** identity: a script that quietly re-authenticates as whoever is available has swapped
principals. **Scope:** scripts that hold a time-limited credential across a human wait. A run that
finishes well inside the lifetime needs only the head check.

Mechanics: the script lives in the owning repo (committed BEFORE the human runs it); writes a
machine-readable progress artifact from the first seconds (a silent multi-minute script is a
hand-off defect — the human can't tell hung from working; measured: a migration script printed
nothing until done and the human asked whether it was hung); prints an explicit end-state summary;
the agent reads the artifact, never asks for the scrollback.

⚠️ **The terse form of the same defect is a step written as a NOUN PHRASE plus a citation.**
*"Store prerequisites (see comment N, step ①): the API keys, the limit value, the sample ids."*
passes every test above by accident — it sits under the human's section, it is numbered, it is
short — and **it is not a step, because nothing in it is a verb the human can type or click.** It
is the agent's index of two documents, compressed to one line by a message-length budget; the
human reads it as *"what needs to be done"* and asks *"what do you want ME to do?"*, which is the
entire cost of the rule paid again.

Four tests, applied to every line in the human's section **in the first message**, not on request:

1. **Does the line contain a VERB with an OBJECT the human can act on now** — a command in a
   fence, a menu path, a field and a value? A citation (a comment id, a step number, a document
   name) is never that object.
2. **If the line names a value the human must supply** — a key, an id, a secret — **does it say
   WHERE that value comes from** (which dashboard, which page), and **which of them are actually
   still missing**? A store the agent can read for key NAMES (never values) is read first; the
   human fills only what that read reported missing, never a list the agent assumed. This covers
   **every prompt the script will raise**, not only the values typed into the block. A prompt that
   asks for a credential which does not exist yet names where to create it and with which
   permissions. Measured: a script prompted for an admin token (hidden input) while the hand-off
   never said which token, where it is minted, or with what scope.
3. **A credential created only for this run is removed by the same hand-off.** Its last step
   revokes it: where, and how. The mirror: a credential meant to persist, such as a service token
   stored for later use, gets no revoke step. It gets a recorded expiry instead.
4. **Is every command where the reader's surface copies it in one action?** In chat that is a
   bare, top-level code block. Never put it inside a quotation, which renders without a copy control
   and drags its markers into a selection. On a surface that gives a copy control to only one block
   per heading marker, each step gets its own marker.

Sending the citation form is not concision. It moves the synthesis the rule exists to do back onto
the human, and it looks compliant while doing it.

**A precondition written in prose gates nothing.** A sentence above a command (*"only if the key
exists"*) is read after the command has run. Chain the check into the command, `check && change`, so a
failed check stops the change, and assert that the external resource exists, not only that a variable
is set. Derive the list of prompts a block will raise from the command's own flags, never from a
description of it. **When a hand-off broke a rule that already existed, the fix is a mechanical check
that would have flagged that hand-off, not a rewording:** restating a rule nobody read lengthens the
thing that went unread. A checker for hand-off text fails loudly on a block it cannot parse. **Where it
is wrong:** a check that cannot be scripted becomes two sittings with its result reported between them;
a read-only block needs no gate; and a rule that was read and misapplied because it is ambiguous is a
wording defect, where rewording is the fix.

### In a recipe, a number means ORDER and a bullet means INDEPENDENT

Number a step only when it needs the one before it to have finished. Steps a person can do in any
order, or at the same time (a second terminal, a click while a command runs), are bullets. Numbering
them tells the reader to wait for something they do not need to wait for.

**The mirror is just as wrong:** steps that must run in order, written as bullets, invite running one
early. The test before sending: *could step 2 start before step 1 ends?* Yes → bullets. No → numbers.

**Scope: steps only.** A number used as an identifier (a decision option answered by number, a ticket
or pull-request number) is not a step, and this rule does not touch it. Several separate asks follow
the same rule: bullets, unless one says it waits on another.

**Measured:** a hand-off numbered "1. type your password at the waiting prompt" and "2. in a second
terminal, run the key block". The second never needed the first, so the reader waited on a prompt
that was never in the way.

## An ask parked on a human names its GATE and what the answer CAUSES

**An ask an agent parks on a human through an asynchronous queue** — a ticket label, a dashboard row,
an inbox — **opens with three lines:**

```
<Human>: <what you need, in one plain sentence>
Why you: <the gate that makes this theirs>
After you answer: <what the answer causes, who acts next, and whether you still have to run anything>
```

- **`Why you` names a gate, or there is no ask.** A gate is a credential only that human holds, a
  physical presence check (a hardware key, a biometric), a go-ahead for something hard to undo
  (production, a merge, a delete), money, a legal act, or a direction call that belongs to the owner.
  If none applies, the agent decides, acts and reports.
- **`After you answer` separates a DECISION from a TASK.** For a decision, the answer is the trigger:
  the agent acts on it. For a task, the answer runs nothing, and the human still performs a step. Say
  which one it is, because the human cannot tell from the question.
- **A choice with one sane option is a STEP, not a decision.** If the other option only breaks
  something, hand over the command instead. A decision table is for choices where either answer is
  acceptable.

**Scope.** This binds asks the agent *initiates and parks*, which the human reads later and out of
context. It does not bind a live exchange where the human asked the question: the gate and the
consequence are already on screen, and three extra lines are noise. It depends on one property: the
answer is recorded and handed back to an agent, with no one watching, which is why what happens next
must be written down. Where the human answers and then acts in the same place, `After you answer`
collapses to one line and stays useful.

**The mirror, which `Why you` also guards:** the rule says when to ask, and the opposite failure is an
agent that stops asking and acts on something gated. An ask with no gate is dropped; a gated act is
still asked.

**Measured:** a parked ask offered two options, one of which would have repeated a known outage. The
human picked the safe one, and the answer ran nothing: the step needed the human's own server password,
and the ticket went back to an agent that could not run it. The human then asked exactly the questions
the three lines answer: *what happens with my decision, and why was I needed?*

**Run every precondition an agent can run before the ask is parked.** A hand-off that records the
human's verb and drops the condition that gated it (*"file it upstream"*, without *"once you have
checked whether a newer version fixes it"*) parks work an agent could have done. Name the precondition
and its owner, and if an agent can run it, run it first. On a re-raise, read the source, not the
record: a record that has been re-parked twice is evidence about the record. **Where it is wrong:**
when the precondition is itself gated (a secret, production), the ask is ripe as it stands; name both
gates.

## A lane that serves people runs AHEAD of them, not behind them

**Scope:** any agent lane whose people (a team, or clients) need its approvals, reviews, answers,
access or next task in order to make progress. The rule is about their waiting, not the agent's own
idleness.

**After every intake of new messages, and before reporting, ask for each person:**
1. **Are they waiting on us?**
2. **Are they out of work, or about to be?**
3. **What will they need next, and have we TESTED that it exists?** That covers access that works,
   code that is merged, and a command that runs. Believing it exists does not count.
4. **Will what we told them work against the live system?**

Act on every yes in the same pass. Where a decision is someone else's to make, hand it to them as a
one-word answer with a recommendation.

**Limits: the neighbouring cases where "proactive" goes wrong.**
- **Enable; do not do their deliverable.** Running ahead means their next step is ready. It does not
  mean you take the step for them.
- **A check-in carries something concrete, never an empty ping.** Send it on the channel, and at the
  cadence, the person chose. Where they set neither, send nothing that has no content.
- **Clients get results, not promises.**
- **Test with your own access or a read-only probe, never with the person's credential.** Signing in
  as someone to check their access is impersonation, not a test.
- **A principal's decisions stay the principal's.**

**The miss loop.** Anyone who waited more than one cycle, or a client who had to chase first, is a
**miss**. Log it, and send it to whoever owns the lane's routines. A miss that recurs is a defect in
the routine. The fix is a change to the routine, not more effort in the next pass.

## Shine a light on a near miss: name the adjustment that would make it work

**Scope:** any analysis, test or build that turns up something *almost* valuable. That means a
strategy, signal, design or result that fails by a margin one specific adjustment might close, or an
adjacent opportunity the request did not ask about but the evidence points at. The sibling rule above
is about people waiting on us. This one is about what the work lets us see.

**Rule: say so in the same report, unasked.** State four things:
1. **What** is close.
2. **How close:** the measured gap, in the work's own units.
3. **The adjustment** that might close it.
4. **The cheapest test** that would show whether it does.

Offer it as a one-word decision ("test it?"). A pass/fail verdict hides a near miss: "no" reads the
same whether a result missed by a mile or by a hair. The person cannot ask for what they do not know
exists.

**Limits: where shining the light goes wrong.**
- **Surface, do not pursue.** Beyond a cheap, reversible probe, the follow-up is the person's call.
  The light is a pointer, not a project you started on their behalf.
- **Evidence, not hunches.** A light names a measured gap and a concrete adjustment. "This might be
  interesting" is noise. Too many lights and none of them gets read.
- **A pre-registered test stays honest.** An adjustment found after seeing the result is a NEW
  hypothesis. It must be tested on data it has not seen (held out, out of sample, or forward), never
  used to rescue the old verdict. Re-running until something passes is how false edges are made.
- **In a decision-support role it proposes a test, never an action.** It names what to examine next;
  the decision to act stays with the principal.
- **The mirror counts.** A risk, falsifier or failure mode that is close to firing is also a near
  miss, and gets the same four lines.

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
- **A reference to another repository is fully qualified, everywhere, titles included.** A bare `#N`
  resolves against the repository it is written in, so a cross-repository reference written bare
  points at an unrelated item; a pull request's title becomes the merge commit's subject, which the
  forge scans too. Write `owner/repo#N`, and make a link's visible text name the same repository as
  its target. A reviewer treats a bare number that does not exist here, or does not match its wording,
  as a defect, fixed by a retitle rather than a re-push. A rolling pull request's number maps to
  different content over time, so a reference to one carries its subject line or a commit hash.
  Same-repository references stay short.
- **An ordinal written as `#N` is reworded, never qualified.** *"Power loss #3"* or *"item #2"* is not
  a reference, but the forge links it to item 3 or 2 of the repository it sits in, and re-notifies
  that item on every mention. Qualifying it makes a correct link to the wrong thing; write *"no. 3"*
  or *"item 2"* instead. And a `#N` straight after a slash (`ADR-002/#16`, `#229/#239`) still links,
  so a scan for bare references must not skip it.

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

## A decision is made only when it lands in the field its consumers read

**A triage, re-prioritisation, retirement or change of direction recorded only in a comment, summary
or report, while the label, status field, registry row or title that downstream readers query still
says the old thing, has not been made.** Consumers read the field, not the thread. Measured: a
complete triage classified nine tickets as mislabelled, with a rationale for each, and changed
nothing: a day later all nine still carried the old priority, a migration gate was computed from the
old labels, and every "list the queue and work it" reader followed the labels.

- **Execute in the same act as recording:** move the labels, edit the field, update the row. Then
  verify by re-running the **consumer's own query** after the writes, not by re-reading your comment.
- **The comment is the rationale, never the mechanism.**
- **A title is prose.** A priority or status written into a title is invisible to every label-keyed
  query, so it has not been set. When a title and a label both carry one and disagree, nothing
  reconciles them. Exactly one field is authoritative; remove the other mentions rather than keeping
  them in sync. Measured: an epic titled as top priority sat for ten days with an empty label set,
  invisible to the intake query built to find it. Where a tracker has no label vocabulary at all, the
  title is the only channel, and then the query must parse it.
- **The consumer's half: derive state from the field, never from matching prose.** A dashboard that
  judged a pull request merge-ready by finding a word in a comment missed the one whose comment used
  other words. Read the state the API holds (the run's jobs, the label) instead.
- **Where two registries share a word with different vocabularies, name the enum at the schema.** A
  value that is meaningful in prose but absent from the enum consumers string-match is a silent miss:
  a status written in one registry's vocabulary into another registry's field makes the row invisible
  to every sweep that matches the correct values.

- **A decision that names a cadence is recorded only when its routine exists.** *"Weekly"*, *"after
  every import"* or *"each Monday"* is incomplete until the scheduled task, cron entry or hook that
  fires it exists, or, where arming is gated, the ticket that arms it is opened in the same turn and
  linked from the decision. Review rejects a cadence with no routine, as it rejects a decision with no
  owner. A decision to **stop** a cadence removes the routine in the same turn. **Where it is wrong:** a
  one-time decision, whose follow-through is a ticket, not a routine.

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

## Fixing an instance of a class: check your own diff against the class first

**Working on a defect class does not protect you from committing it, and may be when you are least
protected**, because attention is on the instance and the class is one level up. Measured: four
sessions in one day, unaware of each other, each reproduced the defect they were fixing, for example
a fix for a dead hard-coded path that introduced a new hard-coded path. Three were caught by their
authors, one only by luck.

- **Before committing, name the class in one sentence, then grep your own diff for it**, as an act,
  not an intention. This is the route-before-write reflex pointed at the diff instead of at the canon.
- **Where a working precedent exists in the repository, open it.** A precedent is a control; your own
  draft is not.

## Reproduce a bug before fixing it, on the current code, and record it on the ticket

**A bug ticket describes the code as it was when it was filed.** Where several lanes land changes in
parallel, a reported defect is often already gone, removed as a side effect of another fix. A fix
written against the report then fixes nothing, or solves a solved problem a second time in a shape
that conflicts with the first.

**Before writing a fix, reproduce the report on the current default branch** (or on the deployed
build it was reported against) **and record on the ticket:** the steps or command, observed versus
expected, and the commit it ran against.
- **It reproduces** → that reproduction becomes the fix's first failing test.
- **It does not reproduce** → find the change that removed it (search the history between the ticket's
  commit and now), and close the ticket citing that change.
- **It does not reproduce, and no removing change can be found** → do not close it as fixed. Record
  what was tried, under which conditions, and hand it back to the reporter as *not reproduced*. A
  failure you can no longer see, and cannot explain, is not a fix.

**Scope: bug tickets**, meaning a claim that existing behaviour is wrong. Feature work and docs have
nothing to reproduce. **Two mirrors:**
- **An intermittent failure is not gone after one clean run.** Match the report's conditions and
  frequency before calling it absent (`technical.md` → *A single red is a HYPOTHESIS, not a baseline*).
- **The reproduction must not cause the harm.** A bug seen only on production data, or a security
  flaw, is reproduced against a copy or a local instance, never by exercising it on the live system.

**Observed:** the human reported, several times, a seat starting work on a bug that another change had
already fixed.

**Re-measure a diagnosis through the code that will act on it.** A cause table built by re-parsing
the data with a different tool can name a cause the acting code already neutralises (whitespace its
matcher strips, say), and a fix for that cause changes nothing. Before building it, re-run the
measurement through the acting code's own parsing and re-derive the causes from its output. **Where
it is wrong:** a diagnosis that already came from the acting tool's report. This diagnoses *inputs*
through the actor; confirming an *outcome* is the opposite, and needs a check independent of the
actor (technical.md → *A checker that FIRES is not a checker that is RIGHT*).

## "Verified" for a user-visible outcome means OBSERVED on the user's surface

**A done-claim of the form *forge + git + CI agree* proves that code landed.** It says nothing about
an outcome that lives where a person looks: a dashboard, a rendered page, a message. Observed: a
coordinator confirmed a receipt existed and told the user *"fixed, reload"*; the user reloaded and the
thing was not there. In the same exchange the implementer had changed **what** was asked, on its own
measurement, and the coordinator accepted the change without asking the user.

1. **"Verified" for a user-visible outcome means observed on the user's surface, by someone other
   than the party claiming it**: a read of what renders, a screenshot, or the user's own
   confirmation. Say which surface and how. Not observed ⇒ the claim is **"landed, not seen"**,
   never *"fixed"*.
2. **A done-when for a user-facing fix names the user's surface and what will be observed there.**
   Prefer an observation an agent can take, a committed command that reads what renders
   (`technical.md` → *A done-when names the COMMITTED SURFACE*); the user's confirmation is the
   fallback, not the plan.
3. **A change to WHAT was asked, not how, goes to the user as a decision**, with the implementer's
   reason attached. A peer or a coordinator never accepts it on the user's behalf. An ask the user has
   already repeated raises the bar further: the repetition is the evidence that the scope mattered.

**Scope: outcomes whose purpose is to be seen or used by a person.** Internal artifacts with no user
surface (a library function, a migration, a CI gate) are out of scope: for them, forge + git + CI *is*
the surface. **Two boundaries:**
- **The user's surface is unreachable by any agent** (a device only the user holds). Rule 1 read
  literally would block forever. Do not block: report *"landed, not seen on your surface"* and name the
  one observation the user can make.
- **Rule 3 cuts both ways.** Narrowing an ask and widening it are both changes to what was asked. A
  change to *how* (the approach, the tool, the order of work) stays the implementer's call.

## Declare a cross-repository dependency as a LABEL the sequencer reads, not as prose

When work in one repository cannot land before work in another, record it where a scheduler looks: a
label, not a sentence in a comment. An orchestrator sequences many lanes by filtering, and a dependency
stated in a ticket's fifth comment is invisible to a filter. The same fact as a label is one query.
Two meanings cover it (shown in scoped-label form):

| label | means | set by | cleared |
|---|---|---|---|
| `Status/Blocked` on a ticket | work cannot start until the linked ticket lands | the lane that learns of the dependency, the moment it learns it, with the blocking ticket linked | as part of landing the blocker, or by a check that reads the link and sees it closed |
| `Compat/Breaking` on a change | deploying this change alone breaks a partner; the named partner repository lands first (for example, a frontend that reads a field its backend does not serve yet) | the change's author, before review | never: it records a property of that change and gates the deploy order |

**The mirror: a stale `Blocked` label is its own outage.** Set and never cleared, it parks a lane on
work that is already free, and nothing about the label looks wrong. That is why the label must name its
blocker, and why clearing it belongs to landing the blocker.

**Scope:** dependencies between repositories or lanes. Inside one repository, branch order already
sequences the work. It depends on something reading the labels to sequence; where nothing does, they are
still the most compact statement of the dependency, but they gate nothing.

## A search that returns ZERO before you create is evidence about the QUERY

**Before concluding "nothing exists yet, so I'll file one", corroborate a zero from a keyword search.**
A tokenised index misses on singular and plural, hyphenation, compounding and words the author never
used, and it misses silently: a zero from a near-miss query looks exactly like a zero from an empty
repository. Measured twice in one week: one search returned 0 because the matching ticket's title used
the plural; another returned 0 for a ticket filed a minute earlier whose title did not contain the word.

- **Corroborate on a different surface, not the same index twice.** A second query through the same
  tokeniser is the first check run again. Use a form that differs in the way the index could have
  failed, or leave the index: list the newest items unfiltered and read them. For a topic someone may
  have just split out, the newest list is the check and the keyword search only a supplement.
- **Prove the search is healthy in the same pass:** an absurd token returns 0, and a known term returns
  its known matches. Without that, a zero can also mean the filter was ignored.
- **A tracker's default listing hides closed items.** Surveying a project you do not control, set the
  state filter explicitly and sweep issues and pull requests, closed included, before reading its
  documents: the measured corpus (numbers, environments, reproductions) often lives only there, and
  the docs are the curated subset. A closed item may be closed because it was wrong, so read its status
  and provenance; the rule widens the candidates, it does not raise their weight.
- **Scope:** keyword or full-text search used as the precondition for *creating* something
  (route-before-create, dedupe by goal). A lookup by a durable identifier (an id, a commit hash, a
  ticket number) is exempt: there, a zero does mean absent.

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

**A recurring routine checks, at the start of each pass, that its report target is still open, and
fails loudly when it is not.** A routine that comments its findings on a fixed ticket outlives that
ticket: once it closes, every pass files into a closed thread that nobody reads, and the routine
reports success. Point it at a standing ticket that exists for the routine's reports, not at a defect
ticket that closes when its fix lands; or have each pass file its own. **Where it is wrong:** a
routine that only writes its own artifact (a log, a page) and reports to no ticket has no target to
lose.

## A context reset releases nothing — walk what the session holds before it

Clearing or compacting an agent's context in place keeps the seat and destroys its memory. Every
hold that lives **outside** the context — a timer, a pinned model, a worktree, an uncommitted file,
a task queued in the harness — survives the reset **with no one left who knows it exists**, and the
reset reports nothing. So before a reset, **enumerate the holds by class and record each result,
including the empty ones**. A generic "release your resources" catches only the holds that announce
themselves, which are the ones that never needed the rule.

- **List the classes that stay silent:** armed timers and self-scheduled wake-ups; resident model
  pins; "building" claims in a resource registry; worktrees and locks; a staged index; commits that
  exist only on this machine; and **items queued in the harness's own interface — a suggested
  follow-up task waiting for the human to click it.** No tool lists those back, and a reset can drop
  them without an error.
- **For each hold: finish it, withdraw it, or carry it** into the continuation record — verbatim for
  a queued task (its title and full prompt), because that record is the only thing the next context
  reads.
- **Release and hand over are different verbs.** A hold meant to outlive the reset is declared, not
  released: what it is, why it runs, how to see it, how to stop it.
- **Scope:** holds this session created. Another session's or the human's items are named, never
  withdrawn. A harness that demonstrably keeps a queue across the reset needs no walk for that queue;
  prove that once, on that harness, and record it. **Handing off to a NEW session loses the same
  holds more slowly** — the old context survives, but nobody reads it — so the walk runs there too.

**The record is dated; the work does not stop at the date.** A continuation record describes the
session at the moment it was written, and a session that keeps working until the reset leaves that
later work only in its activity log. So the successor's half of the walk is to **read the
predecessor's activity after the record's newest stamp**, sorted by time.

- **What that tail created or touched is the successor's own**: a worktree, a branch, a half-written
  file, a promise made on a ticket. Finish it or carry it.
- **What the tail did not touch stays unattributed** until its content says whose it is. *Newer than
  the record* is not ownership wherever other writers share the checkout: another agent, a reviewer,
  the human. Claiming it by timestamp is how one seat commits another's work in progress.
- **The predecessor still writes the record last**, or appends a dated update for anything done
  after it. The successor's read is the backstop, and it can only attribute what the log visibly
  touched.
- **Scope:** this needs a readable log of the predecessor's actions. Where the harness keeps none,
  the record is all there is, and writing it last stops being a courtesy and becomes the only
  control.

**Distil, do not dump.** The record a successor reads holds the reduced fact (what is true, what to
do) with a one-way link to the raw source, never the raw source pasted in. The raw material is for
finding things; the record is what gets acted on. Never edit the source to link back to the record.
**Where it is wrong:** text the reader must act on word for word (an agreed term, a signed clause)
belongs in the record verbatim, not behind a link.

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

## A procedure document holds its WHOLE current flow — a delta version forks the identifier

**One state, one file.** A procedure — an SOP, a runbook, a playbook — is a document that someone
follows end to end, so it carries the whole flow as it stands today. **A version that records only
what CHANGED is not a shorter procedure; it is a second document wearing the same name.** The
reader who finds it follows half a flow and has no way to know which half is missing, because a
delta is silent about everything it did not touch.

This is worse than ordinary duplication. Two full copies disagree visibly — a reader who opens both
can see the conflict. A full copy and a delta look *complementary*, so a reader who opens both still
cannot assemble the procedure without knowing which is authoritative and what order they compose in,
and a reader who opens only one gets no signal at all.

⚠️ **On a shared identifier, FOLD — do not reconcile and do not keep both.** When two documents
claim the same procedure id, the answer is one document containing the current flow, not a pointer
between them and not a merge note explaining their relationship. **The identifier is what consumers
resolve**, so two files answering to it means the id no longer names a single thing, which is the
defect regardless of how good either file is.

Corrections to a procedure are edits to it. The history of *why* it changed belongs in the version
control or the decision record, never in a sibling document the follower might land on instead.

## Placement binds authoring and referencing

**A doc goes to its canonical home at BIRTH.** A requirements or spec doc drafted mid-flight — by
dictation or by an agent — is placed by its type, and *"it went where the dispatch pointed"* is not a
placement decision. **A hand-off, seed block or epic that RECORDS a doc's path is a routing act too:**
confirm the path is the artifact's canonical home before propagating it, because every copy of a
wrong path makes the move more expensive and the misplacement more authoritative. Measured: a redesign
spec was authored into the knowledge vault instead of the initiative repo, and its path was copied
into an epic and two hand-off blocks before a human caught it.

## An id used as a resolution key is validated like one

**Once documents are cited by id rather than by path, the id must be unique, and it must be the kind
of value a generator produces, not one a person might re-type differently.** A check beside the
frontmatter lint asserts, per document: the frontmatter parses; the id is present; it parses as a
generated id (a UUID, say) or matches a namespace the schema's owner has declared for readable ids; it
is unique across the scanned roots; and it equals no other field in the same document. Run it on the
working tree, not only on committed state. Measured: one store held eleven ids that looked like UUIDs
and parsed as nothing, and one whose id was another record's identifier, so a lookup returned the
wrong document. **Where it is wrong:** a store that cites by path needs none of this, and readable ids
in a declared namespace are deliberate: a naive *"must be a UUID"* rule floods with false positives and
gets switched off.

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

### A drafted message is a record too: re-read the thread immediately before sending

A draft covers its thread only up to the last message its author read, which is its watermark.
Approval takes time, and the recipient keeps writing meanwhile. So an approved draft can be the most
carefully checked message in the thread and still answer a conversation that has moved on.

**Immediately before sending any message that was not composed in the same read** (a human-approved
draft, a queued reply, a scheduled send), re-read the recipient's thread since the draft's watermark:
- **nothing new** → send as drafted;
- **new messages** → bring the draft to the current state *within the approved intent*. Anything the
  rewrite adds beyond that intent — a new commitment, a new ask, a changed number — goes back to the
  approver.

**Scope: two mirrors the vivid case hides.**
- **The message may no longer be needed.** The recipient may have answered or withdrawn their own
  question. Check whether to send at all, not only whether the wording is current.
- **An approved EXACT wording is not rewritten in place.** A notice, a quote, a contract term or
  anything signed was approved as text, not as intent. New information becomes a follow-up, or goes
  back to the approver; it is never a silent edit of the approved words.

**Measured:** a reply was approved about an hour and a half after it was drafted. The re-read at send
time found two new messages from the recipient: one reported that what the draft promised to do had
already happened, and one added two new asks. One of the draft's four lines was stale, and both new
asks would have gone unanswered.

**A finding carries its as-of time and the inputs it compared** (the revision, the commit, the query),
**and its consumer re-verifies it before relaying it**, saying which findings still hold and which
were resolved since. A finding carried forward keeps its stamp or is dropped. **Where it is wrong:**
*fine now* does not prove the detector was wrong then, and a finding of irreversible harm is relayed
first and verified after.

## A retirement falsifies every CLAIM that names the thing, and none of the RECORDS

When something is retired, renamed or moved — a repository, a service, a home for a class of
document — the sentences that mention it split into two kinds, and **they need opposite treatment**:

| | what it is | what to do |
|---|---|---|
| **Claim** | asserts a present fact: *canonical home*, *distributed from*, *lives at*, an owner, a path | now **false** — correct it |
| **Record** | reports a past event: a dated measurement, a ticket reference, an exhibit narrative | still **true** — leave it (history is append-only) |

**Both failure modes are one command away.** A global find-and-replace rewrites the records, so a
measurement taken against the old thing now claims to have been taken against the new one — history
quietly falsified, which is the more expensive error because nothing will ever flag it. Leaving
everything alone is the other half: the false pointers stay, and each one routes the next reader to
a dead target with the authority of a canonical path.

**The per-occurrence test is tense, not keyword.** *Does this sentence assert something about now,
or report something that happened?* Present tense plus a location, owner or home is a claim. A date,
an identifier, or a measurement is a record. The same token appears in both, which is exactly why a
textual sweep cannot make this call.

**Measured.** After a governance repository was retired and archived, seven `Canonical:` footers and
one frontmatter `canonical_home:` field still named it as the live home for documents that had moved,
while fifteen other mentions in the same tree were dated measurements and issue links that had to
survive untouched. ⚠️ **The first pass corrected six of the seven.** The last was found only by
re-running the search afterwards **as an assertion** rather than trusting the edit — which is the
general obligation this rule inherits: *after any sweep, re-run the detector and require a zero,
then confirm the detector still fires on a planted positive.*

### A retirement DECLARED as data is only as strong as the reader that never opens it

The table above is about prose. **When a retirement is recorded as data** — a retired-list, a deny
list, a deprecation map — rather than by deleting the thing, the records that name it usually survive
on purpose, so whoever holds one can still close it out. **Every reader of those records must then
consult the declaration**, or it goes on resolving the retired entry, correctly, indefinitely.

⚠️ **The reader that matters most is the one that speaks FIRST and most imperatively** — a start-up
hook, a default, an auto-selector — because it is the one that gets obeyed. **Measured:** a registry
of agent seats kept each retired seat's working directory by design. Three readers honoured a separate
retired-list. The fourth, the hook that tells a freshly cleared session what to run, did not — and
told it, in wording written to suppress hesitation, to boot the retired lane. The lookup was right.
It was simply the only reader nobody had told.

**So adding a declaration means enumerating every reader of the records it qualifies, and gating
each** — preferably through one resolver they all call (`technical.md` → *An invariant with more than
one SOURCE is answered by ONE choke-point function*), because a list with N independent readers is N
places to forget it.

- **The mirror: what a declaration ADDS fails the same way, only quieter.** A new entry some reader
  does not know about usually fails as a *non-event* — nothing resolves, nothing is printed — which
  is harder to notice than a wrong answer.
- **Scope — the reader whose JOB is the retired structure is the exception.** A migration or cut-over
  script that must copy out of the old place is supposed to read it; gating it "fixes" it into a bug.
  Ask whether the reader **routes live work** (gate it) or **moves state out of** the retired thing
  (leave it).
- **The property this depends on is records that outlive the retirement.** Where retiring deletes
  them, no reader can find the entry — and nothing can close it out either, which is usually why they
  were kept.

### The mirror: a RESOLUTION falsifies a claim just as a retirement does

A retirement falsifies a claim because the thing it names is gone. **A resolution falsifies one
because the thing it was WAITING FOR happened** — and this half is harder, because nothing about the
sentence changes and nothing about the event points back at it.

> *"X needs republication — see the open questions in <handoff>."*

Every word of that is stable. It reads exactly as it did the day it was written. The artefact it
describes has since been republished, the journal records the republication, and **the sentence sits
in a resident instruction file that every session loads.** Measured: such a line stood for seven
weeks after the condition closed, and the closure was recorded *later in the same document* the line
points at.

**A claim with a pending condition is a claim with an expiry, and nothing fires when it expires.**
So write it so the expiry is detectable:

- **Name the artefact and the field that will settle it** — *"until `status: published`"* — so the
  claim can be checked mechanically against the thing rather than re-read for plausibility.
- **Closing a condition includes finding who was waiting on it.** The work is not the status change;
  it is the sweep for sentences that named it. A resolution that updates only the artefact leaves
  every pointer to it lying.
- **Prefer pointing at the artefact over restating its state.** A pointer stays true as the artefact
  moves; a restatement is a copy that has to be maintained, and copies are what go stale.

