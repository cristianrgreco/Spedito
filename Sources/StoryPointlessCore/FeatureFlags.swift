import Foundation

public enum StoryPointlessFeatureFlags {
  public static let requireKnowledgeApprovalEnvironmentKey =
    "STORYPOINTLESS_REQUIRE_KNOWLEDGE_APPROVAL"

  public static var requiresKnowledgeApproval: Bool {
    requiresKnowledgeApproval(environment: ProcessInfo.processInfo.environment)
  }

  public static func requiresKnowledgeApproval(
    environment: [String: String]
  ) -> Bool {
    guard
      let rawValue = environment[requireKnowledgeApprovalEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else { return false }
    return ["1", "true", "yes", "on"].contains(rawValue)
  }
}
