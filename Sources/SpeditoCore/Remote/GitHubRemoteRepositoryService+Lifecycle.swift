import Foundation

extension GitHubRemoteRepositoryService {
  public func recover(productID: UUID) async {
    guard configuration.isConfigured, let store = await storeProvider(productID) else { return }
    do {
      let activeProducts = try await store.fetchProducts(status: .active)
      guard activeProducts.contains(where: { $0.id == productID }) else { return }
      transientPresentationErrors[productID] = nil
      try await credentialSession.cleanupOrphans()
      if let accepted = try await store.fetchLatestRemoteSafeSync(productID: productID),
        accepted.status == .accepted
      {
        let workspace = try await workspaceProvider(productID)
        if try await git.currentSHA(at: workspace) == accepted.candidateSHA {
          _ = try await store.reconcileRemoteRepositoryConnection(
            afterAcceptedSafeSync: accepted
          )
        }
      }
      try await recoverSavedAuthorizationIfPossible(productID: productID, store: store)
      let recoverable = try await store.fetchRecoverableRemoteOperations(productID: productID)
      let baselinePublications = try await store.fetchRemotePublications(productID: productID)
        .filter {
          $0.purpose == .existingProductHistory && $0.status.isActive
        }
      let requiresCredentials =
        !recoverable.connections.isEmpty
        || !recoverable.safeSyncs.isEmpty
        || !recoverable.publications.isEmpty
        || !baselinePublications.isEmpty
      guard requiresCredentials else { return }
      try await accountCatalog.reconcile()
      for initializingConnection in recoverable.connections {
        try await recoverLocalRemoteInitialization(
          connection: initializingConnection,
          store: store
        )
      }
      for sync in recoverable.safeSyncs {
        _ = try await acceptSafeSync(syncID: sync.id)
      }
      for publication in recoverable.publications {
        if publication.status == .checking {
          try await executePublication(publication: publication, store: store, includesPush: true)
        } else {
          try await executePublication(publication: publication, store: store, includesPush: false)
        }
      }
      for publication in baselinePublications {
        _ = try await completeExistingProductHistoryPublicationIfReady(
          publicationID: publication.id,
          store: store
        )
      }
    } catch {
      transientPresentationErrors[productID] = error.localizedDescription
    }
  }

  private func recoverSavedAuthorizationIfPossible(
    productID: UUID,
    store: SQLiteStore
  ) async throws {
    guard
      let connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      connection.status == .needsAuthorization,
      connection.accountID != nil
    else { return }
    do {
      _ = try await refreshRepositories(productID: productID)
    } catch let error as GitHubAPIError where error == .unauthorized {
      // The saved credential was genuinely rejected. Keep the durable
      // authorization state so the owner can reconnect explicitly.
    } catch let error as GitHubCredentialStoreError where error == .invalidPayload {
      // Missing or unreadable saved credentials require the same explicit action.
    }
  }

  public func shutdown() async {
    isShuttingDown = true
    await credentialSession.shutdown()
  }
}
