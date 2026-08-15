import Foundation

extension GitHubRemoteRepositoryService {
  public func check(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    try await check(productID: productID, retainsObservationRef: false)
  }

  public func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation {
    let state = try await check(productID: productID, retainsObservationRef: true)
    guard let checked = transientCheckedObservations[productID] else {
      throw GitHubRemoteRepositoryServiceError.stale
    }
    guard checked.value.relationship != .unrelated else {
      let workspace = try await workspaceProvider(productID)
      try? await git.deleteRemoteObservationRef(
        repositoryURL: workspace,
        ref: checked.value.observationRef
      )
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "GitHub contains unrelated history that cannot be integrated into this ticket safely."
      )
    }
    return GitHubTicketIntegrationPreparation(
      state: state,
      base: GitHubTicketIntegrationBase(
        observationRef: checked.value.observationRef,
        remoteSHA: checked.value.remoteSHA
      )
    )
  }

  private func check(
    productID: UUID,
    retainsObservationRef: Bool
  ) async throws -> GitHubRemoteRepositoryState {
    try requireAvailable()
    guard let store = await storeProvider(productID),
      var connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      connection.status == .connected,
      connection.permissions.permitsPublication,
      let accountID = connection.accountID,
      let owner = connection.owner,
      let name = connection.name,
      let canonicalURL = connection.canonicalHTTPSURL,
      let targetBranch = connection.defaultBranch,
      let repositoryID = connection.repositoryID,
      let isPrivate = connection.isPrivate
    else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "The GitHub repository is not ready."
      )
    }
    let workspace = try await workspaceProvider(productID)
    let previousObservationRef = transientCheckedObservations[productID]?.value.observationRef
    var checked: CheckedObservation?
    for attempt in 0..<2 {
      let before = try await accountCatalog.withAccessToken(accountID: accountID) { token in
        async let repository = self.api.repository(owner: owner, name: name, accessToken: token)
        async let head = self.api.branchHead(
          owner: owner,
          name: name,
          branch: targetBranch,
          accessToken: token
        )
        return try await (repository, head)
      }
      guard let beforeHead = before.1 else {
        throw GitHubRemoteRepositoryServiceError.unavailable(
          "The GitHub default branch does not contain a commit."
        )
      }
      let gitObservation = try await withCredential(connection: connection) { credential in
        try await self.git.fetchRemoteObservation(
          repositoryURL: workspace,
          canonicalHTTPSURL: canonicalURL,
          targetBranch: targetBranch,
          observationID: UUID(),
          credentialConfiguration: credential
        )
      }
      let after = try await accountCatalog.withAccessToken(accountID: accountID) { token in
        async let repository = self.api.repository(owner: owner, name: name, accessToken: token)
        async let head = self.api.branchHead(
          owner: owner,
          name: name,
          branch: targetBranch,
          accessToken: token
        )
        return try await (repository, head)
      }
      if before.0.id == repositoryID,
        after.0.id == repositoryID,
        before.0.canonicalHTTPSURL == canonicalURL,
        after.0.canonicalHTTPSURL == canonicalURL,
        before.0.defaultBranch == targetBranch,
        after.0.defaultBranch == targetBranch,
        beforeHead.sha == gitObservation.remoteSHA,
        after.1?.sha == gitObservation.remoteSHA
      {
        var relationship = gitObservation.relationship
        var candidateSHA: String?
        var candidateTree: String?
        var provingPublicationID: UUID?
        var publishedSHA: String?
        if relationship == .remoteAhead {
          candidateSHA = gitObservation.remoteSHA
          candidateTree = gitObservation.remoteTree
        } else if relationship == .diverged,
          let publication = try await store.fetchLatestRemotePublication(productID: productID),
          publication.status == .merged,
          publication.capturedLocalSHA == publication.pullRequest?.headSHA,
          let published = publication.pushedSHA,
          let alignment = try? await git.createHistoryAlignmentCandidate(
            repositoryURL: workspace,
            localSHA: gitObservation.localSHA,
            remoteSHA: gitObservation.remoteSHA,
            publishedSHA: published,
            expectedRemoteTree: gitObservation.remoteTree
          )
        {
          relationship = .historyAlignmentAvailable
          candidateSHA = alignment.sha
          candidateTree = alignment.tree
          provingPublicationID = publication.id
          publishedSHA = published
        }
        let observation = RemoteRepositoryObservation(
          connectionVersion: connection.version,
          repositoryID: repositoryID,
          fullName: after.0.fullName,
          canonicalHTTPSURL: after.0.canonicalHTTPSURL,
          isPrivate: isPrivate,
          defaultBranch: after.0.defaultBranch,
          localSHA: gitObservation.localSHA,
          localTree: gitObservation.localTree,
          remoteSHA: gitObservation.remoteSHA,
          remoteTree: gitObservation.remoteTree,
          mergeBaseSHA: gitObservation.mergeBaseSHA,
          aheadCount: gitObservation.aheadCount,
          behindCount: gitObservation.behindCount,
          relationship: relationship,
          observationRef: gitObservation.observationRef,
          commits: gitObservation.commits,
          paths: gitObservation.paths.map(\.displayPath)
        )
        checked = CheckedObservation(
          value: observation,
          candidateSHA: candidateSHA,
          candidateTree: candidateTree,
          provingPublicationID: provingPublicationID,
          publishedSHA: publishedSHA
        )
        break
      }
      try? await git.deleteRemoteObservationRef(
        repositoryURL: workspace,
        ref: gitObservation.observationRef
      )
      if attempt == 1 { throw GitHubRemoteRepositoryServiceError.stale }
    }
    guard let checked else { throw GitHubRemoteRepositoryServiceError.stale }
    connection = try await store.recordRemoteRepositoryObservation(
      checked.value,
      connectionID: connection.id,
      expectedVersion: connection.version
    )
    let adjustedObservation = RemoteRepositoryObservation(
      id: checked.value.id,
      connectionVersion: connection.version,
      repositoryID: checked.value.repositoryID,
      fullName: checked.value.fullName,
      canonicalHTTPSURL: checked.value.canonicalHTTPSURL,
      isPrivate: checked.value.isPrivate,
      defaultBranch: checked.value.defaultBranch,
      localSHA: checked.value.localSHA,
      localTree: checked.value.localTree,
      remoteSHA: checked.value.remoteSHA,
      remoteTree: checked.value.remoteTree,
      mergeBaseSHA: checked.value.mergeBaseSHA,
      aheadCount: checked.value.aheadCount,
      behindCount: checked.value.behindCount,
      relationship: checked.value.relationship,
      observationRef: checked.value.observationRef,
      commits: checked.value.commits,
      paths: checked.value.paths,
      observedAt: checked.value.observedAt
    )
    transientCheckedObservations[productID] = CheckedObservation(
      value: adjustedObservation,
      candidateSHA: checked.candidateSHA,
      candidateTree: checked.candidateTree,
      provingPublicationID: checked.provingPublicationID,
      publishedSHA: checked.publishedSHA
    )
    if let previousObservationRef,
      previousObservationRef != adjustedObservation.observationRef
    {
      try? await git.deleteRemoteObservationRef(
        repositoryURL: workspace,
        ref: previousObservationRef
      )
    }
    if checked.candidateSHA == nil, !retainsObservationRef {
      try? await git.deleteRemoteObservationRef(
        repositoryURL: workspace,
        ref: checked.value.observationRef
      )
    }
    return await makeState(productID: productID)
  }

  public func prepareSafeSync(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeProvider(productID),
      let connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      let checked = transientCheckedObservations[productID],
      let candidateSHA = checked.candidateSHA,
      let candidateTree = checked.candidateTree,
      checked.value.connectionVersion == connection.version
    else { throw GitHubRemoteRepositoryServiceError.stale }
    let kind: RemoteSafeSyncKind =
      checked.value.relationship == .remoteAhead
      ? .fastForward
      : .historyAlignment
    _ = try await store.createRemoteSafeSync(
      RemoteSafeSync(
        productID: productID,
        connectionID: connection.id,
        connectionVersion: connection.version,
        kind: kind,
        observationRef: checked.value.observationRef,
        localSHA: checked.value.localSHA,
        localTree: checked.value.localTree,
        remoteSHA: checked.value.remoteSHA,
        remoteTree: checked.value.remoteTree,
        mergeBaseSHA: checked.value.mergeBaseSHA,
        candidateSHA: candidateSHA,
        candidateTree: candidateTree,
        provingPublicationID: checked.provingPublicationID,
        publishedSHA: checked.publishedSHA,
        commits: checked.value.commits,
        paths: checked.value.paths
      )
    )
    return await makeState(productID: productID)
  }

  public func acceptSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    guard let store = try await storeContainingSafeSync(syncID),
      let sync = try await store.fetchRemoteSafeSync(id: syncID)
    else { throw GitHubRemoteRepositoryServiceError.stale }
    var accepting = try await store.prepareRemoteSafeSyncAcceptance(
      id: sync.id,
      expectedVersion: sync.version,
      expectedStatus: sync.status,
      expectedLocalSHA: sync.localSHA
    )
    let workspace = try await workspaceProvider(sync.productID)
    try await git.promoteRemoteSafeSync(
      repositoryURL: workspace,
      expectedTrunkSHA: sync.localSHA,
      candidateSHA: sync.candidateSHA,
      expectedTree: sync.candidateTree
    )
    accepting = try await store.finishRemoteSafeSyncAcceptance(
      id: accepting.id,
      expectedVersion: accepting.version,
      expectedStatus: .accepting
    )
    try? await git.deleteRemoteObservationRef(
      repositoryURL: workspace,
      ref: sync.observationRef
    )
    _ = try await store.markRemotePublicationOutdated(
      productID: sync.productID,
      newLocalSHA: sync.candidateSHA
    )
    transientCheckedObservations.removeValue(forKey: sync.productID)
    _ = accepting
    return await makeState(productID: sync.productID)
  }

  public func rejectSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    guard let store = try await storeContainingSafeSync(syncID),
      let sync = try await store.fetchRemoteSafeSync(id: syncID)
    else { throw GitHubRemoteRepositoryServiceError.stale }
    _ = try await store.rejectRemoteSafeSync(
      id: sync.id,
      expectedVersion: sync.version,
      expectedStatus: sync.status,
      candidateSHA: sync.candidateSHA
    )
    let workspace = try await workspaceProvider(sync.productID)
    try? await git.deleteRemoteObservationRef(
      repositoryURL: workspace,
      ref: sync.observationRef
    )
    transientCheckedObservations.removeValue(forKey: sync.productID)
    return await makeState(productID: sync.productID)
  }
}
