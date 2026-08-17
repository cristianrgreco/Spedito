import Foundation
import SpeditoCore

@MainActor
extension AppModel {
  func restoreEpicPlanningConversation(for epic: Epic) async {
    await epicPlanningWorkflowCoordinator.restoreEpicPlanningConversation(for: epic)
  }

  func planEpic(_ epic: Epic) {
    epicPlanningWorkflowCoordinator.planEpic(epic)
  }

  func continueEpicPlanning(
    _ epic: Epic,
    answers: [String],
    answeredQuestions: [EpicPlanningAnsweredQuestion]
  ) {
    epicPlanningWorkflowCoordinator.continueEpicPlanning(
      epic,
      answers: answers,
      answeredQuestions: answeredQuestions
    )
  }

  func retryEpicPlanning(_ epic: Epic) {
    epicPlanningWorkflowCoordinator.retryEpicPlanning(epic)
  }

  func cancelEpicPlanning() {
    epicPlanningWorkflowCoordinator.cancelEpicPlanning()
  }

  func clearEpicPlanningConversation(for epicID: UUID) {
    epicPlanningWorkflowCoordinator.clearEpicPlanningConversation(for: epicID)
  }

  func saveEpicPlanningConversation(
    _ conversation: EpicPlanningConversationState,
    threadID: String?
  ) async throws {
    try await epicPlanningWorkflowCoordinator.saveEpicPlanningConversation(
      conversation,
      threadID: threadID
    )
  }

  func retryEpicPlan(sessionID: UUID) {
    epicPlanningWorkflowCoordinator.retryEpicPlan(sessionID: sessionID)
  }

  func autosuggestTickets() {
    epicPlanningWorkflowCoordinator.autosuggestTickets()
  }

  func updateTicketSuggestion(
    _ suggestion: TicketSuggestion,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    suggestedRole: AgentRole,
    priority: WorkItemPriority,
    rationale: String,
    completion: ((TicketSuggestion?) -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.updateTicketSuggestion(
      suggestion,
      title: title,
      type: type,
      body: body,
      acceptanceCriteria: acceptanceCriteria,
      suggestedRole: suggestedRole,
      priority: priority,
      rationale: rationale,
      completion: completion
    )
  }

  func decideTicketSuggestion(
    _ suggestion: TicketSuggestion,
    accept: Bool,
    completion: ((WorkItem?) -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.decideTicketSuggestion(
      suggestion,
      accept: accept,
      completion: completion
    )
  }

  func rejectTicketSuggestion(
    _ suggestion: TicketSuggestion,
    completion: (() -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.rejectTicketSuggestion(
      suggestion,
      completion: completion
    )
  }

  func decideAllTicketSuggestions(
    sessionID: UUID,
    accept: Bool,
    completion: ((Bool) -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.decideAllTicketSuggestions(
      sessionID: sessionID,
      accept: accept,
      completion: completion
    )
  }

  func decideTicketSuggestionGroup(
    _ suggestions: [TicketSuggestion],
    accept: Bool,
    completion: ((Bool) -> Void)? = nil
  ) {
    epicPlanningWorkflowCoordinator.decideTicketSuggestionGroup(
      suggestions,
      accept: accept,
      completion: completion
    )
  }

  func dismissFailedTicketSuggestions(sessionID: UUID) {
    epicPlanningWorkflowCoordinator.dismissFailedTicketSuggestions(sessionID: sessionID)
  }
}
