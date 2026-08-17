import Foundation
import SQLite3

private let remoteConnectionColumns = """
  id, product_id, version, kind, account_id, installation_id, repository_id,
  owner, name, full_name, canonical_https_url, is_private, default_branch,
  metadata_read, contents_write, pull_requests_write, workflows_write, status,
  error_code, latest_local_sha, latest_local_tree, latest_remote_sha,
  latest_remote_tree, latest_relationship, latest_ahead_count,
  latest_behind_count, latest_checked_at, pending_repository_id,
  pending_full_name, pending_canonical_https_url, pending_default_branch,
  pending_observed_at, bootstrap_root_sha, bootstrap_root_tree,
  initialization_attempt_count, seeded_sha, origin_verified, created_at, updated_at
  """

extension SQLiteStore {
  public func fetchRemoteRepositoryConnection(
    productID: UUID
  ) throws -> RemoteRepositoryConnection? {
    try withStatement(
      "SELECT \(remoteConnectionColumns) FROM remote_repository_connections WHERE product_id = ?;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRemoteRepositoryConnection(statement)
    }
  }

  public func createRemoteRepositoryConnection(
    _ value: RemoteRepositoryConnection
  ) throws -> RemoteRepositoryConnection {
    guard value.version == 1 else {
      throw PersistenceError.corruptData(
        "A new remote repository connection must start at version one.")
    }
    let placeholders = Array(repeating: "?", count: 39).joined(separator: ", ")
    try withStatement(
      "INSERT INTO remote_repository_connections (\(remoteConnectionColumns)) VALUES (\(placeholders));"
    ) { statement in
      _ = try bindRemoteRepositoryConnection(value, to: statement, includesID: true)
      try stepDone(statement)
    }
    return value
  }

  public func saveRemoteRepositoryConnection(
    _ value: RemoteRepositoryConnection,
    expectedVersion: Int
  ) throws -> RemoteRepositoryConnection {
    let current = try requireRemoteRepositoryConnection(id: value.id)
    guard
      current.version == expectedVersion,
      current.productID == value.productID,
      current.kind == value.kind
    else {
      throw PersistenceError.corruptData(
        "The remote repository connection changed before it could be saved.")
    }
    var updated = value
    updated.version = expectedVersion + 1
    updated.updatedAt = Date()
    try updateRemoteRepositoryConnection(updated, expectedVersion: expectedVersion)
    return updated
  }

  public func disconnectRemoteRepositoryConnection(
    id: UUID,
    expectedVersion: Int
  ) throws -> RemoteRepositoryConnection {
    try mutateRemoteRepositoryConnection(id: id, expectedVersion: expectedVersion) { value in
      value.status = .disconnected
      value.errorCode = nil
      value.pendingRepositoryID = nil
      value.pendingFullName = nil
      value.pendingCanonicalHTTPSURL = nil
      value.pendingDefaultBranch = nil
      value.pendingObservedAt = nil
    }
  }

  public func cancelRemoteRepositoryConnectionSetup(
    id: UUID,
    expectedVersion: Int
  ) throws -> RemoteRepositoryConnection {
    try mutateRemoteRepositoryConnection(id: id, expectedVersion: expectedVersion) { value in
      guard value.status == .needsInstallation || value.status == .selectingRepository else {
        throw PersistenceError.corruptData("Only unfinished GitHub setup can be cancelled.")
      }
      value.accountID = nil
      value.installationID = nil
      value.repositoryID = nil
      value.owner = nil
      value.name = nil
      value.fullName = nil
      value.canonicalHTTPSURL = nil
      value.isPrivate = nil
      value.defaultBranch = nil
      value.permissions = RemoteRepositoryPermissions(
        metadataRead: false,
        contentsWrite: false,
        pullRequestsWrite: false,
        workflowsWrite: false
      )
      value.status = .disconnected
      value.errorCode = nil
      value.pendingRepositoryID = nil
      value.pendingFullName = nil
      value.pendingCanonicalHTTPSURL = nil
      value.pendingDefaultBranch = nil
      value.pendingObservedAt = nil
      value.bootstrapRootSHA = nil
      value.bootstrapRootTree = nil
      value.seededSHA = nil
      value.originVerified = nil
    }
  }

  public func prepareLocalRemoteInitialization(
    id: UUID,
    expectedVersion: Int,
    bootstrapSHA: String,
    bootstrapTree: String
  ) throws -> RemoteRepositoryConnection {
    try mutateRemoteRepositoryConnection(id: id, expectedVersion: expectedVersion) { value in
      guard value.kind == .localEmptyRepository,
        value.status == .selectingRepository,
        value.repositoryID != nil,
        value.defaultBranch != nil
      else {
        throw PersistenceError.corruptData(
          "The selected GitHub repository is not ready for initialization.")
      }
      value.status = .initializingRemote
      value.bootstrapRootSHA = bootstrapSHA
      value.bootstrapRootTree = bootstrapTree
      value.initializationAttemptCount += 1
      value.seededSHA = nil
      value.originVerified = false
      value.errorCode = nil
    }
  }

  public func recordLocalRemoteSeed(
    id: UUID,
    expectedVersion: Int,
    expectedAttempt: Int,
    seededSHA: String
  ) throws -> RemoteRepositoryConnection {
    try mutateRemoteRepositoryConnection(id: id, expectedVersion: expectedVersion) { value in
      guard value.status == .initializingRemote,
        value.initializationAttemptCount == expectedAttempt,
        value.bootstrapRootSHA == seededSHA
      else {
        throw PersistenceError.corruptData("The GitHub initialization attempt is stale.")
      }
      value.seededSHA = seededSHA
      value.errorCode = nil
    }
  }

  public func finishLocalRemoteInitialization(
    id: UUID,
    expectedVersion: Int,
    originVerified: Bool
  ) throws -> RemoteRepositoryConnection {
    guard originVerified else {
      throw PersistenceError.corruptData("The local Git origin was not verified.")
    }
    return try mutateRemoteRepositoryConnection(id: id, expectedVersion: expectedVersion) { value in
      guard value.status == .initializingRemote,
        value.seededSHA == value.bootstrapRootSHA
      else {
        throw PersistenceError.corruptData("The GitHub repository seed was not verified.")
      }
      value.originVerified = true
      value.status = .connected
      value.errorCode = nil
    }
  }

  public func recordRemoteRepositoryObservation(
    _ observation: RemoteRepositoryObservation,
    connectionID: UUID,
    expectedVersion: Int
  ) throws -> RemoteRepositoryConnection {
    try mutateRemoteRepositoryConnection(id: connectionID, expectedVersion: expectedVersion) {
      value in
      guard observation.connectionVersion == expectedVersion else {
        throw PersistenceError.corruptData("The GitHub repository observation is stale.")
      }
      guard value.repositoryID == observation.repositoryID else {
        value.status = .unavailable
        value.errorCode = "repository_identity_changed"
        return
      }
      value.latestLocalSHA = observation.localSHA
      value.latestLocalTree = observation.localTree
      value.latestRemoteSHA = observation.remoteSHA
      value.latestRemoteTree = observation.remoteTree
      value.latestRelationship = observation.relationship
      value.latestAheadCount = observation.aheadCount
      value.latestBehindCount = observation.behindCount
      value.latestCheckedAt = observation.observedAt
      if value.fullName != observation.fullName
        || value.canonicalHTTPSURL != observation.canonicalHTTPSURL
        || value.defaultBranch != observation.defaultBranch
      {
        value.status = .needsTargetReview
        value.pendingRepositoryID = observation.repositoryID
        value.pendingFullName = observation.fullName
        value.pendingCanonicalHTTPSURL = observation.canonicalHTTPSURL
        value.pendingDefaultBranch = observation.defaultBranch
        value.pendingObservedAt = observation.observedAt
      } else {
        value.status = .connected
        value.errorCode = nil
      }
    }
  }

  func reconcileRemoteRepositoryConnection(
    afterAcceptedSafeSync sync: RemoteSafeSync
  ) throws -> RemoteRepositoryConnection {
    guard sync.status == .accepted else {
      throw PersistenceError.corruptData(
        "Only an accepted GitHub synchronization can update the connection."
      )
    }
    let relationship: RemoteRepositoryRelationship
    let aheadCount: Int
    switch sync.kind {
    case .fastForward:
      relationship = .aligned
      aheadCount = 0
    case .historyAlignment:
      relationship = .localAhead
      aheadCount = 1
    }
    let current = try requireRemoteRepositoryConnection(id: sync.connectionID)
    guard current.productID == sync.productID else {
      throw PersistenceError.corruptData(
        "The GitHub connection changed before synchronization completed."
      )
    }
    if current.latestRemoteSHA == sync.remoteSHA,
      current.latestRemoteTree == sync.remoteTree,
      current.latestLocalSHA == sync.candidateSHA,
      current.latestLocalTree == sync.candidateTree,
      current.latestRelationship == relationship,
      current.latestAheadCount == aheadCount,
      current.latestBehindCount == 0
    {
      return current
    }
    guard current.status == .connected,
      current.latestRemoteSHA == sync.remoteSHA,
      current.latestRemoteTree == sync.remoteTree,
      current.version == sync.connectionVersion,
      current.latestLocalSHA == sync.localSHA,
      current.latestLocalTree == sync.localTree
    else {
      throw PersistenceError.corruptData(
        "The GitHub connection changed before synchronization completed."
      )
    }
    return try mutateRemoteRepositoryConnection(
      id: current.id,
      expectedVersion: current.version
    ) {
      $0.latestLocalSHA = sync.candidateSHA
      $0.latestLocalTree = sync.candidateTree
      $0.latestRelationship = relationship
      $0.latestAheadCount = aheadCount
      $0.latestBehindCount = 0
      $0.errorCode = nil
    }
  }

  public func confirmRemoteRepositoryTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) throws -> RemoteRepositoryConnection {
    guard let current = try fetchRemoteRepositoryConnection(productID: productID) else {
      throw PersistenceError.recordNotFound("RemoteRepositoryConnection for \(productID)")
    }
    return try mutateRemoteRepositoryConnection(
      id: current.id,
      expectedVersion: expectedVersion
    ) { value in
      guard value.status == .needsTargetReview,
        value.pendingObservedAt == pendingObservedAt,
        value.pendingRepositoryID == value.repositoryID,
        let pendingFullName = value.pendingFullName,
        let pendingURL = value.pendingCanonicalHTTPSURL,
        let pendingBranch = value.pendingDefaultBranch
      else {
        throw PersistenceError.corruptData("The proposed GitHub repository target is stale.")
      }
      let parts = pendingFullName.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2 else {
        throw PersistenceError.corruptData("The proposed GitHub repository name is invalid.")
      }
      value.owner = parts[0]
      value.name = parts[1]
      value.fullName = pendingFullName
      value.canonicalHTTPSURL = pendingURL
      value.defaultBranch = pendingBranch
      value.pendingRepositoryID = nil
      value.pendingFullName = nil
      value.pendingCanonicalHTTPSURL = nil
      value.pendingDefaultBranch = nil
      value.pendingObservedAt = nil
      value.status = .connected
      value.errorCode = nil
    }
  }

  func fetchRemoteRepositoryConnections(accountID: UUID) throws -> [RemoteRepositoryConnection] {
    try withStatement(
      "SELECT \(remoteConnectionColumns) FROM remote_repository_connections WHERE account_id = ? ORDER BY updated_at;"
    ) { statement in
      try bind(accountID.uuidString, to: 1, in: statement)
      var result: [RemoteRepositoryConnection] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(try decodeRemoteRepositoryConnection(statement))
      }
      return result
    }
  }

  func fetchAllRemoteRepositoryConnections() throws -> [RemoteRepositoryConnection] {
    try withStatement(
      "SELECT \(remoteConnectionColumns) FROM remote_repository_connections ORDER BY updated_at;"
    ) { statement in
      var result: [RemoteRepositoryConnection] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(try decodeRemoteRepositoryConnection(statement))
      }
      return result
    }
  }

  func markRemoteRepositoryConnectionsNeedAuthorization(accountID: UUID) throws {
    let values = try fetchRemoteRepositoryConnections(accountID: accountID)
    for value in values where value.status != .disconnected {
      _ = try mutateRemoteRepositoryConnection(id: value.id, expectedVersion: value.version) {
        $0.status = .needsAuthorization
        $0.errorCode = "authorization_required"
        $0.pendingRepositoryID = nil
        $0.pendingFullName = nil
        $0.pendingCanonicalHTTPSURL = nil
        $0.pendingDefaultBranch = nil
        $0.pendingObservedAt = nil
      }
    }
  }

  private func requireRemoteRepositoryConnection(
    id: UUID
  ) throws -> RemoteRepositoryConnection {
    try withStatement(
      "SELECT \(remoteConnectionColumns) FROM remote_repository_connections WHERE id = ?;"
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("RemoteRepositoryConnection \(id)")
      }
      return try decodeRemoteRepositoryConnection(statement)
    }
  }

  private func mutateRemoteRepositoryConnection(
    id: UUID,
    expectedVersion: Int,
    mutation: (inout RemoteRepositoryConnection) throws -> Void
  ) throws -> RemoteRepositoryConnection {
    var value = try requireRemoteRepositoryConnection(id: id)
    guard value.version == expectedVersion else {
      throw PersistenceError.corruptData(
        "The remote repository connection changed before this action completed.")
    }
    try mutation(&value)
    value.version += 1
    value.updatedAt = Date()
    try updateRemoteRepositoryConnection(value, expectedVersion: expectedVersion)
    return value
  }

  private func updateRemoteRepositoryConnection(
    _ value: RemoteRepositoryConnection,
    expectedVersion: Int
  ) throws {
    let assignments =
      remoteConnectionColumns
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .dropFirst()
      .map { "\($0) = ?" }
      .joined(separator: ", ")
    try withStatement(
      "UPDATE remote_repository_connections SET \(assignments) WHERE id = ? AND version = ?;"
    ) { statement in
      var index = try bindRemoteRepositoryConnection(value, to: statement, includesID: false)
      try bind(value.id.uuidString, to: index, in: statement)
      index += 1
      try bind(Int64(expectedVersion), to: index, in: statement)
      try stepDone(statement)
      guard sqlite3_changes(try requiredDatabase) == 1 else {
        throw PersistenceError.corruptData(
          "The remote repository connection changed before this action completed.")
      }
    }
  }

  private func bindRemoteRepositoryConnection(
    _ value: RemoteRepositoryConnection,
    to statement: OpaquePointer,
    includesID: Bool
  ) throws -> Int32 {
    var index: Int32 = 1
    if includesID {
      try bind(value.id.uuidString, to: index, in: statement)
      index += 1
    }
    try bind(value.productID.uuidString, to: index, in: statement)
    index += 1
    try bind(Int64(value.version), to: index, in: statement)
    index += 1
    try bind(value.kind.rawValue, to: index, in: statement)
    index += 1
    try bindOptionalUUID(value.accountID, to: index, in: statement)
    index += 1
    try bindOptionalInt64(value.installationID, to: index, in: statement)
    index += 1
    try bindOptionalInt64(value.repositoryID, to: index, in: statement)
    index += 1
    try bindOptionalString(value.owner, to: index, in: statement)
    index += 1
    try bindOptionalString(value.name, to: index, in: statement)
    index += 1
    try bindOptionalString(value.fullName, to: index, in: statement)
    index += 1
    try bindOptionalString(value.canonicalHTTPSURL?.absoluteString, to: index, in: statement)
    index += 1
    try bindOptionalBool(value.isPrivate, to: index, in: statement)
    index += 1
    try bindOptionalString(value.defaultBranch, to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.metadataRead ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.contentsWrite ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.pullRequestsWrite ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.workflowsWrite ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(value.status.rawValue, to: index, in: statement)
    index += 1
    try bindOptionalString(value.errorCode, to: index, in: statement)
    index += 1
    try bindOptionalString(value.latestLocalSHA, to: index, in: statement)
    index += 1
    try bindOptionalString(value.latestLocalTree, to: index, in: statement)
    index += 1
    try bindOptionalString(value.latestRemoteSHA, to: index, in: statement)
    index += 1
    try bindOptionalString(value.latestRemoteTree, to: index, in: statement)
    index += 1
    try bindOptionalString(value.latestRelationship?.rawValue, to: index, in: statement)
    index += 1
    try bindOptionalInt(value.latestAheadCount, to: index, in: statement)
    index += 1
    try bindOptionalInt(value.latestBehindCount, to: index, in: statement)
    index += 1
    try bindOptionalDate(value.latestCheckedAt, to: index, in: statement)
    index += 1
    try bindOptionalInt64(value.pendingRepositoryID, to: index, in: statement)
    index += 1
    try bindOptionalString(value.pendingFullName, to: index, in: statement)
    index += 1
    try bindOptionalString(value.pendingCanonicalHTTPSURL?.absoluteString, to: index, in: statement)
    index += 1
    try bindOptionalString(value.pendingDefaultBranch, to: index, in: statement)
    index += 1
    try bindOptionalDate(value.pendingObservedAt, to: index, in: statement)
    index += 1
    try bindOptionalString(value.bootstrapRootSHA, to: index, in: statement)
    index += 1
    try bindOptionalString(value.bootstrapRootTree, to: index, in: statement)
    index += 1
    if value.kind == .importedSource {
      try bindNull(to: index, in: statement)
    } else {
      try bind(Int64(value.initializationAttemptCount), to: index, in: statement)
    }
    index += 1
    try bindOptionalString(value.seededSHA, to: index, in: statement)
    index += 1
    try bindOptionalBool(value.originVerified, to: index, in: statement)
    index += 1
    try bind(value.createdAt.timeIntervalSince1970, to: index, in: statement)
    index += 1
    try bind(value.updatedAt.timeIntervalSince1970, to: index, in: statement)
    index += 1
    return index
  }

  private func decodeRemoteRepositoryConnection(
    _ statement: OpaquePointer
  ) throws -> RemoteRepositoryConnection {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let kind = RemoteRepositoryConnectionKind(rawValue: try text(statement, column: 3)),
      let status = RemoteRepositoryConnectionStatus(rawValue: try text(statement, column: 17))
    else {
      throw PersistenceError.corruptData("Invalid remote repository connection identity or state.")
    }
    let accountID = try optionalText(statement, column: 4).flatMap(UUID.init(uuidString:))
    let canonicalURL = try optionalURL(statement, column: 10)
    let pendingURL = try optionalURL(statement, column: 29)
    let relationshipRaw = try optionalText(statement, column: 23)
    let relationship = relationshipRaw.flatMap(RemoteRepositoryRelationship.init(rawValue:))
    if relationshipRaw != nil, relationship == nil {
      throw PersistenceError.corruptData("Invalid remote repository relationship.")
    }
    return RemoteRepositoryConnection(
      id: id,
      productID: productID,
      version: Int(sqlite3_column_int64(statement, 2)),
      kind: kind,
      accountID: accountID,
      installationID: optionalInt64(statement, column: 5),
      repositoryID: optionalInt64(statement, column: 6),
      owner: try optionalText(statement, column: 7),
      name: try optionalText(statement, column: 8),
      fullName: try optionalText(statement, column: 9),
      canonicalHTTPSURL: canonicalURL,
      isPrivate: optionalBool(statement, column: 11),
      defaultBranch: try optionalText(statement, column: 12),
      permissions: RemoteRepositoryPermissions(
        metadataRead: sqlite3_column_int64(statement, 13) == 1,
        contentsWrite: sqlite3_column_int64(statement, 14) == 1,
        pullRequestsWrite: sqlite3_column_int64(statement, 15) == 1,
        workflowsWrite: sqlite3_column_int64(statement, 16) == 1
      ),
      status: status,
      errorCode: try optionalText(statement, column: 18),
      latestLocalSHA: try optionalText(statement, column: 19),
      latestLocalTree: try optionalText(statement, column: 20),
      latestRemoteSHA: try optionalText(statement, column: 21),
      latestRemoteTree: try optionalText(statement, column: 22),
      latestRelationship: relationship,
      latestAheadCount: optionalInt(statement, column: 24),
      latestBehindCount: optionalInt(statement, column: 25),
      latestCheckedAt: optionalDate(statement, column: 26),
      pendingRepositoryID: optionalInt64(statement, column: 27),
      pendingFullName: try optionalText(statement, column: 28),
      pendingCanonicalHTTPSURL: pendingURL,
      pendingDefaultBranch: try optionalText(statement, column: 30),
      pendingObservedAt: optionalDate(statement, column: 31),
      bootstrapRootSHA: try optionalText(statement, column: 32),
      bootstrapRootTree: try optionalText(statement, column: 33),
      initializationAttemptCount: optionalInt(statement, column: 34) ?? 0,
      seededSHA: try optionalText(statement, column: 35),
      originVerified: optionalBool(statement, column: 36),
      createdAt: date(statement, column: 37),
      updatedAt: date(statement, column: 38)
    )
  }

  func bindOptionalInt64(
    _ value: Int64?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    if let value {
      try bind(value, to: index, in: statement)
    } else {
      try bindNull(to: index, in: statement)
    }
  }

  func bindOptionalBool(
    _ value: Bool?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    if let value {
      try bind(Int64(value ? 1 : 0), to: index, in: statement)
    } else {
      try bindNull(to: index, in: statement)
    }
  }

  func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, column)
  }

  func optionalBool(_ statement: OpaquePointer, column: Int32) -> Bool? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, column) == 1
  }

  func optionalURL(_ statement: OpaquePointer, column: Int32) throws -> URL? {
    guard let value = try optionalText(statement, column: column) else { return nil }
    guard let url = URL(string: value) else {
      throw PersistenceError.corruptData("Invalid stored GitHub URL.")
    }
    return url
  }
}
