import SpeditoCore
import Testing
@testable import SpeditoApp

@Suite("Ticket attention sound")
struct TicketAttentionSoundPolicyTests {
  @Test("A new Needs your input state plays the sound")
  func enteringAwaitingOwnerPlaysSound() {
    #expect(
      TicketAttentionSoundPolicy.shouldPlay(
        previousStatus: .running,
        newStatus: .awaitingOwner,
        isShuttingDown: false
      )
    )
  }

  @Test("Refreshing an existing Needs your input state stays quiet")
  func existingAwaitingOwnerStateStaysQuiet() {
    #expect(
      !TicketAttentionSoundPolicy.shouldPlay(
        previousStatus: .awaitingOwner,
        newStatus: .awaitingOwner,
        isShuttingDown: false
      )
    )
  }

  @Test("Other state changes stay quiet")
  func otherStateChangesStayQuiet() {
    #expect(
      !TicketAttentionSoundPolicy.shouldPlay(
        previousStatus: .running,
        newStatus: .failed,
        isShuttingDown: false
      )
    )
  }

  @Test("App shutdown does not start a sound")
  func appShutdownStaysQuiet() {
    #expect(
      !TicketAttentionSoundPolicy.shouldPlay(
        previousStatus: .running,
        newStatus: .awaitingOwner,
        isShuttingDown: true
      )
    )
  }
}
