import Foundation
import Testing

@testable import SpeditoCore

@Suite("Lifecycle-specific agent guidance")
struct CodexLifecycleGuidanceTests {
  @Test("Business analyst delivery receives focused research guidance")
  func researchDeliveryIsFocused() {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "Prefer concise recommendations.",
      customInstructions: "Compare no more than three credible options.",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Business analyst",
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
    #expect(instructions.contains("delivery turn is deliberately non-interactive"))
    #expect(instructions.contains("does not own the product owner's desktop"))
    #expect(instructions.contains("Do not invoke macOS GUI launchers"))
    #expect(instructions.contains("run a graphical app to"))
    #expect(instructions.contains("prove that its window appears"))
    #expect(instructions.contains("expected\nisolation"))
    #expect(instructions.contains("not product limitations"))
    #expect(instructions.contains("Spedito alone prepares and opens"))
    #expect(instructions.contains("managed Demo workflow"))
    #expect(instructions.contains("crashes, traps, or fails"))
    #expect(instructions.contains("treat it as a failed check"))
    #expect(instructions.contains("failed assertion is not capability evidence"))
    #expect(instructions.contains("provide testing infrastructure"))
    #expect(instructions.contains("reproduce the application lifecycle"))
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
    #expect(
      instructions.contains(
        "genuinely additional permission request is the product owner's review point"
      )
    )
    #expect(instructions.contains("ticket workspace and every descendant are already read/write"))
    #expect(instructions.contains("Never request additional access"))
    #expect(instructions.contains("inside that workspace"))
    #expect(instructions.contains("workspace-relative paths for every repository file edit"))
    #expect(instructions.contains("never repeat the absolute ticket-workspace prefix"))
    #expect(instructions.contains("Native file-change"))
    #expect(instructions.contains("approvals are not a permission path in Spedito"))
    #expect(instructions.contains("declined automatically"))
    #expect(instructions.contains("changing a file outside the ticket workspace"))
    #expect(instructions.contains("request write access to the smallest exact path"))
    #expect(instructions.contains("retry the edit after access is granted"))
    #expect(instructions.contains("allowed once remains active"))
    #expect(instructions.contains("system temporary directory, Darwin cache directory"))
    #expect(instructions.contains("Library/Caches directory"))
    #expect(instructions.contains("tool-managed transient files only"))
    #expect(instructions.contains("preview, and other ticket workspaces remain protected"))
    #expect(instructions.contains("recorded as existing access rather than a new approval"))
    #expect(
      instructions.contains(
        "awaiting_owner to ask the product owner to restore, enable, add, or confirm"
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
      name: "Tech lead",
      role: .lead
    )
    let customisedProfile = AgentProfile(
      productID: UUID(),
      name: "Tech lead",
      role: .lead,
      customInstructions: "  Challenge risky assumptions.  "
    )
    let legacyDefaultProfile = AgentProfile(
      productID: UUID(),
      name: "Tech lead",
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

  @Test("Tech lead review is a quick evidence-only inspection")
  func techLeadReviewIsEvidenceOnly() {
    let instructions = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "Run every available test before approval.",
      customInstructions: "Research every referenced provider independently.",
      reviewer: AgentProfile(
        productID: UUID(),
        name: "Tech lead",
        role: .lead
      )
    )

    #expect(instructions.contains("single read-only inspection"))
    #expect(instructions.contains("inspect the exact candidate diff"))
    #expect(instructions.contains("Do not build, test, lint"))
    #expect(instructions.contains("Do not browse the web"))
    #expect(instructions.contains("Do not request broader"))
    #expect(instructions.contains("When a repository artefact exists"))
    #expect(instructions.contains("Do not repeat searches"))
    #expect(instructions.contains("do not prepare or launch it"))
    #expect(instructions.contains("cannot expand permissions"))
    #expect(!CodexTechLeadReviewer.allowsApprovals)
  }
}
