import AppKit
import Foundation
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

/// Resolves the Codex runtime for sandbox contract tests the way the
/// application resolves it, so a contract proven here is a contract the owner
/// actually gets.
///
/// This deliberately has no "skip when missing" path. The sandbox guard that
/// preceded it returned early — and therefore passed — whenever its hardcoded
/// binary was absent, which is exactly how a fully broken sandbox coexisted
/// with green runs for weeks: an uncovered run reported itself as evidence.
enum CodexSandboxRuntimeLocator {
  enum LocatorError: Error, CustomStringConvertible {
    case noRuntime([String])

    var description: String {
      switch self {
      case .noRuntime(let searched):
        """
        No Codex runtime was found, so the sandbox profile contract could not \
        be proven. This test fails rather than skips: a silent skip is what \
        previously let a broken sandbox pass CI.

        Searched:
        \(searched.map { "  - \($0)" }.joined(separator: "\n"))

        Install Codex, or set SPEDITO_CODEX_PATH to a codex executable.
        """
      }
    }
  }

  /// The application resolves `com.openai.codex` through Launch Services, then
  /// falls back to whatever installation the owner selected. The override and
  /// the `PATH` lookup exist so a machine without the desktop app (CI) can
  /// still prove the contract.
  static func resolve() throws -> URL {
    var searched: [String] = []

    if let override = ProcessInfo.processInfo.environment["SPEDITO_CODEX_PATH"],
      !override.isEmpty
    {
      let url = URL(fileURLWithPath: override)
      if FileManager.default.isExecutableFile(atPath: url.path) {
        return url
      }
      searched.append("SPEDITO_CODEX_PATH=\(override)")
    }

    if let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: CodexInstallationDiscovery.officialBundleIdentifier
    ) {
      let url = CodexInstallationDiscovery.executableURL(forApplication: applicationURL)
      if FileManager.default.isExecutableFile(atPath: url.path) {
        return url
      }
      searched.append(url.path)
    } else {
      searched.append("Launch Services: \(CodexInstallationDiscovery.officialBundleIdentifier)")
    }

    for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
      searched.append(candidate)
    }

    throw LocatorError.noRuntime(searched)
  }
}

/// The contract every managed sandbox profile owes an ordinary product build,
/// proven against the real Codex runtime.
///
/// It asserts all three parts at once, on purpose:
///
/// 1. Ordinary filesystem work succeeds — a build script can create and delete
///    its own directories at any depth, and use `mktemp -d` under `TMPDIR`.
/// 2. Workspace secrets stay denied.
/// 3. Standard-font text rasterises — a team member rendering its own PDF or
///    PNG sees the type the product owner will see, not blank pages.
///
/// Holding them together means a future breakage of (1) or (3) cannot be
/// "fixed" by dropping the denies, because that fails (2). `CLAUDE.md` forbids
/// weakening the sandbox as a convenience fallback; this makes the rule
/// executable.
@Suite("Codex sandbox profile contract", .serialized)
struct CodexSandboxProfileContractTests {
  private static let deepestDepth = 4

  @Test(
    "Every managed profile allows ordinary workspace file work and still denies workspace secrets",
    arguments: [CodexPermissionProfiles.delivery, CodexPermissionProfiles.demo]
  )
  func profileHonorsWorkspaceContract(profile: String) async throws {
    let codexURL = try CodexSandboxRuntimeLocator.resolve()

    // The real preview-worktree location: the demo profile denies Spedito's
    // application support and preview worktree roots, so proving the contract
    // in `/tmp` would prove it somewhere the product never runs.
    let cachesRoot = try #require(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    )
    let root = cachesRoot
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      .appendingPathComponent("contract-\(UUID().uuidString.lowercased())", isDirectory: true)
    let workspace = root.appendingPathComponent("ws", isDirectory: true)
    let temporaryDirectory = workspace
      .appendingPathComponent(".spedito-demo-runtime", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    for secret in [".env", ".env.local"] {
      try Data("SECRET=topsecret\n".utf8).write(
        to: workspace.appendingPathComponent(secret)
      )
    }
    try Self.standardFontPDF().write(to: workspace.appendingPathComponent("typography.pdf"))

    let executor = CodexWorkspaceCommandExecutor(executableURL: codexURL)
    let result = try await executor.runManagedCommand(
      CodexManagedCommandRequest(
        command: ["/bin/sh", "-c", contractScript(workspace: workspace)],
        workingDirectory: workspace,
        workspaceRoot: workspace,
        environment: ["TMPDIR": temporaryDirectory.path, "LANG": "en_US.UTF-8"],
        timeoutSeconds: 60,
        permissionProfile: profile
      )
    )

    let observations = Self.observations(in: result.combinedOutput)
    let context = "profile \(profile), codex at \(codexURL.path)"

    // 1. Ordinary filesystem work.
    for depth in 1...Self.deepestDepth {
      #expect(
        observations["depth\(depth)"] == "ok",
        """
        A directory \(depth) level(s) below the workspace root could not be \
        deleted (\(context)). A deny pattern with a wildcard in a directory \
        component makes every directory at and below that component \
        undeletable. See CodexPermissionProfiles.workspaceDenyPaths.
        """
      )
    }
    #expect(
      observations["mktemp"] == "ok",
      "A mktemp build directory under TMPDIR could not be removed (\(context))."
    )

    // 2. Workspace secrets stay denied.
    #expect(
      observations["read_env"] == "blocked",
      "The workspace .env was readable (\(context))."
    )
    #expect(
      observations["read_env_suffixed"] == "blocked",
      "The workspace .env.local was readable (\(context))."
    )

    // 3. Standard-font text rasterises.
    #expect(
      observations["render"] == "ok",
      "sips could not rasterise the standard-font PDF (\(context))."
    )
    let renderURL = workspace.appendingPathComponent("typography.png")
    let darkPixels =
      FileManager.default.fileExists(atPath: renderURL.path)
      ? try Self.darkPixelCount(in: renderURL) : 0
    #expect(
      darkPixels > 500,
      """
      The standard-font PDF rendered with no visible text (\(context)): \(darkPixels) dark \
      pixels. Without the system typeface directories CoreText draws nothing, and designers \
      replaced type with hand-drawn pixel glyphs. See CodexPermissionProfiles.systemFontReadPaths.
      """
    )

    #expect(result.exitCode == 0, "\(context): \(result.combinedOutput)")
  }

  /// One script, so the whole contract costs a single sandboxed command per
  /// profile. Each observation is reported rather than asserted in-script, so a
  /// failure names which part of the contract broke instead of only its exit
  /// code.
  private func contractScript(workspace: URL) -> String {
    let root = workspace.path
    let deepest = (1...Self.deepestDepth).map { "d\($0)" }.joined(separator: "/")
    var lines = ["mkdir -p \"\(root)/\(deepest)\""]
    for depth in stride(from: Self.deepestDepth, through: 1, by: -1) {
      let path = (1...depth).map { "d\($0)" }.joined(separator: "/")
      lines.append(
        """
        if rmdir "\(root)/\(path)" 2>/dev/null; \
        then echo "depth\(depth)=ok"; else echo "depth\(depth)=denied"; fi
        """
      )
    }
    lines.append(
      """
      build_dir="$(mktemp -d "$TMPDIR/contract.XXXXXX")" && touch "$build_dir/artifact" \
      && rm -rf "$build_dir" && test ! -e "$build_dir" \
      && echo "mktemp=ok" || echo "mktemp=denied"
      """
    )
    for (label, name) in [("read_env", ".env"), ("read_env_suffixed", ".env.local")] {
      lines.append(
        """
        if cat "\(root)/\(name)" >/dev/null 2>&1; \
        then echo "\(label)=readable"; else echo "\(label)=blocked"; fi
        """
      )
    }
    lines.append(
      """
      if /usr/bin/sips -s format png "\(root)/typography.pdf" --out "\(root)/typography.png" \
      >/dev/null 2>&1; then echo "render=ok"; else echo "render=failed"; fi
      """
    )
    return lines.joined(separator: "\n")
  }

  /// One page set in Helvetica and Courier-Bold, two of the standard fonts a
  /// PDF viewer supplies without embedding. Rendering it is exactly the check a
  /// designer runs on its own screen set before handing it over.
  private static func standardFontPDF() -> Data {
    let content = """
      1 1 1 rg 0 0 400 200 re f
      BT /F1 28 Tf 0 0 0 rg 1 0 0 1 40 120 Tm (Visible Helvetica text) Tj ET
      BT /F2 20 Tf 0 0 0 rg 1 0 0 1 40 60 Tm (Courier-Bold sample) Tj ET
      """
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [5 0 R] /Count 1 >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] "
        + "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents 6 0 R >>",
      "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
    ]
    var output = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(output.utf8.count)
      output += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let crossReferenceOffset = output.utf8.count
    output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets {
      output += String(format: "%010d 00000 n \n", offset)
    }
    output +=
      "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n"
      + "\(crossReferenceOffset)\n%%EOF\n"
    return Data(output.utf8)
  }

  /// Opaque dark pixels in a rendered page. The page is white and only its
  /// text is drawn in black, so a render without type counts zero.
  private static func darkPixelCount(in url: URL) throws -> Int {
    let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
    var count = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
        if color.alphaComponent > 0.5, luminance < 0.5 {
          count += 1
        }
      }
    }
    return count
  }

  private static func observations(in output: String) -> [String: String] {
    var observations: [String: String] = [:]
    for token in output.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
      let parts = token.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      observations[String(parts[0])] = String(parts[1])
    }
    return observations
  }
}

/// A deny pattern with a wildcard in a directory component is the defect that
/// took down every delivery on 2026-09-01. This is the cheap, always-run form
/// of the real-sandbox contract above: it needs no Codex runtime, so it holds
/// even where the sandbox test cannot run.
@Suite("Workspace deny patterns")
struct WorkspaceDenyPatternTests {
  /// Checks the *rendered* profiles rather than one source array, so a deny
  /// added to any list — workspace paths, credential stores, the Spedito
  /// control plane, or something new — is covered without this test being
  /// updated to know about it.
  @Test("No deny path in any shipped profile puts a wildcard in a directory component")
  func denyPathsAvoidDirectoryWildcards() throws {
    let rendered = CodexPermissionProfiles.appServerArguments(
      demoWorkspaceRoot: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
      writableTransientStorageRoots: [URL(fileURLWithPath: "/tmp/transient", isDirectory: true)]
    ).joined(separator: " ")

    let pattern = try NSRegularExpression(pattern: #""([^"]+)"="deny""#)
    let matches = pattern.matches(
      in: rendered,
      range: NSRange(rendered.startIndex..., in: rendered)
    )
    #expect(!matches.isEmpty, "No deny entries were found, so this test proves nothing.")

    for match in matches {
      guard let range = Range(match.range(at: 1), in: rendered) else { continue }
      let path = String(rendered[range])
      for component in path.split(separator: "/").dropLast() {
        #expect(
          !component.contains("*"),
          """
          Deny path "\(path)" has a wildcard in the directory component \
          "\(component)". Codex expands each deny pattern into ancestor \
          directory-unlink denials, so this makes directories at and below \
          that component undeletable and breaks delivery. Put the wildcard in \
          the filename, or name the directory.
          """
        )
      }
    }
  }

  @Test("The launch-time and thread-time profiles deny the same workspace paths")
  func tomlAndJSONProfilesAgree() throws {
    let json = CodexPermissionProfiles.workspaceRootsFilesystemEntries
    let denied = json.filter { $0.value == .string("deny") }.keys.sorted()
    #expect(denied == CodexPermissionProfiles.workspaceDenyPaths.sorted())
    #expect(json["."] == .string("write"))

    let toml = CodexPermissionProfiles.deliveryProfileOverride
    for path in CodexPermissionProfiles.workspaceDenyPaths {
      #expect(
        toml.contains(#""\#(path)"="deny""#),
        "The TOML profile is missing the deny for \(path)."
      )
    }
    #expect(!toml.contains("**/"), "The TOML profile still contains a directory wildcard.")
  }
}
