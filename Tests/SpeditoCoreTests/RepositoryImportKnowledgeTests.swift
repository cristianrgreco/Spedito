import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

@Suite("Repository import and knowledge", .serialized)
struct RepositoryImportKnowledgeTests {
  @Test("Public repository links are canonical and exclude local or credential-bearing URLs")
  func publicRepositoryURLValidation() throws {
    let source = try PublicGitRepositoryURL(" HTTPS://GitHub.com/example/Product.git/ ")
    #expect(source.url.absoluteString == "https://github.com/example/Product.git")
    #expect(source.suggestedProductName == "Product")

    for invalid in [
      "http://github.com/example/product.git",
      "https://user:token@github.com/example/product.git",
      "https://github.com/example/product.git?token=value",
      "https://github.com/example/product.git#readme",
      "https://localhost/example/product.git",
      "https://127.0.0.1/example/product.git",
      "https://10.0.0.2/example/product.git",
      "https://[::1]/example/product.git",
      "https://github.com:8443/example/product.git",
      "https://example.com/example/product.git",
    ] {
      #expect(throws: PublicGitRepositoryURL.ValidationError.self) {
        try PublicGitRepositoryURL(invalid)
      }
    }
  }

  @Test("Repository snapshots exclude denied and non-regular paths while preserving unusual names")
  func sanitizedSnapshot() async throws {
    let root = temporaryDirectory(named: "snapshot")
    let repository = root.appendingPathComponent("repository", isDirectory: true)
    let snapshotURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("# Product\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try Data("TOKEN=not-for-analysis\n".utf8).write(
      to: repository.appendingPathComponent(".env")
    )
    let unusualName = "notes\nwith-tab\t.txt"
    try Data("bounded evidence\n".utf8).write(
      to: repository.appendingPathComponent(unusualName)
    )
    try FileManager.default.createSymbolicLink(
      at: repository.appendingPathComponent("outside-link"),
      withDestinationURL: URL(fileURLWithPath: "/tmp")
    )

    let manager = GitWorkspaceManager()
    let sha = try await manager.ensureRepository(at: repository)
    let snapshot = try await manager.prepareRepositoryAnalysisSnapshot(
      repositoryURL: repository,
      sha: sha,
      destinationURL: snapshotURL
    )

    #expect(snapshot.allowedPaths == ["README.md", unusualName])
    let productID = UUID()
    let run = RepositoryKnowledgeRun(
      productID: productID,
      attempt: 1,
      analyzedSHA: sha,
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    let prompt = try CodexRepositoryKnowledgeAnalyzer.prompt(
      run: run,
      pages: [
        KnowledgePage(
          productID: productID,
          title: "Overview",
          slug: "overview"
        )
      ],
      snapshot: snapshot
    )
    #expect(prompt.contains(#""path":"README.md""#))
    #expect(prompt.contains(#""numberedText":"1:# Product\n2:""#))
    #expect(prompt.contains("| empty | starter"))
    #expect(prompt.contains("Prioritize the canonical starter pages"))
    let reviewerPrompt = try CodexRepositoryKnowledgeReviewer.prompt(
      run: run,
      drafts: [
        RepositoryKnowledgeDraft(
          runID: run.id,
          operation: .create,
          title: "Product purpose",
          proposedBodyMarkdown: "Hands-off product behavior.",
          rationale: "README evidence",
          evidence: [.init(path: "README.md", startLine: 1, endLine: 1)]
        )
      ],
      launchProposal: nil,
      snapshot: snapshot
    )
    #expect(reviewerPrompt.contains(#""path":"README.md""#))
    #expect(reviewerPrompt.contains(#""numberedText":"1:# Product\n2:""#))
    #expect(!prompt.contains("not-for-analysis"))
    #expect(
      !FileManager.default.fileExists(atPath: snapshotURL.appendingPathComponent(".env").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: snapshotURL.appendingPathComponent("outside-link").path
      )
    )
    #expect(
      try String(contentsOf: snapshotURL.appendingPathComponent(unusualName), encoding: .utf8)
        == "bounded evidence\n"
    )
    try GitWorkspaceManager.removeRepositoryAnalysisSnapshot(at: snapshotURL)
    #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  }

  @Test("Imported launch evidence stays valid after knowledge advances trunk")
  func importedLaunchRevisionValidation() async throws {
    let root = temporaryDirectory(named: "launch-revision")
    let repository = root.appendingPathComponent("repository", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let readme = repository.appendingPathComponent("README.md")
    try Data("# Imported app\n".utf8).write(to: readme)
    let manager = GitWorkspaceManager()
    let importedSHA = try await manager.ensureRepository(at: repository)

    try Data("# Imported app\n\nVerified Product knowledge.\n".utf8).write(to: readme)
    let advancedSHA = try await manager.checkpointTrunk(
      at: repository,
      message: "Publish imported product knowledge"
    )
    #expect(advancedSHA != importedSHA)

    await #expect(throws: GitWorkspaceError.self) {
      try await manager.validateRepositoryAnalysisRevision(
        at: repository,
        sha: importedSHA,
        evidence: [.init(path: "README.md")]
      )
    }
    try await manager.validateRepositoryAnalysisRevision(
      at: repository,
      sha: importedSHA,
      evidence: [.init(path: "README.md")],
      requiresTrunkRevisionMatch: false
    )
  }

  @Test("An interrupted legacy knowledge projection checkpoints only its prepared files")
  func legacyProtectedKnowledgeCheckpoint() async throws {
    let root = temporaryDirectory(named: "checkpoint")
    let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    try Data("# Imported product\n".utf8).write(
      to: repositoryURL.appendingPathComponent("README.md")
    )
    let manager = GitWorkspaceManager()
    let analyzedSHA = try await manager.ensureRepository(at: repositoryURL)
    let productID = UUID()
    let section = KnowledgePage(
      productID: productID,
      title: "Features",
      slug: "features",
      bodyMarkdown: "# Features\n",
      kind: .section
    )
    let page = KnowledgePage(
      productID: productID,
      parentID: section.id,
      title: "Imported behavior",
      slug: "imported-behavior",
      bodyMarkdown: "# Imported behavior\n\nEvidence-backed behavior.\n",
      verificationStatus: .verified
    )
    let projection = RepositoryKnowledgePublicationProjection(
      pages: [section, page],
      changedPageIDs: [page.id]
    )
    let repository = ProductRepository(
      productID: productID,
      originURL: try #require(URL(string: "https://example.com/product.git")),
      sourceDefaultBranch: "main",
      importedSHA: analyzedSHA
    )

    let exported = try await RepositoryKnowledgeExporter.export(
      projection: projection,
      changedPageIDs: [page.id],
      repository: repository,
      workspaceURL: repositoryURL,
      gitWorkspaceManager: manager
    )
    #expect(
      Set(exported.touchedPaths)
        == ["knowledge/features/index.md", "knowledge/features/imported-behavior.md"]
    )
    let expected = Dictionary(
      uniqueKeysWithValues: exported.touchedPaths.map { ($0, exported.expectedContents[$0]!) }
    )
    let checkpointSHA = try await manager.checkpointRepositoryKnowledge(
      at: repositoryURL,
      analyzedSHA: analyzedSHA,
      expectedFiles: expected
    )

    #expect(try await manager.acceptedTrunkSHA(at: repositoryURL) == checkpointSHA)
    #expect(
      try runGit(["show", "-s", "--format=%P", checkpointSHA], at: repositoryURL) == analyzedSHA)
    #expect(
      try runGit(["show", "-s", "--format=%an <%ae>", checkpointSHA], at: repositoryURL)
        == "Spedito <spedito@localhost>")
    #expect(try runGit(["remote"], at: repositoryURL).isEmpty)
  }

  @Test("Version one stores migrate and verified publication is atomic and durable")
  func schemaMigrationAndPublication() async throws {
    let root = temporaryDirectory(named: "migration")
    let databaseURL = root.appendingPathComponent("product.sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    try createVersionOneDatabase(at: databaseURL)

    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Imported product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyzer = try #require(profiles.first { $0.role == .businessAnalyst })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let home = try #require(pages.first { $0.slug == "home" })
    let repository = ProductRepository(
      productID: product.id,
      originURL: try #require(URL(string: "https://example.com/imported.git")),
      sourceDefaultBranch: "main",
      importedSHA: String(repeating: "a", count: 40)
    )
    try await store.createProductRepository(repository)
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      analyzedSHA: repository.importedSHA,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
    try await store.createRepositoryKnowledgeRun(run)
    let draft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .update,
      targetPageID: home.id,
      basePageTitle: home.title,
      basePageBodyMarkdown: home.bodyMarkdown,
      basePageUpdatedAt: home.updatedAt,
      title: home.title,
      proposedBodyMarkdown: "# Product home\n\nVerified from the imported repository.\n",
      rationale: "Captures the imported product purpose",
      evidence: [.init(path: "README.md", startLine: 1, endLine: 3)]
    )
    let launchProposal = RepositoryLaunchProposal(
      runID: run.id,
      specification: DemoLaunchSpecification(
        title: "Imported app",
        preparationCommands: [
          DemoCommand(
            executable: "scripts/build.sh",
            arguments: ["DEBUG"],
            timeoutSeconds: 900
          )
        ],
        presentation: DemoPresentation(
          kind: .macApplication,
          path: ".build/Build/Products/Debug/Imported.app"
        )
      ),
      evidence: [.init(path: "scripts/build.sh", startLine: 1, endLine: 20)]
    )
    _ = try await store.recordRepositoryKnowledgeAnalysis(
      runID: run.id,
      summary: "One bounded update",
      drafts: [draft],
      launchProposal: launchProposal,
      analyzerThreadID: "analyzer-thread",
      analyzerTurnID: "analyzer-turn"
    )
    _ = try await store.recordRepositoryKnowledgeReview(
      runID: run.id,
      summary: "Evidence supports the update",
      decisions: [
        .init(draftID: draft.id, approved: true, explanation: "README supports the claim")
      ],
      launchDecision: .init(
        proposalID: launchProposal.id,
        approved: true,
        explanation: "The build script supports the typed macOS app recipe"
      ),
      reviewerThreadID: "reviewer-thread",
      reviewerTurnID: "reviewer-turn"
    )

    await #expect(throws: PersistenceError.self) {
      try await store.createKnowledgePage(
        productID: product.id,
        parentID: nil,
        title: "Racing edit"
      )
    }
    _ = try await store.recordRepositoryKnowledgeExport(runID: run.id, paths: [])
    let completed = try await store.finalizeRepositoryKnowledgePublication(runID: run.id)
    #expect(completed.status == .completed)
    let updatedHome = try #require(
      try await store.fetchKnowledgePages(productID: product.id).first { $0.id == home.id }
    )
    #expect(updatedHome.verificationStatus == .verified)
    #expect(updatedHome.sourceRepositoryKnowledgeRunID == run.id)
    #expect(updatedHome.bodyMarkdown.contains("Verified from the imported repository"))
    #expect(try await store.fetchKnowledgePageRevisions(pageID: home.id).count == 2)

    let launchOnlyRun = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 2,
      purpose: .importedAppLaunch,
      analyzedSHA: repository.importedSHA,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
    try await store.createRepositoryKnowledgeRun(launchOnlyRun)
    let launchOnlyProposal = RepositoryLaunchProposal(
      runID: launchOnlyRun.id,
      specification: launchProposal.specification,
      evidence: launchProposal.evidence
    )
    _ = try await store.recordRepositoryKnowledgeAnalysis(
      runID: launchOnlyRun.id,
      summary: "Launch recipe only",
      drafts: [],
      launchProposal: launchOnlyProposal,
      analyzerThreadID: "launch-analyzer-thread",
      analyzerTurnID: "launch-analyzer-turn"
    )
    _ = try await store.recordRepositoryKnowledgeReview(
      runID: launchOnlyRun.id,
      summary: "Launch recipe independently verified",
      decisions: [],
      launchDecision: .init(
        proposalID: launchOnlyProposal.id,
        approved: true,
        explanation: "The typed recipe matches the imported revision"
      ),
      reviewerThreadID: "launch-reviewer-thread",
      reviewerTurnID: "launch-reviewer-turn"
    )
    let completedLaunchOnlyRun = try await store.finalizeRepositoryKnowledgePublication(
      runID: launchOnlyRun.id
    )
    #expect(completedLaunchOnlyRun.status == .completed)
    #expect(try await store.fetchKnowledgePageRevisions(pageID: home.id).count == 2)
    #expect(
      try await store.fetchKnowledgePages(productID: product.id)
        .first { $0.id == home.id }?
        .sourceRepositoryKnowledgeRunID == run.id
    )

    let remoteConnection = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .importedSource,
        accountID: UUID(),
        installationID: 7,
        repositoryID: 42,
        owner: "example",
        name: "imported",
        fullName: "example/imported",
        canonicalHTTPSURL: URL(string: "https://github.com/example/imported.git"),
        isPrivate: true,
        defaultBranch: "main",
        permissions: RemoteRepositoryPermissions(
          metadataRead: true,
          contentsWrite: true,
          pullRequestsWrite: true,
          workflowsWrite: true
        ),
        status: .connected
      )
    )
    await store.close()
    let reopened = try SQLiteStore(url: databaseURL)
    let recoveredRepository = try #require(
      try await reopened.fetchProductRepository(productID: product.id)
    )
    #expect(recoveredRepository.productID == repository.productID)
    #expect(recoveredRepository.originURL == repository.originURL)
    #expect(recoveredRepository.sourceDefaultBranch == repository.sourceDefaultBranch)
    #expect(recoveredRepository.importedSHA == repository.importedSHA)
    #expect(recoveredRepository.protectedKnowledgePaths == repository.protectedKnowledgePaths)
    #expect(recoveredRepository.blocksKnowledgeExport == repository.blocksKnowledgeExport)
    #expect(
      try await reopened.fetchLatestRepositoryKnowledgeRun(productID: product.id)?.status
        == .completed
    )
    let importedLaunch = try #require(
      try await reopened.fetchImportedAppLaunch(productID: product.id)
    )
    #expect(importedLaunch.id == launchOnlyProposal.id)
    #expect(importedLaunch.runID == launchOnlyRun.id)
    #expect(importedLaunch.revisionSHA == repository.importedSHA)
    #expect(importedLaunch.specification == launchOnlyProposal.specification)
    let recoveredConnection = try #require(
      try await reopened.fetchRemoteRepositoryConnection(productID: product.id)
    )
    #expect(recoveredConnection.id == remoteConnection.id)
    #expect(recoveredConnection.status == .connected)
    #expect(recoveredConnection.repositoryID == 42)
    await reopened.close()
  }

  @Test("Analyzer and reviewer reject unknown fields and incomplete independent decisions")
  func strictStructuredResponses() throws {
    let productID = UUID()
    let run = RepositoryKnowledgeRun(
      productID: productID,
      attempt: 1,
      analyzedSHA: String(repeating: "b", count: 40),
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    let page = KnowledgePage(
      productID: productID,
      title: "Home",
      slug: "home",
      bodyMarkdown: "# Home\n"
    )
    let snapshot = RepositoryAnalysisSnapshot(
      url: URL(fileURLWithPath: "/tmp/repository-snapshot"),
      analyzedSHA: run.analyzedSHA,
      allowedPaths: ["README.md"],
      integrityDigest: "digest"
    )
    let unknownFieldResponse = """
      {"summary":"bounded","drafts":[],"unexpected":true}
      """
    #expect(throws: RepositoryKnowledgeAnalysisError.self) {
      try CodexRepositoryKnowledgeAnalyzer.decode(
        unknownFieldResponse,
        run: run,
        pages: [page],
        snapshot: snapshot
      )
    }
    #expect(throws: RepositoryKnowledgeAnalysisError.self) {
      try CodexRepositoryKnowledgeAnalyzer.decode(
        "{\"summary\":\"No repository knowledge proposed\",\"drafts\":[]}",
        run: run,
        pages: [page],
        snapshot: snapshot
      )
    }

    let draft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .update,
      targetPageID: page.id,
      basePageTitle: page.title,
      basePageBodyMarkdown: page.bodyMarkdown,
      basePageUpdatedAt: page.updatedAt,
      title: page.title,
      proposedBodyMarkdown: "# Verified Home\n",
      rationale: "README evidence",
      evidence: [.init(path: "README.md")]
    )
    #expect(throws: RepositoryKnowledgeAnalysisError.self) {
      try CodexRepositoryKnowledgeReviewer.decode(
        "{\"summary\":\"checked\",\"decisions\":[]}",
        drafts: [draft]
      )
    }
  }

  @Test("Imported app launch recipes require exact analyzer evidence and independent approval")
  func importedAppLaunchReviewContract() throws {
    let root = temporaryDirectory(named: "launch-contract")
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appendingPathComponent("scripts", isDirectory: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try Data("#!/bin/bash\nxcodebuild\n".utf8).write(
      to: scripts.appendingPathComponent("build.sh")
    )

    let productID = UUID()
    let run = RepositoryKnowledgeRun(
      productID: productID,
      attempt: 1,
      analyzedSHA: String(repeating: "c", count: 40),
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    let architecture = KnowledgePage(
      productID: productID,
      title: "Architecture",
      slug: "architecture",
      bodyMarkdown: "# Architecture\n"
    )
    let features = KnowledgePage(
      productID: productID,
      title: "Features",
      slug: "features",
      kind: .section
    )
    let snapshot = RepositoryAnalysisSnapshot(
      url: root,
      analyzedSHA: run.analyzedSHA,
      allowedPaths: ["scripts/build.sh"],
      integrityDigest: "digest"
    )
    let analyzerResponse = """
      {
        "summary": "Found a documented macOS app build",
        "drafts": [{
          "operation": "update",
          "targetPageID": "\(architecture.id.uuidString)",
          "parentPageID": null,
          "title": "Architecture",
          "bodyMarkdown": "# Architecture\\n\\nNative macOS app.\\n",
          "rationale": "The build script identifies the native target",
          "evidence": [{
            "path": "scripts/build.sh",
            "startLine": 1,
            "endLine": 2
          }]
        }],
        "launchProposal": {
          "specification": {
            "schemaVersion": 1,
            "title": "Imported web app",
            "preparationCommands": [],
            "launchCommand": {
              "executable": "python3",
              "arguments": ["-m", "http.server", "{{PORT}}", "--bind", "127.0.0.1"],
              "workingDirectory": ".",
              "timeoutSeconds": 900
            },
            "portEnvironmentVariable": "PORT",
            "readiness": {
              "kind": "http",
              "path": "/",
              "timeoutSeconds": 30
            },
            "presentation": {
              "kind": "browser",
              "path": "/"
            }
          },
          "evidence": [{
            "path": "scripts/build.sh",
            "startLine": 1,
            "endLine": 2
          }]
        }
      }
      """
    let analysis = try CodexRepositoryKnowledgeAnalyzer.decode(
      analyzerResponse,
      run: run,
      pages: [architecture, features],
      snapshot: snapshot
    )
    let proposal = try #require(analysis.launchProposal)
    #expect(proposal.runID == run.id)
    #expect(proposal.specification.presentation.kind == .browser)
    #expect(proposal.evidence == [.init(path: "scripts/build.sh", startLine: 1, endLine: 2)])
    #expect(analysis.launchProposalIssue == nil)

    let absolutePathResponse = analyzerResponse.replacingOccurrences(
      of: #""workingDirectory": ".""#,
      with: #""workingDirectory": "\#(snapshot.url.path)""#
    )
    #expect(absolutePathResponse != analyzerResponse)
    let analysisWithUnsafeOptionalLaunch = try CodexRepositoryKnowledgeAnalyzer.decode(
      absolutePathResponse,
      run: run,
      pages: [architecture, features],
      snapshot: snapshot
    )
    #expect(analysisWithUnsafeOptionalLaunch.drafts.count == analysis.drafts.count)
    #expect(analysisWithUnsafeOptionalLaunch.launchProposal == nil)
    #expect(
      analysisWithUnsafeOptionalLaunch.launchProposalIssue?.contains(
        "demo paths must be relative"
      ) == true
    )
    #expect(
      CodexRepositoryKnowledgeAnalyzer.developerInstructions.contains(
        "must be relative to the repository root"
      )
    )
    #expect(
      CodexRepositoryKnowledgeAnalyzer.developerInstructions.contains(
        "launchCommand"
      )
    )
    let correctionPrompt = CodexRepositoryKnowledgeAnalyzer.launchCorrectionPrompt(
      reason: "app and artifact demos are opened directly"
    )
    #expect(correctionPrompt.contains("build-only"))
    #expect(correctionPrompt.contains("launchCommand must be null"))
    #expect(correctionPrompt.contains("must not open the app"))

    var macPayload = try #require(
      try JSONSerialization.jsonObject(with: Data(analyzerResponse.utf8))
        as? [String: Any]
    )
    var macLaunch = try #require(macPayload["launchProposal"] as? [String: Any])
    var macSpecification = try #require(macLaunch["specification"] as? [String: Any])
    macSpecification["title"] = "Imported macOS app"
    macSpecification["preparationCommands"] = [
      [
        "executable": "scripts/build.sh",
        "arguments": [],
        "workingDirectory": ".",
        "timeoutSeconds": 900,
      ]
    ]
    macSpecification.removeValue(forKey: "launchCommand")
    macSpecification.removeValue(forKey: "portEnvironmentVariable")
    macSpecification.removeValue(forKey: "readiness")
    macSpecification["presentation"] = [
      "kind": "mac_application",
      "path": ".build/Build/products/Debug/Imported.app",
    ]
    macLaunch["specification"] = macSpecification
    macPayload["launchProposal"] = macLaunch
    let macResponse = String(
      decoding: try JSONSerialization.data(withJSONObject: macPayload),
      as: UTF8.self
    )
    let macAnalysis = try CodexRepositoryKnowledgeAnalyzer.decode(
      macResponse,
      run: run,
      pages: [architecture, features],
      snapshot: snapshot
    )
    #expect(macAnalysis.launchProposal?.specification.presentation.kind == .macApplication)
    #expect(macAnalysis.launchProposalIssue == nil)

    let launchOnlyRun = RepositoryKnowledgeRun(
      productID: productID,
      attempt: 2,
      purpose: .importedAppLaunch,
      analyzedSHA: run.analyzedSHA,
      analyzerProfileID: run.analyzerProfileID,
      reviewerProfileID: run.reviewerProfileID
    )
    let launchOnlyPrompt = try CodexRepositoryKnowledgeAnalyzer.prompt(
      run: launchOnlyRun,
      pages: [architecture, features],
      snapshot: snapshot
    )
    #expect(launchOnlyPrompt.contains("Return an empty drafts array"))
    #expect(!launchOnlyPrompt.contains("propose at most 16 focused product knowledge drafts"))
    #expect(throws: RepositoryKnowledgeAnalysisError.self) {
      try CodexRepositoryKnowledgeAnalyzer.decode(
        analyzerResponse,
        run: launchOnlyRun,
        pages: [architecture, features],
        snapshot: snapshot
      )
    }
    var launchOnlyPayload = try #require(
      try JSONSerialization.jsonObject(with: Data(analyzerResponse.utf8))
        as? [String: Any]
    )
    launchOnlyPayload["drafts"] = [Any]()
    let launchOnlyResponse = String(
      decoding: try JSONSerialization.data(withJSONObject: launchOnlyPayload),
      as: UTF8.self
    )
    let launchOnlyAnalysis = try CodexRepositoryKnowledgeAnalyzer.decode(
      launchOnlyResponse,
      run: launchOnlyRun,
      pages: [architecture, features],
      snapshot: snapshot
    )
    #expect(launchOnlyAnalysis.drafts.isEmpty)
    #expect(launchOnlyAnalysis.launchProposal != nil)
    #expect(launchOnlyAnalysis.launchProposalIssue == nil)
    launchOnlyPayload["launchProposal"] = NSNull()
    let missingLaunchResponse = String(
      decoding: try JSONSerialization.data(withJSONObject: launchOnlyPayload),
      as: UTF8.self
    )
    let missingLaunchAnalysis = try CodexRepositoryKnowledgeAnalyzer.decode(
      missingLaunchResponse,
      run: launchOnlyRun,
      pages: [architecture, features],
      snapshot: snapshot
    )
    #expect(missingLaunchAnalysis.launchProposal == nil)
    #expect(
      missingLaunchAnalysis.launchProposalIssue
        == "The imported source check did not return a complete browser or macOS app recipe."
    )
    let launchOnlyProposal = try #require(launchOnlyAnalysis.launchProposal)
    let launchOnlyReview = try CodexRepositoryKnowledgeReviewer.decode(
      """
      {
        "summary": "The imported launch recipe is independently supported",
        "decisions": [],
        "launchDecision": {
          "proposalID": "\(launchOnlyProposal.id.uuidString)",
          "approved": true,
          "explanation": "The typed command and app path match the supplied script"
        }
      }
      """,
      drafts: [],
      launchProposal: launchOnlyProposal
    )
    #expect(launchOnlyReview.decisions.isEmpty)
    #expect(launchOnlyReview.launchDecision?.approved == true)

    let reviewResponse = """
      {
        "summary": "The repository supports the proposed launch",
        "decisions": [{
          "draftID": "\(analysis.drafts[0].id.uuidString)",
          "approved": true,
          "explanation": "The architecture claim is bounded by the build script"
        }],
        "launchDecision": {
          "proposalID": "\(proposal.id.uuidString)",
          "approved": true,
          "explanation": "The typed command and app path match the supplied script"
        }
      }
      """
    let review = try CodexRepositoryKnowledgeReviewer.decode(
      reviewResponse,
      drafts: analysis.drafts,
      launchProposal: proposal
    )
    #expect(review.launchDecision?.proposalID == proposal.id)
    #expect(review.launchDecision?.approved == true)

    #expect(throws: RepositoryKnowledgeAnalysisError.self) {
      try CodexRepositoryKnowledgeReviewer.decode(
        """
        {
          "summary": "No decision",
          "decisions": [{
            "draftID": "\(analysis.drafts[0].id.uuidString)",
            "approved": true,
            "explanation": "Checked"
          }],
          "launchDecision": null
        }
        """,
        drafts: analysis.drafts,
        launchProposal: proposal
      )
    }
  }

  @MainActor
  @Test("Importer activates complete history and durable provenance from staging")
  func stagedRepositoryImport() async throws {
    let root = temporaryDirectory(named: "import")
    let sourceRepository = root.appendingPathComponent("source", isDirectory: true)
    let productsRoot = root.appendingPathComponent("products", isDirectory: true)
    let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
    let gitWrapper = root.appendingPathComponent("git-wrapper")
    let gitArguments = root.appendingPathComponent("git-arguments.txt")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: sourceRepository.appendingPathComponent("knowledge", isDirectory: true),
      withIntermediateDirectories: true
    )
    _ = try runGit(["init", "-b", "develop"], at: sourceRepository)
    _ = try runGit(["config", "user.name", "Source Author"], at: sourceRepository)
    _ = try runGit(["config", "user.email", "source@example.com"], at: sourceRepository)
    try Data("# Existing product\n".utf8).write(
      to: sourceRepository.appendingPathComponent("README.md")
    )
    try Data("# Existing knowledge\n".utf8).write(
      to: sourceRepository.appendingPathComponent("knowledge/existing.md")
    )
    _ = try runGit(["add", "-A"], at: sourceRepository)
    _ = try runGit(["commit", "-m", "Initial product"], at: sourceRepository)
    try Data("second revision\n".utf8).write(
      to: sourceRepository.appendingPathComponent("history.txt")
    )
    _ = try runGit(["add", "-A"], at: sourceRepository)
    _ = try runGit(["commit", "-m", "Add history"], at: sourceRepository)
    let importedSHA = try runGit(["rev-parse", "HEAD"], at: sourceRepository)

    let publicURL = "https://github.com/example/imported-product.git"
    let wrapper = """
      #!/bin/sh
      is_clone=0
      last=
      for argument do
        [ "$argument" = "clone" ] && is_clone=1
        last="$argument"
      done
      if [ "$is_clone" = "1" ]; then
        printf '%s\\n' "$@" > "\(gitArguments.path)"
        /usr/bin/git clone --no-recurse-submodules --origin origin -- "\(sourceRepository.path)" "$last" || exit $?
        /usr/bin/git -C "$last" remote set-url origin "\(publicURL)" || exit $?
        exit 0
      fi
      exec /usr/bin/git "$@"

      """
    try Data(wrapper.utf8).write(to: gitWrapper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: gitWrapper.path
    )

    let registry = try ProductStoreRegistry(productWorkspacesRootURL: productsRoot)
    let manager = GitWorkspaceManager(executableURL: gitWrapper)
    let importer = ProductRepositoryImporter(
      registration: registry,
      gitWorkspaceManager: manager,
      stagingRootURL: stagingRoot
    )
    let credential = GitCredentialSessionConfiguration(
      socketPath: root.appendingPathComponent("credential.sock").path
    )
    let imported = try await importer.importProduct(
      name: "Imported product",
      from: PublicGitRepositoryURL(publicURL),
      credentialConfiguration: credential
    )
    let workspace = productsRoot.appendingPathComponent(
      imported.product.id.uuidString,
      isDirectory: true
    )

    #expect(imported.repository.importedSHA == importedSHA)
    #expect(imported.repository.sourceDefaultBranch == "develop")
    #expect(imported.repository.protectedKnowledgePaths.isEmpty)
    #expect(imported.knowledgeRun.status == .pendingAnalysis)
    #expect(try runGit(["rev-list", "--count", "trunk"], at: workspace) == "2")
    #expect(try runGit(["remote", "get-url", "origin"], at: workspace) == publicURL)
    #expect(try runGit(["branch", "--show-current"], at: workspace) == "trunk")
    #expect(try runGit(["status", "--porcelain"], at: workspace).isEmpty)
    let cloneArguments = try String(contentsOf: gitArguments, encoding: .utf8)
    #expect(cloneArguments.contains("credential.helper="))
    #expect(cloneArguments.contains("credential.useHttpPath=true"))
    let publicClone = try await manager.clonePublicRepository(
      from: URL(string: publicURL)!,
      to: root.appendingPathComponent("public-clone", isDirectory: true)
    )
    #expect(publicClone.importedSHA == importedSHA)
    let publicCloneArguments = try String(contentsOf: gitArguments, encoding: .utf8)
    #expect(!publicCloneArguments.contains("credential.useHttpPath=true"))
    #expect(registry.store(for: imported.product.id) != nil)
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent(".spedito/product.sqlite").path
      )
    )
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)).isEmpty
    )
  }

  @MainActor
  @Test("Activation failure removes only importer-owned staging and destination paths")
  func activationFailureCleansOwnedPaths() async throws {
    let root = temporaryDirectory(named: "import-activation-failure")
    let sourceRepository = root.appendingPathComponent("source", isDirectory: true)
    let productsRoot = root.appendingPathComponent("products", isDirectory: true)
    let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
    let gitWrapper = root.appendingPathComponent("git-wrapper")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: sourceRepository,
      withIntermediateDirectories: true
    )
    _ = try runGit(["init", "-b", "main"], at: sourceRepository)
    _ = try runGit(["config", "user.name", "Source Author"], at: sourceRepository)
    _ = try runGit(["config", "user.email", "source@example.com"], at: sourceRepository)
    try Data("# Product\n".utf8).write(
      to: sourceRepository.appendingPathComponent("README.md")
    )
    _ = try runGit(["add", "-A"], at: sourceRepository)
    _ = try runGit(["commit", "-m", "Initial product"], at: sourceRepository)

    let publicURL = "https://github.com/example/failing-activation.git"
    let wrapper = """
      #!/bin/sh
      is_clone=0
      last=
      for argument do
        [ "$argument" = "clone" ] && is_clone=1
        last="$argument"
      done
      if [ "$is_clone" = "1" ]; then
        /usr/bin/git clone --no-recurse-submodules --origin origin -- "\(sourceRepository.path)" "$last" || exit $?
        /usr/bin/git -C "$last" remote set-url origin "\(publicURL)" || exit $?
        exit 0
      fi
      exec /usr/bin/git "$@"

      """
    try Data(wrapper.utf8).write(to: gitWrapper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: gitWrapper.path
    )
    let registration = try FailingImportedProductRegistration(
      productWorkspacesRootURL: productsRoot
    )
    let importer = ProductRepositoryImporter(
      registration: registration,
      gitWorkspaceManager: GitWorkspaceManager(executableURL: gitWrapper),
      stagingRootURL: stagingRoot
    )

    await #expect(throws: ImportRegistrationFailure.self) {
      try await importer.importProduct(
        name: "Failing activation",
        from: PublicGitRepositoryURL(publicURL)
      )
    }

    #expect(registration.preparedProductID != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: productsRoot.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: sourceRepository.path))
  }


  @Test("Repository recovery is versioned and publication resumes in place")
  func recoveryPolicy() {
    let productID = UUID()
    let base = RepositoryKnowledgeRun(
      productID: productID,
      attempt: 1,
      analyzedSHA: "revision",
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    let policy = RepositoryKnowledgeRecoveryPolicy()
    #expect(policy.action(for: base) == .startPendingAnalysis)
    var interrupted = base
    interrupted.status = .interrupted
    #expect(policy.action(for: interrupted) == .createRecoveryAttempt)
    var publishing = base
    publishing.status = .publishing
    #expect(policy.action(for: publishing) == .resumePublication)
    #expect(
      policy.canExecute(.resumePublication, codexConnectionAvailable: false)
    )
    #expect(
      !policy.canExecute(.startPendingAnalysis, codexConnectionAvailable: false)
    )
    #expect(
      policy.canExecute(.startPendingAnalysis, codexConnectionAvailable: true)
    )
    var completed = base
    completed.status = .completed
    #expect(policy.action(for: completed) == .none)
    for _ in 0..<3 {
      #expect(policy.action(for: completed) == .none)
    }
    let overview = KnowledgePage(
      productID: productID,
      title: "Overview",
      slug: "overview"
    )
    #expect(
      policy.completionOutcome(
        for: completed,
        drafts: [],
        pages: [overview]
      ) == .noPublishableKnowledge
    )
    let rejectedDraft = RepositoryKnowledgeDraft(
      runID: completed.id,
      operation: .create,
      title: "Rejected",
      proposedBodyMarkdown: "Unsupported",
      rationale: "Could not verify",
      evidence: [.init(path: "README.md")],
      status: .rejected
    )
    #expect(
      policy.completionOutcome(
        for: completed,
        drafts: [rejectedDraft],
        pages: [overview]
      ) == .noPublishableKnowledge
    )
    let publishedOverview = KnowledgePage(
      productID: productID,
      title: "Overview",
      slug: "overview",
      sourceRepositoryKnowledgeRunID: completed.id
    )
    #expect(
      policy.completionOutcome(
        for: completed,
        drafts: [],
        pages: [publishedOverview]
      ) == .publishedKnowledge
    )
    var legacyLaunchFailure = base
    legacyLaunchFailure.status = .failed
    legacyLaunchFailure.errorMessage =
      "The demo could not be prepared safely: demo paths must be relative to the reviewed preview."
    #expect(policy.action(for: legacyLaunchFailure) == .none)
  }

  @Test("Repository analysis process environment is minimal and credential free")
  func repositoryAnalysisEnvironment() {
    let environment = CodexPermissionProfiles.repositoryAnalysisProcessEnvironment(
      inherited: [
        "HOME": "/tmp/home",
        "PATH": "/usr/bin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "AWS_SECRET_ACCESS_KEY": "secret",
        "GITHUB_TOKEN": "secret",
        "SSH_AUTH_SOCK": "/tmp/agent",
      ],
      developerDirectory: nil
    )
    #expect(environment["HOME"] == "/tmp/home")
    #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    #expect(environment["GITHUB_TOKEN"] == nil)
    #expect(environment["SSH_AUTH_SOCK"] == nil)

    let snapshot = URL(fileURLWithPath: "/tmp/exact-snapshot")
    let arguments = CodexPermissionProfiles.repositoryAnalysisAppServerArguments(
      snapshotURL: snapshot
    )
    #expect(arguments.contains { $0.contains(#"":root"="deny""#) })
    #expect(arguments.contains { $0.contains(snapshot.path) })
  }

  private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-\(name)-\(UUID().uuidString)", isDirectory: true)
  }

  private func createVersionOneDatabase(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let fixtureURL = try #require(
      Bundle.module.url(
        forResource: "product-schema-v1",
        withExtension: "sql"
      )
    )
    let sql = try String(contentsOf: fixtureURL, encoding: .utf8)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      throw PersistenceError.corruptData("Could not create the version one fixture")
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
      let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
      sqlite3_free(message)
      throw PersistenceError.corruptData(detail)
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
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: output)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct ImportRegistrationFailure: Error {}

@MainActor
private final class FailingImportedProductRegistration: ImportedProductRegistering {
  let productWorkspacesRootURL: URL
  private(set) var preparedProductID: UUID?

  init(productWorkspacesRootURL: URL) throws {
    self.productWorkspacesRootURL = productWorkspacesRootURL
    try FileManager.default.createDirectory(
      at: productWorkspacesRootURL,
      withIntermediateDirectories: true
    )
  }

  func prepareImportedProduct(
    name: String,
    id: UUID,
    workspaceURL: URL,
    repository: ProductRepository
  ) async throws -> Product {
    _ = (workspaceURL, repository)
    preparedProductID = id
    return Product(id: id, name: name)
  }

  func registerPreparedProduct(id: UUID) async throws -> ImportedProduct {
    _ = id
    throw ImportRegistrationFailure()
  }
}
