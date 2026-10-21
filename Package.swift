// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Automatic updates. build.sh embeds the framework in the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Headroom",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Headroom",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
