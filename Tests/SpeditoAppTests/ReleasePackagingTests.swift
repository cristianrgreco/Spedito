import AppKit
import Foundation
import Testing

@Suite("Release packaging")
struct ReleasePackagingTests {
  @Test("The DMG delegates disk-image handling to create-dmg")
  func createDMGContract() throws {
    let script = try buildDMGScript()
    let workflow = try String(
      contentsOf: projectRoot().appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8
    )
    let verification = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/verify_dmg.sh"),
      encoding: .utf8
    )
    let backgroundGenerator = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/generate_dmg_background.swift"),
      encoding: .utf8
    )

    #expect(script.contains("\"$create_dmg\" \\"))
    #expect(script.contains("--background \"$background_path\""))
    #expect(script.contains("DMGBackground.tiff"))
    #expect(script.contains("--window-size 660 468"))
    #expect(script.contains("--icon \"Spedito.app\" 180 240"))
    #expect(script.contains("--app-drop-link 480 240"))
    #expect(script.contains("--no-internet-enable"))
    #expect(workflow.contains("CREATE_DMG_REVISION: 118f131aa57c1278aca806eb37cf5021e9064198"))
    #expect(!workflow.contains("brew install create-dmg"))
    #expect(!script.contains("hdiutil"))
    #expect(!script.contains("osascript"))
    #expect(!script.contains("--volicon"))
    #expect(!verification.contains(".VolumeIcon.icns"))
    #expect(verification.contains("DMGBackground.tiff"))
    #expect(backgroundGenerator.contains("private let scaleFactors = [1, 2]"))
    #expect(backgroundGenerator.contains("image.tiffRepresentation"))
    #expect(!backgroundGenerator.contains("EARLY PREVIEW"))
  }

  @Test("The DMG background includes standard and Retina artwork")
  @MainActor
  func backgroundResolutionContract() throws {
    let backgroundURL = projectRoot()
      .appendingPathComponent("Distribution/DMGBackground.tiff")
    let image = try #require(NSImage(contentsOf: backgroundURL))

    #expect(image.size == NSSize(width: 660, height: 440))
    #expect(
      image.representations.contains {
        $0.pixelsWide == 660 && $0.pixelsHigh == 440
      }
    )
    #expect(
      image.representations.contains {
        $0.pixelsWide == 1_320 && $0.pixelsHigh == 880
      }
    )
  }

  @Test("The release and website use a stable latest-download DMG")
  func stableLatestDownloadContract() throws {
    let projectRoot = projectRoot()
    let workflow = try String(
      contentsOf: projectRoot.appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8
    )
    let website = try String(
      contentsOf: projectRoot.appendingPathComponent("Website/index.html"),
      encoding: .utf8
    )
    let downloadURL =
      "https://github.com/cristianrgreco/spedito/releases/latest/download/Spedito.dmg"

    #expect(workflow.contains("dmg=\"Spedito.dmg\""))
    #expect(!workflow.contains("macOS-Apple-Silicon.dmg"))
    #expect(website.components(separatedBy: downloadURL).count - 1 == 2)
    #expect(!website.contains("/Spedito/releases/latest\""))
  }

  @Test("Development relaunch refreshes a stale GitHub App registration")
  func developmentRelaunchRefreshesGitHubConfiguration() throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-GitHub-Config-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: fixture) }
    let bin = fixture.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let gh = bin.appendingPathComponent("gh")
    try Data(
      """
      #!/bin/sh
      case "$3" in
        SPEDITO_GITHUB_CLIENT_ID) printf '%s\\n' 'current-client-id' ;;
        SPEDITO_GITHUB_APP_SLUG) printf '%s\\n' 'current-app-slug' ;;
        *) exit 64 ;;
      esac
      """.utf8
    ).write(to: gh)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: gh.path
    )

    let infoPlist = fixture.appendingPathComponent("Info.plist")
    let staleConfiguration = [
      "SpeditoGitHubClientID": "deleted-client-id",
      "SpeditoGitHubAppSlug": "deleted-app-slug",
    ]
    try PropertyListSerialization.data(
      fromPropertyList: staleConfiguration,
      format: .xml,
      options: 0
    ).write(to: infoPlist)

    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = projectRoot()
      .appendingPathComponent("scripts/resolve_github_app_config.sh")
    process.arguments = [projectRoot().path, infoPlist.path]
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "SPEDITO_GITHUB_CLIENT_ID")
    environment.removeValue(forKey: "SPEDITO_GITHUB_APP_SLUG")
    environment["PATH"] = "\(bin.path):/usr/bin:/bin"
    process.environment = environment
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()

    let standardOutput = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let standardError = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
    #expect(
      standardOutput
        == """
          client_id=current-client-id
          app_slug=current-app-slug

          """
    )
  }

  private func buildDMGScript() throws -> String {
    let scriptURL = projectRoot().appendingPathComponent("scripts/build_dmg.sh")
    return try String(contentsOf: scriptURL, encoding: .utf8)
  }

  private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
