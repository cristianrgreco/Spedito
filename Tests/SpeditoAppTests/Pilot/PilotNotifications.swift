import Foundation

@testable import SpeditoApp

/// Captures the alerts Spedito would raise instead of posting them to macOS.
///
/// `UNUserNotificationCenter` requires a bundled process, and the pilot runs
/// under the test helper. Recording them is also more useful than posting them:
/// every alert the owner would have received becomes evidence in the journal,
/// and its wording goes through the same convention checks as the rest of the
/// owner-facing surface.
@MainActor
final class PilotNotificationRecorder: OwnerNotificationSystemNotifying {
  private let journal: PilotJournal
  private(set) var posted: [OwnerNotificationPresentation] = []

  init(journal: PilotJournal) {
    self.journal = journal
  }

  func post(_ presentation: OwnerNotificationPresentation) {
    posted.append(presentation)
    journal.record(
      .observation,
      "Alert: \(presentation.title)",
      detail: "\(presentation.productName): \(presentation.summary)"
    )
  }

  func dismiss(ids: [UUID]) {
    posted.removeAll { ids.contains($0.id) }
  }

  var ownerFacingText: [String] {
    posted.flatMap { [$0.title, $0.summary] }.filter { !$0.isEmpty }
  }
}

/// The alert sound is a real audio side effect on the product owner's Mac. A
/// pilot run may raise dozens, so it is counted rather than played.
@MainActor
final class PilotSilentSoundPlayer: OwnerNotificationSoundPlaying {
  private(set) var playCount = 0
  func play() { playCount += 1 }
}
