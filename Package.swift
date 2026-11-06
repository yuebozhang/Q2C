// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Q2C",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Q2CCore", targets: ["Q2CCore"]),
        .executable(name: "Q2C", targets: ["Q2CApp"])
    ],
    targets: [
        .target(name: "Q2CCore", path: "app/Q2CCore"),
        .executableTarget(name: "Q2CApp", dependencies: ["Q2CCore"], path: "app/Q2CApp"),
        .testTarget(name: "Q2CCoreTests", dependencies: ["Q2CCore"], path: "tests/Q2CCoreTests"),
        .testTarget(name: "Q2CAppTests", dependencies: ["Q2CApp"], path: "tests/Q2CAppTests")
    ]
)
