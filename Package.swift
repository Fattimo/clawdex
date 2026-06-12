// swift-tools-version:5.9
// clawdex — a Codex-pet-compatible companion overlay for Claude Code.
// Apache 2.0 components attribution: see skill/hatch-pet/NOTICE.

import PackageDescription

let package = Package(
    name: "clawdex",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "clawdexd",
            path: "Sources/ClawdexApp"
        ),
        .executableTarget(
            name: "clawdex",
            path: "Sources/ClawdexCLI"
        ),
        .testTarget(
            name: "ClawdexAppTests",
            dependencies: ["clawdexd"]
        )
    ]
)
