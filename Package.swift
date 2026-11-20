// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KeySight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KeySightCore", targets: ["KeySightCore"]),
        .executable(name: "KeySight", targets: ["KeySightApp"])
    ],
    targets: [
        .target(
            name: "KeySightCore",
            path: "Sources/KeySightCore"
        ),
        .executableTarget(
            name: "KeySightApp",
            dependencies: ["KeySightCore"],
            path: "Sources/KeySightApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "KeySightCoreTests",
            dependencies: ["KeySightCore"],
            path: "Tests/KeySightCoreTests"
        )
    ]
)
