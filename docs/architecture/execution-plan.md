# Execution plan: reconcile, protect, extract, verify

- **Date:** 15 August 2026
- **Status:** Proposed; ready to execute packet by packet
- **Evidence commit:** `69227e6`, plus the current working tree where noted
- **Product authority:** `docs/product-spec.md`
- **Architecture authority:** `docs/technical-design.md`
- **Journey inventory:** `docs/architecture/owner-journey-test-plan.md`
- **Historical ledger:** `docs/architecture/stabilization-plan.md`

This file is a sequenced list of work packets, not a fifth source of truth. It never restates product behavior or architecture rules; it points at the documents above and says what to do next, in what order, with what evidence. When a packet lands, its result belongs in those documents, and this file records only that the packet is done.

Every packet follows the change and commit protocol in section 9 of the stabilization plan and the work-packet template in its section 11. Extraction packets fill that template in full before any code moves.

## 1. What this plan fixes

Three findings, each measured rather than assumed.

**The stabilization ledger overclaims.** Commit `69227e6` was an enormous, genuine decomposition: `ContentView.swift` went from 24,806 lines to 611, 63 files were added, `SQLiteStore` was split into 20 aggregate extensions, `GitHubRemoteRepositoryService` into five, and long-lived task sites in `AppModel` and `ContentView` fell from 59 and 97 to 1 and 2. Almost everything on that program landed. But `AppModel.swift` shrank only 13,442 → 12,459 lines, and the Phase 6 and Phase 7 boxes covering delivery execution, epic planning, and sprint planning are checked while that code is still in `AppModel`. The plan's own implementation-status prose says exactly this. The prose is right and the boxes are wrong, so the boxes must move.

**Nothing mechanically protects the result.** `AppModel.swift` grew 10,472 → 13,238 → 13,434 → 13,442 across the three commits before the extraction. Concentration regrowth is the empirical default here, and CI runs only `swift test` and `git diff --check`. The Phase 9 guardrails are real and written down in `AGENTS.md`, but they are prose a reviewer must remember.

**Owner journeys are not yet proved end to end.** The inventory in `docs/architecture/owner-journey-test-plan.md` defines 124 contracts and none exists yet. The precondition for all of them — an application-layer Codex seam — does not exist either.

## 2. Ground truth

Measured facts, so no packet has to re-derive them. Re-measure before starting, and update this table if the working tree has moved.

| Metric | Value | How to reproduce |
| --- | --- | --- |
| `AppModel.swift` lines | 12,511 | `wc -l Sources/SpeditoApp/AppModel.swift` |
| `ContentView.swift` lines | 613 | `wc -l Sources/SpeditoApp/ContentView.swift` |
| `AppModel` functions | 319 | `grep -c "func " Sources/SpeditoApp/AppModel.swift` |
| `AppModel` `@Published` | 34 | `grep -c "@Published" Sources/SpeditoApp/AppModel.swift` |
| `AppModel` `try?` | 122 | `grep -c "try?" Sources/SpeditoApp/AppModel.swift` |
| Task-launch sites, `AppModel` / `ContentView` | 1 / 2 | `grep -c "Task {\|Task(priority" <file>` |
| Longest function | `recoverOrphanedExecutionRuns`, 746 lines, 29 awaits | `AppModel.swift:6839` |
| Automated tests | 469 `@Test` declarations at `f4b0c37` | Count `@Test` declarations under `Tests/` |
| Schema versions | V1 → V13, in-place migrations | `Sources/SpeditoCore/Persistence/ProductDatabaseSchema.swift` |

What the delivery extraction actually produced: `TicketDeliveryRuntimeCoordinator` (556 lines) owns task lifecycle — registries, active turns, wake continuations, busy and snapshot state. The workflow transitions did not move. `executeImplementationRun` (405 lines), `resumeTechLeadReview` (371), `completeSprintTicketAcceptance` (355), `applyTechLeadReviewResult` (331), `reviewCompletedImplementation` (301), `handleServerRequest` (246), and `runIntegrationConflictResolution` (196) still create worktrees, run Codex turns, produce candidates, bind review, integrate, and accept — all inside `AppModel`. Of its 319 functions, 49 are delivery, 31 epic, 26 sprint.

By contrast, the large view files are not a problem and are out of scope: `BacklogView.swift` averages 83 lines per type and `SprintBoardView.swift` 237. Length there is composition, not concentration.

## 3. Sequence

```
Gate 0 (owner baseline)  ─┬─ P1 ledger        (docs only)
                          ├─ P2 ratchets      (CI only)
                          └─ P3 navigation    (docs only)
                                   │
                          P4 Codex seam  ─────┬─ P5 Epic journeys ── P6 delivery extraction
                                              └─ P7 UI spike ── P8 UI runner
                                                                       │
                                                            P9 P0 journey matrix
                                                                       │
                                                                 P10 close-out
```

Packets 1, 2, and 3 change no product code and may run before Gate 0 or in parallel with each other. Packet 4 blocks everything after it. Packet 7 is a decision gate: if the spike fails, packet 8 is cancelled and its rows become owner-verified, as recorded in section 7.1 of the journey plan.

Gate 0 is the stabilization plan's own open gate: Phase 0 owner inspection, the section 14.9 body-recomputation measurement, section 14.11 step 5, and the owner-approved known-good commit. A failing test-only reproduction that changes no production code is exempt.

## 4. Rules for every packet

1. One packet changes one coherent behavior or extracts one complete boundary. Never combine an extraction with a UX change.
2. Reproduce a defect with a failing test before fixing it.
3. Finish every call-site migration and delete the obsolete path inside the same packet. No parallel legacy and replacement paths.
4. Verify with `env SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test -Xswiftc -warnings-as-errors`, then `git diff --check`, then `./scripts/relaunch.sh` for any app-affecting packet, left running.
5. Asynchronous tests observe explicit operation events or continuations. Never a sleep.
6. Commit the accepted packet before starting an unrelated one. Do not rewrite history.
7. Report what was and was not validated. A packet with a failing suite is not complete.

## Packet 1 — Reconcile the stabilization ledger

**Problem.** Checked boxes claim work that the code contradicts, so the ledger cannot be trusted as a record of what is done.

**Scope.** `docs/architecture/stabilization-plan.md` only. No code.

**Steps.**

1. In Phase 6's work list, uncheck the four subdomain migrations that did not happen — implementation execution, candidate review, integration and conflict resolution, and acceptance — and uncheck "Remove migrated task registries and transition policy from `AppModel`". Add one sentence recording what *did* land: `TicketDeliveryRuntimeCoordinator` took task lifecycle ownership while transition execution stayed in `AppModel`, with the function names and line numbers from section 2 above.
2. In Phase 6's required journey tests, keep a box checked only where you can name the test that proves it. Uncheck the rest.
3. In Phase 7's candidate slices, uncheck "Ticket and epic conversations/refinement", "Epic planning and ticket suggestions", and "Sprint planning and goal generation". Evidence: `sendEpicConversationMessage` (`AppModel.swift:2809`), `runEpicClarificationTurn` (`:5465`), `generateEpicPlan` (`:5587`), `saveSprintPlan` (`:6475`), `generateAndSaveSprintGoal` (`:4808`). Leave the five genuinely completed slices checked.
4. In section 12, uncheck "Delivery execution, review, integration, and acceptance are Core-owned workflows" and "`AppModel` is an application composition/navigation boundary". Leave "`ContentView` is an application shell" checked; at 611 lines it is true.
5. In section 14.6, either record the query-count measurements its acceptance boxes claim or uncheck them. Do not leave the boxes checked against the status prose.
6. Add a short evidence block near the implementation-status section carrying the section 2 numbers, so the next reader can tell drift from progress.

**Acceptance.** Every checked box in the plan is defensible against the current code, and the status prose and the ledger agree.

## Packet 2 — Architecture ratchets in CI

**Problem.** The Phase 9 guardrails are review prose. Nothing fails a build when concentration returns, and history shows it returns.

**Scope.** `scripts/check_architecture_ratchets.sh`, a committed baseline file, and one CI step. No product code.

**Behavior.** The script computes the metrics below and compares them to the baseline. It fails when a value exceeds its baseline. It also fails when a value is *below* its baseline without the baseline being updated in the same commit, so improvements are locked in rather than quietly re-spent. Failure output names the metric, the baseline, the actual value, and the one-line fix.

| Metric | Baseline | Command |
| --- | --- | --- |
| `AppModel.swift` lines | 12484 | `wc -l < Sources/SpeditoApp/AppModel.swift` |
| `ContentView.swift` lines | 613 | `wc -l < Sources/SpeditoApp/ContentView.swift` |
| `AppModel` `@Published` | 34 | `grep -c "@Published" Sources/SpeditoApp/AppModel.swift` |
| `AppModel` `try?` | 122 | `grep -c "try?" Sources/SpeditoApp/AppModel.swift` |
| `AppModel` task sites | 1 | `grep -c "Task {\|Task(priority" Sources/SpeditoApp/AppModel.swift` |
| `ContentView` task sites | 2 | `grep -c "Task {\|Task(priority" Sources/SpeditoApp/ContentView.swift` |

**Steps.**

1. Write the script with no network access and no dependency beyond the shell and coreutils already used by `scripts/build_app.sh`.
2. Commit the baseline as data, not as constants inside the script, so lowering it is a one-line reviewable diff.
3. Add a CI step after the test step in `.github/workflows/ci.yml`.
4. Note in `AGENTS.md` that lowering a baseline is expected and raising one requires an explicit reason in the packet.

**Non-goals.** No cap on new files, no complexity metric, no source-layout assertions of the kind section 9 of the stabilization plan prohibits. These six numbers describe concentration in two known files, nothing more.

**Acceptance.** A commit that adds 200 lines to `AppModel.swift` fails CI with an actionable message, and a commit that removes 200 lines fails until the baseline is lowered.

## Packet 3 — Agent navigation map

**Problem.** `AGENTS.md` is strong on product language, permissions, execution model, and UX, but never says where a behavior lives. In a 130-file, 85,000-line codebase that is the difference between an agent editing the authority and an agent editing a caller.

**Scope.** One new section in `AGENTS.md`. No code.

**Steps.** Add a table mapping each feature to its state owner, its persistence operations, its main views, and its journey row IDs from the inventory. One row per feature, one line each, covering at least: product library and lifecycle, repository import, repository knowledge, remote repository, epics and suggestions, backlog and tickets, sprint planning, delivery, chat and notifications, knowledge, codebase and app versions, retrospectives and reports, settings and Codex. Add the rule that a packet introducing or moving a coordinator updates this table in the same commit.

**Acceptance.** An agent asked to change one behavior can name the owning file before opening anything.

## Packet 4 — Codex transport seam

**Problem.** No application-layer test can drive `AppModel` through a Codex turn. `codexClient` is a private concrete `CodexAppServerClient` (`AppModel.swift:816`) built inside the connect path (`:11679`); the existing test initializers (`:887`, `:911`) inject a store, registry, sound player, notifier, and remote feature but not Codex; and every scripted `CodexRPCTransport` fake lives in `Tests/SpeditoCoreTests/CodexAdapterTests.swift`.

**Scope.** An injectable transport factory on `AppModel`, extended test initializers, and one proof test. `CodexAppServerClient(transport:)` is the seam; do not introduce a second client abstraction.

**Steps.**

1. Give `AppModel` a transport factory dependency defaulting to the current production construction, so no production behavior changes.
2. Extend both test initializers to accept it.
3. Move or share a scripted `CodexRPCTransport` so both test targets can use it without duplicating the fixture.
4. Add one application-layer test that drives a scripted Codex turn through a public `AppModel` command and asserts both the presentation snapshot and the SQLite record.

**Acceptance.** An app-layer test completes a Codex-backed turn deterministically, with no sleep and no real process.

**Note.** This is shared infrastructure for all 124 journey rows, not Epic-specific work. Budget it as such.

## Packet 5 — Epic cross-Product journeys

**Problem.** The known defect: an Epic clarification result arriving while another Product is selected does not reliably return the owner to the exact Epic and its pending questions.

**Scope.** The three coordinator journeys in section 6 of the journey plan — clarification needs input across Products, plan ready across Products, and interruption with expired-thread recovery — implementing rows E02, E05, and E06.

**Steps.** Reproduce with a failing test before changing any production code. Assert presentation state and SQLite records. Include fresh-instance recovery and stale-result protection. Prove Product B's store contains neither the conversation nor the notification.

**Acceptance.** The defect is reproducible before the fix and protected after it, without launching a UI runner.

## Packet 6 — Delivery workflow extraction

**Problem.** Delivery transition execution is still in `AppModel`: roughly 2,700 lines across seven functions, including the 747-line `recoverOrphanedExecutionRuns`. This is the highest-risk region in the codebase and the reason `AppModel` did not shrink.

**Scope.** Phase 6 subdomains 2 through 5 — implementation execution, candidate review, integration and conflict resolution, acceptance and finalization — plus delivery recovery. The scheduler and task lifecycle already live in `TicketDeliveryRuntimeCoordinator`; do not rebuild them.

**Method, per subdomain, in this order.** Implementation execution, then candidate review, then integration, then acceptance, then recovery.

### Implementation execution state table

| Durable state | Entering command or event | SQLite evidence | Owner sees | Available actions | Relaunch recovery |
| --- | --- | --- | --- | --- | --- |
| Ready for admission | Starting the sprint creates one implementation `agent_run` for each frozen `sprint_item`; the scheduler admits only Tickets whose direct prerequisites are Done. | Active `sprints` row, frozen `sprint_items`, `work_items.state = queued`, and `agent_runs.status = queued`. | The Ticket remains **Ready to pick** until its admitted run begins. | Pause or stop the sprint. | `TicketDeliveryRuntimeCoordinator` reacquires the Product scheduler and admits the same queued run once. |
| Running in an isolated workspace | The workflow owner prepares or reuses `ticket/TN`, resumes or starts the Codex thread, persists both identities, and starts the structured turn. | `work_items.state = running`; `agent_runs.status = running` with `codex_thread_id` and `worktree_path`; permission requests and grants are separate durable rows. | **In progress**, bounded live activity, work log, and any permission request. | Stop work, pause or stop the sprint, answer a permission request, or add an informational comment. | A preserved workspace and thread resume. A missing workspace resets the execution context and records the data-loss boundary; a missing thread is replaced while preserving the workspace. |
| Needs product owner input | A valid structured result asks a question, or a scoped permission request pauses the turn. | `agent_runs.status = awaiting_owner`; attributed work-log question and options or an active `agent_permission_requests` row. | Inline **Needs your input** on the Ticket, never a separate lane. | Submit an answer, allow or deny exact access, pause, or stop. | The pending question or permission is reconstructed from SQLite and the same run is queued only after the owner decides. |
| Preserved retry | A turn fails, is interrupted manually, or is suspended by pause/shutdown. | The same `agent_runs` row is `failed`, `interrupted`, or `queued`; its thread/worktree identities remain; a labelled system work-log entry records the cause. | A recoverable error or **Retry work** with the preserved work log. | Add direction and retry; resume the sprint when paused; stop the sprint. | Retry requeues the same run. Shutdown and pause recovery preserve the same workspace/thread; no second run or completed transition is created. |
| Candidate produced | A completed structured result passes evidence validation and the workflow owner snapshots an immutable candidate. | `agent_runs.status = completed`; `candidate_revisions` contains the exact base/head, worktree, result, and delivery kind; the delivery note and knowledge proposals are durable; `work_items.state = integrating`. | The Ticket moves to **In review** and exposes the candidate handoff. | Await integration and review; later review actions belong to the candidate-review subdomain. | The scheduler derives the next integration/review command from the candidate row, not in-memory completion state. |
| Stopped | The product owner confirms **Stop sprint**. | `agent_runs.status = cancelled`; unfinished Tickets return to their persisted planning state while work logs and workspaces remain auditable. | The sprint is stopped; Done work remains Done and unfinished work is available for replanning. | Start a later sprint from eligible Backlog Tickets. | Stopped runs are not auto-admitted after relaunch. |

1. Write the state table first, from current code and tests, using the section 11 template. Name every durable intermediate state, its entering command, its SQLite evidence, what the owner sees, available actions, and recovery.
2. Write or complete that subdomain's journey rows from the inventory *before* moving code: D01–D02 and D10 for implementation, D11 for review, D12 for integration, D17–D19 for acceptance, D04–D05 and A11 for recovery.
3. Move the transitions into a Core workflow owner. Keep `AppModel` as the caller.
4. Migrate every call site and delete the obsolete path.
5. Full verification and relaunch. One commit per subdomain. Never one combined cutover.

**Non-goals.** No change to owner-facing delivery behavior, permission semantics, worktree layout, or review rules. No splitting of view files. No new module boundary.

**Acceptance.** `AppModel` no longer executes delivery workflow transitions, the Phase 6 boxes unchecked in packet 1 can be checked again with named tests, and the packet 2 baseline for `AppModel.swift` drops by thousands of lines.

## Packet 7 — UI runner spike

**Problem.** Section 7 of the journey plan commits 7–12 days to a launched-process harness whose CI feasibility is unproven. macOS XCUITest needs a real GUI session, a signed bundle, and automation permission; CI runs `swift test` only.

**Scope.** One trivial launch-and-assert test against the `scripts/build_app.sh debug` bundle, in the target CI environment, using a UI-test bundle with no second application target and a distinct bundle identifier.

**Acceptance.** A decision, recorded in the journey plan: proceed to packet 8, or cancel it and mark the 19 `Shell = Y` rows owner-verified without weakening their coordinator proofs.

## Packet 8 — UI runner and proving contract

Conditional on packet 7. Implements sections 7.2 to 7.4 and the section 6.4 contract of the journey plan: debug-only composition, fixture control, the accessibility identifiers the Epic test needs, and the injectable owner-notification banner interval that removes the eight-second wall-clock dependency at `ContentView.swift:607`.

## Packet 9 — P0 journey matrix

Implements the P0 rows in the order given by work packet 3 of the journey plan, starting with A09 schema migration. Applies the deduplication rule: record which of the 464 existing tests already cover part of a row and implement only the uncovered composition. Names each test for its row ID.

## Packet 10 — Close-out

1. Mark the stabilization plan complete, or state precisely what remains.
2. Move any approved future product behavior into `docs/product-spec.md`.
3. Update `docs/technical-design.md` with the delivery boundaries actually implemented.
4. Confirm every ratchet baseline reflects the improved code.

## Definition of done

- [ ] Every checked box in the stabilization plan is defensible against the code.
- [ ] CI fails when `AppModel` or `ContentView` concentration regrows.
- [ ] `AGENTS.md` names the owner of every feature.
- [ ] An application-layer test can drive a scripted Codex turn.
- [ ] The cross-Product Epic defect has a failing-then-passing journey test.
- [ ] `AppModel` executes no delivery workflow transition.
- [ ] The UI runner question is decided either way and recorded.
- [ ] Every P0 journey row has a named test, or a recorded reason it does not.
- [ ] Full suite passes with warnings as errors; `git diff --check` passes; the app has been relaunched and left running.

## What this plan does not authorize

- Splitting `SprintBoardView`, `BacklogView`, `TicketDetailView`, or `Models.swift`. They are compositions of small types and are not a regression source.
- A new module boundary. That comes after delivery extraction, not before.
- Converting existing component tests into UI tests, or adding a launched-process test for any row not marked `Shell = Y`.
- Any owner-facing behavior change made in the name of simplification.
- Rewriting history to create a checkpoint.
