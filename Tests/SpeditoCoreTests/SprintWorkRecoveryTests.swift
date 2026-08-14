import Foundation
import Testing

@testable import SpeditoCore

@Suite("Sprint work recovery")
struct SprintWorkRecoveryTests {
  @Test("A paused tech lead review is recovered without selecting an older integration run")
  func pausedReviewRunIsRecoverable() {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let workItemID = UUID()
    let implementerRunID = UUID()
    let techLeadID = UUID()
    let integrationPath = "/private/tmp/review-integration"
    let reviewStartedAt = Date()
    let candidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: implementerRunID,
      version: 1,
      branchName: "ticket/T8",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: "integrated",
      worktreePath: "/private/tmp/t8",
      integrationWorktreePath: integrationPath,
      status: .reviewing,
      commitCount: 1,
      executionResultJSON: "{}",
      updatedAt: reviewStartedAt
    )
    let completedIntegratorRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: techLeadID,
      status: .completed,
      worktreePath: integrationPath,
      createdAt: reviewStartedAt.addingTimeInterval(-2),
      updatedAt: reviewStartedAt.addingTimeInterval(-1)
    )
    let pausedReviewRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: techLeadID,
      status: .awaitingOwner,
      codexThreadID: "review-thread",
      worktreePath: integrationPath,
      createdAt: reviewStartedAt.addingTimeInterval(1),
      updatedAt: reviewStartedAt.addingTimeInterval(2)
    )

    let recovered = SprintWorkRecoveryPolicy().latestReviewRun(
      for: candidate,
      runs: [completedIntegratorRun, pausedReviewRun],
      reviewerProfileIDs: [techLeadID]
    )

    #expect(recovered?.id == pausedReviewRun.id)
    #expect(recovered?.codexThreadID == "review-thread")
  }

  @Test("A queued integrated review is recovered after restart")
  func queuedIntegratedReviewIsRecoverable() {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let workItemID = UUID()
    let techLeadID = UUID()
    let reviewStartedAt = Date()
    let reviewPath = "/private/tmp/t8-integrated-review"
    let candidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: UUID(),
      version: 1,
      branchName: "ticket/T8",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: "integrated",
      worktreePath: "/private/tmp/t8",
      integrationWorktreePath: reviewPath,
      status: .reviewing,
      commitCount: 1,
      executionResultJSON: "{}",
      updatedAt: reviewStartedAt
    )
    let queuedReviewRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: techLeadID,
      status: .queued,
      worktreePath: reviewPath,
      createdAt: reviewStartedAt.addingTimeInterval(1)
    )

    let recoveryPolicy = SprintWorkRecoveryPolicy()
    #expect(
      recoveryPolicy.latestReviewRun(
        for: candidate,
        runs: [queuedReviewRun],
        reviewerProfileIDs: [techLeadID]
      )?.id == queuedReviewRun.id
    )

    let unintegratedCandidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: candidate.implementationRunID,
      version: 1,
      branchName: candidate.branchName,
      baseSHA: candidate.baseSHA,
      headSHA: candidate.headSHA,
      worktreePath: candidate.worktreePath,
      integrationWorktreePath: reviewPath,
      status: .reviewing,
      commitCount: 1,
      executionResultJSON: "{}",
      updatedAt: reviewStartedAt
    )
    #expect(
      recoveryPolicy.latestReviewRun(
        for: unintegratedCandidate,
        runs: [queuedReviewRun],
        reviewerProfileIDs: [techLeadID]
      ) == nil
    )
  }

  @Test("A completed review run remains recoverable for an interrupted post-review handoff")
  func completedReviewRunIsRecoverable() {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let workItemID = UUID()
    let techLeadID = UUID()
    let reviewStartedAt = Date()
    let candidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: UUID(),
      version: 2,
      branchName: "ticket/T9",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: "integrated",
      worktreePath: "/private/tmp/t9",
      integrationWorktreePath: "/private/tmp/t9-integration",
      status: .reviewing,
      commitCount: 1,
      executionResultJSON: "{}",
      updatedAt: reviewStartedAt
    )
    let completedReviewRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: techLeadID,
      status: .completed,
      codexThreadID: "completed-review-thread",
      worktreePath: "/private/tmp/t9-integration",
      createdAt: reviewStartedAt.addingTimeInterval(1)
    )

    let recovered = SprintWorkRecoveryPolicy().latestReviewRun(
      for: candidate,
      runs: [completedReviewRun],
      reviewerProfileIDs: [techLeadID]
    )

    #expect(recovered?.id == completedReviewRun.id)
  }

  @Test("An interrupted tech lead run remains bound to its reviewing candidate")
  func interruptedReviewRunIsRecoverable() {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let workItemID = UUID()
    let techLeadID = UUID()
    let reviewStartedAt = Date()
    let integrationPath = "/private/tmp/t9-interrupted-integration"
    let candidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: UUID(),
      version: 3,
      branchName: "ticket/T9",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: "integrated",
      worktreePath: "/private/tmp/t9",
      integrationWorktreePath: integrationPath,
      status: .reviewing,
      commitCount: 1,
      executionResultJSON: "{}",
      updatedAt: reviewStartedAt
    )
    let interruptedReviewRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: techLeadID,
      status: .interrupted,
      codexThreadID: "interrupted-review-thread",
      worktreePath: integrationPath,
      createdAt: reviewStartedAt.addingTimeInterval(1)
    )

    let recovered = SprintWorkRecoveryPolicy().latestReviewRun(
      for: candidate,
      runs: [interruptedReviewRun],
      reviewerProfileIDs: [techLeadID]
    )

    #expect(recovered?.id == interruptedReviewRun.id)
    #expect(recovered?.codexThreadID == "interrupted-review-thread")
  }

  @Test("Review recovery rejects a mismatched workspace")
  func mismatchedReviewWorkspaceIsNotRecoverable() {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let workItemID = UUID()
    let techLeadID = UUID()
    let reviewStartedAt = Date()
    let candidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: UUID(),
      version: 1,
      branchName: "ticket/T10",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: "integrated",
      worktreePath: "/private/tmp/t10",
      integrationWorktreePath: "/private/tmp/t10-integration",
      status: .reviewing,
      commitCount: 1,
      executionResultJSON: "{}",
      updatedAt: reviewStartedAt
    )
    let unrelatedRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: techLeadID,
      status: .awaitingOwner,
      worktreePath: "/private/tmp/other-integration",
      createdAt: reviewStartedAt.addingTimeInterval(1)
    )

    let recovered = SprintWorkRecoveryPolicy().latestReviewRun(
      for: candidate,
      runs: [unrelatedRun],
      reviewerProfileIDs: [techLeadID]
    )

    #expect(recovered == nil)
  }

  @Test("An interrupted live permission decision recovers a run queued during shutdown")
  func interruptedPermissionDecisionIsRecoverable() {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let requestDate = Date()
    let run = AgentRun(
      id: runID,
      productID: productID,
      workItemID: workItemID,
      profileID: UUID(),
      status: .queued,
      updatedAt: requestDate.addingTimeInterval(-1)
    )
    let request = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn",
      serverRequestID: "request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "node tests.mjs",
      signature: "command|node tests.mjs",
      status: .interrupted,
      updatedAt: requestDate
    )

    let recovered = SprintWorkRecoveryPolicy().runsWithExpiredPermissionDecisions(
      runs: [run],
      permissionRequests: [request]
    )

    #expect(recovered.map(\.id) == [runID])
  }

  @Test("A later owner question is not mistaken for an expired permission decision")
  func laterOwnerQuestionIsNotPermissionRecovery() {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let requestDate = Date()
    let run = AgentRun(
      id: runID,
      productID: productID,
      workItemID: workItemID,
      profileID: UUID(),
      status: .awaitingOwner,
      updatedAt: requestDate.addingTimeInterval(1)
    )
    let request = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn",
      serverRequestID: "request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "node tests.mjs",
      signature: "command|node tests.mjs",
      status: .interrupted,
      updatedAt: requestDate
    )

    let recovered = SprintWorkRecoveryPolicy().runsWithExpiredPermissionDecisions(
      runs: [run],
      permissionRequests: [request]
    )

    #expect(recovered.isEmpty)
  }

  @Test("Only the current permission pause remains actionable after relaunch")
  func actionablePermissionRequestIsRunStateAware() {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let runUpdatedAt = Date()
    let run = AgentRun(
      id: runID,
      productID: productID,
      workItemID: workItemID,
      profileID: UUID(),
      status: .awaitingOwner,
      updatedAt: runUpdatedAt
    )
    let liveRequest = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn",
      serverRequestID: "live-request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "swift test",
      signature: "command|swift test",
      status: .pending,
      updatedAt: runUpdatedAt.addingTimeInterval(-1)
    )
    let recoveredRequest = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn",
      serverRequestID: "recovered-request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "swift test",
      signature: "command|swift test",
      status: .interrupted,
      updatedAt: runUpdatedAt.addingTimeInterval(1)
    )
    let staleRequest = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn",
      serverRequestID: "stale-request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "swift test",
      signature: "command|swift test",
      status: .interrupted,
      updatedAt: runUpdatedAt.addingTimeInterval(-1)
    )
    let policy = SprintWorkRecoveryPolicy()

    #expect(
      policy.actionablePermissionRequest(
        for: workItemID,
        runs: [run],
        permissionRequests: [liveRequest]
      )?.id == liveRequest.id
    )
    #expect(
      policy.actionablePermissionRequest(
        for: workItemID,
        runs: [run],
        permissionRequests: [recoveredRequest]
      )?.id == recoveredRequest.id
    )
    #expect(
      policy.actionablePermissionRequest(
        for: workItemID,
        runs: [run],
        permissionRequests: [staleRequest]
      ) == nil
    )
  }

  @Test("Recovery bookkeeping does not hide an interrupted permission decision")
  func recoveredPermissionRemainsActionableAfterRunMetadataUpdate() {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let activityDate = Date()
    let requestRecoveryDate = activityDate.addingTimeInterval(5)
    let run = AgentRun(
      id: runID,
      productID: productID,
      workItemID: workItemID,
      profileID: UUID(),
      status: .awaitingOwner,
      lastActivityAt: activityDate,
      updatedAt: requestRecoveryDate.addingTimeInterval(1)
    )
    let request = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn",
      serverRequestID: "recovered-request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "python3 -m http.server",
      signature: "command|python3 -m http.server",
      status: .interrupted,
      updatedAt: requestRecoveryDate
    )

    #expect(
      SprintWorkRecoveryPolicy().actionablePermissionRequest(
        for: workItemID,
        runs: [run],
        permissionRequests: [request]
      )?.id == request.id
    )
    #expect(
      SprintWorkRecoveryPolicy().runsWithExpiredPermissionDecisions(
        runs: [run],
        permissionRequests: [request]
      ).map(\.id) == [run.id]
    )
  }

  @Test("Permission continuation uses the latest reusable decision for the same run")
  func latestPermissionContinuationIsRunScoped() {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let olderAllowed = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn-1",
      serverRequestID: "request-1",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "swift test",
      signature: "command|swift test",
      status: .allowed,
      updatedAt: Date().addingTimeInterval(-2)
    )
    let latestInterrupted = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread",
      turnID: "turn-2",
      serverRequestID: "request-2",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Network access to example.com",
      signature: "permissions|example.com",
      status: .interrupted,
      updatedAt: Date().addingTimeInterval(-1)
    )
    let unrelated = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: UUID(),
      threadID: "other-thread",
      turnID: "other-turn",
      serverRequestID: "other-request",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "unrelated",
      signature: "command|unrelated",
      status: .allowed
    )

    let recovered = SprintWorkRecoveryPolicy().latestPermissionContinuation(
      for: runID,
      permissionRequests: [olderAllowed, unrelated, latestInterrupted]
    )

    #expect(recovered?.id == latestInterrupted.id)
  }

  @Test("App suspension preserves a permission pause while other work requeues")
  func implementationTurnStopDispositionPreservesOwnerIntent() {
    let policy = SprintWorkRecoveryPolicy()

    #expect(
      policy.implementationRunStatusAfterTurnStops(
        taskWasCancelled: true,
        wasManuallyStopped: false
      ) == .queued
    )
    #expect(
      policy.implementationRunStatusAfterTurnStops(
        taskWasCancelled: true,
        wasManuallyStopped: false,
        wasAwaitingPermission: true
      ) == .awaitingOwner
    )
    #expect(
      policy.implementationRunStatusAfterTurnStops(
        taskWasCancelled: false,
        wasManuallyStopped: true
      ) == .interrupted
    )
    #expect(
      policy.implementationRunStatusAfterTurnStops(
        taskWasCancelled: false,
        wasManuallyStopped: false
      ) == .failed
    )
  }

  @Test("A failed post-review demo can retry without repeating implementation")
  func failedPostReviewDemoIsRecoverable() throws {
    let fixture = try recoveryFixture()
    let candidate = SprintWorkRecoveryPolicy().failedPostReviewDemoCandidate(
      workItemID: fixture.item.id,
      workItems: [fixture.item],
      candidates: [fixture.candidate],
      runs: [fixture.implementationRun, fixture.reviewRun],
      profiles: [fixture.implementer, fixture.techLead]
    )

    #expect(candidate?.id == fixture.candidate.id)
  }

  @Test("An owner question or incomplete review is not treated as demo recovery")
  func ordinaryOwnerPauseIsNotDemoRecovery() throws {
    let fixture = try recoveryFixture()
    var unreviewedRun = fixture.reviewRun
    unreviewedRun.status = .failed

    let candidate = SprintWorkRecoveryPolicy().failedPostReviewDemoCandidate(
      workItemID: fixture.item.id,
      workItems: [fixture.item],
      candidates: [fixture.candidate],
      runs: [fixture.implementationRun, unreviewedRun],
      profiles: [fixture.implementer, fixture.techLead]
    )

    #expect(candidate == nil)
  }

  private func recoveryFixture() throws -> (
    item: WorkItem,
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewRun: AgentRun,
    implementer: AgentProfile,
    techLead: AgentProfile
  ) {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let item = WorkItem(
      productID: productID,
      key: "T49",
      title: "Fix the result",
      state: .running
    )
    let implementer = AgentProfile(
      productID: productID,
      name: "Implementer",
      role: .implementer
    )
    let techLead = AgentProfile(
      productID: productID,
      name: "Tech lead",
      role: .lead
    )
    let integrationPath = "/private/tmp/t49-integration"
    let implementationRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: item.id,
      profileID: implementer.id,
      status: .awaitingOwner,
      codexThreadID: "implementation-thread",
      worktreePath: "/private/tmp/t49"
    )
    let reviewRun = AgentRun(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: item.id,
      profileID: techLead.id,
      status: .completed,
      codexThreadID: "review-thread",
      worktreePath: integrationPath
    )
    let result = TicketExecutionResult(
      status: .completed,
      comment: "Implemented.",
      question: nil,
      options: [],
      summary: "The result is fixed.",
      changedFiles: ["Sources/App.swift"],
      tests: ["Targeted checks passed"],
      knowledgeNotes: [],
      reviewInstructions: ["Run the demo."],
      demo: DemoLaunchSpecification(
        title: "Result demo",
        launchCommand: DemoCommand(
          executable: "node",
          arguments: ["scripts/check.mjs"]
        ),
        presentation: DemoPresentation(kind: .commandOutput)
      ),
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let encodedResult = try JSONEncoder().encode(result)
    let candidate = CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: item.id,
      implementationRunID: implementationRun.id,
      version: 1,
      branchName: "ticket/T49",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: "integrated",
      worktreePath: "/private/tmp/t49",
      integrationWorktreePath: integrationPath,
      status: .failed,
      commitCount: 1,
      executionResultJSON: String(decoding: encodedResult, as: UTF8.self)
    )
    return (item, candidate, implementationRun, reviewRun, implementer, techLead)
  }
}
