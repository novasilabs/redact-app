// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Redact",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "redact", targets: ["redact"]),
        .executable(name: "RedactApp", targets: ["RedactApp"]),
        .library(name: "RedactCore", targets: ["RedactCore"]),
    ],
    targets: [
        .target(name: "RedactCore"),
        .executableTarget(
            name: "redact",
            dependencies: ["RedactCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RedactApp",
            dependencies: ["RedactCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "redact-devtool", dependencies: ["RedactCore"]),
        .testTarget(name: "RedactCoreTests", dependencies: ["RedactCore"]),
    ]
)
