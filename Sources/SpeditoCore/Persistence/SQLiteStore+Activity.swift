import Foundation
import SQLite3

extension SQLiteStore {
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

}
