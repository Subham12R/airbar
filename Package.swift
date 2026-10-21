// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AirBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirCloudKit", targets: ["AirCloudKit"]),
        .executable(name: "AirBarApp", targets: ["AirBar"]),
        .executable(name: "airbar", targets: ["airbar-cli"]),
    ],
    targets: [
        .target(name: "AirCloudKit"),
        .executableTarget(name: "AirBar", dependencies: ["AirCloudKit"]),
        .executableTarget(name: "airbar-cli", dependencies: ["AirCloudKit"]),
        .testTarget(name: "AirCloudKitTests", dependencies: ["AirCloudKit"]),
    ]
)
