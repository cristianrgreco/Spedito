import Foundation
import Testing

@testable import SpeditoCore

@Suite("Ticket delivery runtime coordinator", .serialized)
@MainActor
struct TicketDeliveryRuntimeCoordinatorTests {
  @Test("Duplicate scheduling wakes the existing product scheduler")
  func duplicateSchedulingWakesExistingScheduler() async {
    let productID = UUID()
    var preparationCount = 0
    let probe = DeliverySchedulerProbe()
    let coordinator = TicketDeliveryRuntimeCoordinator(
      prepareScheduler: { _ in preparationCount += 1 },
      drainScheduler: { productID in
        probe.recordDrain(productID: productID)
        return .waitForWake
      }
    )

    coordinator.schedule(productID: productID)
    await probe.waitForDrain(productID: productID, count: 1)
    coordinator.schedule(productID: productID)
    await probe.waitForDrain(productID: productID, count: 2)

    let snapshot = coordinator.snapshot()
    #expect(snapshot.scheduledProductIDs == Set([productID]))
    #expect(probe.drainCount(productID: productID) == 2)
    #expect(preparationCount == 1)
    await coordinator.cancel()
  }

  @Test("Cancelling one product leaves another product running")
  func productCancellationIsIsolated() async {
    let firstProductID = UUID()
    let secondProductID = UUID()
    let firstRunID = UUID()
    let secondRunID = UUID()
    let gate = DeliveryOperationGate()
    let coordinator = makeIdleCoordinator()
    coordinator.registerActiveTurn(
      runID: firstRunID,
      productID: firstProductID,
      threadID: "first-thread",
      turnID: "first-turn"
    )
    coordinator.registerActiveTurn(
      runID: secondRunID,
      productID: secondProductID,
      threadID: "second-thread",
      turnID: "second-turn"
    )

    #expect(
      coordinator.startImplementation(runID: firstRunID, productID: firstProductID) {
        await gate.run(label: "first", releasesOnCancellation: true)
      }
    )
    #expect(
      coordinator.startImplementation(runID: secondRunID, productID: secondProductID) {
        await gate.run(label: "second", releasesOnCancellation: true)
      }
    )
    await gate.waitUntilReady(label: "first")
    await gate.waitUntilReady(label: "second")

    await coordinator.cancel(productID: firstProductID)

    #expect(gate.didFinish(label: "first"))
    #expect(gate.wasCancelled(label: "first"))
    #expect(!gate.wasCancelled(label: "second"))
    #expect(coordinator.snapshot().implementationRunIDs == Set([secondRunID]))
    #expect(coordinator.activeTurn(runID: firstRunID) == nil)
    #expect(coordinator.activeTurn(runID: secondRunID)?.productID == secondProductID)
    await coordinator.cancel(productID: secondProductID)
  }

  @Test("Cancellation awaits implementation, review, live activity, integration, and acceptance")
  func cancellationSettlesEveryChild() async {
    let productID = UUID()
    let runID = UUID()
    let monitorRunID = UUID()
    let candidateID = UUID()
    let reviewCandidateID = UUID()
    let workItemID = UUID()
    let gate = DeliveryOperationGate()
    var acceptanceStates: [Set<UUID>] = []
    let coordinator = TicketDeliveryRuntimeCoordinator(
      prepareScheduler: { _ in },
      drainScheduler: { _ in .finished },
      onAcceptanceChange: { acceptanceStates.append($0) }
    )

    #expect(
      coordinator.startImplementation(runID: runID, productID: productID) {
        await gate.run(label: "implementation", releasesOnCancellation: true)
      }
    )
    #expect(
      coordinator.startReview(candidateID: reviewCandidateID, productID: productID) {
        await gate.run(label: "review", releasesOnCancellation: true)
      }
    )
    #expect(
      coordinator.startIntegration(candidateID: candidateID, productID: productID) {
        await gate.run(label: "integration", releasesOnCancellation: true)
      }
    )
    #expect(
      coordinator.startLiveActivity(runID: monitorRunID, productID: productID) { _ in
        await gate.run(label: "live activity", releasesOnCancellation: true)
      } != nil
    )
    #expect(
      coordinator.startAcceptance(workItemID: workItemID, productID: productID) {
        await gate.run(label: "acceptance", releasesOnCancellation: true)
      }
    )
    await gate.waitUntilReady(label: "implementation")
    await gate.waitUntilReady(label: "review")
    await gate.waitUntilReady(label: "integration")
    await gate.waitUntilReady(label: "live activity")
    await gate.waitUntilReady(label: "acceptance")

    await coordinator.cancel(productID: productID)

    #expect(gate.didFinish(label: "implementation"))
    #expect(gate.didFinish(label: "review"))
    #expect(gate.didFinish(label: "integration"))
    #expect(gate.didFinish(label: "live activity"))
    #expect(gate.didFinish(label: "acceptance"))
    #expect(coordinator.snapshot().implementationRunIDs.isEmpty)
    #expect(coordinator.snapshot().reviewCandidateIDs.isEmpty)
    #expect(coordinator.snapshot().integrationCandidateIDs.isEmpty)
    #expect(coordinator.snapshot().liveActivityRunIDs.isEmpty)
    #expect(coordinator.snapshot().acceptanceWorkItemIDs.isEmpty)
    #expect(acceptanceStates == [Set([workItemID]), []])
  }

  @Test("A stale completion cannot clear replacement task state")
  func staleCompletionCannotClearReplacement() async {
    let productID = UUID()
    let runID = UUID()
    let gate = DeliveryOperationGate()
    let coordinator = makeIdleCoordinator()
    coordinator.registerActiveTurn(
      runID: runID,
      productID: productID,
      threadID: "stale-thread",
      turnID: "stale-turn"
    )

    #expect(
      coordinator.startImplementation(runID: runID, productID: productID) {
        await gate.run(label: "stale", releasesOnCancellation: false)
      }
    )
    await gate.waitUntilReady(label: "stale")

    let cancellation = Task {
      await coordinator.cancel(productID: productID)
    }
    await gate.waitUntilCancelled(label: "stale")
    coordinator.registerActiveTurn(
      runID: runID,
      productID: productID,
      threadID: "replacement-thread",
      turnID: "replacement-turn"
    )
    #expect(
      coordinator.startImplementation(runID: runID, productID: productID) {
        await gate.run(label: "replacement", releasesOnCancellation: true)
      }
    )
    await gate.waitUntilReady(label: "replacement")

    gate.release(label: "stale")
    await cancellation.value

    #expect(coordinator.snapshot().implementationRunIDs == Set([runID]))
    #expect(coordinator.activeTurn(runID: runID)?.turnID == "replacement-turn")
    #expect(!gate.wasCancelled(label: "replacement"))
    await coordinator.cancel(productID: productID)
  }

  private func makeIdleCoordinator() -> TicketDeliveryRuntimeCoordinator {
    TicketDeliveryRuntimeCoordinator(
      prepareScheduler: { _ in },
      drainScheduler: { _ in .finished }
    )
  }
}

@MainActor
private final class DeliverySchedulerProbe {
  private struct WaitKey: Hashable {
    let productID: UUID
    let count: Int
  }

  private var counts: [UUID: Int] = [:]
  private var waiters: [WaitKey: CheckedContinuation<Void, Never>] = [:]

  func recordDrain(productID: UUID) {
    counts[productID, default: 0] += 1
    let key = WaitKey(productID: productID, count: counts[productID, default: 0])
    waiters.removeValue(forKey: key)?.resume()
  }

  func drainCount(productID: UUID) -> Int {
    counts[productID, default: 0]
  }

  func waitForDrain(productID: UUID, count: Int) async {
    guard drainCount(productID: productID) < count else { return }
    await withCheckedContinuation { continuation in
      waiters[WaitKey(productID: productID, count: count)] = continuation
    }
  }
}

@MainActor
private final class DeliveryOperationGate {
  private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
  private var readyLabels: Set<String> = []
  private var cancelledLabels: Set<String> = []
  private var finishedLabels: Set<String> = []
  private var releaseOnCancellationLabels: Set<String> = []
  private var readyWaiters: [String: CheckedContinuation<Void, Never>] = [:]
  private var cancellationWaiters: [String: CheckedContinuation<Void, Never>] = [:]

  func run(label: String, releasesOnCancellation: Bool) async {
    if releasesOnCancellation {
      releaseOnCancellationLabels.insert(label)
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        continuations[label] = continuation
        readyLabels.insert(label)
        readyWaiters.removeValue(forKey: label)?.resume()
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.recordCancellation(label: label)
      }
    }
    finishedLabels.insert(label)
  }

  func waitUntilReady(label: String) async {
    guard !readyLabels.contains(label) else { return }
    await withCheckedContinuation { continuation in
      readyWaiters[label] = continuation
    }
  }

  func waitUntilCancelled(label: String) async {
    guard !cancelledLabels.contains(label) else { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters[label] = continuation
    }
  }

  func release(label: String) {
    continuations.removeValue(forKey: label)?.resume()
  }

  func wasCancelled(label: String) -> Bool {
    cancelledLabels.contains(label)
  }

  func didFinish(label: String) -> Bool {
    finishedLabels.contains(label)
  }

  private func recordCancellation(label: String) {
    cancelledLabels.insert(label)
    cancellationWaiters.removeValue(forKey: label)?.resume()
    if releaseOnCancellationLabels.contains(label) {
      release(label: label)
    }
  }
}
