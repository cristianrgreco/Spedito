import Foundation

extension GitHubRemoteRepositoryService {
  public func state(productID: UUID) async -> GitHubRemoteRepositoryState {
    await makeState(productID: productID)
  }
  func makeState(productID: UUID) async -> GitHubRemoteRepositoryState {
    guard let store = await storeProvider(productID) else {
      return GitHubRemoteRepositoryState(
        isConfigured: configuration.isConfigured,
        errorMessage: transientPresentationErrors[productID]
      )
    }
    do {
      let persisted = try await store.fetchRemoteRepositoryPersistenceSnapshot(
        productID: productID
      )
      return GitHubRemoteRepositoryState(
        isConfigured: configuration.isConfigured,
        connection: persisted.connection,
        repositories: transientRepositoryChoices[productID] ?? [],
        selectedEligibility: transientSelectedEligibility[productID],
        observation: transientCheckedObservations[productID]?.value,
        safeSync: persisted.latestSafeSync,
        publications: persisted.publications,
        errorMessage: transientPresentationErrors[productID]
      )
    } catch {
      transientPresentationErrors[productID] = error.localizedDescription
      return GitHubRemoteRepositoryState(
        isConfigured: configuration.isConfigured,
        repositories: transientRepositoryChoices[productID] ?? [],
        selectedEligibility: transientSelectedEligibility[productID],
        observation: transientCheckedObservations[productID]?.value,
        errorMessage: error.localizedDescription
      )
    }
  }

  func storeContainingSafeSync(_ id: UUID) async throws -> SQLiteStore? {
    for store in await allKnownStores() {
      if try await store.fetchRemoteSafeSync(id: id) != nil { return store }
    }
    return nil
  }

  func storeContainingPublication(_ id: UUID) async throws -> SQLiteStore? {
    for store in await allKnownStores() {
      if try await store.fetchRemotePublication(id: id) != nil { return store }
    }
    return nil
  }

  func allKnownStores() async -> [SQLiteStore] {
    await storesProvider()
  }

  func requireAvailable() throws {
    guard configuration.isConfigured else {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }
    guard !isShuttingDown else {
      throw GitHubRemoteRepositoryServiceError.unavailable("Spedito is shutting down.")
    }
  }

  static func permissions(
    from value: GitHubInstallationPermissions
  ) -> RemoteRepositoryPermissions {
    RemoteRepositoryPermissions(
      metadataRead: value.metadata == "read" || value.metadata == "write",
      contentsWrite: value.contents == "write",
      pullRequestsWrite: value.pullRequests == "write",
      workflowsWrite: value.workflows == "write"
    )
  }

  static func snapshot(
    from value: GitHubAPIPullRequest,
    headSHA: String? = nil
  ) -> RemotePullRequestSnapshot {
    RemotePullRequestSnapshot(
      number: value.number,
      nodeID: value.nodeID,
      canonicalURL: value.htmlURL,
      state: RemotePullRequestState(rawValue: value.state.rawValue) ?? .closed,
      isDraft: value.isDraft,
      headSHA: headSHA ?? value.headSHA,
      baseBranch: value.baseBranch,
      baseSHA: value.baseSHA,
      mergedSHA: value.mergedSHA,
      updatedAt: value.updatedAt
    )
  }

  static func githubTarget(from url: URL) -> (owner: String, name: String)? {
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com",
      url.user == nil,
      url.password == nil,
      url.query == nil,
      url.fragment == nil
    else { return nil }
    let components = url.path.split(separator: "/").map(String.init)
    guard components.count == 2 else { return nil }
    var name = components[1]
    if name.hasSuffix(".git") { name.removeLast(4) }
    guard !components[0].isEmpty, !name.isEmpty else { return nil }
    return (components[0], name)
  }
}
