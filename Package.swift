// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CassiniKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CassiniKit", targets: ["CassiniKit"]),
        .executable(name: "cassini-inspect", targets: ["cassini-inspect"]),
    ],
    targets: [
        .target(name: "CassiniKit"),
        .executableTarget(name: "cassini-inspect", dependencies: ["CassiniKit"]),
        .testTarget(
            name: "CassiniKitTests",
            dependencies: ["CassiniKit"],
            resources: [.copy("Conformance")]
        ),
    ]
)
