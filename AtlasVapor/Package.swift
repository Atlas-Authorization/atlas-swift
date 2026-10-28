// swift-tools-version:5.9
import PackageDescription

// Atlas for Vapor: session-token verification (JWKS, no network call per request) and middleware.
// A separate package on purpose: the Atlas client package stays dependency-free for apps.
let package = Package(
    name: "AtlasVapor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AtlasVapor", targets: ["AtlasVapor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "AtlasVapor",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JWTKit", package: "jwt-kit"),
            ]
        ),
        .testTarget(
            name: "AtlasVaporTests",
            dependencies: [
                "AtlasVapor",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
