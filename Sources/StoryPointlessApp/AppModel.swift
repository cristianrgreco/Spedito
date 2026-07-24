import Foundation
import StoryPointlessCore
import SwiftUI

enum CodexConnectionState: Equatable {
  case notChecked
  case checking
  case connected(version: String, userAgent: String)
  case unavailable(String)
  case incompatible(String)
}

private struct PlanningConversationKey: Hashable {
  let workItemID: UUID
  let profileID: UUID
}

struct TicketRefinementSessionResult: Equatable {
  let base: SprintPlanningTicketSnapshot
  let reply: TicketRefinementReply?
  let errorMessage: String?
}

struct TicketConversationSessionResult: Equatable {
  let base: SprintPlanningTicketSnapshot
  let recipientID: UUID
  let reply: TicketConversationReply
}

struct EpicPlanningConversationMessage: Identifiable, Equatable {
  enum Author: Equatable {
    case owner
    case businessAnalyst
    case system
  }

  let id: UUID
  let author: Author
  let body: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    author: Author,
    body: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.author = author
    self.body = body
    self.createdAt = createdAt
  }
}

struct EpicPlanningConversationState: Equatable {
  let epicID: UUID
  var messages: [EpicPlanningConversationMessage]
  var questions: [TicketRefinementQuestion]
  var isRunning: Bool
  var isGeneratingPlan: Bool
  var isComplete: Bool
  var errorMessage: String?
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var products: [Product] = []
  @Published private(set) var epics: [Epic] = []
  @Published private(set) var workItems: [WorkItem] = []
  @Published private(set) var dependencies: [WorkItemDependency] = []
  @Published private(set) var profiles: [AgentProfile] = []
  @Published private(set) var sprintPlan: SprintPlan?
  @Published private(set) var sprintHistory: [SprintPlan] = []
  @Published private(set) var runs: [AgentRun] = []
  @Published private(set) var sprintReadinessIssues: [SprintReadinessIssue] = []
  @Published private(set) var activity: [ActivityEvent] = []
  @Published private(set) var retrospectiveNotes: [RetrospectiveNote] = []
  @Published private(set) var knowledgePages: [KnowledgePage] = []
  @Published private(set) var candidateRevisions: [CandidateRevision] = []
  @Published private(set) var knowledgePageProposals: [KnowledgePageProposal] = []
  @Published private(set) var agentRunKnowledgeContext: [AgentRunKnowledgePage] = []
  @Published private(set) var liveRunActivities: [UUID: CodexLiveActivity] = [:]
  @Published private(set) var suggestionBatch: TicketSuggestionBatch?
  @Published private(set) var codexModels: [CodexModelOption] = []
  @Published private(set) var codexConnectionState = CodexConnectionState.notChecked
  @Published var selectedProductID: UUID?
  @Published private(set) var shouldPresentProductLibraryOnLaunch = false
  @Published var errorMessage: String?
  @Published private(set) var isLoading = false
  @Published private(set) var isDecidingSuggestions = false
  @Published private(set) var isPlanningMessageRunning = false
  @Published private(set) var isTicketConversationMessageRunning = false
  @Published private(set) var ticketConversationWorkItemID: UUID?
  @Published private(set) var ticketConversationRecipientID: UUID?
  @Published private(set) var ticketRefinementResults: [UUID: TicketRefinementSessionResult] = [:]
  @Published private(set) var ticketConversationResults: [UUID: TicketConversationSessionResult] = [:]
  @Published private(set) var epicPlanningConversation: EpicPlanningConversationState?
  @Published private(set) var isAskingKnowledge = false
  @Published private(set) var refiningWorkItemID: UUID?
  @Published private(set) var codebaseFocusWorkItemID: UUID?
  @Published private(set) var knowledgeFocusPageID: UUID?
  @Published var backlogFocusEpicID: UUID?

  let requiresKnowledgeApproval = StoryPointlessFeatureFlags.requiresKnowledgeApproval

  var candidateSprintPlan: SprintPlan? {
    if let sprintPlan, sprintPlan.sprint.state == .draft {
      return sprintPlan
    }
    return sprintHistory.first { $0.sprint.state == .draft }
  }

  private let store: SQLiteStore?
  private let gitWorkspaceManager = GitWorkspaceManager()
  private var codexClient: CodexAppServerClient?
  private var suggestionTask: Task<Void, Never>?
  private var planningThreadIDs: [PlanningConversationKey: String] = [:]
  private var ticketConversationThreadIDs: [PlanningConversationKey: String] = [:]
  private var activePlanningTurn: (threadID: String, turnID: String)?
  private var activeTicketConversationTurn: (threadID: String, turnID: String)?
  private var activeTicketRefinementTurn: (threadID: String, turnID: String)?
  private var epicPlanningThreadID: String?
  private var activeEpicPlanningTurn: (threadID: String, turnID: String)?
  private var epicPlanningTask: Task<Void, Never>?
  private var sprintExecutionTask: Task<Void, Never>?
  private var activeImplementationTasks: [UUID: Task<Void, Never>] = [:]
    private struct ActiveExecutionTurn: Sendable {
        let threadID: String
        let turnID: String
    }

  private var activeExecutionTurns: [UUID: ActiveExecutionTurn] = [:]
  private var manuallyStoppedRunIDs: Set<UUID> = []
  private var liveActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var liveActivityMonitorIDs: [UUID: UUID] = [:]
  private var didLoad = false
  private var didResolveInitialProductSelection = false

  private static let selectedProductDefaultsKey = "selectedProductID"
  private static let maxAutomaticReviewCorrections = 2

  init() {
    selectedProductID = UserDefaults.standard.string(
      forKey: Self.selectedProductDefaultsKey
    ).flatMap(UUID.init(uuidString:))
    do {
      let baseURL = try Self.applicationSupportURL()
      store = try SQLiteStore(url: baseURL.appendingPathComponent("storypointless.sqlite"))
    } catch {
      store = nil
      errorMessage = error.localizedDescription
    }
  }

  var selectedProduct: Product? {
    products.first { $0.id == selectedProductID }
  }

  var canAutosuggestTickets: Bool {
    guard case .connected = codexConnectionState else { return false }
    guard suggestionBatch?.session.status != .generating else { return false }
    guard !isPlanningMessageRunning else { return false }
    guard !isTicketConversationMessageRunning else { return false }
    guard refiningWorkItemID == nil else { return false }
    return pendingSuggestionCount == 0
  }

  var canPlanEpic: Bool {
    canAutosuggestTickets
      && epicPlanningConversation?.isRunning != true
      && epicPlanningConversation?.isGeneratingPlan != true
  }

  var canRefineTicket: Bool {
    guard case .connected = codexConnectionState else { return false }
    guard suggestionBatch?.session.status != .generating else { return false }
    guard !isPlanningMessageRunning else { return false }
    guard !isTicketConversationMessageRunning else { return false }
    return refiningWorkItemID == nil
  }

  var pendingSuggestionCount: Int {
    guard suggestionBatch?.session.epicID != nil else { return 0 }
    return suggestionBatch?.suggestions.filter { $0.status == .proposed }.count ?? 0
  }

  func codebaseSnapshot() async throws -> GitRepositorySnapshot {
    guard let productID = selectedProductID else {
      throw GitWorkspaceError.invalidRepository("No product is selected.")
    }
    return try await gitWorkspaceManager.repositorySnapshot(
      at: Self.productWorkspaceURL(productID: productID)
    )
  }

  func codebaseCommitDetail(sha: String) async throws -> GitCommitDetail {
    guard let productID = selectedProductID else {
      throw GitWorkspaceError.invalidRepository("No product is selected.")
    }
    return try await gitWorkspaceManager.commitDetail(
      at: Self.productWorkspaceURL(productID: productID),
      sha: sha
    )
  }

  func codebaseBranchDetail(branch: GitBranchSnapshot) async throws -> GitBranchDetail {
    guard let productID = selectedProductID else {
      throw GitWorkspaceError.invalidRepository("No product is selected.")
    }
    return try await gitWorkspaceManager.branchDetail(
      at: Self.productWorkspaceURL(productID: productID),
      branch: branch
    )
  }

  func requestCodebaseFocus(workItemID: UUID) {
    codebaseFocusWorkItemID = workItemID
  }

  func consumeCodebaseFocus(workItemID: UUID) {
    guard codebaseFocusWorkItemID == workItemID else { return }
    codebaseFocusWorkItemID = nil
  }

  func requestKnowledgeFocus(pageID: UUID) {
    knowledgeFocusPageID = pageID
  }

  func consumeKnowledgeFocus(pageID: UUID) {
    guard knowledgeFocusPageID == pageID else { return }
    knowledgeFocusPageID = nil
  }

  var autosuggestUnavailableReason: String {
    if pendingSuggestionCount > 0 {
      return "Review the current \(pendingSuggestionCount) suggestion\(pendingSuggestionCount == 1 ? "" : "s") before asking for another analysis."
    }
    if isPlanningMessageRunning {
      return "A team member is replying in Sprint Planning."
    }
    if isTicketConversationMessageRunning {
      return "A team member is replying in a ticket conversation."
    }
    if refiningWorkItemID != nil {
      return "The Business Analyst is reviewing a ticket."
    }
    switch codexConnectionState {
    case .connected:
      return "The Business Analyst is already preparing suggestions."
    default:
      return "Ticket suggestions require the Codex team connection."
    }
  }

  func load() async {
    guard !didLoad else { return }
    didLoad = true
    await reload()
    await connectCodex()
    await recoverInterruptedSuggestionSession()
    scheduleSprintExecution()
  }

  func createProduct(name: String, vision: String) {
    Task {
      _ = await createProductAndSelect(name: name, vision: vision)
    }
  }

  func createProductAndSelect(name: String, vision: String) async -> Bool {
    guard let store else { return false }
    do {
      let product = try await store.createProduct(name: name, vision: vision)
      _ = try await store.seedDefaultProfiles(productID: product.id)
      _ = try await store.seedKnowledgeBase(productID: product.id)
      selectedProductID = product.id
      rememberSelectedProduct(product.id)
      products = try await store.fetchProducts()
      await reloadSelectedProduct()
      let workspace = try Self.productWorkspaceURL(productID: product.id)
      _ = try await gitWorkspaceManager.ensureRepository(at: workspace)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func selectProduct(_ product: Product) async {
    await suspendSprintExecution()
    suggestionTask?.cancel()
    planningThreadIDs.removeAll()
    ticketConversationThreadIDs.removeAll()
    selectedProductID = product.id
    rememberSelectedProduct(product.id)
    await reloadSelectedProduct()
    await recoverInterruptedSuggestionSession()
  }

  func consumeProductLibraryLaunchPrompt() {
    shouldPresentProductLibraryOnLaunch = false
  }

  func createWorkItem(
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority,
    dependsOnWorkItemIDs: Set<UUID>,
    epicID: UUID? = nil
  ) async -> WorkItem? {
    guard let store, let productID = selectedProductID else { return nil }
    do {
      let item = try await store.createWorkItem(
        productID: productID,
        title: title,
        type: type,
        body: body,
        acceptanceCriteria: acceptanceCriteria,
        priority: priority,
        dependsOnWorkItemIDs: dependsOnWorkItemIDs,
        epicID: epicID
      )
      await reloadSelectedProduct()
      return workItems.first { $0.id == item.id } ?? item
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func createEpic(outcome: String) async -> Epic? {
    guard let store, let productID = selectedProductID else { return nil }
    do {
      let epic = try await store.createEpic(productID: productID, outcome: outcome)
      await reloadSelectedProduct()
      backlogFocusEpicID = epic.id
      return epics.first { $0.id == epic.id } ?? epic
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func createEpicAndPlan(outcome: String) async -> Epic? {
    let epic = await createEpic(outcome: outcome)
    if let epic, canPlanEpic {
      planEpic(epic)
    }
    return epic
  }

  func updateEpic(
    _ epic: Epic,
    title: String,
    goal: String,
    successCriteria: [String],
    constraints: String,
    status: EpicStatus
  ) async -> Epic? {
    guard let store else { return nil }
    do {
      let updated = try await store.updateEpic(
        id: epic.id,
        title: title,
        goal: goal,
        successCriteria: successCriteria,
        constraints: constraints,
        status: status
      )
      await reloadSelectedProduct()
      return updated
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func assignWorkItem(_ item: WorkItem, to epicID: UUID?) async {
    guard let store else { return }
    do {
      _ = try await store.assignWorkItemToEpic(id: item.id, epicID: epicID)
      await reloadSelectedProduct()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refineTicket(_ item: WorkItem) async throws -> TicketRefinementReply {
    guard
      canRefineTicket,
      let store,
      let client = codexClient,
      let product = selectedProduct,
      product.id == item.productID,
      let analyst = profiles.first(where: { $0.role == .businessAnalyst })
    else {
      if refiningWorkItemID != nil || isPlanningMessageRunning
        || isTicketConversationMessageRunning
        || suggestionBatch?.session.status == .generating
      {
        throw TicketRefinementGenerationError.anotherCodexTaskIsRunning
      }
      throw CodexClientError.notConnected
    }

    let refinementBase = SprintPlanningTicketSnapshot(item: item)
    ticketRefinementResults.removeValue(forKey: item.id)
    ticketConversationResults.removeValue(forKey: item.id)
    refiningWorkItemID = item.id
    defer {
      refiningWorkItemID = nil
      activeTicketRefinementTurn = nil
    }

    do {
      let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
      let conversation = try await store.fetchComments(workItemID: item.id)
      let activeItems = workItems.filter { $0.state != .cancelled }
      let activeItemIDs = Set(activeItems.map(\.id))
      let activeDependencies = dependencies.filter {
        activeItemIDs.contains($0.workItemID)
          && activeItemIDs.contains($0.dependsOnWorkItemID)
      }
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workingDirectory,
        developerInstructions: CodexTicketRefinementGenerator.developerInstructions(
          productInstructions: inheritedAgentInstructions(for: product),
          personaInstructions: analyst.effectiveInstructions
        ),
        model: analyst.model
      )
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketRefinementGenerator.prompt(
          product: product,
          item: item,
          epic: item.epicID.flatMap { epicID in epics.first { $0.id == epicID } },
          existingItems: activeItems,
          dependencies: activeDependencies,
          conversation: conversation
        ),
        effort: analyst.reasoningEffort,
        outputSchema: CodexTicketRefinementGenerator.outputSchema
      )
      activeTicketRefinementTurn = (threadID: threadID, turnID: turnID)
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let reply = try CodexTicketRefinementGenerator.decode(
        response,
        currentItem: item,
        validRelatedItems: activeItems
      )
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: analyst.name,
        body: reply.ticketCommentBody
      )
      activity = try await store.fetchActivity(productID: product.id)
      ticketRefinementResults[item.id] = TicketRefinementSessionResult(
        base: refinementBase,
        reply: reply,
        errorMessage: nil
      )
      return reply
    } catch {
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "The Business Analyst couldn't refine this ticket: \(error.localizedDescription)"
      )
      ticketRefinementResults[item.id] = TicketRefinementSessionResult(
        base: refinementBase,
        reply: nil,
        errorMessage: error.localizedDescription
      )
      throw error
    }
  }

  func cancelTicketRefinement() {
    guard let client = codexClient, let activeTicketRefinementTurn else { return }
    Task {
      try? await client.interruptTurn(
        threadID: activeTicketRefinementTurn.threadID,
        turnID: activeTicketRefinementTurn.turnID
      )
    }
  }

  func sendTicketConversationMessage(
    for item: WorkItem,
    to recipient: AgentProfile,
    ownerMessage: String,
    allowsProposal: Bool = true
  ) async throws -> TicketConversationReply {
    guard
      !isTicketConversationMessageRunning,
      !isPlanningMessageRunning,
      refiningWorkItemID == nil,
      suggestionBatch?.session.status != .generating
    else {
      throw TicketConversationGenerationError.anotherCodexTaskIsRunning
    }
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct,
      product.id == item.productID,
      recipient.productID == product.id,
      profiles.contains(where: { $0.id == recipient.id })
    else {
      throw CodexClientError.notConnected
    }
    let trimmedMessage = ownerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      throw TicketConversationGenerationError.invalidResponse("Enter a message first.")
    }

    let conversationBase = SprintPlanningTicketSnapshot(item: item)
    ticketConversationResults.removeValue(forKey: item.id)
    isTicketConversationMessageRunning = true
    ticketConversationWorkItemID = item.id
    ticketConversationRecipientID = recipient.id
    defer {
      isTicketConversationMessageRunning = false
      ticketConversationWorkItemID = nil
      ticketConversationRecipientID = nil
      activeTicketConversationTurn = nil
    }

    let comments = try await store.fetchComments(workItemID: item.id)
    let currentMessageBody = "@\(recipient.name) \(trimmedMessage)"
    let priorComments = comments.last?.authorKind == .owner
      && comments.last?.body == currentMessageBody
      ? Array(comments.dropLast())
      : comments
    let activeItemIDs = Set(workItems.filter { $0.state != .cancelled }.map(\.id))
    let prerequisiteIDs = Set(
      dependencies
        .filter {
          $0.workItemID == item.id
            && activeItemIDs.contains($0.dependsOnWorkItemID)
        }
        .map(\.dependsOnWorkItemID)
    )
    let prerequisites = workItems.filter { prerequisiteIDs.contains($0.id) }
    let conversationKey = PlanningConversationKey(
      workItemID: item.id,
      profileID: recipient.id
    )

    do {
      let threadID: String
      if let existingThreadID = ticketConversationThreadIDs[conversationKey] {
        threadID = existingThreadID
      } else {
        let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
        threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: CodexTicketConversation.developerInstructions(
            productInstructions: inheritedAgentInstructions(for: product),
            personaInstructions: recipient.effectiveInstructions,
            recipient: recipient
          ),
          model: recipient.model
        )
        ticketConversationThreadIDs[conversationKey] = threadID
      }
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketConversation.prompt(
          product: product,
          item: item,
          prerequisites: prerequisites,
          previousComments: priorComments,
          ownerMessage: trimmedMessage,
          allowsProposal: allowsProposal
        ),
        effort: recipient.reasoningEffort,
        outputSchema: CodexTicketConversation.outputSchema
      )
      activeTicketConversationTurn = (threadID: threadID, turnID: turnID)
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let generatedReply = try CodexTicketConversation.decode(
        response,
        currentItem: item
      )
      let reply = allowsProposal
        ? generatedReply
        : TicketConversationReply(message: generatedReply.message)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: recipient.name,
        body: reply.ticketCommentBody
      )
      activity = try await store.fetchActivity(productID: product.id)
      ticketConversationResults[item.id] = TicketConversationSessionResult(
        base: conversationBase,
        recipientID: recipient.id,
        reply: reply
      )
      return reply
    } catch {
      ticketConversationThreadIDs.removeValue(forKey: conversationKey)
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "\(recipient.name) couldn't reply: \(error.localizedDescription)"
      )
      throw error
    }
  }

  func cancelTicketConversationMessage() {
    guard let client = codexClient, let activeTicketConversationTurn else { return }
    Task {
      try? await client.interruptTurn(
        threadID: activeTicketConversationTurn.threadID,
        turnID: activeTicketConversationTurn.turnID
      )
    }
  }

  func dismissTicketAssistantResult(workItemID: UUID) {
    ticketRefinementResults.removeValue(forKey: workItemID)
    ticketConversationResults.removeValue(forKey: workItemID)
  }

  func transition(_ workItem: WorkItem, to state: WorkItemState) {
    guard let store else { return }
    Task {
      do {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: state,
          actor: "Product Owner",
          reason: "Advanced from the board"
        )
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateWorkItem(
    id: UUID,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority,
    customFields: [String: String],
    dependsOnWorkItemIDs: Set<UUID>,
    expectedVersion: Int? = nil
  ) async -> Bool {
    guard let store else { return false }
    do {
      let updated = try await store.updateWorkItem(
        id: id,
        title: title,
        type: type,
        body: body,
        acceptanceCriteria: acceptanceCriteria,
        priority: priority,
        customFields: customFields,
        dependsOnWorkItemIDs: dependsOnWorkItemIDs,
        expectedVersion: expectedVersion
      )
      if updated.ownerProfileID == nil,
        let owner = TicketOwnerRouter.owner(for: updated, profiles: profiles)
      {
        _ = try await store.assignWorkItemOwner(id: updated.id, profileID: owner.id)
      }
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func moveWorkItem(_ workItem: WorkItem, to position: WorkItemRankPosition) {
    guard let store else { return }
    Task {
      do {
        workItems = try await store.moveWorkItem(id: workItem.id, to: position)
        activity = try await store.fetchActivity(productID: workItem.productID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func archiveWorkItem(_ workItem: WorkItem) {
    guard let store else { return }
    Task {
      do {
        try await store.archiveWorkItem(id: workItem.id)
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func comments(for workItemID: UUID) async -> [TicketComment] {
    guard let store else { return [] }
    do {
      return try await store.fetchComments(workItemID: workItemID)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func activityEvents(for workItemID: UUID) async -> [ActivityEvent] {
    guard let store else { return [] }
    do {
      return try await store.fetchActivity(workItemID: workItemID)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func knowledgeRevisions(for pageID: UUID) async -> [KnowledgePageRevision] {
    guard let store else { return [] }
    do {
      return try await store.fetchKnowledgePageRevisions(pageID: pageID)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func saveKnowledgePage(
    id: UUID,
    title: String,
    bodyMarkdown: String,
    changeSummary: String
  ) async -> Bool {
    guard let store else { return false }
    do {
      _ = try await store.updateKnowledgePage(
        id: id,
        title: title,
        bodyMarkdown: bodyMarkdown,
        authorName: "Me",
        changeSummary: changeSummary
      )
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func createKnowledgePage(parentID: UUID?, title: String) async -> KnowledgePage? {
    guard let store, let productID = selectedProductID else { return nil }
    do {
      let page = try await store.createKnowledgePage(
        productID: productID,
        parentID: parentID,
        title: title
      )
      await reloadSelectedProduct()
      return page
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func askKnowledge(_ question: String) async -> KnowledgeAnswer? {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !isAskingKnowledge,
      let client = codexClient,
      let product = selectedProduct,
      case .connected = codexConnectionState
    else { return nil }
    let pages = knowledgePages.filter { $0.verificationStatus == .verified }
    guard !pages.isEmpty else { return nil }
    let respondent =
      profiles.first(where: { $0.role == .knowledgeCurator })
      ?? profiles.first(where: { $0.role == .businessAnalyst })
    guard let respondent else { return nil }

    isAskingKnowledge = true
    defer { isAskingKnowledge = false }
    do {
      let workspace = try Self.productWorkspaceURL(productID: product.id)
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexKnowledgeAssistant.developerInstructions,
        model: respondent.model
      )
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexKnowledgeAssistant.prompt(question: trimmed, pages: pages),
        effort: respondent.reasoningEffort,
        outputSchema: CodexKnowledgeAssistant.outputSchema
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(180)
      )
      return try CodexKnowledgeAssistant.decode(
        response,
        allowedPageIDs: Set(pages.map(\.id))
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func decideRetrospectiveAction(_ note: RetrospectiveNote, accept: Bool) async {
    guard let store else { return }
    guard
      let noteIndex = retrospectiveNotes.firstIndex(where: { $0.id == note.id }),
      retrospectiveNotes[noteIndex].actionStatus == .proposed
    else { return }

    let previousNote = retrospectiveNotes[noteIndex]
    let decidedStatus: RetrospectiveActionStatus = accept ? .accepted : .dismissed
    retrospectiveNotes[noteIndex].actionStatus = decidedStatus
    retrospectiveNotes[noteIndex].updatedAt = Date()

    do {
      _ = try await store.decideRetrospectiveAction(noteID: note.id, accept: accept)
      await reloadSelectedProduct()
    } catch {
      if let currentIndex = retrospectiveNotes.firstIndex(where: { $0.id == note.id }),
        retrospectiveNotes[currentIndex].actionStatus == decidedStatus
      {
        retrospectiveNotes[currentIndex] = previousNote
      }
      errorMessage = error.localizedDescription
    }
  }

  func decideRetrospectiveActions(
    _ notes: [RetrospectiveNote],
    accept: Bool
  ) async {
    guard let store else { return }
    let proposedNotes = notes.filter { $0.actionStatus == .proposed }
    guard !proposedNotes.isEmpty else { return }

    let proposedIDs = Set(proposedNotes.map(\.id))
    let decidedStatus: RetrospectiveActionStatus = accept ? .accepted : .dismissed
    let now = Date()
    for index in retrospectiveNotes.indices
    where proposedIDs.contains(retrospectiveNotes[index].id)
      && retrospectiveNotes[index].actionStatus == .proposed
    {
      retrospectiveNotes[index].actionStatus = decidedStatus
      retrospectiveNotes[index].updatedAt = now
    }

    do {
      for note in proposedNotes {
        _ = try await store.decideRetrospectiveAction(
          noteID: note.id,
          accept: accept
        )
      }
      await reloadSelectedProduct()
    } catch {
      await reloadSelectedProduct()
      errorMessage = error.localizedDescription
    }
  }

  func concludeRetrospective(sprintID: UUID) async -> Bool {
    guard let store else { return false }
    do {
      _ = try await store.concludeRetrospective(id: sprintID)
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func appendOwnerComment(workItemID: UUID, body: String) async -> TicketComment? {
    guard let store else { return nil }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let comment = try await store.appendComment(
        workItemID: workItemID,
        authorKind: .owner,
        authorName: "Me",
        body: trimmed
      )
      if let productID = selectedProductID {
        activity = try await store.fetchActivity(productID: productID)
      }
      return comment
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func appendSprintWorkLogComment(
    workItemID: UUID,
    body: String
  ) async -> TicketComment? {
    await appendOwnerComment(workItemID: workItemID, body: body)
  }

  func stopAgentRun(_ run: AgentRun) async {
    guard
      run.status == .running,
      let client = codexClient,
      let store,
      let turn = activeExecutionTurns[run.id]
    else { return }
    manuallyStoppedRunIDs.insert(run.id)
    do {
      try await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
      stopLiveActivityMonitoring(runID: run.id)
      _ = try await store.updateAgentRun(
        id: run.id,
        status: .interrupted,
        eventActor: "Product Owner",
        eventDetail: "Stopped manually; ticket workspace preserved"
      )
      await reloadSelectedProduct()
    } catch {
      manuallyStoppedRunIDs.remove(run.id)
      errorMessage = error.localizedDescription
    }
  }

  func resumeSprintWork(
    workItemID: UUID,
    body: String
  ) async -> TicketComment? {
    guard let comment = await appendOwnerComment(workItemID: workItemID, body: body) else {
      return nil
    }
    await handleSprintOwnerComment(workItemID: workItemID, body: comment.body)
    return comment
  }

  func acceptSprintTicket(_ item: WorkItem) async -> Bool {
    guard let store else { return false }
    do {
      let current = try await store.fetchWorkItems(productID: item.productID)
        .first { $0.id == item.id }
      guard let current, current.state == .acceptance else { return false }
      let candidates = try await store.fetchCandidateRevisions(productID: item.productID)
      let readyCandidates = candidates.filter { candidate in
        candidate.workItemID == item.id && candidate.status == .readyForDemo
      }
      guard
        let candidate = readyCandidates.max(by: { $0.version < $1.version }),
        let integratedSHA = candidate.integratedSHA
      else {
        throw PersistenceError.corruptData(
          "This ticket has no reviewed candidate revision ready to promote."
        )
      }
      var allProposals = try await store.fetchKnowledgePageProposals(
        productID: item.productID
      )
      var proposals = allProposals.filter { proposal in
        proposal.candidateRevisionID == candidate.id
      }
      if
        !requiresKnowledgeApproval,
        proposals.contains(where: { $0.status == .reviewed })
      {
        _ = try await publishReviewedKnowledgePageProposals(
          candidate: candidate,
          workItem: current,
          authorName: "StoryPointless"
        )
        allProposals = try await store.fetchKnowledgePageProposals(
          productID: item.productID
        )
        proposals = allProposals.filter { proposal in
          proposal.candidateRevisionID == candidate.id
        }
      }
      guard !proposals.contains(where: { $0.status == .proposed || $0.status == .reviewed }) else {
        throw PersistenceError.corruptData(
          "Accept or reject every canonical knowledge proposal before completing the ticket."
        )
      }
      let repositoryURL = try Self.productWorkspaceURL(productID: item.productID)
      try await gitWorkspaceManager.promote(
        repositoryURL: repositoryURL,
        integratedSHA: integratedSHA
      )
      _ = try await store.updateCandidateRevision(id: candidate.id, status: .accepted)
      _ = try await store.transitionWorkItem(
        id: current.id,
        to: .readyToRelease,
        actor: "Product Owner",
        reason: "Demo approved"
      )
      _ = try await store.transitionWorkItem(
        id: current.id,
        to: .released,
        actor: "Product Owner",
        reason: "Accepted outcome completed"
      )
      _ = try await store.appendComment(
        workItemID: current.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "Product Owner approved candidate v\(candidate.version). Integrated revision \(String(integratedSHA.prefix(8))) is now the accepted trunk."
      )
      if let activePlan = sprintPlan,
        activePlan.sprint.state == .active,
        activePlan.items.contains(where: { $0.workItemID == current.id })
      {
        _ = try await store.completeSprintIfFinished(id: activePlan.sprint.id)
      }
      if let integrationPath = candidate.integrationWorktreePath {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
      try? await gitWorkspaceManager.removeTicketWorkspace(
        repositoryURL: repositoryURL,
        worktreeURL: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true),
        branchName: candidate.branchName
      )
      await reloadSelectedProduct()
      scheduleSprintExecution()
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProduct()
      return false
    }
  }

  func decideKnowledgePageProposal(
    _ proposal: KnowledgePageProposal,
    accept: Bool
  ) async -> Bool {
    guard let store else { return false }
    do {
      let candidate = candidateRevisions.first {
        $0.id == proposal.candidateRevisionID
      }
      _ = try await store.decideKnowledgePageProposal(
        id: proposal.id,
        accept: accept,
        authorName: "Me"
      )
      if
        accept,
        let candidate,
        let integrationPath = candidate.integrationWorktreePath
      {
        do {
          let pages = try await store.fetchKnowledgePages(productID: proposal.productID)
          let integrationURL = URL(fileURLWithPath: integrationPath, isDirectory: true)
          try Self.syncKnowledgeMarkdownFiles(
            at: integrationURL,
            pages: pages
          )
          let ticketKey = workItems.first { $0.id == proposal.workItemID }?.key ?? "Ticket"
          let integratedSHA = try await gitWorkspaceManager.checkpointWorkspace(
            at: integrationURL,
            message: "\(ticketKey): accept canonical knowledge"
          )
          _ = try await store.updateCandidateRevision(
            id: candidate.id,
            status: candidate.status,
            integratedSHA: integratedSHA
          )
        } catch {
          _ = try? await store.updateCandidateRevision(
            id: candidate.id,
            status: .failed
          )
          throw error
        }
      }
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProduct()
      return false
    }
  }

  @discardableResult
  private func publishReviewedKnowledgePageProposals(
    candidate: CandidateRevision,
    workItem: WorkItem,
    authorName: String
  ) async throws -> Int {
    guard let store else { return 0 }
    let reviewedProposals = try await store.fetchKnowledgePageProposals(
      productID: candidate.productID
    ).filter {
      $0.candidateRevisionID == candidate.id && $0.status == .reviewed
    }
    guard !reviewedProposals.isEmpty else { return 0 }
    guard let integrationPath = candidate.integrationWorktreePath else {
      throw PersistenceError.corruptData(
        "Reviewed knowledge changes have no integration workspace."
      )
    }

    for proposal in reviewedProposals {
      _ = try await store.decideKnowledgePageProposal(
        id: proposal.id,
        accept: true,
        authorName: authorName
      )
    }

    let pages = try await store.fetchKnowledgePages(productID: candidate.productID)
    let integrationURL = URL(fileURLWithPath: integrationPath, isDirectory: true)
    try Self.syncKnowledgeMarkdownFiles(at: integrationURL, pages: pages)
    let integratedSHA = try await gitWorkspaceManager.checkpointWorkspace(
      at: integrationURL,
      message: "\(workItem.key): publish reviewed knowledge"
    )
    let currentCandidate = try await store.fetchCandidateRevision(id: candidate.id)
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: currentCandidate.status,
      integratedSHA: integratedSHA
    )
    _ = try await store.appendComment(
      workItemID: workItem.id,
      authorKind: .system,
      authorName: "StoryPointless",
      body: "Published \(reviewedProposals.count) Tech Lead-reviewed knowledge change\(reviewedProposals.count == 1 ? "" : "s") automatically. The full content and revision history remain available in Knowledge."
    )
    return reviewedProposals.count
  }

  func sendSprintPlanningMessage(
    for item: WorkItem,
    to recipient: AgentProfile,
    ownerMessage: String,
    ticketSnapshot: SprintPlanningTicketSnapshot,
    proposedAssignee: AgentProfile?
  ) async throws -> SprintPlanningConversationReply {
    guard
      !isPlanningMessageRunning,
      suggestionBatch?.session.status != .generating,
      refiningWorkItemID == nil,
      !isTicketConversationMessageRunning
    else {
      throw SprintPlanningConversationError.anotherCodexTaskIsRunning
    }
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct,
      product.id == item.productID
    else {
      throw CodexClientError.notConnected
    }
    guard recipient.productID == product.id, profiles.contains(where: { $0.id == recipient.id }) else {
      throw CodexClientError.notConnected
    }
    let trimmedMessage = ownerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      throw SprintPlanningConversationError.invalidResponse("Enter a message first.")
    }

    isPlanningMessageRunning = true
    defer {
      isPlanningMessageRunning = false
      activePlanningTurn = nil
    }

    let comments = try await store.fetchComments(workItemID: item.id)
    let currentMessageBody = "@\(recipient.name) \(trimmedMessage)"
    let priorComments = comments.last?.authorKind == .owner
      && comments.last?.body == currentMessageBody
      ? Array(comments.dropLast())
      : comments
    let prerequisiteIDs = Set(
      dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    let prerequisites = workItems.filter { prerequisiteIDs.contains($0.id) }
    let sprintItemIDs = Set(candidateSprintPlan?.items.map(\.workItemID) ?? [])
    let scopedItems = workItems.filter { sprintItemIDs.contains($0.id) }
    let conversationKey = PlanningConversationKey(
      workItemID: item.id,
      profileID: recipient.id
    )
    do {
      let threadID: String
      if let existingThreadID = planningThreadIDs[conversationKey] {
        threadID = existingThreadID
      } else {
        let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
        threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: CodexSprintPlanningConversation.developerInstructions(
            productInstructions: inheritedAgentInstructions(for: product),
            personaInstructions: recipient.effectiveInstructions,
            recipient: recipient
          ),
          model: recipient.model
        )
        planningThreadIDs[conversationKey] = threadID
      }
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexSprintPlanningConversation.prompt(
          product: product,
          itemKey: item.key,
          snapshot: ticketSnapshot,
          prerequisites: prerequisites,
          sprintItems: scopedItems,
          proposedAssignee: proposedAssignee,
          previousComments: priorComments,
          ownerMessage: trimmedMessage
        ),
        effort: recipient.reasoningEffort,
        outputSchema: CodexSprintPlanningConversation.outputSchema
      )
      activePlanningTurn = (threadID: threadID, turnID: turnID)
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let reply = try CodexSprintPlanningConversation.decode(response)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: recipient.name,
        body: reply.ticketCommentBody
      )
      if selectedProductID == product.id {
        activity = try await store.fetchActivity(productID: product.id)
      }
      return reply
    } catch {
      planningThreadIDs.removeValue(forKey: conversationKey)
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "\(recipient.name) couldn't reply: \(error.localizedDescription)"
      )
      throw error
    }
  }

  func cancelSprintPlanningMessage() {
    guard let client = codexClient, let activePlanningTurn else { return }
    Task {
      try? await client.interruptTurn(
        threadID: activePlanningTurn.threadID,
        turnID: activePlanningTurn.turnID
      )
    }
  }

  func addToCandidateSprint(_ workItem: WorkItem) {
    addToCandidateSprint([workItem])
  }

  func addToCandidateSprint(_ selectedItems: [WorkItem]) {
    guard
      let store,
      let productID = selectedProductID,
      canEditCandidateSprint,
      !selectedItems.isEmpty
    else { return }

    let candidatePlan = candidateSprintPlan
    let existingIDs = Set(candidatePlan?.items.map(\.workItemID) ?? [])
    let selectedIDs = Set(selectedItems.map(\.id)).subtracting(existingIDs)
    guard !selectedIDs.isEmpty else { return }
    let availableIDs = existingIDs
      .union(selectedIDs)
      .union(externalCandidatePrerequisiteIDs)
    if let missingEdge = dependencies.first(where: {
      selectedIDs.contains($0.workItemID) && !availableIDs.contains($0.dependsOnWorkItemID)
    }),
      let dependent = workItems.first(where: { $0.id == missingEdge.workItemID }),
      let prerequisite = workItems.first(where: { $0.id == missingEdge.dependsOnWorkItemID })
    {
      errorMessage = "Also select \(prerequisite.key); \(dependent.key) depends on it."
      return
    }

    let currentInputs: [SprintDraftItemInput] = candidatePlan?.items.map { sprintItem in
      let workItem = workItems.first { $0.id == sprintItem.workItemID }
      return SprintDraftItemInput(
        workItemID: sprintItem.workItemID,
        implementerProfileID: sprintItem.implementerProfileID
          ?? workItem?.ownerProfileID
          ?? workItem.flatMap {
            TicketOwnerRouter.owner(for: $0, profiles: profiles)?.id
          },
        reviewerProfileID: sprintItem.reviewerProfileID,
        estimatedTokens: sprintItem.estimatedTokens
      )
    } ?? []
    let newInputs: [SprintDraftItemInput] = workItems
      .filter { selectedIDs.contains($0.id) }
      .map { item in
        let ownerID = item.ownerProfileID
          ?? TicketOwnerRouter.owner(for: item, profiles: profiles)?.id
        return SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: ownerID,
          estimatedTokens: 0
        )
      }
    let inputs = currentInputs + newInputs

    Task {
      do {
        for input in newInputs {
          guard
            let ownerID = input.implementerProfileID,
            workItems.first(where: { $0.id == input.workItemID })?.ownerProfileID == nil
          else { continue }
          _ = try await store.assignWorkItemOwner(id: input.workItemID, profileID: ownerID)
        }
        _ = try await store.saveDraftSprint(
          productID: productID,
          goal: candidatePlan?.sprint.goal ?? "Next valuable increment",
          tokenBudgetLimit: nil,
          concurrencyLimit: candidatePlan?.sprint.concurrencyLimit ?? 4,
          items: inputs
        )
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func removeFromCandidateSprint(_ workItem: WorkItem) {
    removeFromCandidateSprint([workItem])
  }

  func removeFromCandidateSprint(_ selectedItems: [WorkItem]) {
    guard
      let store,
      let productID = selectedProductID,
      let plan = candidateSprintPlan,
      !selectedItems.isEmpty
    else { return }

    let candidateIDs = Set(plan.items.map(\.workItemID))
    let selectedIDs = Set(selectedItems.map(\.id)).intersection(candidateIDs)
    guard !selectedIDs.isEmpty else { return }
    let remainingIDs = candidateIDs.subtracting(selectedIDs)
    if let dependentEdge = dependencies.first(where: {
      selectedIDs.contains($0.dependsOnWorkItemID) && remainingIDs.contains($0.workItemID)
    }),
      let dependent = workItems.first(where: { $0.id == dependentEdge.workItemID }),
      let prerequisite = workItems.first(where: { $0.id == dependentEdge.dependsOnWorkItemID })
    {
      errorMessage = "Also select \(dependent.key); it depends on \(prerequisite.key)."
      return
    }

    let inputs = plan.items.compactMap { item -> SprintDraftItemInput? in
      guard !selectedIDs.contains(item.workItemID) else { return nil }
      return SprintDraftItemInput(
        workItemID: item.workItemID,
        implementerProfileID: item.implementerProfileID
          ?? workItems.first(where: { $0.id == item.workItemID })?.ownerProfileID,
        reviewerProfileID: item.reviewerProfileID,
        estimatedTokens: item.estimatedTokens
      )
    }
    Task {
      do {
        _ = try await store.saveDraftSprint(
          productID: productID,
          goal: plan.sprint.goal,
          tokenBudgetLimit: nil,
          concurrencyLimit: plan.sprint.concurrencyLimit,
          items: inputs
        )
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func dropPlanningItems(
    _ selectedItems: [WorkItem],
    intoCandidateSprint: Bool,
    before targetID: UUID?
  ) {
    guard
      let store,
      let productID = selectedProductID,
      canEditCandidateSprint,
      !selectedItems.isEmpty
    else { return }

    let movingIDs = Set(selectedItems.map(\.id))
    let candidatePlan = candidateSprintPlan
    let existingCandidateIDs = Set(candidatePlan?.items.map(\.workItemID) ?? [])
    let desiredCandidateIDs = intoCandidateSprint
      ? existingCandidateIDs.union(movingIDs)
      : existingCandidateIDs.subtracting(movingIDs)
    let availableCandidateIDs = desiredCandidateIDs.union(externalCandidatePrerequisiteIDs)

    if let invalidEdge = dependencies.first(where: {
      desiredCandidateIDs.contains($0.workItemID)
        && !availableCandidateIDs.contains($0.dependsOnWorkItemID)
    }),
      let dependent = workItems.first(where: { $0.id == invalidEdge.workItemID }),
      let prerequisite = workItems.first(where: { $0.id == invalidEdge.dependsOnWorkItemID })
    {
      errorMessage = intoCandidateSprint
        ? "Also move \(prerequisite.key); \(dependent.key) depends on it."
        : "Also move \(dependent.key); it depends on \(prerequisite.key)."
      return
    }

    let existingItemsByID = Dictionary(
      uniqueKeysWithValues: (candidatePlan?.items ?? []).map { ($0.workItemID, $0) }
    )
    let shouldSaveSprint = desiredCandidateIDs != existingCandidateIDs
      || !movingIDs.isDisjoint(with: existingCandidateIDs)

    Task {
      do {
        let reorderedItems = try await store.moveWorkItems(
          ids: selectedItems.map(\.id),
          before: targetID
        )
        if shouldSaveSprint {
          let inputs = reorderedItems.compactMap { item -> SprintDraftItemInput? in
            guard desiredCandidateIDs.contains(item.id) else { return nil }
            let existing = existingItemsByID[item.id]
            return SprintDraftItemInput(
              workItemID: item.id,
              implementerProfileID: existing?.implementerProfileID
                ?? item.ownerProfileID
                ?? TicketOwnerRouter.owner(for: item, profiles: profiles)?.id,
              reviewerProfileID: existing?.reviewerProfileID,
              estimatedTokens: existing?.estimatedTokens ?? 0
            )
          }
          _ = try await store.saveDraftSprint(
            productID: productID,
            goal: candidatePlan?.sprint.goal ?? "Next valuable increment",
            tokenBudgetLimit: nil,
            concurrencyLimit: candidatePlan?.sprint.concurrencyLimit ?? 4,
            items: inputs
          )
        }
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
        await reloadSelectedProduct()
      }
    }
  }

  var canEditCandidateSprint: Bool {
    selectedProductID != nil
  }

  private var externalCandidatePrerequisiteIDs: Set<UUID> {
    var ids = Set(
      workItems
        .filter { $0.state == .released }
        .map(\.id)
    )
    if let activePlan = sprintPlan, activePlan.sprint.state == .active {
      ids.formUnion(activePlan.items.map(\.workItemID))
    }
    return ids
  }

  func planEpic(_ epic: Epic) {
    guard
      canPlanEpic,
      let product = selectedProduct,
      epic.productID == product.id
    else { return }

    epicPlanningTask?.cancel()
    epicPlanningConversation = EpicPlanningConversationState(
      epicID: epic.id,
      messages: [],
      questions: [],
      isRunning: true,
      isGeneratingPlan: false,
      isComplete: false,
      errorMessage: nil
    )
    epicPlanningTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard let client = codexClient else { throw CodexClientError.notConnected }
        let analyst = profiles.first { $0.role == .businessAnalyst }
        let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
        let threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
            productInstructions: inheritedAgentInstructions(for: product),
            personaInstructions:
              analyst?.effectiveInstructions
              ?? AgentPersonaDefaults.instructions(for: .businessAnalyst)
          ),
          model: analyst?.model
        )
        epicPlanningThreadID = threadID
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexEpicClarificationGenerator.initialPrompt(
            product: product,
            epic: epic,
            existingItems: workItems
          ),
          effort: analyst?.reasoningEffort ?? "medium",
          outputSchema: CodexEpicClarificationGenerator.outputSchema
        )
        activeEpicPlanningTurn = (threadID: threadID, turnID: turnID)
        let response = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        let reply = try CodexEpicClarificationGenerator.decode(response)
        activeEpicPlanningTurn = nil
        receiveEpicClarification(reply, for: epic)
      } catch is CancellationError {
        activeEpicPlanningTurn = nil
        updateEpicPlanningConversation {
          $0.isRunning = false
          $0.errorMessage = "Epic planning was interrupted. You can safely continue."
        }
      } catch {
        activeEpicPlanningTurn = nil
        updateEpicPlanningConversation {
          $0.isRunning = false
          $0.errorMessage = error.localizedDescription
        }
      }
    }
  }

  func continueEpicPlanning(_ epic: Epic, answers: [String]) {
    guard
      !answers.isEmpty,
      epicPlanningConversation?.epicID == epic.id,
      epicPlanningConversation?.isRunning == false,
      epicPlanningConversation?.isGeneratingPlan == false,
      let threadID = epicPlanningThreadID,
      let client = codexClient,
      let analyst = profiles.first(where: { $0.role == .businessAnalyst })
    else { return }

    updateEpicPlanningConversation {
      $0.messages.append(
        EpicPlanningConversationMessage(
          author: .owner,
          body: answers.joined(separator: "\n")
        )
      )
      $0.questions = []
      $0.isRunning = true
      $0.errorMessage = nil
    }
    epicPlanningTask?.cancel()
    epicPlanningTask = Task { [weak self] in
      guard let self else { return }
      do {
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexEpicClarificationGenerator.followUpPrompt(answers: answers),
          effort: analyst.reasoningEffort,
          outputSchema: CodexEpicClarificationGenerator.outputSchema
        )
        activeEpicPlanningTurn = (threadID: threadID, turnID: turnID)
        let response = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        let reply = try CodexEpicClarificationGenerator.decode(response)
        activeEpicPlanningTurn = nil
        receiveEpicClarification(reply, for: epic)
      } catch is CancellationError {
        activeEpicPlanningTurn = nil
        updateEpicPlanningConversation {
          $0.isRunning = false
          $0.errorMessage = "The Business Analyst stopped. Your answers are still visible."
        }
      } catch {
        activeEpicPlanningTurn = nil
        updateEpicPlanningConversation {
          $0.isRunning = false
          $0.errorMessage = error.localizedDescription
        }
      }
    }
  }

  func cancelEpicPlanning() {
    epicPlanningTask?.cancel()
    if let client = codexClient, let activeEpicPlanningTurn {
      Task {
        try? await client.interruptTurn(
          threadID: activeEpicPlanningTurn.threadID,
          turnID: activeEpicPlanningTurn.turnID
        )
      }
    }
  }

  func clearEpicPlanningConversation(for epicID: UUID) {
    guard epicPlanningConversation?.epicID == epicID else { return }
    epicPlanningTask?.cancel()
    epicPlanningTask = nil
    epicPlanningThreadID = nil
    activeEpicPlanningTurn = nil
    epicPlanningConversation = nil
  }

  private func receiveEpicClarification(
    _ reply: EpicClarificationReply,
    for epic: Epic
  ) {
    updateEpicPlanningConversation {
      $0.messages.append(
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: reply.message
        )
      )
      $0.questions = reply.questions
      $0.isRunning = false
    }
    if reply.readyToPlan {
      generateEpicPlan(epic)
    }
  }

  private func generateEpicPlan(_ epic: Epic) {
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct,
      let threadID = epicPlanningThreadID
    else { return }

    let analyst = profiles.first { $0.role == .businessAnalyst }
    let existingItems = workItems.filter { $0.state != .cancelled }
    let previouslyRejectedSuggestions =
      suggestionBatch?.session.epicID == epic.id
      ? suggestionBatch?.suggestions.filter { $0.status == .rejected } ?? []
      : []
    updateEpicPlanningConversation {
      $0.isRunning = false
      $0.isGeneratingPlan = true
      $0.errorMessage = nil
    }
    epicPlanningTask?.cancel()
    epicPlanningTask = Task { [weak self] in
      guard let self else { return }
      var session: SuggestionSession?
      do {
        let startedSession = try await store.beginTicketSuggestionSession(
          productID: product.id,
          epicID: epic.id
        )
        session = startedSession
        suggestionBatch = TicketSuggestionBatch(session: startedSession, suggestions: [])

        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexEpicClarificationGenerator.finalPlanPrompt(
            product: product,
            epic: epic,
            existingItems: existingItems,
            rejectedSuggestions: previouslyRejectedSuggestions
          ),
          effort: analyst?.reasoningEffort ?? "medium",
          outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema
        )
        activeEpicPlanningTurn = (threadID: threadID, turnID: turnID)
        try await store.attachCodexTurn(
          sessionID: startedSession.id,
          threadID: threadID,
          turnID: turnID
        )
        let response = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        let plan: EpicPlanDraft
        do {
          plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            response,
            existingItems: existingItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          let repairTurnID = try await client.startStructuredTurn(
            threadID: threadID,
            prompt:
              CodexTicketSuggestionGenerator.repairPrompt(
                validationError: validationError.localizedDescription,
                existingItems: existingItems
              )
              + "\nReturn the complete corrected epic metadata and ticket plan.",
            effort: analyst?.reasoningEffort ?? "medium",
            outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema
          )
          activeEpicPlanningTurn = (threadID: threadID, turnID: repairTurnID)
          try await store.attachCodexTurn(
            sessionID: startedSession.id,
            threadID: threadID,
            turnID: repairTurnID
          )
          let repairedResponse = try await client.waitForFinalAgentMessage(
            threadID: threadID,
            turnID: repairTurnID
          )
          try Task.checkCancellation()
          plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            repairedResponse,
            existingItems: existingItems
          )
        }

        _ = try await store.updateEpic(
          id: epic.id,
          title: plan.title,
          goal: plan.goal,
          successCriteria: plan.successCriteria,
          constraints: plan.constraints,
          status: .active
        )
        suggestionBatch = try await store.completeTicketSuggestionSession(
          sessionID: startedSession.id,
          drafts: plan.ticketSuggestions
        )
        activeEpicPlanningTurn = nil
        await reloadSelectedProduct()
        updateEpicPlanningConversation {
          $0.messages.append(
            EpicPlanningConversationMessage(
              author: .businessAnalyst,
              body:
                "I’ve prepared the epic and \(plan.ticketSuggestions.count) proposed "
                + (plan.ticketSuggestions.count == 1 ? "ticket" : "tickets")
                + " for you to review in the backlog."
            )
          )
          $0.isGeneratingPlan = false
          $0.isComplete = true
        }
      } catch is CancellationError {
        activeEpicPlanningTurn = nil
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Epic planning was interrupted. You can safely try again."
          )
        }
        updateEpicPlanningConversation {
          $0.isGeneratingPlan = false
          $0.errorMessage = "Epic planning was interrupted. You can safely try again."
        }
      } catch {
        activeEpicPlanningTurn = nil
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: error.localizedDescription
          )
          suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(
            productID: product.id
          )
        }
        updateEpicPlanningConversation {
          $0.isGeneratingPlan = false
          $0.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func updateEpicPlanningConversation(
    _ update: (inout EpicPlanningConversationState) -> Void
  ) {
    guard var conversation = epicPlanningConversation else { return }
    update(&conversation)
    epicPlanningConversation = conversation
  }

  func retryCurrentEpicPlan() {
    guard
      let epicID = suggestionBatch?.session.epicID,
      let epic = epics.first(where: { $0.id == epicID })
    else { return }
    dismissFailedTicketSuggestions()
    Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .milliseconds(150))
      planEpic(epic)
    }
  }

  func autosuggestTickets() {
    guard
      canAutosuggestTickets,
      let store,
      let client = codexClient,
      let product = selectedProduct
    else { return }

    let previouslyRejectedSuggestions = suggestionBatch?.suggestions.filter {
      $0.status == .rejected
    } ?? []
    suggestionTask?.cancel()
    suggestionTask = Task { [weak self] in
      guard let self else { return }
      var session: SuggestionSession?
      do {
        let startedSession = try await store.beginTicketSuggestionSession(productID: product.id)
        session = startedSession
        suggestionBatch = TicketSuggestionBatch(session: startedSession, suggestions: [])

        let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
        let analyst = profiles.first { $0.role == .businessAnalyst }
        let threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
            productInstructions: inheritedAgentInstructions(for: product),
            personaInstructions:
              analyst?.effectiveInstructions
              ?? AgentPersonaDefaults.instructions(for: .businessAnalyst)
          ),
          model: analyst?.model
        )
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexTicketSuggestionGenerator.prompt(
            product: product,
            existingItems: workItems.filter { $0.state != .cancelled },
            rejectedSuggestions: previouslyRejectedSuggestions
          ),
          effort: analyst?.reasoningEffort ?? "medium",
          outputSchema: CodexTicketSuggestionGenerator.outputSchema
        )
        try await store.attachCodexTurn(
          sessionID: startedSession.id,
          threadID: threadID,
          turnID: turnID
        )

        let response = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        let drafts: [TicketSuggestionDraft]
        do {
          drafts = try CodexTicketSuggestionGenerator.decode(
            response,
            existingItems: workItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          let repairTurnID = try await client.startStructuredTurn(
            threadID: threadID,
            prompt: CodexTicketSuggestionGenerator.repairPrompt(
              validationError: validationError.localizedDescription,
              existingItems: workItems
            ),
            effort: analyst?.reasoningEffort ?? "medium",
            outputSchema: CodexTicketSuggestionGenerator.outputSchema
          )
          try await store.attachCodexTurn(
            sessionID: startedSession.id,
            threadID: threadID,
            turnID: repairTurnID
          )
          let repairedResponse = try await client.waitForFinalAgentMessage(
            threadID: threadID,
            turnID: repairTurnID
          )
          try Task.checkCancellation()
          drafts = try CodexTicketSuggestionGenerator.decode(
            repairedResponse,
            existingItems: workItems
          )
        }
        suggestionBatch = try await store.completeTicketSuggestionSession(
          sessionID: startedSession.id,
          drafts: drafts
        )
        await reloadSelectedProduct()
      } catch is CancellationError {
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Ticket suggestion was interrupted. You can safely try again."
          )
          suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(
            productID: product.id
          )
        }
      } catch {
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: error.localizedDescription
          )
          suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(
            productID: product.id
          )
        } else {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  func decideTicketSuggestion(_ suggestion: TicketSuggestion, accept: Bool) {
    guard let store, let productID = selectedProductID, !isDecidingSuggestions else { return }
    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        suggestionBatch = try await store.decideTicketSuggestion(
          id: suggestion.id,
          decision: accept ? .accepted : .rejected
        )
        if accept,
          let acceptedID = suggestionBatch?.suggestions
            .first(where: { $0.id == suggestion.id })?.acceptedWorkItemID,
          let created = try await store.fetchWorkItems(productID: productID)
            .first(where: { $0.id == acceptedID }),
          let owner = TicketOwnerRouter.owner(
            for: created,
            profiles: profiles,
            suggestedRole: suggestion.suggestedRole
          )
        {
          _ = try await store.assignWorkItemOwner(id: created.id, profileID: owner.id)
        }
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func decideAllTicketSuggestions(accept: Bool) {
    guard
      let suggestions = suggestionBatch?.suggestions
        .filter({ $0.status == .proposed })
        .sorted(by: { $0.position < $1.position })
    else { return }
    decideTicketSuggestionGroup(suggestions, accept: accept)
  }

  func decideTicketSuggestionGroup(_ suggestions: [TicketSuggestion], accept: Bool) {
    guard
      let store,
      let productID = selectedProductID,
      !isDecidingSuggestions,
      !suggestions.isEmpty
    else { return }
    let proposedIDs = Set(
      suggestionBatch?.suggestions
        .filter { $0.status == .proposed }
        .map(\.id) ?? []
    )
    let decisions = suggestions
      .filter { proposedIDs.contains($0.id) }
      .sorted { $0.position < $1.position }
    guard !decisions.isEmpty else { return }

    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        for suggestion in decisions {
          suggestionBatch = try await store.decideTicketSuggestion(
            id: suggestion.id,
            decision: accept ? .accepted : .rejected
          )
          if accept,
            let acceptedID = suggestionBatch?.suggestions
              .first(where: { $0.id == suggestion.id })?.acceptedWorkItemID,
            let created = try await store.fetchWorkItems(productID: productID)
              .first(where: { $0.id == acceptedID }),
            let owner = TicketOwnerRouter.owner(
              for: created,
              profiles: profiles,
              suggestedRole: suggestion.suggestedRole
            )
          {
            _ = try await store.assignWorkItemOwner(id: created.id, profileID: owner.id)
          }
        }
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func dismissFailedTicketSuggestions() {
    guard
      let store,
      let session = suggestionBatch?.session,
      session.status == .failed
    else { return }
    Task {
      do {
        try await store.dismissTicketSuggestionSession(sessionID: session.id)
        suggestionBatch = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateProfile(
    _ profile: AgentProfile,
    model: String? = nil,
    effort: String? = nil,
    customInstructions: String? = nil,
    updateInstructions: Bool = false
  ) {
    guard let store else { return }
    let selectedModel = model ?? profile.model
    let modelOption = codexModels.first { $0.model == selectedModel }
    let supportedEfforts = modelOption?.supportedReasoningEfforts.map(\.id) ?? []
    let selectedEffort: String
    if let effort {
      selectedEffort = effort
    } else if model != nil, !supportedEfforts.contains(profile.reasoningEffort) {
      selectedEffort = modelOption?.defaultReasoningEffort ?? profile.reasoningEffort
    } else {
      selectedEffort = profile.reasoningEffort
    }
    let instructions = updateInstructions ? customInstructions : profile.customInstructions

    Task {
      do {
        _ = try await store.updateAgentProfileConfiguration(
          id: profile.id,
          model: selectedModel,
          reasoningEffort: selectedEffort,
          customInstructions: instructions
        )
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateProductInstructions(_ instructions: String) {
    guard let store, let productID = selectedProductID else { return }
    Task {
      do {
        try await store.updateProductInstructions(
          productID: productID,
          instructions: instructions
        )
        await reload()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateProductDetails(name: String, vision: String) {
    guard let store, let productID = selectedProductID else { return }
    Task {
      do {
        try await store.updateProductDetails(
          productID: productID,
          name: name,
          vision: vision
        )
        await reload()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateTeamSettings(
    productInstructions: String,
    modelsByProfile: [UUID: String],
    effortsByProfile: [UUID: String],
    customInstructionsByProfile: [UUID: String]
  ) {
    guard let store, let productID = selectedProductID else { return }
    let currentProfiles = profiles
    Task {
      do {
        try await store.updateProductInstructions(
          productID: productID,
          instructions: productInstructions
        )
        for profile in currentProfiles {
          _ = try await store.updateAgentProfileConfiguration(
            id: profile.id,
            model: modelsByProfile[profile.id] ?? profile.model,
            reasoningEffort: effortsByProfile[profile.id] ?? profile.reasoningEffort,
            customInstructions: customInstructionsByProfile[profile.id]
          )
        }
        await reload()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func createCustomPersona(
    name: String,
    capability: AgentRole,
    model: String,
    effort: String,
    instructions: String
  ) {
    guard let store, let productID = selectedProductID else { return }
    Task {
      do {
        _ = try await store.createCustomAgentProfile(
          productID: productID,
          name: name,
          capability: capability,
          model: model,
          reasoningEffort: effort,
          instructions: instructions
        )
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func archiveCustomPersona(_ profile: AgentProfile) {
    guard let store, !profile.isBuiltIn else { return }
    Task {
      do {
        try await store.archiveCustomAgentProfile(id: profile.id)
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func modelOption(for profile: AgentProfile) -> CodexModelOption? {
    codexModels.first { $0.model == profile.model }
  }

  func reasoningEfforts(for profile: AgentProfile) -> [CodexReasoningEffortOption] {
    modelOption(for: profile)?.supportedReasoningEfforts ?? [
      CodexReasoningEffortOption(id: profile.reasoningEffort, description: "Current selection")
    ]
  }

  func saveSprintPlan(
    goal: String,
    concurrencyLimit: Int,
    items: [SprintDraftItemInput]
  ) async -> Bool {
    guard let store, let productID = selectedProductID else { return false }
    do {
      for input in items {
        guard
          let ownerID = input.implementerProfileID,
          workItems.first(where: { $0.id == input.workItemID })?.ownerProfileID != ownerID
        else { continue }
        _ = try await store.assignWorkItemOwner(id: input.workItemID, profileID: ownerID)
      }
      let savedPlan = try await store.saveDraftSprint(
        productID: productID,
        goal: goal,
        tokenBudgetLimit: nil,
        concurrencyLimit: concurrencyLimit,
        items: items
      )
      if sprintPlan?.sprint.state != .active {
        sprintPlan = savedPlan
      }
      sprintReadinessIssues = try await store.sprintReadinessIssues(
        sprintID: savedPlan.sprint.id
      )
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func reassignDraftTicket(workItemID: UUID, to profileID: UUID) async -> Bool {
    guard
      let plan = candidateSprintPlan,
      profiles.contains(where: { $0.id == profileID && $0.role.canOwnDelivery })
    else { return false }
    let inputs = plan.items.map { sprintItem in
      SprintDraftItemInput(
        workItemID: sprintItem.workItemID,
        implementerProfileID: sprintItem.workItemID == workItemID
          ? profileID
          : sprintItem.implementerProfileID,
        reviewerProfileID: sprintItem.reviewerProfileID,
        estimatedTokens: sprintItem.estimatedTokens
      )
    }
    return await saveSprintPlan(
      goal: plan.sprint.goal,
      concurrencyLimit: plan.sprint.concurrencyLimit,
      items: inputs
    )
  }

  func assignTicketOwner(workItemID: UUID, to profileID: UUID) async -> Bool {
    if candidateSprintPlan?.items.contains(where: { $0.workItemID == workItemID }) == true
    {
      return await reassignDraftTicket(workItemID: workItemID, to: profileID)
    }
    guard
      let store,
      profiles.contains(where: { $0.id == profileID && $0.role.canOwnDelivery })
    else { return false }
    do {
      _ = try await store.assignWorkItemOwner(id: workItemID, profileID: profileID)
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func startSprint() async -> Bool {
    guard
      let store,
      let plan = candidateSprintPlan,
      plan.sprint.state == .draft
    else { return false }
    let sprintID = plan.sprint.id
    do {
      let issues = try await store.sprintReadinessIssues(sprintID: sprintID)
      sprintReadinessIssues = issues
      guard issues.isEmpty else { return false }

      sprintPlan = try await store.startSprint(id: sprintID)
      await reloadSelectedProduct()
      scheduleSprintExecution()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func scheduleSprintExecution() {
    guard
      sprintExecutionTask == nil,
      codexClient != nil,
      let productID = selectedProductID,
      let plan = sprintPlan,
      plan.sprint.productID == productID,
      plan.sprint.state == .active
    else { return }

    sprintExecutionTask = Task { [weak self] in
      guard let self else { return }
      await drainSprintQueue(productID: productID)
    }
  }

  private func drainSprintQueue(productID: UUID) async {
    defer {
      sprintExecutionTask = nil
    }
    await recoverOrphanedExecutionRuns(productID: productID)

    while !Task.isCancelled, selectedProductID == productID {
      await reloadSelectedProduct()
      guard
        let plan = sprintPlan,
        plan.sprint.productID == productID,
        plan.sprint.state == .active
      else { return }

      let eligibleRuns = eligibleImplementationRuns(in: plan)
      for run in eligibleRuns where activeImplementationTasks[run.id] == nil {
        activeImplementationTasks[run.id] = Task { [weak self] in
          guard let self else { return }
          await executeImplementationRun(run, plan: plan)
          activeImplementationTasks.removeValue(forKey: run.id)
        }
      }

      let processedIntegration = await processNextIntegrationCandidate(plan: plan)
      if activeImplementationTasks.isEmpty && eligibleRuns.isEmpty && !processedIntegration {
        return
      }
      try? await Task.sleep(for: .milliseconds(300))
    }
  }

  private func recoverOrphanedExecutionRuns(productID: UUID) async {
    guard
      let store,
      let client = codexClient,
      let plan = sprintPlan,
      plan.sprint.state == .active
    else { return }
    let storedCandidates = (try? await store.fetchCandidateRevisions(productID: productID)) ?? []
    let implementerByItemID = Dictionary(
      uniqueKeysWithValues: plan.items.compactMap { item in
        item.implementerProfileID.map { (item.workItemID, $0) }
      }
    )
    for candidate in storedCandidates where candidate.status == .readyForDemo {
      guard
        let item = workItems.first(where: { $0.id == candidate.workItemID }),
        let implementationRun = try? await store.fetchAgentRun(
          id: candidate.implementationRunID
        )
      else { continue }
      do {
        let result = try CodexTicketExecutor.decode(candidate.executionResultJSON)
        try await validateDeliveryEvidence(
          result,
          workspaceURL: URL(
            fileURLWithPath: candidate.worktreePath,
            isDirectory: true
          )
        )
        continue
      } catch is TicketExecutionGenerationError {
        if let integrationPath = candidate.integrationWorktreePath {
          try? await gitWorkspaceManager.removeWorktree(
            repositoryURL: Self.productWorkspaceURL(productID: productID),
            worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
          )
        }
        _ = try? await store.updateCandidateRevision(
          id: candidate.id,
          status: .superseded
        )
        try? await store.markKnowledgePageProposals(
          candidateRevisionID: candidate.id,
          status: .superseded
        )
        if item.state == .acceptance {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .running,
            actor: "StoryPointless",
            reason: "The candidate contained no inspectable delivery artefact"
          )
        }
        _ = try? await store.updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "StoryPointless",
          eventDetail: "Empty candidate returned to the assigned specialist"
        )
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "StoryPointless",
          body: "Candidate v\(candidate.version) contained no inspectable ticket artefact or meaningful review evidence. I returned the preserved workspace to the assigned specialist to complete the actual delivery."
        )
      } catch {
        continue
      }
    }
    for run in runs where
      run.productID == productID
        && (run.status == .running || run.status == .failed)
        && implementerByItemID[run.workItemID] == run.profileID
    {
      guard
        let threadID = run.codexThreadID,
        let response = try? await client.latestCompletedAgentMessage(threadID: threadID),
        let workspacePath = run.worktreePath
      else { continue }
      do {
        let result = try CodexTicketExecutor.decode(response)
        try await validateDeliveryEvidence(
          result,
          workspaceURL: URL(fileURLWithPath: workspacePath, isDirectory: true)
        )
        await processExecutionResult(
          result,
          implementationRunID: run.id,
          reviewCycle: 0,
          plan: plan
        )
      } catch {
        // Only a valid durable final response can supersede a stale run state.
      }
    }
    for run in runs where run.productID == productID && run.status == .running {
      guard implementerByItemID[run.workItemID] == run.profileID else {
        let runCandidates = storedCandidates.filter {
          $0.workItemID == run.workItemID
        }
        if let candidate = runCandidates.max(by: { $0.version < $1.version }),
          candidate.status == .resolvingConflict {
          _ = try? await store.updateAgentRun(
            id: run.id,
            status: .queued,
            eventActor: "StoryPointless",
            eventDetail: "Interrupted integration queued to resume"
          )
          continue
        }
        _ = try? await store.updateAgentRun(
          id: run.id,
          status: .interrupted,
          eventActor: "StoryPointless",
          eventDetail: "Review interrupted when the app stopped"
        )
        continue
      }

      if let item = workItems.first(where: { $0.id == run.workItemID }) {
        switch item.state {
        case .verifying:
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .running,
            actor: "StoryPointless",
            reason: "Recovering an interrupted review"
          )
        case .integrating:
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .running,
            actor: "StoryPointless",
            reason: "Recovering an interrupted integration"
          )
        default:
          break
        }
      }
      _ = try? await store.updateAgentRun(
        id: run.id,
        status: .queued,
        eventActor: "StoryPointless",
        eventDetail: "Interrupted work queued to resume from the existing workspace"
      )
    }

    for candidate in storedCandidates where
      candidate.status == .integrating || candidate.status == .reviewing
    {
      if let integrationPath = candidate.integrationWorktreePath {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: Self.productWorkspaceURL(productID: productID),
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .queuedForIntegration
      )
      if let item = workItems.first(where: { $0.id == candidate.workItemID }) {
        switch item.state {
        case .verifying:
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .running,
            actor: "StoryPointless",
            reason: "Interrupted review queued to restart"
          )
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "StoryPointless",
            reason: "Candidate restored to the integration queue"
          )
        case .running:
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "StoryPointless",
            reason: "Candidate restored to the integration queue"
          )
        default:
          break
        }
      }
    }

    let latestCandidateByWorkItemID = Dictionary(
      grouping: storedCandidates,
      by: \.workItemID
    ).compactMapValues { candidates in
      candidates.max { $0.version < $1.version }
    }
    for run in runs where
      run.productID == productID
        && run.status == .awaitingOwner
        && implementerByItemID[run.workItemID] == run.profileID
    {
      guard
        let failedCandidate = latestCandidateByWorkItemID[run.workItemID],
        failedCandidate.status == .failed
      else {
        continue
      }
      let comments = (try? await store.fetchComments(workItemID: run.workItemID)) ?? []
      guard let latestSystemFailure = comments.last(where: { $0.authorKind == .system }) else {
        continue
      }
      let reviewContractFailed =
        latestSystemFailure.body.localizedCaseInsensitiveContains(
          "changes-requested reviews need at least one finding"
        )
        || latestSystemFailure.body.localizedCaseInsensitiveContains(
          "requested changes without identifying a concrete blocking finding"
        )
      if reviewContractFailed {
        _ = try? await store.updateAgentRun(
          id: run.id,
          status: .completed,
          eventActor: "StoryPointless",
          eventDetail: "Implementation preserved; malformed review queued to retry"
        )
        _ = try? await store.updateCandidateRevision(
          id: failedCandidate.id,
          status: .queuedForIntegration
        )
        if
          let item = workItems.first(where: { $0.id == run.workItemID }),
          item.state == .running
        {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "StoryPointless",
            reason: "Retrying a malformed Tech Lead review against the preserved candidate"
          )
        }
        _ = try? await store.appendComment(
          workItemID: run.workItemID,
          authorKind: .system,
          authorName: "StoryPointless",
          body: "The implementation was valid; the Tech Lead’s structured response was malformed. Candidate v\(failedCandidate.version) has been preserved and queued for review again without repeating the delivery work."
        )
        continue
      }
      guard latestSystemFailure.body.localizedCaseInsensitiveContains("thread not found")
      else { continue }
      _ = try? await store.updateAgentRun(
        id: run.id,
        status: .queued,
        eventActor: "StoryPointless",
        eventDetail: "Transient Codex session failure queued to recover automatically"
      )
      _ = try? await store.appendComment(
        workItemID: run.workItemID,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "The previous failure was caused by an expired Codex session rather than the ticket work. Recovery has been queued automatically in the preserved workspace."
      )
    }

    if let techLead = profiles.first(where: { $0.role == .lead }) {
      for candidate in storedCandidates where candidate.status == .resolvingConflict {
        let candidateRuns = runs.filter {
          $0.workItemID == candidate.workItemID && $0.profileID == techLead.id
        }
        if let latest = candidateRuns.max(by: { $0.createdAt < $1.createdAt }) {
          if latest.status == .interrupted || latest.status == .failed {
            _ = try? await store.updateAgentRun(
              id: latest.id,
              status: .queued,
              eventActor: "StoryPointless",
              eventDetail: "Interrupted conflict resolution queued to resume"
            )
          }
        } else if let worktreePath = candidate.integrationWorktreePath {
          _ = try? await store.createAgentRun(
            AgentRun(
              productID: productID,
              sprintID: plan.sprint.id,
              sprintItemID: candidate.sprintItemID,
              workItemID: candidate.workItemID,
              profileID: techLead.id,
              status: .queued,
              worktreePath: worktreePath
            )
          )
        }
      }
    }
  }

  private func eligibleImplementationRuns(in plan: SprintPlan) -> [AgentRun] {
    SprintRunAdmission.eligibleImplementationRuns(
      plan: plan,
      runs: runs,
      workItems: workItems,
      dependencies: dependencies
    )
  }

  @discardableResult
  private func processNextIntegrationCandidate(plan: SprintPlan) async -> Bool {
    guard let store else { return false }
    do {
      let candidates = try await store.fetchCandidateRevisions(
        productID: plan.sprint.productID
      )
      let techLeadID = profiles.first(where: { $0.role == .lead })?.id
      let resolvingCandidates = candidates.filter {
        $0.sprintID == plan.sprint.id && $0.status == .resolvingConflict
      }
      if let resolvingCandidate = resolvingCandidates.min(
        by: { $0.createdAt < $1.createdAt }
      ) {
        let resolutionRuns = runs
          .filter {
            $0.workItemID == resolvingCandidate.workItemID
              && $0.status == .queued
              && $0.profileID == techLeadID
          }
        if let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }) {
          await resumeIntegrationConflictResolution(
            candidate: resolvingCandidate,
            resolutionRun: resolutionRun,
            plan: plan
          )
          return true
        }
      }
      let integrationIsOccupied = candidates.contains { candidate in
        guard candidate.sprintID == plan.sprint.id else { return false }
        switch candidate.status {
        case .integrating, .resolvingConflict, .reviewing, .readyForDemo:
          return true
        case .queuedForIntegration, .changesRequested, .accepted, .superseded, .failed:
          return false
        }
      }
      guard !integrationIsOccupied else { return false }

      let rankByWorkItemID = Dictionary(
        uniqueKeysWithValues: workItems.map { ($0.id, $0.rank) }
      )
      let queued = candidates
        .filter {
          $0.sprintID == plan.sprint.id && $0.status == .queuedForIntegration
        }
        .sorted { lhs, rhs in
          let leftRank = rankByWorkItemID[lhs.workItemID] ?? Int.max
          let rightRank = rankByWorkItemID[rhs.workItemID] ?? Int.max
          if leftRank == rightRank {
            return lhs.createdAt < rhs.createdAt
          }
          return leftRank < rightRank
        }
      guard let candidate = queued.first else { return false }
      let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      let implementationRun = try await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating
      )
      await reloadSelectedProduct()
      await reviewCompletedImplementation(
        implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func executeImplementationRun(_ queuedRun: AgentRun, plan: SprintPlan) async {
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct,
      let item = workItems.first(where: { $0.id == queuedRun.workItemID }),
      let assignee = profiles.first(where: { $0.id == queuedRun.profileID })
    else { return }

    var run = queuedRun
    do {
      let productWorkspace = try Self.productWorkspaceURL(productID: product.id)
      let isContinuation = item.state == .running
      let workspace: URL
      if
        let storedPath = run.worktreePath,
        storedPath != productWorkspace.path,
        FileManager.default.fileExists(atPath: storedPath)
      {
        workspace = URL(fileURLWithPath: storedPath, isDirectory: true)
      } else {
        if run.codexThreadID != nil || run.worktreePath != nil {
          run = try await store.resetAgentRunExecutionContext(id: run.id)
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The preserved work is being resumed in an isolated \(item.key) workspace."
          )
        }
        let prepared = try await gitWorkspaceManager.prepareTicketWorkspace(
          repositoryURL: productWorkspace,
          worktreesRootURL: Self.ticketWorktreesRootURL(productID: product.id),
          ticketKey: item.key,
          runID: run.id,
          authorName: assignee.name
        )
        workspace = prepared.url
      }
      try await gitWorkspaceManager.configureAgentIdentity(
        at: workspace,
        authorName: assignee.name
      )

      if item.state == .queued {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: assignee.name,
          reason: "Picked up the authorised ticket"
        )
      }

      let developerInstructions = CodexTicketExecutor.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product),
        personaInstructions: assignee.effectiveInstructions,
        assignee: assignee
      )
      let threadID: String
      if let existingThreadID = run.codexThreadID {
        threadID = existingThreadID
      } else {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: assignee.model
        )
      }
      run = try await store.updateAgentRun(
        id: run.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path
      )
      await reloadSelectedProduct()

      let currentItem = workItems.first(where: { $0.id == item.id }) ?? item
      let prerequisiteIDs = Set(
        dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
      )
      let prerequisites = workItems.filter { prerequisiteIDs.contains($0.id) }
      var prerequisiteComments: [UUID: [TicketComment]] = [:]
      for prerequisite in prerequisites {
        prerequisiteComments[prerequisite.id] = try await store.fetchComments(
          workItemID: prerequisite.id
        )
      }
      let comments = try await store.fetchComments(workItemID: item.id)
      let knowledgeContext = relevantKnowledgeContext(
        for: currentItem,
        prerequisites: prerequisites
      )
      try await store.setAgentRunKnowledgeContext(
        runID: run.id,
        pageIDs: knowledgeContext.map(\.id)
      )
      agentRunKnowledgeContext.removeAll { $0.runID == run.id }
      agentRunKnowledgeContext.append(
        contentsOf: knowledgeContext.map {
          AgentRunKnowledgePage(runID: run.id, pageID: $0.id)
        }
      )
      let executionPrompt = CodexTicketExecutor.prompt(
        product: product,
        item: currentItem,
        assignee: assignee,
        prerequisites: prerequisites,
        prerequisiteComments: prerequisiteComments,
        ticketComments: comments,
        knowledgeContext: knowledgeContext,
        continuationMessage: isContinuation
          ? "Use the latest Product Owner or reviewer comment to resume the existing work."
          : nil
      )
      var activeThreadID = threadID
      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: executionPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        activeThreadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: assignee.model
        )
        run = try await store.updateAgentRun(
          id: run.id,
          status: .running,
          codexThreadID: activeThreadID,
          worktreePath: workspace.path,
          eventActor: "StoryPointless",
          eventDetail: "Replaced a stale Codex thread and preserved the ticket workspace"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "StoryPointless",
          body: "The previous Codex session was no longer available. I started a replacement session in the preserved ticket workspace and continued the work."
        )
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: executionPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema
        )
      }
      activeExecutionTurns[run.id] = ActiveExecutionTurn(
        threadID: activeThreadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: run.id,
        client: client,
        threadID: activeThreadID,
        turnID: turnID,
        initialText: "Getting oriented in the ticket workspace…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: activeThreadID,
        turnID: turnID,
        timeout: .seconds(900)
      )
      stopLiveActivityMonitoring(runID: run.id)
      activeExecutionTurns.removeValue(forKey: run.id)
      let result = try await validatedExecutionResult(
        response,
        client: client,
        threadID: activeThreadID,
        runID: run.id,
        assignee: assignee,
        workspaceURL: workspace
      )
      await processExecutionResult(
        result,
        implementationRunID: run.id,
        reviewCycle: 0,
        plan: plan
      )
    } catch {
      if let activeExecutionTurn = activeExecutionTurns[run.id] {
        try? await client.interruptTurn(
          threadID: activeExecutionTurn.threadID,
          turnID: activeExecutionTurn.turnID
        )
      }
      stopLiveActivityMonitoring(runID: run.id)
      activeExecutionTurns.removeValue(forKey: run.id)
      let wasManuallyStopped = manuallyStoppedRunIDs.remove(run.id) != nil
      let status: AgentRunStatus =
        Task.isCancelled || wasManuallyStopped ? .interrupted : .failed
      _ = try? await store.updateAgentRun(
        id: run.id,
        status: status,
        eventActor: "StoryPointless",
        eventDetail: error.localizedDescription
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: Task.isCancelled || wasManuallyStopped
          ? "This run was stopped. Its ticket workspace has been preserved and can be retried."
          : "The agent run stopped unexpectedly: \(error.localizedDescription)"
      )
      if !Task.isCancelled && !wasManuallyStopped {
        errorMessage = error.localizedDescription
      }
      await reloadSelectedProduct()
    }
  }

  private func validatedExecutionResult(
    _ response: String,
    client: CodexAppServerClient,
    threadID: String,
    runID: UUID,
    assignee: AgentProfile,
    workspaceURL: URL
  ) async throws -> TicketExecutionResult {
    do {
      let result = try CodexTicketExecutor.decode(response)
      try await validateDeliveryEvidence(result, workspaceURL: workspaceURL)
      return result
    } catch let validationError as TicketExecutionGenerationError {
      let repairTurnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketExecutor.repairPrompt(
          validationError: validationError.localizedDescription
        ),
        effort: assignee.reasoningEffort,
        outputSchema: CodexTicketExecutor.outputSchema
      )
      activeExecutionTurns[runID] = ActiveExecutionTurn(
        threadID: threadID,
        turnID: repairTurnID
      )
      monitorLiveActivity(
        runID: runID,
        client: client,
        threadID: threadID,
        turnID: repairTurnID,
        initialText: "Completing the missing delivery evidence…"
      )
      do {
        let repairedResponse = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: repairTurnID,
          timeout: .seconds(900)
        )
        stopLiveActivityMonitoring(runID: runID)
        activeExecutionTurns.removeValue(forKey: runID)
        let repairedResult = try CodexTicketExecutor.decode(repairedResponse)
        try await validateDeliveryEvidence(repairedResult, workspaceURL: workspaceURL)
        return repairedResult
      } catch {
        stopLiveActivityMonitoring(runID: runID)
        activeExecutionTurns.removeValue(forKey: runID)
        throw error
      }
    }
  }

  private func validateDeliveryEvidence(
    _ result: TicketExecutionResult,
    workspaceURL: URL
  ) async throws {
    guard result.status == .completed else { return }
    let actualChangePaths = try await gitWorkspaceManager.ticketChangePaths(
      ticketWorkspaceURL: workspaceURL
    )
    let substantiveChangePaths = Set(
      actualChangePaths.filter {
        !$0.hasPrefix("knowledge/delivery-history/")
      }
    )
    guard !substantiveChangePaths.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Completed work did not create or modify a durable ticket artefact. The generated delivery note does not count as the delivery."
      )
    }
    let reportedChangePaths = Set(
      result.changedFiles.map {
        $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0
      }
    )
    guard reportedChangePaths.isSubset(of: Set(actualChangePaths)) else {
      let missing = reportedChangePaths.subtracting(actualChangePaths).sorted()
      throw TicketExecutionGenerationError.invalidResponse(
        "Reported changed files were not present in the ticket workspace: \(missing.joined(separator: ", "))."
      )
    }
    guard !reportedChangePaths.isDisjoint(with: substantiveChangePaths) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The reported changed files contain only generated delivery history, not an inspectable ticket artefact."
      )
    }
  }

  private func processExecutionResult(
    _ result: TicketExecutionResult,
    implementationRunID: UUID,
    reviewCycle: Int,
    plan: SprintPlan
  ) async {
    guard
      let store,
      let run = try? await store.fetchAgentRun(id: implementationRunID),
      let item = workItems.first(where: { $0.id == run.workItemID }),
      let assignee = profiles.first(where: { $0.id == run.profileID })
    else { return }

    _ = try? await store.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: assignee.name,
      body: result.workLogComment
    )

    if result.status == .completed {
      try? await store.saveRetrospectiveNotes(
        makeRetrospectiveNotes(
          productID: item.productID,
          sprintID: plan.sprint.id,
          workItemID: item.id,
          profile: assignee,
          wentWell: result.retrospectiveWentWell,
          couldImprove: result.retrospectiveCouldImprove,
          actions: result.retrospectiveActions
        )
      )
    }

    switch result.status {
    case .awaitingOwner:
      _ = try? await store.updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        eventActor: assignee.name,
        eventDetail: "Waiting for Product Owner input"
      )
      await reloadSelectedProduct()
    case .completed:
      do {
        guard let worktreePath = run.worktreePath else {
          throw GitWorkspaceError.invalidRepository("The agent run has no ticket workspace.")
        }
        let deliveryNote = deliveryNoteMarkdown(
          item: item,
          result: result,
          authorName: assignee.name
        )
        try Self.writeDeliveryNoteMarkdown(
          deliveryNote,
          sprintNumber: plan.sprint.number,
          item: item,
          workspaceURL: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
        _ = try await store.upsertDeliveryNote(
          productID: item.productID,
          sprint: plan.sprint,
          item: item,
          bodyMarkdown: deliveryNote,
          authorName: assignee.name
        )

        let version = try await store.nextCandidateRevisionVersion(workItemID: item.id)
        let snapshot = try await gitWorkspaceManager.createCandidate(
          ticketWorkspaceURL: URL(fileURLWithPath: worktreePath, isDirectory: true),
          ticketKey: item.key,
          version: version,
          authorName: assignee.name,
          summary: result.summary
        )
        let resultData = try JSONEncoder().encode(result)
        guard let resultJSON = String(data: resultData, encoding: .utf8) else {
          throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let sprintItemID = run.sprintItemID
          ?? plan.items.first(where: { $0.workItemID == item.id })?.id
        guard let sprintItemID else {
          throw PersistenceError.corruptData("Candidate revision has no sprint item.")
        }
        let candidate = try await store.createCandidateRevision(
          CandidateRevision(
            productID: item.productID,
            sprintID: plan.sprint.id,
            sprintItemID: sprintItemID,
            workItemID: item.id,
            implementationRunID: run.id,
            version: version,
            branchName: snapshot.branchName,
            baseSHA: snapshot.baseSHA,
            headSHA: snapshot.headSHA,
            worktreePath: worktreePath,
            commitCount: snapshot.commitCount,
            executionResultJSON: resultJSON
          )
        )
        let proposals = try makeKnowledgePageProposals(
          drafts: result.knowledgePageProposals,
          candidate: candidate,
          runID: run.id
        )
        try await store.createKnowledgePageProposals(proposals)
        let currentState = (try await store.fetchWorkItems(productID: item.productID))
          .first { $0.id == item.id }?.state
        if currentState == .running {
          _ = try await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: assignee.name,
            reason: "Candidate v\(candidate.version) queued for integration"
          )
        }
        _ = try await store.updateAgentRun(
          id: run.id,
          status: .completed,
          eventActor: assignee.name,
          eventDetail: "Candidate v\(candidate.version) queued for integration"
        )
        await reloadSelectedProduct()
      } catch {
        _ = try? await store.updateAgentRun(
          id: run.id,
          status: .awaitingOwner,
          eventActor: "StoryPointless",
          eventDetail: "Could not create an immutable candidate revision"
        )
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "StoryPointless",
          body: "The work is preserved, but StoryPointless could not prepare it for review: \(error.localizedDescription)"
        )
        errorMessage = error.localizedDescription
        await reloadSelectedProduct()
      }
    }
  }

  private func reviewCompletedImplementation(
    _ implementation: TicketExecutionResult,
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    preparedIntegration: GitIntegrationSnapshot? = nil
  ) async {
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct,
      let item = workItems.first(where: { $0.id == implementationRun.workItemID }),
      let implementer = profiles.first(where: { $0.id == implementationRun.profileID }),
      let techLead = profiles.first(where: { $0.role == .lead })
    else { return }

    var failureStage = "Tech Lead review"
    var activeReviewRunID: UUID?
    do {
      let currentState = (try await store.fetchWorkItems(productID: product.id))
        .first { $0.id == item.id }?.state
      if currentState == .running {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: implementer.name,
          reason: "Implementation and reported checks completed"
        )
      }
      _ = try await store.updateAgentRun(
        id: implementationRun.id,
        status: .completed,
        eventActor: implementer.name,
        eventDetail: "Implementation complete; waiting for Tech Lead review"
      )
      let repositoryURL = try Self.productWorkspaceURL(productID: product.id)
      let integration: GitIntegrationSnapshot
      if let preparedIntegration {
        integration = preparedIntegration
      } else {
        do {
          integration = try await gitWorkspaceManager.integrateCandidate(
            repositoryURL: repositoryURL,
            integrationsRootURL: Self.integrationWorktreesRootURL(productID: product.id),
            candidateID: candidate.id,
            headSHA: candidate.headSHA,
            commitMessage: "Integrate \(item.key): \(item.title)"
          )
        } catch GitWorkspaceError.mergeConflict(
          let worktreePath,
          let conflictedFiles,
          _
        ) {
          await beginIntegrationConflictResolution(
            candidate: candidate,
            implementationRun: implementationRun,
            reviewCycle: reviewCycle,
            plan: plan,
            worktreePath: worktreePath,
            conflictedFiles: conflictedFiles
          )
          return
        }
      }
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .reviewing,
        integratedSHA: integration.integratedSHA,
        integrationWorktreePath: integration.url.path
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .verifying,
        actor: techLead.name,
        reason: "Independent Tech Lead review started"
      )

      let reviewRun = try await store.createAgentRun(
        AgentRun(
          productID: product.id,
          sprintID: plan.sprint.id,
          sprintItemID: implementationRun.sprintItemID,
          workItemID: item.id,
          profileID: techLead.id,
          status: .running
        )
      )
      activeReviewRunID = reviewRun.id
      await reloadSelectedProduct()

      let workspace = integration.url
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexTechLeadReviewer.developerInstructions(
          productInstructions: inheritedAgentInstructions(for: product),
          personaInstructions: techLead.effectiveInstructions,
          reviewer: techLead
        ),
        model: techLead.model
      )
      _ = try await store.updateAgentRun(
        id: reviewRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path
      )
      let reviewComments = try await store.fetchComments(workItemID: item.id)
      let priorReviewFeedback =
        reviewCycle > 0
        ? reviewComments.reversed().first {
          $0.authorName == techLead.name
            && !$0.body.hasPrefix("I’m reviewing")
            && !$0.body.hasPrefix("The implementation has not converged")
            && !$0.body.hasPrefix("I still see a material acceptance issue")
        }?.body
        : nil
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTechLeadReviewer.prompt(
          product: product,
          item: item,
          implementation: implementation,
          assignee: implementer,
          reviewCycle: reviewCycle,
          priorReviewFeedback: priorReviewFeedback,
          recentComments: reviewComments,
          baseSHA: candidate.baseSHA,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: integration.integratedSHA
        ),
        effort: techLead.reasoningEffort,
        outputSchema: CodexTechLeadReviewer.outputSchema
      )
      activeExecutionTurns[reviewRun.id] = ActiveExecutionTurn(
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: reviewRun.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Reviewing the delivery evidence…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(600)
      )
      stopLiveActivityMonitoring(runID: reviewRun.id)
      activeExecutionTurns.removeValue(forKey: reviewRun.id)
      let review: TechLeadReviewResult
      do {
        review = try CodexTechLeadReviewer.decode(response)
      } catch TechLeadReviewGenerationError.changesRequestedWithoutFinding {
        let repairTurnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: """
            Your previous review selected changes_requested but did not identify a blocking finding.
            Correct the structured review now. If there is no concrete material blocker under the
            supplied review policy, approve. Otherwise include one to three small, actionable
            findings that name the violated criterion or defect. Return only the required JSON.
            """,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema
        )
        activeExecutionTurns[reviewRun.id] = ActiveExecutionTurn(
          threadID: threadID,
          turnID: repairTurnID
        )
        monitorLiveActivity(
          runID: reviewRun.id,
          client: client,
          threadID: threadID,
          turnID: repairTurnID,
          initialText: "Clarifying the review decision…"
        )
        let repairedResponse = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: repairTurnID,
          timeout: .seconds(180)
        )
        stopLiveActivityMonitoring(runID: reviewRun.id)
        activeExecutionTurns.removeValue(forKey: reviewRun.id)
        review = try CodexTechLeadReviewer.decode(repairedResponse)
      }
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: techLead.name,
        body: review.workLogComment
      )
      _ = try await store.updateAgentRun(id: reviewRun.id, status: .completed)
      activeReviewRunID = nil
      failureStage = "Post-review handoff"
      try await store.saveRetrospectiveNotes(
        makeRetrospectiveNotes(
          productID: item.productID,
          sprintID: plan.sprint.id,
          workItemID: item.id,
          profile: techLead,
          wentWell: review.retrospectiveWentWell,
          couldImprove: review.retrospectiveCouldImprove,
          actions: review.retrospectiveActions
        )
      )

      switch review.decision {
      case .approved:
        try await store.verifyDeliveryNote(workItemID: item.id, authorName: techLead.name)
        try await store.markKnowledgePageProposals(
          candidateRevisionID: candidate.id,
          status: .reviewed
        )
        if !requiresKnowledgeApproval {
          _ = try await publishReviewedKnowledgePageProposals(
            candidate: try await store.fetchCandidateRevision(id: candidate.id),
            workItem: item,
            authorName: "StoryPointless"
          )
        }
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .readyForDemo
        )
        _ = try await store.updateAgentRun(id: implementationRun.id, status: .completed)
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .acceptance,
          actor: techLead.name,
          reason: "Review passed; ready for Product Owner demo"
        )
        await reloadSelectedProduct()
      case .changesRequested:
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .changesRequested
        )
        try await store.markKnowledgePageProposals(
          candidateRevisionID: candidate.id,
          status: .superseded
        )
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: integration.url
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: techLead.name,
          reason: "Review changes requested"
        )
        guard reviewCycle < Self.maxAutomaticReviewCorrections else {
          let remainingFindings = review.findings.prefix(3)
            .map { "- \($0)" }
            .joined(separator: "\n")
          _ = try await store.updateAgentRun(
            id: implementationRun.id,
            status: .awaitingOwner,
            eventActor: techLead.name,
            eventDetail:
              "\(review.findings.count) material review finding\(review.findings.count == 1 ? "" : "s") remain after two revisions"
          )
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .agent,
            authorName: techLead.name,
            body: """
              I paused automatic revisions because these review findings remain:

              \(remainingFindings.isEmpty ? "- The review did not provide a concrete finding." : remainingFindings)

              Ask the assigned specialist a question without restarting work, or add Product Owner direction and choose Resume work.
              """
          )
          await reloadSelectedProduct()
          return
        }
        failureStage = "Applying review feedback"
        _ = try await store.updateAgentRun(
          id: implementationRun.id,
          status: .running,
          eventActor: implementer.name,
          eventDetail: "Resuming after \(techLead.name) requested changes"
        )
        await reloadSelectedProduct()
        let comments = try await store.fetchComments(workItemID: item.id)
        let revisionWorkspace = URL(
          fileURLWithPath: candidate.worktreePath,
          isDirectory: true
        )
        let developerInstructions = CodexTicketExecutor.developerInstructions(
          productInstructions: inheritedAgentInstructions(for: product),
          personaInstructions: implementer.effectiveInstructions,
          assignee: implementer
        )
        let revisionPrompt = CodexTicketExecutor.revisionPrompt(
          item: item,
          reviewer: techLead,
          feedback: review.workLogComment,
          recentComments: comments
        )
        var revisionThreadID: String
        if let existingThreadID = implementationRun.codexThreadID {
          revisionThreadID = existingThreadID
        } else {
          revisionThreadID = try await client.startWorkspaceThread(
            workingDirectory: revisionWorkspace,
            developerInstructions: developerInstructions,
            model: implementer.model
          )
          _ = try await store.updateAgentRun(
            id: implementationRun.id,
            status: .running,
            codexThreadID: revisionThreadID,
            worktreePath: revisionWorkspace.path
          )
        }

        let turnID: String
        do {
          turnID = try await client.startStructuredTurn(
            threadID: revisionThreadID,
            prompt: revisionPrompt,
            effort: implementer.reasoningEffort,
            outputSchema: CodexTicketExecutor.outputSchema
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          revisionThreadID = try await client.startWorkspaceThread(
            workingDirectory: revisionWorkspace,
            developerInstructions: developerInstructions,
            model: implementer.model
          )
          _ = try await store.updateAgentRun(
            id: implementationRun.id,
            status: .running,
            codexThreadID: revisionThreadID,
            worktreePath: revisionWorkspace.path,
            eventActor: "StoryPointless",
            eventDetail: "Replaced a stale Codex thread before applying review feedback"
          )
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The delivery agent’s previous Codex session was unavailable. I started a replacement session in the preserved ticket workspace and passed it the Tech Lead’s feedback."
          )
          turnID = try await client.startStructuredTurn(
            threadID: revisionThreadID,
            prompt: revisionPrompt,
            effort: implementer.reasoningEffort,
            outputSchema: CodexTicketExecutor.outputSchema
          )
        }
        activeExecutionTurns[implementationRun.id] = ActiveExecutionTurn(
          threadID: revisionThreadID,
          turnID: turnID
        )
        monitorLiveActivity(
          runID: implementationRun.id,
          client: client,
          threadID: revisionThreadID,
          turnID: turnID,
          initialText: "Applying the review feedback…"
        )
        let revisionResponse = try await client.waitForFinalAgentMessage(
          threadID: revisionThreadID,
          turnID: turnID,
          timeout: .seconds(900)
        )
        stopLiveActivityMonitoring(runID: implementationRun.id)
        activeExecutionTurns.removeValue(forKey: implementationRun.id)
        let revision = try await validatedExecutionResult(
          revisionResponse,
          client: client,
          threadID: revisionThreadID,
          runID: implementationRun.id,
          assignee: implementer,
          workspaceURL: revisionWorkspace
        )
        await processExecutionResult(
          revision,
          implementationRunID: implementationRun.id,
          reviewCycle: reviewCycle + 1,
          plan: plan
        )
      }
    } catch {
      if let activeReviewRunID {
        stopLiveActivityMonitoring(runID: activeReviewRunID)
        activeExecutionTurns.removeValue(forKey: activeReviewRunID)
        _ = try? await store.updateAgentRun(
          id: activeReviewRunID,
          status: Task.isCancelled ? .interrupted : .failed,
          eventActor: "StoryPointless",
          eventDetail: error.localizedDescription
        )
      }
      stopLiveActivityMonitoring(runID: implementationRun.id)
      activeExecutionTurns.removeValue(forKey: implementationRun.id)
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .failed
      )
      try? await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .superseded
      )
      if
        let failedCandidate = try? await store.fetchCandidateRevision(id: candidate.id),
        let integrationPath = failedCandidate.integrationWorktreePath
      {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: Self.productWorkspaceURL(productID: product.id),
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
      if let currentState = try? await store.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state,
        currentState == .verifying || currentState == .integrating
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "StoryPointless",
          reason: "Review stopped; preserving work for retry"
        )
      }
      _ = try? await store.updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "StoryPointless",
        eventDetail: "\(failureStage) could not complete"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "\(failureStage) stopped unexpectedly: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved workspace."
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProduct()
    }
  }

  private func beginIntegrationConflictResolution(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    worktreePath: String,
    conflictedFiles: [String]
  ) async {
    guard
      let store,
      let product = selectedProduct,
      let item = workItems.first(where: { $0.id == candidate.workItemID }),
      let techLead = profiles.first(where: { $0.role == .lead })
    else { return }

    var resolutionRunID: UUID?
    do {
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .resolvingConflict,
        integrationWorktreePath: worktreePath
      )
      let resolutionRun = try await store.createAgentRun(
        AgentRun(
          productID: product.id,
          sprintID: plan.sprint.id,
          sprintItemID: candidate.sprintItemID,
          workItemID: item.id,
          profileID: techLead.id,
          status: .running,
          worktreePath: worktreePath
        )
      )
      resolutionRunID = resolutionRun.id
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Integrator",
        body: "The candidate overlaps newer accepted work in \(conflictedFiles.count) file(s). I’m resolving the integration before Tech Lead review."
      )
      await reloadSelectedProduct()
      await runIntegrationConflictResolution(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: reviewCycle,
        plan: plan,
        conflictedFiles: conflictedFiles,
        continuationMessage: nil
      )
    } catch {
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: item.id,
        resolutionRunID: resolutionRunID
      )
    }
  }

  private func resumeIntegrationConflictResolution(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    plan: SprintPlan
  ) async {
    guard
      let store,
      let worktreePath = candidate.integrationWorktreePath
    else { return }
    do {
      let implementationRun = try await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
      let conflictedFiles = try await gitWorkspaceManager.unmergedFiles(
        at: URL(fileURLWithPath: worktreePath, isDirectory: true)
      )
      _ = try await store.updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        eventActor: "Integrator",
        eventDetail: "Product Owner response received; conflict resolution resumed"
      )
      await reloadSelectedProduct()
      await runIntegrationConflictResolution(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        conflictedFiles: conflictedFiles,
        continuationMessage: "Use the latest Product Owner comment to resolve the open integration decision."
      )
    } catch {
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: candidate.workItemID,
        resolutionRunID: resolutionRun.id
      )
    }
  }

  private func runIntegrationConflictResolution(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    conflictedFiles: [String],
    continuationMessage: String?
  ) async {
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct,
      let item = workItems.first(where: { $0.id == candidate.workItemID }),
      let techLead = profiles.first(where: { $0.role == .lead }),
      let worktreePath = candidate.integrationWorktreePath
        ?? resolutionRun.worktreePath
    else { return }

    do {
      let workspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
      let developerInstructions = CodexConflictIntegrator.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product)
      )
      var threadID: String
      if let existingThreadID = resolutionRun.codexThreadID {
        threadID = existingThreadID
      } else {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model
        )
      }
      _ = try await store.updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path
      )
      let comments = try await store.fetchComments(workItemID: item.id)
      let resolutionPrompt = CodexConflictIntegrator.prompt(
        product: product,
        item: item,
        conflictedFiles: conflictedFiles,
        recentComments: comments,
        continuationMessage: continuationMessage
      )
      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: resolutionPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexConflictIntegrator.outputSchema
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model
        )
        _ = try await store.updateAgentRun(
          id: resolutionRun.id,
          status: .running,
          codexThreadID: threadID,
          worktreePath: workspace.path,
          eventActor: "StoryPointless",
          eventDetail: "Replaced a stale Integrator Codex thread"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "StoryPointless",
          body: "The Integrator’s previous Codex session was unavailable. I started a replacement session in the preserved conflict workspace."
        )
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: resolutionPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexConflictIntegrator.outputSchema
        )
      }
      activeExecutionTurns[resolutionRun.id] = ActiveExecutionTurn(
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: resolutionRun.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Inspecting the integration conflict…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(900)
      )
      stopLiveActivityMonitoring(runID: resolutionRun.id)
      activeExecutionTurns.removeValue(forKey: resolutionRun.id)
      let result = try CodexConflictIntegrator.decode(response)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: "Integrator",
        body: result.workLogComment
      )

      switch result.status {
      case .awaitingOwner:
        _ = try await store.updateAgentRun(
          id: resolutionRun.id,
          status: .awaitingOwner,
          eventActor: "Integrator",
          eventDetail: "Waiting for Product Owner input"
        )
        await reloadSelectedProduct()
      case .resolved:
        let integration = try await gitWorkspaceManager.completeConflictResolution(
          integrationWorkspaceURL: workspace,
          candidateHeadSHA: candidate.headSHA
        )
        _ = try await store.updateAgentRun(
          id: resolutionRun.id,
          status: .completed,
          eventActor: "Integrator",
          eventDetail: "Conflict resolution completed"
        )
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .integrating,
          integratedSHA: integration.integratedSHA,
          integrationWorktreePath: integration.url.path
        )
        let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
        await reloadSelectedProduct()
        await reviewCompletedImplementation(
          implementation,
          candidate: candidate,
          implementationRun: implementationRun,
          reviewCycle: reviewCycle,
          plan: plan,
          preparedIntegration: integration
        )
      }
    } catch {
      stopLiveActivityMonitoring(runID: resolutionRun.id)
      activeExecutionTurns.removeValue(forKey: resolutionRun.id)
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: item.id,
        resolutionRunID: resolutionRun.id
      )
    }
  }

  private func recordIntegrationResolutionFailure(
    _ error: Error,
    candidate: CandidateRevision,
    workItemID: UUID,
    resolutionRunID: UUID?
  ) async {
    guard let store else { return }
    if let resolutionRunID {
      _ = try? await store.updateAgentRun(
        id: resolutionRunID,
        status: Task.isCancelled ? .interrupted : .awaitingOwner,
        eventActor: "Integrator",
        eventDetail: error.localizedDescription
      )
    }
    _ = try? await store.updateCandidateRevision(
      id: candidate.id,
      status: .resolvingConflict
    )
    _ = try? await store.appendComment(
      workItemID: workItemID,
      authorKind: .system,
      authorName: "StoryPointless",
      body: Task.isCancelled
        ? "Integration was interrupted. The conflict workspace is preserved."
        : "Integration needs attention: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved conflict workspace."
    )
    if !Task.isCancelled {
      errorMessage = error.localizedDescription
    }
    await reloadSelectedProduct()
  }

  private func handleSprintOwnerComment(workItemID: UUID, body: String) async {
    guard
      let store,
      let plan = sprintPlan,
      plan.sprint.state == .active,
      let sprintItem = plan.items.first(where: { $0.workItemID == workItemID }),
      let implementerID = sprintItem.implementerProfileID
    else { return }

    do {
      let currentItems = try await store.fetchWorkItems(productID: plan.sprint.productID)
      guard let item = currentItems.first(where: { $0.id == workItemID }) else { return }
      let currentRuns = try await store.fetchAgentRuns(productID: plan.sprint.productID)
      let currentCandidates = try await store.fetchCandidateRevisions(
        productID: plan.sprint.productID
      )
      if currentCandidates.contains(where: {
        $0.workItemID == workItemID && $0.status == .resolvingConflict
      }) {
        let techLeadID = profiles.first(where: { $0.role == .lead })?.id
        let resolutionRuns = currentRuns.filter {
          $0.workItemID == workItemID
            && $0.profileID == techLeadID
            && $0.status == .awaitingOwner
        }
        if let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }) {
          _ = try await store.updateAgentRun(
            id: resolutionRun.id,
            status: .queued,
            eventActor: "Product Owner",
            eventDetail: "Response received; integration queued to resume"
          )
          await reloadSelectedProduct()
          scheduleSprintExecution()
          return
        }
      }
      let matchingRuns = currentRuns.filter {
        $0.workItemID == workItemID && $0.profileID == implementerID
      }
      guard
        let implementationRun = matchingRuns.max(by: { $0.createdAt < $1.createdAt }),
        implementationRun.codexThreadID != nil
      else { return }

      if implementationRun.status == .awaitingOwner {
        _ = try await store.updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product Owner",
          eventDetail: "Response received; work queued to resume"
        )
      } else if
        (implementationRun.status == .failed || implementationRun.status == .interrupted),
        item.state == .running
      {
        _ = try await store.updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product Owner",
          eventDetail: "Retry requested; preserved work queued to resume"
        )
      } else if item.state == .acceptance {
        let readyCandidates = candidateRevisions.filter { candidate in
          candidate.workItemID == item.id && candidate.status == .readyForDemo
        }
        if let candidate = readyCandidates.max(by: { $0.version < $1.version }) {
          _ = try await store.updateCandidateRevision(
            id: candidate.id,
            status: .superseded
          )
          try await store.markKnowledgePageProposals(
            candidateRevisionID: candidate.id,
            status: .superseded
          )
          if let integrationPath = candidate.integrationWorktreePath {
            try? await gitWorkspaceManager.removeWorktree(
              repositoryURL: Self.productWorkspaceURL(productID: item.productID),
              worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
            )
          }
        }
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Product Owner",
          reason: "Demo feedback: \(body.prefix(160))"
        )
        _ = try await store.updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product Owner",
          eventDetail: "Demo feedback received; work queued to resume"
        )
      } else {
        return
      }
      await reloadSelectedProduct()
      scheduleSprintExecution()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func monitorLiveActivity(
    runID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  ) {
    stopLiveActivityMonitoring(runID: runID)
    let monitorID = UUID()
    liveActivityMonitorIDs[runID] = monitorID
    let initialActivity = CodexLiveActivity(text: initialText, kind: .thinking)
    liveRunActivities[runID] = initialActivity

    liveActivityTasks[runID] = Task { [weak self] in
      guard let self else { return }
      await self.persistRunTelemetry(
        runID: runID,
        activity: initialActivity,
        startsTurn: true
      )
      var accumulator = CodexLiveActivityAccumulator()
      // Execution threads have only one active turn. Some App Server versions return
      // a provisional turn id from turn/start and use a different durable id in
      // notifications. Subscribe only to new messages and route telemetry by thread
      // so those runs do not appear silent.
      let messages = await client.inboundMessages(replayRecent: false)
      var lastHeartbeatAt = Date.distantPast
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard
          notification.params["threadId"]?.stringValue == threadID
        else { continue }
        guard self.liveActivityMonitorIDs[runID] == monitorID else { return }

        let now = Date()
        let contextUsedTokens = notification.method == "thread/tokenUsage/updated"
          ? notification.params["tokenUsage"]?["last"]?["totalTokens"]?.integerValue.map(Int.init)
          : nil
        let contextWindowTokens = notification.method == "thread/tokenUsage/updated"
          ? notification.params["tokenUsage"]?["modelContextWindow"]?.integerValue.map(Int.init)
          : nil
        let didCompact =
          notification.method == "item/completed"
          && notification.params["item"]?["type"]?.stringValue == "contextCompaction"
        let update = accumulator.consume(notification)

        if case .activity(let activity) = update {
          self.liveRunActivities[runID] = activity
          await self.persistRunTelemetry(
            runID: runID,
            activity: activity,
            contextUsedTokens: contextUsedTokens,
            contextWindowTokens: contextWindowTokens,
            didCompact: didCompact,
            at: now
          )
          lastHeartbeatAt = now
        } else if
          contextUsedTokens != nil
            || contextWindowTokens != nil
            || didCompact
            || now.timeIntervalSince(lastHeartbeatAt) >= 5
        {
          await self.persistRunTelemetry(
            runID: runID,
            contextUsedTokens: contextUsedTokens,
            contextWindowTokens: contextWindowTokens,
            didCompact: didCompact,
            at: now
          )
          lastHeartbeatAt = now
        }

        if case .turnFinished = update {
          self.liveRunActivities.removeValue(forKey: runID)
          self.liveActivityMonitorIDs.removeValue(forKey: runID)
          self.liveActivityTasks.removeValue(forKey: runID)
          return
        }
      }

      guard self.liveActivityMonitorIDs[runID] == monitorID else { return }
      self.liveRunActivities.removeValue(forKey: runID)
      self.liveActivityMonitorIDs.removeValue(forKey: runID)
      self.liveActivityTasks.removeValue(forKey: runID)
    }
  }

  private func persistRunTelemetry(
    runID: UUID,
    activity: CodexLiveActivity? = nil,
    contextUsedTokens: Int? = nil,
    contextWindowTokens: Int? = nil,
    didCompact: Bool = false,
    startsTurn: Bool = false,
    at: Date = Date()
  ) async {
    guard let store else { return }
    guard
      let updated = try? await store.recordAgentRunActivity(
        id: runID,
        activity: activity,
        contextUsedTokens: contextUsedTokens,
        contextWindowTokens: contextWindowTokens,
        didCompact: didCompact,
        startsTurn: startsTurn,
        at: at
      )
    else { return }
    if let index = runs.firstIndex(where: { $0.id == updated.id }) {
      runs[index] = updated
    } else {
      runs.append(updated)
    }
  }

  private func stopLiveActivityMonitoring(runID: UUID) {
    liveActivityTasks.removeValue(forKey: runID)?.cancel()
    liveActivityMonitorIDs.removeValue(forKey: runID)
    liveRunActivities.removeValue(forKey: runID)
  }

  private func suspendSprintExecution() async {
    let executionTask = sprintExecutionTask
    executionTask?.cancel()
    let implementationTasks = Array(activeImplementationTasks.values)
    for task in implementationTasks {
      task.cancel()
    }
    if let client = codexClient {
      let turns = activeExecutionTurns.values
      await withTaskGroup(of: Void.self) { group in
        for turn in turns {
          group.addTask {
            try? await client.interruptTurn(
              threadID: turn.threadID,
              turnID: turn.turnID
            )
          }
        }
      }
    }
    if executionTask != nil {
      for _ in 0..<100 {
        guard sprintExecutionTask != nil || !activeImplementationTasks.isEmpty else { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    sprintExecutionTask = nil
    activeImplementationTasks.removeAll()
    activeExecutionTurns.removeAll()
    for task in liveActivityTasks.values {
      task.cancel()
    }
    liveActivityTasks.removeAll()
    liveActivityMonitorIDs.removeAll()
    liveRunActivities.removeAll()
  }

  func shutdown() async {
    suggestionTask?.cancel()
    suggestionTask = nil
    await suspendSprintExecution()
    await codexClient?.disconnect()
    codexClient = nil
  }

  private func makeRetrospectiveNotes(
    productID: UUID,
    sprintID: UUID,
    workItemID: UUID,
    profile: AgentProfile,
    wentWell: [String],
    couldImprove: [String],
    actions: [RetrospectiveActionProposal]
  ) -> [RetrospectiveNote] {
    let observations: [(RetrospectiveNoteCategory, [String])] = [
      (.wentWell, wentWell),
      (.couldImprove, couldImprove),
    ]
    let evidence = observations.flatMap { category, values in
      values.prefix(2).map { body in
        RetrospectiveNote(
          productID: productID,
          sprintID: sprintID,
          workItemID: workItemID,
          profileID: profile.id,
          authorName: profile.name,
          category: category,
          body: body
        )
      }
    }
    let proposedActions = actions.prefix(2).map { action in
      RetrospectiveNote(
        productID: productID,
        sprintID: sprintID,
        workItemID: workItemID,
        profileID: profile.id,
        authorName: profile.name,
        category: .suggestedAction,
        body: action.body,
        actionStatus: .proposed,
        actionDestination: action.destination
      )
    }
    return evidence + proposedActions
  }

  private func inheritedAgentInstructions(for product: Product) -> String {
    let shared = product.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let waysOfWorking = knowledgePages.first(where: {
        $0.productID == product.id
          && $0.slug == "ways-of-working"
          && $0.verificationStatus == .verified
      })
    else {
      return shared
    }
    let practices = waysOfWorking.bodyMarkdown.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !practices.isEmpty else { return shared }
    return [
      shared,
      """
      VERIFIED WAYS OF WORKING
      These practices were accepted by the Product Owner and apply to this task:
      \(practices)
      """,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
  }

  private func deliveryNoteMarkdown(
    item: WorkItem,
    result: TicketExecutionResult,
    authorName: String
  ) -> String {
    let checks = result.tests.isEmpty
      ? "- No automated checks were reported."
      : result.tests.map { "- \($0)" }.joined(separator: "\n")
    let review = result.reviewInstructions.map { "- \($0)" }.joined(separator: "\n")
    let knowledge = result.knowledgeNotes.isEmpty
      ? "- No durable decision or limitation was reported."
      : result.knowledgeNotes.map { "- \($0)" }.joined(separator: "\n")
    let files = result.changedFiles.isEmpty
      ? "- No changed file was reported."
      : result.changedFiles.map { "- `\($0)`" }.joined(separator: "\n")
    return """
      # \(item.key) · \(item.title)

      **Delivery evidence:** Prepared with the candidate revision  
      **Prepared by:** \(authorName)

      ## What changed
      \(result.summary.isEmpty ? result.comment : result.summary)

      ## How it works and why
      \(knowledge)

      ## Changed files
      \(files)

      ## Checks performed
      \(checks)

      ## How the Product Owner can review it
      \(review)

      ## Known limitations
      \(result.knowledgeNotes.isEmpty ? "- None recorded." : knowledge)
      """
  }

  private func makeKnowledgePageProposals(
    drafts: [KnowledgePageProposalDraft],
    candidate: CandidateRevision,
    runID: UUID
  ) throws -> [KnowledgePageProposal] {
    let suppliedPageIDs = Set(
      agentRunKnowledgeContext
        .filter { $0.runID == runID }
        .map(\.pageID)
    )
    let pagesByID = Dictionary(uniqueKeysWithValues: knowledgePages.map { ($0.id, $0) })
    return try drafts.map { draft in
      let basePage = draft.targetPageID.flatMap { pagesByID[$0] }
      switch draft.operation {
      case .update:
        guard
          let targetPageID = draft.targetPageID,
          suppliedPageIDs.contains(targetPageID),
          let page = pagesByID[targetPageID],
          page.productID == candidate.productID,
          page.kind != .deliveryNote
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page update referenced a page that was not supplied to the agent."
          )
        }
      case .create:
        guard
          let parentPageID = draft.parentPageID,
          suppliedPageIDs.contains(parentPageID),
          let parent = pagesByID[parentPageID],
          parent.productID == candidate.productID,
          parent.kind == .section
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page creation referenced a section that was not supplied to the agent."
          )
        }
      }
      return KnowledgePageProposal(
        productID: candidate.productID,
        sprintID: candidate.sprintID,
        workItemID: candidate.workItemID,
        candidateRevisionID: candidate.id,
        operation: draft.operation,
        targetPageID: draft.targetPageID,
        parentPageID: draft.parentPageID,
        basePageTitle: basePage?.title,
        basePageBodyMarkdown: basePage?.bodyMarkdown,
        basePageUpdatedAt: basePage?.updatedAt,
        title: draft.title,
        proposedBodyMarkdown: draft.proposedBodyMarkdown,
        rationale: draft.rationale
      )
    }
  }

  private static func writeDeliveryNoteMarkdown(
    _ markdown: String,
    sprintNumber: Int,
    item: WorkItem,
    workspaceURL: URL
  ) throws {
    let directory = workspaceURL
      .appendingPathComponent("knowledge", isDirectory: true)
      .appendingPathComponent("delivery-history", isDirectory: true)
      .appendingPathComponent("sprint-\(sprintNumber)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("\(item.key.lowercased()).md")
    try Data(markdown.utf8).write(to: fileURL, options: .atomic)
  }

  private func relevantKnowledgeContext(
    for item: WorkItem,
    prerequisites: [WorkItem]
  ) -> [KnowledgePage] {
    let verified = knowledgePages.filter { $0.verificationStatus == .verified }
    let prerequisiteIDs = Set(prerequisites.map(\.id))
    let explicit = verified.filter {
      $0.sourceWorkItemID == item.id
        || $0.sourceWorkItemID.map(prerequisiteIDs.contains) == true
        || ["overview", "product-principles", "glossary", "ways-of-working"].contains($0.slug)
    }
    let terms = Set(
      "\(item.title) \(item.body)"
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .filter { $0.count >= 4 }
        .map(String.init)
    )
    let explicitIDs = Set(explicit.map(\.id))
    var scoredPages: [(page: KnowledgePage, score: Int)] = []
    for page in verified where !explicitIDs.contains(page.id) {
      let pageText = "\(page.title) \(page.bodyMarkdown)".lowercased()
      var score = 0
      for term in terms where pageText.contains(term) {
        score += 1
      }
      if score > 0 {
        scoredPages.append((page: page, score: score))
      }
    }
    scoredPages.sort { lhs, rhs in
      lhs.score == rhs.score ? lhs.page.title < rhs.page.title : lhs.score > rhs.score
    }
    let scored = scoredPages.prefix(5).map(\.page)
    var selected = Array((explicit + scored).prefix(8))
    let pagesByID = Dictionary(uniqueKeysWithValues: verified.map { ($0.id, $0) })
    var selectedIDs = Set(selected.map(\.id))
    for page in selected {
      var parentID = page.parentID
      while let id = parentID, let parent = pagesByID[id] {
        if selectedIDs.insert(parent.id).inserted {
          selected.append(parent)
        }
        parentID = parent.parentID
      }
    }
    return Array(selected.prefix(12))
  }

  func reload() async {
    guard let store else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      products = try await store.fetchProducts()
      if !didResolveInitialProductSelection {
        didResolveInitialProductSelection = true
        let rememberedSelectionIsValid = products.contains { $0.id == selectedProductID }
        shouldPresentProductLibraryOnLaunch = products.count > 1 && !rememberedSelectionIsValid
        if !rememberedSelectionIsValid {
          selectedProductID = products.first?.id
        }
      } else if !products.contains(where: { $0.id == selectedProductID }) {
        selectedProductID = products.first?.id
      }
      if let selectedProductID {
        rememberSelectedProduct(selectedProductID)
      }
      await reloadSelectedProduct()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadSelectedProduct() async {
    guard let store, let productID = selectedProductID else {
      epics = []
      workItems = []
      dependencies = []
      profiles = []
      sprintPlan = nil
      sprintHistory = []
      runs = []
      sprintReadinessIssues = []
      activity = []
      suggestionBatch = nil
      retrospectiveNotes = []
      knowledgePages = []
      candidateRevisions = []
      knowledgePageProposals = []
      agentRunKnowledgeContext = []
      return
    }
    do {
      epics = try await store.fetchEpics(productID: productID)
      workItems = try await store.fetchWorkItems(productID: productID)
      dependencies = try await store.fetchWorkItemDependencies(productID: productID)
      profiles = try await store.seedDefaultProfiles(productID: productID)
      knowledgePages = try await store.seedKnowledgeBase(productID: productID)
      try Self.syncKnowledgeMarkdownFiles(
        productID: productID,
        pages: knowledgePages
      )
      agentRunKnowledgeContext = try await store.fetchAgentRunKnowledgeContext(
        productID: productID
      )
      candidateRevisions = try await store.fetchCandidateRevisions(productID: productID)
      knowledgePageProposals = try await store.fetchKnowledgePageProposals(productID: productID)
      let refinedUnownedItems = workItems.filter {
        $0.state != .cancelled
          && $0.ownerProfileID == nil
          && !$0.acceptanceCriteria.isEmpty
      }
      if !refinedUnownedItems.isEmpty {
        for item in refinedUnownedItems {
          guard let owner = TicketOwnerRouter.owner(for: item, profiles: profiles) else {
            continue
          }
          _ = try await store.assignWorkItemOwner(id: item.id, profileID: owner.id)
        }
        workItems = try await store.fetchWorkItems(productID: productID)
      }
      sprintPlan = try await store.fetchCurrentSprint(productID: productID)
      sprintHistory = try await store.fetchSprintHistory(productID: productID)
      runs = try await store.fetchAgentRuns(productID: productID)
      if let candidateSprintPlan {
        sprintReadinessIssues = try await store.sprintReadinessIssues(
          sprintID: candidateSprintPlan.sprint.id
        )
      } else {
        sprintReadinessIssues = []
      }
      activity = try await store.fetchActivity(productID: productID)
      retrospectiveNotes = try await store.fetchRetrospectiveNotes(productID: productID)
      suggestionBatch = try await store.fetchLatestTicketSuggestionBatch(productID: productID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func connectCodex() async {
    codexConnectionState = .checking
    let candidates = Self.codexRuntimeCandidates()

    do {
      let descriptor = try await Task.detached(priority: .userInitiated) {
        try CodexRuntimeResolver().resolve(candidates: candidates)
      }.value
      let transport = CodexJSONLTransport(
        configuration: .init(executableURL: descriptor.executableURL)
      )
      let client = CodexAppServerClient(transport: transport)
      let info = try await client.connect()
      codexClient = client
      codexConnectionState = .connected(version: descriptor.version, userAgent: info.userAgent)
      codexModels = (try? await client.listModels()) ?? []
    } catch let error as CodexRuntimeError {
      switch error {
      case .incompatible:
        codexConnectionState = .incompatible(error.localizedDescription)
      default:
        codexConnectionState = .unavailable(error.localizedDescription)
      }
    } catch {
      codexConnectionState = .unavailable(error.localizedDescription)
    }
  }

  private func recoverInterruptedSuggestionSession() async {
    guard
      let store,
      let productID = selectedProductID,
      let session = suggestionBatch?.session,
      session.status == .generating
    else { return }

    try? await store.failTicketSuggestionSession(
      sessionID: session.id,
      message: "StoryPointless closed before this proposal finished. Please try again."
    )
    suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(productID: productID)
  }

  private static func codexRuntimeCandidates() -> [CodexRuntimeCandidate] {
    var candidates: [CodexRuntimeCandidate] = []
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "codex") {
      candidates.append(CodexRuntimeCandidate(executableURL: bundled, source: .bundled))
    }

    #if DEBUG
      candidates.append(
        CodexRuntimeCandidate(
          executableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
          source: .developmentFixture
        )
      )
    #endif

    return candidates
  }

  private static func applicationSupportURL() throws -> URL {
    guard
      let root = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return root.appendingPathComponent("StoryPointless", isDirectory: true)
  }

  private func rememberSelectedProduct(_ id: UUID) {
    UserDefaults.standard.set(id.uuidString, forKey: Self.selectedProductDefaultsKey)
  }

  private static func productWorkspaceURL(productID: UUID) throws -> URL {
    let url = try applicationSupportURL()
      .appendingPathComponent("Product Workspaces", isDirectory: true)
      .appendingPathComponent(productID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func ticketWorktreesRootURL(productID: UUID) throws -> URL {
    let url = try applicationSupportURL()
      .appendingPathComponent("Run Worktrees", isDirectory: true)
      .appendingPathComponent(productID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func integrationWorktreesRootURL(productID: UUID) throws -> URL {
    let url = try applicationSupportURL()
      .appendingPathComponent("Integration Worktrees", isDirectory: true)
      .appendingPathComponent(productID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func syncKnowledgeMarkdownFiles(
    productID: UUID,
    pages: [KnowledgePage]
  ) throws {
    try syncKnowledgeMarkdownFiles(
      at: productWorkspaceURL(productID: productID),
      pages: pages
    )
  }

  private static func syncKnowledgeMarkdownFiles(
    at workspaceURL: URL,
    pages: [KnowledgePage]
  ) throws {
    let knowledgeRoot = workspaceURL
      .appendingPathComponent("knowledge", isDirectory: true)
    try FileManager.default.createDirectory(
      at: knowledgeRoot,
      withIntermediateDirectories: true
    )
    let pagesByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })

    func ancestorSlugs(for page: KnowledgePage) -> [String] {
      var slugs: [String] = []
      var parentID = page.parentID
      while let id = parentID, let parent = pagesByID[id] {
        slugs.insert(parent.slug, at: 0)
        parentID = parent.parentID
      }
      return slugs
    }

    for page in pages {
      var directory = knowledgeRoot
      for slug in ancestorSlugs(for: page) {
        directory.appendPathComponent(slug, isDirectory: true)
      }
      if page.kind == .section {
        directory.appendPathComponent(page.slug, isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        directory.appendPathComponent("index.md")
      } else {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        directory.appendPathComponent("\(page.slug).md")
      }
      guard page.verificationStatus == .verified else {
        if FileManager.default.fileExists(atPath: directory.path) {
          try FileManager.default.removeItem(at: directory)
        }
        continue
      }
      let markdown = page.bodyMarkdown.isEmpty
        ? "# \(page.title)\n"
        : page.bodyMarkdown
      try Data(markdown.utf8).write(to: directory, options: .atomic)
    }
  }
}
