import Foundation
import SpeditoCore

@MainActor
extension AppModel {
  @discardableResult
  func sendProductConversationMessage(
    threadID: UUID?,
    recipientID: UUID,
    body: String
  ) async -> UUID? {
    await productConversationFeature.sendMessage(
      threadID: threadID,
      recipientID: recipientID,
      body: body
    )
  }

  @discardableResult
  func retryProductConversation(threadID: UUID) async -> UUID? {
    await productConversationFeature.retry(threadID: threadID)
  }

  func cancelProductConversation(threadID: UUID) {
    productConversationFeature.cancel(threadID: threadID)
  }

  @discardableResult
  func archiveProductConversation(threadID: UUID) async -> Bool {
    guard
      let thread = productConversationFeature.threads.first(where: { $0.id == threadID }),
      await productConversationFeature.archive(threadID: threadID)
    else { return false }
    await retireOwnerNotifications(
      productID: thread.productID,
      target: OwnerNotificationTarget(kind: .conversationThread, id: threadID)
    )
    return true
  }

  @discardableResult
  func restoreProductConversation(threadID: UUID) async -> Bool {
    await productConversationFeature.restore(threadID: threadID)
  }

  func loadProductConversationMessages(threadID: UUID) async {
    await productConversationFeature.loadMessages(threadID: threadID)
  }
}
