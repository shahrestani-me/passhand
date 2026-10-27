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
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
                .linkedLibrary("Advapi32", .when(platforms: [.windows])),
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Kernel32", .when(platforms: [.windows])),
            ]
        )
    ]
)
