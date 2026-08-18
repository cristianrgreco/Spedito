# Owner journey test research and implementation plan

- **Date:** 15 August 2026
- **Status:** Priority 0 complete; Priority 1 work packet 4 covers Backlog, editable Ticket, Sprint planning, and application lifecycle slices
- **Product authority:** `docs/product-spec.md`
- **Architecture authority:** `docs/technical-design.md`
- **Executable coverage ledger:** section 3
- **Evidence baseline:** `69227e6`; section 2 preserves measurements from that commit, while sections 3 and 7.4 record implemented packet evidence.

## 1. Conclusion

A comprehensive journey suite is feasible and valuable, but it should not mean one large XCUITest for every state-machine branch.

The right shape is layered:

1. **Deterministic coordinator journeys** prove owner commands, durable SQLite and Git effects, interruption, recovery, and presentation snapshots.
2. **Presentation scenarios and policy tests** prove meaningful empty, busy, failed, stale, actionable, and completed states without launching the whole app.
3. **A small full-application UI contract suite** proves that the application shell wires controls, sheets, product switching, notifications, and destination routing correctly.
4. **Controlled external smoke checks** cover the few contracts that cannot be represented faithfully by bounded fakes, especially real macOS Notification Center and GitHub authorization.

This follows the repository's architecture and verification rules in `AGENTS.md`. It does not replace strong policy, persistence, Git, adapter, and recovery tests with broad but shallow UI tests.

The inventory below defines **124 owner journey contracts**. The executable
ledger in section 3 gives every Priority 0 row named or non-duplicative composed
deterministic evidence and now records two Priority 1 slices: B01, B04, B06,
B07, B08, B10, B11, P01, P02, P04, P06, and P07. Remaining Priority 1 and 2
rows stay planned. Some contracts should become parameterized tests or several
interruption variants,
so the eventual test-method count will be higher. Only contracts marked
**Shell = Y** are candidates for proof from a launched application process.
Sixteen Priority 0 rows carry that designation and all 16 now have a
launched-process contract.

## 2. Repository evidence

The assessment inspected the app surfaces, the product specification, the technical design, the repository architecture rules, and the existing tests.

Baseline scale at evidence commit `69227e6`:

- 42 Swift source files in `Sources/SpeditoApp`, approximately 44,700 lines.
- 55 Swift test files: 28 app-layer files and 27 Core files.
- `swift test list` exposed 464 automated tests, including 191 app-layer tests,
  and the commit declared 463 `@Test` functions. The close-out tree at
  `0f844d9` declares 517 `@Test` functions, so all counts remain pinned evidence
  rather than a durable invariant.
- No XCUITest target, Xcode project, workspace, or UI test plan exists.
- No `XCUIApplication` tests exist.
- No `.accessibilityIdentifier(...)` contracts exist in `Sources/SpeditoApp`.
- `SpeditoApplication` constructs the normal production `AppModel`; there is no launch-argument fixture composition for a separately launched UI test process.
- No app-layer test drives `AppModel` through a scripted Codex turn. `codexClient` is a private concrete `CodexAppServerClient` created inside the connect path (`Sources/SpeditoApp/AppModel.swift:816` and `:11679`), the existing test initializers (`:887`, `:911`) inject only a store, registry, sound player, notifier, and remote feature, and every scripted `CodexRPCTransport` fake lives in `Tests/SpeditoCoreTests/CodexAdapterTests.swift`.
- `Sources/SpeditoApp/ContentView.swift:607` dismisses the owner-notification banner after a fixed eight-second `Task.sleep`, so any test that must observe or click the banner has a wall-clock deadline unless that interval becomes injectable.
- `Sources/SpeditoCore/Persistence/ProductDatabaseSchema.swift` carries in-place migrations from schema V1 to V13, and only one test exercises the `product-schema-v1` fixture.
- `Sources/SpeditoApp/AppModel.swift:4577` completes a sprint through `completeSprintIfFinished` when the last ticket is accepted, which changes the board, Retrospectives, Reports, and Start sprint eligibility.

Strong existing foundations include:

| Area | Existing evidence |
| --- | --- |
| Owner notifications | `TicketAttentionTests`, `TicketAttentionSoundPolicyTests`, and `SQLiteStoreTests` cover routing, read/resolved state, archived targets, sound policy, and restart durability. |
| Product-scoped background work | `ProductScopedPersistenceTests` covers product switching while refinement and epic planning turns remain active. |
| Epic and ticket presentation policy | `EpicPlanningPresentationTests`, `TicketRefinementApplicationTests`, and `TicketConversationHistoryTests` cover substantial state mapping and apply/conflict rules. |
| Backlog and sprint policy | `PlanningDropPolicyTests`, `SprintStartAvailabilityTests`, `SprintBoardSelectionTests`, `SprintGoalSuggestionPolicyTests`, and `WorkflowPolicyTests` cover deterministic planning rules. |
| Delivery and recovery | `TicketDeliveryRuntimeCoordinatorTests`, `SprintWorkRecoveryTests`, `ProductExecutionLifecycleTests`, and work-log presentation tests cover many individual transitions and durable recovery paths. |
| Repository workflows | Repository import, knowledge, remote connection, publication, account, credential, and AppModel suites already use temporary stores, local Git, bounded transports, and explicit operation events. |
| Knowledge | Knowledge markdown, context selection, proposal validation/materialization, read-state, and table rendering have focused tests. |
| Demos and app versions | Demo guidance, launch, macOS launcher, lifecycle, and app-resource tests cover the execution boundary. |
| Retrospectives and reports | Retrospective guidance/selection and sprint report presentation have focused policy coverage. |
| Codebase and Codex UI policy | Commit-origin, diff-layout, connection-presentation, and installation tests cover deterministic mapping. |

The missing proof is composition across those boundaries. A route test can prove that an epic notification creates an `OwnerNotificationNavigationRequest`; an epic persistence test can prove that questions survive a product switch; neither alone proves that selecting the banner changes Product, opens Backlog, presents the correct Epic, and renders the restored questions.

## 3. Executable coverage ledger — 17 August 2026

### 3.1 Priority 0

This ledger applies the section 5 deduplication rule to every Priority 0 row.
**Named** means at least one cited test carries the row ID. **Composed** means
pre-existing tests jointly or directly prove the deterministic contract and a
wrapper test is intentionally omitted because it would repeat the same commands
and assertions. The 11 pre-existing A11/D01/D02/D04/D05/D10/D11/D12/D17/D18/D19
entries are therefore labelled **Composed**, not retroactively re-badged
**Named**.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| A02 | `ProductScopedPersistenceTests.a02BlankProductCreationActivatesLocalWorkspace`, `PriorityZeroShellJourneyUITests.testA02BlankProductLaunchesItsCompleteWorkspace` | **Named:** the deterministic journey proves the complete durable local workspace; the launched-process contract proves selected-Product and Backlog shell routing. |
| A04 | `ProductExecutionLifecycleTests.productSelectionDoesNotSuspendDelivery`, `TicketAttentionTests.reloadAggregatesBackgroundProductAttention` | **Composed:** Product-scoped continuation and bounded cross-Product attention are independently deterministic; a wrapper would duplicate them. |
| A05 | `ProductScopedPersistenceTests.a05RelaunchRestoresWorkspaceTuple`, `PriorityZeroShellJourneyUITests.testA05RelaunchRestoresProductDestinationAndSprint` | **Named:** the deterministic journey restores the selected Product, destination, and Product-scoped sprint tuple; the launched-process contract proves the same shell projection. |
| A06 | `ProductScopedPersistenceTests.a06ArchiveSelectedProductRoutesToRemainingProduct`, `PriorityZeroShellJourneyUITests.testA06ArchivingSelectedProductRoutesToRemainingProduct` | **Named:** the deterministic journey archives only the selected Product and routes to the remaining active Product; the launched-process contract proves the Product-library and destination projection. |
| A09 | `SQLiteStoreTests.a09SchemaMigrationPreservesCompleteProductHistory` | **Named:** the A09 fixture migrates one version-7 Product containing backlog, work log, knowledge, repository provenance, and delivery history through the complete migration chain. |
| A10 | `ProductExecutionLifecycleTests.a10BoundedShutdownGraceAndQuitNow`, `.appShutdownHasGlobalScope`, `FeatureOperationRegistryTests.scopedAndGlobalSettlement` | **Named:** A10 composes the bounded grace deadline and **Quit now** action without duplicating the existing global-suspension and operation-settlement proofs. |
| A11 | `TicketDeliveryWorkflowCoordinatorTests.crashRecoveryUsesLastDurableMilestone`, `SQLiteStoreTests.invalidCandidateRecoveryIsAtomic` | **Composed:** durable-workspace reuse, the labelled missing-workspace explanation, atomicity, and stale-candidate protection are covered at their owning boundaries. |
| R01 | `RemoteRepositoryAppModelTests.r01ImportedProductOpensBeforeUnderstandingContinues` | **Named:** the imported Product becomes selectable with exact provenance before its explicitly gated background understanding continues. |
| R05 | `RemoteRepositoryAppModelTests.r05EmptyGitHubRepositoryCreation`, `PriorityZeroShellJourneyUITests.testR05ConnectedBlankProductShowsItsExactGitHubRepository` | **Named:** the deterministic journey initializes the exact observed remote default branch; the launched-process contract proves its Product-settings projection. |
| R06 | `RepositoryImportKnowledgeTests.r06ImportedRevisionPreservesDefaultBranchHistory` | **Named:** the imported revision equals the accepted default-branch head and preserves the source history without rewriting it. |
| R07 | `RepositoryImportCoordinatorTests.authorizationCancellationAndRetry`, `RepositoryImportKnowledgeTests.activationFailureCleansOwnedPaths`, `RemoteRepositoryAppModelTests.relaunchedRepositorySetupRecovery` | **Composed:** cancellation, cleanup, retry, and relaunch recovery already cross the coordinator and application boundaries. |
| R08 | `RepositoryImportKnowledgeTests.importedAppLaunchReviewContract`, `.schemaMigrationAndPublication`, `ProductScopedPersistenceTests.completedEmptyRepositoryAnalysisIsTerminal` | **Composed:** exact-revision analysis, independent review, atomic publication, and terminal no-pages recovery are already executable. |
| R09 | `RepositoryKnowledgeCoordinatorTests.r09StaleRetryUsesNewerAcceptedRevision` | **Named:** a stale retry races the accepted newer repository revision and analysis remains bound to the newer durable source. |
| R10 | `RemoteRepositoryServiceTests.matureLocalProductConnection`, `.localProductLifecycle`, `RemoteRepositoryPublishingTests.localBootstrapAndReviewBranch` | **Composed:** captured history, one immutable pull request, and unchanged-head reconciliation are directly covered. |
| R12 | `RemoteRepositoryAppModelTests.r12ObservedTargetChoice` | **Named:** the owner can confirm the newly observed target or disconnect, with each public command producing its exact durable relationship. |
| R13 | `RemoteRepositoryAppModelTests.r13IncomingReviewAndInterruptedRecovery`, `PriorityZeroShellJourneyUITests.testR13IncomingChangesOpenExactReviewCandidate` | **Named:** the deterministic journey proves atomic accept, reject, and interrupted recovery; the launched-process contract opens the exact incoming candidate review. |
| R14 | `RemoteRepositoryAppModelTests.deliveryRemoteSafety`, `.remoteLifecycle`, `GitHubAccountCatalogTests.signOutWaitsForLease` | **Composed:** active-delivery deferral, Product-scoped disconnect, account-scoped sign-out, and relaunch-safe state are covered at their owning boundaries. |
| E01 | `EpicPlanningJourneyTests.e01CreateEpicStartsClarificationWithoutInventedMetadata` | **Named:** the public create command persists only the owner's Epic scope and begins clarification without invented metadata. |
| E02 | `EpicPlanningJourneyTests.e02ClarificationNeedsInputAcrossProducts`, `EpicOwnerNotificationUITests.testE02NeedsInputOpensTheExactEpicAcrossProducts` | **Named:** deterministic and launched-shell E02 journeys protect the original cross-Product defect. |
| E03 | `EpicPlanningPresentationTests.e03ListedAndCustomAnswersEnableSubmission` | **Named:** listed choice and **Other** answers remain mutually exclusive and enable only one **Submit answers** advancement. |
| E05 | `EpicPlanningJourneyTests.e05PlanReadyAcrossProducts` | **Named:** E05 drives background completion and exact-Epic notification routing. |
| E06 | `EpicPlanningJourneyTests.e06ExpiredThreadRecovery` | **Named:** E06 recreates an expired thread from the durable transcript without repeating owner answers. |
| E11 | `EpicPlanningPresentationTests.e11AcceptancePreviewsTransitivePrerequisites` | **Named:** the acceptance preview contains every transitive suggested prerequisite before any durable write. |
| E12 | `SQLiteStoreTests.e12RejectingSuggestionPreservesDeliveredDependent` | **Named:** delivered dependants block an unsafe rejection cascade while open descendants are archived atomically. |
| E14 | `SQLiteStoreTests.e14ArchivingEpicDisposesTicketsAndProposals` | **Named:** Epic archival atomically disposes unfinished tickets and every persisted proposal without touching completed history. |
| B02 | `TicketAttentionTests.b02IncompleteTicketAttentionReturnsToExactTicket`, `PriorityZeroShellJourneyUITests.testB02ClosingIncompleteTicketReturnsToExactSourceTicket` | **Named:** the deterministic journey routes cross-Product attention to the exact editable ticket; the launched-process contract proves the source-Product switch and ticket sheet. |
| B03 | `TicketConversationHistoryTests.b03RelaunchRestoresCompleteRefinementConversation` | **Named:** relaunch restores answered cards, pending cards, comments, and the complete refinement state together. |
| B05 | `TicketRefinementApplicationTests.b05StaleCompletionPreservesNewerDraft` | **Named:** an in-flight stale completion presents the version conflict and preserves the newer owner draft. |
| B09 | `PlanningDropPolicyTests.b09PartialSprintScopeExplainsMissingRelationship` | **Named:** invalid partial scope names the exact missing prerequisite relationship in the owner-facing refusal. |
| P03 | `SprintBoardSelectionTests.p03PartialPlanAndDiscardedPickerState` | **Named:** P03 saves an intentionally partial plan, proves unsaved picker state is not durable, discards to the saved assignment set, and reopens the same durable draft. |
| P05 | `SQLiteStoreTests.p05MissingEstimateAndInvalidDependencyBlockStart`, `PriorityZeroShellJourneyUITests.testP05SprintPlanningShowsStartBlockers` | **Named:** the deterministic journey proves missing-estimate and invalid-dependency blockers; the launched-process contract proves the exact Sprint planning blocker projection. |
| D01 | `SQLiteStoreTests.sprintExecutionSnapshotIsScoped`, `.sprintStartIsDurableAndIdempotent` | **Composed:** the scoped execution snapshot and one durable idempotent start are directly covered. |
| D02 | `WorkflowPolicyTests.dependencyAwareRunAdmission`, `.uncappedIndependentRunAdmission`, `TicketDeliveryRuntimeCoordinatorTests.duplicateSchedulingWakesExistingScheduler` | **Composed:** the independent first wave, prerequisite release, and identity-safe scheduler wake are covered at their owning boundaries. |
| D03 | `TicketAttentionTests.d03ProductSwitchPreservesActiveQuestionRoute` | **Named:** Product switching leaves active delivery running and routes attention back to the exact ticket question. |
| D04 | `TicketDeliveryWorkflowCoordinatorTests.pausedDeliveryResumesExistingRun`, `SQLiteStoreTests.sprintPauseAndResumeAreDurable` | **Composed:** a paused durable run relaunches and resumes its preserved workspace instead of restarting. |
| D05 | `TicketDeliveryWorkflowCoordinatorTests.stoppedDeliveryPreservesAuditAndReturnsTicketToReady`, `SQLiteStoreTests.stoppingSprintPreservesAcceptedWorkAndSupersedesUnacceptedWork` | **Composed:** the public stop command preserves accepted work and audit history, supersedes unaccepted candidates, and returns unfinished tickets to Ready. |
| D06 | `SQLiteStoreTests.agentRunLifecycleIsDurable`, `CodexAdapterTests.liveActivitySummaries`, `SprintTicketWorkLogHistoryTests.structuredArtifactsAreChronological`, `.workLogRowsUseOneOrderedSnapshot` | **Composed:** pre-existing boundary tests jointly prove attributed implementation and review activity is durable, reduced to concise supported summaries rather than raw protocol content, and projected in one chronological work log. |
| D07 | `ProductScopedPersistenceTests.entityWritesUseOwningProductStore`, `SprintTicketWorkLogHistoryTests.activeTicketQuestionRouting`, `.readyForDemoCommentRouting`, `.unansweredPermissionCommentRouting`, `.d15ReadyForDemoCommentPreservesCandidate` | **Composed:** pre-existing command and policy tests persist the owner comment in the ticket's owning product, choose the active team member before the assignee/recent-participant/Tech Lead fallback, keep a pending permission question routable, and preserve the reviewed candidate; they are composed rather than retroactively re-badged as named. |
| D08 | `TicketDeliveryWorkflowCoordinatorTests.d08PermissionReviewActionsPersistDistinctDecisions`, `PriorityZeroShellJourneyUITests.testD08PermissionReviewPresentsDenyAllowOnceAndAlwaysAllow` | **Named:** the deterministic journey persists Deny, Allow once, and Always allow as distinct decisions; the launched-process contract proves all three review controls. |
| D09 | `TicketDeliveryWorkflowCoordinatorTests.d09SubmittedAnswersResumeExactRun`, `PriorityZeroShellJourneyUITests.testD09OwnerQuestionPresentsListedOtherAndSubmitAnswers` | **Named:** the deterministic journey proves **Submit answers** resumes the exact paused run; the launched-process contract proves listed choice, **Other**, and submission wiring. |
| D10 | `ProductScopedPersistenceTests.implementationRetryPreservesRunIdentity`, `TicketDeliveryRuntimeCoordinatorTests.staleCompletionCannotClearReplacement` | **Composed:** failed and interrupted implementations requeue with preserved run identity, workspace, and thread while stale completion remains harmless. |
| D11 | `TicketDeliveryWorkflowCoordinatorTests.approvedReviewRemainsCandidateBound`, `GitWorkspaceManagerTests.candidateLifecycle` | **Composed:** independent review and its handoff remain bound to the immutable integrated candidate. |
| D12 | `GitWorkspaceManagerTests.candidateLifecycle`, `.conflictResolutionLifecycle`, `WorkflowPolicyTests.candidateIntegrationsPrecedeReview` | **Composed:** exact integration, conflict resolution, and changed-result review ordering are covered at their owning boundaries. |
| D13 | `RemoteRepositoryAppModelTests.d13RequestedChangesResumePublishedTicket` | **Named:** requested GitHub changes return the ticket to In progress and resume the same immutable publication branch. |
| D14 | `TicketDeliveryWorkflowCoordinatorTests.d14DemoRetryReusesReviewedCandidate`, `PriorityZeroShellJourneyUITests.testD14DemoRetrySelectsTheReviewedCandidate` | **Named:** the deterministic journey retries host preparation only for the reviewed candidate; the launched-process contract proves exact App-version selection. |
| D15 | `SprintTicketWorkLogHistoryTests.d15ReadyForDemoCommentPreservesCandidate`, `PriorityZeroShellJourneyUITests.testD15ReadyForDemoCommentKeepsCandidateActionable` | **Named:** the deterministic journey proves a ready-for-demo owner comment preserves the reviewed candidate; the launched-process contract leaves that candidate actionable after the comment settles. |
| D16 | `SQLiteStoreTests.d16CandidateKnowledgeDecisionsPublishOnlyAcceptedContent` | **Named:** only accepted candidate knowledge becomes canonical; rejected and unreviewed proposals remain non-authoritative after relaunch. |
| D17 | `TicketDeliveryWorkflowCoordinatorTests.repositoryAcceptancePromotesExactRevision`, `PriorityZeroShellJourneyUITests.testD17ApprovalClosesDetailAndPresentsCompleting` | **Named:** the deterministic proof promotes the exact reviewed repository revision before Done; the launched-process contract proves approval immediately closes Ticket detail and presents **Completing** while finalization remains in progress. |
| D18 | `TicketDeliveryWorkflowCoordinatorTests.failedAcceptanceRetriesWithoutDuplicateCompletion` | **Composed:** the reviewed result survives failure and retries without duplicate promotion. |
| D19 | `TicketDeliveryWorkflowCoordinatorTests.repositoryFreeAcceptanceCompletesWithoutGit` | **Composed:** repository-free handoff and knowledge publish without a Git mutation. |
| D20 | `CodexAdapterTests.d20ResearchPromptIncludesActiveScopeAndExcludesHistory`, `TicketDeliveryWorkflowCoordinatorTests.d20ReviewedResearchFollowUpsPublishWithProvenance` | **Named:** authorised research receives the active downstream scope and excludes released history; no proposal publishes before its candidate is reviewed, then the accepted outcome publishes one reviewable suggestion batch with source Ticket, Epic, existing-dependency, and proposal-dependency provenance without creating Backlog tickets. |
| D21 | `TicketDeliveryWorkflowCoordinatorTests.d21FinalAcceptanceCompletesSprintReportEvidence` | **Named:** final acceptance closes the active Sprint and preserves its started/completed interval, item membership, accepted candidate, and Agent-run evidence across a fresh store for the report. |
| D22 | `TicketDeliveryRuntimeCoordinatorTests.d22CapacityWaitWakesOneImplementationOperation`, `.d22CapacityPolicyPreservesDurableWaitUntilFreshRecovery`, `SQLiteStoreTests.d22QueuedDeliveryCapacityWaitSurvivesFreshStore`, `SprintTicketRunTelemetryPresentationTests.d22CapacityWaitExplainsRecoveryWithoutFailure` | **Named:** an account or safety-capacity limit persists on the queued Agent run, suppresses duplicate scheduler children and false failure, explains the automatic retry to the owner, survives a fresh store, and wakes exactly one implementation operation once current observations show capacity. |
| C02 | `CodexTransportApplicationTests.c02ConcurrentConversationsRemainIndependent` | **Named:** concurrent same-agent replies settle out of order while each thread retains its own durable transcript, unread state, and notification identity. |
| C07 | `TicketAttentionTests.c07BackgroundChatRoutesAndClearsOnlyTarget`, `PriorityZeroShellJourneyUITests.testC07BackgroundChatOpensItsExactSourceThread` | **Named:** the deterministic journey routes to the exact cross-Product Chat thread and clears only its unread target; the launched-process contract proves shell navigation and the persisted reply. |
| C09 | `TicketAttentionTests.c09VisibleTargetReadResolutionAndCounts` | **Named:** visible-target suppression, read, resolution, and deduplicated Product counts are composed in one deterministic journey. |
| C10 | `TicketAttentionTests.notificationRouteRoundTrips`, `.archivedTargetDoesNotNavigate` | **Composed:** every target kind round-trips and an archived target fails closed without navigation. |
| K04 | `RepositoryKnowledgeCoordinatorTests.k04PublicationLockAndFailureRecovery` | **Named:** publication locks owner edits and a recoverable failure preserves drafts for an explicit retry. |
| V06 | `MacOSDemoLauncherTests.v06HistoricalAcceptedVersionLaunchesExactRevision`, `PriorityZeroShellJourneyUITests.testV06HistoricalAcceptedAppVersionIsIndependentlySelectable` | **Named:** the deterministic journey stops the active version and reconstructs the selected accepted revision; the launched-process contract proves historical versions remain independently selectable. |
| I03 | `SQLiteStoreTests.i03RetrospectiveSynthesisRecoveryAndSkipPreserveSources` | **Named:** interruption, failed retry, and explicit continue-without-AI preserve one durable synthesis command and its evidence sources. |
| I06 | `SQLiteStoreTests.retrospectivePracticeLifecycle` | **Composed/direct:** the accepted action updates the inherited verified Ways of working page once with source provenance; no wrapper is needed. |
| I07 | `RetrospectiveJourneyTests.i07AcceptedBacklogActionOpensExactTicketRefinement`, `PriorityZeroShellJourneyUITests.testI07AcceptedRetrospectiveActionOpensExactTicketRefinement` | **Named:** the deterministic journey proves accept creates the exact durable Backlog ticket, starts its Business Analyst refinement, and preserves the accepted link across relaunch; the launched-process contract asserts that Backlog opens that accepted ticket's durable identifier, not the released source delivery, while refinement is active. |
| S02 | `SQLiteStoreTests.s02SavedAgentAccessRevocationJourney` | **Named:** revoke-one and confirmed revoke-all preserve the audit trail and cause subsequent exact access requests to prompt again. |
| S04 | `SQLiteStoreTests.teamSettingsUpdateIsAtomic`, `ProductScopedPersistenceTests.teamSettingsCommandReturnsCommittedSnapshot` | **Composed:** atomic persistence and retryable application presentation cover the shared-guidance/member-settings boundary. |

Every Priority 0 row has named or non-duplicative composed deterministic
evidence. All 16 Priority 0 rows designated `Shell = Y` also have a
launched-process contract.

### 3.2 Priority 1 work packet 4 — Backlog and editable Ticket

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| B01 | `EditableTicketJourneyTests.b01ManualTicketOpensInitialRefinement` | **Named:** manual creation persists the incomplete Ticket with its optional Epic association, routes directly to editable detail with initial refinement enabled, and recovers the exact saved Ticket after a fresh store instance. |
| B04 | `EditableTicketJourneyTests.b04RefinementSuggestionsApplySelectivelyThenSave`, `TicketRefinementApplicationTests.completedRefinementIsAppliedAsOneUpdate` | **Named:** one field remains local, apply-all respects a dismissed dependency, SQLite stays unchanged before Save, and the selected fields and dependency recover after a fresh instance. |
| B06 | `EditableTicketJourneyTests.b06TeamProposalFieldsRemainUnsavedUntilSave`, `CodexTransportApplicationTests.ticketRefinementAndConversationJourney` | **Named:** the scripted conversation proves real team prose changes no Ticket fields and remains durable; B06 maps an explicit proposal into the editor without a write and persists only the fields passed through Save. |
| B07 | `EditableTicketJourneyTests.b07EditableTicketFieldsValidateAndPersist`, `SQLiteStoreTests.editableTicketDetailsAreDurable` | **Named:** the complete editable field set, assignee, custom fields, and blocker are saved and recovered together; blank and case-insensitive duplicate custom-field names disable Save without mutating the draft. |
| B08 | `EditableTicketJourneyTests.b08LinkedNavigationPreservesUnsavedEdits`, `EpicPlanningPresentationTests.ticketDetailsResolveEpic`, `.relationshipLinksResolveRelatedTicket` | **Named:** the editor's bounded presentation state opens and returns from both Epic and Ticket relationships while retaining the exact unsaved title, context, and blockers. |
| B10 | `EditableTicketJourneyTests.b10BacklogReorderPersistsDependencyOrder`, `PlanningDropPolicyTests.placementPreviewsIdentifyValidRange`, `.repeatedInvalidPreviewRemainsInvalid`, `SQLiteStoreTests.dependencyAwareRanking` | **Named:** a valid reorder survives a fresh store instance; invalid drag previews remain stable, and top/bottom commands cannot move either side of a dependency across the other. |
| B11 | `EditableTicketJourneyTests.b11ConfirmedArchiveRemovesActiveTicketReferences`, `SQLiteStoreTests.ownerManagedBlockers`, `.bulkArchiveWorkItems` | **Named:** cancellation leaves the Ticket active, confirmation archives the exact requested Ticket, active sprint planning and dependency/suggestion projections exclude it, and its work log plus archive event remain available after a fresh instance. |

### 3.3 Priority 1 work packet 4 — Sprint planning

This coherent slice covers P01, P02, P04, P06, and P07. It preserves the
existing P03 discard boundary and P05 start-readiness authority. Changing
start-readiness rules, delivering a sprint, changing backlog scope, and
redesigning the surrounding Backlog or Sprint board are non-goals. All five
rows remain `Shell = —` because their coordinator, persistence, and bounded
presentation contracts are deterministic; no launched-process test is
justified.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| P01 | `SprintBoardSelectionTests.p01PlanningScopeMatchesNextSprintAcrossRelaunch`, `PlanningDropPolicyTests.bulkActionsMoveExactRequestedScope`, `SQLiteStoreTests.candidateSprintDefinesPlanningScope` | **Named:** the application command persists the exact Next sprint set, the planning presentation projects every scoped Ticket once and no backlog-only Ticket, and a fresh store and model recover the same set. |
| P02 | `SprintPlanningWorkflowJourneyTests.p02TicketPlanningAppliesSelectedProposalAndAssignment`, `CodexAdapterTests.sprintPlanningConversation`, `TicketRefinementApplicationTests.b05StaleCompletionPreservesNewerDraft` | **Named:** one selected team member receives the owner-edited Ticket snapshot and proposed assignee; only the accepted version-safe proposal changes its Ticket, the other scoped Ticket remains unchanged, and the saved assignment and work-log evidence recover in a fresh model. |
| P04 | `SprintBoardSelectionTests.p04PlanningSummaryPresentsAllDecisionSignals`, `SprintForecastTests`, `SQLiteStoreTests.sprintPlanningHasNoConcurrencySetting` | **Named:** the bounded summary orders a dependant after its prerequisite and aggregates Ticket forecast, elapsed waves, the most constrained Codex usage window, risks, and one owner demo per scoped Ticket. |
| P06 | `SprintPlanningWorkflowJourneyTests.p06GoalFailureLeavesDeliveryUsable`, `.generatedGoalStaysWithOwningPlanAcrossProductSwitchAndRelaunch`, `SQLiteStoreTests.sprintGoalCanFinishAfterStart`, `SprintGoalSuggestionPolicyTests` | **Named:** only a missing goal is eligible; generation remains bounded and exact-plan scoped, stale output is rejected, start does not wait, and an invalid terminal response leaves the saved draft startable and recoverable without affecting another Product. |
| P07 | `SprintBoardSelectionTests.p07SavedDraftAndBoardContextRecoverWithoutUnsavedChanges`, `.p03PartialPlanAndDiscardedPickerState`, `.newlyPlannedSprintBecomesSelected` | **Named:** a fresh store and model restore the durable draft assignment and Product-scoped board selection, discard the unsaved picker choice, and fall back to the valid draft when a stored selection is stale. |

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Draft scope loaded | Open Sprint planning | One SQLite draft sprint whose items are the Next sprint scope | Every scoped Ticket once, in dependency waves | Review a Ticket, assign delivery, save, or close | A fresh model rebuilds scope from the draft |
| Ticket review editing | Edit a scoped Ticket or choose an assignee | No write until the explicit Ticket or plan save | Local edits and the selected team member | Save, ask one team member, apply a version-safe proposal, or discard | Unsaved edits disappear; the last saved Ticket and assignment return |
| Team reply running | Send a Ticket-scoped planning message | Owner comment is durable before the bounded Codex turn; reply or labelled failure is appended afterward | One selected team member and a Stop action | Stop or await the reply | Interruption settles to durable work-log evidence without changing the Ticket |
| Plan summary | Review sprint | Draft scope, dependency edges, estimates, and assignments remain in SQLite | Dependency order, forecast, remaining usage, and owner acceptance load | Return to Ticket review or save | Recomputed from durable state |
| Goal generation | Save a plan with no goal | The versioned draft remains authoritative while generation is transient | Delivery remains usable while a bounded suggestion runs | Continue to the board or start when otherwise ready | Stale output is rejected; failure leaves the draft startable |
| Saved draft selected | Save and open the board | Draft plan and Product-scoped board selection | The same valid planning/board context | Resume planning or start | Fresh-instance recovery restores the saved draft and ignores unsaved picker state |

### 3.4 Priority 1 work packet 4 — Application shell and Product lifecycle

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| A01 | `RemoteRepositoryAppModelTests.a01CancelingCreationLeavesEmptyOnboardingUsable`, `RepositoryImportCoordinatorTests.authorizationCancellationAndRetry` | **Named:** a cancellable GitHub authorization drives the real AppModel cancellation command; the empty Product collection remains on the onboarding root and a second authorization command succeeds through the same flow. |
| A03 | `ProductScopedPersistenceTests.a03ProductSearchAndSwitchingRestoreDestinationsAfterRelaunch`, `AppModelStartupTests.legacyDefaultsMigration`, `SprintBoardSelectionTests.newlyPlannedSprintBecomesSelected` | **Named:** the production Product-library projection finds the exact active Product, a fresh AppModel restores its selection, and switching between Products resolves each Product's own persisted workspace destination. |
| A07 | `ProductScopedPersistenceTests.a07RestorePreservesCompleteProductHistory`, `PriorityZeroShellJourneyUITests.testA07ArchivedProductRestoresIntoItsWorkspace` | **Named:** interruption leaves the Product durably archived; a fresh registry restores its backlog, work log, complete delivery transitions, repository provenance, and knowledge revisions, while the launched-process contract proves the restore control opens that Product's workspace. |
| A12 | `RemoteRepositoryAppModelTests.a12FailureRetryAndProductSwitchingStayScoped`, `RemoteRepositoryFeatureModelTests.snapshotLifecycle` | **Named:** a repository failure remains attached only to its Product while another Product is selected, and an explicit retry clears the failed Product without replacing the other Product's valid presentation. |

A07 remains `Shell = Y` because restoring from the empty onboarding root crosses
the launched application's archived-Product sheet and workspace-routing boundary.
A01, A03, and A12 remain `Shell = —`: their application commands, bounded
presentation projections, Product switching, and recovery are deterministic without
a launched process.

### 3.5 Priority 1 work packet 4 — Repository import and GitHub connection

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| R02 | `RepositoryImportKnowledgeTests.publicRepositoryURLValidation`, `.activationFailureCleansOwnedPaths` | **Composed/direct:** the typed repository URL boundary rejects insecure schemes, credentials, query or fragment data, local addresses, non-default ports, and unsupported hosts before an import command can exist; the importer cleanup proof independently establishes that even a later activation failure leaves no staged or registered Product. A wrapper would repeat those same boundaries. |
| R03 | `RemoteRepositoryServiceTests.r03DeviceFlowCatalogAndCredentialBoundary`, `.localProductLifecycle`, `RepositoryImportCoordinatorTests.authorizedImport`, `GitCredentialSessionTests.defaultCredentialSocketPath`, `RemoteRepositoryPublishingTests.apiRequestSafety` | **Named J:** bounded Device Flow returns public and private choices, passes the selected private repository through a canonical credential-free URL and an ephemeral credential helper, and recovers the durable selecting-repository state plus its transient catalog through a fresh service instance. Bearer-token request safety remains covered at the API boundary. **M remains external:** real GitHub authorization and installation access are not represented by the fake. |
| R04 | `RemoteRepositoryAppModelTests.r04InstallationReturnAndManualRefresh`, `.relaunchedRepositorySetupRecovery`, `RemoteRepositoryServiceTests.importedProductConnection` | **Named J:** one application-return policy triggers the Product-scoped refresh only after access settings were opened and the app becomes active; the same command remains available for manual propagation-delay refresh, and interrupted setup recovers from its durable selection. **M remains external:** browser return and real GitHub installation propagation require the controlled smoke below. |
| R11 | `RemoteRepositoryServiceTests.r11ImportedProductRejectsUnrelatedAccessibleTarget`, `.importedProductConnection`, `RemoteRepositoryAppModelTests.repositorySetupLaunch` | **Named:** when only an unrelated repository is accessible, the imported Product persists `needsInstallation` without adopting any repository identity; a fresh service retains its exact source provenance, and presentation routes to installation access rather than a target picker. The existing success proof connects only after that preserved repository becomes accessible. |

All four rows remain `Shell = —`: URL admission, Device Flow orchestration,
refresh commands, imported-source matching, and interruption recovery are
deterministic at their Core or bounded application boundary. Their external
GitHub behavior is `M`, not application-shell wiring.

Controlled external smoke, outside the deterministic suite:

- **R03:** with a disposable GitHub account whose Spedito installation can see
  one public and one private test repository, complete Device Flow, confirm both
  repositories are listed, import the private repository, and verify its saved
  origin and local Git configuration contain neither the access token nor an
  embedded credential.
- **R04:** remove the test repository from the GitHub App installation, choose
  **Manage access**, grant it in GitHub, return to Spedito, and confirm the list
  refreshes automatically; repeat with delayed propagation and confirm
  **Refresh list** reveals it without restarting setup.

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Input rejected | Enter an unsupported or credential-bearing URL | No Product, workspace, or import operation exists | The repository link remains invalid | Correct the link or cancel | There is no operation to recover |
| Device authorization | Authorize GitHub | The credential is confined to the credential store; no source URL contains it | Verification code and GitHub destination | Complete or cancel authorization | Cancellation settles; a later command starts a new authorization |
| Repository selection | Complete authorization | Product-scoped connection and account link in SQLite; catalog remains transient | Accessible public and private repositories | Select a repository, refresh, or cancel | A fresh service reloads the durable selection state and refreshes the catalog |
| Installation access required | The preserved imported source is absent or lacks permissions | `needsInstallation` and unchanged Product provenance in SQLite | Exact access guidance, never an unrelated target picker | Manage access, refresh, or cancel setup | A fresh service restores the access-required state and original provenance |
| Access refresh | Return from GitHub or choose **Refresh list** | Any resulting connection transition is saved by the remote service | Updated accessible repository list or the same access guidance | Select, retry refresh, or manage access | Relaunch refreshes a durable pending selection before eligibility checking |

### 3.6 Priority 1 work packet 4 — Epics and suggestions

This slice closes E04, E07, E08, E09, E10, and E13 without changing Epic
creation, clarification question semantics, dependency-cascade rules, or Sprint
planning. `EpicPlanningWorkflowCoordinator` remains the single owner of
clarification, plan generation, suggestion edits and decisions, interruption,
and recovery. All six rows remain `Shell = —`: the public commands, bounded
presentation policies, durable SQLite transitions, exact Codex request seam,
Product isolation, and fresh-instance recovery are deterministic without a
launched process.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| E04 | `CodexTransportApplicationTests.e04OrdinaryEpicChatPreservesPendingQuestions` | **Named:** an ordinary Epic message uses its selected team-member thread, appends the owner message and reply chronologically, and preserves the separate unanswered governed clarification question and thread across a fresh instance. |
| E07 | `EpicPlanningJourneyTests.e07StoppedClarificationRecoversContextualRetry` | **Named:** Stop settles the active clarification into a durable owner-facing paused state; a fresh model offers one retry, starts a replacement thread with the durable transcript and answered context, and returns to the exact governed question state without duplicating answers. |
| E08 | `EpicPlanningJourneyTests.e08OwnerEpicEditsSurvivePlanningRetry` | **Named:** malformed plan output receives one repair attempt and then fails reviewably without changing the Epic or Backlog; owner edits to title, goal, success criteria, and constraints become authoritative retry input, survive the successful retry unchanged, and still create only reviewable proposals. |
| E09 | `EpicPlanningJourneyTests.e09EditedSuggestionAcceptsWithoutChangingUnrelatedProposals`, `EpicPlanningPresentationTests.e09SuggestionReviewDisclosesAcceptanceImpact` | **Named:** the review projection discloses rationale, prerequisite scope, Backlog impact, and the no-Sprint boundary; editing every mutable proposal field preserves dependency identity through a fresh registry, acceptance creates the exact edited Ticket plus prerequisite, and unrelated proposals and Products remain unchanged. |
| E10 | `EpicPlanningJourneyTests.e10AllSuggestionDecisionsPersistWithoutStartingSprint`, `EpicPlanningPresentationTests.e10AllSuggestionConfirmationsStateScope` | **Named:** both confirmations name the exact remaining proposal count and no-Sprint effect; **Accept all** preserves dependency edges and **Reject all** creates no Tickets, with both decisions surviving a fresh registry while another Product remains unchanged. |
| E13 | `EpicPlanningJourneyTests.e13InterruptedGenerationRetriesWithoutDuplicatesOrProductLeakage` | **Named:** generation interrupted at its durable session boundary recovers through the public coordinator, retains the earlier completed proposal batch, completes the interrupted batch once with unique identities, and does not expose or change another Product's proposal. |

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Ordinary Epic conversation | Send a message to one team member | Owner message and reply in the selected conversation thread | Chronological chat while any governed questions remain separately actionable | Continue chat or answer the governed question | Fresh-instance projection restores both threads without treating chat as an answer |
| Clarification paused | Stop an active clarification turn | Persisted transcript, answered questions, thread identity, and paused explanation | The planning conversation with a safe retry | Retry or leave the Epic | Retry uses the durable context once and rejects stale output |
| Plan failed | Structured output and one repair both fail | Failed suggestion session with technical evidence; unchanged Epic and Backlog | Reviewable failure and **Retry plan** | Edit the Epic, retry, or leave it failed | Fresh recovery retains owner edits and starts one bounded retry |
| Proposal review | Open one proposed Ticket | Proposed fields, rationale, and dependency identities in SQLite | Full proposal details plus exact acceptance impact | Edit, discuss, accept, or reject | Edits and outstanding proposals rebuild from SQLite |
| Batch decision | Confirm **Accept all** or **Reject all** | One durable decision per proposed suggestion and accepted Ticket links where applicable | Exact remaining scope and confirmation consequence | Confirm or cancel | Fresh registry recovers all decisions and Backlog Tickets; no Sprint is created |
| Generation interrupted | Process ends during a generating session | Generating session, attached turn identity when available, and earlier completed batches | Recoverable planning state without duplicate proposals | Retry or leave the prior proposal available | Recovery resumes or replaces the turn idempotently and remains Product-scoped |

### 3.7 Priority 1 work packet 4 — Chat and owner notifications

This slice closes C01, C03, C04, C05, C06, C08, and C11 without changing
notification timing, adding a new conversation representation, or moving
notification authority out of SQLite. Product Chat operations remain owned by
`ProductConversationFeatureModel` and `ProductConversationRuntime`; Ticket and
Epic conversation operations remain owned by
`PlanningConversationWorkflowCoordinator`; `OwnerNotificationCoordinator`
remains the bounded notification projection. All seven rows remain
`Shell = —`: their commands, persistence, routing metadata, presentation
policies, and interruption recovery are deterministic without a launched
process. C08 and C11 retain their real Notification Center `M` boundary.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| C01 | `CodexTransportApplicationTests.scriptedProductConversation`, `ProductConversationTests.durableThreads`, `.boundedContext`, `.splitReplyAndTitle` | **Composed:** the application transport journey, durable thread/title compare-and-set proof, bounded-room context policy, and strict title decoder jointly cover a new durable Product Chat thread, one owner/agent exchange, bounded context, and an independently generated concise title. |
| C03 | `ProductConversationTests.retargetedThread`, `.boundedContext` | **Composed:** recipient retargeting preserves the Product thread identifier and complete message chronology, clears only the prior role-specific Codex session, supplies a bounded handoff to the next team member, and recovers the retargeted thread after a fresh store instance. |
| C04 | `CodexTransportApplicationTests.c04ProductConversationFailureRetriesWithoutDuplicatingMessage` | **Named:** a malformed empty Codex response leaves the owner-authored message and failed thread durable; a fresh application model exposes that failure and Retry resumes the same thread to completion without duplicating the message. |
| C05 | `TicketConversationHistoryTests.c05ArchivedProductChatPresentation`, `ProductConversationTests.durableThreads` | **Named:** active Product Chat hides archived threads until requested; archive survives a fresh store with transcript and Codex identity intact, and restore returns the same thread and messages to active history. |
| C06 | `TicketConversationHistoryTests.c06ConversationRecipientDefaults`, `CodexTransportApplicationTests.ticketRefinementAndConversationJourney`, `.e04OrdinaryEpicChatPreservesPendingQuestions` | **Named:** Ticket conversation prefers its assigned implementer while Ticket and Epic conversations otherwise prefer the Business Analyst then Tech Lead; explicit recipient replies persist in the owning Ticket/Epic work log, and the Ticket path recovers after Product switching and relaunch. |
| C08 | `TicketAttentionTests.c08ForegroundAndBackgroundNotificationDelivery`, `.notificationRouteRoundTrips` | **Named J/P:** foreground and background policies are mutually exclusive, the in-app banner and attention sound remain available, background metadata routes to the exact durable target, and a fresh coordinator recovers the unread notification. **M remains external:** real macOS Notification Center delivery and open routing require the controlled smoke below. |
| C11 | `TicketAttentionTests.c11DeclinedSystemNotificationsPreserveInAppAttention`, `TicketAttentionSoundPolicyTests.enteringAwaitingOwnerPlaysSound`, `.existingAwaitingOwnerStateStaysQuiet`, `.appShutdownStaysQuiet` | **Named J/P:** a declined system-notification boundary cannot discard the durable alert, in-app presentation or attention sound; a fresh coordinator loads it without reposting or replaying sound, while policy keeps repeated refreshes and shutdown quiet. **M remains external:** the real macOS authorization prompt and denied setting require the controlled smoke below. |

Controlled external smoke, outside the deterministic suite:

- **C08:** in a disposable macOS user account with Spedito notifications
  authorized, background Spedito and trigger both a team reply and a
  needs-your-input event. Confirm Notification Center shows the correct Product,
  title, summary, and one sound only for the question; open each notification
  and confirm Spedito routes to its exact durable thread or Ticket. Repeat while
  Spedito is foreground and confirm only the in-app banner appears.
- **C11:** deny Spedito notification authorization in macOS, trigger a
  needs-your-input event, and confirm the durable in-app indicator, banner, and
  sound remain available. Relaunch twice and confirm Spedito neither prompts
  again nor loses the alert; authorization may be changed later in System
  Settings.

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Product thread active | Send the first Product Chat message | Thread, owner message, selected team member, and eventual reply in SQLite | One titled thread and chronological messages | Continue, switch recipient, stop, or archive | Fresh load reconstructs the thread and bounded transcript |
| Recipient handoff | Send a follow-up to another team member | Same thread and messages; updated recipient; prior Codex identity cleared | One continuous conversation with the selected recipient | Continue or stop | Fresh store preserves the handoff and creates a bounded replacement context |
| Product reply failed | A malformed or transient Codex result settles | Failed thread and original owner message; diagnostic remains presentation state | Clear failure and **Retry** | Retry, write another message, or archive | Fresh model offers Retry against the same durable message |
| Product thread archived | Archive a settled thread | Archived status, transcript, generated title, and Codex identity | Hidden active history plus an optional archived section | Show archived or restore | Fresh store keeps it archived until restore |
| Ticket or Epic conversation | Send to a selected team member | Owner message and reply in the entity's durable conversation/work log | Role-default recipient, alternatives, and chronological reply | Continue with any team member | Product switching and fresh models restore the owning entity history |
| Foreground notification | Publish while Spedito is active | Owner notification and exact target in SQLite | In-app banner/indicator; questions use the bundled sound | Open or dismiss | Fresh coordinator reloads unread attention |
| Background notification | Publish while Spedito is inactive | Same durable notification and route metadata | Notification Center when authorized; no in-app banner until active | Open from macOS or return to Spedito | Denial affects only system delivery; durable in-app attention remains |

### 3.8 Priority 1 work packet 4 — Product knowledge

This slice closes K01, K03, K05, and K06 without introducing a second
Knowledge representation or moving canonical-page authority out of SQLite.
Repository publication remains owned by `RepositoryKnowledgeCoordinator`;
ordinary page commands remain application composition over
`SQLiteStore+KnowledgePages`; read markers remain a Product-scoped presentation
preference that can be rebuilt from page timestamps. K01, K03, and K06 remain
`Shell = —` because their state and routing policies are deterministic. K05
remains `Shell = Y`: only a launched process can prove that submitting the real
Knowledge field presents the answer sheet and that its exact citation control
closes the sheet and selects the cited page.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| K01 | `KnowledgePageReadStateTests.k01ChangedPagesBecomeUnreadIndependently` | **Named:** independent Product/page timestamps become unread, selecting one changed page clears only that marker, and a fresh read-state instance preserves the selection without clearing its sibling or another Product. |
| K03 | `KnowledgePageReadStateTests.k03KnowledgeEditCancelSaveAndRelaunch` | **Named:** the application command creates beneath the selected section, Cancel restores the canonical draft without a revision, Save appends exactly one revision, and a fresh SQLite store recovers the edited title and body. |
| K05 | `KnowledgePageReadStateTests.k05KnowledgeAnswersLinkOnlyCitedVerifiedPages`, `PriorityZeroShellJourneyUITests.testK05GroundedAnswerOpensItsExactCitedKnowledgePage` | **Named:** grounded and Unknown decoder results project only unique cited verified pages; the launched-process contract submits the actual Knowledge field, renders its answer sheet, and opens the exact cited page. |
| K06 | `KnowledgePageReadStateTests.k06AcceptedTicketKnowledgeResolvesCanonicalPage`, `SQLiteStoreTests.d16CandidateKnowledgeDecisionsPublishOnlyAcceptedContent` | **Named:** the work-log action resolves accepted create/update proposals only to their verified canonical page; rejected proposals and unverified targets cannot navigate, while the durable publication proof keeps rejected and historical proposals non-authoritative. |

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Knowledge page changed | A canonical page receives a newer SQLite timestamp | Page and revisions in SQLite; last-seen Product/page timestamp in preferences | Unread count and changed-page marker | Select the page | Fresh load compares the same scoped timestamps |
| Page editing | Choose **Edit** | Canonical page remains unchanged; draft text is presentation state | Editable title/body plus **Cancel** and **Save** | Cancel or save | Cancel restores canonical text; termination discards only the draft |
| Page saved | Choose **Save** | Updated page and appended revision in one store authority | Canonical edited page and version history | Continue editing or inspect history | Fresh store reconstructs the latest page and every revision |
| Knowledge answering | Submit a question | Verified pages are bounded input; the task and answer sheet are transient | Busy answer sheet | Close | Interruption leaves canonical Knowledge unchanged and allows a new question |
| Grounded or Unknown answer | The bounded Codex turn settles | No workflow mutation; citations are validated against the supplied verified page IDs | Answer text and only exact verified source links, or a plain Unknown result | Open a source or close | A new question starts a new bounded transient answer |
| Accepted Ticket knowledge | Open a published work-log proposal | Proposal decision, source Ticket provenance, and canonical verified page in SQLite | Exact canonical Knowledge destination | Open the page | Rejected, historical, missing, or unverified targets fail closed |

### 3.9 Priority 1 work packet 4 — Codebase and App versions

This slice closes V01, V04, V05, and V07 without introducing a second Git
history, Ticket, or runnable-version authority. `GitWorkspaceManager` remains
the live repository observer, accepted Candidate revisions remain the durable
Ticket/version evidence in SQLite, and imported launch recipes remain owned by
`RepositoryKnowledgeCoordinator`. V01, V05, and V07 remain `Shell = —` because
their repository, filtering, retry, review, and publication contracts are
deterministic. V04 remains `Shell = Y`: the Codebase callback had incorrectly
forced every originating Ticket into delivery detail, so its launched-process
contract is required to prove that the exact commit action crosses the
application sheet boundary and uses the shared current-sprint mode policy.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| V01 | `GitWorkspaceManagerTests.v01RefreshReadsCurrentRepositoryState` | **Named:** a second repository snapshot reads newly accepted trunk and Ticket-branch commits from local Git, preserves their accepted/unaccepted distinction, and omits ordinary untracked scratch work from history. |
| V04 | `CodebaseCommitOriginTests.v04CommitOriginAndDetailMode`, `PriorityZeroShellJourneyUITests.testV04CommitOpensItsExactTicketInEditableMode` | **Named:** the deterministic policy resolves the exact Candidate/Ticket and chooses delivery only while that Ticket belongs to an active sprint; the launched-process contract opens the released originating Ticket from its exact commit in editable detail. |
| V05 | `DemoLaunchTests.acceptedAppVersionHistory`, `.unifiedAppVersionHistory`, `.invalidAcceptedCandidates` | **Composed:** existing independent tests order verified imported and accepted runnable versions newest first and exclude incomplete, artifact, and command-output Candidate results; a new wrapper would duplicate those policy assertions. |
| V07 | `RepositoryKnowledgeCoordinatorTests.v07CheckImportedSourceRecordsRetryableAttempt`, `.publicationRecoveryOrdersDurabilityBeforeCompletion`, `RepositoryImportKnowledgeTests.importedAppLaunchReviewContract`, `.schemaMigrationAndPublication` | **Named:** the owner command first presents a connection-specific retry, then records one exact failed launch-check attempt with a bounded retry; composed decoder, independent-review, publication-recovery, and fresh-store evidence proves invalid recipes are withheld and only the approved verified version becomes available. |

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Codebase loaded | Open Codebase or choose **Refresh** | Accepted Candidate revisions in SQLite; current trunk, branch, and commit graph observed from local Git | Accepted trunk history and semantic Ticket activity without a warning for ordinary local scratch work | Refresh, select history scope, or inspect a commit | Every refresh rebuilds the projection from current SQLite and Git evidence |
| Originating Ticket open | Choose **Open T…** on an associated commit | Candidate-to-Ticket identity and current sprint membership | The exact Ticket in delivery detail only for an active sprint, otherwise editable detail | Review or edit according to the resolved mode | Reopening recomputes mode from the current durable sprint |
| Runnable versions available | Import an independently approved recipe or accept a runnable Candidate | Verified imported launch or accepted Candidate result and revision | One newest-first list containing only browser and macOS app versions | Select, open, stop, or retry a version | Fresh load rebuilds the same filtered order |
| Imported source check unavailable | Choose **Check imported source** without a Codex team connection | Existing repository and prior attempts remain unchanged | Concise connection failure and retry action | Reconnect and check again | Retry starts only after the runtime becomes available |
| Imported source check failed | Analyzer or reviewer operation fails | One failed `importedAppLaunch` run bound to the imported revision | Retryable failure; no unverified App version | Retry | A fresh coordinator reloads the failed attempt and creates at most one next attempt |
| Imported source recipe publishing | Independent review approves the exact proposal | Reviewed proposal, evidence, and publishing run in SQLite | Verification/publishing progress | Wait or interrupt | Recovery resumes the durable publishing phase before exposing the version |
| Imported source recipe available | Publication commits the reviewed launch | Completed run and verified `ImportedAppLaunch` in SQLite | Imported version in the same newest-first history | Open the version or check the source again later | Fresh store reconstructs the exact approved revision and recipe |

### 3.10 Priority 1 work packet 4 — Retrospectives

This slice closes I01, I02, I04, I05, and I08 without introducing a second
Sprint, retrospective-note, action-decision, or conclusion authority. SQLite
remains authoritative for Sprint evidence, synthesis sources, proposed actions,
their destinations, and conclusion; `AppModel` continues to compose the
existing retrospective synthesis runtime and owner commands. All five rows
remain `Shell = —`: their persistence, selection, attribution, bulk-decision,
and recovery contracts are deterministic without a launched process.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| I01 | `RetrospectiveSprintSelectionTests.activeSprintIsFallback`, `.pausedSprintIsFallback`, `.retrospectivePhasesFollowSprintLifecycle`, `SQLiteStoreTests.productOwnerRetrospectiveActionIdeaCapture` | **Composed:** when no completed Sprint is awaiting review, the presentation policies select the preferred active or paused Sprint and show it as evidence collection; the store appends Product owner and immutable Ticket/team-member notes to that same durable Sprint without exposing action decisions. |
| I02 | `SQLiteStoreTests.productOwnerRetrospectiveActionIdeaCapture` | **Composed/direct:** the Product owner adds and deletes only their own action ideas while the Sprint is active, team-member evidence cannot be deleted, neither source can be decided early, and the exact remaining attributed sources are frozen for synthesis at completion. |
| I04 | `SQLiteStoreTests.retrospectiveConclusionLifecycle` | **Composed/direct:** after synthesis resolves, the Product owner can propose trimmed actions for either Ways of working or a Backlog ticket; both remain proposed until an explicit decision, and pre-completion or post-conclusion proposals fail closed. |
| I05 | `RetrospectiveJourneyTests.i05IndividualAndBulkDecisionsResolveExactAttributedActions`, `SQLiteStoreTests.retrospectiveEvidenceLifecycle`, `.retrospectivePracticeLifecycle`, `.retrospectiveConclusionLifecycle` | **Named:** one public application journey dismisses an exact action individually, accepts every remaining action in one valid bulk across both destinations, preserves each source author/profile, creates only the accepted Backlog ticket and Ways of working change, leaves no proposal unresolved, and recovers the result in a fresh application model. |
| I08 | `RetrospectiveSprintSelectionTests.i08ConclusionReturnsToBacklogOnlyAfterDurableSuccess`, `.retrospectivePhasesFollowSprintLifecycle`, `SQLiteStoreTests.retrospectiveConclusionLifecycle` | **Named:** conclusion is refused while synthesis or any proposal is unresolved, succeeds once every action is accepted or dismissed, writes one durable idempotent conclusion, routes to Backlog only after that success, presents the concluded phase as read-only history, blocks later mutation, and remains historical after reopening SQLite. |

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Sprint evidence collecting | Add a Product owner action idea or settle a team Ticket run | Attributed retrospective note tied to its Sprint, Ticket, and profile where applicable | Current Sprint outcomes and improvement evidence without premature decisions | Add or remove an owner idea; continue delivery | Fresh load reconstructs all immutable team evidence and remaining owner ideas |
| Completed Sprint selected | Open Retrospectives after Sprint completion | Completed Sprint, Ticket outcomes, notes, and synthesis source identities in SQLite | Latest completed Sprint with outcomes, ideas, and synthesis status | Select another Sprint, wait, retry, or continue without AI | Selection recomputes from durable Sprint state; source identities remain fixed |
| Action proposed | Complete synthesis or add an owner proposal | Proposed note, destination, expected effect, source attribution, and optional synthesis provenance | Reviewable action for Ways of working or the Backlog | Accept, dismiss, or add another proposal | Fresh load returns every unresolved proposal to review |
| Actions decided | Accept or dismiss individually or in a valid bulk | Decision status; accepted Backlog Ticket link or verified Ways of working revision | Resolved actions with original attribution and destination outcome | Review remaining actions or conclude | Partial interruption remains visible as unresolved proposals; retry decides only those still proposed |
| Retrospective concluded | Conclude after all proposals are resolved | One conclusion timestamp and activity event on the completed Sprint | Historical concluded retrospective | Inspect history | Fresh SQLite and application instances preserve the exact conclusion and prohibit later mutation |

### 3.11 Priority 1 work packet 4 — Product settings, Team settings, and Codex

This slice closes S01, S03, S05, and S06 without introducing a second Product,
team-member, repository, or Codex runtime authority. Product names, archives,
team members, and repository history remain durable in the Product store;
Codex installation choices remain explicit local preferences. `AppModel`
composes those commands and bounded presentation policies. All four rows remain
`Shell = —`: command, persistence, presentation, and fresh-instance behavior
are deterministic without launched-process wiring.

S08 remains blocked on a product decision, not a missing test. No editable
definition-of-ready or definition-of-done profile exists in `Sources`, and
implementing that shared authority would be a separate product feature rather
than journey-test coverage. The inventory contract remains unchanged until the
Product owner accepts that feature packet.

| Row | Executable evidence | Coverage |
| --- | --- | --- |
| S01 | `SettingsJourneyTests.s01ProductRenameSaveAndCancel`, `SQLiteStoreTests.durableWorkflow` | **Named:** cancellation resolves without a mutation command; Save trims and persists the Product name before dismissing, updates the bounded Product collection used by navigation and notification presentation, and a fresh registry recovers the same name. |
| S03 | `SettingsJourneyTests.s03DestructiveSettingsPreserveLocalHistory`, `RemoteRepositoryAppModelTests.r12ObservedTargetChoice`, `SQLiteStoreTests.productArchiveAndRestorePreserveHistory` | **Named:** every Product archive, GitHub setup cancellation, disconnect, and account sign-out command passes through an explicit confirmation policy; rejection yields no command. Archival preserves the exact Git revision, Ticket, and work log, while the existing remote command proof disconnects without changing the selected repository or local history. |
| S05 | `SettingsJourneyTests.s05CustomTeamMemberRuntimeAndRemoval`, `SQLiteStoreTests.customPersonas` | **Named:** blank and templated creation share one model/effort compatibility policy that retains supported effort and falls back to the selected model default; the resulting governed custom member persists, built-in removal fails closed, and only the custom member can be archived. |
| S06 | `SettingsJourneyTests.s06CodexInstallationLifecycle`, `CodexInstallationTests.discovery`, `.preferencesRoundTrip`, `CodexConnectionPresentationTests.retryAvailability` | **Named:** discovery orders and deduplicates official, included, and custom installations; AppModel explicitly selects and removes a persisted custom installation, the shared gate rejects changes during active work or shutdown, and retry re-checks an incompatible runtime while preserving an actionable failure state. |
| S08 | — | **Blocked on product:** the specified editable definition-of-ready and definition-of-done profile and its single readiness authority do not exist. A deterministic journey cannot be written until the Product owner accepts that feature as a separate work packet. |

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Product name editing | Open Product settings | Existing Product name in SQLite; draft text is presentation state | Editable name with Save and Cancel | Save or cancel | Cancel discards the draft; Save waits for the durable update and leaves the sheet open on failure |
| Destructive setting requested | Choose archive, disconnect, cancel setup, or sign out | No mutation before confirmation | Exact destructive consequence and preservation promise | Confirm or cancel | Cancel emits no command; confirmed operations retain local repositories and audit history |
| Custom team member editing | Start blank or choose a template | Existing team remains authoritative until creation | Governed capability, compatible model and effort, and optional instructions | Add or cancel | Unsupported effort resolves to the selected model default; only a persisted non-built-in member can later be removed |
| Codex installation selected | Choose an official, included, or custom installation | Custom catalog and selected identifier in local preferences | Selected runtime and connected, incompatible, or unavailable state | Add, select, remove, or retry when no work is active | Retry re-resolves the selected executable; removing it selects the next discovered runtime or none |
| Readiness profile unavailable | Open the specified S08 journey | No profile authority exists | No implemented editor | Accept a separate product feature packet | Remains an explicit specification gap rather than false executable coverage |

## 4. Test taxonomy

| Code | Proof type | Contract |
| --- | --- | --- |
| **J** | Coordinator journey | Drive public feature commands. Use real temporary SQLite and local Git where applicable, bounded fakes at external boundaries, explicit operation events, and fresh-instance recovery. Assert snapshot and durable evidence. |
| **P** | Presentation scenario/policy | Render or resolve a bounded presentation state. Cover normal, empty, busy, interrupted, failed, retryable, stale, actionable, and completed states. |
| **M** | Controlled external smoke | Run manually or in a dedicated controlled macOS/GitHub environment. Keep outside the deterministic pull-request suite. |

The inventory carries a separate **Shell** column because proof type and
application-shell wiring are different questions. `AGENTS.md` is the binding
rule for when a launched-process contract may be added; this plan records each
row's `Shell = Y` or `Shell = —` designation and the resulting inventory.

Full-app UI contracts launch an isolated debug composition and exercise actual owner controls, asserting stable accessibility identifiers, window and sheet routing, and visible state. They must not use display strings as the only selector.

Priority meanings:

- **P0:** authority, destructive behavior, cross-product routing, acceptance, permissions, exact-candidate safety, or a known defect path.
- **P1:** primary product workflow and recovery.
- **P2:** secondary navigation, filtering, display preference, or low-risk convenience behavior.

## 5. Comprehensive owner journey inventory — 124

Two rules apply to every row before it is scheduled.

**Record existing evidence first.** The repository already contains 464 automated tests, and many rows are partly covered by them. Before implementing a row, list the existing tests that already prove part of it in the header comment of the new journey test, and implement only the uncovered composition. A row is not an instruction to rewrite passing component tests.

**Keep the row ID in every new journey test name.** New journey tests use their row (`A02_…`, `D17_…`) so the inventory, suite, and defect reports share one identifier. A genuinely sufficient pre-existing test is not renamed or called **Named** retroactively; mark the row **Composed** and explain why another wrapper would duplicate proof. Coordinator journeys live beside the feature they exercise in `Tests/SpeditoAppTests` or `Tests/SpeditoCoreTests`; only launched-process contracts live in the separate UI target.

### 5.1 Application shell and Product lifecycle — 12

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| A01 | P1 | Launch with no Products and reach onboarding; canceling creation leaves the empty state usable. | J | — |
| A02 | P0 | Create a blank Product; its directory, Git repository, database, starter team, selection, and Backlog destination become durable. | J | Y |
| A03 | P1 | Open Products, search, select another active Product, and restore that Product's last valid workspace destination. | J | — |
| A04 | P0 | Switch Products while background work is active; work continues only for its owning Product and the sidebar exposes bounded activity/attention. | J | — |
| A05 | P0 | Quit and relaunch; the last valid selected Product, destination, and selected sprint return without leaking state from another Product. | J | Y |
| A06 | P0 | Archive a Product through its destructive confirmation; active work is safely suspended, data remains durable, and navigation selects another valid Product or the empty state. | J | Y |
| A07 | P1 | Show archived Products and restore one; its backlog, work logs, knowledge, repository provenance, and delivery history remain available. | J | Y |
| A08 | P2 | Use the Go menu and keyboard shortcuts for Backlog, Sprint board, App versions, Retrospectives, Reports, Product knowledge, Codebase, Chat, and settings. | P | — |
| A09 | P0 | Open a Product database written by an earlier Spedito version; every schema migration applies in place and backlog, work logs, knowledge, repository provenance, and delivery history remain readable and unchanged in meaning. | J | — |
| A10 | P0 | Quit while work is active; stop admitting queued work, checkpoint each active run, honor the bounded grace period and its **Quit now** action, release scheduler leases, and preserve threads and workspaces for resume rather than cancellation. | J | — |
| A11 | P0 | Recover after force quit, crash, or power loss; reconcile stale leases, processes, and worktrees, record the labelled system recovery note from the last durable milestone, and explain the fallback when a ticket workspace is missing. | J | — |
| A12 | P1 | Present a background failure in its owning feature; a failure raised while another destination is visible neither replaces valid presentation there nor disappears without an owner-visible retry path. | J+P | — |

S08 describes a specification contract whose implementation must be confirmed before it is scheduled: its definition-of-ready and definition-of-done profile. No definition-of-ready symbol exists in `Sources`; while that contract remains unimplemented, the row records a specification gap for the product owner rather than a missing test.

### 5.2 Repository import, GitHub connection, and synchronization — 14

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| R01 | P0 | Import a canonical public repository URL; activate full history and exact provenance, open the Product, then continue repository understanding in the background. | J | — |
| R02 | P1 | Reject unsupported or credential-bearing repository input, including embedded credentials, query/fragment data, non-default ports, and unsupported hosts, without creating partial Product state. | J | — |
| R03 | P1 | Authorize GitHub with Device Flow and list accessible public/private repositories without persisting a credential in source URLs or Git configuration. | J+M | — |
| R04 | P1 | Open GitHub App repository-access settings, return to Spedito, automatically refresh the repository list, and retain a manual refresh for propagation delay. | J+M | — |
| R05 | P0 | Select an empty GitHub repository; create a blank local Product, prove eligibility, initialize the exact remote default branch, and finish setup. | J | Y |
| R06 | P0 | Select a repository with history; import the exact accepted default-branch head rather than initializing or rewriting it. | J | — |
| R07 | P0 | Cancel, interrupt, or relaunch during import; no half-activated Product leaks into normal navigation and the durable operation recovers or fails with a retryable explanation. | J | — |
| R08 | P0 | Analyze the imported exact revision, independently review proposals, publish only approved knowledge, and treat a completed no-pages result as terminal across relaunch. | J+P | — |
| R09 | P0 | Retry failed/interrupted/stale repository understanding as one new versioned attempt without overwriting an accepted newer revision. | J+P | — |
| R10 | P0 | Connect a mature local Product to an eligible empty GitHub repository; publish captured history through the dedicated pull request and reconcile the unchanged merged head. | J | — |
| R11 | P1 | Connect an imported Product only to its preserved GitHub repository; handle missing installation access without offering an unrelated target. | J | — |
| R12 | P0 | Detect changed repository identity/default branch, then require the owner to use the observed target or disconnect; never silently retarget. | J | — |
| R13 | P0 | With no active sprint, prepare incoming fast-forward changes for exact review; accept or reject them atomically and recover safely after interruption. | J | Y |
| R14 | P0 | While a sprint is active, defer incoming history to ticket integration; disconnecting or signing out affects the intended Product/account set and remains correct after relaunch. | J | — |

### 5.3 Epics, clarification, and ticket suggestions — 15

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| E01 | P0 | Create an Epic from an owner outcome; persist only submitted scope initially and begin Business Analyst clarification without inventing durable metadata. | J | — |
| E02 | P0 | Close the Epic, switch Products, release a scripted clarification response, see the cross-Product notification, choose Open epic, return to the owning Product, and see the exact pending questions. | J | Y |
| E03 | P0 | Answer one or several clarification rounds using listed choices and Other; only Submit answers advances governed refinement and every answer remains attributed and durable. | J | — |
| E04 | P1 | Send ordinary Epic chat while structured questions remain pending; chat stays chronological and never becomes an authoritative clarification answer. | J | — |
| E05 | P0 | Complete Epic planning in the background, show a plan-ready notification, open the exact Epic, and render the persisted metadata and proposed ticket plan. | J | — |
| E06 | P0 | Relaunch with pending Epic questions; restore them, and replace an expired Codex thread using the preserved transcript without asking the owner to re-enter answers. | J | — |
| E07 | P1 | Stop, interrupt, or fail Epic clarification/planning; preserve the transcript and expose one contextual retry/continue action rather than looping silently. | J+P | — |
| E08 | P1 | Reject an invalid structured plan, attempt the bounded repair once, and retain a reviewable terminal failure if repair is still invalid. | J+P | — |
| E09 | P1 | Review one suggested ticket: inspect rationale/dependencies, edit or discuss it, then accept or reject it without changing unrelated proposals. | J | — |
| E10 | P1 | Accept all remaining Epic proposals or dismiss all with explicit scope and confirmation; neither action starts or scopes a sprint. | J | — |
| E11 | P0 | Accept a suggestion whose proposed prerequisites are unresolved; preview and atomically accept its full transitive prerequisite set with dependency edges. | J | — |
| E12 | P0 | Reject a prerequisite with dependants; preview and atomically reject or archive the permitted cascade, while delivered work blocks an unsafe cascade. | J | — |
| E13 | P1 | Finish one suggestion batch, run Suggest missing tickets, and keep multiple outstanding batches queued and independently reviewable. | J+P | — |
| E14 | P0 | Archive an Epic; archive unfinished backlog tickets and proposals while preserving delivered tickets and historical links. | J | — |
| E15 | P2 | Reorder Epics by drag or top/bottom actions, and preserve each Product's completed-Epic disclosure preference. | J | — |

### 5.4 Backlog and editable Ticket workflow — 11

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| B01 | P1 | Create a Ticket manually, optionally attach it to an Epic, and start initial refinement only when the saved contract is incomplete. | J | — |
| B02 | P0 | Close an incomplete Ticket, switch Products, receive Business Analyst questions, open the notification, and return to the exact editable Ticket. | J | Y |
| B03 | P0 | Answer Ticket refinement questions across rounds and relaunch; answered cards, pending cards, comments, and refinement state remain in the correct chronology. | J | — |
| B04 | P1 | Review completed refinement, apply one field/dependency or all remaining suggestions, dismiss others, then explicitly save the resulting Ticket source of truth. | J | — |
| B05 | P0 | Change a Ticket while a refinement/chat proposal is in flight; stale results expose a conflict and never overwrite the newer owner draft or saved version. | J | — |
| B06 | P1 | Ask a team member to review a Ticket; prose alone changes nothing, while explicitly accepted proposal fields remain unsaved until Save. | J | — |
| B07 | P1 | Edit title, context, type, priority, assignee, acceptance criteria, custom fields, and blockers; invalid/duplicate fields prevent save without losing the draft. | J | — |
| B08 | P1 | Open Epic and dependency/dependant links from Ticket details, then return with unsaved Ticket edits intact. | P | — |
| B09 | P0 | Multi-select and move Tickets between Backlog and Next sprint by row drag or section action; valid dependency branches persist atomically and invalid partial scope explains the missing relationship. | J | — |
| B10 | P1 | Reorder backlog rank by drag and top/bottom actions; show stable valid/invalid drop positions and never violate dependency order. | J | — |
| B11 | P1 | Archive a Ticket through confirmation; remove it from active planning, dependency choices, and suggestions while preserving historical work. | J | — |

### 5.5 Sprint planning — 7

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| P01 | P1 | Open Sprint planning with every Next sprint Ticket in scope and no second hidden inclusion/exclusion mechanism. | J | — |
| P02 | P1 | Walk Ticket by Ticket, edit the draft, choose an assignee, ask one team member, and selectively apply a version-safe proposal. | J | — |
| P03 | P0 | Save a partial plan to the draft board, or close with Discard changes and restore the last saved draft without leaking picker state into Backlog. | J | — |
| P04 | P1 | Review dependency order, forecast, remaining usage, and owner acceptance load in the planning summary before saving. | P | — |
| P05 | P0 | Block Start sprint for unassigned work, missing estimates, readiness failures, invalid dependencies, or another active/paused sprint, with the exact owner-facing reason. | J | Y |
| P06 | P1 | Save a plan and lazily generate one bounded goal; starting does not wait, stale generation cannot overwrite changed scope, and failure leaves delivery usable. | J+P | — |
| P07 | P1 | Relaunch a saved draft plan and restore the valid selected planning/board context without resurrecting unsaved changes. | J | — |

### 5.6 Sprint delivery, review, demo, and acceptance — 23

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| D01 | P0 | Start a valid sprint, freeze its initial plan, and admit only dependency-eligible Tickets rather than launching every Ticket blindly. | J | — |
| D02 | P0 | Run independent Tickets in parallel; keep direct dependants waiting until prerequisites are Done, then admit the next wave exactly once. | J+P | — |
| D03 | P0 | Switch Products during active delivery; execution continues in isolation and owner attention routes back to the correct Product/Ticket. | J | — |
| D04 | P0 | Pause a sprint, interrupt active turns, preserve workspaces/logs/candidates/queues, relaunch while paused, and resume rather than restart work. | J | — |
| D05 | P0 | Stop a sprint through destructive confirmation; keep Done work accepted, supersede unaccepted candidates, return unfinished Tickets to Ready, and preserve audit history. | J | — |
| D06 | P1 | Open a delivery Ticket and observe trusted status/work-log changes, latest-action focus, relationships, run context, candidates, and evidence without raw reasoning. | J | — |
| D07 | P1 | Add an informational owner comment or explicitly ask the active/fallback team member; the read-only question receives a reply without changing delivery or a pending permission. | J | — |
| D08 | P0 | Review a permission request and choose Deny, Allow once, or Always allow; persist before delivery, recover across relaunch, and apply saved access only to equivalent/narrower requests. | J | Y |
| D09 | P0 | Answer an owner question with a listed choice or Other and choose Submit answers; record the attributed answer and resume the exact paused run. | J | Y |
| D10 | P0 | Recover a failed/interrupted implementation by adding direction and choosing Retry work; reuse the durable workspace/thread contract without duplicating a completed transition. | J | — |
| D11 | P0 | Complete implementation, persist an immutable candidate and handoff, integrate against current trunk, and bind independent review to the exact candidate/revision. | J+P | — |
| D12 | P0 | Resolve a merge conflict in the preserved integrator run; continue automatically for safe resolution, ask for material owner input, and require focused re-review when the result changed. | J | — |
| D13 | P0 | Ingest GitHub review comments with bounded context; requested changes return the Ticket to In progress and update the same publication branch. | J | — |
| D14 | P0 | Launch, reopen, stop, or retry the exact reviewed demo; a host preparation failure retries preparation only, while a candidate failure requires a new candidate. | J | Y |
| D15 | P0 | While Ready for demo, send a question/comment without invalidating the candidate, or choose Request changes to begin an explicit revision loop from the reviewed baseline. | J | Y |
| D16 | P0 | Review ticket knowledge changes; when owner approval is enabled, accept/reject each before completion, and never publish rejected/unreviewed content as truth. | J | — |
| D17 | P0 | Approve a repository-changing Ticket; close the detail immediately, show Completing, recheck exact GitHub heads, merge/reconcile/publish serially, and mark Done only after success. | J | Y |
| D18 | P0 | Fail or interrupt acceptance after acknowledgement; retain the reviewed result, log a recoverable failure, and retry exactly once without optimistic completion or duplicate promotion. | J | — |
| D19 | P0 | Approve a repository-free research outcome; publish handoff/knowledge without Git, pull request, empty commit, managed demo, or Codebase change. | J | — |
| D20 | P1 | Approve research follow-up proposals only after Tech Lead review; publish them as reviewable backlog suggestions with Epic/prerequisite provenance, and publish none when active scope already covers them. | J | — |
| D21 | P1 | Accept the final outstanding Ticket; the sprint completes durably in the same transition, the board and Team sidebar present a completed sprint, Retrospectives and Reports admit it, and a new sprint becomes startable. | J | — |
| D22 | P1 | Reach an account rate limit or safety back-pressure during delivery; admitted runs wait instead of failing, the constrained-execution reason is owner-visible, and work resumes when the window resets without duplicating a turn. | J+P | — |
| D23 | P2 | Render sprint board lanes, per-ticket activity (working, waiting, blocked, reviewing, awaiting owner), run telemetry, and compaction and context-health summaries from one coherent durable snapshot. | P | — |

### 5.7 Chat and owner notifications — 11

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| C01 | P1 | Start a Product Chat thread to exactly one selected team member; persist its generated subject, bounded context, owner message, and attributed reply. | J | — |
| C02 | P0 | Start several independent threads and allow replies to complete out of order; each result, unread state, and notification remains attached to its own thread. | J | — |
| C03 | P1 | Reply to the same member using the existing session, or select a different member and start a role-specific session with the visible transcript and current Product evidence. | J | — |
| C04 | P1 | Stop or time out an inactive response; retain a durable authored failure and allow a bounded retry without an unending spinner. | J+P | — |
| C05 | P1 | Archive, show archived, and restore a completed Chat thread without losing messages or Codex context. | J | — |
| C06 | P1 | Use Ticket/Epic conversation defaults and recipient selection; route each message to one profile and persist replies in the owning work log/timeline. | J | — |
| C07 | P0 | Receive a new reply for another Product, choose its notification action, switch Product, open Chat, and focus the exact thread with its unread state cleared. | J | Y |
| C08 | P1 | While the app is active, present the in-app banner; while inactive, post the macOS notification; play sound only for owner-action attention. | J+P+M | — |
| C09 | P0 | Suppress a banner for an already visible target, mark an opened target read, resolve completed attention, and keep cross-Product counts deduplicated. | J+P | — |
| C10 | P0 | Route Ticket, Epic, and conversation notifications; if the target was archived/deleted or the route is malformed, fail closed and resolve stale attention without navigating elsewhere. | J | — |
| C11 | P1 | Decline or leave undetermined the macOS notification authorization; in-app attention remains the only channel, the sound policy still applies, no attention is lost, and the request is not retried on every launch. | J+P+M | — |

### 5.8 Product knowledge — 6

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| K01 | P1 | Open Product knowledge, select a changed page, clear only that Product/page's unread count, and retain read state across relaunch. | J | — |
| K02 | P2 | Search pages and navigate tree branches, breadcrumbs, children, and backlinks without losing the selected valid page. | P | — |
| K03 | P1 | Create a page beneath the current section, edit/cancel/save it, and append durable version history with the canonical result. | J | — |
| K04 | P0 | Prevent owner edits while repository knowledge publication is running, and recover cleanly from publication failure without two authorities. | J+P | — |
| K05 | P1 | Ask a question, render a grounded answer or Unknown result, list only cited verified pages, and navigate from a citation to the exact page. | J | Y |
| K06 | P1 | Open accepted Ticket knowledge from the work log and focus the published canonical page; rejected/historical proposals remain audit history, not current truth. | J | — |

### 5.9 Codebase and App versions — 7

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| V01 | P1 | Open Codebase and load accepted trunk history; refresh after accepted changes without presenting ordinary unpublished local work as a warning. | J | — |
| V02 | P2 | Switch history among trunk, one Ticket's logical stream, and All activity; inspect the selected branch/commit with semantic delivery labels. | P | — |
| V03 | P2 | Select changed files, render unified/side-by-side diffs, and persist a valid display preference while falling back safely for narrow content. | P | — |
| V04 | P1 | Open the originating Ticket from a commit and render delivery history in the correct editable/delivery detail mode. | J | Y |
| V05 | P1 | List independently verified imported and accepted runnable versions newest first; omit artifacts and command-output results. | J+P | — |
| V06 | P0 | Open, revisit, switch, stop, and retry exact App versions; opening another version stops the active one and reconstructs the selected revision. | J | Y |
| V07 | P1 | When import has no approved launch recipe, run Check imported source, handle invalid/failure/retry, require independent approval, and add only the verified version. | J | — |

### 5.10 Retrospectives and Reports — 10

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| I01 | P1 | During an active sprint, open Retrospectives, select the preferred sprint, and show accumulating immutable evidence without premature decisions. | J | — |
| I02 | P1 | Add and delete the Product owner's action idea while the sprint is active; keep team-member evidence immutable and do not apply the idea early. | J | — |
| I03 | P0 | Complete the sprint and prepare one durable synthesis; recover interruption, retry failure, or explicitly continue without AI suggestions without rewriting source notes. | J | — |
| I04 | P1 | Add an owner proposal after sprint completion and choose Ways of working or Backlog ticket as its explicit destination. | J | — |
| I05 | P1 | Review proposed actions individually or in valid bulk; accept/dismiss decisions remain attributed and no unresolved action is silently skipped. | J | — |
| I06 | P0 | Accept a Ways of working action and update the inherited verified page exactly once with source provenance. | J | — |
| I07 | P0 | Accept a Backlog ticket action, create the Ticket, and immediately open its normal Business Analyst refinement flow. | J | Y |
| I08 | P1 | Block conclusion until synthesis is resolved and every proposal decided; conclude, return to Backlog, and retain read-only accepted/dismissed history. | J | — |
| I09 | P2 | Open Reports with no evidence, active work, and completed sprints; select the intended sprint range without treating incomplete work as accepted output. | P | — |
| I10 | P2 | Switch report chart/metric views and verify forecast, duration, outcome, rework, blocker, and improvement presentations from the same durable sprint evidence. | P | — |

### 5.11 Product settings, Team settings, and Codex — 8

| ID | Priority | Owner journey contract | Proof | Shell |
| --- | --- | --- | --- | --- |
| S01 | P1 | Rename a Product and Save, or Cancel without mutation; reflect the durable name consistently in navigation and notifications. | J | — |
| S02 | P0 | Revoke one saved access group or revoke all through confirmation; preserve audit history and require approval for future matching requests. | J | — |
| S03 | P1 | Manage GitHub connection, Product archive, and other destructive settings through explicit confirmations without changing repositories or history unintentionally. | J | — |
| S04 | P0 | Edit shared guidance and each member's model, effort, and instructions; save atomically, keep the sheet open with an error on failure, and never expose a partial team. | J | — |
| S05 | P1 | Add a custom team member from blank or a template, validate model/effort compatibility, then remove only a non-built-in member. | J | — |
| S06 | P1 | Discover official/included Codex, explicitly add/select/remove a custom installation, block changes during active work, and retry incompatible/unavailable connection. | J | — |
| S07 | P2 | Display live Codex usage windows, reset timing, limit-reached state, refresh transitions, and accessible summaries without conflating separate windows. | P | — |
| S08 | P1 | Edit the definition-of-ready and definition-of-done profile; the saved profile governs readiness warnings in Backlog, Sprint planning, and Start sprint from one authority rather than a second hidden policy source. | J | — |

## 6. The proving Epic notification tests

The reported defect deserves three deterministic tests and one full-app UI contract, not one oversized test.

### 6.1 Coordinator journey: clarification needs input across Products

1. Create Products A and B in isolated temporary workspaces.
2. Create an Epic in Product A and start clarification with a scripted Codex transport held behind an explicit operation gate.
3. Close the Epic and select Product B.
4. Release a structured clarification reply containing known questions and choices.
5. Assert Product A's SQLite store contains the Epic conversation and active `needsInput` notification; Product B contains neither.
6. Invoke the notification's public Open action.
7. Assert Product A is selected and the navigation request targets the exact Epic.
8. Construct a fresh model/store instance and assert the questions and unread/resolved state recover identically.

### 6.2 Coordinator journey: plan ready across Products

Repeat the setup with a ready-to-plan reply, release the plan result after switching to Product B, and assert that the exact Epic metadata, suggestion batch, `refinementComplete` notification, and navigation target are durable. Verify that opening does not accept any proposed Ticket.

### 6.3 Coordinator journey: interruption and expired-thread recovery

Interrupt after questions or answers are persisted, close the first instance, construct a fresh instance over the same Product workspace, and continue through a replacement read-only thread. Assert that no answer is duplicated and no previously resolved question is asked again.

### 6.4 Full-app UI contract

Launch the isolated debug app with the scripted scenario, use stable identifiers to create/open the Epic and switch Products, release the response from the test controller, choose **Open epic**, and assert:

- Product A's row is selected;
- Backlog is the active destination;
- the Epic detail surface exists;
- the expected Business Analyst message exists;
- every expected question card and choice exists; and
- selecting/typing an answer enables **Submit answers** without treating ordinary Chat as the answer.

This is the smallest test that proves the current cross-layer wiring in `AppModel`, `OwnerNotificationCoordinator`, `ContentView`, `BacklogView`, and `EpicDetailView`.

Before packet 8, the banner in `ContentView` dismissed itself after a fixed eight-second `Task.sleep`, which gave this test a hidden wall-clock deadline between releasing the scripted response and choosing **Open epic**. The implemented `OwnerNotificationBanner` takes that interval from the presentation environment, and the debug fixture disables automatic dismissal. A test that merely ran faster than the timer would still violate the timing dependency rule in section 8.4.

## 7. Full-app UI runner design

### 7.1 Runner

Add a small macOS XCUITest project/scheme around the existing package sources. Keep the Swift package and `scripts/build_app.sh` as the normal developer/release build. The UI runner is a test-only host, not a second product architecture.

A UI target is needed because `swift test` alone has no target-application configuration for `XCUIApplication`. The runner must be maintained as a separate, serialized test job.

Prefer a project that contains **only a UI test bundle**, with no second application target. `scripts/build_app.sh debug` already assembles `.build/app/debug/Spedito.app` from the package binary, `Distribution/Info.plist`, and the packaged resources, and it accepts `SPEDITO_BUNDLE_IDENTIFIER`, `SPEDITO_GITHUB_CLIENT_ID`, and `SPEDITO_GITHUB_APP_SLUG`. The test bundle launches that exact artifact through `XCUIApplication(url:)`. This keeps one build authority; duplicating the app as an Xcode target would fork the Info.plist, resource copying, signing, and GitHub configuration and let the tested binary drift from the released one.

Build the UI-test bundle with a distinct bundle identifier, for example `io.spedito.app.uitest`. That guarantees the launched process can never read, write, or destroy the product owner's real defaults domain or an installed release build's state.

Prove the runner before committing to it. macOS XCUITest needs a real GUI login session, a signed bundle, and automation permission for the test runner, and CI currently runs `swift test` only. Spike one trivial launch-and-assert test end to end in the target CI environment as the first task of work packet 2. If it cannot be made reliable there, the fallback is explicit and acceptable: keep the launched-process contracts as a product-owner-run local suite, mark the 19 `Shell = Y` rows as owner-verified, and do not weaken their deterministic coordinator proofs to compensate.

**Runner decision — 15 August 2026:** proceed to work packet 2. The
test-only `SpeditoUITests.xcodeproj` built the ad-hoc-signed debug bundle with a
distinct application and runner bundle identifier, launched it through
`XCUIApplication(url:)`, and passed in the repository's pinned macOS 26 /
Xcode 26.6 GitHub Actions environment. The serialized spike completed in
1 minute 41 seconds in
[CI run 31887927106](https://github.com/cristianrgreco/Spedito/actions/runs/31887927106).
No second application target was introduced.

### 7.2 Debug-only composition

Add an explicit debug-only launch configuration, selected by launch arguments/environment:

- isolated Product workspaces root;
- isolated UserDefaults suite;
- scenario identifier;
- scripted Codex transport endpoint;
- scripted GitHub transport endpoint;
- deterministic notification/sound adapters;
- disabled or injected owner-notification banner dismissal interval; and
- a control endpoint for releasing bounded asynchronous responses.

Two of those are cheaper than they look, and one is more expensive.

- **Workspaces root:** `AppModel.migratedApplicationSupportURL(in:)` already accepts a root; only the private `applicationSupportURL()` hardcodes `FileManager.default.urls(...)`. One debug-only environment override there covers every product workspace, import staging directory, and legacy database path.
- **Defaults:** a distinct UI-test bundle identifier gives the launched process its own `UserDefaults.standard` domain, so the roughly twelve hardcoded `.standard` call sites in `AppModel` and `ContentView` do not need to be threaded first.
- **Codex:** this is the real work. `AppModel.codexClient` is a private concrete `CodexAppServerClient` built inside the connect path at `AppModel.swift:11679`, and no application-layer test can substitute it today. `CodexAppServerClient(transport:)` is the seam, so the composition needs an injectable transport factory on `AppModel`. That seam is a precondition for the launched-process suite *and* for every coordinator journey in section 5, so it belongs to work packet 1 rather than here.

Use the same production coordinators, stores, Git services, presentation models, and views. Fake only external boundaries. Never seed a notification as a substitute for testing the operation that is supposed to publish it when the contract under test is completion-to-notification.

The UI test process can host a localhost or Unix-domain-socket fixture controller and pass its endpoint at launch. The app blocks scripted external responses on explicit gates; the test releases a named gate and waits for an accessibility predicate. This avoids arbitrary sleep and cross-process polling.

Compile fixture composition only for debug/testing. It must not appear as fake owner functionality in release builds.

### 7.3 Accessibility contracts

Identifiers should describe stable roles and domain identity, not layout or localized display text. Add them only as journeys require them.

Initial contract for the proving test:

```text
nav.products
product.row.<product-id>
nav.backlog
epic.row.<epic-id>
epic.detail.<epic-id>
epic.refine
owner-notification.banner
owner-notification.open
owner-notification.dismiss
epic.question.<question-index>
epic.question.<question-index>.choice.<choice-index>
epic.question.<question-index>.other
epic.submit-answers
```

Prefer durable UUID-backed identifiers for rows and details. Use stable semantic identifiers for singleton controls. Labels remain important for accessibility, but UI tests should not depend only on owner-facing copy.

### 7.4 Initial full-app smoke suite

The initial inventory has 14 high-value shell-wiring scenarios covering the 19
rows designated `Shell = Y`. `AGENTS.md` owns the binding rule for adding a
launched-process contract; this section records implementation status:

1. blank Product creation and selection — A02;
2. Product switch and relaunch restoration — A05;
3. Epic clarification notification and return navigation — E02;
4. Ticket refinement notification and return navigation — B02;
5. Backlog-to-planning-to-start gating — P05;
6. permission decision and owner-question resume — D08, D09;
7. demo, comment, request changes, and approval controls — D14, D15, D17;
8. Product Chat background reply notification — C07;
9. knowledge answer citation navigation — K05;
10. GitHub setup and incoming review using the scripted transport — R05, R13;
11. retrospective action-to-backlog refinement — I07;
12. App version open/switch/stop — V06;
13. Product archive and restore — A06, A07;
14. Codebase commit-to-Ticket navigation — V04.

**Implementation status — 17 August 2026:** the target contains 17 tests: one
bundle-launch smoke test, the E02 contract in `EpicOwnerNotificationUITests`,
and 15 contracts in `PriorityZeroShellJourneyUITests`. They cover all 16
Priority 0 `Shell = Y` rows: A02, A05, A06, B02, C07, D08, D09, D14, D15,
D17, E02, I07, P05, R05, R13, and V06.

- Fully implemented scenarios: 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, and 12.
- Partially implemented scenario: 13 covers A06 but not the Priority 1 A07
  contract.
- Not implemented: 9 (Priority 1 K05) and 14 (Priority 1 V04).

The debug-only composition uses an isolated application-support root and
defaults domain, deterministic Codex and GitHub boundaries, no-op
sound/system-notification adapters, and a file-system response gate. Release
compilation excludes fixture types. The independent close-out audit at
`0f844d9` ran the prior 15 tests successfully in 182 seconds. The added D17
and I07 contracts pass independently in 18 and 12 test seconds, respectively,
so CI's serialized 10-minute timeout retains substantial headroom for all 17.

Reports, passive labels, every error string, every lane, every diff mode, and every state-machine branch do not need separate XCUITest coverage. Their policy/presentation tests remain faster and more diagnostic.

### 7.5 External smoke boundary

Do not put real GitHub authorization, real Notification Center timing, or general desktop visual assertions in the deterministic suite.

Maintain controlled smoke scripts for:

- real GitHub Device Flow and installation access;
- one real macOS Notification Center delivery/open route;
- app bundle launch/relaunch; and
- product-owner inspection in representative light/dark and laptop-sized layouts.

Repository rules prohibit agents from driving or inspecting the product owner's Mac. These checks must run in controlled CI infrastructure or be performed by the product owner using an explicit inspection script.

## 8. Implementation sequence

These are the journey program's own packets. The Priority 0 foundation packets are complete; Priority 1 and Priority 2 remain planned in that order.

### Gate 0 — Accepted baseline

The product owner accepted the known-good baseline without rewriting history.
The architecture ownership ledger and concentration ratchets were reconciled,
the known cross-Product Epic defect received executable coverage, and the
required harness and feature extractions landed before the remaining journey
matrix.

### Work packet 1 — Exact Epic coordinator journeys (completed)

1. Add the Codex transport seam. Reuse the existing temporary Product registry and store fixtures, but note that the scripted `CodexRPCTransport` fakes exist only in `Tests/SpeditoCoreTests/CodexAdapterTests.swift` and that `AppModel.codexClient` is private and concrete (`AppModel.swift:816`, constructed at `:11679`). Give `AppModel` an injectable transport factory so an application-layer test can drive a scripted Codex turn, and extend the existing test initializers to accept it. Nothing else in this plan can start until this exists.
2. Add explicit operation gates/events only where the Epic planning public surface lacks them.
3. Implement the three coordinator journeys in section 6.
4. Assert both presentation state and SQLite records.
5. Include fresh-instance recovery and stale-result protection.

Acceptance: the known cross-Product Epic issue is reproducible before a fix and protected after a fix without launching a UI runner.

The Codex seam is shared infrastructure for all 124 rows, not Epic-specific work.

### Work packet 2 — Full-app UI runner and proving contract (completed)

1. Spike one trivial launch-and-assert test against the `scripts/build_app.sh debug` bundle in the target CI environment, and stop here if it cannot be made reliable.
2. Add the minimal Xcode UI-test bundle and serialized scheme, with no second application target.
3. Add debug-only dependency composition and cross-process fixture control, including the injectable banner dismissal interval.
4. Add only the accessibility identifiers needed by the Epic test.
5. Implement the exact UI contract in section 6.4.
6. Run UI tests in an isolated temporary root under a distinct bundle identifier and leave normal app data untouched.

Acceptance: one launched-process test proves operation completion, banner presentation, Product switching, Epic navigation, and restored question controls without sleeps.

### Work packet 3 — P0 authority and recovery matrix (completed)

Implement P0 journeys feature by feature, in this order:

1. durable schema migration on upgrade (A09), because every other durable proof assumes an owner's existing database survives the next release;
2. notifications and cross-Product routing;
3. permissions and owner questions;
4. pause, stop, graceful quit, crash recovery, and relaunch (D04, D05, A10, A11);
5. immutable candidate, integration, review, and demo;
6. repository-changing and repository-free acceptance;
7. Product archive/restore;
8. repository import/connection/synchronization;
9. version-safe Epic/Ticket refinement and suggestion cascades;
10. atomic Team settings; and
11. retrospective actions that mutate Ways of working or Backlog.

For each feature, write the state table first and cover every durable intermediate state with interruption and fresh-instance recovery. Apply the binding launched-process rule in `AGENTS.md` and record the row's resulting `Shell` designation here.

### Work packet 4 — P1 primary owner journeys (in progress)

The Backlog and editable Ticket slice B01, B04, B06, B07, B08, B10, and B11 is
complete in section 3.2. The Sprint planning slice P01, P02, P04, P06, and P07
is complete in section 3.3. Continue with Chat, Knowledge, Codebase navigation,
App versions, and Retrospectives as separate coherent packets. Reuse
presentation-policy tests for branches that do not need full coordinator state.

### Work packet 5 — P2 convenience and presentation journeys

Cover shortcuts, filters, display preferences, report variants, counts, and secondary navigation with policy/presentation tests. Apply the binding launched-process rule in `AGENTS.md`.

### Work packet 6 — CI and maintenance ratchet

1. Keep `swift test -Xswiftc -warnings-as-errors` as the fast required suite, and hold it to a stated wall-clock budget. CI currently allows 30 minutes for the whole job; journeys that open real SQLite stores and real temporary Git repositories are the expensive tests, so each work packet reports the suite's runtime before and after and states which suites must be `.serialized` and why.
2. Add a separate serialized `xcodebuild test` job for the small UI contract suite.
3. Run bounded fake external journeys on pull requests.
4. Run real external smoke checks manually or on a controlled schedule.
5. Require every future long-running or multi-screen feature to follow the journey inventory and `Shell` designation checklist in `AGENTS.md`.
6. Quarantine no flaky test silently: fix its synchronization contract or remove the invalid assertion.

## 9. Cross-cutting acceptance rules

Every coordinator journey must:

- drive a public owner command;
- observe an explicit operation event or continuation, never an arbitrary sleep;
- assert a bounded presentation snapshot;
- inspect the underlying durable SQLite/Git result;
- prove Product isolation;
- inject interruption at each new durable phase;
- close the first instance and recover with a fresh one where state is expected to survive;
- prove stale callbacks cannot overwrite newer state; and
- fail if the final durable transition is omitted.

Interruption coverage is tiered by priority so that the rule stays affordable: every P0 row injects interruption at each durable phase, every P1 row injects interruption at its single riskiest durable phase, and P2 rows need none unless they own durable state.

Every full-app UI test must:

- use an isolated root and defaults suite;
- launch a debug/test composition, not production credentials or owner data;
- use stable accessibility identifiers for actions and destinations;
- wait on accessibility predicates rather than sleep;
- assert shell wiring, not re-test every Core invariant;
- capture no product-owner desktop state; and
- leave no app process, temporary repository, database, or fixture server behind.


## 10. Decision

The known-good baseline and Priority 0 matrix are complete. Continue with the
Priority 1 primary owner journeys, then Priority 2 convenience and presentation
journeys. Expand by owner risk, not by source-file order and not by converting
all existing component tests into UI tests.
