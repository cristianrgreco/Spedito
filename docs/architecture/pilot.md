# Live owner pilot

- **Status:** foundation landed; catalog breadth and the engineer loop in progress
- **Runner:** `scripts/pilot.sh`
- **Code:** `Tests/SpeditoAppTests/Pilot/`
- **Journey inventory:** `docs/architecture/owner-journey-test-plan.md`

## Why this layer exists

Every Codex-touching test in the suite injects `ScriptedCodexTransport`. The
reply is a hand-written JSON string that is always well formed, always on the
happy path, and always instant. That proves Spedito's reaction to a perfect
agent, which is the reaction that rarely breaks.

The regressions a product owner actually hits live outside that space:

- real agent output that is slow, verbose, or malformed;
- permission requests arriving at unpredictable moments;
- real Git worktrees, real conflicts, real build output;
- demos that must genuinely serve or launch;
- twenty turns of compounding durable state.

The pilot is the layer that reaches them. It drives the real `AppModel` over a
scratch Application Support root with the production Codex transport, real Git,
and the real demo launcher, and plays the product owner through a whole journey.

This does not replace the deterministic layers. It feeds them: a finding here
should become a fast deterministic test carrying the *real* agent reply captured
from the run's Codex rollout.

## What it drives

The driver only calls commands a view could call and only reads state a view
could read. Anything it cannot do, the owner cannot do either.

```
create product -> ask for an outcome -> answer clarification rounds
  -> accept the suggested plan -> plan and start a sprint
  -> answer questions, decide permissions, open demos, accept work
  -> quit and reopen mid-delivery -> confirm nothing was lost
```

## Product catalog

Briefs are chosen to span every `DemoPresentationKind`, because demo preparation
and launch is where owner-visible delivery most often breaks.

| Brief | Demo kind | Exercises |
| --- | --- | --- |
| `static-weather` | `staticWeb` | scoped network permission, owner memory follow-up |
| `static-converter` | `staticWeb` | smallest end-to-end path, no build step |
| `web-reading-list` | `browser` | build step, mid-sprint scope change |
| `native-notes` | `macApplication` | native launch, app versions, persistence |
| `native-timer` | `macApplication` | native launch, notification behaviour |
| `script-log-summary` | `commandOutput` | non-visual delivery outcome |
| `library-csv` | `artifact` | review-only delivery, test evidence |
| `vague-dashboard` | `browser` | must ask a consequential product question |
| `import-repository` | `artifact` | repository import, knowledge analysis, delivery into existing history |

`import-repository` has no default repository: set `SPEDITO_PILOT_REPO` to one
you would genuinely import. Guessing a third-party repository would clone
something the product owner never chose.

## What counts as a finding

The harness cannot assert exact text, because a real agent words things
differently every run. It asserts the contracts this repository already states,
so a violation is a defect rather than a matter of taste:

- **Dead end** — a non-terminal ticket with no running agent and no available
  action. The owner has been stranded.
- **Convention** — owner-facing text breaking the stated product-language rules:
  sentence case labels, "and" rather than an ampersand, owner vocabulary.
- **Leaked diagnostic** — raw technical evidence reaching the owner instead of a
  typed, concise explanation.
- **Functional** — a broken durable contract: ready for demo that will not open,
  a completed ticket with no handoff, a ticket sequence with gaps, state lost
  across a relaunch.
- **Stalled** — nothing observable happened within the budget. Two shapes: a
  queued run that is never admitted, and a running agent that reports nothing.
  The second needs its own check because a running run always offers **Stop**,
  so the dead-end rule never fires for it.

## Evidence bundle

Each run writes `.pilot-runs/<timestamp>-<brief>/`:

```
journal.jsonl              every owner command, observation, and finding
findings.md                the triage report
evidence/*.sqlite          the product database as the run left it, with its
                           write-ahead log beside it
evidence/codex-threads/    the rollout for every thread the run touched
```

The write-ahead log is copied with the database on purpose. SQLite keeps recent
commits there until something checkpoints them, so copying the database file
alone captures whatever was last checkpointed, which for one run was an empty
file. `PilotSupervisionTests.capturedEvidenceContainsCommittedRows` holds this.

The journal is appended synchronously, so an interrupted or hung run still
leaves a readable trail.

## Deliberate deviations

The verification model requires asynchronous tests to observe explicit operation
events rather than sleeps. The pilot polls on a timer instead. This is
intentional and confined to this harness: it observes a real external agent
whose completion is not an event the app can publish, over minutes to hours.
Deterministic suites must keep using explicit events, and any test mined from a
pilot finding must be written that way.

The pilot reports rather than fails the build. A real agent occasionally
produces a legitimate outcome the harness did not anticipate, and a red build
would train the team to ignore it.

## Findings fixed from live runs

### Stale sprint board (run 3 and 4, 21 August 2026)

The board reported every ticket as queued for ten minutes while the database
recorded one run completing twice and another actively running. The owner had
no way to tell that work was progressing.

`TicketDeliveryWorkflowCoordinator.updateAgentRun` notifies the application of
every run update, but `AppModel.deliveryAgentRunDidUpdate` only refreshed when
owner attention was involved. `AppModel.runs` is assigned in exactly one place,
inside `reloadSelectedProduct()`, and no view refetches it, so an ordinary
queued-to-running transition never reached the board.

Covered by `SprintBoardRunFreshnessTests`, which reproduces all three observed
symptoms: a started run still shown as queued, a completed run still shown as
running, and a review run absent from the board entirely.

This raised `app_model_lines` from 5169 to 5175. The fix belongs in `AppModel`
because that is where the delivery delegate is implemented, and the board
cannot be a projection of durable state without it.

### The harness watched an application it had already closed (run 7, 21 August 2026)

Runs 5 to 7 all reported the same picture: a sprint that reaches delivery and
then freezes, every ticket queued with no available action, for the rest of the
budget. Run 7 was diagnosed as an admission or scheduler defect and written up
as the loop's open blocker.

The durable evidence says the opposite. In run 7's database, delivery ran
continuously from 10:44 to 10:52: two candidates, two tech lead reviews, review
feedback recorded, and both implementation runs resumed and running at the point
the budget expired. Nothing stalled.

`superviseDelivery` bound `model` once, before its loop. `simulateRelaunch`
replaces `model` mid-run, so from the relaunch onwards every observation —
the board snapshot, `PilotInvariants`, and the "every ticket finished" check —
read the application that had just been shut down. That board froze at
shutdown, where `suspendSprintExecution` had correctly queued both runs, so it
showed three queued runs forever.

The owner reactions were unaffected, because each reads `model` when it runs:
permission requests were answered and delivery kept moving. Only the reporting
was blind, which is why the harness produced confident findings about a sprint
that was working.

`reportBoardDivergence` exists to catch exactly this and stayed silent for the
same reason in reverse: it reads `model` freshly, so it compared the reopened
application against the database, found them in agreement, and said nothing.

Two consequences worth keeping in mind:

- every finding filed after a relaunch in runs 5 to 7 is void, including the
  delivery stall the previous handoff named as the blocker; and
- no run has ever reported reaching a demo because the completion check also
  read the closed application. The relaunch fires early, at tick 11, so this
  affected the whole of delivery in every run.

Fixed by extracting `superviseTick`, which reads `model` at the start of every
turn, and routing both opening and reopening through `adopt(model:registry:)`
so there is one place the observed application can change. Covered by
`PilotSupervisionTests`, verified to fail with the binding restored: the board
reports `queued` while the database says `running`.

### Delivery recovery requeued its own live runs (run 8, 21 August 2026)

The first run whose post-relaunch observations were trustworthy reached two
reviewed candidates with changes requested, then stopped progressing for the
last eight minutes of its budget. Its database records 46 `agent_run.queued`
events in that window, two at a time, roughly every 12 to 25 seconds, each one
reading "Interrupted work queued to resume from the existing workspace".

`recoverDelivery` adopts every run the database still calls running, on the
assumption a process stopped and orphaned them. It is invoked from
`prepareScheduler`, which the runtime coordinator calls every time a scheduler
task is created, not only at launch. Schedulers are created and retired
constantly during delivery, so recovery kept requeuing runs the same process was
executing: the drain restarted each one, and the next scheduler requeued it.

Both recovery passes were affected. The requeuing pass interrupted live work;
the earlier pass resumed the run's Codex thread and could reprocess a completed
result while its turn was still running.

Fixed by skipping runs `TicketDeliveryRuntimeCoordinator.executingRunIDs`
reports — an implementation task this process owns, or a live Codex turn it
registered. A genuine relaunch is unaffected because a fresh runtime coordinator
owns nothing, which `[D04]` already proves. Covered by
`recoveryDoesNotRequeueItsOwnLiveRun`, verified to fail without the fix.

This is the defect the previous handoff was reaching for when it named delivery
admission and the scheduler. It could not be seen until the harness stopped
reporting on an application it had closed, and the mechanism is nothing like
what was hypothesised.

### The first successful run left no evidence (run 9, 21 August 2026)

Run 9 completed a whole ticket — plan, sprint, delivery, tech lead review, demo,
acceptance, released — and filed no findings. Its evidence database was 4KB with
no schema in it.

`captureEvidence` copied `product.sqlite` and nothing else. Everything the run
committed was still in the write-ahead log, which is where SQLite keeps recent
commits until a checkpoint moves them. Earlier runs happened to capture usable
databases because their logs had been checkpointed by then, so this looked
reliable until the run that mattered most.

Fixed by copying the log and shared-memory files beside the database, so the
evidence database replays what the run committed. Covered by
`capturedEvidenceContainsCommittedRows`, verified to fail without the fix by
reproducing the empty database exactly.

A run's own bundle is the only durable record: the scratch root is deleted when
the run ends unless `SPEDITO_PILOT_KEEP=1` is set. Run 9's data is gone, and only
its journal survives.

## Cost and safety

- Runs consume real Codex usage under the owner's own authentication. Budget is
  bounded per run by `SPEDITO_PILOT_BUDGET_SECONDS` (default 1800).
- All state is written under a scratch root, never the owner's real products.
- Repository briefs are read-only imports. Nothing is pushed.
