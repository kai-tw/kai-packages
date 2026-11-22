// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "keychain",
    // Flutter's own current floor, not something this package's native code
    // needs.
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "keychain", targets: ["keychain"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "keychain",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
