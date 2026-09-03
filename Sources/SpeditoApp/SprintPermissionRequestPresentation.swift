import SpeditoCore

struct SprintPermissionRequestPresentation: Equatable {
  static let existingAccessTitle = "Existing access used"
  static let existingAccessSummary =
    "Spedito continued using access already available to this run. No permissions changed."
  static let protectedStorageTitle = "Protected Spedito storage"
  static let protectedStorageSummary =
    "Spedito kept this delivery run out of storage owned by another execution. No product owner decision was needed."

  static let additionalAccessTitle = "Additional access"

  let context: String
  let purpose: String
  let detailTitle: String
  let detail: String
  let additionalAccessDetail: String?

  init(request: AgentPermissionRequest) {
    let statedReason = request.reason?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackPurpose: String

    switch request.kind {
    case .command:
      context = "The agent wants to run a local project command."
      fallbackPurpose = "Run a project command needed to continue this ticket."
      detailTitle = "Exact command"
      let sections = CodexAppServerClient.commandApprovalSections(
        fromDetail: request.detail
      )
      detail = sections.command
      additionalAccessDetail = sections.additionalAccess
    case .permissions:
      context = "The agent needs access outside its current ticket workspace."
      fallbackPurpose = "Use an additional capability needed to continue this ticket."
      detailTitle = "Exact access"
      detail = request.detail
      additionalAccessDetail = nil
    case .fileChange:
      context = "The agent wants to change a file outside its current ticket workspace."
      fallbackPurpose = "Make a file change needed to continue this ticket."
      detailTitle = "Requested file change"
      detail = request.detail
      additionalAccessDetail = nil
    }

    purpose =
      if let statedReason, !statedReason.isEmpty {
        statedReason
      } else {
        fallbackPurpose
      }
  }
}
