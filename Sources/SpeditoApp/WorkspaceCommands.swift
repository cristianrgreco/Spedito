import SwiftUI

enum WorkspaceCommand: CaseIterable, Hashable {
  case backlog
  case sprintBoard
  case retrospectives
  case reports
  case productKnowledge
  case codebase
  case chat
  case productSettings
  case teamSettings

  struct Shortcut: Equatable {
    let key: Character
    let modifiers: EventModifiers
  }

  static let navigation: [WorkspaceCommand] = [
    .backlog,
    .sprintBoard,
    .retrospectives,
    .reports,
    .productKnowledge,
    .codebase,
    .chat,
  ]

  static let settings: [WorkspaceCommand] = [
    .productSettings,
    .teamSettings,
  ]

  var title: String {
    switch self {
    case .backlog: "Backlog"
    case .sprintBoard: "Sprint board"
    case .retrospectives: "Retrospectives"
    case .reports: "Reports"
    case .productKnowledge: "Product knowledge"
    case .codebase: "Codebase"
    case .chat: "Chat"
    case .productSettings: "Product settings"
    case .teamSettings: "Team settings"
    }
  }

  var shortcut: Shortcut {
    switch self {
    case .backlog: Shortcut(key: "1", modifiers: .command)
    case .sprintBoard: Shortcut(key: "2", modifiers: .command)
    case .retrospectives: Shortcut(key: "3", modifiers: .command)
    case .reports: Shortcut(key: "4", modifiers: .command)
    case .productKnowledge: Shortcut(key: "5", modifiers: .command)
    case .codebase: Shortcut(key: "6", modifiers: .command)
    case .chat: Shortcut(key: "7", modifiers: .command)
    case .productSettings: Shortcut(key: ",", modifiers: .command)
    case .teamSettings: Shortcut(key: ",", modifiers: [.command, .option])
    }
  }
}

struct WorkspaceCommandActions {
  let perform: (WorkspaceCommand) -> Void
}

private struct WorkspaceCommandActionsKey: FocusedValueKey {
  typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
  var workspaceCommandActions: WorkspaceCommandActions? {
    get { self[WorkspaceCommandActionsKey.self] }
    set { self[WorkspaceCommandActionsKey.self] = newValue }
  }
}

struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceCommandActions) private var actions

  var body: some Commands {
    CommandMenu("Go") {
      commandButton(.backlog)
      commandButton(.sprintBoard)

      Divider()

      commandButton(.retrospectives)
      commandButton(.reports)

      Divider()

      commandButton(.productKnowledge)
      commandButton(.codebase)

      Divider()

      commandButton(.chat)

      Divider()

      commandButton(.productSettings)
      commandButton(.teamSettings)
    }
  }

  private func commandButton(_ command: WorkspaceCommand) -> some View {
    let shortcut = command.shortcut
    return Button(command.title) {
      actions?.perform(command)
    }
    .keyboardShortcut(
      KeyEquivalent(shortcut.key),
      modifiers: shortcut.modifiers
    )
    .disabled(actions == nil)
  }
}
