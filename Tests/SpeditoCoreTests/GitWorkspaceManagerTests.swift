import Darwin
import Foundation
import Testing

@testable import SpeditoCore

@Suite("Git workspace manager", .serialized)
struct GitWorkspaceManagerTests {
  @Test("Spedito-owned commits ignore inherited signing settings")
  func managedCommitsIgnoreSigningSettings() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-git-signing-\(UUID().uuidString)",
        isDirectory: true
      )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    let gitWrapper = root.appendingPathComponent("git-with-signing-enabled")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data(
      """
      #!/bin/sh
      exec /usr/bin/git -c commit.gpgSign=true -c gpg.format=ssh -c gpg.ssh.program=/usr/bin/false -c user.signingKey=unavailable-test-key "$@"

      """.utf8
    ).write(to: gitWrapper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: gitWrapper.path
    )
    try Data("baseline\n".utf8).write(
      to: repository.appendingPathComponent("README.md")
    )

    let manager = GitWorkspaceManager(executableURL: gitWrapper)
    let initialSHA = try await manager.ensureRepository(at: repository)
    try Data("accepted change\n".utf8).write(
      to: repository.appendingPathComponent("accepted.txt")
    )
    let checkpointSHA = try await manager.checkpointTrunk(at: repository)
    let workspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T9",
      runID: UUID(),
      authorName: "Implementer"
    )
    try Data("first ticket change\n".utf8).write(
      to: workspace.url.appendingPathComponent("first.txt")
    )
    let workspaceCheckpointSHA = try await manager.checkpointWorkspace(
      at: workspace.url,
      message: "Capture ticket progress"
    )
    try Data("candidate change\n".utf8).write(
      to: workspace.url.appendingPathComponent("candidate.txt")
    )
    let candidate = try await manager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: "T9",
      version: 1,
      authorName: "Implementer"
    )
    let integration = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: candidate.headSHA
    )

    for sha in [
      initialSHA,
      checkpointSHA,
      workspaceCheckpointSHA,
      candidate.headSHA,
      integration.integratedSHA,
    ] {
      #expect(try runGit(["show", "-s", "--format=%G?", sha], at: repository) == "N")
    }
  }

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
    let initialSHA = try await manager.ensureRepository(at: root)

    #expect(
      try String(
        contentsOf: root.appendingPathComponent(".gitignore"),
        encoding: .utf8
      ) == "/.run/\n"
    )
    #expect(
      try String(
        contentsOf: root.appendingPathComponent(".git/info/exclude"),
        encoding: .utf8
      ).split(whereSeparator: \.isNewline).contains("/.spedito/")
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

  @Test("Repository-free candidates snapshot the ticket base without an empty commit")
  func localOutcomeCandidateSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-local-outcome-\(UUID().uuidString)", isDirectory: true)
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
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
      ticketKey: "T1",
      runID: UUID(),
      authorName: "Business analyst"
    )

    let candidate = try await manager.snapshotLocalOutcomeCandidate(
      ticketWorkspaceURL: workspace.url
    )

    #expect(candidate.baseSHA == initialSHA)
    #expect(candidate.headSHA == initialSHA)
    #expect(candidate.commitCount == 0)
    #expect(candidate.changedFiles.isEmpty)
    #expect(try runGit(["status", "--porcelain"], at: workspace.url).isEmpty)
    #expect(try runGit(["rev-list", "--count", "HEAD"], at: workspace.url) == "1")

    _ = try runGit(
      ["-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Empty delivery"],
      at: workspace.url
    )
    await #expect(throws: GitWorkspaceError.self) {
      _ = try await manager.snapshotLocalOutcomeCandidate(
        ticketWorkspaceURL: workspace.url
      )
    }
  }

  @Test("[D12] Candidate integration serializes exact revisions against current trunk")
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
    #expect(
      try runGit(["show", "-s", "--format=%an", candidate.headSHA], at: repository) == "Implementer"
    )
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

  @Test("An unchanged revision reuses its prior integration instead of duplicating the merge")
  func unchangedRevisionReusesPriorIntegration() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-git-reuse-integration-\(UUID().uuidString)",
        isDirectory: true
      )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("baseline\n".utf8).write(
      to: repository.appendingPathComponent("README.md")
    )
    let manager = GitWorkspaceManager()
    _ = try await manager.ensureRepository(at: repository)
    let workspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T90",
      runID: UUID(),
      authorName: "Implementer"
    )
    try Data("ticket change\n".utf8).write(
      to: workspace.url.appendingPathComponent("ticket.txt")
    )
    let candidate = try await manager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: "T90",
      version: 1,
      authorName: "Implementer"
    )
    let firstIntegration = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: candidate.headSHA,
      commitMessage: "Integrate T90: Deliver the ticket"
    )

    let reused = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: firstIntegration.integratedSHA,
      commitMessage: "Integrate T90: Deliver the ticket",
      reusableIntegratedSHA: firstIntegration.integratedSHA
    )
    #expect(reused.integratedSHA == firstIntegration.integratedSHA)
    #expect(try await manager.currentSHA(at: reused.url) == firstIntegration.integratedSHA)

    try Data("accepted follow-up\n".utf8).write(
      to: repository.appendingPathComponent("accepted.txt")
    )
    _ = try await manager.checkpointTrunk(at: repository)
    let merged = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: firstIntegration.integratedSHA,
      commitMessage: "Integrate T90: Deliver the ticket",
      reusableIntegratedSHA: firstIntegration.integratedSHA
    )
    #expect(merged.integratedSHA != firstIntegration.integratedSHA)
    #expect(
      try runGit(["rev-parse", "\(merged.integratedSHA)^1"], at: repository)
        == runGit(["rev-parse", "refs/heads/trunk"], at: repository)
    )
    #expect(
      FileManager.default.fileExists(
        atPath: merged.url.appendingPathComponent("ticket.txt").path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: merged.url.appendingPathComponent("accepted.txt").path
      )
    )
  }

  @Test("Verified GitHub changes merge into an isolated ticket integration")
  func verifiedRemoteIntegration() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-verified-remote-\(UUID().uuidString)",
        isDirectory: true
      )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    let remoteWorkspace = root.appendingPathComponent("remote", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("baseline\n".utf8).write(
      to: repository.appendingPathComponent("README.md")
    )
    let manager = GitWorkspaceManager()
    let initialSHA = try await manager.ensureRepository(at: repository)
    let ticketWorkspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T80",
      runID: UUID(),
      authorName: "Implementer"
    )
    try Data("ticket\n".utf8).write(
      to: ticketWorkspace.url.appendingPathComponent("ticket.txt")
    )
    let candidate = try await manager.createCandidate(
      ticketWorkspaceURL: ticketWorkspace.url,
      ticketKey: "T80",
      version: 1,
      authorName: "Implementer"
    )
    let integration = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: candidate.headSHA
    )

    _ = try runGit(
      ["worktree", "add", "--detach", remoteWorkspace.path, initialSHA],
      at: repository
    )
    try Data("github\n".utf8).write(
      to: remoteWorkspace.appendingPathComponent("remote.txt")
    )
    _ = try runGit(["add", "remote.txt"], at: remoteWorkspace)
    _ = try runGit(
      [
        "-c", "user.name=GitHub collaborator",
        "-c", "user.email=github@example.com",
        "commit", "--no-gpg-sign", "-m", "Remote change",
      ],
      at: remoteWorkspace
    )
    let remoteSHA = try runGit(["rev-parse", "HEAD"], at: remoteWorkspace)
    let observationRef = "refs/spedito/observations/\(UUID().uuidString.lowercased())"
    _ = try runGit(["update-ref", observationRef, remoteSHA], at: repository)

    let updated = try await manager.integrateVerifiedRemote(
      repositoryURL: repository,
      integrationWorkspaceURL: integration.url,
      observationRef: observationRef,
      expectedRemoteSHA: remoteSHA,
      candidateHeadSHA: candidate.headSHA
    )

    #expect(
      try await manager.revision(
        updated.integratedSHA,
        contains: candidate.headSHA,
        at: repository
      )
    )
    #expect(
      try await manager.revision(
        updated.integratedSHA,
        contains: remoteSHA,
        at: repository
      )
    )
    #expect(
      try String(
        contentsOf: updated.url.appendingPathComponent("ticket.txt"),
        encoding: .utf8
      ) == "ticket\n"
    )
    #expect(
      try String(
        contentsOf: updated.url.appendingPathComponent("remote.txt"),
        encoding: .utf8
      ) == "github\n"
    )
  }

  @Test("Verified GitHub conflicts preserve the existing resolution lifecycle")
  func verifiedRemoteConflictResolution() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-verified-remote-conflict-\(UUID().uuidString)",
        isDirectory: true
      )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    let remoteWorkspace = root.appendingPathComponent("remote", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("baseline\n".utf8).write(
      to: repository.appendingPathComponent("shared.txt")
    )
    let manager = GitWorkspaceManager()
    let initialSHA = try await manager.ensureRepository(at: repository)
    let ticketWorkspace = try await manager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: "T81",
      runID: UUID(),
      authorName: "Implementer"
    )
    try Data("ticket\n".utf8).write(
      to: ticketWorkspace.url.appendingPathComponent("shared.txt")
    )
    let candidate = try await manager.createCandidate(
      ticketWorkspaceURL: ticketWorkspace.url,
      ticketKey: "T81",
      version: 1,
      authorName: "Implementer"
    )
    let integration = try await manager.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: integrations,
      candidateID: UUID(),
      headSHA: candidate.headSHA
    )

    _ = try runGit(
      ["worktree", "add", "--detach", remoteWorkspace.path, initialSHA],
      at: repository
    )
    try Data("github\n".utf8).write(
      to: remoteWorkspace.appendingPathComponent("shared.txt")
    )
    _ = try runGit(["add", "shared.txt"], at: remoteWorkspace)
    _ = try runGit(
      [
        "-c", "user.name=GitHub collaborator",
        "-c", "user.email=github@example.com",
        "commit", "--no-gpg-sign", "-m", "Conflicting remote change",
      ],
      at: remoteWorkspace
    )
    let remoteSHA = try runGit(["rev-parse", "HEAD"], at: remoteWorkspace)
    let observationRef = "refs/spedito/observations/\(UUID().uuidString.lowercased())"
    _ = try runGit(["update-ref", observationRef, remoteSHA], at: repository)

    let conflictWorkspace: URL
    do {
      _ = try await manager.integrateVerifiedRemote(
        repositoryURL: repository,
        integrationWorkspaceURL: integration.url,
        observationRef: observationRef,
        expectedRemoteSHA: remoteSHA,
        candidateHeadSHA: candidate.headSHA
      )
      Issue.record("Expected verified GitHub changes to conflict")
      return
    } catch GitWorkspaceError.mergeConflict(let worktreePath, let files, _) {
      conflictWorkspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
      #expect(files == ["shared.txt"])
    }

    try Data("github\nticket\n".utf8).write(
      to: conflictWorkspace.appendingPathComponent("shared.txt")
    )
    let resolved = try await manager.completeConflictResolution(
      integrationWorkspaceURL: conflictWorkspace,
      candidateHeadSHA: candidate.headSHA
    )
    #expect(
      try await manager.revision(
        resolved.integratedSHA,
        contains: candidate.headSHA,
        at: repository
      )
    )
    #expect(
      try await manager.revision(
        resolved.integratedSHA,
        contains: remoteSHA,
        at: repository
      )
    )
    #expect(
      try String(
        contentsOf: conflictWorkspace.appendingPathComponent("shared.txt"),
        encoding: .utf8
      ) == "github\nticket\n"
    )
  }

  @Test("Same-product Git commands do not overlap while a process is running")
  func sameProductCommandsSerialize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-git-serialization-\(UUID().uuidString)",
      isDirectory: true
    )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let wrapper = root.appendingPathComponent("serialized-git")
    let lock = root.appendingPathComponent("active-command", isDirectory: true)
    let startedPipe = root.appendingPathComponent("started.pipe")
    let releasePipe = root.appendingPathComponent("release.pipe")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    _ = try await GitWorkspaceManager().ensureRepository(at: repository)
    try #require(mkfifo(startedPipe.path, 0o600) == 0)
    try #require(mkfifo(releasePipe.path, 0o600) == 0)
    let startedDescriptor = open(startedPipe.path, O_RDWR)
    let releaseDescriptor = open(releasePipe.path, O_RDWR)
    try #require(startedDescriptor >= 0)
    try #require(releaseDescriptor >= 0)
    defer {
      _ = close(startedDescriptor)
      _ = close(releaseDescriptor)
    }

    try Data(
      """
      #!/bin/sh
      if ! /bin/mkdir '\(lock.path)' 2>/dev/null; then
        printf O > '\(startedPipe.path)'
        exit 97
      fi
      printf S > '\(startedPipe.path)'
      /bin/dd if='\(releasePipe.path)' bs=1 count=1 >/dev/null 2>&1
      /usr/bin/git "$@"
      status=$?
      /bin/rmdir '\(lock.path)'
      exit "$status"

      """.utf8
    ).write(to: wrapper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: wrapper.path
    )

    let manager = GitWorkspaceManager(executableURL: wrapper)
    let first = Task {
      try await manager.currentSHA(at: repository)
    }
    #expect(try await readPipeByte(startedDescriptor) == 83)

    let second = Task {
      try await manager.currentSHA(at: repository)
    }
    try writePipeByte(releaseDescriptor)
    let firstSHA = try await first.value
    #expect(try await readPipeByte(startedDescriptor) == 83)
    try writePipeByte(releaseDescriptor)
    let secondSHA = try await second.value
    #expect(firstSHA == secondSHA)
  }

  @Test("A repository operation rejects overlapping Git commands while suspended")
  func repositoryOperationRejectsOverlap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-git-operation-\(UUID().uuidString)",
      isDirectory: true
    )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let manager = GitWorkspaceManager()
    let expectedSHA = try await manager.ensureRepository(at: repository)
    let gate = GitRepositoryOperationGate()
    let operation = Task {
      try await manager.withRepositoryOperation(at: repository) {
        await gate.begin()
        await gate.waitForRelease()
        return try await manager.currentSHA(at: repository)
      }
    }
    await gate.waitUntilStarted()

    await #expect(throws: GitWorkspaceError.self) {
      _ = try await manager.currentSHA(at: repository)
    }

    await gate.release()
    #expect(try await operation.value == expectedSHA)
  }

  @Test("[V01] Refresh reads current accepted trunk and branch history without local scratch work")
  func v01RefreshReadsCurrentRepositoryState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-codebase-refresh-\(UUID().uuidString)",
      isDirectory: true
    )
    let repository = root.appendingPathComponent("product", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("Initial product\n".utf8).write(
      to: repository.appendingPathComponent("README.md")
    )
    let manager = GitWorkspaceManager()
    let initialSHA = try await manager.ensureRepository(at: repository)
    let initialSnapshot = try await manager.repositorySnapshot(at: repository)

    _ = try runGit(["checkout", "-b", "ticket/T7"], at: repository)
    try Data("Ticket change\n".utf8).write(
      to: repository.appendingPathComponent("ticket.txt")
    )
    _ = try runGit(["add", "ticket.txt"], at: repository)
    _ = try runGit(
      [
        "-c", "user.name=Fixture implementer",
        "-c", "user.email=fixture@example.com",
        "commit", "-m", "T7: prepare accepted change",
      ],
      at: repository
    )
    let ticketSHA = try runGit(["rev-parse", "HEAD"], at: repository)
    _ = try runGit(["checkout", "trunk"], at: repository)
    try Data("Accepted change\n".utf8).write(
      to: repository.appendingPathComponent("accepted.txt")
    )
    _ = try runGit(["add", "accepted.txt"], at: repository)
    _ = try runGit(
      [
        "-c", "user.name=Product owner",
        "-c", "user.email=owner@example.com",
        "commit", "-m", "Accept T7",
      ],
      at: repository
    )
    let acceptedSHA = try runGit(["rev-parse", "HEAD"], at: repository)
    try Data("Unpublished notes\n".utf8).write(
      to: repository.appendingPathComponent("scratch.txt")
    )

    let refreshed = try await manager.repositorySnapshot(at: repository)

    #expect(initialSnapshot.trunkSHA == initialSHA)
    #expect(refreshed.trunkSHA == acceptedSHA)
    #expect(refreshed.commits.first { $0.sha == acceptedSHA }?.isOnTrunk == true)
    #expect(refreshed.commits.first { $0.sha == ticketSHA }?.isOnTrunk == false)
    #expect(refreshed.branches.map(\.name) == ["ticket/T7"])
    #expect(refreshed.branches[0].headSHA == ticketSHA)
    #expect(refreshed.branches[0].aheadOfTrunk == 1)
    #expect(refreshed.branches[0].behindTrunk == 1)
    #expect(!refreshed.commits.contains { $0.subject.contains("Unpublished") })
  }

  private func readPipeByte(_ descriptor: Int32) async throws -> UInt8 {
    try await Task.detached {
      var byte: UInt8 = 0
      guard Darwin.read(descriptor, &byte, 1) == 1 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      return byte
    }.value
  }

  private func writePipeByte(_ descriptor: Int32) throws {
    var byte: UInt8 = 82
    guard Darwin.write(descriptor, &byte, 1) == 1 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
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
    let output =
      String(
        data: data,
        encoding: .utf8
      ) ?? ""
    guard process.terminationStatus == 0 else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: output)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private actor GitRepositoryOperationGate {
  private var didStart = false
  private var didRelease = false
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func begin() {
    didStart = true
    startContinuation?.resume()
    startContinuation = nil
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startContinuation = continuation
    }
  }

  func waitForRelease() async {
    guard !didRelease else { return }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func release() {
    didRelease = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
