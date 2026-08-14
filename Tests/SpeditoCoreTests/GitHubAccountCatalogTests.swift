import Foundation
import Testing

@testable import SpeditoCore

@Suite("GitHub account catalog", .serialized)
struct GitHubAccountCatalogTests {
  @Test("Concurrent token leases share one refresh")
  func concurrentRefresh() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accountID = UUID()
    let productIDs = [UUID(), UUID()]
    let store = CatalogMemoryCredentialStore(
      tokenSet: tokenSet(
        accountID: accountID,
        accessToken: "expired-access",
        accessExpiresAt: now.addingTimeInterval(30)
      )
    )
    let oauth = CatalogOAuth(now: now)
    let connections = CatalogConnections(
      accountID: accountID,
      productIDs: Set(productIDs)
    )
    let catalog = GitHubAccountCatalog(
      clientID: "client-id",
      credentialStore: store,
      oauth: oauth,
      connections: connections,
      now: { now }
    )

    async let first = catalog.withAccessToken(accountID: accountID) { $0 }
    async let second = catalog.withAccessToken(accountID: accountID) { $0 }
    let values = try await [first, second]

    #expect(values == ["refreshed-access", "refreshed-access"])
    #expect(await oauth.refreshCount == 1)
    #expect(try await store.tokenSet(accountID: accountID)?.accessToken == "refreshed-access")
  }

  @Test("A Product reuses the only authorized GitHub account")
  func reusesOnlyAuthorizedAccount() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accountID = UUID()
    let productID = UUID()
    let store = CatalogMemoryCredentialStore(
      tokenSet: tokenSet(
        accountID: accountID,
        accessToken: "current-access",
        accessExpiresAt: now.addingTimeInterval(3_600)
      )
    )
    let oauth = CatalogOAuth(now: now)
    let connections = CatalogConnections(accountID: accountID, productIDs: [])
    let catalog = GitHubAccountCatalog(
      clientID: "client-id",
      credentialStore: store,
      oauth: oauth,
      connections: connections,
      now: { now }
    )

    #expect(try await catalog.linkProductToOnlyAuthorizedAccount(productID: productID))
    #expect(try await connections.durableProductIDs(accountID: accountID) == [productID])
    #expect(await oauth.authorizationCount == 0)
  }

  @Test("One credential load serves setup and later token operations")
  func cachesCredentialsForSession() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accountID = UUID()
    let productID = UUID()
    let store = CatalogMemoryCredentialStore(
      tokenSet: tokenSet(
        accountID: accountID,
        accessToken: "current-access",
        accessExpiresAt: now.addingTimeInterval(3_600)
      )
    )
    let connections = CatalogConnections(accountID: accountID, productIDs: [])
    let catalog = GitHubAccountCatalog(
      clientID: "client-id",
      credentialStore: store,
      oauth: CatalogOAuth(now: now),
      connections: connections,
      now: { now }
    )

    #expect(try await catalog.linkProductToOnlyAuthorizedAccount(productID: productID))
    #expect(
      try await catalog.withAccessToken(accountID: accountID) { $0 } == "current-access"
    )
    try await catalog.disconnect(productID: productID, accountID: accountID)

    #expect(await store.allTokenSetsCount == 1)
    #expect(await store.tokenSetCount == 0)
    #expect(await store.saveCount == 0)
  }

  @Test("Sign out waits for active token leases before deleting credentials")
  func signOutWaitsForLease() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accountID = UUID()
    let productID = UUID()
    let store = CatalogMemoryCredentialStore(
      tokenSet: tokenSet(
        accountID: accountID,
        accessToken: "current-access",
        accessExpiresAt: now.addingTimeInterval(3_600)
      )
    )
    let oauth = CatalogOAuth(now: now)
    let connections = CatalogConnections(accountID: accountID, productIDs: [productID])
    let catalog = GitHubAccountCatalog(
      clientID: "client-id",
      credentialStore: store,
      oauth: oauth,
      connections: connections,
      now: { now }
    )
    let leaseGate = CatalogLeaseGate()
    let lease = Task {
      try await catalog.withAccessToken(accountID: accountID) { token in
        await leaseGate.begin()
        await leaseGate.waitForRelease()
        return token
      }
    }
    for _ in 0..<100 where !(await leaseGate.didBegin) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let signOut = Task {
      try await catalog.signOut(accountID: accountID)
    }
    try await Task.sleep(for: .milliseconds(25))
    #expect(try await store.tokenSet(accountID: accountID) != nil)
    #expect(!(await connections.didDisable))

    await leaseGate.release()
    #expect(try await lease.value == "current-access")
    try await signOut.value
    #expect(try await store.tokenSet(accountID: accountID) == nil)
    #expect(await connections.didDisable)
  }

  @Test("Keychain account discovery lists saved credentials")
  func keychainAccountDiscovery() async throws {
    let accountID = UUID()
    let service = "io.spedito.tests.github.\(UUID().uuidString)"
    let store = GitHubCredentialStore(bundleIdentifier: service)
    let now = Date()
    let saved = GitHubAccountTokenSet(
      accountID: accountID,
      githubUserID: 42,
      login: "owner",
      accessToken: "access-token",
      accessTokenExpiresAt: now.addingTimeInterval(3_600),
      refreshToken: "refresh-token",
      refreshTokenExpiresAt: now.addingTimeInterval(86_400)
    )

    do {
      #expect(try await store.allTokenSets().isEmpty)
      try await store.save(saved)
      let discovered = try await store.allTokenSets()
      #expect(discovered.count == 1)
      #expect(discovered.first?.accountID == saved.accountID)
      #expect(discovered.first?.githubUserID == saved.githubUserID)
      #expect(discovered.first?.login == saved.login)
      try await store.delete(accountID: accountID)
      #expect(try await store.allTokenSets().isEmpty)
    } catch {
      try? await store.delete(accountID: accountID)
      throw error
    }
  }

  private func tokenSet(
    accountID: UUID,
    accessToken: String,
    accessExpiresAt: Date
  ) -> GitHubAccountTokenSet {
    GitHubAccountTokenSet(
      accountID: accountID,
      githubUserID: 5,
      login: "owner",
      accessToken: accessToken,
      accessTokenExpiresAt: accessExpiresAt,
      refreshToken: "current-refresh",
      refreshTokenExpiresAt: accessExpiresAt.addingTimeInterval(86_400)
    )
  }
}

private actor CatalogMemoryCredentialStore: GitHubCredentialStoring {
  private var values: [UUID: GitHubAccountTokenSet]
  private(set) var tokenSetCount = 0
  private(set) var allTokenSetsCount = 0
  private(set) var saveCount = 0
  private(set) var deleteCount = 0

  init(tokenSet: GitHubAccountTokenSet) {
    values = [tokenSet.accountID: tokenSet]
  }

  func tokenSet(accountID: UUID) async throws -> GitHubAccountTokenSet? {
    tokenSetCount += 1
    return values[accountID]
  }

  func allTokenSets() async throws -> [GitHubAccountTokenSet] {
    allTokenSetsCount += 1
    return Array(values.values)
  }

  func save(_ tokenSet: GitHubAccountTokenSet) async throws {
    saveCount += 1
    values[tokenSet.accountID] = tokenSet
  }

  func delete(accountID: UUID) async throws {
    deleteCount += 1
    values.removeValue(forKey: accountID)
  }
}

private actor CatalogOAuth: GitHubOAuthAuthorizing {
  private let now: Date
  private(set) var refreshCount = 0
  private(set) var authorizationCount = 0

  init(now: Date) {
    self.now = now
  }

  func authorize(
    clientID: String,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubAuthorizedAccount {
    _ = (clientID, onPrompt)
    authorizationCount += 1
    throw GitHubAPIError.authorizationDenied
  }

  func refresh(clientID: String, refreshToken: String) async throws -> GitHubRefreshedToken {
    _ = (clientID, refreshToken)
    refreshCount += 1
    await Task.yield()
    return GitHubRefreshedToken(
      accessToken: "refreshed-access",
      accessTokenExpiresAt: now.addingTimeInterval(3_600),
      refreshToken: "refreshed-refresh",
      refreshTokenExpiresAt: now.addingTimeInterval(86_400)
    )
  }
}

private actor CatalogConnections: GitHubAccountConnectionCoordinating {
  private let accountID: UUID
  private var productIDs: Set<UUID>
  private(set) var didDisable = false

  init(accountID: UUID, productIDs: Set<UUID>) {
    self.accountID = accountID
    self.productIDs = productIDs
  }

  func linkProduct(
    productID: UUID,
    accountID: UUID,
    githubUserID: Int64,
    login: String
  ) async throws {
    _ = (githubUserID, login)
    guard accountID == self.accountID else { return }
    productIDs.insert(productID)
  }

  func disconnectProduct(productID: UUID, accountID: UUID) async throws {
    guard accountID == self.accountID else { return }
    productIDs.remove(productID)
  }

  func disableConnections(accountID: UUID) async throws {
    guard accountID == self.accountID else { return }
    didDisable = true
    productIDs.removeAll()
  }

  func durableProductIDs(accountID: UUID) async throws -> Set<UUID> {
    accountID == self.accountID ? productIDs : []
  }

  func referencedAccountIDs() async throws -> Set<UUID> {
    productIDs.isEmpty ? [] : [accountID]
  }

  func markConnectionsNeedAuthorization(accountIDs: Set<UUID>) async throws {
    _ = accountIDs
  }
}

private actor CatalogLeaseGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var didBegin = false

  func begin() {
    didBegin = true
  }

  func waitForRelease() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
