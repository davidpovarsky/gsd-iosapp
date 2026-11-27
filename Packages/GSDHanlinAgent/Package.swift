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
        .package(path: "../../Vendor/HanlinSDK")
    ],
    targets: [
        .target(name: "GSDHanlinAgent", dependencies: [
            .product(name: "GSDModel", package: "GSDKit"),
            .product(name: "GSDStore", package: "GSDKit"),
            .product(name: "HanlinHostContracts", package: "HanlinSDK"),
            .product(name: "HanlinAgentCore", package: "HanlinSDK"),
            .product(name: "HanlinPersistenceAdapters", package: "HanlinSDK"),
            .product(name: "HanlinPlatformContracts", package: "HanlinSDK"),
            .product(name: "HanlinChatCore", package: "HanlinSDK")
        ]),
        .testTarget(name: "GSDHanlinAgentTests", dependencies: [
            "GSDHanlinAgent",
            .product(name: "GSDModel", package: "GSDKit"),
            .product(name: "GSDStore", package: "GSDKit"),
            .product(name: "HanlinAgentCore", package: "HanlinSDK"),
            .product(name: "HanlinHostContracts", package: "HanlinSDK"),
            .product(name: "HanlinPersistenceAdapters", package: "HanlinSDK"),
            .product(name: "HanlinChatCore", package: "HanlinSDK")
        ])
    ],
    swiftLanguageModes: [.v6]
)
