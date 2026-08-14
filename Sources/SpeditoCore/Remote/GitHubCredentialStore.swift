import Foundation
import Security

public struct GitHubAccountTokenSet: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let accountID: UUID
  public let githubUserID: Int64
  public let login: String
  public let accessToken: String
  public let accessTokenExpiresAt: Date
  public let refreshToken: String
  public let refreshTokenExpiresAt: Date

  public init(
    version: Int = GitHubAccountTokenSet.currentVersion,
    accountID: UUID,
    githubUserID: Int64,
    login: String,
    accessToken: String,
    accessTokenExpiresAt: Date,
    refreshToken: String,
    refreshTokenExpiresAt: Date
  ) {
    self.version = version
    self.accountID = accountID
    self.githubUserID = githubUserID
    self.login = login
    self.accessToken = accessToken
    self.accessTokenExpiresAt = accessTokenExpiresAt
    self.refreshToken = refreshToken
    self.refreshTokenExpiresAt = refreshTokenExpiresAt
  }
}

public enum GitHubCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
  case keychainFailure(OSStatus)
  case invalidPayload

  public var errorDescription: String? {
    switch self {
    case .keychainFailure(let status):
      "GitHub credentials are unavailable in Keychain (\(status))."
    case .invalidPayload:
      "Stored GitHub credentials are invalid. Sign in to GitHub again."
    }
  }
}

public protocol GitHubCredentialStoring: Sendable {
  func tokenSet(accountID: UUID) async throws -> GitHubAccountTokenSet?
  func allTokenSets() async throws -> [GitHubAccountTokenSet]
  func save(_ tokenSet: GitHubAccountTokenSet) async throws
  func delete(accountID: UUID) async throws
}

public struct GitHubCredentialStore: GitHubCredentialStoring, Sendable {
  public let service: String

  public init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.spedito.app") {
    service = "\(bundleIdentifier).github"
  }

  public func tokenSet(accountID: UUID) async throws -> GitHubAccountTokenSet? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      baseQuery(accountID: accountID).merging([
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]) { _, new in new } as CFDictionary,
      &result
    )
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw GitHubCredentialStoreError.keychainFailure(status)
    }
    return try decode(data, expectedAccountID: accountID)
  }

  public func allTokenSets() async throws -> [GitHubAccountTokenSet] {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      baseQuery().merging([
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
      ]) { _, new in new } as CFDictionary,
      &result
    )
    if status == errSecItemNotFound {
      return []
    }
    guard status == errSecSuccess, let result else {
      throw GitHubCredentialStoreError.keychainFailure(status)
    }
    let accountIDs = try accountIDs(from: result)
    var tokenSets: [GitHubAccountTokenSet] = []
    tokenSets.reserveCapacity(accountIDs.count)
    for accountID in accountIDs {
      guard let tokenSet = try await tokenSet(accountID: accountID) else {
        throw GitHubCredentialStoreError.invalidPayload
      }
      tokenSets.append(tokenSet)
    }
    return tokenSets
  }

  public func save(_ tokenSet: GitHubAccountTokenSet) async throws {
    try validate(tokenSet)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(tokenSet)
    let query = baseQuery(accountID: tokenSet.accountID)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: payload] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw GitHubCredentialStoreError.keychainFailure(updateStatus)
    }
    let addStatus = SecItemAdd(
      query.merging([
        kSecValueData as String: payload,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]) { _, new in new } as CFDictionary,
      nil
    )
    guard addStatus == errSecSuccess else {
      throw GitHubCredentialStoreError.keychainFailure(addStatus)
    }
  }

  public func delete(accountID: UUID) async throws {
    let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw GitHubCredentialStoreError.keychainFailure(status)
    }
  }

  private func baseQuery(accountID: UUID? = nil) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
    if let accountID {
      query[kSecAttrAccount as String] = accountID.uuidString
    }
    return query
  }

  private func accountIDs(from result: CFTypeRef) throws -> [UUID] {
    let attributes: [[String: Any]]
    if let values = result as? [[String: Any]] {
      attributes = values
    } else if let value = result as? [String: Any] {
      attributes = [value]
    } else {
      throw GitHubCredentialStoreError.invalidPayload
    }
    return try attributes.map { value in
      guard
        let account = value[kSecAttrAccount as String] as? String,
        let accountID = UUID(uuidString: account)
      else {
        throw GitHubCredentialStoreError.invalidPayload
      }
      return accountID
    }
  }

  private func decode(
    _ data: Data,
    expectedAccountID: UUID?
  ) throws -> GitHubAccountTokenSet {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let tokenSet = try? decoder.decode(GitHubAccountTokenSet.self, from: data) else {
      throw GitHubCredentialStoreError.invalidPayload
    }
    try validate(tokenSet)
    if let expectedAccountID, tokenSet.accountID != expectedAccountID {
      throw GitHubCredentialStoreError.invalidPayload
    }
    return tokenSet
  }

  private func validate(_ tokenSet: GitHubAccountTokenSet) throws {
    guard
      tokenSet.version == GitHubAccountTokenSet.currentVersion,
      tokenSet.githubUserID > 0,
      !tokenSet.login.isEmpty,
      tokenSet.login.unicodeScalars.count <= 100,
      !tokenSet.accessToken.isEmpty,
      !tokenSet.refreshToken.isEmpty,
      tokenSet.refreshTokenExpiresAt > tokenSet.accessTokenExpiresAt
    else {
      throw GitHubCredentialStoreError.invalidPayload
    }
  }
}
