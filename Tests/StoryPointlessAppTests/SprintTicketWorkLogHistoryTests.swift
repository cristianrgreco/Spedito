import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Sprint ticket Work log history")
struct SprintTicketWorkLogHistoryTests {
  @Test("A selected sprint answer remains on its question without a duplicate comment")
  func selectedAnswerRemainsOnQuestion() throws {
    let workItemID = UUID()
    let question = TicketOwnerQuestion(
      prompt: "Which runtime should be used?",
      options: [
        "Configure the deployment runtime",
        "Use an existing authorised runtime",
      ]
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
          actor: "StoryPointless",
          detail: "Event \(offset)",
          createdAt: base.addingTimeInterval(TimeInterval(offset))
        )
      )
    }

    let rows = SprintTicketWorkLogTimeline.rows(entries)

    #expect(rows.map(\.id) == entries.map(\.id))
    #expect(rows.map(\.showsBottomSeparator) == [true, true, false])
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
