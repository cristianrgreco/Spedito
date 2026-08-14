import Foundation
import Testing

@testable import SpeditoCore

@Suite("Git credential session", .serialized)
struct GitCredentialSessionTests {
  @Test("Default credential socket fits the macOS Unix-domain path limit")
  func defaultCredentialSocketPath() async throws {
    let session = GitCredentialSession()
    let arguments = try await session.withCredential(
      repositoryURL: URL(string: "https://github.com/example/private-repository.git")!,
      accessToken: "test-access-token"
    ) { configuration in
      configuration.gitConfigurationArguments
    }
    await session.shutdown()

    #expect(arguments.contains("credential.helper="))
    #expect(
      arguments.contains { argument in
        argument.hasPrefix("credential.helper=cache --socket=")
      }
    )
  }
}
