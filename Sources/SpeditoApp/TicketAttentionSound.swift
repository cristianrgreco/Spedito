import AppKit
import SpeditoCore

@MainActor
protocol TicketAttentionSoundPlaying: AnyObject {
  func play()
}

@MainActor
final class BundledTicketAttentionSoundPlayer: TicketAttentionSoundPlaying {
  private lazy var sound: NSSound? = {
    guard
      let url = SpeditoResources.url(
        forResource: "ticket-attention",
        withExtension: "wav"
      )
    else {
      return nil
    }
    return NSSound(contentsOf: url, byReference: true)
  }()

  func play() {
    guard let sound else { return }
    if sound.isPlaying {
      sound.stop()
    }
    sound.play()
  }
}

struct TicketAttentionSoundPolicy {
  static func shouldPlay(
    previousStatus: AgentRunStatus,
    newStatus: AgentRunStatus,
    isShuttingDown: Bool
  ) -> Bool {
    !isShuttingDown
      && previousStatus != .awaitingOwner
      && newStatus == .awaitingOwner
  }
}
