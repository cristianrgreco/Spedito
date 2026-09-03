import Foundation

public enum TicketSuggestionRecoveryAction: Equatable, Sendable {
  case resumeInterruptedGeneration
  case retryLegacyInterruption
  case none
}

public struct TicketSuggestionRecoveryPolicy: Sendable {
  public static let legacyInterruptionMessage =
    "Spedito closed before this proposal finished. Please try again."

  public init() {}

  /// Recovery acts only on orphaned sessions. A generating session whose
  /// planning run is still alive in this process — planning is deliberately
  /// preserved across a Product switch — must be left alone: resuming it
  /// would cancel the healthy run and stamp its session failed.
  public func action(
    for session: SuggestionSession,
    hasLiveRun: Bool
  ) -> TicketSuggestionRecoveryAction {
    guard !hasLiveRun else { return .none }
    switch session.status {
    case .generating:
      return .resumeInterruptedGeneration
    case .failed where session.errorMessage == Self.legacyInterruptionMessage:
      return .retryLegacyInterruption
    case .ready, .failed, .cancelled:
      return .none
    }
  }
}
