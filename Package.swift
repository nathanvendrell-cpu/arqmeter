// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Arqmeter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArqmeterCore", targets: ["ArqmeterCore"]),
        .executable(name: "Arqmeter", targets: ["Arqmeter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "ArqmeterPTY"),
        .target(name: "ArqmeterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "Arqmeter",
            dependencies: ["ArqmeterCore", "ArqmeterPTY", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .testTarget(name: "ArqmeterCoreTests", dependencies: ["ArqmeterCore", "ArqmeterPTY"]),
    ]
)
