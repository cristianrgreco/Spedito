import Foundation
import Testing
@testable import StoryPointlessCore

@Suite("Sprint work recovery")
struct SprintWorkRecoveryTests {
  @Test("A paused Tech Lead review is recovered without selecting an older integration run")
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

  @Test("An interrupted live permission decision recovers its paused run")
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
      status: .awaitingOwner,
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
      name: "Tech Lead",
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
