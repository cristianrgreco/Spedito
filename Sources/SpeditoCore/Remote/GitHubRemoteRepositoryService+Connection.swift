import Foundation

extension GitHubRemoteRepositoryService {
  public func importRepositories() async throws -> GitHubRepositoryImportCatalog {
    try requireAvailable()
    let accountIDs = try await accountCatalog.authorizedAccountIDs()
    var installationsByID: [Int64: GitHubInstallation] = [:]
    var choicesByRepositoryID: [Int64: GitHubRepositoryChoice] = [:]
    for accountID in accountIDs {
      let access = try await repositoryAccess(accountID: accountID)
      for installation in access.installations {
        installationsByID[installation.id] = installation
      }
      for choice in access.choices {
        choicesByRepositoryID[choice.repository.id] = choice
      }
    }
    return GitHubRepositoryImportCatalog(
      installations: installationsByID.values.sorted {
        $0.accountLogin.localizedCaseInsensitiveCompare($1.accountLogin) == .orderedAscending
      },
      choices: choicesByRepositoryID.values.sorted {
        $0.repository.fullName.localizedCaseInsensitiveCompare($1.repository.fullName)
          == .orderedAscending
      }
    )
  }

  public func authorizeImport(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRepositoryImportCatalog {
    try requireAvailable()
    _ = try await accountCatalog.authorize(onPrompt: onPrompt)
    return try await importRepositories()
  }

  public func importProduct(
    name: String,
    repositoryID: Int64,
    importer:
      @escaping @Sendable (
        PublicGitRepositoryURL,
        GitCredentialSessionConfiguration
      ) async throws -> ImportedProduct
  ) async throws -> ImportedProduct {
    try requireAvailable()
    let accountIDs = try await accountCatalog.authorizedAccountIDs()
    for accountID in accountIDs {
      let choices = try await repositoryAccess(accountID: accountID).choices
      guard let choice = choices.first(where: { $0.repository.id == repositoryID }) else {
        continue
      }
      let source = try PublicGitRepositoryURL(
        choice.repository.canonicalHTTPSURL.absoluteString
      )
      let imported = try await accountCatalog.withAccessToken(accountID: accountID) { token in
        try await self.credentialSession.withCredential(
          repositoryURL: choice.repository.canonicalHTTPSURL,
          accessToken: token
        ) { credential in
          try await importer(source, credential)
        }
      }
      do {
        try await accountCatalog.linkProduct(
          productID: imported.product.id,
          accountID: accountID
        )
        _ = try await refreshRepositories(productID: imported.product.id)
      } catch {
        transientPresentationErrors[imported.product.id] =
          "The Product was imported, but its GitHub connection needs attention. \(error.localizedDescription)"
      }
      return imported
    }
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "That GitHub repository is no longer available to Spedito. Refresh the list and try again."
    )
  }

  public func connectLocalProduct(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState {
    try requireAvailable()
    let accountIDs = try await accountCatalog.authorizedAccountIDs()
    for accountID in accountIDs {
      let access = try await repositoryAccess(accountID: accountID)
      guard access.choices.contains(where: { $0.repository.id == repositoryID }) else {
        continue
      }
      try await accountCatalog.linkProduct(productID: productID, accountID: accountID)
      _ = try await refreshRepositories(productID: productID)
      let selected = try await selectLocalRepository(
        productID: productID,
        repositoryID: repositoryID
      )
      switch selected.selectedEligibility {
      case .empty:
        return try await initializeLocalRepository(productID: productID)
      case .ineligible(let message):
        throw GitHubRemoteRepositoryServiceError.notEligible(message)
      case .checking, .unchecked, nil:
        throw GitHubRemoteRepositoryServiceError.stale
      }
    }
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "That GitHub repository is no longer available to Spedito. Refresh the list and try again."
    )
  }

  public func connect(
    productID: UUID,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRemoteRepositoryState {
    try requireAvailable()
    transientPresentationErrors[productID] = nil
    if try await accountCatalog.linkProductToOnlyAuthorizedAccount(productID: productID) {
      do {
        return try await refreshRepositories(productID: productID)
      } catch let error as GitHubAPIError where error == .unauthorized {
        // A revoked or differently registered token cannot recover through refresh.
        // Continue into Device Flow so the owner can replace it in place.
      }
    }
    _ = try await accountCatalog.authorize(productID: productID, onPrompt: onPrompt)
    return try await refreshRepositories(productID: productID)
  }

  public func cancelConnection(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeProvider(productID),
      let connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      connection.status == .needsInstallation || connection.status == .selectingRepository
    else {
      return await makeState(productID: productID)
    }
    _ = try await store.cancelRemoteRepositoryConnectionSetup(
      id: connection.id,
      expectedVersion: connection.version
    )
    transientRepositoryChoices.removeValue(forKey: productID)
    transientSelectedEligibility.removeValue(forKey: productID)
    return await makeState(productID: productID)
  }

  public func disconnect(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeProvider(productID),
      let connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      let accountID = connection.accountID
    else {
      return await makeState(productID: productID)
    }
    try await accountCatalog.disconnect(productID: productID, accountID: accountID)
    transientCheckedObservations.removeValue(forKey: productID)
    return await makeState(productID: productID)
  }

  public func signOut(accountID: UUID) async throws {
    try await accountCatalog.signOut(accountID: accountID)
  }

  public func refreshRepositories(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    try requireAvailable()
    guard let store = await storeProvider(productID),
      var connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      let accountID = connection.accountID
    else {
      throw GitHubRemoteRepositoryServiceError.unavailable("Connect a GitHub account first.")
    }
    let access = try await repositoryAccess(accountID: accountID)
    let choices = access.choices
    transientRepositoryChoices[productID] = choices
    if connection.kind == .localEmptyRepository {
      if let repositoryID = connection.repositoryID {
        guard
          let choice = choices.first(where: { $0.repository.id == repositoryID }),
          choice.permissions.permitsPublication
        else {
          connection.installationID = access.installations.first?.id
          connection.status = .needsInstallation
          connection.errorCode = "installation_or_permissions_required"
          _ = try await store.saveRemoteRepositoryConnection(
            connection,
            expectedVersion: connection.version
          )
          return await makeState(productID: productID)
        }
        connection.installationID = choice.installationID
        connection.isPrivate = choice.repository.isPrivate
        connection.permissions = choice.permissions
        connection.errorCode = nil
        if connection.fullName == choice.repository.fullName,
          connection.canonicalHTTPSURL == choice.repository.canonicalHTTPSURL,
          connection.defaultBranch == choice.repository.defaultBranch
        {
          connection.status = .connected
        } else {
          connection.status = .needsTargetReview
          connection.pendingRepositoryID = choice.repository.id
          connection.pendingFullName = choice.repository.fullName
          connection.pendingCanonicalHTTPSURL = choice.repository.canonicalHTTPSURL
          connection.pendingDefaultBranch = choice.repository.defaultBranch
          connection.pendingObservedAt = Date()
        }
        _ = try await store.saveRemoteRepositoryConnection(
          connection,
          expectedVersion: connection.version
        )
        return await makeState(productID: productID)
      }
      guard let firstInstallation = access.installations.first else {
        connection.status = .needsInstallation
        connection.errorCode = "installation_required"
        _ = try await store.saveRemoteRepositoryConnection(
          connection,
          expectedVersion: connection.version
        )
        return await makeState(productID: productID)
      }
      connection.installationID = firstInstallation.id
      connection.status = .selectingRepository
      connection.errorCode = nil
      _ = try await store.saveRemoteRepositoryConnection(
        connection,
        expectedVersion: connection.version
      )
      return await makeState(productID: productID)
    }
    try await connectImportedProduct(
      productID: productID,
      connection: connection,
      installations: access.installations,
      choices: choices
    )
    let state = await makeState(productID: productID)
    if state.connection?.status == .connected {
      return try await check(productID: productID)
    }
    return state
  }

  public func selectLocalRepository(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState {
    try requireAvailable()
    guard let store = await storeProvider(productID),
      var connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      connection.kind == .localEmptyRepository,
      connection.status == .selectingRepository,
      let accountID = connection.accountID,
      let choice = transientRepositoryChoices[productID]?.first(where: { $0.id == repositoryID })
    else {
      throw GitHubRemoteRepositoryServiceError.stale
    }
    connection.installationID = choice.installationID
    connection.repositoryID = choice.repository.id
    connection.owner = choice.repository.owner
    connection.name = choice.repository.name
    connection.fullName = choice.repository.fullName
    connection.canonicalHTTPSURL = choice.repository.canonicalHTTPSURL
    connection.isPrivate = choice.repository.isPrivate
    connection.defaultBranch = choice.repository.defaultBranch
    connection.permissions = choice.permissions
    connection.errorCode = nil
    connection = try await store.saveRemoteRepositoryConnection(
      connection,
      expectedVersion: connection.version
    )
    transientSelectedEligibility[productID] = .checking
    do {
      let hasBranches = try await accountCatalog.withAccessToken(accountID: accountID) { token in
        try await self.api.repositoryHasBranches(
          owner: choice.repository.owner,
          name: choice.repository.name,
          accessToken: token
        )
      }
      guard !hasBranches else {
        transientSelectedEligibility[productID] = .ineligible(
          "This repository already contains work. Choose an empty repository instead."
        )
        return await makeState(productID: productID)
      }
      let workspace = try await workspaceProvider(productID)
      let bootstrap = try await git.localBootstrapRoot(repositoryURL: workspace)
      let history = try await existingProductHistorySummary(
        productID: productID,
        store: store,
        workspace: workspace,
        bootstrap: bootstrap
      )
      transientSelectedEligibility[productID] = .empty(
        bootstrap: bootstrap,
        existingHistory: history
      )
    } catch {
      transientSelectedEligibility[productID] = .ineligible(error.localizedDescription)
    }
    return await makeState(productID: productID)
  }

  public func initializeLocalRepository(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    try await initializeLocalRepository(productID: productID) { _ in }
  }

  public func initializeLocalRepository(
    productID: UUID,
    onProgress:
      @escaping @Sendable (
        GitHubRemoteRepositoryInitializationProgress
      ) async -> Void
  ) async throws -> GitHubRemoteRepositoryState {
    await onProgress(.validatingProduct)
    try requireAvailable()
    guard let store = await storeProvider(productID),
      var connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      connection.kind == .localEmptyRepository,
      case .empty(let bootstrap, let existingHistory) = transientSelectedEligibility[productID],
      let canonicalURL = connection.canonicalHTTPSURL,
      let defaultBranch = connection.defaultBranch
    else {
      throw GitHubRemoteRepositoryServiceError.notEligible(
        "Choose a repository first."
      )
    }
    let workspace = try await workspaceProvider(productID)
    _ = try await git.outboundManifest(
      repositoryURL: workspace,
      remoteBaseSHA: bootstrap.sha,
      localSHA: bootstrap.sha
    )
    connection = try await store.prepareLocalRemoteInitialization(
      id: connection.id,
      expectedVersion: connection.version,
      bootstrapSHA: bootstrap.sha,
      bootstrapTree: bootstrap.tree
    )
    await onProgress(.publishingBootstrap)
    try await withCredential(connection: connection) { credential in
      try await self.git.initializeEmptyRemote(
        repositoryURL: workspace,
        canonicalHTTPSURL: canonicalURL,
        defaultBranch: defaultBranch,
        bootstrapSHA: bootstrap.sha,
        credentialConfiguration: credential
      )
    }
    await onProgress(.verifyingConnection)
    connection = try await store.recordLocalRemoteSeed(
      id: connection.id,
      expectedVersion: connection.version,
      expectedAttempt: connection.initializationAttemptCount,
      seededSHA: bootstrap.sha
    )
    try await git.verifyOrAddOrigin(repositoryURL: workspace, canonicalHTTPSURL: canonicalURL)
    _ = try await store.finishLocalRemoteInitialization(
      id: connection.id,
      expectedVersion: connection.version,
      originVerified: true
    )
    transientSelectedEligibility.removeValue(forKey: productID)
    await onProgress(.checkingRepository)
    let checked = try await check(productID: productID)
    if existingHistory != nil {
      return try await prepareExistingProductHistoryPublication(
        productID: productID,
        checkedState: checked,
        onProgress: onProgress
      )
    }
    return checked
  }

  public func confirmTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeProvider(productID),
      let connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      let accountID = connection.accountID,
      let owner = connection.owner,
      let name = connection.name,
      let pendingID = connection.pendingRepositoryID,
      let pendingName = connection.pendingFullName,
      let pendingURL = connection.pendingCanonicalHTTPSURL,
      let pendingBranch = connection.pendingDefaultBranch
    else { throw GitHubRemoteRepositoryServiceError.stale }
    let repository = try await accountCatalog.withAccessToken(accountID: accountID) { token in
      try await self.api.repository(owner: owner, name: name, accessToken: token)
    }
    guard repository.id == pendingID,
      repository.fullName == pendingName,
      repository.canonicalHTTPSURL == pendingURL,
      repository.defaultBranch == pendingBranch
    else { throw GitHubRemoteRepositoryServiceError.stale }
    _ = try await store.confirmRemoteRepositoryTarget(
      productID: productID,
      expectedVersion: expectedVersion,
      pendingObservedAt: pendingObservedAt
    )
    return try await check(productID: productID)
  }
  private func repositoryAccess(
    accountID: UUID
  ) async throws -> GitHubRepositoryImportCatalog {
    let installations = try await accountCatalog.withAccessToken(accountID: accountID) { token in
      try await self.api.installations(accessToken: token)
    }
    var choices: [GitHubRepositoryChoice] = []
    for installation in installations {
      let repositories = try await accountCatalog.withAccessToken(accountID: accountID) { token in
        try await self.api.repositories(installationID: installation.id, accessToken: token)
      }
      let permissions = Self.permissions(from: installation.permissions)
      choices.append(
        contentsOf: repositories.map {
          GitHubRepositoryChoice(
            installationID: installation.id,
            repository: $0,
            permissions: permissions
          )
        })
    }
    choices.sort {
      $0.repository.fullName.localizedCaseInsensitiveCompare($1.repository.fullName)
        == .orderedAscending
    }
    return GitHubRepositoryImportCatalog(installations: installations, choices: choices)
  }

  private func connectImportedProduct(
    productID: UUID,
    connection: RemoteRepositoryConnection,
    installations: [GitHubInstallation],
    choices: [GitHubRepositoryChoice]
  ) async throws {
    guard let store = await storeProvider(productID) else {
      throw GitHubRemoteRepositoryServiceError.unavailable("The Product database is unavailable.")
    }
    guard let source = try await store.fetchProductRepository(productID: productID),
      let target = Self.githubTarget(from: source.originURL)
    else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "The imported Product’s GitHub provenance is unavailable."
      )
    }
    let choice = choices.first {
      $0.repository.owner.caseInsensitiveCompare(target.owner) == .orderedSame
        && $0.repository.name.caseInsensitiveCompare(target.name) == .orderedSame
    }
    guard let choice, choice.permissions.permitsPublication else {
      var unavailable = connection
      unavailable.installationID =
        choice?.installationID
        ?? installations.first {
          $0.accountLogin.caseInsensitiveCompare(target.owner) == .orderedSame
        }?.id
      unavailable.status = .needsInstallation
      unavailable.errorCode = "installation_or_permissions_required"
      _ = try await store.saveRemoteRepositoryConnection(
        unavailable,
        expectedVersion: unavailable.version
      )
      return
    }
    let workspace = try await workspaceProvider(productID)
    let origin = try await git.run(["remote", "get-url", "origin"], at: workspace)
    guard origin == source.originURL.absoluteString else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "The imported Product’s preserved Git origin changed. Spedito did not replace it."
      )
    }
    if let priorID = connection.repositoryID, priorID != choice.repository.id {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "The GitHub repository identity changed. Reconnect to the original repository."
      )
    }
    var updated = connection
    updated.installationID = choice.installationID
    updated.repositoryID = choice.repository.id
    updated.owner = choice.repository.owner
    updated.name = choice.repository.name
    updated.fullName = choice.repository.fullName
    updated.canonicalHTTPSURL = choice.repository.canonicalHTTPSURL
    updated.isPrivate = choice.repository.isPrivate
    updated.permissions = choice.permissions
    updated.errorCode = nil
    if choice.repository.defaultBranch == source.sourceDefaultBranch {
      updated.defaultBranch = choice.repository.defaultBranch
      updated.status = .connected
    } else {
      updated.defaultBranch = source.sourceDefaultBranch
      updated.status = .needsTargetReview
      updated.pendingRepositoryID = choice.repository.id
      updated.pendingFullName = choice.repository.fullName
      updated.pendingCanonicalHTTPSURL = choice.repository.canonicalHTTPSURL
      updated.pendingDefaultBranch = choice.repository.defaultBranch
      updated.pendingObservedAt = Date()
    }
    _ = try await store.saveRemoteRepositoryConnection(
      updated,
      expectedVersion: updated.version
    )
  }

  func recoverLocalRemoteInitialization(
    connection initial: RemoteRepositoryConnection,
    store: SQLiteStore
  ) async throws {
    guard initial.kind == .localEmptyRepository,
      initial.status == .initializingRemote,
      let canonicalURL = initial.canonicalHTTPSURL,
      let defaultBranch = initial.defaultBranch,
      let bootstrapSHA = initial.bootstrapRootSHA
    else { throw GitHubRemoteRepositoryServiceError.stale }
    let workspace = try await workspaceProvider(initial.productID)
    var connection = initial
    let heads = try await withCredential(connection: connection) { credential in
      try await self.git.remoteHeadSHAs(
        repositoryURL: workspace,
        canonicalHTTPSURL: canonicalURL,
        credentialConfiguration: credential
      )
    }
    let targetRef = "refs/heads/\(defaultBranch)"
    if heads.isEmpty {
      try await withCredential(connection: connection) { credential in
        try await self.git.initializeEmptyRemote(
          repositoryURL: workspace,
          canonicalHTTPSURL: canonicalURL,
          defaultBranch: defaultBranch,
          bootstrapSHA: bootstrapSHA,
          credentialConfiguration: credential
        )
      }
    } else if heads[targetRef] != bootstrapSHA || heads.count != 1 {
      throw GitRemoteOperationError.remoteMoved
    }
    if connection.seededSHA == nil {
      connection = try await store.recordLocalRemoteSeed(
        id: connection.id,
        expectedVersion: connection.version,
        expectedAttempt: connection.initializationAttemptCount,
        seededSHA: bootstrapSHA
      )
    }
    try await git.verifyOrAddOrigin(repositoryURL: workspace, canonicalHTTPSURL: canonicalURL)
    _ = try await store.finishLocalRemoteInitialization(
      id: connection.id,
      expectedVersion: connection.version,
      originVerified: true
    )
    let currentSHA = try await git.currentSHA(at: workspace)
    if currentSHA != bootstrapSHA {
      _ = try await prepareExistingProductHistoryPublication(productID: connection.productID)
    }
  }

  private func existingProductHistorySummary(
    productID: UUID,
    store: SQLiteStore,
    workspace: URL,
    bootstrap: GitBootstrapRoot
  ) async throws -> GitHubExistingProductHistorySummary? {
    guard try await store.fetchProductRepository(productID: productID) == nil else { return nil }
    let localSHA = try await git.currentSHA(at: workspace)
    guard localSHA != bootstrap.sha else { return nil }
    return GitHubExistingProductHistorySummary(localSHA: localSHA)
  }

  private func prepareExistingProductHistoryPublication(
    productID: UUID,
    checkedState: GitHubRemoteRepositoryState? = nil,
    onProgress: (
      @Sendable (GitHubRemoteRepositoryInitializationProgress) async -> Void
    )? = nil
  ) async throws -> GitHubRemoteRepositoryState {
    try await preparePublication(
      productID: productID,
      workItemID: nil,
      candidateRevisionID: nil,
      purpose: .existingProductHistory,
      publishesImmediately: true,
      checkedState: checkedState,
      initializationProgress: onProgress
    )
  }
}
