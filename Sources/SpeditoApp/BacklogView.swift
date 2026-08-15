import AppKit
import SpeditoCore
import SwiftUI

enum PlanningDropSection: Equatable {
  case candidateSprint
  case backlog
}

struct PlanningDropTarget: Equatable {
  let section: PlanningDropSection
  let index: Int
}

enum PlanningDropTargetState {
  static func updated(
    current: PlanningDropTarget?,
    target: PlanningDropTarget,
    isTargeted: Bool
  ) -> PlanningDropTarget? {
    if isTargeted {
      return target
    }
    return current == target ? nil : current
  }
}

enum PlanningBulkMoveDestination {
  case candidateSprint
  case backlog
}

struct PlanningBulkMoveAction {
  let items: [WorkItem]
  let selectedWorkItemIDs: Set<UUID>
  let destination: PlanningBulkMoveDestination

  private var selectedItems: [WorkItem] {
    items.filter { selectedWorkItemIDs.contains($0.id) }
  }

  var targetItems: [WorkItem] {
    return selectedItems.isEmpty ? items : selectedItems
  }

  var title: String {
    let quantity =
      selectedItems.isEmpty
      ? "all"
      : selectedItems.count.formatted()
    switch destination {
    case .candidateSprint:
      return "Move \(quantity) to next sprint"
    case .backlog:
      return "Move \(quantity) to backlog"
    }
  }

  var compactTitle: String {
    let quantity =
      selectedItems.isEmpty
      ? "All"
      : selectedItems.count.formatted()
    switch destination {
    case .candidateSprint:
      return "\(quantity) to sprint"
    case .backlog:
      return "\(quantity) to backlog"
    }
  }

  var helpText: String {
    let noun = targetItems.count == 1 ? "ticket" : "tickets"
    let subject =
      selectedItems.isEmpty
      ? "all \(items.count.formatted())"
      : "\(targetItems.count.formatted()) selected"
    switch destination {
    case .candidateSprint:
      return "Move \(subject) backlog \(noun) to the next sprint"
    case .backlog:
      return "Return \(subject) sprint \(noun) to the backlog"
    }
  }
}

struct EpicPlanningSections {
  let allEpics: [Epic]
  let openEpics: [Epic]
  let closedEpics: [Epic]
  let deliveredTicketCount: Int

  init(epics: [Epic], workItems: [WorkItem]) {
    let visibleEpics = epics.filter { $0.status != .archived }
    let visibleOpenEpics = visibleEpics.filter { $0.status == .open }
    let visibleClosedEpics = visibleEpics.filter { $0.status == .closed }
    let closedEpicIDs = Set(visibleClosedEpics.map(\.id))
    allEpics = visibleEpics
    openEpics = visibleOpenEpics
    closedEpics = visibleClosedEpics
    deliveredTicketCount =
      workItems.filter {
        guard let epicID = $0.epicID else { return false }
        return closedEpicIDs.contains(epicID) && $0.state == .released
      }.count
  }

  var isEmpty: Bool {
    allEpics.isEmpty
  }
}

enum TicketEpicNavigation {
  static func destination(for item: WorkItem, in epics: [Epic]) -> Epic? {
    guard let epicID = item.epicID else { return nil }
    return epics.first {
      $0.id == epicID && $0.productID == item.productID
    }
  }
}

enum TicketRelationshipNavigation {
  static func destination(
    for relationshipID: UUID,
    source: WorkItem,
    in workItems: [WorkItem]
  ) -> WorkItem? {
    workItems.first {
      $0.id == relationshipID && $0.productID == source.productID
    }
  }
}

struct BacklogPlanningSizing {
  static let tableRowHeight: CGFloat = 40
  static let tableRowDividerHeight: CGFloat = 1
  static let emptyEpicHeight: CGFloat = 166
  static let epicChromeHeight: CGFloat = 66
  static let defaultBacklogRatio: CGFloat = 0.59
  static let minimumBacklogWidth: CGFloat = 480
  static let minimumSprintWidth: CGFloat = 350
  static let epicRowHeight = tableRowHeight + tableRowDividerHeight

  static func backlogWidth(
    availableWidth: CGFloat,
    dividerWidth: CGFloat,
    preferredRatio: CGFloat
  ) -> CGFloat {
    let paneWidth = max(0, availableWidth - dividerWidth)
    guard paneWidth > 0 else { return 0 }

    let proposedWidth = paneWidth * min(max(preferredRatio, 0), 1)
    let minimumScale = min(
      1,
      paneWidth / (minimumBacklogWidth + minimumSprintWidth)
    )
    let scaledBacklogMinimum = minimumBacklogWidth * minimumScale
    let scaledSprintMinimum = minimumSprintWidth * minimumScale
    let defaultBacklogWidth = paneWidth * defaultBacklogRatio
    let maximumBacklogWidth = max(
      scaledBacklogMinimum,
      min(paneWidth - scaledSprintMinimum, defaultBacklogWidth)
    )

    return min(max(proposedWidth, scaledBacklogMinimum), maximumBacklogWidth)
  }

  static func backlogRatio(
    for width: CGFloat,
    availableWidth: CGFloat,
    dividerWidth: CGFloat
  ) -> CGFloat {
    let paneWidth = max(0, availableWidth - dividerWidth)
    guard paneWidth > 0 else { return defaultBacklogRatio }
    return min(max(width / paneWidth, 0), 1)
  }

  static func splitPosition(
    containerWidth: CGFloat,
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat,
    preferredRatio: CGFloat
  ) -> CGFloat {
    let availableWidth = max(0, containerWidth - (horizontalPadding * 2))
    return horizontalPadding
      + backlogWidth(
        availableWidth: availableWidth,
        dividerWidth: dividerWidth,
        preferredRatio: preferredRatio
      )
  }

  static func backlogRatio(
    forSplitPosition position: CGFloat,
    containerWidth: CGFloat,
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat
  ) -> CGFloat {
    backlogRatio(
      for: max(0, position - horizontalPadding),
      availableWidth: max(0, containerWidth - (horizontalPadding * 2)),
      dividerWidth: dividerWidth
    )
  }

  static func epicHeight(
    openEpicCount: Int,
    closedEpicCount: Int,
    closedEpicsExpanded: Bool
  ) -> CGFloat {
    let visibleRowCount =
      openEpicCount
      + (closedEpicCount > 0 ? 1 : 0)
      + (closedEpicsExpanded ? closedEpicCount : 0)

    guard visibleRowCount > 0 else { return emptyEpicHeight }
    return CGFloat(visibleRowCount) * epicRowHeight + epicChromeHeight
  }

  static func backlogHeight(
    availableHeight: CGFloat,
    epicHeight: CGFloat,
    sectionDividerHeight: CGFloat
  ) -> CGFloat {
    max(0, availableHeight - epicHeight - sectionDividerHeight)
  }
}

enum BacklogPlanningSplitPreference {
  private static let key = "backlogPlanningSplitRatio"

  static func load(defaults: UserDefaults = .standard) -> CGFloat {
    guard let number = defaults.object(forKey: key) as? NSNumber else {
      return BacklogPlanningSizing.defaultBacklogRatio
    }
    let ratio = CGFloat(number.doubleValue)
    guard ratio.isFinite, ratio > 0, ratio < 1 else {
      return BacklogPlanningSizing.defaultBacklogRatio
    }
    return min(ratio, BacklogPlanningSizing.defaultBacklogRatio)
  }

  static func save(
    _ ratio: CGFloat,
    defaults: UserDefaults = .standard
  ) {
    guard ratio.isFinite, ratio > 0, ratio < 1 else { return }
    defaults.set(
      Double(min(ratio, BacklogPlanningSizing.defaultBacklogRatio)),
      forKey: key
    )
  }
}

enum EpicPlanningDisclosureDefaults {
  private static let prefix = "completedEpicsExpanded"

  static func isExpanded(
    for productID: UUID,
    defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.bool(forKey: key(for: productID))
  }

  static func setExpanded(
    _ isExpanded: Bool,
    for productID: UUID,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(isExpanded, forKey: key(for: productID))
  }

  private static func key(for productID: UUID) -> String {
    "\(prefix).\(productID.uuidString)"
  }
}

struct BacklogView: View {
  @EnvironmentObject private var model: AppModel
  let onNewTicket: (UUID?) -> Void
  let onNewEpic: () -> Void
  let onPlanSprint: () -> Void
  let onOpenSprint: () -> Void
  @State private var selectedTicket: WorkItem?
  @State private var selectedEpic: Epic?
  @State private var selectedWorkItemIDs: Set<UUID> = []
  @State private var draggedWorkItemIDs: Set<UUID> = []
  @State private var planningDropTarget: PlanningDropTarget?
  @State private var dragResetTask: Task<Void, Never>?
  @State private var dropExitResetTask: Task<Void, Never>?
  @State private var closedEpicsExpanded = false
  @State private var closedExpansionProductID: UUID?

  private var allPlanningItems: [WorkItem] {
    model.workItems.filter { [.backlog, .refining, .ready].contains($0.state) }
  }

  private var candidateIDs: Set<UUID> {
    Set(model.candidateSprintPlan?.items.map(\.workItemID) ?? [])
  }

  private var candidateItems: [WorkItem] {
    allPlanningItems.filter { candidateIDs.contains($0.id) }
  }

  private var allCandidateItems: [WorkItem] {
    allPlanningItems.filter { candidateIDs.contains($0.id) }
  }

  private var backlogItems: [WorkItem] {
    allPlanningItems.filter { !candidateIDs.contains($0.id) }
  }

  private var epicSections: EpicPlanningSections {
    EpicPlanningSections(
      epics: model.planningEpics,
      workItems: model.workItems
    )
  }

  private var candidateSprintNumber: Int {
    if let plan = model.candidateSprintPlan {
      return plan.sprint.number
    }
    return (model.sprintHistory.map(\.sprint.number).max() ?? 0) + 1
  }

  private var visibleSuggestionBatch: TicketSuggestionBatch? {
    guard let batch = model.suggestionBatch else { return nil }
    guard
      batch.session.epicID != nil
        || batch.session.sourceWorkItemID != nil
    else { return nil }
    if batch.session.status == .cancelled {
      return nil
    }
    if batch.session.status == .ready,
      batch.suggestions.allSatisfy({ $0.status != .proposed })
    {
      return nil
    }
    return batch
  }

  private var planningIsComplete: Bool {
    guard
      let plan = model.candidateSprintPlan,
      !plan.items.isEmpty
    else { return false }
    return plan.items.allSatisfy { $0.estimatedTokens > 0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Backlog")
            .font(.largeTitle.bold())
          Text("Rank the work, shape the next sprint, and open any ticket to refine it.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let plan = model.sprintPlan, plan.sprint.state.isInProgress {
          Button(action: onOpenSprint) {
            Label(
              plan.sprint.state == .paused
                ? "Sprint \(plan.sprint.number) paused"
                : "Sprint \(plan.sprint.number) active",
              systemImage: plan.sprint.state == .paused ? "pause.fill" : "bolt.fill"
            )
          }
          .buttonStyle(.bordered)
          .help("Open the current sprint board")
        }
      }
      .workspaceHeaderLayout()

      Divider()

      GeometryReader { proxy in
        let horizontalPadding: CGFloat = 24
        let columnGutter: CGFloat = 18
        let dividerThickness: CGFloat = 1
        let sectionDividerHeight = (columnGutter * 2) + dividerThickness
        let topPadding: CGFloat = 18
        let bottomPadding: CGFloat = 28
        let availableHeight = max(0, proxy.size.height - topPadding - bottomPadding)
        let epicHeight = BacklogPlanningSizing.epicHeight(
          openEpicCount: epicSections.openEpics.count,
          closedEpicCount: epicSections.closedEpics.count,
          closedEpicsExpanded: closedEpicsExpanded
        )
        let backlogHeight = BacklogPlanningSizing.backlogHeight(
          availableHeight: availableHeight,
          epicHeight: epicHeight,
          sectionDividerHeight: sectionDividerHeight
        )

        BacklogPlanningSplitView(
          containerWidth: proxy.size.width,
          horizontalPadding: horizontalPadding,
          dividerWidth: dividerThickness
        ) {
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
              EpicPlanningList(
                sections: epicSections,
                workItems: model.workItems,
                minimumHeight: epicHeight,
                isClosedExpanded: $closedEpicsExpanded,
                onAddEpic: onNewEpic,
                onOpen: { selectedEpic = $0 }
              )
              .padding(.leading, horizontalPadding)
              .padding(.trailing, columnGutter)

              Divider()
                .frame(height: dividerThickness)
                .padding(.vertical, columnGutter)

              PlanningTicketList(
                title: "Backlog",
                items: backlogItems,
                isCandidateSection: false,
                minimumHeight: backlogHeight,
                selectedWorkItemIDs: $selectedWorkItemIDs,
                draggedWorkItemIDs: $draggedWorkItemIDs,
                activeDropTarget: $planningDropTarget,
                onDragBegan: beginDragging,
                onDragCompleted: finishDragging,
                onOpen: { selectedTicket = $0 },
                onAddTicket: { onNewTicket(nil) },
                suggestionBatch: visibleSuggestionBatch
              )
              .padding(.leading, horizontalPadding)
              .padding(.trailing, columnGutter)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(
            height: availableHeight,
            alignment: .topLeading
          )
          .clipped()
          .padding(.top, topPadding)
          .padding(.bottom, bottomPadding)
        } sprint: {
          CandidateSprintPanel(
            sprintNumber: candidateSprintNumber,
            items: candidateItems,
            planningIsComplete: planningIsComplete,
            availableHeight: availableHeight,
            selectedWorkItemIDs: $selectedWorkItemIDs,
            draggedWorkItemIDs: $draggedWorkItemIDs,
            activeDropTarget: $planningDropTarget,
            onDragBegan: beginDragging,
            onDragCompleted: finishDragging,
            onOpen: { selectedTicket = $0 },
            onPlanSprint: onPlanSprint
          )
          .padding(.leading, columnGutter)
          .padding(.trailing, horizontalPadding)
          .frame(
            height: availableHeight,
            alignment: .top
          )
          .clipped()
          .padding(.top, topPadding)
          .padding(.bottom, bottomPadding)
        }
        .frame(maxHeight: .infinity, alignment: .top)
      }
    }
    .sheet(item: $selectedTicket) { item in
      TicketDetailView(
        item: item,
        dependsOnWorkItemIDs: Set(
          model.dependencies
            .filter { $0.workItemID == item.id }
            .map(\.dependsOnWorkItemID)
        )
      )
    }
    .sheet(item: $selectedEpic) { epic in
      EpicDetailView(epic: epic)
    }
    .onChange(of: Set(allPlanningItems.map(\.id))) { _, availableIDs in
      selectedWorkItemIDs.formIntersection(availableIDs)
    }
    .onChange(of: planningDropTarget) { _, target in
      dropExitResetTask?.cancel()
      guard target == nil, !draggedWorkItemIDs.isEmpty else { return }
      dropExitResetTask = Task {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, planningDropTarget == nil else { return }
        finishDragging()
      }
    }
    .onDisappear {
      dragResetTask?.cancel()
      dropExitResetTask?.cancel()
    }
    .onChange(of: model.backlogFocusEpicID, initial: true) { _, epicID in
      guard
        let epicID,
        let epic = model.epics.first(where: {
          $0.id == epicID && $0.status != .archived
        })
      else { return }
      selectedEpic = epic
      model.backlogFocusEpicID = nil
    }
    .onChange(of: model.selectedProductID, initial: true) { _, productID in
      restoreClosedEpicExpansion(for: productID)
    }
    .onChange(of: closedEpicsExpanded) { _, isExpanded in
      guard
        let productID = model.selectedProductID,
        closedExpansionProductID == productID
      else { return }
      EpicPlanningDisclosureDefaults.setExpanded(isExpanded, for: productID)
    }
  }

  private func beginDragging(_ ids: Set<UUID>) {
    dragResetTask?.cancel()
    withAnimation(.snappy(duration: 0.2)) {
      draggedWorkItemIDs = ids
    }
    dragResetTask = Task {
      try? await Task.sleep(for: .seconds(30))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        finishDragging()
      }
    }
  }

  private func finishDragging() {
    dragResetTask?.cancel()
    dragResetTask = nil
    dropExitResetTask?.cancel()
    dropExitResetTask = nil
    withAnimation(.snappy(duration: 0.2)) {
      draggedWorkItemIDs.removeAll()
      planningDropTarget = nil
    }
  }

  private func restoreClosedEpicExpansion(for productID: UUID?) {
    closedExpansionProductID = nil
    guard let productID else {
      closedEpicsExpanded = false
      return
    }
    closedEpicsExpanded = EpicPlanningDisclosureDefaults.isExpanded(for: productID)
    closedExpansionProductID = productID
  }
}

struct BacklogPlanningSplitView<BacklogContent: View, SprintContent: View>: View {
  let containerWidth: CGFloat
  let horizontalPadding: CGFloat
  let dividerWidth: CGFloat
  let backlogContent: BacklogContent
  let sprintContent: SprintContent

  init(
    containerWidth: CGFloat,
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat,
    @ViewBuilder backlog: () -> BacklogContent,
    @ViewBuilder sprint: () -> SprintContent
  ) {
    self.containerWidth = containerWidth
    self.horizontalPadding = horizontalPadding
    self.dividerWidth = dividerWidth
    backlogContent = backlog()
    sprintContent = sprint()
  }

  var body: some View {
    BacklogPlanningNativeSplitView(
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredBacklogRatio: BacklogPlanningSplitPreference.load(),
      backlogContent: backlogContent,
      sprintContent: sprintContent
    )
    .frame(width: containerWidth)
  }
}

struct BacklogPlanningNativeSplitView<
  BacklogContent: View,
  SprintContent: View
>: NSViewRepresentable {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let horizontalPadding: CGFloat
  let dividerWidth: CGFloat
  let preferredBacklogRatio: CGFloat
  let backlogContent: BacklogContent
  let sprintContent: SprintContent

  final class Coordinator {
    var backlogHostingView: NSHostingView<AnyView>?
    var sprintHostingView: NSHostingView<AnyView>?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> BacklogPlanningSplitNSView {
    let splitView = BacklogPlanningSplitNSView()
    let backlogHostingView = NSHostingView(rootView: hosted(backlogContent))
    let sprintHostingView = NSHostingView(rootView: hosted(sprintContent))
    backlogHostingView.sizingOptions = []
    sprintHostingView.sizingOptions = []
    context.coordinator.backlogHostingView = backlogHostingView
    context.coordinator.sprintHostingView = sprintHostingView
    splitView.addArrangedSubview(backlogHostingView)
    splitView.addArrangedSubview(sprintHostingView)
    splitView.configure(
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredBacklogRatio: preferredBacklogRatio,
      onCommit: { BacklogPlanningSplitPreference.save($0) }
    )
    return splitView
  }

  func updateNSView(
    _ nsView: BacklogPlanningSplitNSView,
    context: Context
  ) {
    context.coordinator.backlogHostingView?.rootView = hosted(backlogContent)
    context.coordinator.sprintHostingView?.rootView = hosted(sprintContent)
    nsView.configure(
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredBacklogRatio: preferredBacklogRatio,
      onCommit: { BacklogPlanningSplitPreference.save($0) }
    )
  }

  private func hosted<Content: View>(_ content: Content) -> AnyView {
    AnyView(
      content
        .environmentObject(model)
        .environment(\.colorScheme, colorScheme)
    )
  }
}

final class BacklogPlanningSplitNSView: NSSplitView, NSSplitViewDelegate {
  private var planningHorizontalPadding: CGFloat = 0
  private var planningDividerWidth: CGFloat = 1
  private var preferredBacklogRatio = BacklogPlanningSizing.defaultBacklogRatio
  private var lastLayoutWidth: CGFloat = 0
  private var hasAppliedPreferredPosition = false
  private var isApplyingPreferredPosition = false
  private var onCommit: ((CGFloat) -> Void)?

  override var dividerThickness: CGFloat {
    planningDividerWidth
  }

  override var dividerColor: NSColor {
    .separatorColor
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isVertical = true
    dividerStyle = .thin
    delegate = self
    setAccessibilityLabel("Backlog planning columns")
    setAccessibilityHelp(
      "Drag left to give the sprint more room. Double-click to restore the default size."
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat,
    preferredBacklogRatio: CGFloat,
    onCommit: @escaping (CGFloat) -> Void
  ) {
    let ratioChanged = abs(self.preferredBacklogRatio - preferredBacklogRatio) > 0.0001
    let geometryChanged =
      self.planningHorizontalPadding != horizontalPadding
      || self.planningDividerWidth != dividerWidth
    planningHorizontalPadding = horizontalPadding
    planningDividerWidth = dividerWidth
    self.preferredBacklogRatio = preferredBacklogRatio
    self.onCommit = onCommit
    if ratioChanged || geometryChanged {
      hasAppliedPreferredPosition = false
      needsLayout = true
    }
  }

  override func layout() {
    let widthChanged = abs(bounds.width - lastLayoutWidth) > 0.5
    lastLayoutWidth = bounds.width
    super.layout()
    guard !isApplyingPreferredPosition else { return }
    if !hasAppliedPreferredPosition || widthChanged {
      applyPreferredPosition()
    }
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      resetDivider()
      return
    }

    super.mouseDown(with: event)
    guard arrangedSubviews.count == 2 else { return }
    let ratio = currentBacklogRatio
    preferredBacklogRatio = ratio
    onCommit?(ratio)
  }

  func splitView(
    _ splitView: NSSplitView,
    constrainSplitPosition proposedPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    guard dividerIndex == 0 else { return proposedPosition }
    let minimumPosition = BacklogPlanningSizing.splitPosition(
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness,
      preferredRatio: 0
    )
    let maximumPosition = BacklogPlanningSizing.splitPosition(
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness,
      preferredRatio: 1
    )
    return min(max(proposedPosition, minimumPosition), maximumPosition)
  }

  private var currentBacklogRatio: CGFloat {
    guard let backlogView = arrangedSubviews.first else {
      return preferredBacklogRatio
    }
    return BacklogPlanningSizing.backlogRatio(
      forSplitPosition: backlogView.frame.maxX,
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness
    )
  }

  private func applyPreferredPosition() {
    guard arrangedSubviews.count == 2, bounds.width > 0 else { return }
    isApplyingPreferredPosition = true
    setPosition(
      BacklogPlanningSizing.splitPosition(
        containerWidth: bounds.width,
        horizontalPadding: planningHorizontalPadding,
        dividerWidth: dividerThickness,
        preferredRatio: preferredBacklogRatio
      ),
      ofDividerAt: 0
    )
    hasAppliedPreferredPosition = true
    isApplyingPreferredPosition = false
  }

  private func resetDivider() {
    preferredBacklogRatio = BacklogPlanningSizing.defaultBacklogRatio
    let position = BacklogPlanningSizing.splitPosition(
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness,
      preferredRatio: preferredBacklogRatio
    )
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      animator().setPosition(position, ofDividerAt: 0)
    }
    hasAppliedPreferredPosition = true
    onCommit?(preferredBacklogRatio)
  }
}

enum EpicPlanningTableGeometry {
  static let columnLeadingInset: CGFloat = 14
  static let ticketsWidth: CGFloat = 64
  static let progressWidth: CGFloat = 120
  static let statusWidth: CGFloat = 128
}

struct EpicPlanningList: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let sections: EpicPlanningSections
  let workItems: [WorkItem]
  let minimumHeight: CGFloat
  @Binding var isClosedExpanded: Bool
  let onAddEpic: () -> Void
  let onOpen: (Epic) -> Void
  @State private var targetedEpicID: UUID?
  @State private var isBottomTargeted = false
  @State private var confirmingArchive: Epic?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Text("Epics")
          .font(.title3.weight(.semibold))
        Text(sections.openEpics.count.formatted())
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        Spacer()
        Button(action: onAddEpic) {
          Label("Add epic", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .help("Plan a substantial product outcome with the business analyst")
      }
      .padding(.horizontal, 2)

      VStack(spacing: 0) {
        EpicPlanningTableHeader()
          .background(PlanningDropSurfaceStyle.tableHeaderBackground)
        Divider()

        if sections.isEmpty {
          VStack(spacing: 6) {
            Image(systemName: "flag.checkered")
              .font(.title3)
              .foregroundStyle(.tertiary)
            Text("No open epics")
              .font(.subheadline.weight(.medium))
            Text("Add an epic to plan a substantial product outcome with AI.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity)
        } else {
          ForEach(Array(sections.openEpics.enumerated()), id: \.element.id) {
            index,
            epic in
            epicRow(epic)
            if index < sections.openEpics.count - 1 {
              Divider()
            }
          }

          if !sections.closedEpics.isEmpty {
            if !sections.openEpics.isEmpty {
              Divider()
            }
            ClosedEpicsDisclosureRow(
              epicCount: sections.closedEpics.count,
              deliveredTicketCount: sections.deliveredTicketCount,
              isExpanded: $isClosedExpanded
            )

            if isClosedExpanded {
              ForEach(sections.closedEpics) { epic in
                Divider()
                epicRow(epic)
              }
            }
          }
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: sections.isEmpty ? .infinity : nil,
        alignment: .top
      )
      .background(PlanningDropSurfaceStyle.restingBackground(for: colorScheme))
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(PlanningDropSurfaceStyle.tableBorder(for: colorScheme), lineWidth: 1)
      }
      .overlay(alignment: .bottom) {
        if !sections.isEmpty {
          Color.clear
            .frame(height: 12)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
              if isBottomTargeted {
                Rectangle()
                  .fill(Color.accentColor)
                  .frame(height: 2)
              }
            }
            .dropDestination(
              for: String.self,
              action: { values, _ in move(values, before: nil) },
              isTargeted: { isBottomTargeted = $0 }
            )
        }
      }
    }
    .frame(minHeight: minimumHeight, alignment: .top)
    .confirmationDialog(
      "Archive \(confirmingArchive?.title ?? "epic")?",
      isPresented: Binding(
        get: { confirmingArchive != nil },
        set: { if !$0 { confirmingArchive = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let epic = confirmingArchive {
        Button("Archive epic", role: .destructive) {
          model.archiveEpic(epic)
          confirmingArchive = nil
        }
      }
      Button("Cancel", role: .cancel) {
        confirmingArchive = nil
      }
    } message: {
      Text(
        "All unfinished backlog tickets and proposed tickets in this epic will also be archived. Delivered tickets and history remain available."
      )
    }
  }

  private func epicRow(_ epic: Epic) -> some View {
    EpicPlanningRow(
      epic: epic,
      tickets: workItems.filter {
        $0.epicID == epic.id && $0.state != .cancelled
      },
      isDropTargeted: targetedEpicID == epic.id,
      notificationKind: model.ownerNotificationKind(
        productID: epic.productID,
        target: OwnerNotificationTarget(kind: .epic, id: epic.id)
      ),
      onOpen: { onOpen(epic) },
      onRefine: {
        model.planEpic(epic)
        onOpen(epic)
      },
      onMoveTop: {
        model.moveEpics([epic], before: sections.allEpics.first?.id)
      },
      onMoveBottom: { model.moveEpics([epic], before: nil) },
      onArchive: { confirmingArchive = epic }
    )
    .dropDestination(
      for: String.self,
      action: { values, _ in move(values, before: epic.id) },
      isTargeted: { targeted in
        withAnimation(.easeOut(duration: 0.12)) {
          targetedEpicID = targeted ? epic.id : nil
        }
      }
    )
  }

  private func move(_ values: [String], before targetID: UUID?) -> Bool {
    let ids = values.compactMap { value -> UUID? in
      guard value.hasPrefix("epic:") else { return nil }
      return UUID(uuidString: String(value.dropFirst(5)))
    }
    let moving = sections.allEpics.filter { ids.contains($0.id) }
    guard !moving.isEmpty else { return false }
    if moving.count == 1, moving.first?.id == targetID {
      return true
    }
    model.moveEpics(moving, before: targetID)
    return true
  }
}

struct ClosedEpicsDisclosureRow: View {
  let epicCount: Int
  let deliveredTicketCount: Int
  @Binding var isExpanded: Bool
  @State private var isHovering = false

  private var epicLabel: String {
    "\(epicCount) completed \(epicCount == 1 ? "epic" : "epics")"
  }

  private var ticketLabel: String {
    "\(deliveredTicketCount) delivered \(deliveredTicketCount == 1 ? "ticket" : "tickets")"
  }

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 12)
          .animation(.easeInOut(duration: 0.18), value: isExpanded)
        Text(epicLabel)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
        Text("·")
          .foregroundStyle(.tertiary)
        Text(ticketLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .frame(
        maxWidth: .infinity,
        minHeight: BacklogPlanningSizing.tableRowHeight,
        alignment: .leading
      )
      .contentShape(Rectangle())
      .background(isHovering ? Color.accentColor.opacity(0.055) : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .help(isExpanded ? "Hide completed epics" : "Show completed epics")
  }
}

struct EpicPlanningTableHeader: View {
  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow {
        Text("Epic")
          .frame(maxWidth: .infinity, alignment: .leading)
          .gridColumnAlignment(.leading)
        Text("Tickets")
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.ticketsWidth, alignment: .leading)
          .gridColumnAlignment(.leading)
        Text("Progress")
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.progressWidth, alignment: .leading)
          .gridColumnAlignment(.leading)
        Text("Status")
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.statusWidth, alignment: .leading)
          .gridColumnAlignment(.leading)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(height: 32)
    }
    .padding(.horizontal, 16)
  }
}

struct EpicPlanningRow: View {
  let epic: Epic
  let tickets: [WorkItem]
  let isDropTargeted: Bool
  let notificationKind: OwnerNotificationKind?
  let onOpen: () -> Void
  let onRefine: () -> Void
  let onMoveTop: () -> Void
  let onMoveBottom: () -> Void
  let onArchive: () -> Void
  @State private var isHovering = false

  private var completedCount: Int {
    tickets.filter { $0.state == .released }.count
  }

  private var progress: EpicProgress {
    EpicProgress(tickets: tickets)
  }

  private var displayStatus: String {
    switch epic.status {
    case .open:
      return progress.title
    case .closed, .archived:
      return epic.status.title
    }
  }

  private var statusColor: Color {
    switch epic.status {
    case .open:
      switch progress {
      case .created: return .secondary
      case .planned: return .blue
      case .inProgress: return .orange
      case .complete: return .green
      }
    case .closed:
      return .green
    case .archived:
      return .secondary
    }
  }

  private var archiveTitle: AttributedString {
    var title = AttributedString("Archive epic…")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    Button(action: onOpen) {
      Grid(horizontalSpacing: 0) {
        GridRow(alignment: .center) {
          HStack(spacing: 7) {
            Text(epic.displayTitle)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
              .lineLimit(2)
              .layoutPriority(1)
            if let notificationKind {
              Circle()
                .fill(notificationKind.requiresAction ? Color.orange : Color.purple)
                .frame(width: 7, height: 7)
                .accessibilityLabel(
                  notificationKind.requiresAction
                    ? "Needs your input"
                    : "New refinement result"
                )
            }
          }
          .help(epic.goal)
          .frame(maxWidth: .infinity, alignment: .leading)
          .gridColumnAlignment(.leading)

          Text(tickets.count.formatted())
            .font(.caption)
            .foregroundStyle(tickets.isEmpty ? .secondary : .primary)
            .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
            .frame(width: EpicPlanningTableGeometry.ticketsWidth, alignment: .leading)
            .gridColumnAlignment(.leading)

          Text(
            tickets.isEmpty
              ? "Not started"
              : "\(completedCount) of \(tickets.count) delivered"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.progressWidth, alignment: .leading)
          .gridColumnAlignment(.leading)

          Text(displayStatus)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
            .frame(width: EpicPlanningTableGeometry.statusWidth, alignment: .leading)
            .gridColumnAlignment(.leading)
            .help(displayStatus)
        }
      }
      .padding(.horizontal, 16)
      .frame(minHeight: BacklogPlanningSizing.tableRowHeight)
      .contentShape(Rectangle())
      .background(
        isDropTargeted
          ? Color.accentColor.opacity(0.12)
          : (isHovering ? Color.accentColor.opacity(0.055) : Color.clear)
      )
      .overlay(alignment: .top) {
        if isDropTargeted {
          Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
        }
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(epic.color.displayColor)
          .frame(width: 4)
      }
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .onDrag {
      NSItemProvider(object: "epic:\(epic.id.uuidString)" as NSString)
    } preview: {
      Label(epic.displayTitle, systemImage: "flag.checkered")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    .contextMenu {
      Button(action: onOpen) {
        Label("Open epic", systemImage: "flag.checkered")
      }
      Button(action: onRefine) {
        Label("Refine with AI", systemImage: "wand.and.stars")
      }
      .disabled(epic.status != .open)
      Divider()
      Button(action: onMoveTop) {
        Label("Move to top", systemImage: "arrow.up.to.line")
      }
      Button(action: onMoveBottom) {
        Label("Move to bottom", systemImage: "arrow.down.to.line")
      }
      Divider()
      Button(role: .destructive, action: onArchive) {
        Label {
          Text(archiveTitle)
        } icon: {
          Image(systemName: "archivebox")
            .foregroundStyle(.red)
        }
      }
      .tint(.red)
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
  }
}

enum PlanningDropSurfaceStyle {
  static let targetedBackground = Color.accentColor.opacity(0.11)
  static let invalidTargetedBackground = Color.red.opacity(0.11)
  static let tableHeaderBackground = AnyShapeStyle(.quaternary.opacity(0.18))

  static func tableBorder(for colorScheme: ColorScheme) -> Color {
    Color.secondary.opacity(colorScheme == .dark ? 0.32 : 0.2)
  }

  static func restingBackground(for colorScheme: ColorScheme) -> Color {
    Color.secondary.opacity(colorScheme == .dark ? 0.075 : 0.035)
  }
}

struct CandidateSprintPanel: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let sprintNumber: Int
  let items: [WorkItem]
  let planningIsComplete: Bool
  let availableHeight: CGFloat
  @Binding var selectedWorkItemIDs: Set<UUID>
  @Binding var draggedWorkItemIDs: Set<UUID>
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDragBegan: (Set<UUID>) -> Void
  let onDragCompleted: () -> Void
  let onOpen: (WorkItem) -> Void
  let onPlanSprint: () -> Void

  private var section: PlanningDropSection { .candidateSprint }
  private var itemIDs: Set<UUID> { Set(items.map(\.id)) }
  private var selectedItemCount: Int {
    selectedWorkItemIDs.intersection(itemIDs).count
  }
  private var isDropTargeted: Bool {
    activeDropTarget?.section == .candidateSprint
      && activeDropEvaluation != nil
  }
  private var activeDropEvaluation: PlanningDropEvaluation? {
    guard
      let activeDropTarget,
      activeDropTarget.section == section
    else {
      return nil
    }
    return dropEvaluation(
      ids: draggedWorkItemIDs,
      at: activeDropTarget.index
    )
  }
  private var bulkMoveAction: PlanningBulkMoveAction {
    PlanningBulkMoveAction(
      items: items,
      selectedWorkItemIDs: selectedWorkItemIDs,
      destination: .backlog
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text("Sprint \(sprintNumber)")
              .font(.title3.weight(.semibold))
            Text(items.count.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
          }
        }
        Spacer(minLength: 4)
        Button {
          model.removeFromCandidateSprint(bulkMoveAction.targetItems)
        } label: {
          ViewThatFits(in: .horizontal) {
            Label(bulkMoveAction.title, systemImage: "arrow.left")
            Label(bulkMoveAction.compactTitle, systemImage: "arrow.left")
            Image(systemName: "arrow.left")
          }
        }
        .buttonStyle(.bordered)
        .disabled(items.isEmpty)
        .accessibilityLabel(bulkMoveAction.title)
        .help(bulkMoveAction.helpText)
        Button(action: onPlanSprint) {
          Label(
            planningIsComplete ? "Review plan" : "Plan sprint",
            systemImage: "calendar.badge.plus"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(items.isEmpty)
      }
      .padding(.horizontal, 2)

      VStack(spacing: 0) {
        CandidateSprintTableHeader(
          itemCount: items.count,
          selectedItemCount: selectedItemCount,
          onToggleSelection: toggleAllItems
        )
        .padding(.horizontal, PlanningTicketTableMetrics.horizontalPadding)
        .background(PlanningDropSurfaceStyle.tableHeaderBackground)
        .dropDestination(
          for: String.self,
          action: { values, _ in performDrop(values, at: 0) },
          isTargeted: { setDropTarget($0, index: 0) }
        )

        Divider()

        if items.isEmpty {
          VStack(spacing: 7) {
            Image(
              systemName:
                activeDropEvaluation?.isValid == false
                ? "exclamationmark.triangle.fill"
                : "tray.and.arrow.down"
            )
            .font(.title2)
            .foregroundStyle(
              activeDropEvaluation?.isValid == false
                ? Color.red : Color.secondary
            )
            Text(
              activeDropEvaluation?.isValid == false
                ? "Can't drop here" : "Drag backlog tickets here"
            )
            .font(.subheadline.weight(.medium))
            Text(
              activeDropEvaluation?.message
                ?? (isDropTargeted
                  ? "Backlog rank will stay unchanged."
                  : "Only scoped work enters sprint planning.")
            )
            .font(.caption)
            .foregroundStyle(
              activeDropEvaluation?.isValid == false
                ? Color.red : Color.secondary
            )
            .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { setDropTarget($0, index: 0) }
          )
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(0...items.count, id: \.self) { index in
                PlanningTicketDropSlot(
                  section: section,
                  index: index,
                  showsRestingDivider: index > 0,
                  showsInsertionIndicator: !isNoOpDrop(
                    ids: draggedWorkItemIDs,
                    at: index
                  ),
                  evaluation: dropEvaluation(
                    ids: draggedWorkItemIDs,
                    at: index
                  ),
                  activeDropTarget: $activeDropTarget,
                  onDrop: { values in performDrop(values, at: index) }
                )

                if index < items.count {
                  let item = items[index]
                  let dragSelection =
                    selectedWorkItemIDs.contains(item.id)
                    ? selectedWorkItemIDs.intersection(itemIDs)
                    : [item.id]
                  CandidateSprintRow(
                    item: item,
                    isSelected: selectedWorkItemIDs.contains(item.id),
                    dragSelection: dragSelection,
                    isBeingDragged: draggedWorkItemIDs.contains(item.id),
                    dropEvaluation: dropEvaluation(
                      ids: draggedWorkItemIDs,
                      at: index + 1
                    ),
                    onToggleSelection: {
                      if selectedWorkItemIDs.contains(item.id) {
                        selectedWorkItemIDs.remove(item.id)
                      } else {
                        selectedWorkItemIDs.insert(item.id)
                      }
                    },
                    onDragBegan: { onDragBegan(dragSelection) },
                    onDrop: { values in performDrop(values, at: index + 1) },
                    onDropTargeted: { targeted in
                      setDropTarget(targeted, index: index + 1)
                    },
                    onOpen: { onOpen(item) }
                  )
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(
        isDropTargeted
          ? (activeDropEvaluation?.isValid == false
            ? PlanningDropSurfaceStyle.invalidTargetedBackground
            : PlanningDropSurfaceStyle.targetedBackground)
          : PlanningDropSurfaceStyle.restingBackground(for: colorScheme)
      )
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(
            Color.secondary.opacity(colorScheme == .dark ? 0.45 : 0.28),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
          )
      }
      .contentShape(Rectangle())
      .dropDestination(
        for: String.self,
        action: { values, _ in performDrop(values, at: items.count) },
        isTargeted: { setDropTarget($0, index: items.count) }
      )
      .animation(.snappy(duration: 0.18), value: isDropTargeted)
      .animation(.snappy(duration: 0.22), value: items.map(\.id))
    }
    .frame(height: availableHeight, alignment: .top)
  }

  private func toggleAllItems() {
    if !itemIDs.isEmpty, itemIDs.isSubset(of: selectedWorkItemIDs) {
      selectedWorkItemIDs.subtract(itemIDs)
    } else {
      selectedWorkItemIDs.formUnion(itemIDs)
    }
  }

  private func performDrop(_ values: [String], at index: Int) -> Bool {
    guard model.canEditCandidateSprint else { return false }
    let ids = Set(
      values.flatMap { payload in
        payload.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
      }
    )
    let movingItems = model.workItems.filter { ids.contains($0.id) }
    guard !movingItems.isEmpty else { return false }
    let safeIndex = min(max(index, 0), items.count)
    if isNoOpDrop(ids: ids, at: safeIndex) {
      onDragCompleted()
      return true
    }
    let targetID = dropTargetID(ids: ids, at: safeIndex)
    let evaluation = model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: true,
      before: targetID
    )
    guard evaluation.isValid else {
      onDragCompleted()
      return true
    }
    model.dropPlanningItems(
      movingItems,
      intoCandidateSprint: true,
      before: targetID
    )
    onDragCompleted()
    return true
  }

  private func setDropTarget(_ targeted: Bool, index: Int) {
    let target = PlanningDropTarget(section: section, index: index)
    withAnimation(.snappy(duration: 0.16)) {
      activeDropTarget = PlanningDropTargetState.updated(
        current: activeDropTarget,
        target: target,
        isTargeted: targeted
      )
    }
  }

  private func dropEvaluation(
    ids: Set<UUID>,
    at index: Int
  ) -> PlanningDropEvaluation? {
    guard !ids.isEmpty else { return nil }
    return model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: true,
      before: dropTargetID(ids: ids, at: index)
    )
  }

  private func dropTargetID(ids: Set<UUID>, at index: Int) -> UUID? {
    let safeIndex = min(max(index, 0), items.count)
    return items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
  }

  private func isNoOpDrop(ids: Set<UUID>, at index: Int) -> Bool {
    guard !ids.isEmpty, ids.isSubset(of: itemIDs) else { return false }
    let safeIndex = min(max(index, 0), items.count)
    let movingItems = items.filter { ids.contains($0.id) }
    var reorderedItems = items.filter { !ids.contains($0.id) }
    let targetID = items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
    let insertionIndex =
      targetID.flatMap { targetID in
        reorderedItems.firstIndex { $0.id == targetID }
      } ?? reorderedItems.endIndex
    reorderedItems.insert(contentsOf: movingItems, at: insertionIndex)
    return reorderedItems.map(\.id) == items.map(\.id)
  }
}

enum PlanningTicketTableMetrics {
  static let rowHeight = BacklogPlanningSizing.tableRowHeight
  static let columnSpacing: CGFloat = 6
  static let horizontalPadding: CGFloat = 10
  static let ticketLeadingSpacing: CGFloat = 10
  static let selectionWidth: CGFloat = 30
  static let referenceWidth: CGFloat = 34
  static let assigneeWidth: CGFloat = 54
  static let readinessWidth: CGFloat = 58
  static let priorityWidth: CGFloat = 44
}

struct PlanningSelectionCheckbox: View {
  let symbol: String
  let isActive: Bool
  let isDisabled: Bool
  let helpText: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(
          isActive ? Color.blue : Color(nsColor: .tertiaryLabelColor)
        )
        .frame(
          width: PlanningTicketTableMetrics.selectionWidth,
          height: 32
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(helpText)
    .frame(width: PlanningTicketTableMetrics.selectionWidth, alignment: .center)
  }
}

struct PlanningAssigneeIcon: View {
  let profile: AgentProfile?

  var body: some View {
    Image(
      systemName: profile?.role.symbolName
        ?? "person.crop.circle.badge.questionmark"
    )
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(profile?.role.tint ?? Color.secondary)
    .frame(width: PlanningTicketTableMetrics.assigneeWidth, alignment: .center)
    .accessibilityLabel(profile?.name ?? "Unassigned")
    .help(profile?.name ?? "Unassigned")
  }
}

enum CandidateSprintTableLayout {
  static let columnSpacing = PlanningTicketTableMetrics.columnSpacing
  static let selectionWidth = PlanningTicketTableMetrics.selectionWidth
  static let referenceWidth = PlanningTicketTableMetrics.referenceWidth
  static let assigneeWidth = PlanningTicketTableMetrics.assigneeWidth
  static let readinessWidth = PlanningTicketTableMetrics.readinessWidth
  static let priorityWidth = PlanningTicketTableMetrics.priorityWidth
}

struct CandidateSprintTableHeader: View {
  let itemCount: Int
  let selectedItemCount: Int
  let onToggleSelection: () -> Void

  private var selectionSymbol: String {
    if itemCount > 0, selectedItemCount == itemCount {
      return "checkmark.square.fill"
    }
    if selectedItemCount > 0 {
      return "minus.square.fill"
    }
    return "square"
  }

  private var selectionHelp: String {
    itemCount > 0 && selectedItemCount == itemCount
      ? "Deselect all sprint tickets"
      : "Select all sprint tickets"
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: selectionSymbol,
          isActive: selectedItemCount > 0,
          isDisabled: itemCount == 0,
          helpText: selectionHelp,
          action: onToggleSelection
        )

        Text("Ticket")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
          .gridColumnAlignment(.leading)

        Text("Assignee")
          .frame(
            width: CandidateSprintTableLayout.assigneeWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
          .gridColumnAlignment(.center)

        Text("Readiness")
          .frame(
            width: CandidateSprintTableLayout.readinessWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
          .gridColumnAlignment(.center)

        Text("Priority")
          .frame(
            width: CandidateSprintTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
          .gridColumnAlignment(.center)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(height: 32)
    }
    .frame(maxWidth: .infinity)
  }
}

struct CandidateSprintRow: View {
  @EnvironmentObject private var model: AppModel
  let item: WorkItem
  let isSelected: Bool
  let dragSelection: Set<UUID>
  let isBeingDragged: Bool
  let dropEvaluation: PlanningDropEvaluation?
  let onToggleSelection: () -> Void
  let onDragBegan: () -> Void
  let onDrop: ([String]) -> Bool
  let onDropTargeted: (Bool) -> Void
  let onOpen: () -> Void
  @State private var isHovering = false

  private var sprintItem: SprintItem? {
    model.candidateSprintPlan?.items
      .first { $0.workItemID == item.id }
  }

  private var epicColor: Color? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var owner: AgentProfile? {
    guard let ownerID = sprintItem?.implementerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var readinessProblems: [String] {
    var problems: [String] = []
    if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems.append("Add ticket context")
    }
    if item.acceptanceCriteria.isEmpty {
      problems.append("Add acceptance criteria")
    }
    if owner == nil {
      problems.append("Choose a delivery assignee")
    }
    problems.append(
      contentsOf: model.sprintReadinessIssues
        .filter {
          $0.workItemID == item.id
            && !$0.id.hasSuffix(".acceptance")
            && !$0.id.hasSuffix(".implementer")
        }
        .map(\.message)
    )
    return problems
  }

  private var readinessLabel: String {
    if readinessProblems.isEmpty {
      let count = item.acceptanceCriteria.count
      return "Ready · \(count) \(count == 1 ? "criterion" : "criteria")"
    }
    return readinessProblems.joined(separator: ". ")
  }

  private var isReady: Bool {
    readinessProblems.isEmpty
  }

  private var targetItems: [WorkItem] {
    model.workItems.filter { dragSelection.contains($0.id) }
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: isSelected ? "checkmark.square.fill" : "square",
          isActive: isSelected,
          isDisabled: false,
          helpText: isSelected ? "Deselect ticket" : "Select ticket",
          action: onToggleSelection
        )

        HStack(spacing: 8) {
          Image(systemName: item.type.symbolName)
            .foregroundStyle(item.type.tint)
            .frame(width: 16)
          Text(item.key)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(
              width: CandidateSprintTableLayout.referenceWidth,
              alignment: .leading
            )
          Text(item.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)

        PlanningAssigneeIcon(profile: owner)
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)

        Image(
          systemName: isReady
            ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isReady ? .green : .orange)
        .frame(
          width: CandidateSprintTableLayout.readinessWidth,
          alignment: .center
        )
        .padding(.leading, CandidateSprintTableLayout.columnSpacing)
        .accessibilityLabel(readinessLabel)
        .help(readinessLabel)

        SprintPriorityIndicator(priority: item.priority)
          .frame(
            width: CandidateSprintTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
      }
    }
    .padding(.horizontal, PlanningTicketTableMetrics.horizontalPadding)
    .frame(minHeight: PlanningTicketTableMetrics.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.1)
        : (isHovering ? Color.accentColor.opacity(0.055) : Color.clear)
    )
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    .saturation(dropEvaluation?.isValid == false ? 0.2 : 1)
    .opacity(
      isBeingDragged
        ? 0.28
        : (dropEvaluation?.isValid == false ? 0.45 : 1)
    )
    .onTapGesture(perform: onOpen)
    .onHover { isHovering = $0 }
    .onDrag {
      onDragBegan()
      let payload = dragSelection.map(\.uuidString).sorted().joined(separator: ",")
      return NSItemProvider(object: payload as NSString)
    } preview: {
      PlanningTicketDragPreview(item: item, count: dragSelection.count)
    }
    .dropDestination(
      for: String.self,
      action: { values, _ in onDrop(values) },
      isTargeted: onDropTargeted
    )
    .animation(.easeOut(duration: 0.12), value: dropEvaluation?.isValid)
    .contextMenu {
      Button(action: onOpen) {
        Label("Open ticket", systemImage: "doc.text.magnifyingglass")
      }
      Button {
        model.removeFromCandidateSprint(targetItems)
      } label: {
        Label(
          targetItems.count > 1 ? "Return selected to backlog" : "Return to backlog",
          systemImage: "arrow.uturn.backward"
        )
      }
    }
  }
}

struct PlanningTicketList: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let title: String
  let items: [WorkItem]
  let isCandidateSection: Bool
  let minimumHeight: CGFloat
  @Binding var selectedWorkItemIDs: Set<UUID>
  @Binding var draggedWorkItemIDs: Set<UUID>
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDragBegan: (Set<UUID>) -> Void
  let onDragCompleted: () -> Void
  let onOpen: (WorkItem) -> Void
  let onAddTicket: (() -> Void)?
  let suggestionBatch: TicketSuggestionBatch?

  private var section: PlanningDropSection {
    isCandidateSection ? .candidateSprint : .backlog
  }

  private var isDropTargeted: Bool {
    activeDropTarget?.section == section
      && activeDropEvaluation != nil
  }
  private var activeDropEvaluation: PlanningDropEvaluation? {
    guard
      let activeDropTarget,
      activeDropTarget.section == section
    else {
      return nil
    }
    return dropEvaluation(
      ids: draggedWorkItemIDs,
      at: activeDropTarget.index
    )
  }

  private var itemIDs: Set<UUID> {
    Set(items.map(\.id))
  }

  private var allItemsSelected: Bool {
    !itemIDs.isEmpty && itemIDs.isSubset(of: selectedWorkItemIDs)
  }

  private var selectedItemCount: Int {
    selectedWorkItemIDs.intersection(itemIDs).count
  }

  private var proposedSuggestionCount: Int {
    guard !isCandidateSection, suggestionBatch?.session.status == .ready else { return 0 }
    return suggestionBatch?.suggestions.filter { $0.status == .proposed }.count ?? 0
  }

  private var visibleItemCount: Int {
    items.count + proposedSuggestionCount
  }

  private var restingBackground: Color {
    PlanningDropSurfaceStyle.restingBackground(for: colorScheme)
  }

  private var bulkMoveAction: PlanningBulkMoveAction {
    PlanningBulkMoveAction(
      items: items,
      selectedWorkItemIDs: selectedWorkItemIDs,
      destination: isCandidateSection ? .backlog : .candidateSprint
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .center, spacing: 7) {
            Text(title)
              .font(.title3.weight(.semibold))
            Text(visibleItemCount.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
          }
        }
        Spacer()
        if !isCandidateSection {
          Button {
            model.addToCandidateSprint(bulkMoveAction.targetItems)
          } label: {
            ViewThatFits(in: .horizontal) {
              Label(bulkMoveAction.title, systemImage: "arrow.right")
              Label(bulkMoveAction.compactTitle, systemImage: "arrow.right")
              Image(systemName: "arrow.right")
            }
          }
          .buttonStyle(.bordered)
          .disabled(items.isEmpty || !model.canEditCandidateSprint)
          .accessibilityLabel(bulkMoveAction.title)
          .help(bulkMoveAction.helpText)
        }
        if let onAddTicket {
          Button(action: onAddTicket) {
            Label("Add ticket", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
        }
      }
      .padding(.horizontal, 2)
      .padding(.bottom, 1)

      VStack(spacing: 0) {
        PlanningTicketTableHeader(
          itemCount: items.count,
          selectedItemCount: selectedItemCount,
          onToggleSelection: toggleAllItems
        )
        .dropDestination(
          for: String.self,
          action: { values, _ in performDrop(values, at: 0) },
          isTargeted: { targeted in setDropTarget(targeted, index: 0) }
        )

        Divider()

        if items.isEmpty && suggestionBatch == nil {
          VStack(spacing: 7) {
            Image(
              systemName:
                activeDropEvaluation?.isValid == false
                ? "exclamationmark.triangle.fill"
                : (isCandidateSection ? "tray.and.arrow.down" : "text.badge.plus")
            )
            .font(.title2)
            .foregroundStyle(
              activeDropEvaluation?.isValid == false
                ? Color.red : Color.secondary
            )
            Text(
              activeDropEvaluation?.isValid == false
                ? "Can't drop here"
                : (isCandidateSection ? "Drag backlog tickets here" : "No backlog tickets")
            )
            .font(.subheadline.weight(.medium))
            Text(
              activeDropEvaluation?.message
                ?? (isDropTargeted
                  ? "Backlog rank will stay unchanged."
                  : (isCandidateSection
                    ? "Dependencies must be added before the work that relies on them."
                    : "Add a ticket, or create an epic and let AI plan the outcome."))
            )
            .font(.caption)
            .foregroundStyle(
              activeDropEvaluation?.isValid == false
                ? Color.red : Color.secondary
            )
            .multilineTextAlignment(.center)
          }
          .frame(
            maxWidth: .infinity,
            minHeight: 104,
            maxHeight: .infinity,
            alignment: .center
          )
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { targeted in setDropTarget(targeted, index: 0) }
          )
        } else {
          if let suggestionBatch {
            InlineBacklogSuggestions(batch: suggestionBatch)
          }

          ForEach(0...items.count, id: \.self) { index in
            PlanningTicketDropSlot(
              section: section,
              index: index,
              showsRestingDivider: index > 0,
              showsInsertionIndicator: !isNoOpDrop(
                ids: draggedWorkItemIDs,
                at: index
              ),
              evaluation: dropEvaluation(
                ids: draggedWorkItemIDs,
                at: index
              ),
              activeDropTarget: $activeDropTarget,
              onDrop: { values in performDrop(values, at: index) }
            )

            if index < items.count {
              let item = items[index]
              let dragSelection =
                selectedWorkItemIDs.contains(item.id)
                ? selectedWorkItemIDs.intersection(itemIDs)
                : [item.id]
              PlanningTicketRow(
                item: item,
                isCandidate: isCandidateSection,
                isSelected: selectedWorkItemIDs.contains(item.id),
                dragSelection: dragSelection,
                isBeingDragged: draggedWorkItemIDs.contains(item.id),
                dropEvaluation: dropEvaluation(
                  ids: draggedWorkItemIDs,
                  at: index + 1
                ),
                onDragBegan: { onDragBegan(dragSelection) },
                onDrop: { values in performDrop(values, at: index + 1) },
                onDropTargeted: { targeted in setDropTarget(targeted, index: index + 1) },
                onToggleSelection: {
                  if selectedWorkItemIDs.contains(item.id) {
                    selectedWorkItemIDs.remove(item.id)
                  } else {
                    selectedWorkItemIDs.insert(item.id)
                  }
                },
                onOpen: { onOpen(item) }
              )
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(alignment: .top) {
        Rectangle()
          .fill(PlanningDropSurfaceStyle.tableHeaderBackground)
          .frame(height: 32)
      }
      .background(
        isDropTargeted
          ? (activeDropEvaluation?.isValid == false
            ? PlanningDropSurfaceStyle.invalidTargetedBackground
            : PlanningDropSurfaceStyle.targetedBackground)
          : Color.clear
      )
      .background(restingBackground)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(
            Color.secondary.opacity(colorScheme == .dark ? 0.45 : 0.28),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
          )
      }
      .contentShape(Rectangle())
      .dropDestination(
        for: String.self,
        action: { values, _ in performDrop(values, at: items.count) },
        isTargeted: { targeted in setDropTarget(targeted, index: items.count) }
      )
      .animation(.snappy(duration: 0.18), value: isDropTargeted)
      .animation(.snappy(duration: 0.22), value: items.map(\.id))
    }
    .frame(minHeight: minimumHeight, alignment: .top)
  }

  private func toggleAllItems() {
    if allItemsSelected {
      selectedWorkItemIDs.subtract(itemIDs)
    } else {
      selectedWorkItemIDs.formUnion(itemIDs)
    }
  }

  private func performDrop(_ values: [String], at index: Int) -> Bool {
    guard model.canEditCandidateSprint else { return false }
    let ids = Set(
      values.flatMap { payload in
        payload.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
      }
    )
    let movingItems = model.workItems.filter { ids.contains($0.id) }
    guard !movingItems.isEmpty else { return false }
    let safeIndex = min(max(index, 0), items.count)
    if isNoOpDrop(ids: ids, at: safeIndex) {
      onDragCompleted()
      return true
    }
    let targetID = dropTargetID(ids: ids, at: safeIndex)
    let evaluation = model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: isCandidateSection,
      before: targetID
    )
    guard evaluation.isValid else {
      onDragCompleted()
      return true
    }
    model.dropPlanningItems(
      movingItems,
      intoCandidateSprint: isCandidateSection,
      before: targetID
    )
    onDragCompleted()
    return true
  }

  private func setDropTarget(_ targeted: Bool, index: Int) {
    let target = PlanningDropTarget(section: section, index: index)
    withAnimation(.snappy(duration: 0.16)) {
      activeDropTarget = PlanningDropTargetState.updated(
        current: activeDropTarget,
        target: target,
        isTargeted: targeted
      )
    }
  }

  private func dropEvaluation(
    ids: Set<UUID>,
    at index: Int
  ) -> PlanningDropEvaluation? {
    guard !ids.isEmpty else { return nil }
    return model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: isCandidateSection,
      before: dropTargetID(ids: ids, at: index)
    )
  }

  private func dropTargetID(ids: Set<UUID>, at index: Int) -> UUID? {
    let safeIndex = min(max(index, 0), items.count)
    return items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
  }

  private func isNoOpDrop(ids: Set<UUID>, at index: Int) -> Bool {
    guard !ids.isEmpty, ids.isSubset(of: itemIDs) else { return false }

    let safeIndex = min(max(index, 0), items.count)
    let movingItems = items.filter { ids.contains($0.id) }
    var reorderedItems = items.filter { !ids.contains($0.id) }
    let targetID = items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
    let insertionIndex =
      targetID.flatMap { targetID in
        reorderedItems.firstIndex { $0.id == targetID }
      } ?? reorderedItems.endIndex
    reorderedItems.insert(contentsOf: movingItems, at: insertionIndex)

    return reorderedItems.map(\.id) == items.map(\.id)
  }
}

enum PlanningTicketTableLayout {
  static let columnSpacing = PlanningTicketTableMetrics.columnSpacing
  static let selectionWidth = PlanningTicketTableMetrics.selectionWidth
  static let referenceWidth = PlanningTicketTableMetrics.referenceWidth
  static let dependenciesWidth: CGFloat = 76
  static let assigneeWidth = PlanningTicketTableMetrics.assigneeWidth
  static let priorityWidth = PlanningTicketTableMetrics.priorityWidth
}

enum PlanningTicketDropSlotLayout {
  static let dividerHeight: CGFloat = 1

  static func height(showsRestingDivider: Bool) -> CGFloat {
    showsRestingDivider ? dividerHeight : 0
  }
}

struct PlanningTicketTableHeader: View {
  let itemCount: Int
  let selectedItemCount: Int
  let onToggleSelection: () -> Void

  private var selectionSymbol: String {
    if itemCount > 0, selectedItemCount == itemCount {
      return "checkmark.square.fill"
    }
    if selectedItemCount > 0 {
      return "minus.square.fill"
    }
    return "square"
  }

  private var selectionHelp: String {
    itemCount > 0 && selectedItemCount == itemCount
      ? "Deselect all tickets"
      : "Select all tickets"
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: selectionSymbol,
          isActive: selectedItemCount > 0,
          isDisabled: itemCount == 0,
          helpText: selectionHelp,
          action: onToggleSelection
        )
        .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)
        Text("Ticket")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
          .gridColumnAlignment(.leading)
        Text("Dependencies")
          .frame(
            width: PlanningTicketTableLayout.dependenciesWidth,
            alignment: .leading
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .gridColumnAlignment(.leading)
        Text("Assignee")
          .frame(
            width: PlanningTicketTableLayout.assigneeWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .gridColumnAlignment(.center)
        Text("Priority")
          .frame(
            width: PlanningTicketTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
          .gridColumnAlignment(.center)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(height: 32)
    }
    .frame(maxWidth: .infinity)
  }
}

struct PlanningTicketDropSlot: View {
  let section: PlanningDropSection
  let index: Int
  let showsRestingDivider: Bool
  let showsInsertionIndicator: Bool
  let evaluation: PlanningDropEvaluation?
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDrop: ([String]) -> Bool

  private var target: PlanningDropTarget {
    PlanningDropTarget(section: section, index: index)
  }

  private var isActive: Bool {
    showsInsertionIndicator
      && evaluation != nil
      && activeDropTarget == target
  }

  private var indicatorColor: Color {
    evaluation?.isValid == false ? .red : .accentColor
  }

  private var activeLabel: String {
    evaluation?.message ?? "Drop here"
  }

  private var showsValidPosition: Bool {
    showsInsertionIndicator && evaluation?.isValid == true
  }

  var body: some View {
    Color.clear
      .frame(
        height: PlanningTicketDropSlotLayout.height(
          showsRestingDivider: showsRestingDivider
        )
      )
      .overlay {
        if isActive {
          HStack(spacing: 7) {
            Rectangle()
              .fill(indicatorColor)
              .frame(height: 2)
            Label {
              Text(activeLabel)
                .lineLimit(1)
            } icon: {
              Image(
                systemName:
                  evaluation?.isValid == false
                  ? "exclamationmark.triangle.fill" : "circle.fill"
              )
              .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(indicatorColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            Rectangle()
              .fill(indicatorColor)
              .frame(height: 2)
          }
          .padding(.horizontal, 10)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if showsValidPosition {
          HStack(spacing: 5) {
            Circle()
              .fill(Color.accentColor.opacity(0.65))
              .frame(width: 4, height: 4)
            Rectangle()
              .fill(Color.accentColor.opacity(0.48))
              .frame(height: 2)
          }
          .padding(.horizontal, 10)
        } else if showsRestingDivider {
          Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: PlanningTicketDropSlotLayout.dividerHeight)
            .padding(.horizontal, 1)
        }
      }
      .zIndex(isActive ? 10 : (showsValidPosition ? 1 : 0))
      .contentShape(Rectangle())
      .accessibilityLabel(
        isActive
          ? activeLabel
          : (showsValidPosition ? "Valid drop position" : "Ticket separator")
      )
      .help(
        isActive
          ? activeLabel
          : (showsValidPosition ? "Valid drop position" : "")
      )
      .dropDestination(
        for: String.self,
        action: { values, _ in onDrop(values) },
        isTargeted: { targeted in
          withAnimation(.snappy(duration: 0.16)) {
            activeDropTarget = PlanningDropTargetState.updated(
              current: activeDropTarget,
              target: target,
              isTargeted: targeted
            )
          }
        }
      )
      .animation(.snappy(duration: 0.18), value: isActive)
  }
}

struct PlanningTicketRow: View {
  @EnvironmentObject private var model: AppModel
  let item: WorkItem
  let isCandidate: Bool
  let isSelected: Bool
  let dragSelection: Set<UUID>
  let isBeingDragged: Bool
  let dropEvaluation: PlanningDropEvaluation?
  let onDragBegan: () -> Void
  let onDrop: ([String]) -> Bool
  let onDropTargeted: (Bool) -> Void
  let onToggleSelection: () -> Void
  let onOpen: () -> Void
  @State private var confirmingArchive = false
  @State private var isHovering = false

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

  private var sprintItem: SprintItem? {
    model.candidateSprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var epicColor: Color? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var ownerNotificationKind: OwnerNotificationKind? {
    model.ownerNotificationKind(
      productID: item.productID,
      target: OwnerNotificationTarget(kind: .ticket, id: item.id)
    )
  }

  private var assignedImplementer: AgentProfile? {
    guard let ownerID = sprintItem?.implementerProfileID ?? item.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var archiveMenuTitle: AttributedString {
    var title = AttributedString(
      targetItems.count == 1
        ? "Archive ticket…"
        : "Archive \(targetItems.count) tickets…"
    )
    title.foregroundColor = .red
    return title
  }

  private var targetItems: [WorkItem] {
    model.workItems.filter { dragSelection.contains($0.id) }
  }

  private var targetsMultipleTickets: Bool {
    targetItems.count > 1
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: isSelected ? "checkmark.square.fill" : "square",
          isActive: isSelected,
          isDisabled: false,
          helpText: isSelected ? "Deselect ticket" : "Select ticket",
          action: onToggleSelection
        )
        .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)

        HStack(spacing: 8) {
          Image(systemName: item.type.symbolName)
            .foregroundStyle(item.type.tint)
            .frame(width: 16)
          Text(item.key)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: PlanningTicketTableLayout.referenceWidth, alignment: .leading)
          Text(item.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
          if let ownerNotificationKind {
            Circle()
              .fill(ownerNotificationKind.requiresAction ? Color.orange : Color.purple)
              .frame(width: 7, height: 7)
              .accessibilityLabel(
                ownerNotificationKind.requiresAction
                  ? "Needs your input"
                  : "New refinement result"
              )
          }
          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
        .contentShape(Rectangle())

        Group {
          if !activePrerequisites.isEmpty {
            Label(
              activePrerequisites.map(\.key).joined(separator: ", "),
              systemImage: "arrow.turn.down.right"
            )
            .foregroundStyle(.indigo)
            .help(
              "Waiting for \(activePrerequisites.map(\.key).joined(separator: ", "))"
            )
          } else {
            Text("None")
              .foregroundStyle(.tertiary)
          }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(
          width: PlanningTicketTableLayout.dependenciesWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)

        PlanningAssigneeIcon(profile: assignedImplementer)
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)

        SprintPriorityIndicator(priority: item.priority)
          .frame(
            width: PlanningTicketTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
      }
    }
    .frame(minHeight: PlanningTicketTableMetrics.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBackground)
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
          .accessibilityHidden(true)
      }
    }
    .saturation(dropEvaluation?.isValid == false ? 0.2 : 1)
    .opacity(
      isBeingDragged
        ? 0.28
        : (dropEvaluation?.isValid == false ? 0.45 : 1)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .onDrag {
      onDragBegan()
      let payload = dragSelection.map(\.uuidString).sorted().joined(separator: ",")
      return NSItemProvider(object: payload as NSString)
    } preview: {
      PlanningTicketDragPreview(item: item, count: dragSelection.count)
    }
    .dropDestination(
      for: String.self,
      action: { values, _ in onDrop(values) },
      isTargeted: onDropTargeted
    )
    .animation(.easeOut(duration: 0.12), value: dropEvaluation?.isValid)
    .animation(.snappy(duration: 0.18), value: isBeingDragged)
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .help(
      isSelected
        ? "Drag to move all selected tickets between backlog and next sprint"
        : "Open the ticket, select it to drag with other tickets, or drag it to change sprint scope"
    )
    .contextMenu {
      Button(action: onOpen) {
        Label("Open ticket", systemImage: "doc.text.magnifyingglass")
      }
      Button(action: onToggleSelection) {
        Label(
          isSelected ? "Deselect ticket" : "Select ticket",
          systemImage: isSelected ? "checkmark.square.fill" : "square"
        )
      }
      if isCandidate {
        Button {
          model.removeFromCandidateSprint(targetItems)
        } label: {
          Label(
            targetsMultipleTickets ? "Return selected to backlog" : "Return to backlog",
            systemImage: "arrow.uturn.backward"
          )
        }
      } else {
        Button {
          model.addToCandidateSprint(targetItems)
        } label: {
          Label(
            targetsMultipleTickets ? "Add selected to next sprint" : "Add to next sprint",
            systemImage: "calendar.badge.plus"
          )
        }
        .disabled(!model.canEditCandidateSprint)
      }
      Divider()
      Button {
        model.moveWorkItems(targetItems, to: .top)
      } label: {
        Label(
          targetsMultipleTickets ? "Move selected to top" : "Move to top",
          systemImage: "arrow.up.to.line"
        )
      }
      Button {
        model.moveWorkItems(targetItems, to: .bottom)
      } label: {
        Label(
          targetsMultipleTickets ? "Move selected to bottom" : "Move to bottom",
          systemImage: "arrow.down.to.line"
        )
      }
      Divider()
      Button(role: .destructive) {
        confirmingArchive = true
      } label: {
        Label {
          Text(archiveMenuTitle)
        } icon: {
          Image(systemName: "archivebox")
            .foregroundStyle(.red)
        }
      }
      .tint(.red)
    }
    .confirmationDialog(
      targetsMultipleTickets
        ? "Archive \(targetItems.count) tickets?"
        : "Archive \(item.key)?",
      isPresented: $confirmingArchive,
      titleVisibility: .visible
    ) {
      Button(
        targetsMultipleTickets ? "Archive tickets" : "Archive ticket",
        role: .destructive
      ) {
        model.archiveWorkItems(targetItems)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        targetsMultipleTickets
          ? "The tickets leave the backlog but their history remains in the local workspace."
          : "The ticket leaves the backlog but its history remains in the local workspace."
      )
    }
  }

  private var rowBackground: Color {
    if isBeingDragged {
      return Color.accentColor.opacity(0.045)
    }
    if isSelected {
      return Color.accentColor.opacity(0.1)
    }
    if isHovering {
      return Color.accentColor.opacity(0.055)
    }
    return .clear
  }
}

struct PlanningTicketDragPreview: View {
  let item: WorkItem
  let count: Int

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.type.symbolName)
        .foregroundStyle(item.type.tint)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(count == 1 ? item.key : "\(count) tickets")
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text(count == 1 ? item.title : "Move selected work together")
          .font(.callout.weight(.medium))
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 330, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
  }
}

enum ProposedTicketVisualStyle {
  static var surface: Color { .purple.opacity(0.09) }
  static var emphasizedSurface: Color { .purple.opacity(0.14) }
  static var border: Color { .purple.opacity(0.42) }
}

struct TicketSuggestionBatchActions: View {
  @EnvironmentObject private var model: AppModel
  let suggestions: [TicketSuggestion]
  @State private var confirmingDismissal = false

  private var proposedSuggestions: [TicketSuggestion] {
    suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position }
  }

  private var proposalCount: Int {
    proposedSuggestions.count
  }

  var body: some View {
    HStack(spacing: 7) {
      Button("Dismiss all") {
        confirmingDismissal = true
      }
      .buttonStyle(.bordered)

      Button("Accept all") {
        model.decideTicketSuggestionGroup(proposedSuggestions, accept: true)
      }
      .buttonStyle(.borderedProminent)
    }
    .controlSize(.small)
    .disabled(model.isDecidingSuggestions || proposedSuggestions.isEmpty)
    .confirmationDialog(
      "Dismiss all \(proposalCount) proposed tickets?",
      isPresented: $confirmingDismissal,
      titleVisibility: .visible
    ) {
      Button(
        "Dismiss \(proposalCount) \(proposalCount == 1 ? "ticket" : "tickets")",
        role: .destructive
      ) {
        model.decideTicketSuggestionGroup(proposedSuggestions, accept: false)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "They will not enter the backlog. The decisions remain in history and "
          + "inform future suggestions."
      )
    }
  }
}

private func transitiveSuggestionDependents(
  of suggestion: TicketSuggestion,
  in suggestions: [TicketSuggestion]
) -> [TicketSuggestion] {
  var dependentIDs: Set<UUID> = []
  var dependencyFrontier: Set<UUID> = [suggestion.id]
  while !dependencyFrontier.isEmpty {
    let next = suggestions.filter { candidate in
      !dependentIDs.contains(candidate.id)
        && candidate.id != suggestion.id
        && candidate.dependencyIDs.contains(where: dependencyFrontier.contains)
    }
    dependentIDs.formUnion(next.map(\.id))
    dependencyFrontier = Set(next.map(\.id))
  }
  return
    suggestions
    .filter { dependentIDs.contains($0.id) && $0.status != .rejected }
    .sorted { $0.position < $1.position }
}

private func transitiveSuggestedPrerequisites(
  of suggestion: TicketSuggestion,
  in suggestions: [TicketSuggestion]
) -> [TicketSuggestion] {
  let suggestionsByID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.id, $0) })
  var prerequisiteIDs: Set<UUID> = []
  var dependencyFrontier = suggestion.dependencyIDs
  while let dependencyID = dependencyFrontier.popLast() {
    guard
      prerequisiteIDs.insert(dependencyID).inserted,
      let dependency = suggestionsByID[dependencyID]
    else { continue }
    dependencyFrontier.append(contentsOf: dependency.dependencyIDs)
  }
  return
    suggestions
    .filter { prerequisiteIDs.contains($0.id) && $0.status == .proposed }
    .sorted { $0.position < $1.position }
}

struct SuggestionAcceptanceImpact {
  let suggestion: TicketSuggestion
  let prerequisites: [TicketSuggestion]

  var requiresConfirmation: Bool {
    !prerequisites.isEmpty
  }

  var dialogTitle: String {
    "Accept \(suggestion.reference) and its prerequisites?"
  }

  var actionTitle: String {
    let count = prerequisites.count + 1
    return "Accept \(count) \(count == 1 ? "ticket" : "tickets")"
  }

  var buttonTitle: String {
    guard requiresConfirmation else { return "Accept ticket" }
    return "Accept ticket and \(prerequisites.count) "
      + (prerequisites.count == 1 ? "prerequisite…" : "prerequisites…")
  }

  var message: String {
    let references = prerequisites.map(\.reference).joined(separator: ", ")
    return
      "This also accepts \(prerequisites.count) suggested "
      + (prerequisites.count == 1 ? "prerequisite" : "prerequisites")
      + " (\(references)). All \(prerequisites.count + 1) tickets will be added to the "
      + "backlog with their dependency relationships. This does not add them to a sprint."
  }
}

struct SuggestionRejectionImpact {
  let suggestion: TicketSuggestion
  let dependents: [TicketSuggestion]

  var proposedDependentCount: Int {
    dependents.filter { $0.status == .proposed }.count
  }

  var acceptedDependentCount: Int {
    dependents.filter { $0.status == .accepted }.count
  }

  var requiresConfirmation: Bool {
    !dependents.isEmpty
  }

  var dialogTitle: String {
    "Reject \(suggestion.reference) and its dependent work?"
  }

  var actionTitle: String {
    if acceptedDependentCount > 0 {
      return "Reject and archive dependent work"
    }
    let count = proposedDependentCount + 1
    return "Reject \(count) \(count == 1 ? "suggestion" : "suggestions")"
  }

  var message: String {
    var sentences: [String] = []
    if proposedDependentCount > 0 {
      sentences.append(
        "This will also reject \(proposedDependentCount) dependent "
          + (proposedDependentCount == 1 ? "suggestion." : "suggestions.")
      )
    }
    if acceptedDependentCount > 0 {
      sentences.append(
        "It will archive \(acceptedDependentCount) dependent "
          + (acceptedDependentCount == 1
            ? "ticket already added to the backlog."
            : "tickets already added to the backlog.")
      )
    }
    sentences.append("The decisions and archived tickets remain in history.")
    return sentences.joined(separator: " ")
  }
}

struct InlineBacklogSuggestions: View {
  @EnvironmentObject private var model: AppModel
  let batch: TicketSuggestionBatch
  @State private var selectedSuggestion: TicketSuggestion?

  var body: some View {
    Group {
      switch batch.session.status {
      case .generating:
        generatingRows
      case .failed:
        failedRow
      case .ready:
        readyRows
      case .cancelled:
        EmptyView()
      }
    }
    .sheet(item: $selectedSuggestion) { suggestion in
      TicketSuggestionDetailView(
        suggestion: suggestion,
        batch: batch,
        onClose: { selectedSuggestion = nil }
      )
    }
  }

  private var generatingRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Business analyst is generating and ordering ticket suggestions…")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.purple)
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)

      ForEach(0..<3, id: \.self) { index in
        Divider()
        HStack(spacing: 12) {
          Image(systemName: "wand.and.stars")
            .foregroundStyle(.purple.opacity(0.55))
            .frame(width: 24)
          TicketSuggestionPlaceholderLines(
            primaryWidth: index == 1 ? 250 : 340,
            secondaryWidth: index == 2 ? 180 : 270
          )
          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
      Divider()
    }
    .background(.purple.opacity(0.045))
  }

  private var failedRow: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 5) {
        Text("AI ticket suggestions need another try")
          .font(.subheadline.weight(.semibold))
        Text(batch.session.errorMessage ?? "The business analyst could not complete the proposal.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Dismiss") {
        model.dismissFailedTicketSuggestions()
      }
      .buttonStyle(.bordered)
      Button {
        model.retryCurrentEpicPlan()
      } label: {
        Label("Try again", systemImage: "wand.and.stars")
      }
      .buttonStyle(.borderedProminent)
      .tint(.purple)
      .disabled(!model.canPlanEpic)
    }
    .padding(14)
    .background(.orange.opacity(0.055))
  }

  private var readyRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !orderedSuggestions.isEmpty {
        HStack(spacing: 0) {
          Image(systemName: "wand.and.stars")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.purple)
            .frame(
              width: PlanningTicketTableMetrics.selectionWidth,
              height: 32
            )
            .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)
          HStack(spacing: 9) {
            Text("Proposed tickets")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.purple)
            Text(orderedSuggestions.count.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.purple)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.purple.opacity(0.1), in: Capsule())
          }
          .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
          Spacer()
          TicketSuggestionBatchActions(suggestions: orderedSuggestions)
            .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
        }
        .frame(minHeight: 42)
        .background(.purple.opacity(0.055))
        Divider()
      }

      if let sourceTicket {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.branch")
            .foregroundStyle(.purple)
          Text("Follow-up work proposed from \(sourceTicket.key) research")
            .font(.caption.weight(.semibold))
          Spacer()
          Text("Review before adding to the backlog")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)

        .background(.purple.opacity(0.055))
        Divider()
      }
      ForEach(orderedSuggestions) { suggestion in
        InlineTicketSuggestionRow(
          suggestion: suggestion,
          epicID: batch.session.epicID,
          dependencies: relatedSuggestions(for: suggestion.dependencyIDs),
          existingDependencies: suggestion.existingDependencyWorkItemIDs.compactMap { id in
            model.workItems.first { $0.id == id }
          },
          cascadeDependents: transitiveSuggestionDependents(
            of: suggestion,
            in: batch.suggestions
          ),
          cascadePrerequisites: transitiveSuggestedPrerequisites(
            of: suggestion,
            in: batch.suggestions
          ),
          onOpen: { selectedSuggestion = suggestion }
        )
      }
    }
  }

  private var sourceTicket: WorkItem? {
    guard let sourceID = batch.session.sourceWorkItemID else { return nil }
    return model.workItems.first { $0.id == sourceID }
  }

  private var orderedSuggestions: [TicketSuggestion] {
    batch.suggestions.filter { $0.status == .proposed }
      .sorted { lhs, rhs in
        let leftDepth = dependencyDepth(for: lhs, visiting: [])
        let rightDepth = dependencyDepth(for: rhs, visiting: [])
        return leftDepth == rightDepth ? lhs.position < rhs.position : leftDepth < rightDepth
      }
  }

  private func relatedSuggestions(for ids: [UUID]) -> [TicketSuggestion] {
    ids.compactMap { id in batch.suggestions.first { $0.id == id } }
  }

  private func dependencyDepth(
    for suggestion: TicketSuggestion,
    visiting: Set<UUID>
  ) -> Int {
    guard !visiting.contains(suggestion.id) else { return 0 }
    let dependencies = suggestion.dependencyIDs.compactMap { dependencyID in
      batch.suggestions.first { $0.id == dependencyID && $0.status == .proposed }
    }
    guard !dependencies.isEmpty else { return 0 }
    var next = visiting
    next.insert(suggestion.id)
    return 1 + (dependencies.map { dependencyDepth(for: $0, visiting: next) }.max() ?? 0)
  }
}

struct TicketSuggestionPlaceholderLines: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  let primaryWidth: CGFloat
  let secondaryWidth: CGFloat
  @State private var isHighlighted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RoundedRectangle(cornerRadius: 3)
        .fill(.purple.opacity(isHighlighted ? 0.24 : 0.11))
        .frame(width: primaryWidth, height: 10)
      RoundedRectangle(cornerRadius: 3)
        .fill(Color.secondary.opacity(isHighlighted ? 0.19 : 0.09))
        .frame(width: secondaryWidth, height: 8)
    }
    .animation(
      accessibilityReduceMotion
        ? nil
        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
      value: isHighlighted
    )
    .onAppear {
      if !accessibilityReduceMotion {
        isHighlighted = true
      }
    }
  }
}

struct InlineTicketSuggestionRow: View {
  @EnvironmentObject private var model: AppModel
  let suggestion: TicketSuggestion
  let epicID: UUID?
  let dependencies: [TicketSuggestion]
  let existingDependencies: [WorkItem]
  let cascadeDependents: [TicketSuggestion]
  let cascadePrerequisites: [TicketSuggestion]
  let onOpen: () -> Void
  @State private var isHovering = false
  @State private var confirmingCascadeAcceptance = false
  @State private var confirmingCascadeRejection = false

  private var acceptanceImpact: SuggestionAcceptanceImpact {
    SuggestionAcceptanceImpact(
      suggestion: suggestion,
      prerequisites: cascadePrerequisites
    )
  }

  private var rejectionImpact: SuggestionRejectionImpact {
    SuggestionRejectionImpact(
      suggestion: suggestion,
      dependents: cascadeDependents
    )
  }

  private var epicColor: Color? {
    guard let epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var rejectMenuTitle: AttributedString {
    var title = AttributedString("Reject ticket…")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow(alignment: .center) {
        Color.clear
          .frame(
            width: PlanningTicketTableLayout.selectionWidth,
            height: 24
          )
          .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)

        HStack(alignment: .center, spacing: 8) {
          Image(systemName: suggestion.type.symbolName)
            .foregroundStyle(suggestion.type.tint)
            .frame(width: 16)
          Text(suggestion.reference)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.purple)
            .frame(width: PlanningTicketTableLayout.referenceWidth, alignment: .leading)
          Text(suggestion.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.purple : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)

        Group {
          if !blockerKeys.isEmpty {
            Label(
              blockerKeys.joined(separator: ", "),
              systemImage: "arrow.turn.down.right"
            )
            .foregroundStyle(.indigo)
            .help("Waiting for \(blockerKeys.joined(separator: ", "))")
          } else {
            Text("None")
              .foregroundStyle(.tertiary)
          }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(
          width: PlanningTicketTableLayout.dependenciesWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)

        Image(systemName: suggestion.suggestedRole.symbolName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(suggestion.suggestedRole.tint)
          .frame(
            width: PlanningTicketTableLayout.assigneeWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .accessibilityLabel(suggestion.suggestedRole.title)
          .help(suggestion.suggestedRole.title)

        SprintPriorityIndicator(priority: suggestion.priority)
          .frame(
            width: PlanningTicketTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: PlanningTicketTableMetrics.rowHeight)
    .background(
      isHovering
        ? ProposedTicketVisualStyle.emphasizedSurface
        : ProposedTicketVisualStyle.surface
    )
    .overlay(alignment: .bottom) {
      Divider()
    }
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .help("Open suggested ticket details")
    .contextMenu {
      Button {
        if acceptanceImpact.requiresConfirmation {
          confirmingCascadeAcceptance = true
        } else {
          model.decideTicketSuggestion(suggestion, accept: true)
        }
      } label: {
        Label(acceptanceImpact.buttonTitle, systemImage: "checkmark.circle")
      }
      .disabled(model.isDecidingSuggestions)

      Button(role: .destructive) {
        if rejectionImpact.requiresConfirmation {
          confirmingCascadeRejection = true
        } else {
          model.rejectTicketSuggestion(suggestion)
        }
      } label: {
        Label {
          Text(rejectMenuTitle)
        } icon: {
          Image(systemName: "xmark.circle")
            .foregroundStyle(.red)
        }
      }
      .tint(.red)
      .disabled(model.isDecidingSuggestions)
    }
    .confirmationDialog(
      acceptanceImpact.dialogTitle,
      isPresented: $confirmingCascadeAcceptance,
      titleVisibility: .visible
    ) {
      Button(acceptanceImpact.actionTitle) {
        model.decideTicketSuggestion(suggestion, accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(acceptanceImpact.message)
    }
    .confirmationDialog(
      rejectionImpact.dialogTitle,
      isPresented: $confirmingCascadeRejection,
      titleVisibility: .visible
    ) {
      Button(rejectionImpact.actionTitle, role: .destructive) {
        model.rejectTicketSuggestion(suggestion)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectionImpact.message)
    }
  }

  private var blockerKeys: [String] {
    dependencies.map(\.reference) + activeExistingDependencies.map(\.key)
  }

  private var activeExistingDependencies: [WorkItem] {
    existingDependencies.filter { $0.state != .released }
  }
}

struct TicketSuggestionDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.workspaceContainerSize) private var containerSize
  let suggestion: TicketSuggestion
  let batch: TicketSuggestionBatch
  let onClose: () -> Void
  @State private var confirmingCascadeAcceptance = false
  @State private var confirmingCascadeRejection = false

  init(
    suggestion: TicketSuggestion,
    batch: TicketSuggestionBatch,
    onClose: @escaping () -> Void
  ) {
    self.suggestion = suggestion
    self.batch = batch
    self.onClose = onClose
  }

  private var proposedDependencies: [TicketSuggestion] {
    suggestion.dependencyIDs.compactMap { dependencyID in
      batch.suggestions.first { $0.id == dependencyID }
    }
  }

  private var existingDependencies: [WorkItem] {
    suggestion.existingDependencyWorkItemIDs.compactMap { dependencyID in
      model.workItems.first { $0.id == dependencyID }
    }
  }

  private var activeExistingDependencies: [WorkItem] {
    existingDependencies.filter { $0.state != .released }
  }

  private var dependents: [TicketSuggestion] {
    batch.suggestions.filter { $0.dependencyIDs.contains(suggestion.id) }
  }

  private var epic: Epic? {
    guard let epicID = batch.session.epicID else { return nil }
    return model.epics.first {
      $0.id == epicID && $0.productID == batch.session.productID
    }
  }

  private var relationships: [TicketDetailRelationshipGroup] {
    var groups: [TicketDetailRelationshipGroup] = []
    let blockers =
      proposedDependencies.map {
        TicketDetailRelationshipItem(
          id: "suggestion-\($0.id.uuidString)",
          key: $0.reference,
          title: $0.title
        )
      }
      + activeExistingDependencies.map {
        TicketDetailRelationshipItem(
          id: "ticket-\($0.id.uuidString)",
          key: $0.key,
          title: $0.title
        )
      }
    if !blockers.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocked-by",
          title: "Blocked by",
          symbol: "arrow.turn.up.left",
          items: blockers
        )
      )
    }
    if !dependents.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocks",
          title: "Blocks",
          symbol: "link",
          items: dependents.map {
            TicketDetailRelationshipItem(
              id: "suggestion-\($0.id.uuidString)",
              key: $0.reference,
              title: $0.title
            )
          }
        )
      )
    }
    return groups
  }

  private var acceptanceImpact: SuggestionAcceptanceImpact {
    SuggestionAcceptanceImpact(
      suggestion: suggestion,
      prerequisites: transitiveSuggestedPrerequisites(
        of: suggestion,
        in: batch.suggestions
      )
    )
  }

  private var rejectionImpact: SuggestionRejectionImpact {
    SuggestionRejectionImpact(
      suggestion: suggestion,
      dependents: transitiveSuggestionDependents(
        of: suggestion,
        in: batch.suggestions
      )
    )
  }

  private var detailWidth: CGFloat {
    min(900, max(700, containerSize.width - 140))
  }

  private var detailHeight: CGFloat {
    min(780, max(600, containerSize.height - 110))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: suggestion.type.symbolName)
          .foregroundStyle(suggestion.type.tint)
        Text(suggestion.reference)
          .font(.callout.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Ticket details")
          .font(.title2.bold())
        Text("Suggested")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.purple)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.purple.opacity(0.1), in: Capsule())
        Spacer()
        Button("Close", action: onClose)
      }
      .padding(.horizontal, 22)
      .frame(height: 64)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          TicketDetailOverview(
            title: suggestion.title,
            context: suggestion.body,
            emptyContextText: "No additional context was proposed.",
            metadata: [
              TicketDetailMetadataValue(
                id: "status",
                title: "Status",
                value: "Suggested",
                symbol: "wand.and.stars",
                tint: .purple
              ),
              TicketDetailMetadataValue(
                id: "owner",
                title: "Suggested owner",
                value: suggestion.suggestedRole.title,
                symbol: suggestion.suggestedRole.symbolName,
                tint: suggestion.suggestedRole.tint
              ),
              TicketDetailMetadataValue(
                id: "type",
                title: "Type",
                value: suggestion.type.title,
                symbol: suggestion.type.symbolName,
                tint: suggestion.type.tint
              ),
              TicketDetailMetadataValue(
                id: "priority",
                title: "Priority",
                value: suggestion.priority.title,
                symbol: "flag.fill",
                tint: suggestion.priority.tint
              ),
            ],
            epic: epic,
            acceptanceCriteria: suggestion.acceptanceCriteria,
            emptyAcceptanceCriteriaText: "No acceptance criteria proposed",
            relationships: relationships,
            onOpenRelationship: nil
          )

          SprintTicketSectionCard(title: "Why this work") {
            Text(suggestion.rationale)
              .textSelection(.enabled)
          }
        }
        .padding(24)
      }

      Divider()

      HStack {
        Text(
          acceptanceImpact.requiresConfirmation
            ? "Accepting this ticket also accepts its suggested prerequisites."
            : "Nothing enters the backlog until you accept it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Reject", role: .destructive) {
          if rejectionImpact.requiresConfirmation {
            confirmingCascadeRejection = true
          } else {
            rejectSuggestion()
          }
        }
        .disabled(model.isDecidingSuggestions)
        Button(acceptanceImpact.buttonTitle) {
          if acceptanceImpact.requiresConfirmation {
            confirmingCascadeAcceptance = true
          } else {
            acceptSuggestion()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isDecidingSuggestions)
      }
      .padding(.horizontal, 22)
      .frame(height: 64)
    }
    .frame(width: detailWidth, height: detailHeight)
    .confirmationDialog(
      acceptanceImpact.dialogTitle,
      isPresented: $confirmingCascadeAcceptance,
      titleVisibility: .visible
    ) {
      Button(acceptanceImpact.actionTitle) {
        acceptSuggestion()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(acceptanceImpact.message)
    }
    .confirmationDialog(
      rejectionImpact.dialogTitle,
      isPresented: $confirmingCascadeRejection,
      titleVisibility: .visible
    ) {
      Button(rejectionImpact.actionTitle, role: .destructive) {
        rejectSuggestion()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectionImpact.message)
    }
  }

  private func acceptSuggestion() {
    model.decideTicketSuggestion(suggestion, accept: true)
    onClose()
  }

  private func rejectSuggestion() {
    model.rejectTicketSuggestion(suggestion, completion: onClose)
  }
}

struct BacklogSuggestionStack: View {
  @EnvironmentObject private var model: AppModel
  let batch: TicketSuggestionBatch
  @State private var confirmingAcceptAll = false
  @State private var confirmingRejectAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Label(
            sourceTicket.map { "Follow-up work from \($0.key)" } ?? "Suggested work",
            systemImage: "wand.and.stars"
          )
          .font(.headline)
          Text(
            sourceTicket == nil
              ? "One business analyst proposal · roles are planning hints; team members are assigned in sprint planning"
              : "Proposed from approved research · review each ticket before it enters the backlog"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        if batch.session.status == .generating {
          ProgressView()
            .controlSize(.small)
        } else if batch.session.status == .ready {
          HStack(spacing: 7) {
            Text(
              "\(proposedCount) \(proposedCount == 1 ? "suggestion" : "suggestions") to review"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if proposedCount > 1 {
              Button("Reject all") { confirmingRejectAll = true }
                .buttonStyle(.bordered)
                .disabled(model.isDecidingSuggestions)
              Button("Accept all") { confirmingAcceptAll = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDecidingSuggestions)
            }
          }
          .controlSize(.small)
        }
      }

      switch batch.session.status {
      case .generating:
        BusinessAnalystSuggestionProgress()

      case .failed:
        VStack(alignment: .leading, spacing: 10) {
          Label(
            "The business analyst could not finish", systemImage: "exclamationmark.triangle.fill"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
          Text(batch.session.errorMessage ?? "The proposal did not complete.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button {
            model.retryCurrentEpicPlan()
          } label: {
            Label("Try again", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .disabled(!model.canPlanEpic || batch.session.epicID == nil)
        }
        .padding(12)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

      case .ready:
        if orderedSuggestions.isEmpty {
          Label(reviewedSummary, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.vertical, 4)
        } else {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(orderedSuggestions) { suggestion in
              TicketSuggestionCard(
                suggestion: suggestion,
                dependencies: dependencies(for: suggestion),
                dependents: dependents(for: suggestion),
                cascadeDependents: transitiveSuggestionDependents(
                  of: suggestion,
                  in: batch.suggestions
                ),
                cascadePrerequisites: transitiveSuggestedPrerequisites(
                  of: suggestion,
                  in: batch.suggestions
                )
              )
            }
          }
        }

      case .cancelled:
        Text("This proposal was cancelled.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(
          .purple.opacity(0.38),
          style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
        )
    }
    .confirmationDialog(
      "Accept all remaining suggestions?",
      isPresented: $confirmingAcceptAll,
      titleVisibility: .visible
    ) {
      Button(
        "Accept \(proposedCount) \(proposedCount == 1 ? "suggestion" : "suggestions")"
      ) {
        model.decideAllTicketSuggestions(accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "They will be added to the backlog with their dependency relationships. This does not add them to a sprint."
      )
    }
    .confirmationDialog(
      "Reject all remaining suggestions?",
      isPresented: $confirmingRejectAll,
      titleVisibility: .visible
    ) {
      Button(
        "Reject \(proposedCount) \(proposedCount == 1 ? "suggestion" : "suggestions")",
        role: .destructive
      ) {
        model.decideAllTicketSuggestions(accept: false)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectAllMessage)
    }
  }

  private var proposedCount: Int {
    batch.suggestions.filter { $0.status == .proposed }.count
  }

  private var sourceTicket: WorkItem? {
    guard let sourceID = batch.session.sourceWorkItemID else { return nil }
    return model.workItems.first { $0.id == sourceID }
  }

  private var reviewedSummary: String {
    let accepted = batch.suggestions.filter { $0.status == .accepted }.count
    let rejected = batch.suggestions.filter { $0.status == .rejected }.count
    return "Proposal reviewed · \(accepted) added · \(rejected) rejected"
  }

  private var acceptedCascadeTicketCount: Int {
    let acceptedIDs = batch.suggestions
      .filter { $0.status == .proposed }
      .flatMap {
        transitiveSuggestionDependents(of: $0, in: batch.suggestions)
      }
      .filter { $0.status == .accepted }
      .map(\.id)
    return Set(acceptedIDs).count
  }

  private var rejectAllMessage: String {
    if acceptedCascadeTicketCount > 0 {
      return
        "This also archives \(acceptedCascadeTicketCount) dependent "
        + (acceptedCascadeTicketCount == 1
          ? "ticket already added to the backlog. "
          : "tickets already added to the backlog. ")
        + "The decisions and archived tickets remain in history."
    }
    return "The decisions will be retained as feedback for future backlog analysis."
  }

  private var orderedSuggestions: [TicketSuggestion] {
    batch.suggestions.filter { $0.status == .proposed }
      .sorted { lhs, rhs in
        let lhsDepth = dependencyDepth(for: lhs, visiting: [])
        let rhsDepth = dependencyDepth(for: rhs, visiting: [])
        if lhsDepth == rhsDepth {
          return lhs.position < rhs.position
        }
        return lhsDepth < rhsDepth
      }
  }

  private func dependencies(for suggestion: TicketSuggestion) -> [TicketSuggestion] {
    suggestion.dependencyIDs.compactMap { dependencyID in
      batch.suggestions.first { $0.id == dependencyID }
    }
  }

  private func dependents(for suggestion: TicketSuggestion) -> [TicketSuggestion] {
    batch.suggestions.filter { $0.dependencyIDs.contains(suggestion.id) }
  }

  private func dependencyDepth(
    for suggestion: TicketSuggestion,
    visiting: Set<UUID>
  ) -> Int {
    guard !visiting.contains(suggestion.id) else { return 0 }
    let directDependencies = dependencies(for: suggestion)
    guard !directDependencies.isEmpty else { return 0 }
    var nextVisiting = visiting
    nextVisiting.insert(suggestion.id)
    return 1
      + (directDependencies.map {
        dependencyDepth(for: $0, visiting: nextVisiting)
      }.max() ?? 0)
  }
}

struct BusinessAnalystSuggestionProgress: View {
  private let phases = [
    ("Understanding the product outcome", "target"),
    ("Mapping research, design, and delivery work", "square.3.layers.3d"),
    ("Finding dependencies and parallel paths", "point.3.connected.trianglepath.dotted"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
        HStack(spacing: 9) {
          Image(systemName: phase.1)
            .foregroundStyle(.purple)
            .frame(width: 18)
          Text(phase.0)
            .font(.caption)
          Spacer()
          if index == 0 {
            ProgressView()
              .controlSize(.mini)
          }
        }
      }
    }
    .padding(12)
    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct TicketSuggestionCard: View {
  @EnvironmentObject private var model: AppModel
  let suggestion: TicketSuggestion
  let dependencies: [TicketSuggestion]
  let dependents: [TicketSuggestion]
  let cascadeDependents: [TicketSuggestion]
  let cascadePrerequisites: [TicketSuggestion]
  @State private var confirmingCascadeAcceptance = false
  @State private var confirmingCascadeRejection = false

  private var acceptanceImpact: SuggestionAcceptanceImpact {
    SuggestionAcceptanceImpact(
      suggestion: suggestion,
      prerequisites: cascadePrerequisites
    )
  }

  private var rejectionImpact: SuggestionRejectionImpact {
    SuggestionRejectionImpact(
      suggestion: suggestion,
      dependents: cascadeDependents
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(suggestion.reference)
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Label(suggestion.type.title, systemImage: suggestion.type.symbolName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(suggestion.type.tint)
        Label(suggestion.priority.title, systemImage: "flag.fill")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(suggestion.priority.tint)
        Spacer()
        Label(suggestion.suggestedRole.title, systemImage: suggestion.suggestedRole.symbolName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(suggestion.suggestedRole.tint)
      }

      Text(suggestion.title)
        .font(.headline)
        .lineLimit(2)
      Text(suggestion.body)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      if !dependencies.isEmpty || !dependents.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          if !activeDependencies.isEmpty {
            SuggestionRelationshipRow(
              title: "Blocked by",
              references: activeDependencies.map(\.reference),
              symbol: "exclamationmark.octagon",
              tint: .indigo
            )
          }
          if !rejectedDependencies.isEmpty {
            SuggestionRelationshipRow(
              title: "Rejected blocker",
              references: rejectedDependencies.map(\.reference),
              symbol: "exclamationmark.triangle",
              tint: .orange
            )
          }
          if !dependents.isEmpty {
            SuggestionRelationshipRow(
              title: "Blocks",
              references: dependents.map(\.reference),
              symbol: "arrow.right",
              tint: Color(nsColor: .secondaryLabelColor)
            )
          }
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Why this work")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(suggestion.rationale)
          .font(.caption)
          .lineLimit(3)
      }

      Spacer(minLength: 0)
      Divider()
      switch suggestion.status {
      case .proposed:
        HStack(spacing: 8) {
          Spacer()
          Button("Reject") {
            if rejectionImpact.requiresConfirmation {
              confirmingCascadeRejection = true
            } else {
              model.rejectTicketSuggestion(suggestion)
            }
          }
          .buttonStyle(.bordered)
          .disabled(model.isDecidingSuggestions)
          Button(acceptanceImpact.requiresConfirmation ? acceptanceImpact.buttonTitle : "Accept") {
            if acceptanceImpact.requiresConfirmation {
              confirmingCascadeAcceptance = true
            } else {
              model.decideTicketSuggestion(suggestion, accept: true)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isDecidingSuggestions)
        }
      case .accepted:
        Label("Added to backlog", systemImage: "list.bullet.clipboard")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.blue)
      case .rejected:
        Label("Rejected", systemImage: "xmark.circle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      ProposedTicketVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(ProposedTicketVisualStyle.border)
    }
    .opacity(suggestion.status == .rejected ? 0.58 : 1)
    .confirmationDialog(
      acceptanceImpact.dialogTitle,
      isPresented: $confirmingCascadeAcceptance,
      titleVisibility: .visible
    ) {
      Button(acceptanceImpact.actionTitle) {
        model.decideTicketSuggestion(suggestion, accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(acceptanceImpact.message)
    }
    .confirmationDialog(
      rejectionImpact.dialogTitle,
      isPresented: $confirmingCascadeRejection,
      titleVisibility: .visible
    ) {
      Button(rejectionImpact.actionTitle, role: .destructive) {
        model.rejectTicketSuggestion(suggestion)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectionImpact.message)
    }
  }

  private var rejectedDependencies: [TicketSuggestion] {
    dependencies.filter { $0.status == .rejected }
  }

  private var activeDependencies: [TicketSuggestion] {
    dependencies.filter { $0.status != .rejected }
  }
}

struct SuggestionRelationshipRow: View {
  let title: String
  let references: [String]
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 7) {
      Label(title, systemImage: symbol)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
      ForEach(references, id: \.self) { reference in
        Text(reference)
          .font(.caption2.monospaced().weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(tint.opacity(0.1), in: Capsule())
      }
    }
  }
}

struct PlanningHorizon: View {
  let plan: SprintPlan?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Planning horizon")
        .font(.headline)
      PlanningSlot(
        title: "Candidate sprint",
        detail: plan?.sprint.state == .draft
          ? "\(plan?.items.count ?? 0) tickets under review" : "Drop ready work here"
      )
      PlanningSlot(title: "Next", detail: "Proposed scope")
      PlanningSlot(title: "Later", detail: "Not committed")
      Text("Drag-and-drop planning arrives with interactive refinement.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(width: 248)
    .frame(minHeight: 520, alignment: .top)
    .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
  }
}

struct PlanningSlot: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(.separator.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4]))
    }
  }
}
