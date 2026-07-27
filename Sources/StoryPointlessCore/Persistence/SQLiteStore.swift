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
  private var database: OpaquePointer?
  private let workflowPolicy: WorkflowPolicy
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(url: URL, workflowPolicy: WorkflowPolicy = WorkflowPolicy()) throws {
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
      try Self.migrate(database: connection)
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

  public func createProduct(name: String, vision: String) throws -> Product {
    let product = Product(
      name: name,
      vision: vision,
      color: try nextProductColor()
    )

    try transaction {
      try withStatement(
        """
        INSERT INTO products (
            id, name, vision, instructions, status, color, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(product.id.uuidString, to: 1, in: statement)
        try bind(product.name, to: 2, in: statement)
        try bind(product.vision, to: 3, in: statement)
        try bind(product.instructions, to: 4, in: statement)
        try bind(product.status.rawValue, to: 5, in: statement)
        try bind(product.color.rawValue, to: 6, in: statement)
        try bind(product.createdAt.timeIntervalSince1970, to: 7, in: statement)
        try bind(product.updatedAt.timeIntervalSince1970, to: 8, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: product.id,
        kind: "product.created",
        actor: "owner",
        detail: product.name
      )
    }

    return product
  }

  private func nextProductColor() throws -> ProductColor {
    let existingColors = try withStatement(
      """
      SELECT color
      FROM products
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      var colors: [ProductColor] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let rawValue = try text(statement, column: 0)
        guard let color = ProductColor(rawValue: rawValue) else {
          throw PersistenceError.corruptData("Invalid product color")
        }
        colors.append(color)
      }
      return colors
    }

    guard let mostRecentColor = existingColors.last else {
      return .accent
    }

    let usedColors = Set(existingColors)
    let unusedColors = ProductColor.automaticallyAssigned.filter {
      !usedColors.contains($0)
    }
    let availableColors = unusedColors.isEmpty
      ? ProductColor.automaticallyAssigned.filter { $0 != mostRecentColor }
      : unusedColors
    return availableColors.randomElement() ?? .blue
  }

  public func fetchProducts(status: ProductStatus = .active) throws -> [Product] {
    try withStatement(
      """
      SELECT id, name, vision, instructions, status, color, created_at,
             COALESCE(
               (
                 SELECT created_at
                 FROM activity_events
                 WHERE product_id = products.id
                 ORDER BY sequence DESC
                 LIMIT 1
               ),
               products.updated_at
             )
      FROM products
      WHERE status = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      var products: [Product] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        products.append(try decodeProduct(statement))
      }
      return products
    }
  }

  public func archiveProduct(id: UUID) throws -> Product {
    try setProductStatus(id: id, status: .archived)
  }

  public func restoreProduct(id: UUID) throws -> Product {
    try setProductStatus(id: id, status: .active)
  }

  private func setProductStatus(id: UUID, status: ProductStatus) throws -> Product {
    var product = try fetchProduct(id: id)
    guard product.status != status else { return product }

    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET status = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(status.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: id,
        kind: status == .archived ? "product.archived" : "product.restored",
        actor: "owner",
        detail: product.name
      )
    }

    product.status = status
    product.updatedAt = updatedAt
    return product
  }

  public func updateProductInstructions(productID: UUID, instructions: String) throws {
    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET instructions = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(instructions.trimmingCharacters(in: .whitespacesAndNewlines), to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(productID.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "product.instructions_updated",
        actor: "owner",
        detail: "Shared team instructions updated"
      )
    }
  }

  public func updateProductDetails(productID: UUID, name: String, vision: String) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedVision = vision.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !trimmedVision.isEmpty else {
      throw PersistenceError.corruptData("Product name and description cannot be empty")
    }
    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE products SET name = ?, vision = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(trimmedName, to: 1, in: statement)
        try bind(trimmedVision, to: 2, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(productID.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "product.details_updated",
        actor: "owner",
        detail: trimmedName
      )
    }
  }

  public func createEpic(productID: UUID, outcome: String) throws -> Epic {
    let goal = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !goal.isEmpty else {
      throw PersistenceError.corruptData("Epic outcome cannot be empty")
    }
    let firstLine = goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? goal
    let provisionalTitle = String(firstLine.prefix(72))
    let epic = Epic(
      productID: productID,
      title: provisionalTitle,
      goal: goal,
      color: try nextEpicColor(productID: productID),
      rank: try nextEpicRank(productID: productID)
    )
    try transaction {
      try withStatement(
        """
        INSERT INTO epics (
            id, product_id, title, goal, success_criteria_json, constraints,
            status, color, rank, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(epic.id.uuidString, to: 1, in: statement)
        try bind(epic.productID.uuidString, to: 2, in: statement)
        try bind(epic.title, to: 3, in: statement)
        try bind(epic.goal, to: 4, in: statement)
        try bind(try encodeStringArray(epic.successCriteria), to: 5, in: statement)
        try bind(epic.constraints, to: 6, in: statement)
        try bind(epic.status.rawValue, to: 7, in: statement)
        try bind(epic.color.rawValue, to: 8, in: statement)
        try bind(Int64(epic.rank), to: 9, in: statement)
        try bind(epic.createdAt.timeIntervalSince1970, to: 10, in: statement)
        try bind(epic.updatedAt.timeIntervalSince1970, to: 11, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "epic.created",
        actor: "owner",
        detail: epic.title
      )
    }
    return epic
  }

  private func nextEpicColor(productID: UUID) throws -> EpicColor {
    let existingColors = try withStatement(
      """
      SELECT color
      FROM epics
      WHERE product_id = ? AND status = 'open'
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var colors: [EpicColor] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let rawValue = try text(statement, column: 0)
        guard let color = EpicColor(rawValue: rawValue) else {
          throw PersistenceError.corruptData("Invalid epic color")
        }
        colors.append(color)
      }
      return colors
    }

    let usedColors = Set(existingColors)
    if let unusedColor = EpicColor.assignmentOrder.first(where: {
      !usedColors.contains($0)
    }) {
      return unusedColor
    }
    return EpicColor.assignmentOrder[
      existingColors.count % EpicColor.assignmentOrder.count
    ]
  }

  public func fetchEpics(productID: UUID) throws -> [Epic] {
    try withStatement(
      """
      SELECT id, product_id, title, goal, success_criteria_json, constraints,
             status, color, rank, created_at, updated_at
      FROM epics
      WHERE product_id = ?
      ORDER BY rank ASC, created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var epics: [Epic] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        epics.append(try decodeEpic(statement))
      }
      return epics
    }
  }

  public func saveEpicPlanningConversation(
    _ snapshot: EpicPlanningConversationSnapshot
  ) throws {
    let data = try encoder.encode(snapshot)
    guard let json = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData("Could not encode the epic conversation")
    }
    try withStatement(
      """
      INSERT INTO epic_planning_conversations (epic_id, snapshot_json, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(epic_id) DO UPDATE SET
          snapshot_json = excluded.snapshot_json,
          updated_at = excluded.updated_at;
      """
    ) { statement in
      try bind(snapshot.epicID.uuidString, to: 1, in: statement)
      try bind(json, to: 2, in: statement)
      try bind(snapshot.updatedAt.timeIntervalSince1970, to: 3, in: statement)
      try stepDone(statement)
    }
  }

  public func fetchEpicPlanningConversation(
    epicID: UUID
  ) throws -> EpicPlanningConversationSnapshot? {
    try withStatement(
      """
      SELECT snapshot_json
      FROM epic_planning_conversations
      WHERE epic_id = ?;
      """
    ) { statement in
      try bind(epicID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      let json = try text(statement, column: 0)
      guard let data = json.data(using: .utf8) else {
        throw PersistenceError.corruptData("Could not decode the epic conversation")
      }
      let snapshot = try decoder.decode(EpicPlanningConversationSnapshot.self, from: data)
      guard snapshot.epicID == epicID else {
        throw PersistenceError.corruptData("Epic conversation belongs to another epic")
      }
      return snapshot
    }
  }

  public func deleteEpicPlanningConversation(epicID: UUID) throws {
    try withStatement(
      "DELETE FROM epic_planning_conversations WHERE epic_id = ?;"
    ) { statement in
      try bind(epicID.uuidString, to: 1, in: statement)
      try stepDone(statement)
    }
  }

  public func updateEpic(
    id: UUID,
    title: String,
    goal: String,
    successCriteria: [String],
    constraints: String
  ) throws -> Epic {
    let epic = try fetchEpic(id: id)
    guard epic.status == .open else {
      throw PersistenceError.corruptData("Reopen this epic before editing it")
    }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, !trimmedGoal.isEmpty else {
      throw PersistenceError.corruptData("Epic title and goal cannot be empty")
    }
    let criteria = successCriteria
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let updatedAt = Date()
    try withStatement(
      """
      UPDATE epics
      SET title = ?, goal = ?, success_criteria_json = ?, constraints = ?, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(trimmedTitle, to: 1, in: statement)
      try bind(trimmedGoal, to: 2, in: statement)
      try bind(try encodeStringArray(criteria), to: 3, in: statement)
      try bind(constraints.trimmingCharacters(in: .whitespacesAndNewlines), to: 4, in: statement)
      try bind(updatedAt.timeIntervalSince1970, to: 5, in: statement)
      try bind(id.uuidString, to: 6, in: statement)
      try stepDone(statement)
    }
    return try fetchEpic(id: id)
  }

  public func closeEpic(id: UUID) throws -> Epic {
    let epic = try fetchEpic(id: id)
    if epic.status == .closed {
      return epic
    }
    guard epic.status == .open else {
      throw PersistenceError.corruptData("Only an open epic can be closed")
    }
    let tickets = try fetchWorkItems(productID: epic.productID)
      .filter { $0.epicID == epic.id }
    guard EpicProgress(tickets: tickets) == .complete else {
      throw PersistenceError.corruptData(
        "Deliver every accepted ticket before closing this epic"
      )
    }
    let outstandingPlanningCount = try withStatement(
      """
      SELECT
        (
          SELECT COUNT(*)
          FROM ticket_suggestions AS suggestion
          JOIN suggestion_sessions AS session ON session.id = suggestion.session_id
          WHERE session.epic_id = ? AND suggestion.status = 'proposed'
        )
        +
        (
          SELECT COUNT(*)
          FROM suggestion_sessions
          WHERE epic_id = ? AND status = 'generating'
        );
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      try bind(id.uuidString, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int64(statement, 0))
    }
    guard outstandingPlanningCount == 0 else {
      throw PersistenceError.corruptData(
        "Review or dismiss every proposed ticket before closing this epic"
      )
    }

    let updatedAt = Date()
    try transaction {
      try withStatement(
        "UPDATE epics SET status = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(EpicStatus.closed.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: epic.productID,
        kind: "epic.closed",
        actor: "Product Owner",
        detail: epic.title
      )
    }
    return try fetchEpic(id: id)
  }

  public func reopenEpic(id: UUID) throws -> Epic {
    let epic = try fetchEpic(id: id)
    if epic.status == .open {
      return epic
    }
    guard epic.status == .closed else {
      throw PersistenceError.corruptData("Archived epics cannot be reopened")
    }

    let updatedAt = Date()
    try transaction {
      try withStatement(
        "UPDATE epics SET status = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(EpicStatus.open.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: epic.productID,
        kind: "epic.reopened",
        actor: "Product Owner",
        detail: epic.title
      )
    }
    return try fetchEpic(id: id)
  }

  public func moveEpics(ids: [UUID], before targetID: UUID?) throws -> [Epic] {
    let movingIDs = Set(ids)
    guard !movingIDs.isEmpty, let firstID = ids.first else { return [] }
    let firstEpic = try fetchEpic(id: firstID)
    var epics = try fetchEpics(productID: firstEpic.productID)
      .filter { $0.status != .archived }
    let epicsByID = Dictionary(uniqueKeysWithValues: epics.map { ($0.id, $0) })

    for id in movingIDs {
      guard let epic = epicsByID[id], epic.productID == firstEpic.productID else {
        throw PersistenceError.corruptData("Only visible epics in this product can be reordered")
      }
    }

    let movingEpics = epics.filter { movingIDs.contains($0.id) }
    epics.removeAll { movingIDs.contains($0.id) }
    let insertionIndex: Int
    if let targetID {
      guard let targetIndex = epics.firstIndex(where: { $0.id == targetID }) else {
        throw PersistenceError.corruptData("The epic drop target is no longer available")
      }
      insertionIndex = targetIndex
    } else {
      insertionIndex = epics.endIndex
    }
    epics.insert(contentsOf: movingEpics, at: insertionIndex)

    try transaction {
      for (index, epic) in epics.enumerated() {
        try withStatement(
          "UPDATE epics SET rank = ?, updated_at = ? WHERE id = ?;"
        ) { statement in
          try bind(Int64((index + 1) * 1_000), to: 1, in: statement)
          try bind(Date().timeIntervalSince1970, to: 2, in: statement)
          try bind(epic.id.uuidString, to: 3, in: statement)
          try stepDone(statement)
        }
      }
      for epic in movingEpics {
        _ = try insertEvent(
          productID: epic.productID,
          kind: "epic.ranked",
          actor: "Product Owner",
          detail: targetID == nil ? "\(epic.title) moved to bottom" : "\(epic.title) reordered"
        )
      }
    }
    return try fetchEpics(productID: firstEpic.productID)
  }

  public func archiveEpic(id: UUID) throws {
    let epic = try fetchEpic(id: id)
    guard epic.status != .archived else { return }
    let childTickets = try fetchWorkItems(productID: epic.productID)
      .filter { $0.epicID == epic.id }
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    let unfinishedTickets = childTickets.filter {
      $0.state != .released && $0.state != .cancelled
    }
    let deliveryTickets = unfinishedTickets.filter {
      !planningStates.contains($0.state)
    }
    guard deliveryTickets.isEmpty else {
      let ticketKeys = deliveryTickets.map(\.key).sorted().joined(separator: ", ")
      throw PersistenceError.corruptData(
        "Finish or remove \(ticketKeys) from active delivery before archiving this epic"
      )
    }
    let ticketsToArchive = try prepareWorkItemsForArchival(
      ids: Set(unfinishedTickets.map(\.id))
    )
    let updatedAt = Date()
    let proposedSuggestionTitles = try withStatement(
      """
      SELECT suggestions.title
      FROM ticket_suggestions AS suggestions
      JOIN suggestion_sessions AS sessions ON sessions.id = suggestions.session_id
      WHERE sessions.epic_id = ? AND suggestions.status = 'proposed'
      ORDER BY sessions.created_at ASC, suggestions.position ASC;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      var titles: [String] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        titles.append(try text(statement, column: 0))
      }
      return titles
    }
    try transaction {
      try archivePreparedWorkItems(ticketsToArchive)
      try withStatement(
        """
        UPDATE ticket_suggestions
        SET status = ?, accepted_work_item_id = NULL, updated_at = ?
        WHERE status = 'proposed'
          AND session_id IN (
            SELECT id FROM suggestion_sessions WHERE epic_id = ?
          );
        """
      ) { statement in
        try bind(TicketSuggestionStatus.rejected.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        """
        UPDATE suggestion_sessions
        SET status = ?, error_message = NULL, updated_at = ?
        WHERE epic_id = ? AND status != ?;
        """
      ) { statement in
        try bind(SuggestionSessionStatus.cancelled.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try bind(SuggestionSessionStatus.cancelled.rawValue, to: 4, in: statement)
        try stepDone(statement)
      }
      for title in proposedSuggestionTitles {
        _ = try insertEvent(
          productID: epic.productID,
          kind: "ticket_suggestion.rejected",
          actor: "Product Owner",
          detail: title
        )
      }
      try withStatement(
        "UPDATE epics SET status = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(EpicStatus.archived.rawValue, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: epic.productID,
        kind: "epic.archived",
        actor: "Product Owner",
        detail: epic.title
      )
    }
  }

  public func assignWorkItemToEpic(id: UUID, epicID: UUID?) throws -> WorkItem {
    let item = try fetchWorkItem(id: id)
    if let epicID {
      let epic = try fetchEpic(id: epicID)
      guard epic.productID == item.productID else {
        throw PersistenceError.corruptData("Epic and ticket must belong to the same product")
      }
      guard epic.status == .open else {
        throw PersistenceError.corruptData("Tickets can only be assigned to an open epic")
      }
    }
    try withStatement(
      "UPDATE work_items SET epic_id = ?, version = version + 1, updated_at = ? WHERE id = ?;"
    ) { statement in
      try bindOptionalUUID(epicID, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(id.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
    return try fetchWorkItem(id: id)
  }

  public func createWorkItem(
    productID: UUID,
    title: String,
    type: WorkItemType = .story,
    body: String = "",
    acceptanceCriteria: [String] = [],
    priority: WorkItemPriority = .normal,
    dependsOnWorkItemIDs: Set<UUID> = [],
    epicID: UUID? = nil
  ) throws -> WorkItem {
    var workItem: WorkItem?
    try transaction {
      let inserted = try insertWorkItem(
        productID: productID,
        title: title,
        type: type,
        body: body,
        acceptanceCriteria: acceptanceCriteria,
        priority: priority,
        epicID: epicID
      )
      workItem = inserted

      if !dependsOnWorkItemIDs.isEmpty {
        try replaceWorkItemDependencies(
          for: inserted,
          dependsOnWorkItemIDs: dependsOnWorkItemIDs
        )
      }

      _ = try insertEvent(
        productID: productID,
        workItemID: inserted.id,
        kind: "work_item.created",
        actor: "owner",
        detail: inserted.key
      )
    }

    guard let workItem else {
      throw PersistenceError.corruptData("Could not create work item")
    }
    return workItem
  }

  public func fetchWorkItems(productID: UUID) throws -> [WorkItem] {
    try withStatement(
      """
      SELECT id, product_id, item_key, title, ticket_type, body,
             acceptance_criteria_json, state, priority, version,
             created_at, updated_at, rank, custom_fields_json, owner_profile_id, epic_id
      FROM work_items
      WHERE product_id = ?
      ORDER BY rank ASC, key_number ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var items: [WorkItem] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        items.append(try decodeWorkItem(statement))
      }
      return items
    }
  }

  public func updateWorkItem(
    id: UUID,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority,
    customFields: [String: String],
    dependsOnWorkItemIDs: Set<UUID>? = nil,
    expectedVersion: Int? = nil
  ) throws -> WorkItem {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw PersistenceError.corruptData("Ticket title cannot be empty")
    }

    var workItem = try fetchWorkItem(id: id)
    let previousWorkItem = workItem
    let previousDependencyIDs: Set<UUID>? = if dependsOnWorkItemIDs != nil {
      Set(
        try fetchWorkItemDependencies(productID: workItem.productID)
          .filter { $0.workItemID == workItem.id }
          .map(\.dependsOnWorkItemID)
      )
    } else {
      nil
    }
    if let expectedVersion, workItem.version != expectedVersion {
      throw WorkItemUpdateError.versionConflict(
        key: workItem.key,
        expected: expectedVersion,
        actual: workItem.version
      )
    }
    workItem.title = trimmedTitle
    workItem.type = type
    workItem.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    workItem.acceptanceCriteria = acceptanceCriteria
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    workItem.priority = priority
    workItem.customFields = customFields.reduce(into: [:]) { result, entry in
      let trimmedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedKey.isEmpty else { return }
      result[trimmedKey] = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    workItem.version += 1
    workItem.updatedAt = Date()

    var updateDetails: [String] = []
    if previousWorkItem.title != workItem.title {
      updateDetails.append("title")
    }
    if previousWorkItem.type != workItem.type {
      updateDetails.append(
        "type \(previousWorkItem.type.title) → \(workItem.type.title)"
      )
    }
    if previousWorkItem.body != workItem.body {
      updateDetails.append("context")
    }
    if previousWorkItem.acceptanceCriteria != workItem.acceptanceCriteria {
      updateDetails.append(
        "acceptance criteria \(previousWorkItem.acceptanceCriteria.count) → \(workItem.acceptanceCriteria.count)"
      )
    }
    if previousWorkItem.priority != workItem.priority {
      updateDetails.append(
        "priority \(previousWorkItem.priority.title) → \(workItem.priority.title)"
      )
    }
    if previousWorkItem.customFields != workItem.customFields {
      let changedKeys = Set(previousWorkItem.customFields.keys)
        .union(workItem.customFields.keys)
        .filter { previousWorkItem.customFields[$0] != workItem.customFields[$0] }
        .sorted()
      let fieldSummary = changedKeys.count <= 3
        ? changedKeys.joined(separator: ", ")
        : "\(changedKeys.count) fields"
      updateDetails.append("custom fields (\(fieldSummary))")
    }
    if let previousDependencyIDs, let dependsOnWorkItemIDs,
      previousDependencyIDs != dependsOnWorkItemIDs
    {
      let previousKeys = previousDependencyIDs.compactMap {
        try? fetchWorkItem(id: $0).key
      }.sorted()
      let currentKeys = dependsOnWorkItemIDs.compactMap {
        try? fetchWorkItem(id: $0).key
      }.sorted()
      let previousValue = previousKeys.isEmpty ? "none" : previousKeys.joined(separator: ", ")
      let currentValue = currentKeys.isEmpty ? "none" : currentKeys.joined(separator: ", ")
      updateDetails.append("blockers \(previousValue) → \(currentValue)")
    }
    let updateDetail = updateDetails.isEmpty
      ? "Saved without field changes"
      : "Changed \(updateDetails.joined(separator: "; "))"

    try transaction {
      try withStatement(
        """
        UPDATE work_items
        SET title = ?, ticket_type = ?, body = ?, acceptance_criteria_json = ?,
            priority = ?, custom_fields_json = ?, version = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(workItem.title, to: 1, in: statement)
        try bind(workItem.type.rawValue, to: 2, in: statement)
        try bind(workItem.body, to: 3, in: statement)
        try bind(try encodeStringArray(workItem.acceptanceCriteria), to: 4, in: statement)
        try bind(Int64(workItem.priority.rawValue), to: 5, in: statement)
        try bind(try encodeStringDictionary(workItem.customFields), to: 6, in: statement)
        try bind(Int64(workItem.version), to: 7, in: statement)
        try bind(workItem.updatedAt.timeIntervalSince1970, to: 8, in: statement)
        try bind(workItem.id.uuidString, to: 9, in: statement)
        try stepDone(statement)
      }
      if let dependsOnWorkItemIDs {
        try replaceWorkItemDependencies(
          for: workItem,
          dependsOnWorkItemIDs: dependsOnWorkItemIDs
        )
      }
      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItem.id,
        kind: "work_item.updated",
        actor: "Product Owner",
        detail: updateDetail
      )
    }
    return workItem
  }

  public func assignWorkItemOwner(id: UUID, profileID: UUID?) throws -> WorkItem {
    let workItem = try fetchWorkItem(id: id)
    if let profileID {
      let profile = try fetchAgentProfile(id: profileID)
      guard profile.productID == workItem.productID, profile.role.canOwnDelivery else {
        throw PersistenceError.corruptData("The selected team member cannot own this ticket")
      }
    }

    try withStatement(
      "UPDATE work_items SET owner_profile_id = ?, updated_at = ? WHERE id = ?;"
    ) { statement in
      try bindOptionalUUID(profileID, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(id.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
    _ = try insertEvent(
      productID: workItem.productID,
      workItemID: workItem.id,
      kind: "work_item.owner_assigned",
      actor: "system",
      detail: profileID?.uuidString ?? "Unassigned"
    )
    return try fetchWorkItem(id: id)
  }

  public func moveWorkItem(
    id: UUID,
    to position: WorkItemRankPosition
  ) throws -> [WorkItem] {
    let workItem = try fetchWorkItem(id: id)
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    guard planningStates.contains(workItem.state) else {
      throw WorkItemRankingError.notPlanningItem(workItem.key)
    }

    var items = try fetchWorkItems(productID: workItem.productID)
      .filter { planningStates.contains($0.state) }
    items.removeAll { $0.id == id }
    switch position {
    case .top:
      items.insert(workItem, at: 0)
    case .bottom:
      items.append(workItem)
    }

    let indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    for dependency in try fetchWorkItemDependencies(productID: workItem.productID) {
      guard
        let dependentIndex = indexByID[dependency.workItemID],
        let prerequisiteIndex = indexByID[dependency.dependsOnWorkItemID],
        dependentIndex < prerequisiteIndex,
        let dependent = itemsByID[dependency.workItemID],
        let prerequisite = itemsByID[dependency.dependsOnWorkItemID]
      else { continue }
      throw WorkItemRankingError.dependencyOrder(
        "\(dependent.key) depends on \(prerequisite.key), so it cannot be ranked ahead of it."
      )
    }

    try transaction {
      for (index, item) in items.enumerated() {
        try withStatement("UPDATE work_items SET rank = ? WHERE id = ?;") { statement in
          try bind(Int64((index + 1) * 1_000), to: 1, in: statement)
          try bind(item.id.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
      let detail: String
      switch position {
      case .top: detail = "Moved to top"
      case .bottom: detail = "Moved to bottom"
      }
      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItem.id,
        kind: "work_item.ranked",
        actor: "Product Owner",
        detail: detail
      )
    }
    return try fetchWorkItems(productID: workItem.productID)
  }

  public func moveWorkItems(
    ids: [UUID],
    before targetID: UUID?
  ) throws -> [WorkItem] {
    let movingIDs = Set(ids)
    guard !movingIDs.isEmpty else { return [] }
    guard let firstID = ids.first else { return [] }
    let firstItem = try fetchWorkItem(id: firstID)
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    var items = try fetchWorkItems(productID: firstItem.productID)
      .filter { planningStates.contains($0.state) }
    let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    for id in movingIDs {
      guard let item = itemsByID[id] else {
        let key = try? fetchWorkItem(id: id).key
        throw WorkItemRankingError.notPlanningItem(key ?? "Ticket")
      }
      guard item.productID == firstItem.productID else {
        throw WorkItemRankingError.notPlanningItem(item.key)
      }
    }

    let movingItems = items.filter { movingIDs.contains($0.id) }
    items.removeAll { movingIDs.contains($0.id) }
    let insertionIndex: Int
    if let targetID {
      guard let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
        throw WorkItemRankingError.notPlanningItem("Drop target")
      }
      insertionIndex = targetIndex
    } else {
      insertionIndex = items.endIndex
    }
    items.insert(contentsOf: movingItems, at: insertionIndex)

    let indexByID = Dictionary(
      uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) }
    )
    let reorderedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    for dependency in try fetchWorkItemDependencies(productID: firstItem.productID) {
      guard
        let dependentIndex = indexByID[dependency.workItemID],
        let prerequisiteIndex = indexByID[dependency.dependsOnWorkItemID],
        dependentIndex < prerequisiteIndex,
        let dependent = reorderedItemsByID[dependency.workItemID],
        let prerequisite = reorderedItemsByID[dependency.dependsOnWorkItemID]
      else { continue }
      throw WorkItemRankingError.dependencyOrder(
        "\(dependent.key) depends on \(prerequisite.key), so it cannot be ranked ahead of it."
      )
    }

    try transaction {
      for (index, item) in items.enumerated() {
        try withStatement("UPDATE work_items SET rank = ? WHERE id = ?;") { statement in
          try bind(Int64((index + 1) * 1_000), to: 1, in: statement)
          try bind(item.id.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
      for item in movingItems {
        _ = try insertEvent(
          productID: item.productID,
          workItemID: item.id,
          kind: "work_item.ranked",
          actor: "Product Owner",
          detail: targetID == nil ? "Moved to bottom" : "Moved before another ticket"
        )
      }
    }
    return try fetchWorkItems(productID: firstItem.productID)
  }

  public func archiveWorkItem(id: UUID) throws {
    try archiveWorkItems(ids: [id])
  }

  public func archiveWorkItems(ids: [UUID]) throws {
    let workItems = try prepareWorkItemsForArchival(ids: Set(ids))
    guard !workItems.isEmpty else { return }
    try transaction {
      try archivePreparedWorkItems(workItems)
    }
  }

  private func prepareWorkItemsForArchival(ids archiveIDs: Set<UUID>) throws -> [WorkItem] {
    guard !archiveIDs.isEmpty else { return [] }
    var workItems = try archiveIDs.map { try fetchWorkItem(id: $0) }
    guard let productID = workItems.first?.productID,
      workItems.allSatisfy({ $0.productID == productID })
    else {
      throw PersistenceError.corruptData("Archived tickets must belong to one product")
    }
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    guard workItems.allSatisfy({ planningStates.contains($0.state) }) else {
      throw PersistenceError.corruptData("Only backlog tickets can be archived")
    }
    let dependencies = try fetchWorkItemDependencies(productID: productID)
    let activeDependent = dependencies
      .filter {
        archiveIDs.contains($0.dependsOnWorkItemID)
          && !archiveIDs.contains($0.workItemID)
      }
      .compactMap { try? fetchWorkItem(id: $0.workItemID) }
      .first { planningStates.contains($0.state) }
    if let activeDependent {
      let prerequisiteKey = dependencies
        .first { dependency in
          dependency.workItemID == activeDependent.id
            && archiveIDs.contains(dependency.dependsOnWorkItemID)
        }
        .flatMap { dependency in
          workItems.first { $0.id == dependency.dependsOnWorkItemID }?.key
        } ?? "the selected ticket"
      throw PersistenceError.corruptData(
        "Remove the relationship from \(activeDependent.key) before archiving \(prerequisiteKey)"
      )
    }

    let archivedAt = Date()
    for index in workItems.indices {
      workItems[index].state = .cancelled
      workItems[index].version += 1
      workItems[index].updatedAt = archivedAt
    }
    return workItems
  }

  private func archivePreparedWorkItems(_ workItems: [WorkItem]) throws {
    for workItem in workItems {
      try withStatement(
        """
        DELETE FROM sprint_items
        WHERE work_item_id = ?
          AND sprint_id IN (
            SELECT id FROM sprints WHERE product_id = ? AND state = 'draft'
          );
        """
      ) { statement in
        try bind(workItem.id.uuidString, to: 1, in: statement)
        try bind(workItem.productID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        "DELETE FROM work_item_dependencies WHERE work_item_id = ?;"
      ) { statement in
        try bind(workItem.id.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        "UPDATE work_items SET state = ?, version = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(workItem.state.rawValue, to: 1, in: statement)
        try bind(Int64(workItem.version), to: 2, in: statement)
        try bind(workItem.updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(workItem.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItem.id,
        kind: "work_item.archived",
        actor: "Product Owner",
        detail: workItem.key
      )
    }
  }

  public func beginTicketSuggestionSession(
    productID: UUID,
    epicID: UUID? = nil
  ) throws -> SuggestionSession {
    if let active = try fetchSuggestionSession(productID: productID, status: .generating) {
      guard active.epicID == epicID else {
        throw PersistenceError.corruptData(
          "Another epic is already being planned by the Business Analyst"
        )
      }
      return active
    }

    if let epicID {
      let epic = try fetchEpic(id: epicID)
      guard epic.productID == productID else {
        throw PersistenceError.corruptData("Epic and suggestion session must share a product")
      }
      guard epic.status == .open else {
        throw PersistenceError.corruptData("Only an open epic can be planned")
      }
    }
    let session = SuggestionSession(productID: productID, epicID: epicID)
    try transaction {
      try withStatement(
        """
        INSERT INTO suggestion_sessions (
            id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
            error_message, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(session.id.uuidString, to: 1, in: statement)
        try bind(session.productID.uuidString, to: 2, in: statement)
        try bindOptionalUUID(session.epicID, to: 3, in: statement)
        try bindNull(to: 4, in: statement)
        try bind(session.status.rawValue, to: 5, in: statement)
        try bindNull(to: 6, in: statement)
        try bindNull(to: 7, in: statement)
        try bindNull(to: 8, in: statement)
        try bind(session.createdAt.timeIntervalSince1970, to: 9, in: statement)
        try bind(session.updatedAt.timeIntervalSince1970, to: 10, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "ticket_suggestions.started",
        actor: "Business Analyst",
        detail: session.id.uuidString
      )
    }
    return session
  }

  public func attachCodexTurn(
    sessionID: UUID,
    threadID: String,
    turnID: String
  ) throws {
    try withStatement(
      """
      UPDATE suggestion_sessions
      SET codex_thread_id = ?, codex_turn_id = ?, updated_at = ?
      WHERE id = ? AND status = 'generating';
      """
    ) { statement in
      try bind(threadID, to: 1, in: statement)
      try bind(turnID, to: 2, in: statement)
      try bind(Date().timeIntervalSince1970, to: 3, in: statement)
      try bind(sessionID.uuidString, to: 4, in: statement)
      try stepDone(statement)
    }
  }

  public func completeTicketSuggestionSession(
    sessionID: UUID,
    drafts: [TicketSuggestionDraft]
  ) throws -> TicketSuggestionBatch {
    guard !drafts.isEmpty else {
      throw PersistenceError.corruptData("A suggestion session cannot complete without tickets")
    }
    let session = try fetchSuggestionSession(id: sessionID)
    guard session.status == .generating else {
      return try fetchTicketSuggestionBatch(sessionID: sessionID)
    }

    let now = Date()
    let insertContext = try ticketSuggestionInsertContext(
      productID: session.productID,
      drafts: drafts
    )
    try transaction {
      try insertTicketSuggestionDrafts(
        drafts,
        sessionID: sessionID,
        idsByReference: insertContext.idsByReference,
        existingItemsByKey: insertContext.existingItemsByKey,
        now: now
      )

      try withStatement(
        """
        UPDATE suggestion_sessions
        SET status = 'ready', error_message = NULL, updated_at = ?
        WHERE id = ? AND status = 'generating';
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(sessionID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: session.productID,
        kind: "ticket_suggestions.ready",
        actor: "Business Analyst",
        detail: "\(drafts.count) proposals"
      )
    }
    return try fetchTicketSuggestionBatch(sessionID: sessionID)
  }

  public func createFollowUpTicketSuggestionSession(
    sourceWorkItemID: UUID,
    drafts: [TicketSuggestionDraft]
  ) throws -> TicketSuggestionBatch {
    guard !drafts.isEmpty else {
      throw PersistenceError.corruptData("Follow-up suggestions cannot be empty")
    }
    if let existingSession = try fetchSuggestionSession(
      sourceWorkItemID: sourceWorkItemID
    ) {
      return try fetchTicketSuggestionBatch(sessionID: existingSession.id)
    }
    let source = try fetchWorkItem(id: sourceWorkItemID)
    let now = Date()
    let session = SuggestionSession(
      productID: source.productID,
      epicID: source.epicID,
      sourceWorkItemID: source.id,
      status: .ready,
      createdAt: now,
      updatedAt: now
    )
    let insertContext = try ticketSuggestionInsertContext(
      productID: source.productID,
      drafts: drafts
    )
    try transaction {
      try withStatement(
        """
        INSERT INTO suggestion_sessions (
            id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
            error_message, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(session.id.uuidString, to: 1, in: statement)
        try bind(session.productID.uuidString, to: 2, in: statement)
        try bindOptionalUUID(session.epicID, to: 3, in: statement)
        try bind(source.id.uuidString, to: 4, in: statement)
        try bind(session.status.rawValue, to: 5, in: statement)
        try bindNull(to: 6, in: statement)
        try bindNull(to: 7, in: statement)
        try bindNull(to: 8, in: statement)
        try bind(now.timeIntervalSince1970, to: 9, in: statement)
        try bind(now.timeIntervalSince1970, to: 10, in: statement)
        try stepDone(statement)
      }
      try insertTicketSuggestionDrafts(
        drafts,
        sessionID: session.id,
        idsByReference: insertContext.idsByReference,
        existingItemsByKey: insertContext.existingItemsByKey,
        now: now
      )
      _ = try insertEvent(
        productID: source.productID,
        workItemID: source.id,
        kind: "ticket_suggestions.created_from_research",
        actor: "Business Analyst",
        detail: "\(drafts.count) follow-up proposals"
      )
    }
    return try fetchTicketSuggestionBatch(sessionID: session.id)
  }

  private func ticketSuggestionInsertContext(
    productID: UUID,
    drafts: [TicketSuggestionDraft]
  ) throws -> (
    idsByReference: [String: UUID],
    existingItemsByKey: [String: WorkItem]
  ) {
    var idsByReference: [String: UUID] = [:]
    for draft in drafts {
      guard idsByReference[draft.reference] == nil else {
        throw PersistenceError.corruptData("Suggestion references must be unique")
      }
      idsByReference[draft.reference] = UUID()
    }
    let existingItemsByKey = Dictionary(
      uniqueKeysWithValues: try fetchWorkItems(productID: productID).map { ($0.key, $0) }
    )
    for dependencyKey in drafts.flatMap(\.dependsOnExistingWorkItemKeys) {
      guard existingItemsByKey[dependencyKey] != nil else {
        throw PersistenceError.corruptData(
          "Unknown existing backlog dependency \(dependencyKey)"
        )
      }
    }
    return (idsByReference, existingItemsByKey)
  }

  private func insertTicketSuggestionDrafts(
    _ drafts: [TicketSuggestionDraft],
    sessionID: UUID,
    idsByReference: [String: UUID],
    existingItemsByKey: [String: WorkItem],
    now: Date
  ) throws {
    for (position, draft) in drafts.enumerated() {
      guard let suggestionID = idsByReference[draft.reference] else {
        throw PersistenceError.corruptData("Missing suggestion reference")
      }
      try withStatement(
        """
        INSERT INTO ticket_suggestions (
            id, session_id, reference, position, title, body,
            acceptance_criteria_json, suggested_role, priority, rationale,
            status, accepted_work_item_id, created_at, updated_at, ticket_type
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(suggestionID.uuidString, to: 1, in: statement)
        try bind(sessionID.uuidString, to: 2, in: statement)
        try bind(draft.reference, to: 3, in: statement)
        try bind(Int64(position), to: 4, in: statement)
        try bind(draft.title, to: 5, in: statement)
        try bind(draft.body, to: 6, in: statement)
        try bind(try encodeStringArray(draft.acceptanceCriteria), to: 7, in: statement)
        try bind(draft.suggestedRole.rawValue, to: 8, in: statement)
        try bind(Int64(draft.priority.rawValue), to: 9, in: statement)
        try bind(draft.rationale, to: 10, in: statement)
        try bind(TicketSuggestionStatus.proposed.rawValue, to: 11, in: statement)
        try bindNull(to: 12, in: statement)
        try bind(now.timeIntervalSince1970, to: 13, in: statement)
        try bind(now.timeIntervalSince1970, to: 14, in: statement)
        try bind(draft.type.rawValue, to: 15, in: statement)
        try stepDone(statement)
      }
    }

    for draft in drafts {
      guard let suggestionID = idsByReference[draft.reference] else { continue }
      for dependencyReference in Set(draft.dependsOnReferences) {
        guard let dependencyID = idsByReference[dependencyReference] else {
          throw PersistenceError.corruptData(
            "Unknown dependency reference \(dependencyReference)"
          )
        }
        guard dependencyID != suggestionID else {
          throw PersistenceError.corruptData("A suggestion cannot depend on itself")
        }
        try withStatement(
          """
          INSERT INTO suggestion_dependencies (suggestion_id, depends_on_suggestion_id)
          VALUES (?, ?);
          """
        ) { statement in
          try bind(suggestionID.uuidString, to: 1, in: statement)
          try bind(dependencyID.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
      for dependencyKey in Set(draft.dependsOnExistingWorkItemKeys) {
        guard let dependency = existingItemsByKey[dependencyKey] else {
          throw PersistenceError.corruptData(
            "Unknown existing backlog dependency \(dependencyKey)"
          )
        }
        try withStatement(
          """
          INSERT INTO suggestion_existing_dependencies (
              suggestion_id, depends_on_work_item_id
          ) VALUES (?, ?);
          """
        ) { statement in
          try bind(suggestionID.uuidString, to: 1, in: statement)
          try bind(dependency.id.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func failTicketSuggestionSession(sessionID: UUID, message: String) throws {
    let session = try fetchSuggestionSession(id: sessionID)
    try transaction {
      try withStatement(
        """
        UPDATE suggestion_sessions
        SET status = 'failed', error_message = ?, updated_at = ?
        WHERE id = ? AND status = 'generating';
        """
      ) { statement in
        try bind(message, to: 1, in: statement)
        try bind(Date().timeIntervalSince1970, to: 2, in: statement)
        try bind(sessionID.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: session.productID,
        kind: "ticket_suggestions.failed",
        actor: "system",
        detail: message
      )
    }
  }

  public func retryTicketSuggestionSession(sessionID: UUID) throws -> SuggestionSession {
    let session = try fetchSuggestionSession(id: sessionID)
    guard session.status == .failed else { return session }
    let now = Date()
    try transaction {
      try withStatement(
        """
        UPDATE suggestion_sessions
        SET status = 'generating',
            codex_thread_id = NULL,
            codex_turn_id = NULL,
            error_message = NULL,
            updated_at = ?
        WHERE id = ? AND status = 'failed';
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(sessionID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: session.productID,
        kind: "ticket_suggestions.retried",
        actor: "system",
        detail: "Proposal generation restarted"
      )
    }
    return try fetchSuggestionSession(id: sessionID)
  }

  public func dismissTicketSuggestionSession(sessionID: UUID) throws {
    let session = try fetchSuggestionSession(id: sessionID)
    guard session.status == .failed else { return }
    try transaction {
      try withStatement(
        """
        UPDATE suggestion_sessions
        SET status = 'cancelled', error_message = NULL, updated_at = ?
        WHERE id = ? AND status = 'failed';
        """
      ) { statement in
        try bind(Date().timeIntervalSince1970, to: 1, in: statement)
        try bind(sessionID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: session.productID,
        kind: "ticket_suggestions.dismissed",
        actor: "owner",
        detail: "Failed proposal dismissed"
      )
    }
  }

  public func fetchLatestTicketSuggestionBatch(
    productID: UUID
  ) throws -> TicketSuggestionBatch? {
    let session: SuggestionSession? = try withStatement(
      """
      SELECT id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
             error_message, created_at, updated_at
      FROM suggestion_sessions AS sessions
      WHERE product_id = ?
      ORDER BY
        CASE
          WHEN status = 'generating' THEN 0
          WHEN EXISTS (
            SELECT 1
            FROM ticket_suggestions
            WHERE session_id = sessions.id AND status = 'proposed'
          ) THEN 1
          WHEN status = 'failed' THEN 2
          ELSE 3
        END,
        CASE
          WHEN status = 'generating' THEN created_at
          WHEN EXISTS (
            SELECT 1
            FROM ticket_suggestions
            WHERE session_id = sessions.id AND status = 'proposed'
          ) THEN created_at
          ELSE -created_at
        END ASC
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeSuggestionSession(statement)
    }
    guard let session else { return nil }
    return try fetchTicketSuggestionBatch(sessionID: session.id)
  }

  public func decideTicketSuggestion(
    id: UUID,
    decision: TicketSuggestionStatus
  ) throws -> TicketSuggestionBatch {
    guard decision == .accepted || decision == .rejected else {
      throw PersistenceError.corruptData("A proposal must be accepted or rejected")
    }
    if decision == .rejected {
      return try rejectTicketSuggestionCascade(id: id)
    }
    let suggestion = try fetchTicketSuggestion(id: id)
    let session = try fetchSuggestionSession(id: suggestion.sessionID)
    guard suggestion.status == .proposed else {
      return try fetchTicketSuggestionBatch(sessionID: session.id)
    }
    let batch = try fetchTicketSuggestionBatch(sessionID: session.id)
    let suggestionsToAccept = try suggestedPrerequisiteClosure(
      including: suggestion,
      in: batch
    )
    let acceptedAt = Date()

    try transaction {
      for affected in suggestionsToAccept {
        let workItem = try insertWorkItem(
          productID: session.productID,
          title: affected.title,
          type: affected.type,
          body: affected.body,
          acceptanceCriteria: affected.acceptanceCriteria,
          priority: affected.priority,
          epicID: session.epicID
        )
        _ = try insertEvent(
          productID: session.productID,
          workItemID: workItem.id,
          kind: "work_item.created_from_suggestion",
          actor: "owner",
          detail: workItem.key
        )

        try withStatement(
          """
          UPDATE ticket_suggestions
          SET status = ?, accepted_work_item_id = ?, updated_at = ?
          WHERE id = ? AND status = 'proposed';
          """
        ) { statement in
          try bind(TicketSuggestionStatus.accepted.rawValue, to: 1, in: statement)
          try bind(workItem.id.uuidString, to: 2, in: statement)
          try bind(acceptedAt.timeIntervalSince1970, to: 3, in: statement)
          try bind(affected.id.uuidString, to: 4, in: statement)
          try stepDone(statement)
        }
        _ = try insertEvent(
          productID: session.productID,
          kind: "ticket_suggestion.accepted",
          actor: "owner",
          detail: affected.title
        )
      }
      try reconcileAcceptedSuggestionDependencies(sessionID: session.id)
      try normalizePlanningRanks(productID: session.productID)
    }
    return try fetchTicketSuggestionBatch(sessionID: session.id)
  }

  private func suggestedPrerequisiteClosure(
    including suggestion: TicketSuggestion,
    in batch: TicketSuggestionBatch
  ) throws -> [TicketSuggestion] {
    let suggestionsByID = Dictionary(
      uniqueKeysWithValues: batch.suggestions.map { ($0.id, $0) }
    )
    var closureIDs: Set<UUID> = [suggestion.id]
    var frontier = [suggestion.id]

    while let candidateID = frontier.popLast() {
      guard let candidate = suggestionsByID[candidateID] else {
        throw PersistenceError.corruptData("A ticket suggestion dependency is missing")
      }
      for dependencyID in candidate.dependencyIDs {
        guard let dependency = suggestionsByID[dependencyID] else {
          throw PersistenceError.corruptData("A ticket suggestion dependency is missing")
        }
        guard dependency.status != .rejected else {
          throw PersistenceError.corruptData(
            "A ticket suggestion depends on a rejected prerequisite"
          )
        }
        if closureIDs.insert(dependencyID).inserted {
          frontier.append(dependencyID)
        }
      }
    }

    var remaining = Dictionary(
      uniqueKeysWithValues: batch.suggestions
        .filter { closureIDs.contains($0.id) && $0.status == .proposed }
        .map { ($0.id, $0) }
    )
    var ordered: [TicketSuggestion] = []
    while !remaining.isEmpty {
      let ready = remaining.values
        .filter { candidate in
          candidate.dependencyIDs.allSatisfy { remaining[$0] == nil }
        }
        .sorted { $0.position < $1.position }
      guard !ready.isEmpty else {
        throw PersistenceError.corruptData("Ticket suggestion dependencies contain a cycle")
      }
      ordered.append(contentsOf: ready)
      for candidate in ready {
        remaining.removeValue(forKey: candidate.id)
      }
    }
    return ordered
  }

  public func rejectTicketSuggestionCascade(id: UUID) throws -> TicketSuggestionBatch {
    let suggestion = try fetchTicketSuggestion(id: id)
    let session = try fetchSuggestionSession(id: suggestion.sessionID)
    guard suggestion.status == .proposed else {
      return try fetchTicketSuggestionBatch(sessionID: session.id)
    }

    let batch = try fetchTicketSuggestionBatch(sessionID: session.id)
    var cascadeIDs: Set<UUID> = [suggestion.id]
    var foundDependent = true
    while foundDependent {
      foundDependent = false
      for candidate in batch.suggestions where !cascadeIDs.contains(candidate.id) {
        if candidate.dependencyIDs.contains(where: cascadeIDs.contains) {
          cascadeIDs.insert(candidate.id)
          foundDependent = true
        }
      }
    }

    let affectedSuggestions = batch.suggestions
      .filter { cascadeIDs.contains($0.id) }
      .sorted { $0.position < $1.position }
    let proposedSuggestions = affectedSuggestions.filter { $0.status == .proposed }
    var acceptedWorkItemIDs: Set<UUID> = []
    for dependent in affectedSuggestions where dependent.status == .accepted {
      guard let workItemID = dependent.acceptedWorkItemID else {
        throw PersistenceError.corruptData(
          "An accepted dependent suggestion has no backlog ticket"
        )
      }
      let workItem = try fetchWorkItem(id: workItemID)
      if workItem.state != .cancelled {
        acceptedWorkItemIDs.insert(workItemID)
      }
    }
    let workItemsToArchive = try prepareWorkItemsForArchival(ids: acceptedWorkItemIDs)
    let decidedAt = Date()

    try transaction {
      try archivePreparedWorkItems(workItemsToArchive)
      for affected in proposedSuggestions {
        try withStatement(
          """
          UPDATE ticket_suggestions
          SET status = ?, accepted_work_item_id = NULL, updated_at = ?
          WHERE id = ? AND status = 'proposed';
          """
        ) { statement in
          try bind(TicketSuggestionStatus.rejected.rawValue, to: 1, in: statement)
          try bind(decidedAt.timeIntervalSince1970, to: 2, in: statement)
          try bind(affected.id.uuidString, to: 3, in: statement)
          try stepDone(statement)
        }
        _ = try insertEvent(
          productID: session.productID,
          kind:
            affected.id == suggestion.id
              ? "ticket_suggestion.rejected"
              : "ticket_suggestion.rejected_cascade",
          actor: "owner",
          detail: affected.title
        )
      }
    }
    return try fetchTicketSuggestionBatch(sessionID: session.id)
  }

  public func fetchWorkItemDependencies(productID: UUID) throws -> [WorkItemDependency] {
    try withStatement(
      """
      SELECT d.work_item_id, d.depends_on_work_item_id
      FROM work_item_dependencies d
      JOIN work_items w ON w.id = d.work_item_id
      WHERE w.product_id = ?
      ORDER BY d.work_item_id, d.depends_on_work_item_id;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var dependencies: [WorkItemDependency] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let workItemID = UUID(uuidString: try text(statement, column: 0)),
          let dependsOnID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid work item dependency")
        }
        dependencies.append(
          WorkItemDependency(workItemID: workItemID, dependsOnWorkItemID: dependsOnID)
        )
      }
      return dependencies
    }
  }

  public func transitionWorkItem(
    id: UUID,
    to newState: WorkItemState,
    actor: String,
    reason: String
  ) throws -> WorkItem {
    var workItem = try fetchWorkItem(id: id)
    try workflowPolicy.validateTransition(from: workItem.state, to: newState)

    let previousState = workItem.state
    workItem.state = newState
    workItem.version += 1
    workItem.updatedAt = Date()

    try transaction {
      try withStatement(
        """
        UPDATE work_items
        SET state = ?, version = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(newState.rawValue, to: 1, in: statement)
        try bind(Int64(workItem.version), to: 2, in: statement)
        try bind(workItem.updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(workItem.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItem.id,
        kind: "work_item.transitioned",
        actor: actor,
        detail: "\(previousState.rawValue) -> \(newState.rawValue): \(reason)"
      )
    }

    return workItem
  }

  public func appendComment(
    workItemID: UUID,
    authorKind: CommentAuthorKind,
    authorName: String,
    body: String,
    ownerQuestion: TicketOwnerQuestion? = nil,
    answeredQuestions: [TicketAnsweredQuestion] = []
  ) throws -> TicketComment {
    let workItem = try fetchWorkItem(id: workItemID)
    let comment = TicketComment(
      workItemID: workItemID,
      authorKind: authorKind,
      authorName: authorName,
      body: body,
      ownerQuestion: ownerQuestion,
      answeredQuestions: answeredQuestions
    )
    let ownerQuestionJSON = try ownerQuestion.map { question in
      let data = try encoder.encode(question)
      guard let json = String(data: data, encoding: .utf8) else {
        throw PersistenceError.corruptData("Could not encode the Product Owner question")
      }
      return json
    }
    let answeredQuestionsJSON: String?
    if answeredQuestions.isEmpty {
      answeredQuestionsJSON = nil
    } else {
      let data = try encoder.encode(answeredQuestions)
      guard let json = String(data: data, encoding: .utf8) else {
        throw PersistenceError.corruptData("Could not encode answered questions")
      }
      answeredQuestionsJSON = json
    }

    try transaction {
      try withStatement(
        """
        INSERT INTO ticket_comments (
            id, work_item_id, author_kind, author_name, body, owner_question_json,
            answered_questions_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(comment.id.uuidString, to: 1, in: statement)
        try bind(comment.workItemID.uuidString, to: 2, in: statement)
        try bind(comment.authorKind.rawValue, to: 3, in: statement)
        try bind(comment.authorName, to: 4, in: statement)
        try bind(comment.body, to: 5, in: statement)
        try bindOptionalString(ownerQuestionJSON, to: 6, in: statement)
        try bindOptionalString(answeredQuestionsJSON, to: 7, in: statement)
        try bind(comment.createdAt.timeIntervalSince1970, to: 8, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItemID,
        kind: "comment.created",
        actor: authorName,
        detail: comment.body
      )
    }

    return comment
  }

  public func fetchComments(workItemID: UUID) throws -> [TicketComment] {
    try withStatement(
      """
      SELECT id, work_item_id, author_kind, author_name, body, owner_question_json,
             answered_questions_json, created_at
      FROM ticket_comments
      WHERE work_item_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(workItemID.uuidString, to: 1, in: statement)
      var comments: [TicketComment] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let itemID = UUID(uuidString: try text(statement, column: 1)),
          let authorKind = CommentAuthorKind(rawValue: try text(statement, column: 2))
        else {
          throw PersistenceError.corruptData("Invalid ticket comment")
        }
        comments.append(
          TicketComment(
            id: id,
            workItemID: itemID,
            authorKind: authorKind,
            authorName: try text(statement, column: 3),
            body: try text(statement, column: 4),
            ownerQuestion: try optionalText(statement, column: 5).map { json in
              guard let data = json.data(using: .utf8) else {
                throw PersistenceError.corruptData("Invalid Product Owner question text")
              }
              return try decoder.decode(TicketOwnerQuestion.self, from: data)
            },
            answeredQuestions: try optionalText(statement, column: 6).map { json in
              guard let data = json.data(using: .utf8) else {
                throw PersistenceError.corruptData("Invalid answered question text")
              }
              return try decoder.decode([TicketAnsweredQuestion].self, from: data)
            } ?? [],
            createdAt: date(statement, column: 7)
          )
        )
      }
      return comments
    }
  }

  public func seedDefaultProfiles(productID: UUID) throws -> [AgentProfile] {
    let existing = try fetchAgentProfiles(productID: productID)
    let defaultRoles: [(String, AgentRole)] = [
      ("Business Analyst", .businessAnalyst),
      ("UX Designer", .uxDesigner),
      ("Tech Lead", .lead),
      ("Implementer", .implementer),
    ]
    let desired = defaultRoles.map { name, role in
      let defaults = AgentPersonaDefaults.configuration(for: role)
      return AgentProfile(
        productID: productID,
        name: name,
        role: role,
        model: defaults.model,
        reasoningEffort: defaults.effort
      )
    }
    let existingRoles = Set(existing.map(\.role))
    let missing = desired.filter { !existingRoles.contains($0.role) }
    guard !missing.isEmpty else { return existing }

    try transaction {
      for profile in missing {
        try insertAgentProfile(profile)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "team.profiles_seeded",
        actor: "system",
        detail: missing.map(\.name).joined(separator: ", ")
      )
    }

    return try fetchAgentProfiles(productID: productID)
  }

  public func fetchAgentProfiles(productID: UUID) throws -> [AgentProfile] {
    try withStatement(
      """
      SELECT id, product_id, name, role, model, reasoning_effort,
             custom_instructions, parallelism_limit, is_builtin, created_at, updated_at
      FROM agent_profiles
      WHERE product_id = ? AND is_active = 1
      ORDER BY
        CASE WHEN is_builtin = 1 THEN
          CASE role
            WHEN 'business_analyst' THEN 0
            WHEN 'ux_designer' THEN 1
            WHEN 'lead' THEN 2
            WHEN 'implementer' THEN 3
            WHEN 'frontend_engineer' THEN 4
            WHEN 'backend_engineer' THEN 5
            WHEN 'reviewer' THEN 6
            WHEN 'quality_assurance' THEN 7
            WHEN 'knowledge_curator' THEN 8
            ELSE 9
          END
        ELSE 100 END,
        created_at ASC,
        name ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var profiles: [AgentProfile] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedProductID = UUID(uuidString: try text(statement, column: 1)),
          let role = AgentRole(rawValue: try text(statement, column: 3))
        else {
          throw PersistenceError.corruptData("Invalid agent profile")
        }
        let limit: Int? =
          sqlite3_column_type(statement, 7) == SQLITE_NULL
          ? nil
          : Int(sqlite3_column_int64(statement, 7))
        profiles.append(
          AgentProfile(
            id: id,
            productID: storedProductID,
            name: try text(statement, column: 2),
            role: role,
            model: try text(statement, column: 4),
            reasoningEffort: try text(statement, column: 5),
            customInstructions: try optionalText(statement, column: 6),
            parallelismLimit: limit,
            isBuiltIn: sqlite3_column_int64(statement, 8) != 0,
            createdAt: date(statement, column: 9),
            updatedAt: date(statement, column: 10)
          )
        )
      }
      return profiles
    }
  }

  public func updateAgentProfileConfiguration(
    id: UUID,
    model: String,
    reasoningEffort: String,
    customInstructions: String?
  ) throws -> AgentProfile {
    guard
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PersistenceError.corruptData("Model and reasoning effort cannot be empty")
    }
    let profile = try fetchAgentProfile(id: id)
    let trimmedInstructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedInstructions = trimmedInstructions?.isEmpty == false ? trimmedInstructions : nil
    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE agent_profiles
        SET model = ?, reasoning_effort = ?, custom_instructions = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(model, to: 1, in: statement)
        try bind(reasoningEffort, to: 2, in: statement)
        try bindOptionalString(storedInstructions, to: 3, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 4, in: statement)
        try bind(id.uuidString, to: 5, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: profile.productID,
        kind: "team.profile_configured",
        actor: "owner",
        detail: "\(profile.name): \(model) · \(reasoningEffort)"
      )
    }
    return try fetchAgentProfile(id: id)
  }

  public func createCustomAgentProfile(
    productID: UUID,
    name: String,
    capability: AgentRole,
    model: String,
    reasoningEffort: String,
    instructions: String
  ) throws -> AgentProfile {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw PersistenceError.corruptData("A team member needs a name")
    }
    guard
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PersistenceError.corruptData("A team member needs a model and reasoning effort")
    }
    let duplicateExists = try withStatement(
      """
      SELECT 1 FROM agent_profiles
      WHERE product_id = ? AND lower(name) = lower(?) AND is_active = 1
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(trimmedName, to: 2, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
    guard !duplicateExists else {
      throw PersistenceError.corruptData("A team member named \(trimmedName) already exists")
    }
    let profile = AgentProfile(
      productID: productID,
      name: trimmedName,
      role: capability,
      model: model,
      reasoningEffort: reasoningEffort,
      customInstructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
      isBuiltIn: false
    )
    try transaction {
      try insertAgentProfile(profile)
      _ = try insertEvent(
        productID: productID,
        kind: "team.custom_persona_created",
        actor: "owner",
        detail: "\(profile.name) · \(capability.capabilityTitle)"
      )
    }
    return profile
  }

  public func archiveCustomAgentProfile(id: UUID) throws {
    let profile = try fetchAgentProfile(id: id)
    guard !profile.isBuiltIn else {
      throw PersistenceError.corruptData("Default team members cannot be removed")
    }
    let hasCurrentAssignments = try withStatement(
      """
      SELECT 1
      WHERE EXISTS (
        SELECT 1 FROM agent_runs
        WHERE profile_id = ? AND status IN ('queued', 'running', 'awaiting_owner')
      ) OR EXISTS (
        SELECT 1
        FROM sprint_items si
        JOIN sprints s ON s.id = si.sprint_id
        WHERE (si.implementer_profile_id = ? OR si.reviewer_profile_id = ?)
          AND s.state IN ('draft', 'active')
      );
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      try bind(id.uuidString, to: 2, in: statement)
      try bind(id.uuidString, to: 3, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
    guard !hasCurrentAssignments else {
      throw PersistenceError.corruptData(
        "Remove \(profile.name) from the current sprint before archiving the team member"
      )
    }
    try transaction {
      try withStatement(
        "UPDATE agent_profiles SET is_active = 0, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(Date().timeIntervalSince1970, to: 1, in: statement)
        try bind(id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: profile.productID,
        kind: "team.custom_persona_archived",
        actor: "owner",
        detail: profile.name
      )
    }
  }

  public func saveDraftSprint(
    productID: UUID,
    goal: String,
    tokenBudgetLimit: Int?,
    concurrencyLimit: Int,
    items inputs: [SprintDraftItemInput]
  ) throws -> SprintPlan {
    guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SprintPlanningError.notReady(["Add a sprint goal."])
    }
    guard concurrencyLimit > 0 else {
      throw SprintPlanningError.invalidConcurrency
    }
    if let tokenBudgetLimit, tokenBudgetLimit <= 0 {
      throw SprintPlanningError.invalidTokenBudget
    }
    guard Set(inputs.map(\.workItemID)).count == inputs.count else {
      throw SprintPlanningError.duplicateWorkItem
    }

    for input in inputs {
      let workItem = try fetchWorkItem(id: input.workItemID)
      guard
        workItem.productID == productID,
        [.backlog, .refining, .ready].contains(workItem.state)
      else {
        throw SprintPlanningError.itemNotReady(workItem.key)
      }
      if let implementerID = input.implementerProfileID {
        let implementer = try fetchAgentProfile(id: implementerID)
        guard implementer.productID == productID, implementer.role.canOwnDelivery else {
          throw SprintPlanningError.invalidImplementer(workItem.key)
        }
      }

      if let reviewerID = input.reviewerProfileID {
        let reviewer = try fetchAgentProfile(id: reviewerID)
        guard reviewer.productID == productID, reviewer.role.canReview else {
          throw SprintPlanningError.invalidReviewer(workItem.key)
        }
      }
    }

    let now = Date()
    let existingDraft = try fetchSprint(productID: productID, state: .draft)
    let sprint: Sprint
    if var draft = existingDraft {
      draft.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
      draft.tokenBudgetLimit = tokenBudgetLimit
      draft.concurrencyLimit = concurrencyLimit
      draft.planVersion += 1
      draft.updatedAt = now
      sprint = draft
    } else {
      sprint = Sprint(
        productID: productID,
        number: try nextSprintNumber(productID: productID),
        goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
        tokenBudgetLimit: tokenBudgetLimit,
        concurrencyLimit: concurrencyLimit,
        createdAt: now,
        updatedAt: now
      )
    }

    let sprintItems = inputs.map {
      SprintItem(
        sprintID: sprint.id,
        workItemID: $0.workItemID,
        implementerProfileID: $0.implementerProfileID,
        reviewerProfileID: $0.reviewerProfileID,
        estimatedTokens: $0.estimatedTokens,
        createdAt: now,
        updatedAt: now
      )
    }

    try transaction {
      if existingDraft == nil {
        try insertSprint(sprint)
      } else {
        try updateDraftSprint(sprint)
        try withStatement("DELETE FROM sprint_items WHERE sprint_id = ?;") { statement in
          try bind(sprint.id.uuidString, to: 1, in: statement)
          try stepDone(statement)
        }
      }

      for item in sprintItems {
        try insertSprintItem(item)
      }

      _ = try insertEvent(
        productID: productID,
        kind: "sprint.plan_saved",
        actor: "Product Owner",
        detail: "Sprint \(sprint.number), plan v\(sprint.planVersion): \(sprintItems.count) tickets"
      )
    }

    return SprintPlan(sprint: sprint, items: sprintItems)
  }

  public func fetchCurrentSprint(productID: UUID) throws -> SprintPlan? {
    guard
      let sprint = try withStatement(
        """
        SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
               concurrency_limit, plan_version, started_at, completed_at,
               retrospective_concluded_at, created_at, updated_at
        FROM sprints
        WHERE product_id = ? AND state IN ('active', 'draft')
        ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END, created_at DESC
        LIMIT 1;
        """,
        operation: { statement -> Sprint? in
          try bind(productID.uuidString, to: 1, in: statement)
          guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
          return try decodeSprint(statement)
        }
      )
    else {
      return nil
    }
    return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: sprint.id))
  }

  public func fetchSprintHistory(productID: UUID) throws -> [SprintPlan] {
    let sprints = try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             concurrency_limit, plan_version, started_at, completed_at,
             retrospective_concluded_at, created_at, updated_at
      FROM sprints
      WHERE product_id = ?
      ORDER BY sprint_number DESC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var values: [Sprint] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        values.append(try decodeSprint(statement))
      }
      return values
    }

    return try sprints.map { sprint in
      SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: sprint.id))
    }
  }

  public func sprintReadinessIssues(sprintID: UUID) throws -> [SprintReadinessIssue] {
    let sprint = try fetchSprint(id: sprintID)
    var issues: [SprintReadinessIssue] = []

    guard sprint.state == .draft else {
      return sprint.state == .active
        ? []
        : [SprintReadinessIssue(id: "sprint.state", message: "This sprint is not a draft.")]
    }

    let items = try fetchSprintItems(sprintID: sprintID)
    let sprintWorkItemIDs = Set(items.map(\.workItemID))
    let activeSprintWorkItemIDs: Set<UUID>
    if let activeSprint = try fetchSprint(productID: sprint.productID, state: .active),
      activeSprint.id != sprint.id
    {
      activeSprintWorkItemIDs = Set(
        try fetchSprintItems(sprintID: activeSprint.id).map(\.workItemID)
      )
    } else {
      activeSprintWorkItemIDs = []
    }
    if items.isEmpty {
      issues.append(
        SprintReadinessIssue(id: "sprint.empty", message: "Select at least one ticket."))
    }

    if sprint.concurrencyLimit <= 0 {
      issues.append(
        SprintReadinessIssue(
          id: "sprint.parallelism",
          message: "Parallelism must be greater than zero."
        )
      )
    }

    for item in items {
      let workItem = try fetchWorkItem(id: item.workItemID)
      if workItem.acceptanceCriteria.isEmpty {
        issues.append(
          SprintReadinessIssue(
            id: "\(workItem.id).acceptance",
            workItemID: workItem.id,
            message: "\(workItem.key) needs at least one acceptance criterion."
          )
        )
      }
      let dependencyEdges = try fetchWorkItemDependencies(productID: sprint.productID)
        .filter { $0.workItemID == workItem.id }
      for edge in dependencyEdges where !sprintWorkItemIDs.contains(edge.dependsOnWorkItemID) {
        let prerequisite = try fetchWorkItem(id: edge.dependsOnWorkItemID)
        if prerequisite.state != .released
          && !activeSprintWorkItemIDs.contains(prerequisite.id)
        {
          issues.append(
            SprintReadinessIssue(
              id: "\(workItem.id).dependency.\(prerequisite.id)",
              workItemID: workItem.id,
              message: "\(workItem.key) is blocked by \(prerequisite.key), which is not in this sprint, the active sprint, or Done."
            )
          )
        }
      }
      let implementer = item.implementerProfileID.flatMap { try? fetchAgentProfile(id: $0) }
      if implementer?.productID != sprint.productID || implementer?.role.canOwnDelivery != true {
        issues.append(
          SprintReadinessIssue(
            id: "\(workItem.id).implementer",
            workItemID: workItem.id,
            message: "\(workItem.key) needs a valid delivery owner."
          )
        )
      }

      if let reviewerID = item.reviewerProfileID {
        let reviewer = try? fetchAgentProfile(id: reviewerID)
        if reviewer?.productID != sprint.productID || reviewer?.role.canReview != true {
          issues.append(
            SprintReadinessIssue(
              id: "\(workItem.id).reviewer",
              workItemID: workItem.id,
              message: "\(workItem.key) has an invalid review assignment."
            )
          )
        }
      }
    }

    return issues
  }

  public func startSprint(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    if sprint.state == .active {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }
    guard sprint.state == .draft else {
      throw SprintPlanningError.sprintNotDraft
    }

    let issues = try sprintReadinessIssues(sprintID: id)
    guard issues.isEmpty else {
      throw SprintPlanningError.notReady(issues.map(\.message))
    }

    let items = try fetchSprintItems(sprintID: id)
    let now = Date()
    sprint.state = .active
    sprint.startedAt = now
    sprint.updatedAt = now

    try transaction {
      if let otherActive = try fetchSprint(productID: sprint.productID, state: .active),
        otherActive.id != sprint.id
      {
        throw SprintPlanningError.activeSprintExists
      }

      for sprintItem in items {
        var workItem = try fetchWorkItem(id: sprintItem.workItemID)
        guard [.backlog, .refining, .ready].contains(workItem.state) else {
          throw SprintPlanningError.itemNotReady(workItem.key)
        }

        try withStatement(
          """
          UPDATE sprint_items
          SET frozen_work_item_version = ?, frozen_title = ?, frozen_body = ?,
              frozen_acceptance_criteria_json = ?, updated_at = ?
          WHERE id = ?;
          """
        ) { statement in
          try bind(Int64(workItem.version), to: 1, in: statement)
          try bind(workItem.title, to: 2, in: statement)
          try bind(workItem.body, to: 3, in: statement)
          try bind(try encodeStringArray(workItem.acceptanceCriteria), to: 4, in: statement)
          try bind(now.timeIntervalSince1970, to: 5, in: statement)
          try bind(sprintItem.id.uuidString, to: 6, in: statement)
          try stepDone(statement)
        }

        workItem.state = .queued
        workItem.version += 1
        workItem.updatedAt = now
        try withStatement(
          """
          UPDATE work_items SET state = ?, version = ?, updated_at = ? WHERE id = ?;
          """
        ) { statement in
          try bind(workItem.state.rawValue, to: 1, in: statement)
          try bind(Int64(workItem.version), to: 2, in: statement)
          try bind(now.timeIntervalSince1970, to: 3, in: statement)
          try bind(workItem.id.uuidString, to: 4, in: statement)
          try stepDone(statement)
        }

        guard let implementerProfileID = sprintItem.implementerProfileID else {
          throw SprintPlanningError.invalidImplementer(workItem.key)
        }
        let run = AgentRun(
          productID: sprint.productID,
          sprintID: sprint.id,
          sprintItemID: sprintItem.id,
          workItemID: workItem.id,
          profileID: implementerProfileID,
          createdAt: now,
          updatedAt: now
        )
        try insertAgentRun(run)

        _ = try insertEvent(
          productID: sprint.productID,
          workItemID: workItem.id,
          kind: "work_item.queued",
          actor: "Sprint Scheduler",
          detail: "Authorized by Sprint \(sprint.number), plan v\(sprint.planVersion)"
        )
      }

      try withStatement(
        """
        UPDATE sprints SET state = ?, started_at = ?, updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(sprint.state.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(now.timeIntervalSince1970, to: 3, in: statement)
        try bind(sprint.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: sprint.productID,
        kind: "sprint.started",
        actor: "Product Owner",
        detail:
          "Sprint \(sprint.number), plan v\(sprint.planVersion): \(items.count) tickets authorized"
      )
    }

    return SprintPlan(
      sprint: try fetchSprint(id: id),
      items: try fetchSprintItems(sprintID: id)
    )
  }

  public func completeSprintIfFinished(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    guard sprint.state == .active else {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }

    let items = try fetchSprintItems(sprintID: id)
    guard !items.isEmpty else {
      return SprintPlan(sprint: sprint, items: items)
    }
    let allReleased = try items.allSatisfy { sprintItem in
      try fetchWorkItem(id: sprintItem.workItemID).state == .released
    }
    guard allReleased else {
      return SprintPlan(sprint: sprint, items: items)
    }

    let now = Date()
    sprint.state = .completed
    sprint.completedAt = now
    sprint.updatedAt = now
    try transaction {
      try withStatement(
        """
        UPDATE sprints
        SET state = ?, completed_at = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(sprint.state.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(now.timeIntervalSince1970, to: 3, in: statement)
        try bind(sprint.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: sprint.productID,
        kind: "sprint.completed",
        actor: "StoryPointless",
        detail: "Sprint \(sprint.number): every ticket accepted"
      )
      try insertRetrospectiveSynthesisIfNeeded(
        RetrospectiveSynthesis(
          productID: sprint.productID,
          sprintID: sprint.id,
          createdAt: now,
          updatedAt: now
        )
      )
    }
    return SprintPlan(sprint: sprint, items: items)
  }

  public func concludeRetrospective(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    guard sprint.state == .completed else {
      throw PersistenceError.corruptData(
        "Only a completed sprint can conclude its retrospective."
      )
    }
    if sprint.retrospectiveConcludedAt != nil {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }

    let synthesis = try fetchRetrospectiveSynthesis(sprintID: id)
    guard synthesis?.status.isResolved == true else {
      throw PersistenceError.corruptData(
        "Wait for the final retrospective actions, retry their preparation, or continue without AI suggestions."
      )
    }

    let unresolvedActions = try withStatement(
      """
      SELECT COUNT(*)
      FROM retrospective_notes
      WHERE sprint_id = ?
        AND category = 'suggested_action'
        AND action_status = 'proposed';
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw currentSQLiteError()
      }
      return Int(sqlite3_column_int64(statement, 0))
    }
    guard unresolvedActions == 0 else {
      throw PersistenceError.corruptData(
        "Review every suggested retrospective action before concluding the sprint."
      )
    }

    let now = Date()
    sprint.retrospectiveConcludedAt = now
    sprint.updatedAt = now
    try transaction {
      try withStatement(
        """
        UPDATE sprints
        SET retrospective_concluded_at = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: sprint.productID,
        kind: "retrospective.concluded",
        actor: "Product Owner",
        detail: "Sprint \(sprint.number) retrospective concluded"
      )
    }
    return SprintPlan(
      sprint: try fetchSprint(id: id),
      items: try fetchSprintItems(sprintID: id)
    )
  }

  public func fetchAgentRuns(productID: UUID) throws -> [AgentRun] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id, profile_id,
             status, codex_thread_id, worktree_path, ticket_budget_used,
             context_used_tokens, context_window_tokens, compaction_count,
             created_at, updated_at, turn_started_at, last_activity_at,
             last_activity_text, last_activity_kind, active_duration_seconds
      FROM agent_runs
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var runs: [AgentRun] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedProductID = UUID(uuidString: try text(statement, column: 1)),
          let workItemID = UUID(uuidString: try text(statement, column: 4)),
          let profileID = UUID(uuidString: try text(statement, column: 5)),
          let status = AgentRunStatus(rawValue: try text(statement, column: 6))
        else {
          throw PersistenceError.corruptData("Invalid agent run")
        }
        runs.append(
          AgentRun(
            id: id,
            productID: storedProductID,
            sprintID: try optionalText(statement, column: 2).flatMap(UUID.init(uuidString:)),
            sprintItemID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
            workItemID: workItemID,
            profileID: profileID,
            status: status,
            codexThreadID: try optionalText(statement, column: 7),
            worktreePath: try optionalText(statement, column: 8),
            ticketBudgetUsed: sqlite3_column_double(statement, 9),
            contextUsedTokens: optionalInt(statement, column: 10),
            contextWindowTokens: optionalInt(statement, column: 11),
            compactionCount: Int(sqlite3_column_int64(statement, 12)),
            activeDurationSeconds: sqlite3_column_double(statement, 19),
            turnStartedAt: optionalDate(statement, column: 15),
            lastActivityAt: optionalDate(statement, column: 16),
            lastActivityText: try optionalText(statement, column: 17),
            lastActivityKind: try optionalText(statement, column: 18)
              .flatMap(CodexLiveActivityKind.init(rawValue:)),
            createdAt: date(statement, column: 13),
            updatedAt: date(statement, column: 14)
          )
        )
      }
      return runs
    }
  }

  public func fetchAgentRun(id: UUID) throws -> AgentRun {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id, profile_id,
             status, codex_thread_id, worktree_path, ticket_budget_used,
             context_used_tokens, context_window_tokens, compaction_count,
             created_at, updated_at, turn_started_at, last_activity_at,
             last_activity_text, last_activity_kind, active_duration_seconds
      FROM agent_runs
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("Agent run \(id)")
      }
      guard
        let storedID = UUID(uuidString: try text(statement, column: 0)),
        let productID = UUID(uuidString: try text(statement, column: 1)),
        let workItemID = UUID(uuidString: try text(statement, column: 4)),
        let profileID = UUID(uuidString: try text(statement, column: 5)),
        let status = AgentRunStatus(rawValue: try text(statement, column: 6))
      else {
        throw PersistenceError.corruptData("Invalid agent run")
      }
      return AgentRun(
        id: storedID,
        productID: productID,
        sprintID: try optionalText(statement, column: 2).flatMap(UUID.init(uuidString:)),
        sprintItemID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
        workItemID: workItemID,
        profileID: profileID,
        status: status,
        codexThreadID: try optionalText(statement, column: 7),
        worktreePath: try optionalText(statement, column: 8),
        ticketBudgetUsed: sqlite3_column_double(statement, 9),
        contextUsedTokens: optionalInt(statement, column: 10),
        contextWindowTokens: optionalInt(statement, column: 11),
        compactionCount: Int(sqlite3_column_int64(statement, 12)),
        activeDurationSeconds: sqlite3_column_double(statement, 19),
        turnStartedAt: optionalDate(statement, column: 15),
        lastActivityAt: optionalDate(statement, column: 16),
        lastActivityText: try optionalText(statement, column: 17),
        lastActivityKind: try optionalText(statement, column: 18)
          .flatMap(CodexLiveActivityKind.init(rawValue:)),
        createdAt: date(statement, column: 13),
        updatedAt: date(statement, column: 14)
      )
    }
  }

  public func createAgentRun(_ run: AgentRun) throws -> AgentRun {
    let workItem = try fetchWorkItem(id: run.workItemID)
    let profile = try fetchAgentProfile(id: run.profileID)
    guard workItem.productID == run.productID, profile.productID == run.productID else {
      throw PersistenceError.corruptData("Agent run references another product")
    }
    try insertAgentRun(run)
    return try fetchAgentRun(id: run.id)
  }

  public func updateAgentRun(
    id: UUID,
    status: AgentRunStatus,
    codexThreadID: String? = nil,
    worktreePath: String? = nil,
    eventActor: String? = nil,
    eventDetail: String? = nil
  ) throws -> AgentRun {
    let existing = try fetchAgentRun(id: id)
    let now = Date()
    let closesActiveTurn = existing.status == .running && status != .running
    let additionalActiveDuration = closesActiveTurn
      ? existing.turnStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
      : 0
    try transaction {
      try withStatement(
        """
        UPDATE agent_runs
        SET status = ?,
            codex_thread_id = COALESCE(?, codex_thread_id),
            worktree_path = COALESCE(?, worktree_path),
            active_duration_seconds = active_duration_seconds + ?,
            turn_started_at = CASE WHEN ? = 1 THEN NULL ELSE turn_started_at END,
            updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(status.rawValue, to: 1, in: statement)
        try bindOptionalString(codexThreadID, to: 2, in: statement)
        try bindOptionalString(worktreePath, to: 3, in: statement)
        try bind(additionalActiveDuration, to: 4, in: statement)
        try bind(Int64(closesActiveTurn ? 1 : 0), to: 5, in: statement)
        try bind(now.timeIntervalSince1970, to: 6, in: statement)
        try bind(id.uuidString, to: 7, in: statement)
        try stepDone(statement)
      }
      if existing.status != status, let eventActor, let eventDetail {
        _ = try insertEvent(
          productID: existing.productID,
          workItemID: existing.workItemID,
          kind: "agent_run.\(status.rawValue)",
          actor: eventActor,
          detail: eventDetail
        )
      }
    }
    return try fetchAgentRun(id: id)
  }

  public func resetAgentRunExecutionContext(id: UUID) throws -> AgentRun {
    let now = Date()
    try withStatement(
      """
      UPDATE agent_runs
      SET codex_thread_id = NULL, worktree_path = NULL, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(now.timeIntervalSince1970, to: 1, in: statement)
      try bind(id.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentRun(id: id)
  }

  public func recordAgentRunActivity(
    id: UUID,
    activity: CodexLiveActivity? = nil,
    contextUsedTokens: Int? = nil,
    contextWindowTokens: Int? = nil,
    didCompact: Bool = false,
    startsTurn: Bool = false,
    at: Date = Date()
  ) throws -> AgentRun {
    let existing = try fetchAgentRun(id: id)
    let additionalActiveDuration =
      startsTurn && existing.status == .running
      ? existing.turnStartedAt.map { max(0, at.timeIntervalSince($0)) } ?? 0
      : 0
    try withStatement(
      """
      UPDATE agent_runs
      SET active_duration_seconds = active_duration_seconds + ?,
          turn_started_at =
            CASE
              WHEN ? = 1 THEN ?
              ELSE COALESCE(turn_started_at, ?)
            END,
          last_activity_at = ?,
          last_activity_text = COALESCE(?, last_activity_text),
          last_activity_kind = COALESCE(?, last_activity_kind),
          context_used_tokens = COALESCE(?, context_used_tokens),
          context_window_tokens = COALESCE(?, context_window_tokens),
          compaction_count = compaction_count + ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(additionalActiveDuration, to: 1, in: statement)
      try bind(Int64(startsTurn ? 1 : 0), to: 2, in: statement)
      try bind(at.timeIntervalSince1970, to: 3, in: statement)
      try bind(at.timeIntervalSince1970, to: 4, in: statement)
      try bind(at.timeIntervalSince1970, to: 5, in: statement)
      try bindOptionalString(activity?.text, to: 6, in: statement)
      try bindOptionalString(activity?.kind.rawValue, to: 7, in: statement)
      try bindOptionalInt(contextUsedTokens, to: 8, in: statement)
      try bindOptionalInt(contextWindowTokens, to: 9, in: statement)
      try bind(Int64(didCompact ? 1 : 0), to: 10, in: statement)
      try bind(id.uuidString, to: 11, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentRun(id: id)
  }

  public func nextCandidateRevisionVersion(workItemID: UUID) throws -> Int {
    try withStatement(
      """
      SELECT COALESCE(MAX(version), 0) + 1
      FROM candidate_revisions
      WHERE work_item_id = ?;
      """
    ) { statement in
      try bind(workItemID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  public func createCandidateRevision(
    _ candidate: CandidateRevision
  ) throws -> CandidateRevision {
    try withStatement(
      """
      INSERT INTO candidate_revisions (
          id, product_id, sprint_id, sprint_item_id, work_item_id,
          implementation_run_id, version, branch_name, base_sha, head_sha,
          integrated_sha, worktree_path, integration_worktree_path, status,
          commit_count, execution_result_json, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(candidate.id.uuidString, to: 1, in: statement)
      try bind(candidate.productID.uuidString, to: 2, in: statement)
      try bind(candidate.sprintID.uuidString, to: 3, in: statement)
      try bind(candidate.sprintItemID.uuidString, to: 4, in: statement)
      try bind(candidate.workItemID.uuidString, to: 5, in: statement)
      try bind(candidate.implementationRunID.uuidString, to: 6, in: statement)
      try bind(Int64(candidate.version), to: 7, in: statement)
      try bind(candidate.branchName, to: 8, in: statement)
      try bind(candidate.baseSHA, to: 9, in: statement)
      try bind(candidate.headSHA, to: 10, in: statement)
      try bindOptionalString(candidate.integratedSHA, to: 11, in: statement)
      try bind(candidate.worktreePath, to: 12, in: statement)
      try bindOptionalString(candidate.integrationWorktreePath, to: 13, in: statement)
      try bind(candidate.status.rawValue, to: 14, in: statement)
      try bind(Int64(candidate.commitCount), to: 15, in: statement)
      try bind(candidate.executionResultJSON, to: 16, in: statement)
      try bind(candidate.createdAt.timeIntervalSince1970, to: 17, in: statement)
      try bind(candidate.updatedAt.timeIntervalSince1970, to: 18, in: statement)
      try stepDone(statement)
    }
    return try fetchCandidateRevision(id: candidate.id)
  }

  public func fetchCandidateRevisions(productID: UUID) throws -> [CandidateRevision] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id,
             implementation_run_id, version, branch_name, base_sha, head_sha,
             integrated_sha, worktree_path, integration_worktree_path, status,
             commit_count, execution_result_json, created_at, updated_at
      FROM candidate_revisions
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var candidates: [CandidateRevision] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        candidates.append(try decodeCandidateRevision(statement))
      }
      return candidates
    }
  }

  public func fetchCandidateRevision(id: UUID) throws -> CandidateRevision {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id,
             implementation_run_id, version, branch_name, base_sha, head_sha,
             integrated_sha, worktree_path, integration_worktree_path, status,
             commit_count, execution_result_json, created_at, updated_at
      FROM candidate_revisions
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("candidate revision \(id)")
      }
      return try decodeCandidateRevision(statement)
    }
  }

  public func updateCandidateRevision(
    id: UUID,
    status: CandidateRevisionStatus,
    integratedSHA: String? = nil,
    integrationWorktreePath: String? = nil
  ) throws -> CandidateRevision {
    let now = Date()
    try withStatement(
      """
      UPDATE candidate_revisions
      SET status = ?,
          integrated_sha = COALESCE(?, integrated_sha),
          integration_worktree_path = COALESCE(?, integration_worktree_path),
          updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bindOptionalString(integratedSHA, to: 2, in: statement)
      try bindOptionalString(integrationWorktreePath, to: 3, in: statement)
      try bind(now.timeIntervalSince1970, to: 4, in: statement)
      try bind(id.uuidString, to: 5, in: statement)
      try stepDone(statement)
    }
    return try fetchCandidateRevision(id: id)
  }

  public func saveDemoSession(_ session: DemoSession) throws -> DemoSession {
    try withStatement(
      """
      INSERT INTO demo_sessions (
          id, product_id, candidate_revision_id, status, preview_worktree_path,
          allocated_port, output, error_message, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(candidate_revision_id) DO UPDATE SET
          status = excluded.status,
          preview_worktree_path = excluded.preview_worktree_path,
          allocated_port = excluded.allocated_port,
          output = excluded.output,
          error_message = excluded.error_message,
          updated_at = excluded.updated_at;
      """
    ) { statement in
      try bind(session.id.uuidString, to: 1, in: statement)
      try bind(session.productID.uuidString, to: 2, in: statement)
      try bind(session.candidateRevisionID.uuidString, to: 3, in: statement)
      try bind(session.status.rawValue, to: 4, in: statement)
      try bindOptionalString(session.previewWorktreePath, to: 5, in: statement)
      try bindOptionalInt(session.allocatedPort, to: 6, in: statement)
      try bindOptionalString(session.output, to: 7, in: statement)
      try bindOptionalString(session.errorMessage, to: 8, in: statement)
      try bind(session.createdAt.timeIntervalSince1970, to: 9, in: statement)
      try bind(session.updatedAt.timeIntervalSince1970, to: 10, in: statement)
      try stepDone(statement)
    }
    return try fetchDemoSession(candidateRevisionID: session.candidateRevisionID)
  }

  public func fetchDemoSessions(productID: UUID) throws -> [DemoSession] {
    try withStatement(
      """
      SELECT id, product_id, candidate_revision_id, status, preview_worktree_path,
             allocated_port, output, error_message, created_at, updated_at
      FROM demo_sessions
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var sessions: [DemoSession] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        sessions.append(try decodeDemoSession(statement))
      }
      return sessions
    }
  }

  public func fetchDemoSession(candidateRevisionID: UUID) throws -> DemoSession {
    try withStatement(
      """
      SELECT id, product_id, candidate_revision_id, status, preview_worktree_path,
             allocated_port, output, error_message, created_at, updated_at
      FROM demo_sessions
      WHERE candidate_revision_id = ?;
      """
    ) { statement in
      try bind(candidateRevisionID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound(
          "demo session for candidate \(candidateRevisionID)"
        )
      }
      return try decodeDemoSession(statement)
    }
  }

  public func saveAgentPermissionRequest(
    _ request: AgentPermissionRequest
  ) throws -> AgentPermissionRequest {
    try withStatement(
      """
      INSERT INTO agent_permission_requests (
          id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
          server_request_id, method, kind, title, detail, reason, signature,
          status, created_at, updated_at, product_grant_signature
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          status = excluded.status,
          updated_at = excluded.updated_at;
      """
    ) { statement in
      try bind(request.id.uuidString, to: 1, in: statement)
      try bind(request.productID.uuidString, to: 2, in: statement)
      try bind(request.workItemID.uuidString, to: 3, in: statement)
      try bind(request.agentRunID.uuidString, to: 4, in: statement)
      try bind(request.threadID, to: 5, in: statement)
      try bind(request.turnID, to: 6, in: statement)
      try bind(request.serverRequestID, to: 7, in: statement)
      try bind(request.method, to: 8, in: statement)
      try bind(request.kind.rawValue, to: 9, in: statement)
      try bind(request.title, to: 10, in: statement)
      try bind(request.detail, to: 11, in: statement)
      try bindOptionalString(request.reason, to: 12, in: statement)
      try bind(request.signature, to: 13, in: statement)
      try bind(request.status.rawValue, to: 14, in: statement)
      try bind(request.createdAt.timeIntervalSince1970, to: 15, in: statement)
      try bind(request.updatedAt.timeIntervalSince1970, to: 16, in: statement)
      try bindOptionalString(request.productGrantSignature, to: 17, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionRequest(id: request.id)
  }

  public func fetchAgentPermissionRequests(
    productID: UUID
  ) throws -> [AgentPermissionRequest] {
    try withStatement(
      """
      SELECT id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
             server_request_id, method, kind, title, detail, reason, signature,
             status, created_at, updated_at, product_grant_signature
      FROM agent_permission_requests
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var requests: [AgentPermissionRequest] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        requests.append(try decodeAgentPermissionRequest(statement))
      }
      return requests
    }
  }

  public func fetchAgentPermissionRequest(
    id: UUID
  ) throws -> AgentPermissionRequest {
    try withStatement(
      """
      SELECT id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
             server_request_id, method, kind, title, detail, reason, signature,
             status, created_at, updated_at, product_grant_signature
      FROM agent_permission_requests
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("permission request \(id)")
      }
      return try decodeAgentPermissionRequest(statement)
    }
  }

  public func updateAgentPermissionRequest(
    id: UUID,
    status: AgentPermissionRequestStatus
  ) throws -> AgentPermissionRequest {
    try withStatement(
      """
      UPDATE agent_permission_requests
      SET status = ?, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(id.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionRequest(id: id)
  }

  public func interruptPendingAgentPermissionRequests(
    productID: UUID? = nil
  ) throws {
    let sql =
      if productID == nil {
        """
        UPDATE agent_permission_requests
        SET status = 'interrupted', updated_at = ?
        WHERE status = 'pending';
        """
      } else {
        """
        UPDATE agent_permission_requests
        SET status = 'interrupted', updated_at = ?
        WHERE status = 'pending' AND product_id = ?;
        """
      }
    try withStatement(sql) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      if let productID {
        try bind(productID.uuidString, to: 2, in: statement)
      }
      try stepDone(statement)
    }
  }

  public func saveAgentPermissionGrant(
    _ grant: AgentPermissionGrant
  ) throws -> AgentPermissionGrant {
    if let existing = try fetchActiveAgentPermissionGrant(
      productID: grant.productID,
      signature: grant.signature
    ) {
      return existing
    }
    try withStatement(
      """
      INSERT INTO agent_permission_grants (
          id, product_id, source_request_id, method, kind, title, detail,
          signature, created_at, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(grant.id.uuidString, to: 1, in: statement)
      try bind(grant.productID.uuidString, to: 2, in: statement)
      try bindOptionalUUID(grant.sourceRequestID, to: 3, in: statement)
      try bind(grant.method, to: 4, in: statement)
      try bind(grant.kind.rawValue, to: 5, in: statement)
      try bind(grant.title, to: 6, in: statement)
      try bind(grant.detail, to: 7, in: statement)
      try bind(grant.signature, to: 8, in: statement)
      try bind(grant.createdAt.timeIntervalSince1970, to: 9, in: statement)
      try bindOptionalDate(grant.revokedAt, to: 10, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionGrant(id: grant.id)
  }

  public func fetchAgentPermissionGrants(
    productID: UUID,
    includeRevoked: Bool = false
  ) throws -> [AgentPermissionGrant] {
    let revokedFilter = includeRevoked ? "" : "AND revoked_at IS NULL"
    return try withStatement(
      """
      SELECT id, product_id, source_request_id, method, kind, title, detail,
             signature, created_at, revoked_at
      FROM agent_permission_grants
      WHERE product_id = ? \(revokedFilter)
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var grants: [AgentPermissionGrant] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        grants.append(try decodeAgentPermissionGrant(statement))
      }
      return grants
    }
  }

  public func revokeAgentPermissionGrant(id: UUID) throws -> AgentPermissionGrant {
    try withStatement(
      """
      UPDATE agent_permission_grants
      SET revoked_at = ?
      WHERE id = ? AND revoked_at IS NULL;
      """
    ) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      try bind(id.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionGrant(id: id)
  }

  private func fetchActiveAgentPermissionGrant(
    productID: UUID,
    signature: String
  ) throws -> AgentPermissionGrant? {
    try withStatement(
      """
      SELECT id, product_id, source_request_id, method, kind, title, detail,
             signature, created_at, revoked_at
      FROM agent_permission_grants
      WHERE product_id = ? AND signature = ? AND revoked_at IS NULL
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(signature, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeAgentPermissionGrant(statement)
    }
  }

  private func fetchAgentPermissionGrant(id: UUID) throws -> AgentPermissionGrant {
    try withStatement(
      """
      SELECT id, product_id, source_request_id, method, kind, title, detail,
             signature, created_at, revoked_at
      FROM agent_permission_grants
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("agent permission grant \(id)")
      }
      return try decodeAgentPermissionGrant(statement)
    }
  }

  public func createKnowledgePageProposals(
    _ proposals: [KnowledgePageProposal]
  ) throws {
    try transaction {
      for proposal in proposals {
        try withStatement(
          """
          INSERT INTO knowledge_page_proposals (
              id, product_id, sprint_id, work_item_id, candidate_revision_id,
              operation, target_page_id, parent_page_id, base_page_title,
              base_page_body_markdown, base_page_updated_at, title,
              proposed_body_markdown, rationale, status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          """
        ) { statement in
          try bind(proposal.id.uuidString, to: 1, in: statement)
          try bind(proposal.productID.uuidString, to: 2, in: statement)
          try bind(proposal.sprintID.uuidString, to: 3, in: statement)
          try bind(proposal.workItemID.uuidString, to: 4, in: statement)
          try bind(proposal.candidateRevisionID.uuidString, to: 5, in: statement)
          try bind(proposal.operation.rawValue, to: 6, in: statement)
          try bindOptionalUUID(proposal.targetPageID, to: 7, in: statement)
          try bindOptionalUUID(proposal.parentPageID, to: 8, in: statement)
          try bindOptionalString(proposal.basePageTitle, to: 9, in: statement)
          try bindOptionalString(proposal.basePageBodyMarkdown, to: 10, in: statement)
          try bindOptionalDate(proposal.basePageUpdatedAt, to: 11, in: statement)
          try bind(proposal.title, to: 12, in: statement)
          try bind(
            KnowledgeMarkdown.normalizedBody(proposal.proposedBodyMarkdown),
            to: 13,
            in: statement
          )
          try bind(proposal.rationale, to: 14, in: statement)
          try bind(proposal.status.rawValue, to: 15, in: statement)
          try bind(proposal.createdAt.timeIntervalSince1970, to: 16, in: statement)
          try bind(proposal.updatedAt.timeIntervalSince1970, to: 17, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func fetchKnowledgePageProposals(
    productID: UUID
  ) throws -> [KnowledgePageProposal] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, work_item_id, candidate_revision_id,
             operation, target_page_id, parent_page_id, base_page_title,
             base_page_body_markdown, base_page_updated_at, title,
             proposed_body_markdown, rationale, status, created_at, updated_at
      FROM knowledge_page_proposals
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var proposals: [KnowledgePageProposal] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        proposals.append(try decodeKnowledgePageProposal(statement))
      }
      return proposals
    }
  }

  public func markKnowledgePageProposals(
    candidateRevisionID: UUID,
    status: KnowledgePageProposalStatus
  ) throws {
    try withStatement(
      """
      UPDATE knowledge_page_proposals
      SET status = ?, updated_at = ?
      WHERE candidate_revision_id = ?
        AND status IN ('proposed', 'reviewed');
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(candidateRevisionID.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
  }

  public func decideKnowledgePageProposal(
    id: UUID,
    accept: Bool,
    authorName: String
  ) throws -> KnowledgePageProposal {
    var proposal = try fetchKnowledgePageProposal(id: id)
    guard proposal.status == .reviewed || proposal.status == .proposed else {
      return proposal
    }
    let now = Date()
    try transaction {
      if accept {
        switch proposal.operation {
        case .update:
          guard let targetPageID = proposal.targetPageID else {
            throw PersistenceError.corruptData("Knowledge update has no target page")
          }
          let target = try fetchKnowledgePage(id: targetPageID)
          guard target.productID == proposal.productID else {
            throw PersistenceError.corruptData("Knowledge update targets another product")
          }
          guard
            let baseTitle = proposal.basePageTitle,
            let baseBody = proposal.basePageBodyMarkdown,
            let baseUpdatedAt = proposal.basePageUpdatedAt,
            target.title == baseTitle,
            target.bodyMarkdown == baseBody,
            abs(target.updatedAt.timeIntervalSince(baseUpdatedAt)) < 0.001
          else {
            throw PersistenceError.corruptData(
              "The canonical page changed after this proposal was prepared. Review a fresh proposal instead of overwriting the newer page."
            )
          }
          let normalizedBody = KnowledgeMarkdown.normalizedBody(proposal.proposedBodyMarkdown)
          try withStatement(
            """
            UPDATE knowledge_pages
            SET title = ?, body_markdown = ?, verification_status = 'verified', updated_at = ?
            WHERE id = ?;
            """
          ) { statement in
            try bind(proposal.title, to: 1, in: statement)
            try bind(normalizedBody, to: 2, in: statement)
            try bind(now.timeIntervalSince1970, to: 3, in: statement)
            try bind(targetPageID.uuidString, to: 4, in: statement)
            try stepDone(statement)
          }
          try insertKnowledgeRevision(
            pageID: targetPageID,
            bodyMarkdown: normalizedBody,
            authorName: authorName,
            changeSummary: proposal.rationale,
            createdAt: now
          )
        case .create:
          guard let parentPageID = proposal.parentPageID else {
            throw PersistenceError.corruptData("Knowledge creation has no parent page")
          }
          let parent = try fetchKnowledgePage(id: parentPageID)
          guard parent.productID == proposal.productID else {
            throw PersistenceError.corruptData("Knowledge creation targets another product")
          }
          let siblingPages = try fetchKnowledgePages(productID: proposal.productID)
            .filter { $0.parentID == parentPageID }
          let baseSlug = Self.knowledgeSlug(for: proposal.title)
          var slug = baseSlug
          var suffix = 2
          while siblingPages.contains(where: { $0.slug == slug }) {
            slug = "\(baseSlug)-\(suffix)"
            suffix += 1
          }
          let page = KnowledgePage(
            productID: proposal.productID,
            parentID: parentPageID,
            title: proposal.title,
            slug: slug,
            bodyMarkdown: KnowledgeMarkdown.normalizedBody(proposal.proposedBodyMarkdown),
            verificationStatus: .verified,
            sortOrder: (siblingPages.map(\.sortOrder).max() ?? -1) + 1,
            sourceWorkItemID: proposal.workItemID,
            createdAt: now,
            updatedAt: now
          )
          try insertKnowledgePage(
            page,
            authorName: authorName,
            changeSummary: proposal.rationale
          )
        }
      }

      proposal.status = accept ? .accepted : .rejected
      proposal.updatedAt = now
      try withStatement(
        """
        UPDATE knowledge_page_proposals
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(proposal.status.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: proposal.productID,
        workItemID: proposal.workItemID,
        kind: accept ? "knowledge.proposal.accepted" : "knowledge.proposal.rejected",
        actor: authorName,
        detail: proposal.title
      )
    }
    return try fetchKnowledgePageProposal(id: id)
  }

  public func fetchActivity(productID: UUID, limit: Int = 100) throws -> [ActivityEvent] {
    try withStatement(
      """
      SELECT sequence, id, product_id, work_item_id, kind, actor, detail, created_at
      FROM activity_events
      WHERE product_id = ?
      ORDER BY sequence DESC
      LIMIT ?;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(Int64(limit), to: 2, in: statement)
      var events: [ActivityEvent] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 1)),
          let storedProductID = UUID(uuidString: try text(statement, column: 2))
        else {
          throw PersistenceError.corruptData("Invalid activity event")
        }
        let workItemID = try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:))
        events.append(
          ActivityEvent(
            id: id,
            sequence: sqlite3_column_int64(statement, 0),
            productID: storedProductID,
            workItemID: workItemID,
            kind: try text(statement, column: 4),
            actor: try text(statement, column: 5),
            detail: try text(statement, column: 6),
            createdAt: date(statement, column: 7)
          )
        )
      }
      return events
    }
  }

  public func fetchActivity(workItemID: UUID, limit: Int = 200) throws -> [ActivityEvent] {
    try withStatement(
      """
      SELECT sequence, id, product_id, work_item_id, kind, actor, detail, created_at
      FROM activity_events
      WHERE work_item_id = ?
      ORDER BY sequence DESC
      LIMIT ?;
      """
    ) { statement in
      try bind(workItemID.uuidString, to: 1, in: statement)
      try bind(Int64(limit), to: 2, in: statement)
      var events: [ActivityEvent] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 1)),
          let storedProductID = UUID(uuidString: try text(statement, column: 2))
        else {
          throw PersistenceError.corruptData("Invalid activity event")
        }
        let storedWorkItemID = try optionalText(statement, column: 3)
          .flatMap(UUID.init(uuidString:))
        events.append(
          ActivityEvent(
            id: id,
            sequence: sqlite3_column_int64(statement, 0),
            productID: storedProductID,
            workItemID: storedWorkItemID,
            kind: try text(statement, column: 4),
            actor: try text(statement, column: 5),
            detail: try text(statement, column: 6),
            createdAt: date(statement, column: 7)
          )
        )
      }
      return events
    }
  }

  public func saveRetrospectiveNotes(_ notes: [RetrospectiveNote]) throws {
    guard !notes.isEmpty else { return }
    try transaction {
      for note in notes {
        try insertRetrospectiveNoteIfNeeded(note)
      }
    }
  }

  public func proposeRetrospectiveAction(
    productID: UUID,
    sprintID: UUID,
    body: String,
    destination: RetrospectiveActionDestination
  ) throws -> RetrospectiveNote {
    let sprint = try fetchSprint(id: sprintID)
    guard sprint.productID == productID else {
      throw PersistenceError.corruptData(
        "The retrospective does not belong to the selected product."
      )
    }
    guard sprint.state == .completed else {
      throw PersistenceError.corruptData(
        "Retrospective changes can only be proposed after the sprint is complete."
      )
    }
    guard sprint.retrospectiveConcludedAt == nil else {
      throw PersistenceError.corruptData(
        "This retrospective has already been concluded."
      )
    }
    guard try fetchRetrospectiveSynthesis(sprintID: sprintID)?.status.isResolved == true else {
      throw PersistenceError.corruptData(
        "Wait for the final retrospective actions, retry their preparation, or continue without AI suggestions before adding a proposal."
      )
    }

    let proposal = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !proposal.isEmpty else {
      throw PersistenceError.corruptData(
        "A retrospective proposal needs a description."
      )
    }

    let note = RetrospectiveNote(
      productID: productID,
      sprintID: sprintID,
      authorName: "Product Owner",
      category: .suggestedAction,
      body: proposal,
      actionStatus: .proposed,
      actionDestination: destination
    )
    try transaction {
      try insertRetrospectiveNoteIfNeeded(note)
      _ = try insertEvent(
        productID: productID,
        kind: "retrospective.action_proposed",
        actor: "Product Owner",
        detail: note.id.uuidString
      )
    }
    return note
  }

  public func fetchRetrospectiveNotes(productID: UUID) throws -> [RetrospectiveNote] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, work_item_id, profile_id, author_name,
             category, body, is_action_candidate, action_status, action_destination,
             expected_effect, synthesis_id, accepted_work_item_id, created_at, updated_at
      FROM retrospective_notes
      WHERE product_id = ?
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var notes: [RetrospectiveNote] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedProductID = UUID(uuidString: try text(statement, column: 1)),
          let sprintID = UUID(uuidString: try text(statement, column: 2)),
          let category = RetrospectiveNoteCategory(rawValue: try text(statement, column: 6))
        else {
          throw PersistenceError.corruptData("Invalid retrospective note")
        }
        notes.append(
          RetrospectiveNote(
            id: id,
            productID: storedProductID,
            sprintID: sprintID,
            workItemID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
            profileID: try optionalText(statement, column: 4).flatMap(UUID.init(uuidString:)),
            authorName: try text(statement, column: 5),
            category: category,
            body: try text(statement, column: 7),
            isActionCandidate: sqlite3_column_int64(statement, 8) != 0,
            actionStatus: try optionalText(statement, column: 9).flatMap(
              RetrospectiveActionStatus.init(rawValue:)
            ),
            actionDestination: try optionalText(statement, column: 10).flatMap(
              RetrospectiveActionDestination.init(rawValue:)
            ),
            expectedEffect: try optionalText(statement, column: 11),
            synthesisID: try optionalText(statement, column: 12).flatMap(
              UUID.init(uuidString:)
            ),
            acceptedWorkItemID: try optionalText(statement, column: 13).flatMap(
              UUID.init(uuidString:)
            ),
            createdAt: date(statement, column: 14),
            updatedAt: date(statement, column: 15)
          )
        )
      }
      return notes
    }
  }

  public func fetchRetrospectiveSyntheses(
    productID: UUID
  ) throws -> [RetrospectiveSynthesis] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, profile_id, status, codex_thread_id,
             codex_turn_id, error_message, created_at, updated_at
      FROM retrospective_syntheses
      WHERE product_id = ?
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var syntheses: [RetrospectiveSynthesis] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        syntheses.append(try decodeRetrospectiveSynthesis(statement))
      }
      return syntheses
    }
  }

  public func fetchRetrospectiveSynthesisSourceNotes(
    synthesisID: UUID
  ) throws -> [RetrospectiveNote] {
    let synthesis = try fetchRetrospectiveSynthesis(id: synthesisID)
    let sourceIDs = try withStatement(
      """
      SELECT source_note_id
      FROM retrospective_synthesis_sources
      WHERE synthesis_id = ?;
      """
    ) { statement in
      try bind(synthesisID.uuidString, to: 1, in: statement)
      var ids: Set<UUID> = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: try text(statement, column: 0)) else {
          throw PersistenceError.corruptData(
            "Invalid retrospective synthesis source"
          )
        }
        ids.insert(id)
      }
      return ids
    }
    return try fetchRetrospectiveNotes(productID: synthesis.productID)
      .filter { sourceIDs.contains($0.id) }
  }

  public func fetchRetrospectiveActionSources(
    productID: UUID
  ) throws -> [RetrospectiveActionSource] {
    try withStatement(
      """
      SELECT source.action_note_id, source.source_note_id
      FROM retrospective_action_sources AS source
      JOIN retrospective_notes AS action ON action.id = source.action_note_id
      WHERE action.product_id = ?
      ORDER BY action.created_at ASC, source.source_note_id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var sources: [RetrospectiveActionSource] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let actionNoteID = UUID(uuidString: try text(statement, column: 0)),
          let sourceNoteID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid retrospective action source")
        }
        sources.append(
          RetrospectiveActionSource(
            actionNoteID: actionNoteID,
            sourceNoteID: sourceNoteID
          )
        )
      }
      return sources
    }
  }

  public func beginRetrospectiveSynthesis(
    id: UUID,
    profileID: UUID
  ) throws -> RetrospectiveSynthesis {
    var synthesis = try fetchRetrospectiveSynthesis(id: id)
    if synthesis.status == .generating || synthesis.status.isResolved {
      return synthesis
    }
    let sprint = try fetchSprint(id: synthesis.sprintID)
    guard
      sprint.state == .completed,
      sprint.retrospectiveConcludedAt == nil
    else {
      throw PersistenceError.corruptData(
        "Retrospective actions can only be prepared for an open completed sprint."
      )
    }
    let profile = try fetchAgentProfile(id: profileID)
    guard
      profile.productID == synthesis.productID,
      profile.role == .businessAnalyst
    else {
      throw PersistenceError.corruptData(
        "A Business Analyst must prepare the final retrospective actions."
      )
    }

    let now = Date()
    synthesis.profileID = profileID
    synthesis.status = .generating
    synthesis.codexThreadID = nil
    synthesis.codexTurnID = nil
    synthesis.errorMessage = nil
    synthesis.updatedAt = now
    try transaction {
      let existingSourceCount = try withStatement(
        """
        SELECT COUNT(*)
        FROM retrospective_synthesis_sources
        WHERE synthesis_id = ?;
        """
      ) { statement in
        try bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
          throw currentSQLiteError()
        }
        return Int(sqlite3_column_int64(statement, 0))
      }
      if existingSourceCount == 0 {
        try withStatement(
          """
          INSERT OR IGNORE INTO retrospective_synthesis_sources (
              synthesis_id, source_note_id
          )
          SELECT ?, id
          FROM retrospective_notes
          WHERE sprint_id = ?
            AND (
              category IN ('went_well', 'could_improve')
              OR is_action_candidate = 1
            );
          """
        ) { statement in
          try bind(id.uuidString, to: 1, in: statement)
          try bind(synthesis.sprintID.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
      try updateRetrospectiveSynthesis(synthesis)
      _ = try insertEvent(
        productID: synthesis.productID,
        kind: "retrospective.synthesis_started",
        actor: profile.name,
        detail: synthesis.sprintID.uuidString
      )
    }
    return synthesis
  }

  public func attachRetrospectiveSynthesisTurn(
    id: UUID,
    threadID: String,
    turnID: String
  ) throws -> RetrospectiveSynthesis {
    var synthesis = try fetchRetrospectiveSynthesis(id: id)
    guard synthesis.status == .generating else { return synthesis }
    synthesis.codexThreadID = threadID
    synthesis.codexTurnID = turnID
    synthesis.updatedAt = Date()
    try updateRetrospectiveSynthesis(synthesis)
    return synthesis
  }

  public func completeRetrospectiveSynthesis(
    id: UUID,
    actions: [RetrospectiveSynthesisActionDraft],
    profileID: UUID,
    authorName: String
  ) throws -> [RetrospectiveNote] {
    var synthesis = try fetchRetrospectiveSynthesis(id: id)
    guard synthesis.status == .generating else {
      throw PersistenceError.corruptData(
        "Only a running retrospective synthesis can be completed."
      )
    }
    guard actions.count <= CodexRetrospectiveSynthesizer.maximumActionCount else {
      throw PersistenceError.corruptData(
        "A retrospective synthesis can contain at most five actions."
      )
    }
    let allowedSourceIDs = Set(
      try fetchRetrospectiveSynthesisSourceNotes(synthesisID: id).map(\.id)
    )
    guard actions.allSatisfy({
      !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.expectedEffect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.sourceNoteIDs.isEmpty
        && Set($0.sourceNoteIDs).isSubset(of: allowedSourceIDs)
    }) else {
      throw PersistenceError.corruptData(
        "Every final action needs a description, expected effect, and frozen sprint evidence."
      )
    }

    let now = Date()
    let notes = actions.map { action in
      RetrospectiveNote(
        productID: synthesis.productID,
        sprintID: synthesis.sprintID,
        profileID: profileID,
        authorName: authorName,
        category: .suggestedAction,
        body: action.body.trimmingCharacters(in: .whitespacesAndNewlines),
        actionStatus: .proposed,
        actionDestination: action.destination,
        expectedEffect: action.expectedEffect.trimmingCharacters(
          in: .whitespacesAndNewlines
        ),
        synthesisID: synthesis.id,
        createdAt: now,
        updatedAt: now
      )
    }
    synthesis.profileID = profileID
    synthesis.status = .completed
    synthesis.errorMessage = nil
    synthesis.updatedAt = now
    try transaction {
      for (note, action) in zip(notes, actions) {
        try insertRetrospectiveNoteIfNeeded(note)
        for sourceNoteID in Set(action.sourceNoteIDs) {
          try withStatement(
            """
            INSERT OR IGNORE INTO retrospective_action_sources (
                action_note_id, source_note_id
            ) VALUES (?, ?);
            """
          ) { statement in
            try bind(note.id.uuidString, to: 1, in: statement)
            try bind(sourceNoteID.uuidString, to: 2, in: statement)
            try stepDone(statement)
          }
        }
      }
      try updateRetrospectiveSynthesis(synthesis)
      _ = try insertEvent(
        productID: synthesis.productID,
        kind: "retrospective.synthesized",
        actor: authorName,
        detail: "\(actions.count) final action\(actions.count == 1 ? "" : "s")"
      )
    }
    return notes
  }

  public func failRetrospectiveSynthesis(
    id: UUID,
    message: String
  ) throws -> RetrospectiveSynthesis {
    var synthesis = try fetchRetrospectiveSynthesis(id: id)
    guard synthesis.status == .generating else { return synthesis }
    synthesis.status = .failed
    synthesis.errorMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    synthesis.updatedAt = Date()
    try updateRetrospectiveSynthesis(synthesis)
    return synthesis
  }

  public func skipRetrospectiveSynthesis(id: UUID) throws -> RetrospectiveSynthesis {
    var synthesis = try fetchRetrospectiveSynthesis(id: id)
    guard synthesis.status == .pending || synthesis.status == .failed else {
      return synthesis
    }
    synthesis.status = .skipped
    synthesis.errorMessage = nil
    synthesis.updatedAt = Date()
    try transaction {
      try updateRetrospectiveSynthesis(synthesis)
      _ = try insertEvent(
        productID: synthesis.productID,
        kind: "retrospective.synthesis_skipped",
        actor: "Product Owner",
        detail: synthesis.sprintID.uuidString
      )
    }
    return synthesis
  }

  public func requeueGeneratingRetrospectiveSyntheses() throws {
    try withStatement(
      """
      UPDATE retrospective_syntheses
      SET status = 'pending',
          codex_thread_id = NULL,
          codex_turn_id = NULL,
          updated_at = ?
      WHERE status = 'generating';
      """
    ) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      try stepDone(statement)
    }
  }

  private func fetchRetrospectiveNote(id: UUID) throws -> RetrospectiveNote {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, work_item_id, profile_id, author_name,
             category, body, is_action_candidate, action_status, action_destination,
             expected_effect, synthesis_id, accepted_work_item_id, created_at, updated_at
      FROM retrospective_notes WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("retrospective action \(id)")
      }
      guard
        let storedID = UUID(uuidString: try text(statement, column: 0)),
        let productID = UUID(uuidString: try text(statement, column: 1)),
        let sprintID = UUID(uuidString: try text(statement, column: 2)),
        let category = RetrospectiveNoteCategory(rawValue: try text(statement, column: 6))
      else {
        throw PersistenceError.corruptData("Invalid retrospective action")
      }
      return RetrospectiveNote(
        id: storedID,
        productID: productID,
        sprintID: sprintID,
        workItemID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
        profileID: try optionalText(statement, column: 4).flatMap(UUID.init(uuidString:)),
        authorName: try text(statement, column: 5),
        category: category,
        body: try text(statement, column: 7),
        isActionCandidate: sqlite3_column_int64(statement, 8) != 0,
        actionStatus: try optionalText(statement, column: 9).flatMap(
          RetrospectiveActionStatus.init(rawValue:)
        ),
        actionDestination: try optionalText(statement, column: 10).flatMap(
          RetrospectiveActionDestination.init(rawValue:)
        ),
        expectedEffect: try optionalText(statement, column: 11),
        synthesisID: try optionalText(statement, column: 12).flatMap(
          UUID.init(uuidString:)
        ),
        acceptedWorkItemID: try optionalText(statement, column: 13).flatMap(
          UUID.init(uuidString:)
        ),
        createdAt: date(statement, column: 14),
        updatedAt: date(statement, column: 15)
      )
    }
  }

  private func insertRetrospectiveNoteIfNeeded(_ note: RetrospectiveNote) throws {
    try withStatement(
      """
      INSERT OR IGNORE INTO retrospective_notes (
          id, product_id, sprint_id, work_item_id, profile_id, author_name,
          category, body, is_action_candidate, action_status, action_destination,
          expected_effect, synthesis_id, accepted_work_item_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(note.id.uuidString, to: 1, in: statement)
      try bind(note.productID.uuidString, to: 2, in: statement)
      try bind(note.sprintID.uuidString, to: 3, in: statement)
      try bindOptionalUUID(note.workItemID, to: 4, in: statement)
      try bindOptionalUUID(note.profileID, to: 5, in: statement)
      try bind(note.authorName, to: 6, in: statement)
      try bind(note.category.rawValue, to: 7, in: statement)
      try bind(note.body, to: 8, in: statement)
      try bind(note.isActionCandidate ? Int64(1) : Int64(0), to: 9, in: statement)
      try bindOptionalString(note.actionStatus?.rawValue, to: 10, in: statement)
      try bindOptionalString(note.actionDestination?.rawValue, to: 11, in: statement)
      try bindOptionalString(note.expectedEffect, to: 12, in: statement)
      try bindOptionalUUID(note.synthesisID, to: 13, in: statement)
      try bindOptionalUUID(note.acceptedWorkItemID, to: 14, in: statement)
      try bind(note.createdAt.timeIntervalSince1970, to: 15, in: statement)
      try bind(note.updatedAt.timeIntervalSince1970, to: 16, in: statement)
      try stepDone(statement)
    }
  }

  private func fetchRetrospectiveSynthesis(
    id: UUID
  ) throws -> RetrospectiveSynthesis {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, profile_id, status, codex_thread_id,
             codex_turn_id, error_message, created_at, updated_at
      FROM retrospective_syntheses
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("retrospective synthesis \(id)")
      }
      return try decodeRetrospectiveSynthesis(statement)
    }
  }

  private func fetchRetrospectiveSynthesis(
    sprintID: UUID
  ) throws -> RetrospectiveSynthesis? {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, profile_id, status, codex_thread_id,
             codex_turn_id, error_message, created_at, updated_at
      FROM retrospective_syntheses
      WHERE sprint_id = ?;
      """
    ) { statement in
      try bind(sprintID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRetrospectiveSynthesis(statement)
    }
  }

  private func decodeRetrospectiveSynthesis(
    _ statement: OpaquePointer
  ) throws -> RetrospectiveSynthesis {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let sprintID = UUID(uuidString: try text(statement, column: 2)),
      let status = RetrospectiveSynthesisStatus(
        rawValue: try text(statement, column: 4)
      )
    else {
      throw PersistenceError.corruptData("Invalid retrospective synthesis")
    }
    return RetrospectiveSynthesis(
      id: id,
      productID: productID,
      sprintID: sprintID,
      profileID: try optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
      status: status,
      codexThreadID: try optionalText(statement, column: 5),
      codexTurnID: try optionalText(statement, column: 6),
      errorMessage: try optionalText(statement, column: 7),
      createdAt: date(statement, column: 8),
      updatedAt: date(statement, column: 9)
    )
  }

  private func insertRetrospectiveSynthesisIfNeeded(
    _ synthesis: RetrospectiveSynthesis
  ) throws {
    try withStatement(
      """
      INSERT OR IGNORE INTO retrospective_syntheses (
          id, product_id, sprint_id, profile_id, status, codex_thread_id,
          codex_turn_id, error_message, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(synthesis.id.uuidString, to: 1, in: statement)
      try bind(synthesis.productID.uuidString, to: 2, in: statement)
      try bind(synthesis.sprintID.uuidString, to: 3, in: statement)
      try bindOptionalUUID(synthesis.profileID, to: 4, in: statement)
      try bind(synthesis.status.rawValue, to: 5, in: statement)
      try bindOptionalString(synthesis.codexThreadID, to: 6, in: statement)
      try bindOptionalString(synthesis.codexTurnID, to: 7, in: statement)
      try bindOptionalString(synthesis.errorMessage, to: 8, in: statement)
      try bind(synthesis.createdAt.timeIntervalSince1970, to: 9, in: statement)
      try bind(synthesis.updatedAt.timeIntervalSince1970, to: 10, in: statement)
      try stepDone(statement)
    }
  }

  private func updateRetrospectiveSynthesis(
    _ synthesis: RetrospectiveSynthesis
  ) throws {
    try withStatement(
      """
      UPDATE retrospective_syntheses
      SET profile_id = ?, status = ?, codex_thread_id = ?, codex_turn_id = ?,
          error_message = ?, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bindOptionalUUID(synthesis.profileID, to: 1, in: statement)
      try bind(synthesis.status.rawValue, to: 2, in: statement)
      try bindOptionalString(synthesis.codexThreadID, to: 3, in: statement)
      try bindOptionalString(synthesis.codexTurnID, to: 4, in: statement)
      try bindOptionalString(synthesis.errorMessage, to: 5, in: statement)
      try bind(synthesis.updatedAt.timeIntervalSince1970, to: 6, in: statement)
      try bind(synthesis.id.uuidString, to: 7, in: statement)
      try stepDone(statement)
    }
  }

  public func decideRetrospectiveAction(
    noteID: UUID,
    accept: Bool
  ) throws -> WorkItem? {
    let note = try fetchRetrospectiveNote(id: noteID)

    guard note.category == .suggestedAction else {
      return note.acceptedWorkItemID.flatMap { try? fetchWorkItem(id: $0) }
    }
    try validateRetrospectiveDecision(note)
    guard note.actionStatus == .proposed else {
      return note.acceptedWorkItemID.flatMap { try? fetchWorkItem(id: $0) }
    }

    if accept, note.actionDestination != .backlog {
      _ = try promoteRetrospectiveActionToWaysOfWorking(noteID: noteID)
      return nil
    }

    let now = Date()
    var createdItem: WorkItem?
    try transaction {
      if accept {
        createdItem = try insertWorkItem(
          productID: note.productID,
          title: note.body,
          type: .task,
          body:
            "Suggested by the Sprint retrospective. Refine this improvement before planning it.",
          acceptanceCriteria: [],
          priority: .normal
        )
        if let createdItem {
          _ = try insertEvent(
            productID: note.productID,
            workItemID: createdItem.id,
            kind: "work_item.created_from_retrospective",
            actor: "Product Owner",
            detail: note.id.uuidString
          )
        }
      }

      try withStatement(
        """
        UPDATE retrospective_notes
        SET action_status = ?, accepted_work_item_id = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(
          accept
            ? RetrospectiveActionStatus.accepted.rawValue
            : RetrospectiveActionStatus.dismissed.rawValue,
          to: 1,
          in: statement
        )
        try bindOptionalUUID(createdItem?.id, to: 2, in: statement)
        try bind(now.timeIntervalSince1970, to: 3, in: statement)
        try bind(noteID.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
    }
    return createdItem
  }

  public func promoteRetrospectiveActionToWaysOfWorking(
    noteID: UUID
  ) throws -> KnowledgePage {
    let note = try fetchRetrospectiveNote(id: noteID)
    guard note.category == .suggestedAction else {
      throw PersistenceError.corruptData(
        "Only suggested retrospective actions can become team practices."
      )
    }
    try validateRetrospectiveDecision(note)
    guard note.actionStatus == .proposed else {
      let pages = try seedKnowledgeBase(productID: note.productID)
      guard let existing = pages.first(where: { $0.slug == "ways-of-working" }) else {
        throw PersistenceError.corruptData("Ways of working page is missing.")
      }
      return existing
    }

    let pages = try seedKnowledgeBase(productID: note.productID)
    guard var page = pages.first(where: { $0.slug == "ways-of-working" }) else {
      throw PersistenceError.corruptData("Ways of working page is missing.")
    }
    let practice = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
    var body = page.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    let existingPractices = body.components(separatedBy: .newlines).compactMap {
      line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("- ") else { return nil }
      return String(trimmed.dropFirst(2))
    }
    let didAddPractice = !existingPractices.contains(where: {
      Self.practicesAreEquivalent($0, practice)
    })
    if didAddPractice {
      if !body.contains("## Adopted practices") {
        body += "\n\n## Adopted practices"
      }
      body += "\n- \(practice)"
    }

    let now = Date()
    if didAddPractice {
      page.bodyMarkdown = KnowledgeMarkdown.normalizedBody(body)
      page.verificationStatus = .verified
      page.updatedAt = now
    }
    try transaction {
      if didAddPractice {
        try withStatement(
          """
          UPDATE knowledge_pages
          SET body_markdown = ?, verification_status = ?, updated_at = ?
          WHERE id = ?;
          """
        ) { statement in
          try bind(page.bodyMarkdown, to: 1, in: statement)
          try bind(page.verificationStatus.rawValue, to: 2, in: statement)
          try bind(now.timeIntervalSince1970, to: 3, in: statement)
          try bind(page.id.uuidString, to: 4, in: statement)
          try stepDone(statement)
        }
        try insertKnowledgeRevision(
          pageID: page.id,
          bodyMarkdown: page.bodyMarkdown,
          authorName: "Product Owner",
          changeSummary: "Adopted a Sprint retrospective practice",
          createdAt: now
        )
      }
      try withStatement(
        """
        UPDATE retrospective_notes
        SET action_status = ?, accepted_work_item_id = NULL, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(RetrospectiveActionStatus.accepted.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(noteID.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: note.productID,
        workItemID: note.workItemID,
        kind: "retrospective.action_promoted_to_practice",
        actor: "Product Owner",
        detail: practice
      )
    }
    return page
  }

  private func validateRetrospectiveDecision(_ note: RetrospectiveNote) throws {
    let sprint = try fetchSprint(id: note.sprintID)
    guard sprint.productID == note.productID else {
      throw PersistenceError.corruptData(
        "The retrospective action does not belong to its sprint."
      )
    }
    guard sprint.state == .completed else {
      throw PersistenceError.corruptData(
        "Retrospective actions can only be accepted or dismissed after the sprint is complete."
      )
    }
    guard sprint.retrospectiveConcludedAt == nil else {
      throw PersistenceError.corruptData(
        "This retrospective has already been concluded."
      )
    }
  }

  private static func practicesAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
    let lhsTokens = practiceTokens(lhs)
    let rhsTokens = practiceTokens(rhs)
    guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
      return lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare(
          rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        ) == .orderedSame
    }
    if lhsTokens == rhsTokens { return true }
    let overlap = lhsTokens.intersection(rhsTokens)
    let union = lhsTokens.union(rhsTokens)
    return overlap.count >= 4
      && Double(overlap.count) / Double(union.count) >= 0.8
  }

  private static func practiceTokens(_ value: String) -> Set<String> {
    let ignored = Set([
      "a", "an", "and", "as", "at", "before", "by", "for", "in", "of", "on", "or",
      "the", "to", "with",
    ])
    return Set(
      value.lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { $0.count >= 2 && !ignored.contains($0) }
    )
  }

  @discardableResult
  public func seedKnowledgeBase(productID: UUID) throws -> [KnowledgePage] {
    let existing = try fetchKnowledgePages(productID: productID)
    if !existing.isEmpty {
      var pages = existing
      try transaction {
        let operations: KnowledgePage
        if let existingOperations = pages.first(where: { $0.slug == "operations" }) {
          operations = existingOperations
        } else {
          let page = KnowledgePage(
            productID: productID,
            title: "Operations",
            slug: "operations",
            kind: .section,
            sortOrder: (pages.filter { $0.parentID == nil }.map(\.sortOrder).max() ?? -1) + 1
          )
          try insertKnowledgePage(
            page,
            authorName: "StoryPointless",
            changeSummary: "Backfilled canonical Operations section"
          )
          pages.append(page)
          operations = page
        }

        let missingChildren: [(title: String, slug: String, body: String, summary: String)] = [
          (
            "Environments",
            "environments",
            "",
            "Backfilled mandatory Environments page"
          ),
          (
            "Ways of working",
            "ways-of-working",
            """
            Shared delivery practices adopted by the Product Owner live here. Every team member receives this page as part of their working context.

            ## Adopted practices
            """,
            "Created inherited team-practices page"
          ),
        ]
        for child in missingChildren where !pages.contains(where: { $0.slug == child.slug }) {
          let page = KnowledgePage(
            productID: productID,
            parentID: operations.id,
            title: child.title,
            slug: child.slug,
            bodyMarkdown: child.body,
            sortOrder:
              (pages.filter { $0.parentID == operations.id }.map(\.sortOrder).max() ?? -1) + 1
          )
          try insertKnowledgePage(
            page,
            authorName: "StoryPointless",
            changeSummary: child.summary
          )
          pages.append(page)
        }
      }
      return try fetchKnowledgePages(productID: productID)
    }

    let now = Date()
    let rootDefinitions: [(String, String, KnowledgePageKind)] = [
      ("Home", "home", .page),
      ("Product", "product", .section),
      ("Features", "features", .section),
      ("Technical", "technical", .section),
      ("Operations", "operations", .section),
      ("Decisions", "decisions", .section),
      ("Known limitations", "known-limitations", .page),
      ("Delivery history", "delivery-history", .section),
    ]
    var roots: [String: KnowledgePage] = [:]

    try transaction {
      for (index, definition) in rootDefinitions.enumerated() {
        let body =
          definition.1 == "home"
          ? "Verified product and delivery knowledge lives here."
          : ""
        let page = KnowledgePage(
          productID: productID,
          title: definition.0,
          slug: definition.1,
          bodyMarkdown: body,
          kind: definition.2,
          sortOrder: index,
          createdAt: now,
          updatedAt: now
        )
        try insertKnowledgePage(page, authorName: "StoryPointless", changeSummary: "Created page")
        roots[definition.1] = page
      }

      let children: [(String, String, String)] = [
        ("product", "Overview", "overview"),
        ("product", "Users & journeys", "users-and-journeys"),
        ("product", "Product principles", "product-principles"),
        ("product", "Glossary", "glossary"),
        ("technical", "Architecture", "architecture"),
        ("technical", "Components & data", "components-and-data"),
        ("technical", "Integrations", "integrations"),
        ("operations", "Environments", "environments"),
        ("operations", "Runbooks", "runbooks"),
        ("operations", "Release & rollback", "release-and-rollback"),
        ("operations", "Ways of working", "ways-of-working"),
      ]
      var childOrder: [String: Int] = [:]
      for child in children {
        guard let parent = roots[child.0] else { continue }
        let order = childOrder[child.0, default: 0]
        childOrder[child.0] = order + 1
        let page = KnowledgePage(
          productID: productID,
          parentID: parent.id,
          title: child.1,
          slug: child.2,
          bodyMarkdown: child.2 == "ways-of-working"
            ? """
              Shared delivery practices adopted by the Product Owner live here. Every team member receives this page as part of their working context.

              ## Adopted practices
              """
            : "",
          sortOrder: order,
          createdAt: now,
          updatedAt: now
        )
        try insertKnowledgePage(page, authorName: "StoryPointless", changeSummary: "Created page")
      }
    }
    return try fetchKnowledgePages(productID: productID)
  }

  public func fetchKnowledgePages(productID: UUID) throws -> [KnowledgePage] {
    try withStatement(
      """
      SELECT id, product_id, parent_id, title, slug, body_markdown, kind,
             verification_status, sort_order, source_work_item_id, created_at, updated_at
      FROM knowledge_pages
      WHERE product_id = ?
      ORDER BY sort_order ASC, title COLLATE NOCASE ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var pages: [KnowledgePage] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        pages.append(try decodeKnowledgePage(statement))
      }
      return pages
    }
  }

  public func setAgentRunKnowledgeContext(runID: UUID, pageIDs: [UUID]) throws {
    try transaction {
      try withStatement(
        "DELETE FROM agent_run_knowledge_pages WHERE run_id = ?;"
      ) { statement in
        try bind(runID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      for pageID in Set(pageIDs) {
        try withStatement(
          """
          INSERT INTO agent_run_knowledge_pages (run_id, page_id) VALUES (?, ?);
          """
        ) { statement in
          try bind(runID.uuidString, to: 1, in: statement)
          try bind(pageID.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func fetchAgentRunKnowledgeContext(
    productID: UUID
  ) throws -> [AgentRunKnowledgePage] {
    try withStatement(
      """
      SELECT context.run_id, context.page_id
      FROM agent_run_knowledge_pages AS context
      JOIN agent_runs AS run ON run.id = context.run_id
      WHERE run.product_id = ?
      ORDER BY run.created_at ASC, context.page_id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var links: [AgentRunKnowledgePage] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let runID = UUID(uuidString: try text(statement, column: 0)),
          let pageID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid agent knowledge context")
        }
        links.append(AgentRunKnowledgePage(runID: runID, pageID: pageID))
      }
      return links
    }
  }

  public func setAgentRunKnowledgeDestinations(runID: UUID, pageIDs: [UUID]) throws {
    try transaction {
      try withStatement(
        "DELETE FROM agent_run_knowledge_destinations WHERE run_id = ?;"
      ) { statement in
        try bind(runID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      for pageID in Set(pageIDs) {
        try withStatement(
          """
          INSERT INTO agent_run_knowledge_destinations (run_id, page_id) VALUES (?, ?);
          """
        ) { statement in
          try bind(runID.uuidString, to: 1, in: statement)
          try bind(pageID.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func fetchAgentRunKnowledgeDestinations(
    productID: UUID
  ) throws -> [AgentRunKnowledgeDestination] {
    try withStatement(
      """
      SELECT destination.run_id, destination.page_id
      FROM agent_run_knowledge_destinations AS destination
      JOIN agent_runs AS run ON run.id = destination.run_id
      WHERE run.product_id = ?
      ORDER BY run.created_at ASC, destination.page_id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var links: [AgentRunKnowledgeDestination] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let runID = UUID(uuidString: try text(statement, column: 0)),
          let pageID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid agent knowledge destination")
        }
        links.append(AgentRunKnowledgeDestination(runID: runID, pageID: pageID))
      }
      return links
    }
  }

  public func fetchKnowledgePageRevisions(pageID: UUID) throws -> [KnowledgePageRevision] {
    try withStatement(
      """
      SELECT id, page_id, version, body_markdown, author_name, change_summary, created_at
      FROM knowledge_page_revisions
      WHERE page_id = ?
      ORDER BY version DESC;
      """
    ) { statement in
      try bind(pageID.uuidString, to: 1, in: statement)
      var revisions: [KnowledgePageRevision] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedPageID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid knowledge page revision")
        }
        revisions.append(
          KnowledgePageRevision(
            id: id,
            pageID: storedPageID,
            version: Int(sqlite3_column_int64(statement, 2)),
            bodyMarkdown: try text(statement, column: 3),
            authorName: try text(statement, column: 4),
            changeSummary: try text(statement, column: 5),
            createdAt: date(statement, column: 6)
          )
        )
      }
      return revisions
    }
  }

  public func createKnowledgePage(
    productID: UUID,
    parentID: UUID?,
    title: String
  ) throws -> KnowledgePage {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw PersistenceError.corruptData("A knowledge page needs a title")
    }
    let baseSlug = trimmedTitle
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .joined(separator: "-")
    let siblingSlugs = try fetchKnowledgePages(productID: productID)
      .filter { $0.parentID == parentID }
      .map(\.slug)
    var slug = baseSlug.isEmpty ? "page" : baseSlug
    var suffix = 2
    while siblingSlugs.contains(slug) {
      slug = "\(baseSlug)-\(suffix)"
      suffix += 1
    }
    let sortOrder = try withStatement(
      """
      SELECT COALESCE(MAX(sort_order), -1) + 1
      FROM knowledge_pages
      WHERE product_id = ?
        AND ((parent_id IS NULL AND ? IS NULL) OR parent_id = ?);
      """
    ) { statement -> Int in
      try bind(productID.uuidString, to: 1, in: statement)
      try bindOptionalUUID(parentID, to: 2, in: statement)
      try bindOptionalUUID(parentID, to: 3, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
    let page = KnowledgePage(
      productID: productID,
      parentID: parentID,
      title: trimmedTitle,
      slug: slug,
      bodyMarkdown: "",
      sortOrder: sortOrder
    )
    try insertKnowledgePage(page, authorName: "Me", changeSummary: "Created page")
    return page
  }

  public func updateKnowledgePage(
    id: UUID,
    title: String,
    bodyMarkdown: String,
    authorName: String,
    changeSummary: String
  ) throws -> KnowledgePage {
    var page = try fetchKnowledgePage(id: id)
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw PersistenceError.corruptData("A knowledge page needs a title")
    }
    let now = Date()
    page.title = trimmedTitle
    page.bodyMarkdown = KnowledgeMarkdown.normalizedBody(bodyMarkdown)
    page.verificationStatus = .verified
    page.updatedAt = now
    try transaction {
      try withStatement(
        """
        UPDATE knowledge_pages
        SET title = ?, body_markdown = ?, verification_status = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(page.title, to: 1, in: statement)
        try bind(page.bodyMarkdown, to: 2, in: statement)
        try bind(page.verificationStatus.rawValue, to: 3, in: statement)
        try bind(now.timeIntervalSince1970, to: 4, in: statement)
        try bind(id.uuidString, to: 5, in: statement)
        try stepDone(statement)
      }
      try insertKnowledgeRevision(
        pageID: id,
        bodyMarkdown: page.bodyMarkdown,
        authorName: authorName,
        changeSummary: changeSummary,
        createdAt: now
      )
    }
    return page
  }

  public func upsertDeliveryNote(
    productID: UUID,
    sprint: Sprint,
    item: WorkItem,
    bodyMarkdown: String,
    authorName: String
  ) throws -> KnowledgePage {
    _ = try seedKnowledgeBase(productID: productID)
    let pages = try fetchKnowledgePages(productID: productID)
    guard let history = pages.first(where: { $0.parentID == nil && $0.slug == "delivery-history" })
    else {
      throw PersistenceError.corruptData("Delivery history is missing")
    }

    var sprintPage = pages.first {
      $0.parentID == history.id && $0.slug == "sprint-\(sprint.number)"
    }
    if sprintPage == nil {
      let created = KnowledgePage(
        productID: productID,
        parentID: history.id,
        title: "Sprint \(sprint.number)",
        slug: "sprint-\(sprint.number)",
        kind: .section,
        sortOrder: sprint.number
      )
      try insertKnowledgePage(
        created,
        authorName: "StoryPointless",
        changeSummary: "Created sprint delivery section"
      )
      sprintPage = created
    }
    guard let sprintPage else {
      throw PersistenceError.corruptData("Could not create sprint delivery section")
    }

    if let existing = try fetchKnowledgePages(productID: productID).first(where: {
      $0.sourceWorkItemID == item.id && $0.kind == .deliveryNote
    }) {
      var updated = existing
      updated.bodyMarkdown = KnowledgeMarkdown.normalizedBody(bodyMarkdown)
      updated.verificationStatus = .proposed
      updated.updatedAt = Date()
      try withStatement(
        """
        UPDATE knowledge_pages
        SET body_markdown = ?, verification_status = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(updated.bodyMarkdown, to: 1, in: statement)
        try bind(updated.verificationStatus.rawValue, to: 2, in: statement)
        try bind(updated.updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(updated.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      try insertKnowledgeRevision(
        pageID: updated.id,
        bodyMarkdown: updated.bodyMarkdown,
        authorName: authorName,
        changeSummary: "Updated delivery note"
      )
      return updated
    }

    let page = KnowledgePage(
      productID: productID,
      parentID: sprintPage.id,
      title: "\(item.key) · \(item.title)",
      slug: item.key.lowercased(),
      bodyMarkdown: KnowledgeMarkdown.normalizedBody(bodyMarkdown),
      kind: .deliveryNote,
      verificationStatus: .proposed,
      sortOrder: item.rank,
      sourceWorkItemID: item.id
    )
    try insertKnowledgePage(page, authorName: authorName, changeSummary: "Proposed delivery note")
    return page
  }

  public func verifyDeliveryNote(workItemID: UUID, authorName: String) throws {
    guard let page = try withStatement(
      """
      SELECT id, product_id, parent_id, title, slug, body_markdown, kind,
             verification_status, sort_order, source_work_item_id, created_at, updated_at
      FROM knowledge_pages
      WHERE source_work_item_id = ? AND kind = 'delivery_note'
      LIMIT 1;
      """
    , operation: { statement -> KnowledgePage? in
      try bind(workItemID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeKnowledgePage(statement)
    }) else { return }

    let now = Date()
    try withStatement(
      """
      UPDATE knowledge_pages SET verification_status = 'verified', updated_at = ? WHERE id = ?;
      """
    ) { statement in
      try bind(now.timeIntervalSince1970, to: 1, in: statement)
      try bind(page.id.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
    try insertKnowledgeRevision(
      pageID: page.id,
      bodyMarkdown: page.bodyMarkdown,
      authorName: authorName,
      changeSummary: "Verified during Tech Lead review",
      createdAt: now
    )
  }

  private static func migrate(database: OpaquePointer) throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS products (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          vision TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS work_items (
          id TEXT PRIMARY KEY,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          key_number INTEGER NOT NULL,
          item_key TEXT NOT NULL,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          acceptance_criteria_json TEXT NOT NULL,
          state TEXT NOT NULL,
          priority INTEGER NOT NULL,
          version INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(product_id, key_number),
          UNIQUE(product_id, item_key)
      );

      CREATE TABLE IF NOT EXISTS ticket_comments (
          id TEXT PRIMARY KEY,
          work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
          author_kind TEXT NOT NULL,
          author_name TEXT NOT NULL,
          body TEXT NOT NULL,
          created_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS agent_profiles (
          id TEXT PRIMARY KEY,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          role TEXT NOT NULL,
          model TEXT NOT NULL,
          reasoning_effort TEXT NOT NULL,
          parallelism_limit INTEGER,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS agent_runs (
          id TEXT PRIMARY KEY,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
          profile_id TEXT NOT NULL REFERENCES agent_profiles(id),
          status TEXT NOT NULL,
          codex_thread_id TEXT,
          worktree_path TEXT,
          ticket_budget_used REAL NOT NULL DEFAULT 0,
          context_used_tokens INTEGER,
          context_window_tokens INTEGER,
          compaction_count INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS decision_records (
          id TEXT PRIMARY KEY,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
          title TEXT NOT NULL,
          context TEXT NOT NULL,
          decision TEXT NOT NULL,
          alternatives_json TEXT NOT NULL,
          consequences TEXT NOT NULL,
          applicable_commit TEXT,
          status TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS knowledge_claims (
          id TEXT PRIMARY KEY,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
          statement TEXT NOT NULL,
          provenance_json TEXT NOT NULL,
          verification_state TEXT NOT NULL,
          applicable_commit TEXT,
          invalidated_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS activity_events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT NOT NULL UNIQUE,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          work_item_id TEXT REFERENCES work_items(id) ON DELETE CASCADE,
          kind TEXT NOT NULL,
          actor TEXT NOT NULL,
          detail TEXT NOT NULL,
          created_at REAL NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_work_items_product_state
          ON work_items(product_id, state);
      CREATE INDEX IF NOT EXISTS idx_comments_work_item
          ON ticket_comments(work_item_id, created_at);
      CREATE INDEX IF NOT EXISTS idx_activity_product_sequence
          ON activity_events(product_id, sequence DESC);

      INSERT OR IGNORE INTO schema_migrations (version, applied_at)
      VALUES (1, unixepoch());
      """,
      database: database
    )

    if try !migrationApplied(version: 2, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE sprints (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            sprint_number INTEGER NOT NULL,
            goal TEXT NOT NULL,
            state TEXT NOT NULL,
            token_budget_limit INTEGER,
            concurrency_limit INTEGER NOT NULL,
            plan_version INTEGER NOT NULL,
            started_at REAL,
            completed_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(product_id, sprint_number)
        );

        CREATE TABLE sprint_items (
            id TEXT PRIMARY KEY,
            sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
            work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE RESTRICT,
            implementer_profile_id TEXT NOT NULL REFERENCES agent_profiles(id),
            reviewer_profile_id TEXT REFERENCES agent_profiles(id),
            estimated_tokens INTEGER NOT NULL,
            frozen_work_item_version INTEGER,
            frozen_title TEXT,
            frozen_body TEXT,
            frozen_acceptance_criteria_json TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(sprint_id, work_item_id)
        );

        ALTER TABLE agent_runs ADD COLUMN sprint_id TEXT REFERENCES sprints(id);
        ALTER TABLE agent_runs ADD COLUMN sprint_item_id TEXT REFERENCES sprint_items(id);

        CREATE UNIQUE INDEX idx_sprints_one_active
            ON sprints(product_id) WHERE state = 'active';
        CREATE UNIQUE INDEX idx_sprints_one_draft
            ON sprints(product_id) WHERE state = 'draft';
        CREATE INDEX idx_sprint_items_sprint
            ON sprint_items(sprint_id, created_at);
        CREATE UNIQUE INDEX idx_agent_runs_sprint_item_profile
            ON agent_runs(sprint_item_id, profile_id)
            WHERE sprint_item_id IS NOT NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (2, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 3, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE suggestion_sessions (
          id TEXT PRIMARY KEY,
          product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
          status TEXT NOT NULL,
          codex_thread_id TEXT,
          codex_turn_id TEXT,
          error_message TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE ticket_suggestions (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES suggestion_sessions(id) ON DELETE CASCADE,
          reference TEXT NOT NULL,
          position INTEGER NOT NULL,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          acceptance_criteria_json TEXT NOT NULL,
          suggested_role TEXT NOT NULL,
          priority INTEGER NOT NULL,
          rationale TEXT NOT NULL,
          status TEXT NOT NULL,
          accepted_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(session_id, reference),
          UNIQUE(session_id, position)
      );

      CREATE TABLE suggestion_dependencies (
          suggestion_id TEXT NOT NULL REFERENCES ticket_suggestions(id) ON DELETE CASCADE,
          depends_on_suggestion_id TEXT NOT NULL REFERENCES ticket_suggestions(id) ON DELETE CASCADE,
          PRIMARY KEY (suggestion_id, depends_on_suggestion_id),
          CHECK (suggestion_id <> depends_on_suggestion_id)
      );

      CREATE TABLE work_item_dependencies (
          work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
          depends_on_work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
          source TEXT NOT NULL,
          created_at REAL NOT NULL,
          PRIMARY KEY (work_item_id, depends_on_work_item_id),
          CHECK (work_item_id <> depends_on_work_item_id)
      );

      CREATE UNIQUE INDEX idx_suggestion_sessions_one_generating
          ON suggestion_sessions(product_id) WHERE status = 'generating';
      CREATE INDEX idx_suggestion_sessions_product_created
          ON suggestion_sessions(product_id, created_at DESC);
      CREATE INDEX idx_ticket_suggestions_session_position
          ON ticket_suggestions(session_id, position);

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (3, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 4, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

      ALTER TABLE products ADD COLUMN instructions TEXT NOT NULL DEFAULT '';
      ALTER TABLE agent_profiles ADD COLUMN custom_instructions TEXT;

      UPDATE agent_profiles
      SET model = CASE role
            WHEN 'business_analyst' THEN 'gpt-5.6-terra'
            WHEN 'ux_designer' THEN 'gpt-5.6-sol'
            WHEN 'lead' THEN 'gpt-5.6-sol'
            WHEN 'implementer' THEN 'gpt-5.6-terra'
            WHEN 'frontend_engineer' THEN 'gpt-5.6-terra'
            WHEN 'backend_engineer' THEN 'gpt-5.6-sol'
            WHEN 'reviewer' THEN 'gpt-5.6-sol'
            WHEN 'quality_assurance' THEN 'gpt-5.6-sol'
            WHEN 'knowledge_curator' THEN 'gpt-5.6-terra'
            ELSE model
          END,
          reasoning_effort = CASE role
            WHEN 'lead' THEN 'high'
            WHEN 'backend_engineer' THEN 'high'
            WHEN 'reviewer' THEN 'high'
            WHEN 'quality_assurance' THEN 'high'
            ELSE 'medium'
          END
      WHERE model = 'default';

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (4, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 5, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

      ALTER TABLE agent_profiles ADD COLUMN is_builtin INTEGER NOT NULL DEFAULT 1;
      ALTER TABLE agent_profiles ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1;

      CREATE UNIQUE INDEX idx_agent_profiles_active_name
          ON agent_profiles(product_id, lower(name)) WHERE is_active = 1;

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (5, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 6, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

      UPDATE agent_profiles
      SET is_active = 0, updated_at = unixepoch()
      WHERE is_builtin = 1
        AND role IN ('frontend_engineer', 'backend_engineer', 'reviewer')
        AND NOT EXISTS (
          SELECT 1 FROM agent_runs
          WHERE profile_id = agent_profiles.id
            AND status IN ('queued', 'running', 'awaiting_owner')
        )
        AND NOT EXISTS (
          SELECT 1
          FROM sprint_items si
          JOIN sprints s ON s.id = si.sprint_id
          WHERE (si.implementer_profile_id = agent_profiles.id
                 OR si.reviewer_profile_id = agent_profiles.id)
            AND s.state IN ('draft', 'active')
        );

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (6, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 7, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

      ALTER TABLE work_items ADD COLUMN ticket_type TEXT NOT NULL DEFAULT 'story';
      ALTER TABLE ticket_suggestions ADD COLUMN ticket_type TEXT NOT NULL DEFAULT 'story';

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (7, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 8, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

      UPDATE work_items
      SET ticket_type = 'task'
      WHERE ticket_type = 'story'
        AND id IN (
          SELECT accepted_work_item_id
          FROM ticket_suggestions
          WHERE accepted_work_item_id IS NOT NULL
            AND suggested_role IN ('business_analyst', 'ux_designer')
        );

      UPDATE ticket_suggestions
      SET ticket_type = 'task'
      WHERE ticket_type = 'story'
        AND suggested_role IN ('business_analyst', 'ux_designer');

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (8, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 9, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

      ALTER TABLE work_items ADD COLUMN rank INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE work_items ADD COLUMN custom_fields_json TEXT NOT NULL DEFAULT '{}';

      UPDATE work_items SET rank = key_number * 1000 WHERE rank = 0;

      CREATE INDEX idx_work_items_product_rank
          ON work_items(product_id, rank, key_number);

      INSERT INTO schema_migrations (version, applied_at)
      VALUES (9, unixepoch());

        COMMIT;
      """,
        database: database
      )
    }

    if try !migrationApplied(version: 10, database: database) {
      try execute(
        """
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE;

        CREATE TABLE sprint_items_v10 (
            id TEXT PRIMARY KEY,
            sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
            work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE RESTRICT,
            implementer_profile_id TEXT REFERENCES agent_profiles(id),
            reviewer_profile_id TEXT REFERENCES agent_profiles(id),
            estimated_tokens INTEGER NOT NULL,
            frozen_work_item_version INTEGER,
            frozen_title TEXT,
            frozen_body TEXT,
            frozen_acceptance_criteria_json TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(sprint_id, work_item_id)
        );

        INSERT INTO sprint_items_v10 (
            id, sprint_id, work_item_id, implementer_profile_id,
            reviewer_profile_id, estimated_tokens, frozen_work_item_version,
            frozen_title, frozen_body, frozen_acceptance_criteria_json,
            created_at, updated_at
        )
        SELECT id, sprint_id, work_item_id,
               CASE WHEN sprint_id IN (
                 SELECT id FROM sprints WHERE state = 'draft'
               ) THEN NULL ELSE implementer_profile_id END,
               CASE WHEN sprint_id IN (
                 SELECT id FROM sprints WHERE state = 'draft'
               ) THEN NULL ELSE reviewer_profile_id END,
               estimated_tokens, frozen_work_item_version,
               frozen_title, frozen_body, frozen_acceptance_criteria_json,
               created_at, updated_at
        FROM sprint_items;

        DROP TABLE sprint_items;
        ALTER TABLE sprint_items_v10 RENAME TO sprint_items;
        CREATE INDEX idx_sprint_items_sprint
            ON sprint_items(sprint_id, created_at);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (10, unixepoch());

        COMMIT;
        PRAGMA foreign_keys = ON;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 11, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE work_items
        SET item_key = 'T-' || key_number
        WHERE item_key = 'SP-' || key_number;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (11, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 12, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE agent_profiles
        SET name = 'Tech Lead', updated_at = unixepoch()
        WHERE role = 'lead'
          AND is_builtin = 1
          AND name = 'Lead'
          AND NOT EXISTS (
            SELECT 1
            FROM agent_profiles AS existing
            WHERE existing.product_id = agent_profiles.product_id
              AND existing.id <> agent_profiles.id
              AND existing.is_active = 1
              AND lower(existing.name) = lower('Tech Lead')
          );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (12, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 13, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE work_items
        ADD COLUMN owner_profile_id TEXT REFERENCES agent_profiles(id);

        UPDATE work_items
        SET owner_profile_id = (
          SELECT si.implementer_profile_id
          FROM sprint_items AS si
          JOIN sprints AS s ON s.id = si.sprint_id
          WHERE si.work_item_id = work_items.id
            AND si.implementer_profile_id IS NOT NULL
          ORDER BY s.sprint_number DESC
          LIMIT 1
        )
        WHERE owner_profile_id IS NULL
          AND EXISTS (
            SELECT 1
            FROM sprint_items AS si
            WHERE si.work_item_id = work_items.id
              AND si.implementer_profile_id IS NOT NULL
          );

        UPDATE work_items
        SET owner_profile_id = (
          SELECT ap.id
          FROM ticket_suggestions AS ts
          JOIN agent_profiles AS ap
            ON ap.product_id = work_items.product_id
           AND ap.role = ts.suggested_role
           AND ap.is_active = 1
          WHERE ts.accepted_work_item_id = work_items.id
          ORDER BY ap.is_builtin DESC, ap.created_at ASC
          LIMIT 1
        )
        WHERE owner_profile_id IS NULL
          AND EXISTS (
            SELECT 1
            FROM ticket_suggestions AS ts
            JOIN agent_profiles AS ap
              ON ap.product_id = work_items.product_id
             AND ap.role = ts.suggested_role
             AND ap.is_active = 1
            WHERE ts.accepted_work_item_id = work_items.id
          );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (13, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 14, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE suggestion_existing_dependencies (
            suggestion_id TEXT NOT NULL REFERENCES ticket_suggestions(id) ON DELETE CASCADE,
            depends_on_work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE RESTRICT,
            PRIMARY KEY(suggestion_id, depends_on_work_item_id)
        );

        CREATE INDEX idx_suggestion_existing_dependencies_item
            ON suggestion_existing_dependencies(depends_on_work_item_id);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (14, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 15, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        DROP INDEX IF EXISTS idx_agent_runs_sprint_item_profile;

        CREATE INDEX idx_agent_runs_sprint_item_created
            ON agent_runs(sprint_item_id, created_at)
            WHERE sprint_item_id IS NOT NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (15, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 16, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE retrospective_notes (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
            work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
            profile_id TEXT REFERENCES agent_profiles(id) ON DELETE SET NULL,
            author_name TEXT NOT NULL,
            category TEXT NOT NULL,
            body TEXT NOT NULL,
            action_status TEXT,
            accepted_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE UNIQUE INDEX idx_retrospective_note_evidence
            ON retrospective_notes(
              sprint_id, work_item_id, profile_id, category, body
            );
        CREATE INDEX idx_retrospective_notes_sprint
            ON retrospective_notes(sprint_id, category, created_at);

        CREATE TABLE knowledge_pages (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            parent_id TEXT REFERENCES knowledge_pages(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            slug TEXT NOT NULL,
            body_markdown TEXT NOT NULL,
            kind TEXT NOT NULL,
            verification_status TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            source_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE UNIQUE INDEX idx_knowledge_page_sibling_slug
            ON knowledge_pages(product_id, IFNULL(parent_id, ''), slug);
        CREATE INDEX idx_knowledge_pages_product_parent
            ON knowledge_pages(product_id, parent_id, sort_order);

        CREATE TABLE knowledge_page_revisions (
            id TEXT PRIMARY KEY,
            page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            body_markdown TEXT NOT NULL,
            author_name TEXT NOT NULL,
            change_summary TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(page_id, version)
        );

        CREATE TABLE knowledge_page_links (
            source_page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
            target_page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
            PRIMARY KEY(source_page_id, target_page_id)
        );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (16, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 17, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE agent_run_knowledge_pages (
            run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
            page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
            PRIMARY KEY(run_id, page_id)
        );

        CREATE INDEX idx_agent_run_knowledge_page
            ON agent_run_knowledge_pages(page_id, run_id);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (17, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 18, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE candidate_revisions (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
            sprint_item_id TEXT NOT NULL REFERENCES sprint_items(id) ON DELETE CASCADE,
            work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
            implementation_run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            branch_name TEXT NOT NULL,
            base_sha TEXT NOT NULL,
            head_sha TEXT NOT NULL,
            integrated_sha TEXT,
            worktree_path TEXT NOT NULL,
            integration_worktree_path TEXT,
            status TEXT NOT NULL,
            commit_count INTEGER NOT NULL,
            execution_result_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(work_item_id, version)
        );

        CREATE INDEX idx_candidate_revisions_sprint_status
            ON candidate_revisions(sprint_id, status, created_at);
        CREATE INDEX idx_candidate_revisions_work_item
            ON candidate_revisions(work_item_id, version DESC);

        CREATE TABLE knowledge_page_proposals (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
            work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
            candidate_revision_id TEXT NOT NULL
              REFERENCES candidate_revisions(id) ON DELETE CASCADE,
            operation TEXT NOT NULL,
            target_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
            parent_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
            title TEXT NOT NULL,
            proposed_body_markdown TEXT NOT NULL,
            rationale TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            CHECK (
              (operation = 'update' AND target_page_id IS NOT NULL AND parent_page_id IS NULL)
              OR
              (operation = 'create' AND target_page_id IS NULL AND parent_page_id IS NOT NULL)
            )
        );

        CREATE INDEX idx_knowledge_page_proposals_candidate
            ON knowledge_page_proposals(candidate_revision_id, status, created_at);
        CREATE INDEX idx_knowledge_page_proposals_product
            ON knowledge_page_proposals(product_id, status, created_at);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (18, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 19, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE knowledge_page_proposals
        ADD COLUMN base_page_title TEXT;
        ALTER TABLE knowledge_page_proposals
        ADD COLUMN base_page_body_markdown TEXT;
        ALTER TABLE knowledge_page_proposals
        ADD COLUMN base_page_updated_at REAL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (19, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 20, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE knowledge_pages
        SET body_markdown =
          CASE
            WHEN instr(body_markdown, char(10)) = 0 THEN ''
            ELSE ltrim(
              substr(body_markdown, instr(body_markdown, char(10)) + 1),
              char(10) || char(13)
            )
          END
        WHERE body_markdown GLOB '# *';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (20, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 21, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE agent_runs ADD COLUMN turn_started_at REAL;
        ALTER TABLE agent_runs ADD COLUMN last_activity_at REAL;
        ALTER TABLE agent_runs ADD COLUMN last_activity_text TEXT;
        ALTER TABLE agent_runs ADD COLUMN last_activity_kind TEXT;

        UPDATE agent_runs
        SET last_activity_at = updated_at
        WHERE status = 'running' AND last_activity_at IS NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (21, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 22, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE work_items
        SET item_key = 'T' || key_number
        WHERE item_key = 'T-' || key_number;

        UPDATE knowledge_pages
        SET title = 'T' || substr(title, 3)
        WHERE title GLOB 'T-[0-9]*';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (22, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 23, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE agent_runs
        ADD COLUMN active_duration_seconds REAL NOT NULL DEFAULT 0;

        UPDATE agent_runs
        SET active_duration_seconds = MAX(
              0,
              COALESCE(last_activity_at, updated_at) - turn_started_at
            )
        WHERE status != 'running' AND turn_started_at IS NOT NULL;

        UPDATE agent_runs
        SET turn_started_at = NULL
        WHERE status != 'running';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (23, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 24, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE sprints
        ADD COLUMN retrospective_concluded_at REAL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (24, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 25, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE retrospective_notes
        ADD COLUMN action_destination TEXT;

        UPDATE retrospective_notes
        SET action_destination = 'team_practice'
        WHERE category = 'suggested_action'
          AND action_destination IS NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (25, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 26, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE epics (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            goal TEXT NOT NULL,
            success_criteria_json TEXT NOT NULL,
            constraints TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        ALTER TABLE work_items
        ADD COLUMN epic_id TEXT REFERENCES epics(id) ON DELETE SET NULL;

        ALTER TABLE suggestion_sessions
        ADD COLUMN epic_id TEXT REFERENCES epics(id) ON DELETE SET NULL;

        CREATE INDEX idx_epics_product_status
            ON epics(product_id, status, created_at);
        CREATE INDEX idx_work_items_epic
            ON work_items(epic_id, rank);
        CREATE INDEX idx_suggestion_sessions_epic
            ON suggestion_sessions(epic_id, created_at DESC);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (26, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 27, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE epics
        ADD COLUMN rank INTEGER NOT NULL DEFAULT 0;

        UPDATE epics
        SET rank = rowid * 1000
        WHERE rank = 0;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (27, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 28, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE work_items
        SET epic_id = NULL,
            version = version + 1,
            updated_at = unixepoch()
        WHERE state NOT IN ('released', 'cancelled')
          AND epic_id IN (
            SELECT id
            FROM epics
            WHERE status = 'archived'
          );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (28, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 29, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE epic_planning_conversations (
            epic_id TEXT PRIMARY KEY REFERENCES epics(id) ON DELETE CASCADE,
            snapshot_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (29, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 30, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE epics
        SET status = 'active',
            updated_at = unixepoch()
        WHERE status = 'draft';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (30, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 31, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE ticket_suggestions
        SET reference = '__proposal__' || id;

        UPDATE ticket_suggestions
        SET reference = 'S' || CAST(position + 1 AS TEXT);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (31, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 32, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE suggestion_sessions
        ADD COLUMN source_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL;

        CREATE UNIQUE INDEX idx_suggestion_sessions_source_work_item
            ON suggestion_sessions(source_work_item_id)
            WHERE source_work_item_id IS NOT NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (32, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 33, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE ticket_suggestions
        SET status = 'rejected',
            accepted_work_item_id = NULL,
            updated_at = unixepoch()
        WHERE status = 'proposed'
          AND session_id IN (
            SELECT sessions.id
            FROM suggestion_sessions AS sessions
            JOIN epics ON epics.id = sessions.epic_id
            WHERE epics.status = 'archived'
          );

        UPDATE suggestion_sessions
        SET status = 'cancelled',
            error_message = NULL,
            updated_at = unixepoch()
        WHERE status != 'cancelled'
          AND epic_id IN (
            SELECT id FROM epics WHERE status = 'archived'
          );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (33, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 34, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE ticket_comments
        ADD COLUMN owner_question_json TEXT;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (34, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 35, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE ticket_comments
        ADD COLUMN answered_questions_json TEXT;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (35, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 36, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE demo_sessions (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            candidate_revision_id TEXT NOT NULL
              REFERENCES candidate_revisions(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            preview_worktree_path TEXT,
            allocated_port INTEGER,
            output TEXT,
            error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(candidate_revision_id)
        );

        CREATE INDEX idx_demo_sessions_product_status
            ON demo_sessions(product_id, status, updated_at);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (36, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 37, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE agent_permission_requests (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
            agent_run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            server_request_id TEXT NOT NULL,
            method TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            reason TEXT,
            signature TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE INDEX idx_agent_permission_requests_product_status
            ON agent_permission_requests(product_id, status, updated_at);

        CREATE INDEX idx_agent_permission_requests_run_signature
            ON agent_permission_requests(agent_run_id, signature, status);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (37, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 38, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE agent_permission_requests
            ADD COLUMN product_grant_signature TEXT;

        CREATE TABLE agent_permission_grants (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            source_request_id TEXT
              REFERENCES agent_permission_requests(id) ON DELETE SET NULL,
            method TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            signature TEXT NOT NULL,
            created_at REAL NOT NULL,
            revoked_at REAL
        );

        CREATE UNIQUE INDEX idx_agent_permission_grants_active_signature
            ON agent_permission_grants(product_id, signature)
            WHERE revoked_at IS NULL;

        CREATE INDEX idx_agent_permission_grants_product_created
            ON agent_permission_grants(product_id, created_at);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (38, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    // Migration 39 was used by an earlier development build and remains reserved.
    if try !migrationApplied(version: 40, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TABLE IF NOT EXISTS agent_run_knowledge_destinations (
            run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
            page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
            PRIMARY KEY(run_id, page_id)
        );

        CREATE INDEX IF NOT EXISTS idx_agent_run_knowledge_destination
            ON agent_run_knowledge_destinations(page_id, run_id);

        INSERT INTO knowledge_page_revisions (
            id, page_id, version, body_markdown, author_name, change_summary, created_at
        )
        SELECT
            lower(hex(randomblob(4))) || '-' ||
              lower(hex(randomblob(2))) || '-' ||
              lower(hex(randomblob(2))) || '-' ||
              lower(hex(randomblob(2))) || '-' ||
              lower(hex(randomblob(6))),
            page.id,
            2,
            '',
            'StoryPointless',
            'Removed the initial placeholder body',
            unixepoch()
        FROM knowledge_pages AS page
        WHERE page.body_markdown = 'Add verified knowledge here.'
          AND page.kind = 'page'
          AND page.source_work_item_id IS NULL
          AND (
            SELECT COUNT(*)
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
          ) = 1
          AND EXISTS (
            SELECT 1
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.version = 1
              AND revision.body_markdown = 'Add verified knowledge here.'
              AND revision.author_name = 'StoryPointless'
              AND revision.change_summary = 'Created page'
          );

        UPDATE knowledge_pages
        SET body_markdown = '',
            updated_at = unixepoch()
        WHERE id IN (
          SELECT page_id
          FROM knowledge_page_revisions
          WHERE change_summary = 'Removed the initial placeholder body'
            AND body_markdown = ''
        )
          AND body_markdown = 'Add verified knowledge here.';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (40, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 43, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        INSERT INTO knowledge_page_revisions (
            id, page_id, version, body_markdown, author_name, change_summary, created_at
        )
        SELECT
            lower(hex(randomblob(4))) || '-' ||
              lower(hex(randomblob(2))) || '-' ||
              lower(hex(randomblob(2))) || '-' ||
              lower(hex(randomblob(2))) || '-' ||
              lower(hex(randomblob(6))),
            page.id,
            2,
            '',
            'StoryPointless',
            'Removed the legacy initial placeholder body',
            unixepoch()
        FROM knowledge_pages AS page
        WHERE page.body_markdown = 'Add verified knowledge here.'
          AND page.kind = 'page'
          AND page.source_work_item_id IS NULL
          AND (
            SELECT COUNT(*)
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
          ) = 1
          AND EXISTS (
            SELECT 1
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.version = 1
              AND (
                revision.body_markdown = 'Add verified knowledge here.'
                OR revision.body_markdown =
                  '# ' || page.title || char(10) || char(10) ||
                    'Add verified knowledge here.'
              )
              AND revision.author_name = 'StoryPointless'
              AND revision.change_summary = 'Created page'
          );

        UPDATE knowledge_pages
        SET body_markdown = '',
            updated_at = unixepoch()
        WHERE id IN (
          SELECT page_id
          FROM knowledge_page_revisions
          WHERE change_summary = 'Removed the legacy initial placeholder body'
            AND body_markdown = ''
        )
          AND body_markdown = 'Add verified knowledge here.';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (43, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 42, database: database) {
      if try columnExists("status", in: "products", database: database) {
        try execute(
          """
          BEGIN IMMEDIATE;

          CREATE INDEX IF NOT EXISTS idx_products_status_created
              ON products(status, created_at);

          INSERT INTO schema_migrations (version, applied_at)
          VALUES (42, unixepoch());

          COMMIT;
          """,
          database: database
        )
      } else {
        try execute(
          """
          BEGIN IMMEDIATE;

          ALTER TABLE products
              ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
              CHECK (status IN ('active', 'archived'));

          CREATE INDEX idx_products_status_created
              ON products(status, created_at);

          INSERT INTO schema_migrations (version, applied_at)
          VALUES (42, unixepoch());

          COMMIT;
          """,
          database: database
        )
      }
    }

    if try !migrationApplied(version: 44, database: database) {
      if try !columnExists("color", in: "products", database: database) {
        try execute(
          """
          ALTER TABLE products
              ADD COLUMN color TEXT NOT NULL DEFAULT 'accent'
              CHECK (
                color IN ('accent', 'blue', 'teal', 'green', 'orange', 'pink', 'indigo')
              );
          """,
          database: database
        )
      }

      try execute(
        """
        BEGIN IMMEDIATE;

        WITH ranked_products AS (
          SELECT
            id,
            ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS position
          FROM products
        )
        UPDATE products
        SET color = CASE (
          SELECT (position - 2) % 6
          FROM ranked_products
          WHERE ranked_products.id = products.id
        )
          WHEN 0 THEN 'blue'
          WHEN 1 THEN 'teal'
          WHEN 2 THEN 'green'
          WHEN 3 THEN 'orange'
          WHEN 4 THEN 'pink'
          ELSE 'indigo'
        END
        WHERE color = 'accent'
          AND id IN (
            SELECT id
            FROM ranked_products
            WHERE position > 1
          );

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (44, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 45, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        ALTER TABLE retrospective_notes
        ADD COLUMN is_action_candidate INTEGER NOT NULL DEFAULT 0;

        ALTER TABLE retrospective_notes
        ADD COLUMN expected_effect TEXT;

        ALTER TABLE retrospective_notes
        ADD COLUMN synthesis_id TEXT REFERENCES retrospective_syntheses(id) ON DELETE SET NULL;

        CREATE TABLE retrospective_syntheses (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
            profile_id TEXT REFERENCES agent_profiles(id) ON DELETE SET NULL,
            status TEXT NOT NULL,
            codex_thread_id TEXT,
            codex_turn_id TEXT,
            error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(sprint_id)
        );

        CREATE TABLE retrospective_synthesis_sources (
            synthesis_id TEXT NOT NULL
                REFERENCES retrospective_syntheses(id) ON DELETE CASCADE,
            source_note_id TEXT NOT NULL
                REFERENCES retrospective_notes(id) ON DELETE CASCADE,
            PRIMARY KEY(synthesis_id, source_note_id)
        );

        CREATE TABLE retrospective_action_sources (
            action_note_id TEXT NOT NULL
                REFERENCES retrospective_notes(id) ON DELETE CASCADE,
            source_note_id TEXT NOT NULL
                REFERENCES retrospective_notes(id) ON DELETE CASCADE,
            PRIMARY KEY(action_note_id, source_note_id)
        );

        UPDATE retrospective_notes
        SET is_action_candidate = 1,
            action_status = NULL
        WHERE category = 'suggested_action'
          AND profile_id IS NOT NULL
          AND action_status = 'proposed'
          AND sprint_id IN (
            SELECT id
            FROM sprints
            WHERE retrospective_concluded_at IS NULL
          );

        INSERT INTO retrospective_syntheses (
            id, product_id, sprint_id, profile_id, status,
            codex_thread_id, codex_turn_id, error_message, created_at, updated_at
        )
        SELECT
            upper(hex(randomblob(4))) || '-' ||
              upper(hex(randomblob(2))) || '-' ||
              upper(hex(randomblob(2))) || '-' ||
              upper(hex(randomblob(2))) || '-' ||
              upper(hex(randomblob(6))),
            product_id,
            id,
            NULL,
            'pending',
            NULL,
            NULL,
            NULL,
            COALESCE(completed_at, updated_at),
            unixepoch()
        FROM sprints
        WHERE state = 'completed'
          AND retrospective_concluded_at IS NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (45, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 46, database: database) {
      try execute(
        """
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE;

        UPDATE retrospective_synthesis_sources
        SET synthesis_id = upper(synthesis_id);

        UPDATE retrospective_notes
        SET synthesis_id = upper(synthesis_id)
        WHERE synthesis_id IS NOT NULL;

        UPDATE retrospective_syntheses
        SET id = upper(id);

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (46, unixepoch());

        COMMIT;
        PRAGMA foreign_keys = ON;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 47, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        CREATE TEMP TABLE misdirected_delivery_note_pages AS
        SELECT
          page.id AS corrupted_page_id,
          delivery.id AS delivery_page_id,
          (
            SELECT revision.body_markdown
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.change_summary <> 'Updated delivery note'
            ORDER BY revision.version DESC
            LIMIT 1
          ) AS restored_page_body,
          (
            SELECT revision.body_markdown
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.change_summary = 'Updated delivery note'
            ORDER BY revision.version DESC
            LIMIT 1
          ) AS recovered_delivery_body,
          (
            SELECT revision.version
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.change_summary = 'Updated delivery note'
            ORDER BY revision.version DESC
            LIMIT 1
          ) AS recovered_delivery_version,
          (
            SELECT revision.created_at
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.change_summary = 'Updated delivery note'
            ORDER BY revision.version DESC
            LIMIT 1
          ) AS recovered_delivery_created_at
        FROM knowledge_pages AS page
        JOIN knowledge_pages AS delivery
          ON delivery.product_id = page.product_id
         AND delivery.source_work_item_id = page.source_work_item_id
         AND delivery.kind = 'delivery_note'
        WHERE page.kind <> 'delivery_note'
          AND page.source_work_item_id IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.change_summary = 'Updated delivery note'
          )
          AND EXISTS (
            SELECT 1
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = page.id
              AND revision.change_summary <> 'Updated delivery note'
          );

        UPDATE knowledge_pages
        SET body_markdown = (
              SELECT repair.recovered_delivery_body
              FROM misdirected_delivery_note_pages AS repair
              WHERE repair.delivery_page_id = knowledge_pages.id
              ORDER BY
                repair.recovered_delivery_created_at DESC,
                repair.recovered_delivery_version DESC
              LIMIT 1
            ),
            verification_status = 'proposed',
            updated_at = unixepoch()
        WHERE id IN (
          SELECT delivery_page_id
          FROM misdirected_delivery_note_pages
        );

        INSERT INTO knowledge_page_revisions (
          id, page_id, version, body_markdown, author_name, change_summary, created_at
        )
        SELECT
          lower(hex(randomblob(4))) || '-' ||
            lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(6))),
          repair.delivery_page_id,
          (
            SELECT COALESCE(MAX(revision.version), 0) + 1
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = repair.delivery_page_id
          ),
          repair.recovered_delivery_body,
          'StoryPointless',
          'Recovered misdirected delivery note',
          unixepoch()
        FROM misdirected_delivery_note_pages AS repair
        WHERE repair.corrupted_page_id = (
          SELECT preferred.corrupted_page_id
          FROM misdirected_delivery_note_pages AS preferred
          WHERE preferred.delivery_page_id = repair.delivery_page_id
          ORDER BY
            preferred.recovered_delivery_created_at DESC,
            preferred.recovered_delivery_version DESC
          LIMIT 1
        );

        UPDATE knowledge_pages
        SET body_markdown = (
              SELECT repair.restored_page_body
              FROM misdirected_delivery_note_pages AS repair
              WHERE repair.corrupted_page_id = knowledge_pages.id
            ),
            verification_status = 'verified',
            updated_at = unixepoch()
        WHERE id IN (
          SELECT corrupted_page_id
          FROM misdirected_delivery_note_pages
        );

        INSERT INTO knowledge_page_revisions (
          id, page_id, version, body_markdown, author_name, change_summary, created_at
        )
        SELECT
          lower(hex(randomblob(4))) || '-' ||
            lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(6))),
          repair.corrupted_page_id,
          (
            SELECT COALESCE(MAX(revision.version), 0) + 1
            FROM knowledge_page_revisions AS revision
            WHERE revision.page_id = repair.corrupted_page_id
          ),
          repair.restored_page_body,
          'StoryPointless',
          'Restored after misdirected delivery note update',
          unixepoch()
        FROM misdirected_delivery_note_pages AS repair;

        DROP TABLE misdirected_delivery_note_pages;

        CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_delivery_note_source
        ON knowledge_pages(product_id, source_work_item_id)
        WHERE kind = 'delivery_note' AND source_work_item_id IS NOT NULL;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (47, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 48, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE epics SET status = 'open' WHERE status = 'active';
        UPDATE epics SET status = 'closed' WHERE status = 'complete';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (48, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 49, database: database) {
      if try columnExists("color", in: "epics", database: database) {
        try execute(
          """
          BEGIN IMMEDIATE;

          WITH ordered_epics AS (
            SELECT
              id,
              ROW_NUMBER() OVER (
                PARTITION BY product_id
                ORDER BY created_at ASC, id ASC
              ) AS position
            FROM epics
          )
          UPDATE epics
          SET color = CASE (
            SELECT (position - 1) % 6
            FROM ordered_epics
            WHERE ordered_epics.id = epics.id
          )
            WHEN 0 THEN 'blue'
            WHEN 1 THEN 'teal'
            WHEN 2 THEN 'green'
            WHEN 3 THEN 'orange'
            WHEN 4 THEN 'pink'
            ELSE 'indigo'
          END;

          INSERT INTO schema_migrations (version, applied_at)
          VALUES (49, unixepoch());

          COMMIT;
          """,
          database: database
        )
      } else {
        try execute(
          """
          BEGIN IMMEDIATE;

          ALTER TABLE epics
          ADD COLUMN color TEXT NOT NULL DEFAULT 'blue';

          WITH ordered_epics AS (
            SELECT
              id,
              ROW_NUMBER() OVER (
                PARTITION BY product_id
                ORDER BY created_at ASC, id ASC
              ) AS position
            FROM epics
          )
          UPDATE epics
          SET color = CASE (
            SELECT (position - 1) % 6
            FROM ordered_epics
            WHERE ordered_epics.id = epics.id
          )
            WHEN 0 THEN 'blue'
            WHEN 1 THEN 'teal'
            WHEN 2 THEN 'green'
            WHEN 3 THEN 'orange'
            WHEN 4 THEN 'pink'
            ELSE 'indigo'
          END;

          INSERT INTO schema_migrations (version, applied_at)
          VALUES (49, unixepoch());

          COMMIT;
          """,
          database: database
        )
      }
    }

    if try !migrationApplied(version: 50, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        WITH ordered_epics AS (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY product_id
              ORDER BY created_at ASC, id ASC
            ) AS position
          FROM epics
        )
        UPDATE epics
        SET color = CASE (
          SELECT (position - 1) % 6
          FROM ordered_epics
          WHERE ordered_epics.id = epics.id
        )
          WHEN 0 THEN 'blue'
          WHEN 1 THEN 'teal'
          WHEN 2 THEN 'green'
          WHEN 3 THEN 'orange'
          WHEN 4 THEN 'pink'
          ELSE 'indigo'
        END;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (50, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 51, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        WITH ordered_epics AS (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY product_id, status
              ORDER BY created_at ASC, id ASC
            ) AS position
          FROM epics
        )
        UPDATE epics
        SET color = CASE (
          SELECT (position - 1) % 6
          FROM ordered_epics
          WHERE ordered_epics.id = epics.id
        )
          WHEN 0 THEN 'blue'
          WHEN 1 THEN 'teal'
          WHEN 2 THEN 'green'
          WHEN 3 THEN 'orange'
          WHEN 4 THEN 'pink'
          ELSE 'indigo'
        END;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (51, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 52, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        WITH ordered_epics AS (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY product_id, status
              ORDER BY created_at ASC, id ASC
            ) AS position
          FROM epics
        )
        UPDATE epics
        SET color = CASE (
          SELECT (position - 1) % 6
          FROM ordered_epics
          WHERE ordered_epics.id = epics.id
        )
          WHEN 0 THEN 'blue'
          WHEN 1 THEN 'green'
          WHEN 2 THEN 'indigo'
          WHEN 3 THEN 'orange'
          WHEN 4 THEN 'teal'
          ELSE 'pink'
        END;

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (52, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }

    if try !migrationApplied(version: 53, database: database) {
      try execute(
        """
        BEGIN IMMEDIATE;

        UPDATE candidate_revisions
        SET status = 'queued_for_review',
            updated_at = unixepoch()
        WHERE status = 'queued_for_integration';

        INSERT INTO schema_migrations (version, applied_at)
        VALUES (53, unixepoch());

        COMMIT;
        """,
        database: database
      )
    }
  }

  private static func columnExists(
    _ column: String,
    in table: String,
    database: OpaquePointer
  ) throws -> Bool {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(
      database,
      "PRAGMA table_info(\(table));",
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
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else { continue }
      if String(cString: name) == column {
        return true
      }
    }
    return false
  }

  private static func migrationApplied(version: Int, database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(
      database,
      "SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1;",
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
    guard sqlite3_bind_int64(statement, 1, Int64(version)) == SQLITE_OK else {
      throw PersistenceError.sqlite(
        code: sqlite3_errcode(database),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func insertAgentProfile(_ profile: AgentProfile) throws {
    try withStatement(
      """
      INSERT INTO agent_profiles (
          id, product_id, name, role, model, reasoning_effort,
          custom_instructions, parallelism_limit, is_builtin, is_active,
          created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(profile.id.uuidString, to: 1, in: statement)
      try bind(profile.productID.uuidString, to: 2, in: statement)
      try bind(profile.name, to: 3, in: statement)
      try bind(profile.role.rawValue, to: 4, in: statement)
      try bind(profile.model, to: 5, in: statement)
      try bind(profile.reasoningEffort, to: 6, in: statement)
      try bindOptionalString(profile.customInstructions, to: 7, in: statement)
      if let parallelismLimit = profile.parallelismLimit {
        try bind(Int64(parallelismLimit), to: 8, in: statement)
      } else {
        try bindNull(to: 8, in: statement)
      }
      try bind(profile.isBuiltIn ? Int64(1) : Int64(0), to: 9, in: statement)
      try bind(Int64(1), to: 10, in: statement)
      try bind(profile.createdAt.timeIntervalSince1970, to: 11, in: statement)
      try bind(profile.updatedAt.timeIntervalSince1970, to: 12, in: statement)
      try stepDone(statement)
    }
  }

  private func insertKnowledgePage(
    _ page: KnowledgePage,
    authorName: String,
    changeSummary: String
  ) throws {
    let normalizedBody = KnowledgeMarkdown.normalizedBody(page.bodyMarkdown)
    try withStatement(
      """
      INSERT INTO knowledge_pages (
          id, product_id, parent_id, title, slug, body_markdown, kind,
          verification_status, sort_order, source_work_item_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
      try bind(page.createdAt.timeIntervalSince1970, to: 11, in: statement)
      try bind(page.updatedAt.timeIntervalSince1970, to: 12, in: statement)
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

  private func insertKnowledgeRevision(
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

  private func fetchKnowledgePage(id: UUID) throws -> KnowledgePage {
    try withStatement(
      """
      SELECT id, product_id, parent_id, title, slug, body_markdown, kind,
             verification_status, sort_order, source_work_item_id, created_at, updated_at
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

  private func fetchKnowledgePageProposal(id: UUID) throws -> KnowledgePageProposal {
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

  private func decodeCandidateRevision(_ statement: OpaquePointer) throws -> CandidateRevision {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let sprintID = UUID(uuidString: try text(statement, column: 2)),
      let sprintItemID = UUID(uuidString: try text(statement, column: 3)),
      let workItemID = UUID(uuidString: try text(statement, column: 4)),
      let implementationRunID = UUID(uuidString: try text(statement, column: 5)),
      let status = CandidateRevisionStatus(rawValue: try text(statement, column: 13))
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

  private func decodeDemoSession(_ statement: OpaquePointer) throws -> DemoSession {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let candidateRevisionID = UUID(uuidString: try text(statement, column: 2)),
      let status = DemoSessionStatus(rawValue: try text(statement, column: 3))
    else {
      throw PersistenceError.corruptData("Invalid demo session")
    }
    return DemoSession(
      id: id,
      productID: productID,
      candidateRevisionID: candidateRevisionID,
      status: status,
      previewWorktreePath: try optionalText(statement, column: 4),
      allocatedPort: optionalInt(statement, column: 5),
      output: try optionalText(statement, column: 6),
      errorMessage: try optionalText(statement, column: 7),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
    )
  }

  private func decodeAgentPermissionRequest(
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

  private func decodeAgentPermissionGrant(
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

  private func decodeKnowledgePageProposal(
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

  private func decodeKnowledgePage(_ statement: OpaquePointer) throws -> KnowledgePage {
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
      createdAt: date(statement, column: 10),
      updatedAt: date(statement, column: 11)
    )
  }

  private static func knowledgeSlug(for title: String) -> String {
    let slug = title
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .joined(separator: "-")
    return slug.isEmpty ? "page" : slug
  }

  private func fetchAgentProfile(id: UUID) throws -> AgentProfile {
    try withStatement(
      """
      SELECT id, product_id, name, role, model, reasoning_effort,
             custom_instructions, parallelism_limit, is_builtin, created_at, updated_at
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
        parallelismLimit: optionalInt(statement, column: 7),
        isBuiltIn: sqlite3_column_int64(statement, 8) != 0,
        createdAt: date(statement, column: 9),
        updatedAt: date(statement, column: 10)
      )
    }
  }

  private func insertSprint(_ sprint: Sprint) throws {
    try withStatement(
      """
      INSERT INTO sprints (
          id, product_id, sprint_number, goal, state, token_budget_limit,
          concurrency_limit, plan_version, started_at, completed_at,
          retrospective_concluded_at, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(sprint.id.uuidString, to: 1, in: statement)
      try bind(sprint.productID.uuidString, to: 2, in: statement)
      try bind(Int64(sprint.number), to: 3, in: statement)
      try bind(sprint.goal, to: 4, in: statement)
      try bind(sprint.state.rawValue, to: 5, in: statement)
      try bindOptionalInt(sprint.tokenBudgetLimit, to: 6, in: statement)
      try bind(Int64(sprint.concurrencyLimit), to: 7, in: statement)
      try bind(Int64(sprint.planVersion), to: 8, in: statement)
      try bindOptionalDate(sprint.startedAt, to: 9, in: statement)
      try bindOptionalDate(sprint.completedAt, to: 10, in: statement)
      try bindOptionalDate(sprint.retrospectiveConcludedAt, to: 11, in: statement)
      try bind(sprint.createdAt.timeIntervalSince1970, to: 12, in: statement)
      try bind(sprint.updatedAt.timeIntervalSince1970, to: 13, in: statement)
      try stepDone(statement)
    }
  }

  private func updateDraftSprint(_ sprint: Sprint) throws {
    try withStatement(
      """
      UPDATE sprints
      SET goal = ?, token_budget_limit = ?, concurrency_limit = ?,
          plan_version = ?, updated_at = ?
      WHERE id = ? AND state = 'draft';
      """
    ) { statement in
      try bind(sprint.goal, to: 1, in: statement)
      try bindOptionalInt(sprint.tokenBudgetLimit, to: 2, in: statement)
      try bind(Int64(sprint.concurrencyLimit), to: 3, in: statement)
      try bind(Int64(sprint.planVersion), to: 4, in: statement)
      try bind(sprint.updatedAt.timeIntervalSince1970, to: 5, in: statement)
      try bind(sprint.id.uuidString, to: 6, in: statement)
      try stepDone(statement)
    }
  }

  private func insertSprintItem(_ item: SprintItem) throws {
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

  private func insertAgentRun(_ run: AgentRun) throws {
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

  private func fetchSprint(id: UUID) throws -> Sprint {
    try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             concurrency_limit, plan_version, started_at, completed_at,
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

  private func fetchSprint(productID: UUID, state: SprintState) throws -> Sprint? {
    try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             concurrency_limit, plan_version, started_at, completed_at,
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

  private func fetchSprintItems(sprintID: UUID) throws -> [SprintItem] {
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

  private func nextSprintNumber(productID: UUID) throws -> Int {
    try withStatement(
      "SELECT COALESCE(MAX(sprint_number), 0) + 1 FROM sprints WHERE product_id = ?;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  private func decodeSprint(_ statement: OpaquePointer) throws -> Sprint {
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
      concurrencyLimit: Int(sqlite3_column_int64(statement, 6)),
      planVersion: Int(sqlite3_column_int64(statement, 7)),
      startedAt: optionalDate(statement, column: 8),
      completedAt: optionalDate(statement, column: 9),
      retrospectiveConcludedAt: optionalDate(statement, column: 10),
      createdAt: date(statement, column: 11),
      updatedAt: date(statement, column: 12)
    )
  }

  private func insertWorkItem(
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

  private func fetchSuggestionSession(id: UUID) throws -> SuggestionSession {
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

  private func fetchSuggestionSession(
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

  private func fetchSuggestionSession(
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

  private func decodeSuggestionSession(_ statement: OpaquePointer) throws -> SuggestionSession {
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

  private func fetchTicketSuggestionBatch(sessionID: UUID) throws -> TicketSuggestionBatch {
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

  private func fetchTicketSuggestion(id: UUID) throws -> TicketSuggestion {
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
      suggestion.dependencyIDs = try fetchSuggestionDependencies(
        sessionID: suggestion.sessionID
      )[suggestion.id] ?? []
      suggestion.existingDependencyWorkItemIDs = try fetchSuggestionExistingDependencies(
        sessionID: suggestion.sessionID
      )[suggestion.id] ?? []
      return suggestion
    }
  }

  private func decodeTicketSuggestion(_ statement: OpaquePointer) throws -> TicketSuggestion {
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

  private func fetchSuggestionDependencies(sessionID: UUID) throws -> [UUID: [UUID]] {
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

  private func fetchSuggestionExistingDependencies(
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

  private func reconcileAcceptedSuggestionDependencies(sessionID: UUID) throws {
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

  private func replaceWorkItemDependencies(
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

  private func validateDependencyGraph(productID: UUID) throws {
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

  private func normalizePlanningRanks(productID: UUID) throws {
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
      guard let nextIndex = remaining.firstIndex(where: { item in
        prerequisitesByItem[item.id, default: []].isSubset(of: placedIDs)
      }) else {
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

  private func fetchWorkItem(id: UUID) throws -> WorkItem {
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

  private func nextWorkItemNumber(productID: UUID) throws -> Int {
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

  private func nextWorkItemRank(productID: UUID) throws -> Int {
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

  private func nextEpicRank(productID: UUID) throws -> Int {
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
  private func insertEvent(
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

  private func decodeProduct(_ statement: OpaquePointer) throws -> Product {
    guard let id = UUID(uuidString: try text(statement, column: 0)) else {
      throw PersistenceError.corruptData("Invalid product id")
    }
    guard
      let status = ProductStatus(rawValue: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid product status")
    }
    guard
      let color = ProductColor(rawValue: try text(statement, column: 5))
    else {
      throw PersistenceError.corruptData("Invalid product color")
    }
    return Product(
      id: id,
      name: try text(statement, column: 1),
      vision: try text(statement, column: 2),
      instructions: try text(statement, column: 3),
      status: status,
      color: color,
      createdAt: date(statement, column: 6),
      updatedAt: date(statement, column: 7)
    )
  }

  private func fetchProduct(id: UUID) throws -> Product {
    try withStatement(
      """
      SELECT id, name, vision, instructions, status, color, created_at, updated_at
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

  private func fetchEpic(id: UUID) throws -> Epic {
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

  private func decodeEpic(_ statement: OpaquePointer) throws -> Epic {
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

  private func decodeWorkItem(_ statement: OpaquePointer) throws -> WorkItem {
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

  private func encodeStringArray(_ values: [String]) throws -> String {
    let data = try encoder.encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData("Could not encode string array")
    }
    return value
  }

  private func decodeStringArray(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else {
      throw PersistenceError.corruptData("Could not decode string array")
    }
    return try decoder.decode([String].self, from: data)
  }

  private func encodeStringDictionary(_ values: [String: String]) throws -> String {
    let data = try encoder.encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData("Could not encode custom fields")
    }
    return value
  }

  private func decodeStringDictionary(_ value: String) throws -> [String: String] {
    guard let data = value.data(using: .utf8) else {
      throw PersistenceError.corruptData("Could not decode custom fields")
    }
    return try decoder.decode([String: String].self, from: data)
  }

  private func transaction(_ operation: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      try operation()
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    guard let database else {
      throw PersistenceError.sqlite(code: SQLITE_MISUSE, message: "Database is closed")
    }
    try Self.execute(sql, database: database)
  }

  private static func execute(_ sql: String, database: OpaquePointer) throws {
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

  private func withStatement<T>(
    _ sql: String,
    operation: (OpaquePointer) throws -> T
  ) throws -> T {
    guard let database else {
      throw PersistenceError.sqlite(code: SQLITE_MISUSE, message: "Database is closed")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw currentSQLiteError(code: result)
    }
    defer { sqlite3_finalize(statement) }
    return try operation(statement)
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      throw currentSQLiteError(code: result)
    }
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let result = value.withCString {
      sqlite3_bind_text(statement, index, $0, -1, transient)
    }
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
    let result = sqlite3_bind_int64(statement, index, value)
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
    let result = sqlite3_bind_double(statement, index, value)
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  private func bindOptionalString(
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

  private func bindOptionalUUID(
    _ value: UUID?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    try bindOptionalString(value?.uuidString, to: index, in: statement)
  }

  private func bindOptionalInt(
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

  private func bindOptionalDate(
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

  private func bindNull(to index: Int32, in statement: OpaquePointer) throws {
    let result = sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else {
      throw currentSQLiteError(code: result)
    }
  }

  private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard let value = sqlite3_column_text(statement, column) else {
      throw PersistenceError.corruptData("Missing text at column \(column)")
    }
    return String(cString: value)
  }

  private func optionalText(_ statement: OpaquePointer, column: Int32) throws -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return try text(statement, column: column)
  }

  private func optionalInt(_ statement: OpaquePointer, column: Int32) -> Int? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, column))
  }

  private func date(_ statement: OpaquePointer, column: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
  }

  private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return date(statement, column: column)
  }

  private func currentSQLiteError(code: Int32? = nil) -> PersistenceError {
    guard let database else {
      return .sqlite(code: code ?? SQLITE_MISUSE, message: "Database is closed")
    }
    return .sqlite(
      code: code ?? sqlite3_errcode(database),
      message: String(cString: sqlite3_errmsg(database))
    )
  }
}
