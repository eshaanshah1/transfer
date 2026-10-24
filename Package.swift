// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Transfer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Transfer",
            path: "Sources/Transfer",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
