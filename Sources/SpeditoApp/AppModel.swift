import AppKit
import Foundation
import SpeditoCore
import SwiftUI

enum CodexConnectionState: Equatable {
  case notChecked
  case checking
  case connected(version: String, userAgent: String)
  case unavailable(String)
  case incompatible(String)

  var showsRetryAction: Bool {
    switch self {
    case .notChecked, .unavailable, .incompatible:
      true
    case .checking, .connected:
      false
    }
  }
}

enum CodexInstallationSelectionError: Error, LocalizedError {
  case invalidSelection
  case workInProgress

  var errorDescription: String? {
    switch self {
    case .invalidSelection:
      "Choose a Codex app or an executable named codex."
    case .workInProgress:
      "Wait for the current team work to finish before changing the Codex installation."
    }
  }
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
  let productID: UUID
  let epicID: UUID
  var messages: [EpicPlanningConversationMessage]
  var questions: [TicketRefinementQuestion]
  var hasStartedPlanning: Bool
  var isRunning: Bool
  var isGeneratingPlan: Bool
  var isComplete: Bool
  var errorMessage: String?
}

enum EpicPlanningRetryAction: Equatable {
  case retryFailedPlan
  case retryClarification([EpicPlanningAnsweredQuestion])
  case restartClarification
}

struct EpicPlanningPolicy {
  static func retryAction(
    for conversation: EpicPlanningConversationState,
    hasFailedPlan: Bool
  ) -> EpicPlanningRetryAction {
    if hasFailedPlan {
      return .retryFailedPlan
    }
    if let answeredQuestions = conversation.messages.last?.answeredQuestions,
      !answeredQuestions.isEmpty
    {
      return .retryClarification(answeredQuestions)
    }
    return .restartClarification
  }
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

enum TicketDeliveryEvidencePolicyError: Error, LocalizedError {
  case repositoryChangeRequired

  var errorDescription: String? {
    switch self {
    case .repositoryChangeRequired:
      "Completed product-changing work must create or modify an inspectable repository artefact."
    }
  }
}

struct TicketDeliveryEvidencePolicy {
  static func deliveryKind(
    assigneeRole: AgentRole,
    changedPaths: [String]
  ) throws -> CandidateDeliveryKind {
    if !changedPaths.isEmpty {
      return .repositoryChange
    }
    guard assigneeRole == .businessAnalyst else {
      throw TicketDeliveryEvidencePolicyError.repositoryChangeRequired
    }
    return .localOutcome
  }
}

enum GitHubRepositorySetupActivity: Equatable {
  case inProgress(
    progress: GitHubRemoteRepositoryInitializationProgress,
    publishesExistingHistory: Bool
  )
  case completed(publishedExistingHistory: Bool)

  var isInProgress: Bool {
    if case .inProgress = self { return true }
    return false
  }

  var isCompleted: Bool {
    if case .completed = self { return true }
    return false
  }
}

struct GitHubPullRequestPollingPolicy {
  static let foregroundPriorityInterval: Duration = .seconds(60)
  static let foregroundInterval: Duration = .seconds(120)
  static let backgroundInterval: Duration = .seconds(300)

  static func orderedPublications(
    _ publications: [RemotePublication],
    workItems: [WorkItem],
    visibleWorkItemIDs: Set<UUID>
  ) -> [RemotePublication] {
    let workItemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    return
      publications
      .filter(isPollable)
      .sorted { lhs, rhs in
        let lhsPriority = priority(
          publication: lhs,
          workItemsByID: workItemsByID,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        let rhsPriority = priority(
          publication: rhs,
          workItemsByID: workItemsByID,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        if lhsPriority != rhsPriority {
          return lhsPriority < rhsPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }

  static func interval(
    isApplicationActive: Bool,
    publications: [RemotePublication],
    workItems: [WorkItem],
    visibleWorkItemIDs: Set<UUID>
  ) -> Duration {
    guard isApplicationActive else { return backgroundInterval }
    let workItemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    let hasPriorityPullRequest = publications.contains {
      isPollable($0)
        && priority(
          publication: $0,
          workItemsByID: workItemsByID,
          visibleWorkItemIDs: visibleWorkItemIDs
        ) < 2
    }
    return hasPriorityPullRequest ? foregroundPriorityInterval : foregroundInterval
  }

  private static func isPollable(_ publication: RemotePublication) -> Bool {
    guard publication.workItemID != nil, publication.pullRequest != nil else {
      return false
    }
    switch publication.status {
    case .open, .openOutdated, .openStale:
      return true
    default:
      return false
    }
  }

  private static func priority(
    publication: RemotePublication,
    workItemsByID: [UUID: WorkItem],
    visibleWorkItemIDs: Set<UUID>
  ) -> Int {
    guard let workItemID = publication.workItemID else { return 2 }
    if visibleWorkItemIDs.contains(workItemID) {
      return 0
    }
    if workItemsByID[workItemID]?.state == .acceptance {
      return 1
    }
    return 2
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

struct KnowledgePageReadState: Equatable {
  private(set) var productID: UUID?
  private(set) var seenUpdates: [UUID: Date] = [:]

  mutating func load(
    productID: UUID,
    pages: [KnowledgePage],
    defaults: UserDefaults = .standard
  ) {
    guard
      self.productID != productID,
      !pages.isEmpty,
      pages.allSatisfy({ $0.productID == productID })
    else { return }
    self.productID = productID

    if let stored = defaults.dictionary(forKey: Self.defaultsKey(productID: productID)) {
      let pageIDs = Set(pages.map(\.id))
      seenUpdates = stored.reduce(into: [:]) { result, entry in
        guard
          let pageID = UUID(uuidString: entry.key),
          pageIDs.contains(pageID),
          let timestamp = (entry.value as? NSNumber)?.doubleValue
        else { return }
        result[pageID] = Date(timeIntervalSince1970: timestamp)
      }
    } else {
      seenUpdates = Dictionary(
        uniqueKeysWithValues: pages.map { ($0.id, $0.updatedAt) }
      )
      persist(defaults: defaults)
    }
  }

  mutating func reset() {
    productID = nil
    seenUpdates = [:]
  }

  func unreadPageIDs(in pages: [KnowledgePage]) -> Set<UUID> {
    guard let productID else { return [] }
    return Set(
      pages.compactMap { page in
        guard page.productID == productID else { return nil }
        guard let seenAt = seenUpdates[page.id] else { return page.id }
        return page.updatedAt > seenAt ? page.id : nil
      }
    )
  }

  mutating func markRead(
    _ page: KnowledgePage,
    defaults: UserDefaults = .standard
  ) {
    guard productID == page.productID else { return }
    if let seenAt = seenUpdates[page.id], seenAt >= page.updatedAt {
      return
    }
    seenUpdates[page.id] = page.updatedAt
    persist(defaults: defaults)
  }

  static func defaultsKey(productID: UUID) -> String {
    "Spedito.knowledge-page-seen.\(productID.uuidString)"
  }

  private func persist(defaults: UserDefaults) {
    guard let productID else { return }
    defaults.set(
      Dictionary(
        uniqueKeysWithValues: seenUpdates.map {
          ($0.key.uuidString, $0.value.timeIntervalSince1970)
        }
      ),
      forKey: Self.defaultsKey(productID: productID)
    )
  }
}

enum ProductCreationRequest: Equatable, Sendable {
  case blank(name: String)
  case importRepository(name: String, source: PublicGitRepositoryURL)
  case importGitHubRepository(name: String, repositoryID: Int64)

  var name: String {
    switch self {
    case .blank(let name), .importRepository(let name, _),
      .importGitHubRepository(let name, _):
      name
    }
  }
}

enum TeamSettingsUpdateFailure: Error, Equatable, Sendable {
  case unavailable
  case saveFailed(String)

  var message: String {
    switch self {
    case .unavailable:
      "Team settings are unavailable for this product."
    case .saveFailed(let message):
      message
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var products: [Product] = []
  @Published private(set) var archivedProducts: [Product] = []
  @Published private(set) var ticketAttentionsByProductID: [UUID: [TicketAttention]] = [:]
  @Published private(set) var presentedTicketAttention: TicketAttention?
  @Published private(set) var ticketAttentionNavigationRequest:
    TicketAttentionNavigationRequest?
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
  @Published private(set) var unreadKnowledgePageIDs: Set<UUID> = []
  @Published private(set) var productRepository: ProductRepository?
  @Published private(set) var githubRemoteRepositoryStates: [UUID: GitHubRemoteRepositoryState] =
    [:]
  @Published private(set) var githubDeviceAuthorizationPrompts:
    [UUID: GitHubDeviceAuthorizationPrompt] = [:]
  @Published private(set) var githubRemoteRepositoryBusyProductIDs: Set<UUID> = []
  @Published private(set) var githubRemoteRepositoryErrors: [UUID: String] = [:]
  @Published private(set) var ticketAcceptanceInProgressWorkItemIDs: Set<UUID> = []
  @Published private(set) var githubRepositorySetupActivities:
    [UUID: GitHubRepositorySetupActivity] = [:]
  @Published private(set) var githubImportRepositoryCatalog = GitHubRepositoryImportCatalog()
  @Published private(set) var isLoadingGitHubImportRepositories = false
  @Published private(set) var githubImportRepositoryError: String?
  @Published private(set) var githubImportDeviceAuthorizationPrompt:
    GitHubDeviceAuthorizationPrompt?
  @Published private(set) var importedAppLaunch: ImportedAppLaunch?
  @Published private(set) var repositoryKnowledgeRun: RepositoryKnowledgeRun?
  @Published private(set) var repositoryKnowledgeDrafts: [RepositoryKnowledgeDraft] = []
  @Published private(set) var repositoryKnowledgeActivities: [UUID: CodexLiveActivity] = [:]
  @Published private(set) var candidateRevisions: [CandidateRevision] = []
  @Published private(set) var demoSessions: [DemoSession] = []
  @Published private(set) var permissionRequests: [AgentPermissionRequest] = []
  @Published private(set) var permissionGrants: [AgentPermissionGrant] = []
  @Published private(set) var knowledgePageProposals: [KnowledgePageProposal] = []
  @Published private(set) var agentRunKnowledgeContext: [AgentRunKnowledgePage] = []
  @Published private(set) var agentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] = []
  @Published private(set) var liveRunActivities: [UUID: CodexLiveActivity] = [:]
  @Published private(set) var suggestionBatch: TicketSuggestionBatch?
  @Published private(set) var conversationThreads: [ProductConversationThread] = []
  @Published private(set) var conversationMessagesByThread: [UUID: [ProductConversationMessage]] =
    [:]
  @Published private(set) var respondingConversationThreadIDs: Set<UUID> = []
  @Published private(set) var productConversationActivities: [UUID: CodexLiveActivity] = [:]
  @Published private(set) var conversationErrorsByThread: [UUID: String] = [:]
  @Published private(set) var codexModels: [CodexModelOption] = []
  @Published private(set) var codexConnectionState = CodexConnectionState.notChecked
  @Published private(set) var codexRateLimits: CodexRateLimitsSnapshot?
  @Published private(set) var codexUsageUpdatedAt: Date?
  @Published private(set) var isRefreshingCodexUsage = false
  @Published private(set) var isCodexUsageStale = false
  @Published private(set) var codexInstallations: [CodexInstallation] = []
  @Published private(set) var selectedCodexInstallationID: String?
  @Published var selectedProductID: UUID?
  @Published private(set) var shouldPresentProductLibraryOnLaunch = false
  @Published var errorMessage: String?
  @Published private(set) var productCreationError: String?
  @Published private(set) var isLoading = true
  @Published private(set) var isDecidingSuggestions = false
  @Published private(set) var isPlanningMessageRunning = false
  @Published private(set) var isGeneratingSprintGoal = false
  @Published private(set) var isTicketConversationMessageRunning = false
  @Published private(set) var ticketConversationWorkItemID: UUID?
  @Published private(set) var ticketConversationRecipientID: UUID?
  @Published private(set) var ticketConversationActivity: CodexLiveActivity?
  @Published private(set) var isEpicConversationMessageRunning = false
  @Published private(set) var epicConversationEpicID: UUID?
  @Published private(set) var epicConversationRecipientID: UUID?
  @Published private(set) var ticketRefinementResults: [UUID: TicketRefinementSessionResult] = [:]
  @Published private(set) var ticketConversationResults: [UUID: TicketConversationSessionResult] =
    [:]
  @Published private(set) var epicPlanningConversation: EpicPlanningConversationState?
  @Published private(set) var isAskingKnowledge = false
  @Published private(set) var refiningWorkItemID: UUID?
  @Published private(set) var codebaseFocusWorkItemID: UUID?
  @Published private(set) var knowledgeFocusPageID: UUID?
  @Published var backlogFocusEpicID: UUID?

  let requiresKnowledgeApproval = SpeditoFeatureFlags.requiresKnowledgeApproval

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

  var selectedGitHubRemoteRepositoryState: GitHubRemoteRepositoryState? {
    guard let selectedProductID else { return nil }
    return githubRemoteRepositoryStates[selectedProductID]
  }

  var selectedGitHubDeviceAuthorizationPrompt: GitHubDeviceAuthorizationPrompt? {
    guard let selectedProductID else { return nil }
    return githubDeviceAuthorizationPrompts[selectedProductID]
  }

  var isSelectedGitHubRemoteRepositoryBusy: Bool {
    guard let selectedProductID else { return false }
    return githubRemoteRepositoryBusyProductIDs.contains(selectedProductID)
  }

  var selectedGitHubRemoteRepositoryError: String? {
    guard let selectedProductID else { return nil }
    return githubRemoteRepositoryErrors[selectedProductID]
  }

  private let storeRegistry: ProductStoreRegistry?
  private let injectedStore: SQLiteStore?
  private var store: SQLiteStore? {
    if let injectedStore { return injectedStore }
    guard let selectedProductID else { return nil }
    return storeRegistry?.store(for: selectedProductID)
  }
  private let gitWorkspaceManager: GitWorkspaceManager
  private let productRepositoryImporter: ProductRepositoryImporter?
  private let githubRemoteService: (any GitHubRemoteRepositoryServing)?
  private let demoLauncher = MacOSDemoLauncher()
  private var githubPullRequestPollingTask: Task<Void, Never>?
  private var githubPullRequestSyncTasks: [UUID: Task<Void, Never>] = [:]
  private var ticketAcceptanceTasks: [UUID: Task<Void, Never>] = [:]
  private var visibleGitHubReviewWorkItemCounts: [UUID: Int] = [:]
  private var productsLaunchingManagedPresentation: Set<UUID> = []
  private let sprintWorkRecoveryPolicy = SprintWorkRecoveryPolicy()
  private let ticketSuggestionRecoveryPolicy = TicketSuggestionRecoveryPolicy()
  private let repositoryKnowledgeRecoveryPolicy = RepositoryKnowledgeRecoveryPolicy()
  private let remoteProductArchivePolicy = RemoteProductArchivePolicy()
  private let ticketAttentionSoundPlayer: any TicketAttentionSoundPlaying
  private let ticketAttentionSystemNotifier: any TicketAttentionSystemNotifying
  private let codexInstallationPreferences: CodexInstallationPreferences
  private var knowledgePageReadState = KnowledgePageReadState()
  private var codexClient: CodexAppServerClient?
  private var codexRuntimeExecutableURL: URL?
  private var repositoryKnowledgeTasks: [UUID: Task<Void, Never>] = [:]
  private var repositoryKnowledgeClients: [UUID: CodexAppServerClient] = [:]
  private var activeRepositoryKnowledgeTurns: [UUID: (threadID: String, turnID: String)] = [:]
  private var repositoryKnowledgeActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var repositoryKnowledgeActivityMonitorIDs: [UUID: UUID] = [:]
  private var repositoryRecoveryAttemptProductIDs: Set<UUID> = []
  private var suggestionTask: Task<Void, Never>?
  private var productImportTask: Task<ImportedProduct, Error>?
  private var githubRemoteTasks: [UUID: Task<Void, Never>] = [:]
  private var githubImportAuthorizationTask: Task<GitHubRepositoryImportCatalog, Error>?
  private var planningThreadIDs: [PlanningConversationKey: String] = [:]
  private var ticketConversationThreadIDs: [PlanningConversationKey: String] = [:]
  private var epicConversationThreadIDs: [PlanningConversationKey: String] = [:]
  private var activePlanningTurn: (threadID: String, turnID: String)?
  private var activeSprintGoalTurn: (threadID: String, turnID: String)?
  private var activeTicketConversationTurn: (threadID: String, turnID: String)?
  private var ticketConversationActivityTask: Task<Void, Never>?
  private var ticketConversationActivityMonitorID: UUID?
  private var activeEpicConversationTurn: (threadID: String, turnID: String)?
  private var activeTicketRefinementTurn: (threadID: String, turnID: String)?
  private var epicPlanningThreadID: String?
  private var activeEpicPlanningTurn: (threadID: String, turnID: String)?
  private var epicPlanningTask: Task<Void, Never>?
  private var epicConversationPersistenceTask: Task<Void, Never>?
  private var sprintExecutionTasks: [UUID: Task<Void, Never>] = [:]
  private var sprintExecutionTaskIDs: [UUID: UUID] = [:]
  private var sprintExecutionWakeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
  private var activeImplementationTasks: [UUID: Task<Void, Never>] = [:]
  private var activeImplementationProductIDs: [UUID: UUID] = [:]
  private var activeIntegrationTasks: [UUID: Task<Void, Never>] = [:]
  private var activeIntegrationProductIDs: [UUID: UUID] = [:]

  private struct ActiveExecutionTurn: Sendable {
    let productID: UUID
    let threadID: String
    let turnID: String
  }

  private struct ActiveProductConversationTurn: Sendable {
    let productID: UUID
    let threadID: String
    let turnID: String
  }

  private var activeExecutionTurns: [UUID: ActiveExecutionTurn] = [:]
  private var liveApprovalRequests: [UUID: CodexServerRequest] = [:]
  private var liveApprovalRequestProductIDs: [UUID: UUID] = [:]
  private var approvalRoutingTask: Task<Void, Never>?
  private var codexUsageMonitoringTask: Task<Void, Never>?
  private var codexUsageResetTask: Task<Void, Never>?
  private var codexUsageMonitorID: UUID?
  private var manuallyStoppedRunIDs: Set<UUID> = []
  private var pausedSprintProductIDs: Set<UUID> = []
  private var stoppingSprintProductIDs: Set<UUID> = []
  private var liveActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var liveActivityMonitorIDs: [UUID: UUID] = [:]
  private var liveActivityProductIDs: [UUID: UUID] = [:]
  private var retrospectiveSynthesisTasks: [UUID: Task<Void, Never>] = [:]
  private var activeRetrospectiveSynthesisTurns: [UUID: (threadID: String, turnID: String)] = [:]
  private var activeProductConversationTurns: [UUID: ActiveProductConversationTurn] = [:]
  private var activeProductConversationTitleTurns: [UUID: ActiveProductConversationTurn] = [:]
  private var productConversationTitleTasks: [UUID: Task<Void, Never>] = [:]
  private var productConversationActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var productConversationActivityMonitorIDs: [UUID: UUID] = [:]
  private var cancelledProductConversationThreadIDs: Set<UUID> = []
  private var didLoad = false
  private var didResolveInitialProductSelection = false
  private var automaticallyRecoveredSuggestionSessionIDs: Set<UUID> = []
  private var isShuttingDown = false

  private static let selectedProductDefaultsKey = "selectedProductID"
  private static let legacyDefaultsDomain = "com.storypointless.app"
  private static let legacyDefaultsMigrationKey =
    "migration.preSpeditoDefaultsCompleted"

  init() {
    Self.migrateLegacyDefaults()
    codexInstallationPreferences = CodexInstallationPreferences()
    let gitWorkspaceManager = GitWorkspaceManager()
    var remoteService: (any GitHubRemoteRepositoryServing)?
    self.gitWorkspaceManager = gitWorkspaceManager
    ticketAttentionSoundPlayer = BundledTicketAttentionSoundPlayer()
    ticketAttentionSystemNotifier = MacOSTicketAttentionNotifier()
    selectedProductID = UserDefaults.standard.string(
      forKey: Self.selectedProductDefaultsKey
    ).flatMap(UUID.init(uuidString:))
    do {
      let baseURL = try Self.applicationSupportURL()
      let workspacesRootURL = baseURL.appendingPathComponent(
        "Product Workspaces",
        isDirectory: true
      )
      let registry = try ProductStoreRegistry(
        productWorkspacesRootURL: workspacesRootURL,
        legacyDatabaseURL: baseURL.appendingPathComponent("storypointless.sqlite")
      )
      storeRegistry = registry
      productRepositoryImporter = ProductRepositoryImporter(
        storeRegistry: registry,
        gitWorkspaceManager: gitWorkspaceManager,
        stagingRootURL: baseURL.appendingPathComponent(
          "Import Workspaces",
          isDirectory: true
        )
      )
      remoteService = GitHubRemoteRepositoryService(
        configuration: .current(),
        git: gitWorkspaceManager,
        storeProvider: { productID in
          await registry.store(for: productID)
        },
        storesProvider: {
          await registry.allStores
        },
        workspaceProvider: { productID in
          workspacesRootURL.appendingPathComponent(
            productID.uuidString,
            isDirectory: true
          )
        }
      )
      injectedStore = nil
    } catch {
      storeRegistry = nil
      productRepositoryImporter = nil
      injectedStore = nil
      errorMessage = error.localizedDescription
    }
    githubRemoteService = remoteService
    refreshCodexInstallations()
  }

  init(
    store: SQLiteStore?,
    selectedProductID: UUID? = nil,
    ticketAttentionSoundPlayer: any TicketAttentionSoundPlaying =
      BundledTicketAttentionSoundPlayer(),
    ticketAttentionSystemNotifier: any TicketAttentionSystemNotifying =
      MacOSTicketAttentionNotifier(),
    githubRemoteService: (any GitHubRemoteRepositoryServing)? = nil
  ) {
    codexInstallationPreferences = CodexInstallationPreferences()
    gitWorkspaceManager = GitWorkspaceManager()
    productRepositoryImporter = nil
    storeRegistry = nil
    injectedStore = store
    self.githubRemoteService = githubRemoteService
    self.selectedProductID = selectedProductID
    self.ticketAttentionSoundPlayer = ticketAttentionSoundPlayer
    self.ticketAttentionSystemNotifier = ticketAttentionSystemNotifier
    refreshCodexInstallations()
  }

  init(
    storeRegistry: ProductStoreRegistry,
    selectedProductID: UUID? = nil,
    ticketAttentionSoundPlayer: any TicketAttentionSoundPlaying =
      BundledTicketAttentionSoundPlayer(),
    ticketAttentionSystemNotifier: any TicketAttentionSystemNotifying =
      MacOSTicketAttentionNotifier(),
    githubRemoteService: (any GitHubRemoteRepositoryServing)? = nil
  ) {
    codexInstallationPreferences = CodexInstallationPreferences()
    let gitWorkspaceManager = GitWorkspaceManager()
    self.gitWorkspaceManager = gitWorkspaceManager
    self.storeRegistry = storeRegistry
    productRepositoryImporter = ProductRepositoryImporter(
      storeRegistry: storeRegistry,
      gitWorkspaceManager: gitWorkspaceManager,
      stagingRootURL: storeRegistry.productWorkspacesRootURL
        .deletingLastPathComponent()
        .appendingPathComponent("Import Workspaces", isDirectory: true)
    )
    injectedStore = nil
    self.githubRemoteService = githubRemoteService
    self.selectedProductID = selectedProductID
    self.ticketAttentionSoundPlayer = ticketAttentionSoundPlayer
    self.ticketAttentionSystemNotifier = ticketAttentionSystemNotifier
    refreshCodexInstallations()
  }

  private func store(for productID: UUID) -> SQLiteStore? {
    injectedStore ?? storeRegistry?.store(for: productID)
  }

  private func fetchProducts(
    status: ProductStatus = .active
  ) async throws -> [Product] {
    if let storeRegistry {
      return try await storeRegistry.fetchProducts(status: status)
    }
    guard let injectedStore else { return [] }
    return try await injectedStore.fetchProducts(status: status)
  }

  private func fetchTicketAttentions(
    product: Product,
    store: SQLiteStore
  ) async throws -> [TicketAttention] {
    let workItems = try await store.fetchWorkItems(productID: product.id)
    let workItemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    let permissionRequests = try await store.fetchAgentPermissionRequests(productID: product.id)
    let awaitingRuns = try await store.fetchAgentRuns(productID: product.id)
      .filter { $0.status == .awaitingOwner }
    let latestRunsByWorkItemID = awaitingRuns.reduce(
      into: [UUID: AgentRun]()
    ) { latestRuns, run in
      if let current = latestRuns[run.workItemID], current.updatedAt >= run.updatedAt {
        return
      }
      latestRuns[run.workItemID] = run
    }

    var attentions: [TicketAttention] = []
    for run in latestRunsByWorkItemID.values {
      guard let item = workItemsByID[run.workItemID] else { continue }
      let latestPermissionRequest =
        permissionRequests
        .filter {
          $0.agentRunID == run.id && $0.status.needsOwnerDecision
        }
        .max { $0.updatedAt < $1.updatedAt }
      let comments = try await store.fetchComments(workItemID: item.id)
      let latestQuestion =
        comments
        .reversed()
        .compactMap { comment in
          TicketOwnerQuestion.presentation(
            in: comment.body,
            structuredQuestion: comment.ownerQuestion
          )?.question.prompt
        }
        .first
      let summary =
        latestPermissionRequest?.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? latestPermissionRequest?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? latestQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? item.title
      attentions.append(
        TicketAttention(
          id: run.id,
          productID: product.id,
          productName: product.name,
          sprintID: run.sprintID,
          workItemID: item.id,
          itemKey: item.key,
          title: item.title,
          summary: summary.isEmpty ? item.title : summary,
          updatedAt: run.updatedAt
        )
      )
    }
    return attentions.sorted {
      if $0.updatedAt != $1.updatedAt {
        return $0.updatedAt > $1.updatedAt
      }
      return $0.itemKey.localizedStandardCompare($1.itemKey) == .orderedAscending
    }
  }

  private func fetchTicketAttentions(
    products: [Product]
  ) async -> [UUID: [TicketAttention]] {
    var attentionsByProductID: [UUID: [TicketAttention]] = [:]
    for product in products {
      guard
        let productStore = store(for: product.id),
        let attentions = try? await fetchTicketAttentions(
          product: product,
          store: productStore
        )
      else { continue }
      if !attentions.isEmpty {
        attentionsByProductID[product.id] = attentions
      }
    }
    return attentionsByProductID
  }

  private func refreshTicketAttentions(productID: UUID) async {
    guard
      let product = products.first(where: { $0.id == productID }),
      let productStore = store(for: productID)
    else {
      ticketAttentionsByProductID.removeValue(forKey: productID)
      return
    }
    guard
      let attentions = try? await fetchTicketAttentions(
        product: product,
        store: productStore
      )
    else { return }
    if attentions.isEmpty {
      ticketAttentionsByProductID.removeValue(forKey: productID)
    } else {
      ticketAttentionsByProductID[productID] = attentions
    }
  }

  @discardableResult
  private func updateAgentRun(
    id: UUID,
    status: AgentRunStatus,
    codexThreadID: String? = nil,
    worktreePath: String? = nil,
    eventActor: String? = nil,
    eventDetail: String? = nil
  ) async throws -> AgentRun {
    let runStore: SQLiteStore?
    if let injectedStore {
      runStore = injectedStore
    } else if let storeRegistry {
      runStore = await storeRegistry.findStore(containingAgentRun: id)
    } else {
      runStore = store
    }
    guard let runStore else {
      throw PersistenceError.recordNotFound("Spedito database")
    }
    let previousRun = try await runStore.fetchAgentRun(id: id)
    let updatedRun = try await runStore.updateAgentRun(
      id: id,
      status: status,
      codexThreadID: codexThreadID,
      worktreePath: worktreePath,
      eventActor: eventActor,
      eventDetail: eventDetail
    )
    let newlyNeedsAttention = TicketAttentionSoundPolicy.shouldPlay(
      previousStatus: previousRun.status,
      newStatus: updatedRun.status,
      isShuttingDown: isShuttingDown
    )
    if previousRun.status == .awaitingOwner || updatedRun.status == .awaitingOwner {
      await refreshTicketAttentions(productID: updatedRun.productID)
    }
    if newlyNeedsAttention {
      ticketAttentionSoundPlayer.play()
      if let attention = ticketAttentionsByProductID[updatedRun.productID]?
        .first(where: { $0.workItemID == updatedRun.workItemID })
      {
        presentedTicketAttention = attention
        ticketAttentionSystemNotifier.post(attention)
      }
    }
    return updatedRun
  }

  var selectedProduct: Product? {
    products.first { $0.id == selectedProductID }
  }

  var ticketAttentionCount: Int {
    ticketAttentionsByProductID.values.reduce(0) { $0 + $1.count }
  }

  func ticketAttentionCount(for productID: UUID) -> Int {
    ticketAttentionsByProductID[productID]?.count ?? 0
  }

  func ticketAttentionCount(excluding productID: UUID?) -> Int {
    ticketAttentionsByProductID.reduce(0) { count, entry in
      entry.key == productID ? count : count + entry.value.count
    }
  }

  func dismissPresentedTicketAttention(id: UUID) {
    guard presentedTicketAttention?.id == id else { return }
    presentedTicketAttention = nil
  }

  func openTicketAttention(_ attention: TicketAttention) async {
    guard
      let product = products.first(where: { $0.id == attention.productID })
    else { return }
    if selectedProductID != product.id {
      await selectProduct(product)
    } else {
      await reloadSelectedProduct()
    }
    presentedTicketAttention = nil
    ticketAttentionNavigationRequest = TicketAttentionNavigationRequest(
      productID: attention.productID,
      sprintID: attention.sprintID,
      workItemIDs: [attention.workItemID],
      openWorkItemID: attention.workItemID
    )
  }

  func openTicketAttention(productID: UUID, workItemID: UUID) async {
    await refreshTicketAttentions(productID: productID)
    guard
      let attention = ticketAttentionsByProductID[productID]?
        .first(where: { $0.workItemID == workItemID })
    else { return }
    await openTicketAttention(attention)
  }

  func openTicketAttentions(for product: Product) async {
    let attentions = ticketAttentionsByProductID[product.id] ?? []
    if selectedProductID != product.id {
      await selectProduct(product)
    } else {
      await reloadSelectedProduct()
    }
    guard !attentions.isEmpty else { return }
    presentedTicketAttention = nil
    ticketAttentionNavigationRequest = TicketAttentionNavigationRequest(
      productID: product.id,
      sprintID: attentions.first?.sprintID,
      workItemIDs: Set(attentions.map(\.workItemID)),
      openWorkItemID: attentions.count == 1 ? attentions[0].workItemID : nil
    )
  }

  func consumeTicketAttentionNavigationRequest(id: UUID) {
    guard ticketAttentionNavigationRequest?.id == id else { return }
    ticketAttentionNavigationRequest = nil
  }

  var appVersions: [AppVersion] {
    AppVersionPolicy.all(imported: importedAppLaunch, acceptedCandidates: candidateRevisions)
  }

  var selectedCodexInstallation: CodexInstallation? {
    codexInstallations.first { $0.id == selectedCodexInstallationID }
  }

  var canChangeCodexInstallation: Bool {
    !isShuttingDown
      && suggestionTask == nil
      && epicPlanningTask == nil
      && retrospectiveSynthesisTasks.isEmpty
      && activeExecutionTurns.isEmpty
      && activeProductConversationTurns.isEmpty
      && productConversationTitleTasks.isEmpty
      && activePlanningTurn == nil
      && activeSprintGoalTurn == nil
      && activeTicketConversationTurn == nil
      && activeEpicConversationTurn == nil
      && activeTicketRefinementTurn == nil
      && activeEpicPlanningTurn == nil
      && !demoSessions.contains {
        $0.status == .preparing || $0.status == .starting || $0.status == .ready
      }
  }

  var canAutosuggestTickets: Bool {
    guard case .connected = codexConnectionState else { return false }
    guard suggestionBatch?.session.status != .generating else { return false }
    guard !isPlanningMessageRunning else { return false }
    guard !isGeneratingSprintGoal else { return false }
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
    guard !isGeneratingSprintGoal else { return false }
    guard !isTicketConversationMessageRunning else { return false }
    guard !isEpicConversationMessageRunning else { return false }
    return refiningWorkItemID == nil
  }

  var canGenerateSprintGoal: Bool {
    guard case .connected = codexConnectionState else { return false }
    guard
      let plan = candidateSprintPlan ?? sprintPlan,
      [.draft, .active, .paused].contains(plan.sprint.state),
      !plan.items.isEmpty
    else { return false }
    guard suggestionBatch?.session.status != .generating else { return false }
    guard !isPlanningMessageRunning else { return false }
    guard !isGeneratingSprintGoal else { return false }
    guard !isTicketConversationMessageRunning else { return false }
    guard !isEpicConversationMessageRunning else { return false }
    guard refiningWorkItemID == nil else { return false }
    guard epicPlanningConversation?.isRunning != true else { return false }
    return epicPlanningConversation?.isGeneratingPlan != true
  }

  var pendingSuggestionCount: Int {
    guard
      suggestionBatch?.session.epicID != nil
        || suggestionBatch?.session.sourceWorkItemID != nil
    else { return 0 }
    return suggestionBatch?.suggestions.filter { $0.status == .proposed }.count ?? 0
  }

  func connectGitHub(productID: UUID) async {
    githubDeviceAuthorizationPrompts[productID] = nil
    githubRepositorySetupActivities.removeValue(forKey: productID)
    let onPrompt: @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void = {
      [weak self] prompt in
      await self?.presentGitHubDeviceAuthorizationPrompt(prompt, productID: productID)
    }
    await performGitHubAction(productID: productID) {
      try await $0.connect(productID: productID, onPrompt: onPrompt)
    }
    githubDeviceAuthorizationPrompts[productID] = nil
  }

  func cancelGitHubConnection(productID: UUID) async {
    if let task = githubRemoteTasks[productID] {
      task.cancel()
      await task.value
    }
    githubDeviceAuthorizationPrompts[productID] = nil
    githubRepositorySetupActivities.removeValue(forKey: productID)
    await performGitHubAction(productID: productID) {
      try await $0.cancelConnection(productID: productID)
    }
  }

  func disconnectGitHub(productID: UUID) async {
    githubRepositorySetupActivities.removeValue(forKey: productID)
    await performGitHubAction(productID: productID) {
      try await $0.disconnect(productID: productID)
    }
  }

  func signOutGitHub(accountID: UUID, productID: UUID) async {
    githubRepositorySetupActivities.removeValue(forKey: productID)
    await performGitHubAction(productID: productID) { service in
      try await service.signOut(accountID: accountID)
      return await service.state(productID: productID)
    }
    guard let githubRemoteService else { return }
    for product in products + archivedProducts {
      githubRemoteRepositoryStates[product.id] = await githubRemoteService.state(
        productID: product.id
      )
    }
  }

  func refreshGitHubImportRepositories() async {
    guard !isShuttingDown, !isLoadingGitHubImportRepositories else { return }
    guard let githubRemoteService else {
      githubImportRepositoryCatalog = GitHubRepositoryImportCatalog()
      githubImportRepositoryError = nil
      return
    }
    isLoadingGitHubImportRepositories = true
    defer { isLoadingGitHubImportRepositories = false }
    do {
      githubImportRepositoryCatalog = try await githubRemoteService.importRepositories()
      githubImportRepositoryError = nil
    } catch {
      githubImportRepositoryCatalog = GitHubRepositoryImportCatalog()
      githubImportRepositoryError = error.localizedDescription
    }
  }

  func connectGitHubForImport() async {
    guard !isShuttingDown, githubImportAuthorizationTask == nil else { return }
    guard let githubRemoteService else {
      githubImportRepositoryError = "This Spedito build is not configured for GitHub."
      return
    }
    githubImportDeviceAuthorizationPrompt = nil
    githubImportRepositoryError = nil
    isLoadingGitHubImportRepositories = true
    let onPrompt: @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void = {
      [weak self] prompt in
      await self?.presentGitHubImportDeviceAuthorizationPrompt(prompt)
    }
    let task = Task {
      try await githubRemoteService.authorizeImport(onPrompt: onPrompt)
    }
    githubImportAuthorizationTask = task
    do {
      githubImportRepositoryCatalog = try await task.value
      if githubImportRepositoryCatalog.choices.isEmpty {
        githubImportRepositoryError =
          "GitHub is connected, but no repositories are available to Spedito yet."
      }
    } catch is CancellationError {
      githubImportRepositoryError = nil
    } catch {
      githubImportRepositoryCatalog = GitHubRepositoryImportCatalog()
      githubImportRepositoryError = error.localizedDescription
    }
    githubImportDeviceAuthorizationPrompt = nil
    githubImportAuthorizationTask = nil
    isLoadingGitHubImportRepositories = false
  }

  func cancelGitHubImportAuthorization() async {
    githubImportAuthorizationTask?.cancel()
    _ = try? await githubImportAuthorizationTask?.value
    githubImportAuthorizationTask = nil
    githubImportDeviceAuthorizationPrompt = nil
    isLoadingGitHubImportRepositories = false
  }

  func selectLocalGitHubRepository(productID: UUID, repositoryID: Int64) async {
    githubRepositorySetupActivities.removeValue(forKey: productID)
    if let state = githubRemoteRepositoryStates[productID],
      let choice = state.repositories.first(where: { $0.id == repositoryID }),
      var connection = state.connection
    {
      connection.installationID = choice.installationID
      connection.repositoryID = choice.repository.id
      connection.owner = choice.repository.owner
      connection.name = choice.repository.name
      connection.fullName = choice.repository.fullName
      connection.canonicalHTTPSURL = choice.repository.canonicalHTTPSURL
      connection.isPrivate = choice.repository.isPrivate
      connection.defaultBranch = choice.repository.defaultBranch
      connection.permissions = choice.permissions
      githubRemoteRepositoryStates[productID] = GitHubRemoteRepositoryState(
        isConfigured: state.isConfigured,
        connection: connection,
        repositories: state.repositories,
        selectedEligibility: .checking,
        observation: state.observation,
        safeSync: state.safeSync,
        publications: state.publications
      )
    }
    await performGitHubAction(productID: productID) {
      try await $0.selectLocalRepository(
        productID: productID,
        repositoryID: repositoryID
      )
    }
  }

  func refreshGitHubRepositories(productID: UUID) async {
    await performGitHubAction(productID: productID) {
      try await $0.refreshRepositories(productID: productID)
    }
  }

  func resumeLocalGitHubRepositorySetup(productID: UUID) async {
    guard githubRemoteRepositoryStates[productID]?.connection?.status == .selectingRepository,
      let repositoryID = githubRemoteRepositoryStates[productID]?.connection?.repositoryID
    else { return }
    if githubRemoteRepositoryStates[productID]?.repositories.contains(
      where: { $0.id == repositoryID }
    ) != true {
      await refreshGitHubRepositories(productID: productID)
    }
    guard let currentState = githubRemoteRepositoryStates[productID],
      currentState.repositories.contains(where: { $0.id == repositoryID }),
      currentState.selectedEligibility == nil
        || currentState.selectedEligibility == .unchecked
    else { return }
    await selectLocalGitHubRepository(productID: productID, repositoryID: repositoryID)
  }

  func initializeLocalGitHubRepository(productID: UUID) async {
    let publishesExistingHistory =
      if case .empty(_, let existingHistory) =
        githubRemoteRepositoryStates[productID]?.selectedEligibility
      {
        existingHistory != nil
      } else {
        false
      }
    githubRepositorySetupActivities[productID] = .inProgress(
      progress: .validatingProduct,
      publishesExistingHistory: publishesExistingHistory
    )
    let onProgress: @Sendable (GitHubRemoteRepositoryInitializationProgress) async -> Void = {
      [weak self] progress in
      await self?.recordGitHubRepositorySetupProgress(
        productID: productID,
        progress: progress,
        publishesExistingHistory: publishesExistingHistory
      )
    }
    await performGitHubAction(productID: productID) {
      try await $0.initializeLocalRepository(
        productID: productID,
        onProgress: onProgress
      )
    }
    if githubRemoteRepositoryErrors[productID] == nil,
      githubRemoteRepositoryStates[productID]?.connection?.status == .connected
    {
      githubRepositorySetupActivities[productID] = .completed(
        publishedExistingHistory: publishesExistingHistory
      )
    } else {
      githubRepositorySetupActivities.removeValue(forKey: productID)
    }
  }

  private func recordGitHubRepositorySetupProgress(
    productID: UUID,
    progress: GitHubRemoteRepositoryInitializationProgress,
    publishesExistingHistory: Bool
  ) {
    githubRepositorySetupActivities[productID] = .inProgress(
      progress: progress,
      publishesExistingHistory: publishesExistingHistory
    )
  }

  func confirmRemoteRepositoryTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) async {
    await performGitHubAction(productID: productID) {
      try await $0.confirmTarget(
        productID: productID,
        expectedVersion: expectedVersion,
        pendingObservedAt: pendingObservedAt
      )
    }
  }

  func checkRemoteRepository(productID: UUID) async {
    await performGitHubAction(productID: productID) {
      try await $0.check(productID: productID)
    }
  }

  func prepareIncomingRepositoryChange(productID: UUID) async {
    guard !(await productHasActiveDelivery(productID: productID)) else {
      githubRemoteRepositoryErrors[productID] =
        "Incoming GitHub changes cannot be reviewed while delivery work is active. Finish or stop the current sprint, then check GitHub again."
      return
    }
    await performGitHubAction(productID: productID) {
      try await $0.prepareSafeSync(productID: productID)
    }
  }

  func acceptIncomingRepositoryChange(productID: UUID, syncID: UUID) async {
    guard !(await productHasActiveDelivery(productID: productID)) else {
      githubRemoteRepositoryErrors[productID] =
        "Incoming GitHub changes cannot be accepted while delivery work is active. Finish or stop the current sprint, then check GitHub again."
      return
    }
    await performGitHubAction(productID: productID) {
      try await $0.acceptSafeSync(syncID: syncID)
    }
  }

  func rejectIncomingRepositoryChange(productID: UUID, syncID: UUID) async {
    await performGitHubAction(productID: productID) {
      try await $0.rejectSafeSync(syncID: syncID)
    }
  }

  func prepareRemotePublication(productID: UUID) async {
    guard !(await productHasActiveDelivery(productID: productID)) else {
      githubRemoteRepositoryErrors[productID] =
        "Finish or stop the current sprint before preparing a pull request."
      return
    }
    await performGitHubAction(productID: productID) {
      try await $0.preparePublication(productID: productID)
    }
  }

  func cancelRemotePublication(productID: UUID, publicationID: UUID) async {
    await performGitHubAction(productID: productID) {
      try await $0.cancelPublication(id: publicationID)
    }
  }

  func publishRemoteChanges(
    productID: UUID,
    publicationID: UUID,
    title: String,
    body: String
  ) async {
    await performGitHubAction(productID: productID) {
      try await $0.confirmPublication(id: publicationID, title: title, body: body)
    }
  }

  func finishRemotePullRequest(
    productID: UUID,
    publicationID: UUID,
    title: String,
    body: String
  ) async {
    await performGitHubAction(productID: productID) {
      try await $0.finishPullRequest(id: publicationID, title: title, body: body)
    }
  }

  func refreshRemotePullRequest(productID: UUID, publicationID: UUID) async {
    await performGitHubAction(productID: productID) {
      try await $0.refreshPullRequest(publicationID: publicationID)
    }
  }

  func syncTicketPullRequest(
    productID: UUID,
    publicationID: UUID,
    showsProgress: Bool = true
  ) async {
    guard !isShuttingDown, let githubRemoteService else { return }
    if showsProgress {
      githubRemoteRepositoryBusyProductIDs.insert(productID)
    }
    defer {
      if showsProgress {
        githubRemoteRepositoryBusyProductIDs.remove(productID)
      }
    }
    if let existingTask = githubPullRequestSyncTasks[publicationID] {
      await existingTask.value
      return
    }
    githubRemoteRepositoryErrors[productID] = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await githubRemoteService.syncTicketPullRequest(
          publicationID: publicationID
        )
        githubRemoteRepositoryStates[productID] = result.state
        if result.changesRequested {
          await handleSprintOwnerComment(
            productID: productID,
            workItemID: result.workItemID,
            body: "Address the latest GitHub review feedback.",
            actor: "GitHub reviewer",
            reasonPrefix: "Review feedback"
          )
        } else if result.closedWithoutMerge {
          githubRemoteRepositoryErrors[productID] =
            "The pull request was closed on GitHub without being merged. Reopen it on GitHub to continue this ticket."
        }
      } catch is CancellationError {
        return
      } catch {
        githubRemoteRepositoryErrors[productID] = error.localizedDescription
        githubRemoteRepositoryStates[productID] = await githubRemoteService.state(
          productID: productID
        )
      }
    }
    githubPullRequestSyncTasks[publicationID] = task
    await task.value
    githubPullRequestSyncTasks[publicationID] = nil
  }

  func setGitHubReviewTicket(_ workItemID: UUID, isVisible: Bool) {
    if isVisible {
      visibleGitHubReviewWorkItemCounts[workItemID, default: 0] += 1
    } else if let count = visibleGitHubReviewWorkItemCounts[workItemID] {
      if count > 1 {
        visibleGitHubReviewWorkItemCounts[workItemID] = count - 1
      } else {
        visibleGitHubReviewWorkItemCounts[workItemID] = nil
      }
    }
  }

  private func prepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication? {
    guard let githubRemoteService else { return nil }
    let current = await githubRemoteService.state(productID: productID)
    guard current.connection?.status == .connected else { return nil }
    let state = try await githubRemoteService.prepareTicketPullRequest(
      productID: productID,
      workItemID: workItemID,
      candidateRevisionID: candidateRevisionID
    )
    githubRemoteRepositoryStates[productID] = state
    guard
      let publication = state.publications.first(where: {
        $0.workItemID == workItemID && $0.candidateRevisionID == candidateRevisionID
      })
    else {
      throw PersistenceError.corruptData(
        "GitHub did not preserve the ticket pull request."
      )
    }
    if let pullRequest = publication.pullRequest,
      let store = store(for: productID)
    {
      let message =
        "Created draft pull request #\(pullRequest.number) for candidate revision \(String(publication.capturedLocalSHA.prefix(8)))."
      let comments = try await store.fetchComments(workItemID: workItemID)
      if !comments.contains(where: { $0.body == message }) {
        _ = try await store.appendComment(
          workItemID: workItemID,
          authorKind: .system,
          authorName: "Spedito",
          body: message,
          externalURL: pullRequest.canonicalURL
        )
      }
    }
    return publication
  }

  private func markTicketPullRequestReadyIfNeeded(
    _ publication: RemotePublication?
  ) async throws {
    guard let publication,
      let githubRemoteService,
      publication.pullRequest?.isDraft == true
    else { return }
    let state = try await githubRemoteService.markTicketPullRequestReady(
      publicationID: publication.id
    )
    githubRemoteRepositoryStates[publication.productID] = state
  }

  func clearGitHubRemoteRepositoryError(productID: UUID) {
    githubRemoteRepositoryErrors[productID] = nil
  }

  private func performGitHubAction(
    productID: UUID,
    operation:
      @escaping @Sendable (
        any GitHubRemoteRepositoryServing
      ) async throws -> GitHubRemoteRepositoryState
  ) async {
    guard !isShuttingDown, let githubRemoteService else { return }
    guard products.contains(where: { $0.id == productID && $0.status == .active }) else {
      githubRemoteRepositoryErrors[productID] =
        "Restore this Product before resuming its GitHub repository work."
      return
    }
    while let existingTask = githubRemoteTasks[productID] {
      await existingTask.value
    }
    guard !isShuttingDown else { return }
    githubRemoteRepositoryBusyProductIDs.insert(productID)
    githubRemoteRepositoryErrors[productID] = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let state = try await operation(githubRemoteService)
        githubRemoteRepositoryStates[productID] = state
        githubRemoteRepositoryErrors[productID] = state.errorMessage
      } catch is CancellationError {
        githubRemoteRepositoryStates[productID] = await githubRemoteService.state(
          productID: productID
        )
      } catch {
        githubRemoteRepositoryErrors[productID] = error.localizedDescription
        githubRemoteRepositoryStates[productID] = await githubRemoteService.state(
          productID: productID
        )
      }
      githubRemoteRepositoryBusyProductIDs.remove(productID)
      githubRemoteTasks[productID] = nil
    }
    githubRemoteTasks[productID] = task
    await task.value
  }

  private func productHasActiveDelivery(productID: UUID) async -> Bool {
    guard let productStore = store(for: productID) else { return true }
    do {
      return try await productStore.fetchCurrentSprint(productID: productID)?
        .sprint.state.isInProgress == true
    } catch {
      githubRemoteRepositoryErrors[productID] =
        "Spedito could not verify whether delivery work is active. Try again."
      return true
    }
  }


  private func presentGitHubDeviceAuthorizationPrompt(
    _ prompt: GitHubDeviceAuthorizationPrompt,
    productID: UUID
  ) {
    guard !isShuttingDown else { return }
    githubDeviceAuthorizationPrompts[productID] = prompt
  }

  private func presentGitHubImportDeviceAuthorizationPrompt(
    _ prompt: GitHubDeviceAuthorizationPrompt
  ) {
    guard !isShuttingDown else { return }
    githubImportDeviceAuthorizationPrompt = prompt
  }

  private func scheduleGitHubRemoteRecovery(productIDs: [UUID]) {
    guard let githubRemoteService else { return }
    for productID in productIDs where githubRemoteTasks[productID] == nil {
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        await githubRemoteService.recover(productID: productID)
        let state = await githubRemoteService.state(productID: productID)
        githubRemoteRepositoryStates[productID] = state
        githubRemoteRepositoryErrors[productID] = state.errorMessage
        githubRemoteTasks[productID] = nil
      }
      githubRemoteTasks[productID] = task
    }
  }
  private func scheduleGitHubPullRequestPolling() {
    githubPullRequestPollingTask?.cancel()
    guard let productID = selectedProductID else {
      githubPullRequestPollingTask = nil
      return
    }
    githubPullRequestPollingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, selectedProductID == productID else { return }
        await pollGitHubPullRequestsOnce(productID: productID)
        guard !Task.isCancelled, selectedProductID == productID else { return }
        let visibleWorkItemIDs = Set(visibleGitHubReviewWorkItemCounts.keys)
        let publications = GitHubPullRequestPollingPolicy.orderedPublications(
          githubRemoteRepositoryStates[productID]?.publications ?? [],
          workItems: workItems,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        let interval = GitHubPullRequestPollingPolicy.interval(
          isApplicationActive: NSApplication.shared.isActive,
          publications: publications,
          workItems: workItems,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
      }
    }
  }

  func pollGitHubPullRequestsOnce(productID: UUID) async {
    guard !isShuttingDown, selectedProductID == productID else { return }
    let publications = GitHubPullRequestPollingPolicy.orderedPublications(
      githubRemoteRepositoryStates[productID]?.publications ?? [],
      workItems: workItems,
      visibleWorkItemIDs: Set(visibleGitHubReviewWorkItemCounts.keys)
    )
    for publication in publications {
      guard !Task.isCancelled, selectedProductID == productID else { return }
      await syncTicketPullRequest(
        productID: productID,
        publicationID: publication.id,
        showsProgress: false
      )
    }
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
      return
        "Review the current \(pendingSuggestionCount) suggestion\(pendingSuggestionCount == 1 ? "" : "s") before asking for another analysis."
    }
    if isPlanningMessageRunning {
      return "A team member is replying in sprint planning."
    }
    if isTicketConversationMessageRunning {
      return "A team member is replying in a ticket conversation."
    }
    if isEpicConversationMessageRunning {
      return "A team member is replying in an epic conversation."
    }
    if refiningWorkItemID != nil {
      return "The business analyst is reviewing a ticket."
    }
    switch codexConnectionState {
    case .connected:
      return "The business analyst is already preparing suggestions."
    default:
      return "Ticket suggestions require the Codex team connection."
    }
  }

  func load() async {
    guard !didLoad else { return }
    didLoad = true
    do {
      try await storeRegistry?.prepare()
      try productRepositoryImporter?.prepare()
      let stores = storeRegistry?.allStores ?? injectedStore.map { [$0] } ?? []
      try GitWorkspaceManager.cleanupRepositoryAnalysisSnapshots(
        rootURL: try Self.repositoryAnalysisRootURL()
      )
      for productStore in stores {
        try await productStore.interruptPendingAgentPermissionRequests()
        try await productStore.interruptWorkingConversationThreads()
        try await productStore.requeueGeneratingRetrospectiveSyntheses()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
    await recoverInterruptedTicketAcceptances()
    scheduleGitHubRemoteRecovery(productIDs: products.map(\.id))
    for product in products {
      if let workspace = try? repositoryWorkspaceURL(productID: product.id) {
        try? await gitWorkspaceManager.ensureControlDirectoryExcluded(at: workspace)
      }
    }
    await recoverDemoSessions()
    await connectCodex()
    await recoverTicketSuggestionSessionIfNeeded()
    scheduleRetrospectiveSyntheses()
    scheduleRepositoryKnowledgeRuns()
    scheduleSprintExecutions()
  }

  func createProductAndSelect(_ request: ProductCreationRequest) async -> Bool {
    productCreationError = nil
    errorMessage = nil
    let trimmedName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      productCreationError = ProductRepositoryImportError.missingName.localizedDescription
      return false
    }
    do {
      let product: Product
      switch request {
      case .blank:
        product = try await createBlankProduct(name: trimmedName)
      case .importRepository(_, let source):
        guard productImportTask == nil, let productRepositoryImporter else {
          return false
        }
        let task = Task {
          try await productRepositoryImporter.importProduct(
            name: trimmedName,
            from: source
          )
        }
        productImportTask = task
        do {
          product = try await task.value.product
          productImportTask = nil
        } catch {
          productImportTask = nil
          throw error
        }
      case .importGitHubRepository(_, let repositoryID):
        guard productImportTask == nil,
          let productRepositoryImporter,
          let githubRemoteService
        else {
          return false
        }
        let task = Task {
          try await githubRemoteService.importProduct(
            name: trimmedName,
            repositoryID: repositoryID
          ) { source, credential in
            try await productRepositoryImporter.importProduct(
              name: trimmedName,
              from: source,
              credentialConfiguration: credential
            )
          }
        }
        productImportTask = task
        do {
          product = try await task.value.product
          productImportTask = nil
        } catch ProductRepositoryImportError.emptyDefaultBranch {
          productImportTask = nil
          product = try await createBlankProduct(name: trimmedName)
          do {
            let state = try await githubRemoteService.connectLocalProduct(
              productID: product.id,
              repositoryID: repositoryID
            )
            githubRemoteRepositoryStates[product.id] = state
            githubRemoteRepositoryErrors[product.id] = state.errorMessage
          } catch {
            let message =
              "The Product was created, but its GitHub repository connection needs attention. \(error.localizedDescription)"
            githubRemoteRepositoryErrors[product.id] = message
            errorMessage = message
          }
        } catch {
          productImportTask = nil
          throw error
        }
      }
      products = try await fetchProducts()
      archivedProducts = try await fetchProducts(status: .archived)
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      selectedProductID = product.id
      rememberSelectedProduct(product.id)
      await reloadSelectedProduct()
      scheduleGitHubPullRequestPolling()
      scheduleRepositoryKnowledgeRuns()
      return true
    } catch is CancellationError {
      return false
    } catch {
      productCreationError = error.localizedDescription
      return false
    }
  }

  private func createBlankProduct(name: String) async throws -> Product {
    let product: Product
    let productStore: SQLiteStore
    let workspace: URL
    if let storeRegistry {
      product = try await storeRegistry.createProduct(name: name)
      guard let createdStore = storeRegistry.store(for: product.id) else {
        throw PersistenceError.recordNotFound("product database \(product.id)")
      }
      productStore = createdStore
      workspace = storeRegistry.productWorkspacesRootURL.appendingPathComponent(
        product.id.uuidString,
        isDirectory: true
      )
    } else if let injectedStore {
      product = try await injectedStore.createProduct(name: name)
      productStore = injectedStore
      workspace = try Self.productWorkspaceURL(productID: product.id)
    } else {
      throw PersistenceError.recordNotFound("Product database")
    }
    _ = try await productStore.seedDefaultProfiles(productID: product.id)
    _ = try await productStore.seedKnowledgeBase(productID: product.id)
    _ = try await gitWorkspaceManager.ensureRepository(at: workspace)
    return product
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
    scheduleGitHubPullRequestPolling()
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

    let acceptingWorkItemIDs = Set(
      workItems
        .filter { $0.productID == product.id }
        .map(\.id)
    ).intersection(ticketAcceptanceInProgressWorkItemIDs)
    guard acceptingWorkItemIDs.isEmpty else {
      errorMessage =
        "A ticket is currently being completed. Wait for it to reach a recoverable result before archiving this Product."
      return false
    }
    guard githubRemoteTasks[product.id] == nil else {
      errorMessage =
        "GitHub repository work is currently active. Wait for it to finish before archiving this Product."
      return false
    }
    if let githubRemoteService {
      let remoteState = await githubRemoteService.state(productID: product.id)
      if let reason = remoteProductArchivePolicy.blockingReason(for: remoteState) {
        errorMessage = reason
        return false
      }
      let pullRequestPollingTask = githubPullRequestPollingTask
      pullRequestPollingTask?.cancel()
      await pullRequestPollingTask?.value
      githubPullRequestPollingTask = nil
      let pullRequestPublicationIDs = remoteState.publications.map(\.id)
      let pullRequestTasks = pullRequestPublicationIDs.compactMap {
        githubPullRequestSyncTasks[$0]
      }
      pullRequestTasks.forEach { $0.cancel() }
      for task in pullRequestTasks {
        await task.value
      }
      for publicationID in pullRequestPublicationIDs {
        githubPullRequestSyncTasks[publicationID] = nil
      }
      let settledState = await githubRemoteService.state(productID: product.id)
      if let reason = remoteProductArchivePolicy.blockingReason(for: settledState) {
        errorMessage = reason
        scheduleGitHubPullRequestPolling()
        return false
      }
      githubDeviceAuthorizationPrompts.removeValue(forKey: product.id)
      githubRepositorySetupActivities.removeValue(forKey: product.id)
      githubRemoteRepositoryBusyProductIDs.remove(product.id)
    }

    await stopDemoSessions(productID: product.id, includesPreparation: true)
    await cancelRepositoryKnowledge(productID: product.id)
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
      products = try await fetchProducts()
      archivedProducts = try await fetchProducts(status: .archived)
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      selectedProductID = products.first?.id
      if let selectedProductID {
        rememberSelectedProduct(selectedProductID)
      } else {
        forgetSelectedProduct()
      }
      await reloadSelectedProduct()
      scheduleGitHubPullRequestPolling()
      await recoverTicketSuggestionSessionIfNeeded()
      scheduleSprintExecution()
      return true
    } catch {
      errorMessage = error.localizedDescription
      scheduleGitHubPullRequestPolling()
      scheduleSprintExecution(productID: product.id)
      return false
    }
  }

  func restoreProductAndSelect(_ product: Product) async -> Bool {
    guard product.status == .archived else { return false }
    do {
      if let storeRegistry {
        _ = try await storeRegistry.restoreProduct(id: product.id)
      } else if let store = store(for: product.id) {
        _ = try await store.restoreProduct(id: product.id)
      } else {
        return false
      }
      products = try await fetchProducts()
      archivedProducts = try await fetchProducts(status: .archived)
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      guard let restored = products.first(where: { $0.id == product.id }) else {
        throw PersistenceError.recordNotFound("restored product \(product.id)")
      }
      await selectProduct(restored)
      scheduleGitHubRemoteRecovery(productIDs: [restored.id])
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
      await reloadSelectedProductIfCurrent(productID: productID)
      return item
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func createEpic(outcome: String) async -> Epic? {
    guard let store, let productID = selectedProductID else { return nil }
    do {
      let epic = try await store.createEpic(productID: productID, outcome: outcome)
      await reloadSelectedProductIfCurrent(productID: productID)
      if selectedProductID == productID {
        backlogFocusEpicID = epic.id
      }
      return epic
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
    guard let store = store(for: epic.productID) else { return nil }
    do {
      let updated = try await store.updateEpic(
        id: epic.id,
        title: title,
        goal: goal,
        successCriteria: successCriteria,
        constraints: constraints
      )
      await reloadSelectedProductIfCurrent(productID: epic.productID)
      return updated
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func closeEpic(_ epic: Epic) async -> Epic? {
    guard let store = store(for: epic.productID) else { return nil }
    do {
      let closed = try await store.closeEpic(id: epic.id)
      await reloadSelectedProductIfCurrent(productID: epic.productID)
      return closed
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func reopenEpic(_ epic: Epic) async -> Epic? {
    guard let store = store(for: epic.productID) else { return nil }
    do {
      let reopened = try await store.reopenEpic(id: epic.id)
      await reloadSelectedProductIfCurrent(productID: epic.productID)
      return reopened
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func moveEpics(_ epics: [Epic], before targetID: UUID?) {
    guard
      let productID = epics.first?.productID,
      epics.allSatisfy({ $0.productID == productID }),
      let store = store(for: productID)
    else { return }
    Task {
      do {
        let movedEpics = try await store.moveEpics(
          ids: epics.map(\.id),
          before: targetID
        )
        if selectedProductID == productID {
          self.epics = movedEpics
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func archiveEpic(_ epic: Epic) {
    guard let store = store(for: epic.productID) else { return }
    Task {
      do {
        try await store.archiveEpic(id: epic.id)
        if backlogFocusEpicID == epic.id {
          backlogFocusEpicID = nil
        }
        await reloadSelectedProductIfCurrent(productID: epic.productID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func assignWorkItem(_ item: WorkItem, to epicID: UUID?) async {
    guard let store = store(for: item.productID) else { return }
    do {
      _ = try await store.assignWorkItemToEpic(id: item.id, epicID: epicID)
      await reloadSelectedProductIfCurrent(productID: item.productID)
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
      let activeItems = try await store.fetchWorkItems(productID: product.id)
        .filter { $0.state != .cancelled }
      let activeItemIDs = Set(activeItems.map(\.id))
      let activeDependencies = try await store.fetchWorkItemDependencies(
        productID: product.id
      ).filter {
        activeItemIDs.contains($0.workItemID)
          && activeItemIDs.contains($0.dependsOnWorkItemID)
      }
      let productEpics = try await store.fetchEpics(productID: product.id)
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workingDirectory,
        developerInstructions: CodexTicketRefinementGenerator.developerInstructions(
          productInstructions: inheritedAgentInstructions(for: product),
          customInstructions: analyst.customInstructionText
        ),
        model: analyst.model
      )
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketRefinementGenerator.prompt(
          product: product,
          item: item,
          epic: item.epicID.flatMap { epicID in
            productEpics.first { $0.id == epicID }
          },
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
      if reply.proposal.missingQuestions.isEmpty {
        _ = try await applyCompletedTicketRefinement(reply.proposal, to: item)
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: analyst.name,
          body: reply.ticketCommentBody
        )
      } else {
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: analyst.name,
          body: reply.ticketCommentBody
        )
      }
      if selectedProductID == product.id,
        let latestActivity = try? await store.fetchActivity(productID: product.id)
      {
        activity = latestActivity
      }
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
        authorName: "Spedito",
        body: "The business analyst couldn't refine this ticket: \(error.localizedDescription)"
      )
      ticketRefinementResults[item.id] = TicketRefinementSessionResult(
        base: refinementBase,
        reply: nil,
        errorMessage: error.localizedDescription
      )
      throw error
    }
  }

  @discardableResult
  func applyCompletedTicketRefinement(
    _ proposal: TicketRefinementProposal,
    to item: WorkItem
  ) async throws -> WorkItem {
    guard proposal.missingQuestions.isEmpty else {
      throw TicketRefinementGenerationError.invalidResponse(
        "The ticket cannot be updated while product owner questions remain."
      )
    }
    guard let store = store(for: item.productID) else {
      throw PersistenceError.recordNotFound("Spedito database")
    }

    let activeItems = try await store.fetchWorkItems(productID: item.productID)
      .filter { $0.state != .cancelled }
    let productDependencies = try await store.fetchWorkItemDependencies(
      productID: item.productID
    )
    let productProfiles = try await store.fetchAgentProfiles(productID: item.productID)
    let activeItemIDs = Set(activeItems.map(\.id))
    let activeItemsByKey = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.key, $0) })
    let suggestedDependencyIDs = try Set(
      proposal.dependencies.map { dependency in
        guard
          let relatedItem = activeItemsByKey[dependency.ticketKey],
          relatedItem.id != item.id
        else {
          throw TicketRefinementGenerationError.invalidResponse(
            "The suggested dependency \(dependency.ticketKey) is not active."
          )
        }
        return relatedItem.id
      }
    )
    let existingDependencyIDs = Set(
      productDependencies
        .filter {
          $0.workItemID == item.id
            && activeItemIDs.contains($0.dependsOnWorkItemID)
        }
        .map(\.dependsOnWorkItemID)
    )

    var updated = try await store.updateWorkItem(
      id: item.id,
      title: proposal.title,
      type: proposal.type,
      body: proposal.body,
      acceptanceCriteria: proposal.acceptanceCriteria,
      priority: proposal.priority,
      customFields: item.customFields,
      dependsOnWorkItemIDs: existingDependencyIDs.union(suggestedDependencyIDs),
      expectedVersion: proposal.baseVersion
    )
    let currentPlan = try await store.fetchCurrentSprint(productID: item.productID)
    let draftPlan = currentPlan?.sprint.state == .draft ? currentPlan : nil
    let draftItem = draftPlan?.items.first { $0.workItemID == item.id }
    if updated.ownerProfileID == nil,
      draftItem?.implementerProfileID == nil,
      let owner = TicketOwnerRouter.owner(
        for: updated,
        profiles: productProfiles,
        suggestedRole: proposal.suggestedRole
      )
    {
      updated = try await store.assignWorkItemOwner(
        id: updated.id,
        profileID: owner.id
      )
      if let draftPlan, draftItem != nil {
        _ = try await store.saveDraftSprint(
          productID: updated.productID,
          goal: draftPlan.sprint.goal,
          tokenBudgetLimit: draftPlan.sprint.tokenBudgetLimit,
          items: draftPlan.items.map { sprintItem in
            SprintDraftItemInput(
              workItemID: sprintItem.workItemID,
              implementerProfileID: sprintItem.workItemID == updated.id
                ? owner.id
                : sprintItem.implementerProfileID,
              reviewerProfileID: sprintItem.reviewerProfileID,
              estimatedTokens: sprintItem.estimatedTokens
            )
          }
        )
      }
    }
    await reloadSelectedProductIfCurrent(productID: item.productID)
    return updated
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
      stopTicketConversationActivityMonitoring()
      isTicketConversationMessageRunning = false
      ticketConversationWorkItemID = nil
      ticketConversationRecipientID = nil
      activeTicketConversationTurn = nil
    }

    let comments = try await store.fetchComments(workItemID: item.id)
    let currentMessageBody = "@\(recipient.name) \(trimmedMessage)"
    let priorComments =
      comments.last?.authorKind == .owner
        && comments.last?.body == currentMessageBody
      ? Array(comments.dropLast())
      : comments
    let productItems = try await store.fetchWorkItems(productID: product.id)
    let activeItemIDs = Set(productItems.filter { $0.state != .cancelled }.map(\.id))
    let productDependencies = try await store.fetchWorkItemDependencies(
      productID: product.id
    )
    let prerequisiteIDs = Set(
      productDependencies
        .filter {
          $0.workItemID == item.id
            && activeItemIDs.contains($0.dependsOnWorkItemID)
        }
        .map(\.dependsOnWorkItemID)
    )
    let prerequisites = productItems.filter { prerequisiteIDs.contains($0.id) }
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
            customInstructions: recipient.customInstructionText,
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
      monitorTicketConversationActivity(
        client: client,
        threadID: threadID
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let generatedReply = try CodexTicketConversation.decode(
        response,
        currentItem: item
      )
      let reply =
        allowsProposal
        ? generatedReply
        : TicketConversationReply(message: generatedReply.message)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: recipient.name,
        body: reply.ticketCommentBody
      )
      if selectedProductID == product.id {
        activity = try await store.fetchActivity(productID: product.id)
      }
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
        authorName: "Spedito",
        body: "\(recipient.name) couldn't reply: \(error.localizedDescription)"
      )
      throw error
    }
  }

  func cancelTicketConversationMessage() {
    guard let client = codexClient, let activeTicketConversationTurn else { return }
    ticketConversationActivity = CodexLiveActivity(
      text: "Stopping this response…",
      kind: .thinking
    )
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
    ensureEpicConversationState(for: epic)
    updateEpicPlanningConversation(for: epic.id) {
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
            customInstructions: recipient.customInstructionText,
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
      updateEpicPlanningConversation(for: epic.id) {
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
      updateEpicPlanningConversation(for: epic.id) {
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

  private func ensureEpicConversationState(for epic: Epic) {
    guard epicPlanningConversation?.epicID != epic.id else { return }
    guard
      epicPlanningConversation?.isRunning != true,
      epicPlanningConversation?.isGeneratingPlan != true
    else { return }
    epicPlanningThreadID = nil
    epicPlanningConversation = EpicPlanningConversationState(
      productID: epic.productID,
      epicID: epic.id,
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
    guard let store = store(for: workItem.productID) else { return }
    Task {
      do {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: state,
          actor: "Product owner",
          reason: "Advanced from the board"
        )
        await reloadSelectedProductIfCurrent(productID: workItem.productID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateWorkItem(
    productID: UUID,
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
    guard let store = store(for: productID) else { return false }
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
      await reloadSelectedProductIfCurrent(productID: productID)
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
    guard
      let productID = selectedItems.first?.productID,
      selectedItems.allSatisfy({ $0.productID == productID }),
      let store = store(for: productID)
    else { return }
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
        let movedItems = try await store.moveWorkItems(
          ids: orderedItems.map(\.id),
          before: targetID
        )
        if selectedProductID == productID {
          workItems = movedItems
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
    guard
      let productID = selectedItems.first?.productID,
      selectedItems.allSatisfy({ $0.productID == productID }),
      let store = store(for: productID)
    else { return }
    let selectedIDs = Set(selectedItems.map(\.id))
    guard !selectedIDs.isEmpty else { return }
    Task {
      do {
        try await store.archiveWorkItems(ids: Array(selectedIDs))
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func comments(
    for workItemID: UUID,
    productID: UUID? = nil
  ) async -> [TicketComment] {
    let targetStore = productID.flatMap { store(for: $0) } ?? store
    guard let targetStore else { return [] }
    do {
      return try await targetStore.fetchComments(workItemID: workItemID)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func activityEvents(
    for workItemID: UUID,
    productID: UUID? = nil
  ) async -> [ActivityEvent] {
    let targetStore = productID.flatMap { store(for: $0) } ?? store
    guard let targetStore else { return [] }
    do {
      return try await targetStore.fetchActivity(workItemID: workItemID)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func markKnowledgePageRead(_ page: KnowledgePage) {
    guard
      selectedProductID == page.productID,
      knowledgePages.contains(where: { $0.id == page.id })
    else { return }
    knowledgePageReadState.markRead(page)
    unreadKnowledgePageIDs = knowledgePageReadState.unreadPageIDs(in: knowledgePages)
  }

  func knowledgeRevisions(
    productID: UUID,
    for pageID: UUID
  ) async -> [KnowledgePageRevision] {
    guard let store = store(for: productID) else { return [] }
    do {
      return try await store.fetchKnowledgePageRevisions(pageID: pageID)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func saveKnowledgePage(
    productID: UUID,
    id: UUID,
    title: String,
    bodyMarkdown: String,
    changeSummary: String
  ) async -> Bool {
    guard let store = store(for: productID) else { return false }
    do {
      _ = try await store.updateKnowledgePage(
        id: id,
        title: title,
        bodyMarkdown: bodyMarkdown,
        authorName: "Me",
        changeSummary: changeSummary
      )
      await reloadSelectedProductIfCurrent(productID: productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func createKnowledgePage(
    productID: UUID,
    parentID: UUID?,
    title: String
  ) async -> KnowledgePage? {
    guard let store = store(for: productID) else { return nil }
    do {
      let page = try await store.createKnowledgePage(
        productID: productID,
        parentID: parentID,
        title: title
      )
      await reloadSelectedProductIfCurrent(productID: productID)
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

  @discardableResult
  func sendProductConversationMessage(
    threadID: UUID?,
    recipientID: UUID,
    body: String
  ) async -> UUID? {
    let messageBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !messageBody.isEmpty,
      let product = selectedProduct,
      let recipient = profiles.first(where: {
        $0.id == recipientID && $0.productID == product.id
      }),
      let store = store(for: product.id),
      let client = codexClient,
      case .connected = codexConnectionState
    else { return nil }

    let thread: ProductConversationThread
    let turnPrompt: String
    let provisionalSubject: String?
    do {
      if let threadID {
        provisionalSubject = nil
        guard
          let existingThread = conversationThreads.first(where: {
            $0.id == threadID && $0.productID == product.id
          }),
          !existingThread.isArchived
        else {
          throw PersistenceError.recordNotFound("Conversation thread \(threadID)")
        }
        let switchesRecipient = existingThread.recipientProfileID != recipient.id
        let ownerMessage = ProductConversationMessage(
          threadID: threadID,
          authorKind: .owner,
          authorName: "Me",
          body: messageBody
        )
        thread = try await store.appendConversationMessage(
          ownerMessage,
          threadStatus: .working,
          threadRecipientProfileID: switchesRecipient ? recipient.id : nil,
          resetsCodexThread: switchesRecipient
        )
        if switchesRecipient {
          turnPrompt = CodexProductConversation.handoffPrompt(
            messages: try await store.fetchConversationMessages(threadID: threadID)
          )
        } else if existingThread.codexThreadID == nil {
          turnPrompt = CodexProductConversation.recoveryPrompt(
            messages: try await store.fetchConversationMessages(threadID: threadID)
          )
        } else {
          turnPrompt = CodexProductConversation.resumedThreadPrompt(
            ownerMessage: messageBody
          )
        }
      } else {
        let recentMessages = try await store.fetchRecentConversationMessages(
          productID: product.id,
          limit: 100
        )
        let now = Date()
        let createdThread = ProductConversationThread(
          productID: product.id,
          recipientProfileID: recipient.id,
          subject: Self.conversationSubject(from: messageBody),
          createdAt: now,
          updatedAt: now
        )
        provisionalSubject = createdThread.subject
        let ownerMessage = ProductConversationMessage(
          threadID: createdThread.id,
          authorKind: .owner,
          authorName: "Me",
          body: messageBody,
          createdAt: now
        )
        thread = try await store.createConversationThread(
          createdThread,
          initialMessage: ownerMessage
        )
        turnPrompt = CodexProductConversation.newThreadPrompt(
          ownerMessage: messageBody,
          recentRoomMessages: recentMessages
        )
      }
      try await reloadProductConversations(productID: product.id, store: store)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }

    respondingConversationThreadIDs.insert(thread.id)
    conversationErrorsByThread.removeValue(forKey: thread.id)
    defer {
      stopProductConversationActivityMonitoring(threadID: thread.id)
      respondingConversationThreadIDs.remove(thread.id)
      activeProductConversationTurns.removeValue(forKey: thread.id)
    }

    do {
      let workspace = try Self.productWorkspaceURL(productID: product.id)
      if let provisionalSubject {
        startProductConversationTitleGeneration(
          conversationThreadID: thread.id,
          productID: product.id,
          ownerMessage: messageBody,
          provisionalSubject: provisionalSubject,
          recipient: recipient,
          store: store,
          client: client,
          workspace: workspace
        )
      }
      let developerInstructions = CodexProductConversation.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product),
        customInstructions: recipient.customInstructionText,
        recipient: recipient
      )

      var codexThreadID: String
      var prompt = turnPrompt
      if let existingCodexThreadID = thread.codexThreadID {
        do {
          codexThreadID = try await client.resumeReadOnlyThread(
            threadID: existingCodexThreadID,
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: recipient.model
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          codexThreadID = try await client.startReadOnlyThread(
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: recipient.model
          )
          prompt = CodexProductConversation.recoveryPrompt(
            messages: try await store.fetchConversationMessages(threadID: thread.id)
          )
        }
      } else {
        codexThreadID = try await client.startReadOnlyThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: recipient.model
        )
      }
      _ = try await store.updateConversationThread(
        id: thread.id,
        status: .working,
        codexThreadID: codexThreadID
      )
      if cancelledProductConversationThreadIDs.contains(thread.id) {
        throw CancellationError()
      }
      let turnID = try await client.startTurn(
        threadID: codexThreadID,
        prompt: prompt,
        effort: recipient.reasoningEffort
      )
      activeProductConversationTurns[thread.id] = ActiveProductConversationTurn(
        productID: product.id,
        threadID: codexThreadID,
        turnID: turnID
      )
      monitorProductConversationActivity(
        threadID: thread.id,
        client: client,
        codexThreadID: codexThreadID
      )
      if cancelledProductConversationThreadIDs.contains(thread.id) {
        try? await client.interruptTurn(
          threadID: codexThreadID,
          turnID: turnID
        )
        throw CancellationError()
      }
      let response = try await client.waitForFinalAgentMessage(
        threadID: codexThreadID,
        turnID: turnID,
        timeout: .seconds(300)
      )
      let reply = try CodexProductConversation.decodeMessage(response)
      cancelledProductConversationThreadIDs.remove(thread.id)
      _ = try await store.appendConversationMessage(
        ProductConversationMessage(
          threadID: thread.id,
          authorKind: .agent,
          authorName: recipient.name,
          body: reply
        ),
        threadStatus: .complete
      )
      try await reloadProductConversations(productID: product.id, store: store)
      return thread.id
    } catch is CancellationError {
      cancelledProductConversationThreadIDs.remove(thread.id)
      _ = try? await store.updateConversationThread(
        id: thread.id,
        status: .cancelled
      )
      try? await reloadProductConversations(productID: product.id, store: store)
      return thread.id
    } catch {
      let wasCancelled =
        cancelledProductConversationThreadIDs.remove(thread.id) != nil
        || isShuttingDown
      _ = try? await store.updateConversationThread(
        id: thread.id,
        status: wasCancelled ? .cancelled : .failed
      )
      if wasCancelled {
        conversationErrorsByThread.removeValue(forKey: thread.id)
      } else {
        conversationErrorsByThread[thread.id] = error.localizedDescription
      }
      try? await reloadProductConversations(productID: product.id, store: store)
      return thread.id
    }
  }

  private func startProductConversationTitleGeneration(
    conversationThreadID: UUID,
    productID: UUID,
    ownerMessage: String,
    provisionalSubject: String,
    recipient: AgentProfile,
    store: SQLiteStore,
    client: CodexAppServerClient,
    workspace: URL
  ) {
    let supportedEfforts =
      modelOption(for: recipient)?
      .supportedReasoningEfforts
      .map(\.id) ?? []
    let reasoningEffort = CodexSprintGoalGenerator.lightestReasoningEffort(
      supportedEfforts: supportedEfforts,
      fallback: recipient.reasoningEffort
    )
    productConversationTitleTasks[conversationThreadID] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.productConversationTitleTasks.removeValue(forKey: conversationThreadID)
      }
      await self.generateProductConversationTitle(
        conversationThreadID: conversationThreadID,
        productID: productID,
        ownerMessage: ownerMessage,
        provisionalSubject: provisionalSubject,
        recipient: recipient,
        reasoningEffort: reasoningEffort,
        store: store,
        client: client,
        workspace: workspace
      )
    }
  }

  private func generateProductConversationTitle(
    conversationThreadID: UUID,
    productID: UUID,
    ownerMessage: String,
    provisionalSubject: String,
    recipient: AgentProfile,
    reasoningEffort: String,
    store: SQLiteStore,
    client: CodexAppServerClient,
    workspace: URL
  ) async {
    let deadline = ContinuousClock.now + CodexProductConversation.titleGenerationTimeout
    var activeTurn: ActiveProductConversationTurn?
    defer {
      activeProductConversationTitleTurns.removeValue(forKey: conversationThreadID)
    }
    do {
      let codexThreadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexProductConversation.titleDeveloperInstructions,
        model: recipient.model,
        ephemeral: true,
        responseTimeout: try remainingProductConversationTitleGenerationTime(until: deadline)
      )
      try Task.checkCancellation()
      let turnID = try await client.startStructuredTurn(
        threadID: codexThreadID,
        prompt: CodexProductConversation.titlePrompt(ownerMessage: ownerMessage),
        effort: reasoningEffort,
        outputSchema: CodexProductConversation.titleOutputSchema,
        responseTimeout: try remainingProductConversationTitleGenerationTime(until: deadline)
      )
      let turn = ActiveProductConversationTurn(
        productID: productID,
        threadID: codexThreadID,
        turnID: turnID
      )
      activeTurn = turn
      activeProductConversationTitleTurns[conversationThreadID] = turn
      let response = try await client.waitForFinalAgentMessage(
        threadID: codexThreadID,
        turnID: turnID,
        timeout: CodexProductConversation.titleGenerationTimeout,
        totalTimeout: try remainingProductConversationTitleGenerationTime(until: deadline)
      )
      try Task.checkCancellation()
      let title = try CodexProductConversation.decodeTitle(response)
      _ = try await store.updateConversationThreadSubject(
        id: conversationThreadID,
        subject: title,
        replacing: provisionalSubject
      )
      if selectedProductID == productID {
        try await reloadProductConversations(productID: productID, store: store)
      }
    } catch {
      if let activeTurn {
        try? await client.interruptTurn(
          threadID: activeTurn.threadID,
          turnID: activeTurn.turnID
        )
      }
    }
  }

  private func remainingProductConversationTitleGenerationTime(
    until deadline: ContinuousClock.Instant
  ) throws -> Duration {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw CancellationError() }
    return remaining
  }

  func cancelProductConversation(threadID: UUID) {
    guard respondingConversationThreadIDs.contains(threadID) else { return }
    cancelledProductConversationThreadIDs.insert(threadID)
    productConversationActivities[threadID] = CodexLiveActivity(
      text: "Stopping this response…",
      kind: .thinking
    )
    guard
      let client = codexClient,
      let turn = activeProductConversationTurns[threadID]
    else { return }
    Task {
      try? await client.interruptTurn(
        threadID: turn.threadID,
        turnID: turn.turnID
      )
    }
  }

  @discardableResult
  func archiveProductConversation(threadID: UUID) async -> Bool {
    guard
      !respondingConversationThreadIDs.contains(threadID),
      let product = selectedProduct,
      let thread = conversationThreads.first(where: {
        $0.id == threadID && $0.productID == product.id
      }),
      !thread.isArchived,
      let store = store(for: product.id)
    else { return false }

    do {
      _ = try await store.archiveConversationThread(id: threadID)
      conversationErrorsByThread.removeValue(forKey: threadID)
      try await reloadProductConversations(productID: product.id, store: store)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func restoreProductConversation(threadID: UUID) async -> Bool {
    guard
      let product = selectedProduct,
      let thread = conversationThreads.first(where: {
        $0.id == threadID && $0.productID == product.id
      }),
      thread.isArchived,
      let store = store(for: product.id)
    else { return false }

    do {
      _ = try await store.restoreConversationThread(id: threadID)
      try await reloadProductConversations(productID: product.id, store: store)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func monitorProductConversationActivity(
    threadID: UUID,
    client: CodexAppServerClient,
    codexThreadID: String
  ) {
    stopProductConversationActivityMonitoring(threadID: threadID)
    let monitorID = UUID()
    productConversationActivityMonitorIDs[threadID] = monitorID
    productConversationActivities[threadID] = CodexLiveActivity(
      text: "Thinking through your question…",
      kind: .thinking
    )

    productConversationActivityTasks[threadID] = Task { [weak self] in
      guard let self else { return }
      var accumulator = CodexLiveActivityAccumulator()
      let messages = await client.inboundMessages(replayRecent: false)
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard
          notification.params["threadId"]?.stringValue == codexThreadID,
          self.productConversationActivityMonitorIDs[threadID] == monitorID
        else { continue }

        switch accumulator.consume(notification) {
        case .activity(let activity):
          self.productConversationActivities[threadID] = activity
        case .turnFinished:
          self.stopProductConversationActivityMonitoring(threadID: threadID)
          return
        case nil:
          continue
        }
      }

      guard self.productConversationActivityMonitorIDs[threadID] == monitorID
      else { return }
      self.stopProductConversationActivityMonitoring(threadID: threadID)
    }
  }

  private func stopProductConversationActivityMonitoring(threadID: UUID) {
    productConversationActivityTasks.removeValue(forKey: threadID)?.cancel()
    productConversationActivityMonitorIDs.removeValue(forKey: threadID)
    productConversationActivities.removeValue(forKey: threadID)
  }

  private func monitorTicketConversationActivity(
    client: CodexAppServerClient,
    threadID: String
  ) {
    stopTicketConversationActivityMonitoring()
    let monitorID = UUID()
    ticketConversationActivityMonitorID = monitorID
    ticketConversationActivity = CodexLiveActivity(
      text: "Thinking through your question…",
      kind: .thinking
    )

    ticketConversationActivityTask = Task { [weak self] in
      guard let self else { return }
      var accumulator = CodexLiveActivityAccumulator()
      let messages = await client.inboundMessages(replayRecent: false)
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard
          notification.params["threadId"]?.stringValue == threadID,
          self.ticketConversationActivityMonitorID == monitorID
        else { continue }

        switch accumulator.consume(notification) {
        case .activity(let activity):
          self.ticketConversationActivity = activity
        case .turnFinished:
          self.stopTicketConversationActivityMonitoring()
          return
        case nil:
          continue
        }
      }

      guard self.ticketConversationActivityMonitorID == monitorID else { return }
      self.stopTicketConversationActivityMonitoring()
    }
  }

  private func stopTicketConversationActivityMonitoring() {
    ticketConversationActivityTask?.cancel()
    ticketConversationActivityTask = nil
    ticketConversationActivityMonitorID = nil
    ticketConversationActivity = nil
  }

  private func reloadProductConversations(
    productID: UUID,
    store: SQLiteStore
  ) async throws {
    let threads = try await store.fetchConversationThreads(productID: productID)
    var messagesByThread: [UUID: [ProductConversationMessage]] = [:]
    for thread in threads {
      messagesByThread[thread.id] = try await store.fetchConversationMessages(
        threadID: thread.id
      )
    }
    guard selectedProductID == productID else { return }
    conversationThreads = threads
    conversationMessagesByThread = messagesByThread
  }

  private static func conversationSubject(from message: String) -> String {
    let firstLine =
      message
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Conversation"
    guard firstLine.count > 72 else { return firstLine }
    return "\(firstLine.prefix(69))…"
  }

  func proposeRetrospectiveAction(
    productID: UUID,
    sprintID: UUID,
    body: String,
    destination: RetrospectiveActionDestination
  ) async -> RetrospectiveNote? {
    guard let store = store(for: productID) else { return nil }
    do {
      let note = try await store.proposeRetrospectiveAction(
        productID: productID,
        sprintID: sprintID,
        body: body,
        destination: destination
      )
      await reloadSelectedProductIfCurrent(productID: productID)
      return note
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func captureRetrospectiveActionIdea(
    productID: UUID,
    sprintID: UUID,
    body: String
  ) async -> RetrospectiveNote? {
    guard let store = store(for: productID) else { return nil }
    do {
      let note = try await store.captureRetrospectiveActionIdea(
        productID: productID,
        sprintID: sprintID,
        body: body
      )
      await reloadSelectedProductIfCurrent(productID: productID)
      return note
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func deleteRetrospectiveActionIdea(_ note: RetrospectiveNote) async {
    guard let store = store(for: note.productID) else { return }
    do {
      try await store.deleteRetrospectiveActionIdea(noteID: note.id)
      await reloadSelectedProductIfCurrent(productID: note.productID)
    } catch {
      errorMessage = error.localizedDescription
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
    guard let store = store(for: synthesis.productID) else { return }
    do {
      _ = try await store.skipRetrospectiveSynthesis(id: synthesis.id)
      await reloadSelectedProductIfCurrent(productID: synthesis.productID)
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
    return
      retrospectiveNotes
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
    guard let store = store(for: note.productID) else { return nil }
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
      await reloadSelectedProductIfCurrent(productID: note.productID)
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
    let proposedNotes = notes.filter { $0.actionStatus == .proposed }
    guard
      let productID = proposedNotes.first?.productID,
      proposedNotes.allSatisfy({ $0.productID == productID }),
      let store = store(for: productID)
    else { return }

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
      await reloadSelectedProductIfCurrent(productID: productID)
    } catch {
      await reloadSelectedProductIfCurrent(productID: productID)
      errorMessage = error.localizedDescription
    }
  }

  func concludeRetrospective(productID: UUID, sprintID: UUID) async -> Bool {
    guard let store = store(for: productID) else { return false }
    do {
      _ = try await store.concludeRetrospective(id: sprintID)
      await reloadSelectedProductIfCurrent(productID: productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func appendOwnerComment(
    workItemID: UUID,
    productID: UUID? = nil,
    body: String,
    answeredQuestions: [TicketAnsweredQuestion] = []
  ) async -> TicketComment? {
    let targetStore = productID.flatMap { store(for: $0) } ?? store
    guard let targetStore else { return nil }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let comment = try await targetStore.appendComment(
        workItemID: workItemID,
        authorKind: .owner,
        authorName: "Me",
        body: trimmed,
        answeredQuestions: answeredQuestions
      )
      if let productID, selectedProductID == productID {
        activity = try await targetStore.fetchActivity(productID: productID)
      } else if productID == nil, let selectedProductID {
        activity = try await targetStore.fetchActivity(productID: selectedProductID)
      }
      return comment
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func appendSprintWorkLogComment(
    workItemID: UUID,
    productID: UUID,
    body: String
  ) async -> TicketComment? {
    await appendOwnerComment(
      workItemID: workItemID,
      productID: productID,
      body: body
    )
  }

  func openDecisionArtifact(
    _ artifact: TicketDecisionArtifact,
    workItemID: UUID
  ) {
    let workspaceCandidates =
      runs
      .filter { $0.workItemID == workItemID }
      .sorted { $0.createdAt > $1.createdAt }
      .compactMap { $0.worktreePath }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let productWorkspace =
      workItems.first(where: { $0.id == workItemID })
      .flatMap { try? Self.productWorkspaceURL(productID: $0.productID) }
    let workspaces = workspaceCandidates + (productWorkspace.map { [$0] } ?? [])

    for workspace in workspaces {
      guard
        let artifactURL = try? TicketDecisionArtifactValidator.resolveExistingFile(
          artifact,
          in: workspace
        )
      else { continue }
      guard NSWorkspace.shared.open(artifactURL) else {
        errorMessage = "macOS could not open \(artifact.title)."
        return
      }
      return
    }
    errorMessage =
      "The decision evidence “\(artifact.title)” is no longer available in the preserved ticket workspace."
  }

  func stopAgentRun(_ run: AgentRun) async {
    guard
      run.status == .running,
      let client = codexClient,
      let turn = activeExecutionTurns[run.id]
    else { return }
    manuallyStoppedRunIDs.insert(run.id)
    do {
      try await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
      stopLiveActivityMonitoring(runID: run.id)
      _ = try await updateAgentRun(
        id: run.id,
        status: .interrupted,
        eventActor: "Product owner",
        eventDetail: "Stopped manually; ticket workspace preserved"
      )
      await reloadSelectedProduct()
    } catch {
      manuallyStoppedRunIDs.remove(run.id)
      errorMessage = error.localizedDescription
    }
  }

  func resumeSprintWork(
    productID: UUID,
    workItemID: UUID,
    body: String,
    answeredQuestions: [TicketAnsweredQuestion] = []
  ) async -> TicketComment? {
    guard
      let comment = await appendOwnerComment(
        workItemID: workItemID,
        productID: productID,
        body: body,
        answeredQuestions: answeredQuestions
      )
    else {
      return nil
    }
    await handleSprintOwnerComment(
      productID: productID,
      workItemID: workItemID,
      body: comment.body
    )
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
      let specification = result.demo,
      let store = store(for: recoverableCandidate.productID)
    else {
      return false
    }

    let reviewerName =
      profiles.first { profile in
        guard profile.role == .lead else { return false }
        return runs.contains {
          $0.workItemID == workItemID
            && $0.profileID == profile.id
            && $0.status == .completed
            && $0.worktreePath == recoverableCandidate.integrationWorktreePath
        }
      }?.name ?? "Tech lead"

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
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .running,
        eventActor: "Spedito",
        eventDetail: "Retrying demo preparation for the reviewed candidate"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .integrating,
        actor: "Spedito",
        reason: "Retrying the reviewed candidate handoff"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .verifying,
        actor: "Spedito",
        reason: "Re-running demo preparation against the reviewed revision"
      )
      await reloadSelectedProductIfCurrent(productID: recoverableCandidate.productID)
      let ticketPublication = try await prepareTicketPullRequestIfConnected(
        productID: candidate.productID,
        workItemID: item.id,
        candidateRevisionID: candidate.id
      )

      try await prepareDemoForAcceptance(
        candidate: candidate,
        integratedSHA: integratedSHA,
        specification: specification
      )
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .readyForDemo
      )
      try await markTicketPullRequestReadyIfNeeded(ticketPublication)
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .completed,
        eventActor: "Spedito",
        eventDetail: "Demo preparation succeeded on retry"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .acceptance,
        actor: reviewerName,
        reason: "Reviewed candidate prepared successfully for product owner demo"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Demo preparation succeeded on retry. The already reviewed candidate was preserved; implementation and tech lead review were not repeated."
      )
      await reloadSelectedProductIfCurrent(productID: recoverableCandidate.productID)
      return true
    } catch {
      if DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate,
        let item = try? await store.fetchWorkItems(
          productID: recoverableCandidate.productID
        ).first(where: { $0.id == workItemID })
      {
        do {
          try await returnDemoFailureForCorrection(
            candidateID: recoverableCandidate.id,
            implementationRun: implementationRun,
            workItem: item,
            error: error
          )
          return true
        } catch {
          errorMessage = error.localizedDescription
        }
      }
      _ = try? await store.updateCandidateRevision(
        id: recoverableCandidate.id,
        status: .failed
      )
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Demo preparation retry could not complete"
      )
      if let item = try? await store.fetchWorkItems(
        productID: recoverableCandidate.productID
      ).first(where: { $0.id == workItemID }),
        item.state == .integrating || item.state == .verifying
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: "Demo preparation retry stopped; preserving the reviewed candidate"
        )
      }
      _ = try? await store.appendComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Demo preparation stopped unexpectedly again: \(error.localizedDescription)\n\nChoose Retry demo preparation to try the preserved reviewed candidate again."
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: recoverableCandidate.productID)
      return false
    }
  }

  func launchDemo(for candidate: CandidateRevision) async -> Bool {
    guard candidate.deliveryKind.changesRepository,
      candidate.status == .readyForDemo,
      candidate.integratedSHA != nil
    else {
      return false
    }
    do {
      let result = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      guard let specification = result.demo else {
        throw DemoLaunchValidationError.invalid(
          "this older candidate has no managed demo recipe. Request changes so the delivery agent can add one."
        )
      }
      try DemoLaunchSpecificationValidator.validate(specification)
      return await launchManagedPresentation(
        for: candidate,
        specification: specification
      )
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func openAppVersion(id: UUID) async -> Bool {
    guard
      let selectedProductIDAtLaunch = selectedProductID,
      let version = appVersions.first(where: { $0.id == id }),
      version.productID == selectedProductIDAtLaunch
    else { return false }

    guard selectedProductID == selectedProductIDAtLaunch else { return false }

    let didLaunch = await launchManagedPresentation(
      productID: version.productID,
      sourceKind: version.sessionSourceKind,
      launchID: version.id,
      revisionSHA: version.revisionSHA,
      specification: version.specification
    )
    guard selectedProductID == selectedProductIDAtLaunch else {
      await stopManagedSession(
        productID: version.productID,
        sourceKind: version.sessionSourceKind,
        launchID: version.id,
        removesPreview: false
      )
      return false
    }
    return didLaunch
  }

  func stopAppVersion(id: UUID) async {
    guard
      let version = appVersions.first(where: { $0.id == id }),
      version.productID == selectedProductID
    else { return }
    await stopManagedSession(
      productID: version.productID,
      sourceKind: version.sessionSourceKind,
      launchID: version.id,
      removesPreview: false
    )
  }

  private func launchManagedPresentation(
    for candidate: CandidateRevision,
    specification: DemoLaunchSpecification
  ) async -> Bool {
    guard let integratedSHA = candidate.integratedSHA else { return false }
    return await launchManagedPresentation(
      productID: candidate.productID,
      sourceKind: .acceptedCandidate,
      launchID: candidate.id,
      revisionSHA: integratedSHA,
      specification: specification
    )
  }

  private func launchManagedPresentation(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    revisionSHA: String,
    specification: DemoLaunchSpecification
  ) async -> Bool {
    guard let store = store(for: productID) else { return false }
    guard productsLaunchingManagedPresentation.insert(productID).inserted else { return false }
    defer { productsLaunchingManagedPresentation.remove(productID) }
    let activeStatuses: Set<DemoSessionStatus> = [.preparing, .starting, .ready]
    let productSessions = (try? await store.fetchDemoSessions(productID: productID)) ?? []
    for session in productSessions
    where activeStatuses.contains(session.status)
      && (session.sourceKind != sourceKind || session.launchID != launchID)
    {
      await stopManagedSession(
        productID: productID,
        sourceKind: session.sourceKind,
        launchID: session.launchID,
        removesPreview: false
      )
    }
    do {
      let previewURL = try await prepareLaunchPreview(
        productID: productID,
        sourceKind: sourceKind,
        launchID: launchID,
        revisionSHA: revisionSHA
      )
      var session =
        currentDemoSession(sourceKind: sourceKind, launchID: launchID)
        ?? DemoSession(
          productID: productID,
          sourceKind: sourceKind,
          launchID: launchID,
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
        candidateID: launchID,
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
      var session =
        currentDemoSession(sourceKind: sourceKind, launchID: launchID)
        ?? DemoSession(
          productID: productID,
          sourceKind: sourceKind,
          launchID: launchID,
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
    currentDemoSession(sourceKind: .acceptedCandidate, launchID: candidateRevisionID)
  }

  func currentAppVersionSession(id: UUID) -> DemoSession? {
    guard let version = appVersions.first(where: { $0.id == id }) else { return nil }
    return currentDemoSession(sourceKind: version.sessionSourceKind, launchID: version.id)
  }

  private func currentDemoSession(
    sourceKind: DemoSessionSourceKind,
    launchID: UUID
  ) -> DemoSession? {
    demoSessions.first { $0.sourceKind == sourceKind && $0.launchID == launchID }
  }

  private func replaceDemoSession(_ session: DemoSession) {
    guard selectedProductID == session.productID else { return }
    demoSessions.removeAll {
      $0.sourceKind == session.sourceKind && $0.launchID == session.launchID
    }
    demoSessions.append(session)
    demoSessions.sort { $0.createdAt < $1.createdAt }
  }

  private func storedDemoSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID
  ) async -> DemoSession? {
    guard let store = store(for: productID) else { return nil }
    return try? await store.fetchDemoSession(sourceKind: sourceKind, launchID: launchID)
  }

  private func storedDemoSession(for candidate: CandidateRevision) async -> DemoSession? {
    await storedDemoSession(
      productID: candidate.productID,
      sourceKind: .acceptedCandidate,
      launchID: candidate.id
    )
  }

  private func stopDemoSession(
    _ candidate: CandidateRevision,
    removesPreview: Bool
  ) async {
    await stopManagedSession(
      productID: candidate.productID,
      sourceKind: .acceptedCandidate,
      launchID: candidate.id,
      removesPreview: removesPreview
    )
  }

  private func stopManagedSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    removesPreview: Bool
  ) async {
    await demoLauncher.stop(candidateID: launchID)
    guard
      let store = store(for: productID),
      var session = await storedDemoSession(
        productID: productID,
        sourceKind: sourceKind,
        launchID: launchID
      )
    else { return }
    if removesPreview,
      let previewPath = session.previewWorktreePath,
      let repositoryURL = try? Self.productWorkspaceURL(productID: productID)
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
    guard let store = store(for: productID) else { return }
    let productSessions =
      (try? await store.fetchDemoSessions(productID: productID)) ?? []
    let stoppableStatuses: [DemoSessionStatus] =
      includesPreparation
      ? [.preparing, .starting, .ready]
      : [.starting, .ready]
    for var session in productSessions where stoppableStatuses.contains(session.status) {
      await demoLauncher.stop(candidateID: session.launchID)
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
    let activeSessions = demoSessions.filter {
      $0.status == .preparing || $0.status == .starting || $0.status == .ready
    }
    for var session in activeSessions {
      guard let store = store(for: session.productID) else { continue }
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
    try await prepareLaunchPreview(
      productID: candidate.productID,
      sourceKind: .acceptedCandidate,
      launchID: candidate.id,
      revisionSHA: integratedSHA
    )
  }

  private func prepareLaunchPreview(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    revisionSHA: String
  ) async throws -> URL {
    let repositoryURL = try Self.productWorkspaceURL(productID: productID)
    let previewsRootURL = try Self.previewWorktreesRootURL(productID: productID)
    let expectedPreviewURL = previewsRootURL.appendingPathComponent(
      launchID.uuidString.lowercased(),
      isDirectory: true
    )
    if let existingPath = await storedDemoSession(
      productID: productID,
      sourceKind: sourceKind,
      launchID: launchID
    )?.previewWorktreePath,
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
      candidateID: launchID,
      integratedSHA: revisionSHA
    )
  }

  private func prepareDemoForAcceptance(
    candidate: CandidateRevision,
    integratedSHA: String,
    specification: DemoLaunchSpecification
  ) async throws {
    guard let store = store(for: candidate.productID) else {
      throw PersistenceError.recordNotFound("product database \(candidate.productID)")
    }
    let previewURL = try await prepareCandidatePreview(
      candidate: candidate,
      integratedSHA: integratedSHA
    )
    var session =
      await storedDemoSession(for: candidate)
      ?? DemoSession(
        productID: candidate.productID,
        launchID: candidate.id,
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

  @discardableResult
  func beginSprintTicketAcceptance(_ item: WorkItem) -> Bool {
    guard item.state == .acceptance || item.state == .readyToRelease else {
      return false
    }
    if ticketAcceptanceTasks[item.id] != nil {
      return true
    }
    ticketAcceptanceInProgressWorkItemIDs.insert(item.id)
    ticketAcceptanceTasks[item.id] = Task { [weak self] in
      guard let self else { return }
      _ = await completeSprintTicketAcceptance(
        workItemID: item.id,
        productID: item.productID
      )
      ticketAcceptanceTasks.removeValue(forKey: item.id)
      ticketAcceptanceInProgressWorkItemIDs.remove(item.id)
    }
    return true
  }

  private func recoverInterruptedTicketAcceptances() async {
    for product in products {
      guard let store = store(for: product.id) else { continue }
      do {
        let itemsByID = Dictionary(
          uniqueKeysWithValues: try await store.fetchWorkItems(productID: product.id).map {
            ($0.id, $0)
          }
        )
        let interrupted = try await store.fetchCandidateRevisions(productID: product.id)
          .filter { candidate in
            guard candidate.status == .promoting || candidate.status == .accepted,
              let item = itemsByID[candidate.workItemID]
            else {
              return false
            }
            return item.state == .acceptance || item.state == .readyToRelease
          }
        for candidate in interrupted {
          guard let item = itemsByID[candidate.workItemID] else { continue }
          _ = beginSprintTicketAcceptance(item)
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func completeSprintTicketAcceptance(
    workItemID: UUID,
    productID: UUID
  ) async -> Bool {
    guard let store = store(for: productID) else { return false }
    do {
      guard
        let current = try await store.fetchWorkItems(productID: productID)
          .first(where: { $0.id == workItemID }),
        current.state == .acceptance || current.state == .readyToRelease
      else {
        return false
      }
      let candidates = try await store.fetchCandidateRevisions(productID: productID)
      let resumableCandidates = candidates.filter { candidate in
        candidate.workItemID == workItemID
          && (candidate.status == .readyForDemo
            || candidate.status == .promoting
            || candidate.status == .accepted)
      }
      guard
        let candidate = resumableCandidates.max(by: { $0.version < $1.version })
      else {
        throw PersistenceError.corruptData(
          "This ticket has no reviewed candidate revision ready to promote."
        )
      }
      var ticketPublication: RemotePublication?
      if candidate.deliveryKind.changesRepository, let githubRemoteService {
        let remoteState = await githubRemoteService.state(productID: productID)
        if remoteState.connection?.status == .connected {
          guard
            let publication = remoteState.publications.first(where: {
              $0.workItemID == workItemID && $0.candidateRevisionID == candidate.id
                && ($0.status.isActive || $0.status == .merged)
            })
          else {
            throw PersistenceError.corruptData(
              "This reviewed ticket has no GitHub pull request."
            )
          }
          if publication.status == .merged {
            ticketPublication = publication
          } else {
            let sync = try await githubRemoteService.syncTicketPullRequest(
              publicationID: publication.id
            )
            githubRemoteRepositoryStates[productID] = sync.state
            if sync.changesRequested {
              await handleSprintOwnerComment(
                productID: productID,
                workItemID: workItemID,
                body: "Address the latest GitHub review feedback.",
                actor: "GitHub reviewer",
                reasonPrefix: "Review feedback"
              )
              return false
            }
            guard !sync.closedWithoutMerge,
              let refreshed = sync.state.publications.first(where: { $0.id == publication.id }),
              refreshed.status == .open,
              refreshed.pullRequest?.isDraft == false
            else {
              throw PersistenceError.corruptData(
                "The GitHub pull request must be open and ready for review before approval."
              )
            }
            ticketPublication = refreshed
          }
        }
      }
      let executionResult = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      let allProposals = try await store.fetchKnowledgePageProposals(productID: productID)
      let proposals = allProposals.filter { $0.candidateRevisionID == candidate.id }
      let publishableProposals: [KnowledgePageProposal]
      if requiresKnowledgeApproval {
        guard
          !proposals.contains(where: {
            $0.status == .proposed || $0.status == .reviewed
          })
        else {
          throw PersistenceError.corruptData(
            "Accept or reject every product knowledge proposal before completing the ticket."
          )
        }
        publishableProposals = proposals.filter { $0.status == .accepted }
      } else {
        guard !proposals.contains(where: { $0.status == .proposed }) else {
          throw PersistenceError.corruptData(
            "Tech lead review must finish every product knowledge proposal before completing the ticket."
          )
        }
        publishableProposals = proposals.filter {
          $0.status == .reviewed || $0.status == .accepted
        }
      }
      let canonicalPages = try await store.fetchKnowledgePages(productID: productID)
      _ = try KnowledgePageProposalMaterializer.applying(
        publishableProposals,
        to: canonicalPages
      )

      if candidate.status == .readyForDemo {
        _ = try await store.updateCandidateRevision(id: candidate.id, status: .promoting)
      }
      await stopDemoSession(candidate, removesPreview: true)
      let repositoryURL = try Self.productWorkspaceURL(productID: productID)
      if candidate.deliveryKind.changesRepository {
        guard let integratedSHA = candidate.integratedSHA else {
          throw PersistenceError.corruptData(
            "This repository-changing ticket has no reviewed integrated revision."
          )
        }
      if let ticketPublication, let githubRemoteService {
        let mergedSHA: String
        if ticketPublication.status == .merged,
          let existingMergedSHA = ticketPublication.pullRequest?.mergedSHA
        {
          let checked = try await githubRemoteService.check(productID: productID)
          if let sync = checked.safeSync, sync.status == .awaitingConfirmation {
            let reconciled = try await githubRemoteService.acceptSafeSync(syncID: sync.id)
            githubRemoteRepositoryStates[productID] = reconciled
          } else {
            githubRemoteRepositoryStates[productID] = checked
          }
          mergedSHA = existingMergedSHA
        } else {
          do {
            let result = try await githubRemoteService.mergeTicketPullRequest(
              publicationID: ticketPublication.id
            )
            githubRemoteRepositoryStates[productID] = result.state
            mergedSHA = result.mergedSHA
          } catch GitHubRemoteRepositoryServiceError.ticketIntegrationRequired {
            if ticketPublication.pullRequest?.isDraft == false {
              let draftState = try await githubRemoteService.returnTicketPullRequestToDraft(
                publicationID: ticketPublication.id
              )
              githubRemoteRepositoryStates[productID] = draftState
            }
            try await requeueStaleReadyCandidate(
              candidate,
              reason:
                "GitHub changed after this demo revision was prepared. Spedito will integrate the latest verified changes and review the ticket again."
            )
            await reloadSelectedProductIfCurrent(productID: productID)
            scheduleSprintExecution(productID: productID)
            return false
          }
        }
        let acceptedSHA = try await gitWorkspaceManager.acceptedTrunkSHA(at: repositoryURL)
        let acceptedTree = try await gitWorkspaceManager.revisionTreeSHA(
          repositoryURL: repositoryURL,
          revisionSHA: acceptedSHA
        )
        let integratedTree = try await gitWorkspaceManager.revisionTreeSHA(
          repositoryURL: repositoryURL,
          revisionSHA: integratedSHA
        )
        guard acceptedSHA == mergedSHA, acceptedTree == integratedTree else {
          throw PersistenceError.corruptData(
            "The merged GitHub revision did not reconcile to the reviewed ticket result."
          )
        }
      } else {
        let acceptedTrunkSHA = try await gitWorkspaceManager.acceptedTrunkSHA(at: repositoryURL)
        if acceptedTrunkSHA != integratedSHA {
          guard
            try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
              repositoryURL: repositoryURL,
              integratedSHA: integratedSHA
            )
          else {
            try await requeueStaleReadyCandidate(
              candidate,
              reason: "Accepted trunk advanced after this demo revision was prepared."
            )
            await reloadSelectedProductIfCurrent(productID: productID)
            scheduleSprintExecution(productID: productID)
            return false
          }
          try await gitWorkspaceManager.promote(
            repositoryURL: repositoryURL,
            integratedSHA: integratedSHA
          )
        }
      }
      }

      if let specification = executionResult.demo,
        specification.presentation.kind == .browser
          || specification.presentation.kind == .macApplication,
        (try? DemoLaunchSpecificationValidator.validate(specification)) != nil
      {
        let previousLatestCandidateID = AcceptedAppLaunchPolicy.latest(in: candidates)?.candidate.id
        if let previousLatestCandidateID {
          await stopManagedSession(
            productID: productID,
            sourceKind: .acceptedCandidate,
            launchID: previousLatestCandidateID,
            removesPreview: true
          )
        }
        let activeStatuses: Set<DemoSessionStatus> = [.preparing, .starting, .ready]
        for session in demoSessions
        where activeStatuses.contains(session.status)
          && !(session.sourceKind == .acceptedCandidate
            && session.launchID == previousLatestCandidateID)
        {
          await stopManagedSession(
            productID: session.productID,
            sourceKind: session.sourceKind,
            launchID: session.launchID,
            removesPreview: false
          )
        }
      }
      for proposal in publishableProposals {
        _ = try await store.publishKnowledgePageProposal(
          id: proposal.id,
          authorName: requiresKnowledgeApproval ? "Me" : "Spedito"
        )
      }
      if !publishableProposals.isEmpty {
        _ = try await store.appendComment(
          workItemID: current.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "Published \(publishableProposals.count) approved product knowledge change\(publishableProposals.count == 1 ? "" : "s") to this Product's local knowledge."
        )
      }
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

      var latest = try await store.fetchWorkItems(productID: productID)
        .first(where: { $0.id == current.id })
      if latest?.state == .acceptance {
        latest = try await store.transitionWorkItem(
          id: current.id,
          to: .readyToRelease,
          actor: "Product owner",
          reason:
            candidate.deliveryKind == .localOutcome
            ? "Reviewed outcome approved"
            : "Demo approved"
        )
      }
      if latest?.state == .readyToRelease {
        latest = try await store.transitionWorkItem(
          id: current.id,
          to: .released,
          actor: "Product owner",
          reason: "Accepted outcome completed"
        )
      }
      guard latest?.state == .released else {
        throw PersistenceError.corruptData(
          "The accepted ticket could not complete its workflow transitions."
        )
      }

      let followUpSuffix =
        executionResult.followUpTicketProposals.isEmpty
        ? ""
        : " \(executionResult.followUpTicketProposals.count) follow-up "
          + (executionResult.followUpTicketProposals.count == 1
            ? "ticket is"
            : "tickets are")
          + " ready for review in the backlog."
      let completionComment: String
      if candidate.deliveryKind == .localOutcome {
        completionComment =
          "Product owner approved local outcome v\(candidate.version). No repository revision was created or promoted."
          + followUpSuffix
      } else if let integratedSHA = candidate.integratedSHA {
        completionComment =
          "Product owner approved candidate v\(candidate.version). Integrated revision "
          + "\(String(integratedSHA.prefix(8))) is now the accepted trunk."
          + followUpSuffix
      } else {
        throw PersistenceError.corruptData(
          "The accepted repository candidate has no integrated revision."
        )
      }
      let existingComments = try await store.fetchComments(workItemID: current.id)
      if !existingComments.contains(where: { $0.body == completionComment }) {
        _ = try await store.appendComment(
          workItemID: current.id,
          authorKind: .system,
          authorName: "Spedito",
          body: completionComment
        )
      }
      try await requeueStaleReadyCandidates(
        productID: productID,
        excluding: candidate.id
      )
      if let activePlan = try await store.fetchCurrentSprint(productID: productID),
        activePlan.sprint.state.isInProgress,
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
      await reloadSelectedProductIfCurrent(productID: productID)
      scheduleRetrospectiveSyntheses()
      scheduleSprintExecution(productID: productID)
      return true
    } catch {
      if let candidate = try? await store.fetchCandidateRevisions(productID: productID)
        .filter({
          $0.workItemID == workItemID && $0.status == .promoting
        })
        .max(by: { $0.version < $1.version })
      {
        _ = try? await store.updateCandidateRevision(
          id: candidate.id,
          status: .readyForDemo
        )
      }
      _ = try? await store.appendComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Ticket completion stopped: \(error.localizedDescription)\n\nThe reviewed result remains ready for approval. Choose Approve and complete to retry."
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: productID)
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
    guard let store = store(for: proposal.productID) else { return false }
    do {
      _ = try await store.recordKnowledgePageProposalDecision(
        id: proposal.id,
        accept: accept,
        authorName: "Me"
      )
      await reloadSelectedProductIfCurrent(productID: proposal.productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: proposal.productID)
      return false
    }
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
    guard recipient.productID == product.id, profiles.contains(where: { $0.id == recipient.id })
    else {
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
    let priorComments =
      comments.last?.authorKind == .owner
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
            customInstructions: recipient.customInstructionText,
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
        authorName: "Spedito",
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

  func generateAndSaveSprintGoal(for sprintID: UUID, planVersion: Int) async throws -> String {
    guard
      !isGeneratingSprintGoal,
      suggestionBatch?.session.status != .generating,
      !isPlanningMessageRunning,
      !isTicketConversationMessageRunning,
      !isEpicConversationMessageRunning,
      refiningWorkItemID == nil,
      epicPlanningConversation?.isRunning != true,
      epicPlanningConversation?.isGeneratingPlan != true
    else {
      throw SprintGoalGenerationError.anotherCodexTaskIsRunning
    }
    guard
      let client = codexClient,
      let product = selectedProduct,
      let analyst = profiles.first(where: { $0.role == .businessAnalyst })
    else {
      throw CodexClientError.notConnected
    }
    guard
      let plan = sprintPlanForGoalGeneration(id: sprintID),
      plan.sprint.planVersion == planVersion
    else {
      throw SprintPlanningError.planChanged
    }
    let scopedIDs = Set(plan.items.map(\.workItemID))
    let titles =
      workItems
      .filter { scopedIDs.contains($0.id) }
      .sorted {
        if $0.rank == $1.rank { return $0.key < $1.key }
        return $0.rank < $1.rank
      }
      .map(\.title)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !titles.isEmpty else {
      throw SprintGoalGenerationError.noTickets
    }
    let supportedEfforts =
      modelOption(for: analyst)?
      .supportedReasoningEfforts
      .map(\.id) ?? []
    let reasoningEffort = CodexSprintGoalGenerator.lightestReasoningEffort(
      supportedEfforts: supportedEfforts,
      fallback: analyst.reasoningEffort
    )
    let deadline = ContinuousClock.now + CodexSprintGoalGenerator.totalTimeout

    isGeneratingSprintGoal = true
    defer {
      isGeneratingSprintGoal = false
      activeSprintGoalTurn = nil
    }

    do {
      let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workingDirectory,
        developerInstructions: CodexSprintGoalGenerator.developerInstructions,
        model: analyst.model,
        responseTimeout: try remainingSprintGoalGenerationTime(until: deadline)
      )
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexSprintGoalGenerator.prompt(
          productName: product.name,
          sprintNumber: plan.sprint.number,
          ticketTitles: titles
        ),
        effort: reasoningEffort,
        outputSchema: CodexSprintGoalGenerator.outputSchema,
        responseTimeout: try remainingSprintGoalGenerationTime(until: deadline)
      )
      activeSprintGoalTurn = (threadID: threadID, turnID: turnID)
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(180),
        totalTimeout: try remainingSprintGoalGenerationTime(until: deadline)
      )
      let suggestion = try CodexSprintGoalGenerator.decode(response)
      guard
        let currentPlan = sprintPlanForGoalGeneration(id: sprintID),
        currentPlan.sprint.planVersion == planVersion,
        let store = store(for: currentPlan.sprint.productID)
      else {
        throw SprintPlanningError.planChanged
      }
      let savedPlan = try await store.saveGeneratedSprintGoal(
        id: sprintID,
        goal: suggestion,
        expectedPlanVersion: planVersion
      )
      await reloadSelectedProductIfCurrent(productID: currentPlan.sprint.productID)
      return savedPlan.sprint.goal
    } catch let error as SprintGoalGenerationError {
      if error == .timedOut, let activeSprintGoalTurn {
        try? await client.interruptTurn(
          threadID: activeSprintGoalTurn.threadID,
          turnID: activeSprintGoalTurn.turnID
        )
      }
      throw error
    } catch let error as CodexClientError {
      guard case .turnTimedOut = error else { throw error }
      throw SprintGoalGenerationError.timedOut
    } catch let error as CodexTransportError {
      guard case .requestTimedOut = error else { throw error }
      throw SprintGoalGenerationError.timedOut
    }
  }

  private func sprintPlanForGoalGeneration(id: UUID) -> SprintPlan? {
    if let candidateSprintPlan, candidateSprintPlan.sprint.id == id {
      return candidateSprintPlan
    }
    if let sprintPlan, sprintPlan.sprint.id == id {
      return sprintPlan
    }
    return sprintHistory.first {
      $0.sprint.id == id && [.draft, .active, .paused].contains($0.sprint.state)
    }
  }

  private func remainingSprintGoalGenerationTime(
    until deadline: ContinuousClock.Instant
  ) throws -> Duration {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw SprintGoalGenerationError.timedOut
    }
    return remaining
  }


  func addToCandidateSprint(_ workItem: WorkItem) {
    addToCandidateSprint([workItem])
  }

  func addToCandidateSprint(_ selectedItems: [WorkItem]) {
    guard
      let store,
      let productID = selectedProductID,
      canEditCandidateSprint,
      !selectedItems.isEmpty,
      selectedItems.allSatisfy({ $0.productID == productID })
    else { return }

    let candidatePlan = candidateSprintPlan
    let existingIDs = Set(candidatePlan?.items.map(\.workItemID) ?? [])
    let selectedIDs = Set(selectedItems.map(\.id)).subtracting(existingIDs)
    guard !selectedIDs.isEmpty else { return }
    let availableIDs =
      existingIDs
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

    let currentInputs: [SprintDraftItemInput] =
      candidatePlan?.items.map { sprintItem in
        let workItem = workItems.first { $0.id == sprintItem.workItemID }
        return SprintDraftItemInput(
          workItemID: sprintItem.workItemID,
          implementerProfileID: sprintItem.implementerProfileID
            ?? workItem?.ownerProfileID,
          reviewerProfileID: sprintItem.reviewerProfileID,
          estimatedTokens: sprintItem.estimatedTokens
        )
      } ?? []
    let newInputs: [SprintDraftItemInput] =
      workItems
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
          goal: candidatePlan?.sprint.goal ?? "",
          tokenBudgetLimit: nil,
          items: inputs
        )
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        presentExecutionError(error, productID: productID)
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
      !selectedItems.isEmpty,
      selectedItems.allSatisfy({ $0.productID == productID })
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
          items: inputs
        )
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        presentExecutionError(error, productID: productID)
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
      !selectedItems.isEmpty,
      selectedItems.allSatisfy({ $0.productID == productID })
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
    let desiredCandidateIDs =
      intoCandidateSprint
      ? existingCandidateIDs.union(movingIDs)
      : existingCandidateIDs.subtracting(movingIDs)

    let existingItemsByID = Dictionary(
      uniqueKeysWithValues: (candidatePlan?.items ?? []).map { ($0.workItemID, $0) }
    )
    let shouldSaveSprint = desiredCandidateIDs != existingCandidateIDs
    let capturedWorkItems = workItems

    Task {
      do {
        let reorderedItems: [WorkItem]
        switch rankAction {
        case .preserve:
          reorderedItems = capturedWorkItems
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
            goal: candidatePlan?.sprint.goal ?? "",
            tokenBudgetLimit: nil,
            items: inputs
          )
        }
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        presentExecutionError(error, productID: productID)
        await reloadSelectedProductIfCurrent(productID: productID)
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
    if let activePlan = sprintPlan, activePlan.sprint.state.isInProgress {
      ids.formUnion(activePlan.items.map(\.workItemID))
    }
    return ids
  }

  func restoreEpicPlanningConversation(for epic: Epic) async {
    guard epicPlanningConversation?.epicID != epic.id else { return }
    guard
      epicPlanningConversation?.isRunning != true,
      epicPlanningConversation?.isGeneratingPlan != true
    else { return }
    await epicConversationPersistenceTask?.value
    guard
      !Task.isCancelled,
      selectedProductID == epic.productID,
      epicPlanningConversation?.isRunning != true,
      epicPlanningConversation?.isGeneratingPlan != true,
      let store = store(for: epic.productID)
    else { return }

    do {
      guard var snapshot = try await store.fetchEpicPlanningConversation(epicID: epic.id) else {
        epicPlanningConversation = nil
        epicPlanningThreadID = nil
        activeEpicPlanningTurn = nil
        return
      }
      let planningSession = try await store.fetchLatestEpicPlanningSuggestionSession(
        epicID: epic.id
      )
      let hasCompletedPlan =
        snapshot.isComplete || planningSession?.status == .ready
      if hasCompletedPlan && !snapshot.isComplete {
        snapshot.isComplete = true
        snapshot.updatedAt = Date()
        try await store.saveEpicPlanningConversation(snapshot)
      }
      guard
        !Task.isCancelled,
        selectedProductID == epic.productID,
        epicPlanningConversation?.isRunning != true,
        epicPlanningConversation?.isGeneratingPlan != true
      else { return }
      epicPlanningThreadID = snapshot.threadID
      activeEpicPlanningTurn = nil
      let hasStartedPlanning = snapshot.hasStartedPlanning ?? true
      epicPlanningConversation = EpicPlanningConversationState(
        productID: epic.productID,
        epicID: snapshot.epicID,
        messages: snapshot.messages,
        questions: snapshot.questions,
        hasStartedPlanning: hasStartedPlanning,
        isRunning: false,
        isGeneratingPlan: false,
        isComplete: hasCompletedPlan,
        errorMessage:
          !hasStartedPlanning || hasCompletedPlan || !snapshot.questions.isEmpty
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
      productID: epic.productID,
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
            productInstructions: inheritedAgentInstructions(
              for: product,
              allowsRepositoryInspection: false
            ),
            customInstructions: analyst?.customInstructionText ?? ""
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
            existingItems: workItems,
            verifiedKnowledge: epicPlanningKnowledge(for: epic)
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
        updateEpicPlanningConversation(for: epic.id) {
          $0.isRunning = false
          $0.errorMessage = "Epic planning was interrupted. You can safely continue."
        }
      } catch {
        activeEpicPlanningTurn = nil
        updateEpicPlanningConversation(for: epic.id) {
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

    updateEpicPlanningConversation(for: epic.id) {
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
            messages: messages,
            verifiedKnowledge: epicPlanningKnowledge(for: epic)
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
        updateEpicPlanningConversation(for: epic.id) {
          $0.isRunning = false
          $0.errorMessage = "The business analyst stopped. Your answers are still visible."
        }
      } catch {
        activeEpicPlanningTurn = nil
        updateEpicPlanningConversation(for: epic.id) {
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

    let hasFailedPlan =
      suggestionBatch?.session.epicID == epic.id
      && suggestionBatch?.session.status == .failed
    switch EpicPlanningPolicy.retryAction(
      for: conversation,
      hasFailedPlan: hasFailedPlan
    ) {
    case .retryFailedPlan:
      retryCurrentEpicPlan()

    case .retryClarification(let answeredQuestions):
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

    case .restartClarification:
      epicPlanningThreadID = nil
      activeEpicPlanningTurn = nil
      updateEpicPlanningConversation(for: epic.id) {
        $0.questions = []
        $0.hasStartedPlanning = false
        $0.errorMessage = nil
      }
      planEpic(epic)
    }
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
        productInstructions: inheritedAgentInstructions(
          for: product,
          allowsRepositoryInspection: false
        ),
        customInstructions: analyst.customInstructionText
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
    guard
      let conversation = epicPlanningConversation,
      conversation.epicID == epicID
    else { return }
    epicPlanningTask?.cancel()
    epicPlanningTask = nil
    epicPlanningThreadID = nil
    activeEpicPlanningTurn = nil
    epicPlanningConversation = nil
    deletePersistedEpicPlanningConversation(
      epicID: epicID,
      productID: conversation.productID
    )
  }

  private func receiveEpicClarification(
    _ reply: EpicClarificationReply,
    for epic: Epic
  ) {
    updateEpicPlanningConversation(for: epic.id) {
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
      let client = codexClient,
      let product = selectedProduct,
      product.id == epic.productID,
      let store = store(for: epic.productID)
    else { return }

    let analyst = profiles.first { $0.role == .businessAnalyst }
    let existingItems = workItems.filter { $0.state != .cancelled }
    let previouslyRejectedSuggestions =
      suggestionBatch?.session.epicID == epic.id
      ? suggestionBatch?.suggestions.filter { $0.status == .rejected } ?? []
      : []
    let durableMessages =
      epicPlanningConversation?.epicID == epic.id
      ? epicPlanningConversation?.messages ?? []
      : []
    updateEpicPlanningConversation(for: epic.id) {
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
        if selectedProductID == product.id {
          suggestionBatch = TicketSuggestionBatch(session: startedSession, suggestions: [])
        }

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
        let completedBatch = try await store.completeTicketSuggestionSession(
          sessionID: startedSession.id,
          drafts: plan.ticketSuggestions
        )
        if selectedProductID == product.id {
          suggestionBatch = completedBatch
        }
        activeEpicPlanningTurn = nil
        await reloadSelectedProductIfCurrent(productID: product.id)
        try await completeEpicPlanningConversation(
          for: epic,
          proposalCount: plan.ticketSuggestions.count,
          threadID: completedBatch.session.codexThreadID,
          fallbackMessages: durableMessages
        )
      } catch is CancellationError {
        activeEpicPlanningTurn = nil
        if let session, !isShuttingDown {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Epic planning was interrupted. You can safely try again."
          )
        }
        if !isShuttingDown {
          updateEpicPlanningConversation(for: epic.id) {
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
          if selectedProductID == product.id {
            suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(
              productID: product.id
            )
          }
        }
        updateEpicPlanningConversation(for: epic.id) {
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
    let planningKnowledge = epicPlanningKnowledge(for: epic)
    let developerInstructions = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: inheritedAgentInstructions(
        for: product,
        allowsRepositoryInspection: false
      ),
      customInstructions: analyst?.customInstructionText ?? ""
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
      rejectedSuggestions: rejectedSuggestions,
      verifiedKnowledge: planningKnowledge
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
        messages: durableMessages,
        verifiedKnowledge: planningKnowledge
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
    for epicID: UUID,
    _ update: (inout EpicPlanningConversationState) -> Void
  ) {
    guard
      var conversation = epicPlanningConversation,
      conversation.epicID == epicID
    else { return }
    update(&conversation)
    epicPlanningConversation = conversation
    persistEpicPlanningConversation()
  }

  private func completeEpicPlanningConversation(
    for epic: Epic,
    proposalCount: Int,
    threadID: String?,
    fallbackMessages: [EpicPlanningConversationMessage]
  ) async throws {
    await epicConversationPersistenceTask?.value
    guard let store = store(for: epic.productID) else {
      throw PersistenceError.recordNotFound("product store \(epic.productID)")
    }

    var snapshot =
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
      ?? EpicPlanningConversationSnapshot(
        epicID: epic.id,
        messages: fallbackMessages,
        questions: [],
        isComplete: false,
        threadID: threadID
      )
    if !snapshot.isComplete {
      snapshot.messages.append(
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body:
            "I’ve prepared the epic and \(proposalCount) proposed "
            + (proposalCount == 1 ? "ticket" : "tickets")
            + " for you to review in the tickets section."
        )
      )
    }
    snapshot.questions = []
    snapshot.isComplete = true
    snapshot.threadID = threadID ?? snapshot.threadID
    snapshot.updatedAt = Date()
    try await store.saveEpicPlanningConversation(snapshot)

    guard
      selectedProductID == epic.productID,
      var conversation = epicPlanningConversation,
      conversation.productID == epic.productID,
      conversation.epicID == epic.id
    else { return }
    conversation.messages = snapshot.messages
    conversation.questions = []
    conversation.hasStartedPlanning = snapshot.hasStartedPlanning ?? true
    conversation.isRunning = false
    conversation.isGeneratingPlan = false
    conversation.isComplete = true
    conversation.errorMessage = nil
    epicPlanningThreadID = snapshot.threadID
    epicPlanningConversation = conversation
  }

  private func persistEpicPlanningConversation() {
    guard let conversation = epicPlanningConversation else { return }
    let threadID = epicPlanningThreadID
    let previousTask = epicConversationPersistenceTask
    epicConversationPersistenceTask = Task { [weak self] in
      await previousTask?.value
      guard let self else { return }
      do {
        try await saveEpicPlanningConversation(conversation, threadID: threadID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func saveEpicPlanningConversation(
    _ conversation: EpicPlanningConversationState,
    threadID: String?
  ) async throws {
    guard let store = store(for: conversation.productID) else {
      throw PersistenceError.recordNotFound("product store \(conversation.productID)")
    }
    let snapshot = EpicPlanningConversationSnapshot(
      epicID: conversation.epicID,
      messages: conversation.messages,
      questions: conversation.questions,
      isComplete: conversation.isComplete,
      threadID: threadID,
      hasStartedPlanning: conversation.hasStartedPlanning
    )
    try await store.saveEpicPlanningConversation(snapshot)
  }

  private func deletePersistedEpicPlanningConversation(
    epicID: UUID,
    productID: UUID
  ) {
    guard let store = store(for: productID) else { return }
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
      let failedSession = suggestionBatch?.session,
      let store = store(for: failedSession.productID),
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
        guard selectedProductID == failedSession.productID else {
          try? await store.failTicketSuggestionSession(
            sessionID: restartedSession.id,
            message: "Epic planning was interrupted by a product change. You can safely try again."
          )
          return
        }
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

    let previouslyRejectedSuggestions =
      suggestionBatch?.suggestions.filter {
        $0.status == .rejected
      } ?? []
    let existingItems = workItems.filter { $0.state != .cancelled }
    let analyst = profiles.first { $0.role == .businessAnalyst }
    let verifiedKnowledge = KnowledgeContextSelector.mandatoryPages(in: knowledgePages)
    suggestionTask?.cancel()
    suggestionTask = Task { [weak self] in
      guard let self else { return }
      var session: SuggestionSession?
      do {
        let startedSession = try await store.beginTicketSuggestionSession(productID: product.id)
        session = startedSession
        if selectedProductID == product.id {
          suggestionBatch = TicketSuggestionBatch(session: startedSession, suggestions: [])
        }

        let workingDirectory = try Self.productWorkspaceURL(productID: product.id)
        let threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
            productInstructions: inheritedAgentInstructions(
              for: product,
              allowsRepositoryInspection: false
            ),
            customInstructions: analyst?.customInstructionText ?? ""
          ),
          model: analyst?.model
        )
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexTicketSuggestionGenerator.prompt(
            product: product,
            existingItems: existingItems,
            rejectedSuggestions: previouslyRejectedSuggestions,
            verifiedKnowledge: verifiedKnowledge
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
            existingItems: existingItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          let repairTurnID = try await client.startStructuredTurn(
            threadID: threadID,
            prompt: CodexTicketSuggestionGenerator.repairPrompt(
              validationError: validationError.localizedDescription,
              existingItems: existingItems
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
            existingItems: existingItems
          )
        }
        let completedBatch = try await store.completeTicketSuggestionSession(
          sessionID: startedSession.id,
          drafts: drafts
        )
        if selectedProductID == product.id {
          suggestionBatch = completedBatch
        }
        await reloadSelectedProductIfCurrent(productID: product.id)
      } catch is CancellationError {
        if let session, !isShuttingDown {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Ticket suggestion was interrupted. You can safely try again."
          )
          if selectedProductID == product.id {
            suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(
              productID: product.id
            )
          }
        }
      } catch {
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: error.localizedDescription
          )
          if selectedProductID == product.id {
            suggestionBatch = try? await store.fetchLatestTicketSuggestionBatch(
              productID: product.id
            )
          }
        } else if selectedProductID == product.id {
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
    guard
      let session = suggestionBatch?.session,
      suggestionBatch?.suggestions.contains(where: { $0.id == suggestion.id }) == true,
      let store = store(for: session.productID),
      !isDecidingSuggestions
    else { return }
    let productID = session.productID
    let productProfiles = profiles.filter { $0.productID == productID }
    let previouslyProposedIDs = Set(
      suggestionBatch?.suggestions
        .filter { $0.status == .proposed }
        .map(\.id) ?? [suggestion.id]
    )
    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        let decidedBatch = try await store.decideTicketSuggestion(
          id: suggestion.id,
          decision: accept ? .accepted : .rejected
        )
        if selectedProductID == productID {
          suggestionBatch = decidedBatch
        }
        var acceptedItemsBySuggestionID: [UUID: WorkItem] = [:]
        if accept {
          let createdItems = try await store.fetchWorkItems(productID: productID)
          let createdItemsByID = Dictionary(uniqueKeysWithValues: createdItems.map { ($0.id, $0) })
          for acceptedSuggestion in decidedBatch.suggestions
          where previouslyProposedIDs.contains(acceptedSuggestion.id)
            && acceptedSuggestion.status == .accepted
          {
            guard
              let acceptedID = acceptedSuggestion.acceptedWorkItemID,
              var created = createdItemsByID[acceptedID]
            else { continue }
            if let owner = TicketOwnerRouter.owner(
              for: created,
              profiles: productProfiles,
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
        await reloadSelectedProductIfCurrent(productID: productID)
        let acceptedItem = acceptedItemsBySuggestionID[suggestion.id]
        if let acceptedItem {
          completion?(acceptedItem)
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
    guard
      let session = suggestionBatch?.session,
      suggestionBatch?.suggestions.contains(where: { $0.id == suggestion.id }) == true,
      let store = store(for: session.productID),
      !isDecidingSuggestions
    else { return }
    let productID = session.productID
    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        let decidedBatch = try await store.rejectTicketSuggestionCascade(id: suggestion.id)
        if selectedProductID == productID {
          suggestionBatch = decidedBatch
        }
        await reloadSelectedProductIfCurrent(productID: productID)
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
      let session = suggestionBatch?.session,
      let store = store(for: session.productID),
      !isDecidingSuggestions,
      !suggestions.isEmpty
    else { return }
    let productID = session.productID
    let productProfiles = profiles.filter { $0.productID == productID }
    let proposedIDs = Set(
      suggestionBatch?.suggestions
        .filter { $0.status == .proposed }
        .map(\.id) ?? []
    )
    let decisions =
      suggestions
      .filter { proposedIDs.contains($0.id) }
      .sorted { $0.position < $1.position }
    guard !decisions.isEmpty else { return }

    isDecidingSuggestions = true
    Task {
      defer { isDecidingSuggestions = false }
      do {
        for suggestion in decisions {
          let decidedBatch = try await store.decideTicketSuggestion(
            id: suggestion.id,
            decision: accept ? .accepted : .rejected
          )
          if selectedProductID == productID {
            suggestionBatch = decidedBatch
          }
        }
        let decidedBatch = try await store.fetchLatestTicketSuggestionBatch(productID: productID)
        if accept, let decidedBatch {
          let createdItems = try await store.fetchWorkItems(productID: productID)
          let createdItemsByID = Dictionary(uniqueKeysWithValues: createdItems.map { ($0.id, $0) })
          for acceptedSuggestion in decidedBatch.suggestions
          where proposedIDs.contains(acceptedSuggestion.id)
            && acceptedSuggestion.status == .accepted
          {
            guard
              let acceptedID = acceptedSuggestion.acceptedWorkItemID,
              let created = createdItemsByID[acceptedID],
              let owner = TicketOwnerRouter.owner(
                for: created,
                profiles: productProfiles,
                suggestedRole: acceptedSuggestion.suggestedRole
              )
            else { continue }
            _ = try await store.assignWorkItemOwner(id: created.id, profileID: owner.id)
          }
        }
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func dismissFailedTicketSuggestions() {
    guard
      let session = suggestionBatch?.session,
      let store = store(for: session.productID),
      session.status == .failed
    else { return }
    Task {
      do {
        try await store.dismissTicketSuggestionSession(sessionID: session.id)
        if selectedProductID == session.productID {
          suggestionBatch = nil
        }
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
    guard let store = store(for: profile.productID) else { return }
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
        await reloadSelectedProductIfCurrent(productID: profile.productID)
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

  func updateProductDetails(name: String) {
    guard let store, let productID = selectedProductID else { return }
    Task {
      do {
        try await store.updateProductDetails(
          productID: productID,
          name: name
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
  ) async -> Result<TeamSettingsSnapshot, TeamSettingsUpdateFailure> {
    guard let productID = selectedProductID, let productStore = store(for: productID) else {
      return .failure(.unavailable)
    }
    let currentProfiles = profiles.filter { $0.productID == productID }
    let updates = currentProfiles.map { profile in
      TeamProfileSettingsUpdate(
        profileID: profile.id,
        model: modelsByProfile[profile.id] ?? profile.model,
        reasoningEffort: effortsByProfile[profile.id] ?? profile.reasoningEffort,
        customInstructions: customInstructionsByProfile[profile.id]
      )
    }
    do {
      let snapshot = try await productStore.updateTeamSettings(
        productID: productID,
        productInstructions: productInstructions,
        profiles: updates
      )
      if let index = products.firstIndex(where: { $0.id == productID }) {
        products[index] = snapshot.product
      }
      if selectedProductID == productID {
        profiles = snapshot.profiles
      }
      return .success(snapshot)
    } catch {
      return .failure(.saveFailed(error.localizedDescription))
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
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        presentExecutionError(error, productID: productID)
      }
    }
  }

  func archiveCustomPersona(_ profile: AgentProfile) {
    guard let store = store(for: profile.productID), !profile.isBuiltIn else { return }
    Task {
      do {
        try await store.archiveCustomAgentProfile(id: profile.id)
        await reloadSelectedProductIfCurrent(productID: profile.productID)
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
    items: [SprintDraftItemInput]
  ) async -> Bool {
    guard let store, let productID = selectedProductID else { return false }
    do {
      for input in items {
        let savedOwnerID =
          workItems
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
        items: items
      )
      if selectedProductID == productID {
        if sprintPlan?.sprint.state.isInProgress != true {
          sprintPlan = savedPlan
        }
        sprintReadinessIssues = try await store.sprintReadinessIssues(
          sprintID: savedPlan.sprint.id
        )
      }
      await reloadSelectedProductIfCurrent(productID: productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }


  func reassignDraftTicket(
    productID: UUID,
    workItemID: UUID,
    to profileID: UUID?
  ) async -> Bool {
    guard let store = store(for: productID) else { return false }
    guard
      let plan = try? await store.fetchCurrentSprint(productID: productID),
      plan.sprint.state == .draft,
      plan.items.contains(where: { $0.workItemID == workItemID })
    else { return false }
    if let profileID {
      let productProfiles = (try? await store.fetchAgentProfiles(productID: productID)) ?? []
      guard
        productProfiles.contains(where: {
          $0.id == profileID && $0.role.canOwnDelivery
        })
      else { return false }
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
    do {
      _ = try await store.assignWorkItemOwner(id: workItemID, profileID: profileID)
      _ = try await store.saveDraftSprint(
        productID: productID,
        goal: plan.sprint.goal,
        tokenBudgetLimit: nil,
        items: inputs
      )
      await reloadSelectedProductIfCurrent(productID: productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func assignTicketOwner(
    productID: UUID,
    workItemID: UUID,
    to profileID: UUID?
  ) async -> Bool {
    guard let store = store(for: productID) else { return false }
    do {
      if let draft = try await store.fetchCurrentSprint(productID: productID),
        draft.sprint.state == .draft,
        draft.items.contains(where: { $0.workItemID == workItemID })
      {
        return await reassignDraftTicket(
          productID: productID,
          workItemID: workItemID,
          to: profileID
        )
      }
      if let profileID {
        let productProfiles = try await store.fetchAgentProfiles(productID: productID)
        guard
          productProfiles.contains(where: {
            $0.id == profileID && $0.role.canOwnDelivery
          })
        else { return false }
      }
      _ = try await store.assignWorkItemOwner(id: workItemID, profileID: profileID)
      await reloadSelectedProductIfCurrent(productID: productID)
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
    let productID = plan.sprint.productID
    let sprintID = plan.sprint.id
    do {
      let issues = try await store.sprintReadinessIssues(sprintID: sprintID)
      if selectedProductID == productID {
        sprintReadinessIssues = issues
      }
      guard issues.isEmpty else { return false }


      let startedPlan = try await store.startSprint(id: sprintID)
      if selectedProductID == productID {
        sprintPlan = startedPlan
      }
      await reloadSelectedProductIfCurrent(productID: productID)
      scheduleSprintExecution(productID: productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func pauseSprint(_ sprint: Sprint) async -> Bool {
    guard
      sprint.state == .active,
      let store = store(for: sprint.productID)
    else { return false }

    do {
      _ = try await store.pauseSprint(id: sprint.id)
      pausedSprintProductIDs.insert(sprint.productID)
      await suspendSprintExecution(productID: sprint.productID)
      pausedSprintProductIDs.remove(sprint.productID)
      await stopDemoSessions(productID: sprint.productID, includesPreparation: true)
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return true
    } catch {
      pausedSprintProductIDs.remove(sprint.productID)
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return false
    }
  }

  func resumeSprint(_ sprint: Sprint) async -> Bool {
    guard
      sprint.state == .paused,
      let store = store(for: sprint.productID)
    else { return false }

    do {
      _ = try await store.resumeSprint(id: sprint.id)
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      scheduleSprintExecution(productID: sprint.productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return false
    }
  }

  func stopSprint(_ sprint: Sprint) async -> Bool {
    guard
      sprint.state.isInProgress,
      let store = store(for: sprint.productID)
    else { return false }

    stoppingSprintProductIDs.insert(sprint.productID)
    defer { stoppingSprintProductIDs.remove(sprint.productID) }
    do {
      if sprint.state == .active {
        _ = try await store.pauseSprint(id: sprint.id)
      }
      await suspendSprintExecution(productID: sprint.productID)
      await stopDemoSessions(productID: sprint.productID, includesPreparation: true)
      _ = try await store.cancelSprint(id: sprint.id)
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
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


      let startedIntegration = await processIntegrationCandidates(context: context)
      let hasActiveImplementation = activeImplementationProductIDs.values.contains(productID)
      let hasActiveIntegration = activeIntegrationProductIDs.values.contains(productID)
      if !hasActiveImplementation,
        !hasActiveIntegration,
        eligibleRuns.isEmpty,
        !startedIntegration
      {
        return
      }
      if (hasActiveImplementation || hasActiveIntegration) && !startedIntegration {
        guard await wakeIterator.next() != nil else { return }
      }
    }
  }

  private func sprintExecutionContext(productID: UUID) async -> SprintExecutionContext? {
    guard let store = store(for: productID) else { return nil }
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
      let store = store(for: productID),
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
    var expiredPermissionRunIDs = Set(expiredPermissionRuns.map(\.id))
    for run in expiredPermissionRuns {
      let isImplementer = implementerByItemID[run.workItemID] == run.profileID
      let latestCandidate =
        storedCandidates
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
      if canResumeReview {
        expiredPermissionRunIDs.remove(run.id)
        if run.status != .queued {
          _ = try? await updateAgentRun(
            id: run.id,
            status: .queued,
            eventActor: "Spedito",
            eventDetail: "Review capability request retired; read-only review queued to continue"
          )
          _ = try? await store.appendComment(
            workItemID: run.workItemID,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The earlier tech lead permission request is no longer needed. Review will continue as a read-only inspection of the existing candidate and delivery evidence."
          )
        }
        continue
      }
      let canResume = isImplementer || canResumeConflict
      let latestRequest =
        permissionRequests
        .filter { $0.agentRunID == run.id }
        .max(by: { $0.updatedAt < $1.updatedAt })
      let hasSavedDecision = latestRequest?.status.isPendingDelivery == true
      let recoveredStatus: AgentRunStatus =
        if canResume && hasSavedDecision {
          .queued
        } else {
          canResume ? .awaitingOwner : .interrupted
        }
      let recoveryEventDetail: String
      let recoveryComment: String
      if hasSavedDecision {
        recoveryEventDetail = "Saved permission decision queued for recovery"
        recoveryComment =
          "Spedito recovered the saved permission decision without asking again. The preserved conversation and workspace are queued to continue, and the decision will be delivered if the agent requests the same capability again."
      } else if canResume {
        recoveryEventDetail =
          "Expired permission request remains paused for product owner input"
        recoveryComment =
          "The live permission request expired when Spedito stopped. The conversation and workspace are preserved, and the request remains above for your decision. Work will resume only after you choose Allow or Deny."
      } else {
        recoveryEventDetail = "Permission request expired when the app stopped"
        recoveryComment =
          "The previous permission request expired when Spedito stopped. This run cannot continue automatically."
      }
      if run.status != recoveredStatus {
        _ = try? await updateAgentRun(
          id: run.id,
          status: recoveredStatus,
          eventActor: "Spedito",
          eventDetail: recoveryEventDetail
        )
        if canResume, !hasSavedDecision,
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
          authorName: "Spedito",
          body: recoveryComment
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
        let deliveryKind = try await validateDeliveryEvidence(
          result,
          assignee: assignee,
          workspaceURL: URL(
            fileURLWithPath: candidate.worktreePath,
            isDirectory: true
          )
        )
        guard deliveryKind == candidate.deliveryKind else {
          throw TicketExecutionGenerationError.invalidResponse(
            "The persisted candidate delivery kind no longer matches its evidence."
          )
        }
        if item.state == .integrating {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .verifying,
            actor: "Spedito",
            reason: "Recovered the reviewed candidate after restart"
          )
        }
        if item.state == .integrating || item.state == .verifying {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .acceptance,
            actor: "Spedito",
            reason: "Recovered the completed tech lead review"
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
            actor: "Spedito",
            reason: "The candidate contained no inspectable delivery artefact"
          )
        }
        _ = try? await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Spedito",
          eventDetail: "Empty candidate returned to the assigned specialist"
        )
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "Candidate v\(candidate.version) contained no inspectable ticket artefact or meaningful review evidence. I returned the preserved workspace to the assigned specialist to complete the actual delivery."
        )
      } catch {
        continue
      }
    }
    for run in runs
    where
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
            productInstructions: inheritedAgentInstructions(for: product),
            customInstructions: assignee.customInstructionText,
            assignee: assignee,
            savedPermissionGrants: context.permissionGrants
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
        let deliveryKind = try await validateDeliveryEvidence(
          result,
          assignee: assignee,
          workspaceURL: workspace
        )
        await processExecutionResult(
          result,
          deliveryKind: deliveryKind,
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
          candidate.status == .resolvingConflict
        {
          _ = try? await updateAgentRun(
            id: run.id,
            status: .queued,
            eventActor: "Spedito",
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
          _ = try? await updateAgentRun(
            id: run.id,
            status: .queued,
            eventActor: "Spedito",
            eventDetail: "Interrupted tech lead review queued to continue"
          )
          continue
        }
        _ = try? await updateAgentRun(
          id: run.id,
          status: .interrupted,
          eventActor: "Spedito",
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
            actor: "Spedito",
            reason: "Recovering an interrupted review"
          )
        case .integrating:
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .running,
            actor: "Spedito",
            reason: "Recovering an interrupted integration"
          )
        default:
          break
        }
      }
      _ = try? await updateAgentRun(
        id: run.id,
        status: .queued,
        eventActor: "Spedito",
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
            actor: "Spedito",
            reason: "Candidate restored to the integration queue"
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

      guard let integratedSHA = candidate.integratedSHA else {
        let repositoryURL = try? Self.productWorkspaceURL(productID: productID)
        if let integrationPath = candidate.integrationWorktreePath, let repositoryURL {
          try? await gitWorkspaceManager.removeWorktree(
            repositoryURL: repositoryURL,
            worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
          )
        }
        if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: candidate,
          runs: runs,
          reviewerProfileIDs: reviewerProfileIDs
        ) {
          _ = try? await updateAgentRun(
            id: reviewRun.id,
            status: .interrupted,
            eventActor: "Spedito",
            eventDetail: "Review retired so integration can complete first"
          )
        }
        _ = try? await store.updateCandidateRevision(
          id: candidate.id,
          status: .queuedForIntegration
        )
        if item.state == .verifying {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .running,
            actor: "Spedito",
            reason: "Preparing the candidate for integration before review"
          )
        }
        if item.state == .verifying || item.state == .running {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "Spedito",
            reason: "Candidate queued for integration before review"
          )
        }
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "Spedito preserved this candidate and will integrate the latest accepted local and GitHub changes before restarting tech lead review."
        )
        continue
      }

      do {
        let repositoryURL = try Self.productWorkspaceURL(productID: productID)
        let reviewWorkspace = try await gitWorkspaceManager.prepareIntegratedWorkspace(
          repositoryURL: repositoryURL,
          integrationsRootURL: Self.integrationWorktreesRootURL(productID: productID),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: integratedSHA
        )
        if candidate.integrationWorktreePath != reviewWorkspace.url.path {
          _ = try await store.updateCandidateRevision(
            id: candidate.id,
            status: .reviewing,
            integratedSHA: integratedSHA,
            integrationWorktreePath: reviewWorkspace.url.path
          )
        }

        if item.state == .running {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "Spedito",
            reason: "Recovered the integrated review candidate"
          )
        }
        if item.state == .running || item.state == .integrating {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .verifying,
            actor: "Spedito",
            reason: "Continuing tech lead review after restart"
          )
        }

        if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: candidate,
          runs: runs,
          reviewerProfileIDs: reviewerProfileIDs
        ) {
          if expiredPermissionRunIDs.contains(reviewRun.id) {
            _ = try? await updateAgentRun(
              id: reviewRun.id,
              status: .awaitingOwner,
              worktreePath: reviewWorkspace.url.path
            )
          } else if reviewRun.status != .completed {
            _ = try? await updateAgentRun(
              id: reviewRun.id,
              status: .queued,
              worktreePath: reviewWorkspace.url.path,
              eventActor: "Spedito",
              eventDetail: "Tech lead review queued to continue against the same revision"
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
        await restoreCandidateToIntegrationQueue(
          candidate,
          context: context,
          reason:
            "The exact integrated revision could not be restored: \(error.localizedDescription)"
        )
      }
    }

    let latestCandidateByWorkItemID = Dictionary(
      grouping: storedCandidates,
      by: \.workItemID
    ).compactMapValues { candidates in
      candidates.max { $0.version < $1.version }
    }
    for run in runs
    where
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
        _ = try? await updateAgentRun(
          id: run.id,
          status: .completed,
          eventActor: "Spedito",
          eventDetail: "Implementation preserved; malformed review queued to retry"
        )
        _ = try? await store.updateCandidateRevision(
          id: failedCandidate.id,
          status: .queuedForIntegration
        )
        if let item = workItems.first(where: { $0.id == run.workItemID }),
          item.state == .running
        {
          _ = try? await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: "Spedito",
            reason: "Retrying a malformed tech lead review against the preserved candidate"
          )
        }
        _ = try? await store.appendComment(
          workItemID: run.workItemID,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The implementation was valid; the tech lead’s structured response was malformed. Candidate v\(failedCandidate.version) has been preserved and queued for integration and review again without repeating the delivery work."
        )
        continue
      }
      guard latestSystemFailure.body.localizedCaseInsensitiveContains("thread not found")
      else { continue }
      _ = try? await updateAgentRun(
        id: run.id,
        status: .queued,
        eventActor: "Spedito",
        eventDetail: "Transient Codex session failure queued to recover automatically"
      )
      _ = try? await store.appendComment(
        workItemID: run.workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "The previous failure was caused by an expired Codex session rather than the ticket work. Recovery has been queued automatically in the preserved workspace."
      )
    }

    if let techLead = profiles.first(where: { $0.role == .lead }) {
      for candidate in storedCandidates where candidate.status == .resolvingConflict {
        let candidateRuns = runs.filter {
          $0.workItemID == candidate.workItemID && $0.profileID == techLead.id
        }
        if let latest = candidateRuns.max(by: { $0.createdAt < $1.createdAt }) {
          if expiredPermissionRunIDs.contains(latest.id) {
            _ = try? await updateAgentRun(
              id: latest.id,
              status: .awaitingOwner
            )
          } else if latest.status == .interrupted || latest.status == .failed {
            _ = try? await updateAgentRun(
              id: latest.id,
              status: .queued,
              eventActor: "Spedito",
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
    let productID = context.product.id
    guard let store = store(for: productID) else { return }
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
      _ = try? await updateAgentRun(
        id: reviewRun.id,
        status: .interrupted,
        eventActor: "Spedito",
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
          actor: "Spedito",
          reason: "The exact reviewed revision could not be recovered"
        )
      }
      if item.state == .running || item.state == .verifying {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: "Spedito",
          reason: "Candidate restored to the integration queue"
        )
      }
    }
    _ = try? await store.appendComment(
      workItemID: candidate.workItemID,
      authorKind: .system,
      authorName: "Spedito",
      body:
        "\(reason)\n\nCandidate v\(candidate.version) will be integrated and reviewed again so the product owner never receives an unverified revision."
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
  private func processIntegrationCandidates(
    context: SprintExecutionContext
  ) async -> Bool {
    let plan = context.plan
    let profiles = context.profiles
    let runs = context.runs
    let workItems = context.workItems
    let productID = plan.sprint.productID
    guard let store = store(for: productID) else { return false }
    do {
      try await requeueStaleReadyCandidates(productID: productID)
      let candidates = try await store.fetchCandidateRevisions(productID: productID)
      var startedTask = false
      let techLeadID = profiles.first(where: { $0.role == .lead })?.id
      let reviewerProfileIDs = Set(
        profiles
          .filter { $0.role == .lead }
          .map(\.id)
      )
      let reviewingCandidates =
        candidates
        .filter {
          $0.sprintID == plan.sprint.id
            && $0.status == .reviewing
            && $0.integratedSHA != nil
        }
        .sorted { $0.createdAt < $1.createdAt }
      for reviewingCandidate in reviewingCandidates
      where activeIntegrationTasks[reviewingCandidate.id] == nil {
        guard
          let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
            for: reviewingCandidate,
            runs: runs,
            reviewerProfileIDs: reviewerProfileIDs
          ),
          reviewRun.status == .queued
            || reviewRun.status == .running
            || reviewRun.status == .completed
        else { continue }
        activeIntegrationProductIDs[reviewingCandidate.id] = productID
        activeIntegrationTasks[reviewingCandidate.id] = Task { [weak self] in
          guard let self else { return }
          defer {
            activeIntegrationTasks.removeValue(forKey: reviewingCandidate.id)
            activeIntegrationProductIDs.removeValue(forKey: reviewingCandidate.id)
            sprintExecutionWakeContinuations[productID]?.yield()
          }
          await resumeTechLeadReview(
            candidate: reviewingCandidate,
            reviewRun: reviewRun,
            plan: plan
          )
        }
        startedTask = true
      }
      let resolvingCandidates =
        candidates
        .filter {
          $0.sprintID == plan.sprint.id && $0.status == .resolvingConflict
        }
        .sorted { $0.createdAt < $1.createdAt }
      for resolvingCandidate in resolvingCandidates
      where activeIntegrationTasks[resolvingCandidate.id] == nil {
        let resolutionRuns =
          runs
          .filter {
            $0.workItemID == resolvingCandidate.workItemID
              && $0.profileID == techLeadID
              && $0.worktreePath == resolvingCandidate.integrationWorktreePath
          }
        if let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }),
          let worktreePath = resolvingCandidate.integrationWorktreePath,
          try await gitWorkspaceManager.conflictResolutionIsReadyToCommit(
            integrationWorkspaceURL: URL(
              fileURLWithPath: worktreePath,
              isDirectory: true
            )
          )
        {
          activeIntegrationProductIDs[resolvingCandidate.id] = productID
          activeIntegrationTasks[resolvingCandidate.id] = Task { [weak self] in
            guard let self else { return }
            defer {
              activeIntegrationTasks.removeValue(forKey: resolvingCandidate.id)
              activeIntegrationProductIDs.removeValue(forKey: resolvingCandidate.id)
              sprintExecutionWakeContinuations[productID]?.yield()
            }
            await completePreservedIntegrationConflict(
              candidate: resolvingCandidate,
              resolutionRun: resolutionRun,
              plan: plan
            )
          }
          startedTask = true
          continue
        }
        if let resolutionRun =
          resolutionRuns
          .filter({ $0.status == .queued })
          .max(by: { $0.createdAt < $1.createdAt })
        {
          activeIntegrationProductIDs[resolvingCandidate.id] = productID
          activeIntegrationTasks[resolvingCandidate.id] = Task { [weak self] in
            guard let self else { return }
            defer {
              activeIntegrationTasks.removeValue(forKey: resolvingCandidate.id)
              activeIntegrationProductIDs.removeValue(forKey: resolvingCandidate.id)
              sprintExecutionWakeContinuations[productID]?.yield()
            }
            await resumeIntegrationConflictResolution(
              candidate: resolvingCandidate,
              resolutionRun: resolutionRun,
              plan: plan
            )
          }
          startedTask = true
        }
      }
      let integrationCandidates = SprintCandidateAdmission.integrationQueue(
        candidates: candidates,
        sprintID: plan.sprint.id,
        workItems: workItems
      )
      for candidate in integrationCandidates
      where activeIntegrationTasks[candidate.id] == nil {
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .integrating
        )
        activeIntegrationProductIDs[candidate.id] = productID
        activeIntegrationTasks[candidate.id] = Task { [weak self] in
          guard let self else { return }
          defer {
            activeIntegrationTasks.removeValue(forKey: candidate.id)
            activeIntegrationProductIDs.removeValue(forKey: candidate.id)
            sprintExecutionWakeContinuations[productID]?.yield()
          }
          await integrateCandidateBeforeReview(candidate, plan: plan)
        }
        startedTask = true
      }
      if !integrationCandidates.isEmpty {
        await reloadSelectedProductIfCurrent(productID: context.product.id)
      }
      return startedTask
    } catch {
      presentExecutionError(error, productID: context.product.id)
      return false
    }
  }

  private func requeueStaleReadyCandidates(
    productID: UUID,
    excluding excludedCandidateID: UUID? = nil
  ) async throws {
    guard let store = store(for: productID) else { return }
    let repositoryURL = try Self.productWorkspaceURL(productID: productID)
    let candidates = try await store.fetchCandidateRevisions(productID: productID)
    for candidate in candidates
    where
      candidate.id != excludedCandidateID
      && candidate.deliveryKind.changesRepository
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
    guard let store = store(for: candidate.productID) else { return }
    await stopDemoSession(candidate, removesPreview: true)
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .queuedForIntegration
    )
    if let item = try await store.fetchWorkItems(productID: candidate.productID)
      .first(where: { $0.id == candidate.workItemID })
    {
      if item.state == .acceptance {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: String(reason.prefix(160))
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: "Spedito",
          reason: "The reviewed candidate is queued to integrate again"
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: "Spedito",
          reason: "The reviewed candidate is waiting to integrate"
        )
      } else if item.state == .integrating {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: "Spedito",
          reason: "The reviewed candidate is waiting to integrate"
        )
      }
    }
    _ = try await store.appendComment(
      workItemID: candidate.workItemID,
      authorKind: .system,
      authorName: "Spedito",
      body:
        "\(reason)\n\nCandidate v\(candidate.version) kept its tech lead approval and returned to the integration queue. A clean local merge will only repeat demo preparation; incorporated GitHub changes or a conflict will receive focused tech lead re-review."
    )
  }

  private func executeImplementationRun(
    _ queuedRun: AgentRun,
    context: SprintExecutionContext
  ) async {
    guard
      let store = store(for: context.product.id),
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
      if let storedPath = run.worktreePath,
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
            authorName: "Spedito",
            body:
              "The previous ticket workspace was unavailable. Spedito prepared a fresh isolated \(item.key) workspace, so work that was not captured in a durable candidate could not be recovered."
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
      let latestCandidate =
        currentCandidates
        .filter { $0.workItemID == item.id }
        .max(by: { $0.version < $1.version })
      let adoptedBaseline: TicketRevisionBaseline? =
        if let latestCandidate,
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
          includesMandatoryKnowledge: false
        ),
        customInstructions: assignee.customInstructionText,
        assignee: assignee,
        savedPermissionGrants: context.permissionGrants
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
            authorName: "Spedito",
            body:
              "The previous conversation could not be recovered. I started a replacement in the preserved ticket workspace and continued the work."
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
      run = try await updateAgentRun(
        id: run.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path,
        eventActor: replacedUnavailableThread ? "Spedito" : nil,
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable conversation and preserved the ticket workspace"
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
          runtimeWorkspaceRoots: [
            workspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
        run = try await updateAgentRun(
          id: run.id,
          status: .running,
          codexThreadID: activeThreadID,
          worktreePath: workspace.path,
          eventActor: "Spedito",
          eventDetail: "Replaced a stale Codex thread and preserved the ticket workspace"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The previous Codex session was no longer available. I started a replacement session in the preserved ticket workspace and continued the work."
        )
        turnPrompt = executionPrompt
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: turnPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
      let validated = try await validatedExecutionResult(
        response,
        client: client,
        threadID: activeThreadID,
        runID: run.id,
        productID: product.id,
        assignee: assignee,
        workspaceURL: workspace,
        canonicalKnowledgePages: knowledgeSelection.directoryPages
      )
      await processExecutionResult(
        validated.result,
        deliveryKind: validated.deliveryKind,
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
      let wasPausedBySprint =
        Task.isCancelled && pausedSprintProductIDs.contains(product.id)
      let wasStoppedBySprint =
        Task.isCancelled && stoppingSprintProductIDs.contains(product.id)
      let status: AgentRunStatus =
        if wasStoppedBySprint {
          .cancelled
        } else {
          sprintWorkRecoveryPolicy.implementationRunStatusAfterTurnStops(
            taskWasCancelled: Task.isCancelled,
            wasManuallyStopped: wasManuallyStopped,
            wasAwaitingPermission: wasAwaitingPermission
          )
        }
      let wasSuspendedByApp =
        Task.isCancelled && !wasManuallyStopped && !wasPausedBySprint
        && !wasStoppedBySprint
      let wasSuspendedAtPermission = wasSuspendedByApp && wasAwaitingPermission
      let eventDetail: String
      let workLogBody: String
      if wasStoppedBySprint {
        eventDetail = "Sprint stopped; ticket workspace preserved"
        workLogBody =
          "The product owner stopped this sprint. This run will not continue automatically. Its conversation and ticket workspace are preserved for audit, and the ticket will return to ready for replanning."
      } else if wasPausedBySprint && wasAwaitingPermission {
        eventDetail = "Sprint paused; permission request remains paused for product owner input"
        workLogBody =
          "The product owner paused this sprint while this run was waiting for a permission decision. Its conversation and ticket workspace are preserved. The decision remains available, but work will not continue until the sprint resumes."
      } else if wasPausedBySprint {
        eventDetail = "Sprint paused; preserved work queued to continue"
        workLogBody =
          "The product owner paused this sprint. This run's conversation and ticket workspace are preserved, and work is queued to continue when the sprint resumes."
      } else if wasSuspendedAtPermission {
        eventDetail = "App stopped; permission request remains paused for product owner input"
        workLogBody =
          "Spedito stopped while this run was waiting for a permission decision. Its conversation and ticket workspace are preserved, and work will remain paused after relaunch until the product owner chooses Allow or Deny."
      } else if wasSuspendedByApp {
        eventDetail = "App stopped; preserved work queued to continue"
        workLogBody =
          "Spedito paused this run while stopping. Its conversation and ticket workspace are preserved, and it is queued to continue automatically."
      } else if wasManuallyStopped {
        eventDetail = "Stopped manually; ticket workspace preserved"
        workLogBody =
          "This run was stopped by the product owner. Its ticket workspace has been preserved and can be resumed with a new comment."
      } else {
        eventDetail = error.localizedDescription
        workLogBody = "The agent run stopped unexpectedly: \(error.localizedDescription)"
      }
      _ = try? await updateAgentRun(
        id: run.id,
        status: status,
        eventActor: "Spedito",
        eventDetail: eventDetail
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
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
    workspaceURL: URL,
    canonicalKnowledgePages: [KnowledgePage]
  ) async throws -> (result: TicketExecutionResult, deliveryKind: CandidateDeliveryKind) {
    do {
      let result = try CodexTicketExecutor.decode(response)
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: result,
        canonicalPages: canonicalKnowledgePages
      )
      try CodexTicketExecutor.validateFollowUpTicketProposals(
        in: result,
        assignee: assignee
      )
      let deliveryKind = try await validateDeliveryEvidence(
        result,
        assignee: assignee,
        workspaceURL: workspaceURL
      )
      return (result, deliveryKind)
    } catch let validationError as TicketExecutionGenerationError {
      let repairTurnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketExecutor.repairPrompt(
          validationError: validationError.localizedDescription
        ),
        effort: assignee.reasoningEffort,
        outputSchema: CodexTicketExecutor.outputSchema,
        runtimeWorkspaceRoots: [
          workspaceURL,
          try Self.productDatabaseURL(productID: productID).deletingLastPathComponent(),
        ]
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
        try CodexTicketExecutor.validateKnowledgePageProposals(
          in: repairedResult,
          canonicalPages: canonicalKnowledgePages
        )
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: repairedResult,
          assignee: assignee
        )
        let deliveryKind = try await validateDeliveryEvidence(
          repairedResult,
          assignee: assignee,
          workspaceURL: workspaceURL
        )
        return (repairedResult, deliveryKind)
      } catch {
        stopLiveActivityMonitoring(runID: runID)
        activeExecutionTurns.removeValue(forKey: runID)
        throw error
      }
    }
  }

  private func validateDeliveryEvidence(
    _ result: TicketExecutionResult,
    assignee: AgentProfile,
    workspaceURL: URL
  ) async throws -> CandidateDeliveryKind {
    let actualChangePaths: [String]
    if result.status == .completed || result.decisionArtifact != nil {
      actualChangePaths = try await gitWorkspaceManager.ticketChangePaths(
        ticketWorkspaceURL: workspaceURL
      )
    } else {
      actualChangePaths = []
    }
    if let decisionArtifact = result.decisionArtifact {
      _ = try TicketDecisionArtifactValidator.resolveExistingFile(
        decisionArtifact,
        in: workspaceURL
      )
      guard actualChangePaths.contains(decisionArtifact.path) else {
        throw TicketExecutionGenerationError.invalidResponse(
          "decisionArtifact must reference a file created or changed by this ticket."
        )
      }
    }
    guard result.status == .completed else { return .repositoryChange }
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
    let deliveryKind: CandidateDeliveryKind
    do {
      deliveryKind = try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: assignee.role,
        changedPaths: actualChangePaths
      )
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
    }
    if deliveryKind == .localOutcome {
      guard result.demo == nil else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Repository-free research uses its in-app outcome review and must not supply a managed demo."
        )
      }
      return deliveryKind
    }
    guard let demo = result.demo else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Repository-changing work needs a managed demo recipe for the product owner."
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
    guard !reportedChangePaths.isDisjoint(with: Set(actualChangePaths)) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The reported changed files do not identify an inspectable ticket artefact."
      )
    }
    return deliveryKind
  }

  private func processExecutionResult(
    _ result: TicketExecutionResult,
    deliveryKind: CandidateDeliveryKind,
    implementationRunID: UUID,
    reviewCycle: Int,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
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
          TicketOwnerQuestion(
            prompt: $0,
            options: result.options,
            decisionArtifact: result.decisionArtifact
          )
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
      _ = try? await updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        eventActor: assignee.name,
        eventDetail: "Waiting for product owner input"
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
        _ = try await store.upsertDeliveryNote(
          productID: item.productID,
          sprint: plan.sprint,
          item: item,
          bodyMarkdown: deliveryNote,
          authorName: assignee.name
        )

        let version = try await store.nextCandidateRevisionVersion(workItemID: item.id)
        let workspaceURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let snapshot =
          if deliveryKind.changesRepository {
            try await gitWorkspaceManager.createCandidate(
              ticketWorkspaceURL: workspaceURL,
              ticketKey: item.key,
              version: version,
              authorName: assignee.name,
              summary: result.summary
            )
          } else {
            try await gitWorkspaceManager.snapshotLocalOutcomeCandidate(
              ticketWorkspaceURL: workspaceURL
            )
          }
        let resultData = try JSONEncoder().encode(result)
        guard let resultJSON = String(data: resultData, encoding: .utf8) else {
          throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let sprintItemID =
          run.sprintItemID
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
            deliveryKind: deliveryKind,
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
            reason: deliveryKind.changesRepository
              ? "Candidate v\(candidate.version) queued for integration"
              : "Outcome v\(candidate.version) queued for review"
          )
        }
        _ = try await updateAgentRun(
          id: run.id,
          status: .completed,
          eventActor: assignee.name,
          eventDetail: deliveryKind.changesRepository
            ? "Candidate v\(candidate.version) queued for integration"
            : "Outcome v\(candidate.version) queued for review"
        )
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        _ = try? await updateAgentRun(
          id: run.id,
          status: .awaitingOwner,
          eventActor: "Spedito",
          eventDetail: "Could not create an immutable candidate revision"
        )
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The work is preserved, but Spedito could not prepare it for review: \(error.localizedDescription)"
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
      let store = store(for: plan.sprint.productID),
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
      let candidateKnowledgePageProposals = try await store.fetchKnowledgePageProposals(
        productID: product.id
      ).filter { proposal in
        proposal.candidateRevisionID == candidate.id
      }
      let developerInstructions = CodexTechLeadReviewer.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product),
        customInstructions: techLead.customInstructionText,
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
            allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
            readOnlyProductDirectory: try Self.productDatabaseURL(
              productID: product.id
            ).deletingLastPathComponent()
          )
          resumedReviewThreadID = resumedThreadID
          if let recoveredResponse = try? await client.latestCompletedAgentMessage(
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
        knowledgePageProposals: candidateKnowledgePageProposals,
        assignee: implementer,
        reviewCycle: reviewCycle,
        priorReviewFeedback: priorReviewFeedback,
        recentComments: reviewComments,
        deliveryKind: candidate.deliveryKind,
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
        turnPrompt = """
          \(CodexTechLeadReviewer.recoveryPrompt(
            item: item,
            reviewedSHA: reviewWorkspace.integratedSHA,
            isIntegratedRevision: integration != nil,
            interruptedPermission: interruptedPermission
          ))

          AUTHORITATIVE CANDIDATE REVIEW CONTEXT
          Re-read this complete immutable context before deciding. It supersedes any incomplete
          candidate context from an earlier turn in this conversation.

          \(fullReviewPrompt)
          """
      } else {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: reviewWorkspace.url,
          developerInstructions: developerInstructions,
          model: techLead.model,
          allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
          readOnlyProductDirectory: try Self.productDatabaseURL(
            productID: product.id
          ).deletingLastPathComponent()
        )
        turnPrompt = fullReviewPrompt
        if replacedUnavailableThread {
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The previous tech lead conversation was unavailable. I started a replacement against the same immutable revision; implementation was not repeated."
          )
        }
      }

      _ = try await updateAgentRun(
        id: reviewRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: reviewWorkspace.url.path,
        eventActor: "Spedito",
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable review conversation"
          : "Continuing tech lead review against the same immutable revision"
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: turnPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [
            reviewWorkspace.url,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: reviewWorkspace.url,
          developerInstructions: developerInstructions,
          model: techLead.model,
          allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
          readOnlyProductDirectory: try Self.productDatabaseURL(
            productID: product.id
          ).deletingLastPathComponent()
        )
        turnPrompt = fullReviewPrompt
        _ = try await updateAgentRun(
          id: reviewRun.id,
          status: .running,
          codexThreadID: threadID,
          worktreePath: reviewWorkspace.url.path,
          eventActor: "Spedito",
          eventDetail: "Replaced an unavailable review conversation"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The previous tech lead conversation was unavailable. I started a replacement against the same immutable revision; implementation was not repeated."
        )
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: turnPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [
            reviewWorkspace.url,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
        initialText: "Continuing the tech lead review…"
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
          runtimeWorkspaceRoots: [
            reviewWorkspace.url,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
        _ = try? await updateAgentRun(
          id: reviewRun.id,
          status: .interrupted,
          eventActor: "Spedito",
          eventDetail: "Tech lead review paused when the app stopped"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }

      _ = try? await updateAgentRun(
        id: reviewRun.id,
        status: .failed,
        eventActor: "Spedito",
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
          actor: "Spedito",
          reason: "Review continuation stopped; preserving work for retry"
        )
      }
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Tech lead review continuation could not complete"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Tech lead review continuation stopped unexpectedly: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved implementation workspace."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }


  private func integrateCandidateBeforeReview(
    _ candidate: CandidateRevision,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let context = await sprintExecutionContext(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
    else { return }
    let product = context.product
    do {
      if candidate.deliveryKind == .localOutcome {
        let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
        await reviewCompletedImplementation(
          implementation,
          candidate: candidate,
          implementationRun: implementationRun,
          reviewCycle: max(0, candidate.version - 1),
          plan: plan
        )
        return
      }
      let repositoryURL = try Self.productWorkspaceURL(productID: product.id)
      var integration: GitIntegrationSnapshot
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
          conflictedFiles: conflictedFiles,
          includesGitHubChanges: false
        )
        return
      }

      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating,
        integratedSHA: integration.integratedSHA,
        integrationWorktreePath: integration.url.path
      )

      let remoteIntegration: (
        snapshot: GitIntegrationSnapshot,
        incorporatedChanges: Bool,
        remoteSHA: String?
      )
      do {
        remoteIntegration = try await integrateLatestGitHubChanges(
          candidate: candidate,
          integration: integration
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
          conflictedFiles: conflictedFiles,
          includesGitHubChanges: true
        )
        return
      }
      integration = remoteIntegration.snapshot
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating,
        integratedSHA: integration.integratedSHA,
        integrationWorktreePath: integration.url.path
      )

      let implementation = try CodexTicketExecutor.decode(
        candidate.executionResultJSON
      )
      if remoteIntegration.incorporatedChanges, let remoteSHA = remoteIntegration.remoteSHA {
        let message =
          "Integrated verified GitHub changes at \(String(remoteSHA.prefix(8))) into this ticket before final review."
        let comments = try await store.fetchComments(workItemID: item.id)
        if !comments.contains(where: { $0.body == message }) {
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body: message
          )
        }
      }
      await reviewCompletedImplementation(
        implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        preparedIntegration: integration
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
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Candidate integration could not complete"
      )
      if let currentState = try? await store.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state,
        currentState == .integrating || currentState == .verifying
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: "Integration stopped; preserving the candidate"
        )
      }
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "The candidate could not be integrated or prepared for review: \(error.localizedDescription)\n\nThe candidate revision and ticket workspace are preserved for retry."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }

  private func integrateLatestGitHubChanges(
    candidate: CandidateRevision,
    integration: GitIntegrationSnapshot
  ) async throws -> (
    snapshot: GitIntegrationSnapshot,
    incorporatedChanges: Bool,
    remoteSHA: String?
  ) {
    guard let githubRemoteService else {
      return (integration, false, nil)
    }
    let current = await githubRemoteService.state(productID: candidate.productID)
    guard let connection = current.connection else {
      return (integration, false, nil)
    }
    switch connection.status {
    case .disconnected, .selectingRepository:
      return (integration, false, nil)
    case .connected:
      break
    case .needsAuthorization, .needsInstallation, .needsTargetReview, .unavailable,
      .initializingRemote:
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "Reconnect this Product to GitHub before this ticket can finish review."
      )
    }

    let preparation = try await githubRemoteService.prepareTicketIntegration(
      productID: candidate.productID
    )
    githubRemoteRepositoryStates[candidate.productID] = preparation.state
    guard let base = preparation.base else {
      return (integration, false, nil)
    }
    let updated = try await gitWorkspaceManager.integrateVerifiedRemote(
      repositoryURL: Self.productWorkspaceURL(productID: candidate.productID),
      integrationWorkspaceURL: integration.url,
      observationRef: base.observationRef,
      expectedRemoteSHA: base.remoteSHA,
      candidateHeadSHA: candidate.headSHA
    )
    return (
      updated,
      updated.integratedSHA != integration.integratedSHA,
      base.remoteSHA
    )
  }

  private func finalizeReviewedIntegration(
    candidateID: UUID,
    implementation: TicketExecutionResult,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let store = store(for: workItem.productID) else { return }
    let integratedCandidate = try await store.fetchCandidateRevision(id: candidateID)
    guard
      let integratedSHA = integratedCandidate.integratedSHA,
      let demo = implementation.demo
    else {
      throw DemoLaunchValidationError.invalid(
        "the reviewed candidate has no managed demo recipe."
      )
    }
    let ticketPublication: RemotePublication?
    do {
      ticketPublication = try await prepareTicketPullRequestIfConnected(
        productID: workItem.productID,
        workItemID: workItem.id,
        candidateRevisionID: integratedCandidate.id
      )
    } catch GitHubRemoteRepositoryServiceError.ticketIntegrationRequired {
      try await requeueStaleReadyCandidate(
        integratedCandidate,
        reason:
          "GitHub changed while this ticket was being prepared for review. Spedito will integrate the latest verified changes and review the ticket again."
      )
      await reloadSelectedProductIfCurrent(productID: workItem.productID)
      scheduleSprintExecution(productID: workItem.productID)
      return
    }
    do {
      try await prepareDemoForAcceptance(
        candidate: integratedCandidate,
        integratedSHA: integratedSHA,
        specification: demo
      )
    } catch {
      guard
        DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate
      else {
        throw error
      }
      try await returnDemoFailureForCorrection(
        candidateID: candidateID,
        implementationRun: implementationRun,
        workItem: workItem,
        error: error
      )
      return
    }
    let repositoryURL = try Self.productWorkspaceURL(productID: workItem.productID)
    guard
      try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
        repositoryURL: repositoryURL,
        integratedSHA: integratedSHA
      )
    else {
      try await requeueStaleReadyCandidate(
        integratedCandidate,
        reason: "Accepted trunk advanced while this demo revision was being prepared."
      )
      return
    }
    _ = try await store.updateCandidateRevision(
      id: candidateID,
      status: .readyForDemo
    )
    try await markTicketPullRequestReadyIfNeeded(ticketPublication)
    _ = try await updateAgentRun(
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
          reason: "Reviewed candidate integrated; ready for product owner demo"
        )
      }
    }
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
  }

  private func finalizeReviewedLocalOutcome(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let store = store(for: workItem.productID) else { return }
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .readyForDemo
    )
    _ = try await updateAgentRun(
      id: implementationRun.id,
      status: .completed,
      eventActor: reviewerName,
      eventDetail: "Reviewed local outcome ready for product owner review"
    )
    if let currentState = try await store.fetchWorkItems(productID: workItem.productID)
      .first(where: { $0.id == workItem.id })?.state
    {
      if currentState == .integrating {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .verifying,
          actor: reviewerName,
          reason: "Recovered the reviewed local outcome"
        )
      }
      if currentState == .integrating || currentState == .verifying {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .acceptance,
          actor: reviewerName,
          reason: "Reviewed local outcome ready for product owner review"
        )
      }
    }
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
  }

  private func returnDemoFailureForCorrection(
    candidateID: UUID,
    implementationRun: AgentRun,
    workItem: WorkItem,
    error: Error
  ) async throws {
    guard let store = store(for: workItem.productID) else { return }
    let candidate = try await store.fetchCandidateRevision(id: candidateID)
    guard let integratedSHA = candidate.integratedSHA else {
      throw PersistenceError.corruptData(
        "The failed demo candidate has no integrated revision to preserve."
      )
    }

    let errorDetail = error.localizedDescription
    await stopDemoSession(candidate, removesPreview: true)
    _ = try await adoptIntegratedBaselineForRevision(
      candidate: candidate,
      integratedSHA: integratedSHA
    )
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .changesRequested
    )
    try await store.markKnowledgePageProposals(
      candidateRevisionID: candidate.id,
      status: .superseded
    )
    if let integrationPath = candidate.integrationWorktreePath {
      try? await gitWorkspaceManager.removeWorktree(
        repositoryURL: Self.productWorkspaceURL(productID: workItem.productID),
        worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
      )
    }
    if let currentState = try await store.fetchWorkItems(
      productID: workItem.productID
    ).first(where: { $0.id == workItem.id })?.state,
      currentState == .integrating || currentState == .verifying
    {
      _ = try await store.transitionWorkItem(
        id: workItem.id,
        to: .running,
        actor: "Spedito",
        reason: "Demo verification failed; correction queued"
      )
    }

    let reviewCycle = max(0, candidate.version - 1)
    let automaticallyRevises = SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(
      reviewCycle: reviewCycle
    )
    _ = try await updateAgentRun(
      id: implementationRun.id,
      status: automaticallyRevises ? .queued : .awaitingOwner,
      eventActor: "Spedito",
      eventDetail: automaticallyRevises
        ? "Demo verification failed; correction queued for the implementer"
        : "Automatic corrections paused after repeated demo verification failures"
    )
    _ = try await store.appendComment(
      workItemID: workItem.id,
      authorKind: .system,
      authorName: "Spedito",
      body:
        automaticallyRevises
        ? """
        The reviewed candidate failed its managed demo verification, so I returned it to the implementer automatically. No product owner decision is needed.

        Error:
        \(errorDetail)

        The reviewed integrated revision is now the ticket workspace baseline. The correction must produce a new candidate and pass tech lead review again.
        """
        : """
        The reviewed candidate failed its managed demo verification:

        \(errorDetail)

        I preserved the integrated revision but paused automatic correction after \(SprintReviewCorrectionPolicy.changeRequestNumber(reviewCycle: reviewCycle)) revision attempts. Add product owner direction to resume the implementer.
        """
    )
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
    if automaticallyRevises {
      scheduleSprintExecution(productID: workItem.productID)
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
      let store = store(for: plan.sprint.productID),
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

    var failureStage = "Tech lead review"
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
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .completed,
        eventActor: implementer.name,
        eventDetail: preparedIntegration == nil
          ? "Implementation complete; waiting for tech lead review"
          : "Integrated candidate ready for tech lead review"
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
          reason: "Independent tech lead review started"
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
          productInstructions: inheritedAgentInstructions(for: product),
          customInstructions: techLead.customInstructionText,
          reviewer: techLead
        ),
        model: techLead.model,
        allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
        readOnlyProductDirectory: try Self.productDatabaseURL(
          productID: product.id
        ).deletingLastPathComponent()
      )
      _ = try await updateAgentRun(
        id: reviewRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path
      )
      let reviewComments = try await store.fetchComments(workItemID: item.id)
      let candidateKnowledgePageProposals = try await store.fetchKnowledgePageProposals(
        productID: product.id
      ).filter { proposal in
        proposal.candidateRevisionID == candidate.id
      }
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
          knowledgePageProposals: candidateKnowledgePageProposals,
          assignee: implementer,
          reviewCycle: reviewCycle,
          priorReviewFeedback: priorReviewFeedback,
          recentComments: reviewComments,
          deliveryKind: candidate.deliveryKind,
          baseSHA: candidate.baseSHA,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: preparedIntegration?.integratedSHA
        ),
        effort: techLead.reasoningEffort,
        outputSchema: CodexTechLeadReviewer.outputSchema,
        runtimeWorkspaceRoots: [
          workspace,
          try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
        ]
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
          runtimeWorkspaceRoots: [
            workspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
          _ = try? await updateAgentRun(
            id: activeReviewRunID,
            status: .interrupted,
            eventActor: "Spedito",
            eventDetail: "Tech lead review paused when the app stopped"
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
        _ = try? await updateAgentRun(
          id: activeReviewRunID,
          status: Task.isCancelled ? .interrupted : .failed,
          eventActor: "Spedito",
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
      if let failedCandidate = try? await store.fetchCandidateRevision(id: candidate.id),
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
          actor: "Spedito",
          reason: "Review stopped; preserving work for retry"
        )
      }
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "\(failureStage) could not complete"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "\(failureStage) stopped unexpectedly: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved workspace."
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
      let store = store(for: plan.sprint.productID),
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
    _ = try await updateAgentRun(id: reviewRun.id, status: .completed)
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
      if candidate.deliveryKind == .localOutcome {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: reviewWorkspace.url
        )
        try await finalizeReviewedLocalOutcome(
          candidate: candidate,
          implementationRun: implementationRun,
          workItem: item,
          reviewerName: techLead.name
        )
        return
      }
      guard integration != nil else {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: reviewWorkspace.url
        )
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .queuedForIntegration
        )
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .completed,
          eventActor: techLead.name,
          eventDetail: "Tech lead review passed; candidate queued for integration"
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
      guard
        SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(
          reviewCycle: reviewCycle
        )
      else {
        let remainingFindings = review.findings.prefix(3)
          .map { "- \($0)" }
          .joined(separator: "\n")
        _ = try await updateAgentRun(
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

            Ask the assigned specialist a question without restarting work, or add product owner direction and choose Submit answers.
            """
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      _ = try await updateAgentRun(
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
        productInstructions: inheritedAgentInstructions(for: product),
        customInstructions: implementer.customInstructionText,
        assignee: implementer,
        savedPermissionGrants: context.permissionGrants
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
            authorName: "Spedito",
            body:
              "The delivery agent’s previous conversation was unavailable. I started a replacement in the preserved ticket workspace and passed it the tech lead’s feedback."
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
      _ = try await updateAgentRun(
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
          runtimeWorkspaceRoots: [
            revisionWorkspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .running,
          codexThreadID: revisionThreadID,
          worktreePath: revisionWorkspace.path,
          eventActor: "Spedito",
          eventDetail: "Replaced a stale Codex thread before applying review feedback"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The delivery agent’s previous Codex session was unavailable. I started a replacement session in the preserved ticket workspace and passed it the tech lead’s feedback."
        )
        turnID = try await client.startStructuredTurn(
          threadID: revisionThreadID,
          prompt: revisionPrompt,
          effort: implementer.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            revisionWorkspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
        workspaceURL: revisionWorkspace,
        canonicalKnowledgePages: context.knowledgePages
      )
      await processExecutionResult(
        revision.result,
        deliveryKind: revision.deliveryKind,
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
    conflictedFiles: [String],
    includesGitHubChanges: Bool
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
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
        body:
          includesGitHubChanges
          ? "The ticket overlaps verified GitHub changes in \(conflictedFiles.count) file(s). I’m resolving the integration before final tech lead review."
          : "The ticket overlaps newer accepted work in \(conflictedFiles.count) file(s). I’m resolving the integration before final tech lead review."
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
      let store = store(for: candidate.productID),
      let worktreePath = candidate.integrationWorktreePath
    else { return }
    do {
      let implementationRun = try await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
      let conflictedFiles = try await gitWorkspaceManager.unmergedFiles(
        at: URL(fileURLWithPath: worktreePath, isDirectory: true)
      )
      _ = try await updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        eventActor: "Integrator",
        eventDetail: "Product owner response received; conflict resolution resumed"
      )
      await reloadSelectedProductIfCurrent(productID: plan.sprint.productID)
      await runIntegrationConflictResolution(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        conflictedFiles: conflictedFiles,
        continuationMessage:
          "Use the latest product owner comment to resolve the open integration decision."
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
      let store = store(for: plan.sprint.productID),
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
        productInstructions: inheritedAgentInstructions(for: product)
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
            authorName: "Spedito",
            body:
              "The integrator’s previous conversation was unavailable. I started a replacement in the preserved conflict workspace."
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
      _ = try await updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path,
        eventActor: replacedUnavailableThread ? "Spedito" : nil,
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable integrator conversation"
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
          runtimeWorkspaceRoots: [
            workspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model,
          readOnlyGitDirectory: productGitDirectory
        )
        _ = try await updateAgentRun(
          id: resolutionRun.id,
          status: .running,
          codexThreadID: threadID,
          worktreePath: workspace.path,
          eventActor: "Spedito",
          eventDetail: "Replaced a stale integrator Codex thread"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The integrator’s previous Codex session was unavailable. I started a replacement session in the preserved conflict workspace."
        )
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: resolutionPrompt,
          effort: "medium",
          outputSchema: CodexConflictIntegrator.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try Self.productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
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
        _ = try await updateAgentRun(
          id: resolutionRun.id,
          status: .awaitingOwner,
          eventActor: "Integrator",
          eventDetail: "Waiting for product owner input"
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
      let store = store(for: candidate.productID),
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
    guard let store = store(for: candidate.productID) else { return }
    var integration = try await gitWorkspaceManager.completeConflictResolution(
      integrationWorkspaceURL: workspace,
      candidateHeadSHA: candidate.headSHA
    )
    _ = try await updateAgentRun(
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

    let remoteIntegration: (
      snapshot: GitIntegrationSnapshot,
      incorporatedChanges: Bool,
      remoteSHA: String?
    )
    do {
      remoteIntegration = try await integrateLatestGitHubChanges(
        candidate: candidate,
        integration: integration
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
        conflictedFiles: conflictedFiles,
        includesGitHubChanges: true
      )
      return
    }
    integration = remoteIntegration.snapshot
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .integrating,
      integratedSHA: integration.integratedSHA,
      integrationWorktreePath: integration.url.path
    )
    if remoteIntegration.incorporatedChanges, let remoteSHA = remoteIntegration.remoteSHA {
      let message =
        "Integrated verified GitHub changes at \(String(remoteSHA.prefix(8))) into this ticket before final review."
      let comments = try await store.fetchComments(workItemID: candidate.workItemID)
      if !comments.contains(where: { $0.body == message }) {
        _ = try await store.appendComment(
          workItemID: candidate.workItemID,
          authorKind: .system,
          authorName: "Spedito",
          body: message
        )
      }
    }
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
    guard let store = store(for: candidate.productID) else { return }
    if let resolutionRunID {
      _ = try? await updateAgentRun(
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
      authorName: "Spedito",
      body: Task.isCancelled
        ? "Integration was interrupted. The conflict workspace is preserved."
        : "Integration needs attention: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved conflict workspace."
    )
    if !Task.isCancelled {
      presentExecutionError(error, productID: candidate.productID)
    }
    await reloadSelectedProductIfCurrent(productID: candidate.productID)
  }

  private func handleSprintOwnerComment(
    productID: UUID,
    workItemID: UUID,
    body: String,
    actor: String = "Product owner",
    reasonPrefix: String = "Demo feedback"
  ) async {
    guard
      let store = store(for: productID),
      let plan = try? await store.fetchCurrentSprint(productID: productID),
      plan.sprint.state == .active,
      let sprintItem = plan.items.first(where: { $0.workItemID == workItemID }),
      let implementerID = sprintItem.implementerProfileID
    else { return }

    do {
      let currentItems = try await store.fetchWorkItems(productID: productID)
      guard let item = currentItems.first(where: { $0.id == workItemID }) else { return }
      let currentRuns = try await store.fetchAgentRuns(productID: productID)
      let currentCandidates = try await store.fetchCandidateRevisions(
        productID: productID
      )
      let productProfiles = try await store.fetchAgentProfiles(productID: productID)
      let reviewerProfileIDs = Set(
        productProfiles
          .filter { $0.role == .lead }
          .map(\.id)
      )
      if let reviewingCandidate =
        currentCandidates
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
        _ = try await updateAgentRun(
          id: reviewRun.id,
          status: .queued,
          eventActor: "Product owner",
          eventDetail: "Retry requested; tech lead review queued to continue"
        )
        await reloadSelectedProductIfCurrent(productID: productID)
        scheduleSprintExecution(productID: productID)
        return
      }
      if currentCandidates.contains(where: {
        $0.workItemID == workItemID && $0.status == .resolvingConflict
      }) {
        let techLeadID = productProfiles.first(where: { $0.role == .lead })?.id
        let resolutionRuns = currentRuns.filter {
          $0.workItemID == workItemID
            && $0.profileID == techLeadID
            && $0.status == .awaitingOwner
        }
        if let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }) {
          _ = try await updateAgentRun(
            id: resolutionRun.id,
            status: .queued,
            eventActor: "Product owner",
            eventDetail: "Response received; integration queued to resume"
          )
          await reloadSelectedProductIfCurrent(productID: productID)
          scheduleSprintExecution(productID: productID)
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
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product owner",
          eventDetail: "Response received; work queued to resume"
        )
      } else if implementationRun.status == .failed || implementationRun.status == .interrupted,
        item.state == .running
      {
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product owner",
          eventDetail: "Retry requested; preserved work queued to resume"
        )
      } else if item.state == .acceptance {
        if let githubRemoteService {
          let remoteState = await githubRemoteService.state(productID: productID)
          if let publication = remoteState.publications.first(where: {
            $0.workItemID == workItemID && $0.status.isActive
              && $0.pullRequest?.state == .open && $0.pullRequest?.isDraft == false
          }) {
            let updated = try await githubRemoteService.returnTicketPullRequestToDraft(
              publicationID: publication.id
            )
            githubRemoteRepositoryStates[productID] = updated
          }
        }
        let readyCandidates = currentCandidates.filter { candidate in
          candidate.workItemID == item.id && candidate.status == .readyForDemo
        }
        if let candidate = readyCandidates.max(by: { $0.version < $1.version }) {
          await stopDemoSession(candidate, removesPreview: true)
          if candidate.deliveryKind.changesRepository {
            guard let integratedSHA = candidate.integratedSHA else {
              throw PersistenceError.corruptData(
                "The reviewed demo candidate has no integrated revision."
              )
            }
            _ = try await adoptIntegratedBaselineForRevision(
              candidate: candidate,
              integratedSHA: integratedSHA
            )
          }
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
          actor: actor,
          reason: "\(reasonPrefix): \(body.prefix(160))"
        )
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: actor,
          eventDetail: "\(reasonPrefix) received; work queued to resume"
        )
      } else {
        return
      }
      await reloadSelectedProductIfCurrent(productID: productID)
      scheduleSprintExecution(productID: productID)
    } catch {
      presentExecutionError(error, productID: productID)
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
        let contextUsedTokens =
          notification.method == "thread/tokenUsage/updated"
          ? notification.params["tokenUsage"]?["last"]?["totalTokens"]?.integerValue.map(Int.init)
          : nil
        let contextWindowTokens =
          notification.method == "thread/tokenUsage/updated"
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
        } else if contextUsedTokens != nil
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
    let telemetryStore: SQLiteStore?
    if let injectedStore {
      telemetryStore = injectedStore
    } else if let storeRegistry {
      telemetryStore = await storeRegistry.findStore(containingAgentRun: runID)
    } else {
      telemetryStore = nil
    }
    guard let telemetryStore else { return }
    guard
      let updated = try? await telemetryStore.recordAgentRunActivity(
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
    let integrationCandidateIDs = activeIntegrationProductIDs.compactMap {
      productID == nil || $0.value == productID ? $0.key : nil
    }
    for candidateID in integrationCandidateIDs {
      activeIntegrationTasks[candidateID]?.cancel()
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
    if !executionTasks.isEmpty
      || !implementationTaskIDs.isEmpty
      || !integrationCandidateIDs.isEmpty
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
        let hasIntegration = activeIntegrationProductIDs.contains {
          productID == nil || $0.value == productID
        }
        guard hasScheduler || hasImplementation || hasIntegration
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
      for candidateID in integrationCandidateIDs {
        activeIntegrationTasks.removeValue(forKey: candidateID)
        activeIntegrationProductIDs.removeValue(forKey: candidateID)
      }
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
      activeIntegrationTasks.removeAll()
      activeIntegrationProductIDs.removeAll()
      activeExecutionTurns.removeAll()
    }
    let approvalRequestIDs = liveApprovalRequestProductIDs.compactMap {
      productID == nil || $0.value == productID ? $0.key : nil
    }
    for requestID in approvalRequestIDs {
      guard
        let requestProductID = liveApprovalRequestProductIDs[requestID],
        let requestStore = store(for: requestProductID)
      else { continue }
      if let updated = try? await requestStore.updateAgentPermissionRequest(
        id: requestID,
        status: .interrupted
      ) {
        replacePermissionRequest(updated)
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
    let pullRequestPollingTask = githubPullRequestPollingTask
    pullRequestPollingTask?.cancel()
    let pullRequestSyncTasks = Array(githubPullRequestSyncTasks.values)
    for task in pullRequestSyncTasks {
      task.cancel()
    }
    await pullRequestPollingTask?.value
    for task in pullRequestSyncTasks {
      await task.value
    }
    githubPullRequestPollingTask = nil
    githubPullRequestSyncTasks.removeAll()
    let remoteTasks = Array(githubRemoteTasks.values)
    for task in remoteTasks {
      task.cancel()
    }
    for task in remoteTasks {
      await task.value
    }
    githubRemoteTasks.removeAll()
    let importAuthorizationTask = githubImportAuthorizationTask
    importAuthorizationTask?.cancel()
    _ = try? await importAuthorizationTask?.value
    githubImportAuthorizationTask = nil
    githubImportDeviceAuthorizationPrompt = nil
    await githubRemoteService?.shutdown()
    let interruptedImportTask = productImportTask
    interruptedImportTask?.cancel()
    _ = try? await interruptedImportTask?.value
    productImportTask = nil
    let interruptedRepositoryKnowledgeTasks = repositoryKnowledgeTasks
    for task in interruptedRepositoryKnowledgeTasks.values {
      task.cancel()
    }
    for (runID, turn) in activeRepositoryKnowledgeTurns {
      if let client = repositoryKnowledgeClients[runID] {
        try? await client.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
      }
    }
    for task in interruptedRepositoryKnowledgeTasks.values {
      await task.value
    }
    repositoryKnowledgeTasks.removeAll()
    activeRepositoryKnowledgeTurns.removeAll()
    for client in repositoryKnowledgeClients.values {
      await client.disconnect()
    }
    repositoryKnowledgeClients.removeAll()
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
    let interruptedProductConversationTitleTasks = Array(
      productConversationTitleTasks.values
    )
    for task in interruptedProductConversationTitleTasks {
      task.cancel()
    }
    if let client = codexClient {
      for (conversationThreadID, turn) in activeProductConversationTurns {
        try? await client.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
        _ = try? await store(for: turn.productID)?.updateConversationThread(
          id: conversationThreadID,
          status: .cancelled
        )
      }
      for turn in activeProductConversationTitleTurns.values {
        try? await client.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
      }
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
    for task in interruptedProductConversationTitleTasks {
      await task.value
    }
    retrospectiveSynthesisTasks.removeAll()
    cancelledProductConversationThreadIDs.removeAll()
    for threadID in Array(productConversationActivityTasks.keys) {
      stopProductConversationActivityMonitoring(threadID: threadID)
    }
    stopTicketConversationActivityMonitoring()
    activeProductConversationTurns.removeAll()
    activeProductConversationTitleTurns.removeAll()
    productConversationTitleTasks.removeAll()
    respondingConversationThreadIDs.removeAll()
    activeRetrospectiveSynthesisTurns.removeAll()
    await epicConversationPersistenceTask?.value
    await stopAllDemoSessions()
    await applyExecutionLifecycle(.appShutdown)
    approvalRoutingTask?.cancel()
    approvalRoutingTask = nil
    stopCodexUsageMonitoring()
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
    guard
      let store = store(for: product.id),
      let client = codexClient
    else { return }
    var startedSynthesis: RetrospectiveSynthesis?
    do {
      let productProfiles = try await store.fetchAgentProfiles(productID: product.id)
      guard
        let analyst = productProfiles.first(where: { $0.role == .businessAnalyst })
      else {
        throw PersistenceError.corruptData(
          "This product needs a business analyst to prepare retrospective actions."
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
      let waysOfWorking =
        productKnowledge.first {
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
          productInstructions: inheritedAgentInstructions(for: product),
          customInstructions: analyst.customInstructionText
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

  private func epicPlanningKnowledge(for epic: Epic) -> [KnowledgePage] {
    KnowledgeContextSelector.selectForEpic(
      pages: knowledgePages,
      epic: epic
    )
  }

  private func inheritedAgentInstructions(
    for product: Product,
    includesMandatoryKnowledge: Bool = true,
    allowsRepositoryInspection: Bool = true
  ) -> String {
    let shared = product.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let databasePath =
      (try? Self.productDatabaseURL(productID: product.id).path)
      ?? ".spedito/product.sqlite"
    let knowledgeScope =
      includesMandatoryKnowledge
      ? """
      Read agent_verified_knowledge before acting on product or operating assumptions. Treat only
      rows in that view as verified reusable knowledge.
      """
      : """
      Query agent_verified_knowledge when the assigned ticket needs durable product context.
      """
    let repositoryScope =
      allowsRepositoryInspection
      ? """
      Search the product Git history when repository evidence is useful.
      """
      : """
      This is a planning turn. Use the ticket contracts and verified product knowledge supplied in the
      prompt. Do not inspect repository files or Git history.
      """
    return [
      shared,
      """
      LIVE PRODUCT CONTEXT
      The authoritative, live product database is at:
      \(databasePath)

      You may inspect it read-only with `/usr/bin/sqlite3 -readonly`. Use the stable agent_product,
      agent_team, agent_epics, agent_tickets, agent_ticket_dependencies, agent_work_log,
      agent_sprints, agent_verified_knowledge, agent_decisions, agent_delivery_provenance, and
      agent_retrospectives views. The exact stable view schemas are:
      \(CodexLiveProductContext.stableViewSchemas)

      \(repositoryScope)
      The database can change while you work, so re-read a record before relying on mutable state.
      \(knowledgeScope)
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
    guard let store = store(for: productID) else {
      throw CodexClientError.notConnected
    }
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
    let checks =
      result.tests.isEmpty
      ? "- No automated checks were reported."
      : result.tests.map { "- \($0)" }.joined(separator: "\n")
    let review = result.reviewInstructions.map { "- \($0)" }.joined(separator: "\n")
    let knowledge =
      result.knowledgeNotes.isEmpty
      ? "- No durable decision or limitation was reported."
      : result.knowledgeNotes.map { "- \($0)" }.joined(separator: "\n")
    let files =
      result.changedFiles.isEmpty
      ? "- No changed file was reported."
      : result.changedFiles.map { "- `\($0)`" }.joined(separator: "\n")
    let demo =
      result.demo.map {
        "- **\($0.title)** — \($0.presentation.kind.title)"
      } ?? "- No managed demo recipe was recorded."
    let followUps =
      result.followUpTicketProposals.isEmpty
      ? "- No follow-up tickets were recommended."
      : result.followUpTicketProposals.map {
        "- **\($0.reference): \($0.title)** — \($0.rationale)"
      }.joined(separator: "\n")
    return """
      # \(item.key) · \(item.title)

      **Delivery evidence:** Prepared with the candidate revision<br>
      **Prepared by:** \(authorName)

      ## What changed
      \(result.summary.isEmpty ? result.comment : result.summary)

      ## How it works and why
      \(knowledge)

      ## Changed files
      \(files)

      ## Checks performed
      \(checks)

      ## How the product owner can review it
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
    guard let store = store(for: candidate.productID) else {
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


  private func cancelRepositoryKnowledge(productID: UUID) async {
    guard let task = repositoryKnowledgeTasks[productID] else { return }
    task.cancel()
    if let productStore = store(for: productID),
      let run = try? await productStore.fetchLatestRepositoryKnowledgeRun(productID: productID),
      let turn = activeRepositoryKnowledgeTurns[run.id],
      let client = repositoryKnowledgeClients[run.id]
    {
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
    await task.value
    repositoryKnowledgeTasks[productID] = nil
  }

  private func scheduleRepositoryKnowledgeRuns() {
    for product in products where repositoryKnowledgeTasks[product.id] == nil {
      let task = Task { [weak self] in
        guard let self else { return }
        await self.recoverOrRunRepositoryKnowledge(productID: product.id)
      }
      repositoryKnowledgeTasks[product.id] = task
    }
  }

  private func recoverOrRunRepositoryKnowledge(productID: UUID) async {
    defer { repositoryKnowledgeTasks[productID] = nil }
    guard !Task.isCancelled, let productStore = store(for: productID) else { return }
    do {
      guard try await productStore.fetchProductRepository(productID: productID) != nil,
        let latest = try await productStore.fetchLatestRepositoryKnowledgeRun(
          productID: productID
        )
      else {
        return
      }
      let action = repositoryKnowledgeRecoveryPolicy.action(
        for: latest,
        alreadyCreatedRecoveryAttempt: repositoryRecoveryAttemptProductIDs.contains(productID)
      )
      let run: RepositoryKnowledgeRun
      guard
        repositoryKnowledgeRecoveryPolicy.canExecute(
          action,
          codexConnectionAvailable: codexRuntimeExecutableURL != nil
        )
      else {
        return
      }
      switch action {
      case .startPendingAnalysis:
        run = latest
      case .resumePublication:
        run = latest
      case .createRecoveryAttempt:
        repositoryRecoveryAttemptProductIDs.insert(productID)
        let recoveryMessage = "Analysis was interrupted when Spedito closed and is being retried."
        let interrupted = try await productStore.updateRepositoryKnowledgeRun(
          id: latest.id,
          status: .interrupted,
          errorMessage: recoveryMessage
        )
        guard
          let recovered = try await createRepositoryKnowledgeRetry(
            productID: productID,
            after: interrupted,
            store: productStore
          )
        else {
          return
        }
        run = recovered
      case .none:
        return
      }
      await executeRepositoryKnowledgeRun(run, store: productStore)
    } catch {
      if selectedProductID == productID {
        errorMessage = error.localizedDescription
        await reloadSelectedProduct()
      }
    }
  }

  private func createRepositoryKnowledgeRetry(
    productID: UUID,
    after previous: RepositoryKnowledgeRun,
    store productStore: SQLiteStore
  ) async throws -> RepositoryKnowledgeRun? {
    let profiles = try await productStore.fetchAgentProfiles(productID: productID)
    guard
      let analyzer = profiles.first(where: { $0.role == .businessAnalyst }),
      let reviewer = profiles.first(where: { $0.role == .lead })
    else {
      return nil
    }
    let sha: String
    if previous.purpose == .importedAppLaunch {
      guard
        let repository = try await productStore.fetchProductRepository(productID: productID)
      else {
        return nil
      }
      sha = repository.importedSHA
    } else {
      sha = try await gitWorkspaceManager.acceptedTrunkSHA(
        at: repositoryWorkspaceURL(productID: productID)
      )
    }
    let run = RepositoryKnowledgeRun(
      productID: productID,
      attempt: previous.attempt + 1,
      purpose: previous.purpose,
      analyzedSHA: sha,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
    try await productStore.createRepositoryKnowledgeRun(run)
    return run
  }

  var repositoryKnowledgeCompletionOutcome: RepositoryKnowledgeCompletionOutcome? {
    guard let repositoryKnowledgeRun else { return nil }
    return repositoryKnowledgeRecoveryPolicy.completionOutcome(
      for: repositoryKnowledgeRun,
      drafts: repositoryKnowledgeDrafts,
      pages: knowledgePages
    )
  }

  func retryRepositoryKnowledgeAnalysis() async {
    guard
      let productID = selectedProductID,
      repositoryKnowledgeTasks[productID] == nil,
      let productStore = store(for: productID)
    else {
      return
    }
    do {
      guard
        let latest = try await productStore.fetchLatestRepositoryKnowledgeRun(
          productID: productID
        )
      else {
        return
      }
      let retriesCompletedAnalysis: Bool
      if latest.status == .completed {
        let drafts = try await productStore.fetchRepositoryKnowledgeDrafts(runID: latest.id)
        let pages = try await productStore.fetchKnowledgePages(productID: productID)
        retriesCompletedAnalysis =
          repositoryKnowledgeRecoveryPolicy.completionOutcome(
            for: latest,
            drafts: drafts,
            pages: pages
          ) == .noPublishableKnowledge
      } else {
        retriesCompletedAnalysis = false
      }
      guard
        latest.status == .failed || latest.status == .interrupted || latest.status == .stale
          || latest.status == .publishing || latest.status == .pendingAnalysis
          || retriesCompletedAnalysis
      else {
        return
      }

      let retry: RepositoryKnowledgeRun
      if latest.status == .publishing || latest.status == .pendingAnalysis {
        retry = latest
      } else {
        guard
          let newAttempt = try await createRepositoryKnowledgeRetry(
            productID: productID,
            after: latest,
            store: productStore
          )
        else {
          errorMessage =
            "Repository analysis needs an active business analyst and tech lead on this product."
          return
        }
        retry = newAttempt
      }
      await reloadSelectedProduct()
      guard retry.status != .pendingAnalysis || codexRuntimeExecutableURL != nil else {
        return
      }
      let task = Task { [weak self] in
        guard let self else { return }
        defer { self.repositoryKnowledgeTasks[productID] = nil }
        await self.executeRepositoryKnowledgeRun(retry, store: productStore)
      }
      repositoryKnowledgeTasks[productID] = task
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  var isCheckingImportedAppLaunch: Bool {
    guard repositoryKnowledgeRun?.purpose == .importedAppLaunch else { return false }
    switch repositoryKnowledgeRun?.status {
    case .pendingAnalysis, .analyzing, .reviewing, .publishing:
      return true
    default:
      return false
    }
  }
  var canCheckImportedAppLaunch: Bool {
    guard let productID = selectedProductID else { return false }
    let runIsActive: Bool
    switch repositoryKnowledgeRun?.status {
    case .pendingAnalysis, .analyzing, .reviewing, .publishing:
      runIsActive = true
    default:
      runIsActive = false
    }
    return productRepository != nil
      && importedAppLaunch == nil
      && repositoryKnowledgeTasks[productID] == nil
      && !runIsActive
      && codexRuntimeExecutableURL != nil
  }

  func checkImportedAppLaunch() async {
    guard
      let productID = selectedProductID,
      importedAppLaunch == nil,
      canCheckImportedAppLaunch,
      repositoryKnowledgeTasks[productID] == nil,
      let productStore = store(for: productID),
      let repository = try? await productStore.fetchProductRepository(productID: productID)
    else { return }
    guard codexRuntimeExecutableURL != nil else {
      errorMessage = "Checking the imported app needs the Codex team connection."
      return
    }
    do {
      let profiles = try await productStore.fetchAgentProfiles(productID: productID)
      guard
        let analyzer = profiles.first(where: { $0.role == .businessAnalyst }),
        let reviewer = profiles.first(where: { $0.role == .lead })
      else {
        errorMessage =
          "Checking the imported app needs an active business analyst and tech lead."
        return
      }
      let attempts = try await productStore.fetchRepositoryKnowledgeRuns(productID: productID)
      let run = RepositoryKnowledgeRun(
        productID: productID,
        attempt: (attempts.map(\.attempt).max() ?? 0) + 1,
        purpose: .importedAppLaunch,
        analyzedSHA: repository.importedSHA,
        analyzerProfileID: analyzer.id,
        reviewerProfileID: reviewer.id
      )
      try await productStore.createRepositoryKnowledgeRun(run)
      await reloadSelectedProduct()
      let task = Task { [weak self] in
        guard let self else { return }
        defer { self.repositoryKnowledgeTasks[productID] = nil }
        await self.executeRepositoryKnowledgeRun(run, store: productStore)
      }
      repositoryKnowledgeTasks[productID] = task
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func executeRepositoryKnowledgeRun(
    _ initialRun: RepositoryKnowledgeRun,
    store productStore: SQLiteStore
  ) async {
    var snapshotURL: URL?
    var analysisClient: CodexAppServerClient?
    do {
      var run = try await productStore.fetchRepositoryKnowledgeRun(id: initialRun.id)
      if run.status == .pendingAnalysis {
        guard let executableURL = codexRuntimeExecutableURL else {
          throw CodexClientError.notConnected
        }
        let activeProfiles = try await productStore.fetchAgentProfiles(
          productID: run.productID
        )
        guard
          let analyzer = activeProfiles.first(where: { $0.id == run.analyzerProfileID }),
          let reviewer = activeProfiles.first(where: { $0.id == run.reviewerProfileID })
        else {
          _ = try await productStore.updateRepositoryKnowledgeRun(
            id: run.id,
            status: .pendingAnalysis,
            errorMessage:
              "Repository analysis needs its active business analyst and tech lead."
          )
          if selectedProductID == run.productID { await reloadSelectedProduct() }
          return
        }
        let workspaceURL = try repositoryWorkspaceURL(productID: run.productID)
        let destinationURL = try Self.repositoryAnalysisRootURL()
          .appendingPathComponent(run.id.uuidString, isDirectory: true)
        let snapshot = try await gitWorkspaceManager.prepareRepositoryAnalysisSnapshot(
          repositoryURL: workspaceURL,
          sha: run.analyzedSHA,
          destinationURL: destinationURL
        )
        snapshotURL = snapshot.url
        let transport = CodexJSONLTransport(
          configuration: .init(
            executableURL: executableURL,
            arguments: CodexPermissionProfiles.repositoryAnalysisAppServerArguments(
              snapshotURL: snapshot.url
            ),
            currentDirectoryURL: snapshot.url,
            environmentOverrides: CodexPermissionProfiles.repositoryAnalysisProcessEnvironment,
            environmentMode: .replace,
            requestTimeout: .seconds(30)
          )
        )
        let client = CodexAppServerClient(transport: transport)
        analysisClient = client
        repositoryKnowledgeClients[run.id] = client
        _ = try await client.connect()

        run = try await productStore.updateRepositoryKnowledgeRun(
          id: run.id,
          status: .analyzing
        )
        presentRepositoryKnowledgeRun(run)
        let analyzerThreadID = try await client.startRepositoryAnalysisThread(
          snapshotURL: snapshot.url,
          developerInstructions: repositoryInstructions(
            base: CodexRepositoryKnowledgeAnalyzer.developerInstructions,
            profile: analyzer
          ),
          model: analyzer.model
        )
        monitorRepositoryKnowledgeActivity(
          productID: run.productID,
          client: client,
          threadID: analyzerThreadID,
          initialText: "Reading repository evidence…"
        )
        let pages = try await productStore.fetchKnowledgePages(productID: run.productID)
        var analyzerTurnID = try await client.startStructuredTurn(
          threadID: analyzerThreadID,
          prompt: try CodexRepositoryKnowledgeAnalyzer.prompt(
            run: run,
            pages: pages,
            snapshot: snapshot
          ),
          effort: analyzer.reasoningEffort,
          outputSchema: CodexRepositoryKnowledgeAnalyzer.outputSchema,
          runtimeWorkspaceRoots: [snapshot.url],
          responseTimeout: Duration.seconds(30)
        )
        activeRepositoryKnowledgeTurns[run.id] = (analyzerThreadID, analyzerTurnID)
        run = try await productStore.updateRepositoryKnowledgeRun(
          id: run.id,
          status: .analyzing,
          analyzerThreadID: analyzerThreadID,
          analyzerTurnID: analyzerTurnID
        )
        presentRepositoryKnowledgeRun(run)
        let analyzerText = try await client.waitForFinalAgentMessage(
          threadID: analyzerThreadID,
          turnID: analyzerTurnID,
          timeout: Duration.seconds(120),
          totalTimeout: Duration.seconds(1_200)
        )
        activeRepositoryKnowledgeTurns[run.id] = nil
        var analysis = try CodexRepositoryKnowledgeAnalyzer.decode(
          analyzerText,
          run: run,
          pages: pages,
          snapshot: snapshot
        )
        if let launchIssue = analysis.launchProposalIssue {
          repositoryKnowledgeActivities[run.productID] = CodexLiveActivity(
            text: "Correcting the imported app recipe…",
            kind: .inspecting
          )
          let correctionTurnID = try await client.startStructuredTurn(
            threadID: analyzerThreadID,
            prompt: CodexRepositoryKnowledgeAnalyzer.launchCorrectionPrompt(
              reason: launchIssue
            ),
            effort: analyzer.reasoningEffort,
            outputSchema: CodexRepositoryKnowledgeAnalyzer.outputSchema,
            runtimeWorkspaceRoots: [snapshot.url],
            responseTimeout: Duration.seconds(30)
          )
          analyzerTurnID = correctionTurnID
          activeRepositoryKnowledgeTurns[run.id] = (analyzerThreadID, correctionTurnID)
          run = try await productStore.updateRepositoryKnowledgeRun(
            id: run.id,
            status: .analyzing,
            analyzerThreadID: analyzerThreadID,
            analyzerTurnID: correctionTurnID
          )
          presentRepositoryKnowledgeRun(run)
          let correctedText = try await client.waitForFinalAgentMessage(
            threadID: analyzerThreadID,
            turnID: correctionTurnID,
            timeout: Duration.seconds(120),
            totalTimeout: Duration.seconds(1_200)
          )
          activeRepositoryKnowledgeTurns[run.id] = nil
          let corrected = try CodexRepositoryKnowledgeAnalyzer.decode(
            correctedText,
            run: run,
            pages: pages,
            snapshot: snapshot
          )
          analysis = RepositoryKnowledgeAnalysisResult(
            summary: analysis.summary,
            drafts: analysis.drafts,
            launchProposal: corrected.launchProposal,
            launchProposalIssue: corrected.launchProposalIssue
          )
        }
        if run.purpose == .importedAppLaunch, let launchIssue = analysis.launchProposalIssue {
          throw RepositoryKnowledgeAnalysisError.invalidResponse(
            "The imported app recipe could not be validated after one correction: \(launchIssue)"
          )
        }
        if let launchIssue = analysis.launchProposalIssue {
          analysis = RepositoryKnowledgeAnalysisResult(
            summary:
              "\(analysis.summary)\n\nThe optional imported app recipe was not saved: \(launchIssue)",
            drafts: analysis.drafts
          )
        }
        try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
          at: workspaceURL,
          sha: run.analyzedSHA,
          evidence: analysis.drafts.flatMap(\.evidence) + (analysis.launchProposal?.evidence ?? []),
          requiresTrunkRevisionMatch: run.purpose == .knowledge
        )
        run = try await productStore.recordRepositoryKnowledgeAnalysis(
          runID: run.id,
          summary: analysis.summary,
          drafts: analysis.drafts,
          launchProposal: analysis.launchProposal,
          analyzerThreadID: analyzerThreadID,
          analyzerTurnID: analyzerTurnID
        )
        let persistedDrafts = try await productStore.fetchRepositoryKnowledgeDrafts(
          runID: run.id
        )
        let persistedLaunchProposal = try await productStore.fetchRepositoryLaunchProposal(
          runID: run.id
        )
        presentRepositoryKnowledgeRun(run, drafts: persistedDrafts)
        if run.status == .completed {
          await finishRepositoryKnowledgeRun(
            run: run,
            snapshotURL: snapshotURL,
            client: analysisClient
          )
          if selectedProductID == run.productID { await reloadSelectedProduct() }
          return
        }

        let reviewerThreadID = try await client.startRepositoryAnalysisThread(
          snapshotURL: snapshot.url,
          developerInstructions: repositoryInstructions(
            base: CodexRepositoryKnowledgeReviewer.developerInstructions,
            profile: reviewer
          ),
          model: reviewer.model
        )
        monitorRepositoryKnowledgeActivity(
          productID: run.productID,
          client: client,
          threadID: reviewerThreadID,
          initialText: "Checking proposed product information…"
        )
        let reviewerTurnID = try await client.startStructuredTurn(
          threadID: reviewerThreadID,
          prompt: try CodexRepositoryKnowledgeReviewer.prompt(
            run: run,
            drafts: persistedDrafts,
            launchProposal: persistedLaunchProposal,
            snapshot: snapshot
          ),
          effort: reviewer.reasoningEffort,
          outputSchema: CodexRepositoryKnowledgeReviewer.outputSchema,
          runtimeWorkspaceRoots: [snapshot.url],
          responseTimeout: Duration.seconds(30)
        )
        activeRepositoryKnowledgeTurns[run.id] = (reviewerThreadID, reviewerTurnID)
        run = try await productStore.updateRepositoryKnowledgeRun(
          id: run.id,
          status: .reviewing,
          reviewerThreadID: reviewerThreadID,
          reviewerTurnID: reviewerTurnID
        )
        presentRepositoryKnowledgeRun(run, drafts: persistedDrafts)
        let reviewerText = try await client.waitForFinalAgentMessage(
          threadID: reviewerThreadID,
          turnID: reviewerTurnID,
          timeout: Duration.seconds(120),
          totalTimeout: Duration.seconds(1_200)
        )
        activeRepositoryKnowledgeTurns[run.id] = nil
        let review = try CodexRepositoryKnowledgeReviewer.decode(
          reviewerText,
          drafts: persistedDrafts,
          launchProposal: persistedLaunchProposal
        )
        try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
          at: workspaceURL,
          sha: run.analyzedSHA,
          evidence: persistedDrafts.flatMap(\.evidence) + (persistedLaunchProposal?.evidence ?? []),
          requiresTrunkRevisionMatch: run.purpose == .knowledge
        )
        run = try await productStore.recordRepositoryKnowledgeReview(
          runID: run.id,
          summary: review.summary,
          decisions: review.decisions,
          launchDecision: review.launchDecision,
          reviewerThreadID: reviewerThreadID,
          reviewerTurnID: reviewerTurnID
        )
        presentRepositoryKnowledgeRun(run, drafts: persistedDrafts)
      }

      if run.status == .publishing {
        stopRepositoryKnowledgeActivityMonitoring(productID: run.productID)
        repositoryKnowledgeActivities[run.productID] = CodexLiveActivity(
          text: run.purpose == .importedAppLaunch
            ? "Saving the verified imported app recipe…"
            : "Saving verified product information…",
          kind: .inspecting
        )
        if run.purpose == .importedAppLaunch {
          run = try await productStore.finalizeRepositoryKnowledgePublication(runID: run.id)
        } else {
          run = try await publishRepositoryKnowledge(run: run, store: productStore)
        }
      }
      await finishRepositoryKnowledgeRun(
        run: run,
        snapshotURL: snapshotURL,
        client: analysisClient
      )
      if selectedProductID == run.productID { await reloadSelectedProduct() }
    } catch is CancellationError {
      await interruptRepositoryKnowledgeRun(
        initialRun.id,
        store: productStore,
        publishingRemainsResumable: true
      )
      await finishRepositoryKnowledgeRun(
        run: initialRun,
        snapshotURL: snapshotURL,
        client: analysisClient
      )
    } catch {
      await failRepositoryKnowledgeRun(initialRun.id, error: error, store: productStore)
      await finishRepositoryKnowledgeRun(
        run: initialRun,
        snapshotURL: snapshotURL,
        client: analysisClient
      )
      if selectedProductID == initialRun.productID { await reloadSelectedProduct() }
    }
  }

  private func monitorRepositoryKnowledgeActivity(
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    initialText: String
  ) {
    stopRepositoryKnowledgeActivityMonitoring(productID: productID)
    let monitorID = UUID()
    repositoryKnowledgeActivityMonitorIDs[productID] = monitorID
    repositoryKnowledgeActivities[productID] = CodexLiveActivity(
      text: initialText,
      kind: .thinking
    )

    repositoryKnowledgeActivityTasks[productID] = Task { [weak self] in
      guard let self else { return }
      var accumulator = CodexLiveActivityAccumulator()
      let messages = await client.inboundMessages(replayRecent: true)
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard
          notification.params["threadId"]?.stringValue == threadID,
          self.repositoryKnowledgeActivityMonitorIDs[productID] == monitorID
        else {
          continue
        }

        switch accumulator.consume(notification) {
        case .activity(let activity):
          self.repositoryKnowledgeActivities[productID] = activity
        case .turnFinished:
          self.repositoryKnowledgeActivityMonitorIDs[productID] = nil
          self.repositoryKnowledgeActivityTasks[productID] = nil
          return
        case nil:
          continue
        }
      }

      guard self.repositoryKnowledgeActivityMonitorIDs[productID] == monitorID else {
        return
      }
      self.repositoryKnowledgeActivityMonitorIDs[productID] = nil
      self.repositoryKnowledgeActivityTasks[productID] = nil
    }
  }

  private func stopRepositoryKnowledgeActivityMonitoring(productID: UUID) {
    repositoryKnowledgeActivityTasks.removeValue(forKey: productID)?.cancel()
    repositoryKnowledgeActivityMonitorIDs.removeValue(forKey: productID)
    repositoryKnowledgeActivities.removeValue(forKey: productID)
  }

  private func presentRepositoryKnowledgeRun(
    _ run: RepositoryKnowledgeRun,
    drafts: [RepositoryKnowledgeDraft]? = nil
  ) {
    guard selectedProductID == run.productID else { return }
    repositoryKnowledgeRun = run
    if let drafts {
      repositoryKnowledgeDrafts = drafts
    }
  }

  private func publishRepositoryKnowledge(
    run: RepositoryKnowledgeRun,
    store productStore: SQLiteStore
  ) async throws -> RepositoryKnowledgeRun {
    guard
      let repository = try await productStore.fetchProductRepository(productID: run.productID)
    else {
      throw PersistenceError.corruptData("Imported repository provenance is missing")
    }
    let workspaceURL = try repositoryWorkspaceURL(productID: run.productID)
    let drafts = try await productStore.fetchRepositoryKnowledgeDrafts(runID: run.id)
    if run.knowledgeExportPaths.isEmpty, run.knowledgeCommitSHA == nil {
      try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
        at: workspaceURL,
        sha: run.analyzedSHA,
        evidence: drafts.filter { $0.status != .rejected }.flatMap(\.evidence)
      )
      return try await productStore.finalizeRepositoryKnowledgePublication(runID: run.id)
    }
    // Runs started by older builds may already own a prepared knowledge checkpoint.
    // New runs publish locally and return above; this branch only preserves durable recovery.
    try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
      at: workspaceURL,
      sha: run.analyzedSHA,
      evidence: drafts.filter { $0.status != .rejected }.flatMap(\.evidence),
      requiresCleanWorkspace: false
    )
    let projection = try await productStore.projectRepositoryKnowledgePublication(
      runID: run.id
    )
    let export = try await RepositoryKnowledgeExporter.export(
      projection: projection,
      changedPageIDs: Set(projection.changedPageIDs),
      repository: repository,
      workspaceURL: workspaceURL,
      gitWorkspaceManager: gitWorkspaceManager
    )

    var currentRun = run
    if !currentRun.knowledgeExportPaths.isEmpty, currentRun.knowledgeCommitSHA == nil {
      let expected = Dictionary(
        uniqueKeysWithValues: currentRun.knowledgeExportPaths.compactMap { path in
          export.expectedContents[path].map { (path, $0) }
        }
      )
      guard expected.count == currentRun.knowledgeExportPaths.count else {
        throw PersistenceError.corruptData(
          "Repository knowledge publication content could not be reconstructed"
        )
      }
      if let recoveredSHA = try await gitWorkspaceManager.recoverRepositoryKnowledgeCheckpoint(
        at: workspaceURL,
        analyzedSHA: run.analyzedSHA,
        expectedFiles: expected
      ) {
        currentRun = try await productStore.recordRepositoryKnowledgeCommitSHA(
          runID: run.id,
          sha: recoveredSHA
        )
      }
    } else if currentRun.knowledgeCommitSHA == nil {
      currentRun = try await productStore.recordRepositoryKnowledgeExport(
        runID: run.id,
        paths: export.touchedPaths
      )
      if !export.touchedPaths.isEmpty {
        let expected = Dictionary(
          uniqueKeysWithValues: export.touchedPaths.compactMap { path in
            export.expectedContents[path].map { (path, $0) }
          }
        )
        let commitSHA = try await gitWorkspaceManager.checkpointRepositoryKnowledge(
          at: workspaceURL,
          analyzedSHA: run.analyzedSHA,
          expectedFiles: expected
        )
        currentRun = try await productStore.recordRepositoryKnowledgeCommitSHA(
          runID: run.id,
          sha: commitSHA
        )
      }
    }
    return try await productStore.finalizeRepositoryKnowledgePublication(runID: run.id)
  }

  private func interruptRepositoryKnowledgeRun(
    _ runID: UUID,
    store productStore: SQLiteStore,
    publishingRemainsResumable: Bool
  ) async {
    guard let run = try? await productStore.fetchRepositoryKnowledgeRun(id: runID) else {
      return
    }
    let status: RepositoryKnowledgeRunStatus =
      publishingRemainsResumable && run.status == .publishing ? .publishing : .interrupted
    _ = try? await productStore.updateRepositoryKnowledgeRun(
      id: runID,
      status: status,
      errorMessage:
        status == .publishing
        ? "Spedito closed while verified knowledge was publishing. Publication will resume."
        : "Spedito closed before repository analysis finished."
    )
  }

  private func failRepositoryKnowledgeRun(
    _ runID: UUID,
    error: Error,
    store productStore: SQLiteStore
  ) async {
    guard let run = try? await productStore.fetchRepositoryKnowledgeRun(id: runID) else {
      return
    }
    let status: RepositoryKnowledgeRunStatus
    if error is GitWorkspaceError || error is RepositoryAnalysisSnapshotError {
      status = .stale
    } else if run.status == .publishing {
      status = .publishing
    } else {
      status = .failed
    }
    _ = try? await productStore.updateRepositoryKnowledgeRun(
      id: runID,
      status: status,
      errorMessage: error.localizedDescription
    )
  }

  private func finishRepositoryKnowledgeRun(
    run: RepositoryKnowledgeRun,
    snapshotURL: URL?,
    client: CodexAppServerClient?
  ) async {
    activeRepositoryKnowledgeTurns[run.id] = nil
    stopRepositoryKnowledgeActivityMonitoring(productID: run.productID)
    repositoryKnowledgeClients[run.id] = nil
    if let client { await client.disconnect() }
    if let snapshotURL {
      try? GitWorkspaceManager.removeRepositoryAnalysisSnapshot(at: snapshotURL)
    }
  }

  private func repositoryInstructions(
    base: String,
    profile: AgentProfile
  ) -> String {
    let custom = profile.customInstructionText
    guard !custom.isEmpty else { return base }
    return "\(base)\n\nTeam member instructions:\n\(custom)"
  }

  private func repositoryWorkspaceURL(productID: UUID) throws -> URL {
    if let storeRegistry {
      return storeRegistry.productWorkspacesRootURL
        .appendingPathComponent(productID.uuidString, isDirectory: true)
    }
    return try Self.productWorkspaceURL(productID: productID)
  }

  private static func repositoryAnalysisRootURL() throws -> URL {
    let caches = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      caches
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("Repository analysis", isDirectory: true)
  }

  func reload() async {
    guard storeRegistry != nil || injectedStore != nil else {
      isLoading = false
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      products = try await fetchProducts()
      archivedProducts = try await fetchProducts(status: .archived)
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
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
      scheduleGitHubPullRequestPolling()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadSelectedProduct() async {
    guard
      let productID = selectedProductID,
      let store = store(for: productID)
    else {
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
      importedAppLaunch = nil
      retrospectiveNotes = []
      retrospectiveSyntheses = []
      retrospectiveActionSources = []
      knowledgePages = []
      knowledgePageReadState.reset()
      unreadKnowledgePageIDs = []
      productRepository = nil
      repositoryKnowledgeRun = nil
      repositoryKnowledgeDrafts = []
      candidateRevisions = []
      demoSessions = []
      permissionRequests = []
      permissionGrants = []
      knowledgePageProposals = []
      agentRunKnowledgeContext = []
      agentRunKnowledgeDestinations = []
      conversationThreads = []
      conversationMessagesByThread = [:]
      conversationErrorsByThread = [:]
      return
    }
    do {
      let loadedGitHubRemoteState = await githubRemoteService?.state(productID: productID)
      let loadedRepository = try await store.fetchProductRepository(productID: productID)
      let loadedRepositoryRun = try await store.fetchLatestRepositoryKnowledgeRun(
        productID: productID
      )
      let loadedImportedAppLaunch = try await store.fetchImportedAppLaunch(productID: productID)
      let loadedRepositoryDrafts: [RepositoryKnowledgeDraft]
      if let loadedRepositoryRun {
        loadedRepositoryDrafts = try await store.fetchRepositoryKnowledgeDrafts(
          runID: loadedRepositoryRun.id
        )
      } else {
        loadedRepositoryDrafts = []
      }
      let loadedEpics = try await store.fetchEpics(productID: productID)
      let loadedWorkItems = try await store.fetchWorkItems(productID: productID)
      let loadedDependencies = try await store.fetchWorkItemDependencies(
        productID: productID
      )
      let loadedProfiles = try await store.seedDefaultProfiles(productID: productID)
      let loadedKnowledgePages =
        if loadedRepository == nil {
          try await store.seedKnowledgeBase(productID: productID)
        } else {
          try await store.fetchKnowledgePages(productID: productID)
        }
      let loadedCandidates = try await store.fetchCandidateRevisions(productID: productID)
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
      let loadedConversationThreads = try await store.fetchConversationThreads(
        productID: productID
      )
      var loadedConversationMessages: [UUID: [ProductConversationMessage]] = [:]
      for thread in loadedConversationThreads {
        loadedConversationMessages[thread.id] =
          try await store.fetchConversationMessages(threadID: thread.id)
      }

      guard selectedProductID == productID else { return }
      if let loadedGitHubRemoteState {
        githubRemoteRepositoryStates[productID] = loadedGitHubRemoteState
      }
      epics = loadedEpics
      importedAppLaunch = loadedImportedAppLaunch
      workItems = loadedWorkItems
      dependencies = loadedDependencies
      profiles = loadedProfiles
      knowledgePages = loadedKnowledgePages
      knowledgePageReadState.load(productID: productID, pages: loadedKnowledgePages)
      unreadKnowledgePageIDs = knowledgePageReadState.unreadPageIDs(in: loadedKnowledgePages)
      productRepository = loadedRepository
      repositoryKnowledgeRun = loadedRepositoryRun
      repositoryKnowledgeDrafts = loadedRepositoryDrafts
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
      conversationThreads = loadedConversationThreads
      conversationMessagesByThread = loadedConversationMessages
    } catch {
      presentExecutionError(error, productID: productID)
    }
  }

  private func startCodexUsageMonitoring(client: CodexAppServerClient) async {
    stopCodexUsageMonitoring()
    let monitorID = UUID()
    codexUsageMonitorID = monitorID
    isRefreshingCodexUsage = true
    let messages = await client.inboundMessages(replayRecent: false)

    codexUsageMonitoringTask = Task { [weak self] in
      guard let self else { return }
      await self.refreshCodexUsage(client: client, monitorID: monitorID)
      for await message in messages {
        guard !Task.isCancelled else { return }
        guard
          case .notification(let notification) = message,
          notification.method == "account/rateLimits/updated"
        else { continue }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await self.refreshCodexUsage(client: client, monitorID: monitorID)
      }
    }
  }

  private func refreshCodexUsage(
    client: CodexAppServerClient,
    monitorID: UUID
  ) async {
    guard codexUsageMonitorID == monitorID else { return }
    isRefreshingCodexUsage = true
    do {
      let snapshot = try await client.readRateLimits()
      guard codexUsageMonitorID == monitorID else { return }
      codexRateLimits = snapshot
      codexUsageUpdatedAt = Date()
      isCodexUsageStale = false
      isRefreshingCodexUsage = false
      scheduleCodexUsageReset(snapshot.nextResetAt, client: client, monitorID: monitorID)
    } catch {
      guard codexUsageMonitorID == monitorID else { return }
      isRefreshingCodexUsage = false
      isCodexUsageStale = codexRateLimits != nil
    }
  }

  private func scheduleCodexUsageReset(
    _ resetAt: Date?,
    client: CodexAppServerClient,
    monitorID: UUID
  ) {
    codexUsageResetTask?.cancel()
    guard let resetAt else {
      codexUsageResetTask = nil
      return
    }
    let delay = resetAt.timeIntervalSinceNow + 1
    guard delay > 0 else {
      codexUsageResetTask = nil
      return
    }
    codexUsageResetTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard let self, self.codexUsageMonitorID == monitorID else { return }
      self.isRefreshingCodexUsage = true
      await self.refreshCodexUsage(client: client, monitorID: monitorID)
    }
  }

  private func stopCodexUsageMonitoring() {
    codexUsageMonitoringTask?.cancel()
    codexUsageMonitoringTask = nil
    codexUsageResetTask?.cancel()
    codexUsageResetTask = nil
    codexUsageMonitorID = nil
    codexRateLimits = nil
    codexUsageUpdatedAt = nil
    isRefreshingCodexUsage = false
    isCodexUsageStale = false
  }

  private func connectCodex() async {
    codexConnectionState = .checking
    stopCodexUsageMonitoring()
    codexModels = []
    refreshCodexInstallations()
    let candidates = selectedCodexInstallation.map(\.runtimeCandidate).map { [$0] } ?? []

    do {
      let descriptor = try await Task.detached(priority: .userInitiated) {
        try CodexRuntimeResolver().resolve(candidates: candidates)
      }.value
      let transport = CodexJSONLTransport(
        configuration: .init(
          executableURL: descriptor.executableURL,
          environmentOverrides: CodexPermissionProfiles.agentProcessEnvironment,
          environmentMode: .replace
        )
      )
      let client = CodexAppServerClient(transport: transport)
      let info: CodexConnectionInfo
      let models: [CodexModelOption]
      do {
        info = try await client.connect()
        models = try await client.listModels()
      } catch {
        await client.disconnect()
        throw error
      }
      codexClient = client
      codexRuntimeExecutableURL = descriptor.executableURL
      demoLauncher.useExecutor(
        CodexWorkspaceCommandExecutor(executableURL: descriptor.executableURL)
      )
      startApprovalRouting(client: client)
      await startCodexUsageMonitoring(client: client)
      codexConnectionState = .connected(version: descriptor.version, userAgent: info.userAgent)
      scheduleRetrospectiveSyntheses()
      scheduleRepositoryKnowledgeRuns()
      codexModels = models
    } catch let error as CodexRuntimeError {
      codexRuntimeExecutableURL = nil
      switch error {
      case .missingRequiredFeature:
        codexConnectionState = .incompatible(error.localizedDescription)
      default:
        codexConnectionState = .unavailable(error.localizedDescription)
      }
    } catch {
      codexRuntimeExecutableURL = nil
      codexConnectionState = .unavailable(error.localizedDescription)
    }
  }

  func selectCodexInstallation(id: String) async {
    guard canChangeCodexInstallation else {
      errorMessage = CodexInstallationSelectionError.workInProgress.localizedDescription
      return
    }
    guard codexInstallations.contains(where: { $0.id == id }) else {
      errorMessage = CodexInstallationSelectionError.invalidSelection.localizedDescription
      return
    }
    guard selectedCodexInstallationID != id else { return }

    selectedCodexInstallationID = id
    codexInstallationPreferences.saveSelectedInstallationID(id)
    await reconnectCodex()
  }

  func addCodexInstallation(at selectionURL: URL) async {
    guard canChangeCodexInstallation else {
      errorMessage = CodexInstallationSelectionError.workInProgress.localizedDescription
      return
    }

    let executableURL = CodexInstallationDiscovery.executableURL(
      forSelection: selectionURL
    )
    guard
      executableURL.lastPathComponent == "codex",
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      errorMessage = CodexInstallationSelectionError.invalidSelection.localizedDescription
      return
    }

    if let existing = codexInstallations.first(where: {
      Self.sameFileLocation($0.executableURL, executableURL)
    }) {
      await selectCodexInstallation(id: existing.id)
      return
    }

    do {
      _ = try await Task.detached(priority: .userInitiated) {
        try CodexRuntimeResolver().resolve(
          candidates: [
            CodexRuntimeCandidate(executableURL: executableURL, source: .custom)
          ]
        )
      }.value
    } catch let error as CodexRuntimeError {
      errorMessage = error.localizedDescription
      return
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    var stored = codexInstallationPreferences.customInstallations()
    let installation = CodexInstallationDiscovery.customInstallation(
      forSelection: selectionURL,
      existing: stored
    )
    if !stored.contains(where: { $0.id == installation.id }) {
      stored.append(installation)
      codexInstallationPreferences.saveCustomInstallations(stored)
    }
    refreshCodexInstallations()
    await selectCodexInstallation(id: installation.id)
  }

  func removeCodexInstallation(id: String) async {
    guard canChangeCodexInstallation else {
      errorMessage = CodexInstallationSelectionError.workInProgress.localizedDescription
      return
    }
    guard codexInstallations.first(where: { $0.id == id })?.kind == .custom else {
      return
    }

    let wasSelected = selectedCodexInstallationID == id
    let remaining = codexInstallationPreferences.customInstallations().filter {
      $0.id != id
    }
    codexInstallationPreferences.saveCustomInstallations(remaining)
    refreshCodexInstallations()

    if wasSelected {
      let replacementID = codexInstallations.first?.id
      selectedCodexInstallationID = replacementID
      codexInstallationPreferences.saveSelectedInstallationID(replacementID)
      await reconnectCodex()
    }
  }

  func retryCodexConnection() async {
    guard canChangeCodexInstallation else {
      errorMessage = CodexInstallationSelectionError.workInProgress.localizedDescription
      return
    }
    await reconnectCodex()
  }

  private func reconnectCodex() async {
    approvalRoutingTask?.cancel()
    stopCodexUsageMonitoring()
    approvalRoutingTask = nil
    await codexClient?.disconnect()
    codexClient = nil
    demoLauncher.clearExecutor()
    await connectCodex()
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
      let store = store(for: request.productID),
      let client = codexClient
    else {
      errorMessage =
        "This permission request is no longer waiting for a decision."
      return
    }
    let serverRequest = liveApprovalRequests[request.id]
    guard request.status != .pending || serverRequest != nil else {
      errorMessage =
        "This permission request is no longer attached to a live agent turn. Relaunch Spedito to recover it before deciding."
      return
    }
    let resumesAfterDecision = request.status == .interrupted
    let intent: AgentPermissionRequestStatus
    if allow && rememberForProduct {
      intent = .allowProductPendingDelivery
    } else if allow {
      intent = .allowOncePendingDelivery
    } else {
      intent = .denyPendingDelivery
    }

    let proposedGrant: AgentPermissionGrant?
    if intent == .allowProductPendingDelivery {
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

    do {
      let result = try await AgentPermissionResolver(
        persistence: store,
        responder: client
      ).resolve(
        request: request,
        serverRequest: serverRequest,
        intent: intent,
        productGrant: proposedGrant
      )
      if result.responseDelivered {
        liveApprovalRequests.removeValue(forKey: request.id)
        liveApprovalRequestProductIDs.removeValue(forKey: request.id)
      }
      replacePermissionRequest(result.request)
      if let savedGrant = result.grant {
        replacePermissionGrant(savedGrant)
      }
      if let run = try? await store.fetchAgentRun(id: request.agentRunID),
        run.status == .awaitingOwner
      {
        let eventDetail =
          if resumesAfterDecision && allow && rememberForProduct {
            "Saved the recovered capability for this product; queued the conversation to resume"
          } else if resumesAfterDecision && allow {
            "Saved the recovered one-time permission; queued the conversation to resume"
          } else if resumesAfterDecision {
            "Saved the recovered denial; queued the conversation so the agent can adapt"
          } else if allow && rememberForProduct {
            "Saved and allowed the requested capability for this product"
          } else if allow {
            "Allowed the requested capability once"
          } else {
            "Denied the requested capability; the agent will adapt"
          }
        _ = try await updateAgentRun(
          id: request.agentRunID,
          status: resumesAfterDecision ? .queued : .running,
          eventActor: "Product owner",
          eventDetail: eventDetail
        )
      }
      await reloadSelectedProductIfCurrent(productID: request.productID)
      if resumesAfterDecision {
        scheduleSprintExecution(productID: request.productID)
      }
    } catch {
      if let persisted = try? await store.fetchAgentPermissionRequest(id: request.id) {
        replacePermissionRequest(persisted)
      }
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
    let presentation: CodexApprovalPresentation
    do {
      presentation = try CodexAppServerClient.approvalPresentation(for: request)
    } catch {
      await client.rejectUnsupportedServerRequest(request)
      return
    }
    let activeMatch = activeExecutionTurns.first(where: {
      $0.value.threadID == presentation.threadID
        && $0.value.turnID == presentation.turnID
    })
    let runID =
      activeMatch?.key
      ?? runs
      .filter {
        $0.codexThreadID == presentation.threadID
          && ($0.status == .running || $0.status == .awaitingOwner)
      }
      .max(by: { $0.createdAt < $1.createdAt })?
      .id
    let runStore: SQLiteStore?
    if let productID = activeMatch?.value.productID {
      runStore = store(for: productID)
    } else if let runID, let storeRegistry {
      runStore = await storeRegistry.findStore(containingAgentRun: runID)
    } else {
      runStore = injectedStore ?? store
    }
    guard let runID, let store = runStore else {
      await client.rejectUnsupportedServerRequest(request)
      return
    }

    let run: AgentRun
    let productPermissionRequests: [AgentPermissionRequest]
    let productPermissionGrants: [AgentPermissionGrant]
    do {
      run = try await store.fetchAgentRun(id: runID)
      productPermissionRequests = try await store.fetchAgentPermissionRequests(
        productID: run.productID
      )
      productPermissionGrants = try await store.fetchAgentPermissionGrants(
        productID: run.productID
      )
    } catch {
      errorMessage =
        "The permission request could not be checked against its durable history, so no response was sent. \(error.localizedDescription)"
      return
    }

    let productGrantSignature = try? CodexAppServerClient.productGrantSignature(
      for: request,
      ticketWorkspaceRoot: run.worktreePath.map {
        URL(fileURLWithPath: $0)
      }
    )
    let serverRequestID = Self.serverRequestID(request.id)
    let exactRequest = productPermissionRequests
      .filter {
        $0.agentRunID == runID
          && $0.serverRequestID == serverRequestID
          && $0.signature == presentation.signature
      }
      .max(by: { $0.updatedAt < $1.updatedAt })

    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.requestsProtectedSpeditoStorage(
        productGrantSignature: signature,
        kind: presentation.kind,
        ticketWorkspaceRoot: run.worktreePath.map {
          URL(fileURLWithPath: $0)
        },
        protectedStorageRoots: CodexPermissionProfiles.protectedSpeditoDeliveryStorageRoots
      )
    {
      let policyExplanation =
        "Spedito protected storage owned by another execution. This delivery run must use its assigned ticket worktree; managed preview, integration, product-control, and other ticket workspaces are not available to it."
      let recordedReason =
        presentation.reason.map {
          "\(policyExplanation)\n\nAgent rationale: \($0)"
        } ?? policyExplanation
      let record =
        exactRequest
        ?? permissionRequestRecord(
          run: run,
          presentation: presentation,
          request: request,
          productGrantSignature: productGrantSignature,
          reason: recordedReason,
          status: .policyDenyPendingDelivery
        )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: exactRequest != nil,
        intent: .policyDenyPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    if let exactRequest {
      if let intent = exactRequest.status.replayIntent {
        await resolveAutomaticPermissionRequest(
          exactRequest,
          isPersisted: true,
          intent: intent,
          serverRequest: request,
          store: store,
          client: client
        )
      } else {
        liveApprovalRequests[exactRequest.id] = request
        liveApprovalRequestProductIDs[exactRequest.id] = run.productID
        replacePermissionRequest(exactRequest)
      }
      return
    }

    if let priorDecision =
      (productPermissionRequests
        .filter {
          $0.agentRunID == runID
            && $0.signature == presentation.signature
            && $0.status.replayIntent != nil
            && ($0.status != .existingAccess
              || $0.turnID == presentation.turnID)
            && ($0.status != .existingAccessPendingDelivery
              || $0.turnID == presentation.turnID)
        }
        .max(by: { $0.updatedAt < $1.updatedAt })),
      let intent = priorDecision.status.replayIntent
    {
      let record = permissionRequestRecord(
        run: run,
        presentation: presentation,
        request: request,
        productGrantSignature: productGrantSignature,
        reason: presentation.reason,
        status: intent
      )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: false,
        intent: intent,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.coversActiveRunRequest(
        productGrantSignature: signature,
        kind: presentation.kind,
        turnID: presentation.turnID,
        ticketWorkspaceRoot: run.worktreePath.map {
          URL(fileURLWithPath: $0)
        },
        writableTransientStorageRoots: CodexPermissionProfiles.macOSUserTransientStorageRoots,
        requests: productPermissionRequests.filter { $0.agentRunID == runID }
      )
    {
      let record = permissionRequestRecord(
        run: run,
        presentation: presentation,
        request: request,
        productGrantSignature: productGrantSignature,
        reason: presentation.reason,
        status: .existingAccessPendingDelivery
      )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: false,
        intent: .existingAccessPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    if let signature = productGrantSignature,
      AgentPermissionGrantPolicy.covers(
        productGrantSignature: signature,
        kind: presentation.kind,
        grants: productPermissionGrants.filter { $0.productID == run.productID }
      )
    {
      let record = permissionRequestRecord(
        run: run,
        presentation: presentation,
        request: request,
        productGrantSignature: productGrantSignature,
        reason: presentation.reason,
        status: .grantAccessPendingDelivery
      )
      await resolveAutomaticPermissionRequest(
        record,
        isPersisted: false,
        intent: .grantAccessPendingDelivery,
        serverRequest: request,
        store: store,
        client: client
      )
      return
    }

    let record = permissionRequestRecord(
      run: run,
      presentation: presentation,
      request: request,
      productGrantSignature: productGrantSignature,
      reason: presentation.reason,
      status: .pending
    )
    do {
      let saved = try await store.saveAgentPermissionRequest(record)
      liveApprovalRequests[saved.id] = request
      liveApprovalRequestProductIDs[saved.id] = run.productID
      replacePermissionRequest(saved)
      _ = try await updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Waiting for a scoped permission decision"
      )
      await reloadSelectedProductIfCurrent(productID: run.productID)
    } catch {
      errorMessage =
        "The permission request could not be saved, so no response was sent. \(error.localizedDescription)"
    }
  }

  private func permissionRequestRecord(
    run: AgentRun,
    presentation: CodexApprovalPresentation,
    request: CodexServerRequest,
    productGrantSignature: String?,
    reason: String?,
    status: AgentPermissionRequestStatus
  ) -> AgentPermissionRequest {
    AgentPermissionRequest(
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
      reason: reason,
      signature: presentation.signature,
      productGrantSignature: productGrantSignature,
      status: status
    )
  }

  private func resolveAutomaticPermissionRequest(
    _ request: AgentPermissionRequest,
    isPersisted: Bool,
    intent: AgentPermissionRequestStatus,
    serverRequest: CodexServerRequest,
    store: SQLiteStore,
    client: CodexAppServerClient
  ) async {
    do {
      let durableRequest =
        if isPersisted {
          request
        } else {
          try await store.saveAgentPermissionRequest(request)
        }
      let proposedGrant: AgentPermissionGrant?
      if intent == .allowProductPendingDelivery {
        guard let signature = durableRequest.productGrantSignature else {
          throw PersistenceError.corruptData(
            "The saved product permission has no reusable signature"
          )
        }
        proposedGrant = AgentPermissionGrant(
          productID: durableRequest.productID,
          sourceRequestID: durableRequest.id,
          method: durableRequest.method,
          kind: durableRequest.kind,
          title: durableRequest.title,
          detail: durableRequest.detail,
          signature: signature
        )
      } else {
        proposedGrant = nil
      }
      let result = try await AgentPermissionResolver(
        persistence: store,
        responder: client
      ).resolve(
        request: durableRequest,
        serverRequest: serverRequest,
        intent: intent,
        productGrant: proposedGrant
      )
      if result.responseDelivered {
        liveApprovalRequests.removeValue(forKey: result.request.id)
        liveApprovalRequestProductIDs.removeValue(forKey: result.request.id)
      }
      replacePermissionRequest(result.request)
      if let grant = result.grant {
        replacePermissionGrant(grant)
      }
    } catch {
      if let persisted = try? await store.fetchAgentPermissionRequest(id: request.id) {
        replacePermissionRequest(persisted)
      }
      errorMessage = error.localizedDescription
    }
  }

  private func replacePermissionRequest(_ request: AgentPermissionRequest) {
    guard selectedProductID == request.productID else { return }
    permissionRequests.removeAll { $0.id == request.id }
    permissionRequests.append(request)
    permissionRequests.sort { $0.createdAt < $1.createdAt }
  }

  func revokePermissionGrants(_ grantIDs: [UUID]) async {
    guard
      !grantIDs.isEmpty,
      let productID = permissionGrants.first(where: { grantIDs.contains($0.id) })?.productID,
      let store = store(for: productID)
    else { return }
    do {
      _ = try await store.revokeAgentPermissionGrants(ids: grantIDs)
      let revokedIDs = Set(grantIDs)
      permissionGrants.removeAll { revokedIDs.contains($0.id) }
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
    let productID = session.productID

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
        guard selectedProductID == productID else {
          try? await store.failTicketSuggestionSession(
            sessionID: restartedSession.id,
            message: "Epic planning recovery was interrupted by a product change."
          )
          return
        }
        suggestionBatch = TicketSuggestionBatch(session: restartedSession, suggestions: [])
      } catch {
        errorMessage = error.localizedDescription
        return
      }
    }

    guard selectedProductID == productID else { return }
    automaticallyRecoveredSuggestionSessionIDs.insert(session.id)
    await restoreEpicPlanningConversation(for: epic)
    generateEpicPlan(epic, recovering: session)
  }

  private func refreshCodexInstallations() {
    let officialApplicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: CodexInstallationDiscovery.officialBundleIdentifier
    )
    codexInstallations = CodexInstallationDiscovery.discover(
      officialApplicationURL: officialApplicationURL,
      bundledExecutableURL: Bundle.main.url(forAuxiliaryExecutable: "codex"),
      customInstallations: codexInstallationPreferences.customInstallations()
    )

    let savedID =
      selectedCodexInstallationID
      ?? codexInstallationPreferences.selectedInstallationID()
    if let savedID {
      selectedCodexInstallationID = savedID
    } else {
      selectedCodexInstallationID = codexInstallations.first?.id
      codexInstallationPreferences.saveSelectedInstallationID(
        selectedCodexInstallationID
      )
    }
  }

  private static func sameFileLocation(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
      == rhs.standardizedFileURL.resolvingSymlinksInPath().path
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
    return try migratedApplicationSupportURL(in: root)
  }

  static func migratedApplicationSupportURL(
    in root: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let currentURL = root.appendingPathComponent("Spedito", isDirectory: true)
    let legacyURL = root.appendingPathComponent("StoryPointless", isDirectory: true)
    if !fileManager.fileExists(atPath: currentURL.path),
      fileManager.fileExists(atPath: legacyURL.path)
    {
      try fileManager.moveItem(at: legacyURL, to: currentURL)
    }
    return currentURL
  }

  static func migrateLegacyDefaults(
    from legacyDomain: String = legacyDefaultsDomain,
    to defaults: UserDefaults = .standard
  ) {
    guard !defaults.bool(forKey: legacyDefaultsMigrationKey) else { return }
    guard let values = defaults.persistentDomain(forName: legacyDomain) else {
      return
    }
    for (key, value) in values where defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
    }
    defaults.set(true, forKey: legacyDefaultsMigrationKey)
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

  private static func productDatabaseURL(productID: UUID) throws -> URL {
    ProductStoreRegistry.databaseURL(
      productID: productID,
      productWorkspacesRootURL: try applicationSupportURL()
        .appendingPathComponent("Product Workspaces", isDirectory: true)
    )
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
    let url =
      cachesURL
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      .appendingPathComponent(productID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

}
