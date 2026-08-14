import Foundation

public enum CodexLiveActivityKind: String, Codable, Equatable, Sendable {
  case thinking
  case planning
  case researching
  case inspecting
  case changingFiles
  case runningChecks
  case coordinating

  public var symbolName: String {
    switch self {
    case .thinking: "brain"
    case .planning: "list.bullet.clipboard"
    case .researching: "globe"
    case .inspecting: "doc.text.magnifyingglass"
    case .changingFiles: "hammer"
    case .runningChecks: "terminal"
    case .coordinating: "person.2"
    }
  }
}

public struct CodexLiveActivity: Equatable, Sendable {
  public let text: String
  public let kind: CodexLiveActivityKind

  public init(text: String, kind: CodexLiveActivityKind) {
    self.text = text
    self.kind = kind
  }
}

public enum CodexLiveActivityUpdate: Equatable, Sendable {
  case activity(CodexLiveActivity)
  case turnFinished
}

public struct CodexLiveActivityAccumulator: Sendable {
  private var reasoningSummariesByItemID: [String: String] = [:]
  private var emittedReasoningCharacterCountsByItemID: [String: Int] = [:]

  public init() {}

  public mutating func consume(_ notification: CodexNotification) -> CodexLiveActivityUpdate? {
    switch notification.method {
    case "turn/completed":
      return .turnFinished

    case "item/reasoning/summaryTextDelta":
      guard
        let itemID = notification.params["itemId"]?.stringValue,
        let delta = notification.params["delta"]?.stringValue
      else { return nil }
      reasoningSummariesByItemID[itemID, default: ""] += delta
      guard let text = Self.displayText(reasoningSummariesByItemID[itemID]) else { return nil }
      let previousCharacterCount =
        emittedReasoningCharacterCountsByItemID[itemID] ?? 0
      let terminalPunctuation = text.last.map { ".!?…".contains($0) } ?? false
      let newlyVisibleCharacterCount =
        reasoningSummariesByItemID[itemID, default: ""].count - previousCharacterCount
      guard
        previousCharacterCount == 0
          ? text.count >= 24 || terminalPunctuation
          : newlyVisibleCharacterCount >= 24 || terminalPunctuation
      else { return nil }
      emittedReasoningCharacterCountsByItemID[itemID] =
        reasoningSummariesByItemID[itemID, default: ""].count
      return .activity(CodexLiveActivity(text: text, kind: .thinking))

    case "turn/plan/updated":
      let steps = notification.params["plan"]?.arrayValue ?? []
      let currentStep = steps.first {
        $0["status"]?.stringValue == "inProgress"
      }?["step"]?.stringValue
      let fallback = notification.params["explanation"]?.stringValue
      guard let text = Self.displayText(currentStep ?? fallback) else { return nil }
      return .activity(CodexLiveActivity(text: text, kind: .planning))

    case "item/plan/delta":
      guard let text = Self.displayText(notification.params["delta"]?.stringValue) else {
        return nil
      }
      return .activity(CodexLiveActivity(text: text, kind: .planning))

    case "item/mcpToolCall/progress":
      guard let text = Self.displayText(notification.params["message"]?.stringValue) else {
        return nil
      }
      return .activity(CodexLiveActivity(text: text, kind: .inspecting))

    case "item/started":
      guard let type = notification.params["item"]?["type"]?.stringValue else { return nil }
      return Self.itemStartedActivity(type: type)

    default:
      return nil
    }
  }

  private static func itemStartedActivity(type: String) -> CodexLiveActivityUpdate? {
    let activity: CodexLiveActivity
    switch type {
    case "commandExecution":
      activity = CodexLiveActivity(
        text: "Running a project command…",
        kind: .runningChecks
      )
    case "fileChange":
      activity = CodexLiveActivity(
        text: "Updating project files…",
        kind: .changingFiles
      )
    case "webSearch":
      activity = CodexLiveActivity(
        text: "Researching external sources…",
        kind: .researching
      )
    case "imageView":
      activity = CodexLiveActivity(
        text: "Inspecting a visual artefact…",
        kind: .inspecting
      )
    case "mcpToolCall", "dynamicToolCall":
      activity = CodexLiveActivity(
        text: "Inspecting supporting information…",
        kind: .inspecting
      )
    case "collabAgentToolCall", "subAgentActivity":
      activity = CodexLiveActivity(
        text: "Coordinating additional work…",
        kind: .coordinating
      )
    case "reasoning":
      activity = CodexLiveActivity(
        text: "Thinking through the next step…",
        kind: .thinking
      )
    default:
      return nil
    }
    return .activity(activity)
  }

  private static func displayText(_ value: String?) -> String? {
    guard let value else { return nil }
    let source: String
    let expression = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    let range = NSRange(value.startIndex..., in: value)
    let matches = expression?.matches(in: value, range: range) ?? []
    if matches.count > 1,
      let last = matches.last,
      let captureRange = Range(last.range(at: 1), in: value)
    {
      source = String(value[captureRange])
    } else {
      source = value
    }

    let lines =
      source
      .components(separatedBy: .newlines)
      .map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "****", with: "** · **")
          .replacingOccurrences(
            of: #"(?<=[\p{L}\p{N}.!?])\*\*(?=[\p{L}\p{N}])"#,
            with: " · **",
            options: .regularExpression
          )
          .replacingOccurrences(of: "**", with: "")
          .replacingOccurrences(of: "`", with: "")
          .trimmingCharacters(in: CharacterSet(charactersIn: "#-• "))
      }
      .filter { !$0.isEmpty }
    guard var text = lines.last else { return nil }
    if text.count > 150 {
      text = "…" + String(text.suffix(149))
    }
    return text
  }
}
