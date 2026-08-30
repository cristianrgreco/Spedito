import Foundation
import SQLite3

public enum InvalidCandidateRecoveryError: Error, Equatable, LocalizedError, Sendable {
  case invalidCandidateState
  case invalidReferences
  case invalidTicketState(String)
  case persistence(String)

  public var errorDescription: String? {
    switch self {
    case .invalidCandidateState:
      "The candidate is no longer awaiting ready-for-demo recovery."
    case .invalidReferences:
      "The candidate recovery records do not belong to one product and ticket."
    case .invalidTicketState(let state):
      "The ticket cannot resume from \(state)."
    case .persistence(let detail):
      "The recovery transaction failed: \(detail)"
    }
  }
}

public enum TicketDeliveryRecoveryMutation: Sendable {
  case updateCandidate(
    id: UUID,
    expectedStatuses: Set<CandidateRevisionStatus>,
    status: CandidateRevisionStatus,
    integratedSHA: String? = nil,
    integrationWorktreePath: String? = nil
  )
  case updateRun(
    id: UUID,
    expectedStatuses: Set<AgentRunStatus>,
    status: AgentRunStatus,
    worktreePath: String? = nil,
    eventDetail: String? = nil
  )
  case createRunIfAbsent(AgentRun, notBefore: Date)
  case transitionWorkItem(
    id: UUID,
    expectedStates: Set<WorkItemState>,
    states: [WorkItemState],
    reasons: [String]
  )
  case updatePermissionRequest(
    id: UUID,
    expectedStatuses: Set<AgentPermissionRequestStatus>,
    status: AgentPermissionRequestStatus
  )
  case appendComment(body: String)
}

public enum TicketDeliveryRecoveryError: Error, Equatable, LocalizedError, Sendable {
  case invalidReferences
  case staleCandidate
  case staleRun
  case staleWorkItem
  case stalePermissionRequest
  case invalidTransition
  case persistence(String)

  public var errorDescription: String? {
    switch self {
    case .invalidReferences:
      "The delivery recovery records do not belong to one product and ticket."
    case .staleCandidate:
      "The candidate changed before delivery recovery could claim it."
    case .staleRun:
      "The team member run changed before delivery recovery could claim it."
    case .staleWorkItem:
      "The ticket changed before delivery recovery could claim it."
    case .stalePermissionRequest:
      "The permission request changed before delivery recovery could claim it."
    case .invalidTransition:
      "The delivery recovery transition is incomplete."
    case .persistence(let detail):
      "The delivery recovery transaction failed: \(detail)"
    }
  }
}

public struct DeliveryResultSettlementPreparation: Equatable, Sendable {
  public let operationID: UUID
  public let candidateVersion: Int
  public let existingCandidate: CandidateRevision?

  public init(
    operationID: UUID,
    candidateVersion: Int,
    existingCandidate: CandidateRevision?
  ) {
    self.operationID = operationID
    self.candidateVersion = candidateVersion
    self.existingCandidate = existingCandidate
  }
}

public struct CompletedDeliverySettlement: Equatable, Sendable {
  public let candidate: CandidateRevision
  public let comment: TicketComment?
  public let run: AgentRun
  public let inserted: Bool

  public init(
    candidate: CandidateRevision,
    comment: TicketComment?,
    run: AgentRun,
    inserted: Bool
  ) {
    self.candidate = candidate
    self.comment = comment
    self.run = run
    self.inserted = inserted
  }
}


extension SQLiteStore {
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
    try insertCandidateRevision(candidate)
    return try fetchCandidateRevision(id: candidate.id)
  }

  func insertCandidateRevision(_ candidate: CandidateRevision) throws {
    try withStatement(
      """
      INSERT INTO candidate_revisions (
          id, product_id, sprint_id, sprint_item_id, work_item_id,
          implementation_run_id, version, branch_name, base_sha, head_sha,
          integrated_sha, worktree_path, integration_worktree_path, status,
          commit_count, execution_result_json, created_at, updated_at, delivery_kind,
          reviewed_head_sha, review_run_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
      try bind(candidate.deliveryKind.rawValue, to: 19, in: statement)
      try bindOptionalString(candidate.reviewedHeadSHA, to: 20, in: statement)
      try bindOptionalUUID(candidate.reviewRunID, to: 21, in: statement)
      try stepDone(statement)
    }
  }

  public func prepareCompletedDeliverySettlement(
    runID: UUID,
    operationID: UUID = UUID()
  ) throws -> DeliveryResultSettlementPreparation {
    try transaction {
      let run = try fetchAgentRun(id: runID)
      let persisted = try deliverySettlementIdentity(runID: runID)
      let identity: (operationID: UUID, version: Int)

      switch persisted {
      case (nil, nil):
        let version = try nextCandidateRevisionVersion(workItemID: run.workItemID)
        try withStatement(
          """
          UPDATE agent_runs
          SET settlement_operation_id = ?,
              settlement_candidate_version = ?,
              updated_at = ?
          WHERE id = ?
            AND settlement_operation_id IS NULL
            AND settlement_candidate_version IS NULL;
          """
        ) { statement in
          try bind(operationID.uuidString, to: 1, in: statement)
          try bind(Int64(version), to: 2, in: statement)
          try bind(Date().timeIntervalSince1970, to: 3, in: statement)
          try bind(runID.uuidString, to: 4, in: statement)
          try stepDone(statement)
        }
        identity = (operationID, version)
      case let (.some(persistedOperationID), .some(version)):
        identity = (persistedOperationID, version)
      default:
        throw PersistenceError.corruptData(
          "Agent run \(runID) has an incomplete delivery settlement identity."
        )
      }

      return DeliveryResultSettlementPreparation(
        operationID: identity.operationID,
        candidateVersion: identity.version,
        existingCandidate: try fetchCandidateRevision(
          implementationRunID: runID,
          version: identity.version
        )
      )
    }
  }

  /// Sends a candidate back to its implementer for another attempt.
  ///
  /// Marking the candidate and releasing the run's settlement identity are one
  /// durable step because they are one decision: this candidate is superseded,
  /// so whatever the run delivers next is a new version. Two separate call sites
  /// send a candidate back — a tech lead requesting changes, and a managed demo
  /// failing verification — and the second was written without the release, so
  /// its corrections were silently discarded exactly as the first one's were.
  /// Keeping them together means a third caller cannot forget.
  public func requestCandidateChanges(
    candidateID: UUID,
    implementationRunID: UUID
  ) throws -> CandidateRevision {
    try transaction {
      let updated = try updateCandidateRevision(id: candidateID, status: .changesRequested)
      try releaseDeliverySettlementIdentity(runID: implementationRunID)
      return updated
    }
  }

  /// Releases a run's settlement identity so its next completed delivery
  /// settles as a new candidate rather than being recognised as one already
  /// settled.
  ///
  /// The identity is an idempotency token for one delivery attempt: it is what
  /// stops a run that is recovered after a restart from creating a second
  /// candidate for work it already settled. A run resumed to apply review
  /// feedback is not that case — it is a new attempt, and its result belongs in
  /// the next candidate version.
  ///
  /// Without this, the resumed run keeps the identity of the candidate the tech
  /// lead just rejected, so `prepareCompletedDeliverySettlement` reports that
  /// candidate as already existing and the revision is discarded in silence.
  /// Three live runs ended that way: the agent finished, nothing was recorded,
  /// and the board told the product owner an agent was still working for the
  /// rest of the sprint.
  public func releaseDeliverySettlementIdentity(runID: UUID) throws {
    try withStatement(
      """
      UPDATE agent_runs
      SET settlement_operation_id = NULL,
          settlement_candidate_version = NULL,
          updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      try bind(runID.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
  }

  public func settleCompletedDelivery(
    candidate: CandidateRevision,
    operationID: UUID,
    comment: TicketComment,
    deliveryNoteMarkdown: String,
    sprint: Sprint,
    knowledgePageProposals: [KnowledgePageProposal],
    retrospectiveNotes: [RetrospectiveNote],
    eventActor: String,
    eventDetail: String,
    at date: Date = Date()
  ) throws -> CompletedDeliverySettlement {
    try transaction {
      let run = try fetchAgentRun(id: candidate.implementationRunID)
      guard
        run.productID == candidate.productID,
        run.sprintID == candidate.sprintID,
        run.sprintItemID == candidate.sprintItemID,
        run.workItemID == candidate.workItemID
      else {
        throw PersistenceError.corruptData(
          "Delivery settlement candidate does not belong to its implementation run."
        )
      }

      let identity = try deliverySettlementIdentity(runID: run.id)
      guard
        identity.operationID == operationID,
        identity.version == candidate.version
      else {
        throw PersistenceError.corruptData(
          "Delivery settlement identity changed before the result could be committed."
        )
      }

      if let existing = try fetchCandidateRevision(
        implementationRunID: run.id,
        version: candidate.version
      ) {
        return CompletedDeliverySettlement(
          candidate: existing,
          comment: nil,
          run: try fetchAgentRun(id: run.id),
          inserted: false
        )
      }
      guard run.status == .running else {
        throw PersistenceError.corruptData(
          "Agent run \(run.id) cannot settle a completed result from \(run.status.rawValue)."
        )
      }

      let workItem = try fetchWorkItem(id: candidate.workItemID)
      let targetState = WorkItemState.integrating
      try workflowPolicy.validateTransition(from: workItem.state, to: targetState)

      try insertCandidateRevision(candidate)
      _ = try upsertDeliveryNote(
        productID: workItem.productID,
        sprint: sprint,
        item: workItem,
        bodyMarkdown: deliveryNoteMarkdown,
        authorName: comment.authorName
      )
      for note in retrospectiveNotes {
        _ = try insertRetrospectiveNoteIfNeeded(note)
      }
      try insertKnowledgePageProposals(knowledgePageProposals)
      let persistedComment = try appendComment(
        workItemID: comment.workItemID,
        authorKind: comment.authorKind,
        authorName: comment.authorName,
        body: comment.body,
        ownerQuestion: comment.ownerQuestion,
        answeredQuestions: comment.answeredQuestions,
        authorAvatarURL: comment.authorAvatarURL,
        externalURL: comment.externalURL,
        externalID: comment.externalID,
        githubReviewContext: comment.githubReviewContext,
        createdAt: comment.createdAt
      )

      let activeDuration =
        run.activeDurationSeconds
        + (run.turnStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
      try withStatement(
        """
        UPDATE agent_runs
        SET status = ?,
            active_duration_seconds = ?,
            turn_started_at = NULL,
            execution_constraint_kind = NULL,
            execution_constraint_observed_at = NULL,
            execution_constraint_retry_at = NULL,
            execution_constraint_evidence = NULL,
            updated_at = ?
        WHERE id = ?
          AND status = ?
          AND settlement_operation_id = ?
          AND settlement_candidate_version = ?;
        """
      ) { statement in
        try bind(AgentRunStatus.completed.rawValue, to: 1, in: statement)
        try bind(activeDuration, to: 2, in: statement)
        try bind(date.timeIntervalSince1970, to: 3, in: statement)
        try bind(run.id.uuidString, to: 4, in: statement)
        try bind(AgentRunStatus.running.rawValue, to: 5, in: statement)
        try bind(operationID.uuidString, to: 6, in: statement)
        try bind(Int64(candidate.version), to: 7, in: statement)
        try stepDone(statement)
      }

      try withStatement(
        "UPDATE work_items SET state = ?, version = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(targetState.rawValue, to: 1, in: statement)
        try bind(Int64(workItem.version + 1), to: 2, in: statement)
        try bind(date.timeIntervalSince1970, to: 3, in: statement)
        try bind(workItem.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItem.id,
        kind: "work_item.transitioned",
        actor: eventActor,
        detail: "\(workItem.state.rawValue) -> \(targetState.rawValue): \(eventDetail)"
      )

      return CompletedDeliverySettlement(
        candidate: try fetchCandidateRevision(id: candidate.id),
        comment: persistedComment,
        run: try fetchAgentRun(id: run.id),
        inserted: true
      )
    }
  }

  private func deliverySettlementIdentity(
    runID: UUID
  ) throws -> (operationID: UUID?, version: Int?) {
    try withStatement(
      """
      SELECT settlement_operation_id, settlement_candidate_version
      FROM agent_runs
      WHERE id = ?;
      """
    ) { statement in
      try bind(runID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("Agent run \(runID)")
      }
      let operationID = try optionalText(statement, column: 0).flatMap(UUID.init(uuidString:))
      let version = optionalInt(statement, column: 1)
      return (operationID, version)
    }
  }

  private func fetchCandidateRevision(
    implementationRunID: UUID,
    version: Int
  ) throws -> CandidateRevision? {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id,
             implementation_run_id, version, branch_name, base_sha, head_sha,
             integrated_sha, worktree_path, integration_worktree_path, status,
             commit_count, execution_result_json, created_at, updated_at, delivery_kind,
             reviewed_head_sha, review_run_id
      FROM candidate_revisions
      WHERE implementation_run_id = ? AND version = ?;
      """
    ) { statement in
      try bind(implementationRunID.uuidString, to: 1, in: statement)
      try bind(Int64(version), to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeCandidateRevision(statement)
    }
  }

  public func fetchCandidateRevisions(productID: UUID) throws -> [CandidateRevision] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id,
             implementation_run_id, version, branch_name, base_sha, head_sha,
             integrated_sha, worktree_path, integration_worktree_path, status,
             commit_count, execution_result_json, created_at, updated_at, delivery_kind,
             reviewed_head_sha, review_run_id
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

  func fetchSprintExecutionCandidateRevisions(
    sprintID: UUID
  ) throws -> [CandidateRevision] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, sprint_item_id, work_item_id,
             implementation_run_id, version, branch_name, base_sha, head_sha,
             integrated_sha, worktree_path, integration_worktree_path, status,
             commit_count, execution_result_json, created_at, updated_at, delivery_kind,
             reviewed_head_sha, review_run_id
      FROM candidate_revisions
      WHERE sprint_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(sprintID.uuidString, to: 1, in: statement)
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
             commit_count, execution_result_json, created_at, updated_at, delivery_kind,
             reviewed_head_sha, review_run_id
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
    integrationWorktreePath: String? = nil,
    reviewedHeadSHA: String? = nil,
    reviewRunID: UUID? = nil
  ) throws -> CandidateRevision {
    let now = Date()
    try withStatement(
      """
      UPDATE candidate_revisions
      SET status = ?,
          integrated_sha = COALESCE(?, integrated_sha),
          integration_worktree_path = COALESCE(?, integration_worktree_path),
          reviewed_head_sha = COALESCE(?, reviewed_head_sha),
          review_run_id = COALESCE(?, review_run_id),
          updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bindOptionalString(integratedSHA, to: 2, in: statement)
      try bindOptionalString(integrationWorktreePath, to: 3, in: statement)
      try bindOptionalString(reviewedHeadSHA, to: 4, in: statement)
      try bindOptionalUUID(reviewRunID, to: 5, in: statement)
      try bind(now.timeIntervalSince1970, to: 6, in: statement)
      try bind(id.uuidString, to: 7, in: statement)
      try stepDone(statement)
    }
    return try fetchCandidateRevision(id: id)
  }

  public func recoverInvalidReadyForDemoCandidate(
    candidateID: UUID,
    runEventDetail: String,
    transitionReason: String,
    commentBody: String
  ) throws {
    do {
      try transaction {
        let candidate = try fetchCandidateRevision(id: candidateID)
        guard candidate.status == .readyForDemo || candidate.status == .superseded else {
          throw InvalidCandidateRecoveryError.invalidCandidateState
        }

        let implementationRun = try fetchAgentRun(id: candidate.implementationRunID)
        let workItem = try fetchWorkItem(id: candidate.workItemID)
        guard
          implementationRun.productID == candidate.productID,
          implementationRun.workItemID == candidate.workItemID,
          workItem.productID == candidate.productID
        else {
          throw InvalidCandidateRecoveryError.invalidReferences
        }

        if candidate.status == .readyForDemo {
          _ = try updateCandidateRevision(id: candidate.id, status: .superseded)
        }
        try markKnowledgePageProposals(
          candidateRevisionID: candidate.id,
          status: .superseded
        )

        switch workItem.state {
        case .acceptance, .integrating, .verifying:
          _ = try transitionWorkItem(
            id: workItem.id,
            to: .running,
            actor: "Spedito",
            reason: transitionReason
          )
        case .running:
          break
        default:
          throw InvalidCandidateRecoveryError.invalidTicketState(workItem.state.rawValue)
        }

        _ = try updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Spedito",
          eventDetail: runEventDetail
        )

        let matchingComment = try fetchComments(workItemID: workItem.id).contains {
          $0.authorKind == .system
            && $0.authorName == "Spedito"
            && $0.body == commentBody
        }
        if !matchingComment {
          _ = try appendComment(
            workItemID: workItem.id,
            authorKind: .system,
            authorName: "Spedito",
            body: commentBody
          )
        }
      }
    } catch let error as InvalidCandidateRecoveryError {
      throw error
    } catch {
      throw InvalidCandidateRecoveryError.persistence(error.localizedDescription)
    }
  }

  public func performTicketDeliveryRecovery(
    productID: UUID,
    workItemID: UUID,
    mutations: [TicketDeliveryRecoveryMutation]
  ) throws {
    do {
      try transaction {
        let workItem = try fetchWorkItem(id: workItemID)
        guard workItem.productID == productID else {
          throw TicketDeliveryRecoveryError.invalidReferences
        }

        for mutation in mutations {
          switch mutation {
          case .updateCandidate(
            let id,
            let expectedStatuses,
            let status,
            let integratedSHA,
            let integrationWorktreePath
          ):
            let candidate = try fetchCandidateRevision(id: id)
            guard
              candidate.productID == productID,
              candidate.workItemID == workItemID
            else {
              throw TicketDeliveryRecoveryError.invalidReferences
            }
            guard candidate.status == status || expectedStatuses.contains(candidate.status) else {
              throw TicketDeliveryRecoveryError.staleCandidate
            }
            _ = try updateCandidateRevision(
              id: candidate.id,
              status: status,
              integratedSHA: integratedSHA,
              integrationWorktreePath: integrationWorktreePath
            )

          case .updateRun(
            let id,
            let expectedStatuses,
            let status,
            let worktreePath,
            let eventDetail
          ):
            let run = try fetchAgentRun(id: id)
            guard run.productID == productID, run.workItemID == workItemID else {
              throw TicketDeliveryRecoveryError.invalidReferences
            }
            guard run.status == status || expectedStatuses.contains(run.status) else {
              throw TicketDeliveryRecoveryError.staleRun
            }
            _ = try updateAgentRun(
              id: run.id,
              status: status,
              worktreePath: worktreePath,
              eventActor: eventDetail == nil ? nil : "Spedito",
              eventDetail: eventDetail
            )

          case .createRunIfAbsent(let run, let notBefore):
            guard run.productID == productID, run.workItemID == workItemID else {
              throw TicketDeliveryRecoveryError.invalidReferences
            }
            let matchingRunExists = try fetchAgentRuns(productID: productID).contains {
              $0.workItemID == workItemID
                && $0.profileID == run.profileID
                && $0.createdAt >= notBefore
            }
            if !matchingRunExists {
              // The run struct is built before this transaction, so restamp
              // creation here: an earlier mutation in the same recovery may
              // have advanced the candidate's updatedAt, and a run created
              // before it would never match latestReviewRun.
              _ = try createAgentRun(run.stampedAsCreated(at: Date()))
            }

          case .transitionWorkItem(
            let id,
            let expectedStates,
            let states,
            let reasons
          ):
            guard id == workItemID, !states.isEmpty, states.count == reasons.count else {
              throw TicketDeliveryRecoveryError.invalidTransition
            }
            var current = try fetchWorkItem(id: id)
            guard current.productID == productID else {
              throw TicketDeliveryRecoveryError.invalidReferences
            }
            if current.state == states.last {
              continue
            }
            guard expectedStates.contains(current.state) else {
              throw TicketDeliveryRecoveryError.staleWorkItem
            }
            for (state, reason) in zip(states, reasons) where current.state != state {
              current = try transitionWorkItem(
                id: current.id,
                to: state,
                actor: "Spedito",
                reason: reason
              )
            }

          case .updatePermissionRequest(let id, let expectedStatuses, let status):
            let request = try fetchAgentPermissionRequest(id: id)
            guard request.productID == productID, request.workItemID == workItemID else {
              throw TicketDeliveryRecoveryError.invalidReferences
            }
            guard request.status == status || expectedStatuses.contains(request.status) else {
              throw TicketDeliveryRecoveryError.stalePermissionRequest
            }
            _ = try updateAgentPermissionRequest(id: request.id, status: status)

          case .appendComment(let body):
            let matchingComment = try fetchComments(workItemID: workItemID).contains {
              $0.authorKind == .system
                && $0.authorName == "Spedito"
                && $0.body == body
            }
            if !matchingComment {
              _ = try appendComment(
                workItemID: workItemID,
                authorKind: .system,
                authorName: "Spedito",
                body: body
              )
            }
          }
        }
      }
    } catch let error as TicketDeliveryRecoveryError {
      throw error
    } catch {
      throw TicketDeliveryRecoveryError.persistence(error.localizedDescription)
    }
  }
  public func saveDemoSession(_ session: DemoSession) throws -> DemoSession {
    try withStatement(
      """
      INSERT INTO demo_sessions (
          id, product_id, source_kind, launch_id, status, preview_worktree_path,
          allocated_port, output, error_message, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_kind, launch_id) DO UPDATE SET
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
      try bind(session.sourceKind.rawValue, to: 3, in: statement)
      try bind(session.launchID.uuidString, to: 4, in: statement)
      try bind(session.status.rawValue, to: 5, in: statement)
      try bindOptionalString(session.previewWorktreePath, to: 6, in: statement)
      try bindOptionalInt(session.allocatedPort, to: 7, in: statement)
      try bindOptionalString(session.output, to: 8, in: statement)
      try bindOptionalString(session.errorMessage, to: 9, in: statement)
      try bind(session.createdAt.timeIntervalSince1970, to: 10, in: statement)
      try bind(session.updatedAt.timeIntervalSince1970, to: 11, in: statement)
      try stepDone(statement)
    }
    return try fetchDemoSession(sourceKind: session.sourceKind, launchID: session.launchID)
  }

  public func fetchDemoSessions(productID: UUID) throws -> [DemoSession] {
    try withStatement(
      """
      SELECT id, product_id, source_kind, launch_id, status, preview_worktree_path,
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

  public func fetchDemoSession(
    sourceKind: DemoSessionSourceKind,
    launchID: UUID
  ) throws -> DemoSession {
    try withStatement(
      """
      SELECT id, product_id, source_kind, launch_id, status, preview_worktree_path,
             allocated_port, output, error_message, created_at, updated_at
      FROM demo_sessions
      WHERE source_kind = ? AND launch_id = ?;
      """
    ) { statement in
      try bind(sourceKind.rawValue, to: 1, in: statement)
      try bind(launchID.uuidString, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("demo session \(sourceKind.rawValue)/\(launchID)")
      }
      return try decodeDemoSession(statement)
    }
  }

}

extension AgentRun {
  /// A copy whose creation and update times are the given date, for inserts
  /// whose construction time predates the transaction that persists them.
  fileprivate func stampedAsCreated(at date: Date) -> AgentRun {
    AgentRun(
      id: id,
      productID: productID,
      sprintID: sprintID,
      sprintItemID: sprintItemID,
      workItemID: workItemID,
      profileID: profileID,
      status: status,
      codexThreadID: codexThreadID,
      worktreePath: worktreePath,
      ticketBudgetUsed: ticketBudgetUsed,
      contextUsedTokens: contextUsedTokens,
      contextWindowTokens: contextWindowTokens,
      compactionCount: compactionCount,
      cumulativeUsedTokens: cumulativeUsedTokens,
      activeDurationSeconds: activeDurationSeconds,
      turnStartedAt: turnStartedAt,
      lastActivityAt: lastActivityAt,
      lastActivityText: lastActivityText,
      lastActivityKind: lastActivityKind,
      executionConstraint: executionConstraint,
      settlementOperationID: settlementOperationID,
      settlementCandidateVersion: settlementCandidateVersion,
      createdAt: date,
      updatedAt: date
    )
  }
}
