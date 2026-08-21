# Pilot loop handoff

- **Date:** 21 August 2026
- **Branch:** `pilot` (7 commits ahead of `main`)
- **Harness:** `Tests/SpeditoAppTests/Pilot/`, runner `scripts/pilot.sh`
- **Design rationale:** `docs/architecture/pilot.md`

Read `docs/architecture/pilot.md` first for why this layer exists. This document
covers only what a continuing agent needs to pick the loop up.

## Resolve this before anything else

Commit `0bd0af6` accidentally contains the product owner's uncommitted
`AppModel.swift` work: a token-usage refactor introducing `cumulativeUsedTokens`
around `thread/tokenUsage/updated`. It was swept in by `git add` on a file that
was already dirty at session start.

Nothing is lost and the other 54 dirty files are untouched, but the owner was
told their work was untouched, which was wrong for that file. They have been
offered a split into a separate commit and have not yet answered. **Do not
rewrite that history without their instruction.**

Lesson for the rest of this loop: this repository is worked on with a
persistently dirty tree. Stage explicit paths, and check `git status` for the
file first when a production file must change.

## Where the loop is

Seven live runs, all on the `static-converter` brief. Every run reaches a sprint
and delivers real work. **No run has ever been observed reaching a demo**, so
everything downstream of delivery — demo launch, acceptance, retrospectives, app
versions — is still unproven. Note the wording: until the fix below, the harness
went blind at the relaunch, so it could not have reported a demo even if one
happened.

### Fixed and proven

Two things, one in Spedito and one in the harness. Read both: the second is why
the previous handoff's blocker was wrong.

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

### Second finding, not yet written up

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

Currently 606 tests pass, ratchets match all six baselines, diff is clean. The
pilot run itself is gated behind `SPEDITO_PILOT=1` and does not run in
`swift test`, but the harness's own deterministic tests do and must stay that
way: `PilotSupervisionTests` is the reason a relaunch defect cannot silently
return.

A regression test must be verified to **fail without its fix**. Disable the fix,
watch the test fail, restore it. A test written against an already-fixed
behaviour proves nothing.

## Cost and side effects

Each run consumes real Codex usage under the owner's own authentication, for up
to its budget in wall clock. Seven runs is roughly three hours. Keep budgets
tight while iterating on the harness, and only lengthen them once a run is
expected to reach a demo.

Runs write only under a scratch root and never touch the owner's real products.
They do, however, execute real agent work on the owner's machine: this session
produced repeated Google Chrome crash dialogs on their desktop. Watch for side
effects that escape the sandbox into their session, and say so promptly.

## Suggested next steps

1. Run the pilot again on `static-converter` now that the harness can see past
   the relaunch. This is the first run whose post-relaunch observations mean
   anything; treat its findings as a first sighting, not a diagnosis.
2. Once a run genuinely reaches a demo, run the native macOS, script, and
   library briefs. The owner asked for varied products; only static web has been
   exercised.
3. Write up the Chrome and permission-wording findings as their own packet.
   The relaunch defect does not touch these, even though both were seen after
   the relaunch: they arrived through `drainPermissionRequests` and the shared
   notification recorder, and every owner-reaction path reads the application
   that is open now. Only the reporting paths were blind.
4. Mine real Codex replies from `evidence/codex-threads/` into
   `ScriptedCodexTransport` fixtures. The existing suite's fixtures are
   hand-written happy paths, and replacing them with real agent output is the
   durable fix for regressions recurring.
