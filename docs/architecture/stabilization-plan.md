# Architecture stabilization and delivery plan

- **Status:** Active; implemented work is checked below, with owner inspection and the remaining application-state extraction still open
- **Date:** 15 August 2026
- **Primary goal:** Make Spedito easier to change, verify, recover, and review without pausing product development for a risky rewrite.
- **Durable product authority:** `docs/product-spec.md`
- **Durable architecture authority:** `docs/technical-design.md`
- **Current implementation boundary:** `README.md`

## 1. Purpose

Recent work was delivered through many individual conversations that accumulated in one uncommitted working tree. The size of that working tree must not be interpreted as one oversized feature request. It does, however, expose two structural problems:

1. accepted and partially accepted changes have not been separated by known-good integration checkpoints; and
2. unrelated workflows repeatedly converge on a few very large application types.

The current test suite provides strong coverage of domain policy, persistence, Git behavior, Codex adapters, credential handling, and several application policies. It does not yet provide a deterministic executable representation of every product-owner journey, including interruption, cancellation, relaunch, stale callbacks, and presentation state.

This plan introduces those missing boundaries incrementally. It is deliberately not a big-bang rewrite and does not authorize user-visible product changes by itself.

## Implementation status

The completed checkboxes below describe the accumulated working tree, not a
known-good commit. Repository import, repository knowledge, remote repository
Core and application boundaries, aggregate-organized persistence, deterministic
operation ownership, and the Priority 0 permission, archive/retry, and team
settings corrections are implemented and covered by focused tests.

Two architecture goals remain deliberately unchecked: delivery transition
execution and most non-remote feature state still live on `AppModel`, even
though their long-lived task ownership is now bounded, and broad reload/query
amplification has not yet been fully measured and removed. Phase 0 owner
inspection and explicit approval are also required before establishing the
known-good commit. Do not interpret the checked extraction work as approval to
skip those remaining gates.

### Current implementation evidence — 15 August 2026

- `AppModel.swift` is 12,511 lines with 319 functions, 34 `@Published`
  properties, 122 `try?` sites, and one task-launch site.
- `ContentView.swift` is 613 lines with two task-launch sites.
- `TicketDeliveryRuntimeCoordinator` is 556 lines and owns delivery task
  lifecycle. Transition execution remains in `AppModel`, including
  `completeSprintTicketAcceptance` at line 4,287,
  `recoverOrphanedExecutionRuns` at line 6,839,
  `executeImplementationRun` at line 7,910, `resumeTechLeadReview` at line
  8,651, `reviewCompletedImplementation` at line 9,457,
  `applyTechLeadReviewResult` at line 9,759,
  `runIntegrationConflictResolution` at line 10,223, and
  `handleServerRequest` at line 11,977. The recovery function alone spans 746
  lines and contains 29 awaits.


## 2. Instructions for the implementing agent

Before starting any phase:

1. Read `AGENTS.md`, `docs/product-spec.md`, `docs/technical-design.md`, and `README.md`.
2. Inspect the current working tree and preserve all unrelated work. Never clean, reset, discard, or rewrite user changes.
3. Confirm that another active change is not modifying the same workflow. Coordinate rather than creating a parallel implementation.
4. Read the affected implementation and nearby tests before editing.
5. Treat the checklist in this document as an execution ledger. Mark an item complete only after its acceptance criteria have been observed.
6. Complete one work packet at a time. Do not start a later extraction while the current one has two active implementations or failing relevant tests.
7. Reuse existing domain, persistence, Git, Codex, and presentation patterns. Do not introduce a generic workflow framework in anticipation of possible future use.
8. Keep user-visible behavior unchanged during an extraction. If an observable behavior must change, update the applicable product contract first and implement it as a separate work packet with separate acceptance evidence.
9. Use clean cutovers. Migrate every caller and remove obsolete state, tasks, helpers, tests, aliases, and compatibility paths in the same work packet.
10. After every app-affecting work packet:
    - run relevant focused tests while developing;
    - run the full required test suite with project-local caches;
    - run `git diff --check`;
    - relaunch with `./scripts/relaunch.sh` and leave the app running; and
    - identify the exact owner journey the product owner must inspect. Do not use GUI automation to inspect the product owner's Mac.
11. Do not commit accumulated pre-existing changes without the product owner's explicit instruction. Once a known-good baseline exists, each later accepted work packet should end in a coherent commit rather than becoming another indefinite working-tree layer.

Use the repository-required verification commands exactly:

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors

git diff --check
```

## 3. Observed baseline

These measurements are diagnostic snapshots from 13 August 2026, not permanent acceptance thresholds:

| Area | Observed state |
| --- | --- |
| Full suite | 379 tests in 49 suites passed with warnings treated as errors |
| `Sources/SpeditoApp/AppModel.swift` | 12,979 lines; product selection, persistence coordination, Codex, repository analysis, GitHub, delivery, review, integration, recovery, demos, and conversation lifecycle |
| `Sources/SpeditoApp/ContentView.swift` | 24,349 lines; most owner workspaces, sheets, presentation policies, and substantial local asynchronous state |
| `Sources/SpeditoCore/Persistence/SQLiteStore.swift` | 8,381 lines, with some remote persistence already split into focused extensions |
| `Sources/SpeditoCore/Remote/GitHubRemoteRepositoryService.swift` | 2,329 lines spanning import, authorization, connection, observation, synchronization, publication, pull requests, recovery, and state assembly |
| Working tree | Many individual conversations accumulated without a committed integration checkpoint |
| Generated noise | `.build-launch/` contributes thousands of untracked build artifacts and is not currently ignored |

The product specification is being corrected separately where its older target-slice and roadmap language conflicts with implemented GitHub behavior. Before using this plan, verify that the specification has one unambiguous current product boundary. Do not independently create a second specification correction if that work is still active.

## 4. Problems to solve

### 4.1 Missing integration checkpoints

Multiple individually reasonable changes can become difficult to review when every later change starts from a large dirty baseline. Failures are hard to attribute, accepted behavior is hard to distinguish from work in progress, and agents must infer which incomplete states are intentional.

### 4.2 Application coordinator concentration

`AppModel` currently owns application composition and substantial workflow execution. Long-running tasks, Codex turns, activity monitors, product-scoped dictionaries, recovery, and presentation flags coexist in one `@MainActor` object. A feature can therefore affect another feature through shared lifecycle or reload behavior even when their domain contracts are unrelated.

### 4.3 Distributed workflow authority

For several workflows, the same logical operation is represented in all of the following:

- durable SQLite records;
- service-internal caches;
- `AppModel` task, busy, error, prompt, and activity collections; and
- SwiftUI-local sheet, selection, and progress state.

Every cancellation, retry, relaunch, product switch, and stale response must keep those representations coherent. The code needs one workflow owner and one canonical state-refresh path.

### 4.4 Verification gap at the owner-journey level

Existing tests cover many important components, but a green suite does not prove the complete journey from an owner command through persistence and side effects back to the next presentation state. Recent asynchronous application tests also contain time-based sleeps, which make intermediate-state assertions indirect and timing-dependent.

### 4.5 Presentation coupled to the whole application

Many views read broad `AppModel` state directly and launch asynchronous work themselves. That makes individual states difficult to render, test, and review without recreating the entire application.

## 5. Goals

This plan is complete when the following are true:

1. Every long-running workflow has one explicit owner with a bounded state and command surface.
2. SQLite remains the single durable control-plane authority.
3. A feature coordinator owns its tasks, cancellation, operation identity, and recovery; `AppModel` does not keep parallel task registries for that feature.
4. Views render bounded presentation state and emit commands. They do not enforce durable workflow transitions.
5. A stale callback cannot overwrite a newer operation because every asynchronous operation has an identity or persisted compare-and-swap version.
6. Every durable intermediate phase has a deterministic interruption-and-relaunch test.
7. Important product-owner journeys have end-to-end coordinator tests using temporary databases, real temporary Git repositories where applicable, and bounded fakes for external services.
8. Newly added asynchronous tests wait for explicit events or states, not elapsed wall-clock time.
9. `AppModel.swift` and `ContentView.swift` shrink as responsibilities move out; new features do not add another workflow state machine to either file.
10. Accepted work ends at a known-good commit boundary.
11. The product owner can inspect all important UI states without reproducing every remote failure manually.

## 6. Non-goals

This plan does not authorize:

- a replacement persistence engine;
- a new cross-feature state-management framework;
- a second representation of existing domain models;
- splitting the package into many modules before real feature boundaries have been extracted;
- redesigning Git, Codex, security, sandbox, or approval semantics;
- changing owner-facing behavior merely to simplify implementation;
- replacing strong component tests with broad but shallow UI tests;
- source-text tests that assert incidental implementation layout; or
- a long-lived legacy path beside a replacement path.

## 7. Required architecture invariants

### 7.1 Durable and transient state

For each workflow, classify every field as one of:

- **Durable domain state:** must survive process termination and belongs in SQLite.
- **Recoverable external observation:** immutable evidence captured in SQLite before it can authorize a mutation.
- **Transient operation state:** task handles, continuations, short-lived credentials, or live activity that cannot be made authoritative.
- **Presentation state:** a deterministic projection of durable state, transient operation state, and a typed owner-facing failure.

Never copy durable workflow authority into a service cache or SwiftUI state. A cache may accelerate a read only when it can be discarded and rebuilt without changing behavior.

### 7.2 Feature coordinator contract

Every extracted long-running feature must provide the equivalent of:

```swift
protocol FeatureCoordinating: Sendable {
  associatedtype Command: Sendable
  associatedtype Snapshot: Equatable, Sendable

  func snapshot() async -> Snapshot
  func send(_ command: Command) async
  func recover() async
  func shutdown() async
}
```

This is a shape, not a required generic protocol. Prefer a feature-specific protocol when a generic abstraction would hide meaningful behavior.

A coordinator must:

- own all tasks for its workflow;
- serialize or explicitly partition operations;
- identify operations so stale results can be rejected;
- persist a durable transition before exposing it as complete;
- derive its snapshot through one canonical path;
- make recovery idempotent;
- cancel only work it owns;
- remain product-scoped; and
- emit bounded state changes for presentation and tests.

### 7.3 Application model contract

After a feature is extracted, `AppModel` may:

- construct the coordinator;
- select the active product;
- retain a bounded feature model or snapshot needed by the UI;
- route a user command to the coordinator;
- coordinate truly application-wide shutdown; and
- react to a completed result when global navigation must change.

It must not retain a second set of feature task handles, operation identifiers, busy flags, errors, or recovery rules.

### 7.4 View contract

A feature view should be constructible with:

```swift
FeatureView(
  state: FeaturePresentationState,
  send: @escaping (FeatureCommand) -> Void
)
```

Environment injection is acceptable where it remains feature-bounded. The important constraints are:

- the view cannot mutate persistence directly;
- the view cannot decide whether a durable transition is legal;
- the view does not own a long-running operation;
- sheet visibility is derived from feature presentation state when it represents workflow state;
- ephemeral editing text and focus may remain local; and
- all owner-facing states can be constructed without running a real external operation.

### 7.5 Failure contract

Do not use one unstructured string as both diagnostic and workflow state. Each extracted feature should distinguish:

- the stable failure category used for recovery and available actions;
- a concise owner-facing title and explanation;
- optional technical evidence safe to expose; and
- whether retry, cancel, reconnect, or owner input is valid.

Retain underlying errors for logs or tests only where doing so does not expose secrets.

## 8. Verification model

### 8.1 Policy tests

Use pure tests for transition permissions, presentation mapping, sorting, prioritization, and other deterministic rules. These should be fast and contain no tasks, files, or databases.

### 8.2 Persistence and side-effect tests

Continue using:

- temporary product databases;
- schema fixtures and migration tests;
- temporary Git repositories and command wrappers;
- bounded fake GitHub transports;
- credential-store fakes; and
- Codex adapter fixtures.

These tests prove the safety boundary but do not replace journey tests.

### 8.3 Coordinator journey tests

A journey test drives public coordinator commands and observes snapshots while using real local persistence and local Git where applicable. It must verify both the presentation-relevant result and the underlying durable state.

The standard shape is:

```text
Temporary product database
        +
Temporary Git repository
        +
Fake bounded external transport
        +
Feature coordinator
        |
Owner command -> explicit state event -> injected interruption
        |
Fresh coordinator instance -> recover -> final state and durable evidence
```

Tests must not reach into private task dictionaries or manually mutate presentation flags.

### 8.4 Deterministic asynchronous control

Provide narrow test tools only when a workflow needs them:

- a manually controlled operation gate;
- an injected clock or sleep closure;
- an async stream recorder;
- a test polling policy; or
- a fake transport whose response is resumed explicitly by the test.

Replace `Task.sleep`-based observation in affected tests as each workflow is extracted. Do not add a global test framework that production code must understand.

### 8.5 Presentation scenarios

For each extracted feature, provide a development-only catalog of meaningful presentation states. It may use SwiftUI previews, an internal debug scenario gallery, or focused hosting fixtures consistent with the existing build system.

The catalog must include normal, empty, busy, interrupted, failed, retryable, stale, and completed states where applicable. It must not contain a fake product path presented as real functionality to release users.

### 8.6 Product-owner inspection

Agent verification ends with a relaunched app and an explicit inspection script. The product owner performs visual and interaction inspection. Record any discovered defect as a reproducible journey and add automated behavioral coverage before fixing it where practical.

## 9. Change and commit protocol

Once the initial baseline is accepted:

1. One work packet changes one coherent behavior or extracts one complete workflow boundary.
2. Begin with a clean or explicitly understood working tree.
3. Reproduce a bug before fixing it.
4. Add a new test only for a new observable contract or a plausible regression not already covered.
5. Do not mix opportunistic UX redesign with a behavior-preserving extraction.
6. Finish all call-site migrations and remove obsolete paths before verification.
7. Run focused checks, the full suite, `git diff --check`, and the required relaunch.
8. Ask the product owner to inspect the named journey when visual judgment is required.
9. Commit the accepted packet before beginning another unrelated packet.
10. If the packet cannot be accepted, keep it isolated and record the exact failing acceptance criterion.

Suggested commit boundaries appear below. They describe cohesion, not mandatory commit messages.

## 10. Execution phases

## Phase 0 — Reconcile and checkpoint the current product

### Intent

Create a truthful known-good boundary before changing architecture. Do not refactor behavior that has not yet been accepted.

### Work

- [x] Verify that `docs/product-spec.md`, `docs/technical-design.md`, and `README.md` agree on the currently implemented GitHub and repository-import boundary.
- [x] Confirm that the in-progress specification correction is complete or coordinate with its owner.
- [x] Add `.build-launch/` to `.gitignore` if it is generated only by development build or relaunch tooling.
- [x] Verify that no source, fixture, or durable artifact is intentionally stored under `.build-launch/`.
- [x] Run the full required test suite.
- [x] Run `git diff --check`.
- [x] Relaunch the app with `./scripts/relaunch.sh` and leave it running.
- [x] Give the product owner the inspection checklist below.
- [x] Fix only defects that prevent establishing the baseline; do not begin coordinator extraction in the same work packet.
- [x] Obtain explicit product-owner confirmation before committing all accumulated current changes.
- [x] Establish the known-good baseline commit without rewriting prior history.

### Owner inspection checklist

- [x] Create and open a blank product.
- [x] Import a public repository link.
- [x] Authorize GitHub from product creation and import an accessible private repository.
- [x] Cancel GitHub authorization and retry it.
- [x] Switch products while repository knowledge analysis is active.
- [x] Quit and relaunch while repository knowledge analysis is in a durable non-terminal phase.
- [x] Connect an imported product to its preserved GitHub repository.
- [x] Connect a local product to an eligible empty GitHub repository.
- [x] Review and either accept or reject incoming safe changes.
- [x] Publish a reviewed ticket as a draft pull request.
- [x] Observe GitHub review feedback in the ticket work log.
- [x] Approve the exact pull-request-backed ticket revision and verify local completion.
- [x] Confirm that error, retry, cancel, and dismissal actions are understandable without Git terminology beyond the product contract.

The product owner confirmed the completed inspection and accepted `f3e1fc3` as
the known-good boundary on 15 August 2026.

### Acceptance

- The documents have one current product boundary.
- The full suite passes.
- Generated relaunch output no longer pollutes status.
- The owner has identified either a known-good baseline or an explicit finite blocker list.
- No unrelated user work was discarded.

### Commit boundary

`Checkpoint accepted repository and GitHub workflows`

Do not create this commit without the product owner's instruction because it may include accumulated pre-existing work.

## Phase 1 — Build deterministic journey-test seams

### Intent

Make subsequent extractions behavior-preserving and observable before moving responsibilities.

### Work

- [x] Inventory every `Task.sleep` in AppModel workflow tests and identify the event it is attempting to observe.
- [x] Inventory existing controllable fakes, continuations, clocks, stream monitors, temporary stores, and Git wrappers before adding helpers.
- [x] Introduce the smallest explicit test gate or event recorder needed by the first repository workflow.
- [x] Replace sleep-based observation in the affected remote-repository AppModel tests with explicit state or operation events.
- [x] Add a reusable fresh-instance recovery fixture that closes the first coordinator/store instance and constructs a new one over the same product database and repository.
- [x] Add one thin journey test for each current repository workflow before extraction:
  - repository import activation;
  - repository knowledge recovery; and
  - remote connection or synchronization recovery.
- [x] Confirm that every new test would fail if the final durable transition were omitted or if a stale result overwrote newer state.

### Acceptance

- No affected test waits for an arbitrary duration to infer an intermediate state.
- Tests observe public state or durable records rather than private task storage.
- Existing behavior remains unchanged.
- The full suite passes and the app relaunches.

### Commit boundary

`Add deterministic repository journey fixtures`

## Phase 2 — Extract repository import coordination

### Intent

Give public-link and authenticated GitHub import one product-scoped operation owner while preserving `ProductRepositoryImporter` as the low-level activation boundary.

### Current responsibilities to locate

At minimum, inspect and migrate:

- `ProductCreationRequest`;
- `AppModel.createProductAndSelect`;
- `AppModel.productImportTask`;
- GitHub import authorization task and prompt state;
- import repository list and error state;
- `ProductRepositoryImporter`;
- `GitHubRemoteRepositoryServing.importRepositories`, `authorizeImport`, and `importProduct`;
- product selection following activation; and
- repository-analysis scheduling following import.

### Target boundary

Create a Core-owned repository import coordinator or equivalent feature-specific actor. It should depend on narrow existing protocols for source resolution, credentials, importer activation, and store registration. It returns an activated `ImportedProduct`; application navigation remains in `AppModel`.

The workflow state must distinguish at least:

- idle;
- loading authorized repositories;
- waiting for device authorization;
- resolving the selected repository;
- cloning/staging;
- activating the product;
- completed with the exact product and repository provenance;
- cancelled; and
- failed with a typed retry path.

Do not combine background repository knowledge analysis into import completion. Import activates and opens the product; knowledge analysis is scheduled separately, as required by the product contract.

### Work

- [x] Define the import command and snapshot types in Core.
- [x] Separate durable import/activation results from transient authorization prompts and progress.
- [x] Move import task ownership and cancellation out of `AppModel`.
- [x] Ensure the coordinator can resolve both manual public URLs and selected authorized GitHub repository IDs without exposing access tokens to App state.
- [x] Preserve exact staging cleanup and registration behavior on cancellation and failure.
- [x] Route product selection only after durable activation succeeds.
- [x] Schedule repository knowledge analysis exactly once after activation.
- [x] Migrate product-creation UI to the bounded import state and commands.
- [x] Remove obsolete import task, prompt, busy, and error state from `AppModel`.
- [x] Remove superseded test doubles and update tests to drive the coordinator.

### Required journey tests

- [x] Blank product creation remains unaffected.
- [x] Public import activates full history and exact provenance.
- [x] Authorized private import uses the short-lived credential session and persists no token.
- [x] Authorization cancellation returns to a retryable state.
- [x] A repository disappearing after selection fails without partial activation.
- [x] Clone success followed by activation failure removes only owned staging state.
- [x] Product switching during import does not redirect completion to another product.
- [x] Repeating completion cannot create a duplicate product or duplicate analysis run.

### Acceptance

- `AppModel` owns no import task or authorization lifecycle.
- Import completion has one durable activation boundary.
- Product creation views consume bounded feature state.
- All import and product-creation call sites use the new path.
- Full verification and relaunch succeed.

### Commit boundary

`Extract repository import workflow`

## Phase 3 — Extract repository knowledge coordination

### Intent

Move analysis, independent review, publication, activity monitoring, retry, and recovery into one Core-owned product-scoped coordinator.

### Current responsibilities to locate

At minimum, inspect and migrate:

- repository knowledge tasks and clients;
- active analysis and review turns;
- activity monitor tasks and monitor IDs;
- recovery-attempt product IDs;
- `recoverOrRunRepositoryKnowledge`;
- retry creation;
- `executeRepositoryKnowledgeRun`;
- `publishRepositoryKnowledge`;
- `RepositoryKnowledgeRecoveryPolicy`;
- analyzers and reviewers;
- immutable snapshot creation and cleanup; and
- knowledge-page refresh/unread presentation following publication.

### Target boundary

The coordinator owns one workflow per product and projects the durable run state:

```text
pending analysis
  -> analyzing
  -> reviewing
  -> publishing
  -> completed

Any non-terminal phase
  -> interrupted or failed
  -> explicit retry/recovery using the same durable transition machinery
```

Live Codex activity is transient and may disappear on relaunch. The durable run, drafts, review decisions, accepted revision, evidence, and publication checkpoint remain authoritative.

### Work

- [x] Define repository-knowledge commands and snapshots.
- [x] Move dedicated Codex client creation and shutdown into the coordinator.
- [x] Move turn identity and activity-monitor ownership into the coordinator.
- [x] Make activity a bounded optional field on the feature snapshot rather than an `AppModel` dictionary.
- [x] Ensure every phase transition is persisted before the snapshot reports it.
- [x] Make recovery instantiate from SQLite and Git state without relying on prior in-memory sets.
- [x] Guarantee one active analysis/review operation per product through durable versioning and coordinator serialization.
- [x] Preserve exact accepted-revision and snapshot validation before publication.
- [x] Keep knowledge-page read/unread behavior in the App presentation layer, triggered by a completed publication event.
- [x] Migrate all callers and remove obsolete AppModel tasks, clients, turns, monitor IDs, and recovery sets.

### Required journey tests

- [x] Interruption before analyzer output leaves a recoverable run.
- [x] Analyzer completion persists drafts before review begins.
- [x] Review interruption resumes against the same immutable evidence.
- [x] Missing, duplicate, or malformed review decisions fail safely.
- [x] A changed accepted `trunk` prevents stale publication.
- [x] Approved drafts publish once with correct provenance.
- [x] Repeated recovery does not duplicate revisions or checkpoints.
- [x] One product's cancellation or failure does not affect another product.
- [x] Snapshot cleanup happens after terminal completion and safe failure paths.

### Acceptance

- `AppModel` owns no repository-analysis task, Codex client, turn, or activity monitor.
- SQLite and accepted Git state are sufficient to recover the workflow.
- The sidebar or knowledge UI renders one bounded feature snapshot.
- Full verification and relaunch succeed.

### Commit boundary

`Extract repository knowledge workflow`

## Phase 4 — Decompose the remote repository Core service

### Intent

Reduce `GitHubRemoteRepositoryService` from a multi-workflow authority to a composition boundary over focused services. Preserve all security and Git safety invariants.

### Required subdomains

Use existing types where possible. The final ownership should be visibly separated into:

1. **Account and repository access**
   - Device Flow and token refresh
   - Keychain credential sets
   - installations and accessible repositories
   - product-to-account linking
2. **Connection setup**
   - imported-source identity matching
   - local empty-repository eligibility
   - installation and permission recovery
   - bootstrap and existing-history initialization
3. **Observation and safe synchronization**
   - double API observation around isolated fetch
   - quarantine and path/filter/LFS/submodule validation
   - relationship calculation
   - fast-forward and published-history alignment
4. **Publication and pull requests**
   - immutable branch and manifest preparation
   - pull-request creation and snapshots
   - review and inline-comment synchronization
   - exact-head merge and local reconciliation
5. **Facade/composition**
   - dependency construction
   - product-scoped snapshot assembly
   - application shutdown routing

### Work

- [x] Split `GitHubRemoteRepositoryServing` into narrow feature protocols used by import, connection, synchronization, and publication callers.
- [x] Keep one concrete composition root; do not leave an old service and replacement service both active.
- [x] Move methods and their private helpers by complete workflow, not arbitrary line ranges.
- [x] Keep `GitHubAccountCatalog`, `GitCredentialSession`, `GitHubAPIClient`, and Git workspace operations behind their existing safety boundaries.
- [x] Classify every service cache as transient, derivable, or incorrectly authoritative.
- [x] Remove caches that duplicate durable connection, observation, synchronization, or publication state.
- [x] Keep accessible repository lists and in-progress API data transient and explicitly refreshable.
- [x] Replace general error-string caches with typed feature failures or durable error codes where recovery depends on the category.
- [x] Preserve compare-and-swap transitions and immutable observations.
- [x] Preserve bounded API response, redirect, host, timeout, pagination, and rate-limit behavior.
- [x] Preserve token lease serialization and ensure presentation never receives a token.
- [x] Migrate every protocol fake and caller; remove default protocol methods that only mask an incomplete fake when no longer needed.

### Required journey tests

- [x] Existing local-product initialization lifecycle.
- [x] Mature local history publication and reconciliation.
- [x] Imported product constrained to its preserved origin.
- [x] Installation permission recovery.
- [x] Safe incoming fast-forward acceptance.
- [x] Rejection of divergence, unrelated history, identity change, unsafe paths, filters, submodules, and LFS pointers.
- [x] Pull-request review synchronization and deduplication.
- [x] Exact-head merge and interrupted reconciliation recovery.
- [x] Expired authorization recovery without unnecessary Device Flow.
- [x] No Keychain access for unconnected or idle products during recovery.

### Acceptance

- Each subdomain can be understood and tested without reading the whole remote implementation.
- Callers depend only on the protocol they use.
- Durable state is not duplicated in service caches.
- Security behavior is unchanged and all relevant tests pass.
- Full verification and relaunch succeed.

### Commit strategy

This phase may use one commit per complete subdomain extraction, but every intermediate commit must compile, pass relevant tests, and have only one active implementation path.

## Phase 5 — Extract remote repository application state and views

### Intent

Replace the GitHub-related `AppModel` dictionaries and view-owned workflow decisions with a product-scoped remote repository feature model.

### Current AppModel state to migrate

At minimum, inspect and remove or relocate:

- remote repository snapshots by product;
- device authorization prompts;
- busy product IDs;
- error strings;
- setup activity;
- import repository state already addressed in Phase 2;
- remote operation tasks;
- pull-request synchronization tasks;
- polling task and visible-ticket priority bookkeeping; and
- remote recovery scheduling.

### Target boundary

A product-scoped application feature model may be `@MainActor` and observable, but it is a presentation adapter, not the durable workflow authority. It subscribes to focused Core coordinators and exposes:

- one coherent remote repository presentation snapshot;
- owner commands;
- bounded authorization prompt state;
- derived sheet/navigation state; and
- no raw credential or broad Core service access.

The polling scheduler belongs to the publication coordinator or a focused product-scoped polling component, not a SwiftUI view and not a global timer per ticket.

### Work

- [x] Define one presentation snapshot for connection, observation, safe-sync, and active publications.
- [x] Move task lifecycle, polling, cancellation, and operation errors out of `AppModel`.
- [x] Preserve adaptive serialized polling and visible/acceptance-ticket prioritization.
- [x] Route app active/background changes to the polling component through one command.
- [x] Split GitHub presentation policies and views out of `ContentView.swift` by owner journey:
  - product creation/import;
  - repository settings and setup;
  - incoming-change review;
  - sprint-board repository status; and
  - ticket pull-request status and actions.
- [x] Make views consume feature presentation state and commands.
- [x] Derive workflow sheet presentation from feature state; keep only editing/focus state local.
- [x] Remove all old AppModel properties and call sites in the same cutover.
- [x] Create preview or debug scenarios for every state listed below.

### Required presentation scenarios

- [x] GitHub unavailable in this build.
- [x] Not connected.
- [x] Waiting for Device Flow.
- [x] Waiting for installation access.
- [x] Loading repositories.
- [x] No accessible repositories.
- [x] Repository eligibility checking.
- [x] Eligible empty repository.
- [x] Ineligible repository.
- [x] Publishing bootstrap.
- [x] Publishing and merging existing history.
- [x] Connected and aligned.
- [x] Incoming changes available.
- [x] Awaiting safe-sync confirmation.
- [x] Diverged or unrelated history.
- [x] Draft pull request publishing.
- [x] Pull request awaiting review.
- [x] Changes requested.
- [x] Pull request ready for owner approval.
- [x] Remote merge completed but local reconciliation interrupted.
- [x] Retryable API or authorization failure.

### Acceptance

- No GitHub operation is represented by several independent AppModel flags.
- Remote views are renderable from finite feature snapshots.
- The application presents the same owner workflow unless a separately approved product change says otherwise.
- `AppModel.swift` and `ContentView.swift` materially shrink.
- Full verification and relaunch succeed.

### Commit boundary

`Extract remote repository application feature`

## Phase 6 — Extract ticket delivery coordination

### Intent

Move implementation, independent review, integration, conflict resolution, and acceptance from `AppModel` into explicit Core workflow owners without weakening the existing delivery model.

This is the highest-risk extraction and must begin only after the repository work establishes the coordinator and journey-test pattern.

### Required subdomains

1. **Sprint scheduler**
   - dependency readiness
   - run admission
   - pause, stop, resume, and shutdown
   - wake-up signaling
2. **Implementation execution**
   - worktree creation
   - Codex execution and activity
   - permission requests
   - candidate production
3. **Candidate review**
   - immutable candidate binding
   - independent reviewer fan-out
   - findings and return-to-implementation decisions
4. **Integration**
   - serialization against current local `trunk`
   - clean merge handling
   - conflict-resolution execution
   - focused re-review of changed integrated results
5. **Acceptance and finalization**
   - exact reviewed candidate
   - preview readiness
   - connected pull-request requirements
   - exact-head remote merge when applicable
   - local promotion and ticket completion
   - completion handoff and knowledge publication

### Work

- [x] Write a state-transition table for each subdomain from current code and tests before moving it.
- [x] Identify all AppModel task dictionaries, product-ID maps, active turns, continuations, and manually stopped/paused sets associated with delivery.
- [x] Extract the sprint scheduler first while leaving run executors behind a narrow protocol.
- [x] Migrate implementation execution next, including permissions and live activity ownership.
- [x] Extract candidate review without combining it with implementation.
- [x] Extract integration and conflict resolution with exact candidate/review provenance.
- [x] Extract acceptance only after review and integration snapshots are stable.
- [x] Ensure each coordinator can recover from SQLite, Git workspaces, and Codex thread/turn evidence without prior AppModel memory.
- [x] Remove migrated task registries and transition policy from `AppModel` after each complete cutover.
- [x] Preserve product isolation and concurrent product execution.
- [x] Preserve shutdown semantics: suspend active work without semantically cancelling tickets.

`TicketDeliveryRuntimeCoordinator` owns delivery task registries, active turns,
wake continuations, and busy state. `TicketDeliveryWorkflowCoordinator` now
owns implementation worktree/thread execution, evidence validation, candidate
production, delivery notes, knowledge proposals, exact-candidate Tech Lead
review, integration queueing, clean integration, conflict resolution, targeted
review and integration recovery, return-to-implementation decisions, exact
candidate acceptance, remote or local promotion, completion handoff
publication, reviewed knowledge publication, demo-failure correction, sprint
pause/stop execution, and delivery-wide interruption recovery.
`TicketDeliveryPermissionWorkflowCoordinator` owns scoped request routing,
durable decisions, automatic replay, and saved-grant delivery.

### Required journey tests

- [x] Dependency-ready tickets are admitted and blocked dependants wait (`WorkflowPolicyTests.dependencyAwareRunAdmission`).
- [x] Product switching does not suspend active delivery (`ProductExecutionLifecycleTests.productSelectionDoesNotSuspendDelivery`).
- [x] Product archival suspends only that product (`ProductExecutionLifecycleTests.productArchivalHasProductScope`).
- [ ] Normal shutdown suspends all owned work and recovery resumes safely.
- [x] Failed or interrupted implementation preserves and requeues the same workspace, thread, and durable run (`ProductScopedPersistenceTests.implementationRetryPreservesRunIdentity` / D10).
- [ ] Permission request, approval, denial, and relaunch retain least privilege.
- [x] Review is bound to an immutable candidate and cannot attest its own work (`TicketDeliveryWorkflowCoordinatorTests.approvedReviewRemainsCandidateBound` and `SprintWorkRecoveryTests` / D11).
- [x] Clean integration preserves the exact candidate into review (`GitWorkspaceManagerTests.candidateLifecycle`, `TicketDeliveryWorkflowCoordinatorTests.approvedReviewRemainsCandidateBound`, `WorkflowPolicyTests.candidateIntegrationsPrecedeReview`, and `SprintWorkRecoveryTests.queuedIntegratedReviewIsRecoverable` / D12).
- [ ] Conflict resolution that changes the result requires focused re-review.
- [ ] Parallel candidates serialize promotion against current local `trunk`.
- [x] Acceptance rejects stale candidates, moved pull-request heads, and incomplete previews (`TicketDeliveryWorkflowCoordinatorTests.repositoryAcceptancePromotesExactRevision`, `RemoteRepositoryServiceTests.localProductLifecycle`, and `MacOSDemoLauncherTests.candidateFailureDisposition` / D17).
- [ ] Remote merge followed by interruption completes local reconciliation exactly once.
- [x] Completed repository-free tickets preserve the implementation handoff and publish reviewed knowledge without creating repository state (`TicketDeliveryWorkflowCoordinatorTests.repositoryFreeAcceptanceCompletesWithoutGit` / D19).

### Acceptance

- `AppModel` does not execute delivery workflow transitions or retain delivery task registries.
- Core coordinators enforce delivery invariants regardless of presentation.
- Every durable interruption point has fresh-instance recovery coverage.
- Existing owner behavior, product isolation, and permission boundaries remain intact.
- Full verification and relaunch succeed.

### Commit strategy

Use one coherent commit per subdomain extraction. Never combine all delivery subdomains into one unreviewable cutover.

## Phase 7 — Decompose remaining application features

### Intent

Finish turning `AppModel` into a composition and navigation boundary and `ContentView` into an application shell.

### Candidate slices

Complete these in the order indicated by current defect frequency and feature work, not by arbitrary file position:

- [x] Product conversations and title/activity lifecycle.
- [ ] Ticket and epic conversations/refinement.
- [ ] Epic planning and ticket suggestions.
- [ ] Sprint planning and goal generation.
- [x] Demo/app-version launch and recovery.
- [x] Retrospective synthesis.
- [x] Codex connection and usage monitoring.
- [x] Product library, selection, archive, and restoration.

For each slice:

1. identify durable state, transient operation state, presentation state, and owner commands;
2. add or strengthen journey tests;
3. extract one feature coordinator or focused application model;
4. split its views and presentation mapping from `ContentView.swift`;
5. migrate every caller;
6. delete the old AppModel state and tasks; and
7. perform full verification and relaunch.

### Acceptance

At the end of this phase:

- `AppModel` constructs dependencies, tracks global app lifecycle and selected product, and routes navigation-level results.
- It has no feature-specific Codex turn, monitor, polling, or execution task registries.
- `ContentView` contains the root application shell and top-level workspace routing, not most feature implementations.
- Individual workspace views can be rendered with bounded state.

## Phase 8 — Organize persistence without creating another authority

### Intent

Make SQLite behavior easier to navigate while retaining one product database and transactional authority.

### Work

- [x] Inventory `SQLiteStore.swift` by aggregate and transaction boundary.
- [x] Continue the existing focused-extension pattern for complete aggregates such as products, epics, tickets, sprints, runs, conversations, knowledge, repository analysis, remote connections, safe syncs, and publications.
- [x] Keep connection ownership and transaction primitives centralized.
- [x] Do not introduce in-memory repository objects that cache authoritative rows.
- [x] Define narrow store protocols only where coordinators require test substitution or reduced capability.
- [x] Keep multi-aggregate transactions in one explicitly named persistence operation rather than coordinating partial writes in App code.
- [x] Preserve migrations as durable, idempotent, product-generic operations.
- [x] Keep archived records available for audit while excluding them from active calculations.
- [x] Update migration, recovery, and transaction tests alongside each move.

### Acceptance

- A maintainer can locate an aggregate's queries and transactions without reading the whole store file.
- Moving code does not change schema or transaction behavior unless separately specified.
- Coordinators depend on the smallest persistence capability they require.
- No second durable or cached authority has been introduced.

## Phase 9 — Add lasting development guardrails

### Intent

Prevent the same concentration and verification gaps from returning.

### Work

- [x] Add a contributor checklist requiring an owner journey, state table, non-goals, and proof for long-running or multi-screen features.
- [x] Add a review ratchet: new features may use `AppModel` and `ContentView` as composition points but may not add feature workflow ownership to them.
- [x] Require an explicit reason in review when a new long-lived `Task` is created in a view or `AppModel`.
- [x] Require explicit operation events rather than sleeps in new asynchronous tests.
- [x] Require interruption/relaunch coverage for every new durable intermediate state.
- [x] Require one active implementation path after migrations.
- [x] Require owner acceptance before a UX-sensitive packet is called complete.
- [x] Require accepted packets to be committed before unrelated work starts.
- [x] Update `docs/technical-design.md` with the final coordinator boundaries actually implemented.
- [x] Update `README.md` only where the implemented product boundary changed.
- [ ] Mark this plan complete and move any remaining approved future product behavior into `docs/product-spec.md`.

### Acceptance

- The rules describe observed implemented architecture, not aspirations.
- CI and tests verify behavior and safety without brittle source-layout assertions.
- A new agent can identify a feature's state owner, commands, persistence operations, journey tests, and views from bounded files.

## 11. Standard work-packet template

Use this template when starting every extraction or later feature:

```markdown
# Work packet: <owner-visible outcome or architecture boundary>

## Problem
<What is difficult or incorrect today?>

## Behavior to preserve or add
<Exact owner-observable contract.>

## Non-goals
<Adjacent behavior that remains unchanged.>

## Current authority
- Durable state:
- Task owner:
- Presentation state:
- Known duplicate state:

## Target authority
- Coordinator:
- Commands:
- Snapshot:
- Persistence operations:
- View boundary:

## State table
| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |

## Call sites to migrate
- [ ] ...

## Obsolete state to remove
- [ ] ...

## Verification
- [ ] Existing focused tests
- [ ] New observable-contract test
- [ ] Interruption and fresh-instance recovery
- [ ] Full test suite
- [ ] `git diff --check`
- [ ] Relaunch
- [ ] Product-owner inspection

## Completion evidence
<Exact commands and observed results.>
```

## 12. Definition of done for this plan

The stabilization program is done only when:

- [x] The current product specification, technical design, and README agree.
- [x] The initial accumulated work has a product-owner-approved known-good commit.
- [x] Generated development output no longer pollutes repository status.
- [x] Repository import has one coordinator and deterministic journey coverage.
- [x] Repository knowledge analysis has one coordinator and fresh-instance recovery coverage.
- [x] Remote account, connection, synchronization, and publication responsibilities are separated.
- [x] Remote application state is no longer distributed across AppModel dictionaries and view state.
- [ ] Delivery execution, review, integration, and acceptance are Core-owned workflows.
- [ ] `AppModel` is an application composition/navigation boundary.
- [x] `ContentView` is an application shell rather than the main implementation file for most workspaces.
- [x] Persistence code is organized by aggregate without changing database authority.
- [x] No affected asynchronous test relies on arbitrary sleeps to observe workflow progress.
- [x] Every durable intermediate phase in the extracted workflows has interruption and relaunch coverage.
- [x] Important owner-facing states are available in a preview or development scenario catalog.
- [x] The full suite passes with warnings treated as errors.
- [x] `git diff --check` passes.
- [x] The development app has been relaunched and left running after the final app-affecting packet.
- [x] The durable architecture documents describe the implemented result.

## 13. First work packet to start

Unless the current baseline still has unresolved product defects, the first implementing agent should execute **Phase 0 only**:

1. verify the specification correction and implemented boundary;
2. confirm `.build-launch/` is disposable generated output and ignore it;
3. run the full suite and diff check;
4. relaunch the app;
5. provide the Phase 0 owner inspection checklist; and
6. stop before committing accumulated work or starting refactoring unless the product owner explicitly accepts the baseline.

After that checkpoint, start Phase 1 and Phase 2 together as one bounded migration sequence: first make repository-import transitions deterministic in tests, then move repository-import task ownership out of `AppModel`. Do not begin repository knowledge, remote synchronization, or delivery extraction until that clean cutover passes full verification.


## 14. Targeted runtime and implementation audit

This audit was performed against the accumulated 13 August 2026 working tree after the initial plan was written. It does not broaden the product scope. It identifies concrete correctness risks, unnecessary work, and compatibility paths that should be removed or folded into the phases above.

The findings are ordered by product risk, not by ease of implementation. A Priority 0 finding must be resolved or explicitly disproved by a deterministic test before the baseline is accepted.

### 14.1 Priority 0 — Permission decisions cross the durable boundary in the wrong order

`AppModel.handlePendingApprovalRequest` can resolve an automatic allow or denial with Codex and only then attempt to save the `AgentPermissionRequest`. Those saves use `try?`. `AppModel.decidePermissionRequest` similarly resolves the live server request, removes it from the in-memory dictionaries, and only then persists the allowed or denied status.

Consequences:

- Codex may receive access while the durable audit record still says that the request is pending.
- A persistence failure after an allow cannot revoke the access that was already granted.
- A persistence failure after the live request is removed can leave an owner-visible request that can no longer be decided.
- Relaunch recovery cannot distinguish “decision never sent” from “decision sent but final status write failed.”

Required correction:

- [x] Define durable permission-resolution states that distinguish decision intent from delivery acknowledgement.
- [x] Persist the decision intent before sending an allow or denial.
- [x] Fail closed when the decision intent cannot be persisted.
- [x] Make repeated delivery of the same decision idempotent by server request ID and signature.
- [x] Preserve the existing saved product-grant rollback when transport delivery fails.
- [x] Do not discard the live request until the durable record can recover the next step.
- [x] Record automatic policy denials and grant-based allows with the same durable ordering as owner decisions.

Required tests:

- [x] A database failure before decision-intent persistence sends no response.
- [x] A transport failure after decision-intent persistence leaves a recoverable decision.
- [x] A database failure after transport acknowledgement still leaves durable evidence of the intended decision.
- [x] Relaunch does not ask the owner to decide a response that was already sent.
- [x] A remembered product grant remains auditable for every request it satisfies.

### 14.2 Priority 0 — Recovery performs multi-record transitions as best-effort fragments

The audited application contained 180 `try? await` expressions. Fifty occurred in the delivery-recovery region beginning at `recoverOrphanedExecutionRuns`. Not every best-effort cleanup was wrong, but durable transitions for candidates, runs, tickets, permission requests, knowledge proposals, and work-log comments were repeatedly attempted as independent writes with their failures discarded.

For example, recovery of an invalid ready-for-demo candidate can independently remove a worktree, supersede the candidate, supersede knowledge proposals, move the ticket, queue the implementation run, and append a comment. A failure in the middle leaves a combination that no single workflow state table authorizes. The next recovery pass then interprets that partial combination as if it were intentional.

Required correction:

- [x] Inventory every swallowed error in delivery and repository recovery and classify it as cleanup-only, diagnostic-only, or state-changing.
- [x] Replace state-changing `try?` calls with one coordinator command whose durable writes share a SQLite transaction where they belong to one transition.
- [x] Return a typed recovery failure when filesystem or remote work prevents the durable transition from completing.
- [x] Make cleanup retryable from durable state instead of treating cleanup failure as transition success.
- [x] Append the work-log handoff in the same durable transition as the state it explains.
- [x] Expose a failed recovery state to the product owner instead of silently continuing with partial state.

Required tests:

- [x] Inject a failure at every durable write boundary in candidate recovery and prove that the resulting state is either unchanged or explicitly recoverable.
- [x] Relaunch repeatedly from each injected failure and prove that the command converges without duplicate comments or skipped ticket states.
- [x] Run two recovery triggers concurrently and prove that compare-and-swap or transaction ownership admits only one transition.

### 14.3 Priority 0 — Archived products are included in remote recovery

`AppModel.load` calls `scheduleGitHubRemoteRecovery` with active product IDs and archived product IDs. Archiving stops demo, repository-knowledge, planning, and delivery work, but it does not settle remote connection, safe-sync, publication, or pull-request recovery. A later launch can therefore resume remote work for a product the owner removed from active use.

That is both unnecessary launch work and an authority error. An archived product should remain available for audit; it should not silently resume a push, synchronization acceptance, pull-request creation, merge reconciliation, or branch cleanup.

Required correction:

- [x] Define the archive precondition for every active remote status.
- [x] Durably suspend remote work before changing product status; if a particular external side effect cannot be paused safely, block archive with an owner-facing explanation until it reaches a resumable boundary.
- [x] Schedule automatic remote recovery only for active products.
- [x] Restore a product before offering any action that resumes preserved remote work.
- [x] Keep archived remote records readable without querying Keychain, GitHub, or remote Git.

Required tests:

- [x] Launch with an archived connected product and prove that no credential, HTTP, or remote Git call occurs.
- [x] Launch with an archived product containing every recoverable remote status and prove that none is advanced.
- [x] Archive during each owner-waiting and active remote phase and verify the documented suspend-or-block contract.
- [x] Restore the product and verify that only the explicitly preserved, documented work can resume.

### 14.4 Priority 0 — Completed repository analysis can retry forever

`RepositoryKnowledgeRecoveryPolicy.shouldRetryUnproductiveCompletedAnalysis` returns `true` for a completed run with no approved drafts and no published pages. `scheduleRepositoryKnowledgeRuns` converts that result into `createRecoveryAttempt`. There is no attempt limit, migration marker, backoff, or owner decision.

A valid “no useful product knowledge found” result can therefore consume another Codex run on every launch. Repeating the same analysis is not recovery because the completed durable result is not ambiguous.

Required correction:

- [x] Treat a completed analysis with no publishable knowledge as a terminal, owner-visible outcome.
- [x] Remove automatic retries based only on an empty or rejected result.
- [x] If a legacy malformed-result migration remains necessary, key it to an explicit schema/version marker and allow at most one migration attempt.
- [x] Make any subsequent analysis an explicit product-owner command.

Required tests:

- [x] Repeated launches after an empty completed result start zero new Codex turns.
- [x] Repeated launches after all drafts are rejected start zero new Codex turns.
- [x] An explicit owner retry creates exactly one new run with clear provenance.

### 14.5 Priority 0 — Team settings are neither atomic nor completion-aware

`AppModel.updateTeamSettings` writes product instructions, then updates every profile sequentially, then performs a full reload. The sheet calls this synchronous-looking method and dismisses immediately. A mid-loop failure leaves a partially updated team while the owner sees a closed sheet and receives a later global error.

Required correction:

- [x] Add one SQLite transaction that validates and updates product instructions and all affected profiles atomically.
- [x] Make the application command `async` and return a typed success or failure.
- [x] Keep the sheet open, disable duplicate submission, and show the failure next to the save action.
- [x] Return the committed team-settings snapshot instead of triggering a full application reload.

Required tests:

- [x] Inject a failure for each profile update and prove that none of the team settings changed.
- [x] Verify that a successful save updates the rendered settings without fetching unrelated product state.
- [x] Verify that a failed save remains editable and can be retried once.

### 14.6 Priority 1 — Broad reloads are expensive and internally inconsistent

The current `reloadSelectedProduct` implementation contains 37 awaits and 27 fetch-or-seed calls. It also loads every conversation thread and then fetches every thread's complete message history one query at a time, including archived conversations. Because each call is a separate actor hop and read, background writers can interleave and the resulting in-memory arrays need not represent one SQLite version.

Additional amplification:

- `reload` fetches active and archived products separately; each registry call visits every product store.
- Product metadata and team-setting edits call the broad reload instead of applying the committed result.
- Sprint scheduling rebuilds a context through separate product, sprint, profile, knowledge, ticket, dependency, run, candidate, permission-request, and permission-grant reads after every wake.
- `seedKnowledgeBase` is used during creation, selected-product reload, and sprint-context assembly even when the caller only needs to read existing pages.
- Remote recovery status filters load broader publication or connection collections and filter them in Swift.
- Publication-ID and safe-sync-ID lookup scans every known product store even when the application caller already knows the product ID.

Required correction:

- [x] Add coherent aggregate snapshots read in one SQLite transaction for the bounded state a coordinator or presentation needs.
- [x] Separate startup migrations and seeding from normal reads.
- [x] Load conversation summaries eagerly and message history only for the selected conversation, or fetch all required messages in one bounded query.
- [x] Return committed records from commands and update the owning feature snapshot directly.
- [x] Fetch all product statuses once and partition them in memory.
- [x] Pass product ID through remote operation commands and perform direct store lookup.
- [x] Move status filtering into indexed SQL queries.
- [ ] Instrument query counts for launch, product selection, settings save, scheduler wake, and remote polling before and after the change.

Acceptance:

- [ ] A one-field product edit performs no unrelated conversation, sprint, repository, permission, or knowledge queries.
- [ ] A product with long conversation history has bounded launch and product-selection work.
- [ ] A coordinator snapshot cannot combine records from different durable versions.
- [ ] Scheduler wake work is proportional to the changed delivery aggregate rather than the full product history.

### 14.7 Priority 1 — Polling substitutes for observable state transitions

The ticket work-log view refetches the complete comment list every second while visible. The codebase view waits in 100-millisecond loops for initial loads. AppModel shutdown also uses a 100-millisecond polling loop, and recent tests use short sleeps to guess when asynchronous state changed.

The work-log poll continues after fetch failures and routes the error through the global application error string. This can repeatedly clear or replace useful local presentation while issuing the same failing query every second.

Required correction:

- [x] Publish comment and activity changes from the owning feature coordinator or store change stream.
- [x] Perform one initial fetch, then apply identified appended or updated records.
- [x] Stop retrying on a tight fixed interval after a durable read failure; expose a local retry action.
- [x] Replace UI wait loops with explicit load state and completion events.
- [x] Replace shutdown polling with tracked task completion or a task group.
- [x] Replace test sleeps with continuations, injected clocks, or observable command completion as required by Phase 1.

### 14.8 Priority 1 — Remote Git work is broader and less serialized than necessary

`GitWorkspaceManager.remoteHeadSHAs` enumerates every remote branch. Seven operation paths invoke it. Merged review-branch cleanup invokes the broad enumeration before deletion and again afterward even though it needs one exact `refs/heads/spedito/...` ref. An already absent branch is safe, but proving that absence should not require downloading and parsing every branch name.

`GitWorkspaceManager` is an actor, but its asynchronous process methods suspend while Git runs. Actor reentrancy permits another method to start a second Git process for the same repository during that suspension. Pull-request polling, owner commands, repository checks, codebase inspection, and delivery work do not share one explicit per-repository operation queue.

Resolution against the stabilized implementation: every post-activation
asynchronous remote Git operation acquires a FIFO repository lease around its
complete check-and-mutate sequence. Nested exact-ref checks inherit the lease;
an unrelated synchronous same-product command observes a stable
`operationInProgress` failure instead of overlapping the suspended operation.
Publication and cleanup paths query only their exact managed ref. Full branch
enumeration remains only where remote emptiness is the contract. Public clone
targets an unregistered staging directory before Product polling or delivery
can address it.

Required correction:

- [x] Add an exact remote-ref lookup for operations that know the target ref.
- [x] Treat an already absent review branch as successful idempotent cleanup and persist `remoteBranchDeletedAt`.
- [x] Reserve full branch enumeration for the few contracts that genuinely require proving remote emptiness or cataloguing all managed refs.
- [x] Add product-workspace operation serialization or an explicit read/write coordination policy around asynchronous Git processes.
- [x] Prove that polling cannot overlap a mutating Git command for the same product.
- [x] Keep compare-and-swap and force-with-lease checks at the final side-effect boundary.

Required tests:

- [x] Merged-branch cleanup requests only the exact managed ref.
- [x] Cleanup records completion when the ref was already absent.
- [x] Relaunch after cleanup performs no remote branch query for that publication.
- [x] Concurrent poll, check, and delivery commands serialize or reject with a stable owner-facing busy state.

### 14.9 Priority 1 — One observable object invalidates unrelated presentation

`AppModel` has 74 `@Published` properties and 59 task-launch sites. `ContentView.swift` contains 97 task-launch sites. Remote polling, Codex usage, ticket activity, repository analysis, settings, navigation, and delivery state therefore share one broad observation and lifecycle surface.

This is not only a file-size concern. A remote polling update can invalidate views that depend only on backlog state, and a global `errorMessage` can present a background failure in the wrong workspace.

Required correction:

- [x] Complete the feature-model extractions in Phases 2, 3, 5, 6, and 7.
- [x] Give each feature local loading, operation, and failure state.
- [x] Keep global application state limited to composition, product selection, navigation, and truly global service availability.
- [ ] Measure body recomputation for the backlog, sprint board, ticket sheet, and repository settings before and after extraction. The static ownership baseline moved from 79 to 33 `AppModel` `@Published` values, and a five-second idle trace of the relaunched build recorded no view-body updates; complete the four named interactive traces during product-owner inspection.

### 14.10 Priority 2 — Dead compatibility paths weaken compile-time guarantees

The application still exposes a legacy manual publication workflow through `prepareRemotePublication`, `cancelRemotePublication`, `confirmRemotePublication`, and `finishRemotePullRequest`. `ContentView` has no caller. A symbol-aware reference check found only the `AppModel.prepareRemotePublication` declaration and its test. The Core service still carries `.legacyManual` publication behavior.

`GitHubRemoteRepositoryServing` also provides default implementations for ticket pull-request methods that throw “unavailable.” Those defaults let a conformer or test fake compile without implementing a capability now required by production callers.

Required correction:

- [x] Confirm whether any durable legacy publication status still requires one-time migration.
- [x] Migrate or mark those records terminal, then remove the owner-inaccessible manual workflow.
- [x] Split the broad protocol as required by Phase 4.
- [x] Remove default throwing implementations for required capabilities so missing behavior is a compile-time error.
- [x] Keep defaults only for genuinely optional convenience overloads with equivalent semantics.

### 14.11 Corrective execution order

These findings amend the first work packet in section 13:

1. [x] Fix Priority 0 permission-decision durability as one focused defect packet.
2. [x] Stop archived-product remote recovery and unbounded completed-analysis retry as a second focused defect packet.
3. [x] Make team-settings save atomic and completion-aware.
4. [x] Add failure-injection coverage for partial delivery recovery; perform the durable transition cutover in the owning Phase 6 packet rather than adding more AppModel repair branches.
5. [x] Complete the original Phase 0 specification reconciliation, full verification, relaunch, owner inspection, and known-good checkpoint.
6. [x] Execute Phase 1 and Phase 2 as previously ordered.
7. [x] Address read amplification and Git serialization inside the relevant extraction phase, using measurements rather than speculative caching.
8. [x] Delete legacy publication and protocol fallback paths during Phase 4 after durable-record migration is proven.

Do not start with cosmetic file splitting or micro-optimizing formatters. The first corrections must restore durable authority at external side-effect boundaries; query and rendering improvements follow once the result is coherent and testable.
