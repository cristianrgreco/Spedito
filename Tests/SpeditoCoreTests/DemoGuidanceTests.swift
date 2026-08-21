import Foundation
import Testing

@testable import SpeditoCore

@Suite("Product owner demo guidance")
struct DemoGuidanceTests {
  @Test("Delivery guidance prefers an interactive owner-facing demo")
  func deliveryGuidance() {
    let productID = UUID()
    let assignee = AgentProfile(
      productID: productID,
      name: "UX designer",
      role: .uxDesigner
    )

    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: assignee
    )

    #expect(instructions.contains("most representative owner-facing result"))
    #expect(instructions.contains("interactive prototype or working product"))
    #expect(instructions.contains("with a reviewable prototype must demo the prototype"))
    #expect(instructions.contains("never ask the owner to use a terminal"))
    #expect(instructions.contains("Demo button runs it"))
    #expect(instructions.contains("in-app product knowledge change"))
    #expect(instructions.contains("presentation may support several ordered reviewInstructions"))
    #expect(instructions.contains("accepts the app-supplied port"))
    #expect(instructions.contains("documented readiness check"))
    #expect(instructions.contains("Use static_web for a self-contained interactive prototype"))
    #expect(instructions.contains("static_web has no preparationCommands"))
  }

  @Test("Tech lead guidance rejects developer-oriented or secondary demos")
  func techLeadGuidance() {
    let productID = UUID()
    let reviewer = AgentProfile(
      productID: productID,
      name: "Tech lead",
      role: .lead
    )

    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      reviewer: reviewer
    )

    #expect(instructions.contains("representative owner-facing result"))
    #expect(instructions.contains("interactive result or product"))
    #expect(instructions.contains("code editor, developer tool, or manual setup"))
    #expect(instructions.contains("Inspect the typed demo recipe statically"))
    #expect(instructions.contains("do not prepare or launch it"))
    #expect(instructions.contains("reported evidence only"))
    #expect(instructions.contains("must not depend on ignored build"))
    #expect(instructions.contains("do not author a competing knowledge change"))
  }
  @Test("Business analyst contracts and UX delivery make visible experience work visual")
  func visibleUXContractsRequireVisualReview() {
    let suggestion = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: "",
      customInstructions: ""
    )
    let refinement = CodexTicketRefinementGenerator.developerInstructions(
      productInstructions: "",
      customInstructions: ""
    )
    for instructions in [suggestion, refinement] {
      #expect(instructions.contains("primary review medium"))
      #expect(instructions.contains("static visual screen set"))
      #expect(instructions.contains("prose alone is not the primary deliverable"))
      #expect(instructions.contains("not explicitly document-first outcomes"))
    }

    let designer = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "UX designer",
        role: .uxDesigner
      )
    )
    #expect(designer.contains("make a visual result the primary review deliverable"))
    #expect(designer.contains("self-contained static_web prototype"))
    #expect(designer.contains("PNG/PDF screen mockups"))
    #expect(designer.contains("rather than as a substitute for an explicitly visual contract"))
  }

}
