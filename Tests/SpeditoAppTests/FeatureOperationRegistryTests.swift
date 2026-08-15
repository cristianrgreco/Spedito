import Combine
import Foundation
import Testing

@testable import SpeditoApp

@MainActor
private final class OperationGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      if isOpen {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

@Suite("Feature operation registry")
@MainActor
struct FeatureOperationRegistryTests {
  @Test("Duplicate admission is rejected and replacement completion is identity safe")
  func duplicateAdmissionAndStaleCompletion() async {
    let registry = FeatureOperationRegistry<String>()
    let firstStarted = OperationGate()
    let releaseFirst = OperationGate()
    let secondStarted = OperationGate()
    let releaseSecond = OperationGate()

    let firstToken = registry.start("feature", productID: UUID()) { _ in
      firstStarted.open()
      await releaseFirst.wait()
    }
    #expect(firstToken != nil)
    await firstStarted.wait()

    let duplicate = registry.start("feature", productID: UUID()) { _ in
      Issue.record("A duplicate operation must not start")
    }
    #expect(duplicate == nil)

    let replacementToken = registry.start(
      "feature",
      productID: UUID(),
      replacing: true
    ) { _ in
      secondStarted.open()
      await releaseSecond.wait()
    }
    #expect(replacementToken != nil)

    releaseFirst.open()
    await secondStarted.wait()
    if let replacementToken {
      #expect(registry.isCurrent(replacementToken))
    }

    releaseSecond.open()
    await registry.shutdown()
    #expect(!registry.isBusy)
  }

  @Test("Focused feature state invalidates the application presentation")
  func focusedStateInvalidatesApplicationPresentation() {
    let model = AppModel(store: nil)
    var changeCount = 0
    let observation = model.objectWillChange.sink {
      changeCount += 1
    }

    model.planningConversationRuntime.isTicketMessageRunning = true
    model.sprintPlanningFeature.isGeneratingGoal = true
    model.retrospectiveSynthesisRuntime.notes = []
    model.codexConnectionRuntime.models = []
    model.selectedProductID = UUID()

    #expect(changeCount == 5)
    withExtendedLifetime(observation) {}
  }

  @Test("Explicit settlement waits for every admitted operation")
  func explicitSettlement() async {
    let registry = FeatureOperationRegistry<String>()
    let started = OperationGate()
    let release = OperationGate()
    let settled = OperationGate()

    _ = registry.start("owner-command", productID: UUID()) { _ in
      started.open()
      await release.wait()
    }
    await started.wait()

    let settlement = Task { @MainActor in
      await registry.settleAll()
      settled.open()
    }
    #expect(registry.isBusy)

    release.open()
    await settled.wait()
    await settlement.value
    #expect(!registry.isBusy)
  }

  @Test("Product cancellation and global shutdown await operation settlement")
  func scopedAndGlobalSettlement() async {
    let registry = FeatureOperationRegistry<String>()
    let firstProductID = UUID()
    let secondProductID = UUID()
    let releaseFirst = OperationGate()
    let releaseSecond = OperationGate()
    let firstInterrupted = OperationGate()
    let secondInterrupted = OperationGate()

    let firstToken = registry.start("first", productID: firstProductID) { _ in
      await releaseFirst.wait()
    }
    let secondToken = registry.start("second", productID: secondProductID) { _ in
      await releaseSecond.wait()
    }
    #expect(firstToken != nil)
    #expect(secondToken != nil)
    if let firstToken {
      registry.recordTurn(
        CodexTurnIdentity(threadID: "first-thread", turnID: "first-turn"),
        for: firstToken
      )
    }
    if let secondToken {
      registry.recordTurn(
        CodexTurnIdentity(threadID: "second-thread", turnID: "second-turn"),
        for: secondToken
      )
    }

    let scopedCancellation = Task { @MainActor in
      await registry.cancel(productID: firstProductID) { turn in
        #expect(turn.threadID == "first-thread")
        firstInterrupted.open()
      }
    }
    await firstInterrupted.wait()
    #expect(registry.isActive("first"))
    #expect(registry.isActive("second"))

    releaseFirst.open()
    await scopedCancellation.value
    #expect(!registry.isActive("first"))
    #expect(registry.isActive("second"))

    let shutdown = Task { @MainActor in
      await registry.shutdown { turn in
        #expect(turn.threadID == "second-thread")
        secondInterrupted.open()
      }
    }
    await secondInterrupted.wait()
    #expect(registry.isActive("second"))

    releaseSecond.open()
    await shutdown.value
    #expect(!registry.isBusy)
  }
  @Test("Product Chat exposes active response threads until explicit settlement")
  func productConversationResponsesRemainDiscoverable() async {
    let runtime = ProductConversationRuntime()
    let productID = UUID()
    let threadID = UUID()
    let started = OperationGate()
    let release = OperationGate()

    #expect(
      runtime.start(.response(threadID), productID: productID) { _ in
        started.open()
        await release.wait()
      }
    )
    await started.wait()

    #expect(runtime.activeResponseThreadIDs(productID: productID) == [threadID])
    #expect(runtime.activeResponseThreadIDs(productID: UUID()).isEmpty)

    release.open()
    await runtime.cancel(
      productID: productID,
      interrupt: { _ in },
      markCancelled: { _, _ in }
    )
    #expect(runtime.activeResponseThreadIDs(productID: productID).isEmpty)
  }

}
