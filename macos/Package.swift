// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "WinSCPMac",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "ScpCore", path: "Sources/ScpCore"),
        .executableTarget(name: "WinSCPMac", dependencies: ["ScpCore"], path: "Sources/WinSCPMac"),
        .testTarget(name: "ScpCoreTests", dependencies: ["ScpCore"], path: "Tests/ScpCoreTests"),
    ]
)
