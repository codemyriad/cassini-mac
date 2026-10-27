// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CassiniKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CassiniKit", targets: ["CassiniKit"]),
        .library(name: "CassiniRecording", targets: ["CassiniRecording"]),
        .executable(name: "cassini-browser-host", targets: ["cassini-browser-host"]),
        .executable(name: "cassini-inspect", targets: ["cassini-inspect"]),
    ],
    targets: [
        .target(name: "CassiniKit"),
        .target(name: "CassiniRecording", dependencies: ["CassiniKit"]),
        .executableTarget(name: "cassini-browser-host", dependencies: ["CassiniRecording"]),
        .testTarget(name: "CassiniRecordingTests", dependencies: ["CassiniRecording"]),
        .executableTarget(name: "cassini-inspect", dependencies: ["CassiniKit"]),
        .testTarget(
            name: "CassiniKitTests",
            dependencies: ["CassiniKit"],
            resources: [.copy("Conformance")]
        ),
    ]
)
