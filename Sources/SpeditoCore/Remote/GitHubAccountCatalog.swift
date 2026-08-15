import Foundation

public struct GitHubDeviceAuthorizationPrompt: Equatable, Sendable {
  public let userCode: String
  public let verificationURL: URL
  public let expiresAt: Date

  public init(userCode: String, verificationURL: URL, expiresAt: Date) {
    self.userCode = userCode
    self.verificationURL = verificationURL
    self.expiresAt = expiresAt
  }
}

public struct GitHubAuthorizedAccount: Equatable, Sendable {
  public let githubUserID: Int64
  public let login: String
  public let accessToken: String
  public let accessTokenExpiresAt: Date
  public let refreshToken: String
  public let refreshTokenExpiresAt: Date

  public init(
    githubUserID: Int64,
    login: String,
    accessToken: String,
    accessTokenExpiresAt: Date,
    refreshToken: String,
    refreshTokenExpiresAt: Date
  ) {
    self.githubUserID = githubUserID
    self.login = login
    self.accessToken = accessToken
    self.accessTokenExpiresAt = accessTokenExpiresAt
    self.refreshToken = refreshToken
    self.refreshTokenExpiresAt = refreshTokenExpiresAt
  }
}

public struct GitHubRefreshedToken: Equatable, Sendable {
  public let accessToken: String
  public let accessTokenExpiresAt: Date
  public let refreshToken: String
  public let refreshTokenExpiresAt: Date

  public init(
    accessToken: String,
    accessTokenExpiresAt: Date,
    refreshToken: String,
    refreshTokenExpiresAt: Date
  ) {
    self.accessToken = accessToken
    self.accessTokenExpiresAt = accessTokenExpiresAt
    self.refreshToken = refreshToken
    self.refreshTokenExpiresAt = refreshTokenExpiresAt
  }
}

public protocol GitHubOAuthAuthorizing: Sendable {
  func authorize(
    clientID: String,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubAuthorizedAccount

  func refresh(clientID: String, refreshToken: String) async throws -> GitHubRefreshedToken
}

public protocol GitHubAccountConnectionCoordinating: Sendable {
  func linkProduct(
    productID: UUID,
    accountID: UUID,
    githubUserID: Int64,
    login: String
  ) async throws
  func disconnectProduct(productID: UUID, accountID: UUID) async throws
  func disableConnections(accountID: UUID) async throws
  func durableProductIDs(accountID: UUID) async throws -> Set<UUID>
  func referencedAccountIDs() async throws -> Set<UUID>
  func markConnectionsNeedAuthorization(accountIDs: Set<UUID>) async throws
}

public actor GitHubAccountCatalog {
  private let clientID: String
  private let credentialStore: any GitHubCredentialStoring
  private let oauth: any GitHubOAuthAuthorizing
  private let connections: any GitHubAccountConnectionCoordinating
  private let now: @Sendable () -> Date

  private var activeLeases: [UUID: Int] = [:]
  private var rotatingAccounts: Set<UUID> = []
  private var stateWaiters: [UUID: [UUID: CheckedContinuation<Void, any Error>]] = [:]
  private var cachedTokenSets: [UUID: GitHubAccountTokenSet] = [:]
  private var loadedAllTokenSets = false

  public init(
    clientID: String,
    credentialStore: any GitHubCredentialStoring,
    oauth: any GitHubOAuthAuthorizing,
    connections: any GitHubAccountConnectionCoordinating,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.clientID = clientID
    self.credentialStore = credentialStore
    self.oauth = oauth
    self.connections = connections
    self.now = now
  }

  @discardableResult
  public func authorize(
    productID: UUID,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubAccountTokenSet {
    try await authorizeAccount(productID: productID, onPrompt: onPrompt)
  }

  public func authorize(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubAccountTokenSet {
    try await authorizeAccount(productID: nil, onPrompt: onPrompt)
  }

  private func authorizeAccount(
    productID: UUID?,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubAccountTokenSet {
    let authorized = try await oauth.authorize(clientID: clientID, onPrompt: onPrompt)
    let existing = try await allTokenSets().first {
      $0.githubUserID == authorized.githubUserID
    }
    let accountID = existing?.accountID ?? UUID()
    try await beginRotation(accountID: accountID)
    defer { endRotation(accountID: accountID) }

    let tokenSet = GitHubAccountTokenSet(
      accountID: accountID,
      githubUserID: authorized.githubUserID,
      login: authorized.login,
      accessToken: authorized.accessToken,
      accessTokenExpiresAt: authorized.accessTokenExpiresAt,
      refreshToken: authorized.refreshToken,
      refreshTokenExpiresAt: authorized.refreshTokenExpiresAt
    )
    try await saveTokenSet(tokenSet)
    if let productID {
      try await connections.linkProduct(
        productID: productID,
        accountID: accountID,
        githubUserID: tokenSet.githubUserID,
        login: tokenSet.login
      )
    }
    return tokenSet
  }

  public func linkProduct(productID: UUID, accountID: UUID) async throws {
    guard let tokenSet = try await tokenSet(accountID: accountID) else {
      throw GitHubAPIError.unauthorized
    }
    try await connections.linkProduct(
      productID: productID,
      accountID: accountID,
      githubUserID: tokenSet.githubUserID,
      login: tokenSet.login
    )
  }

  public func authorizedAccountIDs() async throws -> [UUID] {
    try await allTokenSets()
      .map(\.accountID)
      .sorted { $0.uuidString < $1.uuidString }
  }

  public func linkProductToOnlyAuthorizedAccount(productID: UUID) async throws -> Bool {
    let tokenSets = try await allTokenSets()
    guard tokenSets.count == 1, let accountID = tokenSets.first?.accountID else {
      return false
    }
    try await linkProduct(productID: productID, accountID: accountID)
    return true
  }

  public func withAccessToken<T: Sendable>(
    accountID: UUID,
    operation: @escaping @Sendable (String) async throws -> T
  ) async throws -> T {
    let token = try await acquireAccessToken(accountID: accountID)
    do {
      let result = try await operation(token)
      releaseLease(accountID: accountID)
      return result
    } catch {
      releaseLease(accountID: accountID)
      throw error
    }
  }

  public func disconnect(
    productID: UUID,
    accountID: UUID,
    deleteIfOrphaned: Bool = false
  ) async throws {
    guard deleteIfOrphaned else {
      try await connections.disconnectProduct(productID: productID, accountID: accountID)
      return
    }
    try await beginRotation(accountID: accountID)
    defer { endRotation(accountID: accountID) }
    try await connections.disconnectProduct(productID: productID, accountID: accountID)
    if try await connections.durableProductIDs(accountID: accountID).isEmpty {
      try await deleteTokenSet(accountID: accountID)
    }
  }

  public func signOut(accountID: UUID) async throws {
    try await beginRotation(accountID: accountID)
    defer { endRotation(accountID: accountID) }
    try await connections.disableConnections(accountID: accountID)
    guard try await connections.durableProductIDs(accountID: accountID).isEmpty else {
      return
    }
    try await deleteTokenSet(accountID: accountID)
  }

  public func reconcile() async throws {
    let tokenSets = try await allTokenSets()
    let references = try await connections.referencedAccountIDs()
    let availableIDs = Set(tokenSets.map(\.accountID))
    let missingIDs = references.subtracting(availableIDs)
    if !missingIDs.isEmpty {
      try await connections.markConnectionsNeedAuthorization(accountIDs: missingIDs)
    }
  }

  private func acquireAccessToken(accountID: UUID) async throws -> String {
    try await beginRotation(accountID: accountID)
    defer { endRotation(accountID: accountID) }
    guard var tokenSet = try await tokenSet(accountID: accountID) else {
      throw GitHubCredentialStoreError.invalidPayload
    }
    if tokenSet.accessTokenExpiresAt <= now().addingTimeInterval(300) {
      do {
        let refreshed = try await oauth.refresh(
          clientID: clientID,
          refreshToken: tokenSet.refreshToken
        )
        tokenSet = GitHubAccountTokenSet(
          accountID: tokenSet.accountID,
          githubUserID: tokenSet.githubUserID,
          login: tokenSet.login,
          accessToken: refreshed.accessToken,
          accessTokenExpiresAt: refreshed.accessTokenExpiresAt,
          refreshToken: refreshed.refreshToken,
          refreshTokenExpiresAt: refreshed.refreshTokenExpiresAt
        )
        try await saveTokenSet(tokenSet)
      } catch let refreshError {
        do {
          try await connections.markConnectionsNeedAuthorization(accountIDs: [accountID])
        } catch {
          throw error
        }
        throw refreshError
      }
    }
    activeLeases[accountID, default: 0] += 1
    return tokenSet.accessToken
  }

  private func tokenSet(accountID: UUID) async throws -> GitHubAccountTokenSet? {
    if let cached = cachedTokenSets[accountID] {
      return cached
    }
    guard let stored = try await credentialStore.tokenSet(accountID: accountID) else {
      return nil
    }
    cachedTokenSets[accountID] = stored
    return stored
  }

  private func allTokenSets() async throws -> [GitHubAccountTokenSet] {
    if loadedAllTokenSets {
      return Array(cachedTokenSets.values)
    }
    let stored = try await credentialStore.allTokenSets()
    cachedTokenSets = Dictionary(uniqueKeysWithValues: stored.map { ($0.accountID, $0) })
    loadedAllTokenSets = true
    return stored
  }

  private func saveTokenSet(_ tokenSet: GitHubAccountTokenSet) async throws {
    if cachedTokenSets[tokenSet.accountID] == tokenSet {
      return
    }
    try await credentialStore.save(tokenSet)
    cachedTokenSets[tokenSet.accountID] = tokenSet
  }

  private func deleteTokenSet(accountID: UUID) async throws {
    try await credentialStore.delete(accountID: accountID)
    cachedTokenSets.removeValue(forKey: accountID)
  }

  private func releaseLease(accountID: UUID) {
    let remaining = max(0, activeLeases[accountID, default: 0] - 1)
    if remaining == 0 {
      activeLeases.removeValue(forKey: accountID)
      resumeWaiters(accountID: accountID)
    } else {
      activeLeases[accountID] = remaining
    }
  }

  private func beginRotation(accountID: UUID) async throws {
    try await waitWhileRotating(accountID: accountID)
    try Task.checkCancellation()
    rotatingAccounts.insert(accountID)
    do {
      while activeLeases[accountID, default: 0] > 0 {
        try await waitForStateChange(accountID: accountID)
      }
      try Task.checkCancellation()
    } catch {
      endRotation(accountID: accountID)
      throw error
    }
  }

  private func endRotation(accountID: UUID) {
    rotatingAccounts.remove(accountID)
    resumeWaiters(accountID: accountID)
  }

  private func waitWhileRotating(accountID: UUID) async throws {
    while rotatingAccounts.contains(accountID) {
      try await waitForStateChange(accountID: accountID)
    }
  }

  private func waitForStateChange(accountID: UUID) async throws {
    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          stateWaiters[accountID, default: [:]][waiterID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(accountID: accountID, waiterID: waiterID) }
    }
  }

  private func cancelWaiter(accountID: UUID, waiterID: UUID) {
    guard let waiter = stateWaiters[accountID]?.removeValue(forKey: waiterID) else { return }
    if stateWaiters[accountID]?.isEmpty == true {
      stateWaiters.removeValue(forKey: accountID)
    }
    waiter.resume(throwing: CancellationError())
  }

  private func resumeWaiters(accountID: UUID) {
    guard let waiters = stateWaiters.removeValue(forKey: accountID) else { return }
    for waiter in waiters.values {
      waiter.resume()
    }
  }
}
