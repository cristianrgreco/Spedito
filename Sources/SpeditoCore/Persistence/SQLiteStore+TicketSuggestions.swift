import Foundation
import SQLite3

extension SQLiteStore {
  public func beginTicketSuggestionSession(
    productID: UUID,
    epicID: UUID? = nil
  ) throws -> SuggestionSession {
    if let active = try fetchSuggestionSession(productID: productID, status: .generating) {
      guard active.epicID == epicID else {
        throw PersistenceError.corruptData(
          "Another epic is already being planned by the business analyst"
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
        actor: "Business analyst",
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
        actor: "Business analyst",
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
        actor: "Business analyst",
        detail: "\(drafts.count) follow-up proposals"
      )
    }
    return try fetchTicketSuggestionBatch(sessionID: session.id)
  }

  func ticketSuggestionInsertContext(
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

  func insertTicketSuggestionDrafts(
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

  public func fetchLatestEpicPlanningSuggestionSession(
    epicID: UUID
  ) throws -> SuggestionSession? {
    try withStatement(
      """
      SELECT id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
             error_message, created_at, updated_at
      FROM suggestion_sessions
      WHERE epic_id = ? AND source_work_item_id IS NULL
      ORDER BY created_at DESC
      LIMIT 1;
      """
    ) { statement in
      try bind(epicID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeSuggestionSession(statement)
    }
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

  func suggestedPrerequisiteClosure(
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

}
