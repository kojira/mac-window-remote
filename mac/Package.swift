// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacWindowRemote",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacWindowRemote",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .testTarget(
            name: "MacWindowRemoteTests",
            dependencies: [
                "MacWindowRemote",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
