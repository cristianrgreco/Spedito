import Foundation

public enum SprintCandidateAdmission {
  public static func integrationQueue(
    candidates: [CandidateRevision],
    sprintID: UUID,
    workItems: [WorkItem]
  ) -> [CandidateRevision] {
    let rankByWorkItemID = Dictionary(
      uniqueKeysWithValues: workItems.map { ($0.id, $0.rank) }
    )
    return
      candidates
      .filter {
        $0.sprintID == sprintID
          && ($0.status == .queuedForIntegration || $0.status == .queuedForReview)
      }
      .sorted {
        orderedBefore(
          $0,
          $1,
          rankByWorkItemID: rankByWorkItemID
        )
      }
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
