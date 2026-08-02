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

  public func action(for session: SuggestionSession) -> TicketSuggestionRecoveryAction {
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
