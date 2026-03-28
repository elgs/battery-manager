// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BatteryManager",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "SMCWriter",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
