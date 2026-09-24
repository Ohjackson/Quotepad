// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Quotepad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Quotepad", path: "Sources/Quotepad")
    ]
)
