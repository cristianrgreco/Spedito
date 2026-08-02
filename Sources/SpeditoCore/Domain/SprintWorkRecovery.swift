import Foundation

public struct SprintWorkRecoveryPolicy: Sendable {
  public init() {}

  public func latestReviewRun(
    for candidate: CandidateRevision,
    runs: [AgentRun],
    reviewerProfileIDs: Set<UUID>
  ) -> AgentRun? {
    guard
      candidate.status == .reviewing,
      let reviewWorktreePath = candidate.integrationWorktreePath
    else {
      return nil
    }

    return runs
      .filter { run in
        guard
          run.productID == candidate.productID,
          run.sprintID == candidate.sprintID,
          run.sprintItemID == candidate.sprintItemID,
          run.workItemID == candidate.workItemID,
          reviewerProfileIDs.contains(run.profileID),
          run.createdAt >= candidate.updatedAt,
          run.worktreePath == nil || run.worktreePath == reviewWorktreePath
        else {
          return false
        }
        switch run.status {
        case .queued, .running, .awaitingOwner, .interrupted, .completed:
          return true
        case .failed, .cancelled:
          return false
        }
      }
      .max(by: { $0.createdAt < $1.createdAt })
  }

  public func runsWithExpiredPermissionDecisions(
    runs: [AgentRun],
    permissionRequests: [AgentPermissionRequest]
  ) -> [AgentRun] {
    let latestRequestByRunID = Dictionary(
      grouping: permissionRequests,
      by: \.agentRunID
    ).compactMapValues { requests in
      requests.max { $0.updatedAt < $1.updatedAt }
    }

    return runs.filter { run in
      guard
        run.status == .awaitingOwner
          || run.status == .queued
          || run.status == .interrupted,
        let request = latestRequestByRunID[run.id]
      else {
        return false
      }
      let latestMeaningfulActivity = run.lastActivityAt ?? run.updatedAt
      return request.status == .interrupted
        && request.updatedAt >= latestMeaningfulActivity
    }
  }

  public func latestPermissionContinuation(
    for runID: UUID,
    permissionRequests: [AgentPermissionRequest]
  ) -> AgentPermissionRequest? {
    permissionRequests
      .filter {
        $0.agentRunID == runID
          && (
            $0.status == .interrupted
              || $0.status == .allowed
              || $0.status == .denied
          )
      }
      .max(by: { $0.updatedAt < $1.updatedAt })
  }

  public func actionablePermissionRequest(
    for workItemID: UUID,
    runs: [AgentRun],
    permissionRequests: [AgentPermissionRequest]
  ) -> AgentPermissionRequest? {
    let awaitingRunsByID = Dictionary(
      uniqueKeysWithValues: runs
        .filter { $0.status == .awaitingOwner }
        .map { ($0.id, $0) }
    )
    return permissionRequests
      .filter { request in
        guard
          request.workItemID == workItemID,
          let run = awaitingRunsByID[request.agentRunID]
        else {
          return false
        }
        let latestMeaningfulActivity = run.lastActivityAt ?? run.updatedAt
        return request.status == .pending
          || (
            request.status == .interrupted
              && request.updatedAt >= latestMeaningfulActivity
          )
      }
      .max(by: { $0.createdAt < $1.createdAt })
  }

  public func implementationRunStatusAfterTurnStops(
    taskWasCancelled: Bool,
    wasManuallyStopped: Bool,
    wasAwaitingPermission: Bool = false
  ) -> AgentRunStatus {
    if wasManuallyStopped {
      return .interrupted
    }
    if taskWasCancelled && wasAwaitingPermission {
      return .awaitingOwner
    }
    return taskWasCancelled ? .queued : .failed
  }

  public func failedPostReviewDemoCandidate(
    workItemID: UUID,
    workItems: [WorkItem],
    candidates: [CandidateRevision],
    runs: [AgentRun],
    profiles: [AgentProfile]
  ) -> CandidateRevision? {
    guard
      workItems.first(where: { $0.id == workItemID })?.state == .running,
      let candidate = candidates.filter({ $0.workItemID == workItemID })
        .max(by: { $0.version < $1.version }),
      candidate.status == .failed,
      candidate.integratedSHA != nil,
      let integrationWorktreePath = candidate.integrationWorktreePath,
      let implementationRun = runs.first(where: { $0.id == candidate.implementationRunID }),
      implementationRun.status == .awaitingOwner,
      let result = try? CodexTicketExecutor.decode(candidate.executionResultJSON),
      result.demo != nil
    else {
      return nil
    }

    let techLeadProfileIDs = Set(
      profiles
        .filter { $0.role == .lead }
        .map(\.id)
    )
    let completedReviewExists = runs.contains {
      $0.workItemID == workItemID
        && techLeadProfileIDs.contains($0.profileID)
        && $0.status == .completed
        && $0.worktreePath == integrationWorktreePath
    }
    return completedReviewExists ? candidate : nil
  }
}
