import AppKit
import SpeditoCore
import SwiftUI

struct InitialFocusClearer: NSViewRepresentable {
  func makeNSView(context: Context) -> FocusClearingView {
    FocusClearingView()
  }

  func updateNSView(_ nsView: FocusClearingView, context: Context) {}

  final class FocusClearingView: NSView {
    private var hasClearedInitialFocus = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, !hasClearedInitialFocus else { return }
      hasClearedInitialFocus = true
      window.initialFirstResponder = self
      window.makeFirstResponder(self)
    }
  }
}

struct EditableTextField: View {
  let title: String
  let prompt: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
  }
}

struct EditableTextArea: View {
  let title: String
  let prompt: String
  @Binding var text: String
  let statusText: String?
  let minHeight: CGFloat
  let focusOnAppear: Bool
  let isReadOnly: Bool
  let accessibilityIdentifier: String?
  @FocusState private var isFocused: Bool

  init(
    title: String,
    prompt: String,
    text: Binding<String>,
    statusText: String? = nil,
    minHeight: CGFloat,
    focusOnAppear: Bool = false,
    isReadOnly: Bool = false,
    accessibilityIdentifier: String? = nil
  ) {
    self.title = title
    self.prompt = prompt
    _text = text
    self.statusText = statusText
    self.minHeight = minHeight
    self.focusOnAppear = focusOnAppear
    self.isReadOnly = isReadOnly
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        if let statusText {
          Label(statusText, systemImage: "exclamationmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
      }
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(prompt)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
        TextEditor(text: $text)
          .scrollContentBackground(.hidden)
          .multilineTextAlignment(.leading)
          .font(.body)
          .padding(8)
          .focused($isFocused)
          .accessibilityIdentifier(accessibilityIdentifier ?? "")
      }
      .frame(minHeight: minHeight)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }
      .disabled(isReadOnly)
      .allowsHitTesting(!isReadOnly)
    }
    .onAppear {
      guard focusOnAppear else { return }
      DispatchQueue.main.async {
        isFocused = true
      }
    }
  }
}

extension WorkItemType {
  var symbolName: String {
    switch self {
    case .story: "person.crop.circle.badge.checkmark"
    case .task: "list.bullet.rectangle"
    case .bug: "ladybug"
    }
  }

  var tint: Color {
    switch self {
    case .story: .green
    case .task: .blue
    case .bug: .red
    }
  }

  var titlePrompt: String {
    switch self {
    case .story: "User outcome"
    case .task: "Task outcome"
    case .bug: "What isn't working?"
    }
  }

  var contextPrompt: String {
    switch self {
    case .story: "Who needs this, and why?"
    case .task: "What must be delivered, and why?"
    case .bug: "Expected behavior, actual behavior, and reproduction steps"
    }
  }

  var criteriaPrompt: String {
    switch self {
    case .bug: "Fix criteria and regression evidence, one per line"
    default: "Acceptance criteria, one per line"
    }
  }
}

extension AgentRole {
  var symbolName: String {
    switch self {
    case .businessAnalyst: "text.magnifyingglass"
    case .uxDesigner: "paintbrush.pointed"
    case .lead: "point.3.connected.trianglepath.dotted"
    case .implementer: "hammer"
    case .frontendEngineer: "macwindow"
    case .backendEngineer: "server.rack"
    case .reviewer: "checkmark.seal"
    case .qualityAssurance: "testtube.2"
    case .knowledgeCurator: "books.vertical"
    }
  }

  var tint: Color {
    switch self {
    case .businessAnalyst: .purple
    case .uxDesigner: .pink
    case .lead: .orange
    case .implementer: .blue
    case .frontendEngineer: .cyan
    case .backendEngineer: .indigo
    case .reviewer: .green
    case .qualityAssurance: .pink
    case .knowledgeCurator: .indigo
    }
  }
}

struct ConversationRecipientPolicy {
  static func defaultRecipient(
    profiles: [AgentProfile],
    preferredProfileID: UUID? = nil
  ) -> AgentProfile? {
    if let preferredProfileID,
      let preferred = profiles.first(where: { $0.id == preferredProfileID })
    {
      return preferred
    }
    return profiles.first { $0.role == .businessAnalyst }
      ?? profiles.first { $0.role == .lead }
      ?? profiles.first
  }
}
enum ProductNameEditAction: Equatable {
  case save
  case cancel
}

enum ProductNameEditResolution: Equatable {
  case save(String)
  case cancel
  case invalid
}

struct ProductNameEditPolicy {
  static func resolve(
    draftName: String,
    action: ProductNameEditAction
  ) -> ProductNameEditResolution {
    guard action == .save else { return .cancel }
    let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? .invalid : .save(trimmedName)
  }
}

struct CustomTeamMemberRuntimePolicy {
  static func compatibleEffort(
    requestedEffort: String,
    model: CodexModelOption?
  ) -> String {
    guard let model else { return requestedEffort }
    let supportedEfforts = model.supportedReasoningEfforts.map(\.id)
    return supportedEfforts.contains(requestedEffort)
      ? requestedEffort
      : model.defaultReasoningEffort
  }
}

struct CodexInstallationChangePolicy {
  static func isAllowed(
    isShuttingDown: Bool,
    hasActiveWork: Bool
  ) -> Bool {
    !isShuttingDown && !hasActiveWork
  }
}
enum DestructiveProductSetting: Equatable {
  case archiveProduct
  case cancelGitHubSetup
  case disconnectGitHub
  case signOutGitHub
}

struct DestructiveProductSettingConfirmationPolicy {
  static func command(
    _ setting: DestructiveProductSetting,
    confirmed: Bool
  ) -> DestructiveProductSetting? {
    confirmed ? setting : nil
  }
}

struct ProductConversationThreadPresentation {
  static func active(
    _ threads: [ProductConversationThread]
  ) -> [ProductConversationThread] {
    threads.filter { !$0.isArchived }
  }

  static func archived(
    _ threads: [ProductConversationThread]
  ) -> [ProductConversationThread] {
    threads.filter(\.isArchived)
  }

  static func visible(
    _ threads: [ProductConversationThread],
    showingArchived: Bool
  ) -> [ProductConversationThread] {
    showingArchived ? active(threads) + archived(threads) : active(threads)
  }
}

@MainActor
enum RetrospectiveConclusionAction {
  @discardableResult
  static func perform(
    conclude: () async -> Bool,
    showBacklog: () -> Void
  ) async -> Bool {
    guard await conclude() else { return false }
    showBacklog()
    return true
  }
}

struct ProductConversationFailurePresentation {
  static let retryableMessage =
    "The reply could not be completed. Retry when you are ready."

  static func message(
    status: ConversationThreadStatus,
    technicalEvidence: String?
  ) -> String? {
    guard status == .failed else { return nil }
    return technicalEvidence ?? retryableMessage
  }
}

struct KnowledgePageDraft: Equatable {
  var title: String
  var bodyMarkdown: String

  init(title: String = "", bodyMarkdown: String = "") {
    self.title = title
    self.bodyMarkdown = KnowledgeMarkdown.normalizedBody(bodyMarkdown)
  }
  init(page: KnowledgePage) {
    title = page.title
    bodyMarkdown = KnowledgeMarkdown.normalizedBody(page.bodyMarkdown)
  }

  mutating func cancel(to page: KnowledgePage) {
    self = KnowledgePageDraft(page: page)
  }
}

struct KnowledgeAnswerPresentation {
  static func citedVerifiedPages(
    answer: KnowledgeAnswer,
    pages: [KnowledgePage]
  ) -> [KnowledgePage] {
    let pagesByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
    var includedIDs: Set<UUID> = []
    return answer.citationPageIDs.compactMap { pageID in
      guard
        includedIDs.insert(pageID).inserted,
        let page = pagesByID[pageID],
        page.verificationStatus == .verified
      else { return nil }
      return page
    }
  }
}

struct TicketKnowledgeNavigationPolicy {
  static func publishedPage(
    for proposal: KnowledgePageProposal,
    pages: [KnowledgePage]
  ) -> KnowledgePage? {
    guard proposal.status == .accepted else { return nil }
    if let targetPageID = proposal.targetPageID {
      return pages.first {
        $0.id == targetPageID && $0.verificationStatus == .verified
      }
    }
    return pages.last {
      $0.sourceWorkItemID == proposal.workItemID
        && $0.title == proposal.title
        && $0.verificationStatus == .verified
    }
  }
}

extension WorkItemPriority {
  var tint: Color {
    switch self {
    case .urgent: .red
    case .high: .orange
    case .normal: .blue
    case .low: .gray
    }
  }
}

extension AgentRunStatus {
  var activityTitle: String {
    switch self {
    case .queued: "Waiting"
    case .running: "Working"
    case .awaitingOwner: "Needs you"
    case .interrupted: "Interrupted"
    case .completed: "Finished"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  var activitySymbol: String {
    switch self {
    case .queued: "clock"
    case .running: "bolt.fill"
    case .awaitingOwner: "hand.raised.fill"
    case .interrupted: "pause.circle.fill"
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .cancelled: "xmark.circle.fill"
    }
  }

  var activityTint: Color {
    switch self {
    case .queued: Color(nsColor: .secondaryLabelColor)
    case .running: .blue
    case .awaitingOwner: .orange
    case .interrupted: .orange
    case .completed: .green
    case .failed: .red
    case .cancelled: Color(nsColor: .secondaryLabelColor)
    }
  }
}

extension WorkItemState {
  var ownerFacingActivity: String? {
    switch self {
    case .queued: "Waiting to start"
    case .running: "Building"
    case .integrating: "Combining changes"
    case .verifying: "Checking quality"
    case .acceptance: "Ready for you"
    case .readyToRelease: "Finishing approved work"
    case .released: "Completed"
    default: nil
    }
  }

  var activitySymbol: String {
    switch self {
    case .queued: "clock"
    case .running: "hammer"
    case .integrating: "arrow.triangle.merge"
    case .verifying: "checkmark.shield"
    case .acceptance: "play.rectangle"
    case .readyToRelease: "shippingbox"
    case .released: "checkmark.circle.fill"
    default: "circle"
    }
  }

  var activityTint: Color {
    switch self {
    case .backlog, .refining, .ready, .queued:
      Color(nsColor: .secondaryLabelColor)
    case .running, .integrating, .verifying:
      .blue
    case .acceptance:
      .orange
    case .readyToRelease:
      .purple
    case .released:
      .green
    case .cancelled:
      .red
    }
  }
}

extension CodexConnectionState {
  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  var detail: String {
    switch self {
    case .notChecked: "Not checked"
    case .checking: "Checking compatibility…"
    case .connected(let version, _): "Connected · \(version)"
    case .unavailable: "Not available"
    case .incompatible: "Not compatible"
    }
  }

  var diagnostic: String? {
    switch self {
    case .unavailable(let message), .incompatible(let message):
      message
    default:
      nil
    }
  }

  var symbolName: String {
    switch self {
    case .notChecked: "circle.dashed"
    case .checking: "arrow.triangle.2.circlepath"
    case .connected: "checkmark.circle.fill"
    case .unavailable: "xmark.circle"
    case .incompatible: "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .connected: .green
    case .incompatible: .orange
    case .unavailable: .red
    default: .secondary
    }
  }
}

extension String {
  var displayEffort: String {
    switch lowercased() {
    case "low": "Low"
    case "medium": "Medium"
    case "high": "High"
    case "xhigh": "Extra High"
    case "max": "Max"
    case "ultra": "Ultra"
    default: capitalized
    }
  }
}
