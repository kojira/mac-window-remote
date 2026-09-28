// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacWindowRemote",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        // D20: prebuilt WebRTC.xcframework (Chromium M153).
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0"),
        // Already resolved through Hummingbird; listed to name the `Tailscale-User-Login` header.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        // Already resolved through hummingbird-websocket; the auth tests set request headers.
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacWindowRemote",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            // WebRTC.framework is embedded in Contents/Frameworks by scripts/build-app.sh (D20).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "MacWindowRemoteTests",
            dependencies: [
                "MacWindowRemote",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
                .product(name: "WSClient", package: "swift-websocket"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
