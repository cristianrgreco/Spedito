import Testing

@testable import SpeditoApp

@Suite("Codex connection presentation")
struct CodexConnectionPresentationTests {
  @Test("Retry is offered only when a connection can be attempted again")
  func retryVisibility() {
    #expect(CodexConnectionState.notChecked.showsRetryAction)
    #expect(CodexConnectionState.unavailable("Missing").showsRetryAction)
    #expect(CodexConnectionState.incompatible("Unsupported").showsRetryAction)
    #expect(!CodexConnectionState.checking.showsRetryAction)
    #expect(
      !CodexConnectionState.connected(
        version: "1.2.3",
        userAgent: "codex-cli/1.2.3"
      ).showsRetryAction
    )
  }
}
