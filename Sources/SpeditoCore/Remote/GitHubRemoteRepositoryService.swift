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

public struct RemoteProductArchivePolicy: Sendable {
  public init() {}

  public func blockingReason(for state: GitHubRemoteRepositoryState) -> String? {
    if state.connection?.status == .initializingRemote {
      return
        "Repository setup is currently publishing or verifying changes. Wait for it to finish before archiving this Product."
    }
    if state.safeSync?.status == .accepting {
      return
        "Incoming repository changes are currently being accepted. Wait for that operation to finish before archiving this Product."
    }
    if state.publications.contains(where: {
      switch $0.status {
      case .checking, .pushing, .branchPublished, .creatingPullRequest:
        true
      case .awaitingConfirmation, .open, .openOutdated, .openStale, .merged,
        .closed, .cancelled, .stale, .failed:
        false
      }
    }) {
      return
        "A reviewed repository change is currently being published. Wait for that operation to finish before archiving this Product."
    }
    return nil
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

public protocol GitHubRepositoryStateServing: Sendable {
  func state(productID: UUID) async -> GitHubRemoteRepositoryState
}

public protocol GitHubRepositoryConnectionServing:
  GitHubRepositoryStateServing
{
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
}

public protocol GitHubRepositoryObservationServing:
  GitHubRepositoryStateServing
{
  func check(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation
}

public protocol GitHubRepositorySafeSyncServing:
  GitHubRepositoryStateServing
{
  func prepareSafeSync(productID: UUID) async throws -> GitHubRemoteRepositoryState
  func acceptSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState
  func rejectSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState
}

public protocol GitHubRepositoryPublicationServing:
  GitHubRepositoryStateServing
{
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
}

public protocol GitHubRepositoryLifecycleServing: Sendable {
  func recover(productID: UUID) async
  func shutdown() async
}

public protocol GitHubRemoteRepositoryServing:
  RepositoryImportSourceResolving,
  GitHubRepositoryConnectionServing,
  GitHubRepositoryObservationServing,
  GitHubRepositorySafeSyncServing,
  GitHubRepositoryPublicationServing,
  GitHubRepositoryLifecycleServing
{}

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
      let preservesTarget =
        existing.status == .needsAuthorization && existing.repositoryID != nil
      existing.accountID = accountID
      if !preservesTarget {
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
      }
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

  struct CheckedObservation: Sendable {
    let value: RemoteRepositoryObservation
    let candidateSHA: String?
    let candidateTree: String?
    let provingPublicationID: UUID?
    let publishedSHA: String?
  }

  let configuration: GitHubConfiguration
  let api: GitHubAPIClient
  let credentialSession: GitCredentialSession
  let git: GitWorkspaceManager
  let textValidator: RemotePublicationTextValidator
  let storeProvider: StoreProvider
  let storesProvider: StoresProvider
  let workspaceProvider: WorkspaceProvider
  let accountCatalog: GitHubAccountCatalog

  var transientRepositoryChoices: [UUID: [GitHubRepositoryChoice]] = [:]
  var transientSelectedEligibility: [UUID: GitHubRepositoryEligibility] = [:]
  var transientCheckedObservations: [UUID: CheckedObservation] = [:]
  var transientPresentationErrors: [UUID: String] = [:]
  var isShuttingDown = false

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

}
