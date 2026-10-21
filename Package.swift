// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AirBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirCloudKit", targets: ["AirCloudKit"]),
        .library(name: "TuyaKit", targets: ["TuyaKit"]),
        .executable(name: "AirBarApp", targets: ["AirBar"]),
        .executable(name: "airbar", targets: ["airbar-cli"]),
    ],
    targets: [
        .target(name: "AirCloudKit"),
        .target(name: "TuyaKit"),
        .executableTarget(name: "AirBar", dependencies: ["AirCloudKit", "TuyaKit"]),
        .executableTarget(name: "airbar-cli", dependencies: ["AirCloudKit", "TuyaKit"]),
        .testTarget(name: "AirCloudKitTests", dependencies: ["AirCloudKit"]),
        .testTarget(name: "TuyaKitTests", dependencies: ["TuyaKit"]),
    ]
)
