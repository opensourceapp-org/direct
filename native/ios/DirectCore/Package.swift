// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DirectCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DirectCore", targets: ["DirectCore"]),
    ],
    dependencies: [
        // Re-exports Apple CryptoKit on iOS and macOS; BoringSSL-backed on Linux for CI.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "DirectCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            resources: [.copy("Resources/bip39-english.txt")]
        ),
        .testTarget(name: "DirectCoreTests", dependencies: ["DirectCore"]),
    ]
)
