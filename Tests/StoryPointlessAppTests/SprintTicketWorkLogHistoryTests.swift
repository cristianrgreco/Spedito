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
}
