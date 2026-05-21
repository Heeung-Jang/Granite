// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Granite",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Granite", targets: ["Granite"]),
        .library(name: "NativeMarkdownCore", targets: ["NativeMarkdownCore"])
    ],
    targets: [
        .target(name: "NativeMarkdownFFI"),
        .target(
            name: "NativeMarkdownCore",
            dependencies: ["NativeMarkdownFFI"]
        ),
        .executableTarget(
            name: "Granite",
            dependencies: ["NativeMarkdownCore"]
        ),
        .testTarget(
            name: "NativeMarkdownCoreTests",
            dependencies: ["NativeMarkdownCore", "NativeMarkdownFFI"]
        )
    ]
)
