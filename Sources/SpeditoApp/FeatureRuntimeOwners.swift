import Combine
import Foundation
import SpeditoCore

struct CodexTurnIdentity: Equatable, Sendable {
  let threadID: String
  let turnID: String
}

struct FeatureOperationToken<Key: Hashable>: Hashable {
  let key: Key
  fileprivate let identity: UUID
}

@MainActor
final class FeatureOperationRegistry<Key: Hashable> {
  private struct Entry {
    let productID: UUID?
    let token: FeatureOperationToken<Key>
    var task: Task<Void, Never>?
    var turn: CodexTurnIdentity?
  }

  private var entries: [Key: Entry] = [:]
  private var settlementWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

  var isBusy: Bool { !entries.isEmpty }
  var activeKeys: Set<Key> { Set(entries.keys) }

  func activeKeys(productID: UUID) -> Set<Key> {
    Set(
      entries.compactMap { key, entry in
        entry.productID == productID ? key : nil
      })
  }

  func productID(for key: Key) -> UUID? {
    entries[key]?.productID
  }

  func isActive(_ key: Key) -> Bool {
    entries[key] != nil
  }

  func isCurrent(_ token: FeatureOperationToken<Key>) -> Bool {
    entries[token.key]?.token == token
  }

  func token(for key: Key) -> FeatureOperationToken<Key>? {
    entries[key]?.token
  }

  @discardableResult
  func claim(
    _ key: Key,
    productID: UUID?,
    replacing: Bool = false
  ) -> FeatureOperationToken<Key>? {
    guard replacing || entries[key] == nil else { return nil }
    entries[key]?.task?.cancel()
    let token = FeatureOperationToken(key: key, identity: UUID())
    entries[key] = Entry(productID: productID, token: token, task: nil, turn: nil)
    return token
  }

  @discardableResult
  func start(
    _ key: Key,
    productID: UUID?,
    replacing: Bool = false,
    operation: @escaping @MainActor (FeatureOperationToken<Key>) async -> Void
  ) -> FeatureOperationToken<Key>? {
    guard replacing || entries[key] == nil else { return nil }
    let previousTask = entries[key]?.task
    previousTask?.cancel()
    let token = FeatureOperationToken(key: key, identity: UUID())
    let task = Task { @MainActor [weak self] in
      await previousTask?.value
      guard !Task.isCancelled else {
        self?.finish(token)
        return
      }
      await operation(token)
      self?.finish(token)
    }
    entries[key] = Entry(productID: productID, token: token, task: task, turn: nil)
    return token
  }

  @discardableResult
  func enqueue(
    _ key: Key,
    productID: UUID?,
    operation: @escaping @MainActor () async -> Void
  ) -> FeatureOperationToken<Key> {
    let previousTask = entries[key]?.task
    let token = FeatureOperationToken(key: key, identity: UUID())
    let task = Task { @MainActor [weak self] in
      await previousTask?.value
      guard !Task.isCancelled else {
        self?.finish(token)
        return
      }
      await operation()
      self?.finish(token)
    }
    entries[key] = Entry(productID: productID, token: token, task: task, turn: nil)
    return token
  }

  func recordTurn(
    _ turn: CodexTurnIdentity,
    for token: FeatureOperationToken<Key>
  ) {
    guard var entry = entries[token.key], entry.token == token else { return }
    entry.turn = turn
    entries[token.key] = entry
  }

  func clearTurn(for token: FeatureOperationToken<Key>) {
    guard var entry = entries[token.key], entry.token == token else { return }
    entry.turn = nil
    entries[token.key] = entry
  }

  func turn(for key: Key) -> CodexTurnIdentity? {
    entries[key]?.turn
  }

  func finish(_ token: FeatureOperationToken<Key>) {
    let waiters = settlementWaiters.removeValue(forKey: token.identity) ?? []
    for waiter in waiters {
      waiter.resume()
    }
    guard entries[token.key]?.token == token else { return }
    entries.removeValue(forKey: token.key)
  }

  func cancelTask(_ key: Key) {
    entries[key]?.task?.cancel()
  }

  func settle(_ key: Key) async {
    guard let entry = entries[key] else { return }
    await entry.task?.value
  }

  func settleAll() async {
    while !entries.isEmpty {
      let currentEntries = Array(entries.values)
      for entry in currentEntries {
        if let task = entry.task {
          await task.value
        } else {
          await waitForSettlement(entry.token)
        }
      }
    }
  }

  func cancel(
    _ key: Key,
    interrupt: (CodexTurnIdentity) async -> Void = { _ in }
  ) async {
    guard let entry = entries[key] else { return }
    entry.task?.cancel()
    if let turn = entry.turn {
      await interrupt(turn)
    }
    if let task = entry.task {
      await task.value
      finish(entry.token)
    } else {
      await waitForSettlement(entry.token)
    }
  }

  func cancel(
    productID: UUID,
    interrupt: (CodexTurnIdentity) async -> Void = { _ in }
  ) async {
    let matchingEntries = entries.values.filter { $0.productID == productID }
    await cancel(entries: matchingEntries, interrupt: interrupt)
  }

  func shutdown(
    interrupt: (CodexTurnIdentity) async -> Void = { _ in }
  ) async {
    await cancel(entries: Array(entries.values), interrupt: interrupt)
  }

  private func cancel(
    entries entriesToCancel: [Entry],
    interrupt: (CodexTurnIdentity) async -> Void
  ) async {
    for entry in entriesToCancel {
      entry.task?.cancel()
    }
    for entry in entriesToCancel {
      if let turn = entry.turn {
        await interrupt(turn)
      }
    }
    for entry in entriesToCancel {
      if let task = entry.task {
        await task.value
        finish(entry.token)
      } else {
        await waitForSettlement(entry.token)
      }
    }
  }

  private func waitForSettlement(_ token: FeatureOperationToken<Key>) async {
    guard isCurrent(token) else { return }
    await withCheckedContinuation { continuation in
      guard isCurrent(token) else {
        continuation.resume()
        return
      }
      settlementWaiters[token.identity, default: []].append(continuation)
    }
  }
}
@MainActor
final class ProductLibraryFeatureModel: ObservableObject {
  @Published var products: [Product] = []
  @Published var archivedProducts: [Product] = []
  @Published var selectedProductID: UUID?
  @Published var shouldPresentOnLaunch = false
  @Published var creationError: String?
}

@MainActor
final class TicketSuggestionRuntime: ObservableObject {
  private enum Operation: Hashable { case generation }
  private let operations = FeatureOperationRegistry<Operation>()
  private var recoveredSessionIDs: Set<UUID> = []
  @Published var batch: TicketSuggestionBatch?
  @Published var isDeciding = false

  var isBusy: Bool { operations.isBusy }

  func markRecovered(sessionID: UUID) -> Bool {
    recoveredSessionIDs.insert(sessionID).inserted
  }

  func resetRecoveryMarkers() {
    recoveredSessionIDs.removeAll()
  }

  func start(
    productID: UUID,
    operation: @escaping @MainActor () async -> Void
  ) {
    operations.start(.generation, productID: productID, replacing: true) { _ in
      await operation()
    }
  }

  func cancel(productID: UUID) async {
    await operations.cancel(productID: productID)
  }

  func shutdown() async {
    await operations.shutdown()
  }
}

private struct PlanningConversationKey: Hashable {
  let workItemID: UUID
  let profileID: UUID
}

@MainActor
final class PlanningConversationRuntime: ObservableObject {
  @Published var isTicketMessageRunning = false
  @Published var ticketWorkItemID: UUID?
  @Published var ticketRecipientID: UUID?
  @Published var ticketActivity: CodexLiveActivity?
  @Published var isEpicMessageRunning = false
  @Published var epicID: UUID?
  @Published var epicRecipientID: UUID?
  @Published var refinementResults: [UUID: TicketRefinementSessionResult] = [:]
  @Published var ticketResults: [UUID: TicketConversationSessionResult] = [:]
  enum TurnKind: Hashable {
    case sprintPlanning
    case sprintGoal
    case ticketConversation
    case epicConversation
    case ticketRefinement
  }

  enum TaskKind: Hashable {
    case ticketActivity
    case turnInterruption(TurnKind)
  }

  private let turns = FeatureOperationRegistry<TurnKind>()
  private let tasks = FeatureOperationRegistry<TaskKind>()
  private var planningThreadIDs: [PlanningConversationKey: String] = [:]
  private var ticketThreadIDs: [PlanningConversationKey: String] = [:]
  private var epicThreadIDs: [PlanningConversationKey: String] = [:]

  var isBusy: Bool { turns.isBusy || tasks.isBusy }

  func planningThreadID(workItemID: UUID, profileID: UUID) -> String? {
    planningThreadIDs[PlanningConversationKey(workItemID: workItemID, profileID: profileID)]
  }

  func setPlanningThreadID(_ threadID: String, workItemID: UUID, profileID: UUID) {
    planningThreadIDs[PlanningConversationKey(workItemID: workItemID, profileID: profileID)] =
      threadID
  }

  func removePlanningThreadID(workItemID: UUID, profileID: UUID) {
    planningThreadIDs.removeValue(
      forKey: PlanningConversationKey(workItemID: workItemID, profileID: profileID)
    )
  }

  func ticketThreadID(workItemID: UUID, profileID: UUID) -> String? {
    ticketThreadIDs[PlanningConversationKey(workItemID: workItemID, profileID: profileID)]
  }

  func setTicketThreadID(_ threadID: String, workItemID: UUID, profileID: UUID) {
    ticketThreadIDs[PlanningConversationKey(workItemID: workItemID, profileID: profileID)] =
      threadID
  }

  func removeTicketThreadID(workItemID: UUID, profileID: UUID) {
    ticketThreadIDs.removeValue(
      forKey: PlanningConversationKey(workItemID: workItemID, profileID: profileID)
    )
  }

  func epicThreadID(epicID: UUID, profileID: UUID) -> String? {
    epicThreadIDs[PlanningConversationKey(workItemID: epicID, profileID: profileID)]
  }

  func setEpicThreadID(_ threadID: String, epicID: UUID, profileID: UUID) {
    epicThreadIDs[PlanningConversationKey(workItemID: epicID, profileID: profileID)] = threadID
  }

  func removeEpicThreadID(epicID: UUID, profileID: UUID) {
    epicThreadIDs.removeValue(
      forKey: PlanningConversationKey(workItemID: epicID, profileID: profileID)
    )
  }

  @discardableResult
  func beginTurn(
    _ kind: TurnKind,
    productID: UUID,
    threadID: String,
    turnID: String
  ) -> FeatureOperationToken<TurnKind> {
    let token = turns.claim(kind, productID: productID, replacing: true)!
    turns.recordTurn(CodexTurnIdentity(threadID: threadID, turnID: turnID), for: token)
    return token
  }

  func activeTurn(_ kind: TurnKind) -> CodexTurnIdentity? {
    turns.turn(for: kind)
  }

  func finishTurn(_ token: FeatureOperationToken<TurnKind>) {
    turns.finish(token)
  }

  func requestInterrupt(
    _ kind: TurnKind,
    interrupt: @escaping @MainActor (CodexTurnIdentity) async -> Void
  ) {
    guard let turn = turns.turn(for: kind) else { return }
    tasks.start(.turnInterruption(kind), productID: nil, replacing: true) { _ in
      await interrupt(turn)
    }
  }

  func startTicketActivity(
    productID: UUID,
    operation: @escaping @MainActor (FeatureOperationToken<TaskKind>) async -> Void
  ) {
    tasks.start(.ticketActivity, productID: productID, replacing: true, operation: operation)
  }

  func isCurrentTicketActivity(_ token: FeatureOperationToken<TaskKind>) -> Bool {
    tasks.isCurrent(token)
  }

  func stopTicketActivity() {
    guard tasks.isActive(.ticketActivity) else { return }
    tasks.cancelTask(.ticketActivity)
    guard let token = tasks.token(for: .ticketActivity) else { return }
    tasks.finish(token)
  }

  func resetThreads() {
    planningThreadIDs.removeAll()
    ticketThreadIDs.removeAll()
    epicThreadIDs.removeAll()
  }

  func cancel(
    productID: UUID,
    interrupt: (CodexTurnIdentity) async -> Void
  ) async {
    await tasks.cancel(productID: productID)
    await turns.cancel(productID: productID, interrupt: interrupt)
    resetThreads()
  }

  func shutdown(interrupt: (CodexTurnIdentity) async -> Void) async {
    await tasks.shutdown()
    await turns.shutdown(interrupt: interrupt)
    resetThreads()
  }
}

@MainActor
final class SprintPlanningFeatureModel: ObservableObject {
  @Published var isSendingMessage = false
  @Published var isGeneratingGoal = false
}

@MainActor
final class EpicPlanningRuntime: ObservableObject {
  private enum Operation: Hashable {
    case planning
    case persistence
    case interruption
  }
  private let operations = FeatureOperationRegistry<Operation>()
  private(set) var threadID: String?
  @Published var conversation: EpicPlanningConversationState?

  var isBusy: Bool { operations.isActive(.planning) }
  var activeTurn: CodexTurnIdentity? { operations.turn(for: .planning) }

  func setThreadID(_ threadID: String?) {
    self.threadID = threadID
  }

  func start(
    productID: UUID,
    operation: @escaping @MainActor () async -> Void
  ) {
    operations.start(.planning, productID: productID, replacing: true) { _ in
      await operation()
    }
  }

  func recordTurn(threadID: String, turnID: String) {
    guard let token = operations.token(for: .planning) else { return }
    operations.recordTurn(CodexTurnIdentity(threadID: threadID, turnID: turnID), for: token)
  }

  func clearTurn() {
    guard let token = operations.token(for: .planning) else { return }
    operations.clearTurn(for: token)
  }

  func enqueuePersistence(
    productID: UUID,
    operation: @escaping @MainActor () async -> Void
  ) {
    operations.enqueue(.persistence, productID: productID) {
      await operation()
    }
  }

  func awaitPersistence() async {
    await operations.settle(.persistence)
  }

  func requestCancellation(
    interrupt: @escaping @MainActor (CodexTurnIdentity) async -> Void
  ) {
    operations.cancelTask(.planning)
    guard let turn = activeTurn else { return }
    operations.start(.interruption, productID: nil, replacing: true) { _ in
      await interrupt(turn)
    }
  }

  func cancel(
    productID: UUID,
    interrupt: (CodexTurnIdentity) async -> Void
  ) async {
    await operations.cancel(productID: productID, interrupt: interrupt)
    threadID = nil
  }

  func shutdown(interrupt: (CodexTurnIdentity) async -> Void) async {
    await operations.shutdown(interrupt: interrupt)
    threadID = nil
  }

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
  let launcher = MacOSDemoLauncher()
  var productsLaunchingPresentation: Set<UUID> = []
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
