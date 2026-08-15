import Foundation
import SpeditoTestSupport
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

@Suite("Codex transport application seam", .serialized)
@MainActor
struct CodexTransportApplicationTests {
  @Test("A scripted Product conversation updates presentation and SQLite")
  func scriptedProductConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-app-codex-transport-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Scripted conversation")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let recipient = try #require(profiles.first)
    let conversation = ProductConversationThread(
      productID: product.id,
      recipientProfileID: recipient.id,
      subject: "Existing conversation",
      status: .complete,
      codexThreadID: "thread-application"
    )
    _ = try await store.createConversationThread(
      conversation,
      initialMessage: ProductConversationMessage(
        threadID: conversation.id,
        authorKind: .owner,
        authorName: "Me",
        body: "Earlier context"
      )
    )

    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/application-test"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        ),
        .init(method: "model/list", result: .object(["data": .array([])])),
        .init(
          method: "account/rateLimits/read",
          result: .object(["rateLimits": .object([:])])
        ),
        .init(
          method: "thread/resume",
          result: .object(["thread": .object(["id": .string("thread-application")])])
        ),
        .init(
          method: "turn/start",
          result: .object(["turn": .object(["id": .string("turn-application")])])
        ),
      ],
      inboundMessages: [
        .notification(
          CodexNotification(
            method: "turn/completed",
            params: .object([
              "threadId": .string("thread-application"),
              "turn": .object([
                "id": .string("turn-application"),
                "status": .string("completed"),
                "items": .array([
                  .object([
                    "id": .string("message-application"),
                    "type": .string("agentMessage"),
                    "text": .string("A deterministic reply."),
                  ])
                ]),
              ]),
            ])
          )
        )
      ]
    )
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      codexTransportFactory: { _ in
        CodexTransportFactoryOutput(
          descriptor: CodexRuntimeDescriptor(
            executableURL: URL(fileURLWithPath: "/private/tmp/codex-test"),
            version: "test",
            source: .custom
          ),
          transport: transport
        )
      },
      ownerNotificationSoundPlayer: CodexTransportNotificationSound(),
      ownerNotificationSystemNotifier: CodexTransportSystemNotifier()
    )

    await model.load()
    let returnedThreadID = await model.sendProductConversationMessage(
      threadID: conversation.id,
      recipientID: recipient.id,
      body: "What changed?"
    )

    #expect(returnedThreadID == conversation.id)
    #expect(
      model.conversationThreads.first(where: { $0.id == conversation.id })?.status == .complete
    )
    #expect(
      model.conversationMessagesByThread[conversation.id]?.map(\.body)
        == ["Earlier context", "What changed?", "A deterministic reply."]
    )

    let storedMessages = try await store.fetchConversationMessages(threadID: conversation.id)
    #expect(storedMessages.map(\.body) == ["Earlier context", "What changed?", "A deterministic reply."])
    #expect(
      await transport.recordedRequests().map(\.method)
        == [
          "initialize",
          "model/list",
          "account/rateLimits/read",
          "thread/resume",
          "turn/start",
        ]
    )
    #expect(await transport.remainingResponseCount() == 0)

    await model.shutdown()
    await store.close()
  }
}

@MainActor
private final class CodexTransportNotificationSound: OwnerNotificationSoundPlaying {
  func play() {}
}

@MainActor
private final class CodexTransportSystemNotifier: OwnerNotificationSystemNotifying {
  func post(_ presentation: OwnerNotificationPresentation) {}
  func dismiss(ids: [UUID]) {}
}
