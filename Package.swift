// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickMemo",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "QuickMemo", path: "Sources/QuickMemo")
    ]
)
