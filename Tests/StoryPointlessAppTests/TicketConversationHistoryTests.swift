import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

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
      authorName: "Business Analyst",
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
      body: "@Business Analyst A retry action",
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
      analystName: "Business Analyst"
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
      authorName: "Business Analyst",
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
      body: "@Business Analyst A concise explanation"
    )

    let displayed = TicketConversationHistory.displayedComments(
      from: [questionComment, legacyAnswer],
      pendingQuestionID: nil,
      analystName: "Business Analyst"
    )

    let answer = try #require(displayed.only)
    #expect(answer.id == legacyAnswer.id)
    #expect(answer.answeredQuestions.first?.selectedOption == "A concise explanation")
    #expect(
      answer.answeredQuestions.first?.question.prompt
        == "Which empty state should the ticket deliver?"
    )
  }
}

private extension Collection {
  var only: Element? {
    count == 1 ? first : nil
  }
}
