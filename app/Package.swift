// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Octomux",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .executableTarget(
            name: "Octomux",
            dependencies: ["GhosttyKit"],
            path: "Sources/Octomux",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(name: "OctomuxTests", dependencies: ["Octomux"], path: "Tests/OctomuxTests"),
    ]
)
