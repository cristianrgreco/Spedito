import Foundation

public enum SprintCandidateAdmission {
  public static func reviewQueue(
    candidates: [CandidateRevision],
    sprintID: UUID,
    workItems: [WorkItem]
  ) -> [CandidateRevision] {
    let rankByWorkItemID = Dictionary(
      uniqueKeysWithValues: workItems.map { ($0.id, $0.rank) }
    )
    return candidates
      .filter {
        $0.sprintID == sprintID && $0.status == .queuedForReview
      }
      .sorted {
        orderedBefore(
          $0,
          $1,
          rankByWorkItemID: rankByWorkItemID
        )
      }
  }

  public static func integrationQueueIsOccupied(
    candidates: [CandidateRevision],
    sprintID: UUID
  ) -> Bool {
    candidates.contains { candidate in
      guard candidate.sprintID == sprintID else { return false }
      switch candidate.status {
      case .integrating, .resolvingConflict:
        return true
      case .reviewing:
        return candidate.integratedSHA != nil
      case .queuedForReview, .queuedForIntegration, .changesRequested,
        .readyForDemo, .accepted, .superseded, .failed:
        return false
      }
    }
  }

  public static func nextIntegrationCandidate(
    candidates: [CandidateRevision],
    sprintID: UUID,
    workItems: [WorkItem]
  ) -> CandidateRevision? {
    let rankByWorkItemID = Dictionary(
      uniqueKeysWithValues: workItems.map { ($0.id, $0.rank) }
    )
    return candidates
      .filter {
        $0.sprintID == sprintID && $0.status == .queuedForIntegration
      }
      .sorted {
        orderedBefore(
          $0,
          $1,
          rankByWorkItemID: rankByWorkItemID
        )
      }
      .first
  }

  private static func orderedBefore(
    _ lhs: CandidateRevision,
    _ rhs: CandidateRevision,
    rankByWorkItemID: [UUID: Int]
  ) -> Bool {
    let leftRank = rankByWorkItemID[lhs.workItemID] ?? Int.max
    let rightRank = rankByWorkItemID[rhs.workItemID] ?? Int.max
    if leftRank == rightRank {
      return lhs.createdAt < rhs.createdAt
    }
    return leftRank < rightRank
  }
}
