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
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )

    await model.load()
    for _ in 0..<100 {
      if try await store.fetchRepositoryKnowledgeRun(id: run.id).status == .completed {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }

    let completed = try await store.fetchRepositoryKnowledgeRun(id: run.id)
    #expect(completed.status == .completed)
    #expect(try await git.acceptedTrunkSHA(at: workspace) == analyzedSHA)
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent("knowledge", isDirectory: true).path
      )
    )
    let updatedOverview = try #require(
      try await store.fetchKnowledgePages(productID: product.id).first {
        $0.id == overview.id
      }
    )
    #expect(updatedOverview.bodyMarkdown.contains("Verified without changing the repository."))

    for store in registry.allStores {
      await store.close()
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

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
