import Foundation
import Testing

@testable import SpeditoCore

@Suite("Terminal demo launch script")
struct TerminalDemoLaunchScriptTests {
  private let launchID = UUID(uuidString: "0BADF00D-1234-4ABC-8DEF-0123456789AB")!

  @Test("The script quotes every path and argument and execs the reviewed program")
  func exactScriptText() throws {
    let workspaceURL = URL(
      fileURLWithPath: "/Users/owner/Library/Caches/Spedito/Preview Worktrees/it's here",
      isDirectory: true
    )
    let runtimeURL = workspaceURL.appendingPathComponent(
      ".spedito-demo-runtime",
      isDirectory: true
    )
    let specification = DemoLaunchSpecification(
      title: "Dog finder's TUI",
      preparationCommands: [DemoCommand(executable: "scripts/build.sh")],
      launchCommand: DemoCommand(
        executable: "bin/tui",
        arguments: ["--breed", "Great Dane", "it's", "$HOME", "*"],
        workingDirectory: "app/"
      ),
      presentation: DemoPresentation(kind: .terminalApplication)
    )

    let text = try TerminalDemoLaunchScript.text(
      specification: specification,
      workspaceURL: workspaceURL,
      runtimeDirectoryURL: runtimeURL,
      launchID: launchID
    )

    let root = "/Users/owner/Library/Caches/Spedito/Preview Worktrees/it'\\''s here"
    let expected = """
      #!/bin/zsh
      printf '\\033]0;%s\\007' 'Dog finder'\\''s TUI'
      cd '\(root)/app' || exit 1
      export TMPDIR='\(root)/.spedito-demo-runtime/tmp'
      export XDG_CACHE_HOME='\(root)/.spedito-demo-runtime/cache/xdg'
      export SPEDITO_DEMO_DATA_DIRECTORY='\(root)/.spedito-demo-runtime/data'
      printf '%d' "$$" > '\(root)/.spedito-demo-runtime/terminal/\(launchID.uuidString).pid'
      exec '\(root)/bin/tui' '--breed' 'Great Dane' 'it'\\''s' '$HOME' '*'

      """
    #expect(text == expected)
    #expect(text.hasPrefix("#!/bin/zsh\n"))
    #expect(text.hasSuffix("\n"))
  }

  @Test("The current directory working directory runs from the workspace root")
  func currentDirectoryRunsFromTheWorkspaceRoot() throws {
    let workspaceURL = URL(fileURLWithPath: "/tmp/preview", isDirectory: true)
    let runtimeURL = URL(fileURLWithPath: "/tmp/preview/.spedito-demo-runtime", isDirectory: true)
    let text = try TerminalDemoLaunchScript.text(
      specification: DemoLaunchSpecification(
        title: "Menu",
        launchCommand: DemoCommand(executable: "./bin/menu", workingDirectory: "."),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      workspaceURL: workspaceURL,
      runtimeDirectoryURL: runtimeURL,
      launchID: launchID
    )
    #expect(text.contains("\ncd '/tmp/preview' || exit 1\n"))
    #expect(text.hasSuffix("\nexec '/tmp/preview/bin/menu'\n"))
  }

  @Test("A recipe without a launch command cannot produce a script")
  func missingLaunchCommandIsInvalid() {
    #expect(throws: DemoLaunchValidationError.self) {
      try TerminalDemoLaunchScript.text(
        specification: DemoLaunchSpecification(
          title: "Menu",
          presentation: DemoPresentation(kind: .terminalApplication)
        ),
        workspaceURL: URL(fileURLWithPath: "/tmp/preview", isDirectory: true),
        runtimeDirectoryURL: URL(fileURLWithPath: "/tmp/preview/rt", isDirectory: true),
        launchID: launchID
      )
    }
  }

  @Test("Quoting isolates the shell from every value")
  func quoting() {
    #expect(TerminalDemoLaunchScript.quote("plain") == "'plain'")
    #expect(TerminalDemoLaunchScript.quote("it's") == "'it'\\''s'")
    #expect(TerminalDemoLaunchScript.quote("$HOME `id` \"x\"") == "'$HOME `id` \"x\"'")
    #expect(TerminalDemoLaunchScript.quote("") == "''")
  }

  @Test("The script, pid file, and required directories share one runtime root")
  func runtimeLayout() {
    let runtimeURL = URL(fileURLWithPath: "/tmp/preview/.spedito-demo-runtime", isDirectory: true)
    #expect(
      TerminalDemoLaunchScript.scriptURL(runtimeDirectoryURL: runtimeURL, launchID: launchID)
        .path == "/tmp/preview/.spedito-demo-runtime/terminal/\(launchID.uuidString).command"
    )
    #expect(
      TerminalDemoLaunchScript.processIDURL(runtimeDirectoryURL: runtimeURL, launchID: launchID)
        .path == "/tmp/preview/.spedito-demo-runtime/terminal/\(launchID.uuidString).pid"
    )
    #expect(
      TerminalDemoLaunchScript.requiredDirectories(runtimeDirectoryURL: runtimeURL).map(\.path)
        == [
          "/tmp/preview/.spedito-demo-runtime/terminal",
          "/tmp/preview/.spedito-demo-runtime/tmp",
          "/tmp/preview/.spedito-demo-runtime/cache/xdg",
          "/tmp/preview/.spedito-demo-runtime/data",
        ]
    )
  }
}
