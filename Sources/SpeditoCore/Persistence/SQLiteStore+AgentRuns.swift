import Foundation
import SQLite3

extension SQLiteStore {
  public func fetchAgentRuns(productID: UUID) throws -> [AgentRun] {
    try fetchAgentRuns(where: "product_id = ?", id: productID)
  }

  func fetchSprintExecutionAgentRuns(sprintID: UUID) throws -> [AgentRun] {
    try fetchAgentRuns(where: "sprint_id = ?", id: sprintID)
  }

  private func fetchAgentRuns(where predicate: String, id: UUID) throws -> [AgentRun] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id, profile_id,
             status, codex_thread_id, worktree_path, ticket_budget_used,
             context_used_tokens, context_window_tokens, compaction_count,
             created_at, updated_at, turn_started_at, last_activity_at,
             last_activity_text, last_activity_kind, active_duration_seconds,
             execution_constraint_kind, execution_constraint_observed_at,
             execution_constraint_retry_at, execution_constraint_evidence
      FROM agent_runs
      WHERE \(predicate)
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
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
            executionConstraint: try decodeAgentRunExecutionConstraint(
              statement,
              kindColumn: 20,
              observedAtColumn: 21,
              retryAtColumn: 22,
              evidenceColumn: 23
            ),
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
             last_activity_text, last_activity_kind, active_duration_seconds,
             execution_constraint_kind, execution_constraint_observed_at,
             execution_constraint_retry_at, execution_constraint_evidence
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
        executionConstraint: try decodeAgentRunExecutionConstraint(
          statement,
          kindColumn: 20,
          observedAtColumn: 21,
          retryAtColumn: 22,
          evidenceColumn: 23
        ),
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
    let additionalActiveDuration =
      closesActiveTurn
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
      if status != .queued {
        try writeAgentRunExecutionConstraint(id: id, constraint: nil, updatedAt: now)
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

  public func setAgentRunExecutionConstraint(
    id: UUID,
    constraint: AgentRunExecutionConstraint?
  ) throws -> AgentRun {
    let existing = try fetchAgentRun(id: id)
    guard existing.status == .queued || constraint == nil else {
      throw PersistenceError.corruptData(
        "Only a queued agent run can wait for an execution constraint."
      )
    }
    try writeAgentRunExecutionConstraint(
      id: id,
      constraint: constraint,
      updatedAt: Date()
    )
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

  private func writeAgentRunExecutionConstraint(
    id: UUID,
    constraint: AgentRunExecutionConstraint?,
    updatedAt: Date
  ) throws {
    try withStatement(
      """
      UPDATE agent_runs
      SET execution_constraint_kind = ?,
          execution_constraint_observed_at = ?,
          execution_constraint_retry_at = ?,
          execution_constraint_evidence = ?,
          updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bindOptionalString(constraint?.kind.rawValue, to: 1, in: statement)
      try bindOptionalDate(constraint?.observedAt, to: 2, in: statement)
      try bindOptionalDate(constraint?.retryAt, to: 3, in: statement)
      try bindOptionalString(constraint?.technicalEvidence, to: 4, in: statement)
      try bind(updatedAt.timeIntervalSince1970, to: 5, in: statement)
      try bind(id.uuidString, to: 6, in: statement)
      try stepDone(statement)
    }
  }

  private func decodeAgentRunExecutionConstraint(
    _ statement: OpaquePointer,
    kindColumn: Int32,
    observedAtColumn: Int32,
    retryAtColumn: Int32,
    evidenceColumn: Int32
  ) throws -> AgentRunExecutionConstraint? {
    guard let rawKind = try optionalText(statement, column: kindColumn) else {
      return nil
    }
    guard
      let kind = AgentRunExecutionConstraintKind(rawValue: rawKind),
      let observedAt = optionalDate(statement, column: observedAtColumn)
    else {
      throw PersistenceError.corruptData("Invalid agent run execution constraint")
    }
    return AgentRunExecutionConstraint(
      kind: kind,
      observedAt: observedAt,
      retryAt: optionalDate(statement, column: retryAtColumn),
      technicalEvidence: try optionalText(statement, column: evidenceColumn)
    )
  }

}
