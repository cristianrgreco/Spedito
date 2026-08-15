import Foundation

extension GitHubRemoteRepositoryService {

  public func prepareTicketPullRequest(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    try await preparePublication(
      productID: productID,
      workItemID: workItemID,
      candidateRevisionID: candidateRevisionID,
      purpose: .ticket,
      publishesImmediately: true
    )
  }

  func preparePublication(
    productID: UUID,
    workItemID: UUID?,
    candidateRevisionID: UUID?,
    purpose: RemotePublicationPurpose,
    publishesImmediately: Bool,
    checkedState: GitHubRemoteRepositoryState? = nil,
    initializationProgress: (
      @Sendable (GitHubRemoteRepositoryInitializationProgress) async -> Void
    )? = nil
  ) async throws -> GitHubRemoteRepositoryState {
    let currentState: GitHubRemoteRepositoryState
    if let checkedState {
      currentState = checkedState
    } else {
      currentState = try await check(productID: productID)
    }
    guard let store = await storeProvider(productID),
      let connection = currentState.connection,
      let accountID = connection.accountID,
      let repositoryID = connection.repositoryID,
      let owner = connection.owner,
      let name = connection.name,
      let fullName = connection.fullName,
      let url = connection.canonicalHTTPSURL,
      let isPrivate = connection.isPrivate,
      let baseSHA = connection.latestRemoteSHA,
      let baseTree = connection.latestRemoteTree,
      let acceptedLocalSHA = connection.latestLocalSHA,
      let acceptedLocalTree = connection.latestLocalTree,
      let targetBranch = connection.defaultBranch
    else {
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "Publishing is not available. Check GitHub history before creating another pull request."
      )
    }
    let workspace = try await workspaceProvider(productID)
    let localSHA: String
    let localTree: String
    let ticket: WorkItem?
    if let workItemID, let candidateRevisionID {
      let candidate = try await store.fetchCandidateRevision(id: candidateRevisionID)
      guard
        let workItem = try await store.fetchWorkItems(productID: productID)
          .first(where: { $0.id == workItemID }),
        candidate.productID == productID,
        candidate.workItemID == workItemID,
        candidate.deliveryKind.changesRepository,
        let integratedSHA = candidate.integratedSHA,
        candidate.status == .integrating || candidate.status == .reviewing
          || candidate.status == .readyForDemo,
        try await git.integratedRevisionContainsCurrentTrunk(
          repositoryURL: workspace,
          integratedSHA: integratedSHA
        )
      else {
        throw GitHubRemoteRepositoryServiceError.notEligible(
          "This ticket revision is no longer the exact reviewed Product revision."
        )
      }
      localSHA = integratedSHA
      localTree = try await git.revisionTreeSHA(
        repositoryURL: workspace,
        revisionSHA: integratedSHA
      )
      ticket = workItem
    } else if workItemID == nil, candidateRevisionID == nil {
      localSHA = acceptedLocalSHA
      localTree = acceptedLocalTree
      ticket = nil
    } else {
      throw GitHubRemoteRepositoryServiceError.stale
    }
    if workItemID != nil {
      guard
        try await git.revision(
          localSHA,
          contains: baseSHA,
          at: workspace
        )
      else {
        throw GitHubRemoteRepositoryServiceError.ticketIntegrationRequired
      }
    } else {
      guard connection.latestRelationship == .localAhead else {
        throw GitHubRemoteRepositoryServiceError.notEligible(
          "Publishing is not available. Check GitHub history before creating another pull request."
        )
      }
    }
    let manifest = try await accountCatalog.withAccessToken(accountID: accountID) { token in
      try await self.git.outboundManifest(
        repositoryURL: workspace,
        remoteBaseSHA: baseSHA,
        localSHA: localSHA,
        activeTokens: [token]
      )
    }
    guard !manifest.commits.isEmpty else {
      throw GitHubRemoteRepositoryServiceError.notEligible("There are no local changes to publish.")
    }
    let productName =
      try await store.fetchProducts().first(where: { $0.id == productID })?.name
      ?? "Product"
    let branch = GitWorkspaceManager.publicationBranchName(
      productName: productName,
      productID: productID,
      localSHA: localSHA
    )
    let title: String
    let body: String
    if let ticket {
      title = "\(ticket.key): \(ticket.title)"
      body = Self.ticketPullRequestBody(ticket: ticket, localSHA: localSHA)
    } else if purpose == .existingProductHistory {
      title = "Publish existing Product history"
      body = """
        ## Existing Product history

        This pull request publishes \(manifest.commitCount) accepted local commit\(manifest.commitCount == 1 ? "" : "s") across \(manifest.pathCount) path\(manifest.pathCount == 1 ? "" : "s").

        Captured revision: `\(localSHA)`
        Remote bootstrap: `\(baseSHA)`

        Spedito created this pull request and will merge only this exact captured revision.
        """
    } else {
      title = manifest.commits.last?.subject ?? "Publish local changes"
      body = textValidator.defaultBody(
        commits: manifest.commits.map {
          RemotePublicationCommitText(sha: $0.sha, subject: $0.subject)
        },
        localSHA: localSHA,
        remoteSHA: baseSHA
      )
    }
    try await validateText(
      accountID: accountID,
      productID: productID,
      connectionID: connection.id,
      publicationID: nil,
      title: title,
      body: body
    )
    let activePublications = try await store.fetchRemotePublications(productID: productID)
      .filter(\.status.isActive)
    if let workItemID, let candidateRevisionID,
      let active = activePublications.first(where: { $0.workItemID == workItemID })
    {
      if active.candidateRevisionID == candidateRevisionID,
        active.capturedLocalSHA == localSHA,
        active.remoteBaseSHA == baseSHA
      {
        return await makeState(productID: productID)
      }
      let revised = try await store.prepareRemoteTicketRevision(
        id: active.id,
        expectedVersion: active.version,
        expectedStatus: active.status,
        candidateRevisionID: candidateRevisionID,
        capturedLocalSHA: localSHA,
        capturedLocalTree: localTree,
        remoteBaseSHA: baseSHA,
        remoteBaseTree: baseTree,
        manifest: manifest,
        paths: manifest.paths.map(\.displayPath),
        title: title,
        body: body
      )
      try await executePublication(publication: revised, store: store, includesPush: true)
      return await makeState(productID: productID)
    }
    if workItemID == nil, !activePublications.isEmpty {
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "Another pull request is still active for this Product."
      )
    }
    let publication = try await store.createRemotePublication(
      RemotePublication(
        productID: productID,
        connectionID: connection.id,
        workItemID: workItemID,
        candidateRevisionID: candidateRevisionID,
        purpose: purpose,
        accountID: accountID,
        repositoryID: repositoryID,
        owner: owner,
        name: name,
        fullName: fullName,
        canonicalHTTPSURL: url,
        isPrivate: isPrivate,
        permissions: connection.permissions,
        capturedLocalSHA: localSHA,
        capturedLocalTree: localTree,
        remoteBaseSHA: baseSHA,
        remoteBaseTree: baseTree,
        targetBranch: targetBranch,
        publicationBranch: branch,
        manifestDigest: manifest.digest,
        manifestObjectCount: manifest.objectCount,
        manifestCommitCount: manifest.commitCount,
        manifestPathCount: manifest.pathCount,
        commits: manifest.commits,
        paths: manifest.paths.map(\.displayPath),
        title: title,
        body: body
      )
    )
    if publishesImmediately {
      let checking = try await store.prepareRemotePublicationCheck(
        id: publication.id,
        expectedVersion: publication.version,
        expectedStatus: .awaitingConfirmation,
        title: publication.title,
        body: publication.body,
        textRevision: publication.textRevision + 1
      )
      if let initializationProgress {
        await initializationProgress(.publishingExistingHistory)
      }
      try await executePublication(publication: checking, store: store, includesPush: true)
      if purpose == .existingProductHistory, let initializationProgress {
        await initializationProgress(.mergingExistingHistory)
      }
      if purpose == .existingProductHistory {
        return try await completeExistingProductHistoryPublicationIfReady(
          publicationID: publication.id,
          store: store
        )
      }
    }
    return await makeState(productID: productID)
  }

  public func refreshPullRequest(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = try await storeContainingPublication(publicationID),
      let publication = try await store.fetchRemotePublication(id: publicationID),
      let pullRequest = publication.pullRequest
    else { throw GitHubRemoteRepositoryServiceError.stale }
    let snapshot = try await accountCatalog.withAccessToken(accountID: publication.accountID) {
      token in
      try await self.api.pullRequest(
        owner: publication.owner,
        name: publication.name,
        number: pullRequest.number,
        accessToken: token
      )
    }
    let reconciled = try await reconciledPullRequestSnapshot(
      from: snapshot,
      publication: publication
    )
    var updated = try await store.refreshRemotePullRequestState(
      id: publication.id,
      expectedVersion: publication.version,
      snapshot: reconciled
    )
    updated = try await cleanupMergedPublicationBranch(
      publication: updated,
      store: store
    )
    if updated.purpose == .existingProductHistory {
      return try await completeExistingProductHistoryPublicationIfReady(
        publicationID: updated.id,
        store: store
      )
    }
    return await makeState(productID: publication.productID)
  }

  public func markTicketPullRequestReady(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = try await storeContainingPublication(publicationID),
      let publication = try await store.fetchRemotePublication(id: publicationID),
      publication.workItemID != nil,
      let pullRequest = publication.pullRequest,
      publication.status == .open,
      pullRequest.state == .open,
      pullRequest.isDraft,
      pullRequest.headSHA == publication.capturedLocalSHA,
      pullRequest.baseBranch == publication.targetBranch
    else { throw GitHubRemoteRepositoryServiceError.stale }
    try await accountCatalog.withAccessToken(accountID: publication.accountID) { token in
      try await self.api.markPullRequestReadyForReview(
        nodeID: pullRequest.nodeID,
        accessToken: token
      )
    }
    return try await refreshPullRequest(publicationID: publicationID)
  }

  public func returnTicketPullRequestToDraft(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = try await storeContainingPublication(publicationID),
      let publication = try await store.fetchRemotePublication(id: publicationID),
      publication.workItemID != nil,
      let pullRequest = publication.pullRequest,
      publication.status == .open,
      pullRequest.state == .open,
      !pullRequest.isDraft,
      pullRequest.headSHA == publication.capturedLocalSHA,
      pullRequest.baseBranch == publication.targetBranch
    else { throw GitHubRemoteRepositoryServiceError.stale }
    try await accountCatalog.withAccessToken(accountID: publication.accountID) { token in
      try await self.api.convertPullRequestToDraft(
        nodeID: pullRequest.nodeID,
        accessToken: token
      )
    }
    return try await refreshPullRequest(publicationID: publicationID)
  }

  public func syncTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    guard let store = try await storeContainingPublication(publicationID),
      var publication = try await store.fetchRemotePublication(id: publicationID),
      let workItemID = publication.workItemID,
      let pullRequest = publication.pullRequest
    else { throw GitHubRemoteRepositoryServiceError.stale }
    let requestPublication = publication
    let result = try await accountCatalog.withAccessToken(accountID: requestPublication.accountID) {
      token in
      async let snapshot = self.api.pullRequest(
        owner: requestPublication.owner,
        name: requestPublication.name,
        number: pullRequest.number,
        accessToken: token,
        useConditionalRequest: true
      )
      async let feedback = self.api.pullRequestFeedback(
        owner: requestPublication.owner,
        name: requestPublication.name,
        number: pullRequest.number,
        accessToken: token,
        useConditionalRequests: true
      )
      return try await (snapshot, feedback)
    }
    let reconciled = try await reconciledPullRequestSnapshot(
      from: result.0,
      publication: publication
    )
    publication = try await store.refreshRemotePullRequestState(
      id: publication.id,
      expectedVersion: publication.version,
      snapshot: reconciled
    )
    publication = try await cleanupMergedPublicationBranch(
      publication: publication,
      store: store
    )
    for feedback in result.1 {
      let body: String
      if let decision = feedback.decision {
        let label =
          switch decision {
          case .approved: "Approved"
          case .changesRequested: "Changes requested"
          case .commented: "Review comment"
          case .dismissed: "Review dismissed"
          case .pending: "Pending review"
          }
        let detail = feedback.body.trimmingCharacters(in: .whitespacesAndNewlines)
        body = detail.isEmpty ? "GitHub review: \(label)." : "GitHub review — \(label)\n\n\(detail)"
      } else {
        body = feedback.body
      }
      guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      _ = try await store.appendExternalCommentIfNeeded(
        workItemID: workItemID,
        authorName: feedback.reviewerLogin,
        body: body,
        authorAvatarURL: feedback.reviewerAvatarURL,
        externalURL: feedback.canonicalURL,
        externalID: "github:\(publication.repositoryID):\(pullRequest.number):\(feedback.id)",
        createdAt: feedback.createdAt,
        githubReviewContext: feedback.reviewContext
      )
    }
    let latestDecision = result.1
      .filter { $0.decision == .approved || $0.decision == .changesRequested }
      .max { $0.createdAt < $1.createdAt }?
      .decision
    if latestDecision == .changesRequested,
      let refreshed = publication.pullRequest,
      refreshed.state == .open,
      !refreshed.isDraft
    {
      let draftPublication = publication
      try await accountCatalog.withAccessToken(accountID: draftPublication.accountID) { token in
        try await self.api.convertPullRequestToDraft(
          nodeID: refreshed.nodeID,
          accessToken: token
        )
      }
      let snapshot = try await accountCatalog.withAccessToken(accountID: draftPublication.accountID)
      {
        token in
        try await self.api.pullRequest(
          owner: draftPublication.owner,
          name: draftPublication.name,
          number: refreshed.number,
          accessToken: token
        )
      }
      let reconciled = try await reconciledPullRequestSnapshot(
        from: snapshot,
        publication: publication
      )
      publication = try await store.refreshRemotePullRequestState(
        id: publication.id,
        expectedVersion: publication.version,
        snapshot: reconciled
      )
    }
    return GitHubTicketPullRequestSync(
      state: await makeState(productID: publication.productID),
      workItemID: workItemID,
      changesRequested: latestDecision == .changesRequested,
      closedWithoutMerge: publication.status == .closed
    )
  }

  public func mergeTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult {
    guard let store = try await storeContainingPublication(publicationID),
      var publication = try await store.fetchRemotePublication(id: publicationID),
      publication.purpose == .ticket || publication.purpose == .existingProductHistory,
      let pullRequest = publication.pullRequest
    else { throw GitHubRemoteRepositoryServiceError.stale }
    let mergePublication = publication
    let current = try await accountCatalog.withAccessToken(accountID: mergePublication.accountID) {
      token in
      try await self.api.pullRequest(
        owner: mergePublication.owner,
        name: mergePublication.name,
        number: pullRequest.number,
        accessToken: token
      )
    }
    guard current.headSHA == mergePublication.capturedLocalSHA,
      current.baseBranch == mergePublication.targetBranch
    else {
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "GitHub changed this pull request. Review it on GitHub before trying again."
      )
    }
    guard current.baseSHA == mergePublication.remoteBaseSHA else {
      if mergePublication.purpose == .ticket {
        throw GitHubRemoteRepositoryServiceError.ticketIntegrationRequired
      }
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "GitHub changed this pull request. Review it on GitHub before trying again."
      )
    }
    let mergedSnapshot: GitHubAPIPullRequest
    if current.state == .merged, current.mergedSHA != nil {
      mergedSnapshot = current
    } else {
      guard current.state == .open, !current.isDraft else {
        throw GitHubRemoteRepositoryServiceError.notEligible(
          "GitHub changed this pull request. Review it on GitHub before trying again."
        )
      }
      let merge: GitHubPullRequestMerge
      do {
        merge = try await accountCatalog.withAccessToken(
          accountID: mergePublication.accountID
        ) { token in
          try await self.api.mergePullRequest(
            owner: mergePublication.owner,
            name: mergePublication.name,
            number: current.number,
            expectedHeadSHA: mergePublication.capturedLocalSHA,
            accessToken: token
          )
        }
      } catch GitHubAPIError.conflict
        where mergePublication.purpose == .ticket
      {
        throw GitHubRemoteRepositoryServiceError.ticketIntegrationRequired
      } catch GitHubAPIError.unprocessable(_)
        where mergePublication.purpose == .ticket
      {
        throw GitHubRemoteRepositoryServiceError.ticketIntegrationRequired
      }
      mergedSnapshot = GitHubAPIPullRequest(
        number: current.number,
        nodeID: current.nodeID,
        htmlURL: current.htmlURL,
        state: .merged,
        isDraft: false,
        headSHA: current.headSHA,
        baseBranch: current.baseBranch,
        baseSHA: current.baseSHA,
        mergedSHA: merge.sha,
        updatedAt: current.updatedAt
      )
    }
    guard let mergedSHA = mergedSnapshot.mergedSHA else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "GitHub did not identify the merged revision."
      )
    }
    publication = try await store.refreshRemotePullRequestState(
      id: publication.id,
      expectedVersion: publication.version,
      snapshot: Self.snapshot(from: mergedSnapshot)
    )
    publication = try await cleanupMergedPublicationBranch(
      publication: publication,
      store: store
    )
    let checked = try await checkAfterMerge(
      productID: publication.productID,
      mergedSHA: mergedSHA
    )
    let reconciled = try await reconcileMergedPublication(
      productID: publication.productID,
      checkedState: checked
    )
    guard
      let finalPublication = try await store.fetchRemotePublication(id: publication.id),
      finalPublication.status == .merged
    else { throw GitHubRemoteRepositoryServiceError.stale }
    return GitHubTicketPullRequestMergeResult(
      state: reconciled,
      publication: finalPublication,
      mergedSHA: mergedSHA
    )
  }

  private func checkAfterMerge(
    productID: UUID,
    mergedSHA: String
  ) async throws -> GitHubRemoteRepositoryState {
    for attempt in 0..<4 {
      do {
        let state = try await check(productID: productID)
        if state.observation?.remoteSHA == mergedSHA {
          return state
        }
      } catch GitHubRemoteRepositoryServiceError.stale {
        // GitHub's branch API and Git transport can briefly disagree after a merge.
      }
      if attempt < 3 {
        try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
      }
    }
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "GitHub merged the pull request, but its default branch has not reported the merged revision yet. Try again from Product settings."
    )
  }

  private func reconcileMergedPublication(
    productID: UUID,
    checkedState: GitHubRemoteRepositoryState
  ) async throws -> GitHubRemoteRepositoryState {
    if checkedState.observation?.relationship == .aligned {
      return checkedState
    }
    if let sync = checkedState.safeSync, sync.status == .awaitingConfirmation {
      return try await acceptSafeSync(syncID: sync.id)
    }
    guard
      checkedState.observation?.relationship == .remoteAhead
        || checkedState.observation?.relationship == .historyAlignmentAvailable
    else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "GitHub reports that the pull request is merged, but its default branch does not contain the merged result yet. Try finishing GitHub setup again."
      )
    }
    let prepared = try await prepareSafeSync(productID: productID)
    guard let sync = prepared.safeSync, sync.status == .awaitingConfirmation else {
      throw GitHubRemoteRepositoryServiceError.stale
    }
    return try await acceptSafeSync(syncID: sync.id)
  }
  func executePublication(
    publication initial: RemotePublication,
    store: SQLiteStore,
    includesPush: Bool
  ) async throws {
    var publication = initial
    let workspace = try await workspaceProvider(publication.productID)
    if includesPush {
      let revisionIsCurrent: Bool
      if publication.workItemID == nil {
        revisionIsCurrent =
          try await git.currentSHA(at: workspace) == publication.capturedLocalSHA
      } else {
        let treeMatches =
          try await git.revisionTreeSHA(
            repositoryURL: workspace,
            revisionSHA: publication.capturedLocalSHA
          ) == publication.capturedLocalTree
        let containsTrunk = try await git.integratedRevisionContainsCurrentTrunk(
          repositoryURL: workspace,
          integratedSHA: publication.capturedLocalSHA
        )
        revisionIsCurrent = treeMatches && containsTrunk
      }
      guard revisionIsCurrent else {
        _ = try await store.failRemotePublication(
          id: publication.id,
          expectedVersion: publication.version,
          expectedStatus: publication.status,
          errorCode: "local_revision_changed"
        )
        return
      }
      let manifestPublication = publication
      let manifest = try await accountCatalog.withAccessToken(
        accountID: manifestPublication.accountID
      ) { token in
        try await self.git.outboundManifest(
          repositoryURL: workspace,
          remoteBaseSHA: manifestPublication.remoteBaseSHA,
          localSHA: manifestPublication.capturedLocalSHA,
          activeTokens: [token]
        )
      }
      guard manifest.digest == publication.manifestDigest else {
        _ = try await store.failRemotePublication(
          id: publication.id,
          expectedVersion: publication.version,
          expectedStatus: publication.status,
          errorCode: "manifest_changed"
        )
        return
      }
      try await validateText(
        publication: publication,
        title: publication.title,
        body: publication.body
      )
      publication = try await store.prepareRemoteBranchPush(
        id: publication.id,
        expectedVersion: publication.version,
        expectedStatus: publication.status,
        expectedLocalSHA: publication.capturedLocalSHA,
        expectedManifestDigest: publication.manifestDigest,
        expectedRemoteBaseSHA: publication.remoteBaseSHA
      )
      let branchPublication = publication
      try await withCredential(publication: branchPublication) { credential in
        try await self.git.createRemoteReviewBranch(
          repositoryURL: workspace,
          canonicalHTTPSURL: branchPublication.canonicalHTTPSURL,
          fullRef: "refs/heads/\(branchPublication.publicationBranch)",
          localSHA: branchPublication.capturedLocalSHA,
          expectedCurrentSHA:
            branchPublication.pullRequest?.headSHA ?? branchPublication.pushedSHA,
          credentialConfiguration: credential
        )
      }
      publication = try await store.recordPublishedBranch(
        id: publication.id,
        expectedVersion: publication.version,
        expectedAttempt: publication.pushAttemptCount,
        pushedSHA: publication.capturedLocalSHA
      )
    } else if publication.status == .pushing {
      let pushingPublication = publication
      let fullRef = "refs/heads/\(publication.publicationBranch)"
      let remoteSHA = try await withCredential(publication: pushingPublication) { credential in
        try await self.git.remoteHeadSHA(
          repositoryURL: workspace,
          canonicalHTTPSURL: pushingPublication.canonicalHTTPSURL,
          fullRef: fullRef,
          credentialConfiguration: credential
        )
      }
      guard remoteSHA == publication.capturedLocalSHA else {
        if remoteSHA != nil {
          _ = try await store.failRemotePublication(
            id: publication.id,
            expectedVersion: publication.version,
            expectedStatus: publication.status,
            errorCode: "remote_branch_conflict"
          )
        }
        return
      }
      publication = try await store.recordPublishedBranch(
        id: publication.id,
        expectedVersion: publication.version,
        expectedAttempt: publication.pushAttemptCount,
        pushedSHA: publication.capturedLocalSHA
      )
    }
    try await finishPullRequestCreation(publication: publication, store: store)
  }

  private func finishPullRequestCreation(
    publication initial: RemotePublication,
    store: SQLiteStore
  ) async throws {
    var publication = initial
    let history = try await pullRequestHistory(publication: publication)
    let open = history.filter { $0.state == .open }
    if open.count > 1 {
      _ = try await store.failRemotePublication(
        id: publication.id,
        expectedVersion: publication.version,
        expectedStatus: publication.status,
        errorCode: "multiple_open_pull_requests"
      )
      return
    }
    if let existing = open.first {
      let snapshot = try await reconciledPullRequestSnapshot(
        from: existing,
        publication: publication
      )
      guard snapshot.headSHA == publication.capturedLocalSHA,
        snapshot.baseBranch == publication.targetBranch
      else {
        publication = try await store.recordRemotePullRequest(
          id: publication.id,
          expectedVersion: publication.version,
          expectedAttempt: publication.pullRequestAttemptCount,
          snapshot: snapshot
        )
        _ = try await store.refreshRemotePullRequestState(
          id: publication.id,
          expectedVersion: publication.version,
          snapshot: snapshot
        )
        return
      }
      _ = try await store.recordRemotePullRequest(
        id: publication.id,
        expectedVersion: publication.version,
        expectedAttempt: publication.pullRequestAttemptCount,
        snapshot: snapshot
      )
      return
    }
    if let terminal =
      history
      .filter({ $0.state != .open })
      .sorted(by: { $0.updatedAt > $1.updatedAt })
      .first
    {
      var recorded = try await store.recordRemotePullRequest(
        id: publication.id,
        expectedVersion: publication.version,
        expectedAttempt: publication.pullRequestAttemptCount,
        snapshot: Self.snapshot(from: terminal)
      )
      recorded = try await cleanupMergedPublicationBranch(
        publication: recorded,
        store: store
      )
      _ = recorded
      return
    }
    guard publication.status == .branchPublished else { return }
    publication = try await store.prepareRemotePullRequestAttempt(
      id: publication.id,
      expectedVersion: publication.version,
      expectedStatus: publication.status,
      textRevision: publication.textRevision
    )
    let postPublication = publication
    for attempt in 0..<2 {
      do {
        let created = try await accountCatalog.withAccessToken(
          accountID: postPublication.accountID
        ) { token in
          try await self.api.createPullRequest(
            owner: postPublication.owner,
            name: postPublication.name,
            creation: GitHubPullRequestCreation(
              title: postPublication.title,
              body: postPublication.body,
              head: postPublication.publicationBranch,
              base: postPublication.targetBranch,
              isDraft: postPublication.workItemID != nil
            ),
            accessToken: token
          )
        }
        _ = try await store.recordRemotePullRequest(
          id: publication.id,
          expectedVersion: publication.version,
          expectedAttempt: publication.pullRequestAttemptCount,
          snapshot: Self.snapshot(from: created)
        )
        return
      } catch let error as GitHubAPIError {
        let recovered = try await pullRequestHistory(publication: publication)
        if let exact = recovered.first(where: {
          $0.state == .open
            && $0.headSHA == publication.capturedLocalSHA
            && $0.baseBranch == publication.targetBranch
        }) {
          _ = try await store.recordRemotePullRequest(
            id: publication.id,
            expectedVersion: publication.version,
            expectedAttempt: publication.pullRequestAttemptCount,
            snapshot: Self.snapshot(from: exact)
          )
          return
        }
        if attempt == 0, error == .timedOut || error == .serverUnavailable {
          continue
        }
        _ = try await store.recordRemotePullRequestAbsent(
          id: publication.id,
          expectedVersion: publication.version,
          expectedAttempt: publication.pullRequestAttemptCount,
          reasonCode: "pull_request_completion_required"
        )
        return
      }
    }
  }

  private func pullRequestHistory(
    publication: RemotePublication
  ) async throws -> [GitHubAPIPullRequest] {
    try await accountCatalog.withAccessToken(accountID: publication.accountID) { token in
      try await self.api.pullRequests(
        owner: publication.owner,
        name: publication.name,
        head: "\(publication.owner):\(publication.publicationBranch)",
        accessToken: token
      )
    }
  }

  private func reconciledPullRequestSnapshot(
    from value: GitHubAPIPullRequest,
    publication: RemotePublication
  ) async throws -> RemotePullRequestSnapshot {
    let observed = Self.snapshot(from: value)
    let matchesKnownPullRequest =
      if let prior = publication.pullRequest {
        prior.number == value.number
          && prior.nodeID == value.nodeID
          && (prior.headSHA == value.headSHA
            || prior.headSHA == publication.capturedLocalSHA)
      } else {
        publication.pullRequestAttemptCount > 0
      }
    guard
      value.state == .open,
      value.headSHA != publication.capturedLocalSHA,
      value.baseBranch == publication.targetBranch,
      publication.pushedSHA == publication.capturedLocalSHA,
      matchesKnownPullRequest
    else {
      return observed
    }
    let workspace = try await workspaceProvider(publication.productID)
    let publicationRef = "refs/heads/\(publication.publicationBranch)"
    let remoteSHA = try await withCredential(publication: publication) { credential in
      try await self.git.remoteHeadSHA(
        repositoryURL: workspace,
        canonicalHTTPSURL: publication.canonicalHTTPSURL,
        fullRef: publicationRef,
        credentialConfiguration: credential
      )
    }
    guard remoteSHA == publication.capturedLocalSHA else {
      return observed
    }
    return Self.snapshot(from: value, headSHA: publication.capturedLocalSHA)
  }

  private func cleanupMergedPublicationBranch(
    publication: RemotePublication,
    store: SQLiteStore
  ) async throws -> RemotePublication {
    guard publication.status == .merged,
      publication.remoteBranchDeletedAt == nil
    else {
      return publication
    }
    guard let pullRequest = publication.pullRequest,
      pullRequest.state == .merged,
      pullRequest.headSHA == publication.capturedLocalSHA,
      pullRequest.baseBranch == publication.targetBranch
    else {
      throw GitHubRemoteRepositoryServiceError.stale
    }
    let workspace = try await workspaceProvider(publication.productID)
    try await withCredential(publication: publication) { credential in
      try await self.git.deleteRemoteReviewBranch(
        repositoryURL: workspace,
        canonicalHTTPSURL: publication.canonicalHTTPSURL,
        fullRef: "refs/heads/\(publication.publicationBranch)",
        expectedSHA: publication.capturedLocalSHA,
        credentialConfiguration: credential
      )
    }
    return try await store.recordRemotePublicationBranchDeleted(
      id: publication.id,
      expectedVersion: publication.version
    )
  }

  func completeExistingProductHistoryPublicationIfReady(
    publicationID: UUID,
    store: SQLiteStore
  ) async throws -> GitHubRemoteRepositoryState {
    guard let publication = try await store.fetchRemotePublication(id: publicationID) else {
      throw GitHubRemoteRepositoryServiceError.stale
    }
    guard publication.purpose == .existingProductHistory else {
      return await makeState(productID: publication.productID)
    }
    guard let pullRequest = publication.pullRequest,
      pullRequest.headSHA == publication.capturedLocalSHA,
      pullRequest.baseBranch == publication.targetBranch,
      pullRequest.baseSHA == publication.remoteBaseSHA
    else {
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "GitHub changed this pull request. Review it on GitHub before trying again."
      )
    }
    if publication.status == .open, !pullRequest.isDraft {
      return try await mergeTicketPullRequest(publicationID: publicationID).state
    }
    if publication.status == .merged {
      let checked = try await check(productID: publication.productID)
      return try await reconcileMergedPublication(
        productID: publication.productID,
        checkedState: checked
      )
    }
    return await makeState(productID: publication.productID)
  }

  private static func ticketPullRequestBody(ticket: WorkItem, localSHA: String) -> String {
    let acceptanceCriteria =
      ticket.acceptanceCriteria.isEmpty
      ? "No separate acceptance criteria."
      : ticket.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    return """
      ## Ticket

      **\(ticket.key) — \(ticket.title)**

      \(ticket.body.trimmingCharacters(in: .whitespacesAndNewlines))

      ## Acceptance criteria

      \(acceptanceCriteria)

      ## Reviewed revision

      `\(localSHA)`

      Spedito created this pull request for review and did not merge it.
      """
  }

  private func validateText(
    accountID: UUID,
    productID: UUID,
    connectionID: UUID,
    publicationID: UUID?,
    title: String,
    body: String
  ) async throws {
    try await accountCatalog.withAccessToken(accountID: accountID) { token in
      var recordIdentifiers = [productID.uuidString, connectionID.uuidString]
      if let publicationID {
        recordIdentifiers.append(publicationID.uuidString)
      }
      try self.textValidator.validate(
        title: title,
        body: body,
        context: RemotePublicationTextValidationContext(
          activeTokens: [token],
          protectedPaths: [".spedito"],
          sqliteRecordIdentifiers: Set(recordIdentifiers)
        )
      )
    }
  }

  private func validateText(
    publication: RemotePublication,
    title: String,
    body: String
  ) async throws {
    try await validateText(
      accountID: publication.accountID,
      productID: publication.productID,
      connectionID: publication.connectionID,
      publicationID: publication.id,
      title: title,
      body: body
    )
  }

  func withCredential<T: Sendable>(
    connection: RemoteRepositoryConnection,
    operation: @escaping @Sendable (GitCredentialSessionConfiguration) async throws -> T
  ) async throws -> T {
    guard let accountID = connection.accountID,
      let repositoryURL = connection.canonicalHTTPSURL
    else { throw GitHubRemoteRepositoryServiceError.stale }
    return try await accountCatalog.withAccessToken(accountID: accountID) { token in
      try await self.credentialSession.withCredential(
        repositoryURL: repositoryURL,
        accessToken: token,
        operation: operation
      )
    }
  }

  private func withCredential<T: Sendable>(
    publication: RemotePublication,
    operation: @escaping @Sendable (GitCredentialSessionConfiguration) async throws -> T
  ) async throws -> T {
    try await accountCatalog.withAccessToken(accountID: publication.accountID) { token in
      try await self.credentialSession.withCredential(
        repositoryURL: publication.canonicalHTTPSURL,
        accessToken: token,
        operation: operation
      )
    }
  }
}
