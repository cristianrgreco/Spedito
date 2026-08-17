import SpeditoCore
import SwiftUI

struct RetrospectivesView: View {
  @EnvironmentObject private var model: AppModel
  let onShowBacklog: () -> Void
  let onOpenRefiningTicket: (WorkItem) -> Void
  @State private var selectedSprintID: UUID?
  @State private var isConcluding = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Retrospectives")
            .font(.largeTitle.bold())
          Text("Review what the team learned and decide what should change next.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !availablePlans.isEmpty {
          Picker("Sprint", selection: selectedSprintBinding) {
            ForEach(availablePlans, id: \.sprint.id) { plan in
              let phase = RetrospectivePhase(sprint: plan.sprint)
              Text("Sprint \(plan.sprint.number) · \(phase.pickerTitle)")
                .tag(plan.sprint.id)
            }
          }
          .labelsHidden()
          .frame(width: 230, alignment: .trailing)
        }
      }
      .workspaceHeaderLayout()

      Divider()

      if let selectedPlan {
        VStack(spacing: 0) {
          if selectedPlan.sprint.state.isInProgress {
            activeSprintPreviewBanner(selectedPlan.sprint)
            Divider()
          }

          retrospectiveWorkspace

          Divider()
          retrospectiveFooter(selectedPlan)
        }
      } else {
        ContentUnavailableView {
          Label("No sprint evidence yet", systemImage: "rectangle.3.group.bubble")
        } description: {
          Text(
            "Start a sprint and Spedito will collect specific wins, friction, and suggested improvements from each agent."
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      selectPreferredPlanIfNeeded()
      prepareSelectedSynthesisIfNeeded()
    }
    .onChange(of: availablePlanSignature) { _, _ in
      selectPreferredPlanIfNeeded()
      prepareSelectedSynthesisIfNeeded()
    }
    .onChange(of: selectedSprintID) { _, _ in
      prepareSelectedSynthesisIfNeeded()
    }
  }

  private func activeSprintPreviewBanner(_ sprint: Sprint) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.purple)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 3) {
        Text(
          sprint.state == .paused
            ? "Sprint \(sprint.number) is paused"
            : "Sprint \(sprint.number) is still in progress"
        )
        .font(.callout.weight(.semibold))
        Text(
          sprint.state == .paused
            ? "Existing evidence is preserved. Collection continues when the sprint resumes."
            : "Evidence will continue to accumulate until the sprint ends. "
              + "Add action ideas whenever they occur; the business analyst will consider them "
              + "with the team’s evidence when preparing the final actions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(Color.purple.opacity(0.055))
  }

  private var availablePlans: [SprintPlan] {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return
      plans
      .filter { $0.sprint.state.isInProgress || $0.sprint.state == .completed }
      .sorted { $0.sprint.number > $1.sprint.number }
  }

  private var availablePlanSignature: [String] {
    availablePlans.map {
      "\($0.sprint.id.uuidString):\($0.sprint.state.rawValue):\($0.sprint.retrospectiveConcludedAt?.timeIntervalSince1970 ?? 0)"
    }
  }

  private var preferredPlan: SprintPlan? {
    guard
      let preferredSprintID = RetrospectiveSprintSelection.preferredSprintID(
        in: availablePlans
      )
    else { return nil }
    return availablePlans.first { $0.sprint.id == preferredSprintID }
  }

  private var selectedSprintBinding: Binding<UUID> {
    Binding(
      get: { selectedSprintID ?? preferredPlan?.sprint.id ?? UUID() },
      set: { selectedSprintID = $0 }
    )
  }

  private var selectedPlan: SprintPlan? {
    let id = selectedSprintID ?? preferredPlan?.sprint.id
    return availablePlans.first { $0.sprint.id == id }
  }

  private var selectedNotes: [RetrospectiveNote] {
    guard let sprintID = selectedPlan?.sprint.id else { return [] }
    return model.retrospectiveNotes.filter { $0.sprintID == sprintID }
  }

  private var unresolvedActions: [RetrospectiveNote] {
    selectedNotes.filter {
      $0.category == .suggestedAction
        && !$0.isActionCandidate
        && $0.actionStatus == .proposed
    }
  }

  private var selectedSynthesis: RetrospectiveSynthesis? {
    guard let sprintID = selectedPlan?.sprint.id else { return nil }
    return model.retrospectiveSyntheses.first { $0.sprintID == sprintID }
  }

  private func selectPreferredPlanIfNeeded() {
    guard
      selectedSprintID == nil
        || !availablePlans.contains(where: { $0.sprint.id == selectedSprintID })
    else { return }
    selectedSprintID = preferredPlan?.sprint.id
  }

  private func prepareSelectedSynthesisIfNeeded() {
    guard
      let plan = selectedPlan,
      plan.sprint.state == .completed,
      plan.sprint.retrospectiveConcludedAt == nil
    else { return }
    model.prepareRetrospectiveSynthesisIfNeeded(sprintID: plan.sprint.id)
  }

  private func themes(
    for category: RetrospectiveNoteCategory
  ) -> [RetrospectiveTheme] {
    let notes = selectedNotes.filter { $0.category == category }
    return Dictionary(grouping: notes) { retrospectiveThemeTitle(for: $0.body) }
      .map { title, notes in
        RetrospectiveTheme(
          title: title,
          notes: notes.sorted { $0.createdAt < $1.createdAt }
        )
      }
      .sorted {
        if $0.notes.count == $1.notes.count {
          return $0.title < $1.title
        }
        return $0.notes.count > $1.notes.count
      }
  }

  private func retrospectiveThemeTitle(for body: String) -> String {
    let text = body.lowercased()
    let themes: [(String, [String])] = [
      (
        "Verification & evidence",
        [
          "check", "test", "verify", "verification", "candidate", "diff", "whitespace",
        ]
      ),
      (
        "Documentation & knowledge",
        [
          "document", "knowledge", "decision", "record", "wording",
        ]
      ),
      (
        "Product scope & decisions",
        [
          "approval", "requirement", "scope", "provider", "commercial", "privacy", "limit",
        ]
      ),
      (
        "Experience & preview",
        [
          "ui", "theme", "browser", "visual", "prototype", "responsive", "accessibility",
        ]
      ),
      (
        "Integration & architecture",
        [
          "integration", "adapter", "gateway", "cors", "contract", "response",
        ]
      ),
    ]
    return themes.first { _, keywords in
      keywords.contains { text.contains($0) }
    }?.0 ?? "Delivery process"
  }

  private var retrospectiveWorkspace: some View {
    GeometryReader { geometry in
      let dividerWidth: CGFloat = 1
      let availableWidth = max(geometry.size.width - dividerWidth, 0)
      let decisionWidth = availableWidth / 3
      let evidenceWidth = availableWidth - decisionWidth

      HStack(spacing: 0) {
        ScrollView(.vertical) {
          retrospectiveEvidence
            .padding(24)
        }
        .frame(width: evidenceWidth)
        .frame(maxHeight: .infinity)

        Divider()

        RetrospectiveActionPanel(
          sprint: selectedPlan?.sprint,
          synthesis: selectedSynthesis,
          notes: selectedNotes.filter { $0.category == .suggestedAction },
          onShowBacklog: onShowBacklog,
          onOpenRefiningTicket: onOpenRefiningTicket
        )
        .frame(width: decisionWidth)
        .frame(maxHeight: .infinity)
      }
      .frame(
        width: geometry.size.width,
        height: geometry.size.height,
        alignment: .leading
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var retrospectiveEvidence: some View {
    HStack(alignment: .top, spacing: 14) {
      RetrospectiveColumn(
        category: .wentWell,
        themes: themes(for: .wentWell),
        allowsActionDecisions: selectedPlan.map {
          RetrospectivePhase(sprint: $0.sprint) == .reviewing
        } ?? false
      )
      RetrospectiveColumn(
        category: .couldImprove,
        themes: themes(for: .couldImprove),
        allowsActionDecisions: selectedPlan.map {
          RetrospectivePhase(sprint: $0.sprint) == .reviewing
        } ?? false
      )
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func retrospectiveFooter(_ plan: SprintPlan) -> some View {
    HStack(spacing: 10) {
      if plan.sprint.state.isInProgress
        || plan.sprint.retrospectiveConcludedAt != nil
        || !unresolvedActions.isEmpty
      {
        Image(
          systemName: plan.sprint.retrospectiveConcludedAt == nil
            ? "arrow.triangle.2.circlepath"
            : "checkmark.seal.fill"
        )
        .foregroundStyle(
          plan.sprint.retrospectiveConcludedAt == nil ? .purple : .green
        )
        if plan.sprint.state.isInProgress {
          Text(
            plan.sprint.state == .paused
              ? "Evidence collection is paused with the sprint."
              : "Evidence is still being collected."
          )
        } else if let concludedAt = plan.sprint.retrospectiveConcludedAt {
          Text(
            "Concluded \(concludedAt.formatted(date: .abbreviated, time: .shortened))"
          )
        } else {
          Text(
            "\(unresolvedActions.count) suggested action\(unresolvedActions.count == 1 ? "" : "s") still need a decision."
          )
        }
      }
      Spacer()
      Text("\(selectedNotes.count) observations")
        .foregroundStyle(.secondary)
        .monospacedDigit()
      if plan.sprint.retrospectiveConcludedAt != nil {
        Button("Back to backlog", action: onShowBacklog)
          .buttonStyle(.borderedProminent)
      } else if plan.sprint.state == .completed {
        let synthesisIsResolved = selectedSynthesis?.status.isResolved == true
        let conclusionHelp =
          !synthesisIsResolved
          ? "Wait for the final actions, retry their preparation, or continue without AI suggestions."
          : unresolvedActions.isEmpty
            ? "Close this sprint’s learning loop and return to the next backlog."
            : "Accept or dismiss every proposed action first."
        Button(isConcluding ? "Concluding…" : "Conclude retrospective") {
          isConcluding = true
          Task {
            let didConclude = await model.concludeRetrospective(
              productID: plan.sprint.productID,
              sprintID: plan.sprint.id
            )
            isConcluding = false
            if didConclude {
              onShowBacklog()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          isConcluding || !unresolvedActions.isEmpty || !synthesisIsResolved
        )
        .help(conclusionHelp)
      }
    }
    .font(.callout)
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(.bar)
  }
}

private struct RetrospectiveTheme: Identifiable {
  let title: String
  let notes: [RetrospectiveNote]

  var id: String { title }
}

private struct RetrospectiveActionPanel: View {
  @EnvironmentObject private var model: AppModel
  let sprint: Sprint?
  let synthesis: RetrospectiveSynthesis?
  let notes: [RetrospectiveNote]
  let onShowBacklog: () -> Void
  let onOpenRefiningTicket: (WorkItem) -> Void
  @State private var isDecidingAll = false
  @State private var selectedNoteID: UUID?
  @State private var showingProposal = false
  @State private var showingActionIdea = false

  private var actionCandidateNotes: [RetrospectiveNote] {
    notes
      .filter(\.isActionCandidate)
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var decisionNotes: [RetrospectiveNote] {
    notes.filter { !$0.isActionCandidate }
  }

  private var proposedNotes: [RetrospectiveNote] {
    decisionNotes
      .filter { $0.actionStatus == .proposed }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var acceptedNotes: [RetrospectiveNote] {
    decisionNotes
      .filter { $0.actionStatus == .accepted }
      .sorted { $0.updatedAt < $1.updatedAt }
  }

  private var dismissedCount: Int {
    decisionNotes.count { $0.actionStatus == .dismissed }
  }

  private var reviewedCount: Int {
    decisionNotes.count - proposedNotes.count
  }

  private var selectedNote: RetrospectiveNote? {
    proposedNotes.first { $0.id == selectedNoteID } ?? proposedNotes.first
  }

  private var queuedNotes: [RetrospectiveNote] {
    guard let selectedNote else { return proposedNotes }
    return proposedNotes.filter { $0.id != selectedNote.id }
  }

  private var phase: RetrospectivePhase {
    sprint.map(RetrospectivePhase.init(sprint:)) ?? .collecting
  }

  private var canPropose: Bool {
    phase == .reviewing && synthesis?.status.isResolved == true
  }

  private var canCaptureActionIdea: Bool {
    phase == .collecting
  }

  private var isHistorical: Bool {
    phase == .concluded
  }

  private var decisionSummary: String {
    switch phase {
    case .collecting:
      let ideaCount = actionCandidateNotes.count
      return actionCandidateNotes.isEmpty
        ? "Evidence still collecting"
        : "\(ideaCount) action idea\(ideaCount == 1 ? "" : "s") captured"
    case .concluded:
      let accepted = "\(acceptedNotes.count) accepted"
      guard dismissedCount > 0 else { return accepted }
      return "\(accepted) · \(dismissedCount) dismissed"
    case .reviewing:
      if synthesis?.status == .pending || synthesis?.status == .generating {
        return "Business analyst synthesis"
      }
      if synthesis?.status == .failed {
        return "Needs attention"
      }
      return proposedNotes.isEmpty
        ? "\(reviewedCount) reviewed"
        : "\(proposedNotes.count) remaining · \(reviewedCount) reviewed"
    }
  }

  private var canAcceptAll: Bool {
    phase == .reviewing
      && proposedNotes.allSatisfy { $0.actionDestination != .backlog }
  }

  private var panelTitle: String {
    switch phase {
    case .collecting: "Action ideas"
    case .reviewing:
      if synthesis?.status == .pending || synthesis?.status == .generating {
        "Preparing actions"
      } else {
        "Actions to review"
      }
    case .concluded: "Decisions"
    }
  }

  private var queueTitle: String {
    phase == .collecting ? "Also collected" : "Up next"
  }

  private var emptyStateTitle: String {
    phase == .collecting ? "Capture action ideas as they happen" : "Decisions complete"
  }

  private var emptyStateDetail: String {
    if phase == .collecting {
      return "Add an action idea now. The business analyst will consider it after the sprint ends."
    }
    return reviewedCount == 0
      ? "The team did not suggest a change."
      : "Every suggested change has been reviewed."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "checklist")
          .foregroundStyle(.indigo)
        VStack(alignment: .leading, spacing: 2) {
          Text(panelTitle)
            .font(.title3.bold())
          Text(decisionSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if canCaptureActionIdea {
          Button {
            showingActionIdea = true
          } label: {
            Label("Add action idea", systemImage: "plus")
          }
          .controlSize(.small)
          .help("Capture an action idea for the retrospective")
        }
        if canPropose {
          Button {
            showingProposal = true
          } label: {
            Label("Propose change", systemImage: "plus")
          }
          .controlSize(.small)
          .help("Add your own retrospective proposal")
        }
        if phase == .reviewing, proposedNotes.count > 1 {
          Menu {
            if canAcceptAll {
              Button {
                decideAll(accept: true)
              } label: {
                Label("Accept all", systemImage: "checkmark.circle")
              }
            }
            Button(role: .destructive) {
              decideAll(accept: false)
            } label: {
              Label("Dismiss all", systemImage: "xmark.circle")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .disabled(isDecidingAll)
          .help("Decide all remaining actions")
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      if isHistorical {
        historicalDecisions
      } else if phase == .collecting {
        capturedActionIdeas
      } else if phase == .reviewing,
        synthesis == nil || synthesis?.status == .pending || synthesis?.status == .generating
      {
        synthesisProgress
      } else if phase == .reviewing, synthesis?.status == .failed {
        synthesisFailure
      } else if let selectedNote {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 18) {
            RetrospectiveActionDecisionDetail(
              note: selectedNote,
              allowsDecisions: phase == .reviewing,
              onShowBacklog: onShowBacklog,
              onOpenRefiningTicket: onOpenRefiningTicket
            )

            if !queuedNotes.isEmpty {
              VStack(alignment: .leading, spacing: 0) {
                Text(queueTitle)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 4)
                  .padding(.bottom, 7)

                ForEach(queuedNotes) { note in
                  RetrospectiveActionQueueRow(note: note) {
                    selectedNoteID = note.id
                  }
                  if note.id != queuedNotes.last?.id {
                    Divider()
                  }
                }
              }
            }
          }
          .padding(16)
        }
      } else {
        VStack(spacing: 6) {
          Image(
            systemName: phase == .collecting
              ? "clock.arrow.circlepath"
              : "checkmark.circle"
          )
          .font(.title3)
          .foregroundStyle(.tertiary)
          Text(emptyStateTitle)
            .font(.subheadline.weight(.medium))
          Text(emptyStateDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    .sheet(isPresented: $showingProposal) {
      if let sprint {
        RetrospectiveProposalView(
          productID: sprint.productID,
          sprintID: sprint.id,
          isPresented: $showingProposal
        )
      }
    }
    .sheet(isPresented: $showingActionIdea) {
      if let sprint {
        RetrospectiveActionIdeaView(
          productID: sprint.productID,
          sprintID: sprint.id,
          isPresented: $showingActionIdea
        )
      }
    }
  }

  @ViewBuilder
  private var capturedActionIdeas: some View {
    if actionCandidateNotes.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "square.and.pencil")
          .font(.title3)
          .foregroundStyle(.tertiary)
        Text(emptyStateTitle)
          .font(.subheadline.weight(.medium))
        Text(emptyStateDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .padding(16)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(
            Array(actionCandidateNotes.enumerated()),
            id: \.element.id
          ) { index, note in
            RetrospectiveActionCandidateRow(
              note: note,
              allowsDeletion:
                note.authorName == "Product owner"
                && note.profileID == nil
            )
            if index < actionCandidateNotes.count - 1 {
              Divider()
                .padding(.leading, 39)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
    }
  }

  private var synthesisProgress: some View {
    VStack(spacing: 10) {
      if synthesis?.status == .generating {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "wand.and.stars")
          .font(.title3)
          .foregroundStyle(.purple)
      }
      Text(
        synthesis?.status == .generating
          ? "Consolidating sprint evidence"
          : "Waiting to prepare final actions"
      )
      .font(.subheadline.weight(.medium))
      Text(
        synthesis?.status == .generating
          ? "The business analyst is grouping repeated observations into no more than five reviewable actions."
          : "Spedito will ask the business analyst to prepare the final action list when Codex is available."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      if let synthesis, synthesis.status == .pending {
        Button("Continue without AI suggestions") {
          Task { await model.skipRetrospectiveSynthesis(synthesis) }
        }
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(24)
  }

  private var synthesisFailure: some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title3)
        .foregroundStyle(.orange)
      Text("Final actions could not be prepared")
        .font(.subheadline.weight(.medium))
      Text(
        synthesis?.errorMessage
          ?? "The evidence is preserved and can be processed again safely."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      if let synthesis {
        HStack(spacing: 7) {
          Button("Continue without AI suggestions") {
            Task { await model.skipRetrospectiveSynthesis(synthesis) }
          }
          Button("Retry") {
            model.retryRetrospectiveSynthesis(synthesis)
          }
          .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(24)
  }

  @ViewBuilder
  private var historicalDecisions: some View {
    if acceptedNotes.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "checkmark.circle")
          .font(.title3)
          .foregroundStyle(.tertiary)
        Text("No changes were accepted")
          .font(.subheadline.weight(.medium))
        Text(historicalEmptyStateDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .padding(16)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(acceptedNotes.enumerated()), id: \.element.id) { index, note in
            RetrospectiveAcceptedDecisionRow(note: note)
              .overlay(alignment: .bottom) {
                if index < acceptedNotes.count - 1 {
                  Divider()
                    .padding(.leading, 43)
                    .padding(.trailing, 4)
                }
              }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
      }
    }
  }

  private var historicalEmptyStateDetail: String {
    if dismissedCount > 0 {
      return
        "\(dismissedCount) suggested change\(dismissedCount == 1 ? " was" : "s were") dismissed."
    }
    return "No changes were proposed in this retrospective."
  }

  private func decideAll(accept: Bool) {
    isDecidingAll = true
    Task {
      await model.decideRetrospectiveActions(proposedNotes, accept: accept)
      isDecidingAll = false
    }
  }
}

private struct RetrospectiveActionCandidateRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let allowsDeletion: Bool
  @State private var confirmingDeletion = false
  @State private var isDeleting = false

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "lightbulb")
        .foregroundStyle(.indigo)
        .frame(width: 28, height: 28)
        .background(Color.indigo.opacity(0.1), in: Circle())

      VStack(alignment: .leading, spacing: 5) {
        Text(note.body)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 5) {
          Text(note.authorName)
          Text("·")
          Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Label("For business analyst review", systemImage: "clock")
          .font(.caption.weight(.medium))
          .foregroundStyle(.purple)
      }

      if allowsDeletion {
        Button(role: .destructive) {
          confirmingDeletion = true
        } label: {
          Image(systemName: "trash")
            .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .disabled(isDeleting)
        .help("Delete this action idea")
      }
    }
    .padding(.vertical, 10)
    .confirmationDialog(
      "Delete this action idea?",
      isPresented: $confirmingDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete action idea", role: .destructive) {
        isDeleting = true
        Task {
          await model.deleteRetrospectiveActionIdea(note)
          isDeleting = false
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "It will not be included when the business analyst prepares the retrospective."
      )
    }
  }
}

private struct RetrospectiveActionIdeaView: View {
  @EnvironmentObject private var model: AppModel
  let productID: UUID
  let sprintID: UUID
  @Binding var isPresented: Bool
  @State private var actionIdea = ""
  @State private var isSubmitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add an action idea")
          .font(.title.bold())
        Text(
          "Capture the idea now. The business analyst will consider it with the team’s evidence after the sprint ends."
        )
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        EditableTextArea(
          title: "What change should the team consider?",
          prompt: "e.g. Confirm required access before starting delivery.",
          text: $actionIdea,
          minHeight: 140,
          focusOnAppear: true
        )

        Label(
          "This is source evidence during the sprint, not an early decision. You’ll review any final action after the business analyst prepares the retrospective.",
          systemImage: "clock"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Spacer(minLength: 0)
      Divider()

      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        Button {
          submit()
        } label: {
          Label(
            isSubmitting ? "Adding…" : "Add action idea",
            systemImage: "plus.circle"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .padding(20)
    }
    .frame(width: 620, height: 440)
  }

  private var canSubmit: Bool {
    !actionIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
  }

  private func submit() {
    guard canSubmit else { return }
    isSubmitting = true
    Task {
      let note = await model.captureRetrospectiveActionIdea(
        productID: productID,
        sprintID: sprintID,
        body: actionIdea
      )
      isSubmitting = false
      if note != nil {
        isPresented = false
      }
    }
  }
}

private struct RetrospectiveProposalView: View {
  @EnvironmentObject private var model: AppModel
  let productID: UUID
  let sprintID: UUID
  @Binding var isPresented: Bool
  @State private var destination = RetrospectiveActionDestination.teamPractice
  @State private var proposal = ""
  @State private var isSubmitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Propose a retrospective change")
          .font(.title.bold())
        Text(
          "Add your own improvement to the same reviewable decision queue as the team’s suggestions."
        )
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Change type")
            .font(.subheadline.weight(.semibold))
          Picker("Change type", selection: $destination) {
            ForEach(RetrospectiveActionDestination.allCases, id: \.rawValue) { destination in
              Text(destination.title).tag(destination)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }

        EditableTextArea(
          title: proposalTitle,
          prompt: proposalPrompt,
          text: $proposal,
          minHeight: 140,
          focusOnAppear: true
        )

        Label(guidance, systemImage: "checkmark.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Spacer(minLength: 0)
      Divider()

      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        Button {
          submit()
        } label: {
          Label(
            isSubmitting ? "Adding…" : "Add proposal",
            systemImage: "plus.circle"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .padding(20)
    }
    .frame(width: 620, height: 480)
  }

  private var proposalTitle: String {
    switch destination {
    case .teamPractice:
      "What should change in the ways of working?"
    case .backlog:
      "What outcome should the ticket deliver?"
    }
  }

  private var proposalPrompt: String {
    switch destination {
    case .teamPractice:
      "e.g. Confirm the preview evidence before asking for product owner approval."
    case .backlog:
      "e.g. Make sprint forecast changes visible in the retrospective."
    }
  }

  private var guidance: String {
    switch destination {
    case .teamPractice:
      "If accepted, this is added to Ways of working and inherited by future team runs."
    case .backlog:
      "If accepted, this creates a backlog ticket and opens it for automatic business analyst refinement."
    }
  }

  private var canSubmit: Bool {
    !proposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
  }

  private func submit() {
    guard canSubmit else { return }
    isSubmitting = true
    Task {
      let note = await model.proposeRetrospectiveAction(
        productID: productID,
        sprintID: sprintID,
        body: proposal,
        destination: destination
      )
      isSubmitting = false
      if note != nil {
        isPresented = false
      }
    }
  }
}

private struct RetrospectiveActionDecisionDetail: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let allowsDecisions: Bool
  let onShowBacklog: () -> Void
  let onOpenRefiningTicket: (WorkItem) -> Void
  @State private var areSourcesExpanded = false

  private var ticket: WorkItem? {
    guard let workItemID = note.workItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var attributionSymbol: String {
    if attribution.authorNames.count > 1 || attribution.profileIDs.count > 1 {
      return "person.2.fill"
    }
    return profile?.role.symbolName ?? "person.crop.circle"
  }

  private var sourceTicketKeys: [String] {
    Array(
      Set(
        sources.compactMap { source in
          source.workItemID.flatMap { workItemID in
            model.workItems.first { $0.id == workItemID }?.key
          }
        }
      )
    ).sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(destination.title, systemImage: destinationSymbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(destination == .teamPractice ? .purple : .blue)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
          (destination == .teamPractice ? Color.purple : Color.blue).opacity(0.09),
          in: Capsule()
        )

      Text(note.body)
        .font(.body.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)

      if let expectedEffect = note.expectedEffect {
        VStack(alignment: .leading, spacing: 3) {
          Text("Expected effect")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(expectedEffect)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 6) {
        Image(systemName: attributionSymbol)
          .foregroundStyle(profile?.role.tint ?? .secondary)
        Text(attribution.summary)
          .fontWeight(.semibold)
        if let ticket {
          Text("· \(ticket.key)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      if !sources.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          Button {
            withAnimation(.easeInOut(duration: 0.16)) {
              areSourcesExpanded.toggle()
            }
          } label: {
            HStack(spacing: 7) {
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(areSourcesExpanded ? 90 : 0))
                .frame(width: 12)
              Text(sourceSummary)
                .font(.caption.weight(.semibold))
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(sourceSummary)
          .accessibilityValue(areSourcesExpanded ? "Expanded" : "Collapsed")
          .accessibilityHint(
            areSourcesExpanded
              ? "Collapse the source observations"
              : "Expand the source observations"
          )

          if areSourcesExpanded {
            Divider()
              .overlay(Color(nsColor: .separatorColor).opacity(0.55))
              .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 9) {
              ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 3) {
                  HStack(spacing: 5) {
                    Text(source.authorName)
                      .fontWeight(.semibold)
                    if let workItemID = source.workItemID,
                      let sourceTicket = model.workItems.first(where: {
                        $0.id == workItemID
                      })
                    {
                      Text("· \(sourceTicket.key)")
                        .foregroundStyle(.secondary)
                    }
                  }
                  Text(source.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .transition(.opacity)
          }
        }
        .background(
          Color(nsColor: .windowBackgroundColor).opacity(0.7),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
      }

      Divider()

      Text(
        actionEffectDescription
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if allowsDecisions {
        HStack(spacing: 7) {
          Spacer()
          Button("Dismiss") {
            Task { await model.decideRetrospectiveAction(note, accept: false) }
          }
          Button {
            Task {
              let createdItem = await model.decideRetrospectiveAction(
                note,
                accept: true
              )
              if let createdItem {
                #if DEBUG
                  UIFixtureRuntime.recordInteraction(
                    "i07-accepted-work-item-id",
                    value: createdItem.id.uuidString
                  )
                #endif
                onShowBacklog()
                onOpenRefiningTicket(createdItem)
              }
            }
          } label: {
            Label("Accept", systemImage: "checkmark.circle")
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("retrospective.action.accept.\(note.id.uuidString)")
        }
        .controlSize(.small)
      } else {
        Label("Available after sprint completion", systemImage: "clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
    }
  }

  private var destinationSymbol: String {
    switch destination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }

  private var sourceSummary: String {
    let observationCount =
      "\(sources.count) source observation\(sources.count == 1 ? "" : "s")"
    guard !sourceTicketKeys.isEmpty else { return observationCount }
    return "\(observationCount) · \(sourceTicketKeys.joined(separator: ", "))"
  }

  private var actionEffectDescription: String {
    switch (allowsDecisions, destination) {
    case (true, .teamPractice):
      "Accepting updates the team’s Ways of working."
    case (true, .backlog):
      "Accepting creates a new backlog ticket."
    case (false, .teamPractice):
      "If accepted after the sprint, this will update the team’s Ways of working."
    case (false, .backlog):
      "If accepted after the sprint, this will create a new backlog ticket."
    }
  }
}

private struct RetrospectiveActionQueueRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let onSelect: () -> Void
  @State private var isHovering = false

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: destinationSymbol)
          .foregroundStyle(destination == .teamPractice ? .purple : .blue)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 5) {
          Text(note.body)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 5) {
            Text(destination.title)
            Text("·")
            Text(attribution.summary)
              .foregroundStyle(profile?.role.tint ?? .secondary)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .padding(.top, 2)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 11)
      .background(
        isHovering ? Color.accentColor.opacity(0.07) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
  }

  private var destinationSymbol: String {
    switch destination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }
}

private struct RetrospectiveAcceptedDecisionRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var attributionSymbol: String {
    if attribution.authorNames.count > 1 || attribution.profileIDs.count > 1 {
      return "person.2.fill"
    }
    return profile?.role.symbolName ?? "person.crop.circle"
  }

  private var acceptedTicket: WorkItem? {
    guard let workItemID = note.acceptedWorkItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: destinationSymbol)
        .foregroundStyle(destinationTint)
        .frame(width: 28, height: 28)
        .background(destinationTint.opacity(0.1), in: Circle())

      VStack(alignment: .leading, spacing: 5) {
        Text(note.body)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 5) {
          Label("Accepted", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("·")
          Text(destination.title)
          if let acceptedTicket {
            Text("·")
            Text(acceptedTicket.key)
          }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

        HStack(spacing: 5) {
          Image(systemName: attributionSymbol)
            .foregroundStyle(profile?.role.tint ?? .secondary)
          Text(attribution.summary)
          Text("·")
          Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 10)
  }

  private var destinationTint: Color {
    destination == .teamPractice ? .purple : .blue
  }

  private var destinationSymbol: String {
    switch destination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }
}

private struct RetrospectiveColumn: View {
  let category: RetrospectiveNoteCategory
  let themes: [RetrospectiveTheme]
  let allowsActionDecisions: Bool

  private var noteCount: Int {
    themes.reduce(0) { $0 + $1.notes.count }
  }

  private var tint: Color {
    switch category {
    case .wentWell: .green
    case .couldImprove: .orange
    case .suggestedAction: .indigo
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: symbol)
            .foregroundStyle(tint)
          Text(panelTitle)
            .font(.title3.bold())
          Text(noteCount.formatted())
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
          Spacer()
        }
        if category == .suggestedAction {
          Text(
            allowsActionDecisions
              ? "The team has chosen a destination for each action. Accept it or dismiss it."
              : "Suggested actions remain reviewable previews until the sprint is complete."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      if themes.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "note.text")
            .font(.title2)
          Text(category == .suggestedAction ? "No suggested changes" : "No evidence recorded yet")
            .font(.callout.weight(.medium))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
      } else {
        ForEach(themes) { theme in
          RetrospectiveThemeSection(
            category: category,
            theme: theme,
            tint: tint,
            allowsActionDecisions: allowsActionDecisions
          )
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
  }

  private var panelTitle: String {
    guard category == .suggestedAction else { return category.title }
    return allowsActionDecisions ? "Actions to decide" : "Emerging actions"
  }

  private var symbol: String {
    switch category {
    case .wentWell: "hand.thumbsup.fill"
    case .couldImprove: "lightbulb.fill"
    case .suggestedAction: "plus.rectangle.on.rectangle"
    }
  }
}

private struct RetrospectiveThemeSection: View {
  @EnvironmentObject private var model: AppModel
  let category: RetrospectiveNoteCategory
  let theme: RetrospectiveTheme
  let tint: Color
  let allowsActionDecisions: Bool
  @State private var isExpanded = false
  @State private var isDeciding = false

  private var proposedNotes: [RetrospectiveNote] {
    theme.notes.filter { $0.actionStatus == .proposed }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Text(theme.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Spacer()
          if !proposedNotes.isEmpty {
            if allowsActionDecisions {
              Text("\(proposedNotes.count) to decide")
                .foregroundStyle(.orange)
            } else {
              Text("\(proposedNotes.count) collected")
                .foregroundStyle(.secondary)
            }
          } else {
            Text(theme.notes.count.formatted())
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(theme.title), \(theme.notes.count) observations")
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Collapse this group" : "Expand this group")

      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          if category == .suggestedAction,
            allowsActionDecisions,
            !proposedNotes.isEmpty
          {
            HStack(spacing: 7) {
              Button("Dismiss theme") {
                decideAll(accept: false)
              }
              Spacer()
              Button {
                decideAll(accept: true)
              } label: {
                Label("Accept theme", systemImage: "checkmark.circle")
              }
              .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .disabled(isDeciding)
          }
          ForEach(theme.notes) { note in
            RetrospectiveStickyNote(
              note: note,
              tint: tint,
              allowsActionDecisions: allowsActionDecisions
            )
          }
        }
        .padding(.top, 10)
        .transition(.opacity)
      }
    }
    .padding(12)
    .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(tint.opacity(0.13), lineWidth: 1)
    }
  }

  private func decideAll(accept: Bool) {
    isDeciding = true
    Task {
      await model.decideRetrospectiveActions(proposedNotes, accept: accept)
      isDeciding = false
    }
  }

}

private struct RetrospectiveStickyNote: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let tint: Color
  let allowsActionDecisions: Bool

  private var ticket: WorkItem? {
    guard let workItemID = note.workItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var attributionSymbol: String {
    if attribution.authorNames.count > 1 || attribution.profileIDs.count > 1 {
      return "person.2.fill"
    }
    return profile?.role.symbolName ?? "person.crop.circle"
  }

  private var rotation: Double {
    let scalar = note.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return Double((scalar % 5) - 2) * 0.35
  }

  private var actionDestination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(note.body)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        if note.category == .suggestedAction {
          Label(actionDestination.title, systemImage: destinationSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(actionDestination == .teamPractice ? .purple : .blue)
          Text("·")
            .foregroundStyle(.tertiary)
        }
        Image(systemName: attributionSymbol)
          .foregroundStyle(profile?.role.tint ?? tint)
        Text(attribution.summary)
          .fontWeight(.semibold)
        if let ticket {
          Text("· \(ticket.key)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      if note.category == .suggestedAction {
        actionControls
      }
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(tint.opacity(0.18), lineWidth: 0.7)
    }
    .rotationEffect(.degrees(rotation))
  }

  @ViewBuilder
  private var actionControls: some View {
    switch note.actionStatus {
    case .proposed:
      if allowsActionDecisions {
        HStack(spacing: 7) {
          Spacer()
          Button("Dismiss") {
            Task { await model.decideRetrospectiveAction(note, accept: false) }
          }
          Button {
            Task { await model.decideRetrospectiveAction(note, accept: true) }
          } label: {
            Label("Accept", systemImage: "checkmark.circle")
          }
          .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
      } else {
        Label("Available after sprint completion", systemImage: "clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    case .accepted:
      Label(
        actionDestination == .teamPractice ? "Added to Ways of working" : "Added to backlog",
        systemImage: destinationSymbol
      )
      .foregroundStyle(actionDestination == .teamPractice ? .purple : .blue)
      .font(.caption.weight(.semibold))
    case .dismissed:
      Label("Dismissed", systemImage: "xmark.circle")
        .foregroundStyle(.secondary)
        .font(.caption)
    case .none:
      EmptyView()
    }
  }

  private var destinationSymbol: String {
    switch actionDestination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }
}
