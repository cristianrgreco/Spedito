import Foundation
import SQLite3

public enum PersistenceError: Error, Equatable, LocalizedError, Sendable {
  case sqlite(code: Int32, message: String)
  case recordNotFound(String)
  case corruptData(String)

  public var errorDescription: String? {
    switch self {
    case .sqlite(let code, let message):
      "SQLite error \(code): \(message)"
    case .recordNotFound(let record):
      "Record not found: \(record)"
    case .corruptData(let message):
      "Stored data is invalid: \(message)"
    }
  }
}

public actor SQLiteStore {
  public nonisolated let url: URL
  var database: OpaquePointer?
  let workflowPolicy: WorkflowPolicy
  let encoder = JSONEncoder()
  let decoder = JSONDecoder()
  private var transactionDepth = 0
  #if DEBUG
    private var preparedStatementCount = 0

    func resetPreparedStatementCount() {
      preparedStatementCount = 0
    }

    func currentPreparedStatementCount() -> Int {
      preparedStatementCount
    }
  #endif

  public init(url: URL, workflowPolicy: WorkflowPolicy = WorkflowPolicy()) throws {
    self.url = url
    self.workflowPolicy = workflowPolicy

    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    var connection: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path,
      &connection,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )

    guard result == SQLITE_OK, let connection else {
      let message =
        connection.map { String(cString: sqlite3_errmsg($0)) }
        ?? "Could not open database"
      if let connection {
        sqlite3_close(connection)
      }
      throw PersistenceError.sqlite(code: result, message: message)
    }

    database = connection

    do {
      try Self.execute("PRAGMA foreign_keys = ON;", database: connection)
      try Self.execute("PRAGMA journal_mode = WAL;", database: connection)
      try Self.initializeCurrentSchema(database: connection)
    } catch {
      sqlite3_close(connection)
      database = nil
      throw error
    }
  }

  public func close() {
    if let database {
      sqlite3_close(database)
      self.database = nil
    }
  }

  public func importAllRows(from legacyDatabaseURL: URL) throws {
    guard try fetchProducts(status: .active).isEmpty,
      try fetchProducts(status: .archived).isEmpty
    else {
      throw PersistenceError.corruptData(
        "A legacy product can only be imported into an empty product database."
      )
    }

    let escapedPath = legacyDatabaseURL.path.replacingOccurrences(
      of: "'",
      with: "''"
    )
    try execute("ATTACH DATABASE '\(escapedPath)' AS legacy;")
    do {
      try transaction {
        let database = try requiredDatabase
        try execute("PRAGMA defer_foreign_keys = ON;")
        for table in ProductDatabaseSchema.legacyCopyTableOrder {
          guard try Self.tableExists(table, schema: "legacy", database: database)
          else { continue }
          let destinationColumns = try Self.columnNames(
            table: table,
            schema: "main",
            database: database
          )
          let sourceColumns = Set(
            try Self.columnNames(
              table: table,
              schema: "legacy",
              database: database
            )
          )
          let sharedColumns = destinationColumns.filter(sourceColumns.contains)
          guard !sharedColumns.isEmpty else { continue }
          let columns = sharedColumns.map(Self.quotedIdentifier).joined(separator: ", ")
          try execute(
            """
            INSERT INTO main.\(Self.quotedIdentifier(table)) (\(columns))
            SELECT \(columns)
            FROM legacy.\(Self.quotedIdentifier(table));
            """
          )
        }

        let failures = try withStatement("PRAGMA foreign_key_check;") { statement in
          var descriptions: [String] = []
          while sqlite3_step(statement) == SQLITE_ROW {
            descriptions.append(
              "\(try text(statement, column: 0)) row \(sqlite3_column_int64(statement, 1))"
            )
          }
          return descriptions
        }
        guard failures.isEmpty else {
          throw PersistenceError.corruptData(
            "Imported product relationships are invalid: \(failures.joined(separator: ", "))"
          )
        }
      }
      try execute("DETACH DATABASE legacy;")
    } catch {
      try? execute("DETACH DATABASE legacy;")
      throw error
    }
  }

  var requiredDatabase: OpaquePointer {
    get throws {
      guard let database else {
        throw PersistenceError.sqlite(
          code: SQLITE_MISUSE,
          message: "The product database is closed."
        )
      }
      return database
    }
  }

  static func initializeCurrentSchema(database: OpaquePointer) throws {
    let hasProductTables = try tableExists(
      "products",
      schema: "main",
      database: database
    )
    if !hasProductTables {
      try execute(ProductDatabaseSchema.sql, database: database)
      return
    }

    var version = try integerPragma("user_version", database: database)
    guard version != ProductDatabaseSchema.version else { return }
    if try tableExists("schema_migrations", schema: "main", database: database) {
      throw PersistenceError.corruptData(
        "This is a legacy shared Spedito database. Open it through the product importer."
      )
    }
    guard (1..<ProductDatabaseSchema.version).contains(version) else {
      throw PersistenceError.corruptData(
        "Unsupported product database schema \(version); expected \(ProductDatabaseSchema.version)."
      )
    }

    try execute("BEGIN IMMEDIATE;", database: database)
    do {
      while version < ProductDatabaseSchema.version {
        let migration: String
        switch version {
        case 1:
          migration = ProductDatabaseSchema.migrationV1ToV2
        case 2:
          migration = ProductDatabaseSchema.migrationV2ToV3
        case 3:
          migration = ProductDatabaseSchema.migrationV3ToV4
        case 4:
          migration = ProductDatabaseSchema.migrationV4ToV5
        case 5:
          migration = ProductDatabaseSchema.migrationV5ToV6
        case 6:
          migration = ProductDatabaseSchema.migrationV6ToV7
        case 7:
          migration = ProductDatabaseSchema.migrationV7ToV8
        case 8:
          migration = ProductDatabaseSchema.migrationV8ToV9
        case 9:
          migration = ProductDatabaseSchema.migrationV9ToV10
        case 10:
          migration = ProductDatabaseSchema.migrationV10ToV11
        case 11:
          migration = ProductDatabaseSchema.migrationV11ToV12
        case 12:
          migration = ProductDatabaseSchema.migrationV12ToV13
        default:
          throw PersistenceError.corruptData(
            "Unsupported product database schema \(version); expected \(ProductDatabaseSchema.version)."
          )
        }
        try execute(migration, database: database)
        version = try integerPragma("user_version", database: database)
      }
      guard version == ProductDatabaseSchema.version else {
        throw PersistenceError.corruptData(
          "Unsupported product database schema \(version); expected \(ProductDatabaseSchema.version)."
        )
      }
      try execute("COMMIT;", database: database)
    } catch {
      try? execute("ROLLBACK;", database: database)
      throw error
    }
  }

  static func integerPragma(
    _ name: String,
    database: OpaquePointer
  ) throws -> Int32 {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(
      database,
      "PRAGMA \(name);",
      -1,
      &statement,
      nil
    )
    guard result == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(
        code: result,
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw PersistenceError.sqlite(
        code: sqlite3_errcode(database),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    return sqlite3_column_int(statement, 0)
  }

  static func tableExists(
    _ table: String,
    schema: String,
    database: OpaquePointer
  ) throws -> Bool {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(
      database,
      "SELECT 1 FROM \(quotedIdentifier(schema)).sqlite_schema "
        + "WHERE type = 'table' AND name = ? LIMIT 1;",
      -1,
      &statement,
      nil
    )
    guard result == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(
        code: result,
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(statement, 1, table, -1, transient) == SQLITE_OK else {
      throw PersistenceError.sqlite(
        code: sqlite3_errcode(database),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  static func columnNames(
    table: String,
    schema: String,
    database: OpaquePointer
  ) throws -> [String] {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(
      database,
      "PRAGMA \(quotedIdentifier(schema)).table_info(\(quotedIdentifier(table)));",
      -1,
      &statement,
      nil
    )
    guard result == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(
        code: result,
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    defer { sqlite3_finalize(statement) }
    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let value = sqlite3_column_text(statement, 1) else { continue }
      columns.append(String(cString: value))
    }
    return columns
  }

  static func quotedIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  func insertConversationMessage(
    _ message: ProductConversationMessage
  ) throws {
    try withStatement(
      """
      INSERT INTO conversation_messages (
          id, thread_id, author_kind, author_name, body, created_at
      ) VALUES (?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(message.id.uuidString, to: 1, in: statement)
      try bind(message.threadID.uuidString, to: 2, in: statement)
      try bind(message.authorKind.rawValue, to: 3, in: statement)
      try bind(message.authorName, to: 4, in: statement)
      try bind(message.body, to: 5, in: statement)
      try bind(message.createdAt.timeIntervalSince1970, to: 6, in: statement)
      try stepDone(statement)
    }
  }

  func fetchConversationThread(
    id: UUID
  ) throws -> ProductConversationThread? {
    try withStatement(
      """
      SELECT id, product_id, recipient_profile_id, subject, status,
             codex_thread_id, created_at, updated_at
      FROM conversation_threads
      WHERE id = ?
      LIMIT 1;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeConversationThread(statement)
    }
  }

  func decodeConversationThread(
    _ statement: OpaquePointer
  ) throws -> ProductConversationThread {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let recipientProfileID = UUID(uuidString: try text(statement, column: 2)),
      let status = ConversationThreadStatus(
        rawValue: try text(statement, column: 4)
      )
    else {
      throw PersistenceError.corruptData("Invalid conversation thread")
    }
    return ProductConversationThread(
      id: id,
      productID: productID,
      recipientProfileID: recipientProfileID,
      subject: try text(statement, column: 3),
      status: status,
      codexThreadID: try optionalText(statement, column: 5),
      createdAt: date(statement, column: 6),
      updatedAt: date(statement, column: 7)
    )
  }

  func decodeConversationMessage(
    _ statement: OpaquePointer
  ) throws -> ProductConversationMessage {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let threadID = UUID(uuidString: try text(statement, column: 1)),
      let authorKind = CommentAuthorKind(
        rawValue: try text(statement, column: 2)
      )
    else {
      throw PersistenceError.corruptData("Invalid conversation message")
    }
    return ProductConversationMessage(
      id: id,
      threadID: threadID,
      authorKind: authorKind,
      authorName: try text(statement, column: 3),
      body: try text(statement, column: 4),
      createdAt: date(statement, column: 5)
    )
  }

  func insertAgentProfile(_ profile: AgentProfile) throws {
    try withStatement(
      """
      INSERT INTO agent_profiles (
          id, product_id, name, role, model, reasoning_effort,
          custom_instructions, is_builtin, is_active,
          created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(profile.id.uuidString, to: 1, in: statement)
      try bind(profile.productID.uuidString, to: 2, in: statement)
      try bind(profile.name, to: 3, in: statement)
      try bind(profile.role.rawValue, to: 4, in: statement)
      try bind(profile.model, to: 5, in: statement)
      try bind(profile.reasoningEffort, to: 6, in: statement)
      try bindOptionalString(profile.customInstructions, to: 7, in: statement)
      try bind(profile.isBuiltIn ? Int64(1) : Int64(0), to: 8, in: statement)
      try bind(Int64(1), to: 9, in: statement)
      try bind(profile.createdAt.timeIntervalSince1970, to: 10, in: statement)
      try bind(profile.updatedAt.timeIntervalSince1970, to: 11, in: statement)
      try stepDone(statement)
    }
  }

  func insertKnowledgePage(
    _ page: KnowledgePage,
    authorName: String,
    changeSummary: String
  ) throws {
    let normalizedBody = KnowledgeMarkdown.normalizedBody(page.bodyMarkdown)
    try withStatement(
      """
      INSERT INTO knowledge_pages (
          id, product_id, parent_id, title, slug, body_markdown, kind,
          verification_status, sort_order, source_work_item_id,
          source_repository_knowledge_run_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(page.id.uuidString, to: 1, in: statement)
      try bind(page.productID.uuidString, to: 2, in: statement)
      try bindOptionalUUID(page.parentID, to: 3, in: statement)
      try bind(page.title, to: 4, in: statement)
      try bind(page.slug, to: 5, in: statement)
      try bind(normalizedBody, to: 6, in: statement)
      try bind(page.kind.rawValue, to: 7, in: statement)
      try bind(page.verificationStatus.rawValue, to: 8, in: statement)
      try bind(Int64(page.sortOrder), to: 9, in: statement)
      try bindOptionalUUID(page.sourceWorkItemID, to: 10, in: statement)
      try bindOptionalUUID(page.sourceRepositoryKnowledgeRunID, to: 11, in: statement)
      try bind(page.createdAt.timeIntervalSince1970, to: 12, in: statement)
      try bind(page.updatedAt.timeIntervalSince1970, to: 13, in: statement)
      try stepDone(statement)
    }
    try insertKnowledgeRevision(
      pageID: page.id,
      bodyMarkdown: normalizedBody,
      authorName: authorName,
      changeSummary: changeSummary,
      createdAt: page.createdAt
    )
  }

  func insertKnowledgeRevision(
    pageID: UUID,
    bodyMarkdown: String,
    authorName: String,
    changeSummary: String,
    createdAt: Date = Date()
  ) throws {
    let version = try withStatement(
      """
      SELECT COALESCE(MAX(version), 0) + 1
      FROM knowledge_page_revisions WHERE page_id = ?;
      """
    ) { statement -> Int in
      try bind(pageID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
    try withStatement(
      """
      INSERT INTO knowledge_page_revisions (
          id, page_id, version, body_markdown, author_name, change_summary, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(UUID().uuidString, to: 1, in: statement)
      try bind(pageID.uuidString, to: 2, in: statement)
      try bind(Int64(version), to: 3, in: statement)
      try bind(bodyMarkdown, to: 4, in: statement)
      try bind(authorName, to: 5, in: statement)
      try bind(changeSummary, to: 6, in: statement)
      try bind(createdAt.timeIntervalSince1970, to: 7, in: statement)
      try stepDone(statement)
    }
  }

  func fetchKnowledgePage(id: UUID) throws -> KnowledgePage {
    try withStatement(
      """
      SELECT id, product_id, parent_id, title, slug, body_markdown, kind,
             verification_status, sort_order, source_work_item_id,
             source_repository_knowledge_run_id, created_at, updated_at
      FROM knowledge_pages WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("knowledge page \(id)")
      }
      return try decodeKnowledgePage(statement)
    }
  }

  func fetchKnowledgePageProposal(id: UUID) throws -> KnowledgePageProposal {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, work_item_id, candidate_revision_id,
             operation, target_page_id, parent_page_id, base_page_title,
             base_page_body_markdown, base_page_updated_at, title,
             proposed_body_markdown, rationale, status, created_at, updated_at
      FROM knowledge_page_proposals
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("knowledge page proposal \(id)")
      }
      return try decodeKnowledgePageProposal(statement)
    }
  }

  func decodeCandidateRevision(_ statement: OpaquePointer) throws -> CandidateRevision {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let sprintID = UUID(uuidString: try text(statement, column: 2)),
      let sprintItemID = UUID(uuidString: try text(statement, column: 3)),
      let workItemID = UUID(uuidString: try text(statement, column: 4)),
      let implementationRunID = UUID(uuidString: try text(statement, column: 5)),
      let status = CandidateRevisionStatus(rawValue: try text(statement, column: 13)),
      let deliveryKind = CandidateDeliveryKind(rawValue: try text(statement, column: 18))
    else {
      throw PersistenceError.corruptData("Invalid candidate revision")
    }
    return CandidateRevision(
      id: id,
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      implementationRunID: implementationRunID,
      version: Int(sqlite3_column_int64(statement, 6)),
      deliveryKind: deliveryKind,
      branchName: try text(statement, column: 7),
      baseSHA: try text(statement, column: 8),
      headSHA: try text(statement, column: 9),
      integratedSHA: try optionalText(statement, column: 10),
      worktreePath: try text(statement, column: 11),
      integrationWorktreePath: try optionalText(statement, column: 12),
      status: status,
      commitCount: Int(sqlite3_column_int64(statement, 14)),
      executionResultJSON: try text(statement, column: 15),
      createdAt: date(statement, column: 16),
      updatedAt: date(statement, column: 17)
    )
  }

  func decodeDemoSession(_ statement: OpaquePointer) throws -> DemoSession {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let sourceKind = DemoSessionSourceKind(rawValue: try text(statement, column: 2)),
      let launchID = UUID(uuidString: try text(statement, column: 3)),
      let status = DemoSessionStatus(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid demo session")
    }
    return DemoSession(
      id: id,
      productID: productID,
      sourceKind: sourceKind,
      launchID: launchID,
      status: status,
      previewWorktreePath: try optionalText(statement, column: 5),
      allocatedPort: optionalInt(statement, column: 6),
      output: try optionalText(statement, column: 7),
      errorMessage: try optionalText(statement, column: 8),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
    )
  }

  func decodeAgentPermissionRequest(
    _ statement: OpaquePointer
  ) throws -> AgentPermissionRequest {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let workItemID = UUID(uuidString: try text(statement, column: 2)),
      let agentRunID = UUID(uuidString: try text(statement, column: 3)),
      let kind = CodexApprovalRequestKind(rawValue: try text(statement, column: 8)),
      let status = AgentPermissionRequestStatus(rawValue: try text(statement, column: 13))
    else {
      throw PersistenceError.corruptData("Invalid agent permission request")
    }
    return AgentPermissionRequest(
      id: id,
      productID: productID,
      workItemID: workItemID,
      agentRunID: agentRunID,
      threadID: try text(statement, column: 4),
      turnID: try text(statement, column: 5),
      serverRequestID: try text(statement, column: 6),
      method: try text(statement, column: 7),
      kind: kind,
      title: try text(statement, column: 9),
      detail: try text(statement, column: 10),
      reason: try optionalText(statement, column: 11),
      signature: try text(statement, column: 12),
      productGrantSignature: try optionalText(statement, column: 16),
      status: status,
      createdAt: date(statement, column: 14),
      updatedAt: date(statement, column: 15)
    )
  }

  func decodeAgentPermissionGrant(
    _ statement: OpaquePointer
  ) throws -> AgentPermissionGrant {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let kind = CodexApprovalRequestKind(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid agent permission grant")
    }
    let sourceRequestID = try optionalText(statement, column: 2).flatMap(UUID.init(uuidString:))
    return AgentPermissionGrant(
      id: id,
      productID: productID,
      sourceRequestID: sourceRequestID,
      method: try text(statement, column: 3),
      kind: kind,
      title: try text(statement, column: 5),
      detail: try text(statement, column: 6),
      signature: try text(statement, column: 7),
      createdAt: date(statement, column: 8),
      revokedAt: optionalDate(statement, column: 9)
    )
  }

  func decodeKnowledgePageProposal(
    _ statement: OpaquePointer
  ) throws -> KnowledgePageProposal {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let sprintID = UUID(uuidString: try text(statement, column: 2)),
      let workItemID = UUID(uuidString: try text(statement, column: 3)),
      let candidateRevisionID = UUID(uuidString: try text(statement, column: 4)),
      let operation = KnowledgePageProposalOperation(rawValue: try text(statement, column: 5)),
      let status = KnowledgePageProposalStatus(rawValue: try text(statement, column: 14))
    else {
      throw PersistenceError.corruptData("Invalid knowledge page proposal")
    }
    return KnowledgePageProposal(
      id: id,
      productID: productID,
      sprintID: sprintID,
      workItemID: workItemID,
      candidateRevisionID: candidateRevisionID,
      operation: operation,
      targetPageID: try optionalText(statement, column: 6).flatMap(UUID.init(uuidString:)),
      parentPageID: try optionalText(statement, column: 7).flatMap(UUID.init(uuidString:)),
      basePageTitle: try optionalText(statement, column: 8),
      basePageBodyMarkdown: try optionalText(statement, column: 9),
      basePageUpdatedAt: optionalDate(statement, column: 10),
      title: try text(statement, column: 11),
      proposedBodyMarkdown: try text(statement, column: 12),
      rationale: try text(statement, column: 13),
      status: status,
      createdAt: date(statement, column: 15),
      updatedAt: date(statement, column: 16)
    )
  }

  func decodeKnowledgePage(_ statement: OpaquePointer) throws -> KnowledgePage {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let kind = KnowledgePageKind(rawValue: try text(statement, column: 6)),
      let status = KnowledgeVerificationStatus(rawValue: try text(statement, column: 7))
    else {
      throw PersistenceError.corruptData("Invalid knowledge page")
    }
    return KnowledgePage(
      id: id,
      productID: productID,
      parentID: try optionalText(statement, column: 2).flatMap(UUID.init(uuidString:)),
      title: try text(statement, column: 3),
      slug: try text(statement, column: 4),
      bodyMarkdown: try text(statement, column: 5),
      kind: kind,
      verificationStatus: status,
      sortOrder: Int(sqlite3_column_int64(statement, 8)),
      sourceWorkItemID: try optionalText(statement, column: 9).flatMap(UUID.init(uuidString:)),
      sourceRepositoryKnowledgeRunID:
        try optionalText(statement, column: 10).flatMap(UUID.init(uuidString:)),
      createdAt: date(statement, column: 11),
      updatedAt: date(statement, column: 12)
    )
  }

  func fetchAgentProfile(id: UUID) throws -> AgentProfile {
    try withStatement(
      """
      SELECT id, product_id, name, role, model, reasoning_effort,
             custom_instructions, is_builtin, created_at, updated_at
      FROM agent_profiles
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("agent profile \(id)")
      }
      guard
        let storedID = UUID(uuidString: try text(statement, column: 0)),
        let productID = UUID(uuidString: try text(statement, column: 1)),
        let role = AgentRole(rawValue: try text(statement, column: 3))
      else {
        throw PersistenceError.corruptData("Invalid agent profile")
      }
      return AgentProfile(
        id: storedID,
        productID: productID,
        name: try text(statement, column: 2),
        role: role,
        model: try text(statement, column: 4),
        reasoningEffort: try text(statement, column: 5),
        customInstructions: try optionalText(statement, column: 6),
        isBuiltIn: sqlite3_column_int64(statement, 7) != 0,
        createdAt: date(statement, column: 8),
        updatedAt: date(statement, column: 9)
      )
    }
  }

  func insertSprint(_ sprint: Sprint) throws {
    try withStatement(
      """
      INSERT INTO sprints (
          id, product_id, sprint_number, goal, state, token_budget_limit,
          plan_version, started_at, completed_at,
          retrospective_concluded_at, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(sprint.id.uuidString, to: 1, in: statement)
      try bind(sprint.productID.uuidString, to: 2, in: statement)
      try bind(Int64(sprint.number), to: 3, in: statement)
      try bind(sprint.goal, to: 4, in: statement)
      try bind(sprint.state.rawValue, to: 5, in: statement)
      try bindOptionalInt(sprint.tokenBudgetLimit, to: 6, in: statement)
      try bind(Int64(sprint.planVersion), to: 7, in: statement)
      try bindOptionalDate(sprint.startedAt, to: 8, in: statement)
      try bindOptionalDate(sprint.completedAt, to: 9, in: statement)
      try bindOptionalDate(sprint.retrospectiveConcludedAt, to: 10, in: statement)
      try bind(sprint.createdAt.timeIntervalSince1970, to: 11, in: statement)
      try bind(sprint.updatedAt.timeIntervalSince1970, to: 12, in: statement)
      try stepDone(statement)
    }
  }

  func updateDraftSprint(_ sprint: Sprint) throws {
    try withStatement(
      """
      UPDATE sprints
      SET goal = ?, token_budget_limit = ?, plan_version = ?, updated_at = ?
      WHERE id = ? AND state = 'draft';
      """
    ) { statement in
      try bind(sprint.goal, to: 1, in: statement)
      try bindOptionalInt(sprint.tokenBudgetLimit, to: 2, in: statement)
      try bind(Int64(sprint.planVersion), to: 3, in: statement)
      try bind(sprint.updatedAt.timeIntervalSince1970, to: 4, in: statement)
      try bind(sprint.id.uuidString, to: 5, in: statement)
      try stepDone(statement)
    }
  }

  func insertSprintItem(_ item: SprintItem) throws {
    try withStatement(
      """
      INSERT INTO sprint_items (
          id, sprint_id, work_item_id, implementer_profile_id,
          reviewer_profile_id, estimated_tokens, frozen_work_item_version,
          frozen_title, frozen_body, frozen_acceptance_criteria_json,
          created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(item.id.uuidString, to: 1, in: statement)
      try bind(item.sprintID.uuidString, to: 2, in: statement)
      try bind(item.workItemID.uuidString, to: 3, in: statement)
      try bindOptionalUUID(item.implementerProfileID, to: 4, in: statement)
      try bindOptionalUUID(item.reviewerProfileID, to: 5, in: statement)
      try bind(Int64(item.estimatedTokens), to: 6, in: statement)
      try bindOptionalInt(item.frozenWorkItemVersion, to: 7, in: statement)
      try bindOptionalString(item.frozenTitle, to: 8, in: statement)
      try bindOptionalString(item.frozenBody, to: 9, in: statement)
      if let criteria = item.frozenAcceptanceCriteria {
        try bind(try encodeStringArray(criteria), to: 10, in: statement)
      } else {
        try bindNull(to: 10, in: statement)
      }
      try bind(item.createdAt.timeIntervalSince1970, to: 11, in: statement)
      try bind(item.updatedAt.timeIntervalSince1970, to: 12, in: statement)
      try stepDone(statement)
    }
  }

  func insertAgentRun(_ run: AgentRun) throws {
    try withStatement(
      """
      INSERT INTO agent_runs (
          id, product_id, work_item_id, profile_id, status, codex_thread_id,
          worktree_path, ticket_budget_used, context_used_tokens,
          context_window_tokens, compaction_count, created_at, updated_at,
          sprint_id, sprint_item_id, turn_started_at, last_activity_at,
          last_activity_text, last_activity_kind, active_duration_seconds
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(run.id.uuidString, to: 1, in: statement)
      try bind(run.productID.uuidString, to: 2, in: statement)
      try bind(run.workItemID.uuidString, to: 3, in: statement)
      try bind(run.profileID.uuidString, to: 4, in: statement)
      try bind(run.status.rawValue, to: 5, in: statement)
      try bindOptionalString(run.codexThreadID, to: 6, in: statement)
      try bindOptionalString(run.worktreePath, to: 7, in: statement)
      try bind(run.ticketBudgetUsed, to: 8, in: statement)
      try bindOptionalInt(run.contextUsedTokens, to: 9, in: statement)
      try bindOptionalInt(run.contextWindowTokens, to: 10, in: statement)
      try bind(Int64(run.compactionCount), to: 11, in: statement)
      try bind(run.createdAt.timeIntervalSince1970, to: 12, in: statement)
      try bind(run.updatedAt.timeIntervalSince1970, to: 13, in: statement)
      try bindOptionalUUID(run.sprintID, to: 14, in: statement)
      try bindOptionalUUID(run.sprintItemID, to: 15, in: statement)
      try bindOptionalDate(run.turnStartedAt, to: 16, in: statement)
      try bindOptionalDate(run.lastActivityAt, to: 17, in: statement)
      try bindOptionalString(run.lastActivityText, to: 18, in: statement)
      try bindOptionalString(run.lastActivityKind?.rawValue, to: 19, in: statement)
      try bind(run.activeDurationSeconds, to: 20, in: statement)
      try stepDone(statement)
    }
  }

  func fetchSprint(id: UUID) throws -> Sprint {
    try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             plan_version, started_at, completed_at,
             retrospective_concluded_at, created_at, updated_at
      FROM sprints WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("sprint \(id)")
      }
      return try decodeSprint(statement)
    }
  }

  func fetchSprint(productID: UUID, state: SprintState) throws -> Sprint? {
    try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             plan_version, started_at, completed_at,
             retrospective_concluded_at, created_at, updated_at
      FROM sprints
      WHERE product_id = ? AND state = ?
      ORDER BY created_at DESC LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(state.rawValue, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeSprint(statement)
    }
  }

  func fetchInProgressSprint(productID: UUID) throws -> Sprint? {
    try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             plan_version, started_at, completed_at,
             retrospective_concluded_at, created_at, updated_at
      FROM sprints
      WHERE product_id = ? AND state IN ('active', 'paused')
      ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END, created_at DESC
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeSprint(statement)
    }
  }

  func fetchSprintItems(sprintID: UUID) throws -> [SprintItem] {
    try withStatement(
      """
      SELECT id, sprint_id, work_item_id, implementer_profile_id,
             reviewer_profile_id, estimated_tokens, frozen_work_item_version,
             frozen_title, frozen_body, frozen_acceptance_criteria_json,
             created_at, updated_at
      FROM sprint_items
      WHERE sprint_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(sprintID.uuidString, to: 1, in: statement)
      var items: [SprintItem] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedSprintID = UUID(uuidString: try text(statement, column: 1)),
          let workItemID = UUID(uuidString: try text(statement, column: 2))
        else {
          throw PersistenceError.corruptData("Invalid sprint item")
        }
        let criteriaJSON = try optionalText(statement, column: 9)
        items.append(
          SprintItem(
            id: id,
            sprintID: storedSprintID,
            workItemID: workItemID,
            implementerProfileID: try optionalText(statement, column: 3).flatMap(
              UUID.init(uuidString:)),
            reviewerProfileID: try optionalText(statement, column: 4).flatMap(
              UUID.init(uuidString:)),
            estimatedTokens: Int(sqlite3_column_int64(statement, 5)),
            frozenWorkItemVersion: optionalInt(statement, column: 6),
            frozenTitle: try optionalText(statement, column: 7),
            frozenBody: try optionalText(statement, column: 8),
            frozenAcceptanceCriteria: try criteriaJSON.map(decodeStringArray),
            createdAt: date(statement, column: 10),
            updatedAt: date(statement, column: 11)
          )
        )
      }
      return items
    }
  }

  func nextSprintNumber(productID: UUID) throws -> Int {
    try withStatement(
      "SELECT COALESCE(MAX(sprint_number), 0) + 1 FROM sprints WHERE product_id = ?;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  func decodeSprint(_ statement: OpaquePointer) throws -> Sprint {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let state = SprintState(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid sprint")
    }
    return Sprint(
      id: id,
      productID: productID,
      number: Int(sqlite3_column_int64(statement, 2)),
      goal: try text(statement, column: 3),
      state: state,
      tokenBudgetLimit: optionalInt(statement, column: 5),
      planVersion: Int(sqlite3_column_int64(statement, 6)),
      startedAt: optionalDate(statement, column: 7),
      completedAt: optionalDate(statement, column: 8),
      retrospectiveConcludedAt: optionalDate(statement, column: 9),
      createdAt: date(statement, column: 10),
      updatedAt: date(statement, column: 11)
    )
  }

  func insertWorkItem(
    productID: UUID,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority,
    epicID: UUID? = nil
  ) throws -> WorkItem {
    if let epicID {
      let epic = try fetchEpic(id: epicID)
      guard epic.productID == productID else {
        throw PersistenceError.corruptData("Epic and ticket must belong to the same product")
      }
      guard epic.status == .open else {
        throw PersistenceError.corruptData("Tickets can only be created in an open epic")
      }
    }
    let nextNumber = try nextWorkItemNumber(productID: productID)
    let nextRank = try nextWorkItemRank(productID: productID)
    let workItem = WorkItem(
      productID: productID,
      key: "T\(nextNumber)",
      title: title,
      type: type,
      body: body,
      acceptanceCriteria: acceptanceCriteria,
      priority: priority,
      rank: nextRank,
      epicID: epicID
    )
    let criteria = try encodeStringArray(acceptanceCriteria)
    try withStatement(
      """
      INSERT INTO work_items (
          id, product_id, key_number, item_key, title, body,
          acceptance_criteria_json, state, priority, version,
          created_at, updated_at, ticket_type, rank, custom_fields_json, owner_profile_id,
          epic_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(workItem.id.uuidString, to: 1, in: statement)
      try bind(productID.uuidString, to: 2, in: statement)
      try bind(Int64(nextNumber), to: 3, in: statement)
      try bind(workItem.key, to: 4, in: statement)
      try bind(workItem.title, to: 5, in: statement)
      try bind(workItem.body, to: 6, in: statement)
      try bind(criteria, to: 7, in: statement)
      try bind(workItem.state.rawValue, to: 8, in: statement)
      try bind(Int64(workItem.priority.rawValue), to: 9, in: statement)
      try bind(Int64(workItem.version), to: 10, in: statement)
      try bind(workItem.createdAt.timeIntervalSince1970, to: 11, in: statement)
      try bind(workItem.updatedAt.timeIntervalSince1970, to: 12, in: statement)
      try bind(workItem.type.rawValue, to: 13, in: statement)
      try bind(Int64(workItem.rank), to: 14, in: statement)
      try bind("{}", to: 15, in: statement)
      try bindOptionalUUID(workItem.ownerProfileID, to: 16, in: statement)
      try bindOptionalUUID(workItem.epicID, to: 17, in: statement)
      try stepDone(statement)
    }
    return workItem
  }

  func fetchSuggestionSession(id: UUID) throws -> SuggestionSession {
    try withStatement(
      """
      SELECT id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
             error_message, created_at, updated_at
      FROM suggestion_sessions WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("suggestion session \(id)")
      }
      return try decodeSuggestionSession(statement)
    }
  }

  func fetchSuggestionSession(
    productID: UUID,
    status: SuggestionSessionStatus
  ) throws -> SuggestionSession? {
    try withStatement(
      """
      SELECT id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
             error_message, created_at, updated_at
      FROM suggestion_sessions
      WHERE product_id = ? AND status = ?
      ORDER BY created_at DESC LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(status.rawValue, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeSuggestionSession(statement)
    }
  }

  func fetchSuggestionSession(
    sourceWorkItemID: UUID
  ) throws -> SuggestionSession? {
    try withStatement(
      """
      SELECT id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
             error_message, created_at, updated_at
      FROM suggestion_sessions
      WHERE source_work_item_id = ?
      LIMIT 1;
      """
    ) { statement in
      try bind(sourceWorkItemID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeSuggestionSession(statement)
    }
  }

  func decodeSuggestionSession(_ statement: OpaquePointer) throws -> SuggestionSession {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let status = SuggestionSessionStatus(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid suggestion session")
    }
    return SuggestionSession(
      id: id,
      productID: productID,
      epicID: try optionalText(statement, column: 2).flatMap(UUID.init(uuidString:)),
      sourceWorkItemID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
      status: status,
      codexThreadID: try optionalText(statement, column: 5),
      codexTurnID: try optionalText(statement, column: 6),
      errorMessage: try optionalText(statement, column: 7),
      createdAt: date(statement, column: 8),
      updatedAt: date(statement, column: 9)
    )
  }

  func fetchTicketSuggestionBatch(sessionID: UUID) throws -> TicketSuggestionBatch {
    let session = try fetchSuggestionSession(id: sessionID)
    let suggestions = try withStatement(
      """
      SELECT id, session_id, reference, position, title, body,
             acceptance_criteria_json, suggested_role, priority, rationale,
             status, accepted_work_item_id, created_at, updated_at, ticket_type
      FROM ticket_suggestions
      WHERE session_id = ?
      ORDER BY position ASC;
      """
    ) { statement in
      try bind(sessionID.uuidString, to: 1, in: statement)
      var suggestions: [TicketSuggestion] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        suggestions.append(try decodeTicketSuggestion(statement))
      }
      return suggestions
    }
    let dependencies = try fetchSuggestionDependencies(sessionID: sessionID)
    let existingDependencies = try fetchSuggestionExistingDependencies(sessionID: sessionID)
    return TicketSuggestionBatch(
      session: session,
      suggestions: suggestions.map { suggestion in
        var updated = suggestion
        updated.dependencyIDs = dependencies[suggestion.id] ?? []
        updated.existingDependencyWorkItemIDs = existingDependencies[suggestion.id] ?? []
        return updated
      }
    )
  }

  func fetchTicketSuggestion(id: UUID) throws -> TicketSuggestion {
    try withStatement(
      """
      SELECT id, session_id, reference, position, title, body,
             acceptance_criteria_json, suggested_role, priority, rationale,
             status, accepted_work_item_id, created_at, updated_at, ticket_type
      FROM ticket_suggestions WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("ticket suggestion \(id)")
      }
      var suggestion = try decodeTicketSuggestion(statement)
      suggestion.dependencyIDs =
        try fetchSuggestionDependencies(
          sessionID: suggestion.sessionID
        )[suggestion.id] ?? []
      suggestion.existingDependencyWorkItemIDs =
        try fetchSuggestionExistingDependencies(
          sessionID: suggestion.sessionID
        )[suggestion.id] ?? []
      return suggestion
    }
  }

  func decodeTicketSuggestion(_ statement: OpaquePointer) throws -> TicketSuggestion {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let sessionID = UUID(uuidString: try text(statement, column: 1)),
      let role = AgentRole(rawValue: try text(statement, column: 7)),
      let priority = WorkItemPriority(rawValue: Int(sqlite3_column_int64(statement, 8))),
      let status = TicketSuggestionStatus(rawValue: try text(statement, column: 10))
    else {
      throw PersistenceError.corruptData("Invalid ticket suggestion")
    }
    return TicketSuggestion(
      id: id,
      sessionID: sessionID,
      reference: try text(statement, column: 2),
      position: Int(sqlite3_column_int64(statement, 3)),
      title: try text(statement, column: 4),
      type: WorkItemType(rawValue: try text(statement, column: 14)) ?? .story,
      body: try text(statement, column: 5),
      acceptanceCriteria: try decodeStringArray(try text(statement, column: 6)),
      suggestedRole: role,
      priority: priority,
      rationale: try text(statement, column: 9),
      status: status,
      acceptedWorkItemID: try optionalText(statement, column: 11).flatMap(UUID.init(uuidString:)),
      createdAt: date(statement, column: 12),
      updatedAt: date(statement, column: 13)
    )
  }

  func fetchSuggestionDependencies(sessionID: UUID) throws -> [UUID: [UUID]] {
    try withStatement(
      """
      SELECT d.suggestion_id, d.depends_on_suggestion_id
      FROM suggestion_dependencies d
      JOIN ticket_suggestions s ON s.id = d.suggestion_id
      WHERE s.session_id = ?
      ORDER BY d.suggestion_id, d.depends_on_suggestion_id;
      """
    ) { statement in
      try bind(sessionID.uuidString, to: 1, in: statement)
      var dependencies: [UUID: [UUID]] = [:]
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let suggestionID = UUID(uuidString: try text(statement, column: 0)),
          let dependencyID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid suggestion dependency")
        }
        dependencies[suggestionID, default: []].append(dependencyID)
      }
      return dependencies
    }
  }

  func fetchSuggestionExistingDependencies(
    sessionID: UUID
  ) throws -> [UUID: [UUID]] {
    try withStatement(
      """
      SELECT d.suggestion_id, d.depends_on_work_item_id
      FROM suggestion_existing_dependencies d
      JOIN ticket_suggestions s ON s.id = d.suggestion_id
      WHERE s.session_id = ?
      ORDER BY d.suggestion_id, d.depends_on_work_item_id;
      """
    ) { statement in
      try bind(sessionID.uuidString, to: 1, in: statement)
      var dependencies: [UUID: [UUID]] = [:]
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let suggestionID = UUID(uuidString: try text(statement, column: 0)),
          let workItemID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid existing suggestion dependency")
        }
        dependencies[suggestionID, default: []].append(workItemID)
      }
      return dependencies
    }
  }

  func reconcileAcceptedSuggestionDependencies(sessionID: UUID) throws {
    try withStatement(
      """
      INSERT OR IGNORE INTO work_item_dependencies (
          work_item_id, depends_on_work_item_id, source, created_at
      )
      SELECT child.accepted_work_item_id, parent.accepted_work_item_id,
             'ticket_suggestion', ?
      FROM suggestion_dependencies d
      JOIN ticket_suggestions child ON child.id = d.suggestion_id
      JOIN ticket_suggestions parent ON parent.id = d.depends_on_suggestion_id
      WHERE child.session_id = ?
        AND child.status = 'accepted'
        AND parent.status = 'accepted'
        AND child.accepted_work_item_id IS NOT NULL
        AND parent.accepted_work_item_id IS NOT NULL;
      """
    ) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      try bind(sessionID.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
    try withStatement(
      """
      INSERT OR IGNORE INTO work_item_dependencies (
          work_item_id, depends_on_work_item_id, source, created_at
      )
      SELECT child.accepted_work_item_id, d.depends_on_work_item_id,
             'ticket_suggestion', ?
      FROM suggestion_existing_dependencies d
      JOIN ticket_suggestions child ON child.id = d.suggestion_id
      WHERE child.session_id = ?
        AND child.status = 'accepted'
        AND child.accepted_work_item_id IS NOT NULL;
      """
    ) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      try bind(sessionID.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
  }

  func replaceWorkItemDependencies(
    for workItem: WorkItem,
    dependsOnWorkItemIDs: Set<UUID>
  ) throws {
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    guard planningStates.contains(workItem.state) else {
      throw PersistenceError.corruptData(
        "Blockers cannot be changed after \(workItem.key) has entered delivery"
      )
    }
    guard !dependsOnWorkItemIDs.contains(workItem.id) else {
      throw PersistenceError.corruptData("A ticket cannot block itself")
    }

    for dependencyID in dependsOnWorkItemIDs {
      let dependency = try fetchWorkItem(id: dependencyID)
      guard dependency.productID == workItem.productID else {
        throw PersistenceError.corruptData("Blockers must belong to the same product")
      }
    }

    try withStatement(
      "DELETE FROM work_item_dependencies WHERE work_item_id = ?;"
    ) { statement in
      try bind(workItem.id.uuidString, to: 1, in: statement)
      try stepDone(statement)
    }

    for dependencyID in dependsOnWorkItemIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      try withStatement(
        """
        INSERT INTO work_item_dependencies (
            work_item_id, depends_on_work_item_id, source, created_at
        ) VALUES (?, ?, 'owner', ?);
        """
      ) { statement in
        try bind(workItem.id.uuidString, to: 1, in: statement)
        try bind(dependencyID.uuidString, to: 2, in: statement)
        try bind(Date().timeIntervalSince1970, to: 3, in: statement)
        try stepDone(statement)
      }
    }

    try validateDependencyGraph(productID: workItem.productID)
    try normalizePlanningRanks(productID: workItem.productID)
  }

  func validateDependencyGraph(productID: UUID) throws {
    let edges = try fetchWorkItemDependencies(productID: productID)
    let dependenciesByItem = Dictionary(grouping: edges, by: \.workItemID)
      .mapValues { Set($0.map(\.dependsOnWorkItemID)) }
    let allIDs = Set(edges.flatMap { [$0.workItemID, $0.dependsOnWorkItemID] })
    var visiting: Set<UUID> = []
    var visited: Set<UUID> = []

    func visit(_ id: UUID) throws {
      if visiting.contains(id) {
        throw PersistenceError.corruptData(
          "Adding this blocker would create a dependency cycle"
        )
      }
      guard !visited.contains(id) else { return }
      visiting.insert(id)
      for dependencyID in dependenciesByItem[id, default: []] {
        try visit(dependencyID)
      }
      visiting.remove(id)
      visited.insert(id)
    }

    for id in allIDs {
      try visit(id)
    }
  }

  func normalizePlanningRanks(productID: UUID) throws {
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    var remaining = try fetchWorkItems(productID: productID)
      .filter { planningStates.contains($0.state) }
    let planningIDs = Set(remaining.map(\.id))
    let prerequisitesByItem = Dictionary(
      grouping: try fetchWorkItemDependencies(productID: productID),
      by: \.workItemID
    ).mapValues { edges in
      Set(edges.map(\.dependsOnWorkItemID)).intersection(planningIDs)
    }
    var placedIDs: Set<UUID> = []
    var ordered: [WorkItem] = []

    while !remaining.isEmpty {
      guard
        let nextIndex = remaining.firstIndex(where: { item in
          prerequisitesByItem[item.id, default: []].isSubset(of: placedIDs)
        })
      else {
        throw PersistenceError.corruptData("Work item dependencies contain a cycle")
      }
      let next = remaining.remove(at: nextIndex)
      ordered.append(next)
      placedIDs.insert(next.id)
    }

    for (index, item) in ordered.enumerated() {
      try withStatement("UPDATE work_items SET rank = ? WHERE id = ?;") { statement in
        try bind(Int64((index + 1) * 1_000), to: 1, in: statement)
        try bind(item.id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
    }
  }

  func fetchWorkItem(id: UUID) throws -> WorkItem {
    try withStatement(
      """
      SELECT id, product_id, item_key, title, ticket_type, body,
             acceptance_criteria_json, state, priority, version,
             created_at, updated_at, rank, custom_fields_json, owner_profile_id, epic_id
      FROM work_items
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("work item \(id)")
      }
      return try decodeWorkItem(statement)
    }
  }

  func nextWorkItemNumber(productID: UUID) throws -> Int {
    try withStatement(
      """
      SELECT COALESCE(MAX(key_number), 0) + 1
      FROM work_items
      WHERE product_id = ?;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw currentSQLiteError()
      }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  func nextWorkItemRank(productID: UUID) throws -> Int {
    try withStatement(
      "SELECT COALESCE(MAX(rank), 0) + 1000 FROM work_items WHERE product_id = ?;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw currentSQLiteError()
      }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  func nextEpicRank(productID: UUID) throws -> Int {
    try withStatement(
      "SELECT COALESCE(MAX(rank), 0) + 1000 FROM epics WHERE product_id = ?;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw currentSQLiteError()
      }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  @discardableResult
  func insertEvent(
    productID: UUID,
    workItemID: UUID? = nil,
    kind: String,
    actor: String,
    detail: String
  ) throws -> ActivityEvent {
    let id = UUID()
    let createdAt = Date()

    try withStatement(
      """
      INSERT INTO activity_events (
          id, product_id, work_item_id, kind, actor, detail, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      try bind(productID.uuidString, to: 2, in: statement)
      if let workItemID {
        try bind(workItemID.uuidString, to: 3, in: statement)
      } else {
        try bindNull(to: 3, in: statement)
      }
      try bind(kind, to: 4, in: statement)
      try bind(actor, to: 5, in: statement)
      try bind(detail, to: 6, in: statement)
      try bind(createdAt.timeIntervalSince1970, to: 7, in: statement)
      try stepDone(statement)
    }

    return ActivityEvent(
      sequence: sqlite3_last_insert_rowid(database),
      productID: productID,
      workItemID: workItemID,
      kind: kind,
      actor: actor,
      detail: detail,
      createdAt: createdAt
    )
  }

  func decodeProduct(_ statement: OpaquePointer) throws -> Product {
    guard let id = UUID(uuidString: try text(statement, column: 0)) else {
      throw PersistenceError.corruptData("Invalid product id")
    }
    guard
      let status = ProductStatus(rawValue: try text(statement, column: 3))
    else {
      throw PersistenceError.corruptData("Invalid product status")
    }
    guard
      let color = ProductColor(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid product color")
    }
    return Product(
      id: id,
      name: try text(statement, column: 1),
      instructions: try text(statement, column: 2),
      status: status,
      color: color,
      createdAt: date(statement, column: 5),
      updatedAt: date(statement, column: 6)
    )
  }

  func fetchProduct(id: UUID) throws -> Product {
    try withStatement(
      """
      SELECT id, name, instructions, status, color, created_at, updated_at
      FROM products
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("product \(id)")
      }
      return try decodeProduct(statement)
    }
  }

  func fetchEpic(id: UUID) throws -> Epic {
    try withStatement(
      """
      SELECT id, product_id, title, goal, success_criteria_json, constraints,
             status, color, rank, created_at, updated_at
      FROM epics WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("epic \(id)")
      }
      return try decodeEpic(statement)
    }
  }

  func decodeEpic(_ statement: OpaquePointer) throws -> Epic {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let status = EpicStatus(rawValue: try text(statement, column: 6)),
      let color = EpicColor(rawValue: try text(statement, column: 7))
    else {
      throw PersistenceError.corruptData("Invalid epic")
    }
    return Epic(
      id: id,
      productID: productID,
      title: try text(statement, column: 2),
      goal: try text(statement, column: 3),
      successCriteria: try decodeStringArray(try text(statement, column: 4)),
      constraints: try text(statement, column: 5),
      status: status,
      color: color,
      rank: Int(sqlite3_column_int64(statement, 8)),
      createdAt: date(statement, column: 9),
      updatedAt: date(statement, column: 10)
    )
  }

  func decodeWorkItem(_ statement: OpaquePointer) throws -> WorkItem {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let type = WorkItemType(rawValue: try text(statement, column: 4)),
      let state = WorkItemState(rawValue: try text(statement, column: 7)),
      let priority = WorkItemPriority(rawValue: Int(sqlite3_column_int64(statement, 8)))
    else {
      throw PersistenceError.corruptData("Invalid work item")
    }

    return WorkItem(
      id: id,
      productID: productID,
      key: try text(statement, column: 2),
      title: try text(statement, column: 3),
      type: type,
      body: try text(statement, column: 5),
      acceptanceCriteria: try decodeStringArray(try text(statement, column: 6)),
      state: state,
      priority: priority,
      rank: Int(sqlite3_column_int64(statement, 12)),
      customFields: try decodeStringDictionary(try text(statement, column: 13)),
      ownerProfileID: try optionalText(statement, column: 14).flatMap(UUID.init(uuidString:)),
      epicID: try optionalText(statement, column: 15).flatMap(UUID.init(uuidString:)),
      version: Int(sqlite3_column_int64(statement, 9)),
      createdAt: date(statement, column: 10),
      updatedAt: date(statement, column: 11)
    )
  }

  func ensureKnowledgeMutationAllowed(productID: UUID) throws {
    let hasPublishingRun = try withStatement(
      """
      SELECT 1
      FROM repository_knowledge_runs
      WHERE product_id = ? AND status = 'publishing'
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
    guard !hasPublishingRun else {
      throw PersistenceError.corruptData(
        "Verified product knowledge is publishing and cannot be changed yet"
      )
    }
  }

  func bindRepositoryKnowledgeRun(
    _ run: RepositoryKnowledgeRun,
    to statement: OpaquePointer
  ) throws {
    try bind(run.id.uuidString, to: 1, in: statement)
    try bind(run.productID.uuidString, to: 2, in: statement)
    try bind(Int64(run.attempt), to: 3, in: statement)
    try bind(run.purpose.rawValue, to: 4, in: statement)
    try bind(run.analyzedSHA, to: 5, in: statement)
    try bind(run.analyzerProfileID.uuidString, to: 6, in: statement)
    try bind(run.reviewerProfileID.uuidString, to: 7, in: statement)
    try bindOptionalString(run.analyzerThreadID, to: 8, in: statement)
    try bindOptionalString(run.analyzerTurnID, to: 9, in: statement)
    try bindOptionalString(run.reviewerThreadID, to: 10, in: statement)
    try bindOptionalString(run.reviewerTurnID, to: 11, in: statement)
    try bind(run.status.rawValue, to: 12, in: statement)
    try bindOptionalString(run.analysisSummary, to: 13, in: statement)
    try bindOptionalString(run.reviewSummary, to: 14, in: statement)
    try bindOptionalString(run.errorMessage, to: 15, in: statement)
    try bind(try encodeStringArray(run.knowledgeExportPaths), to: 16, in: statement)
    try bindOptionalString(run.knowledgeCommitSHA, to: 17, in: statement)
    try bind(run.createdAt.timeIntervalSince1970, to: 18, in: statement)
    try bind(run.updatedAt.timeIntervalSince1970, to: 19, in: statement)
  }

  func decodeRepositoryKnowledgeRun(
    _ statement: OpaquePointer
  ) throws -> RepositoryKnowledgeRun {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let purpose = RepositoryKnowledgeRunPurpose(rawValue: try text(statement, column: 3)),
      let analyzerProfileID = UUID(uuidString: try text(statement, column: 5)),
      let reviewerProfileID = UUID(uuidString: try text(statement, column: 6)),
      let status = RepositoryKnowledgeRunStatus(rawValue: try text(statement, column: 11))
    else {
      throw PersistenceError.corruptData("Invalid repository knowledge run")
    }
    return RepositoryKnowledgeRun(
      id: id,
      productID: productID,
      attempt: Int(sqlite3_column_int64(statement, 2)),
      purpose: purpose,
      analyzedSHA: try text(statement, column: 4),
      analyzerProfileID: analyzerProfileID,
      reviewerProfileID: reviewerProfileID,
      analyzerThreadID: try optionalText(statement, column: 7),
      analyzerTurnID: try optionalText(statement, column: 8),
      reviewerThreadID: try optionalText(statement, column: 9),
      reviewerTurnID: try optionalText(statement, column: 10),
      status: status,
      analysisSummary: try optionalText(statement, column: 12),
      reviewSummary: try optionalText(statement, column: 13),
      errorMessage: try optionalText(statement, column: 14),
      knowledgeExportPaths: try decodeStringArray(try text(statement, column: 15)),
      knowledgeCommitSHA: try optionalText(statement, column: 16),
      createdAt: date(statement, column: 17),
      updatedAt: date(statement, column: 18)
    )
  }

  func insertRepositoryKnowledgeDraft(
    _ draft: RepositoryKnowledgeDraft
  ) throws {
    try withStatement(
      """
      INSERT INTO repository_knowledge_drafts (
          id, run_id, operation, target_page_id, parent_page_id,
          base_page_title, base_page_body_markdown, base_page_updated_at,
          title, proposed_body_markdown, rationale, evidence_json, status,
          review_explanation, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(draft.id.uuidString, to: 1, in: statement)
      try bind(draft.runID.uuidString, to: 2, in: statement)
      try bind(draft.operation.rawValue, to: 3, in: statement)
      try bindOptionalUUID(draft.targetPageID, to: 4, in: statement)
      try bindOptionalUUID(draft.parentPageID, to: 5, in: statement)
      try bindOptionalString(draft.basePageTitle, to: 6, in: statement)
      try bindOptionalString(draft.basePageBodyMarkdown, to: 7, in: statement)
      if let basePageUpdatedAt = draft.basePageUpdatedAt {
        try bind(basePageUpdatedAt.timeIntervalSince1970, to: 8, in: statement)
      } else {
        sqlite3_bind_null(statement, 8)
      }
      try bind(draft.title, to: 9, in: statement)
      try bind(draft.proposedBodyMarkdown, to: 10, in: statement)
      try bind(draft.rationale, to: 11, in: statement)
      try bind(try encodeJSON(draft.evidence), to: 12, in: statement)
      try bind(draft.status.rawValue, to: 13, in: statement)
      try bindOptionalString(draft.reviewExplanation, to: 14, in: statement)
      try bind(draft.createdAt.timeIntervalSince1970, to: 15, in: statement)
      try bind(draft.updatedAt.timeIntervalSince1970, to: 16, in: statement)
      try stepDone(statement)
    }
  }

  func decodeRepositoryKnowledgeDraft(
    _ statement: OpaquePointer
  ) throws -> RepositoryKnowledgeDraft {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let runID = UUID(uuidString: try text(statement, column: 1)),
      let operation = RepositoryKnowledgeDraftOperation(
        rawValue: try text(statement, column: 2)
      ),
      let status = RepositoryKnowledgeDraftStatus(
        rawValue: try text(statement, column: 12)
      )
    else {
      throw PersistenceError.corruptData("Invalid repository knowledge draft")
    }
    return RepositoryKnowledgeDraft(
      id: id,
      runID: runID,
      operation: operation,
      targetPageID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
      parentPageID: try optionalText(statement, column: 4).flatMap(UUID.init(uuidString:)),
      basePageTitle: try optionalText(statement, column: 5),
      basePageBodyMarkdown: try optionalText(statement, column: 6),
      basePageUpdatedAt: optionalDate(statement, column: 7),
      title: try text(statement, column: 8),
      proposedBodyMarkdown: try text(statement, column: 9),
      rationale: try text(statement, column: 10),
      evidence: try decodeJSON(
        [RepositoryEvidence].self,
        from: try text(statement, column: 11)
      ),
      status: status,
      reviewExplanation: try optionalText(statement, column: 13),
      createdAt: date(statement, column: 14),
      updatedAt: date(statement, column: 15)
    )
  }

  func insertRepositoryLaunchProposal(
    _ proposal: RepositoryLaunchProposal
  ) throws {
    try withStatement(
      """
      INSERT INTO repository_launch_proposals (
          id, run_id, specification_json, evidence_json, status,
          review_explanation, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(proposal.id.uuidString, to: 1, in: statement)
      try bind(proposal.runID.uuidString, to: 2, in: statement)
      try bind(try encodeJSON(proposal.specification), to: 3, in: statement)
      try bind(try encodeJSON(proposal.evidence), to: 4, in: statement)
      try bind(proposal.status.rawValue, to: 5, in: statement)
      try bindOptionalString(proposal.reviewExplanation, to: 6, in: statement)
      try bind(proposal.createdAt.timeIntervalSince1970, to: 7, in: statement)
      try bind(proposal.updatedAt.timeIntervalSince1970, to: 8, in: statement)
      try stepDone(statement)
    }
  }

  func decodeRepositoryLaunchProposal(
    _ statement: OpaquePointer
  ) throws -> RepositoryLaunchProposal {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let runID = UUID(uuidString: try text(statement, column: 1)),
      let status = RepositoryLaunchProposalStatus(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid imported app launch proposal")
    }
    return RepositoryLaunchProposal(
      id: id,
      runID: runID,
      specification: try decodeJSON(
        DemoLaunchSpecification.self,
        from: try text(statement, column: 2)
      ),
      evidence: try decodeJSON(
        [RepositoryEvidence].self,
        from: try text(statement, column: 3)
      ),
      status: status,
      reviewExplanation: try optionalText(statement, column: 5),
      createdAt: date(statement, column: 6),
      updatedAt: date(statement, column: 7)
    )
  }

  func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData("Could not encode repository metadata")
    }
    return string
  }

  func decodeJSON<Value: Decodable>(
    _ type: Value.Type,
    from string: String
  ) throws -> Value {
    guard let data = string.data(using: .utf8) else {
      throw PersistenceError.corruptData("Could not decode repository metadata")
    }
    return try decoder.decode(type, from: data)
  }

  func uniqueKnowledgeSlug(title: String, existing: Set<String>) -> String {
    let base = title.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .joined(separator: "-")
    let normalizedBase = base.isEmpty ? "page" : base
    var candidate = normalizedBase
    var suffix = 2
    while existing.contains(candidate) {
      candidate = "\(normalizedBase)-\(suffix)"
      suffix += 1
    }
    return candidate
  }

  func encodeStringArray(_ values: [String]) throws -> String {
    let data = try encoder.encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData("Could not encode string array")
    }
    return value
  }

  func decodeStringArray(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else {
      throw PersistenceError.corruptData("Could not decode string array")
    }
    return try decoder.decode([String].self, from: data)
  }

  func encodeStringDictionary(_ values: [String: String]) throws -> String {
    let data = try encoder.encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData("Could not encode custom fields")
    }
    return value
  }

  func decodeStringDictionary(_ value: String) throws -> [String: String] {
    guard let data = value.data(using: .utf8) else {
      throw PersistenceError.corruptData("Could not decode custom fields")
    }
    return try decoder.decode([String: String].self, from: data)
  }

  func transaction(_ operation: () throws -> Void) throws {
    if transactionDepth > 0 {
      try operation()
      return
    }

    try execute("BEGIN IMMEDIATE;")
    transactionDepth = 1
    do {
      try operation()
      try execute("COMMIT;")
      transactionDepth = 0
    } catch {
      try? execute("ROLLBACK;")
      transactionDepth = 0
      throw error
    }
  }

  func readTransaction<Value>(_ operation: () throws -> Value) throws -> Value {
    try execute("BEGIN DEFERRED;")
    do {
      let value = try operation()
      try execute("COMMIT;")
      return value
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func execute(_ sql: String) throws {
    guard let database else {
      throw PersistenceError.sqlite(code: SQLITE_MISUSE, message: "Database is closed")
    }
    try Self.execute(sql, database: database)
  }

  static func execute(_ sql: String, database: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      throw PersistenceError.sqlite(code: result, message: message)
    }
  }

  func withStatement<T>(
    _ sql: String,
    operation: (OpaquePointer) throws -> T
  ) throws -> T {
    guard let database else {
      throw PersistenceError.sqlite(code: SQLITE_MISUSE, message: "Database is closed")
    }
    #if DEBUG
      preparedStatementCount += 1
    #endif
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw currentSQLiteError(code: result)
    }
    defer { sqlite3_finalize(statement) }
    return try operation(statement)
  }

  func stepDone(_ statement: OpaquePointer) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      throw currentSQLiteError(code: result)
    }
  }

  func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let result = value.withCString {
      sqlite3_bind_text(statement, index, $0, -1, transient)
    }
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
    let result = sqlite3_bind_int64(statement, index, value)
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
    let result = sqlite3_bind_double(statement, index, value)
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  func bindOptionalString(
    _ value: String?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    if let value {
      try bind(value, to: index, in: statement)
    } else {
      try bindNull(to: index, in: statement)
    }
  }

  func bindOptionalUUID(
    _ value: UUID?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    try bindOptionalString(value?.uuidString, to: index, in: statement)
  }

  func bindOptionalInt(
    _ value: Int?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    if let value {
      try bind(Int64(value), to: index, in: statement)
    } else {
      try bindNull(to: index, in: statement)
    }
  }

  func bindOptionalDate(
    _ value: Date?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    if let value {
      try bind(value.timeIntervalSince1970, to: index, in: statement)
    } else {
      try bindNull(to: index, in: statement)
    }
  }

  func bindNull(to index: Int32, in statement: OpaquePointer) throws {
    let result = sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard let value = sqlite3_column_text(statement, column) else {
      throw PersistenceError.corruptData("Missing text at column \(column)")
    }
    return String(cString: value)
  }

  func optionalText(_ statement: OpaquePointer, column: Int32) throws -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return try text(statement, column: column)
  }

  func optionalInt(_ statement: OpaquePointer, column: Int32) -> Int? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, column))
  }

  func date(_ statement: OpaquePointer, column: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
  }

  func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return date(statement, column: column)
  }

  func currentSQLiteError(code: Int32? = nil) -> PersistenceError {
    guard let database else {
      return .sqlite(code: code ?? SQLITE_MISUSE, message: "Database is closed")
    }
    return .sqlite(
      code: code ?? sqlite3_errcode(database),
      message: String(cString: sqlite3_errmsg(database))
    )
  }
}
