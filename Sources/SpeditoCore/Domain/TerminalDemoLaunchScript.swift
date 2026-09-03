import Foundation

/// The launcher script Spedito writes for a terminal app demo and hands to
/// Terminal.app. Terminal runs the script in a new window; the script moves
/// into the reviewed checkout, mirrors the isolated temporary, cache, and data
/// locations that sandboxed demo commands receive, records its own process id,
/// and `exec`s the reviewed program so that id identifies the program the
/// owner is driving. This is pure text generation: the App launcher writes the
/// file, sets its mode, and opens it.
public enum TerminalDemoLaunchScript {
  public static let runtimeSubdirectory = "terminal"

  public static func scriptURL(runtimeDirectoryURL: URL, launchID: UUID) -> URL {
    runtimeDirectoryURL
      .appendingPathComponent(runtimeSubdirectory, isDirectory: true)
      .appendingPathComponent("\(launchID.uuidString).command", isDirectory: false)
  }

  public static func processIDURL(runtimeDirectoryURL: URL, launchID: UUID) -> URL {
    runtimeDirectoryURL
      .appendingPathComponent(runtimeSubdirectory, isDirectory: true)
      .appendingPathComponent("\(launchID.uuidString).pid", isDirectory: false)
  }

  public static func temporaryDirectoryURL(runtimeDirectoryURL: URL) -> URL {
    runtimeDirectoryURL.appendingPathComponent("tmp", isDirectory: true)
  }

  public static func cacheDirectoryURL(runtimeDirectoryURL: URL) -> URL {
    runtimeDirectoryURL
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("xdg", isDirectory: true)
  }

  public static func dataDirectoryURL(runtimeDirectoryURL: URL) -> URL {
    runtimeDirectoryURL.appendingPathComponent("data", isDirectory: true)
  }

  /// Every directory the script expects to exist before Terminal runs it.
  public static func requiredDirectories(runtimeDirectoryURL: URL) -> [URL] {
    [
      runtimeDirectoryURL.appendingPathComponent(runtimeSubdirectory, isDirectory: true),
      temporaryDirectoryURL(runtimeDirectoryURL: runtimeDirectoryURL),
      cacheDirectoryURL(runtimeDirectoryURL: runtimeDirectoryURL),
      dataDirectoryURL(runtimeDirectoryURL: runtimeDirectoryURL),
    ]
  }

  /// The complete script. `workspaceURL` is the reviewed preview checkout and
  /// `runtimeDirectoryURL` its `.spedito-demo-runtime` directory; both are
  /// used as given, so the caller passes resolved paths.
  public static func text(
    specification: DemoLaunchSpecification,
    workspaceURL: URL,
    runtimeDirectoryURL: URL,
    launchID: UUID
  ) throws -> String {
    guard let command = specification.launchCommand else {
      throw DemoLaunchValidationError.invalid("the terminal app launch command is missing.")
    }
    let workspacePath = workspaceURL.path
    let workingDirectory = join(workspacePath, command.workingDirectory)
    let executable = join(workspacePath, command.executable)
    let processIDPath = processIDURL(
      runtimeDirectoryURL: runtimeDirectoryURL,
      launchID: launchID
    ).path
    let lines = [
      "#!/bin/zsh",
      "printf '\\033]0;%s\\007' \(quote(specification.title))",
      "cd \(quote(workingDirectory)) || exit 1",
      "export TMPDIR=\(quote(temporaryDirectoryURL(runtimeDirectoryURL: runtimeDirectoryURL).path))",
      "export XDG_CACHE_HOME=\(quote(cacheDirectoryURL(runtimeDirectoryURL: runtimeDirectoryURL).path))",
      "export SPEDITO_DEMO_DATA_DIRECTORY=\(quote(dataDirectoryURL(runtimeDirectoryURL: runtimeDirectoryURL).path))",
      "printf '%d' \"$$\" > \(quote(processIDPath))",
      (["exec", quote(executable)] + command.arguments.map(quote)).joined(separator: " "),
    ]
    return lines.joined(separator: "\n") + "\n"
  }

  /// Single-quotes a value for zsh, so the shell never interprets anything
  /// inside it; an embedded apostrophe becomes `'\''`.
  public static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func join(_ base: String, _ relative: String) -> String {
    let components =
      relative
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "/")
      .map(String.init)
      .filter { $0 != "." && !$0.isEmpty }
    guard !components.isEmpty else { return base }
    return base + "/" + components.joined(separator: "/")
  }
}
