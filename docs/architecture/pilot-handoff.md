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

**Run 13 (`native-notes`) is the best run so far and it settles two of the three
open questions.** T1 went plan → sprint → delivery → tech lead review → demo →
acceptance → **released**, and its demo was a real `mac_application` bundle the
owner opened. That is the first time this loop has taken a native Mac app to
completion, and the first time any run has *proved* which
`DemoPresentationKind` it reached rather than assuming it.

**T2 hung, again.** Its turn completed cleanly in Codex and Spedito never
processed it. Detail below — the shape is now much sharper than it was.

Still unexercised: retrospectives, app versions, and the `script-log-summary`,
`library-csv`, `web-reading-list`, `vague-dashboard`, `static-weather` and
`import-repository` briefs.

## What to do first

1. **Take the resume-after-review hang.** It is the one thing standing between
   this loop and a completed sprint, it now reproduces reliably, and the section
   below tells you exactly where to instrument. Do not start from a hypothesis;
   the last three sessions each lost time to one.
2. **Then run the briefs nobody has run:** `script-log-summary`, `library-csv`,
   `web-reading-list`, `vague-dashboard`. Each exercises a
   `DemoPresentationKind` that has never been reached, and the product owner has
   asked for breadth. The journal now records the kind each run actually
   reached, so the coverage claim will be evidence rather than intent.

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

**Recovery runs once per product (`8fd8784`) holds.** No requeue events, no
token burn, across a full run including a mid-delivery relaunch.

**The turn-wait fix (`c04bdb5`) is real but partial.** It explains run 12's T1
exactly. It does not explain T2 in either run, because no owner decision was
involved. See below.

## The resume-after-review hang

This is the open blocker, and it is now reproducible.

**Three turns have hung across runs 12 and 13. All three were the turn that
resumes a ticket after the tech lead requested changes. No turn of any other
kind has hung.**

| Run | Ticket | Turn completed in Codex | Approval in that turn | Last durable Spedito event |
| --- | --- | --- | --- | --- |
| 12 | T1 | 16:39:42Z | yes — one **denied** at 16:35:49Z | 16:35:49Z |
| 12 | T2 | 16:34:13Z | **none anywhere in its history** | 16:33:38Z |
| 13 | T2 | 18:32:52Z | **none anywhere in the run but T1's** | ~18:31:46Z |

Run 13's T2 is the cleanest specimen and its evidence is unambiguous:

- the revision turn started 18:31:46Z and completed 18:32:52Z with a well-formed
  structured result (`reviewInstructions`, `followUpTicketProposals`,
  `knowledgePageProposals`, `tests`);
- no Codex event of any kind followed it on any thread — Spedito never started
  another turn, so it is not waiting on new agent work;
- the Codex app-server process stayed alive throughout;
- the board still read `run=running` with **Stop** eleven minutes later, and the
  harness filed its silent-run finding at 18:43:01Z;
- **and the wait's own 900-second inactivity timeout did not fire.** It was due
  at 18:47:52Z and was watched past 18:50:03Z with no Codex activity and no
  board change. This was observed live, not inferred.

So the owner is told an agent is working, indefinitely, after that agent
finished.

### Where to instrument

`TicketDeliveryWorkflowCoordinator` awaits the revision turn at
`waitForFinalAgentMessage(threadID:turnID:timeout: .seconds(900))`, with no
`totalTimeout`. Inside `CodexAppServerClient.waitForFinalAgentMessage` four
tasks race:

1. the notification stream (primary);
2. a **2-second reconciliation poller** calling `thread/read`;
3. an inactivity timeout that only decrements when `isAwaitingApproval` is false;
4. an optional absolute cap, which this caller does not pass.

**Two independent safety nets both failed, and that is the useful part.**

The reconciliation poller should have found the completed turn within two
seconds of 18:32:52Z. **Its errors are swallowed by a bare `catch` and recorded
nowhere**, so there is no evidence of whether it threw every time or kept
returning nil. Recording that error is the cheapest change with the highest
information yield.

The inactivity timer was watched past its deadline and never fired. Only two
things in that loop can stop the countdown: `activity.record()`, which fires
only for notifications matching this thread *and* turn, or `isAwaitingApproval`
returning true. **A pending approval registered against this turn and never
removed is the leading candidate**, and it fits run 12's T2 as well as run 13's.

Worth checking first, because it is structural rather than speculative:
`routeInboundMessage` registers a pending approval for every
`item/commandExecution/requestApproval` and `item/permissions/requestApproval`
it routes. Only `resolveApprovalRequest`, `rejectUnsupportedServerRequest` and
`disconnect()` ever remove one. **Any path that answers Codex without going
through those two leaves the turn suspended for the life of the connection**,
with no owner decision involved and nothing left to time it out. Note also that
`resolveApprovalRequest`'s `default:` branch throws before its
`defer { removePendingApproval(request) }` is installed, so an unrecognised
method leaks an entry — latent today, since callers route unknown methods to
the reject path, but it is the same hole.

Codex's own record says its turn completed normally, so Codex was not blocked
waiting for a response. Whatever answered it did not clear Spedito's map.

### Already ruled out, so you do not have to

Two paths leave a permission request unanswered and would fit the symptom. Both
are **excluded for run 13 by that run's own evidence**: each sets
`deliveryErrorMessage`, which is `AppModel.errorMessage`, which the pilot renders
as an `Error banner:` line — and **no board snapshot in run 13 carried one**.

- `TicketDeliveryPermissionWorkflowCoordinator.handleServerRequest`, the `catch`
  around fetching the run and its durable permission history.
- `resolveAutomaticPermissionRequest`, its outer `catch`.

Its every other exit was audited and does respond. The one remaining
no-response exit is the path that deliberately hands the request to the product
owner and waits for their decision, which is correct.

**One of those two is worth fixing anyway, independent of this hang.** The
`handleServerRequest` catch returns having sent Codex nothing — its own message
says "so no response was sent" — while the pending approval it registered stays
registered. That suspends the turn's only remaining timeout for the life of the
connection, so the owner gets an error banner *and* a run that says an agent is
working, forever. Answering Codex on that path costs the agent a capability it
may need, which is strictly better than a turn nothing can end: a denied agent
adapts, as run 12's own work log shows.

### Then instrument

Log the reconciliation error, and log `pendingApprovalTurns` for the turn when a
wait passes its deadline. That turns the next occurrence into an answer instead
of another round of inference — this loop has now spent three sessions on
hypotheses and one afternoon on evidence, and only the evidence moved it.

**Do not add an absolute cap as the fix.** The last session considered and
rejected it for the right reason: a turn genuinely waiting on the product owner
should wait indefinitely. A cap would hide this defect rather than remove it.

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
