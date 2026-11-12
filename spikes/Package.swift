// swift-tools-version: 6.0
// M0 spikes for Redact. Throwaway-quality code; findings go into spikes/FINDINGS.md.
import PackageDescription

let package = Package(
    name: "RedactSpikes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RedactCore", targets: ["RedactCore"]),
    ],
    targets: [
        .target(name: "RedactCore"),
        .executableTarget(name: "spike-se", dependencies: ["RedactCore"]),
        .executableTarget(name: "spike-ipc", dependencies: ["RedactCore"]),
        .executableTarget(name: "spike-redact", dependencies: ["RedactCore"]),
        .testTarget(name: "RedactCoreTests", dependencies: ["RedactCore"]),
    ]
)
