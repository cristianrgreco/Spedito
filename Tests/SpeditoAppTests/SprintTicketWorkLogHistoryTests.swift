import Foundation
import SpeditoCore
import Testing
@testable import SpeditoApp

@Suite("Sprint ticket Work log history")
struct SprintTicketWorkLogHistoryTests {
  @Test("An active agent question marks the Work log as needing Product Owner input")
  func activeAgentQuestionNeedsAttention() {
    let requiresInput = SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: false,
      hasActiveOwnerQuestion: true,
      knowledgeProposalStatuses: [],
      requiresKnowledgeApproval: false,
      ticketState: .running
    )

    #expect(requiresInput)
  }

  @Test("Ordinary in-progress activity does not mark the Work log for attention")
  func ordinaryActivityDoesNotNeedAttention() {
    let requiresInput = SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: false,
      hasActiveOwnerQuestion: false,
      knowledgeProposalStatuses: [],
      requiresKnowledgeApproval: false,
      ticketState: .running
    )

    #expect(!requiresInput)
  }

  @Test("Product knowledge under Tech Lead review does not need Product Owner attention")
  func proposedKnowledgeDoesNotNeedAttention() {
    let requiresInput = SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: false,
      hasActiveOwnerQuestion: false,
      knowledgeProposalStatuses: [.proposed],
      requiresKnowledgeApproval: true,
      ticketState: .verifying
    )

    #expect(!requiresInput)
  }

  @Test("Reviewed Product knowledge needs attention only when owner approval is enabled")
  func reviewedKnowledgeNeedsAttentionWhenOwnerApprovalIsEnabled() {
    let requiresInput = SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: false,
      hasActiveOwnerQuestion: false,
      knowledgeProposalStatuses: [.reviewed],
      requiresKnowledgeApproval: true,
      ticketState: .verifying
    )
    let publishesAutomatically = SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: false,
      hasActiveOwnerQuestion: false,
      knowledgeProposalStatuses: [.reviewed],
      requiresKnowledgeApproval: false,
      ticketState: .verifying
    )

    #expect(requiresInput)
    #expect(!publishesAutomatically)
  }

  @Test("A selected sprint answer remains on its question without a duplicate comment")
  func selectedAnswerRemainsOnQuestion() throws {
    let workItemID = UUID()
    let question = TicketOwnerQuestion(
      prompt: "Which runtime should be used?",
      options: [
        "Configure the deployment runtime",
        "Use an existing authorised runtime",
      ],
      decisionArtifact: TicketDecisionArtifact(
        title: "Runtime comparison",
        path: "docs/runtime-comparison.md"
      )
    )
    let questionComment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Implementer",
      body: "I need an authorised runtime.",
      ownerQuestion: question
    )
    let clarification = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@Implementer Is the free provider still approved?"
    )
    let clarificationReply = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Implementer",
      body: "Yes, the free provider is still approved."
    )
    let selectedOption = "Use an existing authorised runtime"
    let answerComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: selectedOption
    )

    let displayed = SprintTicketWorkLogHistory.displayedComments(
      from: [
        questionComment,
        clarification,
        clarificationReply,
        answerComment,
      ]
    )

    #expect(displayed.map(\.id) == [
      questionComment.id,
      clarification.id,
      clarificationReply.id,
    ])
    let answeredQuestion = try #require(displayed.first?.answeredQuestions.first)
    #expect(answeredQuestion.selectedOption == selectedOption)
    #expect(answeredQuestion.answer == selectedOption)
    #expect(
      displayed.first?.ownerQuestion?.decisionArtifact
        == TicketDecisionArtifact(
          title: "Runtime comparison",
          path: "docs/runtime-comparison.md"
        )
    )
  }

  @Test("A structured Other answer remains attached to its question")
  func customAnswerRemainsOnQuestion() throws {
    let workItemID = UUID()
    let question = TicketOwnerQuestion(
      prompt: "Which runtime should be used?",
      options: ["Deployment", "Existing runtime"]
    )
    let questionComment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Implementer",
      body: "Choose a runtime.",
      ownerQuestion: question
    )
    let customAnswer = "Use the staging runtime after its scheduled restart."
    let answerComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: customAnswer,
      answeredQuestions: [
        TicketAnsweredQuestion(
          question: TicketRefinementQuestion(
            prompt: question.prompt,
            options: question.options
          ),
          selectedOption: nil,
          answer: customAnswer
        )
      ]
    )

    let displayed = SprintTicketWorkLogHistory.displayedComments(
      from: [questionComment, answerComment]
    )

    let displayedQuestion = try #require(displayed.first)
    #expect(displayed.count == 1)
    #expect(displayedQuestion.answeredQuestions.first?.selectedOption == nil)
    #expect(displayedQuestion.answeredQuestions.first?.answer == customAnswer)
  }

  @Test("Permission decisions remain on their request without duplicate comments")
  func permissionDecisionsRemainOnRequest() {
    let productID = UUID()
    let workItemID = UUID()
    let runID = UUID()
    let base = Date(timeIntervalSince1970: 900)
    let allowedDetail = "swift test"
    let deniedDetail = "Write /Library/Application Support"
    let allowedRequest = permissionRequest(
      productID: productID,
      workItemID: workItemID,
      runID: runID,
      detail: allowedDetail,
      status: .allowed,
      createdAt: base
    )
    let deniedRequest = permissionRequest(
      productID: productID,
      workItemID: workItemID,
      runID: runID,
      detail: deniedDetail,
      status: .denied,
      createdAt: base.addingTimeInterval(10)
    )
    let ordinaryComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "Please keep the validation local.",
      createdAt: base.addingTimeInterval(20)
    )
    let comments = [
      TicketComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body: "Permission requested: \(allowedDetail)\n\nUse Allow once or Deny on this ticket.",
        createdAt: base
      ),
      TicketComment(
        workItemID: workItemID,
        authorKind: .owner,
        authorName: "Me",
        body: "Allowed once: \(allowedDetail)",
        createdAt: base.addingTimeInterval(1)
      ),
      TicketComment(
        workItemID: workItemID,
        authorKind: .owner,
        authorName: "Me",
        body: "Denied: \(deniedDetail)",
        createdAt: base.addingTimeInterval(11)
      ),
      ordinaryComment,
    ]

    let displayed = SprintTicketWorkLogHistory.displayedComments(
      from: comments,
      permissionRequests: [allowedRequest, deniedRequest]
    )

    #expect(displayed.map(\.id) == [ordinaryComment.id])
  }

  @Test("Saved product access does not add a duplicate Work log message")
  func savedProductAccessRemainsOnRequest() {
    let productID = UUID()
    let workItemID = UUID()
    let detail = "Read /opt/homebrew/bin/node"
    let request = permissionRequest(
      productID: productID,
      workItemID: workItemID,
      runID: UUID(),
      detail: detail,
      status: .allowed,
      createdAt: Date(timeIntervalSince1970: 950)
    )
    let comments = [
      TicketComment(
        workItemID: workItemID,
        authorKind: .owner,
        authorName: "Me",
        body: "Always allowed for this product: \(detail)"
      ),
      TicketComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body: "Automatically allowed by saved product access: \(detail)"
      ),
    ]

    let displayed = SprintTicketWorkLogHistory.displayedComments(
      from: comments,
      permissionRequests: [request]
    )

    #expect(displayed.isEmpty)
  }

  @Test("Command requests lead with their purpose and keep the exact command available")
  func commandRequestPresentation() {
    let request = AgentPermissionRequest(
      productID: UUID(),
      workItemID: UUID(),
      agentRunID: UUID(),
      threadID: "thread-command",
      turnID: "turn-command",
      serverRequestID: "request-command",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: """
        npm test

        Additional access for this command:

        Read /opt/homebrew
        """,
      reason: "Run the product's automated tests.",
      signature: "command-signature"
    )

    let presentation = SprintPermissionRequestPresentation(request: request)

    #expect(presentation.context == "The agent wants to run a local project command.")
    #expect(presentation.purpose == "Run the product's automated tests.")
    #expect(presentation.detailTitle == "Exact command and access")
    #expect(request.detail.contains("npm test"))
  }

  @Test("Permission request presentation supplies plain-language fallback copy")
  func permissionRequestPresentationFallback() {
    let request = AgentPermissionRequest(
      productID: UUID(),
      workItemID: UUID(),
      agentRunID: UUID(),
      threadID: "thread-access",
      turnID: "turn-access",
      serverRequestID: "request-access",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Read /opt/homebrew/bin/node",
      signature: "access-signature"
    )

    let presentation = SprintPermissionRequestPresentation(request: request)

    #expect(presentation.purpose == "Use an additional capability needed to continue this ticket.")
    #expect(presentation.detailTitle == "Exact access")
  }

  @Test("Existing access is non-actionable and says that permissions did not change")
  func existingAccessPresentation() {
    let request = AgentPermissionRequest(
      productID: UUID(),
      workItemID: UUID(),
      agentRunID: UUID(),
      threadID: "thread-existing-access",
      turnID: "turn-existing-access",
      serverRequestID: "request-existing-access",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Read .run-private",
      signature: "existing-access-signature",
      status: .existingAccess
    )

    #expect(request.status.needsOwnerDecision == false)
    #expect(
      SprintPermissionRequestPresentation.existingAccessTitle
        == "Existing access used"
    )
    #expect(
      SprintPermissionRequestPresentation.existingAccessSummary
        == "Spedito continued using access already available to this run. No permissions changed."
    )
  }

  @Test("Protected Spedito storage is non-actionable and explains the policy decision")
  func protectedStoragePresentation() {
    let request = AgentPermissionRequest(
      productID: UUID(),
      workItemID: UUID(),
      agentRunID: UUID(),
      threadID: "thread-protected-storage",
      turnID: "turn-protected-storage",
      serverRequestID: "request-protected-storage",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Write PreviewWorktrees/product",
      signature: "protected-storage-signature",
      status: .policyDenied
    )

    #expect(request.status.needsOwnerDecision == false)
    #expect(
      SprintPermissionRequestPresentation.protectedStorageTitle
        == "Protected Spedito storage"
    )
    #expect(
      SprintPermissionRequestPresentation.protectedStorageSummary
        == "Spedito kept this delivery run out of storage owned by another execution. No Product Owner decision was needed."
    )
  }

  @Test("Structured ticket artifacts are ordered with comments and events by occurrence")
  func structuredArtifactsAreChronological() {
    let productID = UUID()
    let workItemID = UUID()
    let base = Date(timeIntervalSince1970: 1_000)
    let comment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Implementer",
      body: "Implementation is ready.",
      createdAt: base.addingTimeInterval(30)
    )
    let event = ActivityEvent(
      productID: productID,
      workItemID: workItemID,
      kind: "work_item.transitioned",
      actor: "Implementer",
      detail: "running -> integrating: Candidate ready",
      createdAt: base.addingTimeInterval(10)
    )
    let permission = AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: UUID(),
      threadID: "thread-1",
      turnID: "turn-1",
      serverRequestID: "request-1",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: "swift test",
      signature: "signature",
      createdAt: base.addingTimeInterval(20),
      updatedAt: base.addingTimeInterval(20)
    )

    let ordered = SprintTicketWorkLogTimeline.ordered([
      .comment(comment),
      .permission(permission),
      .event(event),
    ])

    #expect(ordered.map(\.id) == [
      "event-\(event.id.uuidString)",
      "permission-\(permission.id.uuidString)",
      "comment-\(comment.id.uuidString)",
    ])
  }

  private func permissionRequest(
    productID: UUID,
    workItemID: UUID,
    runID: UUID,
    detail: String,
    status: AgentPermissionRequestStatus,
    createdAt: Date
  ) -> AgentPermissionRequest {
    AgentPermissionRequest(
      productID: productID,
      workItemID: workItemID,
      agentRunID: runID,
      threadID: "thread-\(UUID().uuidString)",
      turnID: "turn-\(UUID().uuidString)",
      serverRequestID: "request-\(UUID().uuidString)",
      method: "item/commandExecution/requestApproval",
      kind: .command,
      title: "Allow this command?",
      detail: detail,
      signature: "signature-\(UUID().uuidString)",
      status: status,
      createdAt: createdAt,
      updatedAt: createdAt
    )
  }

  @Test("Work log rows mark every entry except the last for separation")
  func workLogRowsUseOneOrderedSnapshot() {
    let productID = UUID()
    let workItemID = UUID()
    let base = Date(timeIntervalSince1970: 1_500)
    let entries = (0..<3).map { offset in
      SprintWorkLogEntry.event(
        ActivityEvent(
          productID: productID,
          workItemID: workItemID,
          kind: "test.event",
          actor: "Spedito",
          detail: "Event \(offset)",
          createdAt: base.addingTimeInterval(TimeInterval(offset))
        )
      )
    }

    let rows = SprintTicketWorkLogTimeline.rows(entries)

    #expect(rows.map(\.id) == entries.map(\.id))
    #expect(rows.map(\.showsBottomSeparator) == [true, true, false])
  }

  @Test("Demo feedback comment replaces its copied transition event")
  func demoFeedbackCommentReplacesTransitionEvent() {
    let productID = UUID()
    let workItemID = UUID()
    let base = Date(timeIntervalSince1970: 1_600)
    let feedback = String(
      repeating: "Keep the saved-place button aligned. ",
      count: 6
    )
    let comment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: feedback,
      createdAt: base
    )
    let feedbackTransition = ActivityEvent(
      productID: productID,
      workItemID: workItemID,
      kind: "work_item.transitioned",
      actor: "Product Owner",
      detail: "acceptance -> running: Demo feedback: \(feedback.prefix(160))",
      createdAt: base.addingTimeInterval(1)
    )
    let unrelatedTransition = ActivityEvent(
      productID: productID,
      workItemID: workItemID,
      kind: "work_item.transitioned",
      actor: "Tech Lead",
      detail: "verifying -> running: Review changes requested",
      createdAt: base.addingTimeInterval(2)
    )

    let displayed = SprintTicketWorkLogTimeline.displayedEvents(
      events: [feedbackTransition, unrelatedTransition],
      comments: [comment],
      permissionRequests: [],
      demoSubmissions: []
    )

    #expect(displayed.map(\.id) == [unrelatedTransition.id])
  }

  @Test("Permission card replaces its generic waiting event")
  func permissionCardReplacesWaitingEvent() {
    let productID = UUID()
    let workItemID = UUID()
    let base = Date(timeIntervalSince1970: 1_700)
    let request = permissionRequest(
      productID: productID,
      workItemID: workItemID,
      runID: UUID(),
      detail: "swift test",
      status: .pending,
      createdAt: base
    )
    let permissionWait = ActivityEvent(
      productID: productID,
      workItemID: workItemID,
      kind: "agent_run.awaiting_owner",
      actor: "Spedito",
      detail: "Waiting for a scoped permission decision",
      createdAt: base.addingTimeInterval(1)
    )
    let productQuestion = ActivityEvent(
      productID: productID,
      workItemID: workItemID,
      kind: "agent_run.awaiting_owner",
      actor: "Implementer",
      detail: "Choose which unavailable state to show",
      createdAt: base.addingTimeInterval(2)
    )

    let displayed = SprintTicketWorkLogTimeline.displayedEvents(
      events: [permissionWait, productQuestion],
      comments: [],
      permissionRequests: [request],
      demoSubmissions: []
    )

    #expect(displayed.map(\.id) == [productQuestion.id])
  }

  @Test("Each Ready for Demo transition uses the latest preceding candidate")
  func demoTransitionsUseLatestCandidate() throws {
    let productID = UUID()
    let workItemID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let base = Date(timeIntervalSince1970: 2_000)
    let firstCandidate = candidate(
      version: 1,
      createdAt: base.addingTimeInterval(10),
      productID: productID,
      workItemID: workItemID,
      sprintID: sprintID,
      sprintItemID: sprintItemID
    )
    let secondCandidate = candidate(
      version: 2,
      createdAt: base.addingTimeInterval(30),
      productID: productID,
      workItemID: workItemID,
      sprintID: sprintID,
      sprintItemID: sprintItemID
    )
    let firstDemo = ActivityEvent(
      sequence: 2,
      productID: productID,
      workItemID: workItemID,
      kind: "work_item.transitioned",
      actor: "Tech Lead",
      detail: "verifying -> acceptance: Review passed",
      createdAt: base.addingTimeInterval(20)
    )
    let nonDemo = ActivityEvent(
      sequence: 1,
      productID: productID,
      workItemID: workItemID,
      kind: "work_item.transitioned",
      actor: "Implementer",
      detail: "running -> integrating: Candidate queued",
      createdAt: base.addingTimeInterval(15)
    )
    let secondDemo = ActivityEvent(
      sequence: 3,
      productID: productID,
      workItemID: workItemID,
      kind: "work_item.transitioned",
      actor: "Tech Lead",
      detail: "verifying -> acceptance: Review passed",
      createdAt: base.addingTimeInterval(40)
    )

    let submissions = SprintTicketWorkLogTimeline.demoSubmissions(
      events: [secondDemo, nonDemo, firstDemo],
      candidates: [secondCandidate, firstCandidate]
    )

    #expect(submissions.map(\.event.id) == [firstDemo.id, secondDemo.id])
    #expect(submissions.map(\.candidate.id) == [
      firstCandidate.id,
      secondCandidate.id,
    ])
    let displayedEvents = SprintTicketWorkLogTimeline.displayedEvents(
      events: [secondDemo, nonDemo, firstDemo],
      comments: [],
      permissionRequests: [],
      demoSubmissions: submissions
    )
    #expect(displayedEvents.map(\.id) == [nonDemo.id])
  }

  @Test("Ready for Demo comments prefer the assignee, recent participant, then Tech Lead")
  func readyForDemoCommentRouting() throws {
    let productID = UUID()
    let workItemID = UUID()
    let base = Date(timeIntervalSince1970: 3_000)
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
    let reviewer = AgentProfile(
      productID: productID,
      name: "Reviewer",
      role: .reviewer
    )
    let comments = [
      TicketComment(
        workItemID: workItemID,
        authorKind: .agent,
        authorName: techLead.name,
        body: "The candidate is ready.",
        createdAt: base.addingTimeInterval(10)
      )
    ]
    let runs = [
      AgentRun(
        productID: productID,
        workItemID: workItemID,
        profileID: reviewer.id,
        status: .completed,
        lastActivityAt: base.addingTimeInterval(20),
        createdAt: base,
        updatedAt: base.addingTimeInterval(20)
      )
    ]
    let profiles = [techLead, reviewer, implementer]

    let assigned = try #require(
      SprintTicketCommentRouting.replyRecipient(
        workItemID: workItemID,
        assignedProfileID: implementer.id,
        comments: comments,
        runs: runs,
        profiles: profiles
      )
    )
    #expect(assigned.id == implementer.id)

    let recentParticipant = try #require(
      SprintTicketCommentRouting.replyRecipient(
        workItemID: workItemID,
        assignedProfileID: nil,
        comments: comments,
        runs: runs,
        profiles: profiles
      )
    )
    #expect(recentParticipant.id == reviewer.id)

    let fallback = try #require(
      SprintTicketCommentRouting.replyRecipient(
        workItemID: workItemID,
        assignedProfileID: nil,
        comments: [],
        runs: [],
        profiles: profiles
      )
    )
    #expect(fallback.id == techLead.id)
  }

  @Test("Ticket questions route to the team member with the active run")
  func activeTicketQuestionRouting() throws {
    let productID = UUID()
    let workItemID = UUID()
    let implementer = AgentProfile(
      productID: productID,
      name: "Implementer",
      role: .implementer
    )
    let designer = AgentProfile(
      productID: productID,
      name: "UX Designer",
      role: .uxDesigner
    )
    let activeRun = AgentRun(
      productID: productID,
      workItemID: workItemID,
      profileID: designer.id,
      status: .awaitingOwner,
      updatedAt: Date(timeIntervalSince1970: 4_000)
    )

    let recipient = try #require(
      SprintTicketCommentRouting.activeQuestionRecipient(
        workItemID: workItemID,
        assignedProfileID: implementer.id,
        comments: [],
        runs: [activeRun],
        profiles: [implementer, designer]
      )
    )

    #expect(recipient.id == designer.id)
  }

  @Test("A comment after a permission request remains routable until an agent replies")
  func unansweredPermissionCommentRouting() throws {
    let workItemID = UUID()
    let requestDate = Date(timeIntervalSince1970: 5_000)
    let earlierComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "Earlier context",
      createdAt: requestDate.addingTimeInterval(-1)
    )
    let question = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "Why is this access needed?",
      createdAt: requestDate.addingTimeInterval(1)
    )

    let unanswered = try #require(
      SprintTicketCommentRouting.unansweredOwnerComment(
        workItemID: workItemID,
        since: requestDate,
        comments: [earlierComment, question]
      )
    )
    #expect(unanswered.id == question.id)

    let reply = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "UX Designer",
      body: "Here is why.",
      createdAt: requestDate.addingTimeInterval(2)
    )
    #expect(
      SprintTicketCommentRouting.unansweredOwnerComment(
        workItemID: workItemID,
        since: requestDate,
        comments: [earlierComment, question, reply]
      ) == nil
    )
  }

  @Test("Run context separates mandatory knowledge from ticket-relevant knowledge")
  func runContextSeparatesMandatoryKnowledge() {
    let productID = UUID()
    let run = AgentRun(
      productID: productID,
      workItemID: UUID(),
      profileID: UUID()
    )
    let environments = KnowledgePage(
      productID: productID,
      title: "Environments",
      slug: "environments",
      bodyMarkdown: "Use the repository's maintained validation entry point."
    )
    let integration = KnowledgePage(
      productID: productID,
      title: "Provider integration",
      slug: "provider-integration",
      bodyMarkdown: "The provider is optional."
    )
    let context = SprintTicketRunContextLogItem(
      run: run,
      pages: [integration, environments]
    )

    #expect(context.mandatoryPages.map(\.id) == [environments.id])
    #expect(context.relevantPages.map(\.id) == [integration.id])
  }

  @Test("Review context does not add a repeated Knowledge used entry")
  func reviewContextIsHidden() {
    let productID = UUID()
    let techLead = AgentProfile(
      productID: productID,
      name: "Tech Lead",
      role: .lead
    )

    #expect(
      !SprintTicketRunContextVisibility.includes(
        profile: techLead,
        isDeliveryRun: false
      )
    )
  }

  @Test("Delivery context remains visible when its assignee can also review")
  func reviewerDeliveryContextRemainsVisible() {
    let productID = UUID()
    let techLead = AgentProfile(
      productID: productID,
      name: "Tech Lead",
      role: .lead
    )

    #expect(
      SprintTicketRunContextVisibility.includes(
        profile: techLead,
        isDeliveryRun: true
      )
    )
  }

  @Test("Ordinary delivery context remains visible")
  func ordinaryDeliveryContextRemainsVisible() {
    let productID = UUID()
    let implementer = AgentProfile(
      productID: productID,
      name: "Implementer",
      role: .implementer
    )

    #expect(
      SprintTicketRunContextVisibility.includes(
        profile: implementer,
        isDeliveryRun: false
      )
    )
  }

  private func candidate(
    version: Int,
    createdAt: Date,
    productID: UUID,
    workItemID: UUID,
    sprintID: UUID,
    sprintItemID: UUID
  ) -> CandidateRevision {
    CandidateRevision(
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: UUID(),
      version: version,
      branchName: "ticket/T\(version)",
      baseSHA: "base-\(version)",
      headSHA: "head-\(version)",
      worktreePath: "/tmp/ticket-\(version)",
      commitCount: 1,
      executionResultJSON: "{}",
      createdAt: createdAt,
      updatedAt: createdAt
    )
  }
}
