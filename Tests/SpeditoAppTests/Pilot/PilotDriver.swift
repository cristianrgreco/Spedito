import Foundation
import SpeditoCore

@testable import SpeditoApp

/// Runs one product through Spedito the way the product owner does.
///
/// The driver only ever calls commands a view could call, and only ever reads
/// state a view could read, so anything it cannot do the owner cannot do either.
@MainActor
final class PilotDriver {
  private let brief: PilotBrief
  private let journal: PilotJournal
  private let workspace: PilotWorkspace
  private let deadline: Date
  private let owner: PilotOwner

  private var model: AppModel?
  private var registry: ProductStoreRegistry?
  private var unchangedSince: [String: Date] = [:]
  private var lastTicketFingerprint: [String: String] = [:]
  private var reportedFindings: Set<String> = []
  private(set) var observedThreadIDs: Set<String> = []
  private var didSimulateRelaunch = false

  init(brief: PilotBrief, journal: PilotJournal, workspace: PilotWorkspace, deadline: Date) {
    self.brief = brief
    self.journal = journal
    self.workspace = workspace
    self.deadline = deadline
    owner = PilotOwner(brief: brief, journal: journal)
  }

  func run() async throws {
    try await startApplication()
    try await createProduct()
    try await requestTheProduct()
    try await acceptThePlan()
    try await planAndStartSprint()
    try await superviseDelivery()
  }

  // MARK: - Application lifecycle

  private func startApplication() async throws {
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: workspace.productWorkspacesURL
    )
    self.registry = registry
    let model = AppModel(storeRegistry: registry)
    self.model = model
    journal.record(.ownerCommand, "Open Spedito")
    await model.load()
    observe()
    guard model.codexConnectionState.isConnected else {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "Spedito could not connect to Codex, so no product can be built",
          evidence: PilotSnapshotRenderer.describe(PilotSnapshotRenderer.render(model)),
          locationHint: "Sources/SpeditoApp/CodexInstallation.swift",
          at: Date()
        )
      )
      throw PilotError.notConnected
    }
  }

  /// Quits and reopens on the same durable root. Every durable intermediate
  /// state is required to survive this, so the driver does it mid-journey
  /// rather than at a convenient boundary.
  private func simulateRelaunch() async {
    guard let registry, let previous = model else { return }
    journal.record(.ownerCommand, "Quit and reopen Spedito")
    let productID = previous.selectedProductID
    let beforeTickets = previous.workItems.count
    await previous.shutdown()

    let reopened = AppModel(storeRegistry: registry, selectedProductID: productID)
    model = reopened
    await reopened.load()
    observe()

    let afterTickets = reopened.workItems.count
    if afterTickets < beforeTickets {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "Reopening Spedito lost tickets that were on screen before",
          evidence: "Before: \(beforeTickets) tickets. After: \(afterTickets).",
          locationHint: "Sources/SpeditoApp/AppModel.swift",
          at: Date()
        )
      )
    }
    if reopened.selectedProductID != productID {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "Reopening Spedito did not restore the product I was working on",
          evidence: "Expected \(productID?.uuidString ?? "none"), got "
            + "\(reopened.selectedProductID?.uuidString ?? "none").",
          locationHint: "Sources/SpeditoApp/AppModel.swift",
          at: Date()
        )
      )
    }
    journal.record(.observation, "Reopened with \(afterTickets) ticket(s)")
  }

  // MARK: - Owner journey

  private func createProduct() async throws {
    guard let model else { throw PilotError.notConnected }
    journal.record(.ownerCommand, "Create product \"\(brief.productName)\"")
    let request: ProductCreationRequest
    switch brief.source {
    case .blank:
      request = .blank(name: brief.productName)
    case .publicRepository(let url):
      guard !url.isEmpty else {
        throw PilotError.invalidBrief(
          "The import brief needs a repository. Set SPEDITO_PILOT_REPO."
        )
      }
      let source = try PublicGitRepositoryURL(url)
      request = .importRepository(name: brief.productName, source: source)
    }
    let created = await model.createProductAndSelect(request)
    guard created else {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "Creating a product failed",
          evidence: model.productCreationError ?? model.errorMessage ?? "No reason given.",
          locationHint: "Sources/SpeditoApp/AppModel.swift",
          at: Date()
        )
      )
      throw PilotError.commandRefused("createProductAndSelect")
    }
    await settle(for: .seconds(2))
  }

  private func requestTheProduct() async throws {
    guard let model else { throw PilotError.notConnected }
    journal.record(.ownerCommand, "Ask for: \(brief.outcome)")
    guard let epic = await model.createEpicAndPlan(outcome: brief.outcome) else {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "Spedito did not start planning the request",
          evidence: model.errorMessage ?? "No reason given.",
          locationHint: "Sources/SpeditoCore/Domain/EpicPlanningWorkflowCoordinator.swift",
          at: Date()
        )
      )
      throw PilotError.commandRefused("createEpicAndPlan")
    }

    // Answer clarification rounds until the plan is ready or the budget runs out.
    var rounds = 0
    while Date() < deadline, rounds < 8 {
      let progressed = await waitUntil("clarification or plan") { model in
        let conversation = model.epicPlanningFeature.snapshot.conversation
        guard let conversation, conversation.epicID == epic.id else { return false }
        if !conversation.questions.isEmpty { return true }
        if conversation.isComplete { return true }
        if conversation.errorMessage != nil { return true }
        return !model.suggestionBatches.isEmpty
      }
      guard progressed else { break }

      let conversation = model.epicPlanningFeature.snapshot.conversation
      if let failure = conversation?.errorMessage {
        journal.file(
          PilotJournal.Finding(
            category: .functional,
            title: "Planning the request failed",
            evidence: failure,
            locationHint: "Sources/SpeditoCore/Domain/EpicPlanningWorkflowCoordinator.swift",
            at: Date()
          )
        )
        return
      }
      guard let questions = conversation?.questions, !questions.isEmpty else { break }

      let reply = owner.answers(to: questions)
      journal.record(
        .ownerCommand,
        "Answer \(questions.count) question(s)",
        detail: zip(questions.map(\.prompt), reply.answers)
          .map { "\($0): \($1)" }
          .joined(separator: "\n")
      )
      model.epicPlanningWorkflowCoordinator.continueEpicPlanning(
        epic,
        answers: reply.answers,
        answeredQuestions: reply.answered
      )
      rounds += 1
      await settle(for: .seconds(2))
    }

    if rounds == 0, brief.id == "vague-dashboard" {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "A deliberately vague request produced a plan without asking anything",
          evidence: """
            Request: \(brief.outcome)

            A normal ticket should deliver an agreed outcome rather than defer
            deciding what that outcome is, so a request this thin should have
            produced at least one consequential question.
            """,
          locationHint: "Sources/SpeditoCore/Codex/CodexEpicClarificationGenerator.swift",
          at: Date()
        )
      )
    }
  }

  private func acceptThePlan() async throws {
    guard let model else { throw PilotError.notConnected }
    let arrived = await waitUntil("suggested tickets") { model in
      model.suggestionBatches.contains { batch in
        batch.suggestions.contains { $0.status == .proposed }
      }
    }
    guard arrived, let batch = model.suggestionBatches.last else {
      journal.file(
        PilotJournal.Finding(
          category: .stalled,
          title: "No tickets were ever suggested for the request",
          evidence: PilotSnapshotRenderer.describe(PilotSnapshotRenderer.render(model)),
          locationHint: "Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift",
          at: Date()
        )
      )
      throw PilotError.stalled("ticket suggestions")
    }

    let proposed = batch.suggestions.filter { $0.status == .proposed }
    journal.record(
      .ownerCommand,
      "Accept \(proposed.count) suggested ticket(s)",
      detail: proposed.map { "\($0.reference) \($0.title)" }.joined(separator: "\n")
    )
    await withCheckedContinuation { continuation in
      model.epicPlanningWorkflowCoordinator.decideAllTicketSuggestions(
        sessionID: batch.session.id,
        accept: true
      ) { _ in continuation.resume() }
    }
    await settle(for: .seconds(2))
    journal.record(.observation, "Backlog now has \(model.workItems.count) ticket(s)")
  }

  private func planAndStartSprint() async throws {
    guard let model else { throw PilotError.notConnected }
    let ready = model.workItems.filter { $0.state == .ready || $0.state == .backlog }
    guard !ready.isEmpty else {
      journal.file(
        PilotJournal.Finding(
          category: .deadEnd,
          title: "No ticket could be put into a sprint after accepting the plan",
          evidence: PilotSnapshotRenderer.describe(PilotSnapshotRenderer.render(model)),
          locationHint: "Sources/SpeditoApp/SprintPlanningView.swift",
          at: Date()
        )
      )
      throw PilotError.stalled("sprint planning")
    }

    let implementer = model.profiles.first { $0.role == .implementer }
    let reviewer = model.profiles.first { $0.role == .lead }
      ?? model.profiles.first { $0.role == .reviewer }
    let items = ready.map { item in
      SprintDraftItemInput(
        workItemID: item.id,
        implementerProfileID: implementer?.id,
        reviewerProfileID: reviewer?.id
      )
    }
    journal.record(.ownerCommand, "Plan a sprint with \(items.count) ticket(s)")
    let saved = await model.saveSprintPlan(goal: brief.outcome, items: items)
    guard saved else {
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "The sprint plan could not be saved",
          evidence: model.errorMessage ?? "No reason given.",
          locationHint: "Sources/SpeditoCore/Domain/SprintPlanningWorkflowCoordinator.swift",
          at: Date()
        )
      )
      throw PilotError.commandRefused("saveSprintPlan")
    }

    if !model.sprintReadinessIssues.isEmpty {
      journal.record(
        .observation,
        "Sprint blockers",
        detail: model.sprintReadinessIssues.map(\.message).joined(separator: "\n")
      )
    }
    journal.record(.ownerCommand, "Start sprint")
    let started = await model.startSprint()
    guard started else {
      journal.file(
        PilotJournal.Finding(
          category: .deadEnd,
          title: "The sprint would not start and the blockers do not explain why",
          evidence: """
            Blockers: \(model.sprintReadinessIssues.map(\.message).joined(separator: "; "))
            Error: \(model.errorMessage ?? "none")
            """,
          locationHint: "Sources/SpeditoApp/SprintPlanningView.swift",
          at: Date()
        )
      )
      throw PilotError.commandRefused("startSprint")
    }
  }

  /// Watches delivery the way an owner watches the board: answering what is
  /// asked, opening demos when offered, accepting finished work.
  private func superviseDelivery() async throws {
    guard let model else { throw PilotError.notConnected }
    var tick = 0
    while Date() < deadline {
      tick += 1
      let snapshot = PilotSnapshotRenderer.render(model)
      trackChange(snapshot)
      observe()

      if tick % 6 == 0 {
        journal.record(.snapshot, "Board", detail: PilotSnapshotRenderer.describe(snapshot))
      }

      await drainPermissionRequests()
      await answerTicketQuestions()
      await openOfferedDemos()
      await acceptFinishedWork()

      for finding in PilotInvariants.check(
        PilotInvariants.Context(
          snapshot: snapshot,
          brief: brief,
          unchangedSince: unchangedSince
        ),
        model: model
      ) {
        fileOnce(finding)
      }

      if !didSimulateRelaunch, tick > 10, snapshot.isAgentWorking {
        didSimulateRelaunch = true
        await simulateRelaunch()
        continue
      }

      let finished = model.workItems.allSatisfy { item in
        item.state == .released || item.state == .cancelled
      }
      if finished, !model.workItems.isEmpty {
        journal.record(.observation, "Every ticket finished")
        return
      }

      await settle(for: .seconds(10))
    }
    journal.record(.note, "Budget exhausted before delivery finished")
  }

  // MARK: - Owner reactions

  private func drainPermissionRequests() async {
    guard let model else { return }
    for request in model.permissionRequests where request.status == .pending {
      let decision = owner.decision(for: request)
      journal.record(
        .ownerCommand,
        decision.allow ? "Allow access" : "Refuse access",
        detail: "\(request.title)\n\(request.detail)\nreason: \(request.reason ?? "none")"
      )
      await model.decidePermissionRequest(
        request,
        allow: decision.allow,
        rememberForProduct: decision.remember
      )
    }
  }

  private func answerTicketQuestions() async {
    guard let model else { return }
    for item in model.workItems {
      let awaiting = model.runs.contains {
        $0.workItemID == item.id && $0.status == .awaitingOwner
      }
      guard awaiting else { continue }
      guard model.pendingPermissionRequest(workItemID: item.id) == nil else { continue }
      let question = model.runs
        .first { $0.workItemID == item.id && $0.status == .awaitingOwner }?
        .lastActivityText ?? "The agent is waiting for me."
      let reply = owner.replyToTicketQuestion(question)
      journal.record(
        .ownerCommand,
        "Reply on \(item.key)",
        detail: "asked: \(question)\nreplied: \(reply)"
      )
      _ = await model.appendOwnerComment(
        workItemID: item.id,
        productID: item.productID,
        body: reply
      )
    }
  }

  private func openOfferedDemos() async {
    guard let model else { return }
    for candidate in model.candidateRevisions where candidate.status == .readyForDemo {
      let alreadyRunning = model.demoSessions.contains { $0.status.isActive }
      guard !alreadyRunning else { continue }
      journal.record(.ownerCommand, "Open the demo for \(candidate.branchName)")
      let launched = await model.launchDemo(for: candidate)
      if !launched {
        fileOnce(
          PilotJournal.Finding(
            category: .functional,
            title: "The demo would not open for work that is ready to show",
            evidence: """
              Candidate: \(candidate.branchName) version \(candidate.version)
              Delivery kind: \(candidate.deliveryKind.rawValue)
              Expected demo kind: \(brief.expectedDemoKind.rawValue)
              Error: \(model.errorMessage ?? "none")
              Sessions: \(model.demoSessions.map(\.status.rawValue).joined(separator: ", "))
              """,
            locationHint: "Sources/SpeditoApp/MacOSDemoLauncher.swift",
            at: Date()
          )
        )
      }
    }
  }

  private func acceptFinishedWork() async {
    guard let model else { return }
    for item in model.workItems where item.state == .acceptance {
      journal.record(.ownerCommand, "Accept \(item.key)")
      let began = model.beginSprintTicketAcceptance(item)
      if !began {
        fileOnce(
          PilotJournal.Finding(
            category: .deadEnd,
            title: "Finished work could not be accepted",
            evidence: """
              Ticket: \(item.key) \(item.title)
              State: \(item.state.rawValue)
              Error: \(model.errorMessage ?? "none")
              """,
            locationHint: "Sources/SpeditoCore/Domain/TicketDeliveryWorkflowCoordinator.swift",
            at: Date()
          )
        )
      }
      await settle(for: .seconds(2))
    }
  }

  // MARK: - Observation helpers

  private func observe() {
    guard let model else { return }
    observedThreadIDs.formUnion(model.runs.compactMap(\.codexThreadID))
  }

  /// Remembers when each ticket last looked different, so a stall is measured
  /// from the last visible change rather than from the start of the run.
  private func trackChange(_ snapshot: PilotSnapshot) {
    let now = Date()
    for ticket in snapshot.tickets {
      let fingerprint = [
        ticket.state.rawValue,
        ticket.latestRunStatus?.rawValue ?? "-",
        ticket.candidateStatus?.rawValue ?? "-",
        ticket.needsInput ? "needs-input" : "-",
        ticket.availableActions.joined(separator: ","),
      ].joined(separator: "|")
      if lastTicketFingerprint[ticket.key] != fingerprint {
        lastTicketFingerprint[ticket.key] = fingerprint
        unchangedSince[ticket.key] = now
      }
    }
  }

  /// One defect should be reported once, however many polling ticks observe it.
  private func fileOnce(_ finding: PilotJournal.Finding) {
    let key = "\(finding.category.rawValue)|\(finding.title)"
    guard !reportedFindings.contains(key) else { return }
    reportedFindings.insert(key)
    journal.file(finding)
    journal.writeFindingsReport()
  }

  private func waitUntil(
    _ what: String,
    poll: Duration = .seconds(3),
    condition: @MainActor (AppModel) -> Bool
  ) async -> Bool {
    guard let model else { return false }
    while Date() < deadline {
      if condition(model) { return true }
      observe()
      await settle(for: poll)
    }
    journal.record(.note, "Gave up waiting for \(what)")
    return false
  }

  private func settle(for duration: Duration) async {
    try? await Task.sleep(for: duration)
  }
}

enum PilotError: Error, CustomStringConvertible {
  case notConnected
  case commandRefused(String)
  case stalled(String)
  case invalidBrief(String)

  var description: String {
    switch self {
    case .notConnected: "Spedito was not connected to Codex."
    case .commandRefused(let command): "The app refused \(command)."
    case .stalled(let what): "Nothing happened while waiting for \(what)."
    case .invalidBrief(let detail): detail
    }
  }
}

extension CodexConnectionState {
  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

/// Demo statuses that mean a session is already on its way up, extracted so the
/// type checker does not have to solve a long chain of comparisons.
extension DemoSessionStatus {
  static let activeStatuses: Set<DemoSessionStatus> = [.preparing, .starting, .ready]
  var isActive: Bool { DemoSessionStatus.activeStatuses.contains(self) }
}
