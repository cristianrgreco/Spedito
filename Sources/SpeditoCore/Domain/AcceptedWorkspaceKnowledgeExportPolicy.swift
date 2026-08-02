import Foundation

public enum AcceptedWorkspaceKnowledgeExportPolicy {
  public static func shouldExport(
    _ page: KnowledgePage,
    acceptedSourceWorkItemIDs: Set<UUID>
  ) -> Bool {
    guard page.verificationStatus == .verified else { return false }
    guard let sourceWorkItemID = page.sourceWorkItemID else { return true }
    return acceptedSourceWorkItemIDs.contains(sourceWorkItemID)
  }
}
