import Foundation
import Testing

@testable import SpeditoCore

@Suite("Owner notification recovery policy")
struct OwnerNotificationRecoveryPolicyTests {
  private let productID = UUID()

  private func epic(status: EpicStatus = .open) -> Epic {
    Epic(
      productID: productID,
      title: "Cat jokes",
      goal: "Add a cat joke to results",
      status: status
    )
  }

  @Test("Pending clarification questions keep the epic row")
  func pendingQuestionsKeepEpicRow() {
    #expect(
      !OwnerNotificationRecoveryPolicy.shouldRetireEpicNeedsInput(
        epic: epic(),
        pendingQuestions: [
          TicketRefinementQuestion(
            prompt: "Which provider should supply the jokes?",
            options: ["Provider A", "Provider B"]
          )
        ],
        latestPlanningSessionStatus: .ready
      )
    )
  }

  @Test("A failed or generating plan keeps the epic row")
  func unfinishedPlanKeepsEpicRow() {
    for status: SuggestionSessionStatus in [.failed, .generating] {
      #expect(
        !OwnerNotificationRecoveryPolicy.shouldRetireEpicNeedsInput(
          epic: epic(),
          pendingQuestions: [],
          latestPlanningSessionStatus: status
        )
      )
    }
  }

  @Test("A landed plan or an ended wait retires the epic row")
  func endedWaitRetiresEpicRow() {
    for status: SuggestionSessionStatus? in [.ready, .cancelled, nil] {
      #expect(
        OwnerNotificationRecoveryPolicy.shouldRetireEpicNeedsInput(
          epic: epic(),
          pendingQuestions: [],
          latestPlanningSessionStatus: status
        )
      )
    }
  }

  @Test("An archived or missing epic retires its row")
  func archivedEpicRetiresRow() {
    #expect(
      OwnerNotificationRecoveryPolicy.shouldRetireEpicNeedsInput(
        epic: epic(status: .archived),
        pendingQuestions: [
          TicketRefinementQuestion(prompt: "Still open?", options: ["Yes", "No"])
        ],
        latestPlanningSessionStatus: .failed
      )
    )
    #expect(
      OwnerNotificationRecoveryPolicy.shouldRetireEpicNeedsInput(
        epic: nil,
        pendingQuestions: [],
        latestPlanningSessionStatus: .failed
      )
    )
  }

  @Test("An awaiting-owner run keeps the ticket row")
  func awaitingRunKeepsTicketRow() {
    let item = WorkItem(productID: productID, key: "T1", title: "Deliver the joke")
    #expect(
      !OwnerNotificationRecoveryPolicy.shouldRetireTicketNeedsInput(
        workItem: item,
        runs: [
          AgentRun(
            productID: productID,
            workItemID: item.id,
            profileID: UUID(),
            status: .awaitingOwner
          )
        ],
        comments: []
      )
    )
  }

  @Test("An unanswered refinement question keeps the ticket row")
  func unansweredQuestionKeepsTicketRow() {
    let item = WorkItem(productID: productID, key: "T1", title: "Deliver the joke")
    let question = TicketComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: "Business analyst",
      body: "I need one decision.",
      ownerQuestion: TicketOwnerQuestion(
        prompt: "Where should jokes be cached?",
        options: ["On this Mac", "Not at all"]
      )
    )
    let laterAgentNote = TicketComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: "Business analyst",
      body: "Still waiting on your answer."
    )
    #expect(
      !OwnerNotificationRecoveryPolicy.shouldRetireTicketNeedsInput(
        workItem: item,
        runs: [],
        comments: [question, laterAgentNote]
      )
    )
  }

  @Test("An owner reply after the question retires the ticket row")
  func ownerReplyRetiresTicketRow() {
    let item = WorkItem(productID: productID, key: "T1", title: "Deliver the joke")
    let question = TicketComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: "Business analyst",
      body: "I need one decision.",
      ownerQuestion: TicketOwnerQuestion(
        prompt: "Where should jokes be cached?",
        options: ["On this Mac", "Not at all"]
      )
    )
    let ownerReply = TicketComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "On this Mac, please."
    )
    #expect(
      OwnerNotificationRecoveryPolicy.shouldRetireTicketNeedsInput(
        workItem: item,
        runs: [],
        comments: [question, ownerReply]
      )
    )
  }

  @Test("A ticket without any wait retires its row")
  func noWaitRetiresTicketRow() {
    let item = WorkItem(productID: productID, key: "T1", title: "Deliver the joke")
    #expect(
      OwnerNotificationRecoveryPolicy.shouldRetireTicketNeedsInput(
        workItem: item,
        runs: [
          AgentRun(
            productID: productID,
            workItemID: item.id,
            profileID: UUID(),
            status: .completed
          )
        ],
        comments: [
          TicketComment(
            workItemID: item.id,
            authorKind: .agent,
            authorName: "Business analyst",
            body: "Refinement is complete."
          )
        ]
      )
    )
  }

  @Test("A released, cancelled, or missing ticket retires its row")
  func endedTicketRetiresRow() {
    for state: WorkItemState in [.released, .cancelled] {
      let item = WorkItem(
        productID: productID,
        key: "T1",
        title: "Deliver the joke",
        state: state
      )
      #expect(
        OwnerNotificationRecoveryPolicy.shouldRetireTicketNeedsInput(
          workItem: item,
          runs: [],
          comments: [
            TicketComment(
              workItemID: item.id,
              authorKind: .agent,
              authorName: "Business analyst",
              body: "I need one decision.",
              ownerQuestion: TicketOwnerQuestion(
                prompt: "Still relevant?",
                options: ["Yes", "No"]
              )
            )
          ]
        )
      )
    }
    #expect(
      OwnerNotificationRecoveryPolicy.shouldRetireTicketNeedsInput(
        workItem: nil,
        runs: [],
        comments: []
      )
    )
  }
}
