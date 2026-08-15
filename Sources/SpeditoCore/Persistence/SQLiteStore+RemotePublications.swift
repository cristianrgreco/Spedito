import Foundation
import SQLite3

private let remotePublicationColumns = """
  id, product_id, connection_id, version, push_attempt_count,
  pull_request_attempt_count, account_id, repository_id, owner, name, full_name,
  canonical_https_url, is_private, metadata_read, contents_write,
  pull_requests_write, workflows_write, captured_local_sha, captured_local_tree,
  remote_base_sha, remote_base_tree, target_branch, publication_branch,
  manifest_digest, manifest_object_count, manifest_commit_count,
  manifest_path_count, commits_json, paths_json, title, body, text_revision,
  status, pushed_sha, pull_request_number, pull_request_node_id,
  pull_request_url, pull_request_state, pull_request_is_draft,
  pull_request_head_sha, pull_request_base_branch, pull_request_base_sha,
  pull_request_merged_sha, pull_request_updated_at, error_code, created_at, updated_at,
  work_item_id, candidate_revision_id, purpose, remote_branch_deleted_at
  """

extension SQLiteStore {
  public func fetchRemotePublication(id: UUID) throws -> RemotePublication? {
    try withStatement(
      "SELECT \(remotePublicationColumns) FROM remote_publications WHERE id = ?;"
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRemotePublication(statement)
    }
  }

  public func fetchLatestRemotePublication(productID: UUID) throws -> RemotePublication? {
    try withStatement(
      "SELECT \(remotePublicationColumns) FROM remote_publications WHERE product_id = ? ORDER BY updated_at DESC LIMIT 1;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRemotePublication(statement)
    }
  }

  public func createRemotePublication(
    _ value: RemotePublication
  ) throws -> RemotePublication {
    let hasTicketIdentity = value.workItemID != nil && value.candidateRevisionID != nil
    guard value.version == 1, value.status == .awaitingConfirmation,
      (value.purpose == .ticket) == hasTicketIdentity,
      value.purpose != .existingProductHistory || !hasTicketIdentity
    else {
      throw PersistenceError.corruptData(
        "A remote publication has an invalid initial purpose or state.")
    }
    let placeholders = Array(repeating: "?", count: 51).joined(separator: ", ")
    try withStatement(
      "INSERT INTO remote_publications (\(remotePublicationColumns)) VALUES (\(placeholders));"
    ) { statement in
      _ = try bindRemotePublication(value, to: statement, includesID: true)
      try stepDone(statement)
    }
    return value
  }

  public func prepareRemotePublicationCheck(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus,
    title: String,
    body: String,
    textRevision: Int
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      guard expectedStatus == .awaitingConfirmation || expectedStatus == .branchPublished,
        textRevision > value.textRevision
      else {
        throw PersistenceError.corruptData("The pull request text revision is stale.")
      }
      value.title = title
      value.body = body
      value.textRevision = textRevision
      value.errorCode = nil
      if expectedStatus == .awaitingConfirmation {
        value.status = .checking
      }
    }
  }

  public func prepareRemoteTicketRevision(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus,
    candidateRevisionID: UUID,
    capturedLocalSHA: String,
    capturedLocalTree: String,
    remoteBaseSHA: String,
    remoteBaseTree: String,
    manifest: GitOutboundManifest,
    paths: [String],
    title: String,
    body: String
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      guard value.workItemID != nil,
        expectedStatus == .open || expectedStatus == .openOutdated,
        let pullRequest = value.pullRequest,
        pullRequest.state == .open,
        pullRequest.isDraft,
        capturedLocalSHA != value.capturedLocalSHA
      else {
        throw PersistenceError.corruptData("The ticket pull request revision cannot be replaced.")
      }
      value.candidateRevisionID = candidateRevisionID
      value.capturedLocalSHA = capturedLocalSHA
      value.capturedLocalTree = capturedLocalTree
      value.remoteBaseSHA = remoteBaseSHA
      value.remoteBaseTree = remoteBaseTree
      value.manifestDigest = manifest.digest
      value.manifestObjectCount = manifest.objectCount
      value.manifestCommitCount = manifest.commitCount
      value.manifestPathCount = manifest.pathCount
      value.commits = manifest.commits
      value.paths = paths
      value.title = title
      value.body = body
      value.textRevision += 1
      value.pullRequest = nil
      value.status = .checking
      value.errorCode = nil
    }
  }

  public func prepareRemoteBranchPush(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus,
    expectedLocalSHA: String,
    expectedManifestDigest: String,
    expectedRemoteBaseSHA: String
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      guard expectedStatus == .checking,
        value.capturedLocalSHA == expectedLocalSHA,
        value.manifestDigest == expectedManifestDigest,
        value.remoteBaseSHA == expectedRemoteBaseSHA
      else {
        throw PersistenceError.corruptData("The remote publication snapshot is stale.")
      }
      value.pushAttemptCount += 1
      value.status = .pushing
      value.errorCode = nil
    }
  }

  public func recordPublishedBranch(
    id: UUID,
    expectedVersion: Int,
    expectedAttempt: Int,
    pushedSHA: String
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: .pushing
    ) { value in
      guard value.pushAttemptCount == expectedAttempt,
        value.capturedLocalSHA == pushedSHA
      else {
        throw PersistenceError.corruptData("The GitHub branch publication attempt is stale.")
      }
      value.pushedSHA = pushedSHA
      value.status = .branchPublished
      value.errorCode = nil
    }
  }

  public func prepareRemotePullRequestAttempt(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus,
    textRevision: Int
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      guard expectedStatus == .branchPublished,
        value.pushedSHA == value.capturedLocalSHA,
        value.textRevision == textRevision
      else {
        throw PersistenceError.corruptData("The pull request publication attempt is stale.")
      }
      value.pullRequestAttemptCount += 1
      value.status = .creatingPullRequest
      value.errorCode = nil
    }
  }

  public func recordRemotePullRequestAbsent(
    id: UUID,
    expectedVersion: Int,
    expectedAttempt: Int,
    reasonCode: String
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: .creatingPullRequest
    ) { value in
      guard value.pullRequestAttemptCount == expectedAttempt else {
        throw PersistenceError.corruptData("The pull request attempt is stale.")
      }
      value.status = .branchPublished
      value.errorCode = String(reasonCode.unicodeScalars.prefix(128))
    }
  }

  public func recordRemotePullRequest(
    id: UUID,
    expectedVersion: Int,
    expectedAttempt: Int,
    snapshot: RemotePullRequestSnapshot
  ) throws -> RemotePublication {
    var value = try requireRemotePublication(id: id)
    guard value.version == expectedVersion,
      value.status == .creatingPullRequest || value.status == .branchPublished,
      value.pullRequestAttemptCount == expectedAttempt,
      value.pushedSHA == value.capturedLocalSHA
    else {
      throw PersistenceError.corruptData(
        "The pull request result does not match its immutable publication.")
    }
    let previousStatus = value.status
    value.pullRequest = snapshot
    if snapshot.headSHA != value.capturedLocalSHA
      || snapshot.baseBranch != value.targetBranch
    {
      value.status = .openStale
    } else {
      value.status = publicationStatus(for: snapshot.state)
    }
    value.errorCode = nil
    value.version += 1
    value.updatedAt = Date()
    try updateRemotePublication(
      value,
      expectedVersion: expectedVersion,
      expectedStatus: previousStatus
    )
    return value
  }

  public func refreshRemotePullRequestState(
    id: UUID,
    expectedVersion: Int,
    snapshot: RemotePullRequestSnapshot
  ) throws -> RemotePublication {
    let current = try requireRemotePublication(id: id)
    guard current.version == expectedVersion,
      current.status.hasPullRequest,
      current.pullRequest?.number == snapshot.number
    else {
      throw PersistenceError.corruptData("The pull request changed before refresh completed.")
    }
    return try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: current.status
    ) { value in
      value.pullRequest = snapshot
      if snapshot.headSHA != value.capturedLocalSHA
        || snapshot.baseBranch != value.targetBranch
      {
        value.status = .openStale
      } else if snapshot.state == .open, value.status == .openOutdated {
        value.status = .openOutdated
      } else {
        value.status = publicationStatus(for: snapshot.state)
      }
      value.errorCode = nil
    }
  }

  public func recordRemotePublicationBranchDeleted(
    id: UUID,
    expectedVersion: Int,
    deletedAt: Date = Date()
  ) throws -> RemotePublication {
    try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: .merged
    ) { value in
      guard value.remoteBranchDeletedAt == nil,
        value.pullRequest?.state == .merged,
        value.pullRequest?.headSHA == value.capturedLocalSHA
      else {
        throw PersistenceError.corruptData(
          "The merged publication branch cleanup is stale.")
      }
      value.remoteBranchDeletedAt = deletedAt
      value.errorCode = nil
    }
  }

  public func markRemotePublicationOutdated(
    productID: UUID,
    newLocalSHA: String
  ) throws -> RemotePublication? {
    guard let value = try fetchLatestRemotePublication(productID: productID),
      value.status == .open || value.status == .openOutdated
    else {
      return nil
    }
    guard value.capturedLocalSHA != newLocalSHA else { return value }
    return try mutateRemotePublication(
      id: value.id,
      expectedVersion: value.version,
      expectedStatus: value.status
    ) {
      $0.status = .openOutdated
      $0.errorCode = nil
    }
  }

  public func failRemotePublication(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus,
    errorCode: String
  ) throws -> RemotePublication {
    guard !expectedStatus.hasPullRequest,
      !errorCode.isEmpty,
      errorCode.unicodeScalars.count <= 128
    else {
      throw PersistenceError.corruptData("The remote publication failure is invalid.")
    }
    return try mutateRemotePublication(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) {
      $0.status = .failed
      $0.errorCode = errorCode
    }
  }

  public func fetchRecoverableRemoteOperations(
    productID: UUID
  ) throws -> (
    connections: [RemoteRepositoryConnection],
    safeSyncs: [RemoteSafeSync],
    publications: [RemotePublication]
  ) {
    let connections = try fetchAllRemoteRepositoryConnections().filter {
      $0.productID == productID && $0.status == .initializingRemote
    }
    let safeSyncs = try fetchRemoteSafeSyncs(
      productID: productID,
      statuses: [.accepting]
    )
    let publications = try fetchRemotePublications(
      productID: productID,
      statuses: [.checking, .pushing, .branchPublished, .creatingPullRequest]
    )
    return (connections, safeSyncs, publications)
  }

  func fetchRemotePublications(
    productID: UUID,
    statuses: Set<RemotePublicationStatus>? = nil
  ) throws -> [RemotePublication] {
    let values = try withStatement(
      "SELECT \(remotePublicationColumns) FROM remote_publications WHERE product_id = ? ORDER BY updated_at;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var result: [RemotePublication] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(try decodeRemotePublication(statement))
      }
      return result
    }
    guard let statuses else { return values }
    return values.filter { statuses.contains($0.status) }
  }

  private func publicationStatus(
    for state: RemotePullRequestState
  ) -> RemotePublicationStatus {
    switch state {
    case .open: .open
    case .closed: .closed
    case .merged: .merged
    }
  }

  private func requireRemotePublication(id: UUID) throws -> RemotePublication {
    guard let value = try fetchRemotePublication(id: id) else {
      throw PersistenceError.recordNotFound("RemotePublication \(id)")
    }
    return value
  }

  private func mutateRemotePublication(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus,
    mutation: (inout RemotePublication) throws -> Void
  ) throws -> RemotePublication {
    var value = try requireRemotePublication(id: id)
    guard value.version == expectedVersion, value.status == expectedStatus else {
      throw PersistenceError.corruptData(
        "The remote publication changed before this action completed.")
    }
    try mutation(&value)
    value.version += 1
    value.updatedAt = Date()
    try updateRemotePublication(
      value,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    )
    return value
  }

  private func updateRemotePublication(
    _ value: RemotePublication,
    expectedVersion: Int,
    expectedStatus: RemotePublicationStatus
  ) throws {
    let assignments =
      remotePublicationColumns
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .dropFirst()
      .map { "\($0) = ?" }
      .joined(separator: ", ")
    try withStatement(
      "UPDATE remote_publications SET \(assignments) WHERE id = ? AND version = ? AND status = ?;"
    ) { statement in
      var index = try bindRemotePublication(value, to: statement, includesID: false)
      try bind(value.id.uuidString, to: index, in: statement)
      index += 1
      try bind(Int64(expectedVersion), to: index, in: statement)
      index += 1
      try bind(expectedStatus.rawValue, to: index, in: statement)
      try stepDone(statement)
      guard sqlite3_changes(try requiredDatabase) == 1 else {
        throw PersistenceError.corruptData(
          "The remote publication changed before this action completed.")
      }
    }
  }

  private func bindRemotePublication(
    _ value: RemotePublication,
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
    try bind(value.connectionID.uuidString, to: index, in: statement)
    index += 1
    try bind(Int64(value.version), to: index, in: statement)
    index += 1
    try bind(Int64(value.pushAttemptCount), to: index, in: statement)
    index += 1
    try bind(Int64(value.pullRequestAttemptCount), to: index, in: statement)
    index += 1
    try bind(value.accountID.uuidString, to: index, in: statement)
    index += 1
    try bind(value.repositoryID, to: index, in: statement)
    index += 1
    try bind(value.owner, to: index, in: statement)
    index += 1
    try bind(value.name, to: index, in: statement)
    index += 1
    try bind(value.fullName, to: index, in: statement)
    index += 1
    try bind(value.canonicalHTTPSURL.absoluteString, to: index, in: statement)
    index += 1
    try bind(Int64(value.isPrivate ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.metadataRead ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.contentsWrite ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.pullRequestsWrite ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(Int64(value.permissions.workflowsWrite ? 1 : 0), to: index, in: statement)
    index += 1
    try bind(value.capturedLocalSHA, to: index, in: statement)
    index += 1
    try bind(value.capturedLocalTree, to: index, in: statement)
    index += 1
    try bind(value.remoteBaseSHA, to: index, in: statement)
    index += 1
    try bind(value.remoteBaseTree, to: index, in: statement)
    index += 1
    try bind(value.targetBranch, to: index, in: statement)
    index += 1
    try bind(value.publicationBranch, to: index, in: statement)
    index += 1
    try bind(value.manifestDigest, to: index, in: statement)
    index += 1
    try bind(Int64(value.manifestObjectCount), to: index, in: statement)
    index += 1
    try bind(Int64(value.manifestCommitCount), to: index, in: statement)
    index += 1
    try bind(Int64(value.manifestPathCount), to: index, in: statement)
    index += 1
    try bind(try encodeRemoteJSON(value.commits), to: index, in: statement)
    index += 1
    try bind(try encodeRemoteJSON(value.paths), to: index, in: statement)
    index += 1
    try bind(value.title, to: index, in: statement)
    index += 1
    try bind(value.body, to: index, in: statement)
    index += 1
    try bind(Int64(value.textRevision), to: index, in: statement)
    index += 1
    try bind(value.status.rawValue, to: index, in: statement)
    index += 1
    try bindOptionalString(value.pushedSHA, to: index, in: statement)
    index += 1
    if let pullRequest = value.pullRequest {
      try bind(Int64(pullRequest.number), to: index, in: statement)
      index += 1
      try bind(pullRequest.nodeID, to: index, in: statement)
      index += 1
      try bind(pullRequest.canonicalURL.absoluteString, to: index, in: statement)
      index += 1
      try bind(pullRequest.state.rawValue, to: index, in: statement)
      index += 1
      try bind(Int64(pullRequest.isDraft ? 1 : 0), to: index, in: statement)
      index += 1
      try bind(pullRequest.headSHA, to: index, in: statement)
      index += 1
      try bind(pullRequest.baseBranch, to: index, in: statement)
      index += 1
      try bind(pullRequest.baseSHA, to: index, in: statement)
      index += 1
      try bindOptionalString(pullRequest.mergedSHA, to: index, in: statement)
      index += 1
      try bind(pullRequest.updatedAt.timeIntervalSince1970, to: index, in: statement)
      index += 1
    } else {
      for _ in 0..<10 {
        try bindNull(to: index, in: statement)
        index += 1
      }
    }
    try bindOptionalString(value.errorCode, to: index, in: statement)
    index += 1
    try bind(value.createdAt.timeIntervalSince1970, to: index, in: statement)
    index += 1
    try bind(value.updatedAt.timeIntervalSince1970, to: index, in: statement)
    index += 1
    try bindOptionalString(value.workItemID?.uuidString, to: index, in: statement)
    index += 1
    try bindOptionalString(value.candidateRevisionID?.uuidString, to: index, in: statement)
    index += 1
    try bind(value.purpose.rawValue, to: index, in: statement)
    index += 1
    try bindOptionalDate(value.remoteBranchDeletedAt, to: index, in: statement)
    index += 1
    return index
  }

  private func decodeRemotePublication(_ statement: OpaquePointer) throws -> RemotePublication {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let connectionID = UUID(uuidString: try text(statement, column: 2)),
      let accountID = UUID(uuidString: try text(statement, column: 6)),
      let canonicalURL = URL(string: try text(statement, column: 11)),
      let status = RemotePublicationStatus(rawValue: try text(statement, column: 32)),
      let purpose = RemotePublicationPurpose(rawValue: try text(statement, column: 49))
    else {
      throw PersistenceError.corruptData("Invalid remote publication identity or state.")
    }
    let pullRequest = try decodeRemotePullRequest(statement)
    return RemotePublication(
      id: id,
      productID: productID,
      connectionID: connectionID,
      workItemID: try optionalText(statement, column: 47).flatMap(UUID.init(uuidString:)),
      candidateRevisionID: try optionalText(statement, column: 48).flatMap(UUID.init(uuidString:)),
      purpose: purpose,
      version: Int(sqlite3_column_int64(statement, 3)),
      pushAttemptCount: Int(sqlite3_column_int64(statement, 4)),
      pullRequestAttemptCount: Int(sqlite3_column_int64(statement, 5)),
      accountID: accountID,
      repositoryID: sqlite3_column_int64(statement, 7),
      owner: try text(statement, column: 8),
      name: try text(statement, column: 9),
      fullName: try text(statement, column: 10),
      canonicalHTTPSURL: canonicalURL,
      isPrivate: sqlite3_column_int64(statement, 12) == 1,
      permissions: RemoteRepositoryPermissions(
        metadataRead: sqlite3_column_int64(statement, 13) == 1,
        contentsWrite: sqlite3_column_int64(statement, 14) == 1,
        pullRequestsWrite: sqlite3_column_int64(statement, 15) == 1,
        workflowsWrite: sqlite3_column_int64(statement, 16) == 1
      ),
      capturedLocalSHA: try text(statement, column: 17),
      capturedLocalTree: try text(statement, column: 18),
      remoteBaseSHA: try text(statement, column: 19),
      remoteBaseTree: try text(statement, column: 20),
      targetBranch: try text(statement, column: 21),
      publicationBranch: try text(statement, column: 22),
      manifestDigest: try text(statement, column: 23),
      manifestObjectCount: Int(sqlite3_column_int64(statement, 24)),
      manifestCommitCount: Int(sqlite3_column_int64(statement, 25)),
      manifestPathCount: Int(sqlite3_column_int64(statement, 26)),
      commits: try decodeRemoteJSON(
        try text(statement, column: 27), as: [RemoteCommitSummary].self),
      paths: try decodeRemoteJSON(try text(statement, column: 28), as: [String].self),
      title: try text(statement, column: 29),
      body: try text(statement, column: 30),
      textRevision: Int(sqlite3_column_int64(statement, 31)),
      status: status,
      pushedSHA: try optionalText(statement, column: 33),
      pullRequest: pullRequest,
      remoteBranchDeletedAt: optionalDate(statement, column: 50),
      errorCode: try optionalText(statement, column: 44),
      createdAt: date(statement, column: 45),
      updatedAt: date(statement, column: 46)
    )
  }

  private func decodeRemotePullRequest(
    _ statement: OpaquePointer
  ) throws -> RemotePullRequestSnapshot? {
    guard let number = optionalInt(statement, column: 34) else { return nil }
    guard
      let url = try optionalURL(statement, column: 36),
      let rawState = try optionalText(statement, column: 37),
      let state = RemotePullRequestState(rawValue: rawState),
      let isDraft = optionalBool(statement, column: 38),
      let updatedAt = optionalDate(statement, column: 43)
    else {
      throw PersistenceError.corruptData("Stored pull request details are incomplete.")
    }
    return RemotePullRequestSnapshot(
      number: number,
      nodeID: try text(statement, column: 35),
      canonicalURL: url,
      state: state,
      isDraft: isDraft,
      headSHA: try text(statement, column: 39),
      baseBranch: try text(statement, column: 40),
      baseSHA: try text(statement, column: 41),
      mergedSHA: try optionalText(statement, column: 42),
      updatedAt: updatedAt
    )
  }
}
