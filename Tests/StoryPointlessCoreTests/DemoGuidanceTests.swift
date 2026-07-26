import Foundation
import Testing

@testable import StoryPointlessCore

@Suite("Product Owner demo guidance")
struct DemoGuidanceTests {
  @Test("Delivery guidance prefers an interactive owner-facing demo")
  func deliveryGuidance() {
    let productID = UUID()
    let assignee = AgentProfile(
      productID: productID,
      name: "UX Designer",
      role: .uxDesigner
    )

    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      personaInstructions: "",
      assignee: assignee
    )

    #expect(instructions.contains("most representative owner-facing result"))
    #expect(instructions.contains("interactive prototype or working product"))
    #expect(instructions.contains("with a reviewable prototype must demo the prototype"))
    #expect(instructions.contains("Do not ask the Product Owner to run terminal commands"))
    #expect(instructions.contains("Demo button runs it on the Product Owner's behalf"))
    #expect(instructions.contains("in-app Product knowledge change"))
    #expect(instructions.contains("presentation may support several ordered reviewInstructions"))
  }

  @Test("Tech Lead guidance rejects developer-oriented or secondary demos")
  func techLeadGuidance() {
    let productID = UUID()
    let reviewer = AgentProfile(
      productID: productID,
      name: "Tech Lead",
      role: .lead
    )

    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      personaInstructions: "",
      reviewer: reviewer
    )

    #expect(instructions.contains("most representative owner-facing result"))
    #expect(instructions.contains("interactive result exists"))
    #expect(instructions.contains("product surface rather than a Markdown contract"))
    #expect(instructions.contains("code editor, developer tool"))
    #expect(instructions.contains("different states within the one primary demo"))
    #expect(instructions.contains("preparationCommands and launchCommand are expected"))
  }
}
