import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Product execution lifecycle")
struct ProductExecutionLifecycleTests {
  @Test("Switching products leaves every delivery scheduler running")
  func productSelectionDoesNotSuspendDelivery() {
    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .productSelectionChanged
      ) == .none
    )
  }

  @Test("Archiving stops only the archived product")
  func productArchivalHasProductScope() {
    let productID = UUID()

    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .productArchived(productID)
      ) == .product(productID)
    )
  }

  @Test("App shutdown stops delivery across products")
  func appShutdownHasGlobalScope() {
    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .appShutdown
      ) == .all
    )
  }

  /// Existing partial coverage:
  /// - `ProductExecutionLifecycleTests.appShutdownHasGlobalScope`
  /// - `FeatureOperationRegistryTests.scopedAndGlobalSettlement`
  /// This test covers only the previously missing bounded grace and Quit now composition.
  @Test("A10 bounded shutdown offers Quit now and expires deterministically")
  @MainActor
  func a10BoundedShutdownGraceAndQuitNow() async {
    let manualShutdown = ApplicationTerminationOperationGate()
    let manualGrace = ApplicationTerminationOperationGate()
    let manualOutcome = ApplicationTerminationOutcomeGate()
    var requestedGracePeriod: Duration?
    let manualCoordinator = ApplicationTerminationCoordinator(
      waitForGrace: { duration in
        requestedGracePeriod = duration
        await manualGrace.wait()
      }
    )

    let didBeginManualShutdown = manualCoordinator.begin(
      shutdown: { await manualShutdown.wait() },
      completion: { manualOutcome.record($0) }
    )
    #expect(didBeginManualShutdown)
    await manualShutdown.waitUntilStarted()
    await manualGrace.waitUntilStarted()
    #expect(requestedGracePeriod == ApplicationTerminationCoordinator.defaultGracePeriod)
    #expect(manualCoordinator.isPreparing)

    manualCoordinator.quitNow()

    #expect(await manualOutcome.wait() == .quitNow)
    #expect(manualCoordinator.outcome == .quitNow)
    manualShutdown.release()
    manualGrace.release()
    await manualShutdown.waitUntilFinished()
    await manualGrace.waitUntilFinished()

    let boundedShutdown = ApplicationTerminationOperationGate()
    let boundedGrace = ApplicationTerminationOperationGate()
    let boundedOutcome = ApplicationTerminationOutcomeGate()
    let boundedCoordinator = ApplicationTerminationCoordinator(
      waitForGrace: { _ in await boundedGrace.wait() }
    )

    let didBeginBoundedShutdown = boundedCoordinator.begin(
      shutdown: { await boundedShutdown.wait() },
      completion: { boundedOutcome.record($0) }
    )
    #expect(didBeginBoundedShutdown)
    await boundedShutdown.waitUntilStarted()
    await boundedGrace.waitUntilStarted()

    boundedGrace.release()

    #expect(await boundedOutcome.wait() == .gracePeriodElapsed)
    #expect(boundedCoordinator.outcome == .gracePeriodElapsed)
    boundedShutdown.release()
    await boundedShutdown.waitUntilFinished()
  }


  @Test("Business analyst can deliver a reviewed outcome without repository changes")
  func businessAnalystLocalOutcomePolicy() throws {
    #expect(
      try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: .businessAnalyst,
        changedPaths: []
      ) == .localOutcome
    )
    #expect(
      try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: .businessAnalyst,
        changedPaths: ["docs/recommendation.md"]
      ) == .repositoryChange
    )
  }

  @Test("Product-changing roles still require repository evidence")
  func productChangingRoleEvidencePolicy() {
    #expect(throws: TicketDeliveryEvidencePolicyError.self) {
      try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: .implementer,
        changedPaths: []
      )
    }
  }
  @Test("Ticket approval starts background completion without holding the detail view")
  @MainActor
  func ticketApprovalStartsInBackground() async {
    let model = AppModel(store: nil)
    let item = WorkItem(
      productID: UUID(),
      key: "T1",
      title: "Complete in the background",
      state: .acceptance
    )

    #expect(model.beginSprintTicketAcceptance(item))
    #expect(model.ticketAcceptanceInProgressWorkItemIDs == Set([item.id]))

    await Task.yield()

    #expect(model.ticketAcceptanceInProgressWorkItemIDs.isEmpty)
  }
}

@MainActor
private final class ApplicationTerminationOperationGate {
  private var didStart = false
  private var didFinish = false
  private var isReleased = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    didStart = true
    let currentStartWaiters = startWaiters
    startWaiters.removeAll()
    for waiter in currentStartWaiters {
      waiter.resume()
    }
    if !isReleased {
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    }
    didFinish = true
    let currentFinishWaiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in currentFinishWaiters {
      waiter.resume()
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func waitUntilFinished() async {
    guard !didFinish else { return }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

@MainActor
private final class ApplicationTerminationOutcomeGate {
  private var outcome: ApplicationTerminationOutcome?
  private var waiter: CheckedContinuation<ApplicationTerminationOutcome, Never>?

  func record(_ outcome: ApplicationTerminationOutcome) {
    self.outcome = outcome
    waiter?.resume(returning: outcome)
    waiter = nil
  }

  func wait() async -> ApplicationTerminationOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }
}
