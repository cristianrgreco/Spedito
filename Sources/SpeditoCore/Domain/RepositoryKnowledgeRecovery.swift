import Foundation

public enum RepositoryKnowledgeRecoveryAction: Equatable, Sendable {
  case startPendingAnalysis
  case createRecoveryAttempt
  case resumePublication
  case none
}

public struct RepositoryKnowledgeRecoveryPolicy: Sendable {
  public init() {}

  public func action(
    for run: RepositoryKnowledgeRun,
    alreadyCreatedRecoveryAttempt: Bool = false
  ) -> RepositoryKnowledgeRecoveryAction {
    switch run.status {
    case .pendingAnalysis:
      return .startPendingAnalysis
    case .analyzing, .reviewing, .interrupted:
      return alreadyCreatedRecoveryAttempt ? .none : .createRecoveryAttempt
    case .publishing:
      return .resumePublication
    case .completed, .failed, .stale:
      return .none
    }
  }

  public func canExecute(
    _ action: RepositoryKnowledgeRecoveryAction,
    codexConnectionAvailable: Bool
  ) -> Bool {
    switch action {
    case .startPendingAnalysis, .createRecoveryAttempt:
      codexConnectionAvailable
    case .resumePublication:
      true
    case .none:
      false
    }
  }

  public func shouldRetryUnproductiveCompletedAnalysis(
    run: RepositoryKnowledgeRun,
    drafts: [RepositoryKnowledgeDraft],
    pages: [KnowledgePage]
  ) -> Bool {
    run.status == .completed
      && !drafts.contains { $0.status == .approved }
      && pages.allSatisfy { $0.sourceRepositoryKnowledgeRunID == nil }
  }

  public func shouldRetryLegacyInvalidLaunchProposal(
    run: RepositoryKnowledgeRun
  ) -> Bool {
    guard run.status == .failed, let errorMessage = run.errorMessage else { return false }
    return errorMessage.hasPrefix(
      "The demo could not be prepared safely:"
    )
  }
}
