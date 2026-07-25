// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "StoryPointless",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "StoryPointlessCore",
      targets: ["StoryPointlessCore"]
    ),
    .executable(
      name: "StoryPointless",
      targets: ["StoryPointlessApp"]
    ),
  ],
  targets: [
    .target(
      name: "StoryPointlessCore",
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "StoryPointlessApp",
      dependencies: ["StoryPointlessCore"]
    ),
    .testTarget(
      name: "StoryPointlessCoreTests",
      dependencies: ["StoryPointlessCore"]
    ),
    .testTarget(
      name: "StoryPointlessAppTests",
      dependencies: ["StoryPointlessApp"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
