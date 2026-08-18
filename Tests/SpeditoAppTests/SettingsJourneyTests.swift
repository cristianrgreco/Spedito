import Foundation
import SpeditoCore
import SpeditoTestSupport
import Testing

@testable import SpeditoApp

@Suite("Product and Codex settings journeys", .serialized)
@MainActor
struct SettingsJourneyTests {
  /// Existing partial coverage:
  /// - `SQLiteStoreTests.durableWorkflow`
  /// - `OwnerNotificationPresentationTests`
  /// This journey adds the application save boundary, cancellation policy, and fresh-instance
  /// recovery of the same Product name used by navigation and notification presentation.
  @Test("S01 Product rename saves durably while cancellation leaves the name unchanged")
  func s01ProductRenameSaveAndCancel() async throws {
    let fixture = try SettingsJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let product = try await registry.createProduct(name: "Original product")
    let model = AppModel(storeRegistry: registry, selectedProductID: product.id)
    await model.reload()

    #expect(
      ProductNameEditPolicy.resolve(draftName: "Discarded name", action: .cancel) == .cancel
    )
    #expect(model.selectedProduct?.name == "Original product")
    #expect(try await registry.fetchProducts().first?.name == "Original product")

    let resolution = ProductNameEditPolicy.resolve(
      draftName: "  Renamed product  ",
      action: .save
    )
    guard case .save(let committedName) = resolution else {
      Issue.record("Expected a valid Product name to produce a save command")
      return
    }
    #expect(await model.updateProductDetails(name: committedName))
    #expect(model.products.first?.name == "Renamed product")

    let notification = OwnerNotification(
      productID: product.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .ticket, id: UUID()),
      title: "A reply is ready",
      body: "Review the durable result."
    )
    let presentation = OwnerNotificationPresentation(
      notification: notification,
      productName: try #require(model.products.first).name
    )
    #expect(presentation.productName == "Renamed product")

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }

    let recoveredRegistry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    #expect(try await recoveredRegistry.fetchProducts().first?.name == "Renamed product")
    for store in recoveredRegistry.allStores {
      await store.close()
    }
  }

  /// Existing partial coverage:
  /// - `RemoteRepositoryAppModelTests.r12ObservedTargetChoice`
  /// - `SQLiteStoreTests.productArchiveAndRestorePreserveHistory`
  /// This journey adds one confirmation policy for every destructive Product setting and proves
  /// archival preserves the Product's exact repository and work-log evidence.
  @Test("S03 destructive Product settings require confirmation and preserve local history")
  func s03DestructiveSettingsPreserveLocalHistory() async throws {
    for setting in [
      DestructiveProductSetting.archiveProduct,
      .cancelGitHubSetup,
      .disconnectGitHub,
      .signOutGitHub,
    ] {
      #expect(
        DestructiveProductSettingConfirmationPolicy.command(setting, confirmed: false) == nil
      )
      #expect(
        DestructiveProductSettingConfirmationPolicy.command(setting, confirmed: true) == setting
      )
    }

    let fixture = try SettingsJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let model = AppModel(storeRegistry: registry)
    #expect(await model.createProductAndSelect(.blank(name: "Durable settings")))
    let product = try #require(model.selectedProduct)
    let store = try #require(registry.store(for: product.id))
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Preserve this work"
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: CommentAuthorKind.owner,
      authorName: "Me",
      body: "This history must survive destructive settings."
    )
    let workspaceURL = registry.productWorkspacesRootURL.appendingPathComponent(
      product.id.uuidString,
      isDirectory: true
    )
    let originalSHA = try await GitWorkspaceManager().currentSHA(at: workspaceURL)

    #expect(await model.archiveSelectedProduct())
    #expect(FileManager.default.fileExists(atPath: workspaceURL.path))
    #expect(try await GitWorkspaceManager().currentSHA(at: workspaceURL) == originalSHA)
    #expect(try await store.fetchWorkItems(productID: product.id).map(\.id) == [item.id])
    #expect(
      try await store.fetchComments(workItemID: item.id).map(\.body)
        == ["This history must survive destructive settings."]
    )

    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  /// Existing partial coverage:
  /// - `SQLiteStoreTests.customPersonas`
  /// This journey adds the model/effort compatibility boundary used by both blank and templated
  /// team-member creation, then proves only the custom member can be removed.
  @Test("S05 custom team members use compatible runtime settings and only custom members remove")
  func s05CustomTeamMemberRuntimeAndRemoval() async throws {
    let modelOption = CodexModelOption(
      id: "model-a",
      model: "model-a",
      displayName: "Model A",
      description: "Fixture model",
      isDefault: true,
      defaultReasoningEffort: "medium",
      supportedReasoningEfforts: [
        CodexReasoningEffortOption(id: "low", description: "Low"),
        CodexReasoningEffortOption(id: "medium", description: "Medium"),
      ]
    )
    #expect(
      CustomTeamMemberRuntimePolicy.compatibleEffort(
        requestedEffort: "low",
        model: modelOption
      ) == "low"
    )
    #expect(
      CustomTeamMemberRuntimePolicy.compatibleEffort(
        requestedEffort: "unsupported",
        model: modelOption
      ) == "medium"
    )

    let fixture = try SettingsJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let product = try await registry.createProduct(name: "Custom team")
    let store = try #require(registry.store(for: product.id))
    _ = try await store.seedDefaultProfiles(productID: product.id)
    let builtIn = try #require(try await store.fetchAgentProfiles(productID: product.id).first)
    let custom = try await store.createCustomAgentProfile(
      productID: product.id,
      name: "Security reviewer",
      capability: AgentRole.reviewer,
      model: modelOption.model,
      reasoningEffort: CustomTeamMemberRuntimePolicy.compatibleEffort(
        requestedEffort: "unsupported",
        model: modelOption
      ),
      instructions: "Review the threat model."
    )
    #expect(!custom.isBuiltIn)
    #expect(custom.reasoningEffort == "medium")
    await #expect(throws: (any Error).self) {
      try await store.archiveCustomAgentProfile(id: builtIn.id)
    }
    try await store.archiveCustomAgentProfile(id: custom.id)
    let activeProfiles = try await store.fetchAgentProfiles(productID: product.id)
    #expect(activeProfiles.contains { $0.id == builtIn.id })
    #expect(!activeProfiles.contains { $0.id == custom.id })

    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  /// Existing partial coverage:
  /// - `CodexInstallationTests.discovery`
  /// - `CodexInstallationTests.preferencesRoundTrip`
  /// - `CodexConnectionPresentationTests.retryAvailability`
  /// This journey adds explicit selection/removal through AppModel and the active-work gate.
  @Test("S06 Codex installations select remove block during work and retry incompatibility")
  func s06CodexInstallationLifecycle() async throws {
    let suiteName = "SettingsJourneyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = CodexInstallationPreferences(defaults: defaults)
    let first = StoredCodexInstallation(
      id: "custom-a",
      name: "Custom A",
      executablePath: "/tmp/custom-a/codex"
    )
    let second = StoredCodexInstallation(
      id: "custom-b",
      name: "Custom B",
      executablePath: "/tmp/custom-b/codex"
    )
    preferences.saveCustomInstallations([first, second])
    preferences.saveSelectedInstallationID(first.id)

    let model = AppModel(
      store: nil,
      codexTransportFactory: { _ in
        throw CodexRuntimeError.missingRequiredFeature(
          name: "structured output",
          path: second.executablePath
        )
      },
      codexInstallationPreferences: preferences
    )
    #expect(model.selectedCodexInstallationID == first.id)
    #expect(model.codexInstallations.map(\.id).contains(first.id))
    #expect(CodexInstallationChangePolicy.isAllowed(isShuttingDown: false, hasActiveWork: false))
    #expect(!CodexInstallationChangePolicy.isAllowed(isShuttingDown: false, hasActiveWork: true))
    #expect(!CodexInstallationChangePolicy.isAllowed(isShuttingDown: true, hasActiveWork: false))

    await model.selectCodexInstallation(id: second.id)
    #expect(model.selectedCodexInstallationID == second.id)
    #expect(preferences.selectedInstallationID() == second.id)
    guard case .incompatible = model.codexConnectionState else {
      Issue.record("Expected the selected incompatible Codex installation to stay retryable")
      return
    }

    await model.retryCodexConnection()
    guard case .incompatible = model.codexConnectionState else {
      Issue.record("Expected retry to re-check and preserve the incompatible state")
      return
    }

    await model.removeCodexInstallation(id: second.id)
    #expect(!preferences.customInstallations().contains { $0.id == second.id })
    #expect(!model.codexInstallations.contains { $0.id == second.id })
    #expect(model.selectedCodexInstallationID != second.id)
    await model.shutdown()
  }
}

private struct SettingsJourneyFixture {
  let directoryURL: URL
  let workspacesURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-settings-journeys-\(UUID())",
        isDirectory: true
      )
    workspacesURL = directoryURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
