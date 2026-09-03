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

  /// A live pilot's implementer guessed the recipe structure for four turns:
  /// it invented a launch command and readiness check for a mac app, then let
  /// the schema force the browser kind. The guidance carries one valid shape
  /// per kind, presentation first, so the agent selects instead of guessing.
  @Test("Delivery guidance carries a valid presentation-first shape per demo kind")
  func deliveryGuidanceCarriesEveryDemoShape() throws {
    let instructions = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Implementer",
        role: .implementer
      )
    )
    let shapes = try demoShapes(in: instructions)
    #expect(shapes.count == DemoPresentationKind.allCases.count)
    #expect(Set(shapes.map(\.presentation.kind)) == Set(DemoPresentationKind.allCases))

    // The anti-wrapper rule reaches the implementer and the tech lead: a
    // Cocoa window around a terminal program is contested, never shipped.
    #expect(instructions.contains("Never wrap the product in another surface"))
    #expect(instructions.contains("Cocoa window around a terminal program"))
    // The contest question is owner-facing: plain words, no internal kind
    // identifiers, no scope-change options.
    #expect(instructions.contains("Write that question in the product owner's words"))
    #expect(instructions.contains("never put an internal identifier such as terminal_application"))
    let techLead = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      reviewer: AgentProfile(productID: UUID(), name: "Tech lead", role: .lead)
    )
    #expect(techLead.contains("wraps the product in another surface"))
    #expect(techLead.contains("returned with changes requested"))
    #expect(techLead.contains("proposedDemoKind"))
    // A PDF screen set where the contract expects an HTML screen set is the
    // wrong medium, not a fidelity nit.
    #expect(techLead.contains("delivered as a PDF or image where the ticket contract expects static_web"))

    // A designer reads a two-shape design catalogue instead. Every browser
    // miss in the UX delivery cells copied the implementer catalogue's browser
    // shape verbatim, placeholder path included, and every mac_application
    // miss handed the HTML directory over as a bundle.
    let designer = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "UX designer",
        role: .uxDesigner
      )
    )
    let designShapes = try demoShapes(in: designer)
    #expect(designShapes.map(\.presentation.kind) == [.staticWeb, .artifact])
    #expect(
      designer.contains(
        "A design delivery never returns browser, mac_application, command_output, or"
      )
    )
    #expect(designer.contains("a working product surface is a delivery ticket's demo, not a design"))
    #expect(!designer.contains("\"kind\":\"browser\""))
    #expect(!designer.contains("path/to/your-service"))
    #expect(!designer.contains("YourApp.app"))
    // The contest path, the anti-wrapper rule, and the fidelity rules still
    // reach the designer unchanged.
    #expect(designer.contains("Never wrap the product in another surface"))
    #expect(designer.contains("A design prototype is not a wrapper"))
    #expect(designer.contains("proposedDemoKind"))
    #expect(designer.contains("in a static_web directory. It is never a browser"))

    // Research delivery never returns a recipe, so the shapes must not reach it.
    let analyst = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Business analyst",
        role: .businessAnalyst
      )
    )
    #expect(!analyst.contains("{\"presentation\""))
  }

  /// The literal recipe shapes in one set of instructions, in order, each
  /// decoded and validated. The presentation object and its kind lead, so a
  /// model that mirrors a shape commits to the kind before any field can
  /// contradict it.
  private func demoShapes(in instructions: String) throws -> [DemoLaunchSpecification] {
    try instructions
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("{\"presentation\"") }
      .map { shape in
        #expect(shape.hasPrefix("{\"presentation\":{\"kind\":\""))
        let specification = try JSONDecoder().decode(
          DemoLaunchSpecification.self,
          from: Data(shape.utf8)
        )
        try DemoLaunchSpecificationValidator.validate(specification)
        return specification
      }
  }

  @Test("Documented readiness sequences must be exercised by the smoke-tested demo recipe")
  func documentedReadinessMatchesDemoRecipe() {
    let implementer = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Implementer",
        role: .implementer
      )
    )
    let analyst = CodexTicketExecutor.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      assignee: AgentProfile(
        productID: UUID(),
        name: "Business analyst",
        role: .businessAnalyst
      )
    )
    let reviewer = CodexTechLeadReviewer.developerInstructions(
      productInstructions: "",
      customInstructions: "",
      reviewer: AgentProfile(
        productID: UUID(),
        name: "Tech lead",
        role: .lead
      )
    )

    // The implementer must put every documented preparation step into the recipe Spedito runs
    // and may not describe a readiness step or check as verified without having run it.
    #expect(
      implementer.contains("executable form of the readiness sequence this candidate documents")
    )
    #expect(implementer.contains("presents as required before the product runs must appear in"))
    #expect(implementer.contains("preparationCommands in the documented order"))
    #expect(implementer.contains("smoke test proves the same claim"))
    #expect(implementer.contains("do not present it as a readiness step unless the recipe"))
    #expect(implementer.contains("ran it successfully in this workspace and reports it in tests"))
    #expect(implementer.contains("recipe does not run is a false operational instruction"))
    #expect(implementer.contains("readiness sequence is the sequence that recipe runs"))

    // Research delivery shares the knowledge guidance but never returns a recipe, so the
    // recipe-specific readiness contract must not reach it.
    #expect(analyst.contains("readiness sequence is the sequence that recipe runs"))
    #expect(!analyst.contains("executable form of the readiness sequence"))

    // The reviewer treats a documented preparation step missing from the recipe as blocking.
    #expect(
      reviewer.contains("Compare the recipe with any readiness sequence the candidate documents")
    )
    #expect(
      reviewer.contains("preparationCommands omit is a materially false operational instruction")
    )
    #expect(reviewer.contains("blocks even when the recipe alone looks valid"))
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
    #expect(repair.contains("missing sandbox capability"))
    #expect(repair.contains("use `request_permissions`"))
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

  /// A live native macOS run asked the product owner for five separate paths in
  /// two minutes, each found by rerunning a build that failed on the next one.
  /// The guidance that prevents exactly that shipped only when there was an
  /// interrupted decision to recover, so neither agent ever saw it.
  @Test("Every delivery turn is told to request one coherent capability")
  func coherentCapabilityGuidanceIsAlwaysDelivered() {
    let withoutInterruption = CodexLifecycleGuidance.permissionRecoveryContext(for: nil)
    #expect(withoutInterruption.contains("one coherent capability"))
    #expect(withoutInterruption.contains("one batched"))
    #expect(withoutInterruption.contains("No interrupted permission request was recorded."))

    let interrupted = AgentPermissionRequest(
      productID: UUID(),
      workItemID: UUID(),
      agentRunID: UUID(),
      threadID: "thread-guidance",
      turnID: "turn-guidance",
      serverRequestID: "1",
      method: "item/permissions/requestApproval",
      kind: .permissions,
      title: "Allow additional access?",
      detail: "Read /opt/homebrew/bin",
      reason: "The build needs its runtime.",
      signature: "signature",
      productGrantSignature: nil,
      status: .interrupted
    )
    #expect(
      CodexLifecycleGuidance.permissionRecoveryContext(for: interrupted)
        .contains("one coherent capability")
    )
  }
}
