import Foundation
import Testing

@testable import StoryPointlessCore

@Suite("Retrospective agent guidance")
struct RetrospectiveGuidanceTests {
  @Test("Implementers do not promise unavailable capabilities through Ways of working")
  func implementerDestinationFeasibility() {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      personaInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Implementer",
        role: .implementer
      )
    )

    #expect(instructions.contains("accepting it can achieve its stated effect"))
    #expect(instructions.contains("Accepting a team_practice only adds its text"))
    #expect(instructions.contains("It does not install, provision, configure, authorise"))
    #expect(instructions.contains("capabilities that already exist"))
    #expect(instructions.contains("request the capability or return awaiting_owner"))
    #expect(instructions.contains("provisioning tooling"))
  }

  @Test("Tech Leads do not defer missing verification through Ways of working")
  func techLeadDestinationFeasibility() {
    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      personaInstructions: "",
      reviewer: AgentProfile(
        productID: UUID(),
        name: "Tech Lead",
        role: .lead
      )
    )

    #expect(instructions.contains("accepting it can achieve its stated effect"))
    #expect(instructions.contains("Accepting team_practice only adds its text"))
    #expect(instructions.contains("it cannot install, provision, configure, authorise"))
    #expect(instructions.contains("capabilities that already exist"))
    #expect(instructions.contains("Do not turn an"))
    #expect(instructions.contains("unresolved permission or required verification"))
    #expect(instructions.contains("provisioning tooling or"))
  }

  @Test("Synthesis does not convert missing capabilities into team practices")
  func synthesisDestinationFeasibility() {
    let instructions = CodexRetrospectiveSynthesizer.developerInstructions(
      productInstructions: "",
      personaInstructions: ""
    )

    #expect(instructions.contains("accepting it can achieve its stated effect"))
    #expect(instructions.contains("Accepting team_practice only adds its text"))
    #expect(instructions.contains("it cannot install, provision, configure, authorise"))
    #expect(instructions.contains("capabilities that"))
    #expect(instructions.contains("already exist"))
    #expect(instructions.contains("missing required verification"))
    #expect(instructions.contains("provisioning tooling"))
  }
}
