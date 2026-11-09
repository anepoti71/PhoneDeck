// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PMD3Bar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PMD3Bar",
            path: "Sources/PMD3Bar"
        )
    ]
)
