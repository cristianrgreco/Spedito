import Foundation
import SQLite3

extension SQLiteStore {
  public func saveRetrospectiveNotes(_ notes: [RetrospectiveNote]) throws {
    guard !notes.isEmpty else { return }
    try transaction {
      for note in notes {
        _ = try insertRetrospectiveNoteIfNeeded(note)
      }
    }
  }

  public func captureRetrospectiveActionIdea(
    productID: UUID,
    sprintID: UUID,
    body: String
  ) throws -> RetrospectiveNote {
    let sprint = try fetchSprint(id: sprintID)
    guard sprint.productID == productID else {
      throw PersistenceError.corruptData(
        "The retrospective does not belong to the selected product."
      )
    }
    guard sprint.state.isInProgress else {
      throw PersistenceError.corruptData(
        "Retrospective action ideas can only be added while the sprint is in progress."
      )
    }

    let actionIdea = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !actionIdea.isEmpty else {
      throw PersistenceError.corruptData(
        "A retrospective action idea needs a description."
      )
    }

    let note = RetrospectiveNote(
      productID: productID,
      sprintID: sprintID,
      authorName: "Product owner",
      category: .suggestedAction,
      body: actionIdea,
      isActionCandidate: true
    )
    let persistedID = try transaction {
      let persistedID = try insertRetrospectiveNoteIfNeeded(note)
      _ = try insertEvent(
        productID: productID,
        kind: "retrospective.action_idea_captured",
        actor: "Product owner",
        detail: persistedID.uuidString
      )
      return persistedID
    }
    return try fetchRetrospectiveNote(id: persistedID)
  }

  public func deleteRetrospectiveActionIdea(noteID: UUID) throws {
    let note = try fetchRetrospectiveNote(id: noteID)
    guard
      note.authorName == "Product owner",
      note.profileID == nil,
      note.category == .suggestedAction,
      note.isActionCandidate,
      note.actionStatus == nil,
      note.synthesisID == nil
    else {
      throw PersistenceError.corruptData(
        "Only product owner action ideas can be deleted."
      )
    }

    let sprint = try fetchSprint(id: note.sprintID)
    guard
      sprint.productID == note.productID,
      sprint.state.isInProgress
    else {
      throw PersistenceError.corruptData(
        "Action ideas can only be deleted while the sprint is in progress."
      )
    }

    try transaction {
      try withStatement(
        "DELETE FROM retrospective_notes WHERE id = ?;"
      ) { statement in
        try bind(noteID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: note.productID,
        kind: "retrospective.action_idea_deleted",
        actor: "Product owner",
        detail: note.id.uuidString
      )
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
      authorName: "Product owner",
      category: .suggestedAction,
      body: proposal,
      actionStatus: .proposed,
      actionDestination: destination
    )
    let persistedID = try transaction {
      let persistedID = try insertRetrospectiveNoteIfNeeded(note)
      _ = try insertEvent(
        productID: productID,
        kind: "retrospective.action_proposed",
        actor: "Product owner",
        detail: persistedID.uuidString
      )
      return persistedID
    }
    return try fetchRetrospectiveNote(id: persistedID)
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
        "A business analyst must prepare the final retrospective actions."
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
    guard
      actions.allSatisfy({
        !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.expectedEffect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.sourceNoteIDs.isEmpty
          && Set($0.sourceNoteIDs).isSubset(of: allowedSourceIDs)
      })
    else {
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
        let actionNoteID = try insertRetrospectiveNoteIfNeeded(note)
        for sourceNoteID in Set(action.sourceNoteIDs) {
          try withStatement(
            """
            INSERT OR IGNORE INTO retrospective_action_sources (
                action_note_id, source_note_id
            ) VALUES (?, ?);
            """
          ) { statement in
            try bind(actionNoteID.uuidString, to: 1, in: statement)
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
        actor: "Product owner",
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

  func fetchRetrospectiveNote(id: UUID) throws -> RetrospectiveNote {
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

  func insertRetrospectiveNoteIfNeeded(_ note: RetrospectiveNote) throws -> UUID {
    let alreadyPersistedID = try withStatement(
      """
      SELECT id
      FROM retrospective_notes
      WHERE sprint_id = ?
        AND work_item_id IS ?
        AND profile_id IS ?
        AND category = ?
        AND body = ?
      LIMIT 1;
      """
    ) { statement -> UUID? in
      try bind(note.sprintID.uuidString, to: 1, in: statement)
      try bindOptionalUUID(note.workItemID, to: 2, in: statement)
      try bindOptionalUUID(note.profileID, to: 3, in: statement)
      try bind(note.category.rawValue, to: 4, in: statement)
      try bind(note.body, to: 5, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      guard let id = UUID(uuidString: try text(statement, column: 0)) else {
        throw PersistenceError.corruptData("Invalid retrospective note identity")
      }
      return id
    }
    if let alreadyPersistedID { return alreadyPersistedID }
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
    return note.id
  }

  func fetchRetrospectiveSynthesis(
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

  func fetchRetrospectiveSynthesis(
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

  func decodeRetrospectiveSynthesis(
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

  func insertRetrospectiveSynthesisIfNeeded(
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

  func updateRetrospectiveSynthesis(
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
            "Suggested by the sprint retrospective. Refine this improvement before planning it.",
          acceptanceCriteria: [],
          priority: .normal
        )
        if let createdItem {
          _ = try insertEvent(
            productID: note.productID,
            workItemID: createdItem.id,
            kind: "work_item.created_from_retrospective",
            actor: "Product owner",
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
          authorName: "Product owner",
          changeSummary: "Adopted a sprint retrospective practice",
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
        actor: "Product owner",
        detail: practice
      )
    }
    return page
  }

  func validateRetrospectiveDecision(_ note: RetrospectiveNote) throws {
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

}
