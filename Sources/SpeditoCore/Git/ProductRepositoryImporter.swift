import Darwin
import Foundation

public struct PublicGitRepositoryURL: Equatable, Hashable, Sendable {
  public static let invalidMessage =
    "Enter a public HTTPS Git repository link from GitHub, GitLab, Bitbucket, or Codeberg without credentials, query parameters, or a fragment."
  public static let supportedHosts: Set<String> = [
    "bitbucket.org", "codeberg.org", "github.com", "gitlab.com",
  ]

  public let url: URL
  public let suggestedProductName: String

  public init(_ rawValue: String) throws {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      var components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      !host.isEmpty,
      Self.supportedHosts.contains(host),
      !components.path.isEmpty,
      components.path != "/",
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.port == nil || components.port == 443,
      !Self.isLocalHost(host),
      !Self.isNonPublicIPLiteral(host)
    else {
      throw ValidationError()
    }

    components.scheme = "https"
    components.host = host
    components.port = nil
    while components.path.count > 1 && components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    guard let canonicalURL = components.url else { throw ValidationError() }
    let finalComponent = canonicalURL.lastPathComponent
    let name =
      finalComponent.lowercased().hasSuffix(".git")
      ? String(finalComponent.dropLast(4))
      : finalComponent
    guard !name.isEmpty else { throw ValidationError() }

    url = canonicalURL
    suggestedProductName = name
  }

  public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { PublicGitRepositoryURL.invalidMessage }
  }

  private static func isLocalHost(_ host: String) -> Bool {
    host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
  }

  private static func isNonPublicIPLiteral(_ host: String) -> Bool {
    let host =
      host.hasPrefix("[") && host.hasSuffix("]")
      ? String(host.dropFirst().dropLast())
      : host
    var ipv4 = in_addr()
    if inet_pton(AF_INET, host, &ipv4) == 1 {
      let address = UInt32(bigEndian: ipv4.s_addr)
      let first = UInt8((address >> 24) & 0xff)
      let second = UInt8((address >> 16) & 0xff)
      return first == 0 || first == 10 || first == 127
        || (first == 169 && second == 254)
        || (first == 172 && (16...31).contains(second))
        || (first == 192 && second == 168)
    }

    var ipv6 = in6_addr()
    if inet_pton(AF_INET6, host, &ipv6) == 1 {
      let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
      let isUnspecified = bytes.allSatisfy { $0 == 0 }
      let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
      let isUniqueLocal = bytes[0] & 0xfe == 0xfc
      let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
      let isMappedIPv4 =
        bytes.prefix(10).allSatisfy { $0 == 0 }
        && bytes[10] == 0xff && bytes[11] == 0xff
      if isMappedIPv4 {
        let mapped = bytes.suffix(4)
        let first = mapped[mapped.startIndex]
        let second = mapped[mapped.index(after: mapped.startIndex)]
        return first == 0 || first == 10 || first == 127
          || (first == 169 && second == 254)
          || (first == 172 && (16...31).contains(second))
          || (first == 192 && second == 168)
      }
      return isUnspecified || isLoopback || isUniqueLocal || isLinkLocal
    }
    return false
  }
}

public struct ImportedProduct: Sendable {
  public let product: Product
  public let repository: ProductRepository
  public let knowledgeRun: RepositoryKnowledgeRun

  public init(
    product: Product,
    repository: ProductRepository,
    knowledgeRun: RepositoryKnowledgeRun
  ) {
    self.product = product
    self.repository = repository
    self.knowledgeRun = knowledgeRun
  }
}

public enum ProductRepositoryImportError: Error, Equatable, LocalizedError, Sendable {
  case missingName
  case cloneFailed
  case emptyDefaultBranch
  case controlPathCollision
  case activationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .missingName:
      "A product needs a name."
    case .cloneFailed:
      "Spedito couldn't clone that public repository. Check the link, repository visibility, and network connection, then try again."
    case .emptyDefaultBranch:
      "That repository has no commits on a named default branch."
    case .controlPathCollision:
      "This repository already contains a .spedito path, so Spedito can't import it safely."
    case .activationFailed(let message):
      message
    }
  }
}

@MainActor
public final class ProductRepositoryImporter {
  private let storeRegistry: ProductStoreRegistry
  private let gitWorkspaceManager: GitWorkspaceManager
  private let stagingRootURL: URL
  private let fileManager: FileManager

  public init(
    storeRegistry: ProductStoreRegistry,
    gitWorkspaceManager: GitWorkspaceManager,
    stagingRootURL: URL,
    fileManager: FileManager = .default
  ) {
    self.storeRegistry = storeRegistry
    self.gitWorkspaceManager = gitWorkspaceManager
    self.stagingRootURL = stagingRootURL
    self.fileManager = fileManager
  }

  public func prepare() throws {
    try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
    let children = try fileManager.contentsOfDirectory(
      at: stagingRootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    for child in children where UUID(uuidString: child.lastPathComponent) != nil {
      try fileManager.removeItem(at: child)
    }
  }

  public func importProduct(
    name: String,
    from source: PublicGitRepositoryURL,
    credentialConfiguration: GitCredentialSessionConfiguration? = nil
  ) async throws -> ImportedProduct {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw ProductRepositoryImportError.missingName }
    try prepare()

    let productID = UUID()
    let stagingURL = stagingRootURL.appendingPathComponent(
      productID.uuidString,
      isDirectory: true
    )
    let canonicalURL = storeRegistry.productWorkspacesRootURL.appendingPathComponent(
      productID.uuidString,
      isDirectory: true
    )
    var didActivate = false
    defer {
      if !didActivate {
        try? fileManager.removeItem(at: stagingURL)
        try? fileManager.removeItem(at: canonicalURL)
      }
    }

    let importedGit: GitImportedRepository
    do {
      importedGit = try await gitWorkspaceManager.clonePublicRepository(
        from: source.url,
        to: stagingURL,
        credentialConfiguration: credentialConfiguration
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as GitWorkspaceError {
      switch error {
      case .invalidRepository(let detail) where detail == GitImportedRepository.emptyBranchMarker:
        throw ProductRepositoryImportError.emptyDefaultBranch
      case .invalidRepository(let detail)
      where detail == GitImportedRepository.controlCollisionMarker:
        throw ProductRepositoryImportError.controlPathCollision
      default:
        throw ProductRepositoryImportError.cloneFailed
      }
    } catch {
      throw ProductRepositoryImportError.cloneFailed
    }

    let repository = ProductRepository(
      productID: productID,
      originURL: source.url,
      sourceDefaultBranch: importedGit.sourceDefaultBranch,
      importedSHA: importedGit.importedSHA
    )
    let product = try await storeRegistry.prepareImportedProduct(
      name: trimmedName,
      id: productID,
      workspaceURL: stagingURL,
      repository: repository
    )
    guard !fileManager.fileExists(atPath: canonicalURL.path) else {
      throw ProductRepositoryImportError.activationFailed(
        "Spedito couldn't activate the imported product because its workspace already exists."
      )
    }
    try fileManager.moveItem(at: stagingURL, to: canonicalURL)
    let registeredProduct = try await storeRegistry.registerPreparedProduct(id: productID)
    guard registeredProduct.id == product.id,
      let store = storeRegistry.store(for: productID),
      let run = try await store.fetchLatestRepositoryKnowledgeRun(productID: productID)
    else {
      throw ProductRepositoryImportError.activationFailed(
        "Spedito couldn't activate the imported product."
      )
    }
    didActivate = true
    return ImportedProduct(product: registeredProduct, repository: repository, knowledgeRun: run)
  }
}
