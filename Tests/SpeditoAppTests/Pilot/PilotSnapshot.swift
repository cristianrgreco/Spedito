import Foundation
import SpeditoCore

@testable import SpeditoApp

/// A text projection of everything the product owner can currently see and do.
///
/// The view contract in `CLAUDE.md` states that presentation state is a
/// deterministic projection of durable state, transient operation state, and a
/// typed failure. This renderer therefore reads only what a view could read. If
/// the owner cannot tell what is happening from this text, neither could a
/// person looking at the window, and that is itself a finding.
struct PilotSnapshot: Sendable {
  struct TicketView: Sendable {
    let key: String
    let title: String
    let state: WorkItemState
    let needsInput: Bool
    let latestRunStatus: AgentRunStatus?
    let candidateStatus: CandidateRevisionStatus?
    /// Direct prerequisites that have not been released yet. A ticket waiting on
    /// one is not stranded: the dispatcher is holding it back on purpose.
    let waitingOnPrerequisites: [String]
    /// Owner-facing things that can be done to this ticket right now.
    let availableActions: [String]
  }

  let renderedAt: Date
  let connection: String
  let isConnected: Bool
  let productName: String?
  let errorMessage: String?
  let epicSummaries: [String]
  let openQuestions: [String]
  let pendingSuggestionCount: Int
  let tickets: [TicketView]
  let sprintGoal: String?
  let sprintReadinessIssues: [String]
  let permissionPrompts: [String]
  let demoSummaries: [String]
  let codexThreadIDs: Set<String>
  /// Every owner-facing string in this snapshot, for convention linting.
  let ownerFacingText: [String]

  var hasOwnerAction: Bool {
    !openQuestions.isEmpty
      || pendingSuggestionCount > 0
      || !permissionPrompts.isEmpty
      || tickets.contains { !$0.availableActions.isEmpty }
  }

  var isAgentWorking: Bool {
    tickets.contains { ticket in
      ticket.latestRunStatus == .running || ticket.latestRunStatus == .queued
        || ticket.state == .running || ticket.state == .integrating
        || ticket.state == .verifying
    }
  }
}

@MainActor
enum PilotSnapshotRenderer {
  static func render(_ model: AppModel) -> PilotSnapshot {
    let connection: String
    let isConnected: Bool
    switch model.codexConnectionState {
    case .notChecked:
      connection = "Not checked"
      isConnected = false
    case .checking:
      connection = "Checking"
      isConnected = false
    case .connected(let version, _):
      connection = "Connected (\(version))"
      isConnected = true
    case .unavailable(let message):
      connection = "Unavailable: \(message)"
      isConnected = false
    case .incompatible(let message):
      connection = "Incompatible: \(message)"
      isConnected = false
    }

    let selectedProduct = model.products.first { $0.id == model.selectedProductID }
    let conversation = model.epicPlanningFeature.snapshot.conversation
    let openQuestions = (conversation?.questions ?? []).map { question in
      question.options.isEmpty
        ? question.prompt
        : "\(question.prompt) [\(question.options.joined(separator: " | "))]"
    }

    let pendingSuggestions = model.suggestionBatches.reduce(into: 0) { total, batch in
      total += batch.suggestions.filter { $0.status == .proposed }.count
    }

    let latestRunByWorkItem = model.runs.reduce(into: [UUID: AgentRun]()) { latest, run in
      if let current = latest[run.workItemID], current.updatedAt >= run.updatedAt { return }
      latest[run.workItemID] = run
    }
    let latestCandidateByWorkItem = model.candidateRevisions.reduce(
      into: [UUID: CandidateRevision]()
    ) { latest, candidate in
      if let current = latest[candidate.workItemID], current.version >= candidate.version {
        return
      }
      latest[candidate.workItemID] = candidate
    }

    let itemsByID = Dictionary(
      model.workItems.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let tickets = model.workItems.map { item -> PilotSnapshot.TicketView in
      let run = latestRunByWorkItem[item.id]
      let unreleasedPrerequisites =
        model.dependencies
        .filter { $0.workItemID == item.id }
        .compactMap { itemsByID[$0.dependsOnWorkItemID] }
        .filter { $0.state != .released && $0.state != .cancelled }
        .map(\.key)
        .sorted()
      let candidate = latestCandidateByWorkItem[item.id]
      let needsInput =
        run?.status == .awaitingOwner
        || model.pendingPermissionRequest(workItemID: item.id) != nil
      return PilotSnapshot.TicketView(
        key: item.key,
        title: item.title,
        state: item.state,
        needsInput: needsInput,
        latestRunStatus: run?.status,
        candidateStatus: candidate?.status,
        waitingOnPrerequisites: unreleasedPrerequisites,
        availableActions: availableActions(
          for: item,
          run: run,
          candidate: candidate,
          needsInput: needsInput,
          model: model
        )
      )
    }

    let permissionPrompts = model.permissionRequests
      .filter { $0.status == .pending }
      .map { "\($0.title) — \($0.detail)" }

    let demoSummaries = model.demoSessions.map { session in
      var summary = "\(session.status.rawValue)"
      if let port = session.allocatedPort { summary += " port \(port)" }
      if let error = session.errorMessage { summary += " error: \(error)" }
      return summary
    }

    let threadIDs = Set(model.runs.compactMap(\.codexThreadID))

    var ownerFacingText: [String] = []
    ownerFacingText.append(contentsOf: openQuestions)
    ownerFacingText.append(contentsOf: permissionPrompts)
    ownerFacingText.append(contentsOf: tickets.flatMap(\.availableActions))
    ownerFacingText.append(contentsOf: tickets.map(\.title))
    ownerFacingText.append(contentsOf: model.sprintReadinessIssues.map(\.message))
    if let errorMessage = model.errorMessage { ownerFacingText.append(errorMessage) }
    if let conversationError = conversation?.errorMessage {
      ownerFacingText.append(conversationError)
    }
    ownerFacingText.append(contentsOf: demoSummaries)

    return PilotSnapshot(
      renderedAt: Date(),
      connection: connection,
      isConnected: isConnected,
      productName: selectedProduct?.name,
      errorMessage: model.errorMessage,
      epicSummaries: model.epics.map { epic in
        "\(epic.title.isEmpty ? epic.goal : epic.title) [\(epic.status.rawValue)]"
      },
      openQuestions: openQuestions,
      pendingSuggestionCount: pendingSuggestions,
      tickets: tickets,
      sprintGoal: model.sprintPlan?.sprint.goal,
      sprintReadinessIssues: model.sprintReadinessIssues.map(\.message),
      permissionPrompts: permissionPrompts,
      demoSummaries: demoSummaries,
      codexThreadIDs: threadIDs,
      ownerFacingText: ownerFacingText.filter { !$0.isEmpty }
    )
  }

  /// Mirrors the affordances the sprint board and ticket detail actually offer.
  /// A ticket with no actions and no running agent is a dead end.
  private static func availableActions(
    for item: WorkItem,
    run: AgentRun?,
    candidate: CandidateRevision?,
    needsInput: Bool,
    model: AppModel
  ) -> [String] {
    var actions: [String] = []
    if needsInput { actions.append("Answer") }
    if candidate?.status == .readyForDemo {
      actions.append("Open demo")
      actions.append("Accept")
    }
    if candidate?.status == .changesRequested { actions.append("Review findings") }
    if run?.status == .failed { actions.append("Retry") }
    if run?.status == .running { actions.append("Stop") }
    switch item.state {
    case .backlog, .refining:
      actions.append("Refine")
      actions.append("Edit")
    case .ready:
      actions.append("Add to sprint")
    case .acceptance:
      actions.append("Accept")
    default:
      break
    }
    return actions
  }

  static func describe(_ snapshot: PilotSnapshot) -> String {
    var lines: [String] = []
    lines.append("Codex: \(snapshot.connection)")
    lines.append("Product: \(snapshot.productName ?? "none selected")")
    if let error = snapshot.errorMessage { lines.append("Error banner: \(error)") }
    if !snapshot.epicSummaries.isEmpty {
      lines.append("Epics: \(snapshot.epicSummaries.joined(separator: "; "))")
    }
    if !snapshot.openQuestions.isEmpty {
      lines.append("Questions waiting on me:")
      for question in snapshot.openQuestions { lines.append("  - \(question)") }
    }
    if snapshot.pendingSuggestionCount > 0 {
      lines.append("Suggested tickets awaiting my decision: \(snapshot.pendingSuggestionCount)")
    }
    if let goal = snapshot.sprintGoal { lines.append("Sprint goal: \(goal)") }
    if !snapshot.sprintReadinessIssues.isEmpty {
      lines.append("Sprint blockers: \(snapshot.sprintReadinessIssues.joined(separator: "; "))")
    }
    if !snapshot.permissionPrompts.isEmpty {
      lines.append("Permission requests:")
      for prompt in snapshot.permissionPrompts { lines.append("  - \(prompt)") }
    }
    if !snapshot.tickets.isEmpty {
      lines.append("Tickets:")
      for ticket in snapshot.tickets {
        var line = "  \(ticket.key) \(ticket.title) — \(ticket.state.rawValue)"
        if ticket.needsInput { line += " (needs your input)" }
        if let candidate = ticket.candidateStatus { line += " candidate=\(candidate.rawValue)" }
        if let run = ticket.latestRunStatus { line += " run=\(run.rawValue)" }
        if !ticket.waitingOnPrerequisites.isEmpty {
          line += " waiting-on=\(ticket.waitingOnPrerequisites.joined(separator: "+"))"
        }
        line += " actions=[\(ticket.availableActions.joined(separator: ", "))]"
        lines.append(line)
      }
    }
    if !snapshot.demoSummaries.isEmpty {
      lines.append("Demos: \(snapshot.demoSummaries.joined(separator: "; "))")
    }
    return lines.joined(separator: "\n")
  }
}
