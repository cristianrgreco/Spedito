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
  private lazy var notificationRecorder = PilotNotificationRecorder(journal: journal)
  private let soundPlayer = PilotSilentSoundPlayer()
  private var unchangedSince: [String: Date] = [:]
  private var lastTicketFingerprint: [String: String] = [:]
  private var reportedFindings: Set<String> = []
  private(set) var observedThreadIDs: Set<String> = []
  private var didSimulateRelaunch = false
  private var didAskMidSprintFollowUp = false
  /// The sprint being watched, remembered while its plan is still current.
  ///
  /// A finished sprint stops being the current one, so `sprintPlan` goes nil at
  /// exactly the moment the watch should end. Reading it then makes the run
  /// track the whole backlog — including tickets the owner added mid-sprint that
  /// this sprint was never going to deliver — and the watch never ends.
  private var watchedSprint: (productID: UUID, sprintID: UUID)?
  private var watchedSprintWorkItemIDs: Set<UUID> = []
  /// Questions already answered, keyed by run and question.
  ///
  /// Answering per run was enough until an agent asked a second question: the
  /// guard that stops the driver re-answering the same question on every poll
  /// also stopped it answering the new one, and the ticket sat on "needs your
  /// input" with an Answer button nobody pressed for the rest of the run. A real
  /// owner answers every question they are asked.
  private var answeredQuestions: Set<String> = []
  /// How many times the owner has retried each failed run.
  private var retryAttemptsByRunID: [UUID: Int] = [:]
  /// When each run's on-screen status first disagreed with the database.
  private var divergenceSince: [UUID: Date] = [:]

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
    let registry = try openRegistry()
    let model = AppModel(
      storeRegistry: registry,
      ownerNotificationSoundPlayer: soundPlayer,
      ownerNotificationSystemNotifier: notificationRecorder
    )
    adopt(model: model, registry: registry)
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

  /// Installs the application every later turn watches. Opening and reopening
  /// both go through here, so there is exactly one place where the model an
  /// observation reads can change.
  func adopt(model: AppModel, registry: ProductStoreRegistry? = nil) {
    self.model = model
    if let registry { self.registry = registry }
  }

  /// The one place a product database is opened, so opening and reopening
  /// cannot drift apart.
  private func openRegistry() throws -> ProductStoreRegistry {
    try ProductStoreRegistry(productWorkspacesRootURL: workspace.productWorkspacesURL)
  }

  /// Quits and reopens on the same durable root. Every durable intermediate
  /// state is required to survive this, so the driver does it mid-journey
  /// rather than at a convenient boundary.
  ///
  /// Quitting ends the process, and the process is what closes the application's
  /// SQLite connections. So the reopened application gets a new registry over
  /// the same root, and the closing one's stores are closed first. Carrying the
  /// old registry across would hand the reopened application the same live
  /// connections, and the harness would stop testing the thing it claims to.
  func simulateRelaunch() async {
    guard let closingRegistry = registry, let previous = model else { return }
    journal.record(.ownerCommand, "Quit and reopen Spedito")
    let productID = previous.selectedProductID
    let beforeTickets = previous.workItems.count
    await quit(previous, registry: closingRegistry)

    let reopenedRegistry: ProductStoreRegistry
    do {
      reopenedRegistry = try openRegistry()
    } catch {
      // Leaving the closed application installed would make every later turn
      // report its frozen board, which is the failure `superviseTick` exists to
      // prevent. A turn with nothing open reports nothing instead.
      model = nil
      registry = nil
      journal.file(
        PilotJournal.Finding(
          category: .functional,
          title: "Reopening Spedito could not open its product databases again",
          evidence: "\(error)",
          locationHint: "Sources/SpeditoCore/Persistence/ProductStoreRegistry.swift",
          at: Date()
        )
      )
      return
    }

    let reopened = AppModel(
      storeRegistry: reopenedRegistry,
      selectedProductID: productID,
      ownerNotificationSoundPlayer: soundPlayer,
      ownerNotificationSystemNotifier: notificationRecorder
    )
    adopt(model: reopened, registry: reopenedRegistry)
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

  /// What the owner does once the sprint's work is delivered.
  ///
  /// No run had ever reached this, so retrospectives and app versions had never
  /// been exercised at all — the journey stopped at the last accepted ticket.
  /// The owner looks at what the sprint produced, reads the retrospective, keeps
  /// the actions worth keeping, and closes it.
  private func closeOutTheSprint() async {
    guard let model, let watched = watchedSprint else { return }
    let productID = watched.productID
    let sprintID = watched.sprintID

    journal.record(
      .observation,
      "Sprint finished",
      detail: "\(model.appVersions.count) app version(s) recorded"
    )

    // App versions are what the owner opens to see the product they now have.
    if let version = model.appVersions.first {
      journal.record(.ownerCommand, "Open app version \(version.revisionSHA.prefix(8))")
      if await model.openAppVersion(id: version.id) == false {
        fileOnce(
          PilotJournal.Finding(
            category: .functional,
            title: "A recorded app version would not open",
            evidence: """
              Version: \(version.revisionSHA)
              \(model.errorMessage ?? "No reason given.")
              """,
            locationHint: "Sources/SpeditoApp/AppVersionsView.swift",
            at: Date()
          )
        )
      }
      await model.stopAppVersion(id: version.id)
    }

    model.prepareRetrospectiveSynthesisIfNeeded(sprintID: sprintID)
    let arrived = await waitUntil("the sprint retrospective", limit: .seconds(300)) { model in
      model.retrospectiveSyntheses.contains { $0.sprintID == sprintID }
        || model.retrospectiveNotes.contains { $0.sprintID == sprintID }
    }
    guard arrived, let model = self.model else {
      fileOnce(
        PilotJournal.Finding(
          category: .stalled,
          title: "A finished sprint never produced a retrospective",
          evidence: """
            Sprint: \(watchedSprintWorkItemIDs.count) delivered ticket(s)

            The owner is meant to learn something from a finished sprint. If
            nothing arrives they have no way to know whether it is coming.
            """,
          locationHint: "Sources/SpeditoApp/RetrospectivesView.swift",
          at: Date()
        )
      )
      return
    }

    let proposed = model.retrospectiveNotes.filter {
      $0.sprintID == sprintID && $0.actionStatus == .proposed
    }
    if !proposed.isEmpty {
      journal.record(
        .ownerCommand,
        "Accept \(proposed.count) retrospective action(s)",
        detail: proposed.map(\.body).joined(separator: "\n")
      )
      await model.decideRetrospectiveActions(proposed, accept: true)
    }

    journal.record(.ownerCommand, "Conclude the retrospective")
    if await model.concludeRetrospective(productID: productID, sprintID: sprintID) == false {
      fileOnce(
        PilotJournal.Finding(
          category: .deadEnd,
          title: "The owner could not conclude the sprint retrospective",
          evidence: model.errorMessage ?? "No reason given.",
          locationHint: "Sources/SpeditoApp/RetrospectivesView.swift",
          at: Date()
        )
      )
    }
    journal.record(.snapshot, "Board", detail: PilotSnapshotRenderer.describe(
      PilotSnapshotRenderer.render(model)
    ))
  }

  /// The owner thinks of something else while the sprint is running.
  ///
  /// This is a real product journey — planning has to work while delivery is
  /// live — and the brief catalog has claimed to exercise it since it was
  /// written, through a `midSprintFollowUp` no code ever read.
  ///
  /// The new tickets go to the backlog and deliberately not into the running
  /// sprint: adding scope to a sprint already in flight is the owner's decision
  /// to make, and the product rules are explicit that scope is never changed for
  /// them.
  private func askMidSprintFollowUp() async {
    guard let model, let followUp = brief.midSprintFollowUp else { return }
    let ticketsBefore = model.workItems.count
    journal.record(.ownerCommand, "Ask for something else mid-sprint: \(followUp)")

    guard let followUpEpic = await model.createEpicAndPlan(outcome: followUp) else {
      fileOnce(
        PilotJournal.Finding(
          category: .functional,
          title: "Spedito would not plan a new request while a sprint was running",
          evidence: """
            Asked for: \(followUp)
            \(model.errorMessage ?? "No reason given.")

            An owner thinks of things mid-sprint. Planning is read-only and must
            not be blocked by delivery running alongside it.
            """,
          locationHint: "Sources/SpeditoCore/Domain/EpicPlanningWorkflowCoordinator.swift",
          at: Date()
        )
      )
      return
    }

    // The analyst asks about a new request just as it does for the first one,
    // and every wait here is bounded. This runs inside the supervision loop, so
    // an unbounded wait would stop the owner watching delivery at all — which is
    // exactly what it did the first time this ran live.
    var suggested = false
    var rounds = 0
    while rounds < 4, Date() < deadline {
      let progressed = await waitUntil(
        "the follow-up plan",
        limit: .seconds(90)
      ) { model in
        let conversation = model.epicPlanningFeature.snapshot.conversation
        if let conversation, conversation.epicID == followUpEpic.id,
          !conversation.questions.isEmpty || conversation.errorMessage != nil
        {
          return true
        }
        return model.suggestionBatches.contains { batch in
          batch.suggestions.contains { $0.status == .proposed }
        }
      }
      guard progressed, let model = self.model else { break }
      if model.suggestionBatches.contains(where: { batch in
        batch.suggestions.contains { $0.status == .proposed }
      }) {
        suggested = true
        break
      }
      let conversation = model.epicPlanningFeature.snapshot.conversation
      if let failure = conversation?.errorMessage {
        fileOnce(
          PilotJournal.Finding(
            category: .functional,
            title: "Planning a request made during a sprint failed",
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
        "Answer \(questions.count) question(s) about the mid-sprint request",
        detail: zip(questions.map(\.prompt), reply.answers)
          .map { "\($0): \($1)" }
          .joined(separator: "\n")
      )
      model.epicPlanningWorkflowCoordinator.continueEpicPlanning(
        followUpEpic,
        answers: reply.answers,
        answeredQuestions: reply.answered
      )
      rounds += 1
      await settle(for: .seconds(2))
    }
    guard suggested, let model = self.model, let batch = model.suggestionBatches.last
    else {
      fileOnce(
        PilotJournal.Finding(
          category: .stalled,
          title: "A request made during a sprint never produced any suggested tickets",
          evidence: PilotSnapshotRenderer.describe(PilotSnapshotRenderer.render(model)),
          locationHint: "Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift",
          at: Date()
        )
      )
      return
    }

    let proposed = batch.suggestions.filter { $0.status == .proposed }
    journal.record(
      .ownerCommand,
      "Accept \(proposed.count) ticket(s) suggested mid-sprint",
      detail: proposed.map { "\($0.reference) \($0.title)" }.joined(separator: "\n")
    )
    await withCheckedContinuation { continuation in
      model.epicPlanningWorkflowCoordinator.decideAllTicketSuggestions(
        sessionID: batch.session.id,
        accept: true
      ) { _ in continuation.resume() }
    }
    await settle(for: .seconds(2))
    journal.record(
      .observation,
      "Backlog went from \(ticketsBefore) to \(self.model?.workItems.count ?? 0) ticket(s)"
    )
  }

  /// Ends the application the way quitting Spedito does.
  ///
  /// `AppModel.shutdown()` settles the workflows, but the thing that closes an
  /// application's SQLite connections is the process ending, and the pilot has
  /// no process to end. So the harness closes them, and durable state that only
  /// survived because a connection stayed open cannot pass a relaunch check.
  func quit(_ application: AppModel, registry closingRegistry: ProductStoreRegistry) async {
    await application.shutdown()
    for store in closingRegistry.allStores {
      await store.close()
    }
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

  /// The outcome of one turn of watching the board.
  enum SupervisionOutcome: Equatable {
    case keepWatching
    /// The application was replaced, so the next turn should look straight away.
    case reopened
    case everyTicketFinished
  }

  /// What one turn of watching saw and decided.
  struct SupervisionTurn {
    let board: PilotSnapshot
    let outcome: SupervisionOutcome
  }

  /// Watches delivery the way an owner watches the board: answering what is
  /// asked, opening demos when offered, accepting finished work.
  private func superviseDelivery() async throws {
    guard model != nil else { throw PilotError.notConnected }
    var tick = 0
    while Date() < deadline {
      tick += 1
      guard let turn = await superviseTick(tick) else { throw PilotError.notConnected }
      switch turn.outcome {
      case .everyTicketFinished:
        journal.record(.observation, "Every ticket finished")
        await closeOutTheSprint()
        return
      case .reopened:
        continue
      case .keepWatching:
        await settle(for: .seconds(10))
      }
    }
    journal.record(.note, "Budget exhausted before delivery finished")
  }

  /// One turn of watching, starting from whichever application is open now.
  ///
  /// Every turn reads `model` again on purpose. A relaunch replaces it, and a
  /// binding held across turns keeps reporting the closed application's board:
  /// that board froze at shutdown, so every ticket looks queued and abandoned
  /// while the reopened application is delivering the sprint normally.
  func superviseTick(_ tick: Int) async -> SupervisionTurn? {
    guard let model else { return nil }
    let snapshot = PilotSnapshotRenderer.render(model)
    trackChange(snapshot)
    observe()
    if let plan = model.sprintPlan {
      watchedSprint = (plan.sprint.productID, plan.sprint.id)
      watchedSprintWorkItemIDs.formUnion(plan.items.map(\.workItemID))
    }

    if tick % 6 == 0 {
      journal.record(.snapshot, "Board", detail: PilotSnapshotRenderer.describe(snapshot))
    }

    await reportBoardDivergence()
    await drainPermissionRequests()
    await answerTicketQuestions()
    await retryFailedWork()
    await openOfferedDemos()
    await acceptFinishedWork()

    for violation in PilotConventions.check(
      ownerFacingText: notificationRecorder.ownerFacingText
    ) {
      fileOnce(
        PilotJournal.Finding(
          category: violation.rule.contains("technical evidence")
            ? .leakedDiagnostic : .convention,
          title: violation.rule,
          evidence: "Alert text: \(violation.text)",
          locationHint: "Sources/SpeditoApp/OwnerNotificationCoordinator.swift",
          at: Date()
        )
      )
    }

    for violation in PilotConventions.checkAlertTitles(
      notificationRecorder.ownerFacingTitles
    ) {
      fileOnce(
        PilotJournal.Finding(
          category: .convention,
          title: violation.rule,
          evidence: "Alert title: \(violation.text)",
          locationHint: "Sources/SpeditoCore/Domain/EpicPlanningWorkflowCoordinator.swift",
          at: Date()
        )
      )
    }

    for finding in await PilotInvariants.completionHandoffs(model: model) {
      fileOnce(finding)
    }

    for finding in PilotInvariants.check(
      PilotInvariants.Context(
        snapshot: snapshot,
        brief: brief,
        unchangedSince: unchangedSince,
        anyRunIsRunning: model.runs.contains { $0.status == .running }
      ),
      model: model
    ) {
      fileOnce(finding)
    }

    if !didSimulateRelaunch, tick > 10, snapshot.isAgentWorking {
      didSimulateRelaunch = true
      await simulateRelaunch()
      return SupervisionTurn(board: snapshot, outcome: .reopened)
    }

    if didSimulateRelaunch, !didAskMidSprintFollowUp, snapshot.isAgentWorking,
      brief.midSprintFollowUp != nil
    {
      didAskMidSprintFollowUp = true
      await askMidSprintFollowUp()
    }

    // The sprint's tickets, not the backlog's. An owner who asks for something
    // new mid-sprint puts tickets in the backlog that this sprint was never
    // going to deliver, and waiting for those would burn the whole budget after
    // the sprint had actually finished.
    let sprintTickets = model.workItems.filter { watchedSprintWorkItemIDs.contains($0.id) }
    let tracked = sprintTickets.isEmpty ? model.workItems : sprintTickets
    let finished = tracked.allSatisfy { item in
      item.state == .released || item.state == .cancelled
    }
    if finished, !tracked.isEmpty {
      return SupervisionTurn(board: snapshot, outcome: .everyTicketFinished)
    }

    return SupervisionTurn(board: snapshot, outcome: .keepWatching)
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

  /// Retries delivery that stopped unexpectedly, which is what the board's
  /// **Retry work** button does. Without this the run sits failed for the rest
  /// of the budget while the owner is being offered the very action that would
  /// move it, and everything downstream of that ticket never runs.
  ///
  /// Capped per run. An owner would try again once or twice and then stop, and
  /// an uncapped retry would spend the whole budget on a ticket that cannot
  /// succeed.
  private func retryFailedWork() async {
    guard let model else { return }
    for item in model.workItems {
      guard
        let failed = model.runs
          .filter({ $0.workItemID == item.id })
          .max(by: { $0.updatedAt < $1.updatedAt }),
        failed.status == .failed || failed.status == .interrupted
      else { continue }
      let attempts = retryAttemptsByRunID[failed.id, default: 0]
      guard attempts < 2 else { continue }
      retryAttemptsByRunID[failed.id] = attempts + 1

      if model.canRetryFailedPostReviewDemo(workItemID: item.id) {
        journal.record(.ownerCommand, "Retry the demo for \(item.key)")
        _ = await model.retryFailedPostReviewDemo(workItemID: item.id)
        await settle(for: .seconds(2))
        continue
      }

      let direction = owner.directionAfterFailure(
        ticketTitle: item.title,
        lastActivity: failed.lastActivityText
      )
      journal.record(
        .ownerCommand,
        "Retry work on \(item.key)",
        detail: "attempt \(attempts + 1)\ndirection: \(direction)"
      )
      _ = await model.resumeSprintWork(
        productID: item.productID,
        workItemID: item.id,
        body: direction,
        answeredQuestions: []
      )
      await settle(for: .seconds(2))
    }
  }

  /// Answers the agent's question and resumes the run, which is what the ticket
  /// sheet does. Appending a comment alone records the reply without releasing
  /// delivery, so the run would sit awaiting the owner forever.
  private func answerTicketQuestions() async {
    guard let model else { return }
    for item in model.workItems {
      // The board takes the most recently updated awaiting run, not any of them.
      guard
        let awaiting = model.runs
          .filter({ $0.workItemID == item.id && $0.status == .awaitingOwner })
          .max(by: { $0.updatedAt < $1.updatedAt })
      else { continue }
      // A pending permission request is answered by the permission flow instead.
      guard model.pendingPermissionRequest(workItemID: item.id) == nil else { continue }
      let comments = await model.comments(for: item.id, productID: item.productID)
      let presented = presentedQuestion(in: comments)
      let questionText = presented?.question.prompt
        ?? awaiting.lastActivityText
        ?? "The agent is waiting for me."
      let questionKey = "\(awaiting.id)|\(questionText)"
      guard !answeredQuestions.contains(questionKey) else { continue }
      answeredQuestions.insert(questionKey)
      let selectedOption = presented?.question.options.first
      let reply = selectedOption ?? owner.replyToTicketQuestion(questionText)
      let answered = presented.map { presentation in
        [
          TicketAnsweredQuestion(
            question: TicketRefinementQuestion(
              prompt: presentation.question.prompt,
              options: presentation.question.options
            ),
            selectedOption: selectedOption,
            answer: reply
          )
        ]
      } ?? []

      journal.record(
        .ownerCommand,
        "Reply on \(item.key)",
        detail: "asked: \(questionText)\nreplied: \(reply)"
      )
      let resumed = await model.resumeSprintWork(
        productID: item.productID,
        workItemID: item.id,
        body: reply,
        answeredQuestions: answered
      )
      if resumed == nil {
        fileOnce(
          PilotJournal.Finding(
            category: .deadEnd,
            title: "Answering the agent's question did not resume the ticket",
            evidence: """
              Ticket: \(item.key) \(item.title)
              Asked: \(questionText)
              Replied: \(reply)
              Error: \(model.errorMessage ?? "none")
              """,
            locationHint: "Sources/SpeditoApp/AppModel.swift",
            at: Date()
          )
        )
      }
    }
  }

  /// The question the ticket sheet would show: the newest agent comment that
  /// carries a structured question, falling back to a parsed legacy body.
  private func presentedQuestion(
    in comments: [TicketComment]
  ) -> TicketOwnerQuestionPresentation? {
    let agentComments = comments.filter { $0.authorKind == .agent }
    if let structured = agentComments.last(where: { $0.ownerQuestion != nil }) {
      return TicketOwnerQuestion.presentation(
        in: structured.body,
        structuredQuestion: structured.ownerQuestion
      )
    }
    guard let latest = agentComments.last else { return nil }
    return TicketOwnerQuestion.presentation(in: latest.body, structuredQuestion: nil)
  }

  private func openOfferedDemos() async {
    guard let model else { return }
    for candidate in model.candidateRevisions where candidate.status == .readyForDemo {
      let alreadyRunning = model.demoSessions.contains { $0.status.isActive }
      guard !alreadyRunning else { continue }
      let offered = demoKind(of: candidate)
      journal.record(
        .ownerCommand,
        "Open the demo for \(candidate.branchName)",
        detail: "Demo kind: \(offered?.rawValue ?? "none declared"), "
          + "expected \(brief.expectedDemoKind.rawValue)"
      )
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

  /// The presentation the candidate declares, which is what the owner is about
  /// to be shown.
  ///
  /// The brief catalog is organised by `DemoPresentationKind`, because demo
  /// preparation is where owner-visible delivery most often breaks. Until now a
  /// run's evidence never recorded which kind it actually reached, so "this
  /// brief exercises `macApplication`" was an intention rather than a fact. A
  /// mismatch is recorded, not filed: the agent may reasonably choose a
  /// different presentation, and this loop has paid for noisy findings before.
  private func demoKind(of candidate: CandidateRevision) -> DemoPresentationKind? {
    try? CodexTicketExecutor.decode(candidate.executionResultJSON).demo?.presentation.kind
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


  /// The board is a projection of durable state, so a run's on-screen status
  /// must agree with the database. A lasting disagreement means the owner is
  /// reading a stale board: work is moving and the board says it is not.
  private func reportBoardDivergence() async {
    guard let model, let productID = model.selectedProductID,
      let store = model.store(for: productID)
    else { return }
    guard let durableRuns = try? await store.fetchAgentRuns(productID: productID) else {
      return
    }
    let onScreen = Dictionary(
      model.runs.map { ($0.id, $0.status) },
      uniquingKeysWith: { first, _ in first }
    )
    let now = Date()
    for durable in durableRuns {
      // A run the board has never heard of is the strongest form of staleness:
      // the owner is not being shown that this work exists at all.
      let shown = onScreen[durable.id]
      guard shown != durable.status else {
        divergenceSince[durable.id] = nil
        continue
      }
      let since = divergenceSince[durable.id] ?? now
      divergenceSince[durable.id] = since
      guard now.timeIntervalSince(since) > 60 else { continue }
      let item = model.workItems.first { $0.id == durable.workItemID }
      fileOnce(
        PilotJournal.Finding(
          category: .functional,
          title: "The board keeps showing a stale status for \(item?.key ?? "a ticket")",
          evidence: """
            Ticket: \(item?.key ?? "unknown") \(item?.title ?? "")
            On screen: \(shown?.rawValue ?? "not shown at all")
            In the database: \(durable.status.rawValue)
            Disagreeing for: \(Int(now.timeIntervalSince(since)))s

            Presentation state is a projection of durable state. While these
            disagree the owner is watching a board that is not telling the truth
            about what the agent is doing.
            """,
          locationHint: "Sources/SpeditoApp/AppModel.swift",
          at: now
        )
      )
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

  /// Waits for something the owner is entitled to see.
  ///
  /// `limit` bounds a wait that would otherwise run to the whole run deadline.
  /// A step near the end of the journey can have most of the budget left, and
  /// spending it polling for something that is never coming holds the machine
  /// for nothing — which is exactly how a run gets described as taking an hour
  /// when it finished in twenty minutes.
  private func waitUntil(
    _ what: String,
    poll: Duration = .seconds(3),
    limit: Duration? = nil,
    condition: @MainActor (AppModel) -> Bool
  ) async -> Bool {
    let until = limit.map {
      min(deadline, Date().addingTimeInterval(Self.seconds(in: $0)))
    } ?? deadline
    while Date() < until {
      // Read the application every pass for the same reason `superviseTick`
      // does: a relaunch replaces it, and a binding held across passes waits
      // forever on a board that stopped changing when it was closed.
      guard let model else { return false }
      if condition(model) { return true }
      observe()
      await settle(for: poll)
    }
    journal.record(.note, "Gave up waiting for \(what)")
    return false
  }

  private nonisolated static func seconds(in duration: Duration) -> TimeInterval {
    TimeInterval(duration.components.seconds)
      + TimeInterval(duration.components.attoseconds) / 1e18
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
