import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

@Suite("SQLite store", .serialized)
struct SQLiteStoreTests {
  @Test("Products follow the palette order and survive restart")
  func productColorsAreAssignedAndPersisted() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    var products: [Product] = []
    for index in 1...8 {
      products.append(
        try await store.createProduct(
          name: "Product \(index)"
        )
      )
    }

    #expect(
      products.map(\.color)
        == [.accent, .green, .indigo, .orange, .teal, .pink, .blue, .green]
    )

    let assignedColors = Dictionary(
      uniqueKeysWithValues: products.map { ($0.id, $0.color) }
    )
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recoveredColors = Dictionary(
      uniqueKeysWithValues: try await reopened.fetchProducts().map { ($0.id, $0.color) }
    )
    #expect(recoveredColors == assignedColors)
    await reopened.close()
  }

  @Test("Team settings update atomically across every profile boundary")
  func teamSettingsUpdateIsAtomic() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Atomic team")
    let originalProfiles = try await store.seedDefaultProfiles(productID: product.id)
    let updates = originalProfiles.enumerated().map { index, profile in
      TeamProfileSettingsUpdate(
        profileID: profile.id,
        model: "updated-model-\(index)",
        reasoningEffort: index.isMultiple(of: 2) ? "high" : "medium",
        customInstructions: " Updated guidance \(index) "
      )
    }

    for profile in originalProfiles {
      try fixture.execute(
        """
        CREATE TRIGGER fail_team_settings_profile
        BEFORE UPDATE ON agent_profiles
        WHEN OLD.id = '\(profile.id.uuidString)'
        BEGIN
          SELECT RAISE(ABORT, 'injected team settings failure');
        END;
        """
      )
      await #expect(throws: PersistenceError.self) {
        try await store.updateTeamSettings(
          productID: product.id,
          productInstructions: "Updated shared guidance",
          profiles: updates
        )
      }
      try fixture.execute("DROP TRIGGER fail_team_settings_profile;")

      let unchangedProduct = try #require(
        try await store.fetchProducts().first { $0.id == product.id }
      )
      #expect(unchangedProduct.instructions == product.instructions)
      #expect(try await store.fetchAgentProfiles(productID: product.id) == originalProfiles)
    }

    #if DEBUG
      await store.resetPreparedStatementCount()
    #endif
    let snapshot = try await store.updateTeamSettings(
      productID: product.id,
      productInstructions: "  Updated shared guidance  ",
      profiles: updates
    )
    #expect(snapshot.product.instructions == "Updated shared guidance")
    #expect(snapshot.profiles.count == originalProfiles.count)
    for (index, profile) in snapshot.profiles.enumerated() {
      #expect(profile.model == "updated-model-\(index)")
      #expect(profile.reasoningEffort == (index.isMultiple(of: 2) ? "high" : "medium"))
      #expect(profile.customInstructions == "Updated guidance \(index)")
    }
    #if DEBUG
      let settingsSaveQueryCount = await store.currentPreparedStatementCount()
      #expect(
        settingsSaveQueryCount <= originalProfiles.count + 6,
        "Observed \(settingsSaveQueryCount) prepared statements"
      )
      let recipient = try #require(originalProfiles.first)
      for index in 0..<20 {
        let thread = ProductConversationThread(
          productID: product.id,
          recipientProfileID: recipient.id,
          subject: "Historical settings thread \(index)"
        )
        _ = try await store.createConversationThread(
          thread,
          initialMessage: ProductConversationMessage(
            threadID: thread.id,
            authorKind: .owner,
            authorName: "Product owner",
            body: "Historical message \(index)"
          )
        )
      }
      await store.resetPreparedStatementCount()
      _ = try await store.updateTeamSettings(
        productID: product.id,
        productInstructions: snapshot.product.instructions,
        profiles: updates
      )
      #expect(await store.currentPreparedStatementCount() == settingsSaveQueryCount)
    #endif
    await store.close()
  }

  @Test("[D01] Starting a sprint freezes its scoped execution plan")
  func sprintExecutionSnapshotIsScoped() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Bounded scheduler")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })

    var prerequisite = try await readyItem(
      in: store,
      productID: product.id,
      title: "Complete prerequisite"
    )
    for state: WorkItemState in [
      .queued, .running, .integrating, .verifying, .acceptance, .readyToRelease, .released,
    ] {
      prerequisite = try await store.transitionWorkItem(
        id: prerequisite.id,
        to: state,
        actor: "Spedito",
        reason: "Prepare scheduler fixture"
      )
    }

    let createdDelivery = try await store.createWorkItem(
      productID: product.id,
      title: "Deliver current sprint",
      acceptanceCriteria: ["The current increment is delivered"],
      dependsOnWorkItemIDs: Set([prerequisite.id])
    )
    _ = try await store.transitionWorkItem(
      id: createdDelivery.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    let delivery = try await store.transitionWorkItem(
      id: createdDelivery.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )

    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Load only the active delivery aggregate",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: delivery.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)

    #if DEBUG
      await store.resetPreparedStatementCount()
    #endif
    let baselineSnapshot = try #require(
      try await store.fetchSprintExecutionSnapshot(productID: product.id)
    )
    #if DEBUG
      let baselineQueryCount = await store.currentPreparedStatementCount()
    #endif

    for index in 0..<25 {
      _ = try await readyItem(
        in: store,
        productID: product.id,
        title: "Unrelated backlog ticket \(index)"
      )
    }

    #if DEBUG
      await store.resetPreparedStatementCount()
    #endif
    let snapshot = try #require(
      try await store.fetchSprintExecutionSnapshot(productID: product.id)
    )

    #expect(baselineSnapshot.workItems.map(\.id) == snapshot.workItems.map(\.id))
    #expect(Set(snapshot.workItems.map(\.id)) == Set([prerequisite.id, delivery.id]))
    #expect(
      snapshot.dependencies
        == [
          WorkItemDependency(
            workItemID: delivery.id,
            dependsOnWorkItemID: prerequisite.id
          )
        ]
    )
    #expect(snapshot.runs.allSatisfy { $0.sprintID == active.sprint.id })
    #expect(snapshot.candidates.allSatisfy { $0.sprintID == active.sprint.id })
    #expect(
      snapshot.permissionRequests.allSatisfy { request in
        snapshot.runs.contains { $0.id == request.agentRunID }
      }
    )
    #if DEBUG
      let expandedQueryCount = await store.currentPreparedStatementCount()
      #expect(expandedQueryCount == baselineQueryCount)
      #expect(expandedQueryCount <= 16)
    #endif
    await store.close()
  }

  @Test("Invalid candidate recovery is atomic, idempotent, and single-admission")
  func invalidCandidateRecoveryIsAtomic() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    var store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Atomic candidate recovery")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Recover one candidate"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Recover atomically",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(active.items.first)
    var run = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    run = try await store.updateAgentRun(
      id: run.id,
      status: .awaitingOwner,
      eventActor: "Spedito",
      eventDetail: "Preparing recovery fixture"
    )
    var currentItem = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    for state: WorkItemState in [.running, .integrating, .verifying, .acceptance] {
      currentItem = try await store.transitionWorkItem(
        id: currentItem.id,
        to: state,
        actor: "Spedito",
        reason: "Preparing recovery fixture"
      )
    }
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: item.id,
        implementationRunID: run.id,
        version: 1,
        branchName: "ticket/\(item.key)",
        baseSHA: "base",
        headSHA: "head",
        worktreePath: "/tmp/\(item.key)",
        status: .readyForDemo,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )
    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let technical = try #require(
      pages.first { $0.parentID == nil && $0.slug == "technical" }
    )
    let proposal = KnowledgePageProposal(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      candidateRevisionID: candidate.id,
      operation: .create,
      parentPageID: technical.id,
      title: "Recovery evidence",
      proposedBodyMarkdown: "# Recovery evidence\n\nDurable evidence.",
      rationale: "Exercises the recovery transaction."
    )
    try await store.createKnowledgePageProposals([proposal])
    let baselineActivityCount = try await store.fetchActivity(productID: product.id).count
    let commentBody = "Candidate recovery returned the preserved workspace."
    let triggers: [(name: String, sql: String)] = [
      (
        "fail_candidate_recovery_candidate",
        """
        CREATE TRIGGER fail_candidate_recovery_candidate
        BEFORE UPDATE ON candidate_revisions
        WHEN OLD.id = '\(candidate.id.uuidString)'
        BEGIN SELECT RAISE(ABORT, 'candidate write failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_proposal",
        """
        CREATE TRIGGER fail_candidate_recovery_proposal
        BEFORE UPDATE ON knowledge_page_proposals
        WHEN OLD.candidate_revision_id = '\(candidate.id.uuidString)'
        BEGIN SELECT RAISE(ABORT, 'proposal write failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_ticket",
        """
        CREATE TRIGGER fail_candidate_recovery_ticket
        BEFORE UPDATE ON work_items
        WHEN OLD.id = '\(item.id.uuidString)'
        BEGIN SELECT RAISE(ABORT, 'ticket write failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_ticket_event",
        """
        CREATE TRIGGER fail_candidate_recovery_ticket_event
        BEFORE INSERT ON activity_events
        WHEN NEW.kind = 'work_item.transitioned'
        BEGIN SELECT RAISE(ABORT, 'ticket event failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_run",
        """
        CREATE TRIGGER fail_candidate_recovery_run
        BEFORE UPDATE ON agent_runs
        WHEN OLD.id = '\(run.id.uuidString)'
        BEGIN SELECT RAISE(ABORT, 'run write failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_run_event",
        """
        CREATE TRIGGER fail_candidate_recovery_run_event
        BEFORE INSERT ON activity_events
        WHEN NEW.kind = 'agent_run.queued'
        BEGIN SELECT RAISE(ABORT, 'run event failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_comment",
        """
        CREATE TRIGGER fail_candidate_recovery_comment
        BEFORE INSERT ON ticket_comments
        WHEN NEW.work_item_id = '\(item.id.uuidString)'
        BEGIN SELECT RAISE(ABORT, 'comment write failed'); END;
        """
      ),
      (
        "fail_candidate_recovery_comment_event",
        """
        CREATE TRIGGER fail_candidate_recovery_comment_event
        BEFORE INSERT ON activity_events
        WHEN NEW.kind = 'comment.created'
        BEGIN SELECT RAISE(ABORT, 'comment event failed'); END;
        """
      ),
    ]

    for trigger in triggers {
      try fixture.execute(trigger.sql)
      await #expect(throws: InvalidCandidateRecoveryError.self) {
        try await store.recoverInvalidReadyForDemoCandidate(
          candidateID: candidate.id,
          runEventDetail: "Candidate queued after recovery",
          transitionReason: "Invalid candidate recovered",
          commentBody: commentBody
        )
      }
      try fixture.execute("DROP TRIGGER \(trigger.name);")
      await store.close()
      store = try SQLiteStore(url: fixture.databaseURL)

      #expect(try await store.fetchCandidateRevision(id: candidate.id).status == .readyForDemo)
      #expect(
        try await store.fetchKnowledgePageProposals(productID: product.id).first?.status
          == .proposed
      )
      #expect(
        try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }?.state
          == .acceptance
      )
      #expect(try await store.fetchAgentRun(id: run.id).status == .awaitingOwner)
      #expect(try await store.fetchComments(workItemID: item.id).isEmpty)
      #expect(try await store.fetchActivity(productID: product.id).count == baselineActivityCount)
    }

    try await store.recoverInvalidReadyForDemoCandidate(
      candidateID: candidate.id,
      runEventDetail: "Candidate queued after recovery",
      transitionReason: "Invalid candidate recovered",
      commentBody: commentBody
    )
    #expect(try await store.fetchCandidateRevision(id: candidate.id).status == .superseded)
    #expect(
      try await store.fetchKnowledgePageProposals(productID: product.id).first?.status
        == .superseded
    )
    #expect(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }?.state
        == .running
    )
    #expect(try await store.fetchAgentRun(id: run.id).status == .queued)
    #expect(try await store.fetchComments(workItemID: item.id).map(\.body) == [commentBody])

    await store.close()
    let recoveryStore = try SQLiteStore(url: fixture.databaseURL)
    async let firstRecovery: Void = recoveryStore.recoverInvalidReadyForDemoCandidate(
      candidateID: candidate.id,
      runEventDetail: "Candidate queued after recovery",
      transitionReason: "Invalid candidate recovered",
      commentBody: commentBody
    )
    async let secondRecovery: Void = recoveryStore.recoverInvalidReadyForDemoCandidate(
      candidateID: candidate.id,
      runEventDetail: "Candidate queued after recovery",
      transitionReason: "Invalid candidate recovered",
      commentBody: commentBody
    )
    _ = try await (firstRecovery, secondRecovery)
    #expect(
      try await recoveryStore.fetchComments(workItemID: item.id).map(\.body)
        == [commentBody]
    )
    let queuedCandidate = try await recoveryStore.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: item.id,
        implementationRunID: run.id,
        version: 2,
        branchName: "ticket/\(item.key)",
        baseSHA: "base",
        headSHA: "head-2",
        worktreePath: "/tmp/\(item.key)",
        status: .reviewing,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )
    let queueComment = "Candidate restored to integration atomically."
    let queueMutations: [TicketDeliveryRecoveryMutation] = [
      .updateCandidate(
        id: queuedCandidate.id,
        expectedStatuses: [.reviewing],
        status: .queuedForIntegration
      ),
      .updateRun(
        id: run.id,
        expectedStatuses: [.queued],
        status: .interrupted,
        eventDetail: "Review retired before integration"
      ),
      .transitionWorkItem(
        id: item.id,
        expectedStates: [.running],
        states: [.integrating],
        reasons: ["Candidate returned to integration"]
      ),
      .appendComment(body: queueComment),
    ]
    try fixture.execute(
      """
      CREATE TRIGGER fail_atomic_delivery_recovery_comment
      BEFORE INSERT ON ticket_comments
      WHEN NEW.body = '\(queueComment)'
      BEGIN SELECT RAISE(ABORT, 'recovery comment failed'); END;
      """
    )
    await #expect(throws: TicketDeliveryRecoveryError.self) {
      try await recoveryStore.performTicketDeliveryRecovery(
        productID: product.id,
        workItemID: item.id,
        mutations: queueMutations
      )
    }
    try fixture.execute("DROP TRIGGER fail_atomic_delivery_recovery_comment;")
    #expect(
      try await recoveryStore.fetchCandidateRevision(id: queuedCandidate.id).status == .reviewing
    )
    #expect(try await recoveryStore.fetchAgentRun(id: run.id).status == .queued)
    #expect(
      try await recoveryStore.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state == .running
    )
    #expect(
      !((try await recoveryStore.fetchComments(workItemID: item.id)).contains {
        $0.body == queueComment
      })
    )

    async let firstQueueRecovery: Void = recoveryStore.performTicketDeliveryRecovery(
      productID: product.id,
      workItemID: item.id,
      mutations: queueMutations
    )
    async let secondQueueRecovery: Void = recoveryStore.performTicketDeliveryRecovery(
      productID: product.id,
      workItemID: item.id,
      mutations: queueMutations
    )
    _ = try await (firstQueueRecovery, secondQueueRecovery)
    #expect(
      try await recoveryStore.fetchCandidateRevision(id: queuedCandidate.id).status
        == .queuedForIntegration
    )
    #expect(try await recoveryStore.fetchAgentRun(id: run.id).status == .interrupted)
    #expect(
      try await recoveryStore.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state == .integrating
    )
    #expect(
      try await recoveryStore.fetchComments(workItemID: item.id)
        .filter { $0.body == queueComment }.count == 1
    )
    await recoveryStore.close()
  }

  @Test("Version 7 databases add durable candidate delivery kinds")
  func candidateDeliveryKindMigration() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let currentStore = try SQLiteStore(url: fixture.databaseURL)
    await currentStore.close()
    try fixture.execute(
      """
      ALTER TABLE candidate_revisions DROP COLUMN delivery_kind;
      PRAGMA user_version = 7;
      """
    )

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    _ = try await migratedStore.createProduct(name: "Migrated product")
    await migratedStore.close()
  }

  @Test("Version 8 placeholder sprint goals migrate to missing goals")
  func placeholderSprintGoalMigration() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let currentStore = try SQLiteStore(url: fixture.databaseURL)
    let product = try await currentStore.createProduct(name: "Migrated planning")
    let item = try await readyItem(
      in: currentStore,
      productID: product.id,
      title: "Deliver the saved scope"
    )
    _ = try await currentStore.saveDraftSprint(
      productID: product.id,
      goal: "Next valuable increment",
      tokenBudgetLimit: nil,
      items: [SprintDraftItemInput(workItemID: item.id)]
    )
    await currentStore.close()

    try fixture.execute("PRAGMA user_version = 8;")

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    let migratedPlan = try #require(
      await migratedStore.fetchCurrentSprint(productID: product.id)
    )
    #expect(migratedPlan.sprint.goal.isEmpty)
    #expect(
      try await migratedStore.sprintReadinessIssues(sprintID: migratedPlan.sprint.id)
        .allSatisfy { $0.id != "sprint.goal" }
    )
    await migratedStore.close()
  }

  @Test("Version 9 databases retain one active repository analysis and recover atomically")
  func repositoryKnowledgeActiveRunMigrationAndRecovery() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let currentStore = try SQLiteStore(url: fixture.databaseURL)
    let product = try await currentStore.createProduct(name: "Migrated analysis")
    let profiles = try await currentStore.seedDefaultProfiles(productID: product.id)
    let analyzer = try #require(profiles.first { $0.role == .businessAnalyst })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    let first = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      analyzedSHA: String(repeating: "1", count: 40),
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id,
      status: .analyzing
    )
    try await currentStore.createRepositoryKnowledgeRun(first)
    await currentStore.close()

    let secondID = UUID()
    let now = Date().timeIntervalSince1970
    try fixture.execute(
      """
      DROP INDEX idx_repository_knowledge_runs_one_active;
      INSERT INTO repository_knowledge_runs (
        id, product_id, attempt, purpose, analyzed_sha, analyzer_profile_id,
        reviewer_profile_id, analyzer_thread_id, analyzer_turn_id,
        reviewer_thread_id, reviewer_turn_id, status, analysis_summary,
        review_summary, error_message, knowledge_export_paths_json,
        knowledge_commit_sha, created_at, updated_at
      ) VALUES (
        '\(secondID.uuidString)', '\(product.id.uuidString)', 2, 'knowledge',
        '\(String(repeating: "2", count: 40))', '\(analyzer.id.uuidString)',
        '\(reviewer.id.uuidString)', NULL, NULL, NULL, NULL, 'reviewing',
        NULL, NULL, NULL, '[]', NULL, \(now), \(now)
      );
      PRAGMA user_version = 9;
      """
    )

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    let migratedRuns = try await migratedStore.fetchRepositoryKnowledgeRuns(
      productID: product.id
    )
    #expect(migratedRuns.first { $0.id == first.id }?.status == .interrupted)
    #expect(migratedRuns.first { $0.id == secondID }?.status == .reviewing)

    let recovered = try await migratedStore.recoverRepositoryKnowledgeRun(
      interruptedRunID: secondID,
      errorMessage: "Interrupted for recovery",
      analyzedSHA: String(repeating: "2", count: 40),
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
    #expect(recovered.attempt == 3)
    #expect(recovered.status == .pendingAnalysis)
    #expect(
      try await migratedStore.fetchRepositoryKnowledgeRun(id: secondID).status
        == .interrupted
    )
    await migratedStore.close()
  }

  @Test("Version 10 databases retire obsolete manual publications")
  func obsoleteManualPublicationMigration() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Migrated publication")
    let accountID = UUID()
    let permissions = RemoteRepositoryPermissions(
      metadataRead: true,
      contentsWrite: true,
      pullRequestsWrite: true,
      workflowsWrite: false
    )
    let connection = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .importedSource,
        accountID: accountID,
        installationID: 16,
        repositoryID: 17,
        owner: "owner",
        name: "product",
        fullName: "owner/product",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/product.git")!,
        isPrivate: false,
        defaultBranch: "main",
        permissions: permissions,
        status: .connected
      )
    )
    let revision = String(repeating: "1", count: 40)
    let publication = try await store.createRemotePublication(
      RemotePublication(
        productID: product.id,
        connectionID: connection.id,
        purpose: .existingProductHistory,
        accountID: accountID,
        repositoryID: 17,
        owner: "owner",
        name: "product",
        fullName: "owner/product",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/product.git")!,
        isPrivate: false,
        permissions: permissions,
        capturedLocalSHA: revision,
        capturedLocalTree: revision,
        remoteBaseSHA: revision,
        remoteBaseTree: revision,
        targetBranch: "main",
        publicationBranch: "spedito/migrated",
        manifestDigest: String(repeating: "2", count: 64),
        manifestObjectCount: 1,
        manifestCommitCount: 1,
        manifestPathCount: 1,
        commits: [RemoteCommitSummary(sha: revision, subject: "Existing history")],
        paths: ["README.md"],
        title: "Publish existing Product history",
        body: "Existing history"
      )
    )
    await store.close()

    try fixture.execute(
      """
      UPDATE remote_publications
      SET purpose = 'legacy_manual'
      WHERE id = '\(publication.id.uuidString)';
      PRAGMA user_version = 10;
      """
    )

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    #expect(
      try await migratedStore.fetchRemotePublication(id: publication.id)?.purpose
        == .existingProductHistory
    )
    #expect(
      try await migratedStore.fetchRemotePublication(id: publication.id)?.status
        == .cancelled
    )
    await migratedStore.close()
  }

  @Test("Archived colors are reused and restored products avoid active colors")
  func activeProductColorsStayDistinctThroughArchiveAndRestore() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let first = try await store.createProduct(name: "First")
    let archived = try await store.createProduct(name: "Archived")
    _ = try await store.archiveProduct(id: archived.id)

    let replacement = try await store.createProduct(name: "Replacement")
    #expect(first.color == .accent)
    #expect(archived.color == .green)
    #expect(replacement.color == .green)

    let restored = try await store.restoreProduct(id: archived.id)
    #expect(restored.color == .indigo)
    #expect(Set(try await store.fetchProducts().map(\.color)).count == 3)

    await store.close()
  }

  @Test("Epics follow the palette order and survive restart")
  func epicColorsAreAssignedAndPersisted() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Colorful planning"
    )
    let epics = try await [
      store.createEpic(productID: product.id, outcome: "First outcome"),
      store.createEpic(productID: product.id, outcome: "Second outcome"),
      store.createEpic(productID: product.id, outcome: "Third outcome"),
    ]

    #expect(epics.map(\.color) == [.blue, .green, .indigo])

    let assignedColors = Dictionary(
      uniqueKeysWithValues: epics.map { ($0.id, $0.color) }
    )
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recoveredColors = Dictionary(
      uniqueKeysWithValues:
        try await reopened.fetchEpics(productID: product.id).map { ($0.id, $0.color) }
    )
    #expect(recoveredColors == assignedColors)
    await reopened.close()
  }

  @Test("New epics persist only the owner's outcome until analysis")
  func newEpicsPersistOnlyOwnerOutcomeUntilAnalysis() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Outcome planning")
    let outcome =
      "Let a macOS user immediately type temporary plain text in a focused native app without saving."
    let epic = try await store.createEpic(productID: product.id, outcome: outcome)

    #expect(epic.title.isEmpty)
    #expect(epic.goal == outcome)
    #expect(epic.successCriteria.isEmpty)
    #expect(epic.constraints.isEmpty)
    #expect(!epic.hasAnalyzedMetadata)
    #expect(epic.displayTitle == outcome)
    let creationEvent = try #require(
      try await store.fetchActivity(productID: product.id)
        .first { $0.kind == "epic.created" }
    )
    #expect(creationEvent.detail == outcome)

    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let persisted = try #require(
      try await reopened.fetchEpics(productID: product.id).first
    )
    #expect(persisted.title.isEmpty)
    #expect(persisted.goal == outcome)
    #expect(persisted.successCriteria.isEmpty)
    #expect(persisted.constraints.isEmpty)
    await reopened.close()
  }

  @Test("Product, ticket, comments, profiles, and audit events survive restart")
  func durableWorkflow() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Tiny browser product"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    #expect(
      profiles.map(\.role) == [
        .businessAnalyst, .uxDesigner, .lead, .implementer,
      ])
    let reseededProfiles = try await store.seedDefaultProfiles(productID: product.id)
    #expect(reseededProfiles.map(\.id) == profiles.map(\.id))
    let defaultAnalyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let defaultDesigner = try #require(profiles.first { $0.role == .uxDesigner })
    let lead = try #require(profiles.first { $0.role == .lead })
    let implementer = try #require(profiles.first { $0.role == .implementer })
    #expect(defaultAnalyst.model == "gpt-5.6-terra")
    #expect(defaultAnalyst.reasoningEffort == "medium")
    #expect(defaultDesigner.model == "gpt-5.6-terra")
    #expect(defaultDesigner.reasoningEffort == "medium")
    #expect(lead.model == "gpt-5.6-terra")
    #expect(lead.reasoningEffort == "high")
    #expect(lead.name == "Tech lead")
    #expect(lead.role.title == "Tech lead")
    #expect(lead.role.capabilityTitle == "Architecture, planning & review")
    #expect(implementer.model == "gpt-5.6-terra")
    #expect(implementer.reasoningEffort == "medium")

    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Show a useful preview",
      type: .task,
      body: "Create a locally reviewable page.",
      acceptanceCriteria: ["The owner can open a loopback URL"],
      priority: .high
    )
    #expect(item.key == "T1")
    #expect(item.state == .backlog)

    let refining = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Clarify acceptance intent"
    )
    #expect(refining.version == 2)

    let ownerQuestion = TicketOwnerQuestion(
      prompt: "Which empty state should the ticket deliver?",
      options: ["A concise explanation", "A retry action"],
      decisionArtifact: TicketDecisionArtifact(
        title: "Empty-state comparison",
        path: "docs/empty-state-comparison.md"
      )
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: "Business analyst",
      body: "We still need to define the empty state.",
      ownerQuestion: ownerQuestion
    )
    let answeredQuestion = TicketAnsweredQuestion(
      question: TicketRefinementQuestion(
        prompt: ownerQuestion.prompt,
        options: ownerQuestion.options
      ),
      selectedOption: "A retry action",
      answer: "A retry action"
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@Business analyst A retry action",
      answeredQuestions: [answeredQuestion]
    )
    try await store.updateProductInstructions(
      productID: product.id,
      instructions: "Prefer plain language and accessible defaults."
    )
    try await store.updateProductDetails(
      productID: product.id,
      name: "Tiny product"
    )
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    _ = try await store.updateAgentProfileConfiguration(
      id: analyst.id,
      model: "gpt-5.6-sol",
      reasoningEffort: "high",
      customInstructions: "Challenge assumptions with concrete examples."
    )

    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let products = try await reopened.fetchProducts()
    let items = try await reopened.fetchWorkItems(productID: product.id)
    let comments = try await reopened.fetchComments(workItemID: item.id)
    let activity = try await reopened.fetchActivity(productID: product.id)
    let ticketActivity = try await reopened.fetchActivity(workItemID: item.id)

    #expect(products.map(\.id) == [product.id])
    #expect(products.map(\.name) == ["Tiny product"])
    #expect(products.map(\.instructions) == ["Prefer plain language and accessible defaults."])
    #expect(items.count == 1)
    #expect(items.first?.state == .refining)
    #expect(items.first?.type == .task)
    #expect(items.first?.version == 2)
    #expect(
      comments.map(\.body) == [
        "We still need to define the empty state.",
        "@Business analyst A retry action",
      ]
    )
    #expect(comments.first?.ownerQuestion == ownerQuestion)
    #expect(comments.last?.answeredQuestions == [answeredQuestion])
    #expect(activity.map(\.kind).contains("product.created"))
    #expect(activity.map(\.kind).contains("work_item.transitioned"))
    #expect(activity.map(\.kind).contains("comment.created"))
    #expect(products.first?.updatedAt == activity.first?.createdAt)
    #expect(ticketActivity.allSatisfy { $0.workItemID == item.id })
    #expect(ticketActivity.map(\.kind).contains("work_item.transitioned"))
    #expect(ticketActivity.map(\.kind).contains("comment.created"))
    let recoveredProfiles = try await reopened.fetchAgentProfiles(productID: product.id)
    let recoveredAnalyst = try #require(
      recoveredProfiles.first { $0.role == .businessAnalyst }
    )
    #expect(recoveredAnalyst.model == "gpt-5.6-sol")
    #expect(recoveredAnalyst.reasoningEffort == "high")
    #expect(recoveredAnalyst.customInstructions == "Challenge assumptions with concrete examples.")

    await reopened.close()
  }

  @Test("Comment aggregate fetch preserves per-ticket ordering")
  func batchedCommentFetch() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Comment aggregate")
    let first = try await store.createWorkItem(
      productID: product.id,
      title: "First ticket"
    )
    let second = try await store.createWorkItem(
      productID: product.id,
      title: "Second ticket"
    )
    let empty = try await store.createWorkItem(
      productID: product.id,
      title: "Empty ticket"
    )
    _ = try await store.appendComment(
      workItemID: first.id,
      authorKind: .agent,
      authorName: "Implementer",
      body: "Newer",
      createdAt: Date(timeIntervalSince1970: 20)
    )
    _ = try await store.appendComment(
      workItemID: first.id,
      authorKind: .owner,
      authorName: "Product owner",
      body: "Older",
      createdAt: Date(timeIntervalSince1970: 10)
    )
    _ = try await store.appendComment(
      workItemID: second.id,
      authorKind: .agent,
      authorName: "Tech lead",
      body: "Only",
      createdAt: Date(timeIntervalSince1970: 15)
    )

    let comments = try await store.fetchComments(
      workItemIDs: [first.id, second.id, empty.id]
    )
    #expect(comments[first.id]?.map(\.body) == ["Older", "Newer"])
    #expect(comments[second.id]?.map(\.body) == ["Only"])
    #expect(comments[empty.id] == nil)
    #expect(try await store.fetchComments(workItemID: first.id).map(\.body) == ["Older", "Newer"])
    #expect(try await store.fetchComments(workItemIDs: []).isEmpty)

    await store.close()
  }

  @Test("Archiving a product hides active work without deleting its history")
  func productArchiveAndRestorePreserveHistory() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let retained = try await store.createProduct(
      name: "Retained product"
    )
    let archived = try await store.createProduct(
      name: "Historical product"
    )
    let item = try await store.createWorkItem(
      productID: archived.id,
      title: "Keep the historical ticket",
      acceptanceCriteria: ["The ticket survives product archival"]
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "This work log entry must remain available."
    )

    let archivedProduct = try await store.archiveProduct(id: archived.id)
    #expect(archivedProduct.status == .archived)
    #expect(try await store.fetchProducts().map(\.id) == [retained.id])
    #expect(
      try await store.fetchProducts(status: .archived).map(\.id) == [archived.id]
    )
    #expect(
      Set(try await store.fetchProducts(status: nil).map(\.id)) == [retained.id, archived.id])
    #expect(try await store.fetchWorkItems(productID: archived.id).map(\.id) == [item.id])
    #expect(
      try await store.fetchComments(workItemID: item.id).map(\.body)
        == ["This work log entry must remain available."]
    )
    #expect(
      try await store.fetchActivity(productID: archived.id).first?.kind
        == "product.archived"
    )

    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    #expect(try await reopened.fetchProducts().map(\.id) == [retained.id])
    #expect(
      try await reopened.fetchProducts(status: .archived).first?.status == .archived
    )

    let restoredProduct = try await reopened.restoreProduct(id: archived.id)
    #expect(restoredProduct.status == .active)
    #expect(
      Set(try await reopened.fetchProducts().map(\.id)) == Set([retained.id, archived.id])
    )
    #expect(try await reopened.fetchProducts(status: .archived).isEmpty)
    #expect(
      try await reopened.fetchActivity(productID: archived.id).first?.kind
        == "product.restored"
    )
    #expect(try await reopened.fetchWorkItems(productID: archived.id).map(\.id) == [item.id])

    await reopened.close()
  }

  @Test("Agent run lifecycle and reviewer runs are durable")
  func agentRunLifecycleIsDurable() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Runner"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let techLead = try #require(profiles.first { $0.role == .lead })
    let item = try await readyItem(in: store, productID: product.id, title: "Build outcome")
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Exercise the runner",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: nil
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let implementationRun = try #require(
      await store.fetchAgentRuns(productID: product.id).first
    )
    let running = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .running,
      codexThreadID: "thread-implementation",
      worktreePath: "/tmp/runner",
      eventActor: implementer.name,
      eventDetail: "Started work"
    )
    #expect(running.status == .running)
    #expect(running.codexThreadID == "thread-implementation")
    #expect(running.worktreePath == "/tmp/runner")
    let activityAt = Date(timeIntervalSince1970: 1_728_000_000)
    let observed = try await store.recordAgentRunActivity(
      id: implementationRun.id,
      activity: CodexLiveActivity(text: "Running focused checks…", kind: .runningChecks),
      contextUsedTokens: 12_000,
      contextWindowTokens: 64_000,
      didCompact: true,
      startsTurn: true,
      at: activityAt
    )
    #expect(observed.turnStartedAt == activityAt)
    #expect(observed.lastActivityAt == activityAt)
    #expect(observed.persistedActivity?.text == "Running focused checks…")
    #expect(observed.contextUsedTokens == 12_000)
    #expect(observed.contextWindowTokens == 64_000)
    #expect(observed.compactionCount == 1)
    #expect(observed.activeDuration(at: activityAt.addingTimeInterval(12)) == 12)
    _ = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .running,
      eventActor: implementer.name,
      eventDetail: "This same-state update is not another lifecycle event"
    )
    let paused = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .awaitingOwner,
      eventActor: implementer.name,
      eventDetail: "Waiting for owner input"
    )
    #expect(paused.turnStartedAt == nil)
    #expect(paused.activeDurationSeconds > 0)
    let queuedAgain = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .queued,
      eventActor: "Product owner",
      eventDetail: "Answer received"
    )
    #expect(queuedAgain.activeDurationSeconds == paused.activeDurationSeconds)

    let reviewRun = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: active.items.first?.id,
        workItemID: item.id,
        profileID: techLead.id,
        status: .running
      )
    )
    _ = try await store.updateAgentRun(id: reviewRun.id, status: .completed)
    let secondReviewRun = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: active.items.first?.id,
        workItemID: item.id,
        profileID: techLead.id,
        status: .running
      )
    )
    let recovered = try await store.fetchAgentRuns(productID: product.id)
    let ticketActivity = try await store.fetchActivity(workItemID: item.id)

    #expect(recovered.count == 3)
    #expect(recovered.first { $0.id == reviewRun.id }?.status == .completed)
    #expect(recovered.first { $0.id == secondReviewRun.id }?.status == .running)
    #expect(recovered.first { $0.id == implementationRun.id }?.lastActivityAt == activityAt)
    #expect(ticketActivity.contains { $0.kind == "agent_run.running" })
    #expect(ticketActivity.filter { $0.kind == "agent_run.running" }.count == 1)
    await store.close()
  }

  @Test("Invalid transition leaves durable state unchanged")
  func invalidTransitionIsAtomic() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Atomicity")
    let item = try await store.createWorkItem(productID: product.id, title: "Cannot skip gates")

    await #expect(throws: WorkflowError.invalidTransition(from: .backlog, to: .running)) {
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .running,
        actor: "Implementer",
        reason: "Tried to skip refinement"
      )
    }

    let stored = try await store.fetchWorkItems(productID: product.id)
    #expect(stored.first?.state == .backlog)
    #expect(stored.first?.version == 1)

    await store.close()
  }

  @Test("Ticket edits reject a stale version instead of overwriting newer owner work")
  func ticketEditVersionConflict() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Concurrent planning")
    let item = try await store.createWorkItem(productID: product.id, title: "Original title")
    let updated = try await store.updateWorkItem(
      id: item.id,
      title: "Owner's newer title",
      type: item.type,
      body: item.body,
      acceptanceCriteria: item.acceptanceCriteria,
      priority: item.priority,
      customFields: item.customFields,
      expectedVersion: item.version
    )

    await #expect(
      throws: WorkItemUpdateError.versionConflict(
        key: item.key,
        expected: item.version,
        actual: updated.version
      )
    ) {
      _ = try await store.updateWorkItem(
        id: item.id,
        title: "Stale agent proposal",
        type: item.type,
        body: item.body,
        acceptanceCriteria: item.acceptanceCriteria,
        priority: item.priority,
        customFields: item.customFields,
        expectedVersion: item.version
      )
    }
    let stored = try #require(
      await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(stored.title == "Owner's newer title")
    #expect(stored.version == updated.version)
    let updateEvent = try #require(
      try await store.fetchActivity(productID: product.id)
        .first { $0.kind == "work_item.updated" }
    )
    #expect(updateEvent.detail == "Changed title")
    await store.close()
  }

  @Test("Starting a sprint freezes contracts and creates durable runs exactly once")
  func sprintStartIsDurableAndIdempotent() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Sprint product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let reviewer = try #require(profiles.first { $0.role == .lead })

    let first = try await readyItem(
      in: store,
      productID: product.id,
      title: "First outcome"
    )
    let second = try await readyItem(
      in: store,
      productID: product.id,
      title: "Second outcome"
    )

    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Prove parallel delivery",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: first.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: reviewer.id
        ),
        SprintDraftItemInput(
          workItemID: second.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: reviewer.id
        ),
      ]
    )
    #expect(draft.sprint.state == .draft)
    #expect(draft.estimatedTokens == 0)
    #expect(try await store.sprintReadinessIssues(sprintID: draft.sprint.id).isEmpty)

    let started = try await store.startSprint(id: draft.sprint.id)
    let repeated = try await store.startSprint(id: draft.sprint.id)
    let items = try await store.fetchWorkItems(productID: product.id)
    let runs = try await store.fetchAgentRuns(productID: product.id)
    let history = try await store.fetchSprintHistory(productID: product.id)

    #expect(started.sprint.state == .active)
    #expect(started.items.allSatisfy { $0.frozenWorkItemVersion == 3 })
    #expect(started.items.allSatisfy { $0.frozenAcceptanceCriteria == ["The outcome is visible"] })
    #expect(repeated.sprint.id == started.sprint.id)
    #expect(items.allSatisfy { $0.state == .queued && $0.version == 4 })
    #expect(runs.count == 2)
    #expect(runs.allSatisfy { $0.status == .queued && $0.sprintID == started.sprint.id })
    #expect(history.map(\.sprint.id) == [started.sprint.id])
    #expect(history.first?.items.count == 2)

    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recoveredPlan = try #require(await reopened.fetchCurrentSprint(productID: product.id))
    let recoveredRuns = try await reopened.fetchAgentRuns(productID: product.id)
    #expect(recoveredPlan.sprint.state == .active)
    #expect(recoveredPlan.items.count == 2)
    #expect(recoveredRuns.count == 2)
    await reopened.close()
  }

  @Test("Sprint start does not wait for a generated goal")
  func sprintGoalCanFinishAfterStart() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Lazy sprint goal")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver the planned outcome"
    )
    let items = [
      SprintDraftItemInput(
        workItemID: item.id,
        implementerProfileID: implementer.id,
        estimatedTokens: 1_000
      )
    ]

    let initialDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "   ",
      tokenBudgetLimit: nil,
      items: items
    )
    #expect(initialDraft.sprint.goal.isEmpty)
    #expect(
      try await store.sprintReadinessIssues(sprintID: initialDraft.sprint.id).isEmpty
    )

    let revisedDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "",
      tokenBudgetLimit: nil,
      items: items
    )
    await #expect(throws: SprintPlanningError.planChanged) {
      _ = try await store.saveGeneratedSprintGoal(
        id: initialDraft.sprint.id,
        goal: "Ignore the newer scope",
        expectedPlanVersion: initialDraft.sprint.planVersion
      )
    }

    let started = try await store.startSprint(id: revisedDraft.sprint.id)
    #expect(started.sprint.state == .active)
    #expect(started.sprint.goal.isEmpty)

    let generated = try await store.saveGeneratedSprintGoal(
      id: started.sprint.id,
      goal: "  Deliver the planned outcome  ",
      expectedPlanVersion: started.sprint.planVersion
    )
    #expect(generated.sprint.state == .active)
    #expect(generated.sprint.goal == "Deliver the planned outcome")
    #expect(generated.sprint.planVersion == started.sprint.planVersion + 1)

    let preserved = try await store.saveGeneratedSprintGoal(
      id: started.sprint.id,
      goal: "Overwrite the generated goal",
      expectedPlanVersion: started.sprint.planVersion
    )
    #expect(preserved.sprint.goal == "Deliver the planned outcome")
    await store.close()
  }

  @Test("[D04] Pausing a sprint is durable, blocks another start, and resumes preserved runs")
  func sprintPauseAndResumeAreDurable() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Pause control"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let first = try await readyItem(
      in: store,
      productID: product.id,
      title: "Preserve this delivery"
    )
    let firstDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Pause without losing work",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: first.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: firstDraft.sprint.id)
    let paused = try await store.pauseSprint(id: active.sprint.id)

    #expect(paused.sprint.state == .paused)
    #expect(
      try await store.fetchCurrentSprint(productID: product.id)?.sprint.state == .paused
    )

    let second = try await readyItem(
      in: store,
      productID: product.id,
      title: "Wait for the current sprint"
    )
    let secondDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Start only after the pause is resolved",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: second.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    await #expect(throws: SprintPlanningError.activeSprintExists) {
      _ = try await store.startSprint(id: secondDraft.sprint.id)
    }

    let resumed = try await store.resumeSprint(id: paused.sprint.id)
    let runs = try await store.fetchAgentRuns(productID: product.id)
    #expect(resumed.sprint.state == .active)
    #expect(runs.count == 1)
    #expect(runs.first?.status == .queued)
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    #expect(
      try await reopened.fetchCurrentSprint(productID: product.id)?.sprint.state == .active
    )
    await reopened.close()
  }

  @Test("[D05] Stopping a sprint keeps done work and returns unfinished work for replanning")
  func stoppingSprintPreservesAcceptedWorkAndSupersedesUnacceptedWork() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Stop control"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let doneItem = try await readyItem(
      in: store,
      productID: product.id,
      title: "Keep the accepted outcome"
    )
    let unfinishedItem = try await readyItem(
      in: store,
      productID: product.id,
      title: "Reconsider the unfinished outcome"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Stop safely when priorities change",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: doneItem.id,
          implementerProfileID: implementer.id
        ),
        SprintDraftItemInput(
          workItemID: unfinishedItem.id,
          implementerProfileID: implementer.id
        ),
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let runs = try await store.fetchAgentRuns(productID: product.id)
    let doneRun = try #require(runs.first { $0.workItemID == doneItem.id })
    let unfinishedRun = try #require(runs.first { $0.workItemID == unfinishedItem.id })
    _ = try await store.updateAgentRun(id: doneRun.id, status: .completed)
    _ = try await store.updateAgentRun(
      id: unfinishedRun.id,
      status: .running,
      codexThreadID: "thread-unfinished",
      worktreePath: "/tmp/unfinished"
    )

    var delivered = try await store.transitionWorkItem(
      id: doneItem.id,
      to: .running,
      actor: implementer.name,
      reason: "Test delivery"
    )
    for state: WorkItemState in [
      .integrating, .verifying, .acceptance, .readyToRelease, .released,
    ] {
      delivered = try await store.transitionWorkItem(
        id: delivered.id,
        to: state,
        actor: "Test",
        reason: "Test accepted outcome"
      )
    }
    _ = try await store.transitionWorkItem(
      id: unfinishedItem.id,
      to: .running,
      actor: implementer.name,
      reason: "Test in-progress delivery"
    )

    let sprintItem = try #require(
      active.items.first { $0.workItemID == unfinishedItem.id }
    )
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: unfinishedItem.id,
        implementationRunID: unfinishedRun.id,
        version: 1,
        branchName: "ticket/\(unfinishedItem.key)",
        baseSHA: "base",
        headSHA: "head",
        integratedSHA: "integrated",
        worktreePath: "/tmp/unfinished",
        status: .readyForDemo,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )

    _ = try await store.pauseSprint(id: active.sprint.id)
    let stopped = try await store.cancelSprint(id: active.sprint.id)
    let storedItems = try await store.fetchWorkItems(productID: product.id)
    let storedRuns = try await store.fetchAgentRuns(productID: product.id)
    let storedCandidate = try await store.fetchCandidateRevision(id: candidate.id)
    let comments = try await store.fetchComments(workItemID: unfinishedItem.id)

    #expect(stopped.sprint.state == .cancelled)
    #expect(storedItems.first { $0.id == doneItem.id }?.state == .released)
    #expect(storedItems.first { $0.id == unfinishedItem.id }?.state == .ready)
    #expect(storedRuns.first { $0.id == doneRun.id }?.status == .completed)
    #expect(storedRuns.first { $0.id == unfinishedRun.id }?.status == .cancelled)
    #expect(storedCandidate.status == .superseded)
    #expect(comments.last?.body.contains("returned to Ready for replanning") == true)
    #expect(try await store.fetchCurrentSprint(productID: product.id) == nil)

    let replacementDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Replan the unfinished outcome",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: unfinishedItem.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let replacement = try await store.startSprint(id: replacementDraft.sprint.id)
    #expect(replacement.sprint.state == .active)
    #expect(replacement.sprint.number == stopped.sprint.number + 1)
    await store.close()
  }

  @Test("Sprint planning has no concurrency setting")
  func sprintPlanningHasNoConcurrencySetting() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Elastic delivery"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver an independent outcome"
    )

    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Allow an elastic execution wave",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )

    #expect(try await store.sprintReadinessIssues(sprintID: draft.sprint.id).isEmpty)
    await store.close()
  }

  @Test("Missing acceptance intent keeps a sprint draft and creates no runs")
  func sprintReadinessBlocksStart() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Guarded sprint")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Missing acceptance intent"
    )
    _ = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    let ready = try await store.transitionWorkItem(
      id: item.id,
      to: .ready,
      actor: "Product owner",
      reason: "Marked ready"
    )

    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Respect readiness",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: ready.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let issues = try await store.sprintReadinessIssues(sprintID: draft.sprint.id)
    #expect(issues.count == 1)
    #expect(issues.map(\.id).contains("\(ready.id).acceptance"))

    do {
      _ = try await store.startSprint(id: draft.sprint.id)
      Issue.record("Expected readiness validation to stop the sprint")
    } catch {
      #expect(error is SprintPlanningError)
    }

    let storedItem = try #require(
      await store.fetchWorkItems(productID: product.id).first { $0.id == ready.id }
    )
    let storedPlan = try #require(await store.fetchCurrentSprint(productID: product.id))
    #expect(storedItem.state == .ready)
    #expect(storedPlan.sprint.state == .draft)
    #expect(try await store.fetchAgentRuns(productID: product.id).isEmpty)
    await store.close()
  }

  @Test("The next sprint can be scoped while the current sprint is active")
  func nextSprintCanBePlannedDuringActiveSprint() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Continuous planning"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let currentItem = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver sprint 1"
    )
    let nextItem = try await readyItem(
      in: store,
      productID: product.id,
      title: "Prepare sprint 2"
    )
    _ = try await store.updateWorkItem(
      id: nextItem.id,
      title: nextItem.title,
      type: nextItem.type,
      body: nextItem.body,
      acceptanceCriteria: nextItem.acceptanceCriteria,
      priority: nextItem.priority,
      customFields: nextItem.customFields,
      dependsOnWorkItemIDs: [currentItem.id]
    )

    let firstDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Current increment",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: currentItem.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: firstDraft.sprint.id)
    let nextDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Following increment",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: nextItem.id,
          implementerProfileID: implementer.id
        )
      ]
    )

    #expect(active.sprint.number == 1)
    #expect(nextDraft.sprint.number == 2)
    #expect(try await store.sprintReadinessIssues(sprintID: nextDraft.sprint.id).isEmpty)
    #expect(
      try await store.fetchCurrentSprint(productID: product.id)?.sprint.id == active.sprint.id)
    let plannedHistory = try await store.fetchSprintHistory(productID: product.id)
    #expect(plannedHistory.map(\.sprint.state) == [.draft, .active])

    for state in [
      WorkItemState.running,
      .integrating,
      .verifying,
      .acceptance,
      .readyToRelease,
      .released,
    ] {
      _ = try await store.transitionWorkItem(
        id: currentItem.id,
        to: state,
        actor: "Test",
        reason: "Complete the active sprint"
      )
    }
    let completed = try await store.completeSprintIfFinished(id: active.sprint.id)
    #expect(completed.sprint.state == .completed)
    #expect(completed.sprint.completedAt != nil)
    #expect(
      try await store.fetchCurrentSprint(productID: product.id)?.sprint.id == nextDraft.sprint.id)

    await store.close()
  }

  @Test("Accepting a suggested ticket also accepts its transitive prerequisites")
  func ticketSuggestionsAreOwnerControlled() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Weather Window"
    )
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    try await store.attachCodexTurn(sessionID: session.id, threadID: "thread-1", turnID: "turn-1")
    let ready = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Select a weather provider",
          type: .task,
          body: "Compare suitable sources.",
          acceptanceCriteria: ["A provider is recommended with trade-offs"],
          suggestedRole: .businessAnalyst,
          priority: .high,
          rationale: "The data contract drives implementation."
        ),
        TicketSuggestionDraft(
          reference: "T2",
          title: "Prototype the weather experience",
          type: .task,
          body: "Design the location and forecast states.",
          acceptanceCriteria: ["The owner can review all core states"],
          suggestedRole: .uxDesigner,
          priority: .high,
          rationale: "The owner should validate the experience first.",
          dependsOnReferences: ["T1"]
        ),
        TicketSuggestionDraft(
          reference: "T3",
          title: "Build the weather interface",
          type: .story,
          body: "Implement the approved experience against a data contract.",
          acceptanceCriteria: ["A location returns a visible forecast"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This creates the customer-facing outcome.",
          dependsOnReferences: ["T2"]
        ),
        TicketSuggestionDraft(
          reference: "T4",
          title: "Prepare launch messaging",
          type: .task,
          body: "Draft messaging independently of implementation.",
          acceptanceCriteria: ["Launch messaging is ready for review"],
          suggestedRole: .businessAnalyst,
          priority: .normal,
          rationale: "This work does not block the interface."
        ),
      ]
    )

    #expect(ready.session.status == .ready)
    #expect(ready.suggestions.count == 4)
    #expect(ready.suggestions.map(\.type) == [.task, .task, .story, .task])
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    let frontend = try #require(ready.suggestions.first { $0.reference == "T3" })
    #expect(frontend.dependencyIDs.count == 1)

    let acceptedBatch = try await store.decideTicketSuggestion(
      id: frontend.id,
      decision: .accepted
    )
    #expect(
      acceptedBatch.suggestions
        .filter { ["T1", "T2", "T3"].contains($0.reference) }
        .allSatisfy { $0.status == .accepted }
    )
    #expect(
      acceptedBatch.suggestions.first { $0.reference == "T4" }?.status == .proposed
    )
    #expect(try await store.fetchWorkItems(productID: product.id).count == 3)
    let dependencies = try await store.fetchWorkItemDependencies(productID: product.id)
    #expect(dependencies.count == 2)

    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      await reopened.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(
      recovered.suggestions.first { $0.reference == "T4" }?.status == .proposed
    )
    #expect(try await reopened.fetchWorkItems(productID: product.id).count == 3)
    #expect(try await reopened.fetchWorkItemDependencies(productID: product.id).count == 2)
    await reopened.close()
  }

  @Test("Approved research follow-ups are durable reviewable backlog proposals")
  func researchFollowUpsBecomeQueuedSuggestions() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Research follow-ups"
    )
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Customers receive reliable external data"
    )
    let source = try await store.createWorkItem(
      productID: product.id,
      title: "Research a suitable data provider",
      type: .task,
      body: "Compare providers and recommend one.",
      acceptanceCriteria: ["The product owner can approve a provider"],
      epicID: epic.id
    )

    let earlierSession = try await store.beginTicketSuggestionSession(productID: product.id)
    let earlierBatch = try await store.completeTicketSuggestionSession(
      sessionID: earlierSession.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "An earlier proposal",
          body: "Keep this proposal reviewable before later research follow-ups.",
          acceptanceCriteria: ["The proposal can be reviewed"],
          suggestedRole: .businessAnalyst,
          priority: .normal,
          rationale: "This verifies queued suggestion batches."
        )
      ]
    )

    let followUps = try await store.createFollowUpTicketSuggestionSession(
      sourceWorkItemID: source.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "Design provider failure states",
          type: .task,
          body: "Design the unavailable and partial-data states.",
          acceptanceCriteria: ["Every provider failure state is reviewable"],
          suggestedRole: .uxDesigner,
          priority: .high,
          rationale: "The approved research identified provider failure behavior.",
          dependsOnExistingWorkItemKeys: [source.key]
        ),
        TicketSuggestionDraft(
          reference: "S2",
          title: "Integrate the approved provider",
          body: "Implement the approved provider contract.",
          acceptanceCriteria: ["Customers can see external data"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This delivers the approved recommendation.",
          dependsOnReferences: ["S1"],
          dependsOnExistingWorkItemKeys: [source.key]
        ),
      ]
    )

    #expect(followUps.session.sourceWorkItemID == source.id)
    #expect(followUps.session.epicID == epic.id)
    #expect(followUps.suggestions.allSatisfy { $0.existingDependencyWorkItemIDs == [source.id] })
    let idempotent = try await store.createFollowUpTicketSuggestionSession(
      sourceWorkItemID: source.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "This duplicate publication is ignored",
          body: "The existing source session remains authoritative.",
          acceptanceCriteria: ["No duplicate session exists"],
          suggestedRole: .businessAnalyst,
          priority: .normal,
          rationale: "Approval retries must be idempotent."
        )
      ]
    )
    #expect(idempotent.session.id == followUps.session.id)

    let firstVisible = try #require(
      await store.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(firstVisible.session.id == earlierSession.id)
    let earlierSuggestion = try #require(earlierBatch.suggestions.first)
    _ = try await store.decideTicketSuggestion(
      id: earlierSuggestion.id,
      decision: .rejected
    )
    let nextVisible = try #require(
      await store.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(nextVisible.session.id == followUps.session.id)

    for reference in ["S2", "S1"] {
      let suggestion = try #require(followUps.suggestions.first { $0.reference == reference })
      _ = try await store.decideTicketSuggestion(id: suggestion.id, decision: .accepted)
    }
    let accepted = try await store.fetchWorkItems(productID: product.id)
      .filter { $0.id != source.id }
    #expect(accepted.count == 2)
    #expect(accepted.allSatisfy { $0.epicID == epic.id })
    let dependencies = try await store.fetchWorkItemDependencies(productID: product.id)
    #expect(dependencies.filter { $0.dependsOnWorkItemID == source.id }.count == 2)

    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      await reopened.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(recovered.session.sourceWorkItemID == source.id)
    #expect(recovered.session.epicID == epic.id)
    await reopened.close()
  }

  @Test("Rejecting a legacy suggested prerequisite archives already accepted dependents")
  func rejectingSuggestionCascadesThroughDependentWork() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Cascade planning"
    )
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    let ready = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "Define the contract",
          body: "Agree the shared contract.",
          acceptanceCriteria: ["The contract is explicit"],
          suggestedRole: .businessAnalyst,
          priority: .high,
          rationale: "Everything else depends on it."
        ),
        TicketSuggestionDraft(
          reference: "S2",
          title: "Design the experience",
          body: "Design against the contract.",
          acceptanceCriteria: ["The experience is reviewable"],
          suggestedRole: .uxDesigner,
          priority: .normal,
          rationale: "The design needs the contract.",
          dependsOnReferences: ["S1"]
        ),
        TicketSuggestionDraft(
          reference: "S3",
          title: "Prepare the implementation",
          body: "Prepare implementation against the contract.",
          acceptanceCriteria: ["The implementation path is clear"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "Delivery needs the contract.",
          dependsOnReferences: ["S1"]
        ),
        TicketSuggestionDraft(
          reference: "S4",
          title: "Validate the design",
          body: "Validate the proposed experience.",
          acceptanceCriteria: ["The design is validated"],
          suggestedRole: .businessAnalyst,
          priority: .normal,
          rationale: "Validation follows design.",
          dependsOnReferences: ["S2"]
        ),
        TicketSuggestionDraft(
          reference: "S5",
          title: "Build the implementation",
          body: "Build the prepared implementation.",
          acceptanceCriteria: ["The implementation is complete"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "Build follows preparation.",
          dependsOnReferences: ["S3"]
        ),
      ]
    )

    let acceptedS3 = try await store.createWorkItem(
      productID: product.id,
      title: "Prepare the implementation"
    )
    let acceptedS5 = try await store.createWorkItem(
      productID: product.id,
      title: "Build the implementation"
    )
    let suggestionS3 = try #require(ready.suggestions.first { $0.reference == "S3" })
    let suggestionS5 = try #require(ready.suggestions.first { $0.reference == "S5" })
    try fixture.execute(
      """
      UPDATE ticket_suggestions
      SET status = 'accepted',
          accepted_work_item_id = CASE id
            WHEN '\(suggestionS3.id.uuidString)' THEN '\(acceptedS3.id.uuidString)'
            WHEN '\(suggestionS5.id.uuidString)' THEN '\(acceptedS5.id.uuidString)'
          END
      WHERE id IN ('\(suggestionS3.id.uuidString)', '\(suggestionS5.id.uuidString)');
      """
    )

    let prerequisite = try #require(ready.suggestions.first { $0.reference == "S1" })
    let cascaded = try await store.rejectTicketSuggestionCascade(id: prerequisite.id)
    let statuses = Dictionary(
      uniqueKeysWithValues: cascaded.suggestions.map { ($0.reference, $0.status) }
    )
    #expect(statuses["S1"] == .rejected)
    #expect(statuses["S2"] == .rejected)
    #expect(statuses["S4"] == .rejected)
    #expect(statuses["S3"] == .accepted)
    #expect(statuses["S5"] == .accepted)

    let acceptedTickets = try await store.fetchWorkItems(productID: product.id)
    #expect(acceptedTickets.count == 2)
    #expect(acceptedTickets.allSatisfy { $0.state == .cancelled })
    #expect(try await store.fetchWorkItemDependencies(productID: product.id).isEmpty)
    await store.close()
  }

  @Test("A failed ticket suggestion session can be dismissed durably")
  func failedTicketSuggestionsCanBeDismissed() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Recoverable suggestions"
    )
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    try await store.failTicketSuggestionSession(
      sessionID: session.id,
      message: "Every dependency must reference another proposed ticket."
    )

    let failed = try #require(
      await store.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(failed.session.status == .failed)
    #expect(failed.session.errorMessage != nil)

    try await store.dismissTicketSuggestionSession(sessionID: session.id)
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let dismissed = try #require(
      await reopened.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(dismissed.session.status == .cancelled)
    #expect(dismissed.session.errorMessage == nil)
    await reopened.close()
  }

  @Test("A failed ticket suggestion session can restart in place")
  func failedTicketSuggestionsCanRestart() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Restartable suggestions"
    )
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Customers can save frequently checked places"
    )
    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    try await store.attachCodexTurn(
      sessionID: session.id,
      threadID: "thread-before-relaunch",
      turnID: "turn-before-relaunch"
    )
    try await store.failTicketSuggestionSession(
      sessionID: session.id,
      message: TicketSuggestionRecoveryPolicy.legacyInterruptionMessage
    )

    let restarted = try await store.retryTicketSuggestionSession(sessionID: session.id)
    #expect(restarted.id == session.id)
    #expect(restarted.status == .generating)
    #expect(restarted.codexThreadID == nil)
    #expect(restarted.codexTurnID == nil)
    #expect(restarted.errorMessage == nil)
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      await reopened.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(recovered.session.id == session.id)
    #expect(recovered.session.status == .generating)
    await reopened.close()
  }

  @Test("Epic plans persist and accepted suggestions inherit their epic")
  func epicPlansOwnAcceptedTickets() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Weather journeys"
    )
    let initialEpic = try await store.createEpic(
      productID: product.id,
      outcome: "Customers can save favourite locations"
    )
    #expect(initialEpic.status == .open)
    let epic = try await store.updateEpic(
      id: initialEpic.id,
      title: "Saved locations",
      goal: "Customers can return to important forecasts without searching again.",
      successCriteria: ["A customer can save and revisit a location"],
      constraints: "Remain local-first."
    )
    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    let batch = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Save a favourite location",
          type: .story,
          body: "Persist an approved location.",
          acceptanceCriteria: ["The saved location remains available"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This creates the epic outcome."
        )
      ]
    )
    let suggestion = try #require(batch.suggestions.first)
    _ = try await store.decideTicketSuggestion(id: suggestion.id, decision: .accepted)

    let accepted = try #require(await store.fetchWorkItems(productID: product.id).first)
    #expect(accepted.epicID == epic.id)
    #expect(try await store.fetchEpics(productID: product.id) == [epic])
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    #expect(try await reopened.fetchEpics(productID: product.id).first?.id == epic.id)
    #expect(
      try await reopened.fetchWorkItems(productID: product.id).first?.epicID == epic.id
    )
    #expect(
      try await reopened.fetchLatestTicketSuggestionBatch(productID: product.id)?
        .session.epicID == epic.id
    )
    await reopened.close()
  }

  @Test("Epics close only after delivery and reopen before accepting more work")
  func epicClosureFollowsDerivedProgress() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Epic lifecycle"
    )
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Customers can finish an important journey"
    )

    await #expect(throws: PersistenceError.self) {
      try await store.closeEpic(id: epic.id)
    }

    let ticket = try await store.createWorkItem(
      productID: product.id,
      title: "Deliver the journey",
      acceptanceCriteria: ["The journey can be completed"],
      epicID: epic.id
    )
    await #expect(throws: PersistenceError.self) {
      try await store.closeEpic(id: epic.id)
    }

    for state in [
      WorkItemState.refining, .ready, .queued, .running, .integrating, .verifying,
      .acceptance, .readyToRelease, .released,
    ] {
      _ = try await store.transitionWorkItem(
        id: ticket.id,
        to: state,
        actor: "Test",
        reason: "Prepare the completed epic"
      )
    }

    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    let batch = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "Consider an optional extension",
          body: "Keep unresolved scope reviewable.",
          acceptanceCriteria: ["The owner decides whether it belongs"],
          suggestedRole: .businessAnalyst,
          priority: .normal,
          rationale: "Confirm the closure boundary"
        )
      ]
    )
    await #expect(throws: PersistenceError.self) {
      try await store.closeEpic(id: epic.id)
    }
    let proposal = try #require(batch.suggestions.first)
    _ = try await store.decideTicketSuggestion(id: proposal.id, decision: .rejected)

    let closed = try await store.closeEpic(id: epic.id)
    #expect(closed.status == .closed)
    await #expect(throws: PersistenceError.self) {
      try await store.updateEpic(
        id: epic.id,
        title: epic.title,
        goal: epic.goal,
        successCriteria: [],
        constraints: ""
      )
    }
    await #expect(throws: PersistenceError.self) {
      try await store.createWorkItem(
        productID: product.id,
        title: "Extend a closed outcome",
        epicID: epic.id
      )
    }
    let ungrouped = try await store.createWorkItem(
      productID: product.id,
      title: "Keep new scope outside the closed outcome"
    )
    await #expect(throws: PersistenceError.self) {
      try await store.assignWorkItemToEpic(id: ungrouped.id, epicID: epic.id)
    }
    await #expect(throws: PersistenceError.self) {
      try await store.beginTicketSuggestionSession(
        productID: product.id,
        epicID: epic.id
      )
    }

    let reopened = try await store.reopenEpic(id: epic.id)
    #expect(reopened.status == .open)
    let followUp = try await store.assignWorkItemToEpic(id: ungrouped.id, epicID: epic.id)
    #expect(followUp.epicID == epic.id)

    let activity = try await store.fetchActivity(productID: product.id)
    #expect(activity.map(\.kind).contains("epic.closed"))
    #expect(activity.map(\.kind).contains("epic.reopened"))
    await store.close()
  }

  @Test("Epic planning conversations survive restart")
  func epicPlanningConversationsAreDurable() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Epic conversation"
    )
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Customers can receive location-specific alerts"
    )
    let audienceQuestion = TicketRefinementQuestion(
      prompt: "Who should receive an alert?",
      options: ["Every visitor", "Signed-in customers"]
    )
    let timingQuestion = TicketRefinementQuestion(
      prompt: "When should the alert be sent?",
      options: ["Immediately", "Daily summary"]
    )
    let snapshot = EpicPlanningConversationSnapshot(
      epicID: epic.id,
      messages: [
        EpicPlanningConversationMessage(
          id: UUID(uuidString: "08C990D8-5081-43C1-A5FE-A41DDE31D960")!,
          author: .businessAnalyst,
          body: "I need to clarify the audience.",
          createdAt: Date(timeIntervalSince1970: 1_728_000_000)
        ),
        EpicPlanningConversationMessage(
          id: UUID(uuidString: "02B804D4-8064-429D-9811-45FC0274DD89")!,
          author: .owner,
          body: "",
          createdAt: Date(timeIntervalSince1970: 1_728_000_010),
          answeredQuestions: [
            EpicPlanningAnsweredQuestion(
              question: audienceQuestion,
              selectedOption: "Signed-in customers",
              answer: "Signed-in customers"
            )
          ]
        ),
        EpicPlanningConversationMessage(
          id: UUID(uuidString: "566720CF-3398-493A-B52F-9009B987C426")!,
          author: .owner,
          body: "@UX designer Which existing pattern should we reuse?",
          createdAt: Date(timeIntervalSince1970: 1_728_000_015),
          kind: .chat,
          participantID: UUID(uuidString: "395FCA59-DA75-4B34-882F-F8B5FE547CD7"),
          participantName: "UX designer"
        ),
      ],
      questions: [timingQuestion],
      isComplete: false,
      threadID: "thread-epic-planning",
      updatedAt: Date(timeIntervalSince1970: 1_728_000_020)
    )
    try await store.saveEpicPlanningConversation(snapshot)
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    #expect(try await reopened.fetchEpicPlanningConversation(epicID: epic.id) == snapshot)
    try await reopened.deleteEpicPlanningConversation(epicID: epic.id)
    #expect(try await reopened.fetchEpicPlanningConversation(epicID: epic.id) == nil)
    await reopened.close()
  }

  @Test("Archiving an epic archives unfinished tickets and preserves delivered work")
  func archivingEpicArchivesUnfinishedTickets() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Epic planning"
    )
    let first = try await store.createEpic(productID: product.id, outcome: "First outcome")
    let second = try await store.createEpic(productID: product.id, outcome: "Second outcome")
    let third = try await store.createEpic(productID: product.id, outcome: "Third outcome")
    let ticket = try await store.createWorkItem(
      productID: product.id,
      title: "Deliver the second outcome",
      type: .story,
      acceptanceCriteria: ["The outcome is observable"],
      epicID: second.id
    )
    let deliveredTicket = try await store.createWorkItem(
      productID: product.id,
      title: "Deliver an earlier part of the second outcome",
      type: .story,
      acceptanceCriteria: ["The earlier outcome remains recorded"],
      epicID: second.id
    )
    for state in [
      WorkItemState.refining, .ready, .queued, .running, .integrating, .verifying,
      .acceptance, .readyToRelease, .released,
    ] {
      _ = try await store.transitionWorkItem(
        id: deliveredTicket.id,
        to: state,
        actor: "Test",
        reason: "Prepare delivered history"
      )
    }
    let suggestionSession = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: second.id
    )
    _ = try await store.completeTicketSuggestionSession(
      sessionID: suggestionSession.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S2",
          title: "Propose another part of the outcome",
          body: "This proposal should leave the active backlog with its epic.",
          acceptanceCriteria: ["The proposal is no longer active"],
          suggestedRole: .businessAnalyst,
          priority: .normal,
          rationale: "Complete the outcome"
        ),
        TicketSuggestionDraft(
          reference: "S3",
          title: "Propose the final part of the outcome",
          body: "This proposal should also be archived with its epic.",
          acceptanceCriteria: ["The proposal is no longer active"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "Finish the outcome"
        ),
      ]
    )

    let reordered = try await store.moveEpics(ids: [third.id], before: first.id)
    #expect(
      reordered.filter { $0.status != .archived }.map(\.id)
        == [third.id, first.id, second.id]
    )

    try await store.archiveEpic(id: second.id)
    let archived = try #require(
      try await store.fetchEpics(productID: product.id).first { $0.id == second.id }
    )
    #expect(archived.status == .archived)
    let storedTickets = try await store.fetchWorkItems(productID: product.id)
    let archivedTicket = try #require(storedTickets.first { $0.id == ticket.id })
    #expect(archivedTicket.state == .cancelled)
    #expect(archivedTicket.epicID == second.id)
    let storedDeliveredTicket = try #require(
      storedTickets.first { $0.id == deliveredTicket.id }
    )
    #expect(storedDeliveredTicket.state == .released)
    #expect(storedDeliveredTicket.epicID == second.id)
    let archivedSuggestions = try #require(
      try await store.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(archivedSuggestions.session.status == .cancelled)
    #expect(archivedSuggestions.suggestions.count == 2)
    #expect(archivedSuggestions.suggestions.allSatisfy { $0.status == .rejected })
    let activity = try await store.fetchActivity(workItemID: ticket.id)
    #expect(activity.first?.kind == "work_item.archived")
    let productActivity = try await store.fetchActivity(productID: product.id)
    #expect(
      productActivity.filter { $0.kind == "ticket_suggestion.rejected" }.map(\.detail)
        == [
          "Propose the final part of the outcome",
          "Propose another part of the outcome",
        ]
    )
    await #expect(throws: PersistenceError.self) {
      try await store.assignWorkItemToEpic(id: ticket.id, epicID: second.id)
    }
    await store.close()
  }

  @Test("Archiving an epic cancels suggestion generation before proposals can arrive")
  func archivingEpicCancelsSuggestionGeneration() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Generating proposals"
    )
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Retire this outcome"
    )
    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )

    try await store.archiveEpic(id: epic.id)
    let batch = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "Late proposal",
          body: "This result arrived after the epic was archived.",
          acceptanceCriteria: ["It does not enter the backlog"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "Late result"
        )
      ]
    )

    #expect(batch.session.status == .cancelled)
    #expect(batch.suggestions.isEmpty)
    await store.close()
  }

  @Test("Archiving an epic refuses to cancel tickets in active delivery")
  func archivingEpicRejectsActiveDeliveryTickets() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Active delivery"
    )
    let epic = try await store.createEpic(productID: product.id, outcome: "Deliver safely")
    let ticket = try await store.createWorkItem(
      productID: product.id,
      title: "Work already queued for delivery",
      type: .story,
      acceptanceCriteria: ["Live delivery is not cancelled implicitly"],
      epicID: epic.id
    )
    for state in [WorkItemState.refining, .ready, .queued] {
      _ = try await store.transitionWorkItem(
        id: ticket.id,
        to: state,
        actor: "Test",
        reason: "Prepare active delivery"
      )
    }

    await #expect(throws: PersistenceError.self) {
      try await store.archiveEpic(id: epic.id)
    }
    let preservedEpic = try #require(
      try await store.fetchEpics(productID: product.id).first { $0.id == epic.id }
    )
    #expect(preservedEpic.status == .open)
    let preservedTicket = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == ticket.id }
    )
    #expect(preservedTicket.state == .queued)
    await store.close()
  }

  @Test("Suggested tickets can depend on existing backlog work")
  func suggestionsCanDependOnExistingWork() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Incremental backlog"
    )
    let existing = try await store.createWorkItem(
      productID: product.id,
      title: "Define the shared data contract",
      type: .task,
      acceptanceCriteria: ["The contract is approved"]
    )
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    let batch = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Implement the missing consumer",
          body: "Use the existing data contract.",
          acceptanceCriteria: ["The consumer uses the approved contract"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This completes the existing flow.",
          dependsOnExistingWorkItemKeys: [existing.key]
        )
      ]
    )
    let suggestion = try #require(batch.suggestions.first)
    #expect(suggestion.existingDependencyWorkItemIDs == [existing.id])

    _ = try await store.decideTicketSuggestion(id: suggestion.id, decision: .accepted)
    let accepted = try #require(
      await store.fetchWorkItems(productID: product.id).first { $0.id != existing.id }
    )
    let dependencies = try await store.fetchWorkItemDependencies(productID: product.id)
    #expect(
      dependencies.contains(
        WorkItemDependency(
          workItemID: accepted.id,
          dependsOnWorkItemID: existing.id
        )
      )
    )
    await store.close()
  }

  @Test("Custom personas retain governed capabilities and can be safely archived")
  func customPersonas() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Custom team")
    _ = try await store.seedDefaultProfiles(productID: product.id)
    let security = try await store.createCustomAgentProfile(
      productID: product.id,
      name: "Security Auditor",
      capability: .reviewer,
      model: "gpt-5.6-sol",
      reasoningEffort: "high",
      instructions: "Build a threat model and report evidence-backed findings."
    )

    #expect(!security.isBuiltIn)
    #expect(security.role == .reviewer)
    #expect(security.customInstructions?.contains("threat model") == true)
    #expect(try await store.fetchAgentProfiles(productID: product.id).last?.id == security.id)

    let audit = try await readyItem(
      in: store,
      productID: product.id,
      title: "Audit a protected feature"
    )
    _ = try await store.assignWorkItemOwner(id: audit.id, profileID: security.id)
    _ = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Use the specialist selected for the ticket artifact",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: audit.id,
          implementerProfileID: security.id
        )
      ]
    )
    let ownedAudit = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == audit.id }
    )
    #expect(ownedAudit.ownerProfileID == security.id)

    _ = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Clear draft scope",
      tokenBudgetLimit: nil,
      items: []
    )
    try await store.archiveCustomAgentProfile(id: security.id)
    let activeProfiles = try await store.fetchAgentProfiles(productID: product.id)
    #expect(!activeProfiles.contains { $0.id == security.id })
    #expect(activeProfiles.count == 4)
    let activity = try await store.fetchActivity(productID: product.id)
    #expect(activity.map(\.kind).contains("team.custom_persona_created"))
    #expect(activity.map(\.kind).contains("team.custom_persona_archived"))
    await store.close()
  }

  @Test("Ticket edits, custom fields, and rank survive restart")
  func editableTicketDetailsAreDurable() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Ticket details")
    let item = try await store.createWorkItem(productID: product.id, title: "Draft title")

    let updated = try await store.updateWorkItem(
      id: item.id,
      title: "Show a useful forecast",
      type: .story,
      body: "The owner needs a reviewable weather result.",
      acceptanceCriteria: ["A searched location shows current conditions"],
      priority: .high,
      customFields: ["Provider": "To be selected", "Market": "UK"]
    )

    #expect(updated.version == 2)
    #expect(updated.rank == 1_000)
    #expect(updated.customFields["Provider"] == "To be selected")

    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      try await reopened.fetchWorkItems(productID: product.id).first
    )
    #expect(recovered.title == "Show a useful forecast")
    #expect(recovered.acceptanceCriteria == ["A searched location shows current conditions"])
    #expect(recovered.customFields == ["Provider": "To be selected", "Market": "UK"])
    #expect(recovered.rank == 1_000)
    await reopened.close()
  }

  @Test("Backlog rank follows dependency order and rejects invalid shortcuts")
  func dependencyAwareRanking() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Safe rank")
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    let batch = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Choose the weather provider",
          type: .task,
          body: "Compare providers.",
          acceptanceCriteria: ["A provider is selected"],
          suggestedRole: .businessAnalyst,
          priority: .high,
          rationale: "The implementation needs a data contract."
        ),
        TicketSuggestionDraft(
          reference: "T2",
          title: "Build the forecast",
          type: .story,
          body: "Implement the UI.",
          acceptanceCriteria: ["A forecast is visible"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This creates the user outcome.",
          dependsOnReferences: ["T1"]
        ),
      ]
    )
    let prerequisiteSuggestion = try #require(batch.suggestions.first { $0.reference == "T1" })
    let dependentSuggestion = try #require(batch.suggestions.first { $0.reference == "T2" })

    _ = try await store.decideTicketSuggestion(id: dependentSuggestion.id, decision: .accepted)
    _ = try await store.decideTicketSuggestion(id: prerequisiteSuggestion.id, decision: .accepted)

    let ordered = try await store.fetchWorkItems(productID: product.id)
    #expect(ordered.map(\.title) == ["Choose the weather provider", "Build the forecast"])
    let prerequisite = try #require(ordered.first)
    let dependent = try #require(ordered.last)

    await #expect(throws: WorkItemRankingError.self) {
      _ = try await store.moveWorkItem(id: dependent.id, to: .top)
    }
    await #expect(throws: WorkItemRankingError.self) {
      _ = try await store.moveWorkItem(id: prerequisite.id, to: .bottom)
    }
    await #expect(throws: WorkItemRankingError.self) {
      _ = try await store.moveWorkItems(ids: [dependent.id], before: prerequisite.id)
    }
    #expect(try await store.fetchWorkItems(productID: product.id).map(\.id) == ordered.map(\.id))

    let independent = try await store.createWorkItem(
      productID: product.id,
      title: "Document the selected provider"
    )
    let reordered = try await store.moveWorkItems(ids: [independent.id], before: dependent.id)
    #expect(reordered.map(\.id) == [prerequisite.id, independent.id, dependent.id])
    await store.close()
  }

  @Test("Scoping stays unassigned until sprint planning saves an implementer")
  func candidateSprintDefinesPlanningScope() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Planning intent")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Build the selected outcome",
      acceptanceCriteria: ["The owner can review the outcome"]
    )
    #expect(item.state == .backlog)

    let assignedItem = try await store.assignWorkItemOwner(
      id: item.id,
      profileID: implementer.id
    )
    #expect(assignedItem.ownerProfileID == implementer.id)
    let unassignedItem = try await store.assignWorkItemOwner(
      id: item.id,
      profileID: nil
    )
    #expect(unassignedItem.ownerProfileID == nil)

    let unassignedDraft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Deliver the next valuable increment",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: item.id)
      ]
    )
    #expect(unassignedDraft.items.first?.implementerProfileID == nil)
    let unassignedIssues = try await store.sprintReadinessIssues(
      sprintID: unassignedDraft.sprint.id
    )
    #expect(unassignedIssues.map(\.id).contains("\(item.id).implementer"))
    #expect(
      unassignedIssues.contains {
        $0.workItemID == item.id
          && $0.message == "\(item.key) needs a valid delivery owner."
      }
    )

    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: unassignedDraft.sprint.goal,
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    #expect(try await store.sprintReadinessIssues(sprintID: draft.sprint.id).isEmpty)

    let active = try await store.startSprint(id: draft.sprint.id)
    #expect(active.sprint.state == .active)
    let startedItem = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(startedItem.state == .queued)
    await store.close()
  }

  @Test("Owner-managed blockers are durable, cycle-safe, and affect sprint readiness")
  func ownerManagedBlockers() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Blocker safety"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let prerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Choose the provider",
      acceptanceCriteria: ["A provider is approved"]
    )
    let dependent = try await store.createWorkItem(
      productID: product.id,
      title: "Build the live forecast",
      acceptanceCriteria: ["Live weather is visible"],
      dependsOnWorkItemIDs: [prerequisite.id]
    )

    let ordered = try await store.fetchWorkItems(productID: product.id)
    #expect(ordered.map(\.id) == [prerequisite.id, dependent.id])
    #expect(
      try await store.fetchWorkItemDependencies(productID: product.id)
        == [
          WorkItemDependency(
            workItemID: dependent.id,
            dependsOnWorkItemID: prerequisite.id
          )
        ]
    )

    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Do not omit unfinished prerequisites",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: dependent.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let issues = try await store.sprintReadinessIssues(sprintID: draft.sprint.id)
    #expect(issues.contains { $0.id.contains("dependency") })

    await #expect(throws: PersistenceError.self) {
      _ = try await store.updateWorkItem(
        id: prerequisite.id,
        title: "This update must roll back",
        type: prerequisite.type,
        body: prerequisite.body,
        acceptanceCriteria: prerequisite.acceptanceCriteria,
        priority: prerequisite.priority,
        customFields: prerequisite.customFields,
        dependsOnWorkItemIDs: [dependent.id]
      )
    }
    let afterRejectedCycle = try await store.fetchWorkItems(productID: product.id)
    #expect(afterRejectedCycle.first { $0.id == prerequisite.id }?.title == "Choose the provider")
    #expect(try await store.fetchWorkItemDependencies(productID: product.id).count == 1)

    _ = try await store.updateWorkItem(
      id: dependent.id,
      title: dependent.title,
      type: dependent.type,
      body: dependent.body,
      acceptanceCriteria: dependent.acceptanceCriteria,
      priority: dependent.priority,
      customFields: dependent.customFields,
      dependsOnWorkItemIDs: []
    )
    #expect(try await store.fetchWorkItemDependencies(productID: product.id).isEmpty)

    try await store.archiveWorkItem(id: dependent.id)
    let archived = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == dependent.id }
    )
    #expect(archived.state == .cancelled)
    #expect(try await store.fetchCurrentSprint(productID: product.id)?.items.isEmpty == true)
    await store.close()
  }

  @Test("Bulk archive is atomic and permits selected dependency groups")
  func bulkArchiveWorkItems() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Bulk archive"
    )
    let prerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Choose an approach"
    )
    let dependent = try await store.createWorkItem(
      productID: product.id,
      title: "Implement the approach",
      dependsOnWorkItemIDs: [prerequisite.id]
    )

    await #expect(throws: PersistenceError.self) {
      try await store.archiveWorkItems(ids: [prerequisite.id])
    }
    let afterRejectedArchive = try await store.fetchWorkItems(productID: product.id)
    #expect(afterRejectedArchive.first { $0.id == prerequisite.id }?.state == .backlog)
    #expect(afterRejectedArchive.first { $0.id == dependent.id }?.state == .backlog)

    try await store.archiveWorkItems(ids: [prerequisite.id, dependent.id])
    let archived = try await store.fetchWorkItems(productID: product.id)
      .filter { [prerequisite.id, dependent.id].contains($0.id) }
    #expect(archived.count == 2)
    #expect(archived.allSatisfy { $0.state == .cancelled })
    await store.close()
  }

  @Test("Knowledge pages cannot use a parent from another product")
  func knowledgePageParentMustShareProduct() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let first = try await store.createProduct(name: "First product")
    let second = try await store.createProduct(name: "Second product")
    let parent = try await store.createKnowledgePage(
      productID: first.id,
      parentID: nil,
      title: "First product parent"
    )

    await #expect(throws: PersistenceError.self) {
      _ = try await store.createKnowledgePage(
        productID: second.id,
        parentID: parent.id,
        title: "Invalid child"
      )
    }
    #expect(try await store.fetchKnowledgePages(productID: second.id).isEmpty)
    await store.close()
  }

  @Test("Knowledge pages are seeded, versioned, and delivery notes are verified")
  func knowledgeBaseLifecycle() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Knowledge product")
    let pages = try await store.seedKnowledgeBase(productID: product.id)
    #expect(pages.contains { $0.slug == "home" })
    #expect(pages.contains { $0.slug == "architecture" })
    #expect(pages.contains { $0.slug == "ways-of-working" })
    #expect(pages.contains { $0.slug == "delivery-history" })
    #expect(pages.allSatisfy { !$0.bodyMarkdown.hasPrefix("# ") })
    let emptySeedSlugs = Set([
      "overview",
      "users-and-journeys",
      "product-principles",
      "glossary",
      "architecture",
      "components-and-data",
      "integrations",
      "environments",
      "runbooks",
      "release-and-rollback",
    ])
    #expect(
      pages
        .filter { emptySeedSlugs.contains($0.slug) }
        .allSatisfy { $0.bodyMarkdown.isEmpty }
    )

    let overview = try #require(pages.first { $0.slug == "overview" })
    _ = try await store.updateKnowledgePage(
      id: overview.id,
      title: overview.title,
      bodyMarkdown: "# Overview\n\nA verified product fact.",
      authorName: "Me",
      changeSummary: "Added the product fact"
    )
    let updatedOverview = try #require(
      try await store.fetchKnowledgePages(productID: product.id).first { $0.id == overview.id }
    )
    #expect(updatedOverview.bodyMarkdown == "A verified product fact.")
    #expect(try await store.fetchKnowledgePageRevisions(pageID: overview.id).count == 2)

    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Ship the outcome",
      acceptanceCriteria: ["The result is visible"]
    )
    let sprint = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Ship and document",
      tokenBudgetLimit: nil,
      items: [SprintDraftItemInput(workItemID: item.id)]
    ).sprint
    let delivery = try await store.upsertDeliveryNote(
      productID: product.id,
      sprint: sprint,
      item: item,
      bodyMarkdown: "# Delivery\n\nWhat changed.",
      authorName: "Implementer"
    )
    #expect(delivery.verificationStatus == .proposed)
    #expect(delivery.bodyMarkdown == "What changed.")

    try await store.verifyDeliveryNote(workItemID: item.id, authorName: "Tech lead")
    let verified = try #require(
      try await store.fetchKnowledgePages(productID: product.id)
        .first { $0.sourceWorkItemID == item.id }
    )
    #expect(verified.verificationStatus == .verified)
    #expect(try await store.fetchKnowledgePageRevisions(pageID: verified.id).count == 2)
    await store.close()
  }

  @Test("Knowledge seeding backfills mandatory operational pages for existing products")
  func knowledgeSeedingBackfillsMandatoryOperationalPages() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Existing knowledge"
    )
    let existingPage = try await store.createKnowledgePage(
      productID: product.id,
      parentID: nil,
      title: "Existing notes"
    )

    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let operations = try #require(pages.first { $0.slug == "operations" })
    let environments = try #require(pages.first { $0.slug == "environments" })
    let waysOfWorking = try #require(pages.first { $0.slug == "ways-of-working" })

    #expect(pages.contains { $0.id == existingPage.id })
    #expect(operations.kind == .section)
    #expect(environments.parentID == operations.id)
    #expect(environments.bodyMarkdown.isEmpty)
    #expect(waysOfWorking.parentID == operations.id)

    let reseeded = try await store.seedKnowledgeBase(productID: product.id)
    #expect(reseeded.filter { $0.slug == "operations" }.count == 1)
    #expect(reseeded.filter { $0.slug == "environments" }.count == 1)
    #expect(reseeded.filter { $0.slug == "ways-of-working" }.count == 1)
    await store.close()
  }

  @Test("Delivery note revisions do not overwrite other knowledge from the same ticket")
  func deliveryNoteUpdatesSelectTheDeliveryNoteKind() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Knowledge provenance"
    )
    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let technical = try #require(
      pages.first { $0.parentID == nil && $0.slug == "technical" }
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Document the forecast"
    )
    let sprint = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Keep the handoff accurate",
      tokenBudgetLimit: nil,
      items: [SprintDraftItemInput(workItemID: item.id)]
    ).sprint
    let delivery = try await store.upsertDeliveryNote(
      productID: product.id,
      sprint: sprint,
      item: item,
      bodyMarkdown: "Initial delivery note.",
      authorName: "Implementer"
    )
    let canonical = try await store.createKnowledgePage(
      productID: product.id,
      parentID: technical.id,
      title: "Forecast guidance"
    )
    _ = try await store.updateKnowledgePage(
      id: canonical.id,
      title: canonical.title,
      bodyMarkdown: "Canonical guidance contract.",
      authorName: "Product owner",
      changeSummary: "Recorded the reusable contract"
    )
    await store.close()

    try fixture.execute(
      """
      UPDATE knowledge_pages
      SET source_work_item_id = '\(item.id.uuidString)',
          sort_order = -1
      WHERE id = '\(canonical.id.uuidString)';
      """
    )

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let updatedDelivery = try await reopened.upsertDeliveryNote(
      productID: product.id,
      sprint: sprint,
      item: item,
      bodyMarkdown: "Revised delivery note.",
      authorName: "Implementer"
    )
    #expect(updatedDelivery.id == delivery.id)
    #expect(updatedDelivery.kind == .deliveryNote)
    #expect(updatedDelivery.bodyMarkdown == "Revised delivery note.")

    try await reopened.verifyDeliveryNote(workItemID: item.id, authorName: "Tech lead")
    let updatedPages = try await reopened.fetchKnowledgePages(productID: product.id)
    let storedDelivery = try #require(updatedPages.first { $0.id == delivery.id })
    let storedCanonical = try #require(updatedPages.first { $0.id == canonical.id })
    #expect(storedDelivery.verificationStatus == .verified)
    #expect(storedCanonical.bodyMarkdown == "Canonical guidance contract.")
    #expect(storedCanonical.verificationStatus == .verified)
    await reopened.close()
  }

  @Test("Product owner action ideas are appended during a sprint and frozen for synthesis")
  func productOwnerRetrospectiveActionIdeaCapture() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Feedback product"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver one outcome"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Capture feedback during delivery",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)

    let actionIdea = try await store.captureRetrospectiveActionIdea(
      productID: product.id,
      sprintID: active.sprint.id,
      body: "  Check external dependencies before delivery starts  "
    )

    #expect(actionIdea.authorName == "Product owner")
    #expect(actionIdea.category == .suggestedAction)
    #expect(actionIdea.body == "Check external dependencies before delivery starts")
    #expect(actionIdea.isActionCandidate)
    #expect(actionIdea.actionStatus == nil)
    #expect(actionIdea.actionDestination == nil)
    #expect(
      try await store.fetchActivity(productID: product.id)
        .count { $0.kind == "retrospective.action_idea_captured" } == 1
    )

    let discardedIdea = try await store.captureRetrospectiveActionIdea(
      productID: product.id,
      sprintID: active.sprint.id,
      body: "Discard this before synthesis"
    )
    try await store.deleteRetrospectiveActionIdea(noteID: discardedIdea.id)
    #expect(
      try await store.fetchRetrospectiveNotes(productID: product.id)
        .contains { $0.id == discardedIdea.id } == false
    )
    #expect(
      try await store.fetchActivity(productID: product.id)
        .count { $0.kind == "retrospective.action_idea_deleted" } == 1
    )

    let teamIdea = RetrospectiveNote(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      profileID: implementer.id,
      authorName: implementer.name,
      category: .suggestedAction,
      body: "Keep team evidence immutable",
      isActionCandidate: true
    )
    try await store.saveRetrospectiveNotes([teamIdea])
    await #expect(throws: PersistenceError.self) {
      try await store.deleteRetrospectiveActionIdea(noteID: teamIdea.id)
    }

    await #expect(throws: PersistenceError.self) {
      _ = try await store.decideRetrospectiveAction(
        noteID: actionIdea.id,
        accept: true
      )
    }

    let completed = try await completeSprint(active, delivering: item, in: store)
    await #expect(throws: PersistenceError.self) {
      _ = try await store.captureRetrospectiveActionIdea(
        productID: product.id,
        sprintID: completed.sprint.id,
        body: "Do not add an action idea after sprint completion"
      )
    }
    await #expect(throws: PersistenceError.self) {
      try await store.deleteRetrospectiveActionIdea(noteID: actionIdea.id)
    }

    let synthesis = try #require(
      try await store.fetchRetrospectiveSyntheses(productID: product.id).first
    )
    _ = try await store.beginRetrospectiveSynthesis(
      id: synthesis.id,
      profileID: analyst.id
    )
    let sources = try await store.fetchRetrospectiveSynthesisSourceNotes(
      synthesisID: synthesis.id
    )
    #expect(
      Set(sources.map(\.id)) == Set([actionIdea.id, teamIdea.id])
    )
    await store.close()
  }

  @Test("Active retrospective actions are read-only until they can become backlog tickets")
  func retrospectiveEvidenceLifecycle() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Learning product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "First delivery"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Learn from delivery",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let action = RetrospectiveNote(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      profileID: implementer.id,
      authorName: implementer.name,
      category: .suggestedAction,
      body: "Document the local preview command",
      actionStatus: .proposed,
      actionDestination: .backlog
    )
    try await store.saveRetrospectiveNotes([action])
    try await store.saveRetrospectiveNotes([action])
    #expect(try await store.fetchRetrospectiveNotes(productID: product.id).count == 1)

    await #expect(throws: PersistenceError.self) {
      _ = try await store.decideRetrospectiveAction(noteID: action.id, accept: true)
    }
    await #expect(throws: PersistenceError.self) {
      _ = try await store.decideRetrospectiveAction(noteID: action.id, accept: false)
    }
    #expect(
      try await store.fetchRetrospectiveNotes(productID: product.id).first?.actionStatus
        == .proposed
    )
    #expect(try await store.fetchWorkItems(productID: product.id).count == 1)

    _ = try await completeSprint(active, delivering: item, in: store)
    let created = try #require(
      try await store.decideRetrospectiveAction(noteID: action.id, accept: true)
    )
    #expect(created.title == action.body)
    #expect(created.type == .task)
    let stored = try #require(
      try await store.fetchRetrospectiveNotes(productID: product.id).first
    )
    #expect(stored.actionStatus == .accepted)
    #expect(stored.actionDestination == .backlog)
    #expect(stored.acceptedWorkItemID == created.id)
    await store.close()
  }

  @Test("Retrospective actions can become inherited ways of working")
  func retrospectivePracticeLifecycle() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Practice product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver an outcome"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Learn from delivery",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let action = RetrospectiveNote(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      authorName: "Tech lead",
      category: .suggestedAction,
      body: "Confirm each candidate contains substantive ticket changes",
      actionStatus: .proposed,
      actionDestination: .teamPractice
    )
    try await store.saveRetrospectiveNotes([action])
    _ = try await completeSprint(active, delivering: item, in: store)

    let created = try await store.decideRetrospectiveAction(
      noteID: action.id,
      accept: true
    )
    #expect(created == nil)
    let page = try #require(
      try await store.fetchKnowledgePages(productID: product.id)
        .first { $0.slug == "ways-of-working" }
    )
    #expect(page.slug == "ways-of-working")
    #expect(page.bodyMarkdown.contains(action.body))
    let stored = try #require(
      try await store.fetchRetrospectiveNotes(productID: product.id).first
    )
    #expect(stored.actionStatus == .accepted)
    #expect(stored.actionDestination == .teamPractice)
    #expect(stored.acceptedWorkItemID == nil)
    #expect(try await store.fetchWorkItems(productID: product.id).count == 1)
    let practiceEvent = try #require(
      try await store.fetchActivity(workItemID: item.id)
        .first { $0.kind == "retrospective.action_promoted_to_practice" }
    )
    #expect(practiceEvent.detail == action.body)

    let duplicate = RetrospectiveNote(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      authorName: "Implementer",
      category: .suggestedAction,
      body: "CONFIRM each candidate contains substantive ticket changes.",
      actionStatus: .proposed,
      actionDestination: .teamPractice
    )
    try await store.saveRetrospectiveNotes([duplicate])
    _ = try await store.decideRetrospectiveAction(noteID: duplicate.id, accept: true)
    let consolidated = try #require(
      try await store.fetchKnowledgePages(productID: product.id)
        .first { $0.slug == "ways-of-working" }
    )
    #expect(
      consolidated.bodyMarkdown
        .components(separatedBy: "substantive ticket changes")
        .count == 2
    )
    #expect(try await store.fetchKnowledgePageRevisions(pageID: consolidated.id).count == 2)
    await store.close()
  }

  @Test("A completed sprint remains open until every retrospective action is decided")
  func retrospectiveConclusionLifecycle() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Closure product"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver one outcome"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Learn from one delivery",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    await #expect(throws: PersistenceError.self) {
      _ = try await store.proposeRetrospectiveAction(
        productID: product.id,
        sprintID: active.sprint.id,
        body: "Review the sprint only after delivery is complete",
        destination: .teamPractice
      )
    }
    for state in [
      WorkItemState.running,
      .integrating,
      .verifying,
      .acceptance,
      .readyToRelease,
      .released,
    ] {
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Test",
        reason: "Complete the delivery"
      )
    }
    let completed = try await store.completeSprintIfFinished(id: active.sprint.id)
    #expect(completed.sprint.state == .completed)
    #expect(completed.sprint.retrospectiveConcludedAt == nil)
    let synthesis = try #require(
      try await store.fetchRetrospectiveSyntheses(productID: product.id).first
    )
    #expect(synthesis.status == .pending)
    await #expect(throws: PersistenceError.self) {
      _ = try await store.proposeRetrospectiveAction(
        productID: product.id,
        sprintID: completed.sprint.id,
        body: "Wait until the team suggestions are ready",
        destination: .teamPractice
      )
    }
    _ = try await store.skipRetrospectiveSynthesis(id: synthesis.id)

    let ownerPractice = try await store.proposeRetrospectiveAction(
      productID: product.id,
      sprintID: completed.sprint.id,
      body: "  Include product owner observations in every retrospective  ",
      destination: .teamPractice
    )
    #expect(ownerPractice.authorName == "Product owner")
    #expect(ownerPractice.body == "Include product owner observations in every retrospective")
    #expect(ownerPractice.actionStatus == .proposed)
    #expect(ownerPractice.actionDestination == .teamPractice)

    let ownerTicket = try await store.proposeRetrospectiveAction(
      productID: product.id,
      sprintID: completed.sprint.id,
      body: "Show whether retrospective actions improved delivery",
      destination: .backlog
    )
    _ = try await store.decideRetrospectiveAction(
      noteID: ownerPractice.id,
      accept: true
    )
    let createdTicket = try #require(
      try await store.decideRetrospectiveAction(
        noteID: ownerTicket.id,
        accept: true
      )
    )
    #expect(createdTicket.title == ownerTicket.body)
    #expect(createdTicket.state == .backlog)
    #expect(
      try await store.fetchActivity(productID: product.id)
        .filter { $0.kind == "retrospective.action_proposed" }
        .count == 2
    )

    let action = RetrospectiveNote(
      productID: product.id,
      sprintID: completed.sprint.id,
      workItemID: item.id,
      profileID: implementer.id,
      authorName: implementer.name,
      category: .suggestedAction,
      body: "Keep the successful check",
      actionStatus: .proposed,
      actionDestination: .teamPractice
    )
    try await store.saveRetrospectiveNotes([action])

    await #expect(throws: PersistenceError.self) {
      _ = try await store.concludeRetrospective(id: completed.sprint.id)
    }
    _ = try await store.decideRetrospectiveAction(noteID: action.id, accept: false)
    let concluded = try await store.concludeRetrospective(id: completed.sprint.id)
    let concludedAt = try #require(concluded.sprint.retrospectiveConcludedAt)
    let repeated = try await store.concludeRetrospective(id: completed.sprint.id)
    #expect(repeated.sprint.retrospectiveConcludedAt == concludedAt)
    await #expect(throws: PersistenceError.self) {
      _ = try await store.decideRetrospectiveAction(noteID: action.id, accept: true)
    }
    await #expect(throws: PersistenceError.self) {
      _ = try await store.proposeRetrospectiveAction(
        productID: product.id,
        sprintID: completed.sprint.id,
        body: "Do not reopen a concluded retrospective",
        destination: .backlog
      )
    }
    #expect(
      try await store.fetchActivity(productID: product.id)
        .filter { $0.kind == "retrospective.concluded" }
        .count == 1
    )
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let historical = try #require(
      try await reopened.fetchSprintHistory(productID: product.id)
        .first { $0.sprint.id == completed.sprint.id }
    )
    #expect(historical.sprint.retrospectiveConcludedAt == concludedAt)
    await reopened.close()
  }

  @Test("Sprint evidence is consolidated into durable sourced retrospective actions")
  func retrospectiveSynthesisLifecycle() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Learning product"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver one outcome"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Learn from repeated validation friction",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let firstCandidate = RetrospectiveNote(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      profileID: implementer.id,
      authorName: implementer.name,
      category: .suggestedAction,
      body: "Keep the approved validation runtime available",
      isActionCandidate: true,
      actionDestination: .teamPractice
    )
    let repeatedCandidate = RetrospectiveNote(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      profileID: implementer.id,
      authorName: implementer.name,
      category: .suggestedAction,
      body: "Ensure final checks can use the configured runtime",
      isActionCandidate: true,
      actionDestination: .teamPractice
    )
    try await store.saveRetrospectiveNotes([firstCandidate, repeatedCandidate])

    let completed = try await completeSprint(active, delivering: item, in: store)
    let pending = try #require(
      try await store.fetchRetrospectiveSyntheses(productID: product.id).first
    )
    #expect(pending.status == .pending)
    await #expect(throws: PersistenceError.self) {
      _ = try await store.concludeRetrospective(id: completed.sprint.id)
    }

    let generating = try await store.beginRetrospectiveSynthesis(
      id: pending.id,
      profileID: analyst.id
    )
    #expect(generating.status == .generating)
    let sources = try await store.fetchRetrospectiveSynthesisSourceNotes(
      synthesisID: pending.id
    )
    #expect(Set(sources.map(\.id)) == Set([firstCandidate.id, repeatedCandidate.id]))

    let actions = try await store.completeRetrospectiveSynthesis(
      id: pending.id,
      actions: [
        RetrospectiveSynthesisActionDraft(
          body: "Make approved validation tools available before delivery begins.",
          destination: .teamPractice,
          expectedEffect:
            "Ticket handoffs include executed checks instead of repeated runtime blockers.",
          sourceNoteIDs: [firstCandidate.id, repeatedCandidate.id]
        )
      ],
      profileID: analyst.id,
      authorName: analyst.name
    )
    let finalAction = try #require(actions.first)
    #expect(finalAction.actionStatus == .proposed)
    #expect(finalAction.expectedEffect?.contains("executed checks") == true)
    #expect(finalAction.synthesisID == pending.id)
    #expect(
      Set(
        try await store.fetchRetrospectiveActionSources(productID: product.id)
          .filter { $0.actionNoteID == finalAction.id }
          .map(\.sourceNoteID)
      ) == Set([firstCandidate.id, repeatedCandidate.id])
    )
    let storedCandidates = try await store.fetchRetrospectiveNotes(productID: product.id)
      .filter(\.isActionCandidate)
    #expect(storedCandidates.count == 2)
    #expect(storedCandidates.allSatisfy { $0.actionStatus == nil })

    _ = try await store.decideRetrospectiveAction(
      noteID: finalAction.id,
      accept: false
    )
    let concluded = try await store.concludeRetrospective(id: completed.sprint.id)
    #expect(concluded.sprint.retrospectiveConcludedAt != nil)
    await store.close()
  }

  @Test("Managed demo sessions are durable and launch-bound")
  func managedDemoSessions() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Demo delivery"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Launch a preview"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Review the real result",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(active.items.first)
    let run = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: item.id,
        implementationRunID: run.id,
        version: 1,
        branchName: "ticket/T1",
        baseSHA: "base",
        headSHA: "head",
        integratedSHA: "integrated",
        worktreePath: "/tmp/t1",
        status: .readyForDemo,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )
    let localCandidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: item.id,
        implementationRunID: run.id,
        version: 2,
        deliveryKind: .localOutcome,
        branchName: "ticket/T1",
        baseSHA: "base",
        headSHA: "base",
        worktreePath: "/tmp/t1",
        status: .queuedForReview,
        commitCount: 0,
        executionResultJSON: "{}"
      )
    )
    #expect(
      try await store.fetchCandidateRevision(id: localCandidate.id).deliveryKind == .localOutcome
    )
    var session = DemoSession(
      productID: product.id,
      launchID: candidate.id,
      status: .starting,
      previewWorktreePath: "/tmp/preview",
      allocatedPort: 8123
    )
    session = try await store.saveDemoSession(session)
    session.status = .ready
    session.output = "Ready"
    session.updatedAt = Date()
    _ = try await store.saveDemoSession(session)
    let importedLaunchID = UUID()
    _ = try await store.saveDemoSession(
      DemoSession(
        productID: product.id,
        sourceKind: .importedRepository,
        launchID: importedLaunchID,
        status: .stopped,
        previewWorktreePath: "/tmp/imported-preview"
      )
    )
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let sessions = try await reopened.fetchDemoSessions(productID: product.id)
    #expect(sessions.count == 2)
    let acceptedSession = try #require(
      sessions.first {
        $0.sourceKind == .acceptedCandidate && $0.launchID == candidate.id
      }
    )
    #expect(acceptedSession.status == .ready)
    #expect(acceptedSession.allocatedPort == 8123)
    #expect(acceptedSession.output == "Ready")
    let importedSession = try #require(
      sessions.first {
        $0.sourceKind == .importedRepository && $0.launchID == importedLaunchID
      }
    )
    #expect(importedSession.status == .stopped)
    #expect(importedSession.previewWorktreePath == "/tmp/imported-preview")
    await reopened.close()
  }

  @Test("Agent permission decisions are durable and pending requests recover safely")
  func agentPermissionRequests() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Permission-aware delivery"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Use a local service"
    )
    let run = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        workItemID: item.id,
        profileID: implementer.id,
        status: .running,
        codexThreadID: "thread-permission",
        worktreePath: "/tmp/ticket"
      )
    )
    let request = AgentPermissionRequest(
      productID: product.id,
      workItemID: item.id,
      agentRunID: run.id,
      threadID: "thread-permission",
      turnID: "turn-permission",
      serverRequestID: "41",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "docker compose up",
      reason: "Start the ticket's local database",
      signature: "command|docker compose up",
      productGrantSignature: "product-command|docker compose up"
    )
    _ = try await store.saveAgentPermissionRequest(request)
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    var requests = try await reopened.fetchAgentPermissionRequests(productID: product.id)
    #expect(requests.count == 1)
    #expect(requests.first?.status == .pending)
    #expect(requests.first?.reason == "Start the ticket's local database")
    #expect(requests.first?.productGrantSignature == request.productGrantSignature)

    try await reopened.interruptPendingAgentPermissionRequests(productID: product.id)
    requests = try await reopened.fetchAgentPermissionRequests(productID: product.id)
    #expect(requests.first?.status == .interrupted)

    let prepared = try await reopened.prepareAgentPermissionResolution(
      requestID: request.id,
      intent: .allowOncePendingDelivery,
      productGrant: nil
    )
    #expect(prepared.request.status == .allowOncePendingDelivery)
    #expect(!prepared.request.status.needsOwnerDecision)
    #expect(
      try await reopened.fetchAgentPermissionRequest(
        agentRunID: run.id,
        serverRequestID: request.serverRequestID,
        signature: request.signature
      )?.id == request.id
    )
    let allowed = try await reopened.acknowledgeAgentPermissionResolution(
      requestID: request.id,
      intent: .allowOncePendingDelivery
    )
    #expect(allowed.status == .allowed)

    let existingAccess = AgentPermissionRequest(
      productID: product.id,
      workItemID: item.id,
      agentRunID: run.id,
      threadID: "thread-permission",
      turnID: "turn-permission",
      serverRequestID: "42",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Read /tmp/ticket/.run-private",
      signature: "permissions|run-private",
      status: .existingAccess
    )
    _ = try await reopened.saveAgentPermissionRequest(existingAccess)
    requests = try await reopened.fetchAgentPermissionRequests(productID: product.id)
    #expect(requests.last?.status == .existingAccess)
    #expect(requests.last?.status.needsOwnerDecision == false)

    let policyDenied = AgentPermissionRequest(
      productID: product.id,
      workItemID: item.id,
      agentRunID: run.id,
      threadID: "thread-permission",
      turnID: "turn-permission",
      serverRequestID: "43",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Write PreviewWorktrees/product",
      signature: "permissions|protected-preview",
      status: .policyDenied
    )
    _ = try await reopened.saveAgentPermissionRequest(policyDenied)
    requests = try await reopened.fetchAgentPermissionRequests(productID: product.id)
    #expect(requests.last?.status == .policyDenied)
    #expect(requests.last?.status.needsOwnerDecision == false)

    let grant = try await reopened.saveAgentPermissionGrant(
      AgentPermissionGrant(
        productID: product.id,
        sourceRequestID: request.id,
        method: request.method,
        kind: request.kind,
        title: request.title,
        detail: request.detail,
        signature: "product-command|docker compose up"
      )
    )
    var grants = try await reopened.fetchAgentPermissionGrants(productID: product.id)
    #expect(grants == [grant])

    let duplicate = try await reopened.saveAgentPermissionGrant(
      AgentPermissionGrant(
        productID: product.id,
        sourceRequestID: request.id,
        method: request.method,
        kind: request.kind,
        title: request.title,
        detail: request.detail,
        signature: grant.signature
      )
    )
    #expect(duplicate.id == grant.id)

    let secondGrant = try await reopened.saveAgentPermissionGrant(
      AgentPermissionGrant(
        productID: product.id,
        sourceRequestID: request.id,
        method: request.method,
        kind: request.kind,
        title: request.title,
        detail: "docker compose ps",
        signature: "product-command|docker compose ps"
      )
    )
    let revoked = try await reopened.revokeAgentPermissionGrants(
      ids: [grant.id, secondGrant.id]
    )
    #expect(revoked.count == 2)
    #expect(revoked.allSatisfy { $0.revokedAt != nil })
    grants = try await reopened.fetchAgentPermissionGrants(productID: product.id)
    #expect(grants.isEmpty)
    let auditGrants = try await reopened.fetchAgentPermissionGrants(
      productID: product.id,
      includeRevoked: true
    )
    #expect(Set(auditGrants.map(\.id)) == [grant.id, secondGrant.id])
    #expect(auditGrants.allSatisfy { $0.revokedAt != nil })

    let replacement = try await reopened.saveAgentPermissionGrant(
      AgentPermissionGrant(
        productID: product.id,
        sourceRequestID: request.id,
        method: request.method,
        kind: request.kind,
        title: request.title,
        detail: request.detail,
        signature: grant.signature
      )
    )
    #expect(replacement.id != grant.id)
    grants = try await reopened.fetchAgentPermissionGrants(productID: product.id)
    #expect(grants == [replacement])
    await reopened.close()
  }

  @Test("Candidate revisions own reviewable canonical knowledge proposals")
  func candidateKnowledgeProposals() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Versioned delivery"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Document the integration"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Ship a traceable candidate",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(active.items.first)
    let run = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: item.id,
        implementationRunID: run.id,
        version: 1,
        branchName: "ticket/T-1",
        baseSHA: "base",
        headSHA: "head",
        worktreePath: "/tmp/t-1",
        commitCount: 2,
        executionResultJSON: "{}"
      )
    )
    #expect(try await store.nextCandidateRevisionVersion(workItemID: item.id) == 2)

    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let overview = try #require(pages.first { $0.slug == "overview" })
    let technical = try #require(
      pages.first { $0.parentID == nil && $0.slug == "technical" }
    )
    try await store.setAgentRunKnowledgeContext(
      runID: run.id,
      pageIDs: [overview.id]
    )
    try await store.setAgentRunKnowledgeDestinations(
      runID: run.id,
      pageIDs: [overview.id, technical.id, overview.id]
    )
    let storedContext = try await store.fetchAgentRunKnowledgeContext(
      productID: product.id
    )
    let storedDestinations = try await store.fetchAgentRunKnowledgeDestinations(
      productID: product.id
    )
    #expect(storedContext == [AgentRunKnowledgePage(runID: run.id, pageID: overview.id)])
    #expect(
      Set(storedDestinations)
        == Set([
          AgentRunKnowledgeDestination(runID: run.id, pageID: overview.id),
          AgentRunKnowledgeDestination(runID: run.id, pageID: technical.id),
        ])
    )
    let update = KnowledgePageProposal(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      candidateRevisionID: candidate.id,
      operation: .update,
      targetPageID: overview.id,
      basePageTitle: overview.title,
      basePageBodyMarkdown: overview.bodyMarkdown,
      basePageUpdatedAt: overview.updatedAt,
      title: overview.title,
      proposedBodyMarkdown: "# Overview\n\nVerified integration details.",
      rationale: "The ticket established the integration boundary."
    )
    let creation = KnowledgePageProposal(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      candidateRevisionID: candidate.id,
      operation: .create,
      parentPageID: technical.id,
      title: "Integration boundary",
      proposedBodyMarkdown: "# Integration boundary\n\nVerified contract.",
      rationale: "This contract is reused by later tickets."
    )
    let staleUpdate = KnowledgePageProposal(
      productID: product.id,
      sprintID: active.sprint.id,
      workItemID: item.id,
      candidateRevisionID: candidate.id,
      operation: .update,
      targetPageID: overview.id,
      basePageTitle: overview.title,
      basePageBodyMarkdown: overview.bodyMarkdown,
      basePageUpdatedAt: overview.updatedAt,
      title: overview.title,
      proposedBodyMarkdown: "# Overview\n\nA stale alternative.",
      rationale: "This must not overwrite a later accepted edit."
    )
    try await store.createKnowledgePageProposals([update, creation, staleUpdate])
    try await store.markKnowledgePageProposals(
      candidateRevisionID: candidate.id,
      status: .reviewed
    )
    _ = try await store.recordKnowledgePageProposalDecision(
      id: update.id,
      accept: true,
      authorName: "Me"
    )
    let unpublishedOverview = try #require(
      try await store.fetchKnowledgePages(productID: product.id)
        .first { $0.id == overview.id }
    )
    #expect(unpublishedOverview.bodyMarkdown == overview.bodyMarkdown)
    _ = try await store.publishKnowledgePageProposal(
      id: update.id,
      authorName: "Me"
    )
    _ = try await store.decideKnowledgePageProposal(
      id: creation.id,
      accept: false,
      authorName: "Me"
    )
    await #expect(throws: PersistenceError.self) {
      _ = try await store.decideKnowledgePageProposal(
        id: staleUpdate.id,
        accept: true,
        authorName: "Me"
      )
    }

    let storedProposals = try await store.fetchKnowledgePageProposals(productID: product.id)
    #expect(storedProposals.first { $0.id == update.id }?.status == .accepted)
    #expect(storedProposals.first { $0.id == creation.id }?.status == .rejected)
    #expect(storedProposals.first { $0.id == staleUpdate.id }?.status == .reviewed)
    let updatedOverview = try #require(
      try await store.fetchKnowledgePages(productID: product.id)
        .first { $0.id == overview.id }
    )
    #expect(updatedOverview.bodyMarkdown.contains("Verified integration details"))
    #expect(!updatedOverview.bodyMarkdown.hasPrefix("# "))
    #expect(updatedOverview.sourceWorkItemID == item.id)
    #expect(
      try await store.fetchKnowledgePageRevisions(pageID: overview.id).first?
        .changeSummary == update.rationale
    )
    await store.close()
  }

  @Test("Owner notifications retain read and resolution state across restart")
  func ownerNotificationLifecyclePersists() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Notification lifecycle")
    let target = OwnerNotificationTarget(kind: .ticket, id: UUID())
    let notification = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: target,
      title: "T1 needs your input",
      body: "Choose the owner-facing behavior.",
      createdAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(try await store.createOwnerNotification(notification))
    #expect(!(try await store.createOwnerNotification(notification)))
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    var active = try await reopened.fetchActiveOwnerNotifications(productID: product.id)
    #expect(active == [notification])

    try await reopened.markOwnerNotificationsRead(productID: product.id, target: target)
    active = try await reopened.fetchActiveOwnerNotifications(productID: product.id)
    #expect(active.count == 1)
    #expect(active.first?.isUnread == false)
    #expect(active.first?.resolvedAt == nil)

    let resolvedIDs = try await reopened.resolveOwnerNotifications(
      productID: product.id,
      target: target
    )
    #expect(resolvedIDs == [notification.id])
    #expect(try await reopened.fetchActiveOwnerNotifications(productID: product.id).isEmpty)
    await reopened.close()
  }

  @Test("Version 11 databases add durable owner notifications")
  func ownerNotificationMigration() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let currentStore = try SQLiteStore(url: fixture.databaseURL)
    let product = try await currentStore.createProduct(name: "Migrated notifications")
    await currentStore.close()
    try fixture.execute(
      """
      DROP TABLE owner_notifications;
      PRAGMA user_version = 11;
      """
    )

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    let notification = OwnerNotification(
      productID: product.id,
      kind: .refinementComplete,
      target: OwnerNotificationTarget(kind: .epic, id: UUID()),
      title: "Epic refinement complete",
      body: "The proposed tickets are ready to review."
    )
    #expect(try await migratedStore.createOwnerNotification(notification))
    let stored = try #require(
      try await migratedStore.fetchActiveOwnerNotifications(productID: product.id).first
    )
    #expect(stored.id == notification.id)
    #expect(stored.kind == notification.kind)
    #expect(stored.target == notification.target)
    #expect(stored.title == notification.title)
    #expect(stored.body == notification.body)
    #expect(stored.isUnread)
    await migratedStore.close()
  }

  @Test("A09 schema migration preserves the complete Product history")
  func a09SchemaMigrationPreservesCompleteProductHistory() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Long-lived Product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })

    let backlogItem = try await store.createWorkItem(
      productID: product.id,
      title: "Preserve the owner backlog",
      body: "Keep the accepted scope intact.",
      acceptanceCriteria: ["The backlog survives every schema upgrade"]
    )
    let workLogBody = "The owner-approved scope must survive migration."
    _ = try await store.appendComment(
      workItemID: backlogItem.id,
      authorKind: .owner,
      authorName: "Me",
      body: workLogBody
    )

    let seededPages = try await store.seedKnowledgeBase(productID: product.id)
    let overview = try #require(seededPages.first { $0.slug == "overview" })
    let knowledgeBody = "The Product preserves its complete local history."
    _ = try await store.updateKnowledgePage(
      id: overview.id,
      title: overview.title,
      bodyMarkdown: knowledgeBody,
      authorName: "Me",
      changeSummary: "Recorded the durable migration requirement"
    )

    let repository = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .importedSource,
        accountID: UUID(),
        installationID: 41,
        repositoryID: 42,
        owner: "owner",
        name: "long-lived-product",
        fullName: "owner/long-lived-product",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/long-lived-product.git")!,
        isPrivate: true,
        defaultBranch: "trunk",
        permissions: RemoteRepositoryPermissions(
          metadataRead: true,
          contentsWrite: true,
          pullRequestsWrite: true,
          workflowsWrite: false
        ),
        status: .connected
      )
    )

    let deliveredItem = try await readyItem(
      in: store,
      productID: product.id,
      title: "Retain reviewed delivery evidence"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Preserve durable Product history",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: deliveredItem.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let active = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(active.items.first)
    let implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    _ = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .completed,
      codexThreadID: "thread-before-migration",
      worktreePath: "/tmp/long-lived-product",
      eventActor: implementer.name,
      eventDetail: "Delivered the reviewed candidate"
    )
    var deliveryState = deliveredItem
    for state: WorkItemState in [.running, .integrating, .verifying, .acceptance] {
      deliveryState = try await store.transitionWorkItem(
        id: deliveryState.id,
        to: state,
        actor: "Spedito",
        reason: "Recorded delivery history"
      )
    }
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: active.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: deliveredItem.id,
        implementationRunID: implementationRun.id,
        version: 1,
        branchName: "ticket/\(deliveredItem.key)",
        baseSHA: "base-before-migration",
        headSHA: "head-before-migration",
        worktreePath: "/tmp/\(deliveredItem.key)",
        status: .readyForDemo,
        commitCount: 1,
        executionResultJSON: #"{"summary":"Reviewed delivery"}"#
      )
    )
    await store.close()

    try fixture.execute(
      """
      ALTER TABLE candidate_revisions DROP COLUMN delivery_kind;
      DROP INDEX IF EXISTS idx_repository_knowledge_runs_one_active;
      DROP TABLE owner_notifications;
      PRAGMA user_version = 7;
      """
    )

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    #expect(try fixture.scalarInt("PRAGMA user_version;") == ProductDatabaseSchema.version)

    let migratedProducts = try await migratedStore.fetchProducts()
    #expect(migratedProducts.map(\.id) == [product.id])
    #expect(migratedProducts.map(\.name) == ["Long-lived Product"])

    let migratedItems = try await migratedStore.fetchWorkItems(productID: product.id)
    #expect(migratedItems.first { $0.id == backlogItem.id }?.state == .backlog)
    #expect(
      migratedItems.first { $0.id == backlogItem.id }?.acceptanceCriteria
        == ["The backlog survives every schema upgrade"]
    )
    #expect(migratedItems.first { $0.id == deliveredItem.id }?.state == .acceptance)
    #expect(
      try await migratedStore.fetchComments(workItemID: backlogItem.id).map(\.body)
        == [workLogBody]
    )

    let migratedKnowledge = try #require(
      try await migratedStore.fetchKnowledgePages(productID: product.id)
        .first { $0.id == overview.id }
    )
    #expect(migratedKnowledge.bodyMarkdown == knowledgeBody)
    #expect(
      try await migratedStore.fetchKnowledgePageRevisions(pageID: overview.id).count == 2
    )

    let migratedRepository = try #require(
      try await migratedStore.fetchRemoteRepositoryConnection(productID: product.id)
    )
    #expect(migratedRepository.id == repository.id)
    #expect(migratedRepository.fullName == "owner/long-lived-product")
    #expect(migratedRepository.defaultBranch == "trunk")
    #expect(migratedRepository.status == .connected)

    let migratedCandidate = try #require(
      try await migratedStore.fetchCandidateRevisions(productID: product.id)
        .first { $0.id == candidate.id }
    )
    #expect(migratedCandidate.deliveryKind == .repositoryChange)
    #expect(migratedCandidate.status == .readyForDemo)
    #expect(migratedCandidate.headSHA == "head-before-migration")
    let migratedRun = try #require(
      try await migratedStore.fetchAgentRuns(productID: product.id)
        .first { $0.id == implementationRun.id }
    )
    #expect(migratedRun.status == .completed)
    #expect(migratedRun.codexThreadID == "thread-before-migration")
    #expect(
      try await migratedStore.fetchActivity(workItemID: deliveredItem.id)
        .contains { $0.kind == "work_item.transitioned" }
    )
    await migratedStore.close()
  }

  @Test("Version 12 databases remove redundant empty GitHub review entries")
  func emptyGitHubReviewMigration() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let currentStore = try SQLiteStore(url: fixture.databaseURL)
    let product = try await currentStore.createProduct(name: "Migrated GitHub reviews")
    let ticket = try await currentStore.createWorkItem(
      productID: product.id,
      title: "Review GitHub feedback"
    )
    let reviewURL = try #require(
      URL(string: "https://github.com/example/product/pull/3#pullrequestreview-73")
    )
    let commentURL = try #require(
      URL(string: "https://github.com/example/product/pull/3#discussion_r72")
    )
    _ = try await currentStore.appendExternalCommentIfNeeded(
      workItemID: ticket.id,
      authorName: "reviewer",
      body: "GitHub review: Review comment.",
      authorAvatarURL: nil,
      externalURL: reviewURL,
      externalID: "github:91:3:review:73",
      createdAt: Date(timeIntervalSince1970: 1_786_787_808)
    )
    _ = try await currentStore.appendExternalCommentIfNeeded(
      workItemID: ticket.id,
      authorName: "reviewer",
      body: "Why is this all inline?",
      authorAvatarURL: nil,
      externalURL: commentURL,
      externalID: "github:91:3:comment:72",
      createdAt: Date(timeIntervalSince1970: 1_786_787_808)
    )
    await currentStore.close()
    try fixture.execute("PRAGMA user_version = 12;")

    let migratedStore = try SQLiteStore(url: fixture.databaseURL)
    let comments = try await migratedStore.fetchComments(workItemID: ticket.id)
    #expect(comments.map(\.body) == ["Why is this all inline?"])
    await migratedStore.close()
  }

  private func readyItem(
    in store: SQLiteStore,
    productID: UUID,
    title: String
  ) async throws -> WorkItem {
    let item = try await store.createWorkItem(
      productID: productID,
      title: title,
      acceptanceCriteria: ["The outcome is visible"]
    )
    _ = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    return try await store.transitionWorkItem(
      id: item.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )
  }

  private func completeSprint(
    _ active: SprintPlan,
    delivering item: WorkItem,
    in store: SQLiteStore
  ) async throws -> SprintPlan {
    for state in [
      WorkItemState.running,
      .integrating,
      .verifying,
      .acceptance,
      .readyToRelease,
      .released,
    ] {
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Test",
        reason: "Complete the delivery"
      )
    }
    return try await store.completeSprintIfFinished(id: active.sprint.id)
  }
}

private struct DatabaseFixture {
  let directoryURL: URL
  let databaseURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    databaseURL = directoryURL.appendingPathComponent("test.sqlite")
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func execute(_ sql: String) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open(databaseURL.path, &database)
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw PersistenceError.sqlite(code: openResult, message: "Could not open test database")
    }
    defer { sqlite3_close(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "Could not execute test SQL"
      sqlite3_free(errorMessage)
      throw PersistenceError.sqlite(code: result, message: message)
    }
  }

  func scalarInt(_ sql: String) throws -> Int32 {
    var database: OpaquePointer?
    let openResult = sqlite3_open(databaseURL.path, &database)
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw PersistenceError.sqlite(code: openResult, message: "Could not open test database")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(
        code: prepareResult,
        message: "Could not prepare scalar test query"
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw PersistenceError.sqlite(
        code: SQLITE_ERROR, message: "Scalar test query returned no row")
    }
    return sqlite3_column_int(statement, 0)
  }
}
