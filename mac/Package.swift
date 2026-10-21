// swift-tools-version:5.10
// Lets the project open in Xcode / build with `swift build` on a healthy toolchain.
// scripts/build-app.sh calls swiftc directly instead, so the app also builds with
// Command Line Tools installs whose SwiftPM is broken.
import PackageDescription

let package = Package(
    name: "ScreenLocalizer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenLocalizer",
            path: "Sources/ScreenLocalizer"
        )
    ]
)
