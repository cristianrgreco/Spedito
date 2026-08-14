import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Ticket conversation history")
struct TicketConversationHistoryTests {
  @Test("A submitted refinement choice remains an answered question card")
  func submittedChoiceRemainsAnsweredQuestion() throws {
    let workItemID = UUID()
    let question = TicketRefinementQuestion(
      prompt: "Which empty state should the ticket deliver?",
      options: ["A concise explanation", "A retry action"]
    )
    let questionComment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Business analyst",
      body: """
        Which empty state should the ticket deliver?
        • A concise explanation
        • A retry action
        """
    )
    let answerComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@Business analyst A retry action",
      answeredQuestions: [
        TicketAnsweredQuestion(
          question: question,
          selectedOption: "A retry action",
          answer: "A retry action"
        )
      ]
    )

    let displayed = TicketConversationHistory.displayedComments(
      from: [questionComment, answerComment],
      pendingQuestionID: nil,
      analystName: "Business analyst"
    )

    let answer = try #require(displayed.only)
    #expect(answer.id == answerComment.id)
    #expect(answer.answeredQuestions.first?.selectedOption == "A retry action")
  }

  @Test("Previously saved plain-text choices recover their answered card")
  func legacyChoiceRecoversAnsweredQuestion() throws {
    let workItemID = UUID()
    let questionComment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Business analyst",
      body: """
        Which empty state should the ticket deliver?
        • A concise explanation
        • A retry action
        """
    )
    let legacyAnswer = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@Business analyst A concise explanation"
    )

    let displayed = TicketConversationHistory.displayedComments(
      from: [questionComment, legacyAnswer],
      pendingQuestionID: nil,
      analystName: "Business analyst"
    )

    let answer = try #require(displayed.only)
    #expect(answer.id == legacyAnswer.id)
    #expect(answer.answeredQuestions.first?.selectedOption == "A concise explanation")
    #expect(
      answer.answeredQuestions.first?.question.prompt
        == "Which empty state should the ticket deliver?"
    )
  }

  @Test("Ordinary chat does not disconnect a later structured answer from its question")
  func chatCanOccurBeforeStructuredAnswer() throws {
    let workItemID = UUID()
    let question = TicketRefinementQuestion(
      prompt: "Which empty state should the ticket deliver?",
      options: ["A concise explanation", "A retry action"]
    )
    let questionComment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Business analyst",
      body: """
        Which empty state should the ticket deliver?
        • A concise explanation
        • A retry action
        """
    )
    let ownerChat = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@Business analyst Why is the recommended option preferred?"
    )
    let analystReply = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Business analyst",
      body: "It keeps the empty state focused on the next useful action."
    )
    let answerComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@Business analyst A concise explanation",
      answeredQuestions: [
        TicketAnsweredQuestion(
          question: question,
          selectedOption: "A concise explanation",
          answer: "A concise explanation"
        )
      ]
    )

    let displayed = TicketConversationHistory.displayedComments(
      from: [questionComment, ownerChat, analystReply, answerComment],
      pendingQuestionID: nil,
      analystName: "Business analyst"
    )

    #expect(displayed.map(\.id) == [ownerChat.id, analystReply.id, answerComment.id])
    #expect(displayed.first?.answeredQuestions.isEmpty == true)
    #expect(displayed.last?.answeredQuestions.first?.question == question)
  }

  @Test("A pending question stays before chat sent after it")
  func pendingQuestionStaysInChronologicalPosition() throws {
    let workItemID = UUID()
    let earlierComment = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@Business analyst Please refine this ticket."
    )
    let questionComment = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Business analyst",
      body: """
        Which empty state should the ticket deliver?
        • A concise explanation
        • A retry action
        """
    )
    let laterOwnerChat = TicketComment(
      workItemID: workItemID,
      authorKind: .owner,
      authorName: "Me",
      body: "@UX designer How should this fit the existing screen?"
    )
    let laterAgentChat = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "UX designer",
      body: "Use the existing inline empty-state treatment."
    )
    let sourceComments = [
      earlierComment,
      questionComment,
      laterOwnerChat,
      laterAgentChat,
    ]
    let displayed = TicketConversationHistory.displayedComments(
      from: sourceComments,
      pendingQuestionID: questionComment.id,
      analystName: "Business analyst"
    )

    let insertionIndex = try #require(
      TicketConversationHistory.pendingQuestionInsertionIndex(
        in: displayed,
        sourceComments: sourceComments,
        pendingQuestionID: questionComment.id
      )
    )

    #expect(
      displayed.map(\.id) == [
        earlierComment.id,
        laterOwnerChat.id,
        laterAgentChat.id,
      ])
    #expect(insertionIndex == 1)
  }
}

@Suite("Conversation timeline scrolling")
struct ConversationTimelineScrollTargetTests {
  @Test("An ordinary reply targets the start of the latest message")
  func ordinaryReplyTargetsLatestMessage() {
    let scopeID = UUID()
    let latestMessageID = UUID()

    let target = ConversationTimelineScrollTarget.latest(
      scopeID: scopeID,
      lastMessageID: latestMessageID,
      messageCount: 2,
      questions: [],
      pendingQuestionInsertionIndex: nil
    )

    #expect(target == ConversationTimelineScrollTarget.message(latestMessageID))
  }

  @Test("A latest structured question group targets its first question")
  func latestQuestionGroupTargetsFirstQuestion() {
    let scopeID = UUID()
    let question = TicketRefinementQuestion(
      prompt: "Which audience should this serve first?",
      options: ["New customers", "Existing customers"]
    )

    let target = ConversationTimelineScrollTarget.latest(
      scopeID: scopeID,
      lastMessageID: UUID(),
      messageCount: 1,
      questions: [question],
      pendingQuestionInsertionIndex: 1
    )

    #expect(
      target == ConversationTimelineScrollTarget.questions(scopeID, [question])
    )
  }

  @Test("Later chat remains the target when pending questions are earlier")
  func laterChatTargetsLatestMessage() {
    let scopeID = UUID()
    let latestMessageID = UUID()
    let question = TicketRefinementQuestion(
      prompt: "Which audience should this serve first?",
      options: ["New customers", "Existing customers"]
    )

    let target = ConversationTimelineScrollTarget.latest(
      scopeID: scopeID,
      lastMessageID: latestMessageID,
      messageCount: 3,
      questions: [question],
      pendingQuestionInsertionIndex: 1
    )

    #expect(target == ConversationTimelineScrollTarget.message(latestMessageID))
  }
}

extension Collection {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
