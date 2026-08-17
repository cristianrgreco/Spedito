import AppKit
import Combine
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
final class AppModel: ObservableObject, TicketDeliveryWorkflowDelegate {
  private(set) var products: [Product] {
    get { productLibraryFeature.products }
    set { productLibraryFeature.products = newValue }
  }
  private(set) var archivedProducts: [Product] {
    get { productLibraryFeature.archivedProducts }
    set { productLibraryFeature.archivedProducts = newValue }
  }
  @Published private(set) var ticketAttentionsByProductID: [UUID: [TicketAttention]] = [:]
  @Published private(set) var ticketAttentionNavigationRequest: TicketAttentionNavigationRequest?
  @Published private(set) var ownerNotificationNavigationRequest:
    OwnerNotificationNavigationRequest?
  @Published private(set) var epics: [Epic] = []
  @Published private(set) var workItems: [WorkItem] = []
  @Published private(set) var dependencies: [WorkItemDependency] = []
  @Published private(set) var profiles: [AgentProfile] = []
  @Published private(set) var sprintPlan: SprintPlan?
  @Published private(set) var sprintHistory: [SprintPlan] = []
  @Published private(set) var runs: [AgentRun] = []
  var sprintReadinessIssues: [SprintReadinessIssue] {
    sprintPlanningFeature.snapshot.readinessIssues
  }
  @Published private(set) var activity: [ActivityEvent] = []
  private(set) var retrospectiveNotes: [RetrospectiveNote] {
    get { retrospectiveSynthesisRuntime.notes }
    set { retrospectiveSynthesisRuntime.notes = newValue }
  }
  private(set) var retrospectiveSyntheses: [RetrospectiveSynthesis] {
    get { retrospectiveSynthesisRuntime.syntheses }
    set { retrospectiveSynthesisRuntime.syntheses = newValue }
  }
  private(set) var retrospectiveActionSources: [RetrospectiveActionSource] {
    get { retrospectiveSynthesisRuntime.actionSources }
    set { retrospectiveSynthesisRuntime.actionSources = newValue }
  }
  @Published private(set) var knowledgePages: [KnowledgePage] = []
  @Published private(set) var unreadKnowledgePageIDs: Set<UUID> = []
  @Published private(set) var productRepository: ProductRepository?
  @Published private(set) var ticketAcceptanceInProgressWorkItemIDs: Set<UUID> = []
  @Published private(set) var repositoryImportSnapshot = RepositoryImportSnapshot()
  @Published private(set) var importedAppLaunch: ImportedAppLaunch?
  @Published private(set) var repositoryKnowledgeSnapshot: RepositoryKnowledgeSnapshot?
  @Published private(set) var candidateRevisions: [CandidateRevision] = []
  private(set) var demoSessions: [DemoSession] {
    get { demoSessionFeature.sessions }
    set { demoSessionFeature.sessions = newValue }
  }
  @Published private(set) var permissionRequests: [AgentPermissionRequest] = []
  @Published private(set) var permissionGrants: [AgentPermissionGrant] = []
  @Published private(set) var knowledgePageProposals: [KnowledgePageProposal] = []
  @Published private(set) var agentRunKnowledgeContext: [AgentRunKnowledgePage] = []
  @Published private(set) var agentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] = []
  @Published private(set) var liveRunActivities: [UUID: CodexLiveActivity] = [:]
  var suggestionBatch: TicketSuggestionBatch? {
    epicPlanningFeature.snapshot.suggestionBatch
  }
  var conversationThreads: [ProductConversationThread] {
    productConversationFeature.threads
  }
  var conversationMessagesByThread: [UUID: [ProductConversationMessage]] {
    productConversationFeature.messagesByThread
  }
  var respondingConversationThreadIDs: Set<UUID> {
    productConversationFeature.respondingThreadIDs
  }
  var productConversationActivities: [UUID: CodexLiveActivity] {
    productConversationFeature.activities
  }
  var conversationErrorsByThread: [UUID: String] {
    productConversationFeature.errorsByThread
  }
  private(set) var codexModels: [CodexModelOption] {
    get { codexConnectionRuntime.models }
    set { codexConnectionRuntime.models = newValue }
  }
  private(set) var codexConnectionState: CodexConnectionState {
    get { codexConnectionRuntime.connectionState }
    set { codexConnectionRuntime.connectionState = newValue }
  }
  private(set) var codexRateLimits: CodexRateLimitsSnapshot? {
    get { codexConnectionRuntime.rateLimits }
    set { codexConnectionRuntime.rateLimits = newValue }
  }
  private(set) var codexUsageUpdatedAt: Date? {
    get { codexConnectionRuntime.usageUpdatedAt }
    set { codexConnectionRuntime.usageUpdatedAt = newValue }
  }
  private(set) var isRefreshingCodexUsage: Bool {
    get { codexConnectionRuntime.isRefreshingUsage }
    set { codexConnectionRuntime.isRefreshingUsage = newValue }
  }
  private(set) var isCodexUsageStale: Bool {
    get { codexConnectionRuntime.isUsageStale }
    set { codexConnectionRuntime.isUsageStale = newValue }
  }
  private(set) var codexInstallations: [CodexInstallation] {
    get { codexConnectionRuntime.installations }
    set { codexConnectionRuntime.installations = newValue }
  }
  private(set) var selectedCodexInstallationID: String? {
    get { codexConnectionRuntime.selectedInstallationID }
    set { codexConnectionRuntime.selectedInstallationID = newValue }
  }
  var selectedProductID: UUID? {
    get { productLibraryFeature.selectedProductID }
    set { productLibraryFeature.selectedProductID = newValue }
  }
  private(set) var shouldPresentProductLibraryOnLaunch: Bool {
    get { productLibraryFeature.shouldPresentOnLaunch }
    set { productLibraryFeature.shouldPresentOnLaunch = newValue }
  }
  @Published var errorMessage: String?
  private(set) var productCreationError: String? {
    get { productLibraryFeature.creationError }
    set { productLibraryFeature.creationError = newValue }
  }
  @Published private(set) var isLoading = true
  var isDecidingSuggestions: Bool {
    epicPlanningFeature.snapshot.isDecidingSuggestions
  }
  var isPlanningMessageRunning: Bool {
    sprintPlanningFeature.snapshot.isSendingMessage
  }
  var isGeneratingSprintGoal: Bool {
    sprintPlanningFeature.snapshot.isGeneratingGoal
  }
  var isTicketConversationMessageRunning: Bool {
    planningConversationFeature.snapshot.isTicketConversationMessageRunning
  }
  var ticketConversationWorkItemID: UUID? {
    planningConversationFeature.snapshot.ticketConversationWorkItemID
  }
  var ticketConversationRecipientID: UUID? {
    planningConversationFeature.snapshot.ticketConversationRecipientID
  }
  var ticketConversationActivity: CodexLiveActivity? {
    planningConversationFeature.snapshot.ticketConversationActivity
  }
  var isEpicConversationMessageRunning: Bool {
    planningConversationFeature.snapshot.isEpicConversationMessageRunning
  }
  var epicConversationEpicID: UUID? {
    planningConversationFeature.snapshot.epicConversationEpicID
  }
  var epicConversationRecipientID: UUID? {
    planningConversationFeature.snapshot.epicConversationRecipientID
  }
  var ticketRefinementResults: [UUID: TicketRefinementSessionResult] {
    planningConversationFeature.snapshot.ticketRefinementResults
  }
  var ticketConversationResults: [UUID: TicketConversationSessionResult] {
    planningConversationFeature.snapshot.ticketConversationResults
  }
  var epicPlanningConversation: EpicPlanningConversationState? {
    epicPlanningFeature.snapshot.conversation
  }
  @Published private(set) var isAskingKnowledge = false
  var refiningWorkItemID: UUID? {
    planningConversationFeature.snapshot.refiningWorkItemID
  }
  @Published private(set) var codebaseFocusWorkItemID: UUID?
  @Published private(set) var knowledgeFocusPageID: UUID?
  @Published var backlogFocusEpicID: UUID?
  @Published var conversationFocusThreadID: UUID?

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
    sprintPlanningWorkflowCoordinator.candidateSprintPlan()
  }

  func remoteRepositorySnapshot(
    for productID: UUID
  ) -> RemoteRepositoryPresentationSnapshot {
    remoteRepositoryFeature.snapshot(for: productID)
  }

  func remoteRepositorySnapshotIfLoaded(
    for productID: UUID
  ) -> RemoteRepositoryPresentationSnapshot? {
    remoteRepositoryFeature.snapshotIfLoaded(for: productID)
  }

  var selectedRemoteRepositorySnapshot: RemoteRepositoryPresentationSnapshot? {
    guard let selectedProductID else { return nil }
    return remoteRepositoryFeature.snapshotIfLoaded(for: selectedProductID)
  }

  private let storeRegistry: ProductStoreRegistry?
  private let injectedStore: SQLiteStore?
  private var store: SQLiteStore? {
    if let injectedStore { return injectedStore }
    guard let selectedProductID else { return nil }
    return storeRegistry?.store(for: selectedProductID)
  }
  private let gitWorkspaceManager: GitWorkspaceManager
  private let repositoryImportActivator: (any RepositoryImportActivating)?
  private let remoteRepositoryFeature: RemoteRepositoryFeatureModel
  private lazy var repositoryImportCoordinator: RepositoryImportCoordinator? = {
    return RepositoryImportCoordinator(
      activator: repositoryImportActivator,
      sourceResolver: remoteRepositoryFeature,
      blankProductActivator: { [weak self] name, repositoryID in
        guard let self else { throw CancellationError() }
        let product = try await self.createBlankProduct(name: name)
        guard self.remoteRepositoryFeature.isAvailable else {
          let message =
            "The Product was created, but this Spedito build is not configured for GitHub."
          return RepositoryImportCompletion(
            product: product,
            provenance: .emptyRepository(remoteState: nil),
            ownerFacingWarning: message
          )
        }
        do {
          let state = try await self.remoteRepositoryFeature.connectLocalProduct(
            productID: product.id,
            repositoryID: repositoryID
          )
          return RepositoryImportCompletion(
            product: product,
            provenance: .emptyRepository(remoteState: state)
          )
        } catch {
          let message =
            "The Product was created, but its GitHub repository connection needs attention. \(error.localizedDescription)"
          return RepositoryImportCompletion(
            product: product,
            provenance: .emptyRepository(remoteState: nil),
            ownerFacingWarning: message
          )
        }
      },
      onSnapshot: { [weak self] snapshot in
        guard let self, !self.isShuttingDown else { return }
        self.repositoryImportSnapshot = snapshot
      }
    )
  }()
  private lazy var repositoryKnowledgeCoordinator: RepositoryKnowledgeCoordinator = {
    RepositoryKnowledgeCoordinator(
      storeProvider: { [weak self] productID in
        self?.store(for: productID)
      },
      workspaceURLProvider: { [weak self] productID in
        guard let self else { throw CancellationError() }
        if let storeRegistry = self.storeRegistry {
          return storeRegistry.productWorkspacesRootURL
            .appendingPathComponent(productID.uuidString, isDirectory: true)
        }
        return try Self.productWorkspaceURL(productID: productID)
      },
      gitWorkspaceManager: gitWorkspaceManager,
      onSnapshot: { [weak self] snapshot, _ in
        guard let self, !self.isShuttingDown else { return }
        if self.selectedProductID == snapshot.productID {
          self.repositoryKnowledgeSnapshot = snapshot
          if let failure = snapshot.failure {
            self.errorMessage = failure.message
          }
        }
      },
      onEvent: { [weak self] event in
        guard let self, !self.isShuttingDown else { return }
        if case .completed(let productID, _) = event,
          self.selectedProductID == productID
        {
          await self.reloadSelectedProduct()
        }
      }
    )
  }()
  private lazy var ticketDeliveryRuntimeCoordinator = TicketDeliveryRuntimeCoordinator(
    prepareScheduler: { [weak self] productID in
      guard let self else { return }
      await self.recoverDeliveryExecution(productID: productID)
      await self.reloadSelectedProductIfCurrent(productID: productID)
    },
    drainScheduler: { [weak self] productID in
      guard let self else { return .finished }
      return await self.drainSprintQueueIteration(productID: productID)
    },
    onAcceptanceChange: { [weak self] workItemIDs in
      self?.ticketAcceptanceInProgressWorkItemIDs = workItemIDs
    }
  )
  private lazy var ticketDeliveryWorkflowCoordinator = TicketDeliveryWorkflowCoordinator(
    delegate: self,
    gitWorkspaceManager: gitWorkspaceManager,
    runtimeCoordinator: ticketDeliveryRuntimeCoordinator,
    recoveryPolicy: sprintWorkRecoveryPolicy,
    prepareAcceptance: prepareTicketDeliveryAcceptanceForUIFixture
  )
  private lazy var ticketDeliveryPermissionWorkflowCoordinator =
    TicketDeliveryPermissionWorkflowCoordinator(
      delegate: self,
      runtimeCoordinator: ticketDeliveryRuntimeCoordinator
    )
  let productLibraryFeature = ProductLibraryFeatureModel()
  let planningConversationFeature = PlanningConversationFeatureModel()
  let epicPlanningFeature = EpicPlanningFeatureModel()
  let sprintPlanningFeature = SprintPlanningFeatureModel()
  let retrospectiveSynthesisRuntime = RetrospectiveSynthesisRuntime()
  lazy var epicPlanningWorkflowCoordinator = EpicPlanningWorkflowCoordinator(
    storeProvider: { [weak self] productID in
      self?.store(for: productID)
    },
    clientProvider: { [weak self] in
      self?.codexClient
    },
    productProvider: { [weak self] productID in
      self?.products.first(where: { $0.id == productID })
    },
    selectedProductID: { [weak self] in
      self?.selectedProductID
    },
    availabilityProvider: { [weak self] in
      guard let self else {
        return EpicPlanningWorkflowAvailability(
          canAutosuggestTickets: false,
          canPlanEpic: false
        )
      }
      return EpicPlanningWorkflowAvailability(
        canAutosuggestTickets: canAutosuggestTickets,
        canPlanEpic: canPlanEpic
      )
    },
    isShuttingDown: { [weak self] in
      self?.isShuttingDown ?? true
    },
    workspaceProvider: { productID in
      try Self.productWorkspaceURL(productID: productID)
    },
    inheritedInstructions: { [weak self] product in
      self?.inheritedAgentInstructions(
        for: product,
        allowsRepositoryInspection: false
      ) ?? ""
    },
    recoveryPolicy: ticketSuggestionRecoveryPolicy,
    onSnapshotChange: { [weak self] snapshot in
      self?.epicPlanningFeature.snapshot = snapshot
    },
    onOwnerNotification: { [weak self] notification in
      await self?.publishOwnerNotification(notification)
    },
    onResolveOwnerNotification: { [weak self] productID, target in
      await self?.ownerNotificationCoordinator.resolve(
        productID: productID,
        target: target
      )
    },
    onReloadSelectedProduct: { [weak self] productID in
      await self?.reloadSelectedProductIfCurrent(productID: productID)
    },
    onError: { [weak self] error, productID in
      self?.presentExecutionError(error, productID: productID)
    }
  )
  lazy var sprintPlanningWorkflowCoordinator = SprintPlanningWorkflowCoordinator(
    storeProvider: { [weak self] productID in
      self?.store(for: productID)
    },
    clientProvider: { [weak self] in
      self?.codexClient
    },
    selectedProductID: { [weak self] in
      self?.selectedProductID
    },
    contextProvider: { [weak self] productID in
      guard
        let self,
        selectedProductID == productID
      else { return nil }
      return SprintPlanningWorkflowContext(
        product: selectedProduct,
        workItems: workItems,
        dependencies: dependencies,
        profiles: profiles,
        sprintPlan: sprintPlan,
        sprintHistory: sprintHistory,
        modelOptions: codexModels
      )
    },
    availabilityProvider: { [weak self] in
      guard let self else {
        return SprintPlanningWorkflowAvailability(
          isSuggestionGenerationRunning: false,
          isTicketConversationRunning: false,
          isEpicConversationRunning: false,
          refiningWorkItemID: nil,
          isEpicPlanningRunning: false,
          isEpicPlanGenerating: false
        )
      }
      return SprintPlanningWorkflowAvailability(
        isSuggestionGenerationRunning: suggestionBatch?.session.status == .generating,
        isTicketConversationRunning: isTicketConversationMessageRunning,
        isEpicConversationRunning: isEpicConversationMessageRunning,
        refiningWorkItemID: refiningWorkItemID,
        isEpicPlanningRunning: epicPlanningConversation?.isRunning == true,
        isEpicPlanGenerating: epicPlanningConversation?.isGeneratingPlan == true
      )
    },
    workspaceURLProvider: { productID in
      try Self.productWorkspaceURL(productID: productID)
    },
    inheritedInstructions: { [weak self] product in
      self?.inheritedAgentInstructions(
        for: product,
        includesMandatoryKnowledge: true,
        allowsRepositoryInspection: true
      ) ?? ""
    },
    onReloadActivity: { [weak self] productID in
      try await self?.reloadSprintPlanningActivity(productID: productID)
    },
    onReloadSelectedProduct: { [weak self] productID in
      await self?.reloadSelectedProductIfCurrent(productID: productID)
    },
    onScheduleSprintExecution: { [weak self] productID in
      self?.scheduleSprintExecution(productID: productID)
    },
    onError: { [weak self] error, productID in
      self?.presentExecutionError(error, productID: productID)
    },
    onErrorMessage: { [weak self] message, productID in
      guard self?.selectedProductID == productID else { return }
      self?.errorMessage = message
    },
    onSnapshotChange: { [weak self] snapshot in
      self?.sprintPlanningFeature.snapshot = snapshot
    }
  )
  private lazy var planningConversationWorkflowCoordinator =
    PlanningConversationWorkflowCoordinator(
      storeProvider: { [weak self] productID in
        self?.store(for: productID)
      },
      clientProvider: { [weak self] in
        self?.codexClient
      },
      selectedProductID: { [weak self] in
        self?.selectedProductID
      },
      contextProvider: { [weak self] productID in
        guard
          let self,
          selectedProductID == productID,
          let product = selectedProduct,
          product.id == productID
        else { return nil }
        return PlanningConversationWorkflowContext(
          product: product,
          profiles: profiles,
          workItems: workItems,
          epics: epics,
          suggestionBatch: suggestionBatch
        )
      },
      availabilityProvider: { [weak self] in
        guard let self else {
          return PlanningConversationWorkflowAvailability(
            isCodexConnected: false,
            isSprintPlanningMessageRunning: false,
            isGeneratingSprintGoal: false,
            isSuggestionGenerationRunning: false,
            isEpicPlanningRunning: false,
            isEpicPlanGenerationRunning: false
          )
        }
        let isCodexConnected =
          if case .connected = codexConnectionState { true } else { false }
        return PlanningConversationWorkflowAvailability(
          isCodexConnected: isCodexConnected,
          isSprintPlanningMessageRunning: isPlanningMessageRunning,
          isGeneratingSprintGoal: isGeneratingSprintGoal,
          isSuggestionGenerationRunning: suggestionBatch?.session.status == .generating,
          isEpicPlanningRunning: epicPlanningConversation?.isRunning == true,
          isEpicPlanGenerationRunning: epicPlanningConversation?.isGeneratingPlan == true
        )
      },
      workspaceProvider: { productID in
        try Self.productWorkspaceURL(productID: productID)
      },
      inheritedInstructions: { [weak self] product in
        self?.inheritedAgentInstructions(for: product) ?? ""
      },
      awaitEpicPersistence: { [weak self] in
        await self?.epicPlanningWorkflowCoordinator.awaitPersistence()
      },
      onSnapshotChange: { [weak self] snapshot in
        self?.planningConversationFeature.snapshot = snapshot
      },
      onEpicConversationChange: { [weak self] conversation, threadID in
        self?.epicPlanningWorkflowCoordinator.loadConversationProjection(
          conversation,
          threadID: threadID
        )
      },
      onOwnerNotification: { [weak self] notification in
        await self?.publishOwnerNotification(notification)
      },
      onSelectedActivityChange: { [weak self] productID, activity in
        guard self?.selectedProductID == productID else { return }
        self?.activity = activity
      },
      onReloadSelectedProduct: { [weak self] productID in
        await self?.reloadSelectedProductIfCurrent(productID: productID)
      }
    )
  private lazy var ownerNotificationCoordinator = OwnerNotificationCoordinator(
    storeProvider: { [weak self] productID in
      self?.store(for: productID)
    },
    soundPlayer: ownerNotificationSoundPlayer,
    systemNotifier: ownerNotificationSystemNotifier
  )
  private(set) lazy var productConversationFeature = ProductConversationFeatureModel(
    selectedProduct: { [weak self] in self?.selectedProduct },
    profiles: { [weak self] in self?.profiles ?? [] },
    storeProvider: { [weak self] productID in self?.store(for: productID) },
    clientProvider: { [weak self] in self?.codexClient },
    isConnected: { [weak self] in
      guard let self, case .connected = self.codexConnectionState else { return false }
      return true
    },
    workspaceProvider: { productID in
      try Self.productWorkspaceURL(productID: productID)
    },
    inheritedInstructions: { [weak self] product in
      self?.inheritedAgentInstructions(for: product) ?? ""
    },
    modelOptions: { [weak self] in self?.codexModels ?? [] },
    isShuttingDown: { [weak self] in self?.isShuttingDown ?? true },
    onError: { [weak self] message in self?.errorMessage = message },
    onAgentReply: { [weak self] thread, message in
      await self?.publishConversationReply(thread: thread, message: message)
    }
  )
  let codexConnectionRuntime = CodexConnectionRuntime()
  private let transientOwnerCommandRuntime = TransientOwnerCommandRuntime()
  let demoSessionFeature = DemoSessionFeatureModel()
  private var demoLauncher: MacOSDemoLauncher { demoSessionFeature.launcher }
  private var productsLaunchingManagedPresentation: Set<UUID> {
    get { demoSessionFeature.productsLaunchingPresentation }
    set { demoSessionFeature.productsLaunchingPresentation = newValue }
  }
  private var featureObservations: Set<AnyCancellable> = []
  private let sprintWorkRecoveryPolicy = SprintWorkRecoveryPolicy()
  private let ticketSuggestionRecoveryPolicy = TicketSuggestionRecoveryPolicy()
  private let remoteProductArchivePolicy = RemoteProductArchivePolicy()
  private let ownerNotificationSoundPlayer: any OwnerNotificationSoundPlaying
  private let ownerNotificationSystemNotifier: any OwnerNotificationSystemNotifying
  private let codexInstallationPreferences: CodexInstallationPreferences
  private var knowledgePageReadState = KnowledgePageReadState()
  private var codexClient: CodexAppServerClient?
  private let codexTransportFactory: CodexTransportFactory
  private var codexRuntimeExecutableURL: URL?

  private var didLoad = false
  private var didResolveInitialProductSelection = false
  private var isShuttingDown = false

  private static let selectedProductDefaultsKey = "selectedProductID"
  private static let legacyDefaultsDomain = "com.storypointless.app"
  private static let legacyDefaultsMigrationKey =
    "migration.preSpeditoDefaultsCompleted"

  init(
    codexTransportFactory: @escaping CodexTransportFactory = makeProductionCodexTransport
  ) {
    Self.migrateLegacyDefaults()
    codexInstallationPreferences = CodexInstallationPreferences()
    self.codexTransportFactory = codexTransportFactory
    let gitWorkspaceManager = GitWorkspaceManager()
    var remoteService: (any GitHubRemoteRepositoryServing)?
    self.gitWorkspaceManager = gitWorkspaceManager
    let notificationAdapters = makeAppOwnerNotificationAdapters()
    ownerNotificationSoundPlayer = notificationAdapters.soundPlayer
    ownerNotificationSystemNotifier = notificationAdapters.systemNotifier
    let persistedSelectedProductID = UserDefaults.standard.string(
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
      repositoryImportActivator = ProductRepositoryImporter(
        registration: registry,
        gitWorkspaceManager: gitWorkspaceManager,
        stagingRootURL: baseURL.appendingPathComponent("Import Workspaces", isDirectory: true)
      )
      remoteService = makeAppRemoteRepositoryService(
        registry: registry,
        gitWorkspaceManager: gitWorkspaceManager,
        workspacesRootURL: workspacesRootURL
      )
      injectedStore = nil
    } catch {
      storeRegistry = nil
      repositoryImportActivator = nil
      injectedStore = nil
      errorMessage = error.localizedDescription
    }
    remoteRepositoryFeature = RemoteRepositoryFeatureModel(service: remoteService)
    productLibraryFeature.selectedProductID = persistedSelectedProductID
    observeFeatureModels()
    refreshCodexInstallations()
  }

  init(
    store: SQLiteStore?,
    selectedProductID: UUID? = nil,
    codexTransportFactory: @escaping CodexTransportFactory = makeProductionCodexTransport,
    ownerNotificationSoundPlayer: any OwnerNotificationSoundPlaying =
      BundledOwnerNotificationSoundPlayer(),
    ownerNotificationSystemNotifier: any OwnerNotificationSystemNotifying =
      MacOSOwnerNotificationNotifier(),
    remoteRepositoryFeature: RemoteRepositoryFeatureModel = RemoteRepositoryFeatureModel(
      service: nil
    )
  ) {
    codexInstallationPreferences = CodexInstallationPreferences()
    self.codexTransportFactory = codexTransportFactory
    gitWorkspaceManager = GitWorkspaceManager()
    repositoryImportActivator = nil
    storeRegistry = nil
    injectedStore = store
    self.remoteRepositoryFeature = remoteRepositoryFeature
    self.ownerNotificationSoundPlayer = ownerNotificationSoundPlayer
    self.ownerNotificationSystemNotifier = ownerNotificationSystemNotifier
    productLibraryFeature.selectedProductID = selectedProductID
    observeFeatureModels()
    refreshCodexInstallations()
  }

  init(
    storeRegistry: ProductStoreRegistry,
    selectedProductID: UUID? = nil,
    codexTransportFactory: @escaping CodexTransportFactory = makeProductionCodexTransport,
    ownerNotificationSoundPlayer: any OwnerNotificationSoundPlaying =
      BundledOwnerNotificationSoundPlayer(),
    ownerNotificationSystemNotifier: any OwnerNotificationSystemNotifying =
      MacOSOwnerNotificationNotifier(),
    remoteRepositoryFeature: RemoteRepositoryFeatureModel = RemoteRepositoryFeatureModel(
      service: nil
    ),
    repositoryImportActivator: (any RepositoryImportActivating)? = nil
  ) {
    codexInstallationPreferences = CodexInstallationPreferences()
    self.codexTransportFactory = codexTransportFactory
    let gitWorkspaceManager = GitWorkspaceManager()
    self.gitWorkspaceManager = gitWorkspaceManager
    self.storeRegistry = storeRegistry
    self.repositoryImportActivator =
      repositoryImportActivator
      ?? ProductRepositoryImporter(
        registration: storeRegistry,
        gitWorkspaceManager: gitWorkspaceManager,
        stagingRootURL: storeRegistry.productWorkspacesRootURL
          .deletingLastPathComponent()
          .appendingPathComponent("Import Workspaces", isDirectory: true)
      )
    injectedStore = nil
    self.remoteRepositoryFeature = remoteRepositoryFeature
    self.ownerNotificationSoundPlayer = ownerNotificationSoundPlayer
    self.ownerNotificationSystemNotifier = ownerNotificationSystemNotifier
    productLibraryFeature.selectedProductID = selectedProductID
    observeFeatureModels()
    refreshCodexInstallations()
  }

  private func observeFeatureModels() {
    [
      remoteRepositoryFeature.objectWillChange.eraseToAnyPublisher(),
      planningConversationFeature.objectWillChange.eraseToAnyPublisher(),
      epicPlanningFeature.objectWillChange.eraseToAnyPublisher(),
      sprintPlanningFeature.objectWillChange.eraseToAnyPublisher(),
      retrospectiveSynthesisRuntime.objectWillChange.eraseToAnyPublisher(),
      codexConnectionRuntime.objectWillChange.eraseToAnyPublisher(),
      demoSessionFeature.objectWillChange.eraseToAnyPublisher(),
      productLibraryFeature.objectWillChange.eraseToAnyPublisher(),
      ownerNotificationCoordinator.objectWillChange.eraseToAnyPublisher(),
    ]
    .forEach { publisher in
      publisher.sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &featureObservations)
    }
  }

  private func store(for productID: UUID) -> SQLiteStore? {
    injectedStore ?? storeRegistry?.store(for: productID)
  }

  private func fetchProducts(
    status: ProductStatus? = .active
  ) async throws -> [Product] {
    if let storeRegistry {
      return try await storeRegistry.fetchProducts(status: status)
    }
    guard let injectedStore else { return [] }
    return try await injectedStore.fetchProducts(status: status)
  }

  private func fetchProductLists() async throws -> (
    active: [Product], archived: [Product]
  ) {
    let allProducts = try await fetchProducts(status: nil)
    return (
      active: allProducts.filter { $0.status == .active },
      archived: allProducts.filter { $0.status == .archived }
    )
  }

  private func prepareStartupProductDefaults() async throws {
    for product in try await fetchProducts() {
      guard let store = store(for: product.id) else { continue }
      _ = try await store.seedDefaultProfiles(productID: product.id)
      if try await store.fetchProductRepository(productID: product.id) == nil {
        _ = try await store.seedKnowledgeBase(productID: product.id)
      }
    }
  }

  private func fetchTicketAttentions(
    product: Product,
    store: SQLiteStore
  ) async throws -> [TicketAttention] {
    let workItems = try await store.fetchWorkItems(productID: product.id)
    let permissionRequests = try await store.fetchAgentPermissionRequests(productID: product.id)
    let runs = try await store.fetchAgentRuns(productID: product.id)
    let latestRunsByWorkItemID = runs.reduce(
      into: [UUID: AgentRun]()
    ) { latestRuns, run in
      if let current = latestRuns[run.workItemID], current.updatedAt >= run.updatedAt {
        return
      }
      latestRuns[run.workItemID] = run
    }
    let latestAwaitingRunsByWorkItemID =
      runs
      .filter { $0.status == .awaitingOwner }
      .reduce(into: [UUID: AgentRun]()) { latestRuns, run in
        if let current = latestRuns[run.workItemID], current.updatedAt >= run.updatedAt {
          return
        }
        latestRuns[run.workItemID] = run
      }
    let commentsByWorkItemID = try await store.fetchComments(
      workItemIDs: Set(latestAwaitingRunsByWorkItemID.keys)
    )

    var attentions: [TicketAttention] = []
    for item in workItems {
      if let run = latestAwaitingRunsByWorkItemID[item.id] {
        let latestPermissionRequest =
          permissionRequests
          .filter {
            $0.agentRunID == run.id && $0.status.needsOwnerDecision
          }
          .max { $0.updatedAt < $1.updatedAt }
        let latestQuestion =
          commentsByWorkItemID[item.id, default: []]
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
      } else if item.state == .acceptance {
        attentions.append(
          TicketAttention(
            id: item.id,
            productID: product.id,
            productName: product.name,
            sprintID: latestRunsByWorkItemID[item.id]?.sprintID,
            workItemID: item.id,
            itemKey: item.key,
            title: item.title,
            summary: "Ready for demo",
            updatedAt: item.updatedAt
          )
        )
      }
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
    try await ticketDeliveryWorkflowCoordinator.updateAgentRun(
      id: id,
      status: status,
      codexThreadID: codexThreadID,
      worktreePath: worktreePath,
      eventActor: eventActor,
      eventDetail: eventDetail
    )
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

  var presentedOwnerNotification: OwnerNotificationPresentation? {
    ownerNotificationCoordinator.presentedNotification
  }

  var ownerNotificationsByProductID: [UUID: [OwnerNotification]] {
    ownerNotificationCoordinator.notificationsByProductID
  }

  func ownerNotificationKind(
    productID: UUID,
    target: OwnerNotificationTarget
  ) -> OwnerNotificationKind? {
    ownerNotificationCoordinator.activeKind(
      productID: productID,
      target: target
    )
  }

  func hasUnreadOwnerNotification(
    productID: UUID,
    target: OwnerNotificationTarget
  ) -> Bool {
    ownerNotificationCoordinator.hasUnread(productID: productID, target: target)
  }

  func backlogOwnerNotificationCount(productID: UUID) -> Int {
    ownerNotificationCoordinator.activeTargetCount(
      productID: productID,
      targetKinds: [.ticket, .epic]
    )
  }

  func unreadChatThreadCount(productID: UUID) -> Int {
    ownerNotificationCoordinator.unreadTargetCount(
      productID: productID,
      targetKinds: [.conversationThread]
    )
  }
  func ownerAttentionCount(for productID: UUID) -> Int {
    ownerAttentionTargets(productID: productID).count
  }

  func ownerAttentionCount(excluding excludedProductID: UUID?) -> Int {
    products.lazy
      .filter { $0.id != excludedProductID }
      .reduce(into: 0) { count, product in
        count += ownerAttentionCount(for: product.id)
      }
  }

  func ownerAttentionRequiresAction(productID: UUID) -> Bool {
    !ticketAttentionsByProductID[productID, default: []].isEmpty
      || ownerNotificationsByProductID[productID, default: []].contains {
        $0.kind.requiresAction && $0.resolvedAt == nil
      }
  }

  private func ownerAttentionTargets(productID: UUID) -> Set<OwnerNotificationTarget> {
    var targets = Set(
      ticketAttentionsByProductID[productID, default: []].map {
        OwnerNotificationTarget(kind: .ticket, id: $0.workItemID)
      }
    )
    targets.formUnion(
      ownerNotificationsByProductID[productID, default: []].map(\.target)
    )
    return targets
  }

  func dismissPresentedOwnerNotification(id: UUID) {
    ownerNotificationCoordinator.dismissPresented(id: id)
  }

  func setOwnerNotificationTargetVisible(
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    await ownerNotificationCoordinator.setVisible(
      productID: productID,
      target: target
    )
  }

  func clearOwnerNotificationTargetVisible(
    productID: UUID,
    target: OwnerNotificationTarget
  ) {
    ownerNotificationCoordinator.clearVisible(
      productID: productID,
      target: target
    )
  }

  func resolveOwnerNotifications(
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    await ownerNotificationCoordinator.resolve(
      productID: productID,
      target: target
    )
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
    ownerNotificationCoordinator.dismissPresented(id: attention.id)
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
    if let presentedOwnerNotification,
      attentions.contains(where: { $0.id == presentedOwnerNotification.id })
    {
      ownerNotificationCoordinator.dismissPresented(id: presentedOwnerNotification.id)
    }
    ticketAttentionNavigationRequest = TicketAttentionNavigationRequest(
      productID: product.id,
      sprintID: attentions.first?.sprintID,
      workItemIDs: Set(attentions.map(\.workItemID)),
      openWorkItemID: attentions.count == 1 ? attentions[0].workItemID : nil
    )
  }

  func openOwnerAttentions(for product: Product) async {
    let targets = ownerAttentionTargets(productID: product.id)
    guard !targets.isEmpty else {
      await selectProduct(product)
      return
    }
    if targets.count == 1, let target = targets.first {
      if let notification = ownerNotificationsByProductID[product.id]?
        .first(where: { $0.target == target })
      {
        await openOwnerNotification(
          notificationID: notification.id,
          productID: product.id,
          target: target
        )
        return
      }
      if target.kind == .ticket,
        let attention = ticketAttentionsByProductID[product.id]?
          .first(where: { $0.workItemID == target.id })
      {
        await openTicketAttention(attention)
        return
      }
    }
    if ownerNotificationsByProductID[product.id, default: []].isEmpty {
      await openTicketAttentions(for: product)
    } else if selectedProductID != product.id {
      await selectProduct(product)
    } else {
      await reloadSelectedProduct()
    }
  }

  func consumeTicketAttentionNavigationRequest(id: UUID) {
    guard ticketAttentionNavigationRequest?.id == id else { return }
    ticketAttentionNavigationRequest = nil
  }

  func openOwnerNotification(_ presentation: OwnerNotificationPresentation) async {
    await openOwnerNotification(
      notificationID: presentation.id,
      productID: presentation.productID,
      target: presentation.target
    )
  }

  func openOwnerNotification(_ route: OwnerNotificationRoute) async {
    await openOwnerNotification(
      notificationID: route.notificationID,
      productID: route.productID,
      target: route.target
    )
  }

  private func openOwnerNotification(
    notificationID: UUID?,
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    if let notificationID {
      let matchesOwnerNotification =
        ownerNotificationsByProductID[productID]?.contains(where: {
          $0.id == notificationID && $0.target == target
        }) == true
      let matchesTicketAttention =
        target.kind == .ticket
        && ticketAttentionsByProductID[productID]?.contains(where: {
          $0.id == notificationID && $0.workItemID == target.id
        }) == true
      guard matchesOwnerNotification || matchesTicketAttention else { return }
    }
    guard let product = products.first(where: { $0.id == productID }) else {
      return
    }
    if selectedProductID != productID {
      await selectProduct(product)
    } else {
      await reloadSelectedProduct()
    }
    guard ownerNotificationTargetExists(target) else {
      await ownerNotificationCoordinator.markRead(
        productID: productID,
        target: target
      )
      await ownerNotificationCoordinator.resolve(
        productID: productID,
        target: target
      )
      return
    }
    await ownerNotificationCoordinator.markRead(productID: productID, target: target)
    if let notificationID {
      ownerNotificationCoordinator.dismissPresented(id: notificationID)
    }
    ownerNotificationNavigationRequest = OwnerNotificationNavigationRequest(
      notificationID: notificationID,
      productID: productID,
      target: target
    )
  }

  private func ownerNotificationTargetExists(
    _ target: OwnerNotificationTarget
  ) -> Bool {
    switch target.kind {
    case .ticket:
      workItems.contains { $0.id == target.id && $0.state != .cancelled }
    case .epic:
      epics.contains { $0.id == target.id && $0.status != .archived }
    case .conversationThread:
      productConversationFeature.threads.contains {
        $0.id == target.id && !$0.isArchived
      }
    }
  }

  func consumeOwnerNotificationNavigationRequest(id: UUID) {
    guard ownerNotificationNavigationRequest?.id == id else { return }
    ownerNotificationNavigationRequest = nil
  }

  private func retireOwnerNotifications(
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    await ownerNotificationCoordinator.markRead(
      productID: productID,
      target: target
    )
    await ownerNotificationCoordinator.resolve(
      productID: productID,
      target: target
    )
  }

  private func publishOwnerNotification(_ notification: OwnerNotification) async {
    guard
      let product = products.first(where: { $0.id == notification.productID })
    else { return }
    _ = await ownerNotificationCoordinator.publish(
      notification,
      productName: product.name
    )
  }

  private func publishConversationReply(
    thread: ProductConversationThread,
    message: ProductConversationMessage
  ) async {
    await publishOwnerNotification(
      OwnerNotification(
        id: message.id,
        productID: thread.productID,
        kind: .newReply,
        target: OwnerNotificationTarget(
          kind: .conversationThread,
          id: thread.id
        ),
        title: "\(message.authorName) replied in Chat",
        body: message.body,
        createdAt: message.createdAt
      )
    )
  }

  var appVersions: [AppVersion] {
    AppVersionPolicy.all(imported: importedAppLaunch, acceptedCandidates: candidateRevisions)
  }

  var selectedCodexInstallation: CodexInstallation? {
    codexInstallations.first { $0.id == selectedCodexInstallationID }
  }

  var canChangeCodexInstallation: Bool {
    !isShuttingDown
      && !repositoryKnowledgeCoordinator.hasActiveOperations
      && !epicPlanningWorkflowCoordinator.isBusy
      && !retrospectiveSynthesisRuntime.isBusy
      && !ticketDeliveryRuntimeCoordinator.isBusy
      && !productConversationFeature.isBusy
      && !sprintPlanningWorkflowCoordinator.isBusy
      && !planningConversationWorkflowCoordinator.isBusy
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
    let isCodexConnected =
      if case .connected = codexConnectionState { true } else { false }
    return sprintPlanningWorkflowCoordinator.canGenerateSprintGoal(
      isCodexConnected: isCodexConnected
    )
  }

  var pendingSuggestionCount: Int {
    guard
      suggestionBatch?.session.epicID != nil
        || suggestionBatch?.session.sourceWorkItemID != nil
    else { return 0 }
    return suggestionBatch?.suggestions.filter { $0.status == .proposed }.count ?? 0
  }

  func connectGitHub(productID: UUID) async {
    await remoteRepositoryFeature.connect(
      productID: productID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func cancelGitHubConnection(productID: UUID) async {
    await remoteRepositoryFeature.cancelConnection(
      productID: productID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func disconnectGitHub(productID: UUID) async {
    await remoteRepositoryFeature.disconnect(
      productID: productID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func signOutGitHub(accountID: UUID, productID: UUID) async {
    await remoteRepositoryFeature.signOut(
      accountID: accountID,
      productID: productID,
      isProductActive: isActiveProduct(productID),
      allProductIDs: (products + archivedProducts).map(\.id)
    )
  }

  @discardableResult
  func sendRepositoryImportCommand(
    _ command: RepositoryImportCommand
  ) async -> RepositoryImportCompletion? {
    guard !isShuttingDown else { return nil }
    guard let repositoryImportCoordinator else {
      repositoryImportSnapshot = RepositoryImportSnapshot(
        phase: .failed(
          RepositoryImportFailure(
            message: "Repository import is unavailable.",
            retry: command
          )
        )
      )
      return nil
    }
    return await repositoryImportCoordinator.send(command)
  }

  func cancelRepositoryImport() async {
    await repositoryImportCoordinator?.cancel()
  }

  func selectLocalGitHubRepository(productID: UUID, repositoryID: Int64) async {
    let currentState = remoteRepositorySnapshot(for: productID).repositoryState
    let optimisticState: GitHubRemoteRepositoryState?
    if let choice = currentState.repositories.first(where: { $0.id == repositoryID }),
      var connection = currentState.connection
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
      optimisticState = GitHubRemoteRepositoryState(
        isConfigured: currentState.isConfigured,
        connection: connection,
        repositories: currentState.repositories,
        selectedEligibility: .checking,
        observation: currentState.observation,
        safeSync: currentState.safeSync,
        publications: currentState.publications
      )
    } else {
      optimisticState = nil
    }
    await remoteRepositoryFeature.selectLocalRepository(
      productID: productID,
      repositoryID: repositoryID,
      optimisticState: optimisticState,
      isProductActive: isActiveProduct(productID)
    )
  }

  func refreshGitHubRepositories(productID: UUID) async {
    await remoteRepositoryFeature.refreshRepositories(
      productID: productID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func resumeLocalGitHubRepositorySetup(productID: UUID) async {
    let initialState = remoteRepositorySnapshot(for: productID).repositoryState
    guard initialState.connection?.status == .selectingRepository,
      let repositoryID = initialState.connection?.repositoryID
    else { return }
    if !initialState.repositories.contains(where: { $0.id == repositoryID }) {
      await refreshGitHubRepositories(productID: productID)
    }
    let currentState = remoteRepositorySnapshot(for: productID).repositoryState
    guard
      currentState.repositories.contains(where: { $0.id == repositoryID }),
      currentState.selectedEligibility == nil
        || currentState.selectedEligibility == .unchecked
    else { return }
    await selectLocalGitHubRepository(productID: productID, repositoryID: repositoryID)
  }

  func initializeLocalGitHubRepository(productID: UUID) async {
    let publishesExistingHistory =
      if case .empty(_, let existingHistory) =
        remoteRepositorySnapshot(for: productID).repositoryState.selectedEligibility
      {
        existingHistory != nil
      } else {
        false
      }
    await remoteRepositoryFeature.initializeLocalRepository(
      productID: productID,
      publishesExistingHistory: publishesExistingHistory,
      isProductActive: isActiveProduct(productID)
    )
  }

  func confirmRemoteRepositoryTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) async {
    await remoteRepositoryFeature.confirmTarget(
      productID: productID,
      expectedVersion: expectedVersion,
      pendingObservedAt: pendingObservedAt,
      isProductActive: isActiveProduct(productID)
    )
  }

  func checkRemoteRepository(productID: UUID) async {
    await remoteRepositoryFeature.check(
      productID: productID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func prepareIncomingRepositoryChange(productID: UUID) async {
    guard !(await productHasActiveDelivery(productID: productID)) else {
      setRemoteRepositoryFailure(
        productID: productID,
        message:
          "Incoming GitHub changes cannot be reviewed while delivery work is active. Finish or stop the current sprint, then check GitHub again."
      )
      return
    }
    await remoteRepositoryFeature.prepareSafeSync(
      productID: productID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func acceptIncomingRepositoryChange(productID: UUID, syncID: UUID) async {
    guard !(await productHasActiveDelivery(productID: productID)) else {
      setRemoteRepositoryFailure(
        productID: productID,
        message:
          "Incoming GitHub changes cannot be accepted while delivery work is active. Finish or stop the current sprint, then check GitHub again."
      )
      return
    }
    await remoteRepositoryFeature.acceptSafeSync(
      productID: productID,
      syncID: syncID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func rejectIncomingRepositoryChange(productID: UUID, syncID: UUID) async {
    await remoteRepositoryFeature.rejectSafeSync(
      productID: productID,
      syncID: syncID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func refreshRemotePullRequest(productID: UUID, publicationID: UUID) async {
    await remoteRepositoryFeature.refreshPullRequest(
      productID: productID,
      publicationID: publicationID,
      isProductActive: isActiveProduct(productID)
    )
  }

  func syncTicketPullRequest(
    productID: UUID,
    publicationID: UUID,
    showsProgress: Bool = true
  ) async {
    guard
      let result = await remoteRepositoryFeature.syncTicketPullRequest(
        productID: productID,
        publicationID: publicationID,
        showsProgress: showsProgress
      )
    else { return }
    await handleGitHubPullRequestSync(result, productID: productID)
  }

  func setGitHubReviewTicket(_ workItemID: UUID, isVisible: Bool) {
    remoteRepositoryFeature.setReviewTicket(workItemID, isVisible: isVisible)
  }

  private func prepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication? {
    guard
      let publication = try await remoteRepositoryFeature.prepareTicketPullRequestIfConnected(
        productID: productID,
        workItemID: workItemID,
        candidateRevisionID: candidateRevisionID
      )
    else { return nil }
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
    try await remoteRepositoryFeature.markTicketPullRequestReadyIfNeeded(publication)
  }

  func clearGitHubRemoteRepositoryError(productID: UUID) {
    remoteRepositoryFeature.setFailure(nil, productID: productID)
  }

  private func productHasActiveDelivery(productID: UUID) async -> Bool {
    guard let productStore = store(for: productID) else { return true }
    do {
      return try await productStore.fetchCurrentSprint(productID: productID)?
        .sprint.state.isInProgress == true
    } catch {
      remoteRepositoryFeature.setFailure(
        RemoteRepositoryFeatureFailure(
          kind: .activeDeliveryCheck,
          message: "Spedito could not verify whether delivery work is active. Try again."
        ),
        productID: productID
      )
      return true
    }
  }

  private func isActiveProduct(_ productID: UUID) -> Bool {
    products.contains { $0.id == productID && $0.status == .active }
  }

  private func setRemoteRepositoryFailure(productID: UUID, message: String) {
    remoteRepositoryFeature.setFailure(
      RemoteRepositoryFeatureFailure(kind: .operation, message: message),
      productID: productID
    )
  }

  private func scheduleGitHubRemoteRecovery(productIDs: [UUID]) {
    remoteRepositoryFeature.scheduleRecovery(productIDs: productIDs)
  }

  func setApplicationActive(_ isActive: Bool) async {
    remoteRepositoryFeature.setApplicationActive(isActive)
    await ownerNotificationCoordinator.setApplicationActive(isActive)
  }

  private func scheduleGitHubPullRequestPolling() {
    remoteRepositoryFeature.schedulePullRequestPolling(
      productID: selectedProductID,
      workItems: { [weak self] in self?.workItems ?? [] },
      isSelected: { [weak self] productID in self?.selectedProductID == productID },
      onSync: { [weak self] result in
        guard let self, let productID = self.selectedProductID else { return }
        await self.handleGitHubPullRequestSync(result, productID: productID)
      }
    )
  }

  func pollGitHubPullRequestsOnce(productID: UUID) async {
    await remoteRepositoryFeature.pollPullRequestsOnce(
      productID: productID,
      workItems: workItems,
      isSelected: { [weak self] productID in self?.selectedProductID == productID },
      onSync: { [weak self] result in
        await self?.handleGitHubPullRequestSync(result, productID: productID)
      }
    )
  }

  private func handleGitHubPullRequestSync(
    _ result: GitHubTicketPullRequestSync,
    productID: UUID
  ) async {
    guard result.changesRequested else { return }
    await ticketDeliveryWorkflowCoordinator.handleSprintOwnerComment(
      productID: productID,
      workItemID: result.workItemID,
      body: "Address the latest GitHub review feedback.",
      actor: "GitHub reviewer",
      reasonPrefix: "Review feedback"
    )
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
      #if DEBUG
        if let storeRegistry,
          let fixtureProductID = try await UIFixtureRuntime.prepare(registry: storeRegistry)
        {
          selectedProductID = fixtureProductID
        }
      #endif
      try repositoryImportActivator?.prepare()
      try await prepareStartupProductDefaults()
      let stores = storeRegistry?.allStores ?? injectedStore.map { [$0] } ?? []
      try repositoryKnowledgeCoordinator.cleanupAbandonedSnapshots()
      for productStore in stores {
        try await interruptPendingPermissionRequestsForStartup(in: productStore)
        try await productStore.interruptWorkingConversationThreads()
        try await productStore.requeueGeneratingRetrospectiveSyntheses()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
    await ticketDeliveryWorkflowCoordinator.recoverInterruptedTicketAcceptances(
      productIDs: products.map(\.id)
    )
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
    await repositoryKnowledgeCoordinator.send(.schedule(productIDs: products.map(\.id)))
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
        guard
          let completion = await sendRepositoryImportCommand(
            .importPublic(name: trimmedName, source: source)
          )
        else {
          productCreationError = repositoryImportSnapshot.failure?.message
          return false
        }
        product = completion.product
        applyRepositoryImportCompletion(completion)
      case .importGitHubRepository(_, let repositoryID):
        guard
          let completion = await sendRepositoryImportCommand(
            .importAuthorized(name: trimmedName, repositoryID: repositoryID)
          )
        else {
          productCreationError = repositoryImportSnapshot.failure?.message
          return false
        }
        product = completion.product
        applyRepositoryImportCompletion(completion)
      }
      let productLists = try await fetchProductLists()
      products = productLists.active
      archivedProducts = productLists.archived
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      await ownerNotificationCoordinator.load(products: products)
      selectedProductID = product.id
      repositoryKnowledgeSnapshot = repositoryKnowledgeCoordinator.snapshot(for: product.id)
      productRepository = repositoryKnowledgeSnapshot?.repository
      importedAppLaunch = nil
      rememberSelectedProduct(product.id)
      await reloadSelectedProduct()
      scheduleGitHubPullRequestPolling()
      await repositoryKnowledgeCoordinator.send(.schedule(productIDs: [product.id]))
      return true
    } catch is CancellationError {
      return false
    } catch {
      productCreationError = error.localizedDescription
      return false
    }
  }

  private func applyRepositoryImportCompletion(
    _ completion: RepositoryImportCompletion
  ) {
    if case .emptyRepository(let remoteState) = completion.provenance,
      let remoteState
    {
      remoteRepositoryFeature.record(remoteState, productID: completion.product.id)
    }
    if let warning = completion.ownerFacingWarning {
      setRemoteRepositoryFailure(productID: completion.product.id, message: warning)
      errorMessage = warning
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
    if let departingProductID = selectedProductID {
      await settleFeatureRuntimes(
        productID: departingProductID,
        preservingOwnerAgentTurns: true
      )
    }
    if let departingProductID = selectedProductID {
      await refreshTicketAttentions(productID: departingProductID)
    }
    selectedProductID = product.id
    repositoryKnowledgeSnapshot = repositoryKnowledgeCoordinator.snapshot(for: product.id)
    productRepository = repositoryKnowledgeSnapshot?.repository
    importedAppLaunch = nil
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

    let acceptingWorkItemIDs =
      ticketDeliveryRuntimeCoordinator.acceptanceWorkItemIDs(productID: product.id)
    guard acceptingWorkItemIDs.isEmpty else {
      errorMessage =
        "A ticket is currently being completed. Wait for it to reach a recoverable result before archiving this Product."
      return false
    }
    guard !remoteRepositoryFeature.hasActiveOperation(productID: product.id) else {
      errorMessage =
        "GitHub repository work is currently active. Wait for it to finish before archiving this Product."
      return false
    }
    if let remoteState = await remoteRepositoryFeature.state(productID: product.id) {
      if let reason = remoteProductArchivePolicy.blockingReason(for: remoteState) {
        errorMessage = reason
        return false
      }
      guard
        let settledState = await remoteRepositoryFeature.settleForArchival(productID: product.id)
      else {
        errorMessage = "Spedito could not safely pause GitHub repository work. Try again."
        return false
      }
      if let reason = remoteProductArchivePolicy.blockingReason(for: settledState) {
        errorMessage = reason
        scheduleGitHubPullRequestPolling()
        return false
      }
    }

    await stopDemoSessions(productID: product.id, includesPreparation: true)
    await repositoryKnowledgeCoordinator.send(.cancel(productID: product.id))
    await applyExecutionLifecycle(.productArchived(product.id))
    await settleFeatureRuntimes(productID: product.id)
    await productConversationFeature.settle(productID: product.id)

    do {
      _ = try await store.archiveProduct(id: product.id)
      let productLists = try await fetchProductLists()
      products = productLists.active
      archivedProducts = productLists.archived
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      await ownerNotificationCoordinator.load(products: products)
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
      guard let restoredStore = store(for: product.id) else {
        throw PersistenceError.recordNotFound("restored product store \(product.id)")
      }
      _ = try await restoredStore.seedDefaultProfiles(productID: product.id)
      if try await restoredStore.fetchProductRepository(productID: product.id) == nil {
        _ = try await restoredStore.seedKnowledgeBase(productID: product.id)
      }
      let productLists = try await fetchProductLists()
      products = productLists.active
      archivedProducts = productLists.archived
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      await ownerNotificationCoordinator.load(products: products)
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
    transientOwnerCommandRuntime.start(productID: productID) { [self] in
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
    transientOwnerCommandRuntime.start(productID: epic.productID) { [self] in
      do {
        try await store.archiveEpic(id: epic.id)
        await retireOwnerNotifications(
          productID: epic.productID,
          target: OwnerNotificationTarget(kind: .epic, id: epic.id)
        )
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
    try await planningConversationWorkflowCoordinator.refineTicket(item)
  }

  @discardableResult
  func applyCompletedTicketRefinement(
    _ proposal: TicketRefinementProposal,
    to item: WorkItem
  ) async throws -> WorkItem {
    try await planningConversationWorkflowCoordinator.applyCompletedTicketRefinement(
      proposal,
      to: item
    )
  }

  func cancelTicketRefinement() {
    planningConversationWorkflowCoordinator.cancelTicketRefinement()
  }

  func sendTicketConversationMessage(
    for item: WorkItem,
    to recipient: AgentProfile,
    ownerMessage: String,
    allowsProposal: Bool = true
  ) async throws -> TicketConversationReply {
    try await planningConversationWorkflowCoordinator.sendTicketConversationMessage(
      for: item,
      to: recipient,
      ownerMessage: ownerMessage,
      allowsProposal: allowsProposal
    )
  }

  func cancelTicketConversationMessage() {
    planningConversationWorkflowCoordinator.cancelTicketConversationMessage()
  }

  func sendEpicConversationMessage(
    for epic: Epic,
    to recipient: AgentProfile,
    ownerMessage: String
  ) async throws -> EpicConversationReply {
    try await planningConversationWorkflowCoordinator.sendEpicConversationMessage(
      for: epic,
      to: recipient,
      ownerMessage: ownerMessage
    )
  }

  func cancelEpicConversationMessage() {
    planningConversationWorkflowCoordinator.cancelEpicConversationMessage()
  }

  func dismissTicketAssistantResult(workItemID: UUID) {
    planningConversationWorkflowCoordinator.dismissTicketAssistantResult(
      workItemID: workItemID
    )
  }


  func transition(_ workItem: WorkItem, to state: WorkItemState) {
    guard let store = store(for: workItem.productID) else { return }
    transientOwnerCommandRuntime.start(productID: workItem.productID) { [self] in
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
    transientOwnerCommandRuntime.start(productID: productID) { [self] in
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
    transientOwnerCommandRuntime.start(productID: productID) { [self] in
      do {
        try await store.archiveWorkItems(ids: Array(selectedIDs))
        for workItemID in selectedIDs {
          await retireOwnerNotifications(
            productID: productID,
            target: OwnerNotificationTarget(kind: .ticket, id: workItemID)
          )
        }
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
    await productConversationFeature.sendMessage(
      threadID: threadID,
      recipientID: recipientID,
      body: body
    )
  }

  func cancelProductConversation(threadID: UUID) {
    productConversationFeature.cancel(threadID: threadID)
  }

  @discardableResult
  func archiveProductConversation(threadID: UUID) async -> Bool {
    guard
      let thread = productConversationFeature.threads.first(where: { $0.id == threadID }),
      await productConversationFeature.archive(threadID: threadID)
    else { return false }
    await retireOwnerNotifications(
      productID: thread.productID,
      target: OwnerNotificationTarget(kind: .conversationThread, id: threadID)
    )
    return true
  }

  @discardableResult
  func restoreProductConversation(threadID: UUID) async -> Bool {
    await productConversationFeature.restore(threadID: threadID)
  }


  func loadProductConversationMessages(threadID: UUID) async {
    await productConversationFeature.loadMessages(threadID: threadID)
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
      if !answeredQuestions.isEmpty,
        let notificationProductID = productID ?? selectedProductID
      {
        await ownerNotificationCoordinator.resolve(
          productID: notificationProductID,
          target: OwnerNotificationTarget(kind: .ticket, id: workItemID)
        )
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
    await ticketDeliveryWorkflowCoordinator.stopAgentRun(run)
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
    await ticketDeliveryWorkflowCoordinator.handleSprintOwnerComment(
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
    guard let productID = workItems.first(where: { $0.id == workItemID })?.productID else {
      return false
    }
    return await ticketDeliveryWorkflowCoordinator.retryFailedPostReviewDemo(
      productID: productID,
      workItemID: workItemID
    )
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
    ticketDeliveryWorkflowCoordinator.beginSprintTicketAcceptance(item)
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
    try await sprintPlanningWorkflowCoordinator.sendSprintPlanningMessage(
      for: item,
      to: recipient,
      ownerMessage: ownerMessage,
      ticketSnapshot: ticketSnapshot,
      proposedAssignee: proposedAssignee
    )
  }

  func cancelSprintPlanningMessage() {
    sprintPlanningWorkflowCoordinator.cancelSprintPlanningMessage()
  }

  func generateAndSaveSprintGoal(for sprintID: UUID, planVersion: Int) async throws -> String {
    try await sprintPlanningWorkflowCoordinator.generateAndSaveSprintGoal(
      for: sprintID,
      planVersion: planVersion
    )
  }

  func addToCandidateSprint(_ workItem: WorkItem) {
    sprintPlanningWorkflowCoordinator.addToCandidateSprint([workItem])
  }

  func addToCandidateSprint(_ selectedItems: [WorkItem]) {
    sprintPlanningWorkflowCoordinator.addToCandidateSprint(selectedItems)
  }

  func removeFromCandidateSprint(_ workItem: WorkItem) {
    sprintPlanningWorkflowCoordinator.removeFromCandidateSprint([workItem])
  }

  func removeFromCandidateSprint(_ selectedItems: [WorkItem]) {
    sprintPlanningWorkflowCoordinator.removeFromCandidateSprint(selectedItems)
  }

  func dropPlanningItems(
    _ selectedItems: [WorkItem],
    intoCandidateSprint: Bool,
    before targetID: UUID?
  ) {
    sprintPlanningWorkflowCoordinator.dropPlanningItems(
      selectedItems,
      intoCandidateSprint: intoCandidateSprint,
      before: targetID
    )
  }

  func planningDropEvaluation(
    ids: Set<UUID>,
    intoCandidateSprint: Bool,
    before targetID: UUID?
  ) -> PlanningDropEvaluation {
    sprintPlanningWorkflowCoordinator.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: intoCandidateSprint,
      before: targetID
    )
  }

  var canEditCandidateSprint: Bool {
    sprintPlanningWorkflowCoordinator.canEditCandidateSprint
  }

  func restoreEpicPlanningConversation(for epic: Epic) async {
    await epicPlanningWorkflowCoordinator.restoreEpicPlanningConversation(for: epic)
  }

  func planEpic(_ epic: Epic) {
    epicPlanningWorkflowCoordinator.planEpic(epic)
  }

  func continueEpicPlanning(
    _ epic: Epic,
    answers: [String],
    answeredQuestions: [EpicPlanningAnsweredQuestion]
  ) {
    epicPlanningWorkflowCoordinator.continueEpicPlanning(
      epic,
      answers: answers,
      answeredQuestions: answeredQuestions
    )
  }

  func retryEpicPlanning(_ epic: Epic) {
    epicPlanningWorkflowCoordinator.retryEpicPlanning(epic)
  }

  func cancelEpicPlanning() {
    epicPlanningWorkflowCoordinator.cancelEpicPlanning()
  }

  func clearEpicPlanningConversation(for epicID: UUID) {
    epicPlanningWorkflowCoordinator.clearEpicPlanningConversation(for: epicID)
  }

  func saveEpicPlanningConversation(
    _ conversation: EpicPlanningConversationState,
    threadID: String?
  ) async throws {
    try await epicPlanningWorkflowCoordinator.saveEpicPlanningConversation(
      conversation,
      threadID: threadID
    )
  }

  func retryCurrentEpicPlan() {
    epicPlanningWorkflowCoordinator.retryCurrentEpicPlan()
  }

  func autosuggestTickets() {
    epicPlanningWorkflowCoordinator.autosuggestTickets()
  }

  func decideTicketSuggestion(
    _ suggestion: TicketSuggestion,
    accept: Bool,
    completion: ((WorkItem?) -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.decideTicketSuggestion(
      suggestion,
      accept: accept,
      completion: completion
    )
  }

  func rejectTicketSuggestion(
    _ suggestion: TicketSuggestion,
    completion: (() -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.rejectTicketSuggestion(
      suggestion,
      completion: completion
    )
  }

  func decideAllTicketSuggestions(accept: Bool) {
    epicPlanningWorkflowCoordinator.decideAllTicketSuggestions(accept: accept)
  }

  func decideTicketSuggestionGroup(_ suggestions: [TicketSuggestion], accept: Bool) {
    epicPlanningWorkflowCoordinator.decideTicketSuggestionGroup(
      suggestions,
      accept: accept
    )
  }

  func dismissFailedTicketSuggestions() {
    epicPlanningWorkflowCoordinator.dismissFailedTicketSuggestions()
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

    transientOwnerCommandRuntime.start(productID: profile.productID) { [self] in
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
    transientOwnerCommandRuntime.start(productID: productID) { [self] in
      do {
        let updatedProduct = try await store.updateProductInstructions(
          productID: productID,
          instructions: instructions
        )
        replaceProductSnapshot(updatedProduct)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func updateProductDetails(name: String) {
    guard let store, let productID = selectedProductID else { return }
    transientOwnerCommandRuntime.start(productID: productID) { [self] in
      do {
        let updatedProduct = try await store.updateProductDetails(
          productID: productID,
          name: name
        )
        replaceProductSnapshot(updatedProduct)
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
      replaceProductSnapshot(snapshot.product)
      if selectedProductID == productID {
        profiles = snapshot.profiles
      }
      return .success(snapshot)
    } catch {
      return .failure(.saveFailed(error.localizedDescription))
    }
  }

  private func replaceProductSnapshot(_ product: Product) {
    if let index = products.firstIndex(where: { $0.id == product.id }) {
      products[index] = product
    }
    if let index = archivedProducts.firstIndex(where: { $0.id == product.id }) {
      archivedProducts[index] = product
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
    transientOwnerCommandRuntime.start(productID: productID) { [self] in
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
    transientOwnerCommandRuntime.start(productID: profile.productID) { [self] in
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
    await sprintPlanningWorkflowCoordinator.saveSprintPlan(
      goal: goal,
      items: items
    )
  }

  func reassignDraftTicket(
    productID: UUID,
    workItemID: UUID,
    to profileID: UUID?
  ) async -> Bool {
    await sprintPlanningWorkflowCoordinator.reassignDraftTicket(
      productID: productID,
      workItemID: workItemID,
      to: profileID
    )
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
    await sprintPlanningWorkflowCoordinator.startSprint()
  }

  func pauseSprint(_ sprint: Sprint) async -> Bool {
    await ticketDeliveryWorkflowCoordinator.pauseSprint(sprint)
  }

  func resumeSprint(_ sprint: Sprint) async -> Bool {
    await ticketDeliveryWorkflowCoordinator.resumeSprint(sprint)
  }

  func stopSprint(_ sprint: Sprint) async -> Bool {
    await ticketDeliveryWorkflowCoordinator.stopSprint(sprint)
  }

  private func recoverDeliveryExecution(productID: UUID) async {
    await ticketDeliveryWorkflowCoordinator.recoverDelivery(productID: productID)
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
    ticketDeliveryRuntimeCoordinator.schedule(productID: productID)
  }

  private func drainSprintQueueIteration(
    productID: UUID
  ) async -> TicketDeliverySchedulerDisposition {
    guard
      let context = await ticketDeliveryWorkflowCoordinator.context(productID: productID)
    else {
      return .finished
    }

    let eligibleRuns = eligibleImplementationRuns(in: context)
    for run in eligibleRuns {
      ticketDeliveryRuntimeCoordinator.startImplementation(
        runID: run.id,
        productID: productID
      ) { [weak self] in
        guard let self else { return }
        await self.ticketDeliveryWorkflowCoordinator.executeImplementationRun(
          run,
          context: context
        )
      }
    }

    let startedIntegration = await ticketDeliveryWorkflowCoordinator.processIntegrationCandidates(
      context: context
    )
    let hasActiveImplementation =
      ticketDeliveryRuntimeCoordinator.hasActiveImplementation(productID: productID)
    let hasActiveIntegration =
      ticketDeliveryRuntimeCoordinator.hasActiveIntegration(productID: productID)
    if !hasActiveImplementation,
      !hasActiveIntegration,
      eligibleRuns.isEmpty,
      !startedIntegration
    {
      return .finished
    }
    return startedIntegration ? .continueImmediately : .waitForWake
  }

  private func reloadSelectedProductIfCurrent(productID: UUID) async {
    guard selectedProductID == productID else {
      await refreshTicketAttentions(productID: productID)
      return
    }
    await reloadSelectedProduct()
  }

  private func reloadSprintPlanningActivity(productID: UUID) async throws {
    guard
      selectedProductID == productID,
      let store = store(for: productID)
    else { return }
    activity = try await store.fetchActivity(productID: productID, limit: 100)
  }

  func settleOwnerCommands() async {
    await transientOwnerCommandRuntime.settle()
    await sprintPlanningWorkflowCoordinator.settleMutations()
  }

  private func presentExecutionError(_ error: Error, productID: UUID) {
    guard selectedProductID == productID else { return }
    errorMessage = error.localizedDescription
  }

  private func eligibleImplementationRuns(
    in context: TicketDeliveryWorkflowContext
  ) -> [AgentRun] {
    SprintRunAdmission.eligibleImplementationRuns(
      plan: context.plan,
      runs: context.runs,
      workItems: context.workItems,
      dependencies: context.dependencies
    )
  }

  private func integrateLatestGitHubChanges(
    candidate: CandidateRevision,
    integration: GitIntegrationSnapshot
  ) async throws -> (
    snapshot: GitIntegrationSnapshot,
    incorporatedChanges: Bool,
    remoteSHA: String?
  ) {
    guard
      let current = await remoteRepositoryFeature.state(productID: candidate.productID),
      let connection = current.connection
    else {
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

    guard
      let preparation = try await remoteRepositoryFeature.prepareTicketIntegration(
        productID: candidate.productID
      )
    else {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }
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

  private func monitorLiveActivity(
    runID: UUID,
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  ) {
    stopLiveActivityMonitoring(runID: runID)
    let initialActivity = CodexLiveActivity(text: initialText, kind: .thinking)
    liveRunActivities[runID] = initialActivity

    ticketDeliveryRuntimeCoordinator.startLiveActivity(
      runID: runID,
      productID: productID
    ) { [weak self] monitorID in
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
        guard
          self.ticketDeliveryRuntimeCoordinator.isLiveActivityCurrent(
            runID: runID,
            monitorID: monitorID
          )
        else { return }

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
          return
        }
      }

      guard
        self.ticketDeliveryRuntimeCoordinator.isLiveActivityCurrent(
          runID: runID,
          monitorID: monitorID
        )
      else { return }
      self.liveRunActivities.removeValue(forKey: runID)
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
    ticketDeliveryRuntimeCoordinator.stopLiveActivity(runID: runID)
    liveRunActivities.removeValue(forKey: runID)
  }

  private func applyExecutionLifecycle(
    _ event: ProductExecutionLifecycleEvent
  ) async {
    switch ProductExecutionLifecyclePolicy.suspensionScope(for: event) {
    case .none:
      return
    case .product(let productID):
      await ticketDeliveryWorkflowCoordinator.suspendSprintExecution(productID: productID)
    case .all:
      await ticketDeliveryWorkflowCoordinator.suspendSprintExecution()
    }
  }

  private func interruptFeatureTurn(_ turn: CodexTurnIdentity) async {
    guard let client = codexClient else { return }
    try? await client.interruptTurn(
      threadID: turn.threadID,
      turnID: turn.turnID
    )
  }

  private func settleFeatureRuntimes(
    productID: UUID,
    preservingOwnerAgentTurns: Bool = false
  ) async {
    await transientOwnerCommandRuntime.cancel(productID: productID)
    await epicPlanningWorkflowCoordinator.cancel(
      productID: productID,
      preservingEpicPlanning: preservingOwnerAgentTurns
    )
    if !preservingOwnerAgentTurns {
      await planningConversationWorkflowCoordinator.cancel(productID: productID)
      await sprintPlanningWorkflowCoordinator.cancel(productID: productID)
    }
    await retrospectiveSynthesisRuntime.cancel(productID: productID) {
      [weak self] turn in
      await self?.interruptFeatureTurn(turn)
    }
  }

  private func shutdownFeatureRuntimes() async {
    await transientOwnerCommandRuntime.shutdown()
    await epicPlanningWorkflowCoordinator.shutdown()
    await planningConversationWorkflowCoordinator.shutdown()
    await sprintPlanningWorkflowCoordinator.shutdown()
    await retrospectiveSynthesisRuntime.shutdown { [weak self] turn in
      await self?.interruptFeatureTurn(turn)
    }
    await productConversationFeature.shutdown()
  }

  func shutdown() async {
    isShuttingDown = true
    ownerNotificationCoordinator.beginShutdown()
    await repositoryImportCoordinator?.cancel()
    await remoteRepositoryFeature.shutdown()
    await repositoryKnowledgeCoordinator.shutdown()
    await shutdownFeatureRuntimes()
    await stopAllDemoSessions()
    await applyExecutionLifecycle(.appShutdown)
    await codexConnectionRuntime.shutdown()
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
      !retrospectiveSynthesisRuntime.isBusy,
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
      !retrospectiveSynthesisRuntime.isBusy,
      case .connected = codexConnectionState,
      let product = selectedProduct,
      product.id == synthesis.productID,
      synthesis.status == .pending
        || (allowsFailedRetry && synthesis.status == .failed)
    else { return }

    _ = retrospectiveSynthesisRuntime.start(
      synthesisID: synthesis.id,
      productID: product.id
    ) { [weak self] token in
      guard let self else { return }
      await performRetrospectiveSynthesis(
        synthesisID: synthesis.id,
        product: product,
        operationToken: token
      )
      scheduleRetrospectiveSyntheses()
    }
  }

  private func performRetrospectiveSynthesis(
    synthesisID: UUID,
    product: Product,
    operationToken: FeatureOperationToken<UUID>
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
      retrospectiveSynthesisRuntime.recordTurn(
        synthesisID: synthesis.id,
        token: operationToken,
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
        retrospectiveSynthesisRuntime.recordTurn(
          synthesisID: synthesis.id,
          token: operationToken,
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

  func awaitRepositoryKnowledgeRecovery(productID: UUID) async {
    await repositoryKnowledgeCoordinator.send(.recover(productID: productID))
  }

  func retryRepositoryKnowledgeAnalysis() async {
    guard let productID = selectedProductID else { return }
    await repositoryKnowledgeCoordinator.send(.retry(productID: productID))
  }

  var isCheckingImportedAppLaunch: Bool {
    guard repositoryKnowledgeSnapshot?.run?.purpose == .importedAppLaunch else {
      return false
    }
    return repositoryKnowledgeSnapshot?.isActive == true
  }

  var canCheckImportedAppLaunch: Bool {
    guard let productID = selectedProductID else { return false }
    let snapshot = repositoryKnowledgeSnapshot
    return snapshot?.productID == productID
      && productRepository != nil
      && importedAppLaunch == nil
      && snapshot?.isActive != true
      && codexRuntimeExecutableURL != nil
  }

  func checkImportedAppLaunch() async {
    guard let productID = selectedProductID, canCheckImportedAppLaunch else { return }
    await repositoryKnowledgeCoordinator.send(.checkImportedAppLaunch(productID: productID))
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
      let productLists = try await fetchProductLists()
      products = productLists.active
      archivedProducts = productLists.archived
      ticketAttentionsByProductID = await fetchTicketAttentions(products: products)
      await ownerNotificationCoordinator.load(products: products)
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
      sprintPlanningWorkflowCoordinator.clearSelectedProductProjection()
      activity = []
      epicPlanningWorkflowCoordinator.clearSelectedProductProjection()
      importedAppLaunch = nil
      retrospectiveNotes = []
      retrospectiveSyntheses = []
      retrospectiveActionSources = []
      knowledgePages = []
      knowledgePageReadState.reset()
      unreadKnowledgePageIDs = []
      productRepository = nil
      repositoryKnowledgeSnapshot = nil
      candidateRevisions = []
      demoSessions = []
      permissionRequests = []
      permissionGrants = []
      knowledgePageProposals = []
      agentRunKnowledgeContext = []
      agentRunKnowledgeDestinations = []
      productConversationFeature.clear()
      return
    }
    do {
      await repositoryKnowledgeCoordinator.send(.refresh(productID: productID))
      _ = await remoteRepositoryFeature.state(productID: productID)
      let workspace = try await store.fetchProductWorkspaceSnapshot(productID: productID)

      guard selectedProductID == productID else { return }
      epics = workspace.epics
      importedAppLaunch = workspace.importedAppLaunch
      workItems = workspace.workItems
      dependencies = workspace.dependencies
      profiles = workspace.profiles
      knowledgePages = workspace.knowledgePages
      knowledgePageReadState.load(productID: productID, pages: workspace.knowledgePages)
      unreadKnowledgePageIDs = knowledgePageReadState.unreadPageIDs(in: workspace.knowledgePages)
      productRepository = workspace.productRepository
      repositoryKnowledgeSnapshot = repositoryKnowledgeCoordinator.snapshot(for: productID)
      agentRunKnowledgeContext = workspace.agentRunKnowledgeContext
      agentRunKnowledgeDestinations = workspace.agentRunKnowledgeDestinations
      candidateRevisions = workspace.candidateRevisions
      demoSessions = workspace.demoSessions
      permissionRequests = workspace.permissionRequests
      permissionGrants = workspace.permissionGrants
      knowledgePageProposals = workspace.knowledgePageProposals
      sprintPlan = workspace.sprintPlan
      sprintHistory = workspace.sprintHistory
      runs = workspace.runs
      sprintPlanningWorkflowCoordinator.loadReadinessProjection(workspace.sprintReadinessIssues)
      activity = workspace.activity
      retrospectiveNotes = workspace.retrospectiveNotes
      retrospectiveSyntheses = workspace.retrospectiveSyntheses
      retrospectiveActionSources = workspace.retrospectiveActionSources
      epicPlanningWorkflowCoordinator.loadSuggestionBatch(workspace.suggestionBatch)
      productConversationFeature.load(
        productID: productID,
        threads: workspace.conversationThreads
      )
    } catch {
      presentExecutionError(error, productID: productID)
    }
  }

  private func startCodexUsageMonitoring(client: CodexAppServerClient) async {
    stopCodexUsageMonitoring()
    isRefreshingCodexUsage = true
    let messages = await client.inboundMessages(replayRecent: false)

    codexConnectionRuntime.start(.usageMonitor) { [weak self] monitorToken in
      guard let self else { return }
      await self.refreshCodexUsage(client: client, monitorToken: monitorToken)
      for await message in messages {
        guard !Task.isCancelled else { return }
        guard
          case .notification(let notification) = message,
          notification.method == "account/rateLimits/updated"
        else { continue }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await self.refreshCodexUsage(client: client, monitorToken: monitorToken)
      }
    }
  }

  private func refreshCodexUsage(
    client: CodexAppServerClient,
    monitorToken: FeatureOperationToken<CodexConnectionRuntime.Operation>
  ) async {
    guard codexConnectionRuntime.isCurrent(monitorToken) else { return }
    isRefreshingCodexUsage = true
    do {
      let snapshot = try await client.readRateLimits()
      guard codexConnectionRuntime.isCurrent(monitorToken) else { return }
      codexRateLimits = snapshot
      codexUsageUpdatedAt = Date()
      isCodexUsageStale = false
      isRefreshingCodexUsage = false
      scheduleCodexUsageReset(
        snapshot.nextResetAt,
        client: client,
        monitorToken: monitorToken
      )
    } catch {
      guard codexConnectionRuntime.isCurrent(monitorToken) else { return }
      isRefreshingCodexUsage = false
      isCodexUsageStale = codexRateLimits != nil
    }
  }

  private func scheduleCodexUsageReset(
    _ resetAt: Date?,
    client: CodexAppServerClient,
    monitorToken: FeatureOperationToken<CodexConnectionRuntime.Operation>
  ) {
    codexConnectionRuntime.stopNow(.usageReset)
    guard let resetAt else {
      return
    }
    let delay = resetAt.timeIntervalSinceNow + 1
    guard delay > 0 else {
      return
    }
    codexConnectionRuntime.start(.usageReset) { [weak self] _ in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard let self, self.codexConnectionRuntime.isCurrent(monitorToken) else {
        return
      }
      self.isRefreshingCodexUsage = true
      await self.refreshCodexUsage(client: client, monitorToken: monitorToken)
    }
  }

  private func stopCodexUsageMonitoring() {
    codexConnectionRuntime.stopNow(.usageMonitor)
    codexConnectionRuntime.stopNow(.usageReset)
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
      let factoryOutput = try await codexTransportFactory(candidates)
      let descriptor = factoryOutput.descriptor
      let client = CodexAppServerClient(transport: factoryOutput.transport)
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
      await repositoryKnowledgeCoordinator.send(
        .runtimeChanged(executableURL: descriptor.executableURL)
      )
      demoLauncher.useExecutor(
        CodexWorkspaceCommandExecutor(executableURL: descriptor.executableURL)
      )
      startApprovalRouting(client: client)
      await startCodexUsageMonitoring(client: client)
      codexConnectionState = .connected(version: descriptor.version, userAgent: info.userAgent)
      scheduleRetrospectiveSyntheses()
      await repositoryKnowledgeCoordinator.send(.schedule(productIDs: products.map(\.id)))
      codexModels = models
    } catch let error as CodexRuntimeError {
      codexRuntimeExecutableURL = nil
      await repositoryKnowledgeCoordinator.send(.runtimeChanged(executableURL: nil))
      switch error {
      case .missingRequiredFeature:
        codexConnectionState = .incompatible(error.localizedDescription)
      default:
        codexConnectionState = .unavailable(error.localizedDescription)
      }
    } catch {
      codexRuntimeExecutableURL = nil
      await repositoryKnowledgeCoordinator.send(.runtimeChanged(executableURL: nil))
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
    codexConnectionRuntime.stopNow(.approvalRouting)
    stopCodexUsageMonitoring()
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
    await ticketDeliveryPermissionWorkflowCoordinator.decidePermissionRequest(
      request,
      allow: allow,
      rememberForProduct: rememberForProduct
    )
  }

  private func startApprovalRouting(client: CodexAppServerClient) {
    codexConnectionRuntime.start(.approvalRouting) { [weak self] _ in
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
    await ticketDeliveryPermissionWorkflowCoordinator.handleServerRequest(
      request,
      client: client
    )
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

  private func recoverTicketSuggestionSessionIfNeeded() async {
    await epicPlanningWorkflowCoordinator.recoverTicketSuggestionSessionIfNeeded()
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
    try appApplicationSupportURL()
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

  func deliveryStore(for productID: UUID) -> SQLiteStore? {
    store(for: productID)
  }

  func deliveryStore(containingAgentRun runID: UUID) async -> SQLiteStore? {
    if let injectedStore {
      return injectedStore
    }
    if let storeRegistry {
      return await storeRegistry.findStore(containingAgentRun: runID)
    }
    return store
  }

  var deliveryCodexClient: CodexAppServerClient? { codexClient }
  var deliverySelectedProductID: UUID? { selectedProductID }
  var deliveryIsShuttingDown: Bool { isShuttingDown }

  var deliveryAgentRunKnowledgeContext: [AgentRunKnowledgePage] {
    get { agentRunKnowledgeContext }
    set { agentRunKnowledgeContext = newValue }
  }

  var deliveryAgentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] {
    get { agentRunKnowledgeDestinations }
    set { agentRunKnowledgeDestinations = newValue }
  }

  func deliveryProductWorkspaceURL(productID: UUID) throws -> URL {
    try Self.productWorkspaceURL(productID: productID)
  }

  func deliveryTicketWorktreesRootURL(productID: UUID) throws -> URL {
    try Self.ticketWorktreesRootURL(productID: productID)
  }

  func deliveryProductDatabaseURL(productID: UUID) throws -> URL {
    try Self.productDatabaseURL(productID: productID)
  }

  func deliveryIntegrationWorktreesRootURL(productID: UUID) throws -> URL {
    try Self.integrationWorktreesRootURL(productID: productID)
  }

  func deliveryIntegrateLatestGitHubChanges(
    candidate: CandidateRevision,
    integration: GitIntegrationSnapshot
  ) async throws -> TicketDeliveryRemoteIntegration {
    let result = try await integrateLatestGitHubChanges(
      candidate: candidate,
      integration: integration
    )
    return TicketDeliveryRemoteIntegration(
      snapshot: result.snapshot,
      incorporatedChanges: result.incorporatedChanges,
      remoteSHA: result.remoteSHA
    )
  }

  var deliveryRequiresKnowledgeApproval: Bool { requiresKnowledgeApproval }
  var deliveryDemoSessions: [DemoSession] { demoSessions }

  func deliveryRemoteRepositoryState(productID: UUID) async -> GitHubRemoteRepositoryState? {
    await remoteRepositoryFeature.state(productID: productID)
  }

  func deliverySyncTicketPullRequestForDelivery(
    productID: UUID,
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    try await remoteRepositoryFeature.syncTicketPullRequestForDelivery(
      productID: productID,
      publicationID: publicationID
    )
  }

  func deliveryHandleGitHubPullRequestSync(
    _ sync: GitHubTicketPullRequestSync,
    productID: UUID
  ) async {
    await handleGitHubPullRequestSync(sync, productID: productID)
  }

  func deliveryCheckRemoteRepositoryForDelivery(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState? {
    try await remoteRepositoryFeature.checkForDelivery(productID: productID)
  }

  func deliveryAcceptSafeRemoteSync(syncID: UUID, productID: UUID) async throws {
    try await remoteRepositoryFeature.acceptSafeSyncForDelivery(
      syncID: syncID,
      productID: productID
    )
  }

  func deliveryMergeTicketPullRequest(
    publicationID: UUID,
    productID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult? {
    try await remoteRepositoryFeature.mergeTicketPullRequest(
      publicationID: publicationID,
      productID: productID
    )
  }

  func deliveryReturnTicketPullRequestToDraft(
    publicationID: UUID,
    productID: UUID
  ) async throws {
    try await remoteRepositoryFeature.returnTicketPullRequestToDraft(
      publicationID: publicationID,
      productID: productID
    )
  }

  func deliveryPrepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication? {
    try await prepareTicketPullRequestIfConnected(
      productID: productID,
      workItemID: workItemID,
      candidateRevisionID: candidateRevisionID
    )
  }

  func deliveryMarkTicketPullRequestReadyIfNeeded(
    _ publication: RemotePublication?
  ) async throws {
    try await markTicketPullRequestReadyIfNeeded(publication)
  }

  func deliveryPrepareDemoForAcceptance(
    candidate: CandidateRevision,
    integratedSHA: String,
    specification: DemoLaunchSpecification
  ) async throws {
    try await prepareDemoForAcceptance(
      candidate: candidate,
      integratedSHA: integratedSHA,
      specification: specification
    )
  }

  func deliveryDemoPreparationShouldCorrectCandidate(_ error: Error) -> Bool {
    DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate
  }

  func deliveryStopManagedSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    removesPreview: Bool
  ) async {
    await stopManagedSession(
      productID: productID,
      sourceKind: sourceKind,
      launchID: launchID,
      removesPreview: removesPreview
    )
  }

  func deliveryScheduleRetrospectiveSyntheses() {
    scheduleRetrospectiveSyntheses()
  }

  func deliveryInheritedAgentInstructions(
    for product: Product,
    includesMandatoryKnowledge: Bool
  ) -> String {
    inheritedAgentInstructions(
      for: product,
      includesMandatoryKnowledge: includesMandatoryKnowledge
    )
  }

  func deliveryAgentRunDidUpdate(previous: AgentRun, updated: AgentRun) async {
    let newlyNeedsAttention = TicketAttentionSoundPolicy.shouldPlay(
      previousStatus: previous.status,
      newStatus: updated.status,
      isShuttingDown: isShuttingDown
    )
    if previous.status == .awaitingOwner || updated.status == .awaitingOwner {
      await refreshTicketAttentions(productID: updated.productID)
    }
    if previous.status == .awaitingOwner && updated.status != .awaitingOwner {
      ownerNotificationCoordinator.dismissSystemNotification(id: previous.id)
    }
    if newlyNeedsAttention,
      let attention = ticketAttentionsByProductID[updated.productID]?
        .first(where: { $0.workItemID == updated.workItemID })
    {
      ownerNotificationCoordinator.present(attention)
    }
  }

  func deliveryReloadSelectedProductIfCurrent(productID: UUID) async {
    await reloadSelectedProductIfCurrent(productID: productID)
  }

  func deliveryMonitorLiveActivity(
    runID: UUID,
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  ) {
    monitorLiveActivity(
      runID: runID,
      productID: productID,
      client: client,
      threadID: threadID,
      turnID: turnID,
      initialText: initialText
    )
  }

  func deliveryStopLiveActivityMonitoring(runID: UUID) {
    stopLiveActivityMonitoring(runID: runID)
  }

  func deliveryPresentExecutionError(_ error: Error, productID: UUID) {
    presentExecutionError(error, productID: productID)
  }

  func deliveryStopDemoSession(
    _ candidate: CandidateRevision,
    removesPreview: Bool
  ) async {
    await stopDemoSession(candidate, removesPreview: removesPreview)
  }

  func deliveryStopDemoSessions(productID: UUID, includesPreparation: Bool) async {
    await stopDemoSessions(
      productID: productID,
      includesPreparation: includesPreparation
    )
  }

  var deliveryRuns: [AgentRun] { runs }

  var deliveryErrorMessage: String? {
    get { errorMessage }
    set { errorMessage = newValue }
  }

  func deliveryReplacePermissionRequest(_ request: AgentPermissionRequest) {
    replacePermissionRequest(request)
  }

  func deliveryReplacePermissionGrant(_ grant: AgentPermissionGrant) {
    replacePermissionGrant(grant)
  }

  func deliveryScheduleSprintExecution(productID: UUID) {
    scheduleSprintExecution(productID: productID)
  }

}
