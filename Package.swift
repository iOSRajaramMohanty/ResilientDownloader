// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ResilientDownloader",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ResilientDownloader",
            targets: ["ResilientDownloader"]
        ),
        .executable(
            name: "ResilientDownloaderDemo",
            targets: ["ResilientDownloaderDemo"]
        ),
    ],
    targets: [
        .target(
            name: "ResilientDownloader",
            dependencies: [],
            path: "Sources/ResilientDownloader"
        ),
        .executableTarget(
            name: "ResilientDownloaderDemo",
            dependencies: ["ResilientDownloader"],
            path: "Sources/ResilientDownloaderDemo"
        ),
        .testTarget(
            name: "ResilientDownloaderTests",
            dependencies: ["ResilientDownloader"],
            path: "Tests/ResilientDownloaderTests"
        ),
    ]
)
