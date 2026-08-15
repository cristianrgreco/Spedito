import Foundation
import SpeditoCore

@MainActor
func makeAppOwnerNotificationAdapters() -> (
  soundPlayer: any OwnerNotificationSoundPlaying,
  systemNotifier: any OwnerNotificationSystemNotifying
) {
  #if DEBUG
    if UIFixtureRuntime.isEnabled {
      return (
        UIFixtureOwnerNotificationSoundPlayer(),
        UIFixtureOwnerNotificationSystemNotifier()
      )
    }
  #endif
  return (BundledOwnerNotificationSoundPlayer(), MacOSOwnerNotificationNotifier())
}

@MainActor
func makeAppRemoteRepositoryService(
  registry: ProductStoreRegistry,
  gitWorkspaceManager: GitWorkspaceManager,
  workspacesRootURL: URL
) -> any GitHubRemoteRepositoryServing {
  #if DEBUG
    if UIFixtureRuntime.isEnabled {
      return UIFixtureGitHubRemoteRepositoryService()
    }
  #endif
  return GitHubRemoteRepositoryService(
    configuration: .current(),
    git: gitWorkspaceManager,
    storeProvider: { productID in
      await registry.store(for: productID)
    },
    storesProvider: {
      await registry.allStores
    },
    workspaceProvider: { productID in
      workspacesRootURL.appendingPathComponent(
        productID.uuidString,
        isDirectory: true
      )
    }
  )
}

@MainActor
func appApplicationSupportURL() throws -> URL {
  #if DEBUG
    if let fixtureURL = UIFixtureRuntime.applicationSupportURL {
      return fixtureURL
    }
  #endif
  guard
    let root = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
  else {
    throw CocoaError(.fileNoSuchFile)
  }
  return try AppModel.migratedApplicationSupportURL(in: root)
}
