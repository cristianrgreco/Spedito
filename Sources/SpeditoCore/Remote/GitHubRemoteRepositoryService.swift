import Foundation

public struct GitHubConfiguration: Equatable, Sendable {
  public let clientID: String
  public let appSlug: String

  public init(clientID: String, appSlug: String) {
    self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.appSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isConfigured: Bool { !clientID.isEmpty && !appSlug.isEmpty }

  public static func current(bundle: Bundle = .main) -> GitHubConfiguration {
    GitHubConfiguration(
      clientID: bundle.object(forInfoDictionaryKey: "SpeditoGitHubClientID") as? String ?? "",
      appSlug: bundle.object(forInfoDictionaryKey: "SpeditoGitHubAppSlug") as? String ?? ""
    )
  }
}

public struct GitHubExistingProductHistorySummary: Equatable, Sendable {
  public let localSHA: String

  public init(localSHA: String) {
    self.localSHA = localSHA
  }
}

public enum GitHubRemoteRepositoryInitializationProgress: Int, CaseIterable, Equatable, Sendable {
  case validatingProduct
  case publishingBootstrap
  case verifyingConnection
  case checkingRepository
  case publishingExistingHistory
  case mergingExistingHistory
}

public enum GitHubRepositoryEligibility: Equatable, Sendable {
  case unchecked
  case checking
  case empty(
    bootstrap: GitBootstrapRoot,
    existingHistory: GitHubExistingProductHistorySummary?
  )
  case ineligible(String)
}

public struct GitHubRepositoryChoice: Identifiable, Equatable, Sendable {
  public var id: Int64 { repository.id }
  public let installationID: Int64
  public let repository: GitHubRepository
  public let permissions: RemoteRepositoryPermissions
  public let eligibility: GitHubRepositoryEligibility

  public init(
    installationID: Int64,
    repository: GitHubRepository,
    permissions: RemoteRepositoryPermissions,
    eligibility: GitHubRepositoryEligibility = .unchecked
  ) {
    self.installationID = installationID
    self.repository = repository
    self.permissions = permissions
    self.eligibility = eligibility
  }
}

public struct GitHubRepositoryImportCatalog: Equatable, Sendable {
  public let installations: [GitHubInstallation]
  public let choices: [GitHubRepositoryChoice]

  public init(
    installations: [GitHubInstallation] = [],
    choices: [GitHubRepositoryChoice] = []
  ) {
    self.installations = installations
    self.choices = choices
  }
}

public struct GitHubRemoteRepositoryState: Equatable, Sendable {
  public let isConfigured: Bool
  public let connection: RemoteRepositoryConnection?
  public let repositories: [GitHubRepositoryChoice]
  public let selectedEligibility: GitHubRepositoryEligibility?
  public let observation: RemoteRepositoryObservation?
  public let safeSync: RemoteSafeSync?
  public let publications: [RemotePublication]
  public let errorMessage: String?

  public init(
    isConfigured: Bool,
    connection: RemoteRepositoryConnection? = nil,
    repositories: [GitHubRepositoryChoice] = [],
    selectedEligibility: GitHubRepositoryEligibility? = nil,
    observation: RemoteRepositoryObservation? = nil,
    safeSync: RemoteSafeSync? = nil,
    publications: [RemotePublication] = [],
    errorMessage: String? = nil
  ) {
    self.isConfigured = isConfigured
    self.connection = connection
    self.repositories = repositories
    self.selectedEligibility = selectedEligibility
    self.observation = observation
    self.safeSync = safeSync
    self.publications = publications
    self.errorMessage = errorMessage
  }

  public var publication: RemotePublication? {
    publications.max { $0.updatedAt < $1.updatedAt }
  }
}

public struct GitHubTicketIntegrationBase: Equatable, Sendable {
  public let observationRef: String
  public let remoteSHA: String

  public init(observationRef: String, remoteSHA: String) {
    self.observationRef = observationRef
    self.remoteSHA = remoteSHA
  }
}

public struct GitHubTicketIntegrationPreparation: Equatable, Sendable {
  public let state: GitHubRemoteRepositoryState
  public let base: GitHubTicketIntegrationBase?

  public init(
    state: GitHubRemoteRepositoryState,
    base: GitHubTicketIntegrationBase?
  ) {
    self.state = state
    self.base = base
  }
}

public enum GitHubRemoteRepositoryServiceError: Error, Equatable, LocalizedError, Sendable {
  case notConfigured
  case unavailable(String)
  case stale
  case notEligible(String)
  case ticketIntegrationRequired

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      "This Spedito build is not configured for GitHub."
    case .unavailable(let message), .notEligible(let message):
      message
    case .stale:
      "GitHub changed while Spedito was checking it. Check GitHub again."
    case .ticketIntegrationRequired:
      "GitHub changed while this ticket was in review. Spedito will integrate the latest changes and review the ticket again."
    }
  }
}

public struct GitHubTicketPullRequestSync: Equatable, Sendable {
  public let state: GitHubRemoteRepositoryState
  public let workItemID: UUID
  public let changesRequested: Bool
  public let closedWithoutMerge: Bool

  public init(
    state: GitHubRemoteRepositoryState,
    workItemID: UUID,
    changesRequested: Bool,
    closedWithoutMerge: Bool
  ) {
    self.state = state
    self.workItemID = workItemID
    self.changesRequested = changesRequested
    self.closedWithoutMerge = closedWithoutMerge
  }
}

public struct GitHubTicketPullRequestMergeResult: Equatable, Sendable {
  public let state: GitHubRemoteRepositoryState
  public let publication: RemotePublication
  public let mergedSHA: String

  public init(
    state: GitHubRemoteRepositoryState,
    publication: RemotePublication,
    mergedSHA: String
  ) {
    self.state = state
    self.publication = publication
    self.mergedSHA = mergedSHA
  }
}

public protocol GitHubRemoteRepositoryServing: Sendable {
  func state(productID: UUID) async -> GitHubRemoteRepositoryState
  func importRepositories() async throws -> GitHubRepositoryImportCatalog
  func authorizeImport(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRepositoryImportCatalog
  func importProduct(
    name: String,
    repositoryID: Int64,
    importer:
      @escaping @Sendable (
        PublicGitRepositoryURL,
        GitCredentialSessionConfiguration
      ) async throws -> ImportedProduct
  ) async throws -> ImportedProduct
  func connectLocalProduct(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState
  func connect(
    productID: UUID,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRemoteRepositoryState
  func cancelConnection(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func disconnect(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func signOut(accountID: UUID) async throws
  func selectLocalRepository(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState
  func refreshRepositories(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func initializeLocalRepository(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func initializeLocalRepository(
    productID: UUID,
    onProgress:
      @escaping @Sendable (
        GitHubRemoteRepositoryInitializationProgress
      ) async -> Void
  ) async throws -> GitHubRemoteRepositoryState
  func confirmTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) async throws -> GitHubRemoteRepositoryState
  func check(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation
  func prepareSafeSync(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func acceptSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState
  func rejectSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState
  func preparePublication(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func cancelPublication(id: UUID) async throws -> GitHubRemoteRepositoryState
  func confirmPublication(
    id: UUID,
    title: String,
    body: String
  ) async throws -> GitHubRemoteRepositoryState
  func finishPullRequest(
    id: UUID,
    title: String,
    body: String
  ) async throws -> GitHubRemoteRepositoryState
  func prepareTicketPullRequest(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> GitHubRemoteRepositoryState
  func markTicketPullRequestReady(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState
  func returnTicketPullRequestToDraft(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState
  func syncTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync
  func mergeTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult
  func refreshPullRequest(publicationID: UUID) async throws -> GitHubRemoteRepositoryState
  func recover(productID: UUID) async
  func shutdown() async
}

extension GitHubRemoteRepositoryServing {
  public func initializeLocalRepository(
    productID: UUID,
    onProgress:
      @escaping @Sendable (
        GitHubRemoteRepositoryInitializationProgress
      ) async -> Void
  ) async throws -> GitHubRemoteRepositoryState {
    await onProgress(.validatingProduct)
    return try await initializeLocalRepository(productID: productID)
  }

  public func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation {
    GitHubTicketIntegrationPreparation(
      state: try await check(productID: productID),
      base: nil
    )
  }

  public func prepareTicketPullRequest(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable."
    )
  }

  public func markTicketPullRequestReady(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable."
    )
  }

  public func returnTicketPullRequestToDraft(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable."
    )
  }

  public func syncTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable."
    )
  }

  public func mergeTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult {
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable."
    )
  }
}

public final class GitHubProductStoreConnectionCoordinator:
  GitHubAccountConnectionCoordinating, @unchecked Sendable
{
  public typealias StoreProvider = @Sendable (UUID) async -> SQLiteStore?
  public typealias StoresProvider = @Sendable () async -> [SQLiteStore]

  private let storeProvider: StoreProvider
  private let storesProvider: StoresProvider

  public init(
    storeProvider: @escaping StoreProvider,
    storesProvider: @escaping StoresProvider
  ) {
    self.storeProvider = storeProvider
    self.storesProvider = storesProvider
  }

  public func linkProduct(
    productID: UUID,
    accountID: UUID,
    githubUserID: Int64,
    login: String
  ) async throws {
    guard let store = await storeProvider(productID) else {
      throw GitHubRemoteRepositoryServiceError.unavailable("The Product database is unavailable.")
    }
    if var existing = try await store.fetchRemoteRepositoryConnection(productID: productID) {
      guard
        existing.status == .disconnected || existing.status == .needsAuthorization
          || existing.accountID == accountID
      else {
        throw GitHubRemoteRepositoryServiceError.unavailable(
          "Disconnect the current GitHub account before connecting another one."
        )
      }
      existing.accountID = accountID
      existing.installationID = nil
      existing.repositoryID = nil
      existing.owner = nil
      existing.name = nil
      existing.fullName = nil
      existing.canonicalHTTPSURL = nil
      existing.isPrivate = nil
      existing.defaultBranch = nil
      existing.permissions = RemoteRepositoryPermissions(
        metadataRead: false,
        contentsWrite: false,
        pullRequestsWrite: false,
        workflowsWrite: false
      )
      existing.status = .needsInstallation
      existing.errorCode = nil
      _ = try await store.saveRemoteRepositoryConnection(
        existing,
        expectedVersion: existing.version
      )
      return
    }
    let repository = try await store.fetchProductRepository(productID: productID)
    _ = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: productID,
        kind: repository == nil ? .localEmptyRepository : .importedSource,
        accountID: accountID,
        status: .needsInstallation
      )
    )
    _ = githubUserID
    _ = login
  }

  public func disconnectProduct(productID: UUID, accountID: UUID) async throws {
    guard let store = await storeProvider(productID),
      let connection = try await store.fetchRemoteRepositoryConnection(productID: productID),
      connection.accountID == accountID
    else { return }
    _ = try await store.disconnectRemoteRepositoryConnection(
      id: connection.id,
      expectedVersion: connection.version
    )
  }

  public func disableConnections(accountID: UUID) async throws {
    for store in await storesProvider() {
      for var connection in try await store.fetchRemoteRepositoryConnections(accountID: accountID) {
        connection.accountID = nil
        connection.status = .needsAuthorization
        connection.errorCode = "authorization_required"
        connection.pendingRepositoryID = nil
        connection.pendingFullName = nil
        connection.pendingCanonicalHTTPSURL = nil
        connection.pendingDefaultBranch = nil
        connection.pendingObservedAt = nil
        _ = try await store.saveRemoteRepositoryConnection(
          connection,
          expectedVersion: connection.version
        )
      }
    }
  }

  public func durableProductIDs(accountID: UUID) async throws -> Set<UUID> {
    var productIDs = Set<UUID>()
    for store in await storesProvider() {
      for connection in try await store.fetchRemoteRepositoryConnections(accountID: accountID)
      where connection.status != .disconnected {
        productIDs.insert(connection.productID)
      }
    }
    return productIDs
  }

  public func referencedAccountIDs() async throws -> Set<UUID> {
    var result = Set<UUID>()
    for store in await storesProvider() {
      for connection in try await store.fetchAllRemoteRepositoryConnections() {
        if let accountID = connection.accountID, connection.status != .disconnected {
          result.insert(accountID)
        }
      }
    }
    return result
  }

  public func markConnectionsNeedAuthorization(accountIDs: Set<UUID>) async throws {
    for store in await storesProvider() {
      for accountID in accountIDs {
        try await store.markRemoteRepositoryConnectionsNeedAuthorization(accountID: accountID)
      }
    }
  }
}

public actor GitHubRemoteRepositoryService: GitHubRemoteRepositoryServing {
  public typealias StoreProvider = @Sendable (UUID) async -> SQLiteStore?
  public typealias StoresProvider = @Sendable () async -> [SQLiteStore]
  public typealias WorkspaceProvider = @Sendable (UUID) async throws -> URL

  private struct CheckedObservation: Sendable {
    let value: RemoteRepositoryObservation
    let candidateSHA: String?
    let candidateTree: String?
    let provingPublicationID: UUID?
    let publishedSHA: String?
  }


  private let configuration: GitHubConfiguration
  private let api: GitHubAPIClient
  private let credentialSession: GitCredentialSession
  private let git: GitWorkspaceManager
  private let textValidator: RemotePublicationTextValidator
  private let storeProvider: StoreProvider
  private let storesProvider: StoresProvider
  private let workspaceProvider: WorkspaceProvider
  private let accountCatalog: GitHubAccountCatalog

  private var repositoryChoices: [UUID: [GitHubRepositoryChoice]] = [:]
  private var selectedEligibility: [UUID: GitHubRepositoryEligibility] = [:]
  private var checkedObservations: [UUID: CheckedObservation] = [:]
  private var errors: [UUID: String] = [:]
  private var isShuttingDown = false

  public init(
    configuration: GitHubConfiguration,
    api: GitHubAPIClient = GitHubAPIClient(),
    credentialStore: any GitHubCredentialStoring = GitHubCredentialStore(),
    credentialSession: GitCredentialSession = GitCredentialSession(),
    git: GitWorkspaceManager,
    storeProvider: @escaping StoreProvider,
    storesProvider: @escaping StoresProvider,
    workspaceProvider: @escaping WorkspaceProvider
  ) {
    self.configuration = configuration
    self.api = api
    self.credentialSession = credentialSession
    self.git = git
    self.storeProvider = storeProvider
    self.storesProvider = storesProvider
    self.workspaceProvider = workspaceProvider
    textValidator = RemotePublicationTextValidator()
    let coordinator = GitHubProductStoreConnectionCoordinator(
      storeProvider: storeProvider,
      storesProvider: storesProvider
    )
    accountCatalog = GitHubAccountCatalog(
      clientID: configuration.clientID,
      credentialStore: credentialStore,
      oauth: api,
      connections: coordinator
    )
  }

  public func state(productID: UUID) async -> GitHubRemoteRepositoryState {
    await makeState(productID: productID)
  }

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
        errors[imported.product.id] =
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
    errors[productID] = nil
    if try await accountCatalog.linkProductToOnlyAuthorizedAccount(productID: productID) {
      return try await refreshRepositories(productID: productID)
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
    repositoryChoices.removeValue(forKey: productID)
    selectedEligibility.removeValue(forKey: productID)
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
    checkedObservations.removeValue(forKey: productID)
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
    repositoryChoices[productID] = choices
    if connection.kind == .localEmptyRepository {
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
      let choice = repositoryChoices[productID]?.first(where: { $0.id == repositoryID })
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
    selectedEligibility[productID] = .checking
    do {
      let hasBranches = try await accountCatalog.withAccessToken(accountID: accountID) { token in
        try await self.api.repositoryHasBranches(
          owner: choice.repository.owner,
          name: choice.repository.name,
          accessToken: token
        )
      }
      guard !hasBranches else {
        selectedEligibility[productID] = .ineligible(
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
      selectedEligibility[productID] = .empty(
        bootstrap: bootstrap,
        existingHistory: history
      )
    } catch {
      selectedEligibility[productID] = .ineligible(error.localizedDescription)
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
      case .empty(let bootstrap, let existingHistory) = selectedEligibility[productID],
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
    selectedEligibility.removeValue(forKey: productID)
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

  public func check(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    try await check(productID: productID, retainsObservationRef: false)
  }

  public func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation {
    let state = try await check(productID: productID, retainsObservationRef: true)
    guard let checked = checkedObservations[productID] else {
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
    let previousObservationRef = checkedObservations[productID]?.value.observationRef
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
    checkedObservations[productID] = CheckedObservation(
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
      let checked = checkedObservations[productID],
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
    guard let store = await storeContainingSafeSync(syncID),
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
    checkedObservations.removeValue(forKey: sync.productID)
    _ = accepting
    return await makeState(productID: sync.productID)
  }

  public func rejectSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeContainingSafeSync(syncID),
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
    checkedObservations.removeValue(forKey: sync.productID)
    return await makeState(productID: sync.productID)
  }

  public func preparePublication(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    try await preparePublication(
      productID: productID,
      workItemID: nil,
      candidateRevisionID: nil,
      purpose: .legacyManual,
      publishesImmediately: false
    )
  }

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

  private func preparePublication(
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
      guard
        let workItem = try await store.fetchWorkItems(productID: productID)
          .first(where: { $0.id == workItemID }),
        let candidate = try? await store.fetchCandidateRevision(id: candidateRevisionID),
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

  public func cancelPublication(id: UUID) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeContainingPublication(id),
      let publication = try await store.fetchRemotePublication(id: id)
    else { throw GitHubRemoteRepositoryServiceError.stale }
    _ = try await store.cancelRemotePublication(
      id: id,
      expectedVersion: publication.version,
      expectedStatus: publication.status
    )
    return await makeState(productID: publication.productID)
  }

  public func confirmPublication(
    id: UUID,
    title: String,
    body: String
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeContainingPublication(id),
      var publication = try await store.fetchRemotePublication(id: id)
    else { throw GitHubRemoteRepositoryServiceError.stale }
    try await validateText(publication: publication, title: title, body: body)
    publication = try await store.prepareRemotePublicationCheck(
      id: id,
      expectedVersion: publication.version,
      expectedStatus: publication.status,
      title: title,
      body: body,
      textRevision: publication.textRevision + 1
    )
    try await executePublication(publication: publication, store: store, includesPush: true)
    return await makeState(productID: publication.productID)
  }

  public func finishPullRequest(
    id: UUID,
    title: String,
    body: String
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeContainingPublication(id),
      var publication = try await store.fetchRemotePublication(id: id),
      publication.status == .branchPublished
    else { throw GitHubRemoteRepositoryServiceError.stale }
    try await validateText(publication: publication, title: title, body: body)
    publication = try await store.prepareRemotePublicationCheck(
      id: id,
      expectedVersion: publication.version,
      expectedStatus: .branchPublished,
      title: title,
      body: body,
      textRevision: publication.textRevision + 1
    )
    try await executePublication(publication: publication, store: store, includesPush: false)
    return await makeState(productID: publication.productID)
  }

  public func refreshPullRequest(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    guard let store = await storeContainingPublication(publicationID),
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
    guard let store = await storeContainingPublication(publicationID),
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
    guard let store = await storeContainingPublication(publicationID),
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
    guard let store = await storeContainingPublication(publicationID),
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
    guard let store = await storeContainingPublication(publicationID),
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
      where mergePublication.purpose == .ticket {
        throw GitHubRemoteRepositoryServiceError.ticketIntegrationRequired
      } catch GitHubAPIError.unprocessable(_)
      where mergePublication.purpose == .ticket {
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

  public func recover(productID: UUID) async {
    guard configuration.isConfigured, let store = await storeProvider(productID) else { return }
    errors[productID] = nil
    do {
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
      errors[productID] = error.localizedDescription
    }
  }

  public func shutdown() async {
    isShuttingDown = true
    await credentialSession.shutdown()
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

  private func executePublication(
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
      let heads = try await withCredential(publication: pushingPublication) { credential in
        try await self.git.remoteHeadSHAs(
          repositoryURL: workspace,
          canonicalHTTPSURL: pushingPublication.canonicalHTTPSURL,
          credentialConfiguration: credential
        )
      }
      let fullRef = "refs/heads/\(publication.publicationBranch)"
      guard heads[fullRef] == publication.capturedLocalSHA else {
        if heads[fullRef] != nil {
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
    let heads = try await withCredential(publication: publication) { credential in
      try await self.git.remoteHeadSHAs(
        repositoryURL: workspace,
        canonicalHTTPSURL: publication.canonicalHTTPSURL,
        credentialConfiguration: credential
      )
    }
    let publicationRef = "refs/heads/\(publication.publicationBranch)"
    guard heads[publicationRef] == publication.capturedLocalSHA else {
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

  private func completeExistingProductHistoryPublicationIfReady(
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

  private func recoverLocalRemoteInitialization(
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

  private func withCredential<T: Sendable>(
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

  private func makeState(productID: UUID) async -> GitHubRemoteRepositoryState {
    guard let store = await storeProvider(productID) else {
      return GitHubRemoteRepositoryState(
        isConfigured: configuration.isConfigured,
        errorMessage: errors[productID]
      )
    }
    return GitHubRemoteRepositoryState(
      isConfigured: configuration.isConfigured,
      connection: try? await store.fetchRemoteRepositoryConnection(productID: productID),
      repositories: repositoryChoices[productID] ?? [],
      selectedEligibility: selectedEligibility[productID],
      observation: checkedObservations[productID]?.value,
      safeSync: try? await store.fetchLatestRemoteSafeSync(productID: productID),
      publications: (try? await store.fetchRemotePublications(productID: productID)) ?? [],
      errorMessage: errors[productID]
    )
  }

  private func storeContainingSafeSync(_ id: UUID) async -> SQLiteStore? {
    for store in await allKnownStores() {
      if (try? await store.fetchRemoteSafeSync(id: id)) != nil { return store }
    }
    return nil
  }

  private func storeContainingPublication(_ id: UUID) async -> SQLiteStore? {
    for store in await allKnownStores() {
      if (try? await store.fetchRemotePublication(id: id)) != nil { return store }
    }
    return nil
  }

  private func allKnownStores() async -> [SQLiteStore] {
    await storesProvider()
  }

  private func requireAvailable() throws {
    guard configuration.isConfigured else {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }
    guard !isShuttingDown else {
      throw GitHubRemoteRepositoryServiceError.unavailable("Spedito is shutting down.")
    }
  }

  private static func permissions(
    from value: GitHubInstallationPermissions
  ) -> RemoteRepositoryPermissions {
    RemoteRepositoryPermissions(
      metadataRead: value.metadata == "read" || value.metadata == "write",
      contentsWrite: value.contents == "write",
      pullRequestsWrite: value.pullRequests == "write",
      workflowsWrite: value.workflows == "write"
    )
  }

  private static func snapshot(
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

  private static func githubTarget(from url: URL) -> (owner: String, name: String)? {
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
