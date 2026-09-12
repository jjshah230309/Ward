// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ward",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Ward",
            path: "Sources/Ward",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
