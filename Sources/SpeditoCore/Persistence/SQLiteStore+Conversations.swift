import Foundation
import SQLite3

extension SQLiteStore {
  public func createConversationThread(
    _ thread: ProductConversationThread,
    initialMessage: ProductConversationMessage
  ) throws -> ProductConversationThread {
    guard initialMessage.threadID == thread.id else {
      throw PersistenceError.corruptData(
        "The initial conversation message belongs to another thread."
      )
    }
    let profile = try fetchAgentProfile(id: thread.recipientProfileID)
    guard profile.productID == thread.productID else {
      throw PersistenceError.corruptData(
        "The selected team member belongs to another product."
      )
    }
    _ = try fetchProduct(id: thread.productID)

    try transaction {
      try withStatement(
        """
        INSERT INTO conversation_threads (
            id, product_id, recipient_profile_id, subject, status,
            codex_thread_id, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(thread.id.uuidString, to: 1, in: statement)
        try bind(thread.productID.uuidString, to: 2, in: statement)
        try bind(thread.recipientProfileID.uuidString, to: 3, in: statement)
        try bind(thread.subject, to: 4, in: statement)
        try bind(thread.status.rawValue, to: 5, in: statement)
        try bindOptionalString(thread.codexThreadID, to: 6, in: statement)
        try bind(thread.createdAt.timeIntervalSince1970, to: 7, in: statement)
        try bind(thread.updatedAt.timeIntervalSince1970, to: 8, in: statement)
        try stepDone(statement)
      }
      try insertConversationMessage(initialMessage)
    }
    return thread
  }

  public func fetchConversationThreads(
    productID: UUID
  ) throws -> [ProductConversationThread] {
    try withStatement(
      """
      SELECT id, product_id, recipient_profile_id, subject, status,
             codex_thread_id, created_at, updated_at
      FROM conversation_threads
      WHERE product_id = ?
      ORDER BY updated_at DESC, created_at DESC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var threads: [ProductConversationThread] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        threads.append(try decodeConversationThread(statement))
      }
      return threads
    }
  }

  public func fetchConversationMessages(
    threadID: UUID
  ) throws -> [ProductConversationMessage] {
    try withStatement(
      """
      SELECT id, thread_id, author_kind, author_name, body, created_at
      FROM conversation_messages
      WHERE thread_id = ?
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      try bind(threadID.uuidString, to: 1, in: statement)
      var messages: [ProductConversationMessage] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        messages.append(try decodeConversationMessage(statement))
      }
      return messages
    }
  }

  public func fetchRecentConversationMessages(
    productID: UUID,
    limit: Int = 100
  ) throws -> [ProductConversationMessage] {
    let boundedLimit = max(1, min(limit, 500))
    return try withStatement(
      """
      SELECT message.id, message.thread_id, message.author_kind,
             message.author_name, message.body, message.created_at
      FROM conversation_messages AS message
      JOIN conversation_threads AS thread ON thread.id = message.thread_id
      WHERE thread.product_id = ? AND thread.status != ?
      ORDER BY message.created_at DESC, message.id DESC
      LIMIT ?;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(ConversationThreadStatus.archived.rawValue, to: 2, in: statement)
      try bind(Int64(boundedLimit), to: 3, in: statement)
      var messages: [ProductConversationMessage] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        messages.append(try decodeConversationMessage(statement))
      }
      return Array(messages.reversed())
    }
  }

  public func appendConversationMessage(
    _ message: ProductConversationMessage,
    threadStatus: ConversationThreadStatus,
    threadSubject: String? = nil,
    threadRecipientProfileID: UUID? = nil,
    resetsCodexThread: Bool = false
  ) throws -> ProductConversationThread {
    guard let existingThread = try fetchConversationThread(id: message.threadID) else {
      throw PersistenceError.recordNotFound("Conversation thread \(message.threadID)")
    }
    if let threadRecipientProfileID {
      let profile = try fetchAgentProfile(id: threadRecipientProfileID)
      guard profile.productID == existingThread.productID else {
        throw PersistenceError.corruptData(
          "The selected team member belongs to another product."
        )
      }
    }
    try transaction {
      try insertConversationMessage(message)
      try withStatement(
        """
        UPDATE conversation_threads
        SET status = ?,
            subject = COALESCE(?, subject),
            recipient_profile_id = COALESCE(?, recipient_profile_id),
            codex_thread_id = CASE WHEN ? = 1 THEN NULL ELSE codex_thread_id END,
            updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(threadStatus.rawValue, to: 1, in: statement)
        try bindOptionalString(threadSubject, to: 2, in: statement)
        try bindOptionalString(
          threadRecipientProfileID?.uuidString,
          to: 3,
          in: statement
        )
        try bind(Int64(resetsCodexThread ? 1 : 0), to: 4, in: statement)
        try bind(message.createdAt.timeIntervalSince1970, to: 5, in: statement)
        try bind(message.threadID.uuidString, to: 6, in: statement)
        try stepDone(statement)
      }
    }
    guard let updatedThread = try fetchConversationThread(id: message.threadID) else {
      throw PersistenceError.recordNotFound("Conversation thread \(message.threadID)")
    }
    return updatedThread
  }

  public func updateConversationThreadSubject(
    id: UUID,
    subject: String,
    replacing expectedSubject: String
  ) throws -> ProductConversationThread {
    try withStatement(
      """
      UPDATE conversation_threads
      SET subject = ?
      WHERE id = ? AND subject = ?;
      """
    ) { statement in
      try bind(subject, to: 1, in: statement)
      try bind(id.uuidString, to: 2, in: statement)
      try bind(expectedSubject, to: 3, in: statement)
      try stepDone(statement)
    }
    guard let thread = try fetchConversationThread(id: id) else {
      throw PersistenceError.recordNotFound("Conversation thread \(id)")
    }
    return thread
  }

  public func updateConversationThread(
    id: UUID,
    status: ConversationThreadStatus,
    codexThreadID: String? = nil
  ) throws -> ProductConversationThread {
    let updatedAt = Date()
    try withStatement(
      """
      UPDATE conversation_threads
      SET status = ?, codex_thread_id = COALESCE(?, codex_thread_id), updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bindOptionalString(codexThreadID, to: 2, in: statement)
      try bind(updatedAt.timeIntervalSince1970, to: 3, in: statement)
      try bind(id.uuidString, to: 4, in: statement)
      try stepDone(statement)
    }
    guard let thread = try fetchConversationThread(id: id) else {
      throw PersistenceError.recordNotFound("Conversation thread \(id)")
    }
    return thread
  }

  public func archiveConversationThread(
    id: UUID
  ) throws -> ProductConversationThread {
    guard let thread = try fetchConversationThread(id: id) else {
      throw PersistenceError.recordNotFound("Conversation thread \(id)")
    }
    guard thread.status != .working else {
      throw PersistenceError.corruptData(
        "Stop the active response before archiving this thread"
      )
    }
    guard !thread.isArchived else { return thread }
    return try updateConversationThread(id: id, status: .archived)
  }

  public func restoreConversationThread(
    id: UUID
  ) throws -> ProductConversationThread {
    guard let thread = try fetchConversationThread(id: id) else {
      throw PersistenceError.recordNotFound("Conversation thread \(id)")
    }
    guard thread.isArchived else { return thread }
    return try updateConversationThread(id: id, status: .complete)
  }

  public func interruptWorkingConversationThreads() throws {
    try withStatement(
      """
      UPDATE conversation_threads
      SET status = ?, updated_at = ?
      WHERE status = ?;
      """
    ) { statement in
      try bind(ConversationThreadStatus.failed.rawValue, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(ConversationThreadStatus.working.rawValue, to: 3, in: statement)
      try stepDone(statement)
    }
  }

}
