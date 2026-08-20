import Foundation
import SpeditoCore

@testable import SpeditoApp

/// The product owner the pilot plays.
///
/// Deliberately behaves like the non-technical owner the product is designed
/// for: answers the question that was asked, takes the first reasonable option
/// when the choice is not consequential, grants only the access a request
/// actually justifies, and expects to be able to watch the result run.
@MainActor
struct PilotOwner {
  let brief: PilotBrief
  let journal: PilotJournal

  /// Answers an epic clarification round. A real owner answers in their own
  /// words when no options are offered, and picks an option when they are.
  func answers(
    to questions: [TicketRefinementQuestion]
  ) -> (answers: [String], answered: [EpicPlanningAnsweredQuestion]) {
    var plainAnswers: [String] = []
    var answered: [EpicPlanningAnsweredQuestion] = []
    for question in questions {
      let selected = question.options.first
      let answer = selected ?? freeformAnswer(for: question.prompt)
      plainAnswers.append(answer)
      answered.append(
        EpicPlanningAnsweredQuestion(
          question: question,
          selectedOption: selected,
          answer: answer
        )
      )
    }
    return (plainAnswers, answered)
  }

  /// Keeps the answer grounded in the brief rather than inventing new scope,
  /// which would make a run untraceable.
  private func freeformAnswer(for prompt: String) -> String {
    let lowered = prompt.lowercased()
    if lowered.contains("who") || lowered.contains("audience") {
      return "Just me to start with."
    }
    if lowered.contains("how many") || lowered.contains("scale") {
      return "Small, a handful of items."
    }
    if lowered.contains("data") || lowered.contains("store") || lowered.contains("save") {
      return "Keep it on this Mac, nothing in the cloud."
    }
    if lowered.contains("look") || lowered.contains("design") || lowered.contains("style") {
      return "Keep it plain and simple."
    }
    return "Whatever is simplest for \(brief.outcome.lowercased())"
  }

  /// Grants only what the brief justifies. A request for network access on a
  /// product that has no reason to reach the internet is refused, and the
  /// refusal itself is worth observing: delivery must degrade gracefully.
  func decision(for request: AgentPermissionRequest) -> (allow: Bool, remember: Bool) {
    let described = "\(request.title) \(request.detail) \(request.reason ?? "")".lowercased()
    let asksForNetwork = ["network", "internet", "http", "fetch", "download", "curl"]
      .contains { described.contains($0) }
    if asksForNetwork {
      return (brief.expectsNetworkPermission, false)
    }
    return (true, false)
  }

  /// What the owner says when an agent asks a question mid-delivery.
  func replyToTicketQuestion(_ question: String) -> String {
    let lowered = question.lowercased()
    if lowered.contains("proceed") || lowered.contains("continue") || lowered.contains("ok to") {
      return "Yes, go ahead."
    }
    if lowered.contains("prefer") || lowered.contains("which") {
      return "Use whichever is simplest to maintain."
    }
    return "Use your judgement and keep it simple. \(brief.outcome)"
  }
}
