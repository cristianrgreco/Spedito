import Foundation
import SpeditoCore

enum GitHubRepositorySetupActivity: Equatable {
  case inProgress(
    progress: GitHubRemoteRepositoryInitializationProgress,
    publishesExistingHistory: Bool
  )
  case completed(publishedExistingHistory: Bool)

  var isInProgress: Bool {
    if case .inProgress = self { return true }
    return false
  }

  var isCompleted: Bool {
    if case .completed = self { return true }
    return false
  }
}

protocol RemoteRepositoryPollingSleeping: Sendable {
  func sleep(for duration: Duration) async throws
}

struct ContinuousRemoteRepositoryPollingSleeper: RemoteRepositoryPollingSleeping {
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

struct GitHubPullRequestPollingPolicy {
  static let foregroundPriorityInterval: Duration = .seconds(60)
  static let foregroundInterval: Duration = .seconds(120)
  static let backgroundInterval: Duration = .seconds(300)

  static func orderedPublications(
    _ publications: [RemotePublication],
    workItems: [WorkItem],
    visibleWorkItemIDs: Set<UUID>
  ) -> [RemotePublication] {
    let workItemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    return
      publications
      .filter(isPollable)
      .sorted { lhs, rhs in
        let lhsPriority = priority(
          publication: lhs,
          workItemsByID: workItemsByID,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        let rhsPriority = priority(
          publication: rhs,
          workItemsByID: workItemsByID,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        if lhsPriority != rhsPriority {
          return lhsPriority < rhsPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }

  static func interval(
    isApplicationActive: Bool,
    publications: [RemotePublication],
    workItems: [WorkItem],
    visibleWorkItemIDs: Set<UUID>
  ) -> Duration {
    guard isApplicationActive else { return backgroundInterval }
    let workItemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    let hasPriorityPullRequest = publications.contains {
      isPollable($0)
        && priority(
          publication: $0,
          workItemsByID: workItemsByID,
          visibleWorkItemIDs: visibleWorkItemIDs
        ) < 2
    }
    return hasPriorityPullRequest ? foregroundPriorityInterval : foregroundInterval
  }

  private static func isPollable(_ publication: RemotePublication) -> Bool {
    guard publication.workItemID != nil, publication.pullRequest != nil else {
      return false
    }
    switch publication.status {
    case .open, .openOutdated, .openStale:
      return true
    default:
      return false
    }
  }

  private static func priority(
    publication: RemotePublication,
    workItemsByID: [UUID: WorkItem],
    visibleWorkItemIDs: Set<UUID>
  ) -> Int {
    guard let workItemID = publication.workItemID else { return 2 }
    if visibleWorkItemIDs.contains(workItemID) {
      return 0
    }
    if workItemsByID[workItemID]?.state == .acceptance {
      return 1
    }
    return 2
  }
}
