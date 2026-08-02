import Foundation
import Testing

@testable import SpeditoCore

@Suite("Lifecycle-specific agent guidance")
struct CodexLifecycleGuidanceTests {
  @Test("Business Analyst delivery receives focused research guidance")
  func researchDeliveryIsFocused() {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "Prefer concise recommendations.",
      customInstructions: "Compare no more than three credible options.",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Business Analyst",
        role: .businessAnalyst
      )
    )

    #expect(instructions.contains("DELIVERY MODE: RESEARCH AND DECISION SUPPORT"))
    #expect(instructions.contains("Historical delivery notes are analogous context"))
    #expect(instructions.contains("Do not invoke Node"))
    #expect(instructions.contains("INTERNAL ROLE GUIDANCE"))
    #expect(instructions.contains("turn product intent into delivery-ready scope"))
    #expect(!instructions.contains("DELIVERY MODE: PRODUCT CHANGE"))
    #expect(!instructions.contains("app-supplied port"))
    #expect(
      instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasSuffix("Compare no more than three credible options.")
    )
  }

  @Test("Implementation delivery receives product-change guidance")
  func productChangeDeliveryIsFocused() {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Implementer",
        role: .implementer
      )
    )

    #expect(instructions.contains("DELIVERY MODE: PRODUCT CHANGE"))
    #expect(instructions.contains("interactive prototype or working product surface"))
    #expect(instructions.contains("Implement the approved ticket contract"))
    #expect(!instructions.contains("DELIVERY MODE: RESEARCH AND DECISION SUPPORT"))
    #expect(!instructions.contains("Do not invoke Node"))
  }

  @Test("Delivery routes blocked network access through the scoped permission tool")
  func deliveryRequestsNetworkPermission() {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Implementer",
        role: .implementer
      )
    )
    let repair = CodexTicketExecutor.repairPrompt(
      validationError: "Awaiting-owner result did not identify a product decision."
    )

    #expect(instructions.contains("scoped `request_permissions` tool is available"))
    #expect(instructions.contains("Ticket delivery starts without"))
    #expect(instructions.contains("external network access"))
    #expect(instructions.contains("command fails with DNS"))
    #expect(instructions.contains("resolution, host lookup, connection"))
    #expect(instructions.contains("permission request is itself the Product Owner's review point"))
    #expect(
      instructions.contains(
        "awaiting_owner to ask the Product Owner to restore, enable, add, or confirm"
      )
    )
    #expect(instructions.contains("does not grant access by itself"))
    #expect(repair.contains("sandbox filesystem or network capability"))
    #expect(repair.contains("available `request_permissions` tool"))
  }

  @Test("Empty profile instructions stay empty and role guidance remains internal")
  func customInstructionsAreAnOverlay() {
    let emptyProfile = AgentProfile(
      productID: UUID(),
      name: "Tech Lead",
      role: .lead
    )
    let customisedProfile = AgentProfile(
      productID: UUID(),
      name: "Tech Lead",
      role: .lead,
      customInstructions: "  Challenge risky assumptions.  "
    )
    let legacyDefaultProfile = AgentProfile(
      productID: UUID(),
      name: "Tech Lead",
      role: .lead,
      customInstructions: AgentPersonaDefaults.instructions(for: .lead)
    )

    #expect(emptyProfile.customInstructionText.isEmpty)
    #expect(legacyDefaultProfile.customInstructionText.isEmpty)
    #expect(customisedProfile.customInstructionText == "Challenge risky assumptions.")

    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      customInstructions: customisedProfile.customInstructionText,
      reviewer: customisedProfile
    )
    #expect(instructions.contains("LIFECYCLE: INDEPENDENT TECH LEAD REVIEW"))
    #expect(instructions.contains("maintain architectural coherence"))
    #expect(
      instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasSuffix("Challenge risky assumptions.")
    )
  }

  @Test("Tech Lead review is a quick evidence-only inspection")
  func techLeadReviewIsEvidenceOnly() {
    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "Run every available test before approval.",
      customInstructions: "Research every referenced provider independently.",
      reviewer: AgentProfile(
        productID: UUID(),
        name: "Tech Lead",
        role: .lead
      )
    )

    #expect(instructions.contains("single read-only inspection"))
    #expect(instructions.contains("Use repository reads such as diff, show"))
    #expect(instructions.contains("Do not build, test, lint"))
    #expect(instructions.contains("Do not browse the web"))
    #expect(instructions.contains("Do not request broader"))
    #expect(instructions.contains("read the primary artefact"))
    #expect(instructions.contains("Do not repeat searches"))
    #expect(instructions.contains("do not prepare or launch it"))
    #expect(instructions.contains("cannot expand permissions"))
    #expect(!CodexTechLeadReviewer.allowsApprovals)
  }
}
