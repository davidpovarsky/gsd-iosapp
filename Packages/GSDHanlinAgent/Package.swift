// swift-tools-version: 6.2
import PackageDescription

// The host adapter is intentionally isolated from the GSDKit model and the app.
// No GSD persistence code is duplicated; the host calls TaskStore mutations.
let package = Package(
    name: "GSDHanlinAgent",
    platforms: [.iOS("27.0"), .macOS(.v26)],
    products: [.library(name: "GSDHanlinAgent", targets: ["GSDHanlinAgent"])],
    dependencies: [
        .package(path: "../../GSDKit"),
        .package(path: "../../Vendor/HanlinPlatform"),
        .package(path: "../../Vendor/HanlinAgentSDK")
    ],
    targets: [
        .target(name: "GSDHanlinAgent", dependencies: [
            .product(name: "GSDModel", package: "GSDKit"),
            .product(name: "GSDStore", package: "GSDKit"),
            .product(name: "HanlinHostContracts", package: "HanlinAgentSDK"),
            .product(name: "HanlinAgentCore", package: "HanlinAgentSDK"),
            .product(name: "HanlinPersistenceAdapters", package: "HanlinAgentSDK"),
            .product(name: "HanlinPlatformContracts", package: "HanlinPlatform"),
            .product(name: "HanlinChatCore", package: "HanlinPlatform")
        ]),
        .testTarget(name: "GSDHanlinAgentTests", dependencies: [
            "GSDHanlinAgent",
            .product(name: "GSDModel", package: "GSDKit"),
            .product(name: "GSDStore", package: "GSDKit"),
            .product(name: "HanlinAgentCore", package: "HanlinAgentSDK"),
            .product(name: "HanlinHostContracts", package: "HanlinAgentSDK")
        ])
    ],
    swiftLanguageModes: [.v6]
)
