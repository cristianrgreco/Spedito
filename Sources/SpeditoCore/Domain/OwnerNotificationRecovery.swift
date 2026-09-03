import Foundation

/// Decides whether a stored `needs_input` owner notification still announces a
/// real wait. The governing rule: a pending question must never outlive the
/// wait it announces, and an owed decision must keep its row until the owner
/// decides. The recovery sweep applies these rules to durable state on load so
/// rows stranded by interrupted or historical routes retire idempotently.
public struct OwnerNotificationRecoveryPolicy {
  /// An epic `needs_input` row waits on either unanswered clarification
  /// questions or a failed plan generation the owner can retry. The wait ends
  /// when the questions are gone and the latest planning session, if any,
  /// neither failed nor is still generating.
  public static func shouldRetireEpicNeedsInput(
    epic: Epic?,
    pendingQuestions: [TicketRefinementQuestion],
    latestPlanningSessionStatus: SuggestionSessionStatus?
  ) -> Bool {
    guard let epic, epic.status != .archived else { return true }
    guard pendingQuestions.isEmpty else { return false }
    switch latestPlanningSessionStatus {
    case .failed, .generating:
      return false
    case .ready, .cancelled, nil:
      return true
    }
  }

  /// A ticket `needs_input` row waits on an agent question: either a delivery
  /// run awaiting the owner or an unanswered refinement question in the work
  /// log. Any owner reply after the latest question ends the refinement wait.
  public static func shouldRetireTicketNeedsInput(
    workItem: WorkItem?,
    runs: [AgentRun],
    comments: [TicketComment]
  ) -> Bool {
    guard let workItem, workItem.state != .cancelled, workItem.state != .released
    else { return true }
    if runs.contains(where: {
      $0.workItemID == workItem.id && $0.status == .awaitingOwner
    }) {
      return false
    }
    guard
      let questionIndex = comments.lastIndex(where: { comment in
        comment.authorKind == .agent
          && TicketOwnerQuestion.presentation(
            in: comment.body,
            structuredQuestion: comment.ownerQuestion
          ) != nil
      })
    else { return true }
    return comments[comments.index(after: questionIndex)...]
      .contains { $0.authorKind == .owner }
  }
}
