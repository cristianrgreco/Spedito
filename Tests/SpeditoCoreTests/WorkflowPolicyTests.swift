import Foundation
import Testing

@testable import SpeditoCore

@Suite("Workflow policy")
struct WorkflowPolicyTests {
  private let policy = WorkflowPolicy()

  @Test("Epic progress is derived from its active tickets")
  func epicProgress() {
    let productID = UUID()
    let epicID = UUID()

    #expect(EpicProgress(tickets: []).title == "Created")
    #expect(
      EpicProgress(
        tickets: [
          WorkItem(
            productID: productID,
            key: "T1",
            title: "Plan delivery",
            state: .refining,
            epicID: epicID
          )
        ]
      ) == .planned
    )
    #expect(
      EpicProgress(
        tickets: [
          WorkItem(
            productID: productID,
            key: "T1",
            title: "Deliver the outcome",
            state: .running,
            epicID: epicID
          ),
          WorkItem(
            productID: productID,
            key: "T2",
            title: "Verify the outcome",
            state: .ready,
            epicID: epicID
          ),
        ]
      ) == .inProgress
    )
    #expect(
      EpicProgress(
        tickets: [
          WorkItem(
            productID: productID,
            key: "T1",
            title: "Delivered",
            state: .released,
            epicID: epicID
          ),
          WorkItem(
            productID: productID,
            key: "T2",
            title: "Archived",
            state: .cancelled,
            epicID: epicID
          ),
        ]
      ) == .complete
    )
  }

  @Test("Happy-path transitions are available")
  func happyPathTransitions() throws {
    try policy.validateTransition(from: .backlog, to: .refining)
    try policy.validateTransition(from: .refining, to: .ready)
    try policy.validateTransition(from: .ready, to: .queued)
    try policy.validateTransition(from: .queued, to: .running)
    try policy.validateTransition(from: .running, to: .integrating)
    try policy.validateTransition(from: .integrating, to: .verifying)
    try policy.validateTransition(from: .verifying, to: .acceptance)
    try policy.validateTransition(from: .acceptance, to: .readyToRelease)
    try policy.validateTransition(from: .readyToRelease, to: .released)
  }

  @Test("Agents cannot skip governance gates")
  func governanceGatesCannotBeSkipped() {
    #expect(throws: WorkflowError.invalidTransition(from: .backlog, to: .running)) {
      try policy.validateTransition(from: .backlog, to: .running)
    }
    #expect(throws: WorkflowError.invalidTransition(from: .running, to: .released)) {
      try policy.validateTransition(from: .running, to: .released)
    }
  }

  @Test("Refined artifacts route to the appropriate delivery specialist")
  func capabilityBasedOwnership() throws {
    let productID = UUID()
    let analyst = AgentProfile(
      productID: productID,
      name: "Business Analyst",
      role: .businessAnalyst
    )
    let designer = AgentProfile(
      productID: productID,
      name: "UX Designer",
      role: .uxDesigner
    )
    let implementer = AgentProfile(
      productID: productID,
      name: "Implementer",
      role: .implementer
    )
    let profiles = [analyst, designer, implementer]

    let design = WorkItem(
      productID: productID,
      key: "T-1",
      title: "Design the location-to-forecast experience",
      body: "Create a responsive prototype and document the user flow.",
      acceptanceCriteria: ["The prototype covers mobile and desktop layouts"]
    )
    let research = WorkItem(
      productID: productID,
      key: "T-2",
      title: "Compare and select a weather data provider",
      type: .task,
      acceptanceCriteria: ["The trade-offs and recommendation are documented"]
    )
    let implementation = WorkItem(
      productID: productID,
      key: "T-3",
      title: "Build the approved weather experience",
      acceptanceCriteria: ["The approved experience works end to end"]
    )

    #expect(TicketOwnerRouter.owner(for: design, profiles: profiles)?.id == designer.id)
    #expect(TicketOwnerRouter.owner(for: research, profiles: profiles)?.id == analyst.id)
    #expect(
      TicketOwnerRouter.owner(for: implementation, profiles: profiles)?.id == implementer.id
    )
  }

  @Test("Scheduler admits only unblocked implementation runs in backlog order")
  func dependencyAwareRunAdmission() throws {
    let productID = UUID()
    let sprint = Sprint(productID: productID, number: 1, goal: "Deliver in order", state: .active)
    let implementerID = UUID()
    let reviewerID = UUID()
    let prerequisite = WorkItem(
      productID: productID,
      key: "T-1",
      title: "Choose the provider",
      state: .queued,
      rank: 1
    )
    let dependant = WorkItem(
      productID: productID,
      key: "T-2",
      title: "Build the integration",
      state: .queued,
      rank: 2
    )
    let independent = WorkItem(
      productID: productID,
      key: "T-3",
      title: "Prepare independent copy",
      state: .queued,
      rank: 3
    )
    let firstSprintItem = SprintItem(
      sprintID: sprint.id,
      workItemID: prerequisite.id,
      implementerProfileID: implementerID,
      estimatedTokens: 100
    )
    let secondSprintItem = SprintItem(
      sprintID: sprint.id,
      workItemID: dependant.id,
      implementerProfileID: implementerID,
      estimatedTokens: 100
    )
    let thirdSprintItem = SprintItem(
      sprintID: sprint.id,
      workItemID: independent.id,
      implementerProfileID: implementerID,
      estimatedTokens: 100
    )
    let plan = SprintPlan(
      sprint: sprint,
      items: [firstSprintItem, secondSprintItem, thirdSprintItem]
    )
    let firstRun = AgentRun(
      productID: productID,
      sprintID: sprint.id,
      sprintItemID: firstSprintItem.id,
      workItemID: prerequisite.id,
      profileID: implementerID
    )
    let secondRun = AgentRun(
      productID: productID,
      sprintID: sprint.id,
      sprintItemID: secondSprintItem.id,
      workItemID: dependant.id,
      profileID: implementerID
    )
    let thirdRun = AgentRun(
      productID: productID,
      sprintID: sprint.id,
      sprintItemID: thirdSprintItem.id,
      workItemID: independent.id,
      profileID: implementerID
    )
    let reviewerRun = AgentRun(
      productID: productID,
      sprintID: sprint.id,
      sprintItemID: firstSprintItem.id,
      workItemID: prerequisite.id,
      profileID: reviewerID
    )
    let dependency = WorkItemDependency(
      workItemID: dependant.id,
      dependsOnWorkItemID: prerequisite.id
    )

    let firstEligible = SprintRunAdmission.nextEligibleImplementationRun(
      plan: plan,
      runs: [reviewerRun, thirdRun, secondRun, firstRun],
      workItems: [prerequisite, dependant, independent],
      dependencies: [dependency]
    )
    #expect(firstEligible?.id == firstRun.id)
    let initiallyEligible = SprintRunAdmission.eligibleImplementationRuns(
      plan: plan,
      runs: [reviewerRun, thirdRun, secondRun, firstRun],
      workItems: [prerequisite, dependant, independent],
      dependencies: [dependency]
    )
    #expect(initiallyEligible.map(\.id) == [firstRun.id, thirdRun.id])

    var releasedPrerequisite = prerequisite
    releasedPrerequisite.state = .released
    let secondEligible = SprintRunAdmission.nextEligibleImplementationRun(
      plan: plan,
      runs: [reviewerRun, secondRun],
      workItems: [releasedPrerequisite, dependant],
      dependencies: [dependency]
    )
    #expect(secondEligible?.id == secondRun.id)
  }

  @Test("Scheduler admits every independent implementation run without a ticket cap")
  func uncappedIndependentRunAdmission() {
    let productID = UUID()
    let implementerID = UUID()
    let sprint = Sprint(
      productID: productID,
      number: 1,
      goal: "Deliver every independent outcome",
      state: .active,
      concurrencyLimit: 1
    )
    let workItems = (1...65).map { index in
      WorkItem(
        productID: productID,
        key: "T-\(index)",
        title: "Independent outcome \(index)",
        state: .queued,
        rank: index
      )
    }
    let sprintItems = workItems.map { item in
      SprintItem(
        sprintID: sprint.id,
        workItemID: item.id,
        implementerProfileID: implementerID,
        estimatedTokens: 100
      )
    }
    let runs = zip(workItems, sprintItems).map { item, sprintItem in
      AgentRun(
        productID: productID,
        sprintID: sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: item.id,
        profileID: implementerID
      )
    }

    let eligible = SprintRunAdmission.eligibleImplementationRuns(
      plan: SprintPlan(sprint: sprint, items: sprintItems),
      runs: runs,
      workItems: workItems,
      dependencies: []
    )

    #expect(eligible.map(\.id) == runs.map(\.id))
  }

  @Test("Candidate reviews run in parallel and only integrated work occupies the merge queue")
  func candidateReviewAndIntegrationAdmissionAreIndependent() throws {
    let productID = UUID()
    let sprintID = UUID()
    let first = WorkItem(
      productID: productID,
      key: "T62",
      title: "Revise the first candidate",
      state: .running,
      rank: 1
    )
    let second = WorkItem(
      productID: productID,
      key: "T63",
      title: "Integrate the approved candidate",
      state: .verifying,
      rank: 2
    )
    let third = WorkItem(
      productID: productID,
      key: "T64",
      title: "Review another candidate",
      state: .verifying,
      rank: 3
    )

    func candidate(
      for item: WorkItem,
      status: CandidateRevisionStatus,
      integratedSHA: String? = nil
    ) -> CandidateRevision {
      CandidateRevision(
        productID: productID,
        sprintID: sprintID,
        sprintItemID: UUID(),
        workItemID: item.id,
        implementationRunID: UUID(),
        version: 1,
        branchName: "ticket/\(item.key)",
        baseSHA: "base-\(item.key)",
        headSHA: "head-\(item.key)",
        integratedSHA: integratedSHA,
        worktreePath: "/tmp/\(item.key)",
        status: status,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    }

    let changesRequested = candidate(for: first, status: .changesRequested)
    let approvedAndQueued = candidate(for: second, status: .queuedForIntegration)
    let parallelReview = candidate(for: third, status: .reviewing)
    let candidates = [changesRequested, approvedAndQueued, parallelReview]

    #expect(
      !SprintCandidateAdmission.integrationQueueIsOccupied(
        candidates: candidates,
        sprintID: sprintID
      )
    )
    #expect(
      SprintCandidateAdmission.nextIntegrationCandidate(
        candidates: candidates,
        sprintID: sprintID,
        workItems: [first, second, third]
      )?.id == approvedAndQueued.id
    )

    let conflictReview = candidate(
      for: third,
      status: .reviewing,
      integratedSHA: "resolved-merge"
    )
    #expect(
      SprintCandidateAdmission.integrationQueueIsOccupied(
        candidates: candidates + [conflictReview],
        sprintID: sprintID
      )
    )

    let readyForDemo = candidate(for: first, status: .readyForDemo)
    #expect(
      !SprintCandidateAdmission.integrationQueueIsOccupied(
        candidates: candidates + [readyForDemo],
        sprintID: sprintID
      )
    )
  }

  @Test("Five review returns are allowed before owner direction is required")
  func reviewCorrectionLimit() {
    #expect(
      SprintReviewCorrectionPolicy.maximumChangeRequestsBeforeOwnerPause == 5
    )
    #expect(
      SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(reviewCycle: 0)
    )
    #expect(
      SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(reviewCycle: 3)
    )
    #expect(
      !SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(reviewCycle: 4)
    )
    #expect(
      SprintReviewCorrectionPolicy.changeRequestNumber(reviewCycle: 4) == 5
    )
  }
}
