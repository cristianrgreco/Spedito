import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Editable Ticket owner journeys")
struct EditableTicketJourneyTests {
  /// Existing evidence:
  /// - `SQLiteStoreTests.editableTicketDetailsAreDurable`
  /// - `CodexTransportApplicationTests.ticketRefinementAndConversationJourney`
  /// This journey adds only B01's manual creation-to-detail composition and a fresh-instance
  /// check at the riskiest boundary: after the Ticket is durable but before refinement begins.
  @Test("B01 a manually created Ticket opens directly into initial refinement")
  @MainActor
  func b01ManualTicketOpensInitialRefinement() async throws {
    let fixture = try DatabaseFixture(name: "B01")
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Manual Ticket")
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let epic = try #require(await model.createEpic(outcome: "Deliver saved searches"))

    let item = try #require(
      await model.createWorkItem(
        title: "Clarify saved search retention",
        type: .story,
        body: "",
        acceptanceCriteria: [],
        priority: .normal,
        dependsOnWorkItemIDs: [],
        epicID: epic.id
      )
    )
    let presentation = TicketDetailPresentation.newlyCreated(item)

    #expect(presentation.item.id == item.id)
    #expect(presentation.mode == .editable)
    #expect(presentation.startRefinementOnAppear)
    #expect(TicketEditorPresentationState.needsInitialRefinement(for: item))
    #expect(item.epicID == epic.id)

    await model.shutdown()
    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      try await reopened.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(recovered.title == "Clarify saved search retention")
    #expect(recovered.epicID == epic.id)
    #expect(TicketEditorPresentationState.needsInitialRefinement(for: recovered))
    await reopened.close()
  }

  /// Existing evidence:
  /// - `TicketRefinementApplicationTests.completedRefinementIsAppliedAsOneUpdate`
  /// - `SQLiteStoreTests.ticketEditVersionConflict`
  /// This journey adds only B04's field-level review, dismissed dependency, apply-all, explicit
  /// save, and fresh-instance recovery composition.
  @Test("B04 refinement suggestions remain reviewable until the owner saves selected changes")
  @MainActor
  func b04RefinementSuggestionsApplySelectivelyThenSave() async throws {
    let fixture = try DatabaseFixture(name: "B04")
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Selective refinement")
    let dismissedDependency = try await store.createWorkItem(
      productID: product.id,
      title: "Dismissed prerequisite"
    )
    let acceptedDependency = try await store.createWorkItem(
      productID: product.id,
      title: "Accepted prerequisite"
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Draft checkout",
      body: "Original context",
      acceptanceCriteria: ["Original outcome"]
    )
    let proposal = TicketRefinementProposal(
      baseVersion: item.version,
      title: "Complete checkout with a saved address",
      type: .story,
      body: "Let a returning customer choose a saved address.",
      acceptanceCriteria: ["The selected saved address is used for checkout"],
      priority: .high,
      rationale: "The owner outcome is now testable.",
      dependencies: [
        TicketRefinementDependencyProposal(
          ticketKey: dismissedDependency.key,
          reason: "This suggestion is not needed."
        ),
        TicketRefinementDependencyProposal(
          ticketKey: acceptedDependency.key,
          reason: "The address contract is required."
        ),
      ],
      potentialDuplicates: [],
      splitRecommendation: nil,
      missingQuestions: []
    )
    var state = TicketEditorPresentationState(item: item, dependsOnWorkItemIDs: [])

    state.apply(field: .title, from: proposal)
    #expect(state.title == proposal.title)
    #expect(state.bodyText == item.body)
    let unchangedAfterOneField = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(unchangedAfterOneField.version == item.version)
    #expect(unchangedAfterOneField.title == item.title)

    state.applyAll(
      from: proposal,
      workItems: [dismissedDependency, acceptedDependency, item],
      dismissedDependencyKeys: [dismissedDependency.key]
    )
    #expect(state.bodyText == proposal.body)
    #expect(state.parsedAcceptanceCriteria == proposal.acceptanceCriteria)
    #expect(state.blockerIDs == [acceptedDependency.id])

    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let saved = await model.updateWorkItem(
      productID: product.id,
      id: item.id,
      title: state.title,
      type: state.type,
      body: state.bodyText,
      acceptanceCriteria: state.parsedAcceptanceCriteria,
      priority: state.priority,
      customFields: state.normalizedCustomFields,
      dependsOnWorkItemIDs: state.blockerIDs,
      expectedVersion: item.version
    )
    #expect(saved)

    await model.shutdown()
    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      try await reopened.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    let recoveredDependencies = try await reopened.fetchWorkItemDependencies(
      productID: product.id
    )
    #expect(recovered.title == proposal.title)
    #expect(recovered.body == proposal.body)
    #expect(recovered.acceptanceCriteria == proposal.acceptanceCriteria)
    #expect(
      recoveredDependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
        == [acceptedDependency.id]
    )
    await reopened.close()
  }

  /// Existing evidence:
  /// - `CodexTransportApplicationTests.ticketRefinementAndConversationJourney`
  /// - `TicketRefinementApplicationTests.b05StaleCompletionPreservesNewerDraft`
  /// The first test proves real team-member prose is durable and survives relaunch. This journey
  /// adds only B06's proposal-to-editor composition and explicit Save boundary.
  @Test("B06 team prose changes nothing and accepted proposal fields wait for Save")
  @MainActor
  func b06TeamProposalFieldsRemainUnsavedUntilSave() async throws {
    let fixture = try DatabaseFixture(name: "B06")
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Team review")
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Review account summary",
      body: "Original context",
      acceptanceCriteria: ["Original criterion"]
    )
    let prose = TicketConversationReply(message: "The current contract is clear.")
    #expect(prose.proposal == nil)
    let unchangedAfterProse = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(unchangedAfterProse.version == item.version)
    #expect(unchangedAfterProse.title == item.title)
    #expect(unchangedAfterProse.body == item.body)
    #expect(unchangedAfterProse.acceptanceCriteria == item.acceptanceCriteria)

    let conversationProposal = SprintPlanningTicketProposal(
      baseVersion: item.version,
      title: item.title,
      type: item.type,
      body: "Show the approved account summary.",
      acceptanceCriteria: ["The owner can verify the approved summary"],
      priority: .high,
      rationale: "The review clarified the visible outcome."
    )
    let proposal = TicketRefinementProposal(conversationProposal: conversationProposal)
    var state = TicketEditorPresentationState(item: item, dependsOnWorkItemIDs: [])
    state.apply(field: .context, from: proposal)
    state.apply(field: .acceptanceCriteria, from: proposal)

    #expect(state.bodyText == conversationProposal.body)
    #expect(state.parsedAcceptanceCriteria == conversationProposal.acceptanceCriteria)
    let unchangedBeforeSave = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(unchangedBeforeSave.version == item.version)
    #expect(unchangedBeforeSave.title == item.title)
    #expect(unchangedBeforeSave.body == item.body)
    #expect(unchangedBeforeSave.acceptanceCriteria == item.acceptanceCriteria)

    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let saved = await model.updateWorkItem(
      productID: product.id,
      id: item.id,
      title: state.title,
      type: state.type,
      body: state.bodyText,
      acceptanceCriteria: state.parsedAcceptanceCriteria,
      priority: state.priority,
      customFields: state.normalizedCustomFields,
      dependsOnWorkItemIDs: state.blockerIDs,
      expectedVersion: item.version
    )
    #expect(saved)
    let storedAfterSave = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(storedAfterSave.body == conversationProposal.body)
    #expect(storedAfterSave.acceptanceCriteria == conversationProposal.acceptanceCriteria)
    await model.shutdown()
    await store.close()
  }

  /// Existing evidence:
  /// - `SQLiteStoreTests.editableTicketDetailsAreDurable`
  /// - `SQLiteStoreTests.ownerManagedBlockers`
  /// - `TicketRefinementApplicationTests.completedRefinementUpdatesDraftSprintAssignee`
  /// This journey adds only B07's complete editor composition, validation that preserves the
  /// draft, explicit Save, and fresh-instance recovery.
  @Test("B07 every editable Ticket field validates and survives Save and relaunch")
  @MainActor
  func b07EditableTicketFieldsValidateAndPersist() async throws {
    let fixture = try DatabaseFixture(name: "B07")
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Editable Ticket")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let blocker = try await store.createWorkItem(
      productID: product.id,
      title: "Define storage"
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Draft saved searches"
    )
    var state = TicketEditorPresentationState(item: item, dependsOnWorkItemIDs: [])
    state.title = "Show saved searches"
    state.type = .task
    state.bodyText = "List the owner's saved searches."
    state.criteria = [
      AcceptanceCriterionDraft(text: "Saved searches are visible"),
      AcceptanceCriterionDraft(text: "  Empty criteria are ignored  "),
    ]
    state.priority = .high
    state.assigneeID = implementer.id
    state.blockerIDs = [blocker.id]
    state.customFields = [
      TicketCustomFieldDraft(name: "Region", value: " UK "),
      TicketCustomFieldDraft(name: "region", value: "US"),
    ]

    let duplicateDraft = state
    #expect(!state.isValidForSave)
    #expect(state.duplicateCustomFieldNames == ["Region", "region"])
    #expect(state == duplicateDraft)

    state.customFields = [
      TicketCustomFieldDraft(name: "", value: "Invalid")
    ]
    let invalidDraft = state
    #expect(!state.isValidForSave)
    #expect(state == invalidDraft)

    state.customFields = [
      TicketCustomFieldDraft(name: "Market", value: " UK "),
      TicketCustomFieldDraft(name: "Owner note", value: " Reviewable "),
    ]
    #expect(state.isValidForSave)

    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let saved = await model.updateWorkItem(
      productID: product.id,
      id: item.id,
      title: state.title,
      type: state.type,
      body: state.bodyText,
      acceptanceCriteria: state.parsedAcceptanceCriteria,
      priority: state.priority,
      customFields: state.normalizedCustomFields,
      dependsOnWorkItemIDs: state.blockerIDs,
      expectedVersion: item.version
    )
    #expect(saved)
    #expect(
      await model.assignTicketOwner(
        productID: product.id,
        workItemID: item.id,
        to: state.assigneeID
      )
    )

    await model.shutdown()
    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try #require(
      try await reopened.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    let recoveredDependencies = try await reopened.fetchWorkItemDependencies(
      productID: product.id
    )
    #expect(recovered.title == state.title)
    #expect(recovered.type == state.type)
    #expect(recovered.body == state.bodyText)
    #expect(recovered.acceptanceCriteria == state.parsedAcceptanceCriteria)
    #expect(recovered.priority == state.priority)
    #expect(recovered.ownerProfileID == implementer.id)
    #expect(recovered.customFields == ["Market": "UK", "Owner note": "Reviewable"])
    #expect(
      recoveredDependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
        == [blocker.id]
    )
    await reopened.close()
  }

  /// Existing evidence:
  /// - `EpicPlanningPresentationTests.ticketDetailsResolveEpic`
  /// - `EpicPlanningPresentationTests.relationshipLinksResolveRelatedTicket`
  /// - `TicketRefinementApplicationTests.b05StaleCompletionPreservesNewerDraft`
  /// This test adds only B08's exact open-and-return composition on the editor state that owns
  /// unsaved fields and linked destinations.
  @Test("B08 linked Epic and Ticket navigation preserves unsaved Ticket edits")
  func b08LinkedNavigationPreservesUnsavedEdits() throws {
    let productID = UUID()
    let epic = Epic(
      productID: productID,
      title: "Saved searches",
      goal: "Deliver saved search management"
    )
    let source = WorkItem(
      productID: productID,
      key: "T1",
      title: "Original title",
      epicID: epic.id
    )
    let blocker = WorkItem(
      productID: productID,
      key: "T2",
      title: "Define storage"
    )
    var state = TicketEditorPresentationState(
      item: source,
      dependsOnWorkItemIDs: [blocker.id]
    )
    state.title = "Unsaved owner title"
    state.bodyText = "Unsaved owner context"

    state.open(epic: epic)
    guard case .epic(let openedEpic) = state.linkedDestination else {
      Issue.record("B08 did not open the linked Epic")
      return
    }
    #expect(openedEpic.id == epic.id)
    state.linkedDestination = nil
    #expect(state.title == "Unsaved owner title")
    #expect(state.bodyText == "Unsaved owner context")

    state.openRelationship(id: blocker.id, source: source, workItems: [source, blocker])
    guard case .ticket(let openedTicket) = state.linkedDestination else {
      Issue.record("B08 did not open the linked Ticket")
      return
    }
    #expect(openedTicket.id == blocker.id)
    state.linkedDestination = nil
    #expect(state.title == "Unsaved owner title")
    #expect(state.bodyText == "Unsaved owner context")
    #expect(state.blockerIDs == [blocker.id])
  }

  /// Existing evidence:
  /// - `SQLiteStoreTests.dependencyAwareRanking`
  /// - `PlanningDropPolicyTests.placementPreviewsIdentifyValidRange`
  /// - `PlanningDropPolicyTests.repeatedInvalidPreviewRemainsInvalid`
  /// This journey adds only B10's durable valid reorder and fresh-instance boundary; the cited
  /// tests retain exact invalid drag and top/bottom dependency behavior.
  @Test("B10 backlog reorder persists without weakening dependency order")
  func b10BacklogReorderPersistsDependencyOrder() async throws {
    let fixture = try DatabaseFixture(name: "B10")
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Backlog ordering")
    let prerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Define storage"
    )
    let dependant = try await store.createWorkItem(
      productID: product.id,
      title: "Build saved searches",
      dependsOnWorkItemIDs: [prerequisite.id]
    )
    let independent = try await store.createWorkItem(
      productID: product.id,
      title: "Document saved searches"
    )

    let reordered = try await store.moveWorkItems(ids: [independent.id], before: dependant.id)
    #expect(reordered.map(\.id) == [prerequisite.id, independent.id, dependant.id])
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recovered = try await reopened.fetchWorkItems(productID: product.id)
    #expect(recovered.map(\.id) == [prerequisite.id, independent.id, dependant.id])
    await #expect(throws: WorkItemRankingError.self) {
      _ = try await reopened.moveWorkItem(id: dependant.id, to: .top)
    }
    await #expect(throws: WorkItemRankingError.self) {
      _ = try await reopened.moveWorkItem(id: prerequisite.id, to: .bottom)
    }
    #expect(
      try await reopened.fetchWorkItems(productID: product.id).map(\.id)
        == [prerequisite.id, independent.id, dependant.id]
    )
    await reopened.close()
  }

  /// Existing evidence:
  /// - `SQLiteStoreTests.ownerManagedBlockers`
  /// - `SQLiteStoreTests.bulkArchiveWorkItems`
  /// This journey adds only B11's explicit confirmation gate and the combined active-planning,
  /// dependency-choice, suggestion, history, and fresh-instance archive projection.
  @Test("B11 confirmed Ticket archive leaves only historical evidence")
  func b11ConfirmedArchiveRemovesActiveTicketReferences() async throws {
    let fixture = try DatabaseFixture(name: "B11")
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Ticket archive")
    let archivedItem = try await store.createWorkItem(
      productID: product.id,
      title: "Retire obsolete search"
    )
    let remainingItem = try await store.createWorkItem(
      productID: product.id,
      title: "Keep current search"
    )
    let workLogEntry = try await store.appendComment(
      workItemID: archivedItem.id,
      authorKind: .owner,
      authorName: "Product owner",
      body: "Archive after the replacement is approved."
    )
    _ = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Keep active planning current",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: archivedItem.id, estimatedTokens: 1),
        SprintDraftItemInput(workItemID: remainingItem.id, estimatedTokens: 1),
      ]
    )
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    _ = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "Use the retired search contract",
          body: "Reference existing work.",
          acceptanceCriteria: ["The existing contract is reused"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "The proposal should stop showing an archived dependency.",
          dependsOnExistingWorkItemKeys: [archivedItem.key]
        )
      ]
    )

    var confirmation = TicketArchiveConfirmationState()
    confirmation.request([archivedItem])
    #expect(confirmation.isPresented)
    let beforeConfirmation = try #require(
      try await store.fetchWorkItems(productID: product.id).first {
        $0.id == archivedItem.id
      }
    )
    #expect(beforeConfirmation.state == .backlog)
    confirmation.cancel()
    #expect(!confirmation.isPresented)

    confirmation.request([archivedItem])
    let confirmedIDs = confirmation.confirm()
    #expect(confirmedIDs == [archivedItem.id])
    #expect(!confirmation.isPresented)
    try await store.archiveWorkItems(ids: Array(confirmedIDs))

    let storedItems = try await store.fetchWorkItems(productID: product.id)
    let archived = try #require(storedItems.first { $0.id == archivedItem.id })
    let currentPlan = try #require(try await store.fetchCurrentSprint(productID: product.id))
    let batch = try #require(
      try await store.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    let suggestion = try #require(batch.suggestions.first)
    let existingSuggestionDependencies = suggestion.existingDependencyWorkItemIDs.compactMap {
      dependencyID in
      storedItems.first { $0.id == dependencyID }
    }
    #expect(archived.state == .cancelled)
    #expect(currentPlan.items.map(\.workItemID) == [remainingItem.id])
    #expect(
      TicketBlockerChoices.availableItems(
        in: storedItems,
        excludingWorkItemID: nil,
        selectedIDs: []
      ).map(\.id) == [remainingItem.id]
    )
    #expect(
      TicketSuggestionDependencyPresentation.activeExistingDependencies(
        in: existingSuggestionDependencies
      ).isEmpty
    )
    #expect(
      try await store.fetchComments(workItemID: archivedItem.id).map(\.id)
        == [workLogEntry.id]
    )

    await store.close()
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    let recoveredArchived = try #require(
      try await reopened.fetchWorkItems(productID: product.id).first {
        $0.id == archivedItem.id
      }
    )
    #expect(recoveredArchived.state == .cancelled)
    #expect(
      try await reopened.fetchCurrentSprint(productID: product.id)?.items.map(\.workItemID)
        == [remainingItem.id]
    )
    #expect(
      try await reopened.fetchComments(workItemID: archivedItem.id).map(\.body)
        == ["Archive after the replacement is approved."]
    )
    #expect(
      try await reopened.fetchActivity(productID: product.id)
        .contains { $0.kind == "work_item.archived" && $0.workItemID == archivedItem.id }
    )
    await reopened.close()
  }
}

private struct DatabaseFixture {
  let directoryURL: URL
  let databaseURL: URL

  init(name: String) throws {
    directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SpeditoEditableTicket-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
    databaseURL = directoryURL.appendingPathComponent("spedito.sqlite")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
