# Pilot loop handoff

- **Date:** 21 August 2026
- **Branch:** `pilot` (12 commits ahead of `main`)
- **Harness:** `Tests/SpeditoAppTests/Pilot/`, runner `scripts/pilot.sh`
- **Design rationale:** `docs/architecture/pilot.md`

Read `docs/architecture/pilot.md` first for why this layer exists. This document
covers only what a continuing agent needs to pick the loop up.

## The working tree is committed now

Commit `0bd0af6` swept in the product owner's uncommitted `AppModel.swift` work.
They have since said the commit is fine and asked for all local changes to be
committed, which is `775e4bb`. The tree is clean and no history was rewritten.

Three fixes on this branch were blocked while it was dirty and are now done, so
the rule that produced the problem still stands: **stage explicit paths, and
check `git status` on a file before staging it.** A future session should not
assume the tree is clean just because this one left it that way.

## Where the loop is

Ten live runs. Run 9 (`static-converter`) completed a ticket end to end and
filed no findings: plan -> sprint -> delivery -> tech lead review -> demo ->
acceptance -> released. That remains the only complete journey.

Run 10 was the first `native-notes` run, and the first on any brief other than
`static-converter`. It reached two reviewed candidates and then lost the rest of
its budget to a recovery loop that also burned roughly fifteen million input
tokens of the product owner's Codex usage in eight minutes. That loop is the one
that was declared fixed after run 8; the fix removed one of its two paths. It is
now fixed at its cause, and `docs/architecture/pilot.md` has the full account.

Still unexercised: retrospectives, app versions, and the script, library, and
browser briefs. No `native-notes` run has reached a demo.

### Fixed and proven

Two things, one in Spedito and one in the harness. Read both: the second is why
the previous handoff's blocker was wrong.

**Restart recovery ran on every scheduler creation.** It resumes each run's Codex
thread and requeues what it cannot account for, and schedulers are created and
retired constantly during a sprint. Run 8 showed the requeuing half; the guard
added then only helped while a run was executing, so run 10 looped between
turns instead and additionally spent roughly fifteen million input tokens
resuming threads. `recoverDelivery` now runs once per product per process, which
is what "recovery after restart" always meant. Covered by
`recoveryRunsOncePerProduct`.

**A hung run was invisible.** For thirty minutes of run 9 a running agent
reported nothing and the pilot filed nothing: `stalledRuns` only looks at queued
runs, and `deadEnds` skips any ticket offering an action, which a running run
always does because it offers **Stop**. `silentRuns` now reports a run whose last
activity is older than `silentRunTolerance`, and its evidence says to rule out a
dropped connection first, because that is what run 9 turned out to be.

**Evidence capture dropped the write-ahead log.** Run 9's evidence database was
4KB with no schema in it, because `captureEvidence` copied `product.sqlite`
without the log SQLite keeps recent commits in. Earlier runs looked fine only
because their logs happened to have been checkpointed. The scratch root is
deleted at the end of a run, so run 9's data is gone and only its journal
survives. Fixed and covered by `capturedEvidenceContainsCommittedRows`.

**Delivery recovery requeued its own live runs.** `recoverDelivery` adopts runs
the database still calls running, on the assumption a process stopped and
orphaned them. It is invoked from `prepareScheduler`, which runs every time a
scheduler is created, not only at launch. So while delivery was live it kept
requeuing runs this process was executing: the drain restarted them, the next
scheduler requeued them again. Run 8 recorded 46 requeues in eight minutes,
starting immediately after a tech lead requested changes, after which the sprint
made no further progress.

Fixed in `TicketDeliveryWorkflowCoordinator.recoverDelivery`, which now skips
runs `TicketDeliveryRuntimeCoordinator.executingRunIDs` reports. A genuine
relaunch still recovers everything, because a fresh runtime coordinator owns
nothing; `[D04]` is the proof of that and still passes. Covered by
`recoveryDoesNotRequeueItsOwnLiveRun`, verified to fail without the fix.

**Two owner-facing text defects**, both found by run 8 and both fixed with a
regression test verified to fail first:

- clarification alerts interpolated `epic.title`, which is empty until the plan
  names the Epic, so the first notification an owner ever receives was titled
  `" needs your input"`. Both alert sites now use `Epic.displayTitle`.
- the live permission prompt said `"Network access"` for a scoped request, while
  the saved grant said `"Restricted network access"`. Both now defer to
  `AgentPermissionGrantPolicy.isUnrestrictedNetwork`.

**Stale sprint board.** Runs were completing in SQLite while the board showed
`queued` for twenty minutes. `TicketDeliveryWorkflowCoordinator.updateAgentRun`
notifies the app of every run update, but `AppModel.deliveryAgentRunDidUpdate`
only refreshed when owner attention was involved. `AppModel.runs` is assigned in
exactly one place, inside `reloadSelectedProduct()`, and no view refetches it, so
an ordinary queued-to-running transition never reached the board.

Fixed in `AppModel.swift`. Covered by `SprintBoardRunFreshnessTests`, verified to
fail without the fix. Raised `app_model_lines` 5169 to 5175 with the reason
recorded in `docs/architecture/pilot.md`.

### The blocker named by the previous handoff does not exist

The previous handoff called delivery stalling partway through every sprint the
open blocker, with `SprintRunAdmission`, `executeImplementationRun`, and the
scheduler as the remaining suspects. That was wrong, and the durable evidence in
run 7's own bundle says so.

`agent_runs` and `activity_events` in
`.pilot-runs/2026-08-21-104247-static-converter/evidence/` record continuous
delivery while the harness was reporting a frozen board:

```
10:44:05  both implementation runs picked up, tickets queued -> running
10:45:46  the pilot quits and reopens; shutdown queues both runs, correctly
10:47:31  T2 candidate v1 captured, running -> integrating
10:47:32  T2 tech lead review starts
10:48:47  T2 review returns changes; implementation resumes
10:50:28  T1 candidate v1 captured
10:52:05  T1 review returns changes; implementation resumes, turn live
```

Nothing stalled. The harness's `superviseDelivery` bound `model` once before its
loop, and `simulateRelaunch` replaces it, so every observation after the
relaunch read the application that had just been closed. Its board froze at
shutdown with all three runs queued. Full write-up in `docs/architecture/pilot.md`.

**Treat every post-relaunch finding from runs 5 to 7 as void.** The relaunch
fires at tick 11, roughly one hundred seconds into supervision, so in practice
that is the whole of delivery in each of those runs. This also explains "no run
has ever reached a demo": the completion check read the same closed application,
so a finished sprint could not be observed even if it happened.

Fixed on this branch: `superviseTick` reads `model` at the start of every turn,
and `adopt(model:registry:)` is the one place the observed application changes.
`PilotSupervisionTests` covers it and was verified to fail with the binding
restored.

The three eliminated hypotheses from the previous session stand, and the
following are now eliminated too, because delivery was never stuck:

- `SprintRunAdmission` refusing eligible runs;
- the guard at the top of `executeImplementationRun`; and
- the scheduler failing to drain after `deliveryScheduleSprintExecution`.

What remains genuinely unknown is what a run does *after* delivery: no
observation of demo preparation, demo launch, acceptance, retrospectives, or app
versions is trustworthy yet, because the harness has never reported that far.
That needs a fresh run, not more code reading.

### Chrome crash dialogs and permission wording

The agent implemented a browser readiness check using a headless automation
kernel driving the owner's installed Google Chrome. Chrome aborted repeatedly
against the sandbox and produced **macOS crash dialogs on the owner's desktop**.

Two things worth a packet. Sandboxed agent work should not surface OS-level
crash reporting to a product owner, which is the opposite of hiding the
machinery. And a permission prompt reading `Read /Applications/Google Chrome.app`
is not a decision a non-technical owner can meaningfully make; contrast
`CodexAppServerClient.permissionDetail`, which cannot express a restricted
network scope, with `AgentPermissionGrantPolicy.detailLines`, which can.

Spedito itself never launches a specific browser. `NSWorkspace.open(url)` uses
the system default. The Chrome choice was the agent's, because headless
automation drives Chrome over the DevTools protocol.

The permission-wording half is now pinned to a specific line. Compare the two
renderers:

- `CodexAppServerClient.permissionDetail` emits `"Network access"` whenever
  `network.enabled` is true, and has no other network branch.
- `AgentPermissionGrantPolicy.detailLines` distinguishes `"Network access"` from
  `"Restricted network access"`, because it keeps the whole network object as
  the scope and compares it against the unrestricted `{"enabled":true}`.

So a restricted request and a full-internet request are worded identically at
the moment the owner decides, and differently afterwards in the saved grant.
That is the wrong way round: the broader wording appears where consent is given
and the narrower one where it is merely recorded.

The wording half is fixed in `f29f1f4`. The Chrome half is not: Spedito cannot
stop macOS from reporting a sandboxed child process's crash, and deciding what
the owner should see instead is a product question, not a defect with an obvious
fix. It stays a report.

## Running it

```sh
./scripts/pilot.sh                      # static-converter, 1800s
./scripts/pilot.sh native-notes 2400    # a named brief and budget in seconds
```

Nine briefs, spanning every `DemoPresentationKind`. `import-repository` needs
`SPEDITO_PILOT_REPO` set to a repository the owner nominates; it has no default
on purpose.

Evidence lands in `.pilot-runs/<timestamp>-<brief>/`. **Read the bundle named by
`.pilot-runs/current-run`,** never "the newest directory": while a run rebuilds,
the previous run's bundle is still newest, and reading it produces a confident
report about the wrong run. That mistake was made once already.

## Traps that cost time in this session

**Do not read a live pilot database with external `sqlite3`.** The writer holds
the WAL, so external reads silently fall back to the checkpointed file and
under-report committed rows. One query reported zero work items for a product
that plainly had three. The in-process divergence check in `PilotDriver` shares
the app's own connection and is the authoritative signal.

**Extend the harness's diagnosis instead of theorising.** Three wrong
conclusions in this session all came from reasoning one step past the evidence.
Every time the fix was to make the pilot report a fact — the admission verdict,
the permission status, the last reported activity — and the answer then arrived
immediately. Prefer adding a diagnostic to the pilot over adding an accessor to
`AppModel`; an accessor was added for this and reverted, because it grew
`AppModel` for diagnostics only, against the architecture ratchets.

**The relaunch step is the least faithful part of the harness.** It builds a new
`AppModel` but reuses the `ProductStoreRegistry`, so it is not a genuinely cold
start. Rule this out before attributing any post-relaunch finding to Spedito.

**Five of the defects found so far were the harness's own**, not Spedito's:
posting real user notifications from an unbundled process, replying to a ticket
without resuming it, refusing localhost demo servers as if they were internet
access, a divergence check that skipped runs the board had never seen, and
reporting on an application the harness had already closed. Treat a first
finding as suspect until the mechanism is understood.

The last of those cost a whole session and produced a confident handoff naming
the wrong blocker. Before believing any finding, check it against the run's own
database: `.pilot-runs/<run>/evidence/*.sqlite` is safe to query with `sqlite3`
once the run has finished, and `activity_events` is the clearest record of what
actually happened, in order.

## Scope of autonomous fixes

Agreed with the product owner:

- **Fix unattended:** reproducible functional defects, dead-end states, raw
  diagnostics reaching the owner, and product-language or convention violations
  — each with a regression test mined from the real failure.
- **Report only:** visual layout, information architecture, and anything needing
  taste. Surface with evidence and let the owner judge.
- **All work lands on the long-lived `pilot` branch.** Nothing merges to `main`
  without the owner.

## Validation before any commit

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
git diff --check
./scripts/check_architecture_ratchets.sh
```

Currently 612 tests pass, ratchets match all six baselines, diff is clean. The
pilot run itself is gated behind `SPEDITO_PILOT=1` and does not run in
`swift test`, but the harness's own deterministic tests do and must stay that
way: `PilotSupervisionTests` is the reason a relaunch defect cannot silently
return.

A regression test must be verified to **fail without its fix**. Disable the fix,
watch the test fail, restore it. A test written against an already-fixed
behaviour proves nothing.

## Cost and side effects

Each run consumes real Codex usage under the owner's own authentication, for up
to its budget in wall clock. A defect can spend far more than the budget
suggests: run 10 spent roughly fifteen million input tokens in eight minutes
through a loop that resumed agent threads. When a finding mentions repeated
turns, count the tokens in the rollouts before anything else. Seven runs is roughly three hours. Keep budgets
tight while iterating on the harness, and only lengthen them once a run is
expected to reach a demo.

Runs write only under a scratch root and never touch the owner's real products.
They do, however, execute real agent work on the owner's machine: this session
produced repeated Google Chrome crash dialogs on their desktop. Watch for side
effects that escape the sandbox into their session, and say so promptly.

## Suggested next steps

1. Run `native-notes` again. Run 10 never reached a demo, so native launch, app
   versions, and persistence are all still unproven, and the recovery fix needs
   a live run to confirm it at its cause rather than at a symptom.
2. Run the script, library, and browser briefs. Delivery now reaches a demo,
   so the demo kinds that have never been exercised are the obvious next target.
   `static-converter` has been run nine times; it has little left to say.
3. Make the relaunch a genuinely cold start. `simulateRelaunch` reuses the
   `ProductStoreRegistry`, so the same SQLite connections survive a quit that
   should have closed them. This is the least faithful part of the harness.
4. Mine real Codex replies from `evidence/codex-threads/` into
   `ScriptedCodexTransport` fixtures. The existing suite's fixtures are
   hand-written happy paths, and replacing them with real agent output is the
   durable fix for regressions recurring.

Set `SPEDITO_PILOT_KEEP=1` when a run is expected to be interesting. The scratch
root is deleted otherwise, and run 9 showed what that costs.
