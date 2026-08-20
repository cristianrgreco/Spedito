import Foundation
import SpeditoCore

@testable import SpeditoApp

/// Rules that must hold no matter what the agent said or did.
///
/// A live run cannot assert exact text, because a real agent's wording changes
/// every time. It can assert the contracts `CLAUDE.md` states as invariants, and
/// those are exactly the ones that break when a refactor drifts.
@MainActor
enum PilotInvariants {
  /// How long a ticket may sit with no owner action and no working agent before
  /// the run calls it a dead end.
  static let deadEndTolerance: TimeInterval = 240

  struct Context {
    let snapshot: PilotSnapshot
    let brief: PilotBrief
    /// When each ticket last changed observable state, used for stall detection.
    let unchangedSince: [String: Date]
  }

  static func check(_ context: Context, model: AppModel) -> [PilotJournal.Finding] {
    var findings: [PilotJournal.Finding] = []
    findings.append(contentsOf: deadEnds(context))
    findings.append(contentsOf: conventionFindings(context))
    findings.append(contentsOf: demoContract(context, model: model))
    findings.append(contentsOf: completionHandoffs(context, model: model))
    findings.append(contentsOf: ticketSequence(model: model))
    return findings
  }

  /// The owner must always have somewhere to go. A ticket that is not finished,
  /// has no agent working on it, and offers no action, has stranded the owner.
  private static func deadEnds(_ context: Context) -> [PilotJournal.Finding] {
    let terminal: Set<WorkItemState> = [.released, .cancelled]
    let now = Date()
    return context.snapshot.tickets.compactMap { ticket in
      guard !terminal.contains(ticket.state) else { return nil }
      guard ticket.availableActions.isEmpty else { return nil }
      guard ticket.latestRunStatus != .running, ticket.latestRunStatus != .queued else {
        return nil
      }
      guard let since = context.unchangedSince[ticket.key],
        now.timeIntervalSince(since) > deadEndTolerance
      else { return nil }
      return PilotJournal.Finding(
        category: .deadEnd,
        title: "Ticket \(ticket.key) offers the owner no action and nothing is running",
        evidence: """
          Ticket: \(ticket.key) \(ticket.title)
          State: \(ticket.state.rawValue)
          Latest run: \(ticket.latestRunStatus?.rawValue ?? "none")
          Candidate: \(ticket.candidateStatus?.rawValue ?? "none")
          Unchanged for: \(Int(now.timeIntervalSince(since)))s
          Available actions: none

          A non-terminal ticket with no running agent must offer the owner an
          action or be marked as needing their input.
          """,
        locationHint: "Sources/SpeditoApp/SprintBoardView.swift",
        at: now
      )
    }
  }

  private static func conventionFindings(_ context: Context) -> [PilotJournal.Finding] {
    var findings: [PilotJournal.Finding] = []
    for violation in PilotConventions.check(
      ownerFacingText: context.snapshot.ownerFacingText
    ) {
      let isDiagnostic = violation.rule.contains("technical evidence")
      findings.append(
        PilotJournal.Finding(
          category: isDiagnostic ? .leakedDiagnostic : .convention,
          title: violation.rule,
          evidence: "Owner-facing text: \(violation.text)",
          locationHint: nil,
          at: Date()
        )
      )
    }
    let labels = context.snapshot.tickets.flatMap(\.availableActions)
    for violation in PilotConventions.checkActionLabels(labels) {
      findings.append(
        PilotJournal.Finding(
          category: .convention,
          title: violation.rule,
          evidence: """
            Label: \(violation.text)
            Suggested: \(violation.suggestion ?? "n/a")
            """,
          locationHint: nil,
          at: Date()
        )
      )
    }
    return findings
  }

  /// Ready for demo must mean the owner can actually watch the thing run.
  private static func demoContract(
    _ context: Context,
    model: AppModel
  ) -> [PilotJournal.Finding] {
    model.candidateRevisions
      .filter { $0.status == .readyForDemo }
      .compactMap { candidate in
        let hasSession = model.demoSessions.contains { $0.status.isActive }
        let failed = model.demoSessions.first { $0.errorMessage != nil }
        guard let failed, !hasSession else { return nil }
        return PilotJournal.Finding(
          category: .functional,
          title: "A candidate reached ready for demo but its demo failed to run",
          evidence: """
            Candidate: \(candidate.id) version \(candidate.version)
            Delivery kind: \(candidate.deliveryKind.rawValue)
            Expected demo kind for this product: \(context.brief.expectedDemoKind.rawValue)
            Demo error: \(failed.errorMessage ?? "unknown")

            Ready for demo is an owner-facing promise that the work can be
            watched running.
            """,
          locationHint: "Sources/SpeditoApp/MacOSDemoLauncher.swift",
          at: Date()
        )
      }
  }

  /// Every completed ticket must leave a self-contained handoff in its work log,
  /// because direct dependants are given only that handoff as context.
  private static func completionHandoffs(
    _ context: Context,
    model: AppModel
  ) -> [PilotJournal.Finding] {
    model.workItems
      .filter { $0.state == .released }
      .compactMap { item in
        let runs = model.runs.filter { $0.workItemID == item.id }
        guard runs.contains(where: { $0.status == .completed }) else { return nil }
        // The work log is durable; absence of any completed run comment means the
        // handoff contract was not honoured.
        guard runs.allSatisfy({ ($0.lastActivityText ?? "").isEmpty }) else { return nil }
        return PilotJournal.Finding(
          category: .functional,
          title: "Completed ticket \(item.key) left no completion handoff",
          evidence: """
            Ticket: \(item.key) \(item.title)
            Completed runs: \(runs.filter { $0.status == .completed }.count)

            Every completed ticket must record the delivered outcome, decisions,
            evidence, and what dependants may assume.
            """,
          locationHint: "Sources/SpeditoCore/Domain/TicketDeliveryWorkflowCoordinator.swift",
          at: Date()
        )
      }
  }

  /// Accepted tickets use one durable product sequence with no gaps or repeats.
  private static func ticketSequence(model: AppModel) -> [PilotJournal.Finding] {
    let numbers = model.workItems.compactMap { item -> Int? in
      guard item.key.hasPrefix("T") else { return nil }
      return Int(item.key.dropFirst())
    }.sorted()
    guard !numbers.isEmpty else { return [] }
    let expected = Array(1...numbers.count)
    guard numbers != expected else { return [] }
    return [
      PilotJournal.Finding(
        category: .functional,
        title: "Accepted ticket keys are not one gap-free durable sequence",
        evidence: """
          Observed: \(numbers.map(String.init).joined(separator: ", "))
          Expected: \(expected.map(String.init).joined(separator: ", "))
          """,
        locationHint: "Sources/SpeditoCore/Persistence/SQLiteStore+WorkItems.swift",
        at: Date()
      )
    ]
  }
}
