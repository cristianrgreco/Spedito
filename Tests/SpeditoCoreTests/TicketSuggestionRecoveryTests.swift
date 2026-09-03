import Foundation
import SpeditoCore
import Testing

@Suite("Ticket suggestion recovery")
struct TicketSuggestionRecoveryTests {
  private let policy = TicketSuggestionRecoveryPolicy()

  @Test("An orphaned interrupted generation resumes automatically")
  func generatingSessionResumes() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .generating
    )

    #expect(
      policy.action(for: session, hasLiveRun: false) == .resumeInterruptedGeneration
    )
  }

  @Test("A generating session with a live planning run is left alone")
  func liveRunIsNotRecovered() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .generating
    )

    #expect(policy.action(for: session, hasLiveRun: true) == .none)
  }

  @Test("The legacy relaunch failure retries automatically")
  func legacyInterruptionRetries() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .failed,
      errorMessage: TicketSuggestionRecoveryPolicy.legacyInterruptionMessage
    )

    #expect(policy.action(for: session, hasLiveRun: false) == .retryLegacyInterruption)
  }

  @Test("A genuine planning failure remains owner-controlled")
  func genuineFailureDoesNotLoop() {
    let session = SuggestionSession(
      productID: UUID(),
      epicID: UUID(),
      status: .failed,
      errorMessage: "The business analyst returned an invalid proposal."
    )

    #expect(policy.action(for: session, hasLiveRun: false) == .none)
  }
}
