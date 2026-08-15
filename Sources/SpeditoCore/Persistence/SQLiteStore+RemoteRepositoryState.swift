import Foundation

public struct RemoteRepositoryPersistenceSnapshot: Equatable, Sendable {
  public let connection: RemoteRepositoryConnection?
  public let latestSafeSync: RemoteSafeSync?
  public let publications: [RemotePublication]
}

extension SQLiteStore {
  public func fetchRemoteRepositoryPersistenceSnapshot(
    productID: UUID
  ) throws -> RemoteRepositoryPersistenceSnapshot {
    try readTransaction {
      RemoteRepositoryPersistenceSnapshot(
        connection: try fetchRemoteRepositoryConnection(productID: productID),
        latestSafeSync: try fetchLatestRemoteSafeSync(productID: productID),
        publications: try fetchRemotePublications(productID: productID)
      )
    }
  }
}
