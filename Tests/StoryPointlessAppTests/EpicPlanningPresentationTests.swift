import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Epic planning presentation")
struct EpicPlanningPresentationTests {
  @Test("Ticket and Epic conversation details share the same adaptive sheet size")
  func conversationDetailsShareSheetSize() {
    let laptopWorkspace = CGSize(width: 1_440, height: 900)
    let largeWorkspace = CGSize(width: 1_920, height: 1_200)

    #expect(
      ConversationDetailSheetSizing.size(for: laptopWorkspace)
        == CGSize(width: 1_080, height: 740)
    )
    #expect(
      ConversationDetailSheetSizing.size(for: largeWorkspace)
        == CGSize(width: 1_080, height: 740)
    )
    #expect(
      ConversationDetailSheetSizing.conversationWidth(for: 1_080) == 430
    )
  }

  @Test("Open and closed epics are separated while archived epics stay hidden")
  func epicsAreSeparatedByStatus() {
    let productID = UUID()
    let openEpic = Epic(
      productID: productID,
      title: "Open",
      goal: "Deliver an open outcome",
      status: .open
    )
    let closedEpic = Epic(
      productID: productID,
      title: "Closed",
      goal: "Preserve a confirmed outcome",
      status: .closed
    )
    let archivedEpic = Epic(
      productID: productID,
      title: "Archived",
      goal: "Preserve an archived outcome",
      status: .archived
    )

    let sections = EpicPlanningSections(
      epics: [closedEpic, archivedEpic, openEpic],
      workItems: []
    )

    #expect(sections.allEpics.map(\.id) == [closedEpic.id, openEpic.id])
    #expect(sections.openEpics.map(\.id) == [openEpic.id])
    #expect(sections.closedEpics.map(\.id) == [closedEpic.id])
  }

  @Test("Closed summary counts only delivered tickets from closed epics")
  func closedSummaryCountsDeliveredTickets() {
    let productID = UUID()
    let openEpic = Epic(
      productID: productID,
      title: "Open",
      goal: "Deliver an open outcome",
      status: .open
    )
    let closedEpic = Epic(
      productID: productID,
      title: "Closed",
      goal: "Preserve a confirmed outcome",
      status: .closed
    )
    let tickets = [
      WorkItem(
        productID: productID,
        key: "T1",
        title: "Delivered",
        state: .released,
        epicID: closedEpic.id
      ),
      WorkItem(
        productID: productID,
        key: "T2",
        title: "Archived",
        state: .cancelled,
        epicID: closedEpic.id
      ),
      WorkItem(
        productID: productID,
        key: "T3",
        title: "Delivered elsewhere",
        state: .released,
        epicID: openEpic.id
      ),
    ]

    let sections = EpicPlanningSections(
      epics: [openEpic, closedEpic],
      workItems: tickets
    )

    #expect(sections.deliveredTicketCount == 1)
  }

  @Test("Ticket details resolve their Epic across delivery history")
  func ticketDetailsResolveEpic() throws {
    let productID = UUID()
    let epic = Epic(
      productID: productID,
      title: "Delivered outcome",
      goal: "Keep the outcome available from ticket history",
      status: .archived
    )
    let ticket = WorkItem(
      productID: productID,
      key: "T1",
      title: "Deliver the outcome",
      state: .released,
      epicID: epic.id
    )

    let destination = try #require(
      TicketEpicNavigation.destination(for: ticket, in: [epic])
    )

    #expect(destination.id == epic.id)
  }

  @Test("Ticket details do not cross product boundaries when resolving an Epic")
  func ticketDetailsRejectForeignEpic() {
    let epic = Epic(
      productID: UUID(),
      title: "Another product",
      goal: "Remain isolated"
    )
    let ticket = WorkItem(
      productID: UUID(),
      key: "T1",
      title: "Unrelated ticket",
      epicID: epic.id
    )

    #expect(TicketEpicNavigation.destination(for: ticket, in: [epic]) == nil)
  }

  @Test("Ticket relationship links resolve the related ticket")
  func relationshipLinksResolveRelatedTicket() throws {
    let productID = UUID()
    let source = WorkItem(
      productID: productID,
      key: "T1",
      title: "Source ticket"
    )
    let related = WorkItem(
      productID: productID,
      key: "T2",
      title: "Related ticket"
    )

    let destination = try #require(
      TicketRelationshipNavigation.destination(
        for: related.id,
        source: source,
        in: [source, related]
      )
    )

    #expect(destination.id == related.id)
  }

  @Test("Ticket relationship links do not cross product boundaries")
  func relationshipLinksRejectForeignTickets() {
    let source = WorkItem(
      productID: UUID(),
      key: "T1",
      title: "Source ticket"
    )
    let foreign = WorkItem(
      productID: UUID(),
      key: "T2",
      title: "Foreign ticket"
    )

    #expect(
      TicketRelationshipNavigation.destination(
        for: foreign.id,
        source: source,
        in: [source, foreign]
      ) == nil
    )
  }

  @Test("Closed disclosure defaults to collapsed and persists per product")
  func closedDisclosurePersistsPerProduct() throws {
    let suiteName = "EpicPlanningPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let firstProductID = UUID()
    let secondProductID = UUID()

    #expect(
      !EpicPlanningDisclosureDefaults.isExpanded(
        for: firstProductID,
        defaults: defaults
      )
    )

    EpicPlanningDisclosureDefaults.setExpanded(
      true,
      for: firstProductID,
      defaults: defaults
    )

    #expect(
      EpicPlanningDisclosureDefaults.isExpanded(
        for: firstProductID,
        defaults: defaults
      )
    )
    #expect(
      !EpicPlanningDisclosureDefaults.isExpanded(
        for: secondProductID,
        defaults: defaults
      )
    )
  }

  @Test("Backlog uses the height remaining below every visible Epic row")
  func backlogUsesRemainingHeightBelowEpics() {
    let availableHeight: CGFloat = 922
    let dividerHeight: CGFloat = 37
    let epicHeight = BacklogPlanningSizing.epicHeight(
      openEpicCount: 3,
      closedEpicCount: 4,
      closedEpicsExpanded: false
    )
    let backlogHeight = BacklogPlanningSizing.backlogHeight(
      availableHeight: availableHeight,
      epicHeight: epicHeight,
      sectionDividerHeight: dividerHeight
    )

    #expect(epicHeight == 230)
    #expect(backlogHeight == 655)
    #expect(epicHeight + dividerHeight + backlogHeight == availableHeight)
  }

  @Test("Backlog can shrink below its former minimum when Epics use the space")
  func backlogShrinksToRemainingHeight() {
    let availableHeight: CGFloat = 730
    let dividerHeight: CGFloat = 37
    let epicHeight = BacklogPlanningSizing.epicHeight(
      openEpicCount: 1,
      closedEpicCount: 8,
      closedEpicsExpanded: true
    )
    let backlogHeight = BacklogPlanningSizing.backlogHeight(
      availableHeight: availableHeight,
      epicHeight: epicHeight,
      sectionDividerHeight: dividerHeight
    )

    #expect(epicHeight == 476)
    #expect(backlogHeight == 217)
    #expect(epicHeight + dividerHeight + backlogHeight == availableHeight)
  }

  @Test("Expanded closed Epics contribute to the planning section height")
  func expandedClosedEpicsContributeToHeight() {
    let collapsedHeight = BacklogPlanningSizing.epicHeight(
      openEpicCount: 2,
      closedEpicCount: 3,
      closedEpicsExpanded: false
    )
    let expandedHeight = BacklogPlanningSizing.epicHeight(
      openEpicCount: 2,
      closedEpicCount: 3,
      closedEpicsExpanded: true
    )

    #expect(
      expandedHeight - collapsedHeight
        == CGFloat(3) * BacklogPlanningSizing.epicRowHeight
    )
  }

  @Test("Pending Epic questions stay attached to the analyst message that asked them")
  func pendingEpicQuestionsStayInChronologicalPosition() throws {
    let question = TicketRefinementQuestion(
      prompt: "Which audience should this outcome serve first?",
      options: ["New customers", "Existing customers"]
    )
    let analystQuestion = EpicPlanningConversationMessage(
      author: .businessAnalyst,
      body: "I need one product decision before I can propose the tickets."
    )
    let laterOwnerChat = EpicPlanningConversationMessage(
      author: .owner,
      body: "@UX Designer What would each option mean for the flow?",
      kind: .chat
    )
    let laterAgentChat = EpicPlanningConversationMessage(
      author: .agent,
      body: "The first option needs more onboarding guidance.",
      kind: .chat,
      participantName: "UX Designer"
    )

    let anchorID = try #require(
      EpicPlanningConversationTimeline.pendingQuestionMessageID(
        in: [analystQuestion, laterOwnerChat, laterAgentChat],
        questions: [question]
      )
    )

    #expect(anchorID == analystQuestion.id)
  }

  @Test("A failed Epic plan retries generation without restarting clarification")
  func failedEpicPlanRetriesGeneration() {
    let question = TicketRefinementQuestion(
      prompt: "Which forecast should the Epic deliver?",
      options: ["Hourly", "Daily"]
    )
    let answer = EpicPlanningAnsweredQuestion(
      question: question,
      selectedOption: "Hourly",
      answer: "Hourly"
    )
    let conversation = EpicPlanningConversationState(
      epicID: UUID(),
      messages: [
        EpicPlanningConversationMessage(
          author: .owner,
          body: "",
          answeredQuestions: [answer]
        ),
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: "The outcome is ready to plan."
        ),
      ],
      questions: [],
      hasStartedPlanning: true,
      isRunning: false,
      isGeneratingPlan: false,
      isComplete: false,
      errorMessage: "The plan timed out."
    )

    #expect(
      EpicPlanningPolicy.retryAction(
        for: conversation,
        hasFailedPlan: true
      ) == .retryFailedPlan
    )
  }

  @Test("A failed clarification retries its last durable answers")
  func failedEpicClarificationRetriesAnswers() {
    let question = TicketRefinementQuestion(
      prompt: "Which forecast should the Epic deliver?",
      options: ["Hourly", "Daily"]
    )
    let answer = EpicPlanningAnsweredQuestion(
      question: question,
      selectedOption: "Hourly",
      answer: "Hourly"
    )
    let conversation = EpicPlanningConversationState(
      epicID: UUID(),
      messages: [
        EpicPlanningConversationMessage(
          author: .owner,
          body: "",
          answeredQuestions: [answer]
        )
      ],
      questions: [],
      hasStartedPlanning: true,
      isRunning: false,
      isGeneratingPlan: false,
      isComplete: false,
      errorMessage: "The clarification timed out."
    )

    #expect(
      EpicPlanningPolicy.retryAction(
        for: conversation,
        hasFailedPlan: false
      ) == .retryClarification([answer])
    )
  }

}
