import Foundation
import SQLite3

extension SQLiteStore {
  public func saveDraftSprint(
    productID: UUID,
    goal: String,
    tokenBudgetLimit: Int?,
    items inputs: [SprintDraftItemInput]
  ) throws -> SprintPlan {
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
      draft.planVersion += 1
      draft.updatedAt = now
      sprint = draft
    } else {
      sprint = Sprint(
        productID: productID,
        number: try nextSprintNumber(productID: productID),
        goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
        tokenBudgetLimit: tokenBudgetLimit,
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
        actor: "Product owner",
        detail: "Sprint \(sprint.number), plan v\(sprint.planVersion): \(sprintItems.count) tickets"
      )
    }

    return SprintPlan(sprint: sprint, items: sprintItems)
  }

  public func saveGeneratedSprintGoal(
    id: UUID,
    goal: String,
    expectedPlanVersion: Int
  ) throws -> SprintPlan {
    let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedGoal.isEmpty else {
      throw SprintPlanningError.notReady(["The generated sprint goal was empty."])
    }

    var sprint = try fetchSprint(id: id)
    if !sprint.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }
    guard [.draft, .active, .paused].contains(sprint.state) else {
      throw SprintPlanningError.planChanged
    }
    guard sprint.planVersion == expectedPlanVersion else {
      throw SprintPlanningError.planChanged
    }

    let now = Date()
    sprint.goal = trimmedGoal
    sprint.planVersion += 1
    sprint.updatedAt = now

    try transaction {
      try withStatement(
        """
        UPDATE sprints
        SET goal = ?, plan_version = ?, updated_at = ?
        WHERE id = ? AND state IN ('draft', 'active', 'paused');
        """
      ) { statement in
        try bind(sprint.goal, to: 1, in: statement)
        try bind(Int64(sprint.planVersion), to: 2, in: statement)
        try bind(sprint.updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(sprint.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: sprint.productID,
        kind: "sprint.goal_generated",
        actor: "Business analyst",
        detail: "Sprint \(sprint.number), plan v\(sprint.planVersion)"
      )
    }

    return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
  }

  public func fetchCurrentSprint(productID: UUID) throws -> SprintPlan? {
    guard
      let sprint = try withStatement(
        """
        SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
               plan_version, started_at, completed_at,
               retrospective_concluded_at, created_at, updated_at
        FROM sprints
        WHERE product_id = ? AND state IN ('active', 'paused', 'draft')
        ORDER BY CASE state WHEN 'active' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END,
                 created_at DESC
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

  /// The sprint currently being planned, if any.
  ///
  /// `fetchCurrentSprint` prefers an active or paused sprint, so it cannot
  /// answer questions about the draft that is being planned alongside a sprint
  /// already in progress. Draft-scoped mutations must resolve the sprint here.
  public func fetchDraftSprint(productID: UUID) throws -> SprintPlan? {
    guard let sprint = try fetchSprint(productID: productID, state: .draft) else {
      return nil
    }
    return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: sprint.id))
  }

  public func fetchSprintHistory(productID: UUID) throws -> [SprintPlan] {
    let sprints = try withStatement(
      """
      SELECT id, product_id, sprint_number, goal, state, token_budget_limit,
             plan_version, started_at, completed_at,
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
      return sprint.state.isInProgress
        ? []
        : [SprintReadinessIssue(id: "sprint.state", message: "This sprint is not a draft.")]
    }

    let items = try fetchSprintItems(sprintID: sprintID)
    let sprintWorkItemIDs = Set(items.map(\.workItemID))
    let activeSprintWorkItemIDs: Set<UUID>
    if let activeSprint = try fetchInProgressSprint(productID: sprint.productID),
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
              message:
                "\(workItem.key) is blocked by \(prerequisite.key), which is not in this sprint, the active sprint, or done."
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
      if let otherActive = try fetchInProgressSprint(productID: sprint.productID),
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
          actor: "Sprint scheduler",
          detail: "Authorized by sprint \(sprint.number), plan v\(sprint.planVersion)"
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
        actor: "Product owner",
        detail:
          "Sprint \(sprint.number), plan v\(sprint.planVersion): \(items.count) tickets authorized"
      )
    }

    return SprintPlan(
      sprint: try fetchSprint(id: id),
      items: try fetchSprintItems(sprintID: id)
    )
  }

  public func pauseSprint(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    if sprint.state == .paused {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }
    guard sprint.state == .active else {
      throw PersistenceError.corruptData("Only an active sprint can be paused.")
    }

    let now = Date()
    sprint.state = .paused
    sprint.updatedAt = now
    try transaction {
      try withStatement(
        "UPDATE sprints SET state = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(sprint.state.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(sprint.id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: sprint.productID,
        kind: "sprint.paused",
        actor: "Product owner",
        detail: "Sprint \(sprint.number): delivery paused"
      )
    }
    return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
  }

  public func resumeSprint(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    if sprint.state == .active {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }
    guard sprint.state == .paused else {
      throw PersistenceError.corruptData("Only a paused sprint can be resumed.")
    }
    if let otherActive = try fetchSprint(productID: sprint.productID, state: .active),
      otherActive.id != sprint.id
    {
      throw SprintPlanningError.activeSprintExists
    }

    let now = Date()
    sprint.state = .active
    sprint.updatedAt = now
    try transaction {
      try withStatement(
        "UPDATE sprints SET state = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(sprint.state.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(sprint.id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: sprint.productID,
        kind: "sprint.resumed",
        actor: "Product owner",
        detail: "Sprint \(sprint.number): preserved delivery resumed"
      )
    }
    return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
  }

  public func cancelSprint(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    if sprint.state == .cancelled {
      return SprintPlan(sprint: sprint, items: try fetchSprintItems(sprintID: id))
    }
    guard sprint.state.isInProgress else {
      throw PersistenceError.corruptData("Only a sprint in progress can be stopped.")
    }

    let items = try fetchSprintItems(sprintID: id)
    let unfinishedItems =
      try items
      .map { try fetchWorkItem(id: $0.workItemID) }
      .filter { $0.state != .released && $0.state != .cancelled }
    let now = Date()
    sprint.state = .cancelled
    sprint.updatedAt = now

    try transaction {
      for item in unfinishedItems {
        if item.state != .ready {
          try withStatement(
            "UPDATE work_items SET state = 'ready', version = ?, updated_at = ? WHERE id = ?;"
          ) { statement in
            try bind(Int64(item.version + 1), to: 1, in: statement)
            try bind(now.timeIntervalSince1970, to: 2, in: statement)
            try bind(item.id.uuidString, to: 3, in: statement)
            try stepDone(statement)
          }
          _ = try insertEvent(
            productID: sprint.productID,
            workItemID: item.id,
            kind: "work_item.transitioned",
            actor: "Product owner",
            detail:
              "\(item.state.rawValue) -> ready: sprint \(sprint.number) stopped; returned for replanning"
          )
        }

        let comment = TicketComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "Sprint \(sprint.number) was stopped by the product owner. This unfinished ticket returned to Ready for replanning. Its work log, conversation, and any preserved workspace or candidate history remain available for audit; no unaccepted candidate was promoted."
        )
        try withStatement(
          """
          INSERT INTO ticket_comments (
              id, work_item_id, author_kind, author_name, body,
              owner_question_json, answered_questions_json, created_at
          ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?);
          """
        ) { statement in
          try bind(comment.id.uuidString, to: 1, in: statement)
          try bind(comment.workItemID.uuidString, to: 2, in: statement)
          try bind(comment.authorKind.rawValue, to: 3, in: statement)
          try bind(comment.authorName, to: 4, in: statement)
          try bind(comment.body, to: 5, in: statement)
          try bind(comment.createdAt.timeIntervalSince1970, to: 6, in: statement)
          try stepDone(statement)
        }
        _ = try insertEvent(
          productID: sprint.productID,
          workItemID: item.id,
          kind: "comment.created",
          actor: comment.authorName,
          detail: comment.body
        )
      }

      try withStatement(
        """
        UPDATE agent_runs
        SET status = 'cancelled',
            active_duration_seconds = active_duration_seconds
              + CASE
                  WHEN status = 'running' AND turn_started_at IS NOT NULL
                  THEN MAX(0, ? - turn_started_at)
                  ELSE 0
                END,
            turn_started_at = NULL,
            updated_at = ?
        WHERE sprint_id = ? AND status NOT IN ('completed', 'cancelled');
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(sprint.id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        """
        UPDATE candidate_revisions
        SET status = 'superseded', updated_at = ?
        WHERE sprint_id = ? AND status NOT IN ('accepted', 'superseded');
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(sprint.id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        """
        UPDATE knowledge_page_proposals
        SET status = 'superseded', updated_at = ?
        WHERE sprint_id = ? AND status IN ('proposed', 'reviewed', 'accepted');
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(sprint.id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        """
        UPDATE demo_sessions
        SET status = 'stopped', allocated_port = NULL, updated_at = ?
        WHERE source_kind = 'accepted_candidate' AND launch_id IN (
          SELECT id FROM candidate_revisions WHERE sprint_id = ?
        ) AND status IN ('preparing', 'starting', 'ready');
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(sprint.id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        "UPDATE sprints SET state = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(sprint.state.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(sprint.id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: sprint.productID,
        kind: "sprint.cancelled",
        actor: "Product owner",
        detail:
          "Sprint \(sprint.number): stopped with \(unfinishedItems.count) unfinished ticket\(unfinishedItems.count == 1 ? "" : "s") returned to Ready"
      )
    }

    return SprintPlan(sprint: sprint, items: items)
  }

  public func completeSprintIfFinished(id: UUID) throws -> SprintPlan {
    var sprint = try fetchSprint(id: id)
    guard sprint.state.isInProgress else {
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
        actor: "Spedito",
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
        actor: "Product owner",
        detail: "Sprint \(sprint.number) retrospective concluded"
      )
    }
    return SprintPlan(
      sprint: try fetchSprint(id: id),
      items: try fetchSprintItems(sprintID: id)
    )
  }

}
