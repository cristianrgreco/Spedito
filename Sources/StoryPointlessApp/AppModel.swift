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

struct EpicPlanningConversationState: Equatable {
  let epicID: UUID
  var messages: [EpicPlanningConversationMessage]
  var questions: [TicketRefinementQuestion]
  var hasStartedPlanning: Bool
  var isRunning: Bool
  var isGeneratingPlan: Bool
  var isComplete: Bool
  var errorMessage: String?
}

private struct SprintExecutionContext {
  let product: Product
  let plan: SprintPlan
  let workItems: [WorkItem]
  let dependencies: [WorkItemDependency]
  let profiles: [AgentProfile]
  let runs: [AgentRun]
  let candidates: [CandidateRevision]
  let permissionRequests: [AgentPermissionRequest]
  let permissionGrants: [AgentPermissionGrant]
  let knowledgePages: [KnowledgePage]
}

enum ProductExecutionLifecycleEvent: Equatable {
  case productSelectionChanged
  case productArchived(UUID)
  case appShutdown
}

enum ProductExecutionSuspensionScope: Equatable {
  case none
  case product(UUID)
  case all
}

struct ProductExecutionLifecyclePolicy {
  static func suspensionScope(
    for event: ProductExecutionLifecycleEvent
  ) -> ProductExecutionSuspensionScope {
    switch event {
    case .productSelectionChanged:
      .none
    case .productArchived(let productID):
      .product(productID)
    case .appShutdown:
      .all
    }
  }
}

enum PlanningDropConstraint: Equatable {
  case sprintScope
  case rank
  case unavailable
}

enum PlanningDropRankAction: Equatable {
  case preserve
  case move(before: UUID?)
}

struct PlanningDropEvaluation: Equatable {
  let rankAction: PlanningDropRankAction?
  let blockingConstraint: PlanningDropConstraint?
  let message: String?

  var isValid: Bool {
    blockingConstraint == nil
  }

  static func valid(_ rankAction: PlanningDropRankAction) -> Self {
    PlanningDropEvaluation(
      rankAction: rankAction,
      blockingConstraint: nil,
      message: nil
    )
  }

  static func invalid(
    _ constraint: PlanningDropConstraint,
    message: String
  ) -> Self {
    PlanningDropEvaluation(
      rankAction: nil,
      blockingConstraint: constraint,
      message: message
    )
  }
}

struct PlanningDropPolicy {
  private static let planningStates: Set<WorkItemState> = [
    .backlog,
    .refining,
    .ready,
  ]

  static func evaluate(
    workItems: [WorkItem],
    dependencies: [WorkItemDependency],
    candidateIDs: Set<UUID>,
    externalCandidatePrerequisiteIDs: Set<UUID>,
    movingIDs requestedMovingIDs: Set<UUID>,
    intoCandidateSprint: Bool,
    before requestedTargetID: UUID?
  ) -> PlanningDropEvaluation {
    let planningItems = workItems.filter { planningStates.contains($0.state) }
    let planningIDs = Set(planningItems.map(\.id))
    let movingIDs = requestedMovingIDs.intersection(planningIDs)
    guard !movingIDs.isEmpty, movingIDs == requestedMovingIDs else {
      return .invalid(
        .unavailable,
        message: "These tickets are no longer available for planning"
      )
    }

    let desiredCandidateIDs =
      intoCandidateSprint
      ? candidateIDs.union(movingIDs)
      : candidateIDs.subtracting(movingIDs)
    let availableCandidateIDs =
      desiredCandidateIDs.union(externalCandidatePrerequisiteIDs)
    let itemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    let sortedDependencies = dependencies.sorted { lhs, rhs in
      let lhsDependent = itemsByID[lhs.workItemID]
      let rhsDependent = itemsByID[rhs.workItemID]
      if lhsDependent?.rank != rhsDependent?.rank {
        return (lhsDependent?.rank ?? .max) < (rhsDependent?.rank ?? .max)
      }
      if lhsDependent?.key != rhsDependent?.key {
        return (lhsDependent?.key ?? "") < (rhsDependent?.key ?? "")
      }
      return (itemsByID[lhs.dependsOnWorkItemID]?.key ?? "")
        < (itemsByID[rhs.dependsOnWorkItemID]?.key ?? "")
    }

    if let edge = sortedDependencies.first(where: {
      desiredCandidateIDs.contains($0.workItemID)
        && !availableCandidateIDs.contains($0.dependsOnWorkItemID)
    }) {
      let dependentKey = itemsByID[edge.workItemID]?.key ?? "The dependant ticket"
      let prerequisiteKey =
        itemsByID[edge.dependsOnWorkItemID]?.key ?? "its prerequisite"
      let message =
        intoCandidateSprint
        ? "Move \(prerequisiteKey) too; \(dependentKey) depends on it"
        : "Move \(dependentKey) too; it depends on \(prerequisiteKey)"
      return .invalid(.sprintScope, message: message)
    }

    let nonMovingDestinationItems = planningItems.filter { item in
      !movingIDs.contains(item.id)
        && desiredCandidateIDs.contains(item.id) == intoCandidateSprint
    }
    if let requestedTargetID,
      !nonMovingDestinationItems.contains(where: { $0.id == requestedTargetID })
    {
      return .invalid(
        .unavailable,
        message: "That drop position is no longer available"
      )
    }

    let movingItems = planningItems.filter { movingIDs.contains($0.id) }
    var desiredDestinationIDs = nonMovingDestinationItems.map(\.id)
    let destinationInsertionIndex =
      requestedTargetID.flatMap { targetID in
        desiredDestinationIDs.firstIndex(of: targetID)
      } ?? desiredDestinationIDs.endIndex
    desiredDestinationIDs.insert(
      contentsOf: movingItems.map(\.id),
      at: destinationInsertionIndex
    )

    let currentDestinationIDs = planningItems.compactMap { item -> UUID? in
      guard desiredCandidateIDs.contains(item.id) == intoCandidateSprint else {
        return nil
      }
      return item.id
    }

    let rankAction: PlanningDropRankAction
    if currentDestinationIDs == desiredDestinationIDs {
      rankAction = .preserve
    } else if let requestedTargetID {
      rankAction = .move(before: requestedTargetID)
    } else if let lastDestinationID = nonMovingDestinationItems.last?.id {
      let remainingItems = planningItems.filter { !movingIDs.contains($0.id) }
      let lastDestinationIndex = remainingItems.firstIndex {
        $0.id == lastDestinationID
      }
      let anchorID = lastDestinationIndex.flatMap { index in
        remainingItems.dropFirst(index + 1).first?.id
      }
      rankAction = .move(before: anchorID)
    } else {
      // An empty destination section does not express a new global rank.
      rankAction = .preserve
    }

    let reorderedItems: [WorkItem]
    switch rankAction {
    case .preserve:
      reorderedItems = planningItems
    case .move(let targetID):
      var remainingItems = planningItems.filter { !movingIDs.contains($0.id) }
      let insertionIndex =
        targetID.flatMap { targetID in
          remainingItems.firstIndex { $0.id == targetID }
        } ?? remainingItems.endIndex
      remainingItems.insert(contentsOf: movingItems, at: insertionIndex)
      reorderedItems = remainingItems
    }

    let indexByID = Dictionary(
      uniqueKeysWithValues: reorderedItems.enumerated().map {
        ($0.element.id, $0.offset)
      }
    )
    if let edge = sortedDependencies.first(where: { edge in
      guard
        let dependentIndex = indexByID[edge.workItemID],
        let prerequisiteIndex = indexByID[edge.dependsOnWorkItemID]
      else {
        return false
      }
      return dependentIndex < prerequisiteIndex
    }) {
      let dependentKey = itemsByID[edge.workItemID]?.key ?? "The dependant ticket"
      let prerequisiteKey =
        itemsByID[edge.dependsOnWorkItemID]?.key ?? "its prerequisite"
      let message =
        movingIDs.contains(edge.dependsOnWorkItemID)
          && !movingIDs.contains(edge.workItemID)
        ? "Place \(prerequisiteKey) above \(dependentKey)"
        : "Place \(dependentKey) below \(prerequisiteKey)"
      return .invalid(.rank, message: message)
    }

    return .valid(rankAction)
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var products: [Product] = []
  @Published private(set) var archivedProducts: [Product] = []
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
  @Published private(set) var retrospectiveSyntheses: [RetrospectiveSynthesis] = []
  @Published private(set) var retrospectiveActionSources: [RetrospectiveActionSource] = []
  @Published private(set) var knowledgePages: [KnowledgePage] = []
  @Published private(set) var candidateRevisions: [CandidateRevision] = []
  @Published private(set) var demoSessions: [DemoSession] = []
  @Published private(set) var permissionRequests: [AgentPermissionRequest] = []
  @Published private(set) var permissionGrants: [AgentPermissionGrant] = []
  @Published private(set) var knowledgePageProposals: [KnowledgePageProposal] = []
  @Published private(set) var agentRunKnowledgeContext: [AgentRunKnowledgePage] = []
  @Published private(set) var agentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] = []
  @Published private(set) var liveRunActivities: [UUID: CodexLiveActivity] = [:]
  @Published private(set) var suggestionBatch: TicketSuggestionBatch?
  @Published private(set) var codexModels: [CodexModelOption] = []
  @Published private(set) var codexConnectionState = CodexConnectionState.notChecked
  @Published var selectedProductID: UUID?
  @Published private(set) var shouldPresentProductLibraryOnLaunch = false
  @Published var errorMessage: String?
  @Published private(set) var isLoading = true
  @Published private(set) var isDecidingSuggestions = false
  @Published private(set) var isPlanningMessageRunning = false
  @Published private(set) var isTicketConversationMessageRunning = false
  @Published private(set) var ticketConversationWorkItemID: UUID?
  @Published private(set) var ticketConversationRecipientID: UUID?
  @Published private(set) var isEpicConversationMessageRunning = false
  @Published private(set) var epicConversationEpicID: UUID?
  @Published private(set) var epicConversationRecipientID: UUID?
  @Published private(set) var ticketRefinementResults: [UUID: TicketRefinementSessionResult] = [:]
  @Published private(set) var ticketConversationResults: [UUID: TicketConversationSessionResult] = [:]
  @Published private(set) var epicPlanningConversation: EpicPlanningConversationState?
  @Published private(set) var isAskingKnowledge = false
  @Published private(set) var refiningWorkItemID: UUID?
  @Published private(set) var codebaseFocusWorkItemID: UUID?
  @Published private(set) var knowledgeFocusPageID: UUID?
  @Published var backlogFocusEpicID: UUID?

  let requiresKnowledgeApproval = StoryPointlessFeatureFlags.requiresKnowledgeApproval

  var planningEpics: [Epic] {
    epics
      .filter { $0.status != .archived }
      .sorted {
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        return $0.createdAt < $1.createdAt
      }
  }

  var openEpics: [Epic] {
    planningEpics.filter { $0.status == .open }
  }

  var candidateSprintPlan: SprintPlan? {
    if let sprintPlan, sprintPlan.sprint.state == .draft {
      return sprintPlan
    }
    return sprintHistory.first { $0.sprint.state == .draft }
  }

  private let store: SQLiteStore?
  private let gitWorkspaceManager = GitWorkspaceManager()
  private let demoLauncher = MacOSDemoLauncher()
  private let sprintWorkRecoveryPolicy = SprintWorkRecoveryPolicy()
  private let ticketSuggestionRecoveryPolicy = TicketSuggestionRecoveryPolicy()
  private var codexClient: CodexAppServerClient?
  private var suggestionTask: Task<Void, Never>?
  private var planningThreadIDs: [PlanningConversationKey: String] = [:]
  private var ticketConversationThreadIDs: [PlanningConversationKey: String] = [:]
  private var epicConversationThreadIDs: [PlanningConversationKey: String] = [:]
  private var activePlanningTurn: (threadID: String, turnID: String)?
  private var activeTicketConversationTurn: (threadID: String, turnID: String)?
  private var activeEpicConversationTurn: (threadID: String, turnID: String)?
  private var activeTicketRefinementTurn: (threadID: String, turnID: String)?
  private var epicPlanningThreadID: String?
  private var activeEpicPlanningTurn: (threadID: String, turnID: String)?
  private var epicPlanningTask: Task<Void, Never>?
  private var epicConversationPersistenceTask: Task<Void, Never>?
  private var sprintExecutionTasks: [UUID: Task<Void, Never>] = [:]
  private var sprintExecutionTaskIDs: [UUID: UUID] = [:]
  private var sprintExecutionWakeContinuations: [
    UUID: AsyncStream<Void>.Continuation
  ] = [:]
  private var activeImplementationTasks: [UUID: Task<Void, Never>] = [:]
  private var activeImplementationProductIDs: [UUID: UUID] = [:]
  private var activeReviewTasks: [UUID: Task<Void, Never>] = [:]
  private var activeReviewProductIDs: [UUID: UUID] = [:]
  private var activeIntegrationTasks: [UUID: Task<Void, Never>] = [:]

  private struct ActiveExecutionTurn: Sendable {
    let productID: UUID
    let threadID: String
    let turnID: String
  }

  private var activeExecutionTurns: [UUID: ActiveExecutionTurn] = [:]
  private var liveApprovalRequests: [UUID: CodexServerRequest] = [:]
  private var liveApprovalRequestProductIDs: [UUID: UUID] = [:]
  private var approvalRoutingTask: Task<Void, Never>?
  private var manuallyStoppedRunIDs: Set<UUID> = []
  private var liveActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var liveActivityMonitorIDs: [UUID: UUID] = [:]
  private var liveActivityProductIDs: [UUID: UUID] = [:]
  private var retrospectiveSynthesisTasks: [UUID: Task<Void, Never>] = [:]
  private var activeRetrospectiveSynthesisTurns: [
    UUID: (threadID: String, turnID: String)
  ] = [:]
  private var didLoad = false
  private var didResolveInitialProductSelection = false
  private var automaticallyRecoveredSuggestionSessionIDs: Set<UUID> = []
  private var isShuttingDown = false

  private static let selectedProductDefaultsKey = "selectedProductID"

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

  init(store: SQLiteStore?, selectedProductID: UUID? = nil) {
    self.store = store
    self.selectedProductID = selectedProductID
  }

  var selectedProduct: Product? {
    products.first { $0.id == selectedProductID }
  }

  var canAutosuggestTickets: Bool {
    guard case .connected = codexConnectionState else { return false }
    guard suggestionBatch?.session.status != .generating else { return false }
    guard !isPlanningMessageRunning else { return false }
    guard !isTicketConversationMessageRunning else { return false }
    guard !isEpicConversationMessageRunning else { return false }
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
    guard !isEpicConversationMessageRunning else { return false }
    return refiningWorkItemID == nil
  }

  var pendingSuggestionCount: Int {
    guard
      suggestionBatch?.session.epicID != nil
        || suggestionBatch?.session.sourceWorkItemID != nil
    else { return 0 }
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
    if isEpicConversationMessageRunning {
      return "A team member is replying in an epic conversation."
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
    try? await store?.interruptPendingAgentPermissionRequests()
    try? await store?.requeueGeneratingRetrospectiveSyntheses()
    await reload()
    await recoverDemoSessions()
    await connectCodex()
    await recoverTicketSuggestionSessionIfNeeded()
    scheduleRetrospectiveSyntheses()
    scheduleSprintExecutions()
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
      archivedProducts = try await store.fetchProducts(status: .archived)
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
    guard product.status == .active else { return }
    if let departingProductID = selectedProductID {
      await stopDemoSessions(
        productID: departingProductID,
        includesPreparation: false
      )
    }
    await applyExecutionLifecycle(.productSelectionChanged)
    suggestionTask?.cancel()
    planningThreadIDs.removeAll()
    ticketConversationThreadIDs.removeAll()
    epicConversationThreadIDs.removeAll()
    selectedProductID = product.id
    rememberSelectedProduct(product.id)
    await reloadSelectedProduct()
    await recoverTicketSuggestionSessionIfNeeded()
    scheduleRetrospectiveSyntheses()
    scheduleSprintExecution(productID: product.id)
  }

  func archiveSelectedProduct() async -> Bool {
    guard
      let store,
      let product = selectedProduct,
      product.status == .active
    else { return false }

    await stopDemoSessions(productID: product.id, includesPreparation: true)
    await applyExecutionLifecycle(.productArchived(product.id))
    let interruptedSuggestionTask = suggestionTask
    let interruptedEpicPlanningTask = epicPlanningTask
    interruptedSuggestionTask?.cancel()
    interruptedEpicPlanningTask?.cancel()
    if let client = codexClient, let activeEpicPlanningTurn {
      try? await client.interruptTurn(
        threadID: activeEpicPlanningTurn.threadID,
        turnID: activeEpicPlanningTurn.turnID
      )
    }
    await interruptedSuggestionTask?.value
    await interruptedEpicPlanningTask?.value
    suggestionTask = nil
    epicPlanningTask = nil
    activeEpicPlanningTurn = nil
    planningThreadIDs.removeAll()
    ticketConversationThreadIDs.removeAll()
    epicConversationThreadIDs.removeAll()

    do {
      _ = try await store.archiveProduct(id: product.id)
      products = try await store.fetchProducts()
      archivedProducts = try await store.fetchProducts(status: .archived)
      selectedProductID = products.first?.id
      if let selectedProductID {
        rememberSelectedProduct(selectedProductID)
      } else {
        forgetSelectedProduct()
      }
      await reloadSelectedProduct()
      await recoverTicketSuggestionSessionIfNeeded()
      scheduleSprintExecution()
      return true
    } catch {
      errorMessage = error.localizedDescription
      scheduleSprintExecution(productID: product.id)
      return false
    }
  }

  func restoreProductAndSelect(_ product: Product) async -> Bool {
    guard let store, product.status == .archived else { return false }
    do {
      _ = try await store.restoreProduct(id: product.id)
      products = try await store.fetchProducts()
      archivedProducts = try await store.fetchProducts(status: .archived)
      guard let restored = products.first(where: { $0.id == product.id }) else {
        throw PersistenceError.recordNotFound("restored product \(product.id)")
      }
      await selectProduct(restored)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
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
    constraints: String
  ) async -> Epic? {
    guard let store else { return nil }
    do {
      let updated = try await store.updateEpic(
        id: epic.id,
        title: title,
        goal: goal,
        successCriteria: successCriteria,
        constraints: constraints
      )
      await reloadSelectedProduct()
      return updated
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func closeEpic(_ epic: Epic) async -> Epic? {
    guard let store else { return nil }
    do {
      let closed = try await store.closeEpic(id: epic.id)
      await reloadSelectedProduct()
      return closed
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func reopenEpic(_ epic: Epic) async -> Epic? {
    guard let store else { return nil }
    do {
      let reopened = try await store.reopenEpic(id: epic.id)
      await reloadSelectedProduct()
      return reopened
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func moveEpics(_ epics: [Epic], before targetID: UUID?) {
    guard let store, !epics.isEmpty else { return }
    Task {
      do {
        self.epics = try await store.moveEpics(
          ids: epics.map(\.id),
          before: targetID
        )
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func archiveEpic(_ epic: Epic) {
    guard let store else { return }
    Task {
      do {
        try await store.archiveEpic(id: epic.id)
        if backlogFocusEpicID == epic.id {
          backlogFocusEpicID = nil
        }
        await reloadSelectedProduct()
      } catch {
        errorMessage = error.localizedDescription
      }
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
        || isEpicConversationMessageRunning
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
      !isEpicConversationMessageRunning,
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

  func sendEpicConversationMessage(
    for epic: Epic,
    to recipient: AgentProfile,
    ownerMessage: String
  ) async throws -> EpicConversationReply {
    guard
      !isEpicConversationMessageRunning,
      !isTicketConversationMessageRunning,
      !isPlanningMessageRunning,
      refiningWorkItemID == nil,
      suggestionBatch?.session.status != .generating,
      epicPlanningConversation?.isRunning != true,
      epicPlanningConversation?.isGeneratingPlan != true
    else {
      throw EpicConversationGenerationError.anotherCodexTaskIsRunning
    }
    guard
      let client = codexClient,
      let product = selectedProduct,
      product.id == epic.productID,
      epic.status == .open,
      recipient.productID == product.id,
      profiles.contains(where: { $0.id == recipient.id })
    else {
      throw CodexClientError.notConnected
    }
    let trimmedMessage = ownerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      throw EpicConversationGenerationError.invalidResponse("Enter a message first.")
    }

    await restoreEpicPlanningConversation(for: epic)
    guard !Task.isCancelled, selectedProductID == epic.productID else {
      throw CodexClientError.notConnected
    }
    let previousMessages =
      epicPlanningConversation?.epicID == epic.id
      ? epicPlanningConversation?.messages ?? []
      : []
    ensureEpicConversationState(for: epic.id)
    updateEpicPlanningConversation {
      $0.messages.append(
        EpicPlanningConversationMessage(
          author: .owner,
          body: "@\(recipient.name) \(trimmedMessage)",
          kind: .chat,
          participantID: recipient.id,
          participantName: recipient.name
        )
      )
    }

    isEpicConversationMessageRunning = true
    epicConversationEpicID = epic.id
    epicConversationRecipientID = recipient.id
    defer {
      isEpicConversationMessageRunning = false
      epicConversationEpicID = nil
      epicConversationRecipientID = nil
      activeEpicConversationTurn = nil
    }

    let currentEpic = epics.first(where: { $0.id == epic.id }) ?? epic
    let relatedItems = workItems.filter {
      $0.epicID == epic.id && $0.state != .cancelled
    }
    let proposedItems =
      suggestionBatch?.session.epicID == epic.id
      ? suggestionBatch?.suggestions.filter { $0.status == .proposed } ?? []
      : []
    let conversationKey = PlanningConversationKey(
      workItemID: epic.id,
      profileID: recipient.id
    )

    do {
      let threadID: String
      if let existingThreadID = epicConversationThreadIDs[conversationKey] {
        threadID = existingThreadID
      } else {
        let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
        threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: CodexEpicConversation.developerInstructions(
            productInstructions: inheritedAgentInstructions(for: product),
            personaInstructions: recipient.effectiveInstructions,
            recipient: recipient
          ),
          model: recipient.model
        )
        epicConversationThreadIDs[conversationKey] = threadID
      }
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexEpicConversation.prompt(
          product: product,
          epic: currentEpic,
          relatedItems: relatedItems,
          proposedItems: proposedItems,
          previousMessages: previousMessages,
          ownerMessage: trimmedMessage
        ),
        effort: recipient.reasoningEffort,
        outputSchema: CodexEpicConversation.outputSchema
      )
      activeEpicConversationTurn = (threadID: threadID, turnID: turnID)
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let reply = try CodexEpicConversation.decode(response)
      updateEpicPlanningConversation {
        $0.messages.append(
          EpicPlanningConversationMessage(
            author: .agent,
            body: reply.message,
            kind: .chat,
            participantID: recipient.id,
            participantName: recipient.name
          )
        )
      }
      return reply
    } catch {
      epicConversationThreadIDs.removeValue(forKey: conversationKey)
      updateEpicPlanningConversation {
        $0.messages.append(
          EpicPlanningConversationMessage(
            author: .system,
            body: "\(recipient.name) couldn't reply: \(error.localizedDescription)",
            kind: .chat
          )
        )
      }
      throw error
    }
  }

  func cancelEpicConversationMessage() {
    guard let client = codexClient, let activeEpicConversationTurn else { return }
    Task {
      try? await client.interruptTurn(
        threadID: activeEpicConversationTurn.threadID,
        turnID: activeEpicConversationTurn.turnID
      )
    }
  }

  func dismissTicketAssistantResult(workItemID: UUID) {
    ticketRefinementResults.removeValue(forKey: workItemID)
    ticketConversationResults.removeValue(forKey: workItemID)
  }

  private func ensureEpicConversationState(for epicID: UUID) {
    guard epicPlanningConversation?.epicID != epicID else { return }
    epicPlanningThreadID = nil
    epicPlanningConversation = EpicPlanningConversationState(
      epicID: epicID,
      messages: [],
      questions: [],
      hasStartedPlanning: false,
      isRunning: false,
      isGeneratingPlan: false,
      isComplete: false,
      errorMessage: nil
    )
    persistEpicPlanningConversation()
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
      _ = try await store.updateWorkItem(
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
      await reloadSelectedProduct()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func moveWorkItem(_ workItem: WorkItem, to position: WorkItemRankPosition) {
    moveWorkItems([workItem], to: position)
  }

  func moveWorkItems(_ selectedItems: [WorkItem], to position: WorkItemRankPosition) {
    guard let store else { return }
    let selectedIDs = Set(selectedItems.map(\.id))
    guard !selectedIDs.isEmpty else { return }
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    let planningItems = workItems.filter { planningStates.contains($0.state) }
    let orderedItems = planningItems.filter { selectedIDs.contains($0.id) }
    let targetID: UUID?
    switch position {
    case .top:
      targetID = planningItems.first { !selectedIDs.contains($0.id) }?.id
    case .bottom:
      targetID = nil
    }
    Task {
      do {
        workItems = try await store.moveWorkItems(
          ids: orderedItems.map(\.id),
          before: targetID
        )
        if let productID = orderedItems.first?.productID {
          activity = try await store.fetchActivity(productID: productID)
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func archiveWorkItem(_ workItem: WorkItem) {
    archiveWorkItems([workItem])
  }

  func archiveWorkItems(_ selectedItems: [WorkItem]) {
    guard let store else { return }
    let selectedIDs = Set(selectedItems.map(\.id))
    guard !selectedIDs.isEmpty else { return }
    Task {
      do {
        try await store.archiveWorkItems(ids: Array(selectedIDs))
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

  func proposeRetrospectiveAction(
    sprintID: UUID,
    body: String,
    destination: RetrospectiveActionDestination
  ) async -> RetrospectiveNote? {
    guard let store, let productID = selectedProductID else { return nil }
    do {
      let note = try await store.proposeRetrospectiveAction(
        productID: productID,
        sprintID: sprintID,
        body: body,
        destination: destination
      )
      await reloadSelectedProduct()
      return retrospectiveNotes.first { $0.id == note.id } ?? note
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func prepareRetrospectiveSynthesisIfNeeded(sprintID: UUID) {
    guard
      let synthesis = retrospectiveSyntheses.first(where: {
        $0.sprintID == sprintID && $0.status == .pending
      })
    else { return }
    scheduleRetrospectiveSynthesis(synthesis)
  }

  func retryRetrospectiveSynthesis(_ synthesis: RetrospectiveSynthesis) {
    guard synthesis.status == .failed else { return }
    scheduleRetrospectiveSynthesis(synthesis, allowsFailedRetry: true)
  }

  func skipRetrospectiveSynthesis(_ synthesis: RetrospectiveSynthesis) async {
    guard let store else { return }
    do {
      _ = try await store.skipRetrospectiveSynthesis(id: synthesis.id)
      await reloadSelectedProduct()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func retrospectiveSources(for actionNoteID: UUID) -> [RetrospectiveNote] {
    let sourceIDs = Set(
      retrospectiveActionSources
        .filter { $0.actionNoteID == actionNoteID }
        .map(\.sourceNoteID)
    )
    return retrospectiveNotes
      .filter { sourceIDs.contains($0.id) }
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.createdAt < $1.createdAt
      }
  }

  func decideRetrospectiveAction(
    _ note: RetrospectiveNote,
    accept: Bool
  ) async -> WorkItem? {
    guard let store else { return nil }
    guard
      let noteIndex = retrospectiveNotes.firstIndex(where: { $0.id == note.id }),
      retrospectiveNotes[noteIndex].actionStatus == .proposed
    else { return nil }

    let previousNote = retrospectiveNotes[noteIndex]
    let decidedStatus: RetrospectiveActionStatus = accept ? .accepted : .dismissed
    retrospectiveNotes[noteIndex].actionStatus = decidedStatus
    retrospectiveNotes[noteIndex].updatedAt = Date()

    do {
      let createdItem = try await store.decideRetrospectiveAction(
        noteID: note.id,
        accept: accept
      )
      await reloadSelectedProduct()
      guard let createdItem else { return nil }
      return workItems.first { $0.id == createdItem.id } ?? createdItem
    } catch {
      if let currentIndex = retrospectiveNotes.firstIndex(where: { $0.id == note.id }),
        retrospectiveNotes[currentIndex].actionStatus == decidedStatus
      {
        retrospectiveNotes[currentIndex] = previousNote
      }
      errorMessage = error.localizedDescription
      return nil
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

  func appendOwnerComment(
    workItemID: UUID,
    body: String,
    answeredQuestions: [TicketAnsweredQuestion] = []
  ) async -> TicketComment? {
    guard let store else { return nil }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let comment = try await store.appendComment(
        workItemID: workItemID,
        authorKind: .owner,
        authorName: "Me",
        body: trimmed,
        answeredQuestions: answeredQuestions
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
    body: String,
    answeredQuestions: [TicketAnsweredQuestion] = []
  ) async -> TicketComment? {
    guard
      let comment = await appendOwnerComment(
        workItemID: workItemID,
        body: body,
        answeredQuestions: answeredQuestions
      )
    else {
      return nil
    }
    await handleSprintOwnerComment(workItemID: workItemID, body: comment.body)
    return comment
  }

  func canRetryFailedPostReviewDemo(workItemID: UUID) -> Bool {
    sprintWorkRecoveryPolicy.failedPostReviewDemoCandidate(
      workItemID: workItemID,
      workItems: workItems,
      candidates: candidateRevisions,
      runs: runs,
      profiles: profiles
    ) != nil
  }

  func retryFailedPostReviewDemo(workItemID: UUID) async -> Bool {
    guard
      let store,
      let recoverableCandidate = sprintWorkRecoveryPolicy.failedPostReviewDemoCandidate(
        workItemID: workItemID,
        workItems: workItems,
        candidates: candidateRevisions,
        runs: runs,
        profiles: profiles
      ),
      let integratedSHA = recoverableCandidate.integratedSHA,
      let implementationRun = runs.first(where: {
        $0.id == recoverableCandidate.implementationRunID
      }),
      let result = try? CodexTicketExecutor.decode(
        recoverableCandidate.executionResultJSON
      ),
      let specification = result.demo
    else {
      return false
    }

    let reviewerName = profiles.first { profile in
      guard profile.role == .lead else { return false }
      return runs.contains {
        $0.workItemID == workItemID
          && $0.profileID == profile.id
          && $0.status == .completed
          && $0.worktreePath == recoverableCandidate.integrationWorktreePath
      }
    }?.name ?? "Tech Lead"

    do {
      let candidate = try await store.fetchCandidateRevision(
        id: recoverableCandidate.id
      )
      guard
        candidate.status == .failed,
        let item = try await store.fetchWorkItems(productID: candidate.productID)
          .first(where: { $0.id == workItemID }),
        item.state == .running
      else {
        return false
      }

      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .reviewing
      )
      _ = try await store.updateAgentRun(
        id: implementationRun.id,
        status: .running,
        eventActor: "StoryPointless",
        eventDetail: "Retrying demo preparation for the reviewed candidate"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .integrating,
        actor: "StoryPointless",
        reason: "Retrying the reviewed candidate handoff"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .verifying,
        actor: "StoryPointless",
        reason: "Re-running demo preparation against the reviewed revision"
      )
      await reloadSelectedProduct()

      try await prepareDemoForAcceptance(
        candidate: candidate,
        integratedSHA: integratedSHA,
        specification: specification
      )
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .readyForDemo
      )
      _ = try await store.updateAgentRun(
        id: implementationRun.id,
        status: .completed,
        eventActor: "StoryPointless",
        eventDetail: "Demo preparation succeeded on retry"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .acceptance,
        actor: reviewerName,
        reason: "Reviewed candidate prepared successfully for Product Owner demo"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "Demo preparation succeeded on retry. The already reviewed candidate was preserved; implementation and Tech Lead review were not repeated."
      )
      await reloadSelectedProduct()
      return true
    } catch {
      _ = try? await store.updateCandidateRevision(
        id: recoverableCandidate.id,
        status: .failed
      )
      _ = try? await store.updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "StoryPointless",
        eventDetail: "Demo preparation retry could not complete"
      )
      if
        let item = try? await store.fetchWorkItems(
          productID: recoverableCandidate.productID
        ).first(where: { $0.id == workItemID }),
        item.state == .integrating || item.state == .verifying
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "StoryPointless",
          reason: "Demo preparation retry stopped; preserving the reviewed candidate"
        )
      }
      _ = try? await store.appendComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "Demo preparation stopped unexpectedly again: \(error.localizedDescription)\n\nChoose Retry demo preparation to try the preserved reviewed candidate again."
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProduct()
      return false
    }
  }

  func launchDemo(for candidate: CandidateRevision) async -> Bool {
    guard
      let store,
      candidate.status == .readyForDemo,
      let integratedSHA = candidate.integratedSHA
    else { return false }
    do {
      let result = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      guard let specification = result.demo else {
        throw DemoLaunchValidationError.invalid(
          "this older candidate has no managed demo recipe. Request changes so the delivery agent can add one."
        )
      }
      try DemoLaunchSpecificationValidator.validate(specification)
      let previewURL = try await prepareCandidatePreview(
        candidate: candidate,
        integratedSHA: integratedSHA
      )
      var session = currentDemoSession(for: candidate.id) ?? DemoSession(
        productID: candidate.productID,
        candidateRevisionID: candidate.id,
        status: .preparing
      )
      session.status = .preparing
      session.previewWorktreePath = previewURL.path
      session.errorMessage = nil
      session.updatedAt = Date()
      session = try await store.saveDemoSession(session)
      replaceDemoSession(session)

      session.status = .starting
      session.updatedAt = Date()
      session = try await store.saveDemoSession(session)
      replaceDemoSession(session)

      let outcome = try await demoLauncher.launch(
        candidateID: candidate.id,
        specification: specification,
        workspaceURL: previewURL
      )
      session.status = .ready
      session.allocatedPort = outcome.allocatedPort
      session.output = outcome.output.map { String($0.suffix(80_000)) }
      session.errorMessage = nil
      session.updatedAt = Date()
      session = try await store.saveDemoSession(session)
      replaceDemoSession(session)
      return true
    } catch {
      var session = currentDemoSession(for: candidate.id) ?? DemoSession(
        productID: candidate.productID,
        candidateRevisionID: candidate.id,
        status: .failed
      )
      session.status = .failed
      session.errorMessage = error.localizedDescription
      session.updatedAt = Date()
      if let saved = try? await store.saveDemoSession(session) {
        replaceDemoSession(saved)
      }
      errorMessage = error.localizedDescription
      return false
    }
  }

  func stopDemo(for candidate: CandidateRevision) async {
    await stopDemoSession(candidate, removesPreview: false)
  }

  func currentDemoSession(for candidateRevisionID: UUID) -> DemoSession? {
    demoSessions.first { $0.candidateRevisionID == candidateRevisionID }
  }

  private func replaceDemoSession(_ session: DemoSession) {
    guard selectedProductID == session.productID else { return }
    demoSessions.removeAll { $0.candidateRevisionID == session.candidateRevisionID }
    demoSessions.append(session)
    demoSessions.sort { $0.createdAt < $1.createdAt }
  }

  private func storedDemoSession(for candidate: CandidateRevision) async -> DemoSession? {
    guard let store else { return nil }
    return try? await store.fetchDemoSessions(productID: candidate.productID)
      .first { $0.candidateRevisionID == candidate.id }
  }

  private func stopDemoSession(
    _ candidate: CandidateRevision,
    removesPreview: Bool
  ) async {
    await demoLauncher.stop(candidateID: candidate.id)
    guard let store, var session = await storedDemoSession(for: candidate) else { return }
    if
      removesPreview,
      let previewPath = session.previewWorktreePath,
      let repositoryURL = try? Self.productWorkspaceURL(productID: candidate.productID)
    {
      try? await gitWorkspaceManager.removeWorktree(
        repositoryURL: repositoryURL,
        worktreeURL: URL(fileURLWithPath: previewPath, isDirectory: true)
      )
      session.previewWorktreePath = nil
    }
    session.status = .stopped
    session.allocatedPort = nil
    session.errorMessage = nil
    session.updatedAt = Date()
    if let saved = try? await store.saveDemoSession(session) {
      replaceDemoSession(saved)
    }
  }

  private func stopDemoSessions(
    productID: UUID,
    includesPreparation: Bool
  ) async {
    guard let store else { return }
    let productSessions =
      (try? await store.fetchDemoSessions(productID: productID)) ?? []
    let stoppableStatuses: [DemoSessionStatus] = includesPreparation
      ? [.preparing, .starting, .ready]
      : [.starting, .ready]
    for var session in productSessions where stoppableStatuses.contains(session.status) {
      await demoLauncher.stop(candidateID: session.candidateRevisionID)
      session.status = .stopped
      session.allocatedPort = nil
      session.errorMessage = nil
      session.updatedAt = Date()
      if let saved = try? await store.saveDemoSession(session) {
        replaceDemoSession(saved)
      }
    }
  }

  private func stopAllDemoSessions() async {
    await demoLauncher.stopAll()
    guard let store else { return }
    let activeSessions = demoSessions.filter {
      $0.status == .preparing || $0.status == .starting || $0.status == .ready
    }
    for var session in activeSessions {
      session.status = .stopped
      session.allocatedPort = nil
      session.errorMessage = nil
      session.updatedAt = Date()
      if let saved = try? await store.saveDemoSession(session) {
        replaceDemoSession(saved)
      }
    }
  }

  private func recoverDemoSessions() async {
    await stopAllDemoSessions()
  }

  private func prepareCandidatePreview(
    candidate: CandidateRevision,
    integratedSHA: String
  ) async throws -> URL {
    let repositoryURL = try Self.productWorkspaceURL(productID: candidate.productID)
    let previewsRootURL = try Self.previewWorktreesRootURL(
      productID: candidate.productID
    )
    let expectedPreviewURL = previewsRootURL.appendingPathComponent(
      candidate.id.uuidString.lowercased(),
      isDirectory: true
    )
    if
      let existingPath = await storedDemoSession(for: candidate)?.previewWorktreePath,
      URL(fileURLWithPath: existingPath).standardizedFileURL
        != expectedPreviewURL.standardizedFileURL
    {
      try? await gitWorkspaceManager.removeWorktree(
        repositoryURL: repositoryURL,
        worktreeURL: URL(fileURLWithPath: existingPath, isDirectory: true)
      )
    }
    return try await gitWorkspaceManager.preparePreviewWorkspace(
      repositoryURL: repositoryURL,
      previewsRootURL: previewsRootURL,
      candidateID: candidate.id,
      integratedSHA: integratedSHA
    )
  }

  private func prepareDemoForAcceptance(
    candidate: CandidateRevision,
    integratedSHA: String,
    specification: DemoLaunchSpecification
  ) async throws {
    guard let store else { return }
    let previewURL = try await prepareCandidatePreview(
      candidate: candidate,
      integratedSHA: integratedSHA
    )
    var session = await storedDemoSession(for: candidate) ?? DemoSession(
      productID: candidate.productID,
      candidateRevisionID: candidate.id,
      status: .preparing
    )
    session.status = .preparing
    session.previewWorktreePath = previewURL.path
    session.output = nil
    session.errorMessage = nil
    session.updatedAt = Date()
    session = try await store.saveDemoSession(session)
    replaceDemoSession(session)
    do {
      let output = try await demoLauncher.smokeTest(
        candidateID: candidate.id,
        specification: specification,
        workspaceURL: previewURL
      )
      session.status = .stopped
      session.output = output.map { String($0.suffix(80_000)) }
      session.updatedAt = Date()
      session = try await store.saveDemoSession(session)
      replaceDemoSession(session)
    } catch {
      session.status = .failed
      session.errorMessage = error.localizedDescription
      session.updatedAt = Date()
      session = try await store.saveDemoSession(session)
      replaceDemoSession(session)
      throw error
    }
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
      let executionResult = try CodexTicketExecutor.decode(candidate.executionResultJSON)
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
      await stopDemoSession(candidate, removesPreview: true)
      let repositoryURL = try Self.productWorkspaceURL(productID: item.productID)
      guard
        try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
          repositoryURL: repositoryURL,
          integratedSHA: integratedSHA
        )
      else {
        try await requeueStaleReadyCandidate(
          candidate,
          reason:
            "Accepted trunk advanced after this demo revision was prepared."
        )
        await reloadSelectedProduct()
        scheduleSprintExecution(productID: item.productID)
        return false
      }
      try await gitWorkspaceManager.promote(
        repositoryURL: repositoryURL,
        integratedSHA: integratedSHA
      )
      if !executionResult.followUpTicketProposals.isEmpty {
        _ = try await store.createFollowUpTicketSuggestionSession(
          sourceWorkItemID: current.id,
          drafts: followUpSuggestionDrafts(
            executionResult.followUpTicketProposals,
            source: current
          )
        )
      }
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
        body:
          "Product Owner approved candidate v\(candidate.version). Integrated revision "
          + "\(String(integratedSHA.prefix(8))) is now the accepted trunk."
          + (executionResult.followUpTicketProposals.isEmpty
            ? ""
            : " \(executionResult.followUpTicketProposals.count) follow-up "
              + (executionResult.followUpTicketProposals.count == 1
                ? "ticket is"
                : "tickets are")
              + " ready for review in the Backlog.")
      )
      try await requeueStaleReadyCandidates(
        productID: item.productID,
        excluding: candidate.id
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
      scheduleRetrospectiveSyntheses()
      scheduleSprintExecution()
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProduct()
      return false
    }
  }

  private func followUpSuggestionDrafts(
    _ proposals: [FollowUpTicketProposalDraft],
    source: WorkItem
  ) -> [TicketSuggestionDraft] {
    let referenceMap = Dictionary(
      uniqueKeysWithValues: proposals.enumerated().map { index, proposal in
        (proposal.reference, "S\(index + 1)")
      }
    )
    return proposals.enumerated().map { index, proposal in
      TicketSuggestionDraft(
        reference: "S\(index + 1)",
        title: proposal.title,
        type: proposal.type,
        body: proposal.body,
        acceptanceCriteria: proposal.acceptanceCriteria,
        suggestedRole: proposal.suggestedRole,
        priority: proposal.priority,
        rationale: proposal.rationale,
        dependsOnReferences: proposal.dependsOnReferences.compactMap {
          referenceMap[$0]
        },
        dependsOnExistingWorkItemKeys: [source.key]
      )
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
      !isTicketConversationMessageRunning,
      !isEpicConversationMessageRunning
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
          ?? workItem?.ownerProfileID,
        reviewerProfileID: sprintItem.reviewerProfileID,
        estimatedTokens: sprintItem.estimatedTokens
      )
    } ?? []
    let newInputs: [SprintDraftItemInput] = workItems
      .filter { selectedIDs.contains($0.id) }
      .map { item in
        return SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: item.ownerProfileID,
          estimatedTokens: 0
        )
      }
    let inputs = currentInputs + newInputs

    Task {
      do {
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
    let evaluation = planningDropEvaluation(
      ids: movingIDs,
      intoCandidateSprint: intoCandidateSprint,
      before: targetID
    )
    guard evaluation.isValid, let rankAction = evaluation.rankAction else {
      return
    }
    let desiredCandidateIDs = intoCandidateSprint
      ? existingCandidateIDs.union(movingIDs)
      : existingCandidateIDs.subtracting(movingIDs)

    let existingItemsByID = Dictionary(
      uniqueKeysWithValues: (candidatePlan?.items ?? []).map { ($0.workItemID, $0) }
    )
    let shouldSaveSprint = desiredCandidateIDs != existingCandidateIDs

    Task {
      do {
        let reorderedItems: [WorkItem]
        switch rankAction {
        case .preserve:
          reorderedItems = workItems
        case .move(let resolvedTargetID):
          reorderedItems = try await store.moveWorkItems(
            ids: selectedItems.map(\.id),
            before: resolvedTargetID
          )
        }
        if shouldSaveSprint {
          let inputs = reorderedItems.compactMap { item -> SprintDraftItemInput? in
            guard desiredCandidateIDs.contains(item.id) else { return nil }
            let existing = existingItemsByID[item.id]
            return SprintDraftItemInput(
              workItemID: item.id,
              implementerProfileID: existing?.implementerProfileID
                ?? item.ownerProfileID,
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

  func planningDropEvaluation(
    ids: Set<UUID>,
    intoCandidateSprint: Bool,
    before targetID: UUID?
  ) -> PlanningDropEvaluation {
    PlanningDropPolicy.evaluate(
      workItems: workItems,
      dependencies: dependencies,
      candidateIDs: Set(candidateSprintPlan?.items.map(\.workItemID) ?? []),
      externalCandidatePrerequisiteIDs: externalCandidatePrerequisiteIDs,
      movingIDs: ids,
      intoCandidateSprint: intoCandidateSprint,
      before: targetID
    )
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

  func restoreEpicPlanningConversation(for epic: Epic) async {
    guard epicPlanningConversation?.epicID != epic.id else { return }
    await epicConversationPersistenceTask?.value
    guard !Task.isCancelled, let store else { return }

    do {
      guard let snapshot = try await store.fetchEpicPlanningConversation(epicID: epic.id) else {
        epicPlanningConversation = nil
        epicPlanningThreadID = nil
        activeEpicPlanningTurn = nil
        return
      }
      guard !Task.isCancelled else { return }
      epicPlanningThreadID = snapshot.threadID
      activeEpicPlanningTurn = nil
      let hasStartedPlanning = snapshot.hasStartedPlanning ?? true
      epicPlanningConversation = EpicPlanningConversationState(
        epicID: snapshot.epicID,
        messages: snapshot.messages,
        questions: snapshot.questions,
        hasStartedPlanning: hasStartedPlanning,
        isRunning: false,
        isGeneratingPlan: false,
        isComplete: snapshot.isComplete,
        errorMessage:
          !hasStartedPlanning || snapshot.isComplete || !snapshot.questions.isEmpty
          ? nil
          : "Epic planning was paused when the app closed. You can safely try again."
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func planEpic(_ epic: Epic) {
    guard
      canPlanEpic,
      let product = selectedProduct,
      epic.productID == product.id,
      epic.status == .open
    else { return }

    epicPlanningTask?.cancel()
    let existingMessages =
      epicPlanningConversation?.epicID == epic.id
      ? epicPlanningConversation?.messages ?? []
      : []
    epicPlanningConversation = EpicPlanningConversationState(
      epicID: epic.id,
      messages: existingMessages,
      questions: [],
      hasStartedPlanning: true,
      isRunning: true,
      isGeneratingPlan: false,
      isComplete: false,
      errorMessage: nil
    )
    persistEpicPlanningConversation()
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
        persistEpicPlanningConversation()
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

  func continueEpicPlanning(
    _ epic: Epic,
    answers: [String],
    answeredQuestions: [EpicPlanningAnsweredQuestion]
  ) {
    continueEpicPlanning(
      epic,
      answers: answers,
      answeredQuestions: answeredQuestions,
      recordsAnswers: true,
      requiresReplacementThread: false
    )
  }

  private func continueEpicPlanning(
    _ epic: Epic,
    answers: [String],
    answeredQuestions: [EpicPlanningAnsweredQuestion],
    recordsAnswers: Bool,
    requiresReplacementThread: Bool
  ) {
    guard
      !answers.isEmpty,
      answers.count == answeredQuestions.count,
      epicPlanningConversation?.epicID == epic.id,
      epicPlanningConversation?.isRunning == false,
      epicPlanningConversation?.isGeneratingPlan == false,
      !isEpicConversationMessageRunning,
      let client = codexClient,
      let product = selectedProduct,
      product.id == epic.productID,
      let analyst = profiles.first(where: { $0.role == .businessAnalyst })
    else { return }

    updateEpicPlanningConversation {
      if recordsAnswers {
        $0.messages.append(
          EpicPlanningConversationMessage(
            author: .owner,
            body: "",
            answeredQuestions: answeredQuestions
          )
        )
      }
      $0.questions = []
      $0.isRunning = true
      $0.errorMessage = nil
    }
    let messages = epicPlanningConversation?.messages ?? []
    let preferredThreadID = requiresReplacementThread ? nil : epicPlanningThreadID
    epicPlanningTask?.cancel()
    epicPlanningTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await runEpicClarificationTurn(
          client: client,
          preferredThreadID: preferredThreadID,
          prompt: CodexEpicClarificationGenerator.followUpPrompt(answers: answers),
          recoveryPrompt: CodexEpicClarificationGenerator.recoveryPrompt(
            product: product,
            epic: epic,
            existingItems: workItems,
            messages: messages
          ),
          product: product,
          analyst: analyst
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

  func retryEpicPlanning(_ epic: Epic) {
    guard
      let conversation = epicPlanningConversation,
      conversation.epicID == epic.id,
      conversation.isRunning == false,
      conversation.isGeneratingPlan == false
    else { return }

    if
      let answeredQuestions = conversation.messages.last?.answeredQuestions,
      !answeredQuestions.isEmpty
    {
      let answers = answeredQuestions.map {
        "\($0.question.prompt)\nAnswer: \($0.answer)"
      }
      continueEpicPlanning(
        epic,
        answers: answers,
        answeredQuestions: answeredQuestions,
        recordsAnswers: false,
        requiresReplacementThread: true
      )
      return
    }

    epicPlanningThreadID = nil
    activeEpicPlanningTurn = nil
    updateEpicPlanningConversation {
      $0.messages = $0.messages.filter { $0.kind == .chat }
      $0.questions = []
      $0.hasStartedPlanning = false
      $0.errorMessage = nil
    }
    planEpic(epic)
  }

  private func runEpicClarificationTurn(
    client: CodexAppServerClient,
    preferredThreadID: String?,
    prompt: String,
    recoveryPrompt: String,
    product: Product,
    analyst: AgentProfile
  ) async throws -> String {
    if let preferredThreadID {
      do {
        return try await runEpicStructuredTurn(
          client: client,
          threadID: preferredThreadID,
          prompt: prompt,
          effort: analyst.reasoningEffort
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        activeEpicPlanningTurn = nil
      }
    }

    let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
    let replacementThreadID = try await client.startReadOnlyThread(
      workingDirectory: workingDirectory,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product),
        personaInstructions: analyst.effectiveInstructions
      ),
      model: analyst.model
    )
    epicPlanningThreadID = replacementThreadID
    persistEpicPlanningConversation()
    return try await runEpicStructuredTurn(
      client: client,
      threadID: replacementThreadID,
      prompt: recoveryPrompt,
      effort: analyst.reasoningEffort
    )
  }

  private func runEpicStructuredTurn(
    client: CodexAppServerClient,
    threadID: String,
    prompt: String,
    effort: String
  ) async throws -> String {
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: prompt,
      effort: effort,
      outputSchema: CodexEpicClarificationGenerator.outputSchema
    )
    activeEpicPlanningTurn = (threadID: threadID, turnID: turnID)
    return try await client.waitForFinalAgentMessage(
      threadID: threadID,
      turnID: turnID
    )
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
    deletePersistedEpicPlanningConversation(epicID: epicID)
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

  private func generateEpicPlan(
    _ epic: Epic,
    recovering recoveredSession: SuggestionSession? = nil
  ) {
    guard
      let store,
      let client = codexClient,
      let product = selectedProduct
    else { return }

    let analyst = profiles.first { $0.role == .businessAnalyst }
    let existingItems = workItems.filter { $0.state != .cancelled }
    let previouslyRejectedSuggestions =
      suggestionBatch?.session.epicID == epic.id
      ? suggestionBatch?.suggestions.filter { $0.status == .rejected } ?? []
      : []
    let durableMessages = epicPlanningConversation?.epicID == epic.id
      ? epicPlanningConversation?.messages ?? []
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

        let response = try await runEpicPlanTurn(
          client: client,
          store: store,
          session: startedSession,
          recoveredSession: recoveredSession,
          product: product,
          epic: epic,
          existingItems: existingItems,
          rejectedSuggestions: previouslyRejectedSuggestions,
          durableMessages: durableMessages,
          analyst: analyst
        )
        try Task.checkCancellation()
        let plan: EpicPlanDraft
        do {
          plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            response,
            existingItems: existingItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          guard let repairThreadID = epicPlanningThreadID else {
            throw CodexClientError.invalidThreadResponse
          }
          let repairedResponse = try await runEpicPlanStructuredTurn(
            client: client,
            store: store,
            sessionID: startedSession.id,
            threadID: repairThreadID,
            prompt:
              CodexTicketSuggestionGenerator.repairPrompt(
                validationError: validationError.localizedDescription,
                existingItems: existingItems
              )
              + "\nReturn the complete corrected epic metadata and ticket plan.",
            effort: analyst?.reasoningEffort ?? "medium"
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
          constraints: plan.constraints
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
                + " for you to review in the Tickets section."
            )
          )
          $0.isGeneratingPlan = false
          $0.isComplete = true
        }
      } catch is CancellationError {
        activeEpicPlanningTurn = nil
        if let session, !isShuttingDown {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Epic planning was interrupted. You can safely try again."
          )
        }
        if !isShuttingDown {
          updateEpicPlanningConversation {
            $0.isGeneratingPlan = false
            $0.errorMessage = "Epic planning was interrupted. You can safely try again."
          }
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

  private func runEpicPlanTurn(
    client: CodexAppServerClient,
    store: SQLiteStore,
    session: SuggestionSession,
    recoveredSession: SuggestionSession?,
    product: Product,
    epic: Epic,
    existingItems: [WorkItem],
    rejectedSuggestions: [TicketSuggestion],
    durableMessages: [EpicPlanningConversationMessage],
    analyst: AgentProfile?
  ) async throws -> String {
    let developerInstructions = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: inheritedAgentInstructions(for: product),
      personaInstructions:
        analyst?.effectiveInstructions
        ?? AgentPersonaDefaults.instructions(for: .businessAnalyst)
    )
    let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
    var preferredThreadID = epicPlanningThreadID

    if let recoveredThreadID = recoveredSession?.codexThreadID {
      do {
        let resumedThreadID = try await client.resumeReadOnlyThread(
          threadID: recoveredThreadID,
          workingDirectory: workingDirectory,
          developerInstructions: developerInstructions,
          model: analyst?.model
        )
        preferredThreadID = resumedThreadID
        epicPlanningThreadID = resumedThreadID
        persistEpicPlanningConversation()
        if let recoveredTurnID = recoveredSession?.codexTurnID,
          let recoveredResponse = try? await client.completedAgentMessage(
            threadID: resumedThreadID,
            turnID: recoveredTurnID
          )
        {
          return recoveredResponse
        }
      } catch let error as CodexRPCError where error.isThreadNotFound {
        preferredThreadID = nil
      }
    }

    let standardPrompt = CodexEpicClarificationGenerator.finalPlanPrompt(
      product: product,
      epic: epic,
      existingItems: existingItems,
      rejectedSuggestions: rejectedSuggestions
    )
    if let preferredThreadID {
      do {
        return try await runEpicPlanStructuredTurn(
          client: client,
          store: store,
          sessionID: session.id,
          threadID: preferredThreadID,
          prompt: standardPrompt,
          effort: analyst?.reasoningEffort ?? "medium"
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        activeEpicPlanningTurn = nil
      }
    }

    let replacementThreadID = try await client.startReadOnlyThread(
      workingDirectory: workingDirectory,
      developerInstructions: developerInstructions,
      model: analyst?.model
    )
    epicPlanningThreadID = replacementThreadID
    persistEpicPlanningConversation()
    return try await runEpicPlanStructuredTurn(
      client: client,
      store: store,
      sessionID: session.id,
      threadID: replacementThreadID,
      prompt: CodexEpicClarificationGenerator.finalPlanRecoveryPrompt(
        product: product,
        epic: epic,
        existingItems: existingItems,
        rejectedSuggestions: rejectedSuggestions,
        messages: durableMessages
      ),
      effort: analyst?.reasoningEffort ?? "medium"
    )
  }

  private func runEpicPlanStructuredTurn(
    client: CodexAppServerClient,
    store: SQLiteStore,
    sessionID: UUID,
    threadID: String,
    prompt: String,
    effort: String
  ) async throws -> String {
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: prompt,
      effort: effort,
      outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema
    )
    activeEpicPlanningTurn = (threadID: threadID, turnID: turnID)
    try await store.attachCodexTurn(
      sessionID: sessionID,
      threadID: threadID,
      turnID: turnID
    )
    return try await client.waitForFinalAgentMessage(
      threadID: threadID,
      turnID: turnID
    )
  }

  private func updateEpicPlanningConversation(
    _ update: (inout EpicPlanningConversationState) -> Void
  ) {
    guard var conversation = epicPlanningConversation else { return }
    update(&conversation)
    epicPlanningConversation = conversation
    persistEpicPlanningConversation()
  }

  private func persistEpicPlanningConversation() {
    guard let store, let conversation = epicPlanningConversation else { return }
    let snapshot = EpicPlanningConversationSnapshot(
      epicID: conversation.epicID,
      messages: conversation.messages,
      questions: conversation.questions,
      isComplete: conversation.isComplete,
      threadID: epicPlanningThreadID,
      hasStartedPlanning: conversation.hasStartedPlanning
    )
    let previousTask = epicConversationPersistenceTask
    epicConversationPersistenceTask = Task { [weak self] in
      await previousTask?.value
      do {
        try await store.saveEpicPlanningConversation(snapshot)
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  private func deletePersistedEpicPlanningConversation(epicID: UUID) {
    guard let store else { return }
    let previousTask = epicConversationPersistenceTask
    epicConversationPersistenceTask = Task { [weak self] in
      await previousTask?.value
      do {
        try await store.deleteEpicPlanningConversation(epicID: epicID)
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func retryCurrentEpicPlan() {
    guard
      canPlanEpic,
      let store,
      let failedSession = suggestionBatch?.session,
      failedSession.status == .failed,
      let epicID = failedSession.epicID,
      let epic = epics.first(where: { $0.id == epicID })
    else { return }

    Task { [weak self] in
      guard let self else { return }
      do {
        let restartedSession = try await store.retryTicketSuggestionSession(
          sessionID: failedSession.id
        )
        suggestionBatch = TicketSuggestionBatch(session: restartedSession, suggestions: [])
        await restoreEpicPlanningConversation(for: epic)
        generateEpicPlan(epic)
      } catch {
        errorMessage = error.localizedDescription
      }
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
        if let session, !isShuttingDown {
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

  func decideTicketSuggestion(
    _ suggestion: TicketSuggestion,
    accept: Bool,
    completion: ((WorkItem?) -> Void)? = nil
  ) {
    guard let store, let productID = selectedProductID, !isDecidingSuggestions else { return }
    let previouslyProposedIDs = Set(
      suggestionBatch?.suggestions
        .filter { $0.status == .proposed }
        .map(\.id) ?? [suggestion.id]
    )
    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        suggestionBatch = try await store.decideTicketSuggestion(
          id: suggestion.id,
          decision: accept ? .accepted : .rejected
        )
        var acceptedItemsBySuggestionID: [UUID: WorkItem] = [:]
        if accept, let suggestionBatch {
          let createdItems = try await store.fetchWorkItems(productID: productID)
          let createdItemsByID = Dictionary(uniqueKeysWithValues: createdItems.map { ($0.id, $0) })
          for acceptedSuggestion in suggestionBatch.suggestions
          where previouslyProposedIDs.contains(acceptedSuggestion.id)
            && acceptedSuggestion.status == .accepted
          {
            guard
              let acceptedID = acceptedSuggestion.acceptedWorkItemID,
              var created = createdItemsByID[acceptedID]
            else { continue }
            if let owner = TicketOwnerRouter.owner(
              for: created,
              profiles: profiles,
              suggestedRole: acceptedSuggestion.suggestedRole
            ) {
              created = try await store.assignWorkItemOwner(
                id: created.id,
                profileID: owner.id
              )
            }
            acceptedItemsBySuggestionID[acceptedSuggestion.id] = created
          }
        }
        await reloadSelectedProduct()
        let acceptedItem = acceptedItemsBySuggestionID[suggestion.id]
        if let acceptedItem {
          completion?(workItems.first(where: { $0.id == acceptedItem.id }) ?? acceptedItem)
        } else {
          completion?(nil)
        }
      } catch {
        errorMessage = error.localizedDescription
        completion?(nil)
      }
    }
  }

  func rejectTicketSuggestion(
    _ suggestion: TicketSuggestion,
    completion: (() -> Void)? = nil
  ) {
    guard let store, !isDecidingSuggestions else { return }
    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        suggestionBatch = try await store.rejectTicketSuggestionCascade(id: suggestion.id)
        await reloadSelectedProduct()
        completion?()
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
        }
        if accept, let suggestionBatch {
          let createdItems = try await store.fetchWorkItems(productID: productID)
          let createdItemsByID = Dictionary(uniqueKeysWithValues: createdItems.map { ($0.id, $0) })
          for acceptedSuggestion in suggestionBatch.suggestions
          where proposedIDs.contains(acceptedSuggestion.id)
            && acceptedSuggestion.status == .accepted
          {
            guard
              let acceptedID = acceptedSuggestion.acceptedWorkItemID,
              let created = createdItemsByID[acceptedID],
              let owner = TicketOwnerRouter.owner(
                for: created,
                profiles: profiles,
                suggestedRole: acceptedSuggestion.suggestedRole
              )
            else { continue }
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
        let savedOwnerID = workItems
          .first(where: { $0.id == input.workItemID })?
          .ownerProfileID
        guard savedOwnerID != input.implementerProfileID else { continue }
        _ = try await store.assignWorkItemOwner(
          id: input.workItemID,
          profileID: input.implementerProfileID
        )
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

  func reassignDraftTicket(workItemID: UUID, to profileID: UUID?) async -> Bool {
    guard let plan = candidateSprintPlan else { return false }
    if let profileID,
      !profiles.contains(where: { $0.id == profileID && $0.role.canOwnDelivery })
    {
      return false
    }
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

  func assignTicketOwner(workItemID: UUID, to profileID: UUID?) async -> Bool {
    if candidateSprintPlan?.items.contains(where: { $0.workItemID == workItemID }) == true
    {
      return await reassignDraftTicket(workItemID: workItemID, to: profileID)
    }
    guard let store else { return false }
    if let profileID,
      !profiles.contains(where: { $0.id == profileID && $0.role.canOwnDelivery })
    {
      return false
    }
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

  private func scheduleSprintExecutions() {
    for product in products where product.status == .active {
      scheduleSprintExecution(productID: product.id)
    }
  }

  private func scheduleSprintExecution(productID: UUID? = nil) {
    guard
      codexClient != nil,
      let productID = productID ?? selectedProductID
    else { return }
    if sprintExecutionTasks[productID] != nil {
      sprintExecutionWakeContinuations[productID]?.yield()
      return
    }

    let schedulerID = UUID()
    sprintExecutionTaskIDs[productID] = schedulerID
    sprintExecutionTasks[productID] = Task { [weak self] in
      guard let self else { return }
      await drainSprintQueue(productID: productID, schedulerID: schedulerID)
    }
  }

  private func drainSprintQueue(productID: UUID, schedulerID: UUID) async {
    let (wakeStream, wakeContinuation) = AsyncStream<Void>.makeStream()
    sprintExecutionWakeContinuations[productID] = wakeContinuation
    var wakeIterator = wakeStream.makeAsyncIterator()
    defer {
      wakeContinuation.finish()
      if sprintExecutionTaskIDs[productID] == schedulerID {
        sprintExecutionWakeContinuations.removeValue(forKey: productID)
        sprintExecutionTasks.removeValue(forKey: productID)
        sprintExecutionTaskIDs.removeValue(forKey: productID)
      }
    }
    await recoverOrphanedExecutionRuns(productID: productID)
    await reloadSelectedProductIfCurrent(productID: productID)

    while !Task.isCancelled {
      guard let context = await sprintExecutionContext(productID: productID) else {
        return
      }

      let eligibleRuns = eligibleImplementationRuns(in: context)
      for run in eligibleRuns where activeImplementationTasks[run.id] == nil {
        activeImplementationProductIDs[run.id] = productID
        activeImplementationTasks[run.id] = Task { [weak self] in
          guard let self else { return }
          defer {
            activeImplementationTasks.removeValue(forKey: run.id)
            activeImplementationProductIDs.removeValue(forKey: run.id)
            sprintExecutionWakeContinuations[productID]?.yield()
          }
          await executeImplementationRun(run, context: context)
        }
      }

      let reviewCandidates = SprintCandidateAdmission.reviewQueue(
        candidates: context.candidates,
        sprintID: context.plan.sprint.id,
        workItems: context.workItems
      )
      for candidate in reviewCandidates where activeReviewTasks[candidate.id] == nil {
        activeReviewProductIDs[candidate.id] = productID
        activeReviewTasks[candidate.id] = Task { [weak self] in
          guard let self else { return }
          defer {
            activeReviewTasks.removeValue(forKey: candidate.id)
            activeReviewProductIDs.removeValue(forKey: candidate.id)
            sprintExecutionWakeContinuations[productID]?.yield()
          }
          await executeCandidateReview(candidate, context: context)
        }
      }
      let reviewerProfileIDs = Set(
        context.profiles.filter { $0.role == .lead }.map(\.id)
      )
      let resumableCandidateReviews: [(CandidateRevision, AgentRun)] =
        context.candidates.compactMap { candidate in
          guard
            candidate.sprintID == context.plan.sprint.id,
            candidate.status == .reviewing,
            candidate.integratedSHA == nil,
            let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
              for: candidate,
              runs: context.runs,
              reviewerProfileIDs: reviewerProfileIDs
            ),
            reviewRun.status == .queued
              || reviewRun.status == .running
              || reviewRun.status == .completed
          else { return nil }
          return (candidate, reviewRun)
        }
      for (candidate, reviewRun) in resumableCandidateReviews
      where activeReviewTasks[candidate.id] == nil {
        activeReviewProductIDs[candidate.id] = productID
        activeReviewTasks[candidate.id] = Task { [weak self] in
          guard let self else { return }
          defer {
            activeReviewTasks.removeValue(forKey: candidate.id)
            activeReviewProductIDs.removeValue(forKey: candidate.id)
            sprintExecutionWakeContinuations[productID]?.yield()
          }
          await resumeTechLeadReview(
            candidate: candidate,
            reviewRun: reviewRun,
            plan: context.plan
          )
        }
      }

      let processedIntegration = await processNextIntegrationCandidate(context: context)
      let hasActiveImplementation = activeImplementationProductIDs.values.contains(productID)
      let hasActiveReview = activeReviewProductIDs.values.contains(productID)
      let hasActiveIntegration = activeIntegrationTasks[productID] != nil
      if
        !hasActiveImplementation,
        !hasActiveReview,
        !hasActiveIntegration,
        eligibleRuns.isEmpty,
        reviewCandidates.isEmpty,
        resumableCandidateReviews.isEmpty,
        !processedIntegration
      {
        return
      }
      if
        (hasActiveImplementation || hasActiveReview || hasActiveIntegration)
          && !processedIntegration
      {
        guard await wakeIterator.next() != nil else { return }
      }
    }
  }

  private func sprintExecutionContext(productID: UUID) async -> SprintExecutionContext? {
    guard let store else { return nil }
    do {
      let availableProducts = try await store.fetchProducts()
      guard
        let product = availableProducts.first(where: { $0.id == productID }),
        product.status == .active,
        let plan = try await store.fetchCurrentSprint(productID: productID),
        plan.sprint.state == .active
      else { return nil }
      var productProfiles = try await store.fetchAgentProfiles(productID: productID)
      if productProfiles.isEmpty {
        productProfiles = try await store.seedDefaultProfiles(productID: productID)
      }
      let productKnowledge = try await store.seedKnowledgeBase(productID: productID)
      return SprintExecutionContext(
        product: product,
        plan: plan,
        workItems: try await store.fetchWorkItems(productID: productID),
        dependencies: try await store.fetchWorkItemDependencies(productID: productID),
        profiles: productProfiles,
        runs: try await store.fetchAgentRuns(productID: productID),
        candidates: try await store.fetchCandidateRevisions(productID: productID),
        permissionRequests: try await store.fetchAgentPermissionRequests(
          productID: productID
        ),
        permissionGrants: try await store.fetchAgentPermissionGrants(productID: productID),
        knowledgePages: productKnowledge
      )
    } catch {
      presentExecutionError(error, productID: productID)
      return nil
    }
  }

  private func reloadSelectedProductIfCurrent(productID: UUID) async {
    guard selectedProductID == productID else { return }
    await reloadSelectedProduct()
  }

  private func presentExecutionError(_ error: Error, productID: UUID) {
    guard selectedProductID == productID else { return }
    errorMessage = error.localizedDescription
  }

  private func recoverOrphanedExecutionRuns(productID: UUID) async {
    guard
      let store,
      let client = codexClient,
      let context = await sprintExecutionContext(productID: productID)
    else { return }
    let plan = context.plan
    let product = context.product
    let workItems = context.workItems
    let profiles = context.profiles
    let runs = context.runs
    let permissionRequests = context.permissionRequests
    let storedCandidates = (try? await store.fetchCandidateRevisions(productID: productID)) ?? []
    let implementerByItemID = Dictionary(
      uniqueKeysWithValues: plan.items.compactMap { item in
        item.implementerProfileID.map { (item.workItemID, $0) }
      }
    )
    let reviewerProfileIDs = Set(
      profiles
        .filter { $0.role == .lead }
        .map(\.id)
    )
    let expiredPermissionRuns = sprintWorkRecoveryPolicy.runsWithExpiredPermissionDecisions(
      runs: runs.filter { $0.productID == productID },
      permissionRequests: permissionRequests.filter { $0.productID == productID }
    )
    let expiredPermissionRunIDs = Set(expiredPermissionRuns.map(\.id))
    for run in expiredPermissionRuns {
      let isImplementer = implementerByItemID[run.workItemID] == run.profileID
      let latestCandidate = storedCandidates
        .filter { $0.workItemID == run.workItemID }
        .max(by: { $0.version < $1.version })
      let canResumeConflict =
        !isImplementer && latestCandidate?.status == .resolvingConflict
      let canResumeReview =
        !isImplementer
        && latestCandidate.flatMap {
          sprintWorkRecoveryPolicy.latestReviewRun(
            for: $0,
            runs: runs,
            reviewerProfileIDs: reviewerProfileIDs
          )
        }?.id == run.id
      let canResume = isImplementer || canResumeConflict || canResumeReview
      let recoveredStatus: AgentRunStatus = canResume ? .awaitingOwner : .interrupted
      if run.status != recoveredStatus {
        _ = try? await store.updateAgentRun(
          id: run.id,
          status: recoveredStatus,
          eventActor: "StoryPointless",
          eventDetail: canResume
            ? "Expired permission request remains paused for Product Owner input"
            : "Permission request expired when the app stopped"
        )
        let latestRequest = permissionRequests
          .filter { $0.agentRunID == run.id }
          .max(by: { $0.updatedAt < $1.updatedAt })
        if canResume,
          let latestRequest,
          let updatedRequest = try? await store.updateAgentPermissionRequest(
            id: latestRequest.id,
            status: .interrupted
          )
        {
          replacePermissionRequest(updatedRequest)
        }
        _ = try? await store.appendComment(
          workItemID: run.workItemID,
          authorKind: .system,
          authorName: "StoryPointless",
          body: canResume
            ? "The live permission request expired when StoryPointless stopped. The Conversation and workspace are preserved, and the request remains above for your decision. Work will resume only after you choose Allow or Deny."
            : "The previous permission request expired when StoryPointless stopped. This run cannot continue automatically."
        )
      }
    }
    for candidate in storedCandidates where candidate.status == .readyForDemo {
      guard
        let item = workItems.first(where: { $0.id == candidate.workItemID }),
        let implementationRun = try? await store.fetchAgentRun(
          id: candidate.implementationRunID
        ),
        let assignee = profiles.first(where: { $0.id == implementationRun.profileID })
      else { continue }
      do {
        let result = try CodexTicketExecutor.decode(candidate.executionResultJSON)
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: result,
          assignee: assignee
        )
        try await validateDeliveryEvidence(
          result,
          workspaceURL: URL(
            fileURLWithPath: candidate.worktreePath,
            isDirectory: true
          )
        )
        if item.state == .integrating {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .verifying,
            actor: "StoryPointless",
            reason: "Recovered the reviewed candidate after restart"
          )
        }
        if item.state == .integrating || item.state == .verifying {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .acceptance,
            actor: "StoryPointless",
            reason: "Recovered the completed Tech Lead review"
          )
        }
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
        let workspacePath = run.worktreePath,
        let assignee = profiles.first(where: { $0.id == run.profileID }),
        product.id == productID,
        let productWorkspace = try? Self.productWorkspaceURL(productID: productID)
      else { continue }
      let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
      guard
        let resumedThreadID = try? await client.resumeWorkspaceThread(
          threadID: threadID,
          workingDirectory: workspace,
          developerInstructions: CodexTicketExecutor.developerInstructions(
            productInstructions: inheritedAgentInstructions(
              for: product,
              availableKnowledge: context.knowledgePages
            ),
            personaInstructions: assignee.effectiveInstructions,
            assignee: assignee
          ),
          model: assignee.model,
          readOnlyGitDirectory: productWorkspace.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        ),
        let response = try? await client.latestCompletedAgentMessage(
          threadID: resumedThreadID
        )
      else { continue }
      do {
        let result = try CodexTicketExecutor.decode(response)
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: result,
          assignee: assignee
        )
        try await validateDeliveryEvidence(
          result,
          workspaceURL: workspace
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
        if let candidate = runCandidates.max(by: { $0.version < $1.version }),
          candidate.status == .reviewing,
          sprintWorkRecoveryPolicy.latestReviewRun(
            for: candidate,
            runs: runs,
            reviewerProfileIDs: reviewerProfileIDs
          )?.id == run.id
        {
          _ = try? await store.updateAgentRun(
            id: run.id,
            status: .queued,
            eventActor: "StoryPointless",
            eventDetail: "Interrupted Tech Lead review queued to continue"
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

    for candidate in storedCandidates where candidate.status == .integrating {
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
        case .running:
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "StoryPointless",
            reason: "Candidate restored to the integration queue"
          )
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .verifying,
            actor: "StoryPointless",
            reason: "The reviewed candidate is waiting to integrate"
          )
        default:
          break
        }
      }
    }

    for candidate in storedCandidates where candidate.status == .reviewing {
      guard
        let item = workItems.first(where: { $0.id == candidate.workItemID })
      else {
        continue
      }

      do {
        let repositoryURL = try Self.productWorkspaceURL(productID: productID)
        let reviewWorkspace: GitIntegrationSnapshot
        if let integratedSHA = candidate.integratedSHA {
          reviewWorkspace = try await gitWorkspaceManager.prepareIntegratedWorkspace(
            repositoryURL: repositoryURL,
            integrationsRootURL: Self.integrationWorktreesRootURL(productID: productID),
            candidateID: candidate.id,
            candidateHeadSHA: candidate.headSHA,
            integratedSHA: integratedSHA
          )
        } else {
          reviewWorkspace = try await gitWorkspaceManager.prepareCandidateReviewWorkspace(
            repositoryURL: repositoryURL,
            reviewsRootURL: Self.integrationWorktreesRootURL(productID: productID),
            candidateID: candidate.id,
            candidateHeadSHA: candidate.headSHA
          )
        }
        if candidate.integrationWorktreePath != reviewWorkspace.url.path {
          _ = try await store.updateCandidateRevision(
            id: candidate.id,
            status: .reviewing,
            integratedSHA: candidate.integratedSHA,
            integrationWorktreePath: reviewWorkspace.url.path
          )
        }

        if item.state == .running {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "StoryPointless",
            reason: "Recovered the immutable review candidate"
          )
        }
        if item.state == .running || item.state == .integrating {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .verifying,
            actor: "StoryPointless",
            reason: "Continuing Tech Lead review after restart"
          )
        }

        if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: candidate,
          runs: runs,
          reviewerProfileIDs: reviewerProfileIDs
        ) {
          if expiredPermissionRunIDs.contains(reviewRun.id) {
            _ = try? await store.updateAgentRun(
              id: reviewRun.id,
              status: .awaitingOwner,
              worktreePath: reviewWorkspace.url.path
            )
          } else if reviewRun.status != .completed {
            _ = try? await store.updateAgentRun(
              id: reviewRun.id,
              status: .queued,
              worktreePath: reviewWorkspace.url.path,
              eventActor: "StoryPointless",
              eventDetail: "Tech Lead review queued to continue against the same revision"
            )
          }
        } else if let techLead = profiles.first(where: { $0.role == .lead }) {
          _ = try? await store.createAgentRun(
            AgentRun(
              productID: productID,
              sprintID: plan.sprint.id,
              sprintItemID: candidate.sprintItemID,
              workItemID: candidate.workItemID,
              profileID: techLead.id,
              status: .queued,
              worktreePath: reviewWorkspace.url.path
            )
          )
        }
      } catch {
        if candidate.integratedSHA != nil {
          await restoreCandidateToIntegrationQueue(
            candidate,
            context: context,
            reason: "The exact integrated revision could not be restored: \(error.localizedDescription)"
          )
        } else {
          _ = try? await store.updateCandidateRevision(
            id: candidate.id,
            status: .queuedForReview
          )
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
          status: .queuedForReview
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
          if expiredPermissionRunIDs.contains(latest.id) {
            _ = try? await store.updateAgentRun(
              id: latest.id,
              status: .awaitingOwner
            )
          } else if latest.status == .interrupted || latest.status == .failed {
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

  private func restoreCandidateToIntegrationQueue(
    _ candidate: CandidateRevision,
    context: SprintExecutionContext,
    reason: String
  ) async {
    guard let store else { return }
    let productID = context.product.id
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
    let reviewerProfileIDs = Set(
      context.profiles
        .filter { $0.role == .lead }
        .map(\.id)
    )
    if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
      for: candidate,
      runs: context.runs,
      reviewerProfileIDs: reviewerProfileIDs
    ), reviewRun.status != .completed {
      _ = try? await store.updateAgentRun(
        id: reviewRun.id,
        status: .interrupted,
        eventActor: "StoryPointless",
        eventDetail: "The exact review workspace could not be recovered"
      )
    }
    if let item = try? await store.fetchWorkItems(productID: productID)
      .first(where: { $0.id == candidate.workItemID })
    {
      if item.state == .verifying {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "StoryPointless",
          reason: "The exact reviewed revision could not be recovered"
        )
      }
      if item.state == .running || item.state == .verifying {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: "StoryPointless",
          reason: "Candidate restored to the integration queue"
        )
      }
    }
    _ = try? await store.appendComment(
      workItemID: candidate.workItemID,
      authorKind: .system,
      authorName: "StoryPointless",
      body: "\(reason)\n\nCandidate v\(candidate.version) will be integrated and reviewed again so the Product Owner never receives an unverified revision."
    )
  }

  private func eligibleImplementationRuns(
    in context: SprintExecutionContext
  ) -> [AgentRun] {
    SprintRunAdmission.eligibleImplementationRuns(
      plan: context.plan,
      runs: context.runs,
      workItems: context.workItems,
      dependencies: context.dependencies
    )
  }

  @discardableResult
  private func processNextIntegrationCandidate(
    context: SprintExecutionContext
  ) async -> Bool {
    guard let store else { return false }
    let plan = context.plan
    let profiles = context.profiles
    let runs = context.runs
    let workItems = context.workItems
    let productID = plan.sprint.productID
    guard activeIntegrationTasks[productID] == nil else { return false }
    do {
      try await requeueStaleReadyCandidates(productID: productID)
      let candidates = try await store.fetchCandidateRevisions(productID: productID)
      let techLeadID = profiles.first(where: { $0.role == .lead })?.id
      let reviewerProfileIDs = Set(
        profiles
          .filter { $0.role == .lead }
          .map(\.id)
      )
      let reviewingCandidates = candidates
        .filter {
          $0.sprintID == plan.sprint.id
            && $0.status == .reviewing
            && $0.integratedSHA != nil
        }
        .sorted { $0.createdAt < $1.createdAt }
      if let reviewingCandidate = reviewingCandidates.first,
        let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: reviewingCandidate,
          runs: runs,
          reviewerProfileIDs: reviewerProfileIDs
        ),
        reviewRun.status == .queued
          || reviewRun.status == .running
          || reviewRun.status == .completed
      {
        activeIntegrationTasks[productID] = Task { [weak self] in
          guard let self else { return }
          defer {
            activeIntegrationTasks.removeValue(forKey: productID)
            sprintExecutionWakeContinuations[productID]?.yield()
          }
          await resumeTechLeadReview(
            candidate: reviewingCandidate,
            reviewRun: reviewRun,
            plan: plan
          )
        }
        return true
      }
      let resolvingCandidates = candidates.filter {
        $0.sprintID == plan.sprint.id && $0.status == .resolvingConflict
      }
      if let resolvingCandidate = resolvingCandidates.min(
        by: { $0.createdAt < $1.createdAt }
      ) {
        let resolutionRuns = runs
          .filter {
            $0.workItemID == resolvingCandidate.workItemID
              && $0.profileID == techLeadID
              && $0.worktreePath == resolvingCandidate.integrationWorktreePath
          }
        if
          let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }),
          let worktreePath = resolvingCandidate.integrationWorktreePath,
          try await gitWorkspaceManager.conflictResolutionIsReadyToCommit(
            integrationWorkspaceURL: URL(
              fileURLWithPath: worktreePath,
              isDirectory: true
            )
          )
        {
          activeIntegrationTasks[productID] = Task { [weak self] in
            guard let self else { return }
            defer {
              activeIntegrationTasks.removeValue(forKey: productID)
              sprintExecutionWakeContinuations[productID]?.yield()
            }
            await completePreservedIntegrationConflict(
              candidate: resolvingCandidate,
              resolutionRun: resolutionRun,
              plan: plan
            )
          }
          return true
        }
        if
          let resolutionRun = resolutionRuns
            .filter({ $0.status == .queued })
            .max(by: { $0.createdAt < $1.createdAt })
        {
          activeIntegrationTasks[productID] = Task { [weak self] in
            guard let self else { return }
            defer {
              activeIntegrationTasks.removeValue(forKey: productID)
              sprintExecutionWakeContinuations[productID]?.yield()
            }
            await resumeIntegrationConflictResolution(
              candidate: resolvingCandidate,
              resolutionRun: resolutionRun,
              plan: plan
            )
          }
          return true
        }
      }
      let integrationIsOccupied = SprintCandidateAdmission.integrationQueueIsOccupied(
        candidates: candidates,
        sprintID: plan.sprint.id
      )
      guard !integrationIsOccupied else { return false }

      guard
        let candidate = SprintCandidateAdmission.nextIntegrationCandidate(
          candidates: candidates,
          sprintID: plan.sprint.id,
          workItems: workItems
        )
      else { return false }
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating
      )
      await reloadSelectedProductIfCurrent(productID: context.product.id)
      activeIntegrationTasks[productID] = Task { [weak self] in
        guard let self else { return }
        defer {
          activeIntegrationTasks.removeValue(forKey: productID)
          sprintExecutionWakeContinuations[productID]?.yield()
        }
        await integrateReviewedCandidate(candidate, plan: plan)
      }
      return true
    } catch {
      presentExecutionError(error, productID: context.product.id)
      return false
    }
  }

  private func requeueStaleReadyCandidates(
    productID: UUID,
    excluding excludedCandidateID: UUID? = nil
  ) async throws {
    guard let store else { return }
    let repositoryURL = try Self.productWorkspaceURL(productID: productID)
    let candidates = try await store.fetchCandidateRevisions(productID: productID)
    for candidate in candidates
    where
      candidate.id != excludedCandidateID
        && candidate.status == .readyForDemo
    {
      guard
        let integratedSHA = candidate.integratedSHA,
        !(try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
          repositoryURL: repositoryURL,
          integratedSHA: integratedSHA
        ))
      else { continue }
      try await requeueStaleReadyCandidate(
        candidate,
        reason:
          "Accepted trunk advanced after this demo revision was prepared."
      )
    }
  }

  private func requeueStaleReadyCandidate(
    _ candidate: CandidateRevision,
    reason: String
  ) async throws {
    guard let store else { return }
    await stopDemoSession(candidate, removesPreview: true)
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .queuedForIntegration
    )
    if
      let item = try await store.fetchWorkItems(productID: candidate.productID)
        .first(where: { $0.id == candidate.workItemID })
    {
      if item.state == .acceptance {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "StoryPointless",
          reason: "The accepted trunk changed after demo preparation"
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: "StoryPointless",
          reason: "The reviewed candidate is queued to integrate again"
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: "StoryPointless",
          reason: "The reviewed candidate is waiting to integrate"
        )
      } else if item.state == .integrating {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: "StoryPointless",
          reason: "The reviewed candidate is waiting to integrate"
        )
      }
    }
    _ = try await store.appendComment(
      workItemID: candidate.workItemID,
      authorKind: .system,
      authorName: "StoryPointless",
      body:
        "\(reason)\n\nCandidate v\(candidate.version) kept its Tech Lead approval and returned to the integration queue. A clean merge will only repeat demo preparation; a conflict will receive focused Tech Lead re-review."
    )
  }

  private func executeImplementationRun(
    _ queuedRun: AgentRun,
    context: SprintExecutionContext
  ) async {
    guard
      let store,
      let client = codexClient,
      let item = context.workItems.first(where: { $0.id == queuedRun.workItemID }),
      let assignee = context.profiles.first(where: { $0.id == queuedRun.profileID })
    else { return }
    let product = context.product
    let plan = context.plan
    let workItems = context.workItems
    let dependencies = context.dependencies
    let knowledgePages = context.knowledgePages
    let permissionRequests = context.permissionRequests

    var run = queuedRun
    do {
      let productWorkspace = try Self.productWorkspaceURL(productID: product.id)
      var recoveredExistingWorkspace = false
      let workspace: URL
      if
        let storedPath = run.worktreePath,
        storedPath != productWorkspace.path,
        FileManager.default.fileExists(atPath: storedPath)
      {
        workspace = URL(fileURLWithPath: storedPath, isDirectory: true)
        recoveredExistingWorkspace = true
      } else {
        if run.codexThreadID != nil || run.worktreePath != nil {
          run = try await store.resetAgentRunExecutionContext(id: run.id)
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The previous ticket workspace was unavailable. StoryPointless prepared a fresh isolated \(item.key) workspace, so work that was not captured in a durable candidate could not be recovered."
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
      let isContinuation =
        recoveredExistingWorkspace
          && (item.state == .running || run.codexThreadID != nil || run.worktreePath != nil)
      try await gitWorkspaceManager.configureAgentIdentity(
        at: workspace,
        authorName: assignee.name
      )
      let currentCandidates = try await store.fetchCandidateRevisions(
        productID: product.id
      )
      let latestCandidate = currentCandidates
        .filter { $0.workItemID == item.id }
        .max(by: { $0.version < $1.version })
      let adoptedBaseline: TicketRevisionBaseline? =
        if
          let latestCandidate,
          let integratedSHA = latestCandidate.integratedSHA,
          (try? await gitWorkspaceManager.currentSHA(at: workspace)) == integratedSHA
        {
          TicketRevisionBaseline(
            candidateHeadSHA: latestCandidate.headSHA,
            integratedSHA: integratedSHA
          )
        } else {
          nil
        }

      if item.state == .queued {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: assignee.name,
          reason: "Picked up the authorised ticket"
        )
      }

      let developerInstructions = CodexTicketExecutor.developerInstructions(
        productInstructions: inheritedAgentInstructions(
          for: product,
          availableKnowledge: knowledgePages,
          includesMandatoryKnowledge: false
        ),
        personaInstructions: assignee.effectiveInstructions,
        assignee: assignee
      )
      let existingThreadID = run.codexThreadID
      var replacedUnavailableThread = false
      let threadID: String
      if let existingThreadID {
        do {
          threadID = try await client.resumeWorkspaceThread(
            threadID: existingThreadID,
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: assignee.model,
            readOnlyGitDirectory: productWorkspace.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          threadID = try await client.startWorkspaceThread(
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: assignee.model,
            readOnlyGitDirectory: productWorkspace.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
          replacedUnavailableThread = true
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The previous Conversation could not be recovered. I started a replacement in the preserved ticket workspace and continued the work."
          )
        }
      } else {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: assignee.model,
          readOnlyGitDirectory: productWorkspace.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        )
      }
      run = try await store.updateAgentRun(
        id: run.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path,
        eventActor: replacedUnavailableThread ? "StoryPointless" : nil,
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable Conversation and preserved the ticket workspace"
          : nil
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let currentItem = workItems.first(where: { $0.id == item.id }) ?? item
      let prerequisiteIDs = Set(
        dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
      )
      let prerequisites = workItems.filter { prerequisiteIDs.contains($0.id) }
      let dependantIDs = Set(
        dependencies.filter { $0.dependsOnWorkItemID == item.id }.map(\.workItemID)
      )
      let dependants = workItems.filter {
        dependantIDs.contains($0.id) && $0.state != .cancelled
      }
      var prerequisiteComments: [UUID: [TicketComment]] = [:]
      for prerequisite in prerequisites {
        prerequisiteComments[prerequisite.id] = try await store.fetchComments(
          workItemID: prerequisite.id
        )
      }
      let comments = try await store.fetchComments(workItemID: item.id)
      let knowledgeSelection = KnowledgeContextSelector.select(
        pages: knowledgePages,
        item: currentItem,
        prerequisites: prerequisites
      )
      let knowledgeContext = knowledgeSelection.referencePages
      try await recordKnowledgeContext(
        runID: run.id,
        productID: product.id,
        pages: knowledgeContext
      )
      try await store.setAgentRunKnowledgeDestinations(
        runID: run.id,
        pageIDs: Array(knowledgeSelection.writablePageIDs)
      )
      agentRunKnowledgeDestinations.removeAll { $0.runID == run.id }
      agentRunKnowledgeDestinations.append(
        contentsOf: knowledgeSelection.writablePageIDs.map {
          AgentRunKnowledgeDestination(runID: run.id, pageID: $0)
        }
      )
      let interruptedPermission = sprintWorkRecoveryPolicy.latestPermissionContinuation(
        for: run.id,
        permissionRequests: permissionRequests
      )
      let continuationPrompt = CodexTicketExecutor.recoveryPrompt(
        item: currentItem,
        interruptedPermission: interruptedPermission,
        recentComments: comments,
        adoptedBaseline: adoptedBaseline
      )
      let replacementContinuationPrompt = CodexTicketExecutor.recoveryPrompt(
        item: currentItem,
        interruptedPermission: interruptedPermission,
        recentComments: [],
        conversationIsAvailable: false,
        adoptedBaseline: adoptedBaseline
      )
      let executionPrompt = CodexTicketExecutor.prompt(
        product: product,
        item: currentItem,
        assignee: assignee,
        prerequisites: prerequisites,
        dependants: dependants,
        prerequisiteComments: prerequisiteComments,
        ticketComments: comments,
        knowledgeContext: knowledgeContext,
        knowledgeDirectory: knowledgeSelection.directoryPages,
        knowledgeDestinationIDs: knowledgeSelection.writablePageIDs,
        existingItems: workItems,
        continuationMessage: isContinuation
          ? replacementContinuationPrompt
          : nil
      )
      var activeThreadID = threadID
      var turnPrompt =
        existingThreadID != nil && !replacedUnavailableThread
          ? continuationPrompt
          : executionPrompt
      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: turnPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [workspace]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        activeThreadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: assignee.model,
          readOnlyGitDirectory: productWorkspace.appendingPathComponent(
            ".git",
            isDirectory: true
          )
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
        turnPrompt = executionPrompt
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: turnPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [workspace]
        )
      }
      activeExecutionTurns[run.id] = ActiveExecutionTurn(
        productID: product.id,
        threadID: activeThreadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: run.id,
        productID: product.id,
        client: client,
        threadID: activeThreadID,
        turnID: turnID,
        initialText: isContinuation
          ? "Continuing work in the ticket workspace…"
          : "Getting oriented in the ticket workspace…"
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
        productID: product.id,
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
      let currentPermissionRequests =
        (try? await store.fetchAgentPermissionRequests(productID: product.id))
        ?? permissionRequests
      let wasAwaitingPermission =
        currentPermissionRequests
        .filter { $0.agentRunID == run.id }
        .max(by: { $0.updatedAt < $1.updatedAt })?
        .status.needsOwnerDecision == true
      let status = sprintWorkRecoveryPolicy.implementationRunStatusAfterTurnStops(
        taskWasCancelled: Task.isCancelled,
        wasManuallyStopped: wasManuallyStopped,
        wasAwaitingPermission: wasAwaitingPermission
      )
      let wasSuspendedByApp = Task.isCancelled && !wasManuallyStopped
      let wasSuspendedAtPermission = wasSuspendedByApp && wasAwaitingPermission
      let eventDetail: String
      let workLogBody: String
      if wasSuspendedAtPermission {
        eventDetail = "App stopped; permission request remains paused for Product Owner input"
        workLogBody =
          "StoryPointless stopped while this run was waiting for a permission decision. Its Conversation and ticket workspace are preserved, and work will remain paused after relaunch until the Product Owner chooses Allow or Deny."
      } else if wasSuspendedByApp {
        eventDetail = "App stopped; preserved work queued to continue"
        workLogBody =
          "StoryPointless paused this run while stopping. Its Conversation and ticket workspace are preserved, and it is queued to continue automatically."
      } else if wasManuallyStopped {
        eventDetail = "Stopped manually; ticket workspace preserved"
        workLogBody =
          "This run was stopped by the Product Owner. Its ticket workspace has been preserved and can be resumed with a new comment."
      } else {
        eventDetail = error.localizedDescription
        workLogBody = "The agent run stopped unexpectedly: \(error.localizedDescription)"
      }
      _ = try? await store.updateAgentRun(
        id: run.id,
        status: status,
        eventActor: "StoryPointless",
        eventDetail: eventDetail
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: workLogBody
      )
      if !Task.isCancelled && !wasManuallyStopped {
        presentExecutionError(error, productID: product.id)
      }
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }

  private func validatedExecutionResult(
    _ response: String,
    client: CodexAppServerClient,
    threadID: String,
    runID: UUID,
    productID: UUID,
    assignee: AgentProfile,
    workspaceURL: URL
  ) async throws -> TicketExecutionResult {
    do {
      let result = try CodexTicketExecutor.decode(response)
      try CodexTicketExecutor.validateFollowUpTicketProposals(
        in: result,
        assignee: assignee
      )
      try await validateDeliveryEvidence(result, workspaceURL: workspaceURL)
      return result
    } catch let validationError as TicketExecutionGenerationError {
      let repairTurnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketExecutor.repairPrompt(
          validationError: validationError.localizedDescription
        ),
        effort: assignee.reasoningEffort,
        outputSchema: CodexTicketExecutor.outputSchema,
        runtimeWorkspaceRoots: [workspaceURL]
      )
      activeExecutionTurns[runID] = ActiveExecutionTurn(
        productID: productID,
        threadID: threadID,
        turnID: repairTurnID
      )
      monitorLiveActivity(
        runID: runID,
        productID: productID,
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
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: repairedResult,
          assignee: assignee
        )
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
    guard let demo = result.demo else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Completed work needs a managed demo recipe for the Product Owner."
      )
    }
    do {
      try DemoLaunchSpecificationValidator.validate(demo)
      let commands = demo.preparationCommands + [demo.launchCommand].compactMap { $0 }
      for command in commands {
        let directory = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
          command.workingDirectory,
          in: workspaceURL
        )
        var isDirectory: ObjCBool = false
        guard
          FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else {
          throw DemoLaunchValidationError.invalid(
            "the working directory “\(command.workingDirectory)” does not exist."
          )
        }
      }
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
    }
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
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let run = try? await store.fetchAgentRun(id: implementationRunID),
      let item = context.workItems.first(where: { $0.id == run.workItemID }),
      let assignee = context.profiles.first(where: { $0.id == run.profileID })
    else { return }
    let productID = context.product.id

    _ = try? await store.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: assignee.name,
      body: result.workLogComment,
      ownerQuestion:
        result.status == .awaitingOwner
        ? result.question.map {
          TicketOwnerQuestion(prompt: $0, options: result.options)
        }
        : nil
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
      await reloadSelectedProductIfCurrent(productID: productID)
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
        let proposals = try await makeKnowledgePageProposals(
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
            reason: "Candidate v\(candidate.version) queued for Tech Lead review"
          )
        }
        _ = try await store.updateAgentRun(
          id: run.id,
          status: .completed,
          eventActor: assignee.name,
          eventDetail: "Candidate v\(candidate.version) queued for Tech Lead review"
        )
        await reloadSelectedProductIfCurrent(productID: productID)
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
        presentExecutionError(error, productID: productID)
        await reloadSelectedProductIfCurrent(productID: productID)
      }
    }
  }

  private func resumeTechLeadReview(
    candidate: CandidateRevision,
    reviewRun: AgentRun,
    plan: SprintPlan
  ) async {
    guard
      let store,
      let client = codexClient,
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      ),
      let implementer = context.profiles.first(
        where: { $0.id == implementationRun.profileID }
      ),
      let techLead = context.profiles.first(where: { $0.id == reviewRun.profileID })
    else {
      return
    }
    let product = context.product
    let permissionRequests = context.permissionRequests

    let reviewCycle = max(0, candidate.version - 1)
    do {
      try await recordKnowledgeContext(
        runID: reviewRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      let repositoryURL = try Self.productWorkspaceURL(productID: product.id)
      let integration: GitIntegrationSnapshot?
      let reviewWorkspace: GitIntegrationSnapshot
      if let integratedSHA = candidate.integratedSHA {
        let prepared = try await gitWorkspaceManager.prepareIntegratedWorkspace(
          repositoryURL: repositoryURL,
          integrationsRootURL: Self.integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: integratedSHA
        )
        integration = prepared
        reviewWorkspace = prepared
      } else {
        integration = nil
        reviewWorkspace = try await gitWorkspaceManager.prepareCandidateReviewWorkspace(
          repositoryURL: repositoryURL,
          reviewsRootURL: Self.integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA
        )
      }
      let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      let developerInstructions = CodexTechLeadReviewer.developerInstructions(
        productInstructions: inheritedAgentInstructions(
          for: product,
          availableKnowledge: context.knowledgePages
        ),
        personaInstructions: techLead.effectiveInstructions,
        reviewer: techLead
      )
      var resumedReviewThreadID: String?
      var replacedUnavailableThread = false
      if let existingThreadID = reviewRun.codexThreadID {
        do {
          let resumedThreadID = try await client.resumeReadOnlyThread(
            threadID: existingThreadID,
            workingDirectory: reviewWorkspace.url,
            developerInstructions: developerInstructions,
            model: techLead.model,
            allowsApprovals: true
          )
          resumedReviewThreadID = resumedThreadID
          if
            let recoveredResponse = try? await client.latestCompletedAgentMessage(
              threadID: resumedThreadID,
              notBefore: reviewRun.createdAt.addingTimeInterval(-30)
            ),
            let recoveredReview = try? CodexTechLeadReviewer.decode(recoveredResponse)
          {
            try await applyTechLeadReviewResult(
              recoveredReview,
              implementation: implementation,
              candidate: candidate,
              implementationRun: implementationRun,
              reviewRun: reviewRun,
              reviewCycle: reviewCycle,
              plan: plan,
              reviewWorkspace: reviewWorkspace,
              integration: integration
            )
            return
          }
        } catch let error as CodexRPCError where error.isThreadNotFound {
          replacedUnavailableThread = true
        }
      }

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
      let fullReviewPrompt = CodexTechLeadReviewer.prompt(
        product: product,
        item: item,
        implementation: implementation,
        assignee: implementer,
        reviewCycle: reviewCycle,
        priorReviewFeedback: priorReviewFeedback,
        recentComments: reviewComments,
        baseSHA: candidate.baseSHA,
        candidateHeadSHA: candidate.headSHA,
        integratedSHA: integration?.integratedSHA
      )
      let interruptedPermission = sprintWorkRecoveryPolicy.latestPermissionContinuation(
        for: reviewRun.id,
        permissionRequests: permissionRequests
      )

      var threadID: String
      var turnPrompt: String
      if let resumedReviewThreadID {
        threadID = resumedReviewThreadID
        turnPrompt = CodexTechLeadReviewer.recoveryPrompt(
          item: item,
          reviewedSHA: reviewWorkspace.integratedSHA,
          isIntegratedRevision: integration != nil,
          interruptedPermission: interruptedPermission
        )
      } else {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: reviewWorkspace.url,
          developerInstructions: developerInstructions,
          model: techLead.model,
          allowsApprovals: true
        )
        turnPrompt = fullReviewPrompt
        if replacedUnavailableThread {
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The previous Tech Lead Conversation was unavailable. I started a replacement against the same immutable revision; implementation was not repeated."
          )
        }
      }

      _ = try await store.updateAgentRun(
        id: reviewRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: reviewWorkspace.url.path,
        eventActor: "StoryPointless",
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable review Conversation"
          : "Continuing Tech Lead review against the same immutable revision"
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: turnPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [reviewWorkspace.url]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: reviewWorkspace.url,
          developerInstructions: developerInstructions,
          model: techLead.model,
          allowsApprovals: true
        )
        turnPrompt = fullReviewPrompt
        _ = try await store.updateAgentRun(
          id: reviewRun.id,
          status: .running,
          codexThreadID: threadID,
          worktreePath: reviewWorkspace.url.path,
          eventActor: "StoryPointless",
          eventDetail: "Replaced an unavailable review Conversation"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "StoryPointless",
          body: "The previous Tech Lead Conversation was unavailable. I started a replacement against the same immutable revision; implementation was not repeated."
        )
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: turnPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [reviewWorkspace.url]
        )
      }

      activeExecutionTurns[reviewRun.id] = ActiveExecutionTurn(
        productID: product.id,
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: reviewRun.id,
        productID: product.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Continuing the Tech Lead review…"
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
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [reviewWorkspace.url]
        )
        activeExecutionTurns[reviewRun.id] = ActiveExecutionTurn(
          productID: product.id,
          threadID: threadID,
          turnID: repairTurnID
        )
        monitorLiveActivity(
          runID: reviewRun.id,
          productID: product.id,
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

      try await applyTechLeadReviewResult(
        review,
        implementation: implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewRun: reviewRun,
        reviewCycle: reviewCycle,
        plan: plan,
        reviewWorkspace: reviewWorkspace,
        integration: integration
      )
    } catch {
      stopLiveActivityMonitoring(runID: reviewRun.id)
      activeExecutionTurns.removeValue(forKey: reviewRun.id)
      if Task.isCancelled {
        _ = try? await store.updateAgentRun(
          id: reviewRun.id,
          status: .interrupted,
          eventActor: "StoryPointless",
          eventDetail: "Tech Lead review paused when the app stopped"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }

      _ = try? await store.updateAgentRun(
        id: reviewRun.id,
        status: .failed,
        eventActor: "StoryPointless",
        eventDetail: error.localizedDescription
      )
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .failed
      )
      try? await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .superseded
      )
      if let integrationPath = candidate.integrationWorktreePath {
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
          reason: "Review continuation stopped; preserving work for retry"
        )
      }
      _ = try? await store.updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "StoryPointless",
        eventDetail: "Tech Lead review continuation could not complete"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "Tech Lead review continuation stopped unexpectedly: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved implementation workspace."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }

  private func executeCandidateReview(
    _ candidate: CandidateRevision,
    context: SprintExecutionContext
  ) async {
    guard let store else { return }
    do {
      let implementation = try CodexTicketExecutor.decode(
        candidate.executionResultJSON
      )
      let implementationRun = try await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
      await reviewCompletedImplementation(
        implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: context.plan
      )
    } catch {
      presentExecutionError(error, productID: context.product.id)
    }
  }

  private func integrateReviewedCandidate(
    _ candidate: CandidateRevision,
    plan: SprintPlan
  ) async {
    guard
      let store,
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
    else { return }
    let product = context.product
    do {
      let repositoryURL = try Self.productWorkspaceURL(productID: product.id)
      let integration: GitIntegrationSnapshot
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
          reviewCycle: max(0, candidate.version - 1),
          plan: plan,
          worktreePath: worktreePath,
          conflictedFiles: conflictedFiles
        )
        return
      }

      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating,
        integratedSHA: integration.integratedSHA,
        integrationWorktreePath: integration.url.path
      )
      let implementation = try CodexTicketExecutor.decode(
        candidate.executionResultJSON
      )
      try await finalizeReviewedIntegration(
        candidateID: candidate.id,
        implementation: implementation,
        implementationRun: implementationRun,
        workItem: item,
        reviewerName: context.profiles.first(where: { $0.role == .lead })?.name
          ?? "Tech Lead"
      )
    } catch {
      if Task.isCancelled {
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .failed
      )
      _ = try? await store.updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "StoryPointless",
        eventDetail: "Reviewed candidate integration could not complete"
      )
      if
        let currentState = try? await store.fetchWorkItems(productID: product.id)
          .first(where: { $0.id == item.id })?.state,
        currentState == .integrating || currentState == .verifying
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "StoryPointless",
          reason: "Integration stopped; preserving the reviewed candidate"
        )
      }
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "StoryPointless",
        body: "The reviewed candidate could not be integrated or prepared for demo: \(error.localizedDescription)\n\nThe reviewed revision and ticket workspace are preserved for retry."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }

  private func finalizeReviewedIntegration(
    candidateID: UUID,
    implementation: TicketExecutionResult,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let store else { return }
    if !requiresKnowledgeApproval {
      _ = try await publishReviewedKnowledgePageProposals(
        candidate: try await store.fetchCandidateRevision(id: candidateID),
        workItem: workItem,
        authorName: "StoryPointless"
      )
    }
    let integratedCandidate = try await store.fetchCandidateRevision(id: candidateID)
    guard
      let integratedSHA = integratedCandidate.integratedSHA,
      let demo = implementation.demo
    else {
      throw DemoLaunchValidationError.invalid(
        "the reviewed candidate has no managed demo recipe."
      )
    }
    try await prepareDemoForAcceptance(
      candidate: integratedCandidate,
      integratedSHA: integratedSHA,
      specification: demo
    )
    _ = try await store.updateCandidateRevision(
      id: candidateID,
      status: .readyForDemo
    )
    _ = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .completed,
      eventActor: reviewerName,
      eventDetail: "Reviewed candidate integrated and prepared for demo"
    )
    if let currentState = try await store.fetchWorkItems(productID: workItem.productID)
      .first(where: { $0.id == workItem.id })?.state
    {
      if currentState == .integrating {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .verifying,
          actor: reviewerName,
          reason: "Recovered the reviewed candidate"
        )
      }
      if currentState == .integrating || currentState == .verifying {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .acceptance,
          actor: reviewerName,
          reason: "Reviewed candidate integrated; ready for Product Owner demo"
        )
      }
    }
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
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
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(
        where: { $0.id == implementationRun.workItemID }
      ),
      let implementer = context.profiles.first(
        where: { $0.id == implementationRun.profileID }
      ),
      let techLead = context.profiles.first(where: { $0.role == .lead })
    else { return }
    let product = context.product

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
      let reviewWorkspace: GitIntegrationSnapshot
      if let preparedIntegration {
        reviewWorkspace = preparedIntegration
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .reviewing,
          integratedSHA: preparedIntegration.integratedSHA,
          integrationWorktreePath: preparedIntegration.url.path
        )
      } else {
        reviewWorkspace = try await gitWorkspaceManager.prepareCandidateReviewWorkspace(
          repositoryURL: repositoryURL,
          reviewsRootURL: Self.integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA
        )
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .reviewing,
          integrationWorktreePath: reviewWorkspace.url.path
        )
      }
      if currentState == .integrating {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: techLead.name,
          reason: "Independent Tech Lead review started"
        )
      }

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
      try await recordKnowledgeContext(
        runID: reviewRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let workspace = reviewWorkspace.url
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexTechLeadReviewer.developerInstructions(
          productInstructions: inheritedAgentInstructions(
            for: product,
            availableKnowledge: context.knowledgePages
          ),
          personaInstructions: techLead.effectiveInstructions,
          reviewer: techLead
        ),
        model: techLead.model,
        allowsApprovals: true
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
          integratedSHA: preparedIntegration?.integratedSHA
        ),
        effort: techLead.reasoningEffort,
        outputSchema: CodexTechLeadReviewer.outputSchema,
        runtimeWorkspaceRoots: [workspace]
      )
      activeExecutionTurns[reviewRun.id] = ActiveExecutionTurn(
        productID: product.id,
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: reviewRun.id,
        productID: product.id,
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
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [workspace]
        )
        activeExecutionTurns[reviewRun.id] = ActiveExecutionTurn(
          productID: product.id,
          threadID: threadID,
          turnID: repairTurnID
        )
        monitorLiveActivity(
          runID: reviewRun.id,
          productID: product.id,
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
      activeReviewRunID = nil
      failureStage = "Post-review handoff"
      try await applyTechLeadReviewResult(
        review,
        implementation: implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewRun: reviewRun,
        reviewCycle: reviewCycle,
        plan: plan,
        reviewWorkspace: reviewWorkspace,
        integration: preparedIntegration
      )
    } catch {
      if Task.isCancelled {
        if let activeReviewRunID {
          stopLiveActivityMonitoring(runID: activeReviewRunID)
          activeExecutionTurns.removeValue(forKey: activeReviewRunID)
          _ = try? await store.updateAgentRun(
            id: activeReviewRunID,
            status: .interrupted,
            eventActor: "StoryPointless",
            eventDetail: "Tech Lead review paused when the app stopped"
          )
        }
        stopLiveActivityMonitoring(runID: implementationRun.id)
        activeExecutionTurns.removeValue(forKey: implementationRun.id)
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      await stopDemoSession(candidate, removesPreview: true)
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
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }

  private func applyTechLeadReviewResult(
    _ review: TechLeadReviewResult,
    implementation: TicketExecutionResult,
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    reviewWorkspace: GitIntegrationSnapshot,
    integration: GitIntegrationSnapshot?
  ) async throws {
    guard
      let store,
      let client = codexClient,
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(
        where: { $0.id == implementationRun.workItemID }
      ),
      let implementer = context.profiles.first(
        where: { $0.id == implementationRun.profileID }
      ),
      let techLead = context.profiles.first(where: { $0.id == reviewRun.profileID })
    else {
      throw CodexClientError.notConnected
    }
    let product = context.product

    let existingComments = try await store.fetchComments(workItemID: item.id)
    if !existingComments.contains(where: {
      $0.authorKind == .agent
        && $0.authorName == techLead.name
        && $0.body == review.workLogComment
        && $0.createdAt >= reviewRun.createdAt
    }) {
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: techLead.name,
        body: review.workLogComment
      )
    }
    let reviewWasAlreadyCompleted = reviewRun.status == .completed
    _ = try await store.updateAgentRun(id: reviewRun.id, status: .completed)
    if !reviewWasAlreadyCompleted {
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
    }

    let repositoryURL = try Self.productWorkspaceURL(productID: product.id)
    switch review.decision {
    case .approved:
      try await store.verifyDeliveryNote(workItemID: item.id, authorName: techLead.name)
      try await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .reviewed
      )
      guard integration != nil else {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: reviewWorkspace.url
        )
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .queuedForIntegration
        )
        _ = try await store.updateAgentRun(
          id: implementationRun.id,
          status: .completed,
          eventActor: techLead.name,
          eventDetail: "Tech Lead review passed; candidate queued for integration"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      try await finalizeReviewedIntegration(
        candidateID: candidate.id,
        implementation: implementation,
        implementationRun: implementationRun,
        workItem: item,
        reviewerName: techLead.name
      )
    case .changesRequested:
      let adoptedBaseline: TicketRevisionBaseline?
      if let integration {
        adoptedBaseline = try await adoptIntegratedBaselineForRevision(
          candidate: candidate,
          integratedSHA: integration.integratedSHA
        )
      } else {
        adoptedBaseline = nil
      }
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
        worktreeURL: reviewWorkspace.url
      )
      if let currentState = try await store.fetchWorkItems(productID: item.productID)
        .first(where: { $0.id == item.id })?.state,
        currentState == .verifying || currentState == .integrating
      {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: techLead.name,
          reason: "Review changes requested"
        )
      }
      let changeRequestNumber = SprintReviewCorrectionPolicy.changeRequestNumber(
        reviewCycle: reviewCycle
      )
      guard SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(
        reviewCycle: reviewCycle
      ) else {
        let remainingFindings = review.findings.prefix(3)
          .map { "- \($0)" }
          .joined(separator: "\n")
        _ = try await store.updateAgentRun(
          id: implementationRun.id,
          status: .awaitingOwner,
          eventActor: techLead.name,
          eventDetail:
            "\(review.findings.count) material review finding\(review.findings.count == 1 ? "" : "s") remain after \(changeRequestNumber) review returns"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: techLead.name,
          body: """
            I paused automatic revisions after \(changeRequestNumber) review returns because these findings remain:

            \(remainingFindings.isEmpty ? "- The review did not provide a concrete finding." : remainingFindings)

            Ask the assigned specialist a question without restarting work, or add Product Owner direction and choose Resume work.
            """
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      _ = try await store.updateAgentRun(
        id: implementationRun.id,
        status: .running,
        eventActor: implementer.name,
        eventDetail: "Resuming after \(techLead.name) requested changes"
      )
      await reloadSelectedProductIfCurrent(productID: product.id)
      let comments = try await store.fetchComments(workItemID: item.id)
      let revisionWorkspace = URL(
        fileURLWithPath: candidate.worktreePath,
        isDirectory: true
      )
      let developerInstructions = CodexTicketExecutor.developerInstructions(
        productInstructions: inheritedAgentInstructions(
          for: product,
          availableKnowledge: context.knowledgePages
        ),
        personaInstructions: implementer.effectiveInstructions,
        assignee: implementer
      )
      let revisionPrompt = CodexTicketExecutor.revisionPrompt(
        item: item,
        reviewer: techLead,
        feedback: review.workLogComment,
        recentComments: comments,
        adoptedBaseline: adoptedBaseline
      )
      var revisionThreadID: String
      if let existingThreadID = implementationRun.codexThreadID {
        do {
          revisionThreadID = try await client.resumeWorkspaceThread(
            threadID: existingThreadID,
            workingDirectory: revisionWorkspace,
            developerInstructions: developerInstructions,
            model: implementer.model,
            readOnlyGitDirectory: repositoryURL.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          revisionThreadID = try await client.startWorkspaceThread(
            workingDirectory: revisionWorkspace,
            developerInstructions: developerInstructions,
            model: implementer.model,
            readOnlyGitDirectory: repositoryURL.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The delivery agent’s previous Conversation was unavailable. I started a replacement in the preserved ticket workspace and passed it the Tech Lead’s feedback."
          )
        }
      } else {
        revisionThreadID = try await client.startWorkspaceThread(
          workingDirectory: revisionWorkspace,
          developerInstructions: developerInstructions,
          model: implementer.model,
          readOnlyGitDirectory: repositoryURL.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        )
      }
      _ = try await store.updateAgentRun(
        id: implementationRun.id,
        status: .running,
        codexThreadID: revisionThreadID,
        worktreePath: revisionWorkspace.path
      )

      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: revisionThreadID,
          prompt: revisionPrompt,
          effort: implementer.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [revisionWorkspace]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        revisionThreadID = try await client.startWorkspaceThread(
          workingDirectory: revisionWorkspace,
          developerInstructions: developerInstructions,
          model: implementer.model,
          readOnlyGitDirectory: repositoryURL.appendingPathComponent(
            ".git",
            isDirectory: true
          )
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
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [revisionWorkspace]
        )
      }
      activeExecutionTurns[implementationRun.id] = ActiveExecutionTurn(
        productID: product.id,
        threadID: revisionThreadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: implementationRun.id,
        productID: product.id,
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
        productID: product.id,
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
  }

  private func adoptIntegratedBaselineForRevision(
    candidate: CandidateRevision,
    integratedSHA: String
  ) async throws -> TicketRevisionBaseline {
    let workspace = URL(
      fileURLWithPath: candidate.worktreePath,
      isDirectory: true
    )
    try await gitWorkspaceManager.adoptIntegratedRevision(
      ticketWorkspaceURL: workspace,
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integratedSHA
    )
    return TicketRevisionBaseline(
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integratedSHA
    )
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
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let techLead = context.profiles.first(where: { $0.role == .lead })
    else { return }
    let product = context.product

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
      try await recordKnowledgeContext(
        runID: resolutionRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Integrator",
        body: "The candidate overlaps newer accepted work in \(conflictedFiles.count) file(s). I’m resolving the integration before Tech Lead review."
      )
      await reloadSelectedProductIfCurrent(productID: product.id)
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
      await reloadSelectedProductIfCurrent(productID: plan.sprint.productID)
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
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let techLead = context.profiles.first(where: { $0.role == .lead }),
      let worktreePath = candidate.integrationWorktreePath
        ?? resolutionRun.worktreePath
    else { return }
    let product = context.product

    do {
      try await recordKnowledgeContext(
        runID: resolutionRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      let workspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
      let productGitDirectory = try Self.productWorkspaceURL(
        productID: product.id
      ).appendingPathComponent(".git", isDirectory: true)
      let developerInstructions = CodexConflictIntegrator.developerInstructions(
        productInstructions: inheritedAgentInstructions(
          for: product,
          availableKnowledge: context.knowledgePages
        )
      )
      var replacedUnavailableThread = false
      var threadID: String
      if let existingThreadID = resolutionRun.codexThreadID {
        do {
          threadID = try await client.resumeWorkspaceThread(
            threadID: existingThreadID,
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: techLead.model,
            readOnlyGitDirectory: productGitDirectory
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          threadID = try await client.startWorkspaceThread(
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: techLead.model,
            readOnlyGitDirectory: productGitDirectory
          )
          replacedUnavailableThread = true
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "StoryPointless",
            body: "The Integrator’s previous Conversation was unavailable. I started a replacement in the preserved conflict workspace."
          )
        }
      } else {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model,
          readOnlyGitDirectory: productGitDirectory
        )
      }
      _ = try await store.updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path,
        eventActor: replacedUnavailableThread ? "StoryPointless" : nil,
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable Integrator Conversation"
          : nil
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
          effort: "medium",
          outputSchema: CodexConflictIntegrator.outputSchema,
          runtimeWorkspaceRoots: [workspace]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model,
          readOnlyGitDirectory: productGitDirectory
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
          effort: "medium",
          outputSchema: CodexConflictIntegrator.outputSchema,
          runtimeWorkspaceRoots: [workspace]
        )
      }
      activeExecutionTurns[resolutionRun.id] = ActiveExecutionTurn(
        productID: product.id,
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: resolutionRun.id,
        productID: product.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Resolving the integration conflict…"
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
        body: result.workLogComment,
        ownerQuestion:
          result.status == .awaitingOwner
          ? result.question.map {
            TicketOwnerQuestion(prompt: $0, options: result.options)
          }
          : nil
      )

      switch result.status {
      case .awaitingOwner:
        _ = try await store.updateAgentRun(
          id: resolutionRun.id,
          status: .awaitingOwner,
          eventActor: "Integrator",
          eventDetail: "Waiting for Product Owner input"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
      case .resolved:
        try await completeResolvedIntegrationConflict(
          candidate: candidate,
          resolutionRun: resolutionRun,
          implementationRun: implementationRun,
          reviewCycle: reviewCycle,
          plan: plan,
          workspace: workspace
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

  private func completePreservedIntegrationConflict(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    plan: SprintPlan
  ) async {
    guard
      let store,
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      ),
      let worktreePath = candidate.integrationWorktreePath
    else { return }
    do {
      try await completeResolvedIntegrationConflict(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        workspace: URL(fileURLWithPath: worktreePath, isDirectory: true)
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

  private func completeResolvedIntegrationConflict(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    workspace: URL
  ) async throws {
    guard let store else { return }
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
    await reloadSelectedProductIfCurrent(productID: candidate.productID)
    await reviewCompletedImplementation(
      implementation,
      candidate: candidate,
      implementationRun: implementationRun,
      reviewCycle: reviewCycle,
      plan: plan,
      preparedIntegration: integration
    )
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
      presentExecutionError(error, productID: candidate.productID)
    }
    await reloadSelectedProductIfCurrent(productID: candidate.productID)
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
      let reviewerProfileIDs = Set(
        profiles
          .filter { $0.role == .lead }
          .map(\.id)
      )
      if
        let reviewingCandidate = currentCandidates
          .filter({
            $0.workItemID == workItemID && $0.status == .reviewing
          })
          .max(by: { $0.version < $1.version }),
        let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: reviewingCandidate,
          runs: currentRuns,
          reviewerProfileIDs: reviewerProfileIDs
        ),
        reviewRun.status == .interrupted
      {
        _ = try await store.updateAgentRun(
          id: reviewRun.id,
          status: .queued,
          eventActor: "Product Owner",
          eventDetail: "Retry requested; Tech Lead review queued to continue"
        )
        await reloadSelectedProduct()
        scheduleSprintExecution()
        return
      }
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
        let readyCandidates = currentCandidates.filter { candidate in
          candidate.workItemID == item.id && candidate.status == .readyForDemo
        }
        if let candidate = readyCandidates.max(by: { $0.version < $1.version }) {
          await stopDemoSession(candidate, removesPreview: true)
          guard let integratedSHA = candidate.integratedSHA else {
            throw PersistenceError.corruptData(
              "The reviewed demo candidate has no integrated revision."
            )
          }
          _ = try await adoptIntegratedBaselineForRevision(
            candidate: candidate,
            integratedSHA: integratedSHA
          )
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
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  ) {
    stopLiveActivityMonitoring(runID: runID)
    let monitorID = UUID()
    liveActivityMonitorIDs[runID] = monitorID
    liveActivityProductIDs[runID] = productID
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
          self.liveActivityProductIDs.removeValue(forKey: runID)
          self.liveActivityTasks.removeValue(forKey: runID)
          return
        }
      }

      guard self.liveActivityMonitorIDs[runID] == monitorID else { return }
      self.liveRunActivities.removeValue(forKey: runID)
      self.liveActivityMonitorIDs.removeValue(forKey: runID)
      self.liveActivityProductIDs.removeValue(forKey: runID)
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
    guard selectedProductID == updated.productID else { return }
    if let index = runs.firstIndex(where: { $0.id == updated.id }) {
      runs[index] = updated
    } else {
      runs.append(updated)
    }
  }

  private func stopLiveActivityMonitoring(runID: UUID) {
    liveActivityTasks.removeValue(forKey: runID)?.cancel()
    liveActivityMonitorIDs.removeValue(forKey: runID)
    liveActivityProductIDs.removeValue(forKey: runID)
    liveRunActivities.removeValue(forKey: runID)
  }

  private func applyExecutionLifecycle(
    _ event: ProductExecutionLifecycleEvent
  ) async {
    switch ProductExecutionLifecyclePolicy.suspensionScope(for: event) {
    case .none:
      return
    case .product(let productID):
      await suspendSprintExecution(productID: productID)
    case .all:
      await suspendSprintExecution()
    }
  }

  private func suspendSprintExecution(productID: UUID? = nil) async {
    let executionTasks = sprintExecutionTasks.filter {
      productID == nil || $0.key == productID
    }
    for task in executionTasks.values {
      task.cancel()
    }
    let implementationTaskIDs = activeImplementationProductIDs.compactMap {
      productID == nil || $0.value == productID ? $0.key : nil
    }
    for runID in implementationTaskIDs {
      guard let task = activeImplementationTasks[runID] else { continue }
      task.cancel()
    }
    let reviewCandidateIDs = activeReviewProductIDs.compactMap {
      productID == nil || $0.value == productID ? $0.key : nil
    }
    for candidateID in reviewCandidateIDs {
      activeReviewTasks[candidateID]?.cancel()
    }
    let integrationProductIDs = activeIntegrationTasks.keys.filter {
      productID == nil || $0 == productID
    }
    for integrationProductID in integrationProductIDs {
      activeIntegrationTasks[integrationProductID]?.cancel()
    }
    if let client = codexClient {
      let turns = activeExecutionTurns.values.filter {
        productID == nil || $0.productID == productID
      }
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
    if
      !executionTasks.isEmpty
        || !implementationTaskIDs.isEmpty
        || !reviewCandidateIDs.isEmpty
        || !integrationProductIDs.isEmpty
    {
      for _ in 0..<100 {
        let hasScheduler =
          if let productID {
            sprintExecutionTasks[productID] != nil
          } else {
            !sprintExecutionTasks.isEmpty
          }
        let hasImplementation = activeImplementationProductIDs.contains {
          productID == nil || $0.value == productID
        }
        let hasReview = activeReviewProductIDs.contains {
          productID == nil || $0.value == productID
        }
        let hasIntegration = activeIntegrationTasks.keys.contains {
          productID == nil || $0 == productID
        }
        guard hasScheduler || hasImplementation || hasReview || hasIntegration
        else { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    if let productID {
      sprintExecutionWakeContinuations.removeValue(forKey: productID)?.finish()
      sprintExecutionTasks.removeValue(forKey: productID)
      sprintExecutionTaskIDs.removeValue(forKey: productID)
      for runID in implementationTaskIDs {
        activeImplementationTasks.removeValue(forKey: runID)
        activeImplementationProductIDs.removeValue(forKey: runID)
      }
      for candidateID in reviewCandidateIDs {
        activeReviewTasks.removeValue(forKey: candidateID)
        activeReviewProductIDs.removeValue(forKey: candidateID)
      }
      activeIntegrationTasks.removeValue(forKey: productID)
      activeExecutionTurns = activeExecutionTurns.filter {
        $0.value.productID != productID
      }
    } else {
      for continuation in sprintExecutionWakeContinuations.values {
        continuation.finish()
      }
      sprintExecutionWakeContinuations.removeAll()
      sprintExecutionTasks.removeAll()
      sprintExecutionTaskIDs.removeAll()
      activeImplementationTasks.removeAll()
      activeImplementationProductIDs.removeAll()
      activeReviewTasks.removeAll()
      activeReviewProductIDs.removeAll()
      activeIntegrationTasks.removeAll()
      activeExecutionTurns.removeAll()
    }
    let approvalRequestIDs = liveApprovalRequestProductIDs.compactMap {
      productID == nil || $0.value == productID ? $0.key : nil
    }
    if let store {
      for requestID in approvalRequestIDs {
        if let updated = try? await store.updateAgentPermissionRequest(
          id: requestID,
          status: .interrupted
        ) {
          replacePermissionRequest(updated)
        }
      }
    }
    for requestID in approvalRequestIDs {
      liveApprovalRequests.removeValue(forKey: requestID)
      liveApprovalRequestProductIDs.removeValue(forKey: requestID)
    }
    let liveRunIDs = liveActivityProductIDs.compactMap {
      productID == nil || $0.value == productID ? $0.key : nil
    }
    for runID in liveRunIDs {
      stopLiveActivityMonitoring(runID: runID)
    }
  }

  func shutdown() async {
    isShuttingDown = true
    let interruptedSuggestionTask = suggestionTask
    let interruptedEpicPlanningTask = epicPlanningTask
    interruptedSuggestionTask?.cancel()
    interruptedEpicPlanningTask?.cancel()
    if let client = codexClient, let activeEpicPlanningTurn {
      try? await client.interruptTurn(
        threadID: activeEpicPlanningTurn.threadID,
        turnID: activeEpicPlanningTurn.turnID
      )
    }
    await interruptedSuggestionTask?.value
    await interruptedEpicPlanningTask?.value
    suggestionTask = nil
    epicPlanningTask = nil
    activeEpicPlanningTurn = nil
    let interruptedRetrospectiveTasks = Array(retrospectiveSynthesisTasks.values)
    for task in interruptedRetrospectiveTasks {
      task.cancel()
    }
    if let client = codexClient {
      for turn in activeRetrospectiveSynthesisTurns.values {
        try? await client.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
      }
    }
    for task in interruptedRetrospectiveTasks {
      await task.value
    }
    retrospectiveSynthesisTasks.removeAll()
    activeRetrospectiveSynthesisTurns.removeAll()
    await epicConversationPersistenceTask?.value
    await stopAllDemoSessions()
    await applyExecutionLifecycle(.appShutdown)
    approvalRoutingTask?.cancel()
    approvalRoutingTask = nil
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
        isActionCandidate: true,
        actionDestination: action.destination
      )
    }
    return evidence + proposedActions
  }

  private func scheduleRetrospectiveSyntheses() {
    guard
      retrospectiveSynthesisTasks.isEmpty,
      let product = selectedProduct,
      let synthesis = retrospectiveSyntheses.first(where: {
        $0.productID == product.id && $0.status == .pending
      })
    else { return }
    scheduleRetrospectiveSynthesis(synthesis)
  }

  private func scheduleRetrospectiveSynthesis(
    _ synthesis: RetrospectiveSynthesis,
    allowsFailedRetry: Bool = false
  ) {
    guard
      retrospectiveSynthesisTasks.isEmpty,
      case .connected = codexConnectionState,
      let product = selectedProduct,
      product.id == synthesis.productID,
      synthesis.status == .pending
        || (allowsFailedRetry && synthesis.status == .failed)
    else { return }

    retrospectiveSynthesisTasks[synthesis.id] = Task { [weak self] in
      guard let self else { return }
      await performRetrospectiveSynthesis(
        synthesisID: synthesis.id,
        product: product
      )
      retrospectiveSynthesisTasks.removeValue(forKey: synthesis.id)
      scheduleRetrospectiveSyntheses()
    }
  }

  private func performRetrospectiveSynthesis(
    synthesisID: UUID,
    product: Product
  ) async {
    guard let store, let client = codexClient else { return }
    var startedSynthesis: RetrospectiveSynthesis?
    do {
      let productProfiles = try await store.fetchAgentProfiles(productID: product.id)
      guard
        let analyst = productProfiles.first(where: { $0.role == .businessAnalyst })
      else {
        throw PersistenceError.corruptData(
          "This product needs a Business Analyst to prepare retrospective actions."
        )
      }
      let synthesis = try await store.beginRetrospectiveSynthesis(
        id: synthesisID,
        profileID: analyst.id
      )
      startedSynthesis = synthesis
      replaceRetrospectiveSynthesis(synthesis)

      let sourceNotes = try await store.fetchRetrospectiveSynthesisSourceNotes(
        synthesisID: synthesis.id
      )
      if sourceNotes.isEmpty {
        _ = try await store.completeRetrospectiveSynthesis(
          id: synthesis.id,
          actions: [],
          profileID: analyst.id,
          authorName: analyst.name
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }

      let plans = try await store.fetchSprintHistory(productID: product.id)
      guard
        let sprint = plans.first(where: { $0.sprint.id == synthesis.sprintID })?.sprint
      else {
        throw PersistenceError.recordNotFound(
          "sprint \(synthesis.sprintID)"
        )
      }
      let productItems = try await store.fetchWorkItems(productID: product.id)
      let productNotes = try await store.fetchRetrospectiveNotes(productID: product.id)
      let productKnowledge = try await store.fetchKnowledgePages(productID: product.id)
      let waysOfWorking = productKnowledge.first {
        $0.slug == "ways-of-working" && $0.verificationStatus == .verified
      }?.bodyMarkdown ?? ""
      let existingActions = productNotes.filter {
        $0.category == .suggestedAction
          && !$0.isActionCandidate
          && $0.synthesisID != synthesis.id
      }

      let workspace = try Self.productWorkspaceURL(productID: product.id)
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexRetrospectiveSynthesizer.developerInstructions(
          productInstructions: inheritedAgentInstructions(
            for: product,
            availableKnowledge: productKnowledge
          ),
          personaInstructions: analyst.effectiveInstructions
        ),
        model: analyst.model
      )
      let prompt = CodexRetrospectiveSynthesizer.prompt(
        product: product,
        sprint: sprint,
        sourceNotes: sourceNotes,
        workItems: productItems,
        existingActions: existingActions,
        waysOfWorking: waysOfWorking
      )
      var turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: prompt,
        effort: analyst.reasoningEffort,
        outputSchema: CodexRetrospectiveSynthesizer.outputSchema
      )
      _ = try await store.attachRetrospectiveSynthesisTurn(
        id: synthesis.id,
        threadID: threadID,
        turnID: turnID
      )
      activeRetrospectiveSynthesisTurns[synthesis.id] = (
        threadID: threadID,
        turnID: turnID
      )
      var response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      try Task.checkCancellation()

      let actions: [RetrospectiveSynthesisActionDraft]
      do {
        actions = try CodexRetrospectiveSynthesizer.decode(
          response,
          sourceNotes: sourceNotes
        )
      } catch let validationError as RetrospectiveSynthesisGenerationError {
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexRetrospectiveSynthesizer.repairPrompt(
            validationError: validationError.localizedDescription
          ),
          effort: analyst.reasoningEffort,
          outputSchema: CodexRetrospectiveSynthesizer.outputSchema
        )
        _ = try await store.attachRetrospectiveSynthesisTurn(
          id: synthesis.id,
          threadID: threadID,
          turnID: turnID
        )
        activeRetrospectiveSynthesisTurns[synthesis.id] = (
          threadID: threadID,
          turnID: turnID
        )
        response = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        actions = try CodexRetrospectiveSynthesizer.decode(
          response,
          sourceNotes: sourceNotes
        )
      }

      _ = try await store.completeRetrospectiveSynthesis(
        id: synthesis.id,
        actions: actions,
        profileID: analyst.id,
        authorName: analyst.name
      )
      activeRetrospectiveSynthesisTurns.removeValue(forKey: synthesis.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    } catch is CancellationError {
      if !isShuttingDown, let startedSynthesis {
        _ = try? await store.failRetrospectiveSynthesis(
          id: startedSynthesis.id,
          message: "Preparing retrospective actions was interrupted. You can safely retry."
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
      }
    } catch {
      if let startedSynthesis {
        _ = try? await store.failRetrospectiveSynthesis(
          id: startedSynthesis.id,
          message: error.localizedDescription
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
      } else {
        errorMessage = error.localizedDescription
      }
    }
    activeRetrospectiveSynthesisTurns.removeValue(forKey: synthesisID)
  }

  private func replaceRetrospectiveSynthesis(
    _ synthesis: RetrospectiveSynthesis
  ) {
    guard selectedProductID == synthesis.productID else { return }
    retrospectiveSyntheses.removeAll { $0.id == synthesis.id }
    retrospectiveSyntheses.append(synthesis)
    retrospectiveSyntheses.sort { $0.createdAt < $1.createdAt }
  }

  private func inheritedAgentInstructions(
    for product: Product,
    availableKnowledge: [KnowledgePage]? = nil,
    includesMandatoryKnowledge: Bool = true
  ) -> String {
    let shared = product.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard includesMandatoryKnowledge else { return shared }
    let productKnowledge = (availableKnowledge ?? knowledgePages).filter {
      $0.productID == product.id
    }
    let mandatory = KnowledgeContextSelector.mandatoryPages(in: productKnowledge)
    guard !mandatory.isEmpty else { return shared }
    let context = mandatory.map { page in
      """
      ### \(page.title) [verified, page ID: \(page.id.uuidString)]
      \(page.bodyMarkdown)
      """
    }.joined(separator: "\n\n")
    return [
      shared,
      """
      VERIFIED MANDATORY PRODUCT KNOWLEDGE
      These pages are always included because they contain durable product and operating guidance:

      \(context)
      """,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
  }

  private func recordKnowledgeContext(
    runID: UUID,
    productID: UUID,
    pages: [KnowledgePage]
  ) async throws {
    guard let store else { throw CodexClientError.notConnected }
    try await store.setAgentRunKnowledgeContext(
      runID: runID,
      pageIDs: pages.map(\.id)
    )
    guard selectedProductID == productID else { return }
    agentRunKnowledgeContext.removeAll { $0.runID == runID }
    agentRunKnowledgeContext.append(
      contentsOf: pages.map {
        AgentRunKnowledgePage(runID: runID, pageID: $0.id)
      }
    )
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
    let demo = result.demo.map {
      "- **\($0.title)** — \($0.presentation.kind.title)"
    } ?? "- No managed demo recipe was recorded."
    let followUps = result.followUpTicketProposals.isEmpty
      ? "- No follow-up tickets were recommended."
      : result.followUpTicketProposals.map {
        "- **\($0.reference): \($0.title)** — \($0.rationale)"
      }.joined(separator: "\n")
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

      ## One-click demo
      \(demo)

      ## Recommended follow-up work
      \(followUps)

      ## Known limitations
      \(result.knowledgeNotes.isEmpty ? "- None recorded." : knowledge)
      """
  }

  private func makeKnowledgePageProposals(
    drafts: [KnowledgePageProposalDraft],
    candidate: CandidateRevision,
    runID: UUID
  ) async throws -> [KnowledgePageProposal] {
    guard let store else {
      throw PersistenceError.recordNotFound("knowledge context for agent run \(runID)")
    }
    let productDestinations = try await store.fetchAgentRunKnowledgeDestinations(
      productID: candidate.productID
    )
    let productKnowledgePages = try await store.fetchKnowledgePages(
      productID: candidate.productID
    )
    let destinationPageIDs = Set(
      productDestinations
        .filter { $0.runID == runID }
        .map(\.pageID)
    )
    let pagesByID = Dictionary(
      uniqueKeysWithValues: productKnowledgePages.map { ($0.id, $0) }
    )
    return try drafts.map { draft in
      let basePage = draft.targetPageID.flatMap { pagesByID[$0] }
      switch draft.operation {
      case .update:
        guard
          let targetPageID = draft.targetPageID,
          destinationPageIDs.contains(targetPageID),
          let page = pagesByID[targetPageID],
          page.productID == candidate.productID,
          page.kind == .page
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page update referenced a page that was not writable for this run."
          )
        }
      case .create:
        guard
          let parentPageID = draft.parentPageID,
          destinationPageIDs.contains(parentPageID),
          let parent = pagesByID[parentPageID],
          parent.productID == candidate.productID,
          parent.kind == .section
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page creation referenced a section that was not writable for this run."
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

  func reload() async {
    guard let store else {
      isLoading = false
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      products = try await store.fetchProducts()
      archivedProducts = try await store.fetchProducts(status: .archived)
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
      retrospectiveSyntheses = []
      retrospectiveActionSources = []
      knowledgePages = []
      candidateRevisions = []
      demoSessions = []
      permissionRequests = []
      permissionGrants = []
      knowledgePageProposals = []
      agentRunKnowledgeContext = []
      agentRunKnowledgeDestinations = []
      return
    }
    do {
      let loadedEpics = try await store.fetchEpics(productID: productID)
      let loadedWorkItems = try await store.fetchWorkItems(productID: productID)
      let loadedDependencies = try await store.fetchWorkItemDependencies(
        productID: productID
      )
      let loadedProfiles = try await store.seedDefaultProfiles(productID: productID)
      let loadedKnowledgePages = try await store.seedKnowledgeBase(productID: productID)
      let loadedCandidates = try await store.fetchCandidateRevisions(productID: productID)
      let acceptedKnowledgeSourceWorkItemIDs = Set(
        loadedCandidates
          .filter { $0.status == .accepted }
          .map(\.workItemID)
      ).union(
        loadedWorkItems
          .filter { $0.state == .readyToRelease || $0.state == .released }
          .map(\.id)
      )
      try Self.syncKnowledgeMarkdownFiles(
        productID: productID,
        pages: loadedKnowledgePages,
        acceptedSourceWorkItemIDs: acceptedKnowledgeSourceWorkItemIDs
      )
      let loadedAgentRunKnowledgeContext = try await store.fetchAgentRunKnowledgeContext(
        productID: productID
      )
      let loadedAgentRunKnowledgeDestinations =
        try await store.fetchAgentRunKnowledgeDestinations(productID: productID)
      let loadedDemoSessions = try await store.fetchDemoSessions(productID: productID)
      let loadedPermissionRequests = try await store.fetchAgentPermissionRequests(
        productID: productID
      )
      let loadedPermissionGrants = try await store.fetchAgentPermissionGrants(
        productID: productID
      )
      let loadedKnowledgeProposals = try await store.fetchKnowledgePageProposals(
        productID: productID
      )
      let loadedSprintPlan = try await store.fetchCurrentSprint(productID: productID)
      let loadedSprintHistory = try await store.fetchSprintHistory(productID: productID)
      let loadedRuns = try await store.fetchAgentRuns(productID: productID)
      let loadedCandidateSprint =
        if let loadedSprintPlan, loadedSprintPlan.sprint.state == .draft {
          loadedSprintPlan
        } else {
          loadedSprintHistory.first { $0.sprint.state == .draft }
        }
      let loadedReadinessIssues: [SprintReadinessIssue] =
        if let loadedCandidateSprint {
          try await store.sprintReadinessIssues(
            sprintID: loadedCandidateSprint.sprint.id
          )
        } else {
          []
        }
      let loadedActivity = try await store.fetchActivity(productID: productID)
      let loadedRetrospectiveNotes = try await store.fetchRetrospectiveNotes(
        productID: productID
      )
      let loadedRetrospectiveSyntheses = try await store.fetchRetrospectiveSyntheses(
        productID: productID
      )
      let loadedRetrospectiveActionSources =
        try await store.fetchRetrospectiveActionSources(productID: productID)
      let loadedSuggestionBatch = try await store.fetchLatestTicketSuggestionBatch(
        productID: productID
      )

      guard selectedProductID == productID else { return }
      epics = loadedEpics
      workItems = loadedWorkItems
      dependencies = loadedDependencies
      profiles = loadedProfiles
      knowledgePages = loadedKnowledgePages
      agentRunKnowledgeContext = loadedAgentRunKnowledgeContext
      agentRunKnowledgeDestinations = loadedAgentRunKnowledgeDestinations
      candidateRevisions = loadedCandidates
      demoSessions = loadedDemoSessions
      permissionRequests = loadedPermissionRequests
      permissionGrants = loadedPermissionGrants
      knowledgePageProposals = loadedKnowledgeProposals
      sprintPlan = loadedSprintPlan
      sprintHistory = loadedSprintHistory
      runs = loadedRuns
      sprintReadinessIssues = loadedReadinessIssues
      activity = loadedActivity
      retrospectiveNotes = loadedRetrospectiveNotes
      retrospectiveSyntheses = loadedRetrospectiveSyntheses
      retrospectiveActionSources = loadedRetrospectiveActionSources
      suggestionBatch = loadedSuggestionBatch
    } catch {
      presentExecutionError(error, productID: productID)
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
        configuration: .init(
          executableURL: descriptor.executableURL,
          environmentOverrides: CodexPermissionProfiles.agentProcessEnvironment
        )
      )
      let client = CodexAppServerClient(transport: transport)
      let info = try await client.connect()
      codexClient = client
      demoLauncher.useExecutor(
        CodexWorkspaceCommandExecutor(executableURL: descriptor.executableURL)
      )
      startApprovalRouting(client: client)
      codexConnectionState = .connected(version: descriptor.version, userAgent: info.userAgent)
      scheduleRetrospectiveSyntheses()
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

  func pendingPermissionRequest(workItemID: UUID) -> AgentPermissionRequest? {
    sprintWorkRecoveryPolicy.actionablePermissionRequest(
      for: workItemID,
      runs: runs,
      permissionRequests: permissionRequests
    )
  }

  func decidePermissionRequest(
    _ request: AgentPermissionRequest,
    allow: Bool,
    rememberForProduct: Bool = false
  ) async {
    guard
      request.status.needsOwnerDecision,
      let store,
      let client = codexClient
    else {
      errorMessage =
        "This permission request is no longer waiting for a decision."
      return
    }
    let serverRequest = liveApprovalRequests[request.id]
    guard request.status != .pending || serverRequest != nil else {
      errorMessage =
        "This permission request is no longer attached to a live agent turn. Relaunch StoryPointless to recover it before deciding."
      return
    }
    let resumesAfterDecision = request.status == .interrupted
    do {
      let proposedGrant: AgentPermissionGrant?
      if allow && rememberForProduct {
        guard let signature = request.productGrantSignature else {
          errorMessage = "This type of access cannot be saved for future agent runs."
          return
        }
        proposedGrant = AgentPermissionGrant(
          productID: request.productID,
          sourceRequestID: request.id,
          method: request.method,
          kind: request.kind,
          title: request.title,
          detail: request.detail,
          signature: signature
        )
      } else {
        proposedGrant = nil
      }

      var savedGrant: AgentPermissionGrant?
      if let proposedGrant {
        savedGrant = try await store.saveAgentPermissionGrant(proposedGrant)
      }
      if let serverRequest {
        do {
          try await client.resolveApprovalRequest(serverRequest, allow: allow)
        } catch {
          if let proposedGrant, savedGrant?.id == proposedGrant.id {
            _ = try? await store.revokeAgentPermissionGrant(id: proposedGrant.id)
          }
          throw error
        }
      }
      liveApprovalRequests.removeValue(forKey: request.id)
      liveApprovalRequestProductIDs.removeValue(forKey: request.id)
      let updated = try await store.updateAgentPermissionRequest(
        id: request.id,
        status: allow ? .allowed : .denied
      )
      replacePermissionRequest(updated)
      if let savedGrant {
        replacePermissionGrant(savedGrant)
      }
      if let run = try? await store.fetchAgentRun(id: request.agentRunID),
        run.status == .awaitingOwner
      {
        let eventDetail =
          if resumesAfterDecision && allow && rememberForProduct {
            "Saved the recovered capability for this product; queued the Conversation to resume"
          } else if resumesAfterDecision && allow {
            "Allowed the recovered capability once; queued the Conversation to resume"
          } else if resumesAfterDecision {
            "Denied the recovered capability; queued the Conversation so the agent can adapt"
          } else if allow && rememberForProduct {
            "Saved and allowed the requested capability for this product"
          } else if allow {
            "Allowed the requested capability once"
          } else {
            "Denied the requested capability; the agent will adapt"
          }
        _ = try await store.updateAgentRun(
          id: request.agentRunID,
          status: resumesAfterDecision ? .queued : .running,
          eventActor: "Product Owner",
          eventDetail: eventDetail
        )
      }
      await reloadSelectedProductIfCurrent(productID: request.productID)
      if resumesAfterDecision {
        scheduleSprintExecution(productID: request.productID)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func startApprovalRouting(client: CodexAppServerClient) {
    approvalRoutingTask?.cancel()
    approvalRoutingTask = Task { [weak self] in
      let messages = await client.inboundMessages(replayRecent: false)
      for await message in messages {
        guard !Task.isCancelled else { return }
        guard case .request(let request) = message else { continue }
        await self?.handleServerRequest(request, client: client)
      }
    }
  }

  private func handleServerRequest(
    _ request: CodexServerRequest,
    client: CodexAppServerClient
  ) async {
    guard let store else {
      await client.rejectUnsupportedServerRequest(request)
      return
    }
    let presentation: CodexApprovalPresentation
    do {
      presentation = try CodexAppServerClient.approvalPresentation(for: request)
    } catch {
      await client.rejectUnsupportedServerRequest(request)
      return
    }
    let runID = activeExecutionTurns.first(where: {
        $0.value.threadID == presentation.threadID
          && $0.value.turnID == presentation.turnID
      })?.key
      ?? runs
        .filter {
          $0.codexThreadID == presentation.threadID
            && ($0.status == .running || $0.status == .awaitingOwner)
        }
        .max(by: { $0.createdAt < $1.createdAt })?
        .id
    guard
      let runID,
      let run = try? await store.fetchAgentRun(id: runID)
    else {
      await client.rejectUnsupportedServerRequest(request)
      return
    }
    let productPermissionRequests =
      (try? await store.fetchAgentPermissionRequests(productID: run.productID)) ?? []
    let productPermissionGrants =
      (try? await store.fetchAgentPermissionGrants(productID: run.productID)) ?? []
    let productGrantSignature = try? CodexAppServerClient.productGrantSignature(
      for: request,
      ticketWorkspaceRoot: run.worktreePath.map {
        URL(fileURLWithPath: $0)
      }
    )

    if let priorDecision = (
      productPermissionRequests
        .filter {
          $0.agentRunID == runID
            && $0.signature == presentation.signature
            && ($0.status == .allowed || $0.status == .denied)
        }
        .max(by: { $0.updatedAt < $1.updatedAt })
    ) {
      do {
        try await client.resolveApprovalRequest(
          request,
          allow: priorDecision.status == .allowed
        )
        return
      } catch {
        // Fall through to a visible request if the automatic response could not be sent.
      }
    }

    if
      let signature = productGrantSignature,
      productPermissionGrants.contains(where: {
        $0.productID == run.productID
          && $0.signature == signature
          && $0.isActive
      })
    {
      do {
        try await client.resolveApprovalRequest(request, allow: true)
        let record = AgentPermissionRequest(
          productID: run.productID,
          workItemID: run.workItemID,
          agentRunID: run.id,
          threadID: presentation.threadID,
          turnID: presentation.turnID,
          serverRequestID: Self.serverRequestID(request.id),
          method: request.method,
          kind: presentation.kind,
          title: presentation.title,
          detail: presentation.detail,
          reason: presentation.reason,
          signature: presentation.signature,
          productGrantSignature: productGrantSignature,
          status: .allowed
        )
        if let saved = try? await store.saveAgentPermissionRequest(record) {
          replacePermissionRequest(saved)
        }
        return
      } catch {
        // Fall through so the Product Owner can make a visible decision.
      }
    }

    let record = AgentPermissionRequest(
      productID: run.productID,
      workItemID: run.workItemID,
      agentRunID: run.id,
      threadID: presentation.threadID,
      turnID: presentation.turnID,
      serverRequestID: Self.serverRequestID(request.id),
      method: request.method,
      kind: presentation.kind,
      title: presentation.title,
      detail: presentation.detail,
      reason: presentation.reason,
      signature: presentation.signature,
      productGrantSignature: productGrantSignature
    )
    do {
      let saved = try await store.saveAgentPermissionRequest(record)
      liveApprovalRequests[saved.id] = request
      liveApprovalRequestProductIDs[saved.id] = run.productID
      replacePermissionRequest(saved)
      _ = try await store.updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        eventActor: "StoryPointless",
        eventDetail: "Waiting for a scoped permission decision"
      )
      await reloadSelectedProductIfCurrent(productID: run.productID)
    } catch {
      await client.rejectUnsupportedServerRequest(request)
      errorMessage = error.localizedDescription
    }
  }

  private func replacePermissionRequest(_ request: AgentPermissionRequest) {
    guard selectedProductID == request.productID else { return }
    permissionRequests.removeAll { $0.id == request.id }
    permissionRequests.append(request)
    permissionRequests.sort { $0.createdAt < $1.createdAt }
  }

  func revokePermissionGrant(_ grant: AgentPermissionGrant) async {
    guard grant.isActive, let store else { return }
    do {
      _ = try await store.revokeAgentPermissionGrant(id: grant.id)
      permissionGrants.removeAll { $0.id == grant.id }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func replacePermissionGrant(_ grant: AgentPermissionGrant) {
    guard selectedProductID == grant.productID else { return }
    permissionGrants.removeAll { $0.id == grant.id || $0.signature == grant.signature }
    if grant.isActive {
      permissionGrants.append(grant)
      permissionGrants.sort { $0.createdAt < $1.createdAt }
    }
  }

  private static func serverRequestID(_ id: JSONValue) -> String {
    if let string = id.stringValue { return string }
    if let integer = id.integerValue { return String(integer) }
    return String(describing: id)
  }

  private func recoverTicketSuggestionSessionIfNeeded() async {
    guard
      let store,
      codexClient != nil,
      let session = suggestionBatch?.session,
      !automaticallyRecoveredSuggestionSessionIDs.contains(session.id),
      let epicID = session.epicID,
      let epic = epics.first(where: { $0.id == epicID })
    else { return }

    switch ticketSuggestionRecoveryPolicy.action(for: session) {
    case .none:
      return
    case .resumeInterruptedGeneration:
      break
    case .retryLegacyInterruption:
      do {
        let restartedSession = try await store.retryTicketSuggestionSession(
          sessionID: session.id
        )
        suggestionBatch = TicketSuggestionBatch(session: restartedSession, suggestions: [])
      } catch {
        errorMessage = error.localizedDescription
        return
      }
    }

    automaticallyRecoveredSuggestionSessionIDs.insert(session.id)
    await restoreEpicPlanningConversation(for: epic)
    generateEpicPlan(epic, recovering: session)
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

  private func forgetSelectedProduct() {
    UserDefaults.standard.removeObject(forKey: Self.selectedProductDefaultsKey)
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

  private static func previewWorktreesRootURL(productID: UUID) throws -> URL {
    guard
      let cachesURL = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    let url = cachesURL
      .appendingPathComponent("StoryPointless", isDirectory: true)
      .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      .appendingPathComponent(productID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func syncKnowledgeMarkdownFiles(
    productID: UUID,
    pages: [KnowledgePage],
    acceptedSourceWorkItemIDs: Set<UUID>
  ) throws {
    try syncKnowledgeMarkdownFiles(
      at: productWorkspaceURL(productID: productID),
      pages: pages,
      shouldExport: {
        AcceptedWorkspaceKnowledgeExportPolicy.shouldExport(
          $0,
          acceptedSourceWorkItemIDs: acceptedSourceWorkItemIDs
        )
      }
    )
  }

  private static func syncKnowledgeMarkdownFiles(
    at workspaceURL: URL,
    pages: [KnowledgePage]
  ) throws {
    try syncKnowledgeMarkdownFiles(
      at: workspaceURL,
      pages: pages,
      shouldExport: { $0.verificationStatus == .verified }
    )
  }

  private static func syncKnowledgeMarkdownFiles(
    at workspaceURL: URL,
    pages: [KnowledgePage],
    shouldExport: (KnowledgePage) -> Bool
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
      guard shouldExport(page) else {
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
