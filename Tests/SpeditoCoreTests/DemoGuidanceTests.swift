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
    #expect(instructions.contains("static_web: a self-contained interactive prototype"))
    #expect(instructions.contains("every command, port, and readiness field is null or empty"))
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
      // HTML under static_web is the default design medium; a PDF is reserved
      // for explicitly document-first outcomes.
      #expect(instructions.contains("HTML screen set or clickable prototype under static_web"))
      #expect(instructions.contains("Do not ask for a PDF or image screen set"))
      #expect(instructions.contains("prose alone is not the primary deliverable"))
      #expect(instructions.contains("not schematic or pixel-font approximations"))
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
    #expect(designer.contains("HTML screen set"))
    #expect(designer.contains("PNG/PDF screen mockups only when the ticket"))
    #expect(designer.contains("explicitly document-first"))
    #expect(designer.contains("deliver a design screen set as HTML under static_web"))
    // A screen set is static_web, never a browser recipe: the persona and
    // the delivery guidance both say so, because the first wording made
    // eight of twelve UX samples mirror the browser shape.
    #expect(designer.contains("its recipe is static_web, never browser"))
    #expect(designer.contains("in a static_web directory. It is never a browser"))
    // An HTML mock of a native window is the prototype medium, not a wrapper
    // and not a Mac app: four of twelve re-measured UX samples labelled it
    // mac_application after the anti-wrapper rule first read "a page around
    // a Mac app".
    #expect(designer.contains("A prototype of a native window is"))
    #expect(designer.contains("A design prototype is not a wrapper"))
    #expect(designer.contains("realistic renders set in real typefaces, never hand-drawn glyph"))
    #expect(designer.contains("or lowering the deliverable's fidelity"))
    #expect(designer.contains("hand-drawn glyph alphabet, pixel font, bitmap letters"))
    #expect(designer.contains("that is a limitation of the"))
    #expect(designer.contains("rather than as a substitute for an explicitly visual contract"))
    // The designer's catalogue holds only the two design shapes. The browser
    // and mac_application shapes a designer never needs stay with the
    // implementation roles, because their presence alone produced the misses.
    #expect(designer.contains("A design delivery never returns browser, mac_application"))
    #expect(!designer.contains("{\"presentation\":{\"kind\":\"browser\""))
    #expect(!designer.contains("{\"presentation\":{\"kind\":\"mac_application\""))
  }

}
