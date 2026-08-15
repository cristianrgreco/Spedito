import Foundation
import SQLite3

extension SQLiteStore {
  public func saveAgentPermissionRequest(
    _ request: AgentPermissionRequest
  ) throws -> AgentPermissionRequest {
    try withStatement(
      """
      INSERT INTO agent_permission_requests (
          id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
          server_request_id, method, kind, title, detail, reason, signature,
          status, created_at, updated_at, product_grant_signature
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          status = excluded.status,
          updated_at = excluded.updated_at;
      """
    ) { statement in
      try bind(request.id.uuidString, to: 1, in: statement)
      try bind(request.productID.uuidString, to: 2, in: statement)
      try bind(request.workItemID.uuidString, to: 3, in: statement)
      try bind(request.agentRunID.uuidString, to: 4, in: statement)
      try bind(request.threadID, to: 5, in: statement)
      try bind(request.turnID, to: 6, in: statement)
      try bind(request.serverRequestID, to: 7, in: statement)
      try bind(request.method, to: 8, in: statement)
      try bind(request.kind.rawValue, to: 9, in: statement)
      try bind(request.title, to: 10, in: statement)
      try bind(request.detail, to: 11, in: statement)
      try bindOptionalString(request.reason, to: 12, in: statement)
      try bind(request.signature, to: 13, in: statement)
      try bind(request.status.rawValue, to: 14, in: statement)
      try bind(request.createdAt.timeIntervalSince1970, to: 15, in: statement)
      try bind(request.updatedAt.timeIntervalSince1970, to: 16, in: statement)
      try bindOptionalString(request.productGrantSignature, to: 17, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionRequest(id: request.id)
  }

  public func fetchAgentPermissionRequests(
    productID: UUID
  ) throws -> [AgentPermissionRequest] {
    try withStatement(
      """
      SELECT id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
             server_request_id, method, kind, title, detail, reason, signature,
             status, created_at, updated_at, product_grant_signature
      FROM agent_permission_requests
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var requests: [AgentPermissionRequest] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        requests.append(try decodeAgentPermissionRequest(statement))
      }
      return requests
    }
  }

  func fetchSprintExecutionPermissionRequests(
    sprintID: UUID
  ) throws -> [AgentPermissionRequest] {
    try withStatement(
      """
      SELECT request.id, request.product_id, request.work_item_id, request.agent_run_id,
             request.thread_id, request.turn_id, request.server_request_id, request.method,
             request.kind, request.title, request.detail, request.reason, request.signature,
             request.status, request.created_at, request.updated_at,
             request.product_grant_signature
      FROM agent_permission_requests AS request
      JOIN agent_runs AS run
        ON run.id = request.agent_run_id
      WHERE run.sprint_id = ?
      ORDER BY request.created_at ASC;
      """
    ) { statement in
      try bind(sprintID.uuidString, to: 1, in: statement)
      var requests: [AgentPermissionRequest] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        requests.append(try decodeAgentPermissionRequest(statement))
      }
      return requests
    }
  }

  public func fetchAgentPermissionRequest(
    id: UUID
  ) throws -> AgentPermissionRequest {
    try withStatement(
      """
      SELECT id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
             server_request_id, method, kind, title, detail, reason, signature,
             status, created_at, updated_at, product_grant_signature
      FROM agent_permission_requests
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("permission request \(id)")
      }
      return try decodeAgentPermissionRequest(statement)
    }
  }

  public func fetchAgentPermissionRequest(
    agentRunID: UUID,
    serverRequestID: String,
    signature: String
  ) throws -> AgentPermissionRequest? {
    try withStatement(
      """
      SELECT id, product_id, work_item_id, agent_run_id, thread_id, turn_id,
             server_request_id, method, kind, title, detail, reason, signature,
             status, created_at, updated_at, product_grant_signature
      FROM agent_permission_requests
      WHERE agent_run_id = ? AND server_request_id = ? AND signature = ?
      ORDER BY created_at DESC
      LIMIT 1;
      """
    ) { statement in
      try bind(agentRunID.uuidString, to: 1, in: statement)
      try bind(serverRequestID, to: 2, in: statement)
      try bind(signature, to: 3, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeAgentPermissionRequest(statement)
    }
  }

  public func updateAgentPermissionRequest(
    id: UUID,
    status: AgentPermissionRequestStatus
  ) throws -> AgentPermissionRequest {
    try withStatement(
      """
      UPDATE agent_permission_requests
      SET status = ?, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(id.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionRequest(id: id)
  }

  public func prepareAgentPermissionResolution(
    requestID: UUID,
    intent: AgentPermissionRequestStatus,
    productGrant: AgentPermissionGrant?
  ) throws -> AgentPermissionResolutionPreparation {
    guard intent.isPendingDelivery, let acknowledgedStatus = intent.acknowledgedStatus else {
      throw PersistenceError.corruptData(
        "Permission resolution requires a pending-delivery intent"
      )
    }
    guard (intent == .allowProductPendingDelivery) == (productGrant != nil) else {
      throw PersistenceError.corruptData(
        "Saved product access must match the permission decision intent"
      )
    }

    var preparation: AgentPermissionResolutionPreparation?
    try transaction {
      let current = try fetchAgentPermissionRequest(id: requestID)
      if current.status == acknowledgedStatus {
        preparation = AgentPermissionResolutionPreparation(
          request: current,
          grant: nil,
          createdGrantID: nil
        )
        return
      }
      guard
        current.status == .pending || current.status == .interrupted
          || current.status == intent
      else {
        throw PersistenceError.corruptData(
          "Permission request already has a different durable decision"
        )
      }

      var savedGrant: AgentPermissionGrant?
      var createdGrantID: UUID?
      if let productGrant {
        guard
          productGrant.productID == current.productID,
          productGrant.sourceRequestID == current.id,
          productGrant.signature == current.productGrantSignature
        else {
          throw PersistenceError.corruptData(
            "Saved product access does not match its permission request"
          )
        }
        savedGrant = try saveAgentPermissionGrant(productGrant)
        if savedGrant?.id == productGrant.id {
          createdGrantID = productGrant.id
        }
      }

      let prepared =
        if current.status == intent {
          current
        } else {
          try updateAgentPermissionRequest(id: requestID, status: intent)
        }
      preparation = AgentPermissionResolutionPreparation(
        request: prepared,
        grant: savedGrant,
        createdGrantID: createdGrantID
      )
    }
    guard let preparation else {
      throw PersistenceError.corruptData("Permission resolution was not prepared")
    }
    return preparation
  }

  public func acknowledgeAgentPermissionResolution(
    requestID: UUID,
    intent: AgentPermissionRequestStatus
  ) throws -> AgentPermissionRequest {
    guard let acknowledgedStatus = intent.acknowledgedStatus else {
      throw PersistenceError.corruptData(
        "Permission acknowledgement requires a pending-delivery intent"
      )
    }

    var acknowledged: AgentPermissionRequest?
    try transaction {
      let current = try fetchAgentPermissionRequest(id: requestID)
      if current.status == acknowledgedStatus {
        acknowledged = current
        return
      }
      guard current.status == intent else {
        throw PersistenceError.corruptData(
          "Permission request no longer has the expected delivery intent"
        )
      }
      acknowledged = try updateAgentPermissionRequest(
        id: requestID,
        status: acknowledgedStatus
      )
    }
    guard let acknowledged else {
      throw PersistenceError.corruptData("Permission response was not acknowledged")
    }
    return acknowledged
  }

  public func interruptPendingAgentPermissionRequests(
    productID: UUID? = nil
  ) throws {
    let sql =
      if productID == nil {
        """
        UPDATE agent_permission_requests
        SET status = 'interrupted', updated_at = ?
        WHERE status = 'pending';
        """
      } else {
        """
        UPDATE agent_permission_requests
        SET status = 'interrupted', updated_at = ?
        WHERE status = 'pending' AND product_id = ?;
        """
      }
    try withStatement(sql) { statement in
      try bind(Date().timeIntervalSince1970, to: 1, in: statement)
      if let productID {
        try bind(productID.uuidString, to: 2, in: statement)
      }
      try stepDone(statement)
    }
  }

  public func saveAgentPermissionGrant(
    _ grant: AgentPermissionGrant
  ) throws -> AgentPermissionGrant {
    if let existing = try fetchActiveAgentPermissionGrant(
      productID: grant.productID,
      signature: grant.signature
    ) {
      return existing
    }
    try withStatement(
      """
      INSERT INTO agent_permission_grants (
          id, product_id, source_request_id, method, kind, title, detail,
          signature, created_at, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(grant.id.uuidString, to: 1, in: statement)
      try bind(grant.productID.uuidString, to: 2, in: statement)
      try bindOptionalUUID(grant.sourceRequestID, to: 3, in: statement)
      try bind(grant.method, to: 4, in: statement)
      try bind(grant.kind.rawValue, to: 5, in: statement)
      try bind(grant.title, to: 6, in: statement)
      try bind(grant.detail, to: 7, in: statement)
      try bind(grant.signature, to: 8, in: statement)
      try bind(grant.createdAt.timeIntervalSince1970, to: 9, in: statement)
      try bindOptionalDate(grant.revokedAt, to: 10, in: statement)
      try stepDone(statement)
    }
    return try fetchAgentPermissionGrant(id: grant.id)
  }

  public func fetchAgentPermissionGrants(
    productID: UUID,
    includeRevoked: Bool = false
  ) throws -> [AgentPermissionGrant] {
    let revokedFilter = includeRevoked ? "" : "AND revoked_at IS NULL"
    return try withStatement(
      """
      SELECT id, product_id, source_request_id, method, kind, title, detail,
             signature, created_at, revoked_at
      FROM agent_permission_grants
      WHERE product_id = ? \(revokedFilter)
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var grants: [AgentPermissionGrant] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        grants.append(try decodeAgentPermissionGrant(statement))
      }
      return grants
    }
  }

  public func revokeAgentPermissionGrant(id: UUID) throws -> AgentPermissionGrant {
    let revoked = try revokeAgentPermissionGrants(ids: [id])
    guard let grant = revoked.first else {
      throw PersistenceError.recordNotFound("agent permission grant \(id)")
    }
    return grant
  }

  public func revokeAgentPermissionGrants(ids: [UUID]) throws -> [AgentPermissionGrant] {
    guard !ids.isEmpty else { return [] }
    let revokedAt = Date()
    try transaction {
      for id in ids {
        _ = try fetchAgentPermissionGrant(id: id)
      }
      for id in ids {
        try withStatement(
          """
          UPDATE agent_permission_grants
          SET revoked_at = ?
          WHERE id = ? AND revoked_at IS NULL;
          """
        ) { statement in
          try bind(revokedAt.timeIntervalSince1970, to: 1, in: statement)
          try bind(id.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
    }
    return try ids.map(fetchAgentPermissionGrant(id:))
  }

  func fetchActiveAgentPermissionGrant(
    productID: UUID,
    signature: String
  ) throws -> AgentPermissionGrant? {
    try withStatement(
      """
      SELECT id, product_id, source_request_id, method, kind, title, detail,
             signature, created_at, revoked_at
      FROM agent_permission_grants
      WHERE product_id = ? AND signature = ? AND revoked_at IS NULL
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(signature, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeAgentPermissionGrant(statement)
    }
  }

  func fetchAgentPermissionGrant(id: UUID) throws -> AgentPermissionGrant {
    try withStatement(
      """
      SELECT id, product_id, source_request_id, method, kind, title, detail,
             signature, created_at, revoked_at
      FROM agent_permission_grants
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("agent permission grant \(id)")
      }
      return try decodeAgentPermissionGrant(statement)
    }
  }

}
