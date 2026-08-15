import Foundation
import SpeditoCore

struct GitHubRepositoryImportAccessDestination: Equatable {
  let installationID: Int64?
  let title: String
  let url: URL
}

enum GitHubRepositoryImportAccessPresentation {
  static func resolve(
    installations: [GitHubInstallation],
    appSlug: String
  ) -> [GitHubRepositoryImportAccessDestination] {
    if !installations.isEmpty {
      let includesAccountName = installations.count > 1
      return installations.compactMap { installation in
        guard
          let url = URL(
            string: "https://github.com/settings/installations/\(installation.id)"
          )
        else { return nil }
        return GitHubRepositoryImportAccessDestination(
          installationID: installation.id,
          title: includesAccountName
            ? "Manage repository access for \(installation.accountLogin)"
            : "Manage repository access",
          url: url
        )
      }
    }
    guard !appSlug.isEmpty,
      let url = URL(string: "https://github.com/apps/\(appSlug)/installations/new")
    else { return [] }
    return [
      GitHubRepositoryImportAccessDestination(
        installationID: nil,
        title: "Choose repositories on GitHub",
        url: url
      )
    ]
  }
}
