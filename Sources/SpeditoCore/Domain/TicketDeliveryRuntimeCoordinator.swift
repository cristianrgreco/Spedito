import Foundation

public enum TicketDeliverySchedulerDisposition: Sendable {
  case continueImmediately
  case waitForWake
  case finished
}

public struct TicketDeliveryActiveTurn: Equatable, Sendable {
  public let runID: UUID
  public let productID: UUID
  public let threadID: String
  public let turnID: String

  public init(runID: UUID, productID: UUID, threadID: String, turnID: String) {
    self.runID = runID
    self.productID = productID
    self.threadID = threadID
    self.turnID = turnID
  }
}

public enum TicketDeliverySprintCancellationIntent: Equatable, Sendable {
  case pause
  case stop
}

public struct TicketDeliveryRuntimeSnapshot: Equatable, Sendable {
  public let scheduledProductIDs: Set<UUID>
  public let implementationRunIDs: Set<UUID>
  public let reviewCandidateIDs: Set<UUID>
  public let integrationCandidateIDs: Set<UUID>
  public let liveActivityRunIDs: Set<UUID>
  public let acceptanceWorkItemIDs: Set<UUID>

  public init(
    scheduledProductIDs: Set<UUID>,
    reviewCandidateIDs: Set<UUID>,
    implementationRunIDs: Set<UUID>,
    integrationCandidateIDs: Set<UUID>,
    liveActivityRunIDs: Set<UUID>,
    acceptanceWorkItemIDs: Set<UUID>
  ) {
    self.scheduledProductIDs = scheduledProductIDs
    self.reviewCandidateIDs = reviewCandidateIDs
    self.implementationRunIDs = implementationRunIDs
    self.integrationCandidateIDs = integrationCandidateIDs
    self.liveActivityRunIDs = liveActivityRunIDs
    self.acceptanceWorkItemIDs = acceptanceWorkItemIDs
  }
}

public enum TicketDeliveryCapacityPolicy {
  public static func constraint(
    from snapshot: CodexRateLimitsSnapshot?,
    isObservationStale: Bool,
    durableRuns: [AgentRun],
    observedAt: Date = Date()
  ) -> AgentRunExecutionConstraint? {
    if !isObservationStale,
      let reachedLimitType = snapshot?.reachedLimitType?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !reachedLimitType.isEmpty
    {
      let normalizedType = reachedLimitType.lowercased()
      let kind: AgentRunExecutionConstraintKind =
        normalizedType.contains("safety") || normalizedType.contains("back")
        ? .safetyBackPressure
        : .accountRateLimit
      let retryAt = snapshot?.nextResetAt
      if let existing = durableRuns
        .compactMap(\.executionConstraint)
        .first(where: {
          $0.kind == kind
            && $0.retryAt == retryAt
            && $0.technicalEvidence == reachedLimitType
        })
      {
        return existing
      }
      return AgentRunExecutionConstraint(
        kind: kind,
        observedAt: observedAt,
        retryAt: retryAt,
        technicalEvidence: reachedLimitType
      )
    }

    guard snapshot == nil || isObservationStale else { return nil }
    return durableRuns
      .compactMap(\.executionConstraint)
      .max { $0.observedAt < $1.observedAt }
  }
}

@MainActor
public final class TicketDeliveryRuntimeCoordinator {
  public typealias SchedulerPreparation = @MainActor (UUID) async -> Void
  public typealias IdentifiedOperation = @MainActor (UUID) async -> Void
  public typealias SchedulerDrain =
    @MainActor (UUID) async -> TicketDeliverySchedulerDisposition
  public typealias Operation = @MainActor () async -> Void
  public typealias AcceptanceObserver = @MainActor (Set<UUID>) -> Void

  private struct ScheduledProduct {
    let id: UUID
    let task: Task<Void, Never>
    let wakeContinuation: AsyncStream<Void>.Continuation
    var wakeVersion: UInt64
  }

  private struct ChildOperation {
    let id: UUID
    let productID: UUID
    let task: Task<Void, Never>
  }

  private let prepareScheduler: SchedulerPreparation
  private let drainScheduler: SchedulerDrain
  private let onAcceptanceChange: AcceptanceObserver

  private var scheduledProducts: [UUID: ScheduledProduct] = [:]
  private var reviewTasks: [UUID: ChildOperation] = [:]
  private var implementationTasks: [UUID: ChildOperation] = [:]
  private var integrationTasks: [UUID: ChildOperation] = [:]
  private var liveActivityTasks: [UUID: ChildOperation] = [:]
  private var activeTurns: [UUID: TicketDeliveryActiveTurn] = [:]
  private var manuallyStoppedRunIDs: Set<UUID> = []
  private var liveApprovalRequests: [UUID: (productID: UUID, request: CodexServerRequest)] = [:]
  private var sprintCancellationIntents: [UUID: TicketDeliverySprintCancellationIntent] = [:]
  private var acceptanceTasks: [UUID: ChildOperation] = [:]
  private var allCancellationDepth = 0
  private var productCancellationDepths: [UUID: Int] = [:]

  public init(
    prepareScheduler: @escaping SchedulerPreparation,
    drainScheduler: @escaping SchedulerDrain,
    onAcceptanceChange: @escaping AcceptanceObserver = { _ in }
  ) {
    self.prepareScheduler = prepareScheduler
    self.drainScheduler = drainScheduler
    self.onAcceptanceChange = onAcceptanceChange
  }

  public func snapshot() -> TicketDeliveryRuntimeSnapshot {
    TicketDeliveryRuntimeSnapshot(
      scheduledProductIDs: Set(scheduledProducts.keys),
      reviewCandidateIDs: Set(reviewTasks.keys),
      implementationRunIDs: Set(implementationTasks.keys),
      integrationCandidateIDs: Set(integrationTasks.keys),
      liveActivityRunIDs: Set(liveActivityTasks.keys),
      acceptanceWorkItemIDs: Set(acceptanceTasks.keys)
    )
  }

  public var isBusy: Bool {
    allCancellationDepth > 0
      || !productCancellationDepths.isEmpty
      || !scheduledProducts.isEmpty
      || !reviewTasks.isEmpty
      || !implementationTasks.isEmpty
      || !integrationTasks.isEmpty
      || !liveActivityTasks.isEmpty
      || !liveApprovalRequests.isEmpty
      || !activeTurns.isEmpty
      || !acceptanceTasks.isEmpty
  }

  public func hasActiveWork(productID: UUID) -> Bool {
    allCancellationDepth > 0
      || productCancellationDepths[productID, default: 0] > 0
      || scheduledProducts[productID] != nil
      || reviewTasks.values.contains { $0.productID == productID }
      || implementationTasks.values.contains { $0.productID == productID }
      || integrationTasks.values.contains { $0.productID == productID }
      || liveActivityTasks.values.contains { $0.productID == productID }
      || liveApprovalRequests.values.contains { $0.productID == productID }
      || activeTurns.values.contains { $0.productID == productID }
      || acceptanceTasks.values.contains { $0.productID == productID }
  }

  public func hasActiveImplementation(productID: UUID) -> Bool {
    implementationTasks.values.contains { $0.productID == productID }
  }

  public func hasActiveIntegration(productID: UUID) -> Bool {
    integrationTasks.values.contains { $0.productID == productID }
  }

  public func isReviewInProgress(candidateID: UUID) -> Bool {
    reviewTasks[candidateID] != nil
  }

  public func isIntegrationInProgress(candidateID: UUID) -> Bool {
    integrationTasks[candidateID] != nil
  }

  public func isLiveActivityCurrent(runID: UUID, monitorID: UUID) -> Bool {
    liveActivityTasks[runID]?.id == monitorID
  }

  public func liveActivityRunIDs(productID: UUID? = nil) -> Set<UUID> {
    Set(
      liveActivityTasks.compactMap { runID, operation in
        productID == nil || operation.productID == productID ? runID : nil
      }
    )
  }

  public func registerActiveTurn(
    runID: UUID,
    productID: UUID,
    threadID: String,
    turnID: String
  ) {
    activeTurns[runID] = TicketDeliveryActiveTurn(
      runID: runID,
      productID: productID,
      threadID: threadID,
      turnID: turnID
    )
  }

  public func activeTurn(runID: UUID) -> TicketDeliveryActiveTurn? {
    activeTurns[runID]
  }

  public func activeTurns(productID: UUID? = nil) -> [TicketDeliveryActiveTurn] {
    activeTurns.values.filter { productID == nil || $0.productID == productID }
  }

  public func activeTurn(threadID: String, turnID: String) -> TicketDeliveryActiveTurn? {
    activeTurns.values.first {
      $0.threadID == threadID && $0.turnID == turnID
    }
  }

  public func removeActiveTurn(runID: UUID) {
    activeTurns.removeValue(forKey: runID)
  }

  public func registerLiveApprovalRequest(
    id: UUID,
    productID: UUID,
    request: CodexServerRequest
  ) {
    liveApprovalRequests[id] = (productID: productID, request: request)
  }

  public func liveApprovalRequest(id: UUID) -> CodexServerRequest? {
    liveApprovalRequests[id]?.request
  }

  public func liveApprovalRequestProductID(id: UUID) -> UUID? {
    liveApprovalRequests[id]?.productID
  }

  public func liveApprovalRequestIDs(productID: UUID? = nil) -> [UUID] {
    liveApprovalRequests.compactMap { id, approval in
      productID == nil || approval.productID == productID ? id : nil
    }
  }

  public func removeLiveApprovalRequest(id: UUID) {
    liveApprovalRequests.removeValue(forKey: id)
  }

  public func markManuallyStopped(runID: UUID) {
    manuallyStoppedRunIDs.insert(runID)
  }

  public func clearManuallyStopped(runID: UUID) {
    manuallyStoppedRunIDs.remove(runID)
  }

  public func consumeManuallyStopped(runID: UUID) -> Bool {
    manuallyStoppedRunIDs.remove(runID) != nil
  }

  public func beginSprintCancellation(
    productID: UUID,
    intent: TicketDeliverySprintCancellationIntent
  ) {
    sprintCancellationIntents[productID] = intent
  }

  public func endSprintCancellation(
    productID: UUID,
    intent: TicketDeliverySprintCancellationIntent
  ) {
    guard sprintCancellationIntents[productID] == intent else { return }
    sprintCancellationIntents.removeValue(forKey: productID)
  }

  public func sprintCancellationIntent(
    productID: UUID
  ) -> TicketDeliverySprintCancellationIntent? {
    sprintCancellationIntents[productID]
  }

  public func isAcceptanceInProgress(workItemID: UUID) -> Bool {
    acceptanceTasks[workItemID] != nil
  }

  public func acceptanceWorkItemIDs(productID: UUID? = nil) -> Set<UUID> {
    Set(
      acceptanceTasks.compactMap { workItemID, operation in
        productID == nil || operation.productID == productID ? workItemID : nil
      }
    )
  }

  public func schedule(productID: UUID) {
    guard
      allCancellationDepth == 0,
      productCancellationDepths[productID, default: 0] == 0
    else { return }
    if var scheduled = scheduledProducts[productID] {
      scheduled.wakeVersion &+= 1
      scheduledProducts[productID] = scheduled
      scheduled.wakeContinuation.yield()
      return
    }

    let schedulerID = UUID()
    let (wakeStream, wakeContinuation) = AsyncStream<Void>.makeStream()
    let task = Task { [weak self] in
      guard let self else { return }
      await prepareScheduler(productID)
      var wakeIterator = wakeStream.makeAsyncIterator()
      var observedWakeVersion: UInt64 = 0
      while !Task.isCancelled {
        let disposition = await drainScheduler(productID)
        guard let scheduled = scheduledProducts[productID], scheduled.id == schedulerID else {
          return
        }
        if scheduled.wakeVersion != observedWakeVersion {
          observedWakeVersion = scheduled.wakeVersion
          continue
        }
        switch disposition {
        case .continueImmediately:
          continue
        case .waitForWake:
          guard await wakeIterator.next() != nil else {
            schedulerFinished(productID: productID, schedulerID: schedulerID)
            return
          }
          guard let scheduled = scheduledProducts[productID], scheduled.id == schedulerID else {
            return
          }
          observedWakeVersion = scheduled.wakeVersion
        case .finished:
          schedulerFinished(productID: productID, schedulerID: schedulerID)
          return
        }
      }
      schedulerFinished(productID: productID, schedulerID: schedulerID)
    }
    scheduledProducts[productID] = ScheduledProduct(
      id: schedulerID,
      task: task,
      wakeContinuation: wakeContinuation,
      wakeVersion: 0
    )
  }

  @discardableResult
  public func startImplementation(
    runID: UUID,
    productID: UUID,
    operation: @escaping Operation
  ) -> Bool {
    startChild(
      key: runID,
      productID: productID,
      tasks: &implementationTasks,
      operation: operation,
      completion: { [weak self] operationID in
        self?.implementationFinished(runID: runID, operationID: operationID)
      }
    )
  }

  @discardableResult
  public func startReview(
    candidateID: UUID,
    productID: UUID,
    operation: @escaping Operation
  ) -> Bool {
    startChild(
      key: candidateID,
      productID: productID,
      tasks: &reviewTasks,
      operation: operation,
      completion: { [weak self] operationID in
        self?.reviewFinished(candidateID: candidateID, operationID: operationID)
      }
    )
  }

  @discardableResult
  public func startIntegration(
    candidateID: UUID,
    productID: UUID,
    operation: @escaping Operation
  ) -> Bool {
    startChild(
      key: candidateID,
      productID: productID,
      tasks: &integrationTasks,
      operation: operation,
      completion: { [weak self] operationID in
        self?.integrationFinished(candidateID: candidateID, operationID: operationID)
      }
    )
  }

  @discardableResult
  public func startLiveActivity(
    runID: UUID,
    productID: UUID,
    operation: @escaping IdentifiedOperation
  ) -> UUID? {
    guard liveActivityTasks[runID] == nil else { return nil }
    let monitorID = UUID()
    let task = Task { [weak self] in
      await operation(monitorID)
      self?.liveActivityFinished(runID: runID, monitorID: monitorID)
    }
    liveActivityTasks[runID] = ChildOperation(
      id: monitorID,
      productID: productID,
      task: task
    )
    return monitorID
  }

  public func stopLiveActivity(runID: UUID) {
    liveActivityTasks.removeValue(forKey: runID)?.task.cancel()
  }

  @discardableResult
  public func startAcceptance(
    workItemID: UUID,
    productID: UUID,
    operation: @escaping Operation
  ) -> Bool {
    let started = startChild(
      key: workItemID,
      productID: productID,
      tasks: &acceptanceTasks,
      operation: operation,
      completion: { [weak self] operationID in
        self?.acceptanceFinished(workItemID: workItemID, operationID: operationID)
      }
    )
    if started {
      publishAcceptanceState()
    }
    return started
  }

  public func cancel(
    productID: UUID? = nil,
    afterCancelling: @escaping Operation = {}
  ) async {
    beginCancellation(productID: productID)
    defer { endCancellation(productID: productID) }
    let turnsToSettle = activeTurns(productID: productID)
    let schedulers = detachSchedulers(productID: productID)
    let implementations = detachChildren(from: &implementationTasks, productID: productID)
    let reviews = detachChildren(from: &reviewTasks, productID: productID)
    let integrations = detachChildren(from: &integrationTasks, productID: productID)
    let liveActivities = detachChildren(from: &liveActivityTasks, productID: productID)
    let acceptances = detachChildren(from: &acceptanceTasks, productID: productID)
    if !acceptances.isEmpty {
      publishAcceptanceState()
    }

    for scheduler in schedulers {
      scheduler.wakeContinuation.finish()
      scheduler.task.cancel()
    }
    let children = reviews + implementations + integrations + liveActivities + acceptances
    for child in children {
      child.task.cancel()
    }

    await afterCancelling()

    for scheduler in schedulers {
      await scheduler.task.value
    }
    for child in children {
      await child.task.value
    }
    for turn in turnsToSettle where activeTurns[turn.runID] == turn {
      activeTurns.removeValue(forKey: turn.runID)
    }
  }

  private func startChild(
    key: UUID,
    productID: UUID,
    tasks: inout [UUID: ChildOperation],
    operation: @escaping Operation,
    completion: @escaping @MainActor (UUID) -> Void
  ) -> Bool {
    guard tasks[key] == nil else { return false }
    let operationID = UUID()
    let task = Task {
      await operation()
      completion(operationID)
    }
    tasks[key] = ChildOperation(id: operationID, productID: productID, task: task)
    return true
  }

  private func schedulerFinished(productID: UUID, schedulerID: UUID) {
    guard scheduledProducts[productID]?.id == schedulerID else { return }
    scheduledProducts.removeValue(forKey: productID)?.wakeContinuation.finish()
  }

  private func implementationFinished(runID: UUID, operationID: UUID) {
    guard implementationTasks[runID]?.id == operationID else { return }
    let productID = implementationTasks.removeValue(forKey: runID)?.productID
    if let productID {
      scheduledProducts[productID]?.wakeContinuation.yield()
    }
  }

  private func reviewFinished(candidateID: UUID, operationID: UUID) {
    guard reviewTasks[candidateID]?.id == operationID else { return }
    let productID = reviewTasks.removeValue(forKey: candidateID)?.productID
    if let productID {
      scheduledProducts[productID]?.wakeContinuation.yield()
    }
  }

  private func integrationFinished(candidateID: UUID, operationID: UUID) {
    guard integrationTasks[candidateID]?.id == operationID else { return }
    let productID = integrationTasks.removeValue(forKey: candidateID)?.productID
    if let productID {
      scheduledProducts[productID]?.wakeContinuation.yield()
    }
  }

  private func liveActivityFinished(runID: UUID, monitorID: UUID) {
    guard liveActivityTasks[runID]?.id == monitorID else { return }
    liveActivityTasks.removeValue(forKey: runID)
  }

  private func acceptanceFinished(workItemID: UUID, operationID: UUID) {
    guard acceptanceTasks[workItemID]?.id == operationID else { return }
    acceptanceTasks.removeValue(forKey: workItemID)
    publishAcceptanceState()
  }

  private func detachSchedulers(productID: UUID?) -> [ScheduledProduct] {
    let productIDs = scheduledProducts.keys.filter { productID == nil || $0 == productID }
    return productIDs.compactMap { scheduledProducts.removeValue(forKey: $0) }
  }

  private func detachChildren(
    from tasks: inout [UUID: ChildOperation],
    productID: UUID?
  ) -> [ChildOperation] {
    let keys = tasks.compactMap { key, operation in
      productID == nil || operation.productID == productID ? key : nil
    }
    return keys.compactMap { tasks.removeValue(forKey: $0) }
  }

  private func beginCancellation(productID: UUID?) {
    if let productID {
      productCancellationDepths[productID, default: 0] += 1
    } else {
      allCancellationDepth += 1
    }
  }

  private func endCancellation(productID: UUID?) {
    if let productID {
      let remaining = productCancellationDepths[productID, default: 0] - 1
      if remaining > 0 {
        productCancellationDepths[productID] = remaining
      } else {
        productCancellationDepths.removeValue(forKey: productID)
      }
    } else {
      allCancellationDepth -= 1
    }
  }

  private func publishAcceptanceState() {
    onAcceptanceChange(Set(acceptanceTasks.keys))
  }
}
