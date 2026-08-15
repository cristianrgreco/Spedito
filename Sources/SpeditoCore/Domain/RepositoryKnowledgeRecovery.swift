import Foundation

public enum RepositoryKnowledgeRecoveryAction: Equatable, Sendable {
  case startPendingAnalysis
  case createRecoveryAttempt
  case resumePublication
  case none
}

public enum RepositoryKnowledgeCompletionOutcome: Equatable, Sendable {
  case publishedKnowledge
  case noPublishableKnowledge
}

public struct RepositoryKnowledgeRecoveryPolicy: Sendable {
  public init() {}

  public func action(for run: RepositoryKnowledgeRun) -> RepositoryKnowledgeRecoveryAction {
    switch run.status {
    case .pendingAnalysis:
      return .startPendingAnalysis
    case .analyzing, .reviewing, .interrupted:
      return .createRecoveryAttempt
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

  public func completionOutcome(
    for run: RepositoryKnowledgeRun,
    drafts: [RepositoryKnowledgeDraft],
    pages: [KnowledgePage]
  ) -> RepositoryKnowledgeCompletionOutcome? {
    guard run.status == .completed else { return nil }
    let hasPublishableKnowledge =
      drafts.contains { $0.status == .approved }
      || pages.contains { $0.sourceRepositoryKnowledgeRunID == run.id }
    if hasPublishableKnowledge {
      return .publishedKnowledge
    }
    return .noPublishableKnowledge
  }
}
