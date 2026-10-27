// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "passhand",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "passhand",
            path: "Sources/passhand",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        )
    ]
)
