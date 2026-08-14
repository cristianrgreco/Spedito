import SwiftUI
import Testing

@testable import SpeditoApp

@Suite("Workspace commands")
struct WorkspaceCommandTests {
  @Test("Every workspace destination has a stable command-number shortcut")
  func destinationShortcuts() {
    let expected: [(WorkspaceCommand, Character)] = [
      (.backlog, "1"),
      (.sprintBoard, "2"),
      (.app, "8"),
      (.retrospectives, "3"),
      (.reports, "4"),
      (.productKnowledge, "5"),
      (.codebase, "6"),
      (.chat, "7"),
    ]

    #expect(WorkspaceCommand.navigation == expected.map(\.0))
    for (command, key) in expected {
      #expect(command.shortcut.key == key)
      #expect(command.shortcut.modifiers == .command)
    }
  }

  @Test("Product and Team settings use related comma shortcuts")
  func settingsShortcuts() {
    #expect(WorkspaceCommand.settings == [.productSettings, .teamSettings])
    #expect(
      WorkspaceCommand.productSettings.shortcut
        == WorkspaceCommand.Shortcut(key: ",", modifiers: .command)
    )
    #expect(
      WorkspaceCommand.teamSettings.shortcut
        == WorkspaceCommand.Shortcut(key: ",", modifiers: [.command, .option])
    )
  }

  @Test("Menu labels use owner-facing sentence case")
  func menuLabels() {
    #expect(
      WorkspaceCommand.allCases.map(\.title) == [
        "Backlog",
        "Sprint board",
        "App versions",
        "Retrospectives",
        "Reports",
        "Product knowledge",
        "Codebase",
        "Chat",
        "Product settings",
        "Team settings",
      ]
    )
  }
}
