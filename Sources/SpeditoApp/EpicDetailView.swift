import SpeditoCore
import SwiftUI

struct EpicDetailRefreshPolicy {
  static func shouldSync(
    previous: Epic,
    current: Epic,
    isPlanningComplete: Bool,
    hasUnsavedOwnerChanges: Bool
  ) -> Bool {
    guard isPlanningComplete, !hasUnsavedOwnerChanges else { return false }
    return previous.title != current.title
      || previous.goal != current.goal
      || previous.successCriteria != current.successCriteria
      || previous.constraints != current.constraints
  }
}

struct EpicDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceContainerSize) private var workspaceContainerSize
  let epic: Epic
  let onClose: (() -> Void)?
  @State private var title: String
  @State private var goal: String
  @State private var successCriteria: [EpicDetailItemDraft]
  @State private var constraints: [EpicDetailItemDraft]
  @State private var isSaving = false
  @State private var didStartPlanning = false
  @State private var selectedTicket: WorkItem?
  @State private var selectedSuggestion: TicketSuggestion?

  init(
    epic: Epic,
    onClose: (() -> Void)? = nil
  ) {
    self.epic = epic
    self.onClose = onClose
    _title = State(initialValue: epic.title)
    _goal = State(initialValue: epic.goal)
    _successCriteria = State(
      initialValue: epic.successCriteria.map(EpicDetailItemDraft.init(text:))
    )
    _constraints = State(
      initialValue: Self.itemDrafts(from: epic.constraints)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "flag.checkered")
          .foregroundStyle(.purple)
        Text("Epic details")
          .font(.title2.bold())
          .accessibilityIdentifier("epic.detail.\(epic.id.uuidString)")
        Spacer()
        Button("Done", action: close)
          .accessibilityIdentifier("epic.done")
      }
      .padding(22)
      Divider()

      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if latestEpic.hasAnalyzedMetadata {
              HStack(alignment: .top, spacing: 16) {
                EditableTextField(title: "Title", prompt: "Epic title", text: $title)
                  .disabled(isReadOnly)
                statusSummary
              }
            } else {
              statusSummary
            }
            EditableTextArea(
              title:
                latestEpic.hasAnalyzedMetadata
                ? "Goal and customer value"
                : "Requested outcome",
              prompt: "What outcome should this epic create?",
              text: $goal,
              minHeight: 110,
              isReadOnly: isReadOnly
            )
            if latestEpic.hasAnalyzedMetadata {
              EpicDetailItemsEditor(
                title: "Success criteria",
                guidance: "Each item should describe one measurable product outcome.",
                addLabel: "Add criterion",
                firstItemLabel: "Add the first success criterion",
                itemPrompt: "Describe a measurable outcome",
                systemImage: "checklist",
                items: $successCriteria
              )
              .disabled(isReadOnly)
              EpicDetailItemsEditor(
                title: "Constraints and context",
                guidance:
                  "Capture each material constraint, assumption, or relevant fact separately.",
                addLabel: "Add item",
                firstItemLabel: "Add the first constraint or context item",
                itemPrompt: "Describe a constraint, assumption, or relevant fact",
                systemImage: "slider.horizontal.3",
                items: $constraints
              )
              .disabled(isReadOnly)
            } else {
              Label(
                "The business analyst will propose the title, goal, success criteria, constraints, and tickets for review.",
                systemImage: "wand.and.stars"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            EpicTicketsSection(
              epic: latestEpic,
              tickets: activeEpicTickets,
              archivedCount: archivedEpicTicketCount,
              suggestionBatch: epicSuggestionBatch,
              isGeneratingSuggestions:
                conversation?.isGeneratingPlan == true
                || epicSuggestionBatch?.session.status == .generating,
              onOpen: { selectedTicket = $0 },
              onOpenSuggestion: { selectedSuggestion = $0 }
            )
          }
          .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        EpicPlanningConversationPanel(epic: latestEpic)
          .frame(width: conversationWidth)
          .frame(maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
      .clipped()

      Divider()
      HStack {
        Text(footerStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if isClosed {
          Button {
            reopenEpic()
          } label: {
            Label(
              isSaving ? "Reopening…" : "Reopen epic",
              systemImage: "arrow.uturn.backward.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSaving)
          .help("Return this epic to active planning")
        } else if canCloseEpic {
          Button {
            confirmCloseEpic()
          } label: {
            Label(
              isSaving
                ? "Completing…"
                : (hasUnsavedChanges ? "Save and complete epic" : "Complete epic"),
              systemImage: "checkmark.circle.fill"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSaving || (hasUnsavedChanges && !canSave))
          .help("Confirm the outcome and move this epic to read-only delivery history")
        } else if hasUnsavedChanges {
          Button("Save") { save() }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
        } else if !proposedEpicSuggestions.isEmpty {
          Button("Review tickets in backlog") {
            close()
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(18)
    }
    .background(InitialFocusClearer())
    .frame(width: detailSize.width, height: detailSize.height)
    .task(id: epic.id) {
      await model.setOwnerNotificationTargetVisible(
        productID: epic.productID,
        target: OwnerNotificationTarget(kind: .epic, id: epic.id)
      )
      await model.restoreEpicPlanningConversation(for: epic)
      startPlanningIfNeeded()
    }
    .onChange(of: model.canPlanEpic) { _, _ in
      startPlanningIfNeeded()
    }
    .onChange(of: conversation?.isComplete == true) { _, isComplete in
      guard isComplete else { return }
      syncFromLatestEpic()
    }
    .onChange(of: latestEpic) { previous, current in
      guard
        EpicDetailRefreshPolicy.shouldSync(
          previous: previous,
          current: current,
          isPlanningComplete: conversation?.isComplete == true,
          hasUnsavedOwnerChanges: hasUnsavedChanges(comparedTo: previous)
        )
      else { return }
      syncFromLatestEpic()
    }
    .onDisappear {
      model.clearOwnerNotificationTargetVisible(
        productID: epic.productID,
        target: OwnerNotificationTarget(kind: .epic, id: epic.id)
      )
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
    .sheet(item: $selectedSuggestion) { suggestion in
      if let batch = epicSuggestionBatch {
        TicketSuggestionDetailView(
          suggestion: suggestion,
          batch: batch,
          onClose: { selectedSuggestion = nil }
        )
      }
    }
  }

  private var conversation: EpicPlanningConversationState? {
    guard model.epicPlanningConversation?.epicID == epic.id else { return nil }
    return model.epicPlanningConversation
  }

  private var detailSize: CGSize {
    ConversationDetailSheetSizing.size(for: workspaceContainerSize)
  }

  private var conversationWidth: CGFloat {
    ConversationDetailSheetSizing.conversationWidth(for: detailSize.width)
  }

  private var needsInitialPlanning: Bool {
    conversation?.hasStartedPlanning != true
      && !latestEpic.hasAnalyzedMetadata
      && activeEpicTickets.isEmpty
      && proposedEpicSuggestions.isEmpty
  }

  private var canSave: Bool {
    isOpen
      && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (!latestEpic.hasAnalyzedMetadata
        || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private var latestEpic: Epic {
    model.epics.first(where: { $0.id == epic.id }) ?? epic
  }

  private var isArchived: Bool {
    latestEpic.status == .archived
  }

  private var isClosed: Bool {
    latestEpic.status == .closed
  }

  private var isOpen: Bool {
    latestEpic.status == .open
  }

  private var isReadOnly: Bool {
    !isOpen
  }

  private var progress: EpicProgress {
    EpicProgress(tickets: activeEpicTickets)
  }

  private var statusSummary: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Status")
        .font(.subheadline.weight(.semibold))
      Text(displayStatus)
        .font(.callout.weight(.semibold))
        .foregroundStyle(displayStatusColor)
        .padding(.vertical, 5)
    }
    .frame(width: 130, alignment: .leading)
  }

  private var displayStatus: String {
    isOpen ? progress.title : latestEpic.status.title
  }

  private var displayStatusColor: Color {
    switch latestEpic.status {
    case .closed:
      return .green
    case .archived:
      return .secondary
    case .open:
      switch progress {
      case .created: return .secondary
      case .planned: return .blue
      case .inProgress: return .orange
      case .complete: return .green
      }
    }
  }

  private var hasUnsavedChanges: Bool {
    title != latestEpic.title
      || goal != latestEpic.goal
      || criteria != latestEpic.successCriteria
      || constraintsText != latestEpic.constraints
  }

  private func hasUnsavedChanges(comparedTo epic: Epic) -> Bool {
    title != epic.title
      || goal != epic.goal
      || criteria != epic.successCriteria
      || constraintsText != epic.constraints
  }

  private var criteria: [String] {
    successCriteria
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var constraintsText: String {
    constraints
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private var epicSuggestionBatch: TicketSuggestionBatch? {
    guard model.suggestionBatch?.session.epicID == epic.id else { return nil }
    return model.suggestionBatch
  }

  private var proposedEpicSuggestions: [TicketSuggestion] {
    epicSuggestionBatch?.suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position } ?? []
  }

  private var canCloseEpic: Bool {
    isOpen
      && progress == .complete
      && proposedEpicSuggestions.isEmpty
      && conversation?.isRunning != true
      && conversation?.isGeneratingPlan != true
      && epicSuggestionBatch?.session.status != .generating
  }

  private var footerStatus: String {
    if isArchived {
      return "This archived epic is available as read-only delivery history."
    }
    if isClosed {
      return "The epic outcome is confirmed and available as read-only delivery history."
    }
    if conversation?.isRunning == true
      || conversation?.isGeneratingPlan == true
      || epicSuggestionBatch?.session.status == .generating
    {
      return "The business analyst is preparing the proposed ticket plan."
    }
    if progress == .complete, !proposedEpicSuggestions.isEmpty {
      return
        "All accepted tickets are delivered. Review the remaining proposals before completing the epic."
    }
    if progress == .complete {
      return
        "All accepted tickets are delivered. Completing the epic confirms the outcome and moves it to read-only delivery history."
    }
    let count = proposedEpicSuggestions.count
    if count > 0 {
      return "\(count) proposed \(count == 1 ? "ticket needs" : "tickets need") review in tickets."
    }
    if conversation?.isComplete == true {
      return "The epic plan is up to date."
    }
    switch progress {
    case .created:
      return "Resolve the outcome with the business analyst before tickets are proposed."
    case .planned:
      return "Tickets are planned and delivery has not started."
    case .inProgress:
      return "Delivery is in progress."
    case .complete:
      return
        "All accepted tickets are delivered. Completing the epic confirms the outcome and moves it to read-only delivery history."
    }
  }

  private var activeEpicTickets: [WorkItem] {
    model.workItems.filter {
      $0.epicID == epic.id && $0.state != .cancelled
    }
  }

  private var archivedEpicTicketCount: Int {
    model.workItems.filter {
      $0.epicID == epic.id && $0.state == .cancelled
    }.count
  }

  private func close() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  private func startPlanningIfNeeded() {
    guard
      !didStartPlanning,
      isOpen,
      needsInitialPlanning,
      model.canPlanEpic
    else { return }
    didStartPlanning = true
    model.planEpic(latestEpic)
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    Task {
      let updated = await model.updateEpic(
        epic,
        title: title,
        goal: goal,
        successCriteria: criteria,
        constraints: constraintsText
      )
      isSaving = false
      if updated != nil {
        close()
      }
    }
  }

  private func confirmCloseEpic() {
    guard canCloseEpic else { return }
    isSaving = true
    Task {
      var epicToClose: Epic? = latestEpic
      if hasUnsavedChanges {
        epicToClose = await model.updateEpic(
          epic,
          title: title,
          goal: goal,
          successCriteria: criteria,
          constraints: constraintsText
        )
      }
      let updated: Epic? =
        if let epicToClose {
          await model.closeEpic(epicToClose)
        } else {
          nil
        }
      isSaving = false
      if updated != nil {
        close()
      }
    }
  }

  private func reopenEpic() {
    guard isClosed else { return }
    isSaving = true
    Task {
      let updated = await model.reopenEpic(latestEpic)
      isSaving = false
      if updated != nil {
        syncFromLatestEpic()
      }
    }
  }

  private func syncFromLatestEpic() {
    guard let latest = model.epics.first(where: { $0.id == epic.id }) else { return }
    title = latest.title
    goal = latest.goal
    successCriteria = latest.successCriteria.map(EpicDetailItemDraft.init(text:))
    constraints = Self.itemDrafts(from: latest.constraints)
  }

  private static func itemDrafts(from text: String) -> [EpicDetailItemDraft] {
    text
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(EpicDetailItemDraft.init(text:))
  }

}

struct EpicTicketsSection: View {
  @EnvironmentObject private var model: AppModel
  let epic: Epic
  let tickets: [WorkItem]
  let archivedCount: Int
  let suggestionBatch: TicketSuggestionBatch?
  let isGeneratingSuggestions: Bool
  let onOpen: (WorkItem) -> Void
  let onOpenSuggestion: (TicketSuggestion) -> Void
  @State private var hoveredTicketID: UUID?
  @State private var hoveredSuggestionID: UUID?

  private var deliveredCount: Int {
    tickets.filter { $0.state == .released }.count
  }

  private var allDelivered: Bool {
    !tickets.isEmpty && deliveredCount == tickets.count
  }

  private var proposedSuggestions: [TicketSuggestion] {
    suggestionBatch?.suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position } ?? []
  }

  private var visibleTicketCount: Int {
    tickets.count + proposedSuggestions.count
  }

  private let statusColumnWidth: CGFloat = 108
  private let ownerColumnWidth: CGFloat = 128
  private let tableRowHeight = PlanningTicketTableMetrics.rowHeight

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Text("Tickets")
          .font(.headline)
        Text(visibleTicketCount.formatted())
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        if archivedCount > 0 {
          Text("\(archivedCount) archived")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !proposedSuggestions.isEmpty {
          TicketSuggestionBatchActions(suggestions: proposedSuggestions)
        } else if allDelivered {
          Label(
            epic.status == .closed ? "Outcome confirmed" : "Ready to complete",
            systemImage: "checkmark.circle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
        } else if !tickets.isEmpty {
          Text("\(deliveredCount) of \(tickets.count) delivered")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Text("Ticket")
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("Status")
            .padding(.horizontal, 8)
            .frame(width: statusColumnWidth, alignment: .leading)
          Text("Owner")
            .padding(.horizontal, 8)
            .frame(width: ownerColumnWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: 32)

        Divider()

        if isGeneratingSuggestions && proposedSuggestions.isEmpty {
          ForEach(0..<3, id: \.self) { index in
            proposedTicketPlaceholder(index: index)
            if index < 2 {
              Divider()
            }
          }
        } else if tickets.isEmpty && proposedSuggestions.isEmpty {
          VStack(spacing: 5) {
            Text(archivedCount > 0 ? "No active tickets" : "No tickets yet")
              .font(.subheadline.weight(.medium))
            Text(
              archivedCount > 0
                ? "Archived tickets no longer count towards this epic."
                : "The business analyst can propose the work needed for this outcome."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 74)
        } else {
          ForEach(Array(proposedSuggestions.enumerated()), id: \.element.id) {
            index,
            suggestion in
            proposedTicketRow(suggestion)
            if index < proposedSuggestions.count - 1 || !tickets.isEmpty {
              Divider()
            }
          }

          ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
            ticketRow(ticket)
            if index < tickets.count - 1 {
              Divider()
            }
          }
        }
      }
      .background(Color.secondary.opacity(0.035))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
      }

      if allDelivered, epic.status == .open {
        Text(
          "All accepted tickets are delivered. Confirm the product outcome, then complete this epic."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func proposedTicketPlaceholder(index: Int) -> some View {
    HStack(spacing: 0) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.mini)
          .tint(.purple)
        TicketSuggestionPlaceholderLines(
          primaryWidth: index == 1 ? 150 : 190,
          secondaryWidth: index == 2 ? 100 : 130
        )
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      Text("Preparing")
        .padding(.horizontal, 8)
        .foregroundStyle(.purple)
        .frame(width: statusColumnWidth, alignment: .leading)

      Text("Business analyst")
        .padding(.horizontal, 8)
        .foregroundStyle(.secondary)
        .frame(width: ownerColumnWidth, alignment: .leading)
    }
    .font(.caption)
    .frame(minHeight: tableRowHeight)
  }

  private func proposedTicketRow(_ suggestion: TicketSuggestion) -> some View {
    let isHovering = hoveredSuggestionID == suggestion.id
    return HStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: suggestion.type.symbolName)
          .foregroundStyle(suggestion.type.tint)
          .frame(width: 16)
        Text(suggestion.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isHovering ? Color.purple : Color.primary)
          .lineLimit(2)
          .layoutPriority(1)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      Label("Proposed", systemImage: "wand.and.stars")
        .font(.caption.weight(.medium))
        .foregroundStyle(.purple)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: statusColumnWidth, alignment: .leading)

      Label(suggestion.suggestedRole.title, systemImage: suggestion.suggestedRole.symbolName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(suggestion.suggestedRole.tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: ownerColumnWidth, alignment: .leading)
    }
    .frame(minHeight: tableRowHeight)
    .background(
      isHovering
        ? ProposedTicketVisualStyle.emphasizedSurface
        : ProposedTicketVisualStyle.surface
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onOpenSuggestion(suggestion)
    }
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredSuggestionID = hovering ? suggestion.id : nil
      }
    }
    .help("Open suggested ticket details")
  }

  private func ticketRow(_ ticket: WorkItem) -> some View {
    let isHovering = hoveredTicketID == ticket.id
    return HStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: ticket.type.symbolName)
          .foregroundStyle(ticket.type.tint)
          .frame(width: 16)
        Text(ticket.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
          .lineLimit(2)
          .layoutPriority(1)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(statusTitle(for: ticket))
        .font(.caption.weight(.medium))
        .foregroundStyle(statusColor(for: ticket))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: statusColumnWidth, alignment: .leading)

      ownerLabel(for: ticket)
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(width: ownerColumnWidth, alignment: .leading)
    }
    .frame(minHeight: tableRowHeight)
    .background(
      isHovering ? Color.accentColor.opacity(0.055) : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onOpen(ticket)
    }
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredTicketID = hovering ? ticket.id : nil
      }
    }
    .help("Open \(ticket.key) · \(ticket.title)")
  }

  private func owner(for ticket: WorkItem) -> AgentProfile? {
    guard let ownerID = ticket.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  @ViewBuilder
  private func ownerLabel(for ticket: WorkItem) -> some View {
    if let owner = owner(for: ticket) {
      Label(owner.name, systemImage: owner.role.symbolName)
        .foregroundStyle(owner.role.tint)
        .lineLimit(1)
    } else {
      Text("Unassigned")
        .foregroundStyle(.secondary)
    }
  }

  private func statusTitle(for ticket: WorkItem) -> String {
    switch ticket.state {
    case .queued: "Ready to pick"
    case .running: "In progress"
    case .integrating, .verifying, .readyToRelease: "In review"
    case .acceptance: "Ready for demo"
    case .released: "Done"
    default: ticket.state.title
    }
  }

  private func statusColor(for ticket: WorkItem) -> Color {
    switch ticket.state {
    case .released: .green
    case .running: .blue
    case .integrating, .verifying, .readyToRelease: .indigo
    case .acceptance: .purple
    default: .secondary
    }
  }
}

enum EpicPlanningConversationTimeline {
  static func pendingQuestionMessageID(
    in messages: [EpicPlanningConversationMessage],
    questions: [TicketRefinementQuestion]
  ) -> UUID? {
    guard !questions.isEmpty else { return nil }
    return messages.last(where: {
      $0.author == .businessAnalyst
        && $0.kind != .chat
        && $0.answeredQuestions.isEmpty
    })?.id
  }

  static func shouldAutoScroll(
    from previousTarget: ConversationTimelineScrollTarget?,
    to target: ConversationTimelineScrollTarget?,
    messages: [EpicPlanningConversationMessage]
  ) -> Bool {
    guard let target else { return false }
    guard
      case .questions = previousTarget,
      case .message(let messageID) = target,
      let message = messages.last(where: { $0.id == messageID })
    else { return true }
    return message.author != .owner || message.answeredQuestions.isEmpty
  }
}

enum EpicPlanningAnswerSubmission {
  static let otherChoice = "__other__"

  static func canSubmit(
    questions: [TicketRefinementQuestion],
    selectedOptions: [Int: String],
    otherAnswers: [Int: String]
  ) -> Bool {
    questions.indices.allSatisfy { index in
      guard let option = selectedOptions[index] else { return false }
      if option == otherChoice {
        return !(otherAnswers[index] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return true
    }
  }

  static func answeredQuestions(
    questions: [TicketRefinementQuestion],
    selectedOptions: [Int: String],
    otherAnswers: [Int: String]
  ) -> [EpicPlanningAnsweredQuestion] {
    questions.indices.map { index in
      let selection = selectedOptions[index] ?? ""
      let answer =
        selection == otherChoice
        ? (otherAnswers[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        : selection
      return EpicPlanningAnsweredQuestion(
        question: questions[index],
        selectedOption: selection == otherChoice ? nil : selection,
        answer: answer
      )
    }
  }
}

struct EpicPlanningConversationPanel: View {
  @EnvironmentObject private var model: AppModel
  let epic: Epic
  @State private var selectedOptions: [Int: String] = [:]
  @State private var otherAnswers: [Int: String] = [:]
  @State private var message = ""
  @State private var recipientID: UUID?
  @State private var isSending = false
  @State private var respondingRecipientID: UUID?
  @State private var sendError: String?

  private let otherChoice = EpicPlanningAnswerSubmission.otherChoice

  private var conversation: EpicPlanningConversationState? {
    guard model.epicPlanningConversation?.epicID == epic.id else { return nil }
    return model.epicPlanningConversation
  }

  private var analyst: AgentProfile? {
    model.profiles.first { $0.role == .businessAnalyst }
  }

  private var selectedRecipient: AgentProfile? {
    guard let recipientID else { return nil }
    return model.profiles.first { $0.id == recipientID }
  }

  private var respondingRecipient: AgentProfile? {
    let activeRecipientID =
      respondingRecipientID
      ?? (model.epicConversationEpicID == epic.id
        ? model.epicConversationRecipientID
        : nil)
    guard let activeRecipientID else { return nil }
    return model.profiles.first { $0.id == activeRecipientID }
  }

  private var defaultRecipient: AgentProfile? {
    analyst
      ?? model.profiles.first { $0.role == .lead }
      ?? model.profiles.first
  }

  private var isPlanningResponding: Bool {
    conversation?.isRunning == true || conversation?.isGeneratingPlan == true
  }

  private var isChatResponding: Bool {
    respondingRecipient != nil
  }

  private var isAnyAgentResponding: Bool {
    isPlanningResponding || isChatResponding
  }

  private var tint: Color {
    analyst?.role.tint ?? .purple
  }

  private var showsEmptyConversation: Bool {
    guard let conversation else { return true }
    return conversation.messages.isEmpty && conversation.questions.isEmpty
  }

  private var pendingQuestionMessageID: UUID? {
    guard let conversation else { return nil }
    return EpicPlanningConversationTimeline.pendingQuestionMessageID(
      in: conversation.messages,
      questions: conversation.questions
    )
  }

  private var pendingQuestionInsertionIndex: Int? {
    guard
      let conversation,
      let pendingQuestionMessageID,
      let messageIndex = conversation.messages.firstIndex(where: {
        $0.id == pendingQuestionMessageID
      })
    else { return nil }
    return conversation.messages.index(after: messageIndex)
  }

  private var latestScrollTarget: ConversationTimelineScrollTarget? {
    guard let conversation else { return nil }
    return ConversationTimelineScrollTarget.latest(
      scopeID: epic.id,
      lastMessageID: conversation.messages.last?.id,
      messageCount: conversation.messages.count,
      questions: conversation.questions,
      pendingQuestionInsertionIndex: pendingQuestionInsertionIndex
    )
  }

  var body: some View {
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
            if let conversation {
              ForEach(conversation.messages) { message in
                Group {
                  if message.answeredQuestions.isEmpty {
                    messageRow(message)
                  } else {
                    answeredQuestionCards(message.answeredQuestions)
                  }
                }
                .id(ConversationTimelineScrollTarget.message(message.id))
                if message.id == pendingQuestionMessageID {
                  questionCards(conversation.questions)
                }
              }
              if !conversation.questions.isEmpty,
                pendingQuestionMessageID == nil
              {
                questionCards(conversation.questions)
              }
            }
            Color.clear
              .frame(height: 1)
              .padding(.bottom, 14)
          }
          .padding(.horizontal, 14)
          .padding(.top, 14)
        }
        .overlay {
          if showsEmptyConversation {
            ConversationEmptyState(
              detail: "Ask any team member about this epic."
            )
          }
        }
        .onChange(of: latestScrollTarget, initial: true) { previousTarget, target in
          guard
            EpicPlanningConversationTimeline.shouldAutoScroll(
              from: previousTarget,
              to: target,
              messages: conversation?.messages ?? []
            )
          else { return }
          scrollConversation(proxy, to: target)
        }
      }
      .frame(maxHeight: .infinity)

      Divider()
      conversationStatus
      if isChatResponding {
        ConversationRespondingStatus(
          profile: respondingRecipient,
          fallbackName: "Team member",
          status: "is thinking…",
          onStop: model.cancelEpicConversationMessage
        )
      }
      if epic.status == .open {
        TeamConversationComposer(
          profiles: model.profiles,
          recipientID: $recipientID,
          message: $message,
          isSending: isSending,
          isResponding: isAnyAgentResponding,
          sendError: sendError,
          onSend: send
        )
      }
    }
    .frame(maxHeight: .infinity)
    .clipped()
    .onChange(of: conversation?.questions ?? []) { _, _ in
      selectedOptions.removeAll()
      otherAnswers.removeAll()
    }
    .task(id: epic.id) {
      if recipientID == nil {
        recipientID = defaultRecipient?.id
      }
    }
  }

  @ViewBuilder
  private var conversationStatus: some View {
    if let conversation {
      if conversation.isRunning || conversation.isGeneratingPlan {
        ConversationRespondingStatus(
          profile: analyst,
          fallbackName: "Business analyst",
          status:
            conversation.isGeneratingPlan
            ? "is preparing the epic and tickets…"
            : "is thinking…",
          onStop: model.cancelEpicPlanning
        )
      } else if !conversation.questions.isEmpty {
        HStack {
          Text("\(analyst?.name ?? "Business analyst") is waiting for your response.")
            .font(.caption)
            .foregroundStyle(.primary)
          Spacer()
          Button {
            submitAnswers(conversation.questions)
          } label: {
            Label("Submit answers", systemImage: "paperplane.fill")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
          .disabled(!canSubmit(conversation.questions) || isAnyAgentResponding)
          .accessibilityIdentifier("epic.submit-answers")
        }
        .padding(14)
        .background(tint.opacity(0.075))
      } else if let error = conversation.errorMessage {
        VStack(alignment: .leading, spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
          Button {
            model.retryEpicPlanning(epic)
          } label: {
            Label("Try again", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
        }
        .padding(14)
      }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: EpicPlanningConversationMessage) -> some View {
    let isOwner = message.author == .owner
    let profile = profile(for: message)
    let accent = message.author == .system ? Color.secondary : profile?.role.tint ?? tint
    let displayName =
      switch message.author {
      case .owner: "Me"
      case .businessAnalyst: analyst?.name ?? "Business analyst"
      case .agent: message.participantName ?? profile?.name ?? "Team member"
      case .system: "Spedito"
      }
    let symbolName =
      message.author == .system
      ? "gearshape.fill"
      : profile?.role.symbolName ?? "sparkles"
    HStack(alignment: .top, spacing: 8) {
      if isOwner { Spacer(minLength: 46) }
      if !isOwner {
        Circle()
          .fill(accent.opacity(0.12))
          .overlay {
            Image(systemName: symbolName)
              .font(.caption)
              .foregroundStyle(accent)
          }
          .frame(width: 28, height: 28)
      }
      VStack(alignment: isOwner ? .trailing : .leading, spacing: 4) {
        Text(displayName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(isOwner ? Color.primary : accent)
        Text(message.body)
          .font(.callout)
          .textSelection(.enabled)
          .padding(.horizontal, 11)
          .padding(.vertical, 9)
          .background(
            isOwner ? ConversationPalette.owner.opacity(0.1) : accent.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 11)
          )
      }
      if isOwner {
        Circle()
          .fill(ConversationPalette.owner.opacity(0.12))
          .overlay {
            Image(systemName: "person.fill")
              .font(.caption)
              .foregroundStyle(ConversationPalette.owner)
          }
          .frame(width: 28, height: 28)
      } else {
        Spacer(minLength: 46)
      }
    }
  }

  private func profile(
    for message: EpicPlanningConversationMessage
  ) -> AgentProfile? {
    if let participantID = message.participantID,
      let profile = model.profiles.first(where: { $0.id == participantID })
    {
      return profile
    }
    if let participantName = message.participantName,
      let profile = model.profiles.first(where: { $0.name == participantName })
    {
      return profile
    }
    return message.author == .businessAnalyst ? analyst : nil
  }

  private func questionCards(_ questions: [TicketRefinementQuestion]) -> some View {
    MultipleChoiceQuestionCards(
      questions: questions,
      selectedOptions: $selectedOptions,
      otherAnswers: $otherAnswers,
      otherChoiceKey: otherChoice,
      tint: tint,
      accessibilityPrefix: "epic"
    )
    .id(ConversationTimelineScrollTarget.questions(epic.id, questions))
  }

  private func answeredQuestionCards(
    _ answeredQuestions: [EpicPlanningAnsweredQuestion]
  ) -> some View {
    MultipleChoiceQuestionCards(
      answeredQuestions: answeredQuestions,
      tint: tint,
      accessibilityPrefix: "epic"
    )
  }

  private func send() {
    let ownerMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let recipient = selectedRecipient,
      !ownerMessage.isEmpty,
      !isSending,
      !isAnyAgentResponding
    else { return }
    isSending = true
    respondingRecipientID = recipient.id
    sendError = nil
    message = ""
    Task {
      do {
        _ = try await model.sendEpicConversationMessage(
          for: epic,
          to: recipient,
          ownerMessage: ownerMessage
        )
      } catch {
        sendError = error.localizedDescription
      }
      respondingRecipientID = nil
      isSending = false
    }
  }

  private func canSubmit(_ questions: [TicketRefinementQuestion]) -> Bool {
    EpicPlanningAnswerSubmission.canSubmit(
      questions: questions,
      selectedOptions: selectedOptions,
      otherAnswers: otherAnswers
    )
  }

  private func submitAnswers(_ questions: [TicketRefinementQuestion]) {
    guard canSubmit(questions), !isAnyAgentResponding else { return }
    let answeredQuestions = EpicPlanningAnswerSubmission.answeredQuestions(
      questions: questions,
      selectedOptions: selectedOptions,
      otherAnswers: otherAnswers
    )
    let answers = answeredQuestions.map {
      "\($0.question.prompt)\nAnswer: \($0.answer)"
    }
    model.continueEpicPlanning(
      epic,
      answers: answers,
      answeredQuestions: answeredQuestions
    )
  }
}
