import Foundation
import Testing

@testable import SpeditoCore

@Suite("Retrospective agent guidance")
struct RetrospectiveGuidanceTests {
  @Test("Implementers do not promise unavailable capabilities through Ways of working")
  func implementerDestinationFeasibility() {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Implementer",
        role: .implementer
      )
    )

    #expect(instructions.contains("achieve the stated effect"))
    #expect(instructions.contains("Accepting a team_practice only adds"))
    #expect(instructions.contains("it does not install, provision, configure, authorise"))
    #expect(instructions.contains("capabilities that already exist"))
    #expect(instructions.contains("Never defer a required current-ticket"))
    #expect(instructions.contains("provisioning change"))
  }

  @Test("Tech leads do not defer missing verification through Ways of working")
  func techLeadDestinationFeasibility() {
    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      reviewer: AgentProfile(
        productID: UUID(),
        name: "Tech lead",
        role: .lead
      )
    )

    #expect(instructions.contains("confirm accepting it can achieve"))
    #expect(instructions.contains("the stated effect"))
    #expect(instructions.contains("only adds text to Ways of working"))
    #expect(instructions.contains("it cannot install"))
    #expect(instructions.contains("provision, configure, authorise"))
    #expect(instructions.contains("capabilities that already exist"))
    #expect(instructions.contains("Do not turn missing evidence"))
    #expect(instructions.contains("retrospective action"))
    #expect(instructions.contains("provisioning tooling"))
  }

  @Test("Synthesis does not convert missing capabilities into team practices")
  func synthesisDestinationFeasibility() {
    let instructions = CodexRetrospectiveSynthesizer.developerInstructions(
      productInstructions: "",
      customInstructions: ""
    )

    #expect(instructions.contains("accepting it can achieve its stated effect"))
    #expect(instructions.contains("Accepting team_practice only adds"))
    #expect(instructions.contains("it cannot install, provision, configure, authorise"))
    #expect(instructions.contains("capabilities that"))
    #expect(instructions.contains("already exist"))
    #expect(instructions.contains("missing required verification"))
    #expect(instructions.contains("provisioning tooling"))
  }
}
