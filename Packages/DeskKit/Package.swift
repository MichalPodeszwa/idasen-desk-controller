// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "DeskKit",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "DeskKit", targets: ["DeskKit"]),
    .library(name: "DeskIPC", targets: ["DeskIPC"]),
    .library(name: "DeskServer", targets: ["DeskServer"]),
    .library(name: "IdasenCLI", targets: ["IdasenCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
  ],
  targets: [
    .target(name: "DeskKit"),
    .target(
      name: "DeskKitTestSupport", dependencies: ["DeskKit"], path: "Tests/DeskKitTestSupport"),
    .target(name: "DeskIPC"),
    .target(name: "DeskServer", dependencies: ["DeskKit", "DeskIPC"]),
    .target(
      name: "IdasenCLI",
      dependencies: [
        "DeskIPC",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "DeskKitTests", dependencies: ["DeskKit", "DeskKitTestSupport"]),
    .testTarget(name: "DeskIPCTests", dependencies: ["DeskIPC"]),
    .testTarget(
      name: "DeskServerTests",
      dependencies: ["DeskServer", "DeskKit", "DeskIPC", "IdasenCLI", "DeskKitTestSupport"]),
    .testTarget(
      name: "IdasenCLITests",
      dependencies: [
        "IdasenCLI",
        "DeskIPC",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
  ]
)
