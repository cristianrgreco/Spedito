# Pilot loop handoff

- **Date:** 21 August 2026
- **Branch:** `pilot` (31 commits ahead of `main`, tree clean)
- **Harness:** `Tests/SpeditoAppTests/Pilot/`, runner `scripts/pilot.sh`
- **Design rationale:** `docs/architecture/pilot.md`

Read `docs/architecture/pilot.md` first for why this layer exists. This document
covers only what a continuing agent needs to pick the loop up.

## Where the loop is

Thirteen live runs. Only runs 8 onwards can be trusted; everything before was
reported by a harness watching an application it had already closed.

**Run 21 (`vague-dashboard`) is the run to read.** It started from the vaguest
request the catalog has — "I want a dashboard." — and finished with **zero
findings**:

- eight clarification questions over three rounds, then a four-ticket plan with a
  research ticket and a real dependency graph;
- a network permission the owner **refused**, which delivery survived;
- a quit and reopen mid-delivery;
- **all four tickets released**, every one of them through a correction cycle —
  nine candidates and eight corrections, T3 needing three;
- an app version opened, a retrospective action accepted, the retrospective
  concluded, the sprint `completed`.

Eight corrections in one sprint is the measure of what changed today: before
this session a **single** correction cycle ended a run, every time.

**Run 20 (`library-csv`) was the first whole owner journey**, and **run 18
(`web-reading-list`) the first whole sprint.** T1 and T2 each went v1 → changes requested → **v2 accepted**, T3
was accepted first time, and the sprint reached `completed`. It also ran the
mid-sprint scope change: the owner asked for search while delivery was live, and
two tickets landed in the backlog with correct dependency provenance.

That took **three delivery defects** to reach, all in the same unreviewed corner
of the code, all found and fixed here. The section below is the record.

Earlier milestones worth keeping: run 13 took a native Mac app to a real
`mac_application` demo and released it; run 15 proved the first settlement fix
with candidates v1 → v2 → v3.

**Four consecutive runs then finished clean, across four different products:**

| Run | Brief | Outcome |
| --- | --- | --- |
| 20 | `library-csv` | first whole journey; retrospective reached |
| 21 | `vague-dashboard` | 4 tickets, 8 correction cycles, refused permission, **0 findings** |
| 23 | `native-timer` | 3 tickets, app version, retrospective, **0 findings** |
| 24 | `static-weather` | 4 tickets, mid-sprint scope change, app version, **0 findings** |

Between them they exercise planning and clarification, suggestion review, sprint
planning, parallel delivery, dependency graphs, research tickets, tech lead
review and correction, permissions allowed, **refused** and policy-denied, demos,
acceptance, release, relaunch recovery mid-delivery, mid-sprint scope change, app
versions, and retrospectives.

Nine delivery and harness defects were fixed to get here, each with a regression
test verified to fail without it. The three delivery ones are in the section
below; the rest are in the commit log.

**The one journey still unexercised is repository import**, and it needs the
product owner — see below.

## What to do first

1. **Keep running briefs.** Delivery is no longer the blocker.

2. **`import-repository` needs the product owner, and cannot be worked around.**
   `PublicGitRepositoryURL` accepts only a public `https` host and explicitly
   rejects localhost and private addresses, which is the right boundary. So a
   locally created fixture repository cannot stand in for one, and guessing a
   third-party repository would clone something the owner never chose. Ask them
   for one and set `SPEDITO_PILOT_REPO`. Until then R01–R07 stay unexercised,
   and that is a limit of the harness, not a defect.
2. **Run the briefs nobody has run:** `script-log-summary`, `library-csv`,
   `web-reading-list`, `vague-dashboard`, `static-weather`, `native-timer`. Each
   exercises a `DemoPresentationKind` or a feature never reached, and the product
   owner has asked for breadth. The journal now records the kind each run
   actually reached, so the coverage claim will be evidence rather than intent.
3. **Still untouched by any run:** retrospectives, app versions, repository
   import, and the mid-sprint scope change that `web-reading-list` and
   `static-weather` carry.

## Confirmed working this session

All three fixes that were unverified in the last handoff were exercised live.

**Coherent-capability guidance (`9f67a88`) works.** Run 12 asked the owner for
five separate paths in two minutes. Run 13 made **exactly one** permission
request in the whole run:

```
Read /Applications/Xcode.app
Read /Library/Developer/PrivateFrameworks
reason: Run Quick Notes' Xcode 26.5 build and macOS unit tests; xcodebuild's
        required simulator plug-in was blocked from loading Apple's
        CoreSimulator framework.
```

One batched request, two coherent paths, and a diagnosis the owner can actually
judge. This closes the escalation problem, and it confirms the last session's
conclusion that no new consent mechanism was needed.

**Recovery runs once per product (`8fd8784`) holds.** Run 13's database has
exactly two `agent_run.queued` events, both reading "App stopped; preserved work
queued to continue" at the relaunch, which is the relaunch working. Zero
recovery requeues, against 64 in run 10.

**The turn-wait fix (`c04bdb5`) was real but partial.** It explains run 12's T1
exactly. It never explained T2 in either run, because no owner decision was
involved — which is what led to the fix below.

## The resume-after-review hang — two causes, both fixed

**The changes-requested path had no test coverage at all**, which is why two
separate defects lived in it and why every run that reached a tech lead review
requesting changes stopped there. `failedRevisionReachesTheProductOwner` is the
first test to drive it.

### Cause one: the revision was discarded (`ab4a244`, confirmed live)

**Confirmed working in run 15**, whose T1 recorded candidates **v1 → v2 → v3**
and was released. Before the fix v2 could not exist.

**Cause found and fixed in `ab4a244`.** Three delivery turns across runs 12, 13
and 14 finished their work and were never recorded. Every one was the turn that
resumes a ticket after the tech lead requests changes; no turn of any other kind
ever hung.

A run's **settlement identity** — `settlement_operation_id` and
`settlement_candidate_version` on `agent_runs` — is an idempotency token for one
delivery attempt. It is what stops a run recovered after a restart from settling
a second candidate for work it already settled:
`prepareCompletedDeliverySettlement` hands back the existing candidate so the
caller returns without settling twice.

**Nothing released it when a run was resumed to apply review feedback.** That
resumed run is a new attempt, but it still carried the identity of the candidate
the tech lead had just rejected. Preparing its settlement found that candidate,
reported it as already settled, and the caller returned. The revision was
dropped in silence and the run stayed `running` with nothing left to move it.

Resuming after requested changes now releases the identity, so the revision
settles as the next candidate version. Recovery is untouched — it is the same
attempt and must keep its identity. Covered by
`resumedDeliverySettlesANewCandidateVersion`, verified to fail without the fix by
reproducing the mechanism exactly: the resumed run reports version 1 and hands
back the rejected candidate.

### Cause two: a revision that never validates was dropped (`c3b35d2`)

Run 15 proved cause one and exposed cause two in the same run. Its T2 returned
three results that would not validate, exhausted the repair attempts, and
stopped dead in the same owner-visible way.

The revision runs inside the review flow, and that flow's failure handler drops
any failure whose candidate has stopped awaiting a review outcome — deliberately,
because another task may have carried the candidate through and tearing it down
then would fail an accepted candidate. But **requesting changes is itself what
moves the candidate on**, so a revision failure always looked stale and was
always discarded, leaving the run `running` with nothing to move it.

A failed revision now leaves the run `awaitingOwner` with a comment saying what
stopped and how to retry, which is what the review flow already does for its own
failures.

### Cause three: the same defect on the demo-correction path (`5fd10d7`)

Run 17 hung the same way again, and its evidence named a path that had not been
fixed. Its tech lead **approved** the candidate; the managed demo then failed
verification, which queues a correction for the implementer. That is a second
delivery attempt exactly like a requested change, and it left the settlement
identity in place — so the correction was discarded, same as cause one.

The two are now one durable operation. `requestCandidateChanges` marks the
candidate and releases the run's identity in a single transaction, because they
are a single decision: this candidate is superseded, so whatever the run
delivers next is a new version. Both call sites use it and a third cannot forget
the half that matters.

**Two hypotheses were wrong on the way here and both cost time.** The inactivity
timer and the turn wait were investigated at length and neither was involved.
The thing that named the path was three rows of `activity_events` — "Demo
verification failed; correction queued" — which had been available from the
first minute.

**A live database copy nearly produced a fourth wrong conclusion.** Copied
mid-write, it suggested the tech lead fix had not run; the properly captured
bundle showed the tech lead had never been involved. The trap below is not
theoretical.

### A correction worth reading before you trust anything else here

`83686d8`, committed earlier the same day against this symptom, **is not the
fix.** It requires durable evidence that the owner owes a decision before a turn
may suspend its inactivity timeout, on the reasoning that a transient client
flag was outranking durable state. That reasoning is sound and the guarantee is
worth keeping — a leaked approval flag would otherwise hang a turn forever — but
it was built on a wrong diagnosis, and run 14 disproved it in the field: the
turn hung with the fix in the binary and sailed past its 900-second window
untouched. **The wait was never what hung.** The result had already come back.

Two lessons, both of which this loop has now learned twice:

- A hypothesis that explains the evidence is not the same as the cause. The
  approval-flag theory explained every observation available at the time and was
  still wrong.
- The thing that finally identified it was not reasoning. It was reading two
  columns in the database of a finished run.

### How it was found, in case the next one looks similar

- The Codex rollouts showed **two back-to-back completed turns** on the hung
  thread — a revision turn and a validation repair turn — and then nothing. That
  ruled out the agent and ruled out the wait.
- `agent_runs` for the hung run had `settlement_operation_id` populated and
  `settlement_candidate_version = 1`, on a run whose candidate had already been
  reviewed and rejected. Two columns, and the mechanism was visible.
- No error banner ever appeared in any run, which is what said the code was
  returning cleanly rather than failing.

## Also fixed this session

Harness only — no application code changed, so no relaunch was required.

**The relaunch was not a cold start** (`64cdd30`). `simulateRelaunch` carried
the `ProductStoreRegistry` across, so the reopened application inherited the
same open SQLite connections, prepared statements, and transaction state. State
that survived only because a connection never closed would have passed a
relaunch check — the direction that is hardest to notice. Quitting now closes
the stores, because the process ending is what closes them for a real owner, and
reopening builds a new registry over the same root. Covered by
`quittingClosesTheProductDatabases`, verified to fail without the fix.

**An alert title glued a sentence to a clause** (`5658482`). The first alert a
product owner ever receives read `"A native Mac app for jotting short notes that
stay there when I reopen it. needs your input"`. An Epic has no analysed title
until the plan arrives, so `displayTitle` falls back to the outcome the owner
typed, and an outcome is a sentence. Titles are now checked on their own for a
terminator followed by a lowercase word. **Reported, not fixed** — see the open
items.

**The board claimed a duplicate button** (`5c4ca27`). A ticket whose candidate
was ready for demo while the ticket sat in acceptance rendered
`actions=[Open demo, Accept, Accept]`. Spedito shows one button; the harness was
describing a defect that does not exist.

**A run's evidence never said which demo kind it reached** (`2909a31`). The whole
catalog is organised by `DemoPresentationKind` and no run had ever recorded one.
Opening a demo now records the declared kind beside the expected one. A mismatch
is recorded, not filed: the agent may legitimately choose a different
presentation, and noisy findings have cost this loop real triage time.

**The board could not tell working from hung** (`92af448`). A line reading
`run=running` gave triage no way to distinguish an agent that is working from
one whose turn ended unnoticed, so the only way to tell was to wait out the
ten-minute silent-run tolerance — which happened again live this session. Ticket
lines now carry the run's last activity text and how long it has been quiet.

**A silent-run finding did not say whether the turn had ended** (`f40e24f`).
That is the only question that matters when the board says an agent is working
and nothing is happening, Spedito's own state cannot answer it, and the answer
was in Codex's rollout on disk the whole time. Answering it by hand cost most of
this session. The finding now carries "Codex says this thread's last turn
completed at 18:32:52Z", or that it started and has not ended, or that no
rollout could be read — absence is not evidence of no turn. **Triage the next
hang from findings.md; the archaeology in the traps below is now the fallback,
not the first step.**

## Open, and what is known about each

**The resume-after-review hang.** Above. This is the blocker.

**The malformed first alert.** Detected now, deliberately not fixed. There is no
mechanical correction that is right for every outcome: trimming the full stop
yields a longer run-on, and a goal phrased as a clause — "I want a dashboard" —
reads worse still. The real question is whether an unanalysed Epic should be
named by the owner's whole sentence at all. **That is the product owner's call.**

**Three permission-UX items the product owner has not objected to.** The
escalation problem itself is solved, which changes their priority:

- coalesce requests of the same shape arriving in one turn into one decision;
- tell the owner when a request is the Nth for one ticket;
- make refusal end in a real choice — "I can't build a native Mac app without
  the developer tools on your Mac; allow that, or I can deliver this
  differently" — instead of a failed run and a chained internal error.

A fourth idea, standing consent scoped by *access shape* rather than path, was
**proposed and withdrawn**. Do not resurrect it without reading
`docs/product-spec.md` around line 2090 first: the permission model is more
settled than it looks, and run 13 has now demonstrated that the escalation
problem was an undelivered instruction, not a missing mechanism.

**Agent work escapes into the owner's desktop session.** Run 12's `xcodebuild
test` invocations triggered a macOS *"wants permission to control your
computer"* prompt on the owner's Mac; an earlier session produced repeated
Google Chrome crash dialogs. Spedito's own instructions forbid the agent from
driving the desktop, and it was not trying to — the toolchain asks regardless.
This is a product question about mediating toolchain side effects, not a defect
with an obvious fix. **Report it; do not invent a policy.**

## Running it

```sh
./scripts/pilot.sh                      # static-converter, 1800s
./scripts/pilot.sh native-notes 3600    # a named brief and budget in seconds
```

Nine briefs, spanning every `DemoPresentationKind`. `import-repository` needs
`SPEDITO_PILOT_REPO` set to a repository the owner nominates; it has no default
on purpose.

Evidence lands in `.pilot-runs/<timestamp>-<brief>/`. **Read the bundle named by
`.pilot-runs/current-run`,** never "the newest directory": while a run rebuilds,
the previous run's bundle is still newest, and reading it produces a confident
report about the wrong run.

**Set `SPEDITO_PILOT_KEEP=1` for any run you expect to be interesting.** The
scratch root is deleted otherwise, and run 9 showed what that costs.

A run takes its budget in wall clock and can hold the machine while doing
nothing. Stop a run that cannot progress rather than waiting it out.

## Traps

**Journal timestamps are UTC; file modification times are local.** They differ
by an hour in British Summer Time. An evidence file "modified after the run
finished" is almost always this, not an anomaly.

**Codex rollouts are the fastest ground truth for a live run, and safe to read.**
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` is append-only. The `session_meta`
line names the worktree, which is how you attribute a thread to a ticket —
**do it explicitly.** Thread ordering is not ticket ordering, and this session
misattributed two threads before checking, which inverted the conclusion.
`task_started`, `task_complete` and `turn_aborted` give the turn timeline, and
`last_agent_message` carries the structured result including the demo
specification.

**Do not read a live pilot database with external `sqlite3`.** The writer holds
the WAL, so external reads silently fall back to the checkpointed file and
under-report committed rows. Once a run has finished,
`.pilot-runs/<run>/evidence/*.sqlite` is safe, and `activity_events` joined to
`work_items` is the clearest record of what happened, in order and per ticket.
Timestamps are Core Data epoch: `datetime(created_at + 978307200, 'unixepoch')`.

**Check every finding against the run's own evidence before believing it.** Seven
of the defects found so far were the harness's own, not Spedito's. The worst
cost a whole session and produced a confident handoff naming a blocker that did
not exist.

**Count the tokens when a finding mentions repeated turns.** A loop here spends
the product owner's money. Run 10 spent roughly fifteen million input tokens in
eight minutes before anyone noticed.

**A fix that removes a symptom is not a fix for its cause.** The recovery loop
was declared fixed after run 8 and recurred in run 10 through its other path.
The turn-wait fix removed one of two causes and the second is still live.

**Reason no further than the evidence.** Every wrong conclusion in this loop came
from one step past what was established. When stuck, make the system report a
fact rather than theorising about it.

## Working with the product owner's tree

Check `git status` on a path before staging it, and stage explicit paths rather
than `git add -A` unless the owner has asked otherwise.

Validation can run concurrently with a live pilot **only in a separate
worktree**. Building in the main tree while a run is in flight risks replacing
the test binary that run is executing. A detached worktree under the scratch
directory works well: patch it with `git diff`, build and test there, then
commit from the main tree. Remember to move the worktree forward as you commit,
or you will validate a later packet against a stale base.

## Scope of autonomous fixes

Agreed with the product owner:

- **Fix unattended:** reproducible functional defects, dead-end states, raw
  diagnostics reaching the owner, and product-language or convention violations
  — each with a regression test mined from the real failure.
- **Report only:** visual layout, information architecture, security posture,
  and anything needing taste. Surface with evidence and let the owner judge.
- **All work lands on the long-lived `pilot` branch.** Nothing merges to `main`
  without the owner.

The product owner's stated goal is that Spedito is robust for everyone across
all their use cases, and that nothing hardcodes rules or logic for specific
technologies. A fix that only works for Xcode, Homebrew, or npm is the wrong fix.

## Validation before any commit

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
git diff --check
./scripts/check_architecture_ratchets.sh
```

Currently 622 tests pass, ratchets match all six baselines, diff is clean. The
pilot run itself is gated behind `SPEDITO_PILOT=1` and does not run in
`swift test`, but the harness's own deterministic tests do and must stay that
way: `PilotSupervisionTests` is the reason a relaunch defect cannot silently
return.

A regression test must be verified to **fail without its fix**. Disable the fix,
watch the test fail, restore it. A test written against an already-fixed
behaviour proves nothing. Where the change *is* the check — a new convention
rule has no fix to disable — the honest substitute is showing it separates the
live failure from the correct text beside it in the same run.

## Cost and side effects

Each run consumes real Codex usage under the owner's own authentication, for up
to its budget in wall clock. A defect can spend far more than the budget
suggests: run 10 spent roughly fifteen million input tokens in eight minutes
through a loop that resumed agent threads.

Runs write only under a scratch root and never touch the owner's real products.
They do, however, execute real agent work on the owner's machine, and that work
has twice escaped into their desktop session: Chrome crash dialogs, and a macOS
Accessibility prompt from `xcodebuild test`. Watch for this and say so promptly.
