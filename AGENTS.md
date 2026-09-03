# Spedito contributor instructions

These instructions apply to the whole repository.

## Product intent

Spedito is a local-first, macOS-native product-delivery application for
product owners who may not be software engineers. It preserves the useful parts
of agile delivery while hiding terminals, Git commands, Codex threads, and other
implementation machinery behind a clear owner-facing workflow.

Use the following documents as the durable source of truth:

- `docs/product-spec.md` for product behavior, terminology, journeys, and scope.
- `docs/technical-design.md` for architecture, persistence, execution, and
  recovery boundaries.
- `docs/architecture/owner-journey-test-plan.md` for the journey inventory and
  executable coverage ledger.
- `README.md` for a concise user-facing overview and developer entry points.

Keep those documents accurate when a change materially alters their claims.
Record agreed future product work in the product specification rather than
leaving it only in a code comment or chat.

Keep the README short and lean. Link to `https://spedito.io/` for detailed
feature descriptions instead of cataloguing product workflows in the README.

## Product language and workflow

Use owner-facing language consistently:

- Product owner, not administrator or operator.
- Team member, not persona, unless referring to the internal domain concept.
- Backlog, epic, sprint, ticket, conversation, work log, and product knowledge.
- Ready to pick, in progress, in review, ready for demo, and done.
- Needs your input is an inline attention state, not a separate board column.
- Integrating is an inline execution state, not a separate board column.

Capitalize these common nouns only at sentence beginnings or where grammar otherwise requires it.

Tickets are the source of truth for delivery. Agent progress, questions,
review findings, status changes, and product owner comments belong in the
ticket work log with an author and timestamp. Knowledge pages hold durable
cross-ticket information; delivery history may contain a page per ticket.

The product owner remains in control:

- AI suggestions are reviewable and versioned.
- Never silently change ticket scope, dependencies, or product decisions.
- Ask consequential product questions during refinement.
- Create research work only when the product owner requests it or agrees that
  external evidence is needed.
- A normal ticket should deliver an agreed outcome, not defer deciding what
  that outcome is.
- Follow-up tickets discovered by authorised research remain reviewable
  proposals until the product owner accepts them. Publish them only from the
  approved research outcome and preserve its epic and dependency provenance.

## Architecture

- `Sources/SpeditoCore` contains domain policy, persistence, Git
  workspaces, Codex adapters, and other UI-independent behavior.
- `Sources/SpeditoApp` contains SwiftUI presentation and application
  coordination.
- Keep workflow rules and validation in Core when they must remain true
  regardless of the presenting view.
- Keep Codex protocol details behind the existing adapter boundary.
- Prefer extending existing models and reusable views over introducing a
  second representation of the same concept.

SQLite is the local control plane. Schema changes must use durable, idempotent
migrations and work for every product. Never add migrations, fixtures, prompts,
or defaults that refer specifically to the weather-app development example.
Archived records remain available for audit history but must not leak into
active planning, dependency, or suggestion calculations.

### Required architecture invariants

#### Durable and transient state

For each workflow, classify every field as one of:

- **Durable domain state:** must survive process termination and belongs in SQLite.
- **Recoverable external observation:** immutable evidence captured in SQLite before it can authorize a mutation.
- **Transient operation state:** task handles, continuations, short-lived credentials, or live activity that cannot be made authoritative.
- **Presentation state:** a deterministic projection of durable state, transient operation state, and a typed owner-facing failure.

Never copy durable workflow authority into a service cache or SwiftUI state. A
cache may accelerate a read only when it can be discarded and rebuilt without
changing behavior.

#### Feature coordinator contract

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

This is a shape, not a required generic protocol. Prefer a feature-specific
protocol when a generic abstraction would hide meaningful behavior.

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

#### Application model contract

After a feature is extracted, `AppModel` may:

- construct the coordinator;
- select the active product;
- retain a bounded feature model or snapshot needed by the UI;
- route a user command to the coordinator;
- coordinate truly application-wide shutdown; and
- react to a completed result when global navigation must change.

It must not retain a second set of feature task handles, operation identifiers,
busy flags, errors, or recovery rules.

#### View contract

A feature view should be constructible with:

```swift
FeatureView(
  state: FeaturePresentationState,
  send: @escaping (FeatureCommand) -> Void
)
```

Environment injection is acceptable where it remains feature-bounded. The
important constraints are:

- the view cannot mutate persistence directly;
- the view cannot decide whether a durable transition is legal;
- the view does not own a long-running operation;
- sheet visibility is derived from feature presentation state when it represents workflow state;
- ephemeral editing text and focus may remain local; and
- all owner-facing states can be constructed without running a real external operation.

#### Failure contract

Do not use one unstructured string as both diagnostic and workflow state. Each
extracted feature should distinguish:

- the stable failure category used for recovery and available actions;
- a concise owner-facing title and explanation;
- optional technical evidence safe to expose; and
- whether retry, cancel, reconnect, or owner input is valid.

Retain underlying errors for logs or tests only where doing so does not expose
secrets.

### Feature navigation map

Start at the state owner, not at a caller or view. Persistence entries name the
`SQLiteStore` extension that owns the durable operations. Journey IDs refer to
`docs/architecture/owner-journey-test-plan.md`.

| Feature | State owner | Persistence operations | Main views | Journey rows |
| --- | --- | --- | --- | --- |
| Product library and lifecycle | `AppModel.swift`; `ProductLibraryFeatureModel` and `TransientOwnerCommandRuntime` in `FeatureRuntimeOwners.swift` | `ProductStoreRegistry.swift`, `SQLiteStore+Products.swift`, `ProductDatabaseSchema.swift` | `ProductLibraryView.swift`, `ProductCreationView.swift`, `ProductSettingsView.swift`, `ContentView.swift` | A01–A12 |
| Repository import | `RepositoryImportCoordinator.swift`; composition in `RemoteRepositoryFeatureModel.swift` and `AppModel.swift` | `SQLiteStore+Products.swift`, `SQLiteStore+ProductRepositories.swift`, `SQLiteStore+RepositoryAnalysis.swift` | `ProductCreationView.swift`, `ProductOnboardingView.swift` | R01–R07 |
| Repository knowledge | `RepositoryKnowledgeCoordinator.swift` and `RepositoryKnowledgeRecovery.swift` | `SQLiteStore+RepositoryAnalysis.swift`, `SQLiteStore+KnowledgePages.swift` | `ProductOnboardingView.swift`, `KnowledgeBaseView.swift` | R08–R09, V07 |
| Remote repository | `RemoteRepositoryFeatureModel.swift`; `GitHubRemoteRepositoryService*.swift` | `SQLiteStore+RemoteConnections.swift`, `SQLiteStore+RemoteSafeSyncs.swift`, `SQLiteStore+RemotePublications.swift` | `RemoteRepositorySetupView.swift`, `RemoteRepositorySettingsView.swift`, `IncomingRepositoryReviewView.swift`, `SprintBoardRepositoryStatusView.swift` | R03–R06, R10–R14, D13, D17 |
| Epics and suggestions | `EpicPlanningWorkflowCoordinator.swift` owns clarification, plan and suggestion generation, review decisions, interruption, and recovery; `PlanningConversationWorkflowCoordinator.swift` owns ordinary epic conversation; `AppModel.swift` composes both and projects `EpicPlanningFeatureModel` from `FeatureRuntimeOwners.swift` | `SQLiteStore+Epics.swift`, `SQLiteStore+TicketSuggestions.swift`, `SQLiteStore+Conversations.swift`, `SQLiteStore+WorkItems.swift`, `SQLiteStore+OwnerNotifications.swift` | `BacklogView.swift`, `EpicDetailView.swift` | E01–E16 |
| Backlog and tickets | `PlanningConversationWorkflowCoordinator.swift` owns ticket refinement and conversation; `AppModel.swift` composes it and projects `PlanningConversationFeatureModel` from `FeatureRuntimeOwners.swift` | `SQLiteStore+WorkItems.swift`, `SQLiteStore+WorkItemHistory.swift`, `SQLiteStore+Epics.swift` | `BacklogView.swift`, `TicketDetailView.swift`, `TicketEditorComponents.swift` | B01–B11 |
| Sprint planning | `SprintPlanningWorkflowCoordinator.swift` owns candidate scope, ticket-planning conversations, goal generation, draft persistence, readiness, start, interruption, and recovery; `AppModel.swift` composes it and projects `SprintPlanningFeatureModel` from `FeatureRuntimeOwners.swift` | `SQLiteStore+Sprints.swift`, `SQLiteStore+WorkItems.swift`, `SQLiteStore+WorkItemHistory.swift`, `SQLiteStore+Activity.swift` | `SprintPlanningView.swift`, `BacklogView.swift` | P01–P07 |
| Delivery | `TicketDeliveryRuntimeCoordinator.swift` owns scheduler/task lifecycle; `TicketDeliveryWorkflowCoordinator.swift` owns implementation, review, integration, acceptance, pause/stop, and recovery transitions; `TicketDeliveryPermissionWorkflowCoordinator.swift` owns capability decisions; `AppModel.swift` composes adapters and forwards commands | `SQLiteStore+Sprints.swift`, `SQLiteStore+AgentRuns.swift`, `SQLiteStore+CandidateDelivery.swift`, `SQLiteStore+AgentPermissions.swift`, `SQLiteStore+WorkItemHistory.swift` | `SprintBoardView.swift`, `TicketDetailView.swift`, `TeamSidebar.swift` | D01–D23, A10–A11 |
| Chat and notifications | `ProductConversationFeatureModel.swift`, `ProductConversationRuntime` in `FeatureRuntimeOwners.swift`, `OwnerNotificationCoordinator.swift` | `SQLiteStore+Conversations.swift`, `SQLiteStore+OwnerNotifications.swift`, `SQLiteStore+Activity.swift` | `ProductConversationView.swift`, `TicketDetailView.swift`, `EpicDetailView.swift`, `SprintBoardView.swift`, `OwnerNotificationTrayView.swift`, `ContentView.swift` | C01–C11, E02, E05, B02, D03 |
| Knowledge | `AppModel.swift`; repository publication remains in `RepositoryKnowledgeCoordinator.swift` | `SQLiteStore+KnowledgePages.swift`, `SQLiteStore+KnowledgeProposals.swift`, `SQLiteStore+RepositoryAnalysis.swift` | `KnowledgeBaseView.swift`, `TicketDetailView.swift` | K01–K06, D16, D19 |
| Codebase and app versions | `AppModel.swift`; `DemoSessionFeatureModel` in `FeatureRuntimeOwners.swift`; `MacOSDemoLauncher.swift` | `SQLiteStore+CandidateDelivery.swift`, `SQLiteStore+ProductRepositories.swift` | `CodebaseView.swift`, `AppVersionsView.swift`, `TicketDetailView.swift` | V01–V07, D14, D24 |
| Retrospectives and reports | `AppModel.swift`; `RetrospectiveSynthesisRuntime` in `FeatureRuntimeOwners.swift` | `SQLiteStore+Retrospectives.swift`, `SQLiteStore+Sprints.swift`, `SQLiteStore+AgentRuns.swift` | `RetrospectivesView.swift`, `ReportsView.swift` | I01–I10, D21 |
| Settings and Codex | `AppModel.swift`; `CodexConnectionRuntime` in `FeatureRuntimeOwners.swift`; `CodexInstallation.swift` | `SQLiteStore+Products.swift`, `SQLiteStore+AgentProfiles.swift`, `SQLiteStore+AgentPermissions.swift` | `ProductSettingsView.swift`, `CodexStatusView.swift` | S01–S08 |

A packet that introduces a coordinator or moves ownership between coordinators
must update this table in the same commit.

## Agent execution model

- Refinement, suggestions, planning, and ordinary review turns are read-only
  unless their explicit contract says otherwise.
- Delivery runs use an isolated ticket worktree and `ticket/TN` branch.
- Parallel implementation happens in separate worktrees.
- Tech lead reviews run in parallel against exact immutable ticket candidates.
- Candidate integration is serialized against current local `trunk`.
- Conflict resolution that changes an integrated result requires focused Tech
  Lead re-review; clean merges retain the candidate review.
- Product owner approval promotes the integrated reviewed candidate and
  completes the ticket.
- On interruption, preserve durable run state and the ticket workspace so work
  can be resumed safely.

Do not expose raw chain-of-thought or fabricate activity. UI activity summaries
must be concise, useful descriptions derived from supported Codex events. A
missing or malformed structured agent result should fail safely with a
recoverable owner-facing explanation.

Agent permissions must remain least-privilege:

- No secrets, credential stores, unrelated products, other ticket worktrees,
  or the Spedito database in an agent context.
- Network access is off unless the product owner explicitly permits it.
- Do not discover package managers or runtime installations and pre-authorize
  their paths. Keep Codex's scoped permission-request tool available so the
  assigned agent can diagnose a blocked capability and request the smallest
  exact filesystem or network access from the product owner.
- Do not weaken sandbox or approval behavior as a convenience fallback.
- Capability-detect required runtime features and fail closed when safe
  isolation cannot be provided.
- Never put a wildcard in a directory component of a deny path. Codex expands
  each deny pattern into ancestor directory-unlink rules, so `**/.env` makes
  every workspace directory undeletable and breaks all delivery. Put the
  wildcard in the filename (`.env.*`) or name the directory. Deny paths live in
  `CodexPermissionProfiles.workspaceDenyPaths`.

A permission profile is only proven by running it. A test that skips when no
Codex runtime is present reports an uncovered run as a passing one, so the
sandbox guards fail instead, and CI installs a runtime. When you report a
sandbox- or runtime-dependent result as green, name the binary and version that
were exercised, or say plainly that none was.

## Dependency context and ticket handoffs

Dependencies are durable delivery relationships, not placeholders for tickets
that might be invented later. When an epic plan already contains research,
design, implementation, and verification tickets, accept them as one dependency
graph before delivery. The dispatcher waits for direct prerequisites to reach
done before starting a dependant.

Every completed ticket must leave a self-contained completion handoff in its
work log. The handoff records:

- the delivered outcome and material decisions;
- selected providers, contracts, interfaces, or operating requirements;
- evidence, checks, caveats, and known limitations; and
- what direct dependant tickets may safely assume.

Reusable truth also belongs in verified product knowledge. When a dependant
runs, its context includes its own ticket contract, the contracts and recent
work log comments of its direct prerequisites, and verified product knowledge
originating from those prerequisites. Do not copy all raw transitive history
into every downstream ticket. Each completed ticket should deliberately
synthesise the prerequisite context it used with the outcome it produced, so
the next direct dependant receives a concise current handoff. Dependency links
and source work logs preserve the full audit trail.

Research-generated follow-up tickets are exceptional. If accepted tickets
already cover the downstream work, research must return no follow-up proposals;
it supplies its decision and details through the completion handoff and product
knowledge instead. A follow-up proposal is appropriate only for genuinely new
scope absent from every active ticket. If evidence materially conflicts with an
accepted ticket contract, stop for product owner input or propose a reviewable
edit rather than silently replacing, splitting, or changing that ticket.

For example, an epic to add a cat joke to weather results should normally be
planned as:

1. **T1 — Recommend a suitable content provider:** business analyst research.
2. **T2 — Design the result, loading, attribution, and unavailable states:**
   experience design that may proceed in parallel.
3. **T3 — Integrate the approved provider:** depends on T1 and T2.
4. **T4 — Verify successful, unavailable, privacy, and attribution behaviour:**
   depends on T3.

When T1 completes, it records the approved provider, request contract, content
and privacy constraints, attribution, failure behaviour, evidence, and caveats
in its work log and appropriate product knowledge. It does not create
replacement design, implementation, or verification tickets because T2–T4
already exist. T3 receives the T1 and T2 handoffs, implements the combined
contract, and leaves a new handoff for T4. If T1 instead discovers that every
suitable provider requires a materially different architecture, it asks the
product owner how to change the accepted plan; it does not hide that scope
change in a comment or duplicate ticket.

## SwiftUI and UX conventions

The first supported platform is Apple Silicon macOS. Prefer native SwiftUI and
macOS behavior unless a custom control materially improves clarity.

- Design for a non-technical product owner.
- Use sentence case for every button and menu label across the app. Preserve
  capitalization only for proper nouns and established initialisms such as AI.
- Write out "and" in button and menu labels; do not use ampersands.
- Use `.borderedProminent` as the standard style for actionable buttons. Reserve
  `.bordered`, `.plain`, `.borderless`, and `.link` for controls that genuinely
  need lower visual weight or platform-specific presentation.
- Keep primary actions visually clear; destructive actions use the destructive
  role and red text/icon treatment.
- AI actions use the established purple treatment; ordinary primary workflow
  actions use the app accent color.
- Use semantic colors and verify both light and dark appearances.
- Reuse shared table/grid geometry so headers and cells cannot drift.
- Make an entire backlog row clickable and draggable when the whole row is the
  interaction target.
- Avoid nested cards, repeated labels, decorative icons, and empty containers
  that do not add hierarchy.
- Keep ticket titles readable at compact sizes and allow two lines where the
  current design calls for them.
- Empty states should be centered in their available content area without
  forcing the enclosing view beyond the window.
- Sheets must fit a typical 14-inch MacBook display and remain usable when
  content grows. Put long content in an intentional scroll region.
- Text editors need normal, consistent content insets, visible focus, and
  correctly aligned placeholders.
- Preserve the selected product, main view, and selected sprint across normal
  relaunches when the underlying record still exists.

Completed prerequisites should not be presented as active blockers. Archived
epics and tickets should not appear as active relationships. Suggested tickets
carry final keys from the single durable product sequence `T1`, `T2`, and so
on from the moment they are stored; the key a proposal shows is the key the
accepted ticket keeps. Rejected and superseded proposals retire their keys, so
gaps in the sequence are expected. Temporary `S1`-style references exist only
inside the generation protocol and in decided historical suggestions.

## Making changes

- Never use Computer Use or any other GUI automation to control or inspect the
  product owner's Mac. Do not click, type, scroll, navigate apps, or capture the
  screen on their behalf. Validate through repository code, tests, durable
  state, and the required relaunch; leave visual UI inspection to the product
  owner.
- Inspect the affected implementation and nearby tests before editing.
- Search with `rg` or `rg --files`.
- Preserve unrelated work in a dirty worktree.
- Use `apply_patch` for hand-authored edits.
- Do not use destructive Git operations to clean up user changes.
- Prefer a small coherent implementation over parallel legacy and replacement
  paths.
- Do not add weather-app-specific behavior to demonstrate a generic feature.
- Add or update tests for domain rules, persistence, decoding, migration,
  recovery, and other non-visual behavior.
- Verify UI changes at representative light/dark and laptop-sized layouts when
  practical.

### Change and commit protocol

1. One work packet changes one coherent behavior or extracts one complete
   workflow boundary.
2. Begin with a clean or explicitly understood working tree.
3. Reproduce a bug before fixing it.
4. Add a new test only for a new observable contract or a plausible regression
   not already covered.
5. Do not mix opportunistic UX redesign with a behavior-preserving extraction.
6. Finish all call-site migrations and remove obsolete paths before verification.
7. Run focused checks, the full suite, `git diff --check`, and the required
   relaunch.
8. Ask the product owner to inspect the named journey when visual judgment is
   required.
9. Commit the accepted packet before beginning another unrelated packet, and
   delete its work-packet file in that same commit. The commit message, the
   tests, and the durable documents carry the record; the packet file does
   not outlive the packet.
10. If the packet cannot be accepted, keep it isolated and record the exact
    failing acceptance criterion. Delete the packet file when the packet is
    abandoned.

### Standard work-packet template

Use this template when starting every extraction or later feature. A packet
file is scratch for the packet's lifetime only: keep it out of the repository,
or remove it in the commit that completes or abandons the packet. Do not leave
handover documents behind for a later session to find.

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

### Long-running and multi-screen feature checklist

Before implementing or accepting a long-running or multi-screen feature, record
the following in its work packet or accepted ticket:

- the owner journey, exact behavior, and explicit non-goals;
- a journey inventory row added or updated for the feature;
- an explicit `Shell = Y` or `Shell = —` designation for that row;
- for every `Shell = Y`, a written justification against the launched-process
  criterion in the verification model;
- a state table naming every durable intermediate state, the command that enters
  it, the evidence stored in SQLite, what the owner sees, available actions, and
  relaunch recovery;
- the single feature coordinator, bounded presentation snapshot, persistence
  operations, views, and call sites to migrate;
- the observable proof for success, failure, cancellation, interruption, and
  fresh-instance recovery; and
- the product owner's acceptance for UX-sensitive changes.

Review uses these architecture ratchets:

- `AppModel` and `ContentView` are composition and routing points. New feature
  workflow state, long-lived tasks, polling, and multi-step side-effect
  orchestration belong in a focused coordinator.
- Every new long-lived `Task` in a view or `AppModel` needs an explicit review
  reason. Prefer coordinator-owned tasks with bounded lifecycle and settlement.
- Asynchronous tests observe explicit operation events or continuations, never
  arbitrary sleeps.
- Every new durable intermediate state has interruption and relaunch coverage.
- A migration leaves one active implementation path; remove replaced task
  registries, state projections, aliases, and fallback protocols in the same
  packet.
- Commit an accepted work packet before starting unrelated implementation,
  remove its packet file in that commit, and do not rewrite prior history to
  create that checkpoint.
- Lower a value in `scripts/architecture_ratchets.baseline` whenever an
  extraction improves it, so the improvement is locked in. Raising a baseline
  requires an explicit reason in the accepted work packet. The two line-count
  metrics allow a 25-line drop before they demand a new baseline, so incidental
  edits do not turn into baseline bookkeeping; the counts that carry
  architectural meaning stay exact in both directions.

## Verification model

### Policy tests

Use pure tests for transition permissions, presentation mapping, sorting,
prioritization, and other deterministic rules. These should be fast and contain
no tasks, files, or databases.

### Persistence and side-effect tests

Continue using:

- temporary product databases;
- schema fixtures and migration tests;
- temporary Git repositories and command wrappers;
- bounded fake GitHub transports;
- credential-store fakes; and
- Codex adapter fixtures.

These tests prove the safety boundary but do not replace journey tests.

### Coordinator journey tests

A journey test drives public coordinator commands and observes snapshots while
using real local persistence and local Git where applicable. It must verify both
the presentation-relevant result and the underlying durable state.

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

Tests must not reach into private task dictionaries or manually mutate
presentation flags.

### Deterministic asynchronous control

Provide narrow test tools only when a workflow needs them:

- a manually controlled operation gate;
- an injected clock or sleep closure;
- an async stream recorder;
- a test polling policy; or
- a fake transport whose response is resumed explicitly by the test.

Replace `Task.sleep`-based observation in affected tests as each workflow is
extracted. Do not add a global test framework that production code must
understand.

### Presentation scenarios

For each extracted feature, provide a development-only catalog of meaningful
presentation states. It may use SwiftUI previews, an internal debug scenario
gallery, or focused hosting fixtures consistent with the existing build system.

The catalog must include normal, empty, busy, interrupted, failed, retryable,
stale, and completed states where applicable. It must not contain a fake product
path presented as real functionality to release users.

### Launched-process shell contracts

Launched-process tests prove application-shell contracts that deterministic
tests cannot: control wiring, sheet and window routing, Product switching, and
destination selection. They are added on top of the appropriate deterministic
policy, persistence, or coordinator proof, never instead of it.

The restrictive default is binding: do not add a launched-process test when the
deterministic proof is sufficient. Add one only after a real shell-wiring defect
demonstrates that the contract needs launched-application coverage. The journey
inventory records each feature's `Shell = Y` or `Shell = —` designation; every
`Y` requires a written justification against this criterion.

### Product-owner inspection

Agent verification ends with a relaunched app and an explicit inspection
script. The product owner performs visual and interaction inspection. Record any
discovered defect as a reproducible journey and add automated behavioral
coverage before fixing it where practical.

## Validate changes

Default validation for every change is safe to run concurrently across
worktrees:

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
git diff --check
./scripts/check_architecture_ratchets.sh
```

The launched-process suite is machine-exclusive because it drives the shared
GUI login session and builds an application whose UI-test bundle identifier and
defaults domain are shared by every run. It is required only when a change
touches application-shell wiring: `ContentView.swift`, view files under
`Sources/SpeditoApp`, accessibility identifiers, `UIFixtureRuntime.swift`,
`SpeditoApplication.swift`, or anything under `Tests/SpeditoUITests`.

When required, run only the affected contracts through the machine-wide mutex,
never the whole suite by reflex:

```sh
./scripts/run_ui_tests.sh \
  -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testA02BlankProductLaunchesItsCompleteWorkspace
```

CI remains the backstop that runs the complete launched-process suite with
parallel testing disabled. An agent that skips this suite must say so in its
handoff and state why the change does not touch application-shell wiring.

Do not claim a change is complete if relevant tests are failing. If the full
suite cannot run, state exactly what was and was not validated.

## Relaunch the development app

Use `./scripts/relaunch.sh`. It builds, kills any existing debug
`Spedito` process, and `exec`s the new binary in the foreground. When
called from an agent command, keep the returned command session alive.

After making and validating changes that affect the app, always relaunch it
before handoff and leave it running so the product owner can inspect the result.
Do not wait for a separate relaunch request.

This is deliberately a simple development-only reset. Do not use it while
preserving an active agent turn matters; normal user-initiated app quit still
uses the asynchronous shutdown handler.

## Communicating with the product owner

Be concise and plain. Lead with the answer in one or two sentences, then give
only the detail needed to act on it. Offer one recommendation, not a survey of
options. Do not restate what the owner already knows or re-argue a decision
they have made. A short answer is a feature, not a lack of rigor.

Follow the core rules of Simplified Technical English (ASD-STE100), without
its restricted dictionary: sentences of about 20 words, active voice, one
idea per sentence, the same word for the same thing everywhere, and no
stacked noun clusters. Prefer everyday words over jargon when both are
precise.

State findings directly, without narrative framing. No storytelling, no
"the twist is", no building up to a reveal, and no re-deriving a conclusion
the owner already accepted. Prefer a short list over paragraphs when the
content is a set of facts or steps. Three short points beat five paragraphs.

## Handoff

Lead with the user-visible outcome. Mention the files or areas changed, the
validation performed, and any real limitation that remains. Do not describe a
mock, placeholder, or hard-coded demo as completed functionality.
