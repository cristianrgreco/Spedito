import Foundation
import Testing

@testable import SpeditoCore

@Suite("Product Conversation")
struct ProductConversationTests {
  @Test("Threads, replies, and reversible archival are durable and independently scoped")
  func durableThreads() async throws {
    let fixture = try ConversationDatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Conversation product"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let lead = try #require(profiles.first { $0.role == .lead })

    let first = ProductConversationThread(
      productID: product.id,
      recipientProfileID: analyst.id,
      subject: "Which ticket implemented search?"
    )
    _ = try await store.createConversationThread(
      first,
      initialMessage: ProductConversationMessage(
        threadID: first.id,
        authorKind: .owner,
        authorName: "Me",
        body: "Which ticket implemented search?"
      )
    )
    _ = try await store.appendConversationMessage(
      ProductConversationMessage(
        threadID: first.id,
        authorKind: .agent,
        authorName: analyst.name,
        body: "T4 introduced search in commit abc123."
      ),
      threadStatus: .complete,
      threadSubject: "Search implementation"
    )

    let second = ProductConversationThread(
      productID: product.id,
      recipientProfileID: lead.id,
      subject: "What remains risky?"
    )
    _ = try await store.createConversationThread(
      second,
      initialMessage: ProductConversationMessage(
        threadID: second.id,
        authorKind: .owner,
        authorName: "Me",
        body: "What remains risky?"
      )
    )
    await #expect(throws: PersistenceError.self) {
      _ = try await store.archiveConversationThread(id: second.id)
    }
    await store.close()

    let reopened = try SQLiteStore(url: fixture.databaseURL)
    try await reopened.interruptWorkingConversationThreads()
    let threads = try await reopened.fetchConversationThreads(productID: product.id)
    #expect(Set(threads.map(\.id)) == [first.id, second.id])
    #expect(threads.first(where: { $0.id == first.id })?.subject == "Search implementation")
    #expect(threads.first(where: { $0.id == second.id })?.status == .failed)
    #expect(try await reopened.fetchConversationMessages(threadID: first.id).count == 2)
    #expect(try await reopened.fetchConversationMessages(threadID: second.id).count == 1)
    #expect(
      try await reopened.fetchRecentConversationMessages(
        productID: product.id,
        limit: 2
      ).map(\.body) == [
        "T4 introduced search in commit abc123.",
        "What remains risky?",
      ]
    )

    let archived = try await reopened.archiveConversationThread(id: first.id)
    #expect(archived.isArchived)
    #expect(try await reopened.fetchConversationMessages(threadID: first.id).count == 2)
    #expect(
      try await reopened.fetchRecentConversationMessages(
        productID: product.id,
        limit: 100
      ).map(\.body) == ["What remains risky?"]
    )

    let restored = try await reopened.restoreConversationThread(id: first.id)
    #expect(restored.status == .complete)
    await reopened.close()
  }

  @Test("New context is bounded while same-agent replies and cross-agent handoffs stay scoped")
  func boundedContext() throws {
    let threadID = UUID()
    let messages = (1...101).map {
      ProductConversationMessage(
        threadID: threadID,
        authorKind: .owner,
        authorName: "Me",
        body: "Message \($0)"
      )
    }
    let prompt = CodexProductConversation.newThreadPrompt(
      ownerMessage: "Latest question",
      recentRoomMessages: messages
    )
    #expect(!prompt.contains("Message 1\n"))
    #expect(prompt.contains("Message 2"))
    #expect(prompt.contains("Message 101"))

    let followUp = CodexProductConversation.resumedThreadPrompt(
      ownerMessage: "Can you prove that?"
    )
    #expect(followUp.contains("Can you prove that?"))
    #expect(!followUp.contains("Message 101"))

    let handoff = CodexProductConversation.handoffPrompt(
      messages: Array(messages.suffix(2))
    )
    #expect(handoff.contains("Message 100"))
    #expect(handoff.contains("Message 101"))
    #expect(handoff.contains("selected you to continue"))
  }

  @Test("A follow-up can retarget a thread while clearing its role-specific Codex session")
  func retargetedThread() async throws {
    let fixture = try ConversationDatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(
      name: "Handoff product"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let lead = try #require(profiles.first { $0.role == .lead })
    let thread = ProductConversationThread(
      productID: product.id,
      recipientProfileID: analyst.id,
      subject: "Review search delivery evidence",
      status: .complete,
      codexThreadID: "analyst-thread"
    )
    _ = try await store.createConversationThread(
      thread,
      initialMessage: ProductConversationMessage(
        threadID: thread.id,
        authorKind: .owner,
        authorName: "Me",
        body: "Which ticket implemented search?"
      )
    )

    let retargeted = try await store.appendConversationMessage(
      ProductConversationMessage(
        threadID: thread.id,
        authorKind: .owner,
        authorName: "Me",
        body: "What does the Tech Lead think?"
      ),
      threadStatus: .working,
      threadRecipientProfileID: lead.id,
      resetsCodexThread: true
    )

    #expect(retargeted.recipientProfileID == lead.id)
    #expect(retargeted.codexThreadID == nil)
    #expect(try await store.fetchConversationMessages(threadID: thread.id).count == 2)
    await store.close()
  }

  @Test("Replies use a strict structured result")
  func structuredReply() throws {
    let reply = try CodexProductConversation.decode(
      """
      {
        "message":"T12 implemented the export in commit deadbeef.",
        "threadTitle":"Export implementation and delivery evidence"
      }
      """
    )
    #expect(reply.message == "T12 implemented the export in commit deadbeef.")
    #expect(reply.threadTitle == "Export implementation and delivery evidence")
    #expect(throws: ProductConversationGenerationError.self) {
      _ = try CodexProductConversation.decode(
        #"{"message":"","threadTitle":"Export implementation and delivery evidence"}"#
      )
    }
    #expect(throws: ProductConversationGenerationError.self) {
      _ = try CodexProductConversation.decode(
        #"{"message":"Implemented.","threadTitle":"First line\nSecond line"}"#
      )
    }
    #expect(throws: ProductConversationGenerationError.self) {
      _ = try CodexProductConversation.decode(
        #"{"message":"Implemented.","threadTitle":"Postcards"}"#
      )
    }
  }

  @Test("Conversation guidance asks for readable Markdown and a short title")
  func readableReplyGuidance() {
    let profile = AgentProfile(
      productID: UUID(),
      name: "Business Analyst",
      role: .businessAnalyst
    )
    let instructions = CodexProductConversation.developerInstructions(
      productInstructions: "Use current product evidence.",
      customInstructions: "",
      recipient: profile
    )
    #expect(instructions.contains("blank lines"))
    #expect(instructions.contains("Markdown bullets"))
    #expect(instructions.contains("about five words"))
    #expect(instructions.contains("single-word topic label"))
  }

  @Test("Conversation guidance can inspect operational state without exposing protocol internals")
  func operationalEvidenceGuidance() {
    let profile = AgentProfile(
      productID: UUID(),
      name: "Business Analyst",
      role: .businessAnalyst
    )
    let instructions = CodexProductConversation.developerInstructions(
      productInstructions: "Use current product evidence.",
      customInstructions: "",
      recipient: profile
    )

    #expect(instructions.contains("do not treat that list as"))
    #expect(instructions.contains("inspect agent_runs"))
    #expect(instructions.contains("agent_permission_requests"))
    #expect(instructions.contains("last activity"))
    #expect(instructions.contains("inferring that work is stuck"))
    #expect(instructions.contains("absence of an agent_work_log comment"))
    #expect(instructions.contains("Never reveal internal Codex thread"))
    #expect(instructions.contains("permission signatures"))
    #expect(instructions.contains("worktree paths"))
  }
}

private struct ConversationDatabaseFixture {
  let directoryURL: URL
  let databaseURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-conversation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    databaseURL = directoryURL.appendingPathComponent("product.sqlite")
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
