// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Arqmeter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArqmeterCore", targets: ["ArqmeterCore"]),
        .executable(name: "Arqmeter", targets: ["Arqmeter"]),
    ],
    targets: [
        .target(name: "ArqmeterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "Arqmeter",
            dependencies: ["ArqmeterCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .testTarget(name: "ArqmeterCoreTests", dependencies: ["ArqmeterCore"]),
    ]
)
