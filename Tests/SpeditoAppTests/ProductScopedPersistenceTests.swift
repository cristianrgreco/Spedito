import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Product-scoped persistence", .serialized)
@MainActor
struct ProductScopedPersistenceTests {
  @Test("A ready epic plan repairs an interrupted conversation snapshot")
  func readyEpicPlanRepairsInterruptedConversation() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Recovered product")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Recover an interrupted epic plan"
    )
    let interruptedSnapshot = EpicPlanningConversationSnapshot(
      epicID: epic.id,
      messages: [
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: "The outcome is ready to plan."
        )
      ],
      questions: [],
      isComplete: false,
      threadID: "recovered-thread"
    )
    try await store.saveEpicPlanningConversation(interruptedSnapshot)
    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    _ = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Deliver the recovered outcome",
          body: "Complete the planned product change.",
          acceptanceCriteria: ["The recovered plan remains reviewable"],
          suggestedRole: .implementer,
          priority: .high,
          rationale: "The durable plan completed before the interruption."
        )
      ]
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )

    await model.restoreEpicPlanningConversation(for: epic)

    let conversation = try #require(model.epicPlanningConversation)
    #expect(conversation.epicID == epic.id)
    #expect(conversation.isComplete)
    #expect(conversation.errorMessage == nil)
    let repairedSnapshot = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(repairedSnapshot.isComplete)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Epic planning snapshots stay with their epic after product selection changes")
  func epicPlanningSnapshotUsesOwningProductStore() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(name: "First product")
    let second = try await registry.createProduct(name: "Second product")
    let firstStore = try #require(registry.store(for: first.id))
    let secondStore = try #require(registry.store(for: second.id))
    let epic = try await firstStore.createEpic(
      productID: first.id,
      outcome: "Keep planning in the first product"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: second.id
    )
    let conversation = EpicPlanningConversationState(
      productID: first.id,
      epicID: epic.id,
      messages: [
        EpicPlanningConversationMessage(
          author: .owner,
          body: "Plan this epic"
        )
      ],
      questions: [],
      hasStartedPlanning: true,
      isRunning: false,
      isGeneratingPlan: true,
      isComplete: false,
      errorMessage: nil
    )

    try await model.saveEpicPlanningConversation(
      conversation,
      threadID: "first-product-thread"
    )

    let saved = try #require(
      try await firstStore.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(saved.messages == conversation.messages)
    #expect(saved.threadID == "first-product-thread")
    #expect(try await secondStore.fetchEpicPlanningConversation(epicID: epic.id) == nil)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Product switches preserve in-flight refinement and epic planning turns")
  func productSelectionPreservesOwnerAgentTurns() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(name: "Planning product")
    let second = try await registry.createProduct(name: "Other product")
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: first.id
    )
    await model.reload()

    let epicGate = ProductSwitchOperationGate()
    model.epicPlanningRuntime.start(productID: first.id) {
      await epicGate.wait()
    }
    let refinementTurn = CodexTurnIdentity(
      threadID: "refinement-thread",
      turnID: "refinement-turn"
    )
    let refinementToken = model.planningConversationRuntime.beginTurn(
      .ticketRefinement,
      productID: first.id,
      threadID: refinementTurn.threadID,
      turnID: refinementTurn.turnID
    )

    await model.selectProduct(second)

    #expect(model.selectedProduct?.id == second.id)
    #expect(model.epicPlanningRuntime.isBusy)
    #expect(
      model.planningConversationRuntime.activeTurn(.ticketRefinement)
        == refinementTurn
    )

    epicGate.open()
    model.planningConversationRuntime.finishTurn(refinementToken)
    await model.epicPlanningRuntime.cancel(productID: first.id) { _ in }
    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Epic, ticket, and work log writes use the entity's owning product")
  func entityWritesUseOwningProductStore() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(name: "First product")
    let second = try await registry.createProduct(name: "Second product")
    let firstStore = try #require(registry.store(for: first.id))
    let secondStore = try #require(registry.store(for: second.id))
    let epic = try await firstStore.createEpic(
      productID: first.id,
      outcome: "Original outcome"
    )
    let item = try await firstStore.createWorkItem(
      productID: first.id,
      title: "Original ticket",
      epicID: epic.id
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: second.id
    )

    let updatedEpic = await model.updateEpic(
      epic,
      title: "Updated epic",
      goal: "Keep the product boundary",
      successCriteria: ["Writes reach the owning database"],
      constraints: "No selection-dependent routing"
    )
    let didUpdateTicket = await model.updateWorkItem(
      productID: first.id,
      id: item.id,
      title: "Updated ticket",
      type: item.type,
      body: "Updated while another product is selected",
      acceptanceCriteria: ["The first product owns the change"],
      priority: item.priority,
      customFields: item.customFields,
      dependsOnWorkItemIDs: [],
      expectedVersion: item.version
    )
    let comment = await model.appendOwnerComment(
      workItemID: item.id,
      productID: first.id,
      body: "This comment belongs to the first product."
    )

    #expect(updatedEpic?.title == "Updated epic")
    #expect(didUpdateTicket)
    #expect(comment?.workItemID == item.id)
    #expect(try await firstStore.fetchEpics(productID: first.id).first?.title == "Updated epic")
    #expect(
      try await firstStore.fetchWorkItems(productID: first.id).first?.title
        == "Updated ticket"
    )
    #expect(
      try await firstStore.fetchComments(workItemID: item.id).map(\.body) == [
        "This comment belongs to the first product."
      ])
    #expect(try await secondStore.fetchEpics(productID: second.id).isEmpty)
    #expect(try await secondStore.fetchWorkItems(productID: second.id).isEmpty)

    for store in registry.allStores {
      await store.close()
    }
  }
  @Test("Verified repository knowledge stays local and leaves Git unchanged")
  func repositoryKnowledgePublicationDoesNotChangeGit() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Imported product")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyzer = try #require(profiles.first { $0.role == .businessAnalyst })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let overview = try #require(pages.first { $0.slug == "overview" })
    let workspace = fixture.workspacesURL.appendingPathComponent(
      product.id.uuidString,
      isDirectory: true
    )
    try Data("# Imported product\n".utf8).write(
      to: workspace.appendingPathComponent("README.md")
    )
    let git = GitWorkspaceManager()
    let analyzedSHA = try await git.ensureRepository(at: workspace)
    try await store.createProductRepository(
      ProductRepository(
        productID: product.id,
        originURL: try #require(URL(string: "https://github.com/example/imported.git")),
        sourceDefaultBranch: "main",
        importedSHA: analyzedSHA
      )
    )
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      analyzedSHA: analyzedSHA,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
    try await store.createRepositoryKnowledgeRun(run)
    let draft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .update,
      targetPageID: overview.id,
      basePageTitle: overview.title,
      basePageBodyMarkdown: overview.bodyMarkdown,
      basePageUpdatedAt: overview.updatedAt,
      title: overview.title,
      proposedBodyMarkdown: "# Overview\n\nVerified without changing the repository.\n",
      rationale: "The imported README establishes the product.",
      evidence: [.init(path: "README.md", startLine: 1, endLine: 1)]
    )
    _ = try await store.recordRepositoryKnowledgeAnalysis(
      runID: run.id,
      summary: "One verified update",
      drafts: [draft],
      analyzerThreadID: "analysis-thread",
      analyzerTurnID: "analysis-turn"
    )
    _ = try await store.recordRepositoryKnowledgeReview(
      runID: run.id,
      summary: "The repository supports the update",
      decisions: [
        .init(
          draftID: draft.id,
          approved: true,
          explanation: "The README supports the product description."
        )
      ],
      reviewerThreadID: "review-thread",
      reviewerTurnID: "review-turn"
    )
    let relaunched = try await fixture.relaunch(
      closing: registry,
      selectedProductID: product.id
    )
    await relaunched.model.awaitRepositoryKnowledgeRecovery(productID: product.id)
    let relaunchedStore = try #require(relaunched.registry.store(for: product.id))

    let completed = try await relaunchedStore.fetchRepositoryKnowledgeRun(id: run.id)
    #expect(completed.status == .completed)
    #expect(try await git.acceptedTrunkSHA(at: workspace) == analyzedSHA)
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent("knowledge", isDirectory: true).path
      )
    )
    let updatedOverview = try #require(
      try await relaunchedStore.fetchKnowledgePages(productID: product.id).first {
        $0.id == overview.id
      }
    )
    #expect(updatedOverview.bodyMarkdown.contains("Verified without changing the repository."))

    await relaunched.close()
  }

  @Test("Completed empty repository analysis waits for an explicit owner retry")
  func completedEmptyRepositoryAnalysisIsTerminal() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Quiet repository")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyzer = try #require(profiles.first { $0.role == .businessAnalyst })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    let analyzedSHA = String(repeating: "a", count: 40)
    try await store.createProductRepository(
      ProductRepository(
        productID: product.id,
        originURL: try #require(URL(string: "https://github.com/example/quiet.git")),
        sourceDefaultBranch: "main",
        importedSHA: analyzedSHA
      )
    )
    let completed = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      purpose: .importedAppLaunch,
      analyzedSHA: analyzedSHA,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id,
      status: .completed,
      analysisSummary: "No durable product knowledge found",
      reviewSummary: "No proposals required publication"
    )
    try await store.createRepositoryKnowledgeRun(completed)

    for _ in 0..<2 {
      let relaunched = AppModel(
        storeRegistry: registry,
        selectedProductID: product.id
      )
      await relaunched.load()
      #expect(
        relaunched.repositoryKnowledgeSnapshot?.completionOutcome == .noPublishableKnowledge
      )
      await relaunched.shutdown()
      #expect(try await store.fetchRepositoryKnowledgeRuns(productID: product.id).count == 1)
    }

    let ownerModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )
    await ownerModel.reload()
    await ownerModel.retryRepositoryKnowledgeAnalysis()
    await ownerModel.retryRepositoryKnowledgeAnalysis()
    await ownerModel.shutdown()

    let runs = try await store.fetchRepositoryKnowledgeRuns(productID: product.id)
    #expect(runs.count == 2)
    let explicitRetry = try #require(runs.first { $0.attempt == 2 })
    #expect(explicitRetry.purpose == completed.purpose)
    #expect(explicitRetry.analyzedSHA == completed.analyzedSHA)
    #expect(try await store.fetchRepositoryKnowledgeRun(id: completed.id).status == .completed)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Completed rejected repository analysis stays terminal across launches")
  func completedRejectedRepositoryAnalysisIsTerminal() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Rejected repository knowledge")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyzer = try #require(profiles.first { $0.role == .businessAnalyst })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    let knowledgePages = try await store.seedKnowledgeBase(productID: product.id)
    let features = try #require(knowledgePages.first { $0.slug == "features" })
    let analyzedSHA = String(repeating: "b", count: 40)
    try await store.createProductRepository(
      ProductRepository(
        productID: product.id,
        originURL: try #require(URL(string: "https://github.com/example/rejected.git")),
        sourceDefaultBranch: "main",
        importedSHA: analyzedSHA
      )
    )
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      purpose: .knowledge,
      analyzedSHA: analyzedSHA,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id,
      status: .analyzing
    )
    try await store.createRepositoryKnowledgeRun(run)
    let draft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .create,
      parentPageID: features.id,
      title: "Unsupported claim",
      proposedBodyMarkdown: "The repository did not prove this.",
      rationale: "Review must reject unsupported information.",
      evidence: [.init(path: "README.md")]
    )
    _ = try await store.recordRepositoryKnowledgeAnalysis(
      runID: run.id,
      summary: "One proposal required review",
      drafts: [draft],
      analyzerThreadID: "analysis-thread",
      analyzerTurnID: "analysis-turn"
    )
    _ = try await store.recordRepositoryKnowledgeReview(
      runID: run.id,
      summary: "The proposal was not supported",
      decisions: [
        .init(
          draftID: draft.id,
          approved: false,
          explanation: "The evidence does not establish the claim."
        )
      ],
      reviewerThreadID: "review-thread",
      reviewerTurnID: "review-turn"
    )
    _ = try await store.updateRepositoryKnowledgeRun(id: run.id, status: .completed)

    for _ in 0..<2 {
      let relaunched = AppModel(
        storeRegistry: registry,
        selectedProductID: product.id
      )
      await relaunched.load()
      #expect(
        relaunched.repositoryKnowledgeSnapshot?.completionOutcome == .noPublishableKnowledge
      )
      await relaunched.shutdown()
      #expect(try await store.fetchRepositoryKnowledgeRuns(productID: product.id).count == 1)
      #expect(try await store.fetchRepositoryKnowledgeRun(id: run.id).status == .completed)
    }

    for store in registry.allStores {
      await store.close()
    }
  }
  @Test(
    "[D10] Retry work requeues a failed or interrupted implementation in its preserved workspace",
    arguments: [AgentRunStatus.failed, .interrupted]
  )
  func implementationRetryPreservesRunIdentity(status: AgentRunStatus) async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Recover delivery")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let createdItem = try await store.createWorkItem(
      productID: product.id,
      title: "Preserve interrupted work",
      acceptanceCriteria: ["Retry continues the existing work"]
    )
    _ = try await store.transitionWorkItem(
      id: createdItem.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refined"
    )
    let readyItem = try await store.transitionWorkItem(
      id: createdItem.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Recover without duplication",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: readyItem.id, implementerProfileID: implementer.id, estimatedTokens: 1)
      ]
    )
    _ = try await store.startSprint(id: draft.sprint.id)
    _ = try await store.transitionWorkItem(
      id: readyItem.id,
      to: .running,
      actor: "Spedito",
      reason: "Implementation started"
    )
    let initialRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    let workspacePath = fixture.directoryURL
      .appendingPathComponent("ticket-worktree", isDirectory: true)
      .path
    _ = try await store.updateAgentRun(
      id: initialRun.id,
      status: status,
      codexThreadID: "implementation-thread",
      worktreePath: workspacePath,
      eventActor: "Spedito",
      eventDetail: "The implementation stopped unexpectedly"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )

    let comment = await model.resumeSprintWork(
      productID: product.id,
      workItemID: readyItem.id,
      body: "Keep the existing approach and retry."
    )

    #expect(comment?.body == "Keep the existing approach and retry.")
    let recoveredRuns = try await store.fetchAgentRuns(productID: product.id)
    let recoveredRun = try #require(recoveredRuns.first)
    #expect(recoveredRuns.count == 1)
    #expect(recoveredRun.id == initialRun.id)
    #expect(recoveredRun.status == .queued)
    #expect(recoveredRun.codexThreadID == "implementation-thread")
    #expect(recoveredRun.worktreePath == workspacePath)
    #expect(
      try await store.fetchComments(workItemID: readyItem.id)
        .contains { $0.body == "Keep the existing approach and retry." }
    )

    await model.shutdown()
  }

  @Test("Team settings failure stays retryable and success updates the bounded snapshot")
  func teamSettingsCommandReturnsCommittedSnapshot() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Team settings")
    let store = try #require(registry.store(for: product.id))
    let seededProfiles = try await store.seedDefaultProfiles(productID: product.id)
    _ = try await store.createEpic(
      productID: product.id,
      outcome: "Keep unrelated state stable"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )
    await model.reload()
    let unrelatedEpics = model.epics

    var invalidModels = Dictionary(
      uniqueKeysWithValues: seededProfiles.map { ($0.id, $0.model) }
    )
    invalidModels[try #require(seededProfiles.first).id] = ""
    let failed = await model.updateTeamSettings(
      productInstructions: "Unsaved guidance",
      modelsByProfile: invalidModels,
      effortsByProfile: [:],
      customInstructionsByProfile: [:]
    )
    guard case .failure(let failure) = failed else {
      Issue.record("Expected the invalid team settings update to fail")
      return
    }
    #expect(!failure.message.isEmpty)
    #expect(model.selectedProduct?.instructions == product.instructions)
    #expect(model.profiles == seededProfiles)
    #expect(model.epics == unrelatedEpics)

    let updatedModels = Dictionary(
      uniqueKeysWithValues: seededProfiles.enumerated().map {
        ($0.element.id, "owner-selected-model-\($0.offset)")
      }
    )
    let updatedEfforts = Dictionary(
      uniqueKeysWithValues: seededProfiles.map { ($0.id, "high") }
    )
    let updatedInstructions = Dictionary(
      uniqueKeysWithValues: seededProfiles.enumerated().map {
        ($0.element.id, "Member guidance \($0.offset)")
      }
    )
    let saved = await model.updateTeamSettings(
      productInstructions: "Committed shared guidance",
      modelsByProfile: updatedModels,
      effortsByProfile: updatedEfforts,
      customInstructionsByProfile: updatedInstructions
    )
    guard case .success(let snapshot) = saved else {
      Issue.record("Expected the corrected team settings update to succeed")
      return
    }
    #expect(snapshot.product.instructions == "Committed shared guidance")
    #expect(model.selectedProduct == snapshot.product)
    #expect(model.profiles == snapshot.profiles)
    #expect(model.epics == unrelatedEpics)

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  /// Existing partial coverage:
  /// - `ProductStoreRegistryTests.productCreationOnlyNeedsAName`
  /// - `ProductStoreRegistryTests.finalSchemaAndAgentViews`
  /// This test covers only A02's combined blank-Product activation: workspace, Git, database,
  /// starter team, and selected Product become authoritative in one command.
  @Test("A02 blank Product creation activates its complete local workspace")
  func a02BlankProductCreationActivatesLocalWorkspace() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let model = AppModel(storeRegistry: registry)

    #expect(await model.createProductAndSelect(.blank(name: "Owner product")))
    let product = try #require(model.selectedProduct)
    let workspace = fixture.workspacesURL.appendingPathComponent(
      product.id.uuidString,
      isDirectory: true
    )
    #expect(FileManager.default.fileExists(atPath: workspace.path))
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent(".git", isDirectory: true).path
      )
    )
    #expect(FileManager.default.fileExists(atPath: registry.databaseURL(for: product.id).path))
    let store = try #require(registry.store(for: product.id))
    let roles = Set(try await store.fetchAgentProfiles(productID: product.id).map(\.role))
    #expect(roles.contains(.businessAnalyst))
    #expect(roles.contains(.implementer))
    #expect(roles.contains(.lead))
    #expect(model.products == [product])
    let repositorySHA = try await GitWorkspaceManager().currentSHA(at: workspace)
    #expect(repositorySHA.count == 40)

    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  /// Existing partial coverage:
  /// - `AppModelStartupTests.legacyDefaultsMigration`
  /// - `SprintBoardSelectionTests.newlyPlannedSprintBecomesSelected`
  /// This test covers only A05's relaunched Product, destination, and Product-scoped sprint
  /// tuple using the same persisted keys read by the application shell.
  @Test("A05 relaunch restores the Product destination and sprint tuple")
  func a05RelaunchRestoresWorkspaceTuple() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let product = try await registry.createProduct(name: "Relaunch product")
    let store = try #require(registry.store(for: product.id))
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Restore the selected sprint"
    )
    let plan = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Restore one workspace tuple",
      tokenBudgetLimit: nil,
      items: [SprintDraftItemInput(workItemID: item.id, estimatedTokens: 1)]
    )
    let destinationKey = "workspaceDestination.\(product.id.uuidString)"
    UserDefaults.standard.set(WorkspaceDestination.sprint.rawValue, forKey: destinationKey)
    SprintBoardSelectionDefaults.select(plan.sprint.id, for: product.id)
    defer {
      UserDefaults.standard.removeObject(forKey: destinationKey)
      SprintBoardSelectionDefaults.select(nil, for: product.id)
    }

    let relaunched = try await fixture.relaunch(
      closing: registry,
      selectedProductID: product.id
    )
    #expect(relaunched.model.selectedProductID == product.id)
    #expect(
      UserDefaults.standard.string(forKey: destinationKey)
        .flatMap(WorkspaceDestination.init(rawValue:)) == .sprint
    )
    #expect(SprintBoardSelectionDefaults.selectedSprintID(for: product.id) == plan.sprint.id)
    #expect(relaunched.model.sprintPlan?.sprint.id == plan.sprint.id)
    await relaunched.close()
  }

  /// Existing partial coverage:
  /// - `ProductExecutionLifecycleTests.productArchivalHasProductScope`
  /// - `SQLiteStoreTests.productArchiveAndRestorePreserveHistory`
  /// This test covers only A06's post-archive application navigation to the remaining Product
  /// while the archived Product remains durable and absent from active navigation.
  @Test("A06 archiving the selected Product routes to the remaining active Product")
  func a06ArchiveSelectedProductRoutesToRemainingProduct() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let archivedProduct = try await registry.createProduct(name: "Archive me")
    let remainingProduct = try await registry.createProduct(name: "Keep me")
    let model = AppModel(storeRegistry: registry, selectedProductID: archivedProduct.id)
    await model.reload()

    #expect(await model.archiveSelectedProduct())
    #expect(model.selectedProductID == remainingProduct.id)
    #expect(model.products.map(\.id) == [remainingProduct.id])
    #expect(
      try await registry.fetchProducts(status: .archived).map(\.id) == [archivedProduct.id]
    )

    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

}

private struct ProductScopedPersistenceFixture {
  let directoryURL: URL
  let workspacesURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-product-scoped-persistence-\(UUID())",
        isDirectory: true
      )
    workspacesURL = directoryURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  @MainActor
  func relaunch(
    closing registry: ProductStoreRegistry,
    selectedProductID: UUID
  ) async throws -> ProductScopedAppInstance {
    for store in registry.allStores {
      await store.close()
    }
    let relaunchedRegistry = try ProductStoreRegistry(
      productWorkspacesRootURL: workspacesURL
    )
    try await relaunchedRegistry.prepare()
    let model = AppModel(
      storeRegistry: relaunchedRegistry,
      selectedProductID: selectedProductID
    )
    await model.reload()
    return ProductScopedAppInstance(
      registry: relaunchedRegistry,
      model: model
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

@MainActor
private struct ProductScopedAppInstance {
  let registry: ProductStoreRegistry
  let model: AppModel

  func close() async {
    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }
}

@MainActor
private final class ProductSwitchOperationGate {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    let pair = AsyncStream<Void>.makeStream()
    stream = pair.stream
    continuation = pair.continuation
  }

  func wait() async {
    for await _ in stream {
      return
    }
  }

  func open() {
    continuation.yield()
    continuation.finish()
  }
}
