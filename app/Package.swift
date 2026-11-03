// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Octomux",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update (appcast + EdDSA-signed archives). Our own UI drives it (Updater.swift).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .executableTarget(
            name: "Octomux",
            dependencies: ["GhosttyKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Octomux",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                // Sparkle.framework: Contents/Frameworks in the bundle; next to the binary in a dev run.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
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
