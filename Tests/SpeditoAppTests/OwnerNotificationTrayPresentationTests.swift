import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Owner notification tray presentation")
struct OwnerNotificationTrayPresentationTests {
  private let productA = Product(name: "Product A")
  private let productB = Product(name: "Product B")

  private func notification(
    productID: UUID,
    kind: OwnerNotificationKind,
    target: OwnerNotificationTarget = OwnerNotificationTarget(kind: .ticket, id: UUID()),
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    readAt: Date? = nil,
    resolvedAt: Date? = nil
  ) -> OwnerNotification {
    OwnerNotification(
      productID: productID,
      kind: kind,
      target: target,
      title: "Notification title",
      body: "Notification body",
      createdAt: createdAt,
      readAt: readAt,
      resolvedAt: resolvedAt
    )
  }

  private func attention(
    product: Product,
    workItemID: UUID = UUID(),
    updatedAt: Date = Date(timeIntervalSince1970: 2_000)
  ) -> TicketAttention {
    TicketAttention(
      id: UUID(),
      productID: product.id,
      productName: product.name,
      sprintID: nil,
      workItemID: workItemID,
      itemKey: "T1",
      title: "Ticket title",
      summary: "The developer asks a question.",
      updatedAt: updatedAt
    )
  }

  @Test("Read informational notifications leave the tray")
  func readInformationalNotificationsLeaveTheTray() {
    let read = notification(
      productID: productA.id,
      kind: .newReply,
      readAt: Date(timeIntervalSince1970: 1_100)
    )
    let unread = notification(productID: productA.id, kind: .newReply)

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA],
      selectedProductID: productA.id,
      notificationsByProductID: [productA.id: [read, unread]],
      attentionsByProductID: [:]
    )

    #expect(tray.badgeCount == 1)
    #expect(tray.groups.first?.rows.map(\.id) == [unread.id])
  }

  @Test("A read needs-input notification stays until it is resolved")
  func readNeedsInputStaysUntilResolved() {
    let readUnresolved = notification(
      productID: productA.id,
      kind: .needsInput,
      readAt: Date(timeIntervalSince1970: 1_100)
    )
    let resolved = notification(
      productID: productA.id,
      kind: .needsInput,
      readAt: Date(timeIntervalSince1970: 1_100),
      resolvedAt: Date(timeIntervalSince1970: 1_200)
    )

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA],
      selectedProductID: productA.id,
      notificationsByProductID: [productA.id: [readUnresolved, resolved]],
      attentionsByProductID: [:]
    )

    #expect(tray.groups.first?.rows.map(\.id) == [readUnresolved.id])
  }

  @Test("One row per target, and needs input outranks newer informational")
  func needsInputOutranksNewerInformationalOnOneTarget() {
    let target = OwnerNotificationTarget(kind: .ticket, id: UUID())
    let needsInput = notification(
      productID: productA.id,
      kind: .needsInput,
      target: target,
      createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let newerReply = notification(
      productID: productA.id,
      kind: .newReply,
      target: target,
      createdAt: Date(timeIntervalSince1970: 1_500)
    )

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA],
      selectedProductID: productA.id,
      notificationsByProductID: [productA.id: [needsInput, newerReply]],
      attentionsByProductID: [:]
    )

    #expect(tray.badgeCount == 1)
    #expect(tray.groups.first?.rows.first?.presentation.kind == .needsInput)
    #expect(tray.groups.first?.rows.first?.id == needsInput.id)
  }

  @Test("A ticket attention covers its target's stored notification")
  func attentionCoversStoredNotificationForSameTarget() {
    let workItemID = UUID()
    let liveAttention = attention(product: productA, workItemID: workItemID)
    let stored = notification(
      productID: productA.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .ticket, id: workItemID)
    )
    let separate = notification(productID: productA.id, kind: .newReply)

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA],
      selectedProductID: productA.id,
      notificationsByProductID: [productA.id: [stored, separate]],
      attentionsByProductID: [productA.id: [liveAttention]]
    )

    #expect(tray.badgeCount == 2)
    let rowIDs = tray.groups.first?.rows.map(\.id) ?? []
    #expect(rowIDs.contains(liveAttention.id))
    #expect(rowIDs.contains(separate.id))
    #expect(!rowIDs.contains(stored.id))
  }

  @Test("Groups put the selected product first and order rows newest first")
  func groupsPutSelectedProductFirstAndRowsNewestFirst() {
    let older = notification(
      productID: productB.id,
      kind: .newReply,
      createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let newer = notification(
      productID: productB.id,
      kind: .refinementComplete,
      target: OwnerNotificationTarget(kind: .epic, id: UUID()),
      createdAt: Date(timeIntervalSince1970: 3_000)
    )
    let selectedProductRow = notification(productID: productA.id, kind: .newReply)

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productB, productA],
      selectedProductID: productA.id,
      notificationsByProductID: [
        productA.id: [selectedProductRow],
        productB.id: [older, newer],
      ],
      attentionsByProductID: [:]
    )

    #expect(tray.groups.map(\.productID) == [productA.id, productB.id])
    #expect(tray.groups.last?.rows.map(\.id) == [newer.id, older.id])
    #expect(tray.badgeCount == 3)
  }

  private func planBatch(
    product: Product,
    epicID: UUID,
    statuses: [TicketSuggestionStatus],
    updatedAt: Date = Date(timeIntervalSince1970: 3_000)
  ) -> TicketSuggestionBatch {
    let session = SuggestionSession(
      productID: product.id,
      epicID: epicID,
      status: .ready,
      updatedAt: updatedAt
    )
    return TicketSuggestionBatch(
      session: session,
      suggestions: statuses.enumerated().map { index, status in
        TicketSuggestion(
          sessionID: session.id,
          reference: "T\(index + 1)",
          position: index,
          title: "Proposal \(index + 1)",
          body: "Proposal body",
          acceptanceCriteria: ["It works"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "Proposal rationale",
          status: status
        )
      }
    )
  }

  @Test("An undecided plan batch produces a persistent bell row")
  func undecidedPlanBatchProducesRow() throws {
    let epic = Epic(
      productID: productA.id,
      title: "Cat jokes",
      goal: "Add a cat joke to results"
    )
    let reviews = EpicPlanReviewAttention.derive(
      product: productA,
      epics: [epic],
      batches: [
        planBatch(product: productA, epicID: epic.id, statuses: [.proposed, .proposed])
      ]
    )
    let review = try #require(reviews.first)
    #expect(review.epicID == epic.id)
    #expect(review.proposalCount == 2)

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA],
      selectedProductID: productA.id,
      notificationsByProductID: [:],
      attentionsByProductID: [:],
      planReviewsByProductID: [productA.id: reviews]
    )

    #expect(tray.badgeCount == 1)
    let row = try #require(tray.groups.first?.rows.first)
    #expect(row.presentation.kind == .refinementComplete)
    #expect(row.presentation.target == OwnerNotificationTarget(kind: .epic, id: epic.id))
    #expect(row.presentation.title == "Cat jokes plan ready for review")
    #expect(row.presentation.summary == "2 proposed tickets are ready to review.")
  }

  @Test("Partial decisions keep the plan row; deciding all clears it")
  func planRowStaysUntilEveryProposalIsDecided() {
    let epic = Epic(
      productID: productA.id,
      title: "Cat jokes",
      goal: "Add a cat joke to results"
    )
    let partial = EpicPlanReviewAttention.derive(
      product: productA,
      epics: [epic],
      batches: [
        planBatch(product: productA, epicID: epic.id, statuses: [.accepted, .proposed])
      ]
    )
    #expect(partial.first?.proposalCount == 1)

    let decided = EpicPlanReviewAttention.derive(
      product: productA,
      epics: [epic],
      batches: [
        planBatch(product: productA, epicID: epic.id, statuses: [.accepted, .rejected])
      ]
    )
    #expect(decided.isEmpty)

    let archived = EpicPlanReviewAttention.derive(
      product: productA,
      epics: [
        Epic(
          id: epic.id,
          productID: productA.id,
          title: epic.title,
          goal: epic.goal,
          status: .archived
        )
      ],
      batches: [
        planBatch(product: productA, epicID: epic.id, statuses: [.proposed])
      ]
    )
    #expect(archived.isEmpty)
  }

  @Test("A plan review row covers its epic's stored notification")
  func planReviewCoversStoredNotificationForSameEpic() {
    let epic = Epic(
      productID: productA.id,
      title: "Cat jokes",
      goal: "Add a cat joke to results"
    )
    let reviews = EpicPlanReviewAttention.derive(
      product: productA,
      epics: [epic],
      batches: [planBatch(product: productA, epicID: epic.id, statuses: [.proposed])]
    )
    let stored = notification(
      productID: productA.id,
      kind: .refinementComplete,
      target: OwnerNotificationTarget(kind: .epic, id: epic.id)
    )

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA],
      selectedProductID: productA.id,
      notificationsByProductID: [productA.id: [stored]],
      attentionsByProductID: [:],
      planReviewsByProductID: [productA.id: reviews]
    )

    #expect(tray.badgeCount == 1)
    #expect(tray.groups.first?.rows.map(\.id) == reviews.map(\.id))
  }

  @Test("Products without active notifications produce no group")
  func productsWithoutActiveNotificationsProduceNoGroup() {
    let resolved = notification(
      productID: productB.id,
      kind: .needsInput,
      readAt: Date(timeIntervalSince1970: 1_100),
      resolvedAt: Date(timeIntervalSince1970: 1_200)
    )

    let tray = OwnerNotificationTrayPresentation.make(
      products: [productA, productB],
      selectedProductID: productA.id,
      notificationsByProductID: [productB.id: [resolved]],
      attentionsByProductID: [:]
    )

    #expect(tray.isEmpty)
    #expect(tray.badgeCount == 0)
    #expect(tray.groups.isEmpty)
  }
}
