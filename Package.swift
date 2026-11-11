// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macarum",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Macarum", targets: ["Macarum"]),
    ],
    targets: [
        .target(
            name: "MacarumCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Macarum",
            dependencies: ["MacarumCore"]
        ),
        .testTarget(
            name: "MacarumCoreTests",
            dependencies: ["MacarumCore"]
        ),
    ]
)
