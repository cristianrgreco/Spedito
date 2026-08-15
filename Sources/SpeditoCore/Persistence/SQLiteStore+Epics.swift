import Foundation
import SQLite3

extension SQLiteStore {
  public func createEpic(productID: UUID, outcome: String) throws -> Epic {
    let goal = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !goal.isEmpty else {
      throw PersistenceError.corruptData("Epic outcome cannot be empty")
    }
    let epic = Epic(
      productID: productID,
      title: "",
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
        detail: epic.goal
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
    guard !trimmedGoal.isEmpty else {
      throw PersistenceError.corruptData("Epic goal cannot be empty")
    }
    if epic.hasAnalyzedMetadata, trimmedTitle.isEmpty {
      throw PersistenceError.corruptData("Epic title cannot be empty after analysis")
    }
    let criteria =
      successCriteria
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let trimmedConstraints = constraints.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTitle.isEmpty, !criteria.isEmpty || !trimmedConstraints.isEmpty {
      throw PersistenceError.corruptData(
        "Analyze this epic before adding success criteria or constraints"
      )
    }
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
      try bind(trimmedConstraints, to: 4, in: statement)
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
      throw PersistenceError.corruptData("Only an open epic can be completed")
    }
    let tickets = try fetchWorkItems(productID: epic.productID)
      .filter { $0.epicID == epic.id }
    guard EpicProgress(tickets: tickets) == .complete else {
      throw PersistenceError.corruptData(
        "Deliver every accepted ticket before completing this epic"
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
        "Review or dismiss every proposed ticket before completing this epic"
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
        actor: "Product owner",
        detail: epic.displayTitle
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
        actor: "Product owner",
        detail: epic.displayTitle
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
          actor: "Product owner",
          detail:
            targetID == nil
            ? "\(epic.displayTitle) moved to bottom"
            : "\(epic.displayTitle) reordered"
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
          actor: "Product owner",
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
        actor: "Product owner",
        detail: epic.displayTitle
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

}
