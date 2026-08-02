import Foundation
import Testing

@testable import SpeditoCore

@Suite("Git workspace manager", .serialized)
struct GitWorkspaceManagerTests {
  @Test("Product bootstrap ignores local control data before the first snapshot")
  func productBootstrapIgnoresControlData() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-git-ignore-\(UUID().uuidString)",
        isDirectory: true
      )
    let controlDirectory = root.appendingPathComponent(
      ".spedito",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
      at: controlDirectory,
      withIntermediateDirectories: true
    )
    try Data("product\n".utf8).write(
      to: root.appendingPathComponent("README.md")
    )
    try Data("/.run/\n".utf8).write(
      to: root.appendingPathComponent(".gitignore")
    )
    let databaseURL = controlDirectory.appendingPathComponent("product.sqlite")
    try Data("initial control state".utf8).write(to: databaseURL)

    let manager = GitWorkspaceManager()
    let initialSHA = try await manager.ensureRepository(
      at: root,
      rootIgnoreEntries: ["/.spedito/"]
    )

    #expect(
      try String(
        contentsOf: root.appendingPathComponent(".gitignore"),
        encoding: .utf8
      ) == "/.run/\n/.spedito/\n"
    )
    #expect(
      try runGit(["ls-files"], at: root).split(separator: "\n").map(String.init)
        == [".gitignore", "README.md"]
    )

    try Data("updated control state".utf8).write(to: databaseURL)
    let checkpointSHA = try await manager.checkpointTrunk(at: root)
    #expect(checkpointSHA == initialSHA)
    #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
  }

  @Test("Ticket branches preserve multiple commits and promote one exact integrated revision")
  func candidateLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-git-\(UUID().uuidString)", isDirectory: true)
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("baseline\n".utf8).write(
      to: repository.appendingPathComponent("README.md")
    )

    let manager = GitWorkspaceManager()
    let initialSHA = try await manager.ensureRepository(at: repository)
    let workspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T42",
      runID: UUID(),
      authorName: "Implementer"
    )
    #expect(workspace.branchName == "ticket/T42")
    #expect(workspace.baseSHA == initialSHA)

    try Data("first implementation\n".utf8).write(
      to: workspace.url.appendingPathComponent("feature.txt")
    )
    _ = try runGit(["add", "-A"], at: workspace.url)
    _ = try runGit(["commit", "-m", "T42: implement feature"], at: workspace.url)
    try Data("verification\n".utf8).write(
      to: workspace.url.appendingPathComponent("verification.txt")
    )
    #expect(
      try await manager.ticketChangePaths(ticketWorkspaceURL: workspace.url)
        == ["feature.txt", "verification.txt"]
    )

    let candidate = try await manager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: "T42",
      version: 1,
      authorName: "Implementer",
      summary: "Implemented the verified feature"
    )
    #expect(candidate.branchName == "ticket/T42")
    #expect(candidate.commitCount == 2)
    #expect(candidate.changedFiles == ["feature.txt", "verification.txt"])
    #expect(try runGit(["show", "-s", "--format=%an", candidate.headSHA], at: repository) == "Implementer")
    #expect(
      try runGit(["show", "-s", "--format=%s", candidate.headSHA], at: repository)
        == "T42: Implemented the verified feature"
    )

    let activeSnapshot = try await manager.repositorySnapshot(at: repository)
    #expect(activeSnapshot.branches.map(\.name) == ["ticket/T42"])
    #expect(activeSnapshot.commits.contains { $0.sha == candidate.headSHA && !$0.isOnTrunk })
    #expect(activeSnapshot.branches[0].commitSHAs.contains(candidate.headSHA))
    let branchDetail = try await manager.branchDetail(
      at: repository,
      branch: activeSnapshot.branches[0]
    )
    #expect(Set(branchDetail.files.map(\.path)) == ["feature.txt", "verification.txt"])
    #expect(branchDetail.unifiedDiff.contains("+first implementation"))
    #expect(branchDetail.unifiedDiff.contains("+verification"))
    let candidateDetail = try await manager.commitDetail(
      at: repository,
      sha: candidate.headSHA
    )
    #expect(candidateDetail.commit.authorName == "Implementer")
    #expect(candidateDetail.files.map(\.path) == ["verification.txt"])
    #expect(candidateDetail.unifiedDiff.contains("+verification"))

    let integrationCandidateID = UUID()
    let reviewWorkspace = try await manager.prepareCandidateReviewWorkspace(
      repositoryURL: repository,
      reviewsRootURL: integrations,
      candidateID: integrationCandidateID,
      candidateHeadSHA: candidate.headSHA
    )
    #expect(try await manager.currentSHA(at: reviewWorkspace.url) == candidate.headSHA)
    try Data("unreviewed\n".utf8).write(
      to: reviewWorkspace.url.appendingPathComponent("unreviewed.txt")
    )
    let cleanedReviewWorkspace = try await manager.prepareCandidateReviewWorkspace(
      repositoryURL: repository,
      reviewsRootURL: integrations,
      candidateID: integrationCandidateID,
      candidateHeadSHA: candidate.headSHA
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: cleanedReviewWorkspace.url.appendingPathComponent("unreviewed.txt").path
      )
    )

    let integration = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: integrationCandidateID,
      headSHA: candidate.headSHA
    )
    #expect(
      FileManager.default.fileExists(
        atPath: integration.url.appendingPathComponent("feature.txt").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: repository.appendingPathComponent("feature.txt").path
      )
    )
    let integrationDetail = try await manager.commitDetail(
      at: repository,
      sha: integration.integratedSHA
    )
    #expect(integrationDetail.commit.parentSHAs.count == 2)
    #expect(
      Set(integrationDetail.files.map(\.path))
        == ["feature.txt", "verification.txt"]
    )
    #expect(integrationDetail.unifiedDiff.contains("+first implementation"))
    #expect(integrationDetail.unifiedDiff.contains("+verification"))

    let reusedIntegration = try await manager.prepareIntegratedWorkspace(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: integrationCandidateID,
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integration.integratedSHA
    )
    #expect(reusedIntegration == integration)

    try Data("unreviewed\n".utf8).write(
      to: integration.url.appendingPathComponent("unreviewed.txt")
    )
    let cleanedIntegration = try await manager.prepareIntegratedWorkspace(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: integrationCandidateID,
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integration.integratedSHA
    )
    #expect(cleanedIntegration == integration)
    #expect(
      !FileManager.default.fileExists(
        atPath: cleanedIntegration.url.appendingPathComponent("unreviewed.txt").path
      )
    )

    try await manager.removeWorktree(
      repositoryURL: repository,
      worktreeURL: integration.url
    )
    let restoredIntegration = try await manager.prepareIntegratedWorkspace(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: integrationCandidateID,
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integration.integratedSHA
    )
    #expect(restoredIntegration == integration)

    let previewCandidateID = UUID()
    let preview = try await manager.preparePreviewWorkspace(
      repositoryURL: repository,
      previewsRootURL: root.appendingPathComponent("previews", isDirectory: true),
      candidateID: previewCandidateID,
      integratedSHA: integration.integratedSHA
    )
    #expect(try await manager.currentSHA(at: preview) == integration.integratedSHA)
    try Data("cached build\n".utf8).write(
      to: preview.appendingPathComponent(".demo-cache")
    )
    let reusedPreview = try await manager.preparePreviewWorkspace(
      repositoryURL: repository,
      previewsRootURL: preview.deletingLastPathComponent(),
      candidateID: previewCandidateID,
      integratedSHA: integration.integratedSHA
    )
    #expect(reusedPreview == preview)
    #expect(
      FileManager.default.fileExists(
        atPath: reusedPreview.appendingPathComponent(".demo-cache").path
      )
    )

    try await manager.promote(
      repositoryURL: repository,
      integratedSHA: integration.integratedSHA
    )
    #expect(
      try String(
        contentsOf: repository.appendingPathComponent("feature.txt"),
        encoding: .utf8
      ) == "first implementation\n"
    )
    #expect(try await manager.currentSHA(at: repository) == integration.integratedSHA)
    let acceptedSnapshot = try await manager.repositorySnapshot(at: repository)
    #expect(acceptedSnapshot.commits.contains { $0.sha == candidate.headSHA && $0.isOnTrunk })

    try await manager.removeWorktree(
      repositoryURL: repository,
      worktreeURL: integration.url
    )
    try await manager.removeWorktree(
      repositoryURL: repository,
      worktreeURL: preview
    )
    try await manager.removeTicketWorkspace(
      repositoryURL: repository,
      worktreeURL: workspace.url,
      branchName: workspace.branchName
    )
  }

  @Test("Conflicted integrations remain isolated and can be completed deliberately")
  func conflictResolutionLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-conflict-\(UUID().uuidString)", isDirectory: true)
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let sharedFile = repository.appendingPathComponent("shared.txt")
    try Data("baseline\n".utf8).write(to: sharedFile)

    let manager = GitWorkspaceManager()
    _ = try await manager.ensureRepository(at: repository)
    let workspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T7",
      runID: UUID(),
      authorName: "Implementer"
    )
    try Data("ticket behavior\n".utf8).write(
      to: workspace.url.appendingPathComponent("shared.txt")
    )
    let candidate = try await manager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: "T7",
      version: 1,
      authorName: "Implementer"
    )

    try Data("accepted trunk behavior\n".utf8).write(to: sharedFile)
    _ = try await manager.checkpointTrunk(at: repository, message: "Advance trunk")

    let conflictWorkspace: URL
    do {
      _ = try await manager.integrateCandidate(
        repositoryURL: repository,
        integrationsRootURL: integrations,
        candidateID: UUID(),
        headSHA: candidate.headSHA
      )
      Issue.record("Expected an isolated merge conflict")
      return
    } catch GitWorkspaceError.mergeConflict(let worktreePath, let files, _) {
      conflictWorkspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
      #expect(files == ["shared.txt"])
      #expect(FileManager.default.fileExists(atPath: conflictWorkspace.path))
    }

    await #expect(throws: GitWorkspaceError.self) {
      try await manager.completeConflictResolution(
        integrationWorkspaceURL: conflictWorkspace,
        candidateHeadSHA: candidate.headSHA
      )
    }
    #expect(
      !(try await manager.conflictResolutionIsReadyToCommit(
        integrationWorkspaceURL: conflictWorkspace
      ))
    )

    try Data("accepted trunk behavior  \nticket behavior\n".utf8).write(
      to: conflictWorkspace.appendingPathComponent("shared.txt")
    )
    _ = try runGit(["add", "-A"], at: conflictWorkspace)
    #expect(
      try await manager.conflictResolutionIsReadyToCommit(
        integrationWorkspaceURL: conflictWorkspace
      )
    )
    let integrated = try await manager.completeConflictResolution(
      integrationWorkspaceURL: conflictWorkspace,
      candidateHeadSHA: candidate.headSHA
    )
    #expect(try await manager.unmergedFiles(at: conflictWorkspace).isEmpty)
    let integrationDetail = try await manager.commitDetail(
      at: repository,
      sha: integrated.integratedSHA
    )
    #expect(integrationDetail.commit.parentSHAs.count == 2)
    #expect(integrationDetail.files.map(\.path) == ["shared.txt"])
    #expect(integrationDetail.unifiedDiff.contains("+ticket behavior"))

    try await manager.promote(
      repositoryURL: repository,
      integratedSHA: integrated.integratedSHA
    )
    #expect(
      try String(contentsOf: sharedFile, encoding: .utf8)
        == "accepted trunk behavior  \nticket behavior\n"
    )
    #expect(
      try await manager.integratedRevisionContainsCurrentTrunk(
        repositoryURL: repository,
        integratedSHA: integrated.integratedSHA
      )
    )

    try Data("newer accepted behavior\n".utf8).write(to: sharedFile)
    _ = try await manager.checkpointTrunk(at: repository, message: "Advance accepted trunk")
    #expect(
      !(try await manager.integratedRevisionContainsCurrentTrunk(
        repositoryURL: repository,
        integratedSHA: integrated.integratedSHA
      ))
    )
  }

  @Test("A reviewed integration becomes the baseline for the next ticket revision")
  func reviewedIntegrationBecomesRevisionBaseline() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-adopt-\(UUID().uuidString)", isDirectory: true)
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let sharedFile = repository.appendingPathComponent("shared.txt")
    try Data("baseline\n".utf8).write(to: sharedFile)

    let manager = GitWorkspaceManager()
    _ = try await manager.ensureRepository(at: repository)
    let workspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T71",
      runID: UUID(),
      authorName: "Implementer"
    )
    try Data("ticket behavior\n".utf8).write(
      to: workspace.url.appendingPathComponent("shared.txt")
    )
    let firstCandidate = try await manager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: "T71",
      version: 1,
      authorName: "Implementer"
    )

    try Data("accepted trunk behavior\n".utf8).write(to: sharedFile)
    let acceptedTrunkSHA = try await manager.checkpointTrunk(
      at: repository,
      message: "Advance trunk"
    )

    let conflictWorkspace: URL
    do {
      _ = try await manager.integrateCandidate(
        repositoryURL: repository,
        integrationsRootURL: integrations,
        candidateID: UUID(),
        headSHA: firstCandidate.headSHA
      )
      Issue.record("Expected an isolated merge conflict")
      return
    } catch GitWorkspaceError.mergeConflict(let worktreePath, _, _) {
      conflictWorkspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
    }
    try Data("accepted trunk behavior\nticket behavior\n".utf8).write(
      to: conflictWorkspace.appendingPathComponent("shared.txt")
    )
    let reviewedIntegration = try await manager.completeConflictResolution(
      integrationWorkspaceURL: conflictWorkspace,
      candidateHeadSHA: firstCandidate.headSHA
    )

    let uncapturedFile = workspace.url.appendingPathComponent("uncaptured.txt")
    try Data("not ready\n".utf8).write(to: uncapturedFile)
    await #expect(throws: GitWorkspaceError.self) {
      try await manager.adoptIntegratedRevision(
        ticketWorkspaceURL: workspace.url,
        candidateHeadSHA: firstCandidate.headSHA,
        integratedSHA: reviewedIntegration.integratedSHA
      )
    }
    try FileManager.default.removeItem(at: uncapturedFile)

    let adoptedSHA = try await manager.adoptIntegratedRevision(
      ticketWorkspaceURL: workspace.url,
      candidateHeadSHA: firstCandidate.headSHA,
      integratedSHA: reviewedIntegration.integratedSHA
    )
    #expect(adoptedSHA == reviewedIntegration.integratedSHA)
    #expect(try await manager.currentSHA(at: workspace.url) == reviewedIntegration.integratedSHA)
    #expect(
      try String(
        contentsOf: workspace.url.appendingPathComponent("shared.txt"),
        encoding: .utf8
      ) == "accepted trunk behavior\nticket behavior\n"
    )
    #expect(
      try await manager.adoptIntegratedRevision(
        ticketWorkspaceURL: workspace.url,
        candidateHeadSHA: firstCandidate.headSHA,
        integratedSHA: reviewedIntegration.integratedSHA
      ) == reviewedIntegration.integratedSHA
    )

    try Data("accepted trunk behavior\nticket behavior\nreview correction\n".utf8).write(
      to: workspace.url.appendingPathComponent("shared.txt")
    )
    let secondCandidate = try await manager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: "T71",
      version: 2,
      authorName: "Implementer"
    )
    #expect(secondCandidate.baseSHA == acceptedTrunkSHA)
    _ = try runGit(
      ["merge-base", "--is-ancestor", reviewedIntegration.integratedSHA, secondCandidate.headSHA],
      at: repository
    )

    await #expect(throws: GitWorkspaceError.self) {
      try await manager.adoptIntegratedRevision(
        ticketWorkspaceURL: workspace.url,
        candidateHeadSHA: firstCandidate.headSHA,
        integratedSHA: reviewedIntegration.integratedSHA
      )
    }

    let secondIntegration = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: secondCandidate.headSHA
    )
    #expect(
      try String(
        contentsOf: secondIntegration.url.appendingPathComponent("shared.txt"),
        encoding: .utf8
      ) == "accepted trunk behavior\nticket behavior\nreview correction\n"
    )
  }

  private func runGit(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(
      data: data,
      encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: output)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
