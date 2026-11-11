// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NoteIt",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "NoteIt", path: "Sources/NoteIt"),
    .testTarget(name: "NoteItTests", dependencies: ["NoteIt"], path: "Tests/NoteItTests"),
  ]
)
