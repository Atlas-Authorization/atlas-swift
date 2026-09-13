// swift-tools-version:5.9
import PackageDescription

// Atlas — the official native iOS/macOS Swift SDK for the Atlas auth platform.
//
// Dependency-light on purpose: the whole client is URLSession + Foundation +
// Security (Keychain). No third-party packages, so `swift build` needs no
// network fetch and the surface stays auditable.
let package = Package(
    name: "Atlas",
    platforms: [
        // async/await + the Keychain APIs used here.
        .iOS(.v13),
        .macOS(.v12),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "Atlas", targets: ["Atlas"]),
    ],
    targets: [
        .target(
            name: "Atlas",
            path: "Sources/Atlas"
        ),
        .testTarget(
            name: "AtlasTests",
            dependencies: ["Atlas"],
            path: "Tests/AtlasTests"
        ),
    ]
)
