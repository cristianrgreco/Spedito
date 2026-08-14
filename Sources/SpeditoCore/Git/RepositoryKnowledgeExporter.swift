import CryptoKit
import Foundation

public enum RepositoryKnowledgeExportError: Error, Equatable, LocalizedError, Sendable {
  case unsafeAncestor(String)
  case unexpectedChanges([String])

  public var errorDescription: String? {
    switch self {
    case .unsafeAncestor(let path):
      "Spedito kept repository knowledge in its database because \(path) is not a safe directory."
    case .unexpectedChanges(let paths):
      "Repository knowledge publication found unexpected changes: \(paths.joined(separator: ", "))."
    }
  }
}

public enum RepositoryKnowledgeExporter {
  public static func export(
    projection: RepositoryKnowledgePublicationProjection,
    changedPageIDs: Set<UUID>,
    repository: ProductRepository,
    workspaceURL: URL,
    gitWorkspaceManager: GitWorkspaceManager,
    fileManager: FileManager = .default
  ) async throws -> RepositoryKnowledgeExportResult {
    let pagesByID = Dictionary(uniqueKeysWithValues: projection.pages.map { ($0.id, $0) })
    var exportPageIDs = changedPageIDs
    for pageID in changedPageIDs {
      var parentID = pagesByID[pageID]?.parentID
      while let id = parentID, let parent = pagesByID[id] {
        exportPageIDs.insert(id)
        parentID = parent.parentID
      }
    }

    var contentsByPath: [String: Data] = [:]
    for pageID in exportPageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let page = pagesByID[pageID] else { continue }
      let path = knowledgePath(for: page, pagesByID: pagesByID)
      let markdown = page.bodyMarkdown.isEmpty ? "# \(page.title)\n" : page.bodyMarkdown
      contentsByPath[path] = Data(markdown.utf8)
    }

    let protected = Set(repository.protectedKnowledgePaths.map(\.path))
    var skipped = contentsByPath.keys.filter { path in
      repository.blocksKnowledgeExport
        || protected.contains { protectedPath in
          let key = GitWorkspaceManager.repositoryPathCollisionKey(path)
          return key == protectedPath || key.hasPrefix(protectedPath + "/")
        }
    }
    let preflightPaths = contentsByPath.keys.filter { !skipped.contains($0) }
    let disposition = try await gitWorkspaceManager.repositoryKnowledgeExportDisposition(
      at: workspaceURL,
      paths: preflightPaths
    )
    skipped.append(contentsOf: disposition.skipped)

    var expectedDigests: [String: String] = [:]
    var expectedContents: [String: Data] = [:]
    for path in disposition.allowed.sorted() {
      guard let data = contentsByPath[path] else { continue }
      let fileURL = workspaceURL.appendingPathComponent(path)
      try validateAncestors(
        of: fileURL,
        beneath: workspaceURL,
        fileManager: fileManager
      )
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      expectedDigests[path] = sha256(data)
      expectedContents[path] = data
      if (try? Data(contentsOf: fileURL)) != data {
        try data.write(to: fileURL, options: .atomic)
      }
    }

    let dirty = try await gitWorkspaceManager.repositoryDirtyPaths(at: workspaceURL)
    let touched = dirty.sorted()
    guard Set(touched).isSubset(of: Set(disposition.allowed)) else {
      throw RepositoryKnowledgeExportError.unexpectedChanges(dirty)
    }
    for path in touched {
      guard let expectedData = expectedContents[path],
        try Data(contentsOf: workspaceURL.appendingPathComponent(path)) == expectedData
      else {
        throw RepositoryKnowledgeExportError.unexpectedChanges(dirty)
      }
    }
    return RepositoryKnowledgeExportResult(
      managedPaths: disposition.allowed,
      touchedPaths: touched,
      skippedPaths: Array(Set(skipped)),
      expectedContents: expectedContents,
      expectedDigests: expectedDigests
    )
  }

  public static func knowledgePath(
    for page: KnowledgePage,
    pagesByID: [UUID: KnowledgePage]
  ) -> String {
    var components = ["knowledge"]
    var ancestors: [String] = []
    var parentID = page.parentID
    while let id = parentID, let parent = pagesByID[id] {
      ancestors.insert(parent.slug, at: 0)
      parentID = parent.parentID
    }
    components.append(contentsOf: ancestors)
    if page.kind == .section {
      components.append(page.slug)
      components.append("index.md")
    } else {
      components.append("\(page.slug).md")
    }
    return components.joined(separator: "/")
  }

  private static func validateAncestors(
    of fileURL: URL,
    beneath workspaceURL: URL,
    fileManager: FileManager
  ) throws {
    let relative = String(fileURL.path.dropFirst(workspaceURL.path.count + 1))
    let components = relative.split(separator: "/").dropLast()
    var current = workspaceURL
    for component in components {
      current.appendPathComponent(String(component), isDirectory: true)
      guard fileManager.fileExists(atPath: current.path) else { continue }
      let values = try current.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw RepositoryKnowledgeExportError.unsafeAncestor(
          String(current.path.dropFirst(workspaceURL.path.count + 1))
        )
      }
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
