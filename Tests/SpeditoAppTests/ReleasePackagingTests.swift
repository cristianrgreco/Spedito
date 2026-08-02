import Foundation
import Testing

@Suite("Release packaging")
struct ReleasePackagingTests {
  @Test("The DMG layout uses the Finder-visible mounted disk")
  func dmgLayoutMountContract() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let scriptURL = projectRoot.appendingPathComponent("scripts/build_dmg.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    #expect(script.contains("-mountrandom /Volumes"))
    #expect(script.contains("finder_disk_name=${mount_dir:t}"))
    #expect(script.contains("sleep 5"))
    #expect(
      script.contains(
        "osascript \"$layout_script\" \"$finder_disk_name\""
      )
    )
    #expect(!script.contains("-mountpoint \"$mount_dir\""))
  }
}
