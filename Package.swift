// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenConnectSandbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenConnectSandboxCore", targets: ["OpenConnectSandboxCore"]),
        .executable(name: "OpenConnectSandbox", targets: ["OpenConnectSandboxApp"]),
        .executable(name: "OpenConnectSandboxSupervisor", targets: ["OpenConnectSandboxSupervisor"]),
        .executable(name: "OpenConnectSandboxExec", targets: ["ProcessGroupExec"]),
        .executable(name: "vpnctl", targets: ["VPNCTL"]),
    ],
    targets: [
        .target(name: "OpenConnectSandboxCore"),
        .executableTarget(
            name: "OpenConnectSandboxApp",
            dependencies: ["OpenConnectSandboxCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "OpenConnectSandboxSupervisor",
            dependencies: ["OpenConnectSandboxCore"]
        ),
        .executableTarget(name: "VPNCTL", dependencies: ["OpenConnectSandboxCore"]),
        .executableTarget(name: "ProcessGroupExec", path: "Sources/ProcessGroupExec"),
        .testTarget(
            name: "OpenConnectSandboxCoreTests",
            dependencies: ["OpenConnectSandboxCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
