import Foundation
import SpeditoCore
import Testing

@Suite("Ticket suggestion recovery")
struct TicketSuggestionRecoveryTests {
  private let policy = TicketSuggestionRecoveryPolicy()

  @Test("An interrupted generation resumes automatically")
  func generatingSessionResumes() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .generating
    )

    #expect(policy.action(for: session) == .resumeInterruptedGeneration)
  }

  @Test("The legacy relaunch failure retries automatically")
  func legacyInterruptionRetries() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .failed,
      errorMessage: TicketSuggestionRecoveryPolicy.legacyInterruptionMessage
    )

    #expect(policy.action(for: session) == .retryLegacyInterruption)
  }

  @Test("A genuine planning failure remains owner-controlled")
  func genuineFailureDoesNotLoop() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .failed,
      errorMessage: "The Business Analyst returned an invalid proposal."
    )

    #expect(policy.action(for: session) == .none)
  }
}
