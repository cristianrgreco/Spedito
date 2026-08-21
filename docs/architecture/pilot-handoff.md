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
and then stalls. **No run has ever reached a demo**, so everything downstream of
delivery — demo launch, acceptance, retrospectives, app versions — is still
completely unexercised.

### Fixed and proven

**Stale sprint board.** Runs were completing in SQLite while the board showed
`queued` for twenty minutes. `TicketDeliveryWorkflowCoordinator.updateAgentRun`
notifies the app of every run update, but `AppModel.deliveryAgentRunDidUpdate`
only refreshed when owner attention was involved. `AppModel.runs` is assigned in
exactly one place, inside `reloadSelectedProduct()`, and no view refetches it, so
an ordinary queued-to-running transition never reached the board.

Fixed in `AppModel.swift`. Covered by `SprintBoardRunFreshnessTests`, verified to
fail without the fix. Raised `app_model_lines` 5169 to 5175 with the reason
recorded in `docs/architecture/pilot.md`.

### The open blocker

Delivery stops partway through every sprint. Tickets are left presented as
running, with no available action, indefinitely. The harness self-diagnoses it;
run 7's finding reads:

```
Sprint: active, 3 planned item(s)
No prerequisites, so nothing upstream is holding it.
Delivery considers this run eligible, so something after admission is not starting it.
Eligible runs right now: 2
Last thing this run reported: Implementing headless browser readiness check
Permission requests for this run: policy_denied
```

Established facts, not hypotheses:

- the sprint is **active**, so shutdown is not leaving it paused;
- nothing is waiting on prerequisites;
- `SprintRunAdmission` considers the runs **eligible**;
- nothing starts them, for ten minutes or more;
- the run's only permission request ended `policy_denied`, meaning Spedito's
  least-privilege policy refused it automatically rather than the owner.

The untested step is why an admissible queued run is never started. Two
candidates remain: the guard at the top of
`TicketDeliveryWorkflowCoordinator.executeImplementationRun`, which requires the
run's profile to be present in the loaded context, and the scheduler not
draining after `deliveryScheduleSprintExecution` wakes it.

Hypotheses already **eliminated** by evidence, so do not spend time on them:

- the delivery capacity or rate-limit constraint — no execution constraint is
  ever persisted;
- `shutdown()` leaving the sprint paused — the sprint is active;
- `resumesAfterDecision` re-queueing recovered permission requests — that path
  needs `request.status == .interrupted`, and the observed requests were live;
- the board being stale — the in-process divergence check is now silent, so the
  board agrees with the database.

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

**Four of the defects found so far were the harness's own**, not Spedito's:
posting real user notifications from an unbundled process, replying to a ticket
without resuming it, refusing localhost demo servers as if they were internet
access, and a divergence check that skipped runs the board had never seen. Treat
a first finding as suspect until the mechanism is understood.

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

Currently 603 tests pass, ratchets match all six baselines, diff is clean. The
pilot is gated behind `SPEDITO_PILOT=1` and does not run in `swift test`.

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

1. Confirm the delivery stall and fix it. It blocks every brief, so breadth is
   not worth attempting until a run can reach a demo.
2. Once a demo is reached, run the native macOS, script, and library briefs. The
   owner asked for varied products; only static web has been exercised.
3. Write up the Chrome and permission-wording findings as their own packet.
4. Mine real Codex replies from `evidence/codex-threads/` into
   `ScriptedCodexTransport` fixtures. The existing suite's fixtures are
   hand-written happy paths, and replacing them with real agent output is the
   durable fix for regressions recurring.
