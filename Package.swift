// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SottoCore", targets: ["SottoCore"]),
        .executable(name: "Sotto", targets: ["Sotto"]),
        .executable(name: "SottoCoreTestHarness", targets: ["SottoCoreTestHarness"])
    ],
    targets: [
        .target(name: "SottoCore"),
        .executableTarget(
            name: "Sotto",
            dependencies: ["SottoCore"]
        ),
        .executableTarget(
            name: "SottoCoreTestHarness",
            dependencies: ["SottoCore"],
            path: "Tests/SottoCoreTestHarness"
        )
    ]
)
