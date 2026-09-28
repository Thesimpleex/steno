// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Steno",
    platforms: [.macOS("14.2")],  // ab 14.2 kann eine App den Ton des Macs mithören
    targets: [
        // Offizielle whisper.cpp-Bibliothek (Build b5130 = v1.9.4) mit Metal-Unterstützung.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .executableTarget(
            name: "Steno",
            dependencies: ["whisper"],
            path: "Sources/Steno"
        ),
        .testTarget(
            name: "StenoTests",
            dependencies: ["Steno"],
            path: "Tests/StenoTests"
        ),
    ]
)
