import Foundation
import Testing

@testable import SpeditoCore

@Suite("Managed demo launch")
struct DemoLaunchTests {
  @Test("Web, app, artifact, and command-output recipes validate")
  func supportedPresentations() throws {
    let web = DemoLaunchSpecification(
      title: "Local web preview",
      launchCommand: DemoCommand(
        executable: "python3",
        arguments: ["-m", "http.server", "{{PORT}}", "--bind", "127.0.0.1"]
      ),
      portEnvironmentVariable: "PORT",
      readiness: DemoReadinessCheck(kind: .http, path: "/"),
      presentation: DemoPresentation(kind: .browser, path: "/index.html")
    )
    try DemoLaunchSpecificationValidator.validate(web)

    let app = DemoLaunchSpecification(
      title: "Reviewed app",
      preparationCommands: [
        DemoCommand(executable: "swift", arguments: ["build"])
      ],
      presentation: DemoPresentation(
        kind: .macApplication,
        path: ".build/Spedito.app"
      )
    )
    try DemoLaunchSpecificationValidator.validate(app)

    let artifact = DemoLaunchSpecification(
      title: "Design report",
      presentation: DemoPresentation(kind: .artifact, path: "docs/report.pdf")
    )
    try DemoLaunchSpecificationValidator.validate(artifact)

    let output = DemoLaunchSpecification(
      title: "Parser scenario",
      launchCommand: DemoCommand(
        executable: ".build/debug/parser-demo",
        arguments: ["sample.json"]
      ),
      presentation: DemoPresentation(kind: .commandOutput)
    )
    try DemoLaunchSpecificationValidator.validate(output)
  }

  @Test("Recipes reject shells, escaped paths, and non-loopback browser URLs")
  func unsafeRecipes() {
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Unsafe shell",
          launchCommand: DemoCommand(
            executable: "bash",
            arguments: ["-lc", "python -m http.server"]
          ),
          readiness: DemoReadinessCheck(kind: .http, path: "/"),
          presentation: DemoPresentation(kind: .browser, path: "/")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Escaped artifact",
          presentation: DemoPresentation(kind: .artifact, path: "../secret.txt")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Remote page",
          launchCommand: DemoCommand(executable: "python3"),
          readiness: DemoReadinessCheck(kind: .http, path: "/"),
          presentation: DemoPresentation(
            kind: .browser,
            path: "https://example.com"
          )
        )
      )
    }
  }

  @Test("Workspace paths cannot escape through traversal or symlinks")
  func workspacePathBoundary() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-demo-path-\(UUID())", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: workspace.appendingPathComponent("escape"),
      withDestinationURL: outside
    )

    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        "../outside",
        in: workspace
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        "escape/secret.txt",
        in: workspace
      )
    }
    #expect(
      try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        "docs/report.md",
        in: workspace
      ).path == workspace.appendingPathComponent("docs/report.md").path
    )
  }
}
