import Foundation

public enum TicketOwnerRouter {
  public static func preferredRole(for item: WorkItem) -> AgentRole {
    let text = ([item.title, item.body] + item.acceptanceCriteria)
      .joined(separator: " ")
      .lowercased()

    let routes: [(AgentRole, [String])] = [
      (
        .uxDesigner,
        [
          "user experience", "ux", "prototype", "wireframe", "user flow",
          "interaction", "visual design", "responsive", "accessibility",
        ]
      ),
      (
        .businessAnalyst,
        [
          "research", "investigate", "compare", "requirements", "data provider",
          "market", "analyse", "analyze", "discovery",
        ]
      ),
      (
        .qualityAssurance,
        [
          "test plan", "exploratory test", "regression", "quality assurance",
          "acceptance test", "verify",
        ]
      ),
      (
        .knowledgeCurator,
        ["documentation", "document ", "knowledge base", "runbook", "decision record"]
      ),
      (
        .reviewer,
        ["security audit", "security review", "privacy audit", "independent review"]
      ),
      (
        .lead,
        ["architecture", "technical design", "system design", "architecture decision"]
      ),
      (
        .frontendEngineer,
        ["frontend", "front-end", "user interface", " ui ", "swiftui", "react", "css"]
      ),
      (
        .backendEngineer,
        ["backend", "back-end", "api ", "database", "server", "infrastructure", "aws"]
      ),
    ]

    var bestRole: AgentRole?
    var bestScore = 0
    for (role, phrases) in routes {
      let score = phrases.reduce(into: 0) { result, phrase in
        if text.contains(phrase) {
          result += phrase.contains(" ") ? 2 : 1
        }
      }
      if score > bestScore {
        bestRole = role
        bestScore = score
      }
    }
    return bestRole ?? .implementer
  }

  public static func owner(
    for item: WorkItem,
    profiles: [AgentProfile],
    suggestedRole: AgentRole? = nil
  ) -> AgentProfile? {
    let activeOwners = profiles.filter(\.role.canOwnDelivery)
    let preferredRole = suggestedRole ?? preferredRole(for: item)
    return activeOwners.first { $0.role == preferredRole }
      ?? activeOwners.first { $0.role == .implementer }
      ?? activeOwners.first
  }
}
