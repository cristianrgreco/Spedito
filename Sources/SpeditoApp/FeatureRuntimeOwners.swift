import Combine
import Foundation
import SpeditoCore

@MainActor
final class ProductLibraryFeatureModel: ObservableObject {
  @Published var products: [Product] = []
  @Published var archivedProducts: [Product] = []
  @Published var selectedProductID: UUID?
  @Published var shouldPresentOnLaunch = false
  @Published var creationError: String?
}

@MainActor
final class EpicPlanningFeatureModel: ObservableObject {
  @Published var snapshot = EpicPlanningWorkflowSnapshot()
}


@MainActor
final class PlanningConversationFeatureModel: ObservableObject {
  @Published var snapshot = PlanningConversationWorkflowSnapshot()
}


@MainActor
final class SprintPlanningFeatureModel: ObservableObject {
  @Published var snapshot = SprintPlanningWorkflowSnapshot(
    isSendingMessage: false,
    isGeneratingGoal: false,
    readinessIssues: []
  )
}


@MainActor
final class RetrospectiveSynthesisRuntime: ObservableObject {
  private let operations = FeatureOperationRegistry<UUID>()
  @Published var notes: [RetrospectiveNote] = []
  @Published var syntheses: [RetrospectiveSynthesis] = []
  @Published var actionSources: [RetrospectiveActionSource] = []

  var isBusy: Bool { operations.isBusy }

  func start(
    synthesisID: UUID,
    productID: UUID,
    operation: @escaping @MainActor (FeatureOperationToken<UUID>) async -> Void
  ) -> Bool {
    operations.start(synthesisID, productID: productID, operation: operation) != nil
  }

  func recordTurn(
    synthesisID: UUID,
    token: FeatureOperationToken<UUID>,
    threadID: String,
    turnID: String
  ) {
    operations.recordTurn(CodexTurnIdentity(threadID: threadID, turnID: turnID), for: token)
  }

  func finish(_ token: FeatureOperationToken<UUID>) {
    operations.finish(token)
  }

  func cancel(productID: UUID, interrupt: (CodexTurnIdentity) async -> Void) async {
    await operations.cancel(productID: productID, interrupt: interrupt)
  }

  func shutdown(interrupt: (CodexTurnIdentity) async -> Void) async {
    await operations.shutdown(interrupt: interrupt)
  }
}

@MainActor
final class ProductConversationRuntime {
  enum Operation: Hashable {
    case response(UUID)
    case title(UUID)
    case activity(UUID)
    case interruption(UUID)
  }

  private let operations = FeatureOperationRegistry<Operation>()
  private var cancelledThreadIDs: Set<UUID> = []

  var isBusy: Bool { operations.isBusy }

  func activeResponseThreadIDs(productID: UUID) -> Set<UUID> {
    Set(
      operations.activeKeys(productID: productID).compactMap { operation in
        guard case .response(let threadID) = operation else { return nil }
        return threadID
      }
    )
  }

  func start(
    _ operation: Operation,
    productID: UUID,
    replacing: Bool = false,
    body: @escaping @MainActor (FeatureOperationToken<Operation>) async -> Void
  ) -> Bool {
    operations.start(operation, productID: productID, replacing: replacing, operation: body) != nil
  }

  func claimResponse(
    threadID: UUID,
    productID: UUID
  ) -> FeatureOperationToken<Operation>? {
    operations.claim(.response(threadID), productID: productID)
  }

  func recordTurn(
    _ turn: CodexTurnIdentity,
    for token: FeatureOperationToken<Operation>
  ) {
    operations.recordTurn(turn, for: token)
  }

  func activeTurn(_ operation: Operation) -> CodexTurnIdentity? {
    operations.turn(for: operation)
  }

  func isCurrent(_ token: FeatureOperationToken<Operation>) -> Bool {
    operations.isCurrent(token)
  }

  func finish(_ token: FeatureOperationToken<Operation>) {
    operations.finish(token)
  }

  func stop(_ operation: Operation) {
    operations.cancelTask(operation)
    guard let token = operations.token(for: operation) else { return }
    operations.finish(token)
  }

  func requestInterrupt(
    threadID: UUID,
    interrupt: @escaping @MainActor (CodexTurnIdentity) async -> Void
  ) {
    guard let turn = operations.turn(for: .response(threadID)) else { return }
    operations.start(.interruption(threadID), productID: nil, replacing: true) { _ in
      await interrupt(turn)
    }
  }

  func cancelThread(_ threadID: UUID) {
    cancelledThreadIDs.insert(threadID)
  }

  func isCancelled(_ threadID: UUID) -> Bool {
    cancelledThreadIDs.contains(threadID)
  }

  func clearCancellation(_ threadID: UUID) {
    cancelledThreadIDs.remove(threadID)
  }

  func consumeCancellation(_ threadID: UUID) -> Bool {
    cancelledThreadIDs.remove(threadID) != nil
  }

  func clearCancellations() {
    cancelledThreadIDs.removeAll()
  }

  func cancel(
    productID: UUID,
    interrupt: (CodexTurnIdentity) async -> Void,
    markCancelled: (UUID, UUID) async -> Void
  ) async {
    let threadIDs = operations.activeKeys(productID: productID).compactMap {
      operation -> UUID? in
      guard case .response(let threadID) = operation else { return nil }
      return threadID
    }
    for threadID in threadIDs {
      await markCancelled(threadID, productID)
    }
    await operations.cancel(productID: productID, interrupt: interrupt)
  }

  func shutdown(
    interrupt: (CodexTurnIdentity) async -> Void,
    markCancelled: (UUID, UUID) async -> Void
  ) async {
    let responses = operations.activeKeys.compactMap {
      operation -> (UUID, UUID)? in
      guard
        case .response(let threadID) = operation,
        let productID = operations.productID(for: operation)
      else { return nil }
      return (threadID, productID)
    }
    for (threadID, productID) in responses {
      await markCancelled(threadID, productID)
    }
    await operations.shutdown(interrupt: interrupt)
    clearCancellations()
  }
}

@MainActor
final class DemoSessionFeatureModel: ObservableObject {
  @Published var sessions: [DemoSession] = []
  var launcher: MacOSDemoLauncher
  var productsLaunchingPresentation: Set<UUID> = []

  init(launcher: MacOSDemoLauncher = MacOSDemoLauncher()) {
    self.launcher = launcher
  }
}

@MainActor
final class CodexConnectionRuntime: ObservableObject {
  enum Operation: Hashable {
    case approvalRouting
    case usageMonitor
    case usageReset
  }
  private let operations = FeatureOperationRegistry<Operation>()
  @Published var models: [CodexModelOption] = []
  @Published var connectionState = CodexConnectionState.notChecked
  @Published var rateLimits: CodexRateLimitsSnapshot?
  @Published var usageUpdatedAt: Date?
  @Published var isRefreshingUsage = false
  @Published var isUsageStale = false
  @Published var installations: [CodexInstallation] = []
  @Published var selectedInstallationID: String?

  func start(
    _ operation: Operation,
    replacing: Bool = true,
    body: @escaping @MainActor (FeatureOperationToken<Operation>) async -> Void
  ) {
    operations.start(operation, productID: nil, replacing: replacing, operation: body)
  }

  func isCurrent(_ token: FeatureOperationToken<Operation>) -> Bool {
    operations.isCurrent(token)
  }

  func stopNow(_ operation: Operation) {
    operations.cancelTask(operation)
    guard let token = operations.token(for: operation) else { return }
    operations.finish(token)
  }

  func stop(_ operation: Operation) async {
    await operations.cancel(operation)
  }

  func shutdown() async {
    await operations.shutdown()
  }
}

@MainActor
final class TransientOwnerCommandRuntime {
  private let operations = FeatureOperationRegistry<UUID>()

  func start(
    productID: UUID?,
    operation: @escaping @MainActor () async -> Void
  ) {
    operations.start(UUID(), productID: productID) { _ in
      await operation()
    }
  }

  func settle() async {
    await operations.settleAll()
  }

  func cancel(productID: UUID) async {
    await operations.cancel(productID: productID)
  }

  func shutdown() async {
    await operations.shutdown()
  }
}
