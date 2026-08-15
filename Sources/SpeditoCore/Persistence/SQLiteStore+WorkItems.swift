import Foundation
import SQLite3

extension SQLiteStore {
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

  func fetchSprintExecutionWorkItems(
    productID: UUID,
    sprintID: UUID
  ) throws -> [WorkItem] {
    try withStatement(
      """
      SELECT id, product_id, item_key, title, ticket_type, body,
             acceptance_criteria_json, state, priority, version,
             created_at, updated_at, rank, custom_fields_json, owner_profile_id, epic_id
      FROM work_items
      WHERE product_id = ?
        AND id IN (
          SELECT work_item_id
          FROM sprint_items
          WHERE sprint_id = ?
          UNION
          SELECT dependency.depends_on_work_item_id
          FROM work_item_dependencies AS dependency
          JOIN sprint_items AS item
            ON item.work_item_id = dependency.work_item_id
          WHERE item.sprint_id = ?
        )
      ORDER BY rank ASC, key_number ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(sprintID.uuidString, to: 2, in: statement)
      try bind(sprintID.uuidString, to: 3, in: statement)
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
    let previousDependencyIDs: Set<UUID>? =
      if dependsOnWorkItemIDs != nil {
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
    workItem.acceptanceCriteria =
      acceptanceCriteria
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
      let fieldSummary =
        changedKeys.count <= 3
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
    let updateDetail =
      updateDetails.isEmpty
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
        actor: "Product owner",
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

    let indexByID = Dictionary(
      uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
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
        actor: "Product owner",
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
          actor: "Product owner",
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

  func prepareWorkItemsForArchival(ids archiveIDs: Set<UUID>) throws -> [WorkItem] {
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
    let activeDependent =
      dependencies
      .filter {
        archiveIDs.contains($0.dependsOnWorkItemID)
          && !archiveIDs.contains($0.workItemID)
      }
      .compactMap { try? fetchWorkItem(id: $0.workItemID) }
      .first { planningStates.contains($0.state) }
    if let activeDependent {
      let prerequisiteKey =
        dependencies
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

  func archivePreparedWorkItems(_ workItems: [WorkItem]) throws {
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
        actor: "Product owner",
        detail: workItem.key
      )
    }
  }

}
