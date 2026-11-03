// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenStorm",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "OpenStormCore", targets: ["OpenStormCore"]),
        .executable(name: "OpenStormApp", targets: ["OpenStormApp"])
    ],
    targets: [
        .target(
            name: "OpenStormCore",
            path: "Sources/OpenStormCore"
        ),
        .executableTarget(
            name: "OpenStormApp",
            dependencies: ["OpenStormCore"],
            path: "Sources/OpenStormApp",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalFX"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("AVFAudio")
            ]
        ),
        .testTarget(
            name: "OpenStormTests",
            dependencies: ["OpenStormCore"],
            path: "Tests/OpenStormTests"
        )
    ]
)
