// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "NativeMarkdownMacApp",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "NativeMarkdownApp", targets: ["NativeMarkdownApp"]),
        .library(name: "NativeMarkdownCore", targets: ["NativeMarkdownCore"])
    ],
    targets: [
        .target(name: "NativeMarkdownCore"),
        .executableTarget(
            name: "NativeMarkdownApp",
            dependencies: ["NativeMarkdownCore"]
        ),
        .testTarget(
            name: "NativeMarkdownCoreTests",
            dependencies: ["NativeMarkdownCore"]
        )
    ]
)

