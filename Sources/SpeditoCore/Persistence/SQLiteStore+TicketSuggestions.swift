import Foundation
import SQLite3

/// Maps a batch's temporary in-batch `S` references to the durable `T` keys
/// allocated when the batch is persisted. Only word-boundary `S<digits>` tokens
/// that name a reference in the batch are touched, so active-ticket `T` keys
/// and unrelated prose keep their exact text.
enum TicketSuggestionKeySubstitution {
  private static let referencePattern = try! NSRegularExpression(pattern: #"\bS\d+\b"#)

  static func substitute(
    _ value: String,
    keysByBatchReference: [String: String]
  ) -> String {
    let matches = referencePattern.matches(
      in: value,
      range: NSRange(value.startIndex..., in: value)
    )
    var result = value
    for match in matches.reversed() {
      guard
        let range = Range(match.range, in: result),
        let key = keysByBatchReference[String(result[range])]
      else { continue }
      result.replaceSubrange(range, with: key)
    }
    return result
  }

  static func residualBatchReference(
    in value: String,
    batchReferences: Set<String>
  ) -> String? {
    let matches = referencePattern.matches(
      in: value,
      range: NSRange(value.startIndex..., in: value)
    )
    for match in matches {
      guard let range = Range(match.range, in: value) else { continue }
      let token = String(value[range])
      if batchReferences.contains(token) { return token }
    }
    return nil
  }

  static func durableKeyNumber(reference: String) -> Int? {
    guard
      reference.hasPrefix("T"),
      let number = Int(reference.dropFirst()),
      number > 0,
      reference == "T\(number)"
    else { return nil }
    return number
  }
}

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
        productID: session.productID,
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
      if let epicID = session.epicID {
        try withStatement(
          """
          UPDATE suggestion_sessions
          SET status = 'cancelled', error_message = NULL, updated_at = ?
          WHERE epic_id = ?
            AND id != ?
            AND status = 'failed'
            AND source_work_item_id IS NULL;
          """
        ) { statement in
          try bind(now.timeIntervalSince1970, to: 1, in: statement)
          try bind(epicID.uuidString, to: 2, in: statement)
          try bind(sessionID.uuidString, to: 3, in: statement)
          try stepDone(statement)
        }
        if sqlite3_changes(try requiredDatabase) > 0 {
          _ = try insertEvent(
            productID: session.productID,
            kind: "ticket_suggestions.superseded",
            actor: "system",
            detail: "A completed plan replaced an earlier failed proposal"
          )
        }
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
        productID: source.productID,
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
    productID: UUID,
    idsByReference: [String: UUID],
    existingItemsByKey: [String: WorkItem],
    now: Date
  ) throws {
    // The keys allocated here are final: the reference the owner reads on a
    // proposal is the key the accepted ticket keeps. The allocation and the
    // prose substitution share the caller's transaction, so a failed persist
    // rolls the counter back with everything else.
    let firstKeyNumber = try allocateTicketKeyNumbers(
      productID: productID,
      count: drafts.count
    )
    var keysByBatchReference: [String: String] = [:]
    for (position, draft) in drafts.enumerated() {
      keysByBatchReference[draft.reference] = "T\(firstKeyNumber + position)"
    }
    let batchReferences = Set(drafts.map(\.reference))

    for (position, draft) in drafts.enumerated() {
      guard
        let suggestionID = idsByReference[draft.reference],
        let assignedKey = keysByBatchReference[draft.reference]
      else {
        throw PersistenceError.corruptData("Missing suggestion reference")
      }
      let body = TicketSuggestionKeySubstitution.substitute(
        draft.body,
        keysByBatchReference: keysByBatchReference
      )
      let rationale = TicketSuggestionKeySubstitution.substitute(
        draft.rationale,
        keysByBatchReference: keysByBatchReference
      )
      let acceptanceCriteria = draft.acceptanceCriteria.map {
        TicketSuggestionKeySubstitution.substitute(
          $0,
          keysByBatchReference: keysByBatchReference
        )
      }
      for value in [assignedKey, body, rationale] + acceptanceCriteria {
        if let residual = TicketSuggestionKeySubstitution.residualBatchReference(
          in: value,
          batchReferences: batchReferences
        ) {
          throw PersistenceError.corruptData(
            "The plan could not be stored because temporary reference \(residual) "
              + "was not replaced by its durable ticket key. Generate the plan again."
          )
        }
      }
      try withStatement(
        """
        INSERT INTO ticket_suggestions (
            id, session_id, reference, position, title, body,
            acceptance_criteria_json, suggested_role, priority, rationale,
            status, accepted_work_item_id, created_at, updated_at, ticket_type,
            demo_kind
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(suggestionID.uuidString, to: 1, in: statement)
        try bind(sessionID.uuidString, to: 2, in: statement)
        try bind(assignedKey, to: 3, in: statement)
        try bind(Int64(position), to: 4, in: statement)
        try bind(draft.title, to: 5, in: statement)
        try bind(body, to: 6, in: statement)
        try bind(try encodeStringArray(acceptanceCriteria), to: 7, in: statement)
        try bind(draft.suggestedRole.rawValue, to: 8, in: statement)
        try bind(Int64(draft.priority.rawValue), to: 9, in: statement)
        try bind(rationale, to: 10, in: statement)
        try bind(TicketSuggestionStatus.proposed.rawValue, to: 11, in: statement)
        try bindNull(to: 12, in: statement)
        try bind(now.timeIntervalSince1970, to: 13, in: statement)
        try bind(now.timeIntervalSince1970, to: 14, in: statement)
        try bind(draft.type.rawValue, to: 15, in: statement)
        try bindOptionalString(draft.demoKind?.rawValue, to: 16, in: statement)
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

  /// Settles a generating session whose final-plan turn legitimately returned
  /// questions instead of a plan. The session ends cancelled — not failed — so
  /// no retryable error surfaces and recovery does not resume it; the durable
  /// outcome lives in the epic planning conversation's question payload.
  public func escapeTicketSuggestionSessionToQuestions(sessionID: UUID) throws {
    let session = try fetchSuggestionSession(id: sessionID)
    guard session.status == .generating else { return }
    try transaction {
      try withStatement(
        """
        UPDATE suggestion_sessions
        SET status = 'cancelled', error_message = NULL, updated_at = ?
        WHERE id = ? AND status = 'generating';
        """
      ) { statement in
        try bind(Date().timeIntervalSince1970, to: 1, in: statement)
        try bind(sessionID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: session.productID,
        kind: "ticket_suggestions.escaped_to_questions",
        actor: "system",
        detail: "Planning returned questions for the product owner instead of a plan"
      )
    }
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

  public func fetchOutstandingTicketSuggestionBatches(
    productID: UUID
  ) throws -> [TicketSuggestionBatch] {
    let sessions: [SuggestionSession] = try withStatement(
      """
      SELECT id, product_id, epic_id, source_work_item_id, status, codex_thread_id, codex_turn_id,
             error_message, created_at, updated_at
      FROM suggestion_sessions AS sessions
      WHERE product_id = ?
        AND (
          status IN ('generating', 'failed')
          OR EXISTS (
            SELECT 1
            FROM ticket_suggestions
            WHERE session_id = sessions.id AND status = 'proposed'
          )
        )
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var sessions: [SuggestionSession] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        sessions.append(try decodeSuggestionSession(statement))
      }
      return sessions
    }
    return try sessions.map { try fetchTicketSuggestionBatch(sessionID: $0.id) }
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

  public func updateTicketSuggestion(
    id: UUID,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    suggestedRole: AgentRole,
    priority: WorkItemPriority,
    rationale: String
  ) throws -> TicketSuggestionBatch {
    let suggestion = try fetchTicketSuggestion(id: id)
    let session = try fetchSuggestionSession(id: suggestion.sessionID)
    guard suggestion.status == .proposed else {
      throw PersistenceError.corruptData("Only a proposed ticket can be edited")
    }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw PersistenceError.corruptData("Suggested ticket title cannot be empty")
    }
    let trimmedCriteria =
      acceptanceCriteria
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let now = Date()
    try transaction {
      try withStatement(
        """
        UPDATE ticket_suggestions
        SET title = ?, ticket_type = ?, body = ?, acceptance_criteria_json = ?,
            suggested_role = ?, priority = ?, rationale = ?, updated_at = ?
        WHERE id = ? AND status = 'proposed';
        """
      ) { statement in
        try bind(trimmedTitle, to: 1, in: statement)
        try bind(type.rawValue, to: 2, in: statement)
        try bind(body.trimmingCharacters(in: .whitespacesAndNewlines), to: 3, in: statement)
        try bind(try encodeStringArray(trimmedCriteria), to: 4, in: statement)
        try bind(suggestedRole.rawValue, to: 5, in: statement)
        try bind(Int64(priority.rawValue), to: 6, in: statement)
        try bind(rationale.trimmingCharacters(in: .whitespacesAndNewlines), to: 7, in: statement)
        try bind(now.timeIntervalSince1970, to: 8, in: statement)
        try bind(id.uuidString, to: 9, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: session.productID,
        kind: "ticket_suggestion.edited",
        actor: "owner",
        detail: trimmedTitle
      )
    }
    return try fetchTicketSuggestionBatch(sessionID: session.id)
  }

  public func decideTicketSuggestion(
    id: UUID,
    decision: TicketSuggestionStatus
  ) throws -> TicketSuggestionBatch {
    try decideTicketSuggestionGroup(ids: [id], decision: decision)
  }

  public func decideTicketSuggestionGroup(
    ids: [UUID],
    decision: TicketSuggestionStatus
  ) throws -> TicketSuggestionBatch {
    guard decision == .accepted || decision == .rejected else {
      throw PersistenceError.corruptData("A proposal must be accepted or rejected")
    }
    guard let firstID = ids.first else {
      throw PersistenceError.corruptData("A proposal decision needs at least one ticket")
    }
    let firstSuggestion = try fetchTicketSuggestion(id: firstID)
    let session = try fetchSuggestionSession(id: firstSuggestion.sessionID)
    let batch = try fetchTicketSuggestionBatch(sessionID: session.id)
    let requestedIDs = Set(ids)
    guard requestedIDs.isSubset(of: Set(batch.suggestions.map(\.id))) else {
      throw PersistenceError.corruptData("A proposal batch cannot cross sessions")
    }
    if decision == .rejected {
      return try rejectTicketSuggestions(
        rootIDs: requestedIDs,
        batch: batch,
        session: session
      )
    }
    return try acceptTicketSuggestions(
      rootIDs: requestedIDs,
      batch: batch,
      session: session
    )
  }

  private func acceptTicketSuggestions(
    rootIDs: Set<UUID>,
    batch: TicketSuggestionBatch,
    session: SuggestionSession
  ) throws -> TicketSuggestionBatch {
    var acceptedSuggestionIDs: Set<UUID> = []
    var suggestionsToAccept: [TicketSuggestion] = []
    for suggestion in batch.suggestions
    where rootIDs.contains(suggestion.id) && suggestion.status == .proposed {
      for affected in try suggestedPrerequisiteClosure(including: suggestion, in: batch)
      where acceptedSuggestionIDs.insert(affected.id).inserted {
        suggestionsToAccept.append(affected)
      }
    }
    guard !suggestionsToAccept.isEmpty else { return batch }
    let acceptedAt = Date()

    try transaction {
      for affected in suggestionsToAccept {
        // The proposal already carries its durable key from persist time;
        // acceptance is a state change that copies the reviewed text
        // verbatim, never a renumbering.
        guard
          let keyNumber = TicketSuggestionKeySubstitution.durableKeyNumber(
            reference: affected.reference
          )
        else {
          throw PersistenceError.corruptData(
            "Proposal \(affected.reference) has no durable ticket key and cannot be accepted"
          )
        }
        let workItem = try insertWorkItem(
          productID: session.productID,
          title: affected.title,
          type: affected.type,
          body: affected.body,
          acceptanceCriteria: affected.acceptanceCriteria,
          priority: affected.priority,
          epicID: session.epicID,
          demoKind: affected.demoKind,
          preassignedKeyNumber: keyNumber
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
    try decideTicketSuggestionGroup(ids: [id], decision: .rejected)
  }

  private func rejectTicketSuggestions(
    rootIDs: Set<UUID>,
    batch: TicketSuggestionBatch,
    session: SuggestionSession
  ) throws -> TicketSuggestionBatch {
    let proposedRootIDs = Set(
      batch.suggestions
        .filter { rootIDs.contains($0.id) && $0.status == .proposed }
        .map(\.id)
    )
    guard !proposedRootIDs.isEmpty else { return batch }

    var cascadeIDs = proposedRootIDs
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
    let planningStates: Set<WorkItemState> = [.backlog, .refining, .ready]
    var acceptedWorkItemIDs: Set<UUID> = []
    for dependent in affectedSuggestions where dependent.status == .accepted {
      guard let workItemID = dependent.acceptedWorkItemID else {
        throw PersistenceError.corruptData(
          "An accepted dependent suggestion has no backlog ticket"
        )
      }
      let workItem = try fetchWorkItem(id: workItemID)
      if planningStates.contains(workItem.state) {
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
            proposedRootIDs.contains(affected.id)
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
