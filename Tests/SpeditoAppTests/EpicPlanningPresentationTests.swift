import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Epic planning presentation")
struct EpicPlanningPresentationTests {
  @Test("Ticket and epic conversation details share the same adaptive sheet size")
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

  @Test("Ticket details resolve their epic across delivery history")
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

  @Test("Ticket details do not cross product boundaries when resolving an epic")
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

  @Test("Backlog planning split defaults to 59 percent and persists narrower backlog sizes")
  func backlogPlanningSplitPersists() throws {
    let suiteName = "EpicPlanningPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    #expect(
      BacklogPlanningSplitPreference.load(defaults: defaults)
        == BacklogPlanningSizing.defaultBacklogRatio
    )

    BacklogPlanningSplitPreference.save(0.52, defaults: defaults)

    #expect(BacklogPlanningSplitPreference.load(defaults: defaults) == 0.52)

    BacklogPlanningSplitPreference.save(0.68, defaults: defaults)

    #expect(
      BacklogPlanningSplitPreference.load(defaults: defaults)
        == BacklogPlanningSizing.defaultBacklogRatio
    )
  }

  @Test("Backlog planning split preserves the backlog minimum and sprint default share")
  func backlogPlanningSplitPreservesMinimumWidths() {
    let availableWidth: CGFloat = 1_032
    let dividerWidth: CGFloat = 1

    let narrowBacklog = BacklogPlanningSizing.backlogWidth(
      availableWidth: availableWidth,
      dividerWidth: dividerWidth,
      preferredRatio: 0.2
    )
    let narrowSprint =
      availableWidth - dividerWidth
      - BacklogPlanningSizing.backlogWidth(
        availableWidth: availableWidth,
        dividerWidth: dividerWidth,
        preferredRatio: 0.9
      )

    let defaultSprintWidth =
      (availableWidth - dividerWidth)
      * (1 - BacklogPlanningSizing.defaultBacklogRatio)

    #expect(narrowBacklog == BacklogPlanningSizing.minimumBacklogWidth)
    #expect(abs(narrowSprint - defaultSprintWidth) < 0.001)
  }

  @Test("Backlog planning split falls back safely in a compact container")
  func backlogPlanningSplitHandlesCompactContainers() {
    let narrowPreferenceWidth = BacklogPlanningSizing.backlogWidth(
      availableWidth: 601,
      dividerWidth: 1,
      preferredRatio: 0
    )
    let widePreferenceWidth = BacklogPlanningSizing.backlogWidth(
      availableWidth: 601,
      dividerWidth: 1,
      preferredRatio: 1
    )
    let scaledMinimum =
      600 * BacklogPlanningSizing.minimumBacklogWidth
      / (BacklogPlanningSizing.minimumBacklogWidth
        + BacklogPlanningSizing.minimumSprintWidth)

    #expect(abs(narrowPreferenceWidth - scaledMinimum) < 0.001)
    #expect(abs(widePreferenceWidth - scaledMinimum) < 0.001)
  }

  @Test("Native backlog split positions round-trip through the stored ratio")
  func backlogPlanningNativeSplitRoundTrips() {
    let containerWidth: CGFloat = 1_200
    let horizontalPadding: CGFloat = 24
    let dividerWidth: CGFloat = 1
    let preferredRatio: CGFloat = 0.54

    let position = BacklogPlanningSizing.splitPosition(
      containerWidth: containerWidth,
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredRatio: preferredRatio
    )
    let restoredRatio = BacklogPlanningSizing.backlogRatio(
      forSplitPosition: position,
      containerWidth: containerWidth,
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth
    )

    #expect(abs(restoredRatio - preferredRatio) < 0.001)
  }

  @Test("Native backlog split cannot make sprint narrower than its default share")
  func backlogPlanningNativeSplitProtectsDefaultSprintWidth() {
    let containerWidth: CGFloat = 1_200
    let horizontalPadding: CGFloat = 24
    let dividerWidth: CGFloat = 1
    let paneWidth = containerWidth - (horizontalPadding * 2) - dividerWidth
    let position = BacklogPlanningSizing.splitPosition(
      containerWidth: containerWidth,
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredRatio: 0.9
    )
    let sprintWidth = containerWidth - horizontalPadding - dividerWidth - position

    #expect(
      abs(
        sprintWidth
          - paneWidth * (1 - BacklogPlanningSizing.defaultBacklogRatio)
      ) < 0.001
    )
  }

  @Test("Native backlog split positions include outer planning padding")
  func backlogPlanningNativeSplitIncludesPadding() {
    let horizontalPadding: CGFloat = 24
    let minimumPosition = BacklogPlanningSizing.splitPosition(
      containerWidth: 1_200,
      horizontalPadding: horizontalPadding,
      dividerWidth: 1,
      preferredRatio: 0
    )

    #expect(
      minimumPosition
        == horizontalPadding + BacklogPlanningSizing.minimumBacklogWidth
    )
  }

  @Test("Backlog uses the height remaining below every visible epic row")
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

  @Test("Backlog can shrink below its former minimum when epics use the space")
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

  @Test("Expanded closed epics contribute to the planning section height")
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

  @Test("Pending epic questions stay attached to the analyst message that asked them")
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
      body: "@UX designer What would each option mean for the flow?",
      kind: .chat
    )
    let laterAgentChat = EpicPlanningConversationMessage(
      author: .agent,
      body: "The first option needs more onboarding guidance.",
      kind: .chat,
      participantName: "UX designer"
    )

    let anchorID = try #require(
      EpicPlanningConversationTimeline.pendingQuestionMessageID(
        in: [analystQuestion, laterOwnerChat, laterAgentChat],
        questions: [question]
      )
    )

    #expect(anchorID == analystQuestion.id)
  }

  @Test("Submitting epic answers preserves the current question position")
  func submittedEpicAnswersPreserveQuestionPosition() {
    let scopeID = UUID()
    let question = TicketRefinementQuestion(
      prompt: "Which forecast should the epic deliver?",
      options: ["Hourly", "Daily"]
    )
    let answerMessage = EpicPlanningConversationMessage(
      author: .owner,
      body: "",
      answeredQuestions: [
        EpicPlanningAnsweredQuestion(
          question: question,
          selectedOption: "Hourly",
          answer: "Hourly"
        )
      ]
    )

    #expect(
      !EpicPlanningConversationTimeline.shouldAutoScroll(
        from: .questions(scopeID, [question]),
        to: .message(answerMessage.id),
        messages: [answerMessage]
      )
    )
  }

  @Test("A failed epic plan retries generation without restarting clarification")
  func failedEpicPlanRetriesGeneration() {
    let question = TicketRefinementQuestion(
      prompt: "Which forecast should the epic deliver?",
      options: ["Hourly", "Daily"]
    )
    let answer = EpicPlanningAnsweredQuestion(
      question: question,
      selectedOption: "Hourly",
      answer: "Hourly"
    )
    let conversation = EpicPlanningConversationState(
      productID: UUID(),
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
      prompt: "Which forecast should the epic deliver?",
      options: ["Hourly", "Daily"]
    )
    let answer = EpicPlanningAnsweredQuestion(
      question: question,
      selectedOption: "Hourly",
      answer: "Hourly"
    )
    let conversation = EpicPlanningConversationState(
      productID: UUID(),
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

  @Test("Completed epic analysis refreshes the open sheet when metadata arrives")
  func completedEpicAnalysisRefreshesOpenSheet() {
    let productID = UUID()
    let epicID = UUID()
    let draft = Epic(
      id: epicID,
      productID: productID,
      title: "",
      goal: "Give users a disposable scratchpad"
    )
    let analyzed = Epic(
      id: epicID,
      productID: productID,
      title: "Disposable scratchpad",
      goal: "Give macOS users an immediate place to jot plain text.",
      successCriteria: ["Launching presents a focused plain-text editor"],
      constraints: "Keep all text local."
    )

    #expect(
      EpicDetailRefreshPolicy.shouldSync(
        previous: draft,
        current: analyzed,
        isPlanningComplete: true,
        hasUnsavedOwnerChanges: false
      )
    )
    #expect(
      !EpicDetailRefreshPolicy.shouldSync(
        previous: draft,
        current: analyzed,
        isPlanningComplete: false,
        hasUnsavedOwnerChanges: false
      )
    )
    #expect(
      !EpicDetailRefreshPolicy.shouldSync(
        previous: draft,
        current: analyzed,
        isPlanningComplete: true,
        hasUnsavedOwnerChanges: true
      )
    )
  }

  /// Existing partial coverage:
  /// - `submittedEpicAnswersPreserveQuestionPosition`
  /// - `failedEpicClarificationRetriesAnswers`
  /// - `SQLiteStoreTests.epicPlanningConversationsAreDurable`
  /// This test covers only E03's listed-choice, Other, and exclusive advancement composition.
  @Test("E03 listed and custom answers exclusively enable one complete submission")
  func e03ListedAndCustomAnswersEnableSubmission() throws {
    let questions = [
      TicketRefinementQuestion(
        prompt: "Which audience should this outcome serve first?",
        options: ["New customers", "Existing customers"]
      ),
      TicketRefinementQuestion(
        prompt: "Which reporting cadence is required?",
        options: ["Daily", "Weekly"]
      ),
    ]
    let listedOnly = [0: "Existing customers"]
    let incompleteOther = [
      0: "Existing customers",
      1: EpicPlanningAnswerSubmission.otherChoice,
    ]

    #expect(
      !EpicPlanningAnswerSubmission.canSubmit(
        questions: questions,
        selectedOptions: listedOnly,
        otherAnswers: [:]
      )
    )
    #expect(
      !EpicPlanningAnswerSubmission.canSubmit(
        questions: questions,
        selectedOptions: incompleteOther,
        otherAnswers: [1: "   "]
      )
    )
    #expect(
      EpicPlanningAnswerSubmission.canSubmit(
        questions: questions,
        selectedOptions: incompleteOther,
        otherAnswers: [1: "  Monthly after close  "]
      )
    )

    let answers = EpicPlanningAnswerSubmission.answeredQuestions(
      questions: questions,
      selectedOptions: incompleteOther,
      otherAnswers: [1: "  Monthly after close  "]
    )
    #expect(answers.count == 2)
    #expect(answers[0].selectedOption == "Existing customers")
    #expect(answers[0].answer == "Existing customers")
    #expect(answers[1].selectedOption == nil)
    #expect(answers[1].answer == "Monthly after close")
  }

  /// Existing partial coverage:
  /// - `SQLiteStoreTests.ticketSuggestionsAreOwnerControlled`
  /// - `SQLiteStoreTests.suggestionsCanDependOnExistingWork`
  /// - `SQLiteStoreTests.dependencyAwareRanking`
  /// This test covers only E11's complete transitive preview before persistence.
  @Test("E11 acceptance previews every transitive suggested prerequisite before writing")
  func e11AcceptancePreviewsTransitivePrerequisites() {
    let sessionID = UUID()
    let contract = ticketSuggestion(
      sessionID: sessionID,
      reference: "T1",
      position: 0
    )
    let design = ticketSuggestion(
      sessionID: sessionID,
      reference: "T2",
      position: 1,
      dependencyIDs: [contract.id]
    )
    let implementation = ticketSuggestion(
      sessionID: sessionID,
      reference: "T3",
      position: 2,
      dependencyIDs: [design.id]
    )
    let unrelated = ticketSuggestion(
      sessionID: sessionID,
      reference: "T4",
      position: 3
    )
    let suggestions = [implementation, unrelated, design, contract]

    let prerequisites = transitiveSuggestedPrerequisites(
      of: implementation,
      in: suggestions
    )
    let impact = SuggestionAcceptanceImpact(
      suggestion: implementation,
      prerequisites: prerequisites
    )

    #expect(prerequisites.map(\.reference) == ["T1", "T2"])
    #expect(impact.requiresConfirmation)
    #expect(impact.actionTitle == "Accept 3 tickets")
    #expect(impact.message.contains("T1, T2"))
    #expect(suggestions.allSatisfy { $0.status == .proposed })
  }

  @Test("E09 suggestion review discloses rationale dependencies and Backlog impact")
  func e09SuggestionReviewDisclosesAcceptanceImpact() {
    let sessionID = UUID()
    let prerequisite = ticketSuggestion(
      sessionID: sessionID,
      reference: "T1",
      position: 0
    )
    let target = ticketSuggestion(
      sessionID: sessionID,
      reference: "T2",
      position: 1,
      dependencyIDs: [prerequisite.id]
    )
    let impact = SuggestionAcceptanceImpact(
      suggestion: target,
      prerequisites: [prerequisite]
    )

    #expect(target.rationale == "Required delivery work.")
    #expect(impact.requiresConfirmation)
    #expect(impact.actionTitle == "Accept 2 tickets")
    #expect(impact.message.contains("T1"))
    #expect(impact.message.contains("backlog"))
    #expect(impact.message.contains("does not add them to a sprint"))
    #expect([prerequisite, target].allSatisfy { $0.status == .proposed })
  }

  @Test("E10 all-suggestion confirmations state exact scope and no sprint effect")
  func e10AllSuggestionConfirmationsStateScope() {
    let sessionID = UUID()
    let first = ticketSuggestion(
      sessionID: sessionID,
      reference: "T1",
      position: 0
    )
    let second = ticketSuggestion(
      sessionID: sessionID,
      reference: "T2",
      position: 1
    )
    let alreadyAccepted = ticketSuggestion(
      sessionID: sessionID,
      reference: "T3",
      position: 2,
      dependencyIDs: [first.id],
      status: .accepted,
      acceptedWorkItemID: UUID()
    )
    let suggestions = [first, second, alreadyAccepted]
    let impact = SuggestionBatchDecisionImpact(suggestions: suggestions)

    #expect(impact.proposedCount == 2)
    #expect(impact.acceptActionTitle == "Accept 2 suggestions")
    #expect(impact.acceptMessage.contains("All 2 remaining suggestions"))
    #expect(impact.acceptMessage.contains("does not add them to a sprint"))
    #expect(impact.rejectActionTitle == "Reject 2 suggestions")
    #expect(impact.acceptedCascadeTicketCount == 1)
    #expect(impact.rejectMessage.contains("All 2 remaining suggestions"))
    #expect(impact.rejectMessage.contains("archives 1 dependent ticket"))
    #expect(impact.rejectMessage.contains("no ticket is added to a sprint"))
    #expect(suggestions.map(\.status) == [.proposed, .proposed, .accepted])
  }


  private func ticketSuggestion(
    sessionID: UUID,
    reference: String,
    position: Int,
    dependencyIDs: [UUID] = [],
    status: TicketSuggestionStatus = .proposed,
    acceptedWorkItemID: UUID? = nil
  ) -> TicketSuggestion {
    TicketSuggestion(
      sessionID: sessionID,
      reference: reference,
      position: position,
      title: reference,
      body: "Deliver \(reference).",
      acceptanceCriteria: ["\(reference) is complete"],
      suggestedRole: .implementer,
      priority: .normal,
      rationale: "Required delivery work.",
      dependencyIDs: dependencyIDs,
      status: status,
      acceptedWorkItemID: acceptedWorkItemID
    )
  }

}
