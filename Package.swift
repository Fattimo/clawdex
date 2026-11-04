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
        .target(name: "ClawdexGitHub", path: "Sources/ClawdexGitHub"),
        .executableTarget(
            name: "clawdexd",
            dependencies: ["ClawdexGitHub"],
            path: "Sources/ClawdexApp"
        ),
        .executableTarget(
            name: "clawdex",
            dependencies: ["ClawdexGitHub"],
            path: "Sources/ClawdexCLI"
        ),
        .testTarget(
            name: "ClawdexGitHubTests",
            dependencies: ["ClawdexGitHub"]
        ),
        .testTarget(
            name: "ClawdexAppTests",
            dependencies: ["clawdexd"]
        )
    ]
)
