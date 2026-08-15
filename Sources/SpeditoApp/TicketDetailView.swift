import AppKit
import SpeditoCore
import SwiftUI

struct TicketDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceContainerSize) private var workspaceContainerSize
  let itemID: UUID
  let productID: UUID
  let startRefinementOnAppear: Bool
  @State private var title: String
  @State private var type: WorkItemType
  @State private var bodyText: String
  @State private var criteria: [AcceptanceCriterionDraft]
  @State private var priority: WorkItemPriority
  @State private var blockerIDs: Set<UUID>
  @State private var customFields: [TicketCustomFieldDraft]
  @State private var assigneeID: UUID?
  @State private var isSaving = false
  @State private var isStartingRefinement = false
  @State private var didStartInitialRefinement = false
  @State private var refinementReply: TicketRefinementReply?
  @State private var refinementBaseSnapshot: SprintPlanningTicketSnapshot?
  @State private var refinementConflictMessage: String?
  @State private var refinementError: String?
  @State private var acceptedRefinementFields: Set<TicketRefinementField> = []
  @State private var expandedRefinementFields: Set<TicketRefinementField> = []
  @State private var dismissedDependencyKeys: Set<String> = []
  @State private var conversationRefreshToken = 0
  @State private var refinementPanelTitle = "Business analyst review"
  @State private var selectedRelationshipTicket: WorkItem?

  init(
    item: WorkItem,
    dependsOnWorkItemIDs: Set<UUID>,
    startRefinementOnAppear: Bool = false
  ) {
    itemID = item.id
    productID = item.productID
    self.startRefinementOnAppear = startRefinementOnAppear
    _title = State(initialValue: item.title)
    _type = State(initialValue: item.type)
    _bodyText = State(initialValue: item.body)
    _criteria = State(
      initialValue: item.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    )
    _priority = State(initialValue: item.priority)
    _blockerIDs = State(initialValue: dependsOnWorkItemIDs)
    _customFields = State(
      initialValue: item.customFields.keys.sorted().map {
        TicketCustomFieldDraft(name: $0, value: item.customFields[$0] ?? "")
      }
    )
    _assigneeID = State(initialValue: item.ownerProfileID)
  }

  private var item: WorkItem? {
    model.workItems.first { $0.id == itemID }
  }

  private var isRefining: Bool {
    isStartingRefinement || model.refiningWorkItemID == itemID
  }

  private var duplicateFieldNames: Set<String> {
    let names = customFields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Set(
      names.filter { name in
        names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }.count > 1
      })
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && customFields.allSatisfy {
        !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      && duplicateFieldNames.isEmpty
      && !isSaving
  }

  private var detailSize: CGSize {
    ConversationDetailSheetSizing.size(for: workspaceContainerSize)
  }

  private var conversationWidth: CGFloat {
    ConversationDetailSheetSizing.conversationWidth(for: detailSize.width)
  }

  private var currentSavedSnapshot: SprintPlanningTicketSnapshot? {
    item.map(SprintPlanningTicketSnapshot.init(item:))
  }

  private var currentDraftSnapshot: SprintPlanningTicketSnapshot? {
    guard let item else { return nil }
    return SprintPlanningTicketSnapshot(
      version: item.version,
      title: title,
      type: type,
      body: bodyText,
      acceptanceCriteria: parsedCriteria,
      priority: priority
    )
  }

  private var savedBlockerIDs: Set<UUID> {
    Set(
      model.dependencies
        .filter { $0.workItemID == itemID }
        .map(\.dependsOnWorkItemID)
    )
  }

  private var draftCustomFields: [String: String] {
    customFields.reduce(into: [:]) { result, field in
      let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }
      result[name] = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private var savedAssigneeID: UUID? {
    let plannedAssigneeID = model.candidateSprintPlan?.items
      .first { $0.workItemID == itemID }?
      .implementerProfileID
    return plannedAssigneeID ?? item?.ownerProfileID
  }

  private var deliveryProfiles: [AgentProfile] {
    model.profiles.filter(\.role.canOwnDelivery)
  }

  private var ticketFieldsHaveUnsavedChanges: Bool {
    currentDraftSnapshot != currentSavedSnapshot
      || blockerIDs != savedBlockerIDs
      || draftCustomFields != item?.customFields
  }

  private var assignmentHasUnsavedChanges: Bool {
    return assigneeID != savedAssigneeID
  }

  private var hasUnsavedChanges: Bool {
    ticketFieldsHaveUnsavedChanges || assignmentHasUnsavedChanges
  }

  private var parsedCriteria: [String] {
    criteria
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var isContextMissing: Bool {
    bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var needsInitialRefinement: Bool {
    guard let item else { return false }
    return item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || item.acceptanceCriteria.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        if let item {
          Image(systemName: item.type.symbolName)
            .foregroundStyle(item.type.tint)
          Text(item.key)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text("Ticket details")
          .font(.title2.bold())
        Spacer()
        Button("Close") { dismiss() }
      }
      .padding(.horizontal, 24)
      .frame(height: 62)

      Divider()

      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            EditableTextField(
              title: "Title",
              prompt: "Describe the outcome",
              text: $title
            )

            EditableTextArea(
              title: "Context",
              prompt: "Explain the user need, constraints, and relevant background.",
              text: $bodyText,
              statusText: isContextMissing ? "Required" : nil,
              minHeight: 126
            )

            if let item,
              let epic = TicketEpicNavigation.destination(
                for: item,
                in: model.epics
              )
            {
              TicketEpicLink(epic: epic)
            }

            HStack(spacing: 18) {
              VStack(alignment: .leading, spacing: 7) {
                Text("Type")
                  .font(.subheadline.weight(.semibold))
                Picker("Type", selection: $type) {
                  ForEach(WorkItemType.allCases, id: \.self) { value in
                    Label(value.title, systemImage: value.symbolName).tag(value)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
              }

              VStack(alignment: .leading, spacing: 7) {
                Text("Priority")
                  .font(.subheadline.weight(.semibold))
                Picker("Priority", selection: $priority) {
                  ForEach(WorkItemPriority.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
              }

              VStack(alignment: .leading, spacing: 7) {
                Text("Assignee")
                  .font(.subheadline.weight(.semibold))
                Picker("Assignee", selection: $assigneeID) {
                  Text("Choose assignee")
                    .tag(nil as UUID?)
                  ForEach(deliveryProfiles) { profile in
                    Label(profile.name, systemImage: profile.role.symbolName)
                      .tag(Optional(profile.id))
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(deliveryProfiles.isEmpty)
                .help("Choose the team member who will deliver this ticket.")
              }

              Spacer()

              if let item {
                VStack(alignment: .trailing, spacing: 3) {
                  Text("Planning status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(candidateStatus(for: item))
                    .font(.subheadline.weight(.semibold))
                }
              }
            }

            AcceptanceCriteriaEditor(criteria: $criteria)

            relationshipSection
            customFieldSection
          }
          .padding(24)
          .disabled(isRefining)
        }
        .frame(maxWidth: .infinity)

        Divider()

        TicketConversationView(
          workItemID: itemID,
          productID: productID,
          ticketSnapshot: currentDraftSnapshot,
          refreshToken: conversationRefreshToken,
          showsReview:
            refinementError != nil
            || (refinementReply?.proposal.missingQuestions.isEmpty == true),
          isAgentResponding: isRefining,
          refinementQuestions: refinementReply?.proposal.missingQuestions ?? [],
          onStopRefinement: { model.cancelTicketRefinement() },
          onRefinementAnswer: { _ in
            await continueRefinement()
          },
          onChatProposal: { proposal, base, author in
            presentChatProposal(
              proposal,
              base: base,
              author: author
            )
          },
          reviewContent: refinementPanel
        )
        .frame(width: conversationWidth)
      }

      Divider()

      HStack {
        if !duplicateFieldNames.isEmpty {
          Label("Custom field names must be unique", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Text("Changes are local and become the ticket source of truth when saved.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
        Button(isSaving ? "Saving…" : "Save") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
      }
      .padding(.horizontal, 20)
      .frame(height: 62)
    }
    .frame(width: detailSize.width, height: detailSize.height)
    .background(InitialFocusClearer())
    .task {
      await model.setOwnerNotificationTargetVisible(
        productID: productID,
        target: OwnerNotificationTarget(kind: .ticket, id: itemID)
      )
      assigneeID = savedAssigneeID
      restoreTicketAssistantSession()
      await restorePendingRefinementQuestion()
      guard
        startRefinementOnAppear || needsInitialRefinement,
        !didStartInitialRefinement,
        refinementReply == nil,
        model.canRefineTicket
      else { return }
      didStartInitialRefinement = true
      startRefinement()
    }
    .onChange(of: model.canRefineTicket) { _, canRefine in
      guard
        startRefinementOnAppear || needsInitialRefinement,
        canRefine,
        !didStartInitialRefinement,
        refinementReply == nil,
        !hasUnsavedChanges
      else { return }
      didStartInitialRefinement = true
      startRefinement()
    }
    .onChange(of: model.ticketRefinementResults[itemID]) { _, result in
      guard let result else { return }
      applyRefinementSessionResult(result)
      conversationRefreshToken += 1
    }
    .onChange(of: model.ticketConversationResults[itemID]) { _, result in
      guard let result else { return }
      applyConversationSessionResult(result)
      conversationRefreshToken += 1
    }
    .onChange(of: model.refiningWorkItemID) { previousID, currentID in
      guard previousID == itemID || currentID == itemID else { return }
      conversationRefreshToken += 1
    }
    .onChange(of: model.ticketConversationWorkItemID) { previousID, currentID in
      guard previousID == itemID || currentID == itemID else { return }
      conversationRefreshToken += 1
    }
    .onDisappear {
      model.clearOwnerNotificationTargetVisible(
        productID: productID,
        target: OwnerNotificationTarget(kind: .ticket, id: itemID)
      )
    }
    .sheet(item: $selectedRelationshipTicket) { relatedItem in
      TicketDetailView(
        item: relatedItem,
        dependsOnWorkItemIDs: Set(
          model.dependencies
            .filter { $0.workItemID == relatedItem.id }
            .map(\.dependsOnWorkItemID)
        )
      )
    }
  }

  private func restoreTicketAssistantSession() {
    if let result = model.ticketRefinementResults[itemID] {
      applyRefinementSessionResult(result)
    }
    if let result = model.ticketConversationResults[itemID] {
      applyConversationSessionResult(result)
    }
  }

  private func applyRefinementSessionResult(_ result: TicketRefinementSessionResult) {
    refinementBaseSnapshot = result.base
    refinementPanelTitle =
      (model.profiles.first { $0.role == .businessAnalyst }?.name ?? "Business analyst")
      + " review"
    refinementError = result.errorMessage
    if result.errorMessage == nil,
      result.reply?.proposal.missingQuestions.isEmpty == true
    {
      syncFromLatestSavedTicket()
      refinementReply = nil
      refinementConflictMessage = nil
      return
    }
    refinementReply = result.reply
    guard let reply = result.reply else {
      refinementConflictMessage = nil
      return
    }
    if currentDraftSnapshot != result.base {
      refinementConflictMessage =
        "You edited the ticket while the review was running. Save those edits and run a fresh review before accepting suggestions."
    } else if model.workItems.first(where: { $0.id == itemID })?.version
      != reply.proposal.baseVersion
    {
      refinementConflictMessage =
        "The saved ticket changed while the review was running. Run a fresh review before accepting suggestions."
    } else {
      refinementConflictMessage = nil
    }
  }

  private func syncFromLatestSavedTicket() {
    guard let latest = item else { return }
    title = latest.title
    type = latest.type
    bodyText = latest.body
    criteria = latest.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    priority = latest.priority
    blockerIDs = savedBlockerIDs
    customFields = latest.customFields.keys.sorted().map {
      TicketCustomFieldDraft(name: $0, value: latest.customFields[$0] ?? "")
    }
    assigneeID = savedAssigneeID
    acceptedRefinementFields.removeAll()
    expandedRefinementFields.removeAll()
    dismissedDependencyKeys.removeAll()
  }

  private func applyConversationSessionResult(_ result: TicketConversationSessionResult) {
    guard
      let proposal = result.reply.proposal,
      let author = model.profiles.first(where: { $0.id == result.recipientID })
    else { return }
    presentChatProposal(proposal, base: result.base, author: author)
  }

  private func restorePendingRefinementQuestion() async {
    guard
      refinementReply == nil,
      let item,
      let analyst = model.profiles.first(where: { $0.role == .businessAnalyst })
    else { return }

    let comments = await model.comments(for: item.id, productID: item.productID)
    guard
      let latest = comments.last,
      latest.authorKind == .agent,
      latest.authorName == analyst.name
    else { return }

    let questions = TicketRefinementQuestion.parseTicketCommentBody(latest.body)
    guard !questions.isEmpty else { return }

    let base = SprintPlanningTicketSnapshot(item: item)
    refinementBaseSnapshot = base
    refinementPanelTitle = "\(analyst.name) review"
    refinementReply = TicketRefinementReply(
      message: "",
      proposal: TicketRefinementProposal(
        baseVersion: item.version,
        title: item.title,
        type: item.type,
        body: item.body,
        acceptanceCriteria: item.acceptanceCriteria,
        priority: item.priority,
        rationale: "",
        dependencies: [],
        potentialDuplicates: [],
        splitRecommendation: nil,
        missingQuestions: questions
      )
    )
  }

  @ViewBuilder
  private var refinementPanel: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Label(refinementPanelTitle, systemImage: "wand.and.stars")
          .font(.headline)
          .foregroundStyle(.purple)
        Spacer()
        if refinementReply != nil || refinementError != nil {
          Button {
            refinementReply = nil
            refinementError = nil
            refinementConflictMessage = nil
            model.dismissTicketAssistantResult(workItemID: itemID)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Dismiss review")
        }
      }

      if isRefining {
        HStack(spacing: 9) {
          ProgressView()
            .controlSize(.small)
            .tint(.purple)
          VStack(alignment: .leading, spacing: 2) {
            Text("Business analyst is reviewing this ticket…")
              .font(.subheadline.weight(.semibold))
            Text("Checking clarity, criteria, overlap, and dependencies.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Stop") {
            model.cancelTicketRefinement()
          }
          .controlSize(.mini)
        }
        .padding(11)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
      } else if let refinementError {
        Label(refinementError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
        Button {
          startRefinement()
        } label: {
          Label("Try again", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .controlSize(.small)
      } else if let reply = refinementReply {
        if !reply.proposal.missingQuestions.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            Label("Waiting for your answer", systemImage: "questionmark.bubble")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.purple)
            Text(
              "Reply to the business analyst below. Proposed changes will appear only after the open questions are resolved."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(11)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        } else if let base = refinementBaseSnapshot {
          if let refinementConflictMessage {
            Label(refinementConflictMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(9)
              .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
          }

          VStack(alignment: .leading, spacing: 10) {
            ForEach(refinementFieldChanges(proposal: reply.proposal, base: base)) { change in
              refinementFieldRow(change)
            }

            ForEach(reply.proposal.dependencies, id: \.ticketKey) { dependency in
              dependencyProposalRow(dependency)
            }

            if !reply.proposal.potentialDuplicates.isEmpty {
              refinementInsightSection(
                title: "Possible overlap",
                symbol: "square.on.square",
                rows: reply.proposal.potentialDuplicates.map {
                  "\($0.ticketKey) · \($0.reason)"
                }
              )
            }

            if let split = reply.proposal.splitRecommendation {
              refinementInsightSection(
                title: "Consider splitting",
                symbol: "arrow.triangle.branch",
                rows: [split]
              )
            }
          }

          let reviewProgress = refinementReviewProgress(
            proposal: reply.proposal,
            base: base
          )
          HStack(spacing: 8) {
            if reviewProgress.remaining == 0 {
              Label(
                reviewProgress.total == 0
                  ? "No ticket changes suggested"
                  : reviewProgress.dismissed == 0
                    ? "All suggestions applied"
                    : "Review complete",
                systemImage: reviewProgress.total == 0
                  ? "info.circle.fill"
                  : "checkmark.circle.fill"
              )
              .font(.caption.weight(.semibold))
              .foregroundStyle(.green)
            } else {
              Button(
                reviewProgress.remaining == reviewProgress.total
                  ? "Accept all suggestions"
                  : "Accept remaining suggestions"
              ) {
                acceptAllRefinementSuggestions(reply.proposal)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .disabled(refinementConflictMessage != nil)
            }
            Button("Dismiss") {
              refinementReply = nil
              refinementConflictMessage = nil
              model.dismissTicketAssistantResult(workItemID: itemID)
            }
            .controlSize(.small)
          }

          Text(
            "Accepted suggestions update the form. Save changes to make them the ticket source of truth."
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(14)
    .background(.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.purple.opacity(0.14), lineWidth: 1)
    }
  }

  private func refinementFieldRow(_ change: TicketRefinementFieldChange) -> some View {
    let isAccepted = acceptedRefinementFields.contains(change.field)
    let isExpanded = expandedRefinementFields.contains(change.field)
    let hasLongComparison =
      change.before.count > 180
      || change.after.count > 260
      || change.before.filter(\.isNewline).count > 2
      || change.after.filter(\.isNewline).count > 4
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(change.field.label)
          .font(.caption.weight(.semibold))
        Spacer()
        if isAccepted {
          Label("Applied", systemImage: "checkmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
        } else {
          Button("Accept") {
            acceptRefinementField(change.field)
          }
          .controlSize(.mini)
          .disabled(refinementConflictMessage != nil)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Current")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(change.before)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(isExpanded ? nil : 3)
      }
      Divider()
      VStack(alignment: .leading, spacing: 4) {
        Text("Proposed")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.green)
        Text(change.after)
          .font(.caption)
          .lineLimit(isExpanded ? nil : 5)
      }
      if hasLongComparison {
        Button(isExpanded ? "Show less" : "Show full comparison") {
          if isExpanded {
            expandedRefinementFields.remove(change.field)
          } else {
            expandedRefinementFields.insert(change.field)
          }
        }
        .buttonStyle(.link)
        .font(.caption.weight(.semibold))
      }
    }
    .padding(9)
    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
  }

  private func dependencyProposalRow(
    _ dependency: TicketRefinementDependencyProposal
  ) -> some View {
    let relatedItem = model.workItems.first { $0.key == dependency.ticketKey }
    let isApplied = relatedItem.map { blockerIDs.contains($0.id) } ?? false
    let isDismissed = dismissedDependencyKeys.contains(dependency.ticketKey)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Suggested dependency: \(dependency.ticketKey)", systemImage: "link")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.indigo)
        Spacer()
        if isApplied {
          Label("Applied", systemImage: "checkmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
        } else if isDismissed {
          Text("Dismissed")
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Button("Accept") {
            if let relatedItem {
              blockerIDs.insert(relatedItem.id)
              autoDismissRefinementReviewIfResolved()
            }
          }
          .controlSize(.mini)
          .disabled(refinementConflictMessage != nil || relatedItem == nil)
          Button("Dismiss") {
            dismissedDependencyKeys.insert(dependency.ticketKey)
            autoDismissRefinementReviewIfResolved()
          }
          .controlSize(.mini)
        }
      }
      if let relatedItem {
        Text(relatedItem.title)
          .font(.caption)
      }
      Text(dependency.reason)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(9)
    .background(.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
  }

  private func refinementInsightSection(
    title: String,
    symbol: String,
    rows: [String]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol)
        .font(.caption.weight(.semibold))
      ForEach(Array(rows.enumerated()), id: \.offset) { entry in
        Text("• \(entry.element)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
  }

  private var relationshipSection: some View {
    SprintTicketSectionCard(title: "Relationships") {
      VStack(alignment: .leading, spacing: 14) {
        Text("Blockers affect backlog order and sprint readiness.")
          .font(.caption)
          .foregroundStyle(.secondary)

        TicketBlockerEditor(
          selectedIDs: $blockerIDs,
          excludingWorkItemID: itemID,
          onOpen: openRelationship
        )

        let blockedItems = model.dependencies
          .filter { $0.dependsOnWorkItemID == itemID }
          .compactMap { edge in
            model.workItems.first { $0.id == edge.workItemID }
          }
        if !blockedItems.isEmpty {
          Divider()
          TicketDetailRelationshipRow(
            group: TicketDetailRelationshipGroup(
              id: "blocks",
              title: "Blocks",
              symbol: "link",
              items: blockedItems.map(TicketDetailRelationshipItem.init(workItem:))
            ),
            onOpenRelationship: openRelationship
          )
        }
      }
    }
  }

  private func openRelationship(_ relationshipID: UUID) {
    guard let item else { return }
    selectedRelationshipTicket = TicketRelationshipNavigation.destination(
      for: relationshipID,
      source: item,
      in: model.workItems
    )
  }

  private var customFieldSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Custom fields")
            .font(.subheadline.weight(.semibold))
          Text("Product-specific metadata available to the delivery team.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          customFields.append(TicketCustomFieldDraft(name: "", value: ""))
        } label: {
          Label("Add field", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if customFields.isEmpty {
        Text("No custom fields")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        VStack(spacing: 8) {
          ForEach($customFields) { $field in
            HStack(spacing: 8) {
              TextField("Field name", text: $field.name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(width: 190, height: 36)
                .background(
                  Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
              TextField("Value", text: $field.value)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(
                  Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
              Button {
                customFields.removeAll { $0.id == field.id }
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove custom field")
            }
          }
        }
      }
    }
  }

  private func startRefinement() {
    guard
      let item,
      !hasUnsavedChanges,
      model.canRefineTicket,
      !isRefining
    else { return }
    let base = SprintPlanningTicketSnapshot(item: item)
    refinementBaseSnapshot = base
    refinementPanelTitle =
      (model.profiles.first { $0.role == .businessAnalyst }?.name ?? "Business analyst")
      + " review"
    refinementReply = nil
    refinementConflictMessage = nil
    refinementError = nil
    acceptedRefinementFields.removeAll()
    expandedRefinementFields.removeAll()
    dismissedDependencyKeys.removeAll()
    isStartingRefinement = true

    Task {
      await performRefinement(item: item, base: base)
    }
  }

  private func continueRefinement() async {
    guard
      let item,
      let base = refinementBaseSnapshot,
      !hasUnsavedChanges,
      model.canRefineTicket,
      !isRefining
    else { return }
    isStartingRefinement = true
    refinementError = nil
    await performRefinement(item: item, base: base)
  }

  private func performRefinement(
    item: WorkItem,
    base: SprintPlanningTicketSnapshot
  ) async {
    do {
      let reply = try await model.refineTicket(item)
      if reply.proposal.missingQuestions.isEmpty {
        syncFromLatestSavedTicket()
        refinementReply = nil
        refinementConflictMessage = nil
      } else if currentDraftSnapshot != base {
        refinementReply = reply
        refinementConflictMessage =
          "You edited the ticket while the review was running. Save those edits and run a fresh review before accepting suggestions."
      } else if model.workItems.first(where: { $0.id == item.id })?.version
        != reply.proposal.baseVersion
      {
        refinementReply = reply
        refinementConflictMessage =
          "The saved ticket changed while the review was running. Run a fresh review before accepting suggestions."
      } else {
        refinementReply = reply
        refinementConflictMessage = nil
      }
    } catch {
      refinementError = error.localizedDescription
    }
    conversationRefreshToken += 1
    isStartingRefinement = false
  }

  private func refinementFieldChanges(
    proposal: TicketRefinementProposal,
    base: SprintPlanningTicketSnapshot
  ) -> [TicketRefinementFieldChange] {
    var changes: [TicketRefinementFieldChange] = []
    if proposal.title != base.title {
      changes.append(
        TicketRefinementFieldChange(
          field: .title,
          before: base.title,
          after: proposal.title
        )
      )
    }
    if proposal.type != base.type {
      changes.append(
        TicketRefinementFieldChange(
          field: .type,
          before: base.type.title,
          after: proposal.type.title
        )
      )
    }
    if proposal.body != base.body {
      changes.append(
        TicketRefinementFieldChange(
          field: .context,
          before: base.body.isEmpty ? "No context" : base.body,
          after: proposal.body.isEmpty ? "No context" : proposal.body
        )
      )
    }
    if proposal.acceptanceCriteria != base.acceptanceCriteria {
      changes.append(
        TicketRefinementFieldChange(
          field: .acceptanceCriteria,
          before: refinementCriteriaDescription(base.acceptanceCriteria),
          after: refinementCriteriaDescription(proposal.acceptanceCriteria)
        )
      )
    }
    if proposal.priority != base.priority {
      changes.append(
        TicketRefinementFieldChange(
          field: .priority,
          before: base.priority.title,
          after: proposal.priority.title
        )
      )
    }
    return changes
  }

  private func presentChatProposal(
    _ proposal: SprintPlanningTicketProposal,
    base: SprintPlanningTicketSnapshot,
    author: AgentProfile
  ) {
    refinementBaseSnapshot = base
    refinementPanelTitle = "\(author.name) proposal"
    refinementError = nil
    acceptedRefinementFields.removeAll()
    expandedRefinementFields.removeAll()
    dismissedDependencyKeys.removeAll()
    refinementReply = TicketRefinementReply(
      message: "",
      proposal: TicketRefinementProposal(
        baseVersion: proposal.baseVersion,
        title: proposal.title,
        type: proposal.type,
        body: proposal.body,
        acceptanceCriteria: proposal.acceptanceCriteria,
        priority: proposal.priority,
        rationale: proposal.rationale,
        dependencies: [],
        potentialDuplicates: [],
        splitRecommendation: nil,
        missingQuestions: []
      )
    )
    if currentDraftSnapshot != base {
      refinementConflictMessage =
        "The ticket changed after your message was sent. Review or save those changes, then ask again before accepting this proposal."
    } else if model.workItems.first(where: { $0.id == itemID })?.version
      != proposal.baseVersion
    {
      refinementConflictMessage =
        "The saved ticket changed while this proposal was being prepared. Ask again before accepting it."
    } else {
      refinementConflictMessage = nil
    }
  }

  private func refinementCriteriaDescription(_ criteria: [String]) -> String {
    criteria.isEmpty ? "No acceptance criteria" : criteria.map { "• \($0)" }.joined(separator: "\n")
  }

  private func acceptRefinementField(_ field: TicketRefinementField) {
    guard
      refinementConflictMessage == nil,
      let proposal = refinementReply?.proposal
    else { return }
    switch field {
    case .title:
      title = proposal.title
    case .type:
      type = proposal.type
    case .context:
      bodyText = proposal.body
    case .acceptanceCriteria:
      criteria = proposal.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    case .priority:
      priority = proposal.priority
    }
    acceptedRefinementFields.insert(field)
    autoDismissRefinementReviewIfResolved()
  }

  private func acceptAllRefinementSuggestions(_ proposal: TicketRefinementProposal) {
    guard refinementConflictMessage == nil else { return }
    title = proposal.title
    type = proposal.type
    bodyText = proposal.body
    criteria = proposal.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    priority = proposal.priority
    acceptedRefinementFields.formUnion(TicketRefinementField.allCases)
    for dependency in proposal.dependencies
    where !dismissedDependencyKeys.contains(dependency.ticketKey) {
      if let relatedItem = model.workItems.first(where: { $0.key == dependency.ticketKey }) {
        blockerIDs.insert(relatedItem.id)
      }
    }
    refinementReply = nil
    refinementConflictMessage = nil
    model.dismissTicketAssistantResult(workItemID: itemID)
  }

  private func autoDismissRefinementReviewIfResolved() {
    guard
      let proposal = refinementReply?.proposal,
      let base = refinementBaseSnapshot
    else { return }
    let progress = refinementReviewProgress(proposal: proposal, base: base)
    guard progress.total > 0, progress.remaining == 0 else { return }
    refinementReply = nil
    refinementConflictMessage = nil
    model.dismissTicketAssistantResult(workItemID: itemID)
  }

  private func refinementReviewProgress(
    proposal: TicketRefinementProposal,
    base: SprintPlanningTicketSnapshot
  ) -> (total: Int, remaining: Int, dismissed: Int) {
    let fieldChanges = refinementFieldChanges(proposal: proposal, base: base)
    let remainingFields = fieldChanges.filter {
      !acceptedRefinementFields.contains($0.field)
    }.count
    let dependencyStates = proposal.dependencies.map {
      dependency -> (applied: Bool, dismissed: Bool) in
      let relatedItem = model.workItems.first { $0.key == dependency.ticketKey }
      return (
        relatedItem.map { blockerIDs.contains($0.id) } ?? false,
        dismissedDependencyKeys.contains(dependency.ticketKey)
      )
    }
    let remainingDependencies = dependencyStates.filter {
      !$0.applied && !$0.dismissed
    }.count
    let dismissedDependencies = dependencyStates.filter(\.dismissed).count
    return (
      total: fieldChanges.count + proposal.dependencies.count,
      remaining: remainingFields + remainingDependencies,
      dismissed: dismissedDependencies
    )
  }

  private func candidateStatus(for item: WorkItem) -> String {
    let candidateIDs = Set(model.candidateSprintPlan?.items.map(\.workItemID) ?? [])
    return candidateIDs.contains(item.id) ? "Next sprint" : "Backlog"
  }

  private func save() {
    isSaving = true
    let shouldSaveTicketFields = ticketFieldsHaveUnsavedChanges
    let shouldSaveAssignment = assignmentHasUnsavedChanges
    let selectedAssigneeID = assigneeID
    Task {
      var saved = true
      if shouldSaveTicketFields {
        saved = await model.updateWorkItem(
          productID: productID,
          id: itemID,
          title: title,
          type: type,
          body: bodyText,
          acceptanceCriteria: parsedCriteria,
          priority: priority,
          customFields: draftCustomFields,
          dependsOnWorkItemIDs: blockerIDs
        )
      }
      if saved, shouldSaveAssignment {
        saved = await model.assignTicketOwner(
          productID: productID,
          workItemID: itemID,
          to: selectedAssigneeID
        )
      }
      isSaving = false
      if saved {
        model.dismissTicketAssistantResult(workItemID: itemID)
        dismiss()
      }
    }
  }
}

enum TicketConversationHistory {
  static func displayedComments(
    from comments: [TicketComment],
    pendingQuestionID: UUID?,
    analystName: String?
  ) -> [TicketComment] {
    var displayed: [TicketComment] = []
    let explicitlyAnsweredQuestions = Set(
      comments.flatMap { comment in
        comment.answeredQuestions.map(\.question)
      }
    )

    for comment in comments where comment.id != pendingQuestionID {
      var presentedComment = comment
      var answeredQuestions = comment.answeredQuestions

      if answeredQuestions.isEmpty,
        comment.authorKind == .owner,
        let analystName,
        let questionComment = displayed.last,
        questionComment.authorKind == .agent,
        questionComment.authorName == analystName
      {
        let questions = TicketRefinementQuestion.parseTicketCommentBody(
          questionComment.body
        )
        if questions.allSatisfy({ !explicitlyAnsweredQuestions.contains($0) }) {
          answeredQuestions = inferredAnswers(
            to: questions,
            from: comment.body,
            analystName: analystName
          )
        }
        if !answeredQuestions.isEmpty {
          presentedComment = TicketComment(
            id: comment.id,
            workItemID: comment.workItemID,
            authorKind: comment.authorKind,
            authorName: comment.authorName,
            body: comment.body,
            ownerQuestion: comment.ownerQuestion,
            answeredQuestions: answeredQuestions,
            authorAvatarURL: comment.authorAvatarURL,
            externalURL: comment.externalURL,
            externalID: comment.externalID,
            githubReviewContext: comment.githubReviewContext,
            createdAt: comment.createdAt
          )
        }
      }

      if !answeredQuestions.isEmpty,
        let analystName,
        let questionIndex = displayed.lastIndex(where: { comment in
          guard
            comment.authorKind == .agent,
            comment.authorName == analystName
          else { return false }
          return TicketRefinementQuestion.parseTicketCommentBody(comment.body)
            == answeredQuestions.map(\.question)
        })
      {
        displayed.remove(at: questionIndex)
      }

      displayed.append(presentedComment)
    }

    return displayed
  }

  static func pendingQuestionInsertionIndex(
    in displayedComments: [TicketComment],
    sourceComments: [TicketComment],
    pendingQuestionID: UUID
  ) -> Int? {
    guard
      let questionIndex = sourceComments.firstIndex(where: {
        $0.id == pendingQuestionID
      })
    else { return nil }

    let laterCommentIDs = Set(
      sourceComments[sourceComments.index(after: questionIndex)...].map(\.id)
    )
    return displayedComments.firstIndex(where: {
      laterCommentIDs.contains($0.id)
    }) ?? displayedComments.endIndex
  }

  private static func inferredAnswers(
    to questions: [TicketRefinementQuestion],
    from ownerCommentBody: String,
    analystName: String
  ) -> [TicketAnsweredQuestion] {
    guard !questions.isEmpty else { return [] }
    let mention = "@\(analystName) "
    guard ownerCommentBody.hasPrefix(mention) else { return [] }
    let response = String(ownerCommentBody.dropFirst(mention.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !response.isEmpty else { return [] }

    let answers: [String]
    if questions.count == 1 {
      answers = [response]
    } else {
      let lines = response.components(separatedBy: .newlines)
      guard lines.count == questions.count else { return [] }
      answers = lines.enumerated().compactMap { index, line in
        let prefix = "\(index + 1). "
        guard line.hasPrefix(prefix) else { return nil }
        let answer = String(line.dropFirst(prefix.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
      }
      guard answers.count == questions.count else { return [] }
    }

    return zip(questions, answers).map { question, answer in
      TicketAnsweredQuestion(
        question: question,
        selectedOption: question.options.contains(answer) ? answer : nil,
        answer: answer
      )
    }
  }
}

struct ConversationEmptyState: View {
  let detail: String

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.title3)
        .foregroundStyle(.tertiary)
      Text("No messages yet")
        .font(.subheadline.weight(.medium))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct TeamConversationComposer: View {
  let profiles: [AgentProfile]
  @Binding var recipientID: UUID?
  @Binding var message: String
  let isSending: Bool
  let isResponding: Bool
  let sendError: String?
  let onSend: () -> Void
  var allowsRecipientSelection = true
  @FocusState private var isFocused: Bool

  private var selectedRecipient: AgentProfile? {
    guard let recipientID else { return nil }
    return profiles.first { $0.id == recipientID }
  }

  private var canSend: Bool {
    selectedRecipient != nil
      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSending
      && !isResponding
  }

  private func recipientLabel(showsDisclosureIndicator: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: selectedRecipient?.role.symbolName ?? "person")
        .foregroundStyle(selectedRecipient?.role.tint ?? Color.secondary)
      Text(selectedRecipient?.name ?? "Choose a team member")
        .foregroundStyle(selectedRecipient?.role.tint ?? Color.secondary)
      if showsDisclosureIndicator {
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(
      (selectedRecipient?.role.tint ?? Color.secondary).opacity(0.1),
      in: Capsule()
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("To")
          .font(.caption)
          .foregroundStyle(.secondary)
        if allowsRecipientSelection {
          Menu {
            ForEach(profiles) { profile in
              Button {
                recipientID = profile.id
              } label: {
                HStack {
                  Label(profile.name, systemImage: profile.role.symbolName)
                  if recipientID == profile.id {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          } label: {
            recipientLabel(showsDisclosureIndicator: true)
          }
          .menuStyle(.borderlessButton)
        } else {
          recipientLabel(showsDisclosureIndicator: false)
            .help("Replies stay with this thread's team member")
        }
        Spacer()
      }

      if let sendError {
        Label(sendError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      ZStack(alignment: .topLeading) {
        if message.isEmpty && !isFocused {
          Text("Ask a question or discuss a change…")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }
        TextEditor(text: $message)
          .scrollContentBackground(.hidden)
          .font(.body)
          .focused($isFocused)
          .padding(8)
          .onKeyPress(phases: .down) { keyPress in
            guard keyPress.key == .return else {
              return .ignored
            }
            if keyPress.modifiers.contains(.shift) {
              return .ignored
            }
            if canSend {
              onSend()
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
        Text("Return to send · Shift-Return for a new line")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        Button(isSending ? "Sending…" : "Send", action: onSend)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!canSend)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.25))
  }
}

struct ConversationRespondingStatus: View {
  let profile: AgentProfile?
  let fallbackName: String
  let status: String
  var activity: CodexLiveActivity? = nil
  let onStop: () -> Void

  var body: some View {
    let tint = profile?.role.tint ?? Color.purple
    HStack(spacing: 7) {
      if let activity {
        Image(systemName: activity.kind.symbolName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
          .frame(width: 14)
      } else {
        ProgressView()
          .controlSize(.mini)
          .tint(tint)
      }
      HStack(spacing: 0) {
        Text(profile?.name ?? fallbackName)
          .fontWeight(.semibold)
          .foregroundStyle(tint)
        Text(activity.map { " · \($0.text)" } ?? " \(status)")
          .foregroundStyle(.primary)
      }
      .font(.caption)
      .lineLimit(2)
      Spacer()
      Button("Stop", action: onStop)
        .controlSize(.mini)
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
    .background(tint.opacity(0.075))
  }
}

enum ConversationTimelineScrollTarget: Hashable {
  case message(UUID)
  case questions(UUID, [TicketRefinementQuestion])
  case review(UUID)

  static func latest(
    scopeID: UUID,
    lastMessageID: UUID?,
    messageCount: Int,
    questions: [TicketRefinementQuestion],
    pendingQuestionInsertionIndex: Int?,
    showsReview: Bool = false
  ) -> Self? {
    if showsReview {
      return .review(scopeID)
    }
    if !questions.isEmpty,
      pendingQuestionInsertionIndex == nil
        || pendingQuestionInsertionIndex == messageCount
    {
      return .questions(scopeID, questions)
    }
    return lastMessageID.map(Self.message)
  }
}

@MainActor
func scrollConversation(
  _ proxy: ScrollViewProxy,
  to target: ConversationTimelineScrollTarget?
) {
  guard let target else { return }
  Task { @MainActor in
    await Task.yield()
    withAnimation(.easeOut(duration: 0.18)) {
      proxy.scrollTo(target, anchor: .top)
    }
  }
}

struct TicketConversationView<ReviewContent: View>: View {
  @EnvironmentObject private var model: AppModel
  let workItemID: UUID
  let productID: UUID
  let ticketSnapshot: SprintPlanningTicketSnapshot?
  let refreshToken: Int
  let showsReview: Bool
  let isAgentResponding: Bool
  let refinementQuestions: [TicketRefinementQuestion]
  let onStopRefinement: () -> Void
  let onRefinementAnswer: ((String) async -> Void)?
  let onChatProposal:
    (SprintPlanningTicketProposal, SprintPlanningTicketSnapshot, AgentProfile) -> Void
  let reviewContent: ReviewContent
  @State private var comments: [TicketComment] = []
  @State private var message = ""
  @State private var recipientID: UUID?
  @State private var isSending = false
  @State private var respondingRecipientID: UUID?
  @State private var sendError: String?
  @State private var selectedRefinementOptions: [Int: String] = [:]
  @State private var otherRefinementAnswers: [Int: String] = [:]
  @State private var hasSubmittedRefinementAnswers = false

  private var isAwaitingRefinementAnswer: Bool {
    !refinementQuestions.isEmpty
  }

  private var isShowingRefinementChoices: Bool {
    isAwaitingRefinementAnswer && !hasSubmittedRefinementAnswers
  }

  private var businessAnalyst: AgentProfile? {
    model.profiles.first { $0.role == .businessAnalyst }
  }

  private var selectedRecipient: AgentProfile? {
    guard let recipientID else { return nil }
    return model.profiles.first { $0.id == recipientID }
  }

  private var respondingRecipient: AgentProfile? {
    let activeRecipientID =
      respondingRecipientID
      ?? (model.ticketConversationWorkItemID == workItemID
        ? model.ticketConversationRecipientID
        : nil)
    guard let activeRecipientID else { return nil }
    return model.profiles.first { $0.id == activeRecipientID }
  }

  private var activeStatusProfile: AgentProfile? {
    isAgentResponding ? businessAnalyst : respondingRecipient
  }

  private var isAnyAgentResponding: Bool {
    isAgentResponding || respondingRecipient != nil
  }

  private var otherChoiceKey: String { "\u{0}other" }

  private var canSubmitRefinementAnswers: Bool {
    !refinementQuestions.isEmpty
      && businessAnalyst != nil
      && refinementQuestions.indices.allSatisfy { index in
        guard let selection = selectedRefinementOptions[index] else { return false }
        return selection != otherChoiceKey
          || !(otherRefinementAnswers[index] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      && !isSending
      && !isAnyAgentResponding
  }

  private var displayedComments: [TicketComment] {
    TicketConversationHistory.displayedComments(
      from: comments,
      pendingQuestionID: pendingRefinementComment?.id,
      analystName: businessAnalyst?.name
    )
  }

  private var pendingRefinementComment: TicketComment? {
    guard
      isShowingRefinementChoices,
      let analystName = businessAnalyst?.name
    else { return nil }
    return comments.last { comment in
      comment.authorKind == .agent
        && comment.authorName == analystName
        && TicketRefinementQuestion.parseTicketCommentBody(comment.body)
          == refinementQuestions
    }
  }

  private var pendingRefinementInsertionIndex: Int? {
    guard let pendingRefinementComment else { return nil }
    return TicketConversationHistory.pendingQuestionInsertionIndex(
      in: displayedComments,
      sourceComments: comments,
      pendingQuestionID: pendingRefinementComment.id
    )
  }

  private var latestScrollTarget: ConversationTimelineScrollTarget? {
    let displayedComments = displayedComments
    return ConversationTimelineScrollTarget.latest(
      scopeID: workItemID,
      lastMessageID: displayedComments.last?.id,
      messageCount: displayedComments.count,
      questions: isShowingRefinementChoices ? refinementQuestions : [],
      pendingQuestionInsertionIndex: pendingRefinementInsertionIndex,
      showsReview: showsReview
    )
  }

  private var showsEmptyConversation: Bool {
    displayedComments.isEmpty
      && !showsReview
      && !isShowingRefinementChoices
  }

  private var defaultRecipient: AgentProfile? {
    if let sprintItem =
      (model.candidateSprintPlan?.items.first(where: { $0.workItemID == workItemID })
        ?? model.sprintPlan?.items.first(where: { $0.workItemID == workItemID })),
      let implementerID = sprintItem.implementerProfileID,
      let assignedImplementer = model.profiles.first(where: {
        $0.id == implementerID
      })
    {
      return assignedImplementer
    }
    return model.profiles.first { $0.role == .businessAnalyst }
      ?? model.profiles.first { $0.role == .lead }
      ?? model.profiles.first
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
            ForEach(Array(displayedComments.enumerated()), id: \.element.id) {
              index,
              comment in
              if pendingRefinementInsertionIndex == index {
                refinementQuestionCards
              }

              Group {
                if comment.answeredQuestions.isEmpty {
                  TicketCommentBubble(
                    comment: comment,
                    authorProfile: model.profiles.first { $0.name == comment.authorName },
                    mentionedProfile: mentionedProfile(
                      in: comment.body,
                      profiles: model.profiles
                    )
                  )
                } else {
                  answeredRefinementQuestionCards(comment.answeredQuestions)
                }
              }
              .id(ConversationTimelineScrollTarget.message(comment.id))
            }

            if isShowingRefinementChoices,
              pendingRefinementInsertionIndex == nil
                || pendingRefinementInsertionIndex == displayedComments.endIndex
            {
              refinementQuestionCards
            }

            if showsReview {
              reviewContent
                .id(ConversationTimelineScrollTarget.review(workItemID))
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
              detail: "Ask for clarification or request a ticket review."
            )
          }
        }
        .onChange(of: latestScrollTarget, initial: true) { _, target in
          scrollConversation(proxy, to: target)
        }
      }

      Divider()

      if isShowingRefinementChoices && !isAnyAgentResponding {
        let tint = businessAnalyst?.role.tint ?? Color.purple
        HStack(spacing: 8) {
          Image(systemName: "questionmark.bubble.fill")
            .foregroundStyle(tint)
          HStack(spacing: 0) {
            Text(businessAnalyst?.name ?? "Business analyst")
              .fontWeight(.semibold)
              .foregroundStyle(tint)
            Text(
              canSubmitRefinementAnswers
                ? " has your answers."
                : " is waiting for your response."
            )
            .foregroundStyle(.primary)
          }
          .font(.caption)
          Spacer()
          Button {
            submitRefinementAnswers()
          } label: {
            Label("Submit answers", systemImage: "paperplane.fill")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
          .disabled(!canSubmitRefinementAnswers)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(tint.opacity(0.075))
      } else if isAnyAgentResponding {
        let teammate = activeStatusProfile ?? businessAnalyst
        ConversationRespondingStatus(
          profile: teammate,
          fallbackName: "Business analyst",
          status:
            isAgentResponding
            ? isAwaitingRefinementAnswer
              ? "is reviewing your response…"
              : "is reviewing this ticket…"
            : "is thinking…",
          activity:
            isAgentResponding
            ? nil
            : model.ticketConversationActivity,
          onStop: {
            if isAgentResponding {
              onStopRefinement()
            } else {
              model.cancelTicketConversationMessage()
            }
          }
        )
      }

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
    .task(id: refreshToken) {
      comments = await model.comments(for: workItemID, productID: productID)
      if recipientID == nil {
        recipientID = defaultRecipient?.id
      }
    }
    .onChange(of: model.ticketConversationWorkItemID) { previousID, currentID in
      guard previousID == workItemID || currentID == workItemID else { return }
      Task {
        comments = await model.comments(for: workItemID, productID: productID)
      }
    }
    .onChange(of: refinementQuestions) { _, _ in
      selectedRefinementOptions.removeAll()
      otherRefinementAnswers.removeAll()
      hasSubmittedRefinementAnswers = false
    }
  }

  private var refinementQuestionCards: some View {
    MultipleChoiceQuestionCards(
      questions: refinementQuestions,
      selectedOptions: $selectedRefinementOptions,
      otherAnswers: $otherRefinementAnswers,
      otherChoiceKey: otherChoiceKey,
      tint: businessAnalyst?.role.tint ?? Color.purple
    )
    .id(ConversationTimelineScrollTarget.questions(workItemID, refinementQuestions))
  }

  private func answeredRefinementQuestionCards(
    _ answeredQuestions: [TicketAnsweredQuestion]
  ) -> some View {
    MultipleChoiceQuestionCards(
      answeredQuestions: answeredQuestions,
      tint: businessAnalyst?.role.tint ?? Color.purple
    )
  }

  private func submitRefinementAnswers() {
    guard canSubmitRefinementAnswers else { return }
    let answeredQuestions = refinementQuestions.enumerated().map { index, question in
      let selection = selectedRefinementOptions[index] ?? ""
      let answer =
        selection == otherChoiceKey
        ? (otherRefinementAnswers[index] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        : selection
      return TicketAnsweredQuestion(
        question: question,
        selectedOption: selection == otherChoiceKey ? nil : selection,
        answer: answer
      )
    }
    let selectedAnswers = answeredQuestions.map(\.answer)
    let answer =
      selectedAnswers.count == 1
      ? selectedAnswers[0]
      : selectedAnswers.enumerated().map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")
    guard let businessAnalyst else { return }
    hasSubmittedRefinementAnswers = true
    isSending = true
    sendError = nil
    Task {
      let body = "@\(businessAnalyst.name) \(answer)"
      if let comment = await model.appendOwnerComment(
        workItemID: workItemID,
        productID: productID,
        body: body,
        answeredQuestions: answeredQuestions
      ) {
        comments.append(comment)
        await onRefinementAnswer?(answer)
        comments = await model.comments(for: workItemID, productID: productID)
      } else {
        sendError = model.errorMessage ?? "Your answers couldn't be saved. Try again."
        hasSubmittedRefinementAnswers = false
      }
      isSending = false
    }
  }

  private func send() {
    let ownerMessage =
      message
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let recipient = selectedRecipient,
      !ownerMessage.isEmpty,
      !isSending,
      !isAnyAgentResponding
    else { return }
    isSending = true
    sendError = nil
    respondingRecipientID = recipient.id
    let body = "@\(recipient.name) \(ownerMessage)"
    Task {
      if let comment = await model.appendOwnerComment(
        workItemID: workItemID,
        productID: productID,
        body: body
      ) {
        comments.append(comment)
        message = ""
        if let savedItem = model.workItems.first(where: { $0.id == workItemID }) {
          do {
            let savedSnapshot = SprintPlanningTicketSnapshot(item: savedItem)
            let base =
              if let ticketSnapshot, ticketSnapshot.version == savedItem.version {
                ticketSnapshot
              } else {
                savedSnapshot
              }
            let conversationItem = base.applying(to: savedItem)
            let reply = try await model.sendTicketConversationMessage(
              for: conversationItem,
              to: recipient,
              ownerMessage: ownerMessage
            )
            if let proposal = reply.proposal {
              onChatProposal(proposal, base, recipient)
            }
          } catch {
            sendError = error.localizedDescription
          }
        } else {
          sendError = "This ticket is no longer available."
        }
        comments = await model.comments(for: workItemID, productID: productID)
      } else {
        sendError = model.errorMessage ?? "Your message couldn't be saved. Try again."
      }
      respondingRecipientID = nil
      isSending = false
    }
  }
}

struct RefinementChoiceButtonStyle: ButtonStyle {
  let tint: Color
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        isSelected
          ? tint.opacity(configuration.isPressed ? 0.24 : 0.16)
          : Color(nsColor: .controlBackgroundColor)
            .opacity(configuration.isPressed ? 0.72 : 0.52),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isSelected
              ? tint.opacity(0.55)
              : Color.primary.opacity(0.10),
            lineWidth: isSelected ? 1.2 : 0.8
          )
      }
      .scaleEffect(configuration.isPressed ? 0.992 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

struct MultipleChoiceQuestionCards: View {
  private enum Presentation {
    case unanswered([TicketRefinementQuestion])
    case answered([TicketAnsweredQuestion])
  }

  private let presentation: Presentation
  private let otherChoiceKey: String
  private let tint: Color
  @Binding private var selectedOptions: [Int: String]
  @Binding private var otherAnswers: [Int: String]

  init(
    questions: [TicketRefinementQuestion],
    selectedOptions: Binding<[Int: String]>,
    otherAnswers: Binding<[Int: String]>,
    otherChoiceKey: String,
    tint: Color
  ) {
    presentation = .unanswered(questions)
    _selectedOptions = selectedOptions
    _otherAnswers = otherAnswers
    self.otherChoiceKey = otherChoiceKey
    self.tint = tint
  }

  init(
    answeredQuestions: [TicketAnsweredQuestion],
    tint: Color
  ) {
    presentation = .answered(answeredQuestions)
    _selectedOptions = .constant([:])
    _otherAnswers = .constant([:])
    otherChoiceKey = ""
    self.tint = tint
  }

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .unanswered(let questions):
      unansweredQuestionCards(questions)
    case .answered(let answeredQuestions):
      answeredQuestionCards(answeredQuestions)
    }
  }

  private func unansweredQuestionCards(
    _ questions: [TicketRefinementQuestion]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        VStack(alignment: .leading, spacing: 9) {
          if questions.count > 1 {
            Text("Question \(index + 1) of \(questions.count)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(tint)
          }
          Text(question.prompt)
            .font(.callout.weight(.medium))
          VStack(spacing: 6) {
            ForEach(question.options, id: \.self) { option in
              choiceRow(option, selected: selectedOptions[index] == option) {
                selectedOptions[index] = option
              }
            }
            choiceRow("Other", selected: selectedOptions[index] == otherChoiceKey) {
              selectedOptions[index] = otherChoiceKey
            }
          }
          if selectedOptions[index] == otherChoiceKey {
            TextField(
              "Type another answer",
              text: Binding(
                get: { otherAnswers[index] ?? "" },
                set: { otherAnswers[index] = $0 }
              )
            )
            .textFieldStyle(.roundedBorder)
          }
        }
        .padding(11)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 11))
      }
    }
  }

  private func answeredQuestionCards(
    _ answeredQuestions: [TicketAnsweredQuestion]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(answeredQuestions.enumerated()), id: \.offset) { index, answered in
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(
              answeredQuestions.count > 1
                ? "Question \(index + 1) of \(answeredQuestions.count)"
                : "Answered"
            )
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(tint)

          Text(answered.question.prompt)
            .font(.callout.weight(.medium))

          VStack(spacing: 6) {
            ForEach(answered.question.options, id: \.self) { option in
              readOnlyChoiceRow(
                option,
                selected: answered.selectedOption == option
              )
            }
            readOnlyChoiceRow(
              "Other",
              selected: answered.selectedOption == nil
            )
          }

          if answered.selectedOption == nil {
            Text(answered.answer)
              .font(.callout)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                tint.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
              )
          }
        }
        .padding(11)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
      }
    }
  }

  private func readOnlyChoiceRow(_ label: String, selected: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .font(.caption)
        .foregroundStyle(selected ? tint : Color.secondary.opacity(0.65))
      Text(label)
        .font(.callout)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      selected ? tint.opacity(0.14) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 8)
    )
  }

  private func choiceRow(
    _ label: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .font(.caption)
          .foregroundStyle(selected ? tint : Color.secondary)
        Text(label)
          .font(.callout)
          .foregroundStyle(Color.primary)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        selected ? tint.opacity(0.14) : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 8)
      )
    }
    .buttonStyle(.plain)
  }
}

func mentionedProfile(
  in body: String,
  profiles: [AgentProfile]
) -> AgentProfile? {
  profiles
    .sorted { $0.name.count > $1.name.count }
    .first { body.hasPrefix("@\($0.name) ") }
}

enum ConversationPalette {
  static let owner = Color(nsColor: .secondaryLabelColor)
}

struct TeamConversationMessageBubble: View {
  let authorKind: CommentAuthorKind
  let authorName: String
  let messageBody: String
  let createdAt: Date
  let authorProfile: AgentProfile?
  let mentionedProfile: AgentProfile?

  init(
    authorKind: CommentAuthorKind,
    authorName: String,
    body: String,
    createdAt: Date,
    authorProfile: AgentProfile? = nil,
    mentionedProfile: AgentProfile? = nil
  ) {
    self.authorKind = authorKind
    self.authorName = authorName
    messageBody = body
    self.createdAt = createdAt
    self.authorProfile = authorProfile
    self.mentionedProfile = mentionedProfile
  }

  private var accent: Color {
    switch authorKind {
    case .owner: ConversationPalette.owner
    case .agent: authorProfile?.role.tint ?? .indigo
    case .external: .blue
    case .system: .secondary
    }
  }

  private var symbolName: String {
    switch authorKind {
    case .owner: "person.fill"
    case .agent: authorProfile?.role.symbolName ?? "sparkles"
    case .external: "person.crop.circle.badge.checkmark"
    case .system: "gearshape.fill"
    }
  }

  private var displayName: String {
    authorKind == .owner ? "Me" : authorName
  }

  private var isOwner: Bool {
    authorKind == .owner
  }

  private var avatar: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(0.13))
      Image(systemName: symbolName)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(accent)
    }
    .frame(width: 28, height: 28)
  }

  private var messageDocument: some View {
    SelectableTicketMarkdownDocument(
      source: messageBody,
      baseFont: .callout,
      highlightedText: mentionedProfile.map { "@\($0.name)" },
      highlightedColor: mentionedProfile?.role.tint
    )
  }

  private var messageContent: some View {
    VStack(alignment: isOwner ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 7) {
        if isOwner {
          Text(createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
        } else {
          Text(displayName)
            .font(
              authorKind == .agent
                ? .subheadline.weight(.semibold)
                : .caption.weight(.semibold)
            )
            .foregroundStyle(authorKind == .agent ? accent : Color.primary)
          if authorKind == .agent, let authorProfile {
            Image(systemName: authorProfile.role.symbolName)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(accent)
              .help(authorProfile.role.capabilityTitle)
          }
          Text(createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      ViewThatFits(in: .horizontal) {
        messageDocument
          .fixedSize(horizontal: true, vertical: true)
        messageDocument
      }
      .textSelection(.enabled)
      .multilineTextAlignment(.leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      .frame(maxWidth: 560, alignment: isOwner ? .trailing : .leading)
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      if isOwner {
        Spacer(minLength: 44)
        messageContent
        avatar
      } else {
        avatar
        messageContent
        Spacer(minLength: 44)
      }
    }
    .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
  }
}

struct TicketCommentBubble: View {
  let comment: TicketComment
  let authorProfile: AgentProfile?
  let mentionedProfile: AgentProfile?

  init(
    comment: TicketComment,
    authorProfile: AgentProfile? = nil,
    mentionedProfile: AgentProfile? = nil
  ) {
    self.comment = comment
    self.authorProfile = authorProfile
    self.mentionedProfile = mentionedProfile
  }

  var body: some View {
    TeamConversationMessageBubble(
      authorKind: comment.authorKind,
      authorName: comment.authorName,
      body: comment.body,
      createdAt: comment.createdAt,
      authorProfile: authorProfile,
      mentionedProfile: mentionedProfile
    )
  }
}

struct NewTicketView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let initialEpicID: UUID?
  let onCreated: (WorkItem, Bool) -> Void
  @State private var outcome = ""
  @State private var selectedEpicID: UUID?
  @State private var isCreating = false

  init(
    isPresented: Binding<Bool>,
    initialEpicID: UUID?,
    onCreated: @escaping (WorkItem, Bool) -> Void
  ) {
    _isPresented = isPresented
    self.initialEpicID = initialEpicID
    self.onCreated = onCreated
    _selectedEpicID = State(initialValue: initialEpicID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New ticket")
          .font(.title.bold())
        Text("Describe the outcome. The business analyst will shape the ticket for your review.")
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          EditableTextArea(
            title: "What do you want to achieve?",
            prompt: "e.g. Let customers search for a location and see its current weather.",
            text: $outcome,
            minHeight: 138,
            focusOnAppear: true
          )

          VStack(alignment: .leading, spacing: 7) {
            Text("Epic")
              .font(.subheadline.weight(.semibold))
            Picker("Epic", selection: $selectedEpicID) {
              Text("No epic").tag(UUID?.none)
              ForEach(model.openEpics) { epic in
                Text(epic.displayTitle).tag(Optional(epic.id))
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)
          }

          Label(
            model.canRefineTicket
              ? "The ticket is saved immediately, then the business analyst asks questions and proposes reviewable improvements."
              : "The ticket is saved as a draft. The business analyst review starts automatically when the team connection becomes available.",
            systemImage: "checkmark.shield"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(24)
      }

      Divider()
      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button {
          create()
        } label: {
          Label(isCreating ? "Creating…" : "Create ticket", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(!canCreate)
      }
      .padding(20)
    }
    .frame(width: 660, height: 470)
  }

  private var canCreate: Bool {
    !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
  }

  private func create() {
    guard canCreate else { return }
    isCreating = true
    Task {
      let item = await model.createWorkItem(
        title: outcome.trimmingCharacters(in: .whitespacesAndNewlines),
        type: .story,
        body: "",
        acceptanceCriteria: [],
        priority: .normal,
        dependsOnWorkItemIDs: [],
        epicID: selectedEpicID
      )
      isCreating = false
      if let item {
        onCreated(item, true)
      }
    }
  }
}

struct NewEpicView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var outcome = ""
  @State private var isCreating = false
  @State private var createdEpic: Epic?

  var body: some View {
    if let createdEpic {
      EpicDetailView(
        epic: createdEpic,
        onClose: { isPresented = false }
      )
    } else {
      captureView
    }
  }

  private var captureView: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New epic")
          .font(.title.bold())
        Text(
          "Describe the outcome. The business analyst will shape the epic and its tickets for your review."
        )
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        EditableTextArea(
          title: "What outcome do you want to deliver?",
          prompt: "e.g. Customers can save locations and quickly compare their forecasts.",
          text: $outcome,
          minHeight: 150,
          focusOnAppear: true
        )
        Label(
          model.canPlanEpic
            ? "The proposed title, success criteria, tickets, dependencies and owners remain reviewable."
            : "The outcome will be saved as a draft and can be planned when the team connection is available.",
          systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(24)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button {
          create()
        } label: {
          Label(isCreating ? "Creating…" : "Create epic", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(!canCreate)
      }
      .padding(20)
    }
    .frame(width: 660, height: 480)
  }

  private var canCreate: Bool {
    !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
  }

  private func create() {
    guard canCreate else { return }
    isCreating = true
    Task {
      let epic = await model.createEpic(
        outcome: outcome.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      isCreating = false
      if let epic {
        createdEpic = epic
      }
    }
  }
}
