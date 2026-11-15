// swift-tools-version: 6.0
import PackageDescription

/// Dev hooks (REDACT_HOME, screenshot mode) exist only in debug builds; release builds ignore them.
let dev: SwiftSetting = .define("REDACT_DEV", .when(configuration: .debug))

let package = Package(
    name: "Redact",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "redact", targets: ["redact"]),
        .executable(name: "RedactApp", targets: ["RedactApp"]),
        .library(name: "RedactCore", targets: ["RedactCore"]),
    ],
    targets: [
        .target(name: "RedactCore", swiftSettings: [dev]),
        .executableTarget(
            name: "redact",
            dependencies: ["RedactCore"],
            swiftSettings: [.swiftLanguageMode(.v5), dev]
        ),
        .executableTarget(
            name: "RedactApp",
            dependencies: ["RedactCore"],
            swiftSettings: [.swiftLanguageMode(.v5), dev],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "redact-devtool", dependencies: ["RedactCore"]),
        .testTarget(name: "RedactCoreTests", dependencies: ["RedactCore"]),
    ]
)
