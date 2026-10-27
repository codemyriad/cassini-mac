// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CassiniKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CassiniKit", targets: ["CassiniKit"]),
        .library(name: "CassiniLibrary", targets: ["CassiniLibrary"]),
        .library(name: "CassiniLibraryWatchers", targets: ["CassiniLibraryWatchers"]),
        .library(name: "CassiniPlayback", targets: ["CassiniPlayback"]),
        .library(name: "CassiniWhistle", targets: ["CassiniWhistle"]),
        .executable(name: "cassini-whistle-worker", targets: ["cassini-whistle-worker"]),
        .library(name: "CassiniRecording", targets: ["CassiniRecording"]),
        .executable(name: "cassini-browser-host", targets: ["cassini-browser-host"]),
        .executable(name: "cassini-inspect", targets: ["cassini-inspect"]),
    ],
    targets: [
        .target(name: "CassiniKit"),
        .target(name: "CassiniLibrary", dependencies: ["CassiniKit"], resources: [.copy("Schema")]),
        .target(name: "CassiniLibraryWatchers", dependencies: ["CassiniLibrary"]),
        .target(name: "CassiniPlayback", dependencies: ["CassiniLibrary"]),
        .target(name: "CassiniWhistle"),
        .executableTarget(name: "cassini-whistle-worker", dependencies: ["CassiniWhistle"]),
        .testTarget(name: "CassiniWhistleTests", dependencies: ["CassiniWhistle"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CassiniPlaybackTests", dependencies: ["CassiniPlayback", "CassiniLibrary"]),
        .testTarget(name: "CassiniLibraryTests", dependencies: ["CassiniLibrary", "CassiniLibraryWatchers", "CassiniRecording"], exclude: ["README.md"], resources: [.copy("Golden"), .copy("LibraryVectors")]),
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
