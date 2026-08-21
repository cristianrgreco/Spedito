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

  /// How long a run may stay queued while its sprint is active before the pilot
  /// treats it as a stall. Admission waits on prerequisites, so this is
  /// deliberately generous.
  static let queuedTolerance: TimeInterval = 600

  /// How long a running agent may report nothing before the pilot treats it as
  /// gone. A live turn reports activity as it works, so silence this long means
  /// the turn ended without anyone noticing, not that it is thinking hard.
  static let silentRunTolerance: TimeInterval = 600

  struct Context {
    let snapshot: PilotSnapshot
    let brief: PilotBrief
    /// When each ticket last changed observable state, used for stall detection.
    let unchangedSince: [String: Date]
    /// True while at least one run is genuinely running somewhere in the product.
    let anyRunIsRunning: Bool
  }

  static func check(_ context: Context, model: AppModel) -> [PilotJournal.Finding] {
    var findings: [PilotJournal.Finding] = []
    findings.append(contentsOf: deadEnds(context))
    findings.append(contentsOf: conventionFindings(context))
    findings.append(contentsOf: demoContract(context, model: model))
    findings.append(contentsOf: ticketSequence(model: model))
    findings.append(contentsOf: stalledRuns(context, model: model))
    findings.append(contentsOf: silentRuns(context, model: model))
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
      // A ticket held back by its own prerequisites is not stranded. The
      // dispatcher waits for direct prerequisites to reach done on purpose, and
      // the board tells the owner which ones. Reporting these as dead ends
      // produced noise in runs 7 and 8 that cost real triage time.
      guard ticket.waitingOnPrerequisites.isEmpty else { return nil }
      guard ticket.latestRunStatus != .running else { return nil }
      // A queued run only counts as progress while something is actually
      // running. A board full of queued runs and no running one is frozen,
      // however busy it claims to be.
      if ticket.latestRunStatus == .queued, context.anyRunIsRunning { return nil }
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
  ///
  /// This reads the work log, which needs the store, so it is separate from the
  /// synchronous pass. The check it replaced asked whether every run had an
  /// empty `lastActivityText` — a transient activity summary, not the work log,
  /// and never empty on a run that finished. It could not fail, so a released
  /// ticket with no handoff at all would have gone unreported.
  ///
  /// It deliberately does not judge wording. A real agent phrases a handoff
  /// differently every run, so this asserts only that a released ticket carries
  /// an agent-authored entry written no earlier than the work it describes.
  static func completionHandoffs(model: AppModel) async -> [PilotJournal.Finding] {
    var findings: [PilotJournal.Finding] = []
    for item in model.workItems where item.state == .released {
      let runs = model.runs.filter { $0.workItemID == item.id }
      let completed = runs.filter { $0.status == .completed }
      guard let finished = completed.map(\.updatedAt).max() else { continue }
      let comments = await model.comments(for: item.id, productID: item.productID)
      let handoffs = comments.filter { comment in
        comment.authorKind == .agent && comment.createdAt >= finished.addingTimeInterval(-60)
      }
      guard handoffs.isEmpty else { continue }
      let agentComments = comments.filter { $0.authorKind == .agent }
      findings.append(
        PilotJournal.Finding(
          category: .functional,
          title: "Released ticket \(item.key) left no completion handoff",
          evidence: """
            Ticket: \(item.key) \(item.title)
            Completed runs: \(completed.count)
            Work log entries: \(comments.count), of which \(agentComments.count) \
            are from the assigned team member
            Last completed run finished: \(finished)
            Most recent team member entry: \
            \(agentComments.map(\.createdAt).max().map(String.init(describing:)) ?? "none")

            A direct dependant is given this handoff and little else, so a
            released ticket without one silently starves the tickets that
            depend on it.
            """,
          locationHint: "Sources/SpeditoCore/Domain/TicketDeliveryWorkflowCoordinator.swift",
          at: Date()
        )
      )
    }
    return findings
  }

  /// A queued run means Spedito intends to start work. Sitting queued for a long
  /// time with nothing else running means the owner is watching a board that
  /// claims to be busy and is not.
  private static func stalledRuns(
    _ context: Context,
    model: AppModel
  ) -> [PilotJournal.Finding] {
    let now = Date()
    let anyRunning = model.runs.contains { $0.status == .running }
    guard !anyRunning else { return [] }
    return model.runs
      .filter { $0.status == .queued }
      .filter { now.timeIntervalSince($0.updatedAt) > queuedTolerance }
      .compactMap { run in
        guard let item = model.workItems.first(where: { $0.id == run.workItemID })
        else { return nil }
        // Waiting for a prerequisite is the dispatcher working as designed.
        let ticket = context.snapshot.tickets.first { $0.key == item.key }
        guard ticket?.waitingOnPrerequisites.isEmpty ?? true else { return nil }
        return PilotJournal.Finding(
          category: .stalled,
          title: "Ticket \(item.key) has been queued with nothing running",
          evidence: """
            Ticket: \(item.key) \(item.title)
            Ticket state: \(item.state.rawValue)
            Run queued for: \(Int(now.timeIntervalSince(run.updatedAt)))s
            Runs in this product: \(model.runs.map(\.status.rawValue).joined(separator: ", "))

            No run is running, so nothing will move this ticket on its own.

            \(admissionDiagnosis(run: run, model: model))
            """,
          locationHint: "Sources/SpeditoCore/Domain/TicketDeliveryRuntimeCoordinator.swift",
          at: now
        )
      }
  }


  /// A running agent that reports nothing is the one stall neither other check
  /// can see: `stalledRuns` only looks at queued runs, and `deadEnds` skips any
  /// ticket offering an action, which a running run always does because it
  /// offers **Stop**.
  ///
  /// Run 9 sat like this for thirty minutes. That time the cause was the product
  /// owner's connection dropping and the turn finished by itself, but a turn
  /// that dies quietly looks identical from the board, and the owner is left in
  /// front of a ticket in review with no explanation and nothing to do but stop
  /// work that may still be running.
  private static func silentRuns(
    _ context: Context,
    model: AppModel
  ) -> [PilotJournal.Finding] {
    let now = Date()
    return model.runs
      .filter { $0.status == .running }
      .compactMap { run -> PilotJournal.Finding? in
        let lastHeard = run.lastActivityAt ?? run.updatedAt
        let silentFor = now.timeIntervalSince(lastHeard)
        guard silentFor > silentRunTolerance else { return nil }
        guard let item = model.workItems.first(where: { $0.id == run.workItemID })
        else { return nil }
        let ticket = context.snapshot.tickets.first { $0.key == item.key }
        return PilotJournal.Finding(
          category: .stalled,
          title: "Ticket \(item.key)'s agent has reported nothing while still running",
          evidence: """
            Ticket: \(item.key) \(item.title)
            Ticket state: \(item.state.rawValue)
            Run status: running
            Silent for: \(Int(silentFor))s
            Last thing this run reported: \(run.lastActivityText ?? "nothing")
            Candidate: \(ticket?.candidateStatus?.rawValue ?? "none")
            What the owner can do: \
            \(ticket?.availableActions.joined(separator: ", ") ?? "nothing")

            The board says an agent is working. If its turn has ended without
            Spedito noticing, the owner waits indefinitely with no explanation.

            Rule out a dropped network connection before treating this as a
            defect: a real turn resumes on its own once the connection returns.
            """,
          locationHint: "Sources/SpeditoCore/Domain/TicketDeliveryWorkflowCoordinator.swift",
          at: now
        )
      }
  }

  /// Explains a stall using the production admission rule rather than guessing.
  /// Every reason a queued run can be refused is reported against the durable
  /// state, so a stalled run says why it is stalled.
  private static func admissionDiagnosis(run: AgentRun, model: AppModel) -> String {
    guard let plan = model.sprintPlan else {
      return "There is no sprint plan loaded, so no run can be admitted."
    }
    var lines: [String] = []
    lines.append("Sprint: \(plan.sprint.state.rawValue), \(plan.items.count) planned item(s)")

    if run.sprintID != plan.sprint.id {
      lines.append(
        "This run belongs to sprint \(run.sprintID?.uuidString ?? "none"), not the loaded one."
      )
    }
    if let item = plan.items.first(where: { $0.workItemID == run.workItemID }) {
      if item.implementerProfileID != run.profileID {
        lines.append(
          "The planned implementer differs from the run's team member, so it is never admitted."
        )
      }
    } else {
      lines.append("This ticket is not in the sprint plan, so it is never admitted.")
    }

    let itemByID = Dictionary(uniqueKeysWithValues: model.workItems.map { ($0.id, $0) })
    let prerequisites = model.dependencies
      .filter { $0.workItemID == run.workItemID }
      .map(\.dependsOnWorkItemID)
    if prerequisites.isEmpty {
      lines.append("No prerequisites, so nothing upstream is holding it.")
    } else {
      let unmet = prerequisites.filter { itemByID[$0]?.state != .released }
      lines.append(
        unmet.isEmpty
          ? "Every prerequisite is released."
          : "Waiting on \(unmet.count) unreleased prerequisite(s): "
            + unmet.map { itemByID[$0]?.key ?? "unknown" }.joined(separator: ", ")
      )
    }

    let eligible = SprintRunAdmission.eligibleImplementationRuns(
      plan: plan,
      runs: model.runs,
      workItems: model.workItems,
      dependencies: model.dependencies
    )
    lines.append(
      eligible.contains { $0.id == run.id }
        ? "Delivery considers this run eligible, so something after admission is not starting it."
        : "Delivery does not consider this run eligible."
    )
    lines.append("Eligible runs right now: \(eligible.count)")
    lines.append("Last thing this run reported: \(run.lastActivityText ?? "nothing")")
    let requests = model.permissionRequests.filter { $0.agentRunID == run.id }
    lines.append(
      requests.isEmpty
        ? "No permission request was ever raised for this run."
        : "Permission requests for this run: "
          + requests.map { "\($0.status.rawValue)" }.joined(separator: ", ")
    )
    return lines.joined(separator: "\n")
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
