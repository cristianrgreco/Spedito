import SpeditoCore
import SwiftUI

enum SprintGoalSuggestionPolicy {
  static func shouldGenerate(existingGoal: String) -> Bool {
    existingGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

struct SprintPlanningScope {
  static func items(in plan: SprintPlan?, from workItems: [WorkItem]) -> [WorkItem] {
    guard let plan else { return [] }
    let scopedIDs = Set(plan.items.map(\.workItemID))
    return workItems.filter { scopedIDs.contains($0.id) }
  }
}

struct SprintPlanningWavePolicy {
  static func groups(
    items: [WorkItem],
    dependencies: [WorkItemDependency]
  ) -> [[WorkItem]] {
    let scopedIDs = Set(items.map(\.id))
    let dependenciesByItem = Dictionary(
      grouping: dependencies.filter {
        scopedIDs.contains($0.workItemID) && scopedIDs.contains($0.dependsOnWorkItemID)
      },
      by: \.workItemID
    )
    var waveByItem: [UUID: Int] = [:]
    var remaining = items
    while !remaining.isEmpty {
      var progressed = false
      for item in remaining {
        let prerequisiteIDs = dependenciesByItem[item.id, default: []].map(
          \.dependsOnWorkItemID
        )
        guard prerequisiteIDs.allSatisfy({ waveByItem[$0] != nil }) else { continue }
        waveByItem[item.id] = (prerequisiteIDs.compactMap { waveByItem[$0] }.max() ?? 0) + 1
        remaining.removeAll { $0.id == item.id }
        progressed = true
      }
      if !progressed {
        let fallback = (waveByItem.values.max() ?? 0) + 1
        for item in remaining {
          waveByItem[item.id] = fallback
        }
        remaining.removeAll()
      }
    }
    return Dictionary(grouping: items, by: { waveByItem[$0.id] ?? 1 })
      .sorted { $0.key < $1.key }
      .map { $0.value.sorted { $0.rank < $1.rank } }
  }
}

struct SprintPlanningSummaryPresentation: Equatable {
  let scopeCount: Int
  let waveCount: Int
  let tokenLow: Int
  let tokenHigh: Int
  let elapsedLowSeconds: Int
  let elapsedHighSeconds: Int
  let riskCount: Int
  let ownerReviewCount: Int
  let remainingUsagePercent: Int?

  init(
    waves: [[SprintPlanningLine]],
    rateLimits: CodexRateLimitsSnapshot?
  ) {
    let lines = waves.flatMap { $0 }
    scopeCount = lines.count
    waveCount = waves.count
    tokenLow = lines.reduce(0) { $0 + $1.forecast.tokenLow }
    tokenHigh = lines.reduce(0) { $0 + $1.forecast.tokenHigh }
    elapsedLowSeconds = waves.reduce(0) {
      $0 + ($1.map(\.forecast.durationLowSeconds).max() ?? 0)
    }
    elapsedHighSeconds = waves.reduce(0) {
      $0 + ($1.map(\.forecast.durationHighSeconds).max() ?? 0)
    }
    riskCount = lines.reduce(0) { $0 + $1.risks.count }
    ownerReviewCount = lines.count
    if rateLimits?.reachedLimitType != nil {
      remainingUsagePercent = 0
    } else {
      remainingUsagePercent = rateLimits?.windows
        .map(\.availablePercent)
        .min()
        .map { Int($0.rounded(.down)) }
    }
  }
}

struct SprintPlanningTicketProposalPolicy {
  static func conflict(
    proposal: SprintPlanningTicketProposal,
    baseSnapshot: SprintPlanningTicketSnapshot,
    currentSnapshot: SprintPlanningTicketSnapshot,
    storedVersion: Int?
  ) -> String? {
    guard proposal.baseVersion == baseSnapshot.version else {
      return "The proposal does not target the ticket version that was sent to the agent."
    }
    guard currentSnapshot == baseSnapshot else {
      return
        "You edited the ticket after this request. Save your edits and ask again before applying the proposal."
    }
    guard storedVersion == baseSnapshot.version else {
      return "The saved ticket changed after this request. Reload it before applying the proposal."
    }
    return nil
  }
}

struct SprintPlanningDraftAssignments: Equatable {
  private(set) var saved: [UUID: UUID]
  private(set) var selected: [UUID: UUID]

  init(saved: [UUID: UUID] = [:]) {
    self.saved = saved
    selected = saved
  }

  var hasUnsavedChanges: Bool {
    selected != saved
  }

  mutating func select(_ profileID: UUID?, for workItemID: UUID) {
    if let profileID {
      selected[workItemID] = profileID
    } else {
      selected.removeValue(forKey: workItemID)
    }
  }

  mutating func markSaved() {
    saved = selected
  }

  mutating func discardChanges() {
    selected = saved
  }
}

struct SprintPlanningView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onSaved: (UUID) -> Void
  @State private var didPrepare = false
  @State private var isSaving = false
  @State private var assignments = SprintPlanningDraftAssignments()
  @State private var isShowingDiscardConfirmation = false

  @State private var isShowingTicketReview = false
  private var sprintNumber: Int {
    model.candidateSprintPlan?.sprint.number ?? 1
  }

  private var scopedItems: [WorkItem] {
    SprintPlanningScope.items(in: model.candidateSprintPlan, from: model.workItems)
  }

  private var sprintItemsByWorkItemID: [UUID: SprintItem] {
    Dictionary(
      uniqueKeysWithValues: (model.candidateSprintPlan?.items ?? []).map {
        ($0.workItemID, $0)
      }
    )
  }

  private var deliveryProfiles: [AgentProfile] {
    model.profiles.filter(\.role.canOwnDelivery)
  }

  private var waves: [[SprintPlanningLine]] {
    SprintPlanningWavePolicy.groups(
      items: scopedItems,
      dependencies: model.dependencies
    ).map { wave in
      wave.map { item in
        SprintPlanningLine(
          item: item,
          owner: resolvedOwner(for: item),
          forecast: SprintForecast.estimate(for: item),
          wave: 0,
          risks: risks(
            for: item,
            scopedIDs: Set(scopedItems.map(\.id))
          )
        )
      }
    }
  }

  private var lines: [SprintPlanningLine] {
    waves.flatMap { $0 }
  }

  private var summary: SprintPlanningSummaryPresentation {
    SprintPlanningSummaryPresentation(
      waves: waves,
      rateLimits: model.codexRateLimits
    )
  }

  private var canSave: Bool {
    !lines.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Plan sprint \(sprintNumber)")
            .font(.title.bold())
          Text("Confirm the delivery order and forecast for the sprint as a whole.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !scopedItems.isEmpty {
          Button("Review tickets with team") {
            isShowingTicketReview = true
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
        }
        Button("Close") { requestClose() }
      }

      if scopedItems.isEmpty {
        ContentUnavailableView(
          "No tickets in sprint \(sprintNumber)",
          systemImage: "checklist.unchecked",
          description: Text("Return to the backlog and drag work into the sprint first.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {

        HStack(spacing: 10) {
          SprintPlanningMetric(
            title: "Scope",
            value:
              "\(summary.scopeCount) \(summary.scopeCount == 1 ? "ticket" : "tickets")",
            detail: "ranked backlog order",
            symbol: "checklist"
          )
          SprintPlanningMetric(
            title: "Execution",
            value:
              "\(summary.waveCount) \(summary.waveCount == 1 ? "wave" : "waves")",
            detail: "dependency order",
            symbol: "point.3.connected.trianglepath.dotted"
          )
          SprintPlanningMetric(
            title: "Token forecast",
            value: "\(compactTokens(summary.tokenLow))–\(compactTokens(summary.tokenHigh))",
            detail: "planning range",
            symbol: "gauge.with.dots.needle.33percent"
          )
          SprintPlanningMetric(
            title: "Elapsed time",
            value:
              "\(duration(summary.elapsedLowSeconds))–\(duration(summary.elapsedHighSeconds))",
            detail: "agent work, not a deadline",
            symbol: "clock"
          )
          SprintPlanningMetric(
            title: "Owner review",
            value:
              "\(summary.ownerReviewCount) \(summary.ownerReviewCount == 1 ? "demo" : "demos")",
            detail: "acceptance load",
            symbol: "person.crop.circle.badge.checkmark"
          )
          SprintPlanningMetric(
            title: "Remaining usage",
            value: summary.remainingUsagePercent.map { "\($0)% available" } ?? "Unavailable",
            detail:
              summary.remainingUsagePercent == nil
              ? "Connect Codex to check"
              : "most constrained window",
            symbol: "chart.bar"
          )
        }

        if summary.riskCount > 0 {
          VStack(alignment: .leading, spacing: 9) {
            Label("Plan needs attention", systemImage: "exclamationmark.triangle.fill")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.orange)
            Text(
              "Resolve \(summary.riskCount) \(summary.riskCount == 1 ? "issue" : "issues") before this sprint can start."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(lines.filter { !$0.risks.isEmpty }) { line in
              ForEach(line.risks, id: \.self) { risk in
                Text("\(line.item.key): \(risk)")
                  .font(.caption.weight(.medium))
              }
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .stroke(.orange.opacity(0.22), lineWidth: 1)
          }
          .accessibilityIdentifier("sprint.plan.risks")
        }

        VStack(alignment: .leading, spacing: 0) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Sprint scope")
                .font(.headline)
              Text("Choose the delivery assignee for every ticket before starting the sprint.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Priority and order come from the backlog")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(14)

          Divider()

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(waves.enumerated()), id: \.offset) { waveIndex, wave in
                SprintPlanningWave(
                  number: waveIndex + 1,
                  lines: wave,
                  isLast: waveIndex == waves.count - 1,
                  deliveryProfiles: deliveryProfiles,
                  assigneeBinding: assigneeBinding(for:)
                )
              }
            }
          }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
          RoundedRectangle(cornerRadius: 14)
            .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
      }

      Divider()

      HStack {
        if !lines.isEmpty && lines.contains(where: { $0.owner == nil }) {
          Text("Unassigned tickets can be finished later.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Estimates are forecasts, not token budgets.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if assignments.hasUnsavedChanges {
          Button("Discard changes", role: .destructive) {
            discardAndClose()
          }
          .disabled(isSaving)
        } else {
          Button("Cancel") { isPresented = false }
            .disabled(isSaving)
        }
        Button {
          savePlan()
        } label: {
          if isSaving {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("Saving…")
            }
          } else {
            Text("Save and open board")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave || isSaving)
        .accessibilityIdentifier("sprint.plan.save")
      }
    }
    .padding(26)
    .frame(minWidth: 1_000, idealWidth: 1_160, minHeight: 680, idealHeight: 780)
    .accessibilityIdentifier("sprint.plan")
    .onAppear {
      prepare()
    }
    .confirmationDialog(
      "Discard sprint planning changes?",
      isPresented: $isShowingDiscardConfirmation,
      titleVisibility: .visible
    ) {
      Button("Discard changes", role: .destructive) {
        discardAndClose()
      }
      Button("Keep planning", role: .cancel) {}
    } message: {
      Text("The last saved draft remains unchanged.")
    }
    .interactiveDismissDisabled(assignments.hasUnsavedChanges || isSaving)
    .sheet(
      isPresented: $isShowingTicketReview,
      onDismiss: synchronizeAssignments
    ) {
      SprintPlanningTicketReviewView(isPresented: $isShowingTicketReview)
        .environmentObject(model)
    }
  }

  private func prepare() {
    guard !didPrepare else { return }
    didPrepare = true
    synchronizeAssignments()
  }

  private func synchronizeAssignments() {
    assignments = SprintPlanningDraftAssignments(
      saved: scopedItems.reduce(into: [:]) { result, item in
        let plannedOwnerID = sprintItemsByWorkItemID[item.id]?.implementerProfileID
        if let ownerID = plannedOwnerID ?? item.ownerProfileID {
          result[item.id] = ownerID
        }
      }
    )
  }

  private func savePlan() {
    guard
      !isSaving,
      let sprintID = model.candidateSprintPlan?.sprint.id
    else { return }
    isSaving = true
    let inputs = lines.map { line in
      SprintDraftItemInput(
        workItemID: line.item.id,
        implementerProfileID: line.owner?.id,
        estimatedTokens: line.forecast.tokenMidpoint
      )
    }
    Task {
      let saved = await model.saveSprintPlan(
        goal: model.candidateSprintPlan?.sprint.goal ?? "",
        items: inputs
      )
      isSaving = false
      guard saved else { return }
      assignments.markSaved()
      isPresented = false
      onSaved(sprintID)
    }
  }

  private func resolvedOwner(for item: WorkItem) -> AgentProfile? {
    guard let ownerID = assignments.selected[item.id] else { return nil }
    return deliveryProfiles.first { $0.id == ownerID }
  }

  private func assigneeBinding(for itemID: UUID) -> Binding<UUID?> {
    Binding(
      get: { assignments.selected[itemID] },
      set: { ownerID in
        assignments.select(ownerID, for: itemID)
      }
    )
  }

  private func requestClose() {
    guard assignments.hasUnsavedChanges else {
      isPresented = false
      return
    }
    isShowingDiscardConfirmation = true
  }

  private func discardAndClose() {
    assignments.discardChanges()
    isPresented = false
  }

  private func risks(for item: WorkItem, scopedIDs: Set<UUID>) -> [String] {
    var values: [String] = []
    if resolvedOwner(for: item) == nil {
      values.append("Choose a delivery assignee")
    }
    if item.acceptanceCriteria.isEmpty {
      values.append("Acceptance criteria are missing")
    }
    let externalBlockers = model.dependencies.filter {
      $0.workItemID == item.id && !scopedIDs.contains($0.dependsOnWorkItemID)
    }
    for edge in externalBlockers {
      guard
        let blocker = model.workItems.first(where: { $0.id == edge.dependsOnWorkItemID }),
        blocker.state != .released
      else { continue }
      values.append("Blocked by \(blocker.key) outside this sprint")
    }
    return values
  }

  private func compactTokens(_ value: Int) -> String {
    value >= 1_000
      ? String(format: "%.0fk", Double(value) / 1_000)
      : value.formatted()
  }

  private func duration(_ seconds: Int) -> String {
    if seconds < 60 {
      return "\(seconds)s"
    }
    if seconds < 3_600 {
      if seconds.isMultiple(of: 60) {
        return "\(seconds / 60)m"
      }
      return String(format: "%.1fm", Double(seconds) / 60)
    }
    let hours = Double(seconds) / 3_600
    return String(format: hours < 10 ? "%.1fh" : "%.0fh", hours)
  }
}

struct SprintPlanningLine: Identifiable {
  let item: WorkItem
  let owner: AgentProfile?
  let forecast: TicketForecast
  let wave: Int
  let risks: [String]

  var id: UUID { item.id }
}

struct SprintPlanningMetric: View {
  let title: String
  let value: String
  let detail: String
  let symbol: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: symbol)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
        .lineLimit(1)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
  }
}

struct SprintPlanningWave: View {
  let number: Int
  let lines: [SprintPlanningLine]
  let isLast: Bool
  var deliveryProfiles: [AgentProfile] = []
  var assigneeBinding: ((UUID) -> Binding<UUID?>)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        Text("WAVE \(number)")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
        Text(number == 1 ? "Starts immediately" : "Starts when prerequisites finish")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        if lines.count > 1 {
          Label("\(lines.count) parallel", systemImage: "arrow.left.and.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.quaternary.opacity(0.25))

      ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
        SprintPlanningTicketRow(
          line: line,
          deliveryProfiles: deliveryProfiles,
          assigneeID: assigneeBinding?(line.item.id)
        )
        if index != lines.count - 1 {
          Divider().padding(.leading, 66)
        }
      }
      if !isLast {
        Divider()
      }
    }
  }
}

private struct SprintPlanningTicketRow: View {
  let line: SprintPlanningLine
  let deliveryProfiles: [AgentProfile]
  let assigneeID: Binding<UUID?>?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: line.item.type.symbolName)
        .foregroundStyle(line.item.type.tint)
        .frame(width: 18)
      Text(line.item.key)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text(line.item.title)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if let firstRisk = line.risks.first {
          Label(firstRisk, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      Spacer(minLength: 8)
      if let assigneeID {
        Picker("Assignee", selection: assigneeID) {
          Text("Choose assignee")
            .tag(nil as UUID?)
          ForEach(deliveryProfiles) { profile in
            Label(profile.name, systemImage: profile.role.symbolName)
              .tag(Optional(profile.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 132, alignment: .leading)
        .help("Choose the team member who will deliver this ticket.")
      } else if let owner = line.owner {
        Label(owner.name, systemImage: owner.role.symbolName)
          .font(.caption.weight(.medium))
          .foregroundStyle(owner.role.tint)
          .lineLimit(1)
          .frame(width: 132, alignment: .leading)
      } else {
        Text("Unassigned")
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(width: 132, alignment: .leading)
      }
      Text(line.item.priority.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(line.item.priority.tint)
        .frame(width: 54, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Text(
          "\(line.forecast.tokenLow / 1_000)–\(line.forecast.tokenHigh / 1_000)k"
        )
        .font(.caption.monospacedDigit().weight(.medium))
        Text("tokens")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .frame(width: 62, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}

private struct SprintPlanningTicketReviewView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var selections: [UUID: TicketPlanSelection] = [:]
  @State private var currentIndex = 0
  @State private var showingSummary = false
  @State private var didPrepare = false
  @State private var ticketDrafts: [UUID: SprintPlanningTicketDraft] = [:]
  @State private var commentsByItemID: [UUID: [TicketComment]] = [:]
  @State private var recipientByItemID: [UUID: UUID] = [:]
  @State private var messageByItemID: [UUID: String] = [:]
  @State private var conversationErrorsByItemID: [UUID: String] = [:]
  @State private var pendingProposals: [UUID: PendingPlanningProposal] = [:]
  @State private var sendingMessageItemID: UUID?
  @State private var savingTicketItemID: UUID?
  @State private var ticketSaveErrorsByItemID: [UUID: String] = [:]
  @FocusState private var focusedPlanningComposerItemID: UUID?

  private var readyItems: [WorkItem] {
    guard let plan = model.candidateSprintPlan else { return [] }
    let candidateIDs = Set(plan.items.map(\.workItemID))
    return model.workItems.filter { candidateIDs.contains($0.id) }
  }

  private var implementers: [AgentProfile] {
    model.profiles.filter { $0.role.canImplement }
  }

  private var defaultConversationRecipient: AgentProfile? {
    model.profiles.first { $0.role == .lead }
      ?? model.profiles.first { $0.role == .businessAnalyst }
      ?? model.profiles.first
  }

  private var isCodexConnected: Bool {
    if case .connected = model.codexConnectionState { return true }
    return false
  }

  private var canSave: Bool {
    !readyItems.isEmpty
      && readyItems.allSatisfy { selections[$0.id]?.implementerID != nil }
      && !hasDirtyTicketDrafts
      && pendingProposals.isEmpty
      && !model.isPlanningMessageRunning
  }

  private var hasDirtyTicketDrafts: Bool {
    readyItems.contains { item in
      guard let draft = ticketDrafts[item.id] else { return false }
      return draft.snapshot != SprintPlanningTicketSnapshot(item: item)
    }
  }

  private var currentWorkItemID: UUID? {
    guard !showingSummary, readyItems.indices.contains(currentIndex) else { return nil }
    return readyItems[currentIndex].id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(model.candidateSprintPlan == nil ? "Sprint planning" : "Review sprint plan")
            .font(.title.bold())
          Text(
            showingSummary
              ? "Review the complete plan before saving it."
              : "Resolve each ticket with the team; you remain in control of every change."
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
        if !readyItems.isEmpty {
          Text(
            showingSummary
              ? "Plan summary" : "Ticket \(currentIndex + 1) of \(readyItems.count)"
          )
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      }

      Divider()

      if readyItems.isEmpty {
        ContentUnavailableView(
          "No tickets in the next sprint",
          systemImage: "checklist.unchecked",
          description: Text("Return to the backlog and drag work into the next sprint first.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if showingSummary {
        summaryView
      } else {
        ticketReview(readyItems[currentIndex])
      }

      Divider()

      HStack {
        Text("\(readyItems.count) sprint \(readyItems.count == 1 ? "ticket" : "tickets")")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("Discard changes") { isPresented = false }
          .disabled(model.isPlanningMessageRunning)
        if showingSummary {
          Button("Back") { showingSummary = false }
          Button("Save") {
            saveAndClose()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
        } else {
          Button("Save and close") {
            saveAndClose()
          }
          .disabled(!canSave)
          Button("Back") {
            currentIndex = max(0, currentIndex - 1)
          }
          .disabled(currentIndex == 0 || model.isPlanningMessageRunning)
          Button(currentIndex == readyItems.count - 1 ? "Review sprint" : "Next ticket") {
            if currentIndex == readyItems.count - 1 {
              showingSummary = true
            } else {
              currentIndex += 1
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isPlanningMessageRunning)
        }
      }
    }
    .padding(28)
    .frame(width: 1_120, height: 800)
    .onAppear(perform: prepareOnce)
    .task(id: currentWorkItemID) {
      guard let currentWorkItemID else { return }
      guard let item = readyItems.first(where: { $0.id == currentWorkItemID }) else { return }
      let comments = await model.comments(
        for: currentWorkItemID,
        productID: item.productID
      )
      guard sendingMessageItemID != currentWorkItemID else { return }
      commentsByItemID[currentWorkItemID] = comments
    }
  }

  private func ticketReview(_ item: WorkItem) -> some View {
    HStack(alignment: .top, spacing: 18) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            Text(item.key)
              .font(.callout.monospaced().weight(.semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Picker("Type", selection: typeBinding(for: item)) {
              ForEach(WorkItemType.allCases, id: \.self) { type in
                Text(type.title).tag(type)
              }
            }
            .frame(width: 120)
            Picker("Priority", selection: priorityBinding(for: item)) {
              ForEach(WorkItemPriority.allCases, id: \.self) { priority in
                Text(priority.title).tag(priority)
              }
            }
            .frame(width: 130)
          }

          EditableTextField(
            title: "Title",
            prompt: "Describe the outcome",
            text: titleBinding(for: item)
          )

          EditableTextArea(
            title: "Context",
            prompt: "Explain the user need, constraints, and relevant background.",
            text: bodyBinding(for: item),
            minHeight: 105
          )

          EditableTextArea(
            title: "Acceptance criteria",
            prompt: "One independently verifiable outcome per line.",
            text: criteriaBinding(for: item),
            minHeight: 125
          )

          Picker("Assigned to", selection: implementerBinding(for: item.id)) {
            Text("Choose a team member…").tag(UUID?.none)
            ForEach(implementers) { profile in
              Text(profile.name).tag(Optional(profile.id))
            }
          }
          .frame(maxWidth: 420, alignment: .leading)

          Divider()

          HStack {
            if isTicketDraftDirty(item) {
              Label("Unsaved ticket edits", systemImage: "pencil.circle")
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
              Label("Ticket is up to date", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(savingTicketItemID == item.id ? "Saving…" : "Save") {
              persistTicketDraft(for: item)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isTicketDraftDirty(item) || savingTicketItemID != nil)
          }

          if let error = ticketSaveErrorsByItemID[item.id] {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(20)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

      planningConversation(for: item)
        .frame(width: 390)
        .frame(maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
          RoundedRectangle(cornerRadius: 14)
            .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }
  }

  @ViewBuilder
  private func planningConversation(for item: WorkItem) -> some View {
    let bottomID = "planning-conversation-\(item.id.uuidString)-bottom"
    let comments = commentsByItemID[item.id] ?? []
    let isSending = sendingMessageItemID == item.id
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Conversation", systemImage: "bubble.left.and.bubble.right")
          .font(.headline)
        Spacer()
      }
      .padding(16)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(comments) { comment in
              TicketCommentBubble(
                comment: comment,
                authorProfile: profile(for: comment),
                mentionedProfile: mentionedProfile(
                  in: comment.body,
                  profiles: model.profiles
                )
              )
            }

            if let pending = pendingProposals[item.id] {
              TicketProposalCard(
                proposal: pending.proposal,
                currentSnapshot: draftSnapshot(for: item),
                authorName: pending.authorName,
                conflictMessage: proposalConflict(for: item, pending: pending),
                onAccept: { acceptProposal(for: item, pending: pending) },
                onReject: { rejectProposal(for: item, pending: pending) }
              )
            }

            Color.clear
              .frame(height: 1)
              .padding(.bottom, 14)
              .id(bottomID)
          }
          .padding(.horizontal, 14)
          .padding(.top, 14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if comments.isEmpty && pendingProposals[item.id] == nil {
            ConversationEmptyState(
              detail: "Ask for clarification or request a ticket review."
            )
          }
        }
        .onChange(of: commentsByItemID[item.id]?.count ?? 0) { _, _ in
          Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo(bottomID, anchor: .bottom)
            }
          }
        }
        .onChange(of: pendingProposals[item.id] != nil) { wasShowing, isShowing in
          if wasShowing && !isShowing {
            proxy.scrollTo(bottomID, anchor: .bottom)
            Task { @MainActor in
              await Task.yield()
              proxy.scrollTo(bottomID, anchor: .bottom)
            }
          } else {
            Task { @MainActor in
              await Task.yield()
              withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
              }
            }
          }
        }
      }

      if isSending,
        let recipient = selectedRecipient(for: item.id)
      {
        PlanningPresenceIndicator(
          profile: recipient,
          onStop: { model.cancelSprintPlanningMessage() }
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        if !isSending {
          HStack {
            Text("To")
              .font(.caption)
              .foregroundStyle(.secondary)
            PlanningRecipientMenu(
              profiles: model.profiles,
              selection: recipientBinding(for: item.id)
            )
            Spacer()
          }
        }

        if let error = conversationErrorsByItemID[item.id] {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }

        ZStack(alignment: .topLeading) {
          let message = messageByItemID[item.id] ?? ""
          if message.isEmpty && focusedPlanningComposerItemID != item.id {
            Text("Ask a question or request a change…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
          TextEditor(text: messageBinding(for: item.id))
            .scrollContentBackground(.hidden)
            .font(.body)
            .focused($focusedPlanningComposerItemID, equals: item.id)
            .padding(8)
            .onKeyPress(phases: .down) { keyPress in
              guard keyPress.key == .return else {
                return .ignored
              }
              if keyPress.modifiers.contains(.shift) {
                return .ignored
              }
              if canSendPlanningMessage(for: item) {
                sendPlanningMessage(for: item)
              }
              return .handled
            }
        }
        .frame(height: 74)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }

        HStack(alignment: .center) {
          Text(
            isCodexConnected
              ? "Return to send · Shift-Return for a new line"
              : "Codex unavailable"
          )
          .font(.caption2)
          .foregroundStyle(
            isCodexConnected
              ? Color(nsColor: .tertiaryLabelColor)
              : Color.orange
          )
          Spacer()
          Button(isSending ? "Sending…" : "Send") {
            sendPlanningMessage(for: item)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!canSendPlanningMessage(for: item))
        }
      }
      .padding(14)
      .background(.quaternary.opacity(0.2))
    }
  }

  private var summaryView: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 16) {

        Text("Sprint tickets")
          .font(.headline)
        ScrollView {
          VStack(spacing: 8) {
            ForEach(readyItems) { item in
              HStack {
                Text(item.key)
                  .font(.caption.monospaced().weight(.semibold))
                  .foregroundStyle(.secondary)
                Text(ticketDrafts[item.id]?.title ?? item.title)
                Spacer()
                if isTicketDraftDirty(item) {
                  Text("Unsaved")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
              }
              .padding(10)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)

      VStack(alignment: .leading, spacing: 14) {
        Label("Planning signals", systemImage: "chart.bar.doc.horizontal")
          .font(.headline)
        PlanningSignal(title: "Delivery forecast", value: "Not yet analysed")
        PlanningSignal(title: "Remaining usage", value: "Available after Codex sign-in")
        PlanningSignal(
          title: "Human review load",
          value: "\(readyItems.count) demos planned"
        )
        Text("Spedito will produce forecasts; you will not be asked to guess token budgets.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(18)
      .frame(width: 290, alignment: .topLeading)
      .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  private var draftInputs: [SprintDraftItemInput] {
    readyItems.compactMap { item in
      guard
        let selection = selections[item.id],
        let implementerID = selection.implementerID
      else { return nil }
      return SprintDraftItemInput(
        workItemID: item.id,
        implementerProfileID: implementerID,
        reviewerProfileID: nil
      )
    }
  }

  private func saveAndClose() {
    Task {
      if await model.saveSprintPlan(
        goal: model.candidateSprintPlan?.sprint.goal ?? "",
        items: draftInputs
      ) {
        isPresented = false
      }
    }
  }

  private func prepareOnce() {
    guard !didPrepare else { return }
    didPrepare = true

    for item in readyItems {
      selections[item.id] = TicketPlanSelection(
        implementerID: nil
      )
      ticketDrafts[item.id] = SprintPlanningTicketDraft(item: item)
      if let defaultConversationRecipient {
        recipientByItemID[item.id] = defaultConversationRecipient.id
      }
    }

    if let plan = model.candidateSprintPlan {
      for sprintItem in plan.items {
        selections[sprintItem.workItemID] = TicketPlanSelection(
          implementerID: sprintItem.implementerProfileID
        )
      }
    }
  }

  private func implementerBinding(for id: UUID) -> Binding<UUID?> {
    Binding(
      get: { selections[id]?.implementerID },
      set: {
        selections[id, default: TicketPlanSelection()].implementerID = $0
        pendingProposals[id] = nil
      }
    )
  }

  private func titleBinding(for item: WorkItem) -> Binding<String> {
    draftBinding(for: item, keyPath: \.title)
  }

  private func typeBinding(for item: WorkItem) -> Binding<WorkItemType> {
    draftBinding(for: item, keyPath: \.type)
  }

  private func bodyBinding(for item: WorkItem) -> Binding<String> {
    draftBinding(for: item, keyPath: \.body)
  }

  private func criteriaBinding(for item: WorkItem) -> Binding<String> {
    draftBinding(for: item, keyPath: \.criteriaText)
  }

  private func priorityBinding(for item: WorkItem) -> Binding<WorkItemPriority> {
    draftBinding(for: item, keyPath: \.priority)
  }

  private func draftBinding<Value>(
    for item: WorkItem,
    keyPath: WritableKeyPath<SprintPlanningTicketDraft, Value>
  ) -> Binding<Value> {
    Binding(
      get: { (ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item))[keyPath: keyPath] },
      set: { value in
        var draft = ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item)
        draft[keyPath: keyPath] = value
        ticketDrafts[item.id] = draft
        ticketSaveErrorsByItemID[item.id] = nil
      }
    )
  }

  private func recipientBinding(for itemID: UUID) -> Binding<UUID> {
    Binding(
      get: {
        recipientByItemID[itemID]
          ?? defaultConversationRecipient?.id
          ?? model.profiles.first?.id
          ?? UUID()
      },
      set: { recipientByItemID[itemID] = $0 }
    )
  }

  private func messageBinding(for itemID: UUID) -> Binding<String> {
    Binding(
      get: { messageByItemID[itemID] ?? "" },
      set: { messageByItemID[itemID] = $0 }
    )
  }

  private func selectedRecipient(for itemID: UUID) -> AgentProfile? {
    guard let recipientID = recipientByItemID[itemID] ?? defaultConversationRecipient?.id else {
      return nil
    }
    return model.profiles.first { $0.id == recipientID }
  }

  private func profile(for comment: TicketComment) -> AgentProfile? {
    guard comment.authorKind == .agent else { return nil }
    return model.profiles.first { $0.name == comment.authorName }
  }

  private func selectedAssignee(for itemID: UUID) -> AgentProfile? {
    guard let assigneeID = selections[itemID]?.implementerID else { return nil }
    return model.profiles.first { $0.id == assigneeID }
  }

  private func draftSnapshot(for item: WorkItem) -> SprintPlanningTicketSnapshot {
    (ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item)).snapshot
  }

  private func isTicketDraftDirty(_ item: WorkItem) -> Bool {
    draftSnapshot(for: item) != SprintPlanningTicketSnapshot(item: item)
  }

  private func canSendPlanningMessage(for item: WorkItem) -> Bool {
    isCodexConnected
      && selectedRecipient(for: item.id) != nil
      && !(messageByItemID[item.id] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !model.isPlanningMessageRunning
      && sendingMessageItemID == nil
      && pendingProposals[item.id] == nil
  }

  private func sendPlanningMessage(for item: WorkItem) {
    guard
      let recipient = selectedRecipient(for: item.id),
      canSendPlanningMessage(for: item)
    else { return }
    let message = (messageByItemID[item.id] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = draftSnapshot(for: item)

    let optimisticComment = TicketComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@\(recipient.name) \(message)"
    )
    commentsByItemID[item.id, default: []].append(optimisticComment)
    messageByItemID[item.id] = ""
    sendingMessageItemID = item.id
    conversationErrorsByItemID[item.id] = nil
    Task {
      guard
        await model.appendOwnerComment(
          workItemID: item.id,
          productID: item.productID,
          body: optimisticComment.body
        ) != nil
      else {
        conversationErrorsByItemID[item.id] = "Your message couldn't be saved. Try again."
        commentsByItemID[item.id] = await model.comments(
          for: item.id,
          productID: item.productID
        )
        if sendingMessageItemID == item.id {
          sendingMessageItemID = nil
        }
        return
      }

      do {
        let reply = try await model.sendSprintPlanningMessage(
          for: item,
          to: recipient,
          ownerMessage: message,
          ticketSnapshot: snapshot,
          proposedAssignee: selectedAssignee(for: item.id)
        )
        if let proposal = reply.proposal {
          pendingProposals[item.id] = PendingPlanningProposal(
            proposal: proposal,
            baseSnapshot: snapshot,
            authorName: recipient.name
          )
        }
      } catch {
        conversationErrorsByItemID[item.id] = error.localizedDescription
      }
      commentsByItemID[item.id] = await model.comments(
        for: item.id,
        productID: item.productID
      )
      if sendingMessageItemID == item.id {
        sendingMessageItemID = nil
      }
    }
  }

  private func proposalConflict(
    for item: WorkItem,
    pending: PendingPlanningProposal
  ) -> String? {
    SprintPlanningTicketProposalPolicy.conflict(
      proposal: pending.proposal,
      baseSnapshot: pending.baseSnapshot,
      currentSnapshot: draftSnapshot(for: item),
      storedVersion: model.workItems.first(where: { $0.id == item.id })?.version
    )
  }

  private func acceptProposal(for item: WorkItem, pending: PendingPlanningProposal) {
    guard proposalConflict(for: item, pending: pending) == nil else { return }
    guard savingTicketItemID == nil else { return }
    let dependencyIDs = Set(
      model.dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
    )
    savingTicketItemID = item.id
    ticketSaveErrorsByItemID[item.id] = nil
    Task {
      let saved = await model.updateWorkItem(
        productID: item.productID,
        id: item.id,
        title: pending.proposal.title,
        type: pending.proposal.type,
        body: pending.proposal.body,
        acceptanceCriteria: pending.proposal.acceptanceCriteria,
        priority: pending.proposal.priority,
        customFields: item.customFields,
        dependsOnWorkItemIDs: dependencyIDs,
        expectedVersion: pending.proposal.baseVersion
      )
      if saved, let updated = model.workItems.first(where: { $0.id == item.id }) {
        ticketDrafts[item.id] = SprintPlanningTicketDraft(item: updated)
        pendingProposals[item.id] = nil
        _ = await model.appendOwnerComment(
          workItemID: item.id,
          productID: item.productID,
          body: "Accepted \(pending.authorName)'s proposed ticket changes."
        )
        commentsByItemID[item.id] = await model.comments(
          for: item.id,
          productID: item.productID
        )
      } else {
        ticketSaveErrorsByItemID[item.id] =
          model.errorMessage
          ?? "The proposal could not be applied. Reload the ticket and review it again."
      }
      if savingTicketItemID == item.id {
        savingTicketItemID = nil
      }
    }
  }

  private func rejectProposal(for item: WorkItem, pending: PendingPlanningProposal) {
    pendingProposals[item.id] = nil
    Task {
      _ = await model.appendOwnerComment(
        workItemID: item.id,
        productID: item.productID,
        body: "Rejected \(pending.authorName)'s proposed ticket changes."
      )
      commentsByItemID[item.id] = await model.comments(
        for: item.id,
        productID: item.productID
      )
    }
  }

  private func persistTicketDraft(for item: WorkItem) {
    guard savingTicketItemID == nil else { return }
    let draft = ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item)
    let dependencyIDs = Set(
      model.dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
    )
    savingTicketItemID = item.id
    ticketSaveErrorsByItemID[item.id] = nil
    Task {
      let saved = await model.updateWorkItem(
        productID: item.productID,
        id: item.id,
        title: draft.title,
        type: draft.type,
        body: draft.body,
        acceptanceCriteria: draft.acceptanceCriteria,
        priority: draft.priority,
        customFields: item.customFields,
        dependsOnWorkItemIDs: dependencyIDs,
        expectedVersion: draft.baseVersion
      )
      if saved, let updated = model.workItems.first(where: { $0.id == item.id }) {
        ticketDrafts[item.id] = SprintPlanningTicketDraft(item: updated)
      } else {
        ticketSaveErrorsByItemID[item.id] =
          model.errorMessage ?? "The ticket could not be saved. Reload it and try again."
      }
      if savingTicketItemID == item.id {
        savingTicketItemID = nil
      }
    }
  }

}

private struct PlanningRecipientMenu: View {
  let profiles: [AgentProfile]
  @Binding var selection: UUID

  private var selectedProfile: AgentProfile? {
    profiles.first { $0.id == selection }
  }

  var body: some View {
    Menu {
      ForEach(profiles) { profile in
        Button {
          selection = profile.id
        } label: {
          HStack {
            Label(profile.name, systemImage: profile.role.symbolName)
            if selection == profile.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        if let selectedProfile {
          Image(systemName: selectedProfile.role.symbolName)
            .foregroundStyle(selectedProfile.role.tint)
          Text(selectedProfile.name)
            .foregroundStyle(selectedProfile.role.tint)
        } else {
          Image(systemName: "person.crop.circle.badge.questionmark")
            .foregroundStyle(.secondary)
          Text("Choose a team member")
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        (selectedProfile?.role.tint ?? Color.secondary).opacity(0.1),
        in: Capsule()
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

private struct PlanningPresenceIndicator: View {
  let profile: AgentProfile
  let onStop: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      ProgressView()
        .controlSize(.mini)
        .tint(profile.role.tint)
      HStack(spacing: 0) {
        Text(profile.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(profile.role.tint)
        Text(" is thinking…")
          .font(.caption)
          .foregroundStyle(.primary)
      }
      Spacer()
      Button("Stop", action: onStop)
        .controlSize(.mini)
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
    .background(profile.role.tint.opacity(0.075))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(profile.name) is thinking")
  }
}

private struct TicketProposalCard: View {
  let proposal: SprintPlanningTicketProposal
  let currentSnapshot: SprintPlanningTicketSnapshot
  let authorName: String
  let conflictMessage: String?
  let onAccept: () -> Void
  let onReject: () -> Void

  private var changes: [TicketProposalChange] {
    var values: [TicketProposalChange] = []
    if currentSnapshot.title != proposal.title {
      values.append(
        TicketProposalChange(field: "Title", before: currentSnapshot.title, after: proposal.title))
    }
    if currentSnapshot.type != proposal.type {
      values.append(
        TicketProposalChange(
          field: "Type",
          before: currentSnapshot.type.title,
          after: proposal.type.title
        )
      )
    }
    if currentSnapshot.body != proposal.body {
      values.append(
        TicketProposalChange(
          field: "Context",
          before: currentSnapshot.body.isEmpty ? "No context" : currentSnapshot.body,
          after: proposal.body.isEmpty ? "No context" : proposal.body
        )
      )
    }
    if currentSnapshot.acceptanceCriteria != proposal.acceptanceCriteria {
      values.append(
        TicketProposalChange(
          field: "Acceptance criteria",
          before: criteriaDescription(currentSnapshot.acceptanceCriteria),
          after: criteriaDescription(proposal.acceptanceCriteria)
        )
      )
    }
    if currentSnapshot.priority != proposal.priority {
      values.append(
        TicketProposalChange(
          field: "Priority",
          before: currentSnapshot.priority.title,
          after: proposal.priority.title
        )
      )
    }
    return values
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Label("\(authorName) proposal", systemImage: "wand.and.stars")
        .font(.headline)
        .foregroundStyle(.indigo)
      Text(proposal.rationale)
        .font(.caption)
        .foregroundStyle(.secondary)

      if changes.isEmpty {
        Text("The proposal does not change the current ticket.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(changes) { change in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(change.field)
                .font(.caption.weight(.semibold))
              Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
              Text("Current")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(change.before)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
              Text("Proposed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
              Text(change.after)
                .font(.caption)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(9)
          .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        }
      }

      if let conflictMessage {
        Label(conflictMessage, systemImage: "exclamationmark.triangle")
          .font(.caption2)
          .foregroundStyle(.orange)
      }

      HStack(spacing: 8) {
        Button("Accept all suggestions", action: onAccept)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(conflictMessage != nil || changes.isEmpty)
        Button("Dismiss", action: onReject)
          .controlSize(.small)
      }
    }
    .padding(14)
    .background(.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.indigo.opacity(0.14), lineWidth: 1)
    }
  }

  private func criteriaDescription(_ criteria: [String]) -> String {
    criteria.isEmpty ? "No acceptance criteria" : criteria.map { "• \($0)" }.joined(separator: "\n")
  }
}

private struct TicketProposalChange: Identifiable {
  let id = UUID()
  let field: String
  let before: String
  let after: String
}

private struct PlanningSignal: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.medium))
    }
  }
}

private struct TicketPlanSelection {
  var implementerID: UUID?
}

struct SprintPlanningTicketDraft: Equatable {
  var baseVersion: Int
  var title: String
  var type: WorkItemType
  var body: String
  var criteriaText: String
  var priority: WorkItemPriority

  init(item: WorkItem) {
    baseVersion = item.version
    title = item.title
    type = item.type
    body = item.body
    criteriaText = item.acceptanceCriteria.joined(separator: "\n")
    priority = item.priority
  }

  init(
    baseVersion: Int,
    title: String,
    type: WorkItemType,
    body: String,
    criteriaText: String,
    priority: WorkItemPriority
  ) {
    self.baseVersion = baseVersion
    self.title = title
    self.type = type
    self.body = body
    self.criteriaText = criteriaText
    self.priority = priority
  }

  var acceptanceCriteria: [String] {
    criteriaText
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var snapshot: SprintPlanningTicketSnapshot {
    SprintPlanningTicketSnapshot(
      version: baseVersion,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      type: type,
      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      acceptanceCriteria: acceptanceCriteria,
      priority: priority
    )
  }
}

private struct PendingPlanningProposal {
  let proposal: SprintPlanningTicketProposal
  let baseSnapshot: SprintPlanningTicketSnapshot
  let authorName: String
}

extension SprintPlanningTicketSnapshot {
  init(item: WorkItem) {
    self.init(
      version: item.version,
      title: item.title,
      type: item.type,
      body: item.body,
      acceptanceCriteria: item.acceptanceCriteria,
      priority: item.priority
    )
  }
}

struct TicketCustomFieldDraft: Identifiable, Equatable {
  let id = UUID()
  var name: String
  var value: String
}
