import Foundation
import SQLite3

extension SQLiteStore {
  @discardableResult
  public func createOwnerNotification(
    _ notification: OwnerNotification
  ) throws -> Bool {
    _ = try fetchProduct(id: notification.productID)
    let title = notification.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = notification.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !body.isEmpty else {
      throw PersistenceError.corruptData("Owner notifications require a title and body")
    }
    guard
      notification.resolvedAt == nil
        || (notification.kind.requiresAction && notification.readAt != nil)
    else {
      throw PersistenceError.corruptData(
        "Resolved owner notifications require an owner action and read time"
      )
    }

    try withStatement(
      """
      INSERT OR IGNORE INTO owner_notifications (
          id, product_id, kind, target_kind, target_id, title, body,
          created_at, read_at, resolved_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(notification.id.uuidString, to: 1, in: statement)
      try bind(notification.productID.uuidString, to: 2, in: statement)
      try bind(notification.kind.rawValue, to: 3, in: statement)
      try bind(notification.target.kind.rawValue, to: 4, in: statement)
      try bind(notification.target.id.uuidString, to: 5, in: statement)
      try bind(title, to: 6, in: statement)
      try bind(body, to: 7, in: statement)
      try bind(notification.createdAt.timeIntervalSince1970, to: 8, in: statement)
      try bindOptionalDate(notification.readAt, to: 9, in: statement)
      try bindOptionalDate(notification.resolvedAt, to: 10, in: statement)
      try stepDone(statement)
    }

    if sqlite3_changes(try requiredDatabase) == 1 {
      return true
    }

    guard let existing = try fetchOwnerNotification(id: notification.id) else {
      throw PersistenceError.corruptData(
        "The owner notification could not be persisted"
      )
    }
    guard
      existing.productID == notification.productID,
      existing.kind == notification.kind,
      existing.target == notification.target,
      existing.title == title,
      existing.body == body
    else {
      throw PersistenceError.corruptData(
        "Owner notification \(notification.id) conflicts with another source event"
      )
    }
    return false
  }

  public func fetchOwnerNotification(id: UUID) throws -> OwnerNotification? {
    try withStatement(
      """
      SELECT id, product_id, kind, target_kind, target_id, title, body,
             created_at, read_at, resolved_at
      FROM owner_notifications
      WHERE id = ?
      LIMIT 1;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeOwnerNotification(statement)
    }
  }

  public func fetchActiveOwnerNotifications(
    productID: UUID
  ) throws -> [OwnerNotification] {
    try withStatement(
      """
      SELECT id, product_id, kind, target_kind, target_id, title, body,
             created_at, read_at, resolved_at
      FROM owner_notifications
      WHERE product_id = ?
        AND (
          read_at IS NULL
          OR (kind = 'needs_input' AND resolved_at IS NULL)
        )
      ORDER BY created_at DESC, id DESC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var notifications: [OwnerNotification] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        notifications.append(try decodeOwnerNotification(statement))
      }
      return notifications
    }
  }

  @discardableResult
  public func markOwnerNotificationsRead(
    productID: UUID,
    target: OwnerNotificationTarget,
    at readAt: Date = Date()
  ) throws -> [UUID] {
    let notificationIDs = try fetchActiveOwnerNotifications(productID: productID)
      .filter { $0.target == target && $0.isUnread }
      .map(\.id)
    guard !notificationIDs.isEmpty else { return [] }

    try withStatement(
      """
      UPDATE owner_notifications
      SET read_at = COALESCE(read_at, ?)
      WHERE product_id = ?
        AND target_kind = ?
        AND target_id = ?
        AND read_at IS NULL;
      """
    ) { statement in
      try bind(readAt.timeIntervalSince1970, to: 1, in: statement)
      try bind(productID.uuidString, to: 2, in: statement)
      try bind(target.kind.rawValue, to: 3, in: statement)
      try bind(target.id.uuidString, to: 4, in: statement)
      try stepDone(statement)
    }
    return notificationIDs
  }

  @discardableResult
  public func resolveOwnerNotifications(
    productID: UUID,
    target: OwnerNotificationTarget,
    at resolvedAt: Date = Date()
  ) throws -> [UUID] {
    let notificationIDs = try fetchActiveOwnerNotifications(productID: productID)
      .filter {
        $0.target == target && $0.kind.requiresAction && $0.resolvedAt == nil
      }
      .map(\.id)
    guard !notificationIDs.isEmpty else { return [] }

    try withStatement(
      """
      UPDATE owner_notifications
      SET read_at = COALESCE(read_at, ?), resolved_at = COALESCE(resolved_at, ?)
      WHERE product_id = ?
        AND target_kind = ?
        AND target_id = ?
        AND kind = 'needs_input'
        AND resolved_at IS NULL;
      """
    ) { statement in
      try bind(resolvedAt.timeIntervalSince1970, to: 1, in: statement)
      try bind(resolvedAt.timeIntervalSince1970, to: 2, in: statement)
      try bind(productID.uuidString, to: 3, in: statement)
      try bind(target.kind.rawValue, to: 4, in: statement)
      try bind(target.id.uuidString, to: 5, in: statement)
      try stepDone(statement)
    }
    return notificationIDs
  }

  private func decodeOwnerNotification(
    _ statement: OpaquePointer
  ) throws -> OwnerNotification {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let kind = OwnerNotificationKind(rawValue: try text(statement, column: 2)),
      let targetKind = OwnerNotificationTargetKind(
        rawValue: try text(statement, column: 3)
      ),
      let targetID = UUID(uuidString: try text(statement, column: 4))
    else {
      throw PersistenceError.corruptData("Invalid owner notification")
    }
    return OwnerNotification(
      id: id,
      productID: productID,
      kind: kind,
      target: OwnerNotificationTarget(kind: targetKind, id: targetID),
      title: try text(statement, column: 5),
      body: try text(statement, column: 6),
      createdAt: date(statement, column: 7),
      readAt: optionalDate(statement, column: 8),
      resolvedAt: optionalDate(statement, column: 9)
    )
  }
}
