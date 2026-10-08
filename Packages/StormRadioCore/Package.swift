// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StormRadioCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "StormRadioCore", targets: ["StormRadioCore"]),
        .executable(name: "stormradio-cli", targets: ["stormradio-cli"]),
    ],
    targets: [
        .target(name: "StormRadioCore"),
        .executableTarget(name: "stormradio-cli", dependencies: ["StormRadioCore"]),
        .testTarget(
            name: "StormRadioCoreTests",
            dependencies: ["StormRadioCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
