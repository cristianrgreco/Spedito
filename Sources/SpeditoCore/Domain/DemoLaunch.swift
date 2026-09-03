import Foundation

public enum DemoPresentationKind: String, Codable, CaseIterable, Sendable {
  case browser
  case staticWeb = "static_web"
  case macApplication = "mac_application"
  case artifact
  case commandOutput = "command_output"
  case terminalApplication = "terminal_application"

  public var title: String {
    switch self {
    case .browser: "Web demo"
    case .staticWeb: "Interactive prototype"
    case .macApplication: "macOS app"
    case .artifact: "Review artifact"
    case .commandOutput: "Demo result"
    case .terminalApplication: "Terminal app"
    }
  }
}

/// The owner-approved review medium a ticket carries from planning: one of the
/// six demo presentation kinds, or `none` for code-only work whose delivery
/// must return a null demo. A ticket without a contract (`nil`, stored as SQL
/// NULL) predates the contract and leaves delivery to decide, protected only
/// by the recipe pin. The Swift case is `codeOnly` because `.none` on an
/// optional property would read as the absent optional, not the stored value.
public enum TicketDemoKind: String, Codable, CaseIterable, Hashable, Sendable {
  case browser
  case staticWeb = "static_web"
  case macApplication = "mac_application"
  case artifact
  case commandOutput = "command_output"
  case terminalApplication = "terminal_application"
  case codeOnly = "none"

  public var presentationKind: DemoPresentationKind? {
    switch self {
    case .browser: .browser
    case .staticWeb: .staticWeb
    case .macApplication: .macApplication
    case .artifact: .artifact
    case .commandOutput: .commandOutput
    case .terminalApplication: .terminalApplication
    case .codeOnly: nil
    }
  }

  /// The plain-language phrase shown after "You'll review this as:" on the
  /// proposal card and the stored ticket. Owner-facing, no jargon.
  public var ownerFacingReviewMedium: String {
    switch self {
    case .browser: "Opens in your browser"
    case .staticWeb: "An interactive prototype"
    case .macApplication: "Opens as a Mac app"
    case .artifact: "A file you read"
    case .commandOutput: "Command output"
    case .terminalApplication: "Opens in Terminal"
    case .codeOnly: "A code change with no demo"
    }
  }

  /// The same phrase for mid-sentence use: only the leading capital drops,
  /// so proper nouns such as Mac keep their capitalization.
  public var ownerFacingReviewMediumClause: String {
    ownerFacingReviewMedium.lowercasedFirst
  }
}

/// Decides a contested review medium. A contracted delivery turn cannot emit
/// another kind, so when it concludes the contract is genuinely wrong it
/// returns awaiting_owner naming the kind it believes correct. Spedito — not
/// the agent — authors the two decision options, so the owner's answer can be
/// matched exactly and applied durably before the continuation turn runs.
/// The option text is the durable encoding of the decision; both builders and
/// the matcher below must stay in lockstep. Each option deliberately contains
/// the word "demo" so an accepted change also unpins the Layer 1 recipe pin.
public enum DemoKindContestPolicy {
  public static func changeOption(to proposed: TicketDemoKind) -> String {
    "Change the demo to: \(proposed.ownerFacingReviewMediumClause)"
  }

  public static func keepOption(current: TicketDemoKind) -> String {
    "Keep the planned demo: \(current.ownerFacingReviewMediumClause)"
  }

  /// The question card stored for a contested kind: the agent's own prompt
  /// with Spedito's canonical decision options.
  public static func question(
    prompt: String,
    current: TicketDemoKind,
    proposed: TicketDemoKind,
    decisionArtifact: TicketDecisionArtifact? = nil
  ) -> TicketOwnerQuestion {
    TicketOwnerQuestion(
      prompt: prompt,
      options: [changeOption(to: proposed), keepOption(current: current)],
      decisionArtifact: decisionArtifact
    )
  }

  /// The kind the product owner durably selected, or nil when no answer in
  /// the work log accepts a kind change. Scans owner answers newest first so
  /// the latest decision wins; only an exact canonical change option counts,
  /// which no agent- or owner-authored free text can produce.
  public static func acceptedKindChange(
    comments: [TicketComment]
  ) -> TicketDemoKind? {
    for comment in comments.reversed() where comment.authorKind == .owner {
      for answered in comment.answeredQuestions {
        guard let selected = answered.selectedOption else { continue }
        for kind in TicketDemoKind.allCases where changeOption(to: kind) == selected {
          return kind
        }
      }
    }
    return nil
  }
}

extension String {
  fileprivate var lowercasedFirst: String {
    guard let first else { return self }
    return first.lowercased() + dropFirst()
  }
}

public struct DemoCommand: Codable, Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let workingDirectory: String
  public let timeoutSeconds: Int

  public init(
    executable: String,
    arguments: [String] = [],
    workingDirectory: String = ".",
    timeoutSeconds: Int = 180
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
  }
}

public enum DemoReadinessKind: String, Codable, CaseIterable, Sendable {
  case http
  case process
}

public struct DemoReadinessCheck: Codable, Equatable, Sendable {
  public let kind: DemoReadinessKind
  public let path: String?
  public let timeoutSeconds: Int

  public init(
    kind: DemoReadinessKind,
    path: String? = nil,
    timeoutSeconds: Int = 30
  ) {
    self.kind = kind
    self.path = path
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct DemoPresentation: Codable, Equatable, Sendable {
  public let kind: DemoPresentationKind
  public let path: String?

  public init(kind: DemoPresentationKind, path: String? = nil) {
    self.kind = kind
    self.path = path
  }
}

public struct DemoLaunchSpecification: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let title: String
  public let preparationCommands: [DemoCommand]
  public let launchCommand: DemoCommand?
  public let portEnvironmentVariable: String?
  public let readiness: DemoReadinessCheck?
  public let presentation: DemoPresentation

  public init(
    schemaVersion: Int = 1,
    title: String,
    preparationCommands: [DemoCommand] = [],
    launchCommand: DemoCommand? = nil,
    portEnvironmentVariable: String? = nil,
    readiness: DemoReadinessCheck? = nil,
    presentation: DemoPresentation
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.preparationCommands = preparationCommands
    self.launchCommand = launchCommand
    self.portEnvironmentVariable = portEnvironmentVariable
    self.readiness = readiness
    self.presentation = presentation
  }
}

/// The canonical demo recipe pages: one verified knowledge page per
/// presentation kind the product has shipped, published or updated at
/// candidate acceptance from the accepted candidate's validated recipe.
/// The page is durable domain state derived at acceptance — owner-visible
/// truth that seeds every later delivery turn — and is never read back as
/// authority for launching accepted versions; `AcceptedAppLaunchPolicy`
/// still reads candidate rows.
public enum CanonicalDemoRecipeKnowledge {
  public static func slug(for kind: DemoPresentationKind) -> String {
    "demo-recipe-" + kind.rawValue.replacingOccurrences(of: "_", with: "-")
  }

  public static func kind(forSlug slug: String) -> DemoPresentationKind? {
    DemoPresentationKind.allCases.first { self.slug(for: $0) == slug }
  }

  public static func title(for kind: DemoPresentationKind) -> String {
    "Demo recipe: \(clause(kind.title))"
  }

  /// The complete page body: a plain-language summary and the exact recipe
  /// JSON in one fenced block, so delivery context and tests can recover the
  /// identical specification from the page.
  public static func bodyMarkdown(
    for specification: DemoLaunchSpecification
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = String(decoding: try encoder.encode(specification), as: UTF8.self)
    let kind = specification.presentation.kind
    let preparation =
      specification.preparationCommands.isEmpty
      ? "It needs no preparation commands."
      : "It runs \(specification.preparationCommands.count) preparation "
        + "command\(specification.preparationCommands.count == 1 ? "" : "s") first."
    return """
      The accepted way this product is demoed as a \(clause(kind.title)): \
      “\(specification.title)”. \(preparation) Spedito publishes this page \
      automatically when the product owner accepts a candidate that shipped \
      this recipe. Delivery reuses this exact recipe and extends it only when \
      a ticket adds a new surface; for how the demo runs, this page is \
      authoritative over README wording.

      ## Canonical recipe

      ```json
      \(json)
      ```
      """
  }

  /// The exact specification recovered from a canonical page body, or nil
  /// when the body carries no recoverable recipe. Used by tests to prove the
  /// inherited recipe is executable; launching never reads it back.
  public static func specification(
    fromBody body: String
  ) -> DemoLaunchSpecification? {
    guard
      let fenceStart = body.range(of: "```json\n"),
      let fenceEnd = body.range(of: "\n```", range: fenceStart.upperBound..<body.endIndex)
    else { return nil }
    let json = body[fenceStart.upperBound..<fenceEnd.lowerBound]
    return try? JSONDecoder().decode(
      DemoLaunchSpecification.self,
      from: Data(json.utf8)
    )
  }

  private static func clause(_ title: String) -> String {
    title.lowercasedFirst
  }
}

public struct AcceptedAppLaunch: Equatable, Sendable {
  public let candidate: CandidateRevision
  public let specification: DemoLaunchSpecification

  public init(candidate: CandidateRevision, specification: DemoLaunchSpecification) {
    self.candidate = candidate
    self.specification = specification
  }
}

public enum AcceptedAppLaunchPolicy {
  public static func latest(in candidates: [CandidateRevision]) -> AcceptedAppLaunch? {
    candidates.compactMap(launch(for:)).max(by: isEarlier)
  }

  public static func all(in candidates: [CandidateRevision]) -> [AcceptedAppLaunch] {
    candidates.compactMap(launch(for:)).sorted { lhs, rhs in
      isEarlier(rhs, lhs)
    }
  }

  private static func launch(for candidate: CandidateRevision) -> AcceptedAppLaunch? {
    guard candidate.status == .accepted, candidate.integratedSHA != nil,
      let result = try? CodexTicketExecutor.decode(candidate.executionResultJSON),
      let specification = result.demo,
      specification.presentation.kind == .browser
        || specification.presentation.kind == .staticWeb
        || specification.presentation.kind == .macApplication
        || specification.presentation.kind == .terminalApplication,
      (try? DemoLaunchSpecificationValidator.validate(specification)) != nil
    else {
      return nil
    }
    return AcceptedAppLaunch(candidate: candidate, specification: specification)
  }

  private static func isEarlier(_ lhs: AcceptedAppLaunch, _ rhs: AcceptedAppLaunch) -> Bool {
    if lhs.candidate.updatedAt != rhs.candidate.updatedAt {
      return lhs.candidate.updatedAt < rhs.candidate.updatedAt
    }
    if lhs.candidate.createdAt != rhs.candidate.createdAt {
      return lhs.candidate.createdAt < rhs.candidate.createdAt
    }
    return lhs.candidate.id.uuidString < rhs.candidate.id.uuidString
  }
}

public enum DemoRecipeRevisionPolicy {
  /// A revision may change the demo contract only when the feedback that
  /// triggered it names the demo. Detection is deliberately narrow: a broad
  /// match would re-open the contract to re-derivation — the failure this
  /// policy exists to stop — so only explicit demo vocabulary counts.
  private static let demoChangeTermPattern =
    #"\b(demos?|recipes?|presentation|readiness|browser|static[-_ ]web|mac[-_ ]application|mac(os)? app|command[-_ ]output|terminal[-_ ]application|terminal|tui)\b"#

  public static func feedbackRequestsDemoChange(_ feedback: String) -> Bool {
    feedback.range(
      of: demoChangeTermPattern,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  /// The recipe a tech lead revision turn must carry forward verbatim, or nil
  /// when the feedback names the demo and the turn may change it.
  public static func pinnedRecipeForRevision(
    reviewFeedback: String,
    priorDemo: DemoLaunchSpecification?
  ) -> DemoLaunchSpecification? {
    guard let priorDemo, !feedbackRequestsDemoChange(reviewFeedback) else {
      return nil
    }
    return priorDemo
  }

  /// The pinned recipe for a continuation turn recovered from durable state.
  /// The feedback that sent the candidate back is not stored as one field, so
  /// the policy scans everything said about the ticket since the candidate was
  /// created by anyone other than the implementer — the implementer's own
  /// completion comments always mention the demo they shipped and would
  /// otherwise disable pinning permanently. A demo-failure send-back or a
  /// reviewer naming the demo therefore unpins; unrelated feedback does not.
  public static func pinnedRecipeForContinuation(
    latestCandidate: CandidateRevision?,
    runID: UUID,
    implementerName: String,
    comments: [TicketComment]
  ) -> DemoLaunchSpecification? {
    guard
      let latestCandidate,
      latestCandidate.implementationRunID == runID,
      latestCandidate.status == .changesRequested,
      let priorResult = try? CodexTicketExecutor.decode(
        latestCandidate.executionResultJSON
      ),
      let priorDemo = priorResult.demo
    else {
      return nil
    }
    let feedback = comments
      .filter { $0.createdAt >= latestCandidate.createdAt }
      .filter { !($0.authorKind == .agent && $0.authorName == implementerName) }
      .map(\.body)
      .joined(separator: "\n")
    return feedbackRequestsDemoChange(feedback) ? nil : priorDemo
  }
}

public struct ImportedAppLaunch: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let productID: UUID
  public let revisionSHA: String
  public let specification: DemoLaunchSpecification
  public let evidence: [RepositoryEvidence]
  public let publishedAt: Date

  public init(
    id: UUID,
    runID: UUID,
    productID: UUID,
    revisionSHA: String,
    specification: DemoLaunchSpecification,
    evidence: [RepositoryEvidence],
    publishedAt: Date
  ) {
    self.id = id
    self.runID = runID
    self.productID = productID
    self.revisionSHA = revisionSHA
    self.specification = specification
    self.evidence = evidence
    self.publishedAt = publishedAt
  }
}

public enum AppVersion: Identifiable, Equatable, Sendable {
  case imported(ImportedAppLaunch)
  case accepted(AcceptedAppLaunch)

  public var id: UUID {
    switch self {
    case .imported(let launch):
      launch.id
    case .accepted(let launch):
      launch.candidate.id
    }
  }

  public var productID: UUID {
    switch self {
    case .imported(let launch):
      launch.productID
    case .accepted(let launch):
      launch.candidate.productID
    }
  }

  public var revisionSHA: String {
    switch self {
    case .imported(let launch):
      launch.revisionSHA
    case .accepted(let launch):
      launch.candidate.integratedSHA ?? ""
    }
  }

  public var sessionSourceKind: DemoSessionSourceKind {
    switch self {
    case .imported:
      .importedRepository
    case .accepted:
      .acceptedCandidate
    }
  }
  public var specification: DemoLaunchSpecification {
    switch self {
    case .imported(let launch):
      launch.specification
    case .accepted(let launch):
      launch.specification
    }
  }

  public var acceptedAt: Date {
    switch self {
    case .imported(let launch):
      launch.publishedAt
    case .accepted(let launch):
      launch.candidate.updatedAt
    }
  }
}

public enum AppVersionPolicy {
  public static func all(
    imported: ImportedAppLaunch?,
    acceptedCandidates: [CandidateRevision]
  ) -> [AppVersion] {
    var versions = AcceptedAppLaunchPolicy.all(in: acceptedCandidates).map(AppVersion.accepted)
    if let imported {
      versions.append(.imported(imported))
    }
    return versions.sorted { lhs, rhs in
      if lhs.acceptedAt != rhs.acceptedAt {
        return lhs.acceptedAt > rhs.acceptedAt
      }
      return lhs.id.uuidString > rhs.id.uuidString
    }
  }
}

public enum DemoSessionStatus: String, Codable, CaseIterable, Sendable {
  case preparing
  case starting
  case ready
  case failed
  case stopped
}

public enum DemoSessionSourceKind: String, Codable, CaseIterable, Sendable {
  case acceptedCandidate = "accepted_candidate"
  case importedRepository = "imported_repository"
}

public struct DemoSession: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sourceKind: DemoSessionSourceKind
  public let launchID: UUID
  public var status: DemoSessionStatus
  public var previewWorktreePath: String?
  public var allocatedPort: Int?
  public var output: String?
  public var errorMessage: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sourceKind: DemoSessionSourceKind = .acceptedCandidate,
    launchID: UUID,
    status: DemoSessionStatus,
    previewWorktreePath: String? = nil,
    allocatedPort: Int? = nil,
    output: String? = nil,
    errorMessage: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sourceKind = sourceKind
    self.launchID = launchID
    self.status = status
    self.previewWorktreePath = previewWorktreePath
    self.allocatedPort = allocatedPort
    self.output = output
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum DemoLaunchValidationError: Error, Equatable, LocalizedError,
  OwnerFacingFailure, Sendable
{
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let detail):
      "The demo could not be prepared safely: \(detail)"
    }
  }

  public var ownerFacingDescription: String {
    "This work cannot be demonstrated yet, so there is nothing to open."
  }
}

public enum DemoArtifactPolicy {
  public static let allowedExtensions: Set<String> = [
    "csv", "gif", "jpeg", "jpg", "json", "log", "markdown", "md", "pdf", "png", "txt",
    "webp",
  ]

  public static func validatePath(_ path: String) throws {
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard allowedExtensions.contains(pathExtension) else {
      // Name the rejected extension and the exact allowlist. A repair turn
      // that is told only "inert text, data, image, or PDF" keeps guessing —
      // a live design ticket burned three runs re-submitting an SVG, which
      // reads as an image but can carry active content.
      throw DemoLaunchValidationError.invalid(
        "review artifacts must use an inert format; "
          + "\(pathExtension.isEmpty ? "a file without an extension" : "." + pathExtension) "
          + "is not accepted. Accepted formats: "
          + allowedExtensions.sorted().joined(separator: ", ")
          + ". An SVG or HTML file can contain active content, so deliver a "
          + "PDF, an accepted image format, or a text file instead."
      )
    }
  }

  public static func validateExistingFile(
    at url: URL,
    fileManager: FileManager = .default
  ) throws {
    try validatePath(url.path)
    let values = try url.resourceValues(
      forKeys: [.isAliasFileKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard
      values.isRegularFile == true,
      values.isAliasFile != true,
      values.isPackage != true,
      values.isSymbolicLink != true,
      permissions & 0o111 == 0
    else {
      throw DemoLaunchValidationError.invalid(
        "review artifacts must be regular, non-executable files."
      )
    }
  }
}

public enum DemoLaunchSpecificationValidator {
  public static func validate(_ specification: DemoLaunchSpecification) throws {
    guard specification.schemaVersion == 1 else {
      throw DemoLaunchValidationError.invalid(
        "demo recipe version \(specification.schemaVersion) is not supported."
      )
    }
    guard !specification.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DemoLaunchValidationError.invalid("the demo needs a short owner-facing title.")
    }
    guard specification.preparationCommands.count <= 6 else {
      throw DemoLaunchValidationError.invalid(
        "a demo can contain at most six preparation commands."
      )
    }
    for command in specification.preparationCommands {
      try validate(command)
    }
    if let launchCommand = specification.launchCommand {
      try validate(launchCommand)
    }
    if let name = specification.portEnvironmentVariable {
      try validateEnvironmentVariable(name)
    }
    if let readiness = specification.readiness {
      guard (1...120).contains(readiness.timeoutSeconds) else {
        throw DemoLaunchValidationError.invalid(
          "readiness must time out between 1 and 120 seconds."
        )
      }
      switch readiness.kind {
      case .http:
        try validateLoopbackPath(readiness.path ?? "/", describedAs: "readiness paths")
      case .process:
        guard readiness.path == nil else {
          throw DemoLaunchValidationError.invalid(
            "process readiness cannot contain a URL path."
          )
        }
      }
    }

    switch specification.presentation.kind {
    case .browser:
      guard specification.launchCommand != nil else {
        throw DemoLaunchValidationError.invalid(
          "a web demo needs a managed service command."
        )
      }
      guard specification.readiness?.kind == .http else {
        throw DemoLaunchValidationError.invalid(
          "a web demo needs an HTTP readiness check."
        )
      }
      // A live pilot kept resubmitting a built app bundle as a browser path and
      // could not learn the actual mistake from a message about the path alone.
      let browserPath = specification.presentation.path ?? "/"
      let lowercasedBrowserPath = browserPath.lowercased()
      if !browserPath.hasPrefix("/"),
        lowercasedBrowserPath.hasSuffix(".app") || lowercasedBrowserPath.contains(".app/")
      {
        throw DemoLaunchValidationError.invalid(
          "browser paths must be a loopback URL path beginning with “/”; "
            + "a built application bundle is presented with mac_application, not browser."
        )
      }
      // A UX delivery that mirrors the browser shape for an HTML screen set
      // hands over a workspace directory as the browser path; the repair turn
      // needs to hear the kind, not only the path rule.
      if !browserPath.hasPrefix("/") {
        throw DemoLaunchValidationError.invalid(
          "browser paths must be a loopback URL path beginning with “/”; "
            + "a workspace directory of HTML pages that Spedito can serve is presented with "
            + "static_web, not browser, and declares no launch command."
        )
      }
      try validateLoopbackPath(browserPath, describedAs: "browser paths")
    case .staticWeb:
      guard
        specification.preparationCommands.isEmpty,
        specification.launchCommand == nil,
        specification.portEnvironmentVariable == nil,
        specification.readiness == nil
      else {
        throw DemoLaunchValidationError.invalid(
          "a static web prototype is served by Spedito and cannot declare commands, a port, or readiness."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the prototype needs a workspace-relative directory containing index.html."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
      // A live pilot resubmitted a delivered PDF screen set as static_web and
      // mac_application through five review cycles; the mistaken kind has to
      // fail here, where the repair turn is told the artifact contract.
      try rejectInertArtifactFilePath(path, presentedAs: "static_web")
      // Another pilot twice supplied the correct built-bundle path under
      // static_web, so this mirrors the browser branch's bundle rule.
      let lowercasedPrototypePath = path.lowercased()
      if lowercasedPrototypePath.hasSuffix(".app")
        || lowercasedPrototypePath.contains(".app/")
      {
        throw DemoLaunchValidationError.invalid(
          "a built application bundle is presented with mac_application, not static_web; "
            + "a static web prototype is a directory containing index.html."
        )
      }
    case .macApplication:
      guard
        specification.launchCommand == nil,
        specification.portEnvironmentVariable == nil,
        specification.readiness == nil
      else {
        throw DemoLaunchValidationError.invalid(
          "macOS app demos may build during preparation, but are opened directly without a service command, port, or readiness check."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the demo needs a workspace-relative application path."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
      try rejectInertArtifactFilePath(path, presentedAs: "mac_application")
      // The same pilot offered a directory of review pages as mac_application;
      // the launcher only opens built bundles, so the mistaken kind fails here.
      guard path.lowercased().hasSuffix(".app") else {
        throw DemoLaunchValidationError.invalid(
          "a macOS app demo opens a built .app bundle; a page directory Spedito can serve is static_web and an existing inert file is artifact."
        )
      }
    case .artifact:
      guard
        specification.preparationCommands.isEmpty,
        specification.launchCommand == nil,
        specification.portEnvironmentVariable == nil,
        specification.readiness == nil
      else {
        throw DemoLaunchValidationError.invalid(
          "review artifacts must already exist and cannot declare commands, a port, or readiness."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the demo needs a workspace-relative artifact path."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
      try DemoArtifactPolicy.validatePath(path)
    case .commandOutput:
      guard specification.launchCommand != nil else {
        throw DemoLaunchValidationError.invalid(
          "a result demo needs a command whose output can be shown."
        )
      }
      guard specification.readiness == nil else {
        throw DemoLaunchValidationError.invalid(
          "a result command exits when complete and cannot declare a readiness check."
        )
      }
      guard specification.portEnvironmentVariable == nil else {
        throw DemoLaunchValidationError.invalid(
          "a result command cannot declare a managed service port."
        )
      }
      guard specification.presentation.path == nil else {
        throw DemoLaunchValidationError.invalid(
          "a result demo cannot contain an artifact path."
        )
      }
    case .terminalApplication:
      guard let launchCommand = specification.launchCommand else {
        throw DemoLaunchValidationError.invalid(
          "a terminal app demo needs a launch command naming the built program; Spedito runs it in a Terminal window."
        )
      }
      guard specification.readiness == nil else {
        throw DemoLaunchValidationError.invalid(
          "a terminal app runs interactively in Terminal and cannot declare a readiness check."
        )
      }
      guard specification.portEnvironmentVariable == nil else {
        throw DemoLaunchValidationError.invalid(
          "a terminal app cannot declare a managed service port."
        )
      }
      guard specification.presentation.path == nil else {
        throw DemoLaunchValidationError.invalid(
          "a terminal app demo cannot contain a presentation path; the program is named by launchCommand."
        )
      }
      // The launch command is the program the owner drives, so it must be the
      // built workspace file itself. A bare tool name such as go, python3, or
      // sh would run a host tool against the workspace instead of the
      // reviewed program, and an absolute or escaping path leaves the
      // reviewed checkout.
      let executable = launchCommand.executable.trimmingCharacters(in: .whitespacesAndNewlines)
      guard executable.contains("/") else {
        throw DemoLaunchValidationError.invalid(
          "a terminal app launch command must name the built program by a workspace-relative path "
            + "containing “/”, such as bin/your-program; “\(executable)” is a tool name, not the built program."
        )
      }
      do {
        try validateRelativePath(executable, allowsCurrentDirectory: false)
      } catch {
        throw DemoLaunchValidationError.invalid(
          "a terminal app launch command must name the built program by a workspace-relative path "
            + "inside the reviewed preview, such as bin/your-program; “\(executable)” is not."
        )
      }
    }
  }

  public static func resolveWorkspacePath(
    _ path: String,
    in workspaceURL: URL
  ) throws -> URL {
    try validateRelativePath(path, allowsCurrentDirectory: true)
    let base = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    let basePrefix = base.path.hasSuffix("/") ? base.path : "\(base.path)/"
    var target = base
    for component in path.split(separator: "/").map(String.init) where component != "." {
      target.appendPathComponent(component)
      if FileManager.default.fileExists(atPath: target.path) {
        target = target.standardizedFileURL.resolvingSymlinksInPath()
      } else {
        target = target.standardizedFileURL
      }
      guard target.path == base.path || target.path.hasPrefix(basePrefix) else {
        throw DemoLaunchValidationError.invalid(
          "the path “\(path)” points outside the reviewed preview."
        )
      }
    }
    return target
  }

  private static func rejectInertArtifactFilePath(
    _ path: String,
    presentedAs kind: String
  ) throws {
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard DemoArtifactPolicy.allowedExtensions.contains(pathExtension) else { return }
    throw DemoLaunchValidationError.invalid(
      "an existing inert file such as a PDF, image, or document is presented with artifact, not \(kind)."
    )
  }

  private static func validate(_ command: DemoCommand) throws {
    let executable = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executable.isEmpty, !executable.contains("\0") else {
      throw DemoLaunchValidationError.invalid("a demo command has no executable.")
    }
    let forbiddenExecutables = [
      "sh", "bash", "zsh", "fish", "osascript",
      "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/osascript",
    ]
    guard !forbiddenExecutables.contains(executable) else {
      throw DemoLaunchValidationError.invalid(
        "shell and AppleScript interpreters are not accepted as demo executables; invoke a real executable or executable workspace script directly."
      )
    }
    // A live pilot satisfied the browser contract twice with a no-op launch
    // command, which passed validation and exited without serving anything.
    let noOpExecutables = [
      "true", "false", ":",
      "/usr/bin/true", "/bin/true", "/usr/bin/false", "/bin/false",
    ]
    guard !noOpExecutables.contains(executable) else {
      throw DemoLaunchValidationError.invalid(
        "a no-op command cannot demonstrate or prepare anything; if nothing needs to run, the presentation kind is wrong — a page directory Spedito can serve is static_web and an existing inert file is artifact."
      )
    }
    guard command.arguments.count <= 64 else {
      throw DemoLaunchValidationError.invalid(
        "a demo command can contain at most 64 arguments."
      )
    }
    guard command.arguments.allSatisfy({ !$0.contains("\0") }) else {
      throw DemoLaunchValidationError.invalid("a demo argument contains invalid data.")
    }
    try validateRelativePath(command.workingDirectory, allowsCurrentDirectory: true)
    guard (1...900).contains(command.timeoutSeconds) else {
      throw DemoLaunchValidationError.invalid(
        "commands must time out between 1 and 900 seconds."
      )
    }
  }

  private static func validateEnvironmentVariable(_ name: String) throws {
    let characters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    guard
      !name.isEmpty,
      name.count <= 64,
      name.unicodeScalars.allSatisfy(characters.contains),
      name.first?.isNumber != true
    else {
      throw DemoLaunchValidationError.invalid(
        "the port environment variable name is invalid."
      )
    }
    let forbidden = [
      "PATH", "HOME", "SHELL", "TMPDIR", "DYLD_LIBRARY_PATH",
      "DYLD_INSERT_LIBRARIES", "PYTHONPATH", "NODE_OPTIONS",
    ]
    guard !forbidden.contains(name) else {
      throw DemoLaunchValidationError.invalid(
        "the port cannot be injected through the protected \(name) variable."
      )
    }
  }

  private static func validateRelativePath(
    _ path: String,
    allowsCurrentDirectory: Bool
  ) throws {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !trimmed.hasPrefix("/"),
      !trimmed.hasPrefix("~"),
      !trimmed.contains("\0")
    else {
      throw DemoLaunchValidationError.invalid(
        "demo paths must be relative to the reviewed preview."
      )
    }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else {
      throw DemoLaunchValidationError.invalid(
        "demo paths cannot leave the reviewed preview."
      )
    }
    if !allowsCurrentDirectory, trimmed == "." {
      throw DemoLaunchValidationError.invalid("the demo artifact path is incomplete.")
    }
  }

  /// Every demo kind may declare an HTTP readiness check, so this is not only
  /// reached for browser demos. A native Mac app whose readiness path was
  /// malformed used to tell the product owner about browser paths, which is not
  /// a sentence that means anything about the product they asked for.
  private static func validateLoopbackPath(
    _ path: String,
    describedAs subject: String
  ) throws {
    guard
      path.hasPrefix("/"),
      !path.hasPrefix("//"),
      !path.contains("\0"),
      !path.contains("\r"),
      !path.contains("\n")
    else {
      throw DemoLaunchValidationError.invalid(
        "\(subject) must be a loopback URL path beginning with “/”."
      )
    }
    let components = URLComponents(string: path)
    guard components?.scheme == nil, components?.host == nil else {
      throw DemoLaunchValidationError.invalid(
        "a demo can open only a Spedito-managed loopback URL."
      )
    }
  }
}
