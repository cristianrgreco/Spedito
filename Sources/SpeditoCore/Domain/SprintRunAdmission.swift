import Foundation

public enum SprintRunAdmission {
  public static func eligibleImplementationRuns(
    plan: SprintPlan,
    runs: [AgentRun],
    workItems: [WorkItem],
    dependencies: [WorkItemDependency]
  ) -> [AgentRun] {
    let sprintItemsByWorkItemID = Dictionary(
      uniqueKeysWithValues: plan.items.map { ($0.workItemID, $0) }
    )
    let itemByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })

    return
      runs
      .filter { run in
        guard
          run.sprintID == plan.sprint.id,
          run.status == .queued,
          let sprintItem = sprintItemsByWorkItemID[run.workItemID],
          sprintItem.implementerProfileID == run.profileID
        else { return false }

        let prerequisiteIDs =
          dependencies
          .filter { $0.workItemID == run.workItemID }
          .map(\.dependsOnWorkItemID)
        return prerequisiteIDs.allSatisfy { itemByID[$0]?.state == .released }
      }
      .sorted { lhs, rhs in
        let leftRank = itemByID[lhs.workItemID]?.rank ?? Int.max
        let rightRank = itemByID[rhs.workItemID]?.rank ?? Int.max
        if leftRank == rightRank {
          return lhs.createdAt < rhs.createdAt
        }
        return leftRank < rightRank
      }
  }

  public static func nextEligibleImplementationRun(
    plan: SprintPlan,
    runs: [AgentRun],
    workItems: [WorkItem],
    dependencies: [WorkItemDependency]
  ) -> AgentRun? {
    eligibleImplementationRuns(
      plan: plan,
      runs: runs,
      workItems: workItems,
      dependencies: dependencies
    ).first
  }
}
