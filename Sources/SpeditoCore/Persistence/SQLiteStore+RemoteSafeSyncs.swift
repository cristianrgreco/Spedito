import Foundation
import SQLite3

private let remoteSafeSyncColumns = """
  id, product_id, connection_id, version, connection_version, kind, status,
  observation_ref, local_sha, local_tree, remote_sha, remote_tree, merge_base_sha,
  candidate_sha, candidate_tree, proving_publication_id, published_sha,
  commits_json, paths_json, error_code, created_at, updated_at
  """

extension SQLiteStore {
  public func fetchRemoteSafeSync(id: UUID) throws -> RemoteSafeSync? {
    try withStatement(
      "SELECT \(remoteSafeSyncColumns) FROM remote_safe_syncs WHERE id = ?;"
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRemoteSafeSync(statement)
    }
  }

  public func fetchLatestRemoteSafeSync(productID: UUID) throws -> RemoteSafeSync? {
    try withStatement(
      "SELECT \(remoteSafeSyncColumns) FROM remote_safe_syncs WHERE product_id = ? ORDER BY updated_at DESC LIMIT 1;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRemoteSafeSync(statement)
    }
  }

  public func createRemoteSafeSync(_ value: RemoteSafeSync) throws -> RemoteSafeSync {
    guard value.version == 1, value.status == .awaitingConfirmation else {
      throw PersistenceError.corruptData(
        "A safe synchronization must begin awaiting confirmation at version one.")
    }
    let placeholders = Array(repeating: "?", count: 22).joined(separator: ", ")
    try withStatement(
      "INSERT INTO remote_safe_syncs (\(remoteSafeSyncColumns)) VALUES (\(placeholders));"
    ) { statement in
      _ = try bindRemoteSafeSync(value, to: statement, includesID: true)
      try stepDone(statement)
    }
    return value
  }

  public func prepareRemoteSafeSyncAcceptance(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemoteSafeSyncStatus,
    expectedLocalSHA: String
  ) throws -> RemoteSafeSync {
    try mutateRemoteSafeSync(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      guard expectedStatus == .awaitingConfirmation, value.localSHA == expectedLocalSHA else {
        throw PersistenceError.corruptData("The incoming GitHub review is stale.")
      }
      value.status = .accepting
      value.errorCode = nil
    }
  }

  public func finishRemoteSafeSyncAcceptance(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemoteSafeSyncStatus
  ) throws -> RemoteSafeSync {
    var accepted: RemoteSafeSync?
    try transaction {
      accepted = try mutateRemoteSafeSync(
        id: id,
        expectedVersion: expectedVersion,
        expectedStatus: expectedStatus
      ) { value in
        guard expectedStatus == .accepting else {
          throw PersistenceError.corruptData(
            "Only an accepting GitHub synchronization can finish."
          )
        }
        value.status = .accepted
        value.errorCode = nil
      }
      guard let accepted else {
        throw PersistenceError.corruptData(
          "The accepted GitHub synchronization was not persisted."
        )
      }
      _ = try reconcileRemoteRepositoryConnection(afterAcceptedSafeSync: accepted)
    }
    guard let accepted else {
      throw PersistenceError.corruptData(
        "The accepted GitHub synchronization was not persisted."
      )
    }
    return accepted
  }

  public func rejectRemoteSafeSync(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemoteSafeSyncStatus,
    candidateSHA: String
  ) throws -> RemoteSafeSync {
    try mutateRemoteSafeSync(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      guard expectedStatus == .awaitingConfirmation, value.candidateSHA == candidateSHA else {
        throw PersistenceError.corruptData("The incoming GitHub review changed before rejection.")
      }
      value.status = .rejected
      value.errorCode = nil
    }
  }

  public func failRemoteSafeSync(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemoteSafeSyncStatus,
    errorCode: String
  ) throws -> RemoteSafeSync {
    guard !errorCode.isEmpty, errorCode.unicodeScalars.count <= 128 else {
      throw PersistenceError.corruptData("The safe synchronization error code is invalid.")
    }
    return try mutateRemoteSafeSync(
      id: id,
      expectedVersion: expectedVersion,
      expectedStatus: expectedStatus
    ) { value in
      value.status = .failed
      value.errorCode = errorCode
    }
  }

  func fetchRemoteSafeSyncs(
    productID: UUID,
    statuses: Set<RemoteSafeSyncStatus>? = nil
  ) throws -> [RemoteSafeSync] {
    let values = try withStatement(
      "SELECT \(remoteSafeSyncColumns) FROM remote_safe_syncs WHERE product_id = ? ORDER BY updated_at;"
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var result: [RemoteSafeSync] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(try decodeRemoteSafeSync(statement))
      }
      return result
    }
    guard let statuses else { return values }
    return values.filter { statuses.contains($0.status) }
  }

  private func requireRemoteSafeSync(id: UUID) throws -> RemoteSafeSync {
    guard let value = try fetchRemoteSafeSync(id: id) else {
      throw PersistenceError.recordNotFound("RemoteSafeSync \(id)")
    }
    return value
  }

  private func mutateRemoteSafeSync(
    id: UUID,
    expectedVersion: Int,
    expectedStatus: RemoteSafeSyncStatus,
    mutation: (inout RemoteSafeSync) throws -> Void
  ) throws -> RemoteSafeSync {
    var value = try requireRemoteSafeSync(id: id)
    guard value.version == expectedVersion, value.status == expectedStatus else {
      throw PersistenceError.corruptData(
        "The safe synchronization changed before this action completed.")
    }
    try mutation(&value)
    value.version += 1
    value.updatedAt = Date()
    try updateRemoteSafeSync(
      value, expectedVersion: expectedVersion, expectedStatus: expectedStatus)
    return value
  }

  private func updateRemoteSafeSync(
    _ value: RemoteSafeSync,
    expectedVersion: Int,
    expectedStatus: RemoteSafeSyncStatus
  ) throws {
    let assignments =
      remoteSafeSyncColumns
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .dropFirst()
      .map { "\($0) = ?" }
      .joined(separator: ", ")
    try withStatement(
      "UPDATE remote_safe_syncs SET \(assignments) WHERE id = ? AND version = ? AND status = ?;"
    ) { statement in
      var index = try bindRemoteSafeSync(value, to: statement, includesID: false)
      try bind(value.id.uuidString, to: index, in: statement)
      index += 1
      try bind(Int64(expectedVersion), to: index, in: statement)
      index += 1
      try bind(expectedStatus.rawValue, to: index, in: statement)
      try stepDone(statement)
      guard sqlite3_changes(try requiredDatabase) == 1 else {
        throw PersistenceError.corruptData(
          "The safe synchronization changed before this action completed.")
      }
    }
  }

  private func bindRemoteSafeSync(
    _ value: RemoteSafeSync,
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
    try bind(Int64(value.connectionVersion), to: index, in: statement)
    index += 1
    try bind(value.kind.rawValue, to: index, in: statement)
    index += 1
    try bind(value.status.rawValue, to: index, in: statement)
    index += 1
    try bind(value.observationRef, to: index, in: statement)
    index += 1
    try bind(value.localSHA, to: index, in: statement)
    index += 1
    try bind(value.localTree, to: index, in: statement)
    index += 1
    try bind(value.remoteSHA, to: index, in: statement)
    index += 1
    try bind(value.remoteTree, to: index, in: statement)
    index += 1
    try bindOptionalString(value.mergeBaseSHA, to: index, in: statement)
    index += 1
    try bind(value.candidateSHA, to: index, in: statement)
    index += 1
    try bind(value.candidateTree, to: index, in: statement)
    index += 1
    try bindOptionalUUID(value.provingPublicationID, to: index, in: statement)
    index += 1
    try bindOptionalString(value.publishedSHA, to: index, in: statement)
    index += 1
    try bind(try encodeRemoteJSON(value.commits), to: index, in: statement)
    index += 1
    try bind(try encodeRemoteJSON(value.paths), to: index, in: statement)
    index += 1
    try bindOptionalString(value.errorCode, to: index, in: statement)
    index += 1
    try bind(value.createdAt.timeIntervalSince1970, to: index, in: statement)
    index += 1
    try bind(value.updatedAt.timeIntervalSince1970, to: index, in: statement)
    index += 1
    return index
  }

  private func decodeRemoteSafeSync(_ statement: OpaquePointer) throws -> RemoteSafeSync {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let productID = UUID(uuidString: try text(statement, column: 1)),
      let connectionID = UUID(uuidString: try text(statement, column: 2)),
      let kind = RemoteSafeSyncKind(rawValue: try text(statement, column: 5)),
      let status = RemoteSafeSyncStatus(rawValue: try text(statement, column: 6))
    else {
      throw PersistenceError.corruptData("Invalid safe synchronization identity or state.")
    }
    let provingID = try optionalText(statement, column: 15).flatMap(UUID.init(uuidString:))
    return RemoteSafeSync(
      id: id,
      productID: productID,
      connectionID: connectionID,
      version: Int(sqlite3_column_int64(statement, 3)),
      connectionVersion: Int(sqlite3_column_int64(statement, 4)),
      kind: kind,
      status: status,
      observationRef: try text(statement, column: 7),
      localSHA: try text(statement, column: 8),
      localTree: try text(statement, column: 9),
      remoteSHA: try text(statement, column: 10),
      remoteTree: try text(statement, column: 11),
      mergeBaseSHA: try optionalText(statement, column: 12),
      candidateSHA: try text(statement, column: 13),
      candidateTree: try text(statement, column: 14),
      provingPublicationID: provingID,
      publishedSHA: try optionalText(statement, column: 16),
      commits: try decodeRemoteJSON(
        try text(statement, column: 17), as: [RemoteCommitSummary].self),
      paths: try decodeRemoteJSON(try text(statement, column: 18), as: [String].self),
      errorCode: try optionalText(statement, column: 19),
      createdAt: date(statement, column: 20),
      updatedAt: date(statement, column: 21)
    )
  }

  func encodeRemoteJSON<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw PersistenceError.corruptData(
        "Remote repository presentation data could not be encoded.")
    }
    return string
  }

  func decodeRemoteJSON<Value: Decodable>(_ value: String, as type: Value.Type) throws -> Value {
    guard let data = value.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(type, from: data)
    else {
      throw PersistenceError.corruptData("Remote repository presentation data is invalid.")
    }
    return decoded
  }
}
