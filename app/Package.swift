// swift-tools-version:5.10
// The Shiibar GH menu bar app (docs/DESIGN.md, "Implementation"). macOS 14 or
// later on Apple Silicon. Logic that can run without a screen lives in
// ShiibarGhCore and is covered by `swift test`; ShiibarGhApp wires it to
// AppKit, SwiftUI, UserNotifications and ServiceManagement.
//
// Tools version 5.10: the macos-15 runner's default Xcode is 16.4
// (actions/runner-images, images/macos/macos-15-arm64-Readme.md, image
// 20261028), which builds packages up to tools version 6.1, and 5.10 keeps
// the Swift 5 language mode.

import PackageDescription

let package = Package(
    name: "ShiibarGh",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "ShiibarGhCore",
            path: "Sources/ShiibarGhCore"
        ),
        .executableTarget(
            name: "ShiibarGhApp",
            dependencies: ["ShiibarGhCore"],
            path: "Sources/ShiibarGhApp"
        ),
        .testTarget(
            name: "ShiibarGhCoreTests",
            dependencies: ["ShiibarGhCore"],
            path: "Tests/ShiibarGhCoreTests"
        ),
    ]
)
