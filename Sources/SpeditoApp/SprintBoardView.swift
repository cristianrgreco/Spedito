import AppKit
import SpeditoCore
import SwiftUI

struct SprintBoardSelectionPolicy {
  static func preferredPlan(in plans: [SprintPlan]) -> SprintPlan? {
    plans.first(where: { $0.sprint.state == .active })
      ?? plans.first(where: { $0.sprint.state == .paused })
      ?? plans.first(where: {
        $0.sprint.state == .completed
          && $0.sprint.retrospectiveConcludedAt == nil
      })
      ?? plans.first(where: { $0.sprint.state == .draft })
      ?? plans.first
  }

  static func resolvedSelection(
    availablePlans: [SprintPlan],
    currentID: UUID?,
    restoredID: UUID?,
    isLoading: Bool
  ) -> UUID? {
    if let currentID,
      availablePlans.contains(where: { $0.sprint.id == currentID })
    {
      return currentID
    }
    if let restoredID,
      availablePlans.contains(where: { $0.sprint.id == restoredID })
    {
      return restoredID
    }
    guard !isLoading else { return nil }
    return preferredPlan(in: availablePlans)?.sprint.id
  }
}

extension SprintLane {
  static let board: [SprintLane] = [
    SprintLane(title: "Ready to pick", states: [.queued]),
    SprintLane(title: "In progress", states: [.running]),
    SprintLane(title: "In review", states: [.integrating, .verifying, .readyToRelease]),
    SprintLane(title: "Ready for demo", states: [.acceptance]),
    SprintLane(title: "Done", states: [.released]),
  ]
}

struct SprintBoardView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedSprintID: UUID?
  @Binding var attentionWorkItemIDs: Set<UUID>?
  let onShowBacklog: () -> Void
  let onEditPlan: () -> Void
  let onShowRetrospective: () -> Void
  let onShowReports: () -> Void
  @State private var selectedTicket: WorkItem?
  @State private var showingStopSprintConfirmation = false
  @State private var isUpdatingSprintState = false
  @Namespace private var ticketMotionNamespace

  private let lanes = SprintLane.board

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 9) {
            Text("Sprint board")
              .font(.largeTitle.bold())
              .accessibilityIdentifier("sprint.board")
            if let plan = selectedPlan {
              Text(sprintPhaseTitle(for: plan))
                .font(.caption2.weight(.bold))
                .foregroundStyle(sprintPhaseTint(for: plan))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(sprintPhaseTint(for: plan).opacity(0.1), in: Capsule())
            }
            if let attentionWorkItemIDs, !attentionWorkItemIDs.isEmpty {
              Button {
                self.attentionWorkItemIDs = nil
              } label: {
                Label(
                  attentionWorkItemIDs.count == 1
                    ? "1 needs your attention"
                    : "\(attentionWorkItemIDs.count) need your attention",
                  systemImage: "line.3.horizontal.decrease.circle.fill"
                )
              }
              .buttonStyle(.bordered)
              .tint(.orange)
              .controlSize(.small)
              .help("Show every sprint ticket")
            }
          }
          Text("Track each ticket from ready to pick through review, demo, and done.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 0) {
            if availablePlans.count > 1 {
              Picker("Sprint", selection: selectedSprintBinding) {
                ForEach(availablePlans, id: \.sprint.id) { plan in
                  Text(
                    "Sprint \(plan.sprint.number) · \(sprintSelectorTitle(for: plan))"
                  )
                  .tag(plan.sprint.id)
                }
              }
              .labelsHidden()
              .frame(width: 190, alignment: .trailing)
            }

            if availablePlans.count > 1, hasHeaderActions {
              Divider()
                .frame(height: 22)
                .padding(.horizontal, 12)
            }

            HStack(spacing: 6) {
              if let plan = selectedPlan, plan.sprint.state == .active {
                Button {
                  updateSprintState {
                    await model.pauseSprint(plan.sprint)
                  }
                } label: {
                  Image(systemName: "pause.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isUpdatingSprintState)
                .accessibilityLabel(isUpdatingSprintState ? "Pausing sprint" : "Pause sprint")
                .help("Pause delivery and preserve work so this sprint can resume later")
              }
              if let plan = selectedPlan, plan.sprint.state == .paused {
                Button {
                  updateSprintState {
                    await model.resumeSprint(plan.sprint)
                  }
                } label: {
                  Image(systemName: "play.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isUpdatingSprintState)
                .accessibilityLabel(
                  isUpdatingSprintState ? "Resuming sprint" : "Resume sprint"
                )
                .help("Continue preserved work in this sprint")
              }
              if let plan = selectedPlan, plan.sprint.state.isInProgress {
                Button(role: .destructive) {
                  showingStopSprintConfirmation = true
                } label: {
                  Image(systemName: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isUpdatingSprintState)
                .accessibilityLabel("Stop sprint")
                .help("Stop this sprint and return unfinished tickets to Ready")
              }
              if let plan = selectedPlan, plan.sprint.state == .completed {
                Button("View report", action: onShowReports)
                Button(
                  plan.sprint.retrospectiveConcludedAt == nil
                    ? "Continue to retrospective"
                    : "View retrospective",
                  action: onShowRetrospective
                )
                .buttonStyle(.borderedProminent)
              }
              if let draftPlan = selectedDraftPlan {
                let startAvailability = SprintStartAvailability(
                  draft: draftPlan,
                  plans: availablePlans
                )
                if model.sprintReadinessIssues.isEmpty {
                  Button("Review plan", action: onEditPlan)
                    .buttonStyle(.bordered)
                    .help("Review the sprint plan")
                } else {
                  Button(action: onEditPlan) {
                    Label(
                      "Review plan · \(model.sprintReadinessIssues.count) \(model.sprintReadinessIssues.count == 1 ? "issue" : "issues")",
                      systemImage: "exclamationmark.triangle.fill"
                    )
                  }
                  .buttonStyle(.borderedProminent)
                  .tint(.orange)
                  .help(model.sprintReadinessIssues.map(\.message).joined(separator: "\n"))
                  .accessibilityLabel(
                    model.sprintReadinessIssues.map(\.message).joined(separator: "\n")
                  )
                  .accessibilityIdentifier("sprint.readiness.issues")
                }
                Button("Start sprint") {
                  Task {
                    _ = await model.startSprint()
                  }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sprint.start")
                .disabled(
                  !draftPlan.items.allSatisfy { $0.estimatedTokens > 0 }
                    || !model.sprintReadinessIssues.isEmpty
                    || startAvailability.isBlocked
                )
                .help(startAvailability.explanation ?? "Start the sprint")
              }
            }
          }

          if let plan = selectedPlan {
            SprintBoardGoalView(plan: plan)
          }
        }
      }
      .workspaceHeaderLayout()

      Divider()

      if let productID = model.selectedProductID,
        model.remoteRepositorySnapshotIfLoaded(for: productID)?.repositoryState.connection?.status
          == .connected
      {
        SprintBoardGitHubStatus(
          productID: productID,
          hasActiveDelivery: model.sprintPlan?.sprint.productID == productID
            && model.sprintPlan?.sprint.state.isInProgress == true
        )
        Divider()
      }

      if let plan = selectedPlan {
        VStack(spacing: 0) {
          let planItemIDs = Set(plan.items.map(\.workItemID))
          let displayedItemIDs =
            attentionWorkItemIDs.map { planItemIDs.intersection($0) }
            ?? planItemIDs
          GeometryReader { proxy in
            let horizontalPadding: CGFloat = 40
            let interColumnSpacing: CGFloat = 10
            let availableForColumns =
              proxy.size.width - horizontalPadding
              - (interColumnSpacing * CGFloat(max(0, lanes.count - 1)))
            let columnWidth = min(
              270,
              max(210, availableForColumns / CGFloat(max(1, lanes.count)))
            )

            ScrollView(.horizontal) {
              HStack(alignment: .top, spacing: interColumnSpacing) {
                ForEach(lanes) { lane in
                  SprintBoardColumn(
                    title: boardLaneTitle(for: lane, plan: plan),
                    items: boardItems(
                      for: lane,
                      plan: plan,
                      itemIDs: displayedItemIDs
                    ),
                    columnWidth: columnWidth,
                    motionNamespace: ticketMotionNamespace,
                    onOpen: { selectedTicket = $0 }
                  )
                }
              }
              .padding(20)
              .frame(maxHeight: .infinity, alignment: .top)
              .animation(
                .spring(response: 0.42, dampingFraction: 0.86),
                value: boardPositionSignature(itemIDs: displayedItemIDs)
              )
            }
            .accessibilityIdentifier("sprint.board.columns")
            .frame(maxHeight: .infinity)
          }
        }
      } else {
        ContentUnavailableView {
          Label("No active sprint", systemImage: "figure.run")
        } description: {
          Text("Refine the backlog, review tickets in sprint planning, then start the sprint.")
        } actions: {
          Button("Open backlog", action: onShowBacklog)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      selectPreferredPlanIfNeeded()
    }
    .onChange(of: availablePlanSignature) { _, _ in
      selectPreferredPlanIfNeeded()
    }
    .onChange(of: model.isLoading) { _, isLoading in
      if !isLoading {
        selectPreferredPlanIfNeeded()
      }
    }
    .sheet(item: $selectedTicket) { item in
      if selectedPlan?.sprint.state == .draft {
        TicketDetailView(
          item: item,
          dependsOnWorkItemIDs: Set(
            model.dependencies
              .filter { $0.workItemID == item.id }
              .map(\.dependsOnWorkItemID)
          )
        )
      } else {
        SprintTicketDetailView(item: item)
      }
    }
    .alert(
      selectedPlan.map { "Stop sprint \($0.sprint.number)?" } ?? "Stop sprint?",
      isPresented: $showingStopSprintConfirmation
    ) {
      Button("Stop sprint", role: .destructive) {
        guard let plan = selectedPlan else { return }
        updateSprintState {
          await model.stopSprint(plan.sprint)
        }
      }
      Button("Keep sprint", role: .cancel) {}
    } message: {
      Text(
        "Done tickets stay done. Spedito will stop current work, preserve its work logs, conversations, workspaces, and candidate history for audit, and return unfinished tickets to ready for replanning. No unaccepted candidate will be promoted. This cannot be undone."
      )
    }
  }

  private var availablePlans: [SprintPlan] {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return plans.sorted { $0.sprint.number > $1.sprint.number }
  }

  private var availablePlanSignature: [String] {
    availablePlans.map {
      "\($0.sprint.id.uuidString):\($0.sprint.state.rawValue):\($0.sprint.retrospectiveConcludedAt?.timeIntervalSince1970 ?? 0)"
    }
  }

  private var selectedPlan: SprintPlan? {
    let id = selectedSprintID ?? preferredPlan?.sprint.id
    return availablePlans.first { $0.sprint.id == id }
  }

  private var selectedDraftPlan: SprintPlan? {
    guard let plan = selectedPlan, plan.sprint.state == .draft else { return nil }
    return plan
  }

  private var hasHeaderActions: Bool {
    selectedPlan?.sprint.state.isInProgress == true
      || selectedPlan?.sprint.state == .completed
      || selectedDraftPlan != nil
  }

  private var preferredPlan: SprintPlan? {
    SprintBoardSelectionPolicy.preferredPlan(in: availablePlans)
  }

  private var selectedSprintBinding: Binding<UUID> {
    Binding(
      get: { selectedSprintID ?? preferredPlan?.sprint.id ?? UUID() },
      set: { selectSprint($0) }
    )
  }

  private func selectPreferredPlanIfNeeded() {
    let resolvedID = SprintBoardSelectionPolicy.resolvedSelection(
      availablePlans: availablePlans,
      currentID: selectedSprintID,
      restoredID: restoredSprintID,
      isLoading: model.isLoading
    )
    guard resolvedID != selectedSprintID else { return }
    if resolvedID == restoredSprintID {
      selectedSprintID = resolvedID
    } else {
      selectSprint(resolvedID)
    }
  }

  private var restoredSprintID: UUID? {
    guard let productID = model.selectedProductID else { return nil }
    return SprintBoardSelectionDefaults.selectedSprintID(for: productID)
  }

  private func selectSprint(_ sprintID: UUID?) {
    attentionWorkItemIDs = nil
    selectedSprintID = sprintID
    guard let productID = model.selectedProductID else { return }
    SprintBoardSelectionDefaults.select(sprintID, for: productID)
  }

  private func boardItems(
    for lane: SprintLane,
    plan: SprintPlan,
    itemIDs: Set<UUID>
  ) -> [WorkItem] {
    if plan.sprint.state == .draft {
      return lane.states == [.queued]
        ? model.workItems.filter { itemIDs.contains($0.id) }
        : []
    }
    return model.workItems.filter {
      itemIDs.contains($0.id) && lane.states.contains($0.state)
    }
  }

  private func boardLaneTitle(for lane: SprintLane, plan: SprintPlan) -> String {
    guard plan.sprint.state == .draft, lane.states == [.queued] else {
      return lane.title
    }
    return isReadyToStart(plan) ? lane.title : "Planning"
  }

  private func sprintSelectorTitle(for plan: SprintPlan) -> String {
    switch plan.sprint.state {
    case .draft: "Planning"
    case .active: "Active"
    case .paused: "Paused"
    case .completed:
      plan.sprint.retrospectiveConcludedAt == nil ? "Review due" : "Completed"
    case .cancelled: "Cancelled"
    }
  }

  private func sprintPhaseTitle(for plan: SprintPlan) -> String {
    switch plan.sprint.state {
    case .draft:
      return isReadyToStart(plan) ? "READY" : "PLANNING"
    case .active:
      return "ACTIVE"
    case .paused:
      return "PAUSED"
    case .completed:
      return "COMPLETED"
    case .cancelled:
      return "CANCELLED"
    }
  }

  private func sprintPhaseTint(for plan: SprintPlan) -> Color {
    switch plan.sprint.state {
    case .draft:
      isReadyToStart(plan) ? .green : .orange
    case .active:
      .blue
    case .paused:
      .orange
    case .completed:
      .green
    case .cancelled:
      .red
    }
  }

  private func isReadyToStart(_ plan: SprintPlan) -> Bool {
    !plan.items.isEmpty
      && plan.items.allSatisfy { $0.estimatedTokens > 0 }
      && model.sprintReadinessIssues.isEmpty
  }

  private func updateSprintState(
    _ operation: @escaping () async -> Bool
  ) {
    guard !isUpdatingSprintState else { return }
    isUpdatingSprintState = true
    Task {
      _ = await operation()
      isUpdatingSprintState = false
    }
  }

  private func boardPositionSignature(itemIDs: Set<UUID>) -> [String] {
    model.workItems
      .filter { itemIDs.contains($0.id) }
      .sorted { $0.rank < $1.rank }
      .map { "\($0.id.uuidString):\($0.state.rawValue)" }
  }
}

private struct SprintBoardGoalView: View {
  @EnvironmentObject private var model: AppModel
  let plan: SprintPlan
  @State private var requestedKey: String?

  private var goal: String {
    plan.sprint.goal.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var generationKey: String {
    "\(plan.sprint.id.uuidString):\(plan.sprint.planVersion)"
  }

  private var planSignature: String {
    "\(generationKey):\(plan.sprint.state.rawValue):\(plan.sprint.goal)"
  }

  @ViewBuilder
  var body: some View {
    Group {
      if !goal.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "flag")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
          Text(goal)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: 420, alignment: .trailing)
        .help("Sprint goal: \(goal)")
        .accessibilityLabel("Sprint goal")
        .accessibilityValue(goal)
      }
    }
    .onAppear(perform: generateIfNeeded)
    .onChange(of: planSignature) { _, _ in
      generateIfNeeded()
    }
    .onChange(of: model.canGenerateSprintGoal) { _, canGenerate in
      if canGenerate {
        generateIfNeeded()
      }
    }
  }

  private func generateIfNeeded() {
    guard
      SprintGoalSuggestionPolicy.shouldGenerate(existingGoal: plan.sprint.goal),
      [.draft, .active, .paused].contains(plan.sprint.state),
      requestedKey != generationKey,
      model.canGenerateSprintGoal
    else { return }

    let sprintID = plan.sprint.id
    let planVersion = plan.sprint.planVersion
    requestedKey = generationKey
    Task {
      _ = try? await model.generateAndSaveSprintGoal(
        for: sprintID,
        planVersion: planVersion
      )
    }
  }
}

private struct SprintDraftOverview: View {
  @EnvironmentObject private var model: AppModel
  let plan: SprintPlan

  private var scopedItems: [WorkItem] {
    let ids = Set(plan.items.map(\.workItemID))
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var waves: [[SprintPlanningLine]] {
    let scopedIDs = Set(scopedItems.map(\.id))
    let dependenciesByItem = Dictionary(
      grouping: model.dependencies.filter {
        scopedIDs.contains($0.workItemID) && scopedIDs.contains($0.dependsOnWorkItemID)
      },
      by: \.workItemID
    )
    var waveByItem: [UUID: Int] = [:]
    var remaining = scopedItems
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

    let sprintItems = Dictionary(
      uniqueKeysWithValues: plan.items.map { ($0.workItemID, $0) }
    )
    let lines = scopedItems.map { item -> SprintPlanningLine in
      let sprintItem = sprintItems[item.id]
      let owner = sprintItem?.implementerProfileID.flatMap { ownerID in
        model.profiles.first { $0.id == ownerID }
      }
      let risks = model.sprintReadinessIssues
        .filter { $0.workItemID == item.id }
        .map(\.message)
      return SprintPlanningLine(
        item: item,
        owner: owner,
        forecast: SprintForecast.estimate(for: item),
        wave: waveByItem[item.id] ?? 1,
        risks: risks
      )
    }
    return Dictionary(grouping: lines, by: \.wave)
      .sorted { $0.key < $1.key }
      .map { $0.value.sorted { $0.item.rank < $1.item.rank } }
  }

  private var allLines: [SprintPlanningLine] {
    waves.flatMap { $0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        SprintPlanningMetric(
          title: "Planned scope",
          value: "\(plan.items.count) \(plan.items.count == 1 ? "ticket" : "tickets")",
          detail: "saved and ready to authorise",
          symbol: "checklist.checked"
        )
        SprintPlanningMetric(
          title: "Execution",
          value: "\(waves.count) \(waves.count == 1 ? "wave" : "waves")",
          detail: "all eligible work starts together",
          symbol: "point.3.connected.trianglepath.dotted"
        )
        SprintPlanningMetric(
          title: "Token forecast",
          value: forecastRange,
          detail: "broad planning range",
          symbol: "gauge.with.dots.needle.33percent"
        )
        SprintPlanningMetric(
          title: "Readiness",
          value: model.sprintReadinessIssues.isEmpty
            ? "Ready to start"
            : "\(model.sprintReadinessIssues.count) blocked",
          detail: model.sprintReadinessIssues.isEmpty
            ? "all gates satisfied"
            : "review highlighted issues",
          symbol: model.sprintReadinessIssues.isEmpty
            ? "checkmark.seal"
            : "exclamationmark.triangle"
        )
      }

      VStack(alignment: .leading, spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Planned delivery")
              .font(.headline)
            Text("Tickets are grouped by the dependency wave in which they can begin.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("Saved sprint \(plan.sprint.number) plan")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(14)

        Divider()

        ForEach(Array(waves.enumerated()), id: \.offset) { index, wave in
          SprintPlanningWave(
            number: index + 1,
            lines: wave,
            isLast: index == waves.count - 1
          )
        }
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(.separator.opacity(0.65), lineWidth: 1)
      }

      Text(
        "To change scope or priority, edit tickets in the sprint or backlog section of the backlog view. Review does not start any agents."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var forecastRange: String {
    let low = allLines.reduce(0) { $0 + $1.forecast.tokenLow }
    let high = allLines.reduce(0) { $0 + $1.forecast.tokenHigh }
    return "\(compactTokens(low))–\(compactTokens(high))"
  }

  private func compactTokens(_ value: Int) -> String {
    value >= 1_000
      ? String(format: "%.0fk", Double(value) / 1_000)
      : value.formatted()
  }
}

private struct SprintBanner: View {
  @EnvironmentObject private var model: AppModel
  let plan: SprintPlan
  let onEdit: () -> Void
  let onStart: () -> Void

  private var planningIsComplete: Bool {
    !plan.items.isEmpty && plan.items.allSatisfy { $0.estimatedTokens > 0 }
  }

  private var sprintIsReady: Bool {
    planningIsComplete && model.sprintReadinessIssues.isEmpty
  }

  private var startAvailability: SprintStartAvailability {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return SprintStartAvailability(draft: plan, plans: plans)
  }

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: "pencil.and.list.clipboard")
        .font(.title2)
        .foregroundStyle(sprintIsReady ? .green : .orange)
        .frame(width: 34)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("Sprint \(plan.sprint.number)")
            .font(.headline)
          Text(sprintIsReady ? "READY" : "PLANNING")
            .font(.caption2.weight(.bold))
            .foregroundStyle(sprintIsReady ? .green : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
              (sprintIsReady ? Color.green : Color.orange).opacity(0.1),
              in: Capsule()
            )
        }
        Text(plan.sprint.goal)
          .lineLimit(2)
        Text(planningSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !planningIsComplete {
        VStack(alignment: .trailing, spacing: 3) {
          Text("Sprint planning required")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Text("Review the scope to create owners and forecasts")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if !model.sprintReadinessIssues.isEmpty {
        VStack(alignment: .trailing, spacing: 3) {
          Text("\(model.sprintReadinessIssues.count) readiness issue(s)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Text(model.sprintReadinessIssues.first?.message ?? "Review the sprint plan")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } else if let activeSprintNumber = startAvailability.blockingActiveSprintNumber {
        VStack(alignment: .trailing, spacing: 3) {
          Text("Sprint \(activeSprintNumber) is in progress")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text("Finish it before starting this sprint.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Button(planningIsComplete ? "Review plan" : "Plan sprint", action: onEdit)
      Button("Start sprint") {
        Task {
          if await model.startSprint() {
            onStart()
          }
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        !planningIsComplete
          || !model.sprintReadinessIssues.isEmpty
          || startAvailability.isBlocked
      )
      .help(startAvailability.explanation ?? "Start the sprint")
    }
    .padding(14)
    .background(
      (sprintIsReady ? Color.green : Color.orange).opacity(0.06),
      in: RoundedRectangle(cornerRadius: 14)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(
          (sprintIsReady ? Color.green : Color.orange).opacity(0.18),
          lineWidth: 1
        )
    }
  }

  private var planningSummary: String {
    if !planningIsComplete {
      return "\(plan.items.count) tickets scoped · planning has not been completed"
    }
    let tokens =
      plan.estimatedTokens >= 1_000
      ? String(format: "%.0fk", Double(plan.estimatedTokens) / 1_000)
      : plan.estimatedTokens.formatted()
    return
      "\(plan.items.count) tickets · dependency-led parallelism · ~\(tokens) estimated tokens"
  }
}

private struct BacklogColumn: View {
  let state: WorkItemState
  let items: [WorkItem]
  let suggestionBatch: TicketSuggestionBatch?
  let onNewTicket: (() -> Void)?

  var body: some View {
    TicketColumn(
      title: state.title,
      items: items,
      showsWorkflowActions: true,
      suggestionBatch: suggestionBatch,
      onAdd: onNewTicket
    )
  }
}

private struct SprintBoardColumn: View {
  let title: String
  let items: [WorkItem]
  let columnWidth: CGFloat
  let motionNamespace: Namespace.ID
  let onOpen: (WorkItem) -> Void

  var body: some View {
    TicketColumn(
      title: title,
      items: items,
      showsWorkflowActions: false,
      columnWidth: columnWidth,
      motionNamespace: motionNamespace,
      onOpen: onOpen
    )
  }
}

struct SprintTicketRunTelemetryPresentation {
  let contextFraction: Double?
  let compactionCount: Int?
  let showsLiveActivity: Bool

  var contextPercentage: Int? {
    contextFraction.map { Int(($0 * 100).rounded()) }
  }

  var showsFooter: Bool {
    showsLiveActivity || contextFraction != nil
  }

  init(run: AgentRun?, hasLiveActivity: Bool) {
    if let used = run?.contextUsedTokens,
      let window = run?.contextWindowTokens,
      window > 0
    {
      contextFraction = min(1, max(0, Double(used) / Double(window)))
    } else {
      contextFraction = nil
    }
    if let compactions = run?.compactionCount, compactions > 0 {
      compactionCount = compactions
    } else {
      compactionCount = nil
    }
    showsLiveActivity = run?.status == .running && hasLiveActivity
  }
}

private enum AIActivityVisualStyle {
  static var tint: Color { .purple }
}

struct SprintTicketRunDetailsSelection {
  static func run(
    for itemState: WorkItemState,
    latestRun: AgentRun?,
    allRuns: [AgentRun]
  ) -> AgentRun? {
    guard
      itemState == .acceptance
        || itemState == .readyToRelease
        || itemState == .released
    else {
      return latestRun
    }

    return
      allRuns
      .filter(hasContextTelemetry)
      .max { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.updatedAt < rhs.updatedAt
      }
      ?? latestRun
  }

  private static func hasContextTelemetry(_ run: AgentRun) -> Bool {
    guard
      run.contextUsedTokens != nil,
      let window = run.contextWindowTokens
    else {
      return false
    }
    return window > 0
  }
}

struct SprintTicketExecutionConstraintPresentation: Equatable {
  let title: String
  let explanation: String
  let retryAt: Date?
  let technicalEvidence: String?

  init?(run: AgentRun?) {
    guard let constraint = run?.executionConstraint else { return nil }
    title = constraint.kind.ownerFacingTitle
    explanation = constraint.kind.ownerFacingExplanation
    retryAt = constraint.retryAt
    technicalEvidence = constraint.technicalEvidence
  }
}

private enum WorkItemCardLayout {
  static let edgePadding: CGFloat = 12
}

private struct SprintTicketRunSummary<Status: View>: View {
  let profile: AgentProfile?
  let detailsProfile: AgentProfile?
  let run: AgentRun?
  let liveActivity: CodexLiveActivity?
  let status: Status
  @State private var showsContextDetails = false

  private var telemetry: SprintTicketRunTelemetryPresentation {
    SprintTicketRunTelemetryPresentation(
      run: run,
      hasLiveActivity: liveActivity != nil
    )
  }

  init(
    profile: AgentProfile?,
    detailsProfile: AgentProfile?,
    run: AgentRun?,
    liveActivity: CodexLiveActivity?,
    @ViewBuilder status: () -> Status
  ) {
    self.profile = profile
    self.detailsProfile = detailsProfile
    self.run = run
    self.liveActivity = liveActivity
    self.status = status()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          status
          Spacer(minLength: 4)
          teamMemberLabel
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            status
            Spacer(minLength: 4)
          }
          teamMemberLabel
        }
      }

      if telemetry.showsFooter {
        Divider()
          .padding(.horizontal, -WorkItemCardLayout.edgePadding)
          .padding(.top, WorkItemCardLayout.edgePadding)

        HStack(alignment: .center, spacing: 8) {
          if telemetry.showsLiveActivity, let liveActivity {
            Image(systemName: liveActivity.kind.symbolName)
              .foregroundStyle(AIActivityVisualStyle.tint)
              .frame(width: 13)

            liveActivityText(liveActivity.text)
          } else if let contextPercentage = telemetry.contextPercentage {
            Image(systemName: "brain.head.profile")
              .foregroundStyle(AIActivityVisualStyle.tint)
              .frame(width: 13)

            Text("\(contextPercentage)% context used")
              .foregroundStyle(.primary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          if let contextFraction = telemetry.contextFraction {
            contextOccupancyIndicator(
              fraction: contextFraction,
              compactionCount: telemetry.compactionCount
            )
          }
        }
        .padding(.top, WorkItemCardLayout.edgePadding)
        .font(.caption.weight(.medium))
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func liveActivityText(_ text: String) -> some View {
    ViewThatFits(in: .horizontal) {
      Text(text)
        .lineLimit(1)
        .allowsTightening(true)
        .fixedSize(horizontal: true, vertical: false)

      Text(text)
        .lineLimit(2)
        .truncationMode(.tail)
        .allowsTightening(true)
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(.primary)
    .frame(
      maxWidth: .infinity,
      minHeight: 24,
      maxHeight: 24,
      alignment: .leading
    )
    .layoutPriority(1)
  }

  private func contextOccupancyIndicator(
    fraction: Double,
    compactionCount: Int?
  ) -> some View {
    let percentage = Int((fraction * 100).rounded())
    let compactionDescription =
      compactionCount.map {
        ", \($0) compaction\($0 == 1 ? "" : "s")"
      } ?? ""

    return CircularProgressRing(
      fraction: fraction,
      tint: AIActivityVisualStyle.tint
    )
    .overlay {
      if let compactionCount {
        Text(compactionCount.formatted())
          .font(.system(size: 6, weight: .bold, design: .rounded))
          .foregroundStyle(AIActivityVisualStyle.tint)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .frame(width: 8)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Agent context")
    .accessibilityValue("\(percentage) percent used\(compactionDescription)")
    .onHover { hovering in
      showsContextDetails = hovering
    }
    .popover(isPresented: $showsContextDetails, arrowEdge: .bottom) {
      SprintRunDetailsPopover(
        profile: detailsProfile,
        run: run,
        liveActivity: liveActivity
      )
    }
  }

  private var teamMemberLabel: some View {
    Group {
      if let profile {
        Label(profile.name, systemImage: profile.role.symbolName)
          .foregroundStyle(profile.role.tint)
      } else {
        Label("Unassigned", systemImage: "person.crop.circle.badge.questionmark")
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption.weight(.semibold))
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }

}

enum RunDurationFormatter {
  static func duration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval))
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if days > 0 {
      return "\(days)d \(hours)h"
    }
    if hours > 0 {
      return "\(hours)h \((totalSeconds % 3_600) / 60)m"
    }
    return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
  }
}

private struct SprintRunDetailsPopover: View {
  let profile: AgentProfile?
  let run: AgentRun?
  let liveActivity: CodexLiveActivity?

  var body: some View {
    Group {
      if run?.status == .running {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          details(at: timeline.date)
        }
      } else {
        details(at: run?.updatedAt ?? Date())
      }
    }
  }

  private func details(at referenceDate: Date) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Run details")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 3)
      detailLine("Team member", value: profile?.name ?? "Unavailable")
      if let run {
        detailLine("Status", value: run.status.displayTitle)
        switch run.status {
        case .running:
          if run.turnStartedAt != nil {
            detailLine(
              "Elapsed",
              value: RunDurationFormatter.duration(run.activeDuration(at: referenceDate))
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            detailLine("Last activity", value: Text(lastActivityAt, style: .relative))
          }
        case .queued:
          if let constraint = SprintTicketExecutionConstraintPresentation(run: run) {
            detailLine("Waiting", value: constraint.title)
            Text(constraint.explanation)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let retryAt = constraint.retryAt {
              detailLine("Estimated retry", value: Text(retryAt, style: .relative))
            }
            if let technicalEvidence = constraint.technicalEvidence {
              detailLine("Codex detail", value: technicalEvidence)
            }
          } else {
            detailLine("Timing", value: "Starts when picked up")
          }
          if run.activeDurationSeconds > 0 {
            detailLine(
              "Recorded active time",
              value: RunDurationFormatter.duration(run.activeDurationSeconds)
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            detailLine(
              "Previous activity",
              value: Text(
                lastActivityAt,
                format: .dateTime.day().month(.abbreviated).hour().minute()
              )
            )
          }
        case .awaitingOwner, .interrupted, .completed, .failed, .cancelled:
          if run.activeDurationSeconds > 0 {
            detailLine(
              "Active time",
              value: RunDurationFormatter.duration(run.activeDurationSeconds)
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            detailLine(
              "Last activity",
              value: Text(
                lastActivityAt,
                format: .dateTime.day().month(.abbreviated).hour().minute()
              )
            )
          }
        }
        if run.status != .queued,
          let used = run.contextUsedTokens,
          let window = run.contextWindowTokens,
          window > 0
        {
          let percentage = Int(
            (Double(used) / Double(window) * 100).rounded()
          )
          detailLine(
            "Context used",
            value: "\(percentage)%"
          )
          detailLine(
            "Context tokens",
            value: "\(used.formatted()) / \(window.formatted()) tokens"
          )
        } else if run.status == .running {
          detailLine("Context used", value: "Not reported yet")
        }
        if run.status != .queued {
          detailLine("Compactions", value: run.compactionCount.formatted())
        }
      }
      if run?.status == .running, let liveActivity {
        Divider()
        Label(liveActivity.text, systemImage: liveActivity.kind.symbolName)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.callout)
    .padding(12)
    .frame(width: 270)
  }

  private func detailLine(_ label: String, value: String) -> some View {
    detailLine(label, value: Text(value))
  }

  private func detailLine(_ label: String, value: Text) -> some View {
    (Text("\(label): ")
      .foregroundColor(.secondary)
      + value)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SprintCardActivity {
  let title: String
  let symbol: String
  let tint: Color
}

extension AgentRunStatus {
  fileprivate var displayTitle: String {
    switch self {
    case .queued: "Queued"
    case .running: "Running"
    case .awaitingOwner: "Needs product owner input"
    case .interrupted: "Interrupted"
    case .completed: "Completed"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }
}

enum SprintTicketActivityPresentation {
  static func resolve(
    run: AgentRun?,
    itemState: WorkItemState,
    candidateStatus: CandidateRevisionStatus?,
    isDependencyBlocked: Bool,
    isAcceptanceInProgress: Bool,
    planningIssue: String?
  ) -> SprintCardActivity {
    if planningIssue != nil {
      return SprintCardActivity(
        title: "Needs planning",
        symbol: "exclamationmark.triangle.fill",
        tint: .orange
      )
    }
    if isAcceptanceInProgress {
      return SprintCardActivity(
        title: "Completing ticket",
        symbol: "checkmark.circle.badge.clock",
        tint: .blue
      )
    }
    if run?.status == .awaitingOwner {
      return SprintCardActivity(
        title: "Needs your input",
        symbol: "hand.raised.fill",
        tint: .orange
      )
    }
    if let constraint = SprintTicketExecutionConstraintPresentation(run: run) {
      return SprintCardActivity(
        title: constraint.title,
        symbol: "clock.badge.exclamationmark",
        tint: .orange
      )
    }
    if itemState == .acceptance {
      return SprintCardActivity(
        title: "Ready for demo",
        symbol: "play.rectangle.fill",
        tint: .orange
      )
    }
    if let candidateStatus {
      switch candidateStatus {
      case .queuedForReview, .queuedForIntegration:
        return SprintCardActivity(
          title: "Queued to integrate",
          symbol: "text.line.first.and.arrowtriangle.forward",
          tint: .indigo
        )
      case .integrating:
        return SprintCardActivity(
          title: "Integrating",
          symbol: "arrow.triangle.merge",
          tint: .blue
        )
      case .resolvingConflict:
        return SprintCardActivity(
          title: "Resolving conflict",
          symbol: "wrench.and.screwdriver.fill",
          tint: .indigo
        )
      case .reviewing:
        switch run?.status {
        case .running:
          return SprintCardActivity(
            title: "Reviewing",
            symbol: "checkmark.shield.fill",
            tint: .purple
          )
        case .failed:
          return SprintCardActivity(
            title: "Review failed",
            symbol: "exclamationmark.triangle.fill",
            tint: .red
          )
        case .interrupted:
          return SprintCardActivity(
            title: "Review interrupted",
            symbol: "pause.circle.fill",
            tint: .orange
          )
        default:
          return SprintCardActivity(
            title: "Queued for review",
            symbol: "checkmark.shield",
            tint: .indigo
          )
        }
      case .promoting:
        return SprintCardActivity(
          title: "Completing ticket",
          symbol: "checkmark.circle.badge.clock",
          tint: .blue
        )
      case .readyForDemo:
        return SprintCardActivity(
          title: "Ready for demo",
          symbol: "play.rectangle.fill",
          tint: .orange
        )
      case .accepted:
        return SprintCardActivity(
          title: "Done",
          symbol: "checkmark.circle.fill",
          tint: .green
        )
      case .failed:
        switch run?.status {
        case .running:
          return SprintCardActivity(title: "Working", symbol: "bolt.fill", tint: .blue)
        case .queued:
          return SprintCardActivity(
            title: "Retry queued",
            symbol: "arrow.clockwise",
            tint: .blue
          )
        default:
          return SprintCardActivity(
            title: "Work stopped",
            symbol: "exclamationmark.triangle.fill",
            tint: .red
          )
        }
      case .changesRequested:
        switch run?.status {
        case .failed:
          return SprintCardActivity(
            title: "Work stopped",
            symbol: "exclamationmark.triangle.fill",
            tint: .red
          )
        case .interrupted:
          return SprintCardActivity(
            title: "Work interrupted",
            symbol: "pause.circle.fill",
            tint: .orange
          )
        case .queued:
          return SprintCardActivity(
            title: "Ready to continue",
            symbol: "arrow.clockwise",
            tint: .blue
          )
        default:
          return SprintCardActivity(
            title: "Working",
            symbol: "bolt.fill",
            tint: .blue
          )
        }
      case .superseded:
        return SprintCardActivity(
          title: "Superseded",
          symbol: "arrow.triangle.2.circlepath",
          tint: .secondary
        )
      }
    }
    if itemState == .released {
      return SprintCardActivity(
        title: "Done",
        symbol: "checkmark.circle.fill",
        tint: .green
      )
    }
    if isDependencyBlocked {
      return SprintCardActivity(
        title: "Blocked",
        symbol: "lock.fill",
        tint: .indigo
      )
    }
    if let run {
      switch run.status {
      case .running:
        return SprintCardActivity(title: "Working", symbol: "bolt.fill", tint: .blue)
      case .interrupted:
        return SprintCardActivity(
          title: "Interrupted",
          symbol: "pause.circle.fill",
          tint: .orange
        )
      case .failed:
        return SprintCardActivity(
          title: "Failed",
          symbol: "exclamationmark.triangle.fill",
          tint: .red
        )
      case .cancelled:
        return SprintCardActivity(
          title: "Cancelled",
          symbol: "xmark.circle.fill",
          tint: .secondary
        )
      case .completed:
        return SprintCardActivity(
          title: "Finished",
          symbol: "checkmark.circle.fill",
          tint: .green
        )
      case .queued:
        return SprintCardActivity(title: "Ready", symbol: "tray.full", tint: .secondary)
      case .awaitingOwner:
        return SprintCardActivity(
          title: "Needs your input",
          symbol: "hand.raised.fill",
          tint: .orange
        )
      }
    }

    switch itemState {
    case .backlog:
      return SprintCardActivity(title: "Backlog", symbol: "list.bullet", tint: .secondary)
    case .refining:
      return SprintCardActivity(
        title: "Refining",
        symbol: "wand.and.stars",
        tint: .purple
      )
    case .ready, .queued:
      return SprintCardActivity(title: "Ready", symbol: "tray.full", tint: .secondary)
    case .running:
      return SprintCardActivity(title: "In progress", symbol: "bolt.fill", tint: .blue)
    case .integrating:
      return SprintCardActivity(
        title: "Integrating",
        symbol: "arrow.triangle.merge",
        tint: .blue
      )
    case .verifying:
      return SprintCardActivity(
        title: "In review",
        symbol: "checkmark.shield.fill",
        tint: .purple
      )
    case .acceptance:
      return SprintCardActivity(
        title: "Ready for demo",
        symbol: "play.rectangle.fill",
        tint: .orange
      )
    case .readyToRelease:
      return SprintCardActivity(
        title: "Ready to complete",
        symbol: "checkmark.circle",
        tint: .purple
      )
    case .released:
      return SprintCardActivity(
        title: "Done",
        symbol: "checkmark.circle.fill",
        tint: .green
      )
    case .cancelled:
      return SprintCardActivity(
        title: "Cancelled",
        symbol: "xmark.circle.fill",
        tint: .secondary
      )
    }
  }
}

private struct SprintTicketStatusBadge: View {
  let run: AgentRun?
  let itemState: WorkItemState
  let candidateStatus: CandidateRevisionStatus?
  let isDependencyBlocked: Bool
  let isAcceptanceInProgress: Bool
  let planningIssue: String?

  private var activity: SprintCardActivity {
    SprintTicketActivityPresentation.resolve(
      run: run,
      itemState: itemState,
      candidateStatus: candidateStatus,
      isDependencyBlocked: isDependencyBlocked,
      isAcceptanceInProgress: isAcceptanceInProgress,
      planningIssue: planningIssue
    )
  }

  var body: some View {
    Label(activity.title, systemImage: activity.symbol)
      .font(.caption2.weight(.bold))
      .foregroundStyle(activity.tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(activity.tint.opacity(0.1), in: Capsule())
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .help(planningIssue ?? activity.title)
  }
}

struct SprintPriorityIndicator: View {
  let priority: WorkItemPriority

  private var chevronCount: Int {
    switch priority {
    case .urgent: 3
    case .high: 2
    case .normal, .low: 1
    }
  }

  private var symbolName: String {
    switch priority {
    case .urgent, .high: "chevron.up"
    case .normal: "minus"
    case .low: "chevron.down"
    }
  }

  private var tint: Color {
    switch priority {
    case .urgent: .red
    case .high: .orange
    case .normal: Color(nsColor: .secondaryLabelColor)
    case .low: .blue.opacity(0.72)
    }
  }

  var body: some View {
    VStack(spacing: -4) {
      ForEach(0..<chevronCount, id: \.self) { _ in
        Image(systemName: symbolName)
      }
    }
    .font(.system(size: 7, weight: .semibold))
    .foregroundStyle(tint)
    .frame(width: 8)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityLabel("\(priority.title) priority")
    .help("\(priority.title) priority")
  }
}

private struct TicketColumn: View {
  let title: String
  let items: [WorkItem]
  let showsWorkflowActions: Bool
  let suggestionBatch: TicketSuggestionBatch?
  let onAdd: (() -> Void)?
  let onOpen: ((WorkItem) -> Void)?
  let motionNamespace: Namespace.ID?
  let columnWidth: CGFloat

  init(
    title: String,
    items: [WorkItem],
    showsWorkflowActions: Bool,
    columnWidth: CGFloat = 316,
    suggestionBatch: TicketSuggestionBatch? = nil,
    onAdd: (() -> Void)? = nil,
    motionNamespace: Namespace.ID? = nil,
    onOpen: ((WorkItem) -> Void)? = nil
  ) {
    self.title = title
    self.items = items
    self.showsWorkflowActions = showsWorkflowActions
    self.columnWidth = columnWidth
    self.suggestionBatch = suggestionBatch
    self.onAdd = onAdd
    self.motionNamespace = motionNamespace
    self.onOpen = onOpen
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Text("\(items.count)")
          .font(.caption.monospacedDigit())
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        if let onAdd {
          Button(action: onAdd) {
            Image(systemName: "plus")
              .font(.caption.bold())
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Add ticket to backlog")
        }
      }
      .padding(.horizontal, showsWorkflowActions ? 0 : 10)

      if let suggestionBatch {
        BacklogSuggestionStack(batch: suggestionBatch)
      }

      if items.isEmpty && suggestionBatch == nil {
        Text("No tickets")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 54)
          .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
      } else {
        ScrollView(.vertical) {
          LazyVStack(spacing: 10) {
            ForEach(items) { item in
              ticketCard(for: item)
            }
          }
          .padding(.bottom, 4)
        }
        .scrollIndicators(.visible)
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, showsWorkflowActions ? 12 : 8)
    .frame(width: columnWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
  }

  @ViewBuilder
  private func ticketCard(for item: WorkItem) -> some View {
    if let motionNamespace {
      WorkItemCard(
        item: item,
        showsWorkflowActions: showsWorkflowActions,
        onOpen: onOpen
      )
      .matchedGeometryEffect(id: item.id, in: motionNamespace)
      .transition(.opacity.combined(with: .scale(scale: 0.97)))
    } else {
      WorkItemCard(
        item: item,
        showsWorkflowActions: showsWorkflowActions,
        onOpen: onOpen
      )
    }
  }
}

private struct WorkItemCard: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let item: WorkItem
  let showsWorkflowActions: Bool
  let onOpen: ((WorkItem) -> Void)?
  private let policy = WorkflowPolicy()
  @State private var isHovering = false

  private var sprintItem: SprintItem? {
    model.sprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var epicColor: Color? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var itemRuns: [AgentRun] {
    model.runs.filter { $0.workItemID == item.id }
  }

  private var latestRun: AgentRun? {
    itemRuns
      .sorted { lhs, rhs in
        let lhsPriority = lifecyclePriority(lhs.status)
        let rhsPriority = lifecyclePriority(rhs.status)
        if lhsPriority == rhsPriority {
          return lhs.updatedAt > rhs.updatedAt
        }
        return lhsPriority < rhsPriority
      }
      .first
  }

  private var detailsRun: AgentRun? {
    SprintTicketRunDetailsSelection.run(
      for: item.state,
      latestRun: latestRun,
      allRuns: itemRuns
    )
  }

  private func lifecyclePriority(_ status: AgentRunStatus) -> Int {
    switch status {
    case .running: 0
    case .awaitingOwner: 1
    case .queued: 2
    case .failed, .interrupted: 3
    case .completed: 4
    case .cancelled: 5
    }
  }

  private var assignedProfile: AgentProfile? {
    if let latestRun {
      return model.profiles.first { $0.id == latestRun.profileID }
    }
    guard let ownerID = sprintItem?.implementerProfileID ?? item.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var detailsProfile: AgentProfile? {
    guard let detailsRun else { return assignedProfile }
    return model.profiles.first { $0.id == detailsRun.profileID }
  }

  private var planningIssue: String? {
    guard model.sprintPlan?.sprint.state == .draft, let sprintItem else {
      return nil
    }
    if let issue = model.sprintReadinessIssues.first(where: {
      $0.workItemID == item.id
    }) {
      return issue.message
    }
    if sprintItem.estimatedTokens <= 0 {
      return "\(item.key) still needs sprint planning."
    }
    return nil
  }

  private var latestCandidate: CandidateRevision? {
    let candidate = model.candidateRevisions
      .filter { $0.workItemID == item.id }
      .max { lhs, rhs in
        if lhs.version == rhs.version {
          return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.version < rhs.version
      }
    guard let candidate else { return nil }
    if let latestRun,
      candidate.status == .superseded || candidate.status == .failed,
      latestRun.status == .queued || latestRun.status == .running
        || latestRun.status == .awaitingOwner,
      latestRun.updatedAt > candidate.updatedAt
    {
      return nil
    }
    return candidate
  }

  private var isDependencyBlocked: Bool {
    let prerequisiteIDs = Set(
      model.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    return model.workItems.contains {
      prerequisiteIDs.contains($0.id) && $0.state != .released
    }
  }

  private var isInteractiveHover: Bool {
    onOpen != nil && isHovering
  }

  private var cardBackground: Color {
    return colorScheme == .dark
      ? Color.white.opacity(0.06)
      : Color(nsColor: .controlBackgroundColor)
  }

  private var cardShadow: Color {
    colorScheme == .dark
      ? Color.black.opacity(0.44)
      : Color.black.opacity(0.05)
  }

  private var cardShadowRadius: CGFloat {
    colorScheme == .dark ? 4 : 2
  }

  private var cardShadowOffset: CGFloat {
    colorScheme == .dark ? 2 : 1
  }

  var body: some View {
    Group {
      if let onOpen, !showsWorkflowActions {
        Button {
          #if DEBUG
            UIFixtureRuntime.recordInteraction("sprint-ticket-opened-\(item.id.uuidString)")
          #endif
          onOpen(item)
        } label: {
          cardContent
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sprint.ticket.\(item.id.uuidString)")
      } else {
        cardContent
      }
    }
    .onHover { hovering in
      guard onOpen != nil else { return }
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
  }

  private var cardContent: some View {
    let cardShape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        ticketIdentity
        Spacer(minLength: 0)
        if showsWorkflowActions {
          ticketStatus
        }
        SprintPriorityIndicator(priority: item.priority)
      }

      Text(item.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(3)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)

      if !showsWorkflowActions {
        SprintTicketRunSummary(
          profile: assignedProfile,
          detailsProfile: detailsProfile,
          run: detailsRun,
          liveActivity: detailsRun.flatMap {
            guard $0.status == .running else { return nil }
            return model.liveRunActivities[$0.id] ?? $0.persistedActivity
          }
        ) {
          ticketStatus
        }
      }

      if showsWorkflowActions {
        let transitions = policy.availableTransitions(from: item.state)
          .filter { isOwnerDrivenTransition(from: item.state, to: $0) }
        if !transitions.isEmpty {
          Menu("Move to…") {
            ForEach(transitions, id: \.self) { state in
              Button(state.title) {
                model.transition(item, to: state)
              }
            }
          }
          .font(.caption)
          .menuStyle(.borderlessButton)
        }
      }
    }
    .padding(.vertical, WorkItemCardLayout.edgePadding)
    .padding(.horizontal, WorkItemCardLayout.edgePadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      cardShape
        .fill(cardBackground)
        .overlay {
          if isInteractiveHover {
            cardShape.fill(Color.accentColor.opacity(0.055))
          }
        }
    }
    .overlay {
      if !showsWorkflowActions {
        cardShape.strokeBorder(
          PlanningDropSurfaceStyle.tableBorder(for: colorScheme),
          lineWidth: 1
        )
      } else if colorScheme == .dark {
        cardShape.stroke(Color.white.opacity(0.1), lineWidth: 1)
      }
    }
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
      }
    }
    .clipShape(cardShape)
    .shadow(
      color: showsWorkflowActions ? cardShadow : .clear,
      radius: showsWorkflowActions ? cardShadowRadius : 0,
      y: showsWorkflowActions ? cardShadowOffset : 0
    )
    .contentShape(cardShape)
  }

  private var ticketIdentity: some View {
    HStack(spacing: 8) {
      Text(item.key)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Label(item.type.title, systemImage: item.type.symbolName)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(item.type.tint)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var ticketStatus: some View {
    SprintTicketStatusBadge(
      run: latestRun,
      itemState: item.state,
      candidateStatus: latestCandidate?.status,
      isDependencyBlocked: isDependencyBlocked,
      isAcceptanceInProgress: model.ticketAcceptanceInProgressWorkItemIDs.contains(item.id),
      planningIssue: planningIssue
    )
  }

  private func isOwnerDrivenTransition(from: WorkItemState, to: WorkItemState) -> Bool {
    switch (from, to) {
    case (.backlog, .refining), (.refining, .ready):
      true
    default:
      false
    }
  }
}

enum SprintTicketWorkLogHistory {
  private struct PendingQuestion {
    let displayedIndex: Int
    let question: TicketOwnerQuestion
  }

  static func displayedComments(
    from comments: [TicketComment],
    permissionRequests: [AgentPermissionRequest] = []
  ) -> [TicketComment] {
    var displayed: [TicketComment] = []
    var pendingQuestions: [PendingQuestion] = []

    for comment in comments {
      if isRepresentedByPermissionRequest(
        comment,
        permissionRequests: permissionRequests
      ) {
        continue
      }

      if comment.authorKind == .agent,
        let presentation = TicketOwnerQuestion.presentation(
          in: comment.body,
          structuredQuestion: comment.ownerQuestion
        )
      {
        displayed.append(comment)
        pendingQuestions.append(
          PendingQuestion(
            displayedIndex: displayed.count - 1,
            question: presentation.question
          )
        )
        continue
      }

      if comment.authorKind == .owner,
        let match = matchingAnswer(
          in: comment,
          pendingQuestions: pendingQuestions
        )
      {
        let pending = pendingQuestions.remove(at: match.pendingIndex)
        let questionComment = displayed[pending.displayedIndex]
        displayed[pending.displayedIndex] = TicketComment(
          id: questionComment.id,
          workItemID: questionComment.workItemID,
          authorKind: questionComment.authorKind,
          authorName: questionComment.authorName,
          body: questionComment.body,
          ownerQuestion: questionComment.ownerQuestion,
          answeredQuestions: [match.answer],
          authorAvatarURL: questionComment.authorAvatarURL,
          externalURL: questionComment.externalURL,
          externalID: questionComment.externalID,
          githubReviewContext: questionComment.githubReviewContext,
          createdAt: questionComment.createdAt
        )
      }

      displayed.append(comment)
    }

    return displayed
  }

  private static func isRepresentedByPermissionRequest(
    _ comment: TicketComment,
    permissionRequests: [AgentPermissionRequest]
  ) -> Bool {
    let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return
      permissionRequests
      .filter { $0.workItemID == comment.workItemID }
      .contains { request in
        switch comment.authorKind {
        case .owner:
          switch request.status {
          case .allowOncePendingDelivery, .allowProductPendingDelivery, .allowed:
            body == "Allowed once: \(request.detail)"
              || body == "Always allowed for this product: \(request.detail)"
          case .denyPendingDelivery, .denied:
            body == "Denied: \(request.detail)"
          case .existingAccessPendingDelivery, .grantAccessPendingDelivery,
            .policyDenyPendingDelivery, .existingAccess, .policyDenied,
            .pending, .interrupted:
            false
          }
        case .system:
          body.hasPrefix("Permission requested: \(request.detail)")
            || body == "Automatically allowed by saved product access: \(request.detail)"
        case .agent, .external:
          false
        }
      }
  }

  private static func matchingAnswer(
    in ownerComment: TicketComment,
    pendingQuestions: [PendingQuestion]
  ) -> (pendingIndex: Int, answer: TicketAnsweredQuestion)? {
    for answered in ownerComment.answeredQuestions {
      if let pendingIndex = pendingQuestions.lastIndex(where: {
        $0.question.prompt == answered.question.prompt
          && $0.question.options == answered.question.options
      }) {
        return (pendingIndex, answered)
      }
    }

    let body = ownerComment.body.trimmingCharacters(in: .whitespacesAndNewlines)
    for pendingIndex in pendingQuestions.indices.reversed() {
      let pending = pendingQuestions[pendingIndex]
      guard pending.question.options.contains(body) else { continue }
      return (
        pendingIndex,
        TicketAnsweredQuestion(
          question: TicketRefinementQuestion(
            prompt: pending.question.prompt,
            options: pending.question.options
          ),
          selectedOption: body,
          answer: body
        )
      )
    }
    return nil
  }
}

enum SprintTicketCommentRouting {
  static func activeQuestionRecipient(
    workItemID: UUID,
    assignedProfileID: UUID?,
    comments: [TicketComment],
    runs: [AgentRun],
    profiles: [AgentProfile]
  ) -> AgentProfile? {
    let activeStatuses: Set<AgentRunStatus> = [.queued, .running, .awaitingOwner]
    let activeRun =
      runs
      .filter {
        $0.workItemID == workItemID && activeStatuses.contains($0.status)
      }
      .max {
        let lhsDate = $0.lastActivityAt ?? $0.updatedAt
        let rhsDate = $1.lastActivityAt ?? $1.updatedAt
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return $0.id.uuidString < $1.id.uuidString
      }
    if let activeRun,
      let activeProfile = profiles.first(where: { $0.id == activeRun.profileID })
    {
      return activeProfile
    }
    return replyRecipient(
      workItemID: workItemID,
      assignedProfileID: assignedProfileID,
      comments: comments,
      runs: runs,
      profiles: profiles
    )
  }

  static func unansweredOwnerComment(
    workItemID: UUID,
    since date: Date,
    comments: [TicketComment]
  ) -> TicketComment? {
    let relevantComments =
      comments
      .filter { $0.workItemID == workItemID && $0.createdAt >= date }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    guard
      let ownerIndex = relevantComments.lastIndex(where: {
        $0.authorKind == .owner
      })
    else { return nil }
    guard
      !relevantComments.suffix(from: relevantComments.index(after: ownerIndex))
        .contains(where: { $0.authorKind == .agent })
    else { return nil }
    return relevantComments[ownerIndex]
  }

  static func replyRecipient(
    workItemID: UUID,
    assignedProfileID: UUID?,
    comments: [TicketComment],
    runs: [AgentRun],
    profiles: [AgentProfile]
  ) -> AgentProfile? {
    if let assignedProfileID,
      let assigned = profiles.first(where: { $0.id == assignedProfileID })
    {
      return assigned
    }

    var latestParticipant: (profile: AgentProfile, date: Date)?
    for comment in comments
    where comment.workItemID == workItemID && comment.authorKind == .agent {
      guard let profile = profiles.first(where: { $0.name == comment.authorName }) else {
        continue
      }
      if latestParticipant.map({ comment.createdAt > $0.date }) ?? true {
        latestParticipant = (profile, comment.createdAt)
      }
    }
    for run in runs where run.workItemID == workItemID {
      guard let profile = profiles.first(where: { $0.id == run.profileID }) else {
        continue
      }
      let interactionDate = run.lastActivityAt ?? run.updatedAt
      if latestParticipant.map({ interactionDate > $0.date }) ?? true {
        latestParticipant = (profile, interactionDate)
      }
    }
    if let latestParticipant {
      return latestParticipant.profile
    }
    return profiles.first { $0.role == .lead }
  }
}

enum SprintTicketWorkLogExternalLink {
  static func resolve(
    comment: TicketComment,
    pullRequestNumber: Int?,
    pullRequestURL: URL?
  ) -> URL? {
    if let externalURL = comment.externalURL {
      return externalURL
    }
    guard comment.authorKind == .system,
      comment.authorName == "Spedito",
      let pullRequestNumber,
      let pullRequestURL,
      comment.body.hasPrefix("Created draft pull request #\(pullRequestNumber) ")
    else {
      return nil
    }
    return pullRequestURL
  }

}

enum SprintTicketWorkLogAttention {
  static func requiresProductOwnerInput(
    hasPendingPermissionRequest: Bool,
    hasActiveOwnerQuestion: Bool,
    knowledgeProposalStatuses: [KnowledgePageProposalStatus],
    requiresKnowledgeApproval: Bool,
    ticketState: WorkItemState
  ) -> Bool {
    hasPendingPermissionRequest
      || hasActiveOwnerQuestion
      || (requiresKnowledgeApproval
        && knowledgeProposalStatuses.contains(.reviewed))
      || ticketState == .acceptance
  }
}

struct SprintTicketDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceContainerSize) private var containerSize
  let item: WorkItem
  @State private var comments: [TicketComment] = []
  @State private var activityEvents: [ActivityEvent] = []
  @State private var isPostingComment = false
  @State private var isAskingQuestion = false
  @State private var isResumingWork = false
  @State private var isDemoActionRunning = false
  @State private var decidingPermissionRequestID: UUID?
  @State private var decidingKnowledgeProposalIDs: Set<UUID> = []
  @State private var commentError: String?
  @State private var workLogScrollRequest = 0
  @State private var hasLoadedWorkLog = false
  @State private var hoveredContextPageID: UUID?
  @State private var ownerAnswerSelection: TicketOwnerAnswerSelection?
  @State private var customOwnerAnswerDraft = ""
  @State private var commentComposerFocusResetRequest = 0
  @State private var selectedRelationshipTicket: WorkItem?

  private var currentItem: WorkItem {
    model.workItems.first { $0.id == item.id } ?? item
  }

  private var isAcceptingTicket: Bool {
    model.ticketAcceptanceInProgressWorkItemIDs.contains(currentItem.id)
  }

  private var currentSprintItem: SprintItem? {
    model.sprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var owner: AgentProfile? {
    let sprintOwnerID = currentSprintItem?.implementerProfileID
    guard let ownerID = sprintOwnerID ?? currentItem.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var ticketPullRequestPublication: RemotePublication? {
    model.remoteRepositorySnapshot(for: currentItem.productID).repositoryState.publications
      .filter { $0.workItemID == currentItem.id }
      .sorted { $0.updatedAt > $1.updatedAt }
      .first
  }

  private func workLogExternalURL(for comment: TicketComment) -> URL? {
    SprintTicketWorkLogExternalLink.resolve(
      comment: comment,
      pullRequestNumber: ticketPullRequestPublication?.pullRequest?.number,
      pullRequestURL: ticketPullRequestPublication?.pullRequest?.canonicalURL
    )
  }

  private var commentReplyRecipient: AgentProfile? {
    SprintTicketCommentRouting.replyRecipient(
      workItemID: item.id,
      assignedProfileID: currentSprintItem?.implementerProfileID ?? currentItem.ownerProfileID,
      comments: comments,
      runs: model.runs,
      profiles: model.profiles
    )
  }

  private var questionRecipient: AgentProfile? {
    SprintTicketCommentRouting.activeQuestionRecipient(
      workItemID: item.id,
      assignedProfileID: currentSprintItem?.implementerProfileID ?? currentItem.ownerProfileID,
      comments: comments,
      runs: model.runs,
      profiles: model.profiles
    )
  }

  private var prerequisites: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var activePrerequisites: [WorkItem] {
    prerequisites.filter { $0.state != .released }
  }

  private var dependants: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.dependsOnWorkItemID == item.id }
        .map(\.workItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var ticketCandidates: [CandidateRevision] {
    model.candidateRevisions
      .filter { $0.workItemID == item.id }
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.version < $1.version
        }
        return $0.createdAt < $1.createdAt
      }
  }

  private var currentCandidate: CandidateRevision? {
    ticketCandidates.max(by: { $0.version < $1.version })
  }

  private var ticketPermissionRequests: [AgentPermissionRequest] {
    model.permissionRequests
      .filter { $0.workItemID == item.id }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var ticketRunContexts: [SprintTicketRunContextLogItem] {
    let pageIDsByRun = Dictionary(
      grouping: model.agentRunKnowledgeContext,
      by: \.runID
    )
    let implementationRunIDs = Set(ticketCandidates.map(\.implementationRunID))
    return model.runs
      .filter { $0.workItemID == item.id }
      .compactMap { run in
        let profile = model.profiles.first { $0.id == run.profileID }
        let isActiveDeliveryRun =
          currentItem.state == .running
          && currentSprintItem?.implementerProfileID == run.profileID
        guard
          SprintTicketRunContextVisibility.includes(
            profile: profile,
            isDeliveryRun: implementationRunIDs.contains(run.id) || isActiveDeliveryRun
          )
        else {
          return nil
        }
        let pageIDs = Set((pageIDsByRun[run.id] ?? []).map(\.pageID))
        guard !pageIDs.isEmpty else { return nil }
        let pages = model.knowledgePages
          .filter { pageIDs.contains($0.id) }
          .sorted { $0.title < $1.title }
        guard !pages.isEmpty else { return nil }
        return SprintTicketRunContextLogItem(run: run, pages: pages)
      }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var ticketKnowledgeBatches: [SprintTicketKnowledgeLogItem] {
    let proposalsByCandidate = Dictionary(
      grouping: model.knowledgePageProposals.filter {
        $0.workItemID == item.id
      },
      by: \.candidateRevisionID
    )
    return ticketCandidates.compactMap { candidate in
      guard let proposals = proposalsByCandidate[candidate.id], !proposals.isEmpty else {
        return nil
      }
      return SprintTicketKnowledgeLogItem(
        candidate: candidate,
        proposals: proposals.sorted { $0.createdAt < $1.createdAt }
      )
    }
  }

  private var ticketDemoSubmissions: [SprintTicketDemoLogItem] {
    SprintTicketWorkLogTimeline.demoSubmissions(
      events: activityEvents,
      candidates: ticketCandidates
    )
  }

  private var ticketFollowUps: [SprintTicketFollowUpLogItem] {
    ticketCandidates.compactMap { candidate in
      guard
        let result = executionResult(for: candidate),
        !result.followUpTicketProposals.isEmpty
      else { return nil }
      return SprintTicketFollowUpLogItem(candidate: candidate)
    }
  }

  private var pendingPermissionRequest: AgentPermissionRequest? {
    model.pendingPermissionRequest(workItemID: item.id)
  }

  private var unansweredPermissionComment: TicketComment? {
    guard let pendingPermissionRequest else { return nil }
    return SprintTicketCommentRouting.unansweredOwnerComment(
      workItemID: item.id,
      since: pendingPermissionRequest.createdAt,
      comments: comments
    )
  }

  private var activeTicketConversationProfile: AgentProfile? {
    guard
      model.ticketConversationWorkItemID == item.id,
      let recipientID = model.ticketConversationRecipientID
    else { return nil }
    return model.profiles.first { $0.id == recipientID }
  }

  private func trunkPromotionValue(for candidate: CandidateRevision) -> String {
    if candidate.deliveryKind == .localOutcome {
      return switch candidate.status {
      case .accepted: "Accepted"
      case .readyForDemo: "Awaiting your approval"
      default: "Not accepted"
      }
    }
    switch candidate.status {
    case .accepted:
      return "Promoted after approval"
    case .readyForDemo:
      return "Awaiting your approval"
    default:
      return "Not promoted"
    }
  }

  private func trunkPromotionSymbol(for candidate: CandidateRevision) -> String {
    if candidate.deliveryKind == .localOutcome {
      return candidate.status == .accepted
        ? "checkmark.circle.fill"
        : "doc.text.magnifyingglass"
    }
    return candidate.status == .accepted
      ? "checkmark.circle.fill"
      : "arrow.triangle.branch"
  }

  private func trunkPromotionTint(for candidate: CandidateRevision) -> Color {
    switch candidate.status {
    case .accepted:
      .green
    case .readyForDemo:
      .orange
    default:
      .secondary
    }
  }

  private var currentKnowledgeProposals: [KnowledgePageProposal] {
    guard let candidateID = currentCandidate?.id else { return [] }
    return model.knowledgePageProposals.filter {
      $0.candidateRevisionID == candidateID
    }
  }

  private var knowledgeProposalsBlockCompletion: Bool {
    currentKnowledgeProposals.contains { $0.status == .proposed }
      || (model.requiresKnowledgeApproval
        && currentKnowledgeProposals.contains { $0.status == .reviewed })
  }

  private var hasPendingWorkLogAction: Bool {
    SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: pendingPermissionRequest != nil,
      hasActiveOwnerQuestion: activeOwnerQuestionComment != nil,
      knowledgeProposalStatuses: currentKnowledgeProposals.map(\.status),
      requiresKnowledgeApproval: model.requiresKnowledgeApproval,
      ticketState: currentItem.state
    )
  }

  private var detailWidth: CGFloat {
    min(900, max(700, containerSize.width - 140))
  }

  private var detailHeight: CGFloat {
    min(780, max(600, containerSize.height - 110))
  }

  private func latestActivityButton(hasEntries: Bool) -> some View {
    Button {
      workLogScrollRequest += 1
    } label: {
      Label("Latest activity", systemImage: "arrow.down.to.line")
    }
    .disabled(!hasEntries)
    .help("Jump to the latest work log entry")
  }

  private var boardStatusTitle: String {
    if model.sprintPlan?.sprint.state == .draft, let currentSprintItem {
      if currentSprintItem.estimatedTokens <= 0
        || model.sprintReadinessIssues.contains(where: { $0.workItemID == item.id })
      {
        return "Needs planning"
      }
      return "Ready to pick"
    }
    return switch currentItem.state {
    case .queued: "Ready to pick"
    case .running: "In progress"
    case .integrating, .verifying, .readyToRelease: "In review"
    case .acceptance: "Ready for demo"
    case .released: "Done"
    default: currentItem.state.title
    }
  }

  private var boardStatusSymbol: String {
    switch boardStatusTitle {
    case "Needs planning": "exclamationmark.triangle.fill"
    case "Ready to pick": "tray.full"
    case "In progress": "bolt.fill"
    case "In review": "checkmark.shield"
    case "Ready for demo": "play.rectangle"
    case "Done": "checkmark.circle.fill"
    default: currentItem.state.activitySymbol
    }
  }

  private var boardStatusTint: Color {
    switch boardStatusTitle {
    case "Needs planning": .orange
    case "Ready to pick": Color(nsColor: .secondaryLabelColor)
    case "In progress": .blue
    case "In review": .purple
    case "Ready for demo": .orange
    case "Done": .green
    default: currentItem.state.activityTint
    }
  }

  private var ownerAnswer: String? {
    switch ownerAnswerSelection {
    case .option(let option):
      return option
    case .custom:
      let answer =
        customOwnerAnswerDraft
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return answer.isEmpty ? nil : answer
    case nil:
      return nil
    }
  }

  private var canRetryFailedPostReviewDemo: Bool {
    model.canRetryFailedPostReviewDemo(workItemID: item.id)
  }

  private var awaitingOwnerRun: AgentRun? {
    model.runs
      .filter { $0.workItemID == item.id && $0.status == .awaitingOwner }
      .max { $0.updatedAt < $1.updatedAt }
  }

  private var awaitingOwnerProfile: AgentProfile? {
    guard let awaitingOwnerRun else { return nil }
    return model.profiles.first { $0.id == awaitingOwnerRun.profileID }
  }

  private var activeOwnerQuestionComment: TicketComment? {
    guard awaitingOwnerRun != nil, !canRetryFailedPostReviewDemo else { return nil }
    let agentComments = comments.filter { $0.authorKind == .agent }
    if let structuredComment = agentComments.last(where: { $0.ownerQuestion != nil }) {
      return structuredComment
    }
    guard
      let latestAgentComment = agentComments.last,
      TicketOwnerQuestion.presentation(
        in: latestAgentComment.body,
        structuredQuestion: nil
      ) != nil
    else { return nil }
    return latestAgentComment
  }

  private var pausedQuestionRecipient: AgentProfile? {
    if currentCandidate?.status == .changesRequested,
      let techLead = model.profiles.first(where: { $0.role == .lead })
    {
      return techLead
    }
    return awaitingOwnerProfile
  }

  private var failedDeliveryRun: AgentRun? {
    let latestRun = model.runs
      .filter({
        $0.workItemID == item.id
      })
      .max(by: { $0.updatedAt < $1.updatedAt })
    guard let latestRun else { return nil }
    guard latestRun.status == .failed || latestRun.status == .interrupted else {
      return nil
    }
    return latestRun
  }

  private var failedDeliveryProfile: AgentProfile? {
    guard let failedDeliveryRun else { return nil }
    return model.profiles.first { $0.id == failedDeliveryRun.profileID }
  }

  private func executionResult(
    for candidate: CandidateRevision
  ) -> TicketExecutionResult? {
    try? CodexTicketExecutor.decode(candidate.executionResultJSON)
  }

  private var workLogEntries: [SprintWorkLogEntry] {
    let demoSubmissions = ticketDemoSubmissions
    let commentEntries = SprintTicketWorkLogHistory.displayedComments(
      from: comments,
      permissionRequests: ticketPermissionRequests
    )
    .filter(isVisibleWorkLogComment)
    .map(SprintWorkLogEntry.comment)
    let eventEntries = SprintTicketWorkLogTimeline.displayedEvents(
      events: activityEvents,
      comments: comments,
      permissionRequests: ticketPermissionRequests,
      demoSubmissions: demoSubmissions
    )
    .map(SprintWorkLogEntry.event)
    let artifactEntries =
      ticketPermissionRequests.map(SprintWorkLogEntry.permission)
      + ticketRunContexts.map(SprintWorkLogEntry.runContext)
      + ticketCandidates.map(SprintWorkLogEntry.candidate)
      + ticketKnowledgeBatches.map(SprintWorkLogEntry.knowledge)
      + demoSubmissions.map(SprintWorkLogEntry.demo)
      + ticketFollowUps.map(SprintWorkLogEntry.followUp)
    return SprintTicketWorkLogTimeline.ordered(
      commentEntries + eventEntries + artifactEntries
    )
  }

  private func isVisibleWorkLogComment(_ comment: TicketComment) -> Bool {
    let boilerplate = [
      "I’m starting work on this ticket. I’ll record material progress and any decision I need from you here.",
      "I’m continuing with the latest feedback.",
      "I’m reviewing the implementation and its evidence against the ticket.",
    ]
    return !boilerplate.contains(comment.body)
  }

  private var overviewRelationships: [TicketDetailRelationshipGroup] {
    var groups: [TicketDetailRelationshipGroup] = []
    if !activePrerequisites.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocked-by",
          title: "Blocked by",
          symbol: "arrow.turn.up.left",
          items: activePrerequisites.map(TicketDetailRelationshipItem.init(workItem:))
        )
      )
    }
    if !dependants.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocks",
          title: "Blocks",
          symbol: "link",
          items: dependants.map(TicketDetailRelationshipItem.init(workItem:))
        )
      )
    }
    return groups
  }

  private func profile(for candidate: CandidateRevision) -> AgentProfile? {
    guard
      let run = model.runs.first(where: {
        $0.id == candidate.implementationRunID
      })
    else { return nil }
    return model.profiles.first { $0.id == run.profileID }
  }

  private func workLogArtifactRow<Content: View>(
    actorName: String,
    profile: AgentProfile?,
    createdAt: Date,
    showsBottomSeparator: Bool,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let tint = profile?.role.tint ?? Color.secondary
    let symbol = profile?.role.symbolName ?? "gearshape.fill"
    return HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(tint.opacity(0.12))
        Image(systemName: symbol)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text(actorName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(profile == nil ? Color.primary : tint)
          Text(
            createdAt,
            format: .dateTime.day().month(.abbreviated).hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, 14)
    .padding(.bottom, showsBottomSeparator ? 14 : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsBottomSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.55))
          .frame(height: 1)
          .padding(.leading, 46)
      }
    }
  }

  private func contextSection(
    _ context: SprintTicketRunContextLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    let profile = model.profiles.first { $0.id == context.run.profileID }
    return workLogArtifactRow(
      actorName: profile?.name ?? "Spedito",
      profile: profile,
      createdAt: context.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      WorkLogArtifactCard(
        title: "Knowledge used",
        subtitle:
          "\(context.pages.count) knowledge page\(context.pages.count == 1 ? "" : "s")",
        systemImage: "books.vertical.fill",
        tint: .indigo
      ) {
        VStack(alignment: .leading, spacing: 10) {

          if !context.mandatoryPages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("Always included")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              IntrinsicWrappingLayout(spacing: 6) {
                ForEach(context.mandatoryPages) { page in
                  contextPageRow(page)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          if !context.relevantPages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("Relevant to this ticket")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              IntrinsicWrappingLayout(spacing: 6) {
                ForEach(context.relevantPages) { page in
                  contextPageRow(page)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
  }

  private func contextPageRow(_ page: KnowledgePage) -> some View {
    let isHovered = hoveredContextPageID == page.id
    return Button {
      model.requestKnowledgeFocus(pageID: page.id)
      dismiss()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "doc.text")
          .font(.caption2)
          .foregroundStyle(.indigo)
        Text(page.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(isHovered ? Color.indigo : Color.secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered
        ? Color.indigo.opacity(0.12)
        : Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          isHovered
            ? Color.indigo.opacity(0.55)
            : Color(nsColor: .separatorColor).opacity(0.45),
          lineWidth: 1
        )
    }
    .onHover { hovering in
      if hovering {
        hoveredContextPageID = page.id
      } else if hoveredContextPageID == page.id {
        hoveredContextPageID = nil
      }
    }
    .help("Open \(page.title) in product knowledge")
  }

  private func deliveryRevisionSection(
    _ candidate: CandidateRevision,
    showsBottomSeparator: Bool
  ) -> some View {
    let candidateProfile = profile(for: candidate)
    return workLogArtifactRow(
      actorName: candidateProfile?.name ?? "Spedito",
      profile: candidateProfile,
      createdAt: candidate.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      WorkLogArtifactCard(
        title: candidate.deliveryKind == .localOutcome ? "Delivery outcome" : "Delivery revision",
        systemImage:
          candidate.deliveryKind == .localOutcome
          ? "doc.text.magnifyingglass"
          : "shippingbox.fill",
        tint: .purple
      ) {
        VStack(alignment: .leading, spacing: 10) {
          LazyVGrid(
            columns: Array(
              repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
              count: candidate.deliveryKind.changesRepository ? 5 : 3
            ),
            alignment: .leading,
            spacing: 12
          ) {
            if candidate.deliveryKind == .localOutcome {
              SprintTicketMetadata(
                title: "Outcome",
                value: "Version \(candidate.version)",
                symbol: "doc.text.magnifyingglass",
                tint: .purple
              )
              SprintTicketMetadata(
                title: "Repository",
                value: "No changes",
                symbol: "arrow.triangle.branch",
                tint: .secondary
              )
              SprintTicketMetadata(
                title: "Review",
                value: trunkPromotionValue(for: candidate),
                symbol: trunkPromotionSymbol(for: candidate),
                tint: trunkPromotionTint(for: candidate)
              )
            } else {
              SprintTicketMetadata(
                title: "Ticket branch",
                value: candidate.branchName,
                symbol: "arrow.triangle.branch",
                tint: .indigo
              )
              SprintTicketMetadata(
                title: "Candidate",
                value:
                  "\(candidate.shortHeadSHA) · \(candidate.commitCount) commit\(candidate.commitCount == 1 ? "" : "s")",
                symbol: "shippingbox",
                tint: .purple
              )
              if let integratedSHA = candidate.shortIntegratedSHA {
                SprintTicketMetadata(
                  title: "Integrated revision",
                  value: integratedSHA,
                  symbol: "point.3.connected.trianglepath.dotted",
                  tint: .green
                )
              }
              SprintTicketMetadata(
                title: "Local trunk",
                value: trunkPromotionValue(for: candidate),
                symbol: trunkPromotionSymbol(for: candidate),
                tint: trunkPromotionTint(for: candidate)
              )
              if candidate.id == currentCandidate?.id {
                Button {
                  model.requestCodebaseFocus(workItemID: currentItem.id)
                  dismiss()
                } label: {
                  HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                      .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                      Text("Codebase")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                      HStack(spacing: 4) {
                        Text("View changes")
                        Image(systemName: "arrow.right")
                      }
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.indigo)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            }
          }
          if candidate.status != .accepted {
            Text(deliveryRevisionExplanation(candidate))
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .textSelection(.enabled)
      }
    }
  }

  private func deliveryRevisionExplanation(
    _ candidate: CandidateRevision
  ) -> String {
    if candidate.deliveryKind == .localOutcome {
      return switch candidate.status {
      case .changesRequested, .superseded, .failed:
        "This local outcome was not accepted."
      default:
        "This outcome is stored in Spedito and does not create or promote a repository revision."
      }
    }
    return switch candidate.status {
    case .changesRequested, .superseded, .failed:
      "This candidate was not promoted to local trunk."
    default:
      "The ticket branch remains isolated from trunk until the reviewed demo is approved."
    }
  }

  private func permissionRequestSection(
    _ request: AgentPermissionRequest,
    showsBottomSeparator: Bool
  ) -> some View {
    let run = model.runs.first { $0.id == request.agentRunID }
    let requestProfile = run.flatMap { run in
      model.profiles.first { $0.id == run.profileID }
    }
    let isActionable = pendingPermissionRequest?.id == request.id
    let presentation = SprintPermissionRequestPresentation(request: request)
    let isSpeditoDecision =
      request.status == .existingAccess
      || request.status == .policyDenied
    return workLogArtifactRow(
      actorName: isSpeditoDecision
        ? "Spedito"
        : requestProfile?.name ?? "Spedito",
      profile: isSpeditoDecision ? nil : requestProfile,
      createdAt: request.createdAt,

      showsBottomSeparator: showsBottomSeparator
    ) {
      if request.status == .existingAccess {
        WorkLogArtifactCard(
          title: SprintPermissionRequestPresentation.existingAccessTitle,
          subtitle: SprintPermissionRequestPresentation.existingAccessSummary,
          systemImage: "lock.open.fill",
          tint: .green
        ) {
          WorkLogDisclosure(
            collapsedTitle: "Requested access",
            tint: .green,
            labelFont: .caption.weight(.semibold)
          ) {
            Text(request.detail)
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      } else if request.status == .policyDenied {
        WorkLogArtifactCard(
          title: SprintPermissionRequestPresentation.protectedStorageTitle,
          subtitle: SprintPermissionRequestPresentation.protectedStorageSummary,
          systemImage: "lock.shield.fill",
          tint: .orange
        ) {
          VStack(alignment: .leading, spacing: 10) {
            if let reason = request.reason {
              TicketMarkdownDocument(source: reason, baseFont: .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WorkLogDisclosure(
              collapsedTitle: "Requested access",
              tint: .orange,
              labelFont: .caption.weight(.semibold)
            ) {
              Text(request.detail)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        WorkLogArtifactCard(
          title: request.title,
          subtitle: presentation.context,
          systemImage: "lock.shield.fill",
          tint: .orange,
          headerAccessory: {
            Text(
              permissionStatusTitle(
                request.status,
                isActionable: isActionable
              )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(
              permissionStatusTint(
                request.status,
                isActionable: isActionable
              )
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              permissionStatusTint(
                request.status,
                isActionable: isActionable
              ).opacity(0.1),
              in: Capsule()
            )
          },
          content: {
            VStack(alignment: .leading, spacing: 13) {

              VStack(alignment: .leading, spacing: 5) {
                Text("Why this is needed")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                TicketMarkdownDocument(source: presentation.purpose, baseFont: .body)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .textSelection(.enabled)

              WorkLogDisclosure(
                collapsedTitle: presentation.detailTitle,
                tint: .orange,
                labelFont: .caption.weight(.semibold)
              ) {
                Text(request.detail)
                  .font(
                    request.kind == .command
                      ? .system(.callout, design: .monospaced)
                      : .callout
                  )
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .fixedSize(horizontal: false, vertical: true)

              if isActionable {
                HStack {
                  Spacer()
                  Button("Deny") {
                    decidePermissionRequest(request, allow: false)
                  }
                  .buttonStyle(.bordered)
                  .disabled(decidingPermissionRequestID != nil)
                  .accessibilityIdentifier("permission.deny.\(request.id.uuidString)")

                  Button("Allow once") {
                    decidePermissionRequest(request, allow: true)
                  }
                  .buttonStyle(.bordered)
                  .disabled(decidingPermissionRequestID != nil)
                  .accessibilityIdentifier("permission.allow-once.\(request.id.uuidString)")

                  if request.productGrantSignature != nil {
                    Button("Always allow") {
                      decidePermissionRequest(
                        request,
                        allow: true,
                        rememberForProduct: true
                      )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(decidingPermissionRequestID != nil)
                    .accessibilityIdentifier("permission.always.\(request.id.uuidString)")
                  }
                }
              }

              if let explanation = permissionExplanation(request) {
                Text(explanation)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        )
      }
    }
  }

  private func permissionStatusTitle(
    _ status: AgentPermissionRequestStatus,
    isActionable: Bool
  ) -> String {
    switch status {
    case .pending: "Needs your input"
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .existingAccessPendingDelivery, .grantAccessPendingDelivery:
      "Approval saved"
    case .denyPendingDelivery, .policyDenyPendingDelivery:
      "Denial saved"
    case .allowed: "Allowed"
    case .existingAccess: "Existing access"
    case .policyDenied: "Protected"
    case .denied: "Denied"
    case .interrupted: isActionable ? "Needs your input" : "Interrupted"
    }
  }

  private func permissionStatusTint(
    _ status: AgentPermissionRequestStatus,
    isActionable: Bool
  ) -> Color {
    switch status {
    case .pending: .orange
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .existingAccessPendingDelivery, .grantAccessPendingDelivery:
      .green
    case .denyPendingDelivery: .secondary
    case .policyDenyPendingDelivery: .orange
    case .allowed: .green
    case .existingAccess: .green
    case .policyDenied: .orange
    case .denied: .secondary
    case .interrupted: isActionable ? .orange : .secondary
    }
  }

  private func permissionExplanation(_ request: AgentPermissionRequest) -> String? {
    switch request.status {
    case .pending:
      if request.kind == .fileChange {
        "Allow once grants this file change for the current run. Deny returns control to the agent so it can adapt."
      } else {
        nil
      }
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .existingAccessPendingDelivery, .grantAccessPendingDelivery:
      "The approval is saved. Spedito will deliver it without asking again when the agent requests the same capability."
    case .denyPendingDelivery, .policyDenyPendingDelivery:
      "The denial is saved. Spedito will deliver it without asking again when the agent requests the same capability."
    case .allowed, .existingAccess, .policyDenied, .denied, .interrupted:
      nil
    }
  }

  private func demoSection(
    _ demo: SprintTicketDemoLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    let candidate = demo.candidate
    let result = executionResult(for: candidate)
    let specification = result?.demo
    let session = model.currentDemoSession(for: candidate.id)
    let localOutcomePresentation: SprintTicketLocalOutcomePresentation? =
      candidate.deliveryKind == .localOutcome
      ? SprintTicketLocalOutcomePresentation(result: result, status: candidate.status)
      : nil
    let eventProfile = model.profiles.first { $0.name == demo.event.actor }
    let canOpenDemo =
      candidate.deliveryKind.changesRepository
      && candidate.id == currentCandidate?.id
      && candidate.status == .readyForDemo
      && currentItem.state == .acceptance
    let demoTint = Color.blue
    return workLogArtifactRow(
      actorName: eventProfile?.name ?? demo.event.actor,
      profile: eventProfile,
      createdAt: demo.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      WorkLogArtifactCard(
        title:
          candidate.deliveryKind == .localOutcome
          ? "Review outcome"
          : specification?.title ?? "Demo",
        subtitle:
          localOutcomePresentation?.subtitle
          ?? specification?.presentation.kind.title
          ?? "Demo setup unavailable",
        systemImage:
          candidate.deliveryKind == .localOutcome
          ? "doc.text.magnifyingglass"
          : "play.rectangle.fill",
        tint: demoTint,
        headerAccessory: {
          HStack(spacing: 8) {
            if canOpenDemo,
              session?.status == .ready,
              specification?.presentation.kind == .browser
                || specification?.presentation.kind == .macApplication
            {
              Button("Stop demo") {
                stopDemo(candidate)
              }
              .buttonStyle(.bordered)
              .disabled(isDemoActionRunning)
            }
            if canOpenDemo {
              Button(demoButtonTitle(specification: specification, session: session)) {
                launchDemo(candidate)
              }
              .buttonStyle(.borderedProminent)
              .disabled(isDemoActionRunning || specification == nil)
            } else {
              Text(demoStatusTitle(candidate.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(demoStatusTint(candidate.status))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(demoStatusTint(candidate.status).opacity(0.1), in: Capsule())
            }
          }
        },
        content: {
          VStack(alignment: .leading, spacing: 14) {

            Text(
              localOutcomePresentation?.explanation
                ?? demoExplanation(
                  candidate: candidate,
                  specification: specification,
                  session: session,
                  canOpenDemo: canOpenDemo
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let outcome = localOutcomePresentation?.outcome {
              VStack(alignment: .leading, spacing: 7) {
                Text("Outcome to review")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                TicketMarkdownDocument(source: outcome, baseFont: .body)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }

            if let handoff = localOutcomePresentation?.handoff {
              WorkLogDisclosure(
                collapsedTitle: "Read the full analysis and evidence",
                expandedTitle: "Hide the full analysis and evidence",
                tint: demoTint
              ) {
                TicketMarkdownDocument(source: handoff, baseFont: .callout)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(10)
              }
            }

            if let instructions = result?.reviewInstructions,
              !instructions.isEmpty
            {
              VStack(alignment: .leading, spacing: 7) {
                Text(localOutcomePresentation == nil ? "Things to try" : "Decision and checks")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                ForEach(instructions, id: \.self) { instruction in
                  HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                      .font(.caption)
                      .foregroundStyle(demoTint)
                      .padding(.top, 1)
                    Text(instruction)
                      .font(.callout)
                  }
                }
              }
            }

            if let output = session?.output, !output.isEmpty {
              VStack(alignment: .leading, spacing: 7) {
                Text("Demo result")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                ScrollView {
                  Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxHeight: 180)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
              }
            }

            if let error = session?.errorMessage, !error.isEmpty {
              Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      )
    }
  }

  private func demoButtonTitle(
    specification: DemoLaunchSpecification?,
    session: DemoSession?
  ) -> String {
    if isDemoActionRunning {
      return session?.status == .starting ? "Starting…" : "Preparing…"
    }
    switch session?.status {
    case .ready:
      return specification?.presentation.kind == .commandOutput
        ? "Run demo again"
        : "Open demo"
    case .failed:
      return "Retry demo"
    default:
      return "Demo"
    }
  }

  private func demoStatusTitle(_ status: CandidateRevisionStatus) -> String {
    switch status {
    case .accepted: "Approved"
    case .readyForDemo: "Ready"
    case .changesRequested: "Changes requested"
    case .superseded: "Superseded"
    case .failed: "Stopped"
    default: "Historical"
    }
  }

  private func demoStatusTint(_ status: CandidateRevisionStatus) -> Color {
    switch status {
    case .accepted: .green
    case .readyForDemo: .blue
    case .changesRequested, .failed: .red
    default: .secondary
    }
  }

  private func demoExplanation(
    candidate: CandidateRevision,
    specification: DemoLaunchSpecification?,
    session: DemoSession?,
    canOpenDemo: Bool
  ) -> String {
    guard let specification else {
      return
        "This candidate predates managed demos. Request changes so the assigned team member can add a one-click demo."
    }
    guard canOpenDemo else {
      return candidate.status == .accepted
        ? "The product owner approved this reviewed demo and promoted its integrated revision."
        : "This earlier demo submission remains in the work log as delivery history."
    }
    switch session?.status {
    case .preparing:
      return "Spedito is preparing the exact reviewed revision."
    case .starting:
      return "Spedito is starting the demo and waiting until it is ready."
    case .ready:
      switch specification.presentation.kind {
      case .browser:
        return "The local web demo is running. Open demo reuses it without starting a duplicate."
      case .macApplication:
        return "The reviewed macOS app is running in its managed demo session."
      case .artifact:
        return "The reviewed artifact has been opened."
      case .commandOutput:
        return "The reviewed scenario completed and its result is shown below."
      }
    case .failed:
      return "The demo could not open. Retry it or describe what happened and request changes."
    case .stopped:
      return "The reviewed demo is ready. Spedito will manage its setup and cleanup."
    case nil:
      return "Spedito will open the exact reviewed result and manage any local processes it needs."
    }
  }

  private func launchDemo(_ candidate: CandidateRevision) {
    guard !isDemoActionRunning else { return }
    isDemoActionRunning = true
    Task {
      _ = await model.launchDemo(for: candidate)
      isDemoActionRunning = false
    }
  }

  private func stopDemo(_ candidate: CandidateRevision) {
    guard !isDemoActionRunning else { return }
    isDemoActionRunning = true
    Task {
      await model.stopDemo(for: candidate)
      isDemoActionRunning = false
    }
  }

  private func decidePermissionRequest(
    _ request: AgentPermissionRequest,
    allow: Bool,
    rememberForProduct: Bool = false
  ) {
    guard decidingPermissionRequestID == nil else { return }
    decidingPermissionRequestID = request.id
    Task {
      await model.decidePermissionRequest(
        request,
        allow: allow,
        rememberForProduct: rememberForProduct
      )
      decidingPermissionRequestID = nil
    }
  }

  @ViewBuilder
  private func followUpTicketProposalsSection(
    _ followUp: SprintTicketFollowUpLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    if let result = executionResult(for: followUp.candidate),
      !result.followUpTicketProposals.isEmpty
    {
      let followUpProfile = profile(for: followUp.candidate)
      workLogArtifactRow(
        actorName: followUpProfile?.name ?? "Spedito",
        profile: followUpProfile,
        createdAt: followUp.createdAt,
        showsBottomSeparator: showsBottomSeparator
      ) {
        WorkLogArtifactCard(
          title: "Recommended follow-up work",
          systemImage: "arrow.triangle.branch",
          tint: .purple
        ) {
          VStack(alignment: .leading, spacing: 12) {
            Text(followUpExplanation(followUp.candidate.status))
              .font(.callout)
              .foregroundStyle(.secondary)

            ForEach(result.followUpTicketProposals, id: \.reference) { proposal in
              HStack(alignment: .top, spacing: 10) {
                Text(proposal.reference)
                  .font(.caption.monospaced().weight(.semibold))
                  .foregroundStyle(.purple)
                  .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                  Text(proposal.title)
                    .font(.subheadline.weight(.semibold))
                  Text(proposal.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Label(
                  proposal.suggestedRole.title,
                  systemImage: proposal.suggestedRole.symbolName
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(proposal.suggestedRole.tint)
              }
              .padding(11)
              .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
            }
          }
        }
      }
    }
  }

  private func followUpExplanation(
    _ status: CandidateRevisionStatus
  ) -> String {
    switch status {
    case .accepted:
      "These recommendations were published to the backlog for individual review."
    case .readyForDemo:
      "Approving this research outcome will publish these as reviewable backlog proposals. Nothing enters the backlog until you accept each proposal."
    case .queuedForReview, .queuedForIntegration, .integrating, .resolvingConflict:
      "These recommendations are part of this candidate and remain subject to tech lead review after integration."
    case .reviewing:
      "These recommendations are part of the integrated candidate under tech lead review."
    case .promoting:
      "This accepted outcome is being published. Its recommendations remain unpublished until acceptance completes."
    case .changesRequested, .superseded, .failed:
      "These recommendations belonged to an earlier candidate and were not published."
    }
  }

  private func knowledgeProposalsSection(
    _ knowledge: SprintTicketKnowledgeLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    let knowledgeProfile = profile(for: knowledge.candidate)
    return workLogArtifactRow(
      actorName: knowledgeProfile?.name ?? "Spedito",
      profile: knowledgeProfile,
      createdAt: knowledge.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      WorkLogArtifactCard(
        title: "Knowledge changes",
        systemImage: "books.vertical.fill",
        tint: .indigo,
        headerAccessory: {
          Text(knowledgeProposalStatusTitle(knowledge.proposals))
            .font(.caption.weight(.semibold))
            .foregroundStyle(knowledgeProposalStatusTint(knowledge.proposals))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              knowledgeProposalStatusTint(knowledge.proposals).opacity(0.1),
              in: Capsule()
            )
        },
        content: {
          VStack(alignment: .leading, spacing: 12) {

            Text(knowledgeProposalExplanation(knowledge.proposals))
              .font(.callout)
              .foregroundStyle(.secondary)

            ForEach(knowledge.proposals) { proposal in
              let knowledgePage = publishedKnowledgePage(for: proposal)
              CanonicalKnowledgeProposalCard(
                proposal: proposal,
                currentPage: knowledgePage,
                requiresOwnerApproval: model.requiresKnowledgeApproval,
                isDeciding: decidingKnowledgeProposalIDs.contains(proposal.id),
                onOpenPage: knowledgePage.map { page in
                  {
                    model.requestKnowledgeFocus(pageID: page.id)
                    dismiss()
                  }
                },
                onDecision: { accept in
                  decidingKnowledgeProposalIDs.insert(proposal.id)
                  Task {
                    _ = await model.decideKnowledgePageProposal(
                      proposal,
                      accept: accept
                    )
                    decidingKnowledgeProposalIDs.remove(proposal.id)
                  }
                }
              )
            }
          }
        }
      )
    }
  }

  private func publishedKnowledgePage(
    for proposal: KnowledgePageProposal
  ) -> KnowledgePage? {
    TicketKnowledgeNavigationPolicy.publishedPage(
      for: proposal,
      pages: model.knowledgePages
    )
  }

  private func knowledgeProposalStatusTitle(
    _ proposals: [KnowledgePageProposal]
  ) -> String {
    if proposals.contains(where: { $0.status == .proposed }) {
      return "Reviewing"
    }
    if proposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval ? "Your approval required" : "Ready to publish"
    }
    if proposals.allSatisfy({ $0.status == .accepted }) {
      return "Published"
    }
    return "Review recorded"
  }

  private func knowledgeProposalStatusTint(
    _ proposals: [KnowledgePageProposal]
  ) -> Color {
    if proposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval ? .orange : .indigo
    }
    if proposals.allSatisfy({ $0.status == .accepted }) {
      return .green
    }
    return .indigo
  }

  private func knowledgeProposalExplanation(
    _ proposals: [KnowledgePageProposal]
  ) -> String {
    if proposals.contains(where: { $0.status == .proposed }) {
      return
        "These durable wiki changes travel with the delivery and are currently being checked by the tech lead."
    }
    if proposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval
        ? "The tech lead reviewed these durable wiki changes. Accept or reject each change before completing the ticket."
        : "The tech lead reviewed these product knowledge changes. They’ll be published automatically when you approve this ticket."
    }
    if proposals.allSatisfy({ $0.status == .accepted }) {
      return
        "Published after tech lead review. Open a page below to read the canonical result in the knowledge base."
    }
    return "These proposed changes remain visible as part of the ticket’s delivery history."
  }

  var body: some View {
    let workLogRows = SprintTicketWorkLogTimeline.rows(workLogEntries)

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: currentItem.type.symbolName)
          .foregroundStyle(currentItem.type.tint)
        Text(currentItem.key)
          .font(.callout.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Ticket details")
          .font(.title2.bold())
          .accessibilityIdentifier("ticket.detail.\(item.id.uuidString)")
        Spacer()
        if hasPendingWorkLogAction {
          latestActivityButton(hasEntries: !workLogRows.isEmpty)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else {
          latestActivityButton(hasEntries: !workLogRows.isEmpty)
            .buttonStyle(.bordered)
        }
        Button("Close") { dismiss() }
      }
      .padding(.horizontal, 22)
      .frame(height: 64)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            TicketDetailOverview(
              title: currentItem.title,
              context: currentItem.body,
              emptyContextText: "No additional context was recorded.",
              metadata: [
                TicketDetailMetadataValue(
                  id: "status",
                  title: "Status",
                  value: boardStatusTitle,
                  symbol: boardStatusSymbol,
                  tint: boardStatusTint
                ),
                TicketDetailMetadataValue(
                  id: "owner",
                  title: "Owner",
                  value: owner?.name ?? "Unassigned",
                  symbol: owner?.role.symbolName ?? "person.crop.circle.badge.questionmark",
                  tint: owner?.role.tint ?? Color.secondary
                ),
                TicketDetailMetadataValue(
                  id: "type",
                  title: "Type",
                  value: currentItem.type.title,
                  symbol: currentItem.type.symbolName,
                  tint: currentItem.type.tint
                ),
                TicketDetailMetadataValue(
                  id: "priority",
                  title: "Priority",
                  value: currentItem.priority.title,
                  symbol: "flag.fill",
                  tint: currentItem.priority.tint
                ),
              ],
              epic: TicketEpicNavigation.destination(
                for: currentItem,
                in: model.epics
              ),
              acceptanceCriteria: currentItem.acceptanceCriteria,
              emptyAcceptanceCriteriaText: "No acceptance criteria",
              relationships: overviewRelationships,
              onOpenRelationship: openRelationship
            )

            Divider()

            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Work log")
                  .font(.headline)
                Text(workLogRows.count.formatted())
                  .font(.caption.monospacedDigit())
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
                  .background(.quaternary, in: Capsule())
                Spacer()
              }

              if workLogRows.isEmpty {
                HStack(spacing: 10) {
                  Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.tertiary)
                  VStack(alignment: .leading, spacing: 2) {
                    Text("No work logged yet")
                      .font(.subheadline.weight(.medium))
                    Text("Comments, assignments, and status changes will appear here.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
              } else {
                VStack(spacing: 0) {
                  ForEach(workLogRows) { row in
                    Group {
                      switch row.entry {
                      case .comment(let comment):
                        SprintTicketCommentRow(
                          comment: comment,
                          externalURL: workLogExternalURL(for: comment),
                          authorProfile: model.profiles.first { $0.name == comment.authorName },
                          mentionedProfile: mentionedProfile(
                            in: comment.body,
                            profiles: model.profiles
                          ),
                          showsBottomSeparator: row.showsBottomSeparator,
                          ownerAnswerSelection:
                            comment.id == activeOwnerQuestionComment?.id
                            ? ownerAnswerSelection
                            : nil,
                          customOwnerAnswer:
                            comment.id == activeOwnerQuestionComment?.id
                            ? $customOwnerAnswerDraft
                            : nil,
                          onSelectOwnerAnswer:
                            comment.id == activeOwnerQuestionComment?.id
                            ? { selection in
                              selectOwnerAnswer(selection)
                            }
                            : nil,
                          routedRecipientName:
                            comment.id == unansweredPermissionComment?.id
                            ? questionRecipient?.name
                            : nil,
                          isRouting:
                            comment.id == unansweredPermissionComment?.id
                            && isAskingQuestion,
                          onRoute:
                            comment.id == unansweredPermissionComment?.id
                            && !model.isTicketConversationMessageRunning
                            ? {
                              guard let questionRecipient else { return }
                              Task {
                                _ = await routeExistingQuestion(
                                  comment,
                                  to: questionRecipient
                                )
                              }
                            }
                            : nil,
                          onOpenDecisionArtifact: { artifact in
                            model.openDecisionArtifact(
                              artifact,
                              workItemID: item.id
                            )
                          }
                        )
                      case .event(let event):
                        SprintTicketEventRow(
                          event: event,
                          profiles: model.profiles,
                          retrospectiveNotes: model.retrospectiveNotes,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .permission(let request):
                        permissionRequestSection(
                          request,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .runContext(let context):
                        contextSection(
                          context,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .candidate(let candidate):
                        deliveryRevisionSection(
                          candidate,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .knowledge(let knowledge):
                        knowledgeProposalsSection(
                          knowledge,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .demo(let demo):
                        demoSection(
                          demo,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .followUp(let followUp):
                        followUpTicketProposalsSection(
                          followUp,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      }
                    }
                    .id(row.id)
                  }
                }
              }
            }
          }
          .padding(24)
          .id("work-log-bottom")
        }
        .onChange(of: workLogScrollRequest) {
          Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo("work-log-bottom", anchor: .bottom)
            }
          }
        }
      }

      Divider()

      if model.ticketConversationWorkItemID == item.id {
        ConversationRespondingStatus(
          profile: activeTicketConversationProfile,
          fallbackName: "Team member",
          status: "is thinking…",
          activity: model.ticketConversationActivity,
          onStop: model.cancelTicketConversationMessage
        )
      }

      commentComposer
    }
    .frame(width: detailWidth, height: detailHeight)
    .onChange(of: activeOwnerQuestionComment?.id) { _, _ in
      ownerAnswerSelection = nil
      customOwnerAnswerDraft = ""
    }
    .sheet(item: $selectedRelationshipTicket) { relatedItem in
      SprintTicketDetailView(item: relatedItem)
    }
    .onAppear {
      model.setGitHubReviewTicket(item.id, isVisible: true)
    }
    .onDisappear {
      model.setGitHubReviewTicket(item.id, isVisible: false)
    }
    .task {
      while !Task.isCancelled {
        let isFirstLoad = !hasLoadedWorkLog
        let previousLastEntryID = workLogEntries.last?.id
        let latestComments = await model.comments(for: item.id, productID: item.productID)
        let latestActivityEvents = await model.activityEvents(
          for: item.id,
          productID: item.productID
        )
        if latestComments != comments {
          comments = latestComments
        }
        if latestActivityEvents != activityEvents {
          activityEvents = latestActivityEvents
        }
        let latestEntryID = workLogEntries.last?.id
        if isFirstLoad, hasPendingWorkLogAction {
          workLogScrollRequest += 1
        } else if hasLoadedWorkLog,
          !isAcceptingTicket,
          latestEntryID != previousLastEntryID
        {
          workLogScrollRequest += 1
        }
        hasLoadedWorkLog = true
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func openRelationship(_ relationshipID: UUID) {
    selectedRelationshipTicket = TicketRelationshipNavigation.destination(
      for: relationshipID,
      source: currentItem,
      in: model.workItems
    )
  }

  private var commentComposer: some View {
    SprintTicketCommentComposer(
      ticketState: currentItem.state,
      canRetryFailedPostReviewDemo: canRetryFailedPostReviewDemo,
      awaitingOwnerName: awaitingOwnerProfile?.name,
      failedDeliveryName: failedDeliveryProfile?.name,
      hasPendingPermissionRequest: pendingPermissionRequest != nil,
      hasActiveOwnerQuestion: activeOwnerQuestionComment != nil,
      commentReplyRecipientName: commentReplyRecipient?.name,
      pausedQuestionRecipientName: pausedQuestionRecipient?.name,
      questionRecipientName: questionRecipient?.name,
      ownerAnswer: ownerAnswer,
      isPostingComment: isPostingComment,
      isAskingQuestion: isAskingQuestion,
      isResumingWork: isResumingWork,
      isAcceptingTicket: isAcceptingTicket,
      isConversationMessageRunning: model.isTicketConversationMessageRunning,
      knowledgeProposalsBlockCompletion: knowledgeProposalsBlockCompletion,
      commentError: commentError,
      focusResetRequest: commentComposerFocusResetRequest,
      onPostComment: { body in
        await postComment(body)
      },
      onAskCommentRecipient: { body in
        guard let commentReplyRecipient else { return false }
        return await askQuestion(body, to: commentReplyRecipient)
      },
      onAskPausedRecipient: { body in
        guard let pausedQuestionRecipient else { return false }
        return await askQuestion(body, to: pausedQuestionRecipient)
      },
      onAskQuestionRecipient: { body in
        guard let questionRecipient else { return false }
        return await askQuestion(body, to: questionRecipient)
      },
      onResumeWork: { body in
        await resumeWork(body)
      },
      onAcceptTicket: acceptTicket
    )
  }

  private func acceptTicket() {
    guard !isAcceptingTicket, !knowledgeProposalsBlockCompletion else { return }
    if model.beginSprintTicketAcceptance(currentItem) {
      dismiss()
    }
  }

  private func postComment(_ draft: String) async -> Bool {
    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isPostingComment else { return false }
    commentError = nil
    isPostingComment = true

    if let comment = await model.appendSprintWorkLogComment(
      workItemID: item.id,
      productID: item.productID,
      body: body
    ) {
      if !comments.contains(where: { $0.id == comment.id }) {
        comments.append(comment)
        comments.sort {
          if $0.createdAt == $1.createdAt {
            return $0.id.uuidString < $1.id.uuidString
          }
          return $0.createdAt < $1.createdAt
        }
      }
      workLogScrollRequest += 1
      isPostingComment = false
      return true
    }
    commentError = "Your comment couldn't be saved. Try again."
    isPostingComment = false
    return false
  }

  private func selectOwnerAnswer(_ selection: TicketOwnerAnswerSelection) {
    ownerAnswerSelection = selection
    commentComposerFocusResetRequest += 1
  }

  private func askQuestion(
    _ draft: String,
    to recipient: AgentProfile
  ) async -> Bool {
    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isAskingQuestion else { return false }
    commentError = nil
    isAskingQuestion = true

    let attributedBody = "@\(recipient.name) \(body)"
    guard
      let comment = await model.appendOwnerComment(
        workItemID: item.id,
        productID: item.productID,
        body: attributedBody
      )
    else {
      commentError = "Your question couldn't be saved. Try again."
      isAskingQuestion = false
      return false
    }
    appendLocalComment(comment)
    workLogScrollRequest += 1

    do {
      _ = try await model.sendTicketConversationMessage(
        for: currentItem,
        to: recipient,
        ownerMessage: body,
        allowsProposal: false
      )
      let latestComments = await model.comments(for: item.id, productID: item.productID)
      if latestComments != comments {
        comments = latestComments
      }
      workLogScrollRequest += 1
    } catch {
      commentError = error.localizedDescription
    }
    isAskingQuestion = false
    return true
  }

  private func resumeWork(_ draft: String) async -> Bool {
    if canRetryFailedPostReviewDemo {
      guard !isResumingWork else { return false }
      commentError = nil
      isResumingWork = true
      let didRetry = await model.retryFailedPostReviewDemo(
        workItemID: item.id
      )
      if !didRetry {
        commentError = "Demo preparation couldn't be retried. Try again."
      }
      let latestComments = await model.comments(for: item.id, productID: item.productID)
      let latestActivityEvents = await model.activityEvents(
        for: item.id,
        productID: item.productID
      )
      if latestComments != comments {
        comments = latestComments
      }
      if latestActivityEvents != activityEvents {
        activityEvents = latestActivityEvents
      }
      workLogScrollRequest += 1
      isResumingWork = false
      return didRetry
    }

    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isResumingWork else { return false }
    let answeredQuestions = answeredOwnerQuestions(answer: body)
    let submittedSelection = ownerAnswerSelection
    let submittedCustomAnswer = customOwnerAnswerDraft
    let wasAnsweringQuestion = activeOwnerQuestionComment != nil
    if wasAnsweringQuestion {
      ownerAnswerSelection = nil
      customOwnerAnswerDraft = ""
    }
    commentError = nil
    isResumingWork = true

    if let comment = await model.resumeSprintWork(
      productID: item.productID,
      workItemID: item.id,
      body: body,
      answeredQuestions: answeredQuestions
    ) {
      appendLocalComment(comment)
      workLogScrollRequest += 1
      isResumingWork = false
      return true
    }
    if wasAnsweringQuestion {
      ownerAnswerSelection = submittedSelection
      customOwnerAnswerDraft = submittedCustomAnswer
    }
    commentError = "Your direction couldn't be saved. Try again."
    isResumingWork = false
    return false
  }

  private func routeExistingQuestion(
    _ comment: TicketComment,
    to recipient: AgentProfile
  ) async -> Bool {
    guard
      comment.authorKind == .owner,
      !isAskingQuestion,
      !model.isTicketConversationMessageRunning
    else { return false }
    commentError = nil
    isAskingQuestion = true

    do {
      _ = try await model.sendTicketConversationMessage(
        for: currentItem,
        to: recipient,
        ownerMessage: comment.body,
        allowsProposal: false
      )
      let latestComments = await model.comments(for: item.id, productID: item.productID)
      if latestComments != comments {
        comments = latestComments
      }
      workLogScrollRequest += 1
      isAskingQuestion = false
      return true
    } catch {
      commentError = error.localizedDescription
      isAskingQuestion = false
      return false
    }
  }

  private func answeredOwnerQuestions(
    answer: String
  ) -> [TicketAnsweredQuestion] {
    guard
      let comment = activeOwnerQuestionComment,
      let presentation = TicketOwnerQuestion.presentation(
        in: comment.body,
        structuredQuestion: comment.ownerQuestion
      )
    else { return [] }

    let selectedOption: String? =
      if case .option(let option) = ownerAnswerSelection {
        option
      } else {
        nil
      }
    return [
      TicketAnsweredQuestion(
        question: TicketRefinementQuestion(
          prompt: presentation.question.prompt,
          options: presentation.question.options
        ),
        selectedOption: selectedOption,
        answer: answer
      )
    ]
  }

  private func appendLocalComment(_ comment: TicketComment) {
    guard !comments.contains(where: { $0.id == comment.id }) else { return }
    comments.append(comment)
    comments.sort {
      if $0.createdAt == $1.createdAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.createdAt < $1.createdAt
    }
  }
}

private struct SprintTicketCommentComposer: View {
  let ticketState: WorkItemState
  let canRetryFailedPostReviewDemo: Bool
  let awaitingOwnerName: String?
  let failedDeliveryName: String?
  let hasPendingPermissionRequest: Bool
  let hasActiveOwnerQuestion: Bool
  let commentReplyRecipientName: String?
  let pausedQuestionRecipientName: String?
  let questionRecipientName: String?
  let ownerAnswer: String?
  let isPostingComment: Bool
  let isAskingQuestion: Bool
  let isResumingWork: Bool
  let isAcceptingTicket: Bool
  let isConversationMessageRunning: Bool
  let knowledgeProposalsBlockCompletion: Bool
  let commentError: String?
  let focusResetRequest: Int
  let onPostComment: (String) async -> Bool
  let onAskCommentRecipient: (String) async -> Bool
  let onAskPausedRecipient: (String) async -> Bool
  let onAskQuestionRecipient: (String) async -> Bool
  let onResumeWork: (String) async -> Bool
  let onAcceptTicket: () -> Void

  @State private var draft = ""
  @FocusState private var isFocused: Bool

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSubmitting: Bool {
    isPostingComment || isAskingQuestion || isResumingWork
  }

  private var canPostComment: Bool {
    !trimmedDraft.isEmpty && !isSubmitting
  }

  private var canAskCommentRecipient: Bool {
    canPostComment
      && commentReplyRecipientName != nil
      && !isConversationMessageRunning
  }

  private var canAskQuestionRecipient: Bool {
    canPostComment
      && questionRecipientName != nil
      && !isConversationMessageRunning
  }

  private var resumeBody: String {
    if hasActiveOwnerQuestion {
      return ownerAnswer ?? ""
    }
    return trimmedDraft
  }

  private var canResumeWork: Bool {
    (canRetryFailedPostReviewDemo || !resumeBody.isEmpty)
      && !isSubmitting
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(ConversationPalette.owner.opacity(0.12))
        Image(systemName: "person.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(ConversationPalette.owner)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 7) {
        statusMessage

        Text(hasActiveOwnerQuestion ? "Your response" : "Add a comment")
          .font(.subheadline.weight(.semibold))

        ZStack(alignment: .topLeading) {
          if draft.isEmpty && !isFocused {
            Text("Add context, answer a question, or give feedback…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
          TextEditor(text: $draft)
            .scrollContentBackground(.hidden)
            .font(.body)
            .focused($isFocused)
            .padding(8)
            .accessibilityIdentifier("sprint.ticket.comment.editor")
            .onKeyPress(phases: .down) { keyPress in
              handleKeyPress(keyPress)
            }
        }
        .frame(height: 58)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }

        HStack {
          if let commentError {
            Label(commentError, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          } else {
            Text("Return to comment · Shift-Return for a new line")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Spacer()
          actionButtons
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .background(.quaternary.opacity(0.18))
    .onChange(of: focusResetRequest) {
      isFocused = false
    }
  }

  @ViewBuilder
  private var statusMessage: some View {
    if canRetryFailedPostReviewDemo {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Image(systemName: "arrow.clockwise.circle.fill")
          Text("Demo preparation stopped unexpectedly.")
            .fontWeight(.semibold)
        }
        Text(
          "Retry the already reviewed candidate. No new comment or repeat implementation is required."
        )
        .foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.red)
    } else if let awaitingOwnerName {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Image(systemName: "pause.circle.fill")
          Text(awaitingOwnerName)
            .fontWeight(.semibold)
          Text("is paused and waiting for direction.")
        }
        Text(
          hasPendingPermissionRequest
            ? "Use Allow or Deny on the permission request above, or ask the waiting team member for an explanation without resuming work."
            : hasActiveOwnerQuestion
              ? "Choose an answer above or select Other, then choose Submit answers."
              : "Ask a question without restarting work, or add direction and choose Submit answers."
        )
        .foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.orange)
    } else if let failedDeliveryName {
      HStack(spacing: 7) {
        Image(systemName: "arrow.clockwise.circle.fill")
        Text(failedDeliveryName)
          .fontWeight(.semibold)
        Text("stopped unexpectedly. Add direction, then choose Retry work.")
      }
      .font(.caption)
      .foregroundStyle(.red)
    } else if ticketState == .acceptance {
      Label(
        commentReplyRecipientName.map {
          "Comments go to \($0) for a reply without changing the reviewed demo."
        }
          ?? "No team member is available to answer comments on this ticket.",
        systemImage: "play.rectangle"
      )
      .font(.caption)
      .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var actionButtons: some View {
    if hasPendingPermissionRequest {
      commentButton(style: .bordered)
      questionButton(
        recipientName: questionRecipientName,
        action: onAskQuestionRecipient
      )
    } else if canRetryFailedPostReviewDemo {
      commentButton(style: .bordered)

      Button(
        isResumingWork ? "Retrying…" : "Retry demo preparation"
      ) {
        submitResumeWork()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canResumeWork)
    } else if awaitingOwnerName != nil {
      commentButton(style: .bordered)

      if let pausedQuestionRecipientName {
        Button(
          isAskingQuestion ? "Asking…" : "Ask \(pausedQuestionRecipientName)"
        ) {
          submitDraft(using: onAskPausedRecipient)
        }
        .buttonStyle(.bordered)
        .disabled(!canPostComment)
      }

      Button {
        submitResumeWork()
      } label: {
        Label(
          isResumingWork ? "Submitting…" : "Submit answers",
          systemImage: "paperplane.fill"
        )
      }
      .accessibilityIdentifier("sprint.ticket.owner-question.submit")
      .buttonStyle(.borderedProminent)
      .disabled(!canResumeWork)
    } else if failedDeliveryName != nil {
      commentButton(style: .bordered)

      Button(isResumingWork ? "Retrying…" : "Retry work") {
        submitResumeWork()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canResumeWork)
    } else if ticketState == .acceptance {
      Button(isAskingQuestion ? "Commenting…" : "Comment") {
        submitDraft(using: onAskCommentRecipient)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("sprint.ticket.comment.send")
      .disabled(!canAskCommentRecipient)

      Divider()
        .frame(height: 20)
        .padding(.horizontal, 2)

      Button(isResumingWork ? "Sending…" : "Request changes") {
        submitResumeWork()
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("sprint.ticket.request-changes")
      .disabled(!canResumeWork)

      Button(isAcceptingTicket ? "Completing…" : "Approve and complete") {
        onAcceptTicket()
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("sprint.ticket.approve")
      .disabled(isAcceptingTicket || knowledgeProposalsBlockCompletion)
      .help(
        knowledgeProposalsBlockCompletion
          ? "Accept or reject every proposed knowledge change first."
          : "Accept this exact reviewed result and complete the ticket."
      )
    } else if ticketState == .running
      || ticketState == .integrating
      || ticketState == .verifying
    {
      commentButton(style: .bordered)
      questionButton(
        recipientName: questionRecipientName,
        action: onAskQuestionRecipient
      )
    } else {
      commentButton(style: .borderedProminent)
    }
  }

  @ViewBuilder
  private func questionButton(
    recipientName: String?,
    action: @escaping (String) async -> Bool
  ) -> some View {
    if let recipientName {
      Button(isAskingQuestion ? "Asking…" : "Ask \(recipientName)") {
        submitDraft(using: action)
      }
      .buttonStyle(.borderedProminent)
      .tint(.purple)
      .disabled(!canAskQuestionRecipient)
    }
  }

  @ViewBuilder
  private func commentButton(style: CommentButtonStyle) -> some View {
    switch style {
    case .bordered:
      Button(isPostingComment ? "Commenting…" : "Comment") {
        submitDraft(using: onPostComment)
      }
      .buttonStyle(.bordered)
      .disabled(!canPostComment)
    case .borderedProminent:
      Button(isPostingComment ? "Commenting…" : "Comment") {
        submitDraft(using: onPostComment)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canPostComment)
    }
  }

  private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    guard keyPress.key == .return else { return .ignored }
    if keyPress.modifiers.contains(.shift) {
      return .ignored
    }
    if ticketState == .acceptance, commentReplyRecipientName != nil {
      if canAskCommentRecipient {
        submitDraft(using: onAskCommentRecipient)
      }
      return .handled
    }
    if canPostComment {
      submitDraft(using: onPostComment)
    }
    return .handled
  }

  private func submitDraft(
    using action: @escaping (String) async -> Bool
  ) {
    let submittedDraft = trimmedDraft
    guard !submittedDraft.isEmpty, !isSubmitting else { return }
    draft = ""
    Task { @MainActor in
      if !(await action(submittedDraft)) {
        restore(submittedDraft)
      }
    }
  }

  private func submitResumeWork() {
    let submittedDraft = resumeBody
    guard canResumeWork else { return }
    let restoresDraft = !hasActiveOwnerQuestion && !canRetryFailedPostReviewDemo
    if restoresDraft {
      draft = ""
    }
    Task { @MainActor in
      if !(await onResumeWork(submittedDraft)), restoresDraft {
        restore(submittedDraft)
      }
    }
  }

  private func restore(_ submittedDraft: String) {
    if trimmedDraft.isEmpty {
      draft = submittedDraft
    } else {
      draft = submittedDraft + "\n" + draft
    }
  }

  private enum CommentButtonStyle {
    case bordered
    case borderedProminent
  }
}

private struct CanonicalKnowledgeProposalCard: View {
  let proposal: KnowledgePageProposal
  let currentPage: KnowledgePage?
  let requiresOwnerApproval: Bool
  let isDeciding: Bool
  let onOpenPage: (() -> Void)?
  let onDecision: (Bool) -> Void

  private var isPending: Bool {
    proposal.status == .proposed || proposal.status == .reviewed
  }

  private var sourceChanged: Bool {
    guard isPending, proposal.operation == .update, let currentPage else { return false }
    return currentPage.title != proposal.basePageTitle
      || currentPage.bodyMarkdown != proposal.basePageBodyMarkdown
  }

  private var requiresOwnerDecision: Bool {
    requiresOwnerApproval && proposal.status == .reviewed
  }

  private var statusTitle: String {
    switch proposal.status {
    case .proposed: "Awaiting tech lead"
    case .reviewed: requiresOwnerApproval ? "Decision required" : "Ready to publish"
    case .accepted: "Published"
    case .rejected: "Rejected"
    case .superseded: "Superseded"
    }
  }

  private var statusTint: Color {
    switch proposal.status {
    case .proposed: .secondary
    case .reviewed: .orange
    case .accepted: .green
    case .rejected, .superseded: .secondary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 9) {
        Text(proposal.operation == .create ? "New page" : "Update page")
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.indigo.opacity(0.12), in: Capsule())
          .foregroundStyle(.indigo)
        Text(proposal.title)
          .font(.headline)
        Spacer()
        Text(statusTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusTint)
      }

      Text(proposal.rationale)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if sourceChanged {
        Label(
          "A newer version of this page was published after this proposal was prepared. Dismiss this stale proposal; rerun the ticket only if its missing change is still needed.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      if isPending {
        WorkLogDisclosure(
          collapsedTitle: "Review rendered preview",
          expandedTitle: "Hide rendered preview",
          tint: .indigo
        ) {
          VStack(alignment: .leading, spacing: 14) {
            if proposal.operation == .update {
              VStack(alignment: .leading, spacing: 6) {
                Text("Current page")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                TicketMarkdownDocument(
                  source: currentPage?.bodyMarkdown
                    ?? proposal.basePageBodyMarkdown
                    ?? "The source page is unavailable.",
                  baseFont: .callout
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
              }
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("Proposed complete page")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
              TicketMarkdownDocument(
                source: proposal.proposedBodyMarkdown,
                baseFont: .callout
              )
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      } else if let onOpenPage {
        Button(action: onOpenPage) {
          HStack(spacing: 7) {
            Image(systemName: "books.vertical")
            Text("Open in product")
            Spacer()
            Image(systemName: "arrow.right")
          }
          .font(.callout.weight(.semibold))
          .foregroundStyle(.indigo)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      if requiresOwnerDecision {
        HStack {
          Spacer()
          Button(sourceChanged ? "Dismiss stale proposal" : "Reject") {
            onDecision(false)
          }
          .disabled(isDeciding)
          Button(isDeciding ? "Applying…" : "Accept") { onDecision(true) }
            .buttonStyle(.borderedProminent)
            .disabled(isDeciding || sourceChanged)
        }
      }
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
    }
  }
}

private struct WorkLogArtifactCard<HeaderAccessory: View, Content: View>: View {
  let title: String
  let subtitle: String?
  let systemImage: String
  let tint: Color
  let headerAccessory: HeaderAccessory
  let content: Content

  init(
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    tint: Color,
    @ViewBuilder headerAccessory: () -> HeaderAccessory,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.tint = tint
    self.headerAccessory = headerAccessory()
    self.content = content()
  }

  init(
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) where HeaderAccessory == EmptyView {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.tint = tint
    headerAccessory = EmptyView()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: systemImage)
          .font(.title3)
          .foregroundStyle(tint)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
        headerAccessory
      }

      content
    }
    .padding(15)
    .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .stroke(tint.opacity(0.34), lineWidth: 1.1)
    }
  }
}

private struct WorkLogDisclosure<Content: View>: View {
  let collapsedTitle: String
  let expandedTitle: String
  let tint: Color
  let labelFont: Font
  let content: Content
  @State private var isExpanded = false

  init(
    collapsedTitle: String,
    expandedTitle: String? = nil,
    tint: Color,
    labelFont: Font = .callout.weight(.medium),
    @ViewBuilder content: () -> Content
  ) {
    self.collapsedTitle = collapsedTitle
    self.expandedTitle = expandedTitle ?? collapsedTitle
    self.tint = tint
    self.labelFont = labelFont
    self.content = content()
  }

  private var title: String {
    isExpanded ? expandedTitle : collapsedTitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
          Text(title)
            .font(labelFont)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Collapse these details" : "Expand these details")

      if isExpanded {
        Divider()
          .overlay(tint.opacity(0.16))
          .padding(.horizontal, 10)

        content
          .padding(.horizontal, 10)
          .padding(.vertical, 9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(tint.opacity(0.035))
          .transition(.opacity)
      }
    }
    .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(tint.opacity(0.16), lineWidth: 1)
    }
  }
}

struct SprintTicketSectionCard<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SprintTicketMetadata: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TicketDetailMetadataValue: Identifiable {
  let id: String
  let title: String
  let value: String
  let symbol: String
  let tint: Color
}

struct TicketDetailRelationshipItem: Identifiable {
  let id: String
  let key: String
  let title: String
  let workItemID: UUID?

  init(id: String, key: String, title: String, workItemID: UUID? = nil) {
    self.id = id
    self.key = key
    self.title = title
    self.workItemID = workItemID
  }

  init(workItem: WorkItem) {
    id = "ticket-\(workItem.id.uuidString)"
    key = workItem.key
    title = workItem.title
    workItemID = workItem.id
  }
}

struct TicketDetailRelationshipGroup: Identifiable {
  let id: String
  let title: String
  let symbol: String
  let items: [TicketDetailRelationshipItem]
}

struct TicketDetailOverview: View {
  let title: String
  let context: String
  let emptyContextText: String
  let metadata: [TicketDetailMetadataValue]
  let epic: Epic?
  let acceptanceCriteria: [String]
  let emptyAcceptanceCriteriaText: String
  let relationships: [TicketDetailRelationshipGroup]
  let onOpenRelationship: ((UUID) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        if context.isEmpty {
          Text(emptyContextText)
            .foregroundStyle(.secondary)
        } else {
          Text(context)
            .textSelection(.enabled)
        }

        if let epic {
          TicketEpicLink(epic: epic)
        }
      }

      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
          count: 4
        ),
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(metadata) { value in
          SprintTicketMetadata(
            title: value.title,
            value: value.value,
            symbol: value.symbol,
            tint: value.tint
          )
        }
      }

      TicketDetailAcceptanceCriteriaSection(
        criteria: acceptanceCriteria,
        emptyText: emptyAcceptanceCriteriaText
      )

      if !relationships.isEmpty {
        TicketDetailRelationshipsSection(
          groups: relationships,
          onOpenRelationship: onOpenRelationship
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TicketDetailAcceptanceCriteriaSection: View {
  let criteria: [String]
  let emptyText: String

  var body: some View {
    SprintTicketSectionCard(title: "Acceptance criteria") {
      if criteria.isEmpty {
        Label(emptyText, systemImage: "exclamationmark.circle")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(criteria, id: \.self) { criterion in
            HStack(alignment: .top, spacing: 9) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
              Text(criterion)
                .textSelection(.enabled)
            }
          }
        }
      }
    }
  }
}

private struct TicketDetailRelationshipsSection: View {
  let groups: [TicketDetailRelationshipGroup]
  let onOpenRelationship: ((UUID) -> Void)?

  var body: some View {
    SprintTicketSectionCard(title: "Relationships") {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(groups) { group in
          TicketDetailRelationshipRow(
            group: group,
            onOpenRelationship: onOpenRelationship
          )
        }
      }
    }
  }
}

struct TicketDetailRelationshipRow: View {
  let group: TicketDetailRelationshipGroup
  let onOpenRelationship: ((UUID) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(group.title, systemImage: group.symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(group.items) { item in
          TicketDetailRelationshipItemRow(
            item: item,
            onOpen: item.workItemID.flatMap { workItemID in
              onOpenRelationship.map { open in
                { open(workItemID) }
              }
            }
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TicketDetailRelationshipItemRow: View {
  let item: TicketDetailRelationshipItem
  let onOpen: (() -> Void)?
  @State private var isHovering = false

  var body: some View {
    Group {
      if let onOpen {
        Button(action: onOpen) {
          rowContent(showsOpenAffordance: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
          isHovering
            ? Color.accentColor.opacity(0.075)
            : Color(nsColor: .windowBackgroundColor).opacity(0.7),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              isHovering
                ? Color.accentColor.opacity(0.4)
                : Color(nsColor: .separatorColor).opacity(0.65),
              lineWidth: 1
            )
        }
        .onHover { hovering in
          withAnimation(.easeOut(duration: 0.12)) {
            isHovering = hovering
          }
        }
        .help("Open \(item.key) · \(item.title)")
      } else {
        rowContent(showsOpenAffordance: false)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func rowContent(showsOpenAffordance: Bool) -> some View {
    HStack(alignment: .center, spacing: 9) {
      HStack(alignment: .top, spacing: 9) {
        Text("•")
          .foregroundStyle(.secondary)
          .frame(width: 16, alignment: .center)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(item.key)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(
              showsOpenAffordance && isHovering ? Color.accentColor : Color.secondary
            )
          Text("·")
            .foregroundStyle(.tertiary)
          Text(item.title)
            .foregroundStyle(
              showsOpenAffordance && isHovering ? Color.accentColor : Color.primary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if showsOpenAffordance {
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
      }
    }
  }
}

struct SprintTicketRunContextLogItem: Identifiable {
  let run: AgentRun
  let pages: [KnowledgePage]

  var id: UUID { run.id }
  var createdAt: Date { run.createdAt }
  var mandatoryPages: [KnowledgePage] {
    pages.filter(KnowledgeContextSelector.isMandatory)
  }
  var relevantPages: [KnowledgePage] {
    pages.filter { !KnowledgeContextSelector.isMandatory($0) }
  }
}

enum SprintTicketRunContextVisibility {
  static func includes(
    profile: AgentProfile?,
    isDeliveryRun: Bool
  ) -> Bool {
    isDeliveryRun || profile?.role.canReview != true
  }
}

struct SprintTicketKnowledgeLogItem: Identifiable {
  let candidate: CandidateRevision
  let proposals: [KnowledgePageProposal]

  var id: UUID { candidate.id }
  var createdAt: Date {
    proposals.map(\.createdAt).min() ?? candidate.createdAt
  }
}

struct SprintTicketDemoLogItem: Identifiable {
  let event: ActivityEvent
  let candidate: CandidateRevision

  var id: UUID { event.id }
  var createdAt: Date { event.createdAt }
}

struct SprintTicketLocalOutcomePresentation: Equatable {
  let subtitle = "Research and decision outcome"
  let explanation: String
  let outcome: String?
  let handoff: String?

  init(result: TicketExecutionResult?, status: CandidateRevisionStatus) {
    let comment = Self.nonEmpty(result?.comment)
    let summary = Self.nonEmpty(result?.summary)
    outcome = comment ?? summary
    handoff = summary == outcome ? nil : summary

    switch status {
    case .accepted:
      explanation =
        "The product owner approved this outcome. Its recommendation and supporting analysis remain below for reference; no repository revision was created or promoted."
    case .readyForDemo:
      explanation =
        "Review the recommendation, supporting analysis, and decision checks below. Then approve and complete the ticket or request changes."
    default:
      explanation = "This earlier reviewed outcome remains in the work log as delivery history."
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }
}

struct SprintTicketFollowUpLogItem: Identifiable {
  let candidate: CandidateRevision

  var id: UUID { candidate.id }
  var createdAt: Date { candidate.createdAt }
}

enum SprintWorkLogEntry: Identifiable {
  case comment(TicketComment)
  case event(ActivityEvent)
  case permission(AgentPermissionRequest)
  case runContext(SprintTicketRunContextLogItem)
  case candidate(CandidateRevision)
  case knowledge(SprintTicketKnowledgeLogItem)
  case demo(SprintTicketDemoLogItem)
  case followUp(SprintTicketFollowUpLogItem)

  var id: String {
    switch self {
    case .comment(let comment): "comment-\(comment.id.uuidString)"
    case .event(let event): "event-\(event.id.uuidString)"
    case .permission(let request): "permission-\(request.id.uuidString)"
    case .runContext(let context): "context-\(context.id.uuidString)"
    case .candidate(let candidate): "candidate-\(candidate.id.uuidString)"
    case .knowledge(let knowledge): "knowledge-\(knowledge.id.uuidString)"
    case .demo(let demo): "demo-\(demo.id.uuidString)"
    case .followUp(let followUp): "follow-up-\(followUp.id.uuidString)"
    }
  }

  var createdAt: Date {
    switch self {
    case .comment(let comment): comment.createdAt
    case .event(let event): event.createdAt
    case .permission(let request): request.createdAt
    case .runContext(let context): context.createdAt
    case .candidate(let candidate): candidate.createdAt
    case .knowledge(let knowledge): knowledge.createdAt
    case .demo(let demo): demo.createdAt
    case .followUp(let followUp): followUp.createdAt
    }
  }

  var sortOrder: Int {
    switch self {
    case .event: 0
    case .runContext: 1
    case .comment: 2
    case .permission: 3
    case .candidate: 4
    case .knowledge: 5
    case .followUp: 6
    case .demo: 7
    }
  }
}

struct SprintWorkLogRow: Identifiable {
  let entry: SprintWorkLogEntry
  let showsBottomSeparator: Bool

  var id: String { entry.id }
}

enum SprintTicketWorkLogTimeline {
  static func displayedEvents(
    events: [ActivityEvent],
    comments: [TicketComment],
    permissionRequests: [AgentPermissionRequest],
    demoSubmissions: [SprintTicketDemoLogItem]
  ) -> [ActivityEvent] {
    let demoEventIDs = Set(demoSubmissions.map(\.event.id))
    return events.filter { event in
      guard !demoEventIDs.contains(event.id) else { return false }

      switch event.kind {
      case "comment.created", "work_item.ranked",
        "agent_run.queued", "agent_run.running", "agent_run.completed":
        return false
      case "agent_run.awaiting_owner":
        return !isRepresentedByPermissionRequest(
          event,
          permissionRequests: permissionRequests
        )
      case "work_item.transitioned":
        guard !isRepresentedByDemoFeedbackComment(event, comments: comments) else {
          return false
        }
        guard let transition = transition(in: event.detail) else { return true }
        return workLogPhase(for: transition.from) != workLogPhase(for: transition.to)
      default:
        return true
      }
    }
  }

  static func rows(_ entries: [SprintWorkLogEntry]) -> [SprintWorkLogRow] {
    entries.enumerated().map { index, entry in
      SprintWorkLogRow(
        entry: entry,
        showsBottomSeparator: index < entries.count - 1
      )
    }
  }

  static func ordered(_ entries: [SprintWorkLogEntry]) -> [SprintWorkLogEntry] {
    entries.sorted {
      if $0.createdAt == $1.createdAt {
        if $0.sortOrder == $1.sortOrder {
          return $0.id < $1.id
        }
        return $0.sortOrder < $1.sortOrder
      }
      return $0.createdAt < $1.createdAt
    }
  }

  static func demoSubmissions(
    events: [ActivityEvent],
    candidates: [CandidateRevision]
  ) -> [SprintTicketDemoLogItem] {
    let orderedCandidates = candidates.sorted {
      if $0.createdAt == $1.createdAt {
        return $0.version < $1.version
      }
      return $0.createdAt < $1.createdAt
    }
    return
      events
      .filter(isDemoSubmission)
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.sequence < $1.sequence
        }
        return $0.createdAt < $1.createdAt
      }
      .compactMap { event in
        guard
          let candidate = orderedCandidates.last(where: {
            $0.createdAt <= event.createdAt
          })
        else { return nil }
        return SprintTicketDemoLogItem(event: event, candidate: candidate)
      }
  }

  private static func isRepresentedByPermissionRequest(
    _ event: ActivityEvent,
    permissionRequests: [AgentPermissionRequest]
  ) -> Bool {
    guard event.detail == "Waiting for a scoped permission decision" else {
      return false
    }
    return permissionRequests.contains {
      $0.workItemID == event.workItemID
    }
  }

  private static func isRepresentedByDemoFeedbackComment(
    _ event: ActivityEvent,
    comments: [TicketComment]
  ) -> Bool {
    guard
      let reason = transitionReason(in: event.detail),
      reason.hasPrefix("Demo feedback:")
    else {
      return false
    }
    let feedback =
      reason
      .dropFirst("Demo feedback:".count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !feedback.isEmpty else { return false }
    return comments.contains {
      $0.workItemID == event.workItemID
        && $0.authorKind == .owner
        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(feedback)
    }
  }

  private static func transition(
    in detail: String
  ) -> (from: WorkItemState, to: WorkItemState)? {
    let movement =
      detail
      .split(separator: ":", maxSplits: 1)
      .first
      .map(String.init) ?? ""
    let states = movement.components(separatedBy: " -> ")
    guard states.count == 2,
      let from = WorkItemState(
        rawValue: states[0].trimmingCharacters(in: .whitespacesAndNewlines)
      ),
      let to = WorkItemState(
        rawValue: states[1].trimmingCharacters(in: .whitespacesAndNewlines)
      )
    else {
      return nil
    }
    return (from, to)
  }

  private static func transitionReason(in detail: String) -> String? {
    let parts = detail.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func workLogPhase(for state: WorkItemState) -> Int {
    switch state {
    case .backlog, .refining, .ready: 0
    case .queued: 1
    case .running: 2
    case .integrating, .verifying, .readyToRelease: 3
    case .acceptance: 4
    case .released: 5
    case .cancelled: 6
    }
  }

  private static func isDemoSubmission(_ event: ActivityEvent) -> Bool {
    guard event.kind == "work_item.transitioned" else { return false }
    let movement =
      event.detail
      .split(separator: ":", maxSplits: 1)
      .first
      .map(String.init) ?? ""
    let destination =
      movement
      .components(separatedBy: " -> ")
      .last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return destination == WorkItemState.acceptance.rawValue
  }
}

private struct SprintTicketEventRow: View {
  let event: ActivityEvent
  let profiles: [AgentProfile]
  let retrospectiveNotes: [RetrospectiveNote]
  let showsBottomSeparator: Bool

  private var assignedProfile: AgentProfile? {
    guard
      event.kind == "work_item.owner_assigned",
      let profileID = UUID(uuidString: event.detail)
    else { return nil }
    return profiles.first { $0.id == profileID }
  }

  private var actorProfile: AgentProfile? {
    if event.kind == "agent_run.running",
      let returnedOwner = profiles.first(where: {
        event.detail.localizedCaseInsensitiveContains("returning work to \($0.name)")
      })
    {
      return returnedOwner
    }
    return profiles.first { $0.name == event.actor }
  }

  private var actorName: String {
    if let actorProfile {
      return actorProfile.name
    }
    return switch event.actor.lowercased() {
    case "owner", "product owner": "Me"
    case "system": "Spedito"
    case "sprint scheduler": "Sprint scheduler"
    default: event.actor
    }
  }

  private var isOwnerActor: Bool {
    ["me", "owner", "product owner"].contains(event.actor.lowercased())
  }

  private var transitionDestination: String? {
    guard event.kind == "work_item.transitioned" else { return nil }
    let movement = event.detail.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    let rawState = movement.components(separatedBy: " -> ").last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rawState, !rawState.isEmpty else { return nil }
    return rawState
  }

  private var destinationTitle: String? {
    guard let transitionDestination else { return nil }
    guard let state = WorkItemState(rawValue: transitionDestination) else {
      return transitionDestination.replacingOccurrences(of: "_", with: " ").capitalized
    }
    return switch state {
    case .queued: "Ready to pick"
    case .running: "In progress"
    case .integrating, .verifying, .readyToRelease: "In review"
    case .acceptance: "Ready for demo"
    case .released: "Done"
    case .backlog: "Backlog"
    case .refining: "Refining"
    case .ready: "Ready"
    case .cancelled: "Cancelled"
    }
  }

  private var transitionState: WorkItemState? {
    transitionDestination.flatMap { WorkItemState(rawValue: $0) }
  }

  private var title: String {
    switch event.kind {
    case "work_item.created":
      "Ticket created"
    case "work_item.created_from_suggestion":
      "Suggested ticket accepted"
    case "work_item.updated":
      "Ticket details updated"
    case "work_item.owner_assigned":
      assignedProfile.map { "Assigned to \($0.name)" } ?? "Ticket unassigned"
    case "work_item.ranked":
      "Backlog position changed"
    case "work_item.archived":
      "Ticket archived"
    case "work_item.queued":
      "Moved to ready to pick"
    case "agent_run.queued":
      "Queued to resume"
    case "agent_run.running":
      "Resumed work"
    case "agent_run.awaiting_owner":
      "Waiting for your response"
    case "agent_run.interrupted":
      "Run interrupted"
    case "agent_run.failed":
      "Run failed"
    case "agent_run.completed":
      "Run completed"
    case "retrospective.action_proposed":
      "Retrospective change proposed"
    case "retrospective.action_promoted_to_practice":
      "Added to Ways of working"
    case "work_item.created_from_retrospective":
      "Retrospective ticket created"
    case "work_item.transitioned":
      switch transitionState {
      case .some(.running):
        event.detail.localizedCaseInsensitiveContains("review changes requested")
          ? "Changes requested"
          : "Started work"
      case .some(.acceptance): "Submitted for demo"
      case .some(.released): "Completed ticket"
      case .some(.cancelled): "Cancelled ticket"
      default: destinationTitle.map { "Moved to \($0)" } ?? "Status changed"
      }
    default:
      event.kind
        .split(separator: ".")
        .last
        .map(String.init)?
        .replacingOccurrences(of: "_", with: " ")
        .capitalized ?? "Ticket updated"
    }
  }

  private var detail: String? {
    switch event.kind {
    case "work_item.created", "work_item.created_from_suggestion",
      "work_item.owner_assigned":
      return nil
    case "work_item.updated":
      let trimmed = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.hasPrefix("Changed ") || trimmed == "Saved without field changes"
        ? trimmed
        : nil
    case "work_item.transitioned":
      let parts = event.detail.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let reason = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      return reason.isEmpty ? nil : reason
    case "retrospective.action_proposed", "retrospective.action_promoted_to_practice",
      "work_item.created_from_retrospective":
      let trimmed = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if let noteID = UUID(uuidString: trimmed) {
        return retrospectiveNotes.first { $0.id == noteID }?.body
      }
      return trimmed
    default:
      let trimmed = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  private var actorTint: Color {
    if let actorProfile {
      return actorProfile.role.tint
    }
    return isOwnerActor ? .blue : .secondary
  }

  private var actorSymbolName: String {
    if let actorProfile {
      return actorProfile.role.symbolName
    }
    if isOwnerActor {
      return "person.fill"
    }
    switch event.actor.lowercased() {
    case "system", "sprint scheduler":
      return "gearshape.fill"
    default:
      return "person.crop.circle.fill"
    }
  }

  private var eventTint: Color {
    if let assignedProfile {
      return assignedProfile.role.tint
    }
    return switch event.kind {
    case "work_item.created", "work_item.created_from_suggestion": .blue
    case "work_item.owner_assigned": .indigo
    case "work_item.archived": .red
    case "work_item.queued": Color(nsColor: .secondaryLabelColor)
    case "agent_run.awaiting_owner": .orange
    case "agent_run.failed": .red
    case "agent_run.interrupted": .orange
    case "agent_run.completed": .green
    case "retrospective.action_proposed": .blue
    case "retrospective.action_promoted_to_practice": .purple
    case "work_item.created_from_retrospective": .blue
    case "agent_run.queued": Color(nsColor: .secondaryLabelColor)
    case "agent_run.running": .blue
    case "work_item.transitioned":
      switch transitionState {
      case .some(.running): .blue
      case .some(.acceptance): .purple
      case .some(.released): .green
      case .some(.cancelled): .red
      default: .indigo
      }
    default: .secondary
    }
  }

  private var eventSymbolName: String {
    switch event.kind {
    case "work_item.created", "work_item.created_from_suggestion": "plus"
    case "work_item.updated": "pencil"
    case "work_item.owner_assigned": assignedProfile?.role.symbolName ?? "person.crop.circle"
    case "work_item.ranked": "arrow.up.arrow.down"
    case "work_item.archived": "archivebox"
    case "work_item.queued": "tray.full"
    case "agent_run.queued": "clock"
    case "agent_run.running": "bolt.fill"
    case "agent_run.awaiting_owner": "hand.raised.fill"
    case "agent_run.interrupted": "pause.circle.fill"
    case "agent_run.failed": "exclamationmark.triangle.fill"
    case "agent_run.completed": "checkmark.circle.fill"
    case "retrospective.action_proposed": "plus.bubble"
    case "retrospective.action_promoted_to_practice": "person.2.badge.gearshape"
    case "work_item.created_from_retrospective": "list.bullet.clipboard"
    case "work_item.transitioned":
      switch transitionState {
      case .some(.running): "bolt.fill"
      case .some(.acceptance): "play.rectangle"
      case .some(.released): "checkmark"
      case .some(.cancelled): "xmark"
      default: "arrow.right"
      }
    default: "clock.arrow.circlepath"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(actorTint.opacity(0.12))
        Image(systemName: actorSymbolName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(actorTint)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(actorName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(actorProfile == nil ? Color.primary : actorTint)
          Text(
            event.createdAt,
            format: .dateTime.day().month(.abbreviated).hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Label(title, systemImage: eventSymbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(eventTint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(eventTint.opacity(0.1), in: Capsule())
        }
        if let detail {
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, 14)
    .padding(.bottom, showsBottomSeparator ? 14 : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsBottomSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.55))
          .frame(height: 1)
          .padding(.leading, 46)
      }
    }
  }
}

private enum TicketOwnerAnswerSelection: Equatable {
  case option(String)
  case custom
}

private struct SprintTicketCommentRow: View {
  let comment: TicketComment
  let externalURL: URL?
  let authorProfile: AgentProfile?
  let mentionedProfile: AgentProfile?
  let showsBottomSeparator: Bool
  let ownerAnswerSelection: TicketOwnerAnswerSelection?
  let customOwnerAnswer: Binding<String>?
  let onSelectOwnerAnswer: ((TicketOwnerAnswerSelection) -> Void)?
  let routedRecipientName: String?
  let isRouting: Bool
  let onRoute: (() -> Void)?
  var onOpenDecisionArtifact: ((TicketDecisionArtifact) -> Void)? = nil
  @FocusState private var isCustomOwnerAnswerFocused: Bool

  private var accent: Color {
    switch comment.authorKind {
    case .owner: ConversationPalette.owner
    case .agent: authorProfile?.role.tint ?? .indigo
    case .external: .blue
    case .system: .secondary
    }
  }

  private var symbolName: String {
    switch comment.authorKind {
    case .owner: "person.fill"
    case .agent: authorProfile?.role.symbolName ?? "sparkles"
    case .external: "person.crop.circle.badge.checkmark"
    case .system: "gearshape.fill"
    }
  }

  private var authorName: String {
    comment.authorKind == .owner ? "Me" : comment.authorName
  }

  private var ownerQuestionPresentation: TicketOwnerQuestionPresentation? {
    guard comment.authorKind == .agent else { return nil }
    return TicketOwnerQuestion.presentation(
      in: comment.body,
      structuredQuestion: comment.ownerQuestion
    )
  }

  private var presentedOwnerAnswerSelection: TicketOwnerAnswerSelection? {
    if let ownerAnswerSelection {
      return ownerAnswerSelection
    }
    guard let answered = comment.answeredQuestions.first else { return nil }
    return answered.selectedOption.map(TicketOwnerAnswerSelection.option)
      ?? .custom
  }

  private var submittedCustomOwnerAnswer: String? {
    guard
      presentedOwnerAnswerSelection == .custom,
      customOwnerAnswer == nil
    else { return nil }
    return comment.answeredQuestions.first?.answer
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Group {
        if let avatarURL = comment.authorAvatarURL {
          AsyncImage(url: avatarURL) { phase in
            if let image = phase.image {
              image
                .resizable()
                .scaledToFill()
            } else {
              externalAvatarPlaceholder
            }
          }
        } else {
          externalAvatarPlaceholder
        }
      }
      .frame(width: 34, height: 34)
      .clipShape(Circle())

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(authorName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(comment.authorKind == .agent ? accent : Color.primary)
          Text(
            comment.createdAt,
            format: .dateTime.day().month(.abbreviated).hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if let externalURL {
            Link("View on GitHub", destination: externalURL)
              .font(.caption)
          }
        }
        if let ownerQuestionPresentation {
          if !ownerQuestionPresentation.context.isEmpty {
            TicketMarkdownDocument(
              source: ownerQuestionPresentation.context,
              baseFont: .body,
              highlightedText: mentionedProfile.map { "@\($0.name)" },
              highlightedColor: mentionedProfile?.role.tint
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          ownerQuestionView(ownerQuestionPresentation.question)
            .padding(.top, ownerQuestionPresentation.context.isEmpty ? 0 : 10)
        } else {
          TicketMarkdownDocument(
            source: comment.body,
            baseFont: .body,
            highlightedText: mentionedProfile.map { "@\($0.name)" },
            highlightedColor: mentionedProfile?.role.tint
          )
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let context = comment.githubReviewContext {
          WorkLogArtifactCard(
            title: context.path,
            subtitle:
              "\(context.lineDescription) · Reviewed commit \(context.commitSHA.prefix(12))",
            systemImage: "chevron.left.forwardslash.chevron.right",
            tint: .indigo
          ) {
            if !context.diffHunk.isEmpty {
              WorkLogDisclosure(
                collapsedTitle: "Reviewed code",
                expandedTitle: "Hide reviewed code",
                tint: .indigo,
                labelFont: .caption.weight(.semibold)
              ) {
                ScrollView(.vertical) {
                  LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                      Array(context.diffHunk.components(separatedBy: "\n").enumerated()),
                      id: \.offset
                    ) { _, line in
                      UnifiedDiffLineRow(line: line)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
                }
                .defaultScrollAnchor(.top)
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: 180, alignment: .topLeading)
                .clipped()
                .background(
                  Color(nsColor: .textBackgroundColor).opacity(0.5),
                  in: RoundedRectangle(cornerRadius: 7)
                )
              }
            }
          }
        }
        if let routedRecipientName, let onRoute {
          Button(isRouting ? "Asking…" : "Ask \(routedRecipientName) about this") {
            onRoute()
          }
          .buttonStyle(.bordered)
          .tint(.purple)
          .controlSize(.small)
          .disabled(isRouting)
        }
      }
    }
    .padding(.top, 14)
    .padding(.bottom, showsBottomSeparator ? 14 : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsBottomSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.55))
          .frame(height: 1)
          .padding(.leading, 46)
      }
    }
  }

  private var externalAvatarPlaceholder: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(0.12))
      Image(systemName: symbolName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent)
    }
  }

  private func ownerQuestionView(_ question: TicketOwnerQuestion) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Question for you", systemImage: "questionmark.bubble.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent)
      Text(question.prompt)
        .font(.body.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityIdentifier("sprint.ticket.owner-question.prompt")

      if let artifact = question.decisionArtifact {
        Button {
          onOpenDecisionArtifact?(artifact)
        } label: {
          Label("Open \(artifact.title)", systemImage: "doc.text")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(onOpenDecisionArtifact == nil)
      }

      VStack(spacing: 6) {
        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
          ownerAnswerRow(
            option,
            selection: .option(option)
          )
          .accessibilityIdentifier("sprint.ticket.owner-question.option.\(index)")
        }
        ownerAnswerRow(
          "Other",
          selection: .custom
        )
        .accessibilityIdentifier("sprint.ticket.owner-question.other")
      }

      if presentedOwnerAnswerSelection == .custom, let customOwnerAnswer {
        TextField("Type another answer", text: customOwnerAnswer)
          .textFieldStyle(.roundedBorder)
          .focused($isCustomOwnerAnswerFocused)
          .accessibilityIdentifier("sprint.ticket.owner-question.custom")
          .task {
            await Task.yield()
            isCustomOwnerAnswerFocused = true
          }
      } else if let submittedCustomOwnerAnswer {
        Text(submittedCustomOwnerAnswer)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(
            accent.opacity(0.08),

            in: RoundedRectangle(cornerRadius: 8)
          )
      }

      if onSelectOwnerAnswer != nil {
        Text("Choose an answer to continue.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(accent.opacity(0.28), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func ownerAnswerRow(
    _ label: String,
    selection: TicketOwnerAnswerSelection
  ) -> some View {
    if let onSelectOwnerAnswer {
      Button {
        onSelectOwnerAnswer(selection)
      } label: {
        ownerAnswerLabel(label, selection: selection)
      }
      .buttonStyle(
        RefinementChoiceButtonStyle(
          tint: accent,
          isSelected: presentedOwnerAnswerSelection == selection
        )
      )
    } else {
      readOnlyOwnerAnswerLabel(label, selection: selection)
    }
  }

  private func readOnlyOwnerAnswerLabel(
    _ label: String,
    selection: TicketOwnerAnswerSelection
  ) -> some View {
    let isSelected = presentedOwnerAnswerSelection == selection
    return HStack(alignment: .firstTextBaseline, spacing: 9) {
      Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        .font(.caption)
        .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.65))
      Text(label)
        .font(.callout)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 8)
    )
  }

  private func ownerAnswerLabel(
    _ label: String,
    selection: TicketOwnerAnswerSelection
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 9) {
      Image(
        systemName:
          presentedOwnerAnswerSelection == selection
          ? "largecircle.fill.circle"
          : "circle"
      )
      .font(.caption)
      .foregroundStyle(
        presentedOwnerAnswerSelection == selection ? accent : Color.secondary
      )
      Text(label)
        .font(.callout)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

private struct TicketMarkdownDocument: View {
  let source: String
  let baseFont: Font
  var highlightedText: String?
  var highlightedColor: Color?

  private var blocks: [KnowledgeMarkdown.Block] {
    KnowledgeMarkdown.blocks(in: source, removesLeadingTitle: false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func blockView(_ block: KnowledgeMarkdown.Block) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .font(headingFont(level))
        .fixedSize(horizontal: false, vertical: true)
    case .paragraph(let lines):
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(inlineMarkdown(line))
            .font(baseFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("•")
              .foregroundStyle(.secondary)
            Text(inlineMarkdown(item))
              .font(baseFont)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .layoutPriority(1)
          }
        }
      }
      .padding(.leading, 3)
    case .orderedList(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(index + 1).")
              .font(baseFont)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .frame(minWidth: 18, alignment: .trailing)
            Text(inlineMarkdown(item))
              .font(baseFont)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .layoutPriority(1)
          }
        }
      }
    case .quote(let lines):
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.accentColor.opacity(0.5))
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(inlineMarkdown(line))
              .font(baseFont)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .foregroundStyle(.secondary)
      }
    case .code(let code):
      ScrollView(.horizontal) {
        Text(code)
          .font(.caption.monospaced())
          .padding(9)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    case .table(let table):
      MarkdownTableView(
        table: table,
        font: baseFont,
        inlineMarkdown: inlineMarkdown
      )
    case .divider:
      Divider()
    }
  }

  private func inlineMarkdown(_ source: String) -> AttributedString {
    var attributed = SafeURLPolicy.markdown(source)
    if let highlightedText,
      let highlightedColor,
      let range = attributed.range(of: highlightedText)
    {
      attributed[range].foregroundColor = highlightedColor
      attributed[range].font = baseFont.bold()
    }
    return attributed
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title3.bold()
    case 2: .headline
    default: .subheadline.bold()
    }
  }
}

struct SelectableTicketMarkdownDocument: View {
  let source: String
  let baseFont: Font
  var highlightedText: String?
  var highlightedColor: Color?

  private var document: AttributedString {
    var document = AttributedString()
    let blocks = KnowledgeMarkdown.blocks(in: source, removesLeadingTitle: false)

    for (index, block) in blocks.enumerated() {
      if index > 0 {
        var separator = AttributedString("\n\n")
        separator.font = .system(size: 4)
        document.append(separator)
      }
      document.append(blockDocument(block))
    }

    if let highlightedText,
      let highlightedColor,
      let range = document.range(of: highlightedText)
    {
      document[range].foregroundColor = highlightedColor
      document[range].font = baseFont.bold()
    }
    return document
  }

  var body: some View {
    Text(document)
      .font(baseFont)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func blockDocument(_ block: KnowledgeMarkdown.Block) -> AttributedString {
    switch block {
    case .heading(let level, let text):
      var heading = inlineMarkdown(text)
      heading.font = headingFont(level)
      return heading
    case .paragraph(let lines):
      return linesDocument(lines)
    case .unorderedList(let items):
      return linesDocument(items) { _ in "• " }
    case .orderedList(let items):
      return linesDocument(items) { index in "\(index + 1). " }
    case .quote(let lines):
      var quote = linesDocument(lines)
      quote.foregroundColor = .secondary
      return quote
    case .code(let code):
      var codeBlock = AttributedString(code)
      codeBlock.font = .caption.monospaced()
      return codeBlock
    case .table(let table):
      return tableDocument(table)
    case .divider:
      var divider = AttributedString("────────")
      divider.foregroundColor = .secondary
      return divider
    }
  }

  private func linesDocument(
    _ lines: [String],
    prefix: ((Int) -> String)? = nil
  ) -> AttributedString {
    var result = AttributedString()
    for (index, line) in lines.enumerated() {
      if index > 0 {
        result.append(AttributedString("\n"))
      }
      if let prefix {
        result.append(AttributedString(prefix(index)))
      }
      result.append(inlineMarkdown(line))
    }
    return result
  }

  private func tableDocument(_ table: KnowledgeMarkdown.Table) -> AttributedString {
    var result = tableRowDocument(table.header)
    result.font = baseFont.bold()
    for row in table.rows {
      result.append(AttributedString("\n"))
      result.append(tableRowDocument(row))
    }
    return result
  }

  private func tableRowDocument(_ cells: [String]) -> AttributedString {
    var result = AttributedString()
    for (index, cell) in cells.enumerated() {
      if index > 0 {
        result.append(AttributedString("  |  "))
      }
      result.append(inlineMarkdown(cell))
    }
    return result
  }

  private func inlineMarkdown(_ source: String) -> AttributedString {
    SafeURLPolicy.markdown(source)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title3.bold()
    case 2: .headline
    default: .subheadline.bold()
    }
  }
}

private struct IntrinsicWrappingLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let result = layout(
      sizes: subviews.map { $0.sizeThatFits(.unspecified) },
      availableWidth: proposal.width ?? .infinity
    )
    return CGSize(
      width: proposal.width ?? result.contentSize.width,
      height: result.contentSize.height
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let result = layout(sizes: sizes, availableWidth: bounds.width)

    for (index, subview) in subviews.enumerated() {
      let size = sizes[index]
      let origin = result.origins[index]
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
    }
  }

  private func layout(
    sizes: [CGSize],
    availableWidth: CGFloat
  ) -> (contentSize: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    for size in sizes {
      if currentX > 0, currentX + size.width > availableWidth {
        currentX = 0
        currentY += rowHeight + spacing
        rowHeight = 0
      }

      origins.append(CGPoint(x: currentX, y: currentY))
      contentWidth = max(contentWidth, currentX + size.width)
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    return (
      CGSize(
        width: contentWidth,
        height: sizes.isEmpty ? 0 : currentY + rowHeight
      ),
      origins
    )
  }
}
