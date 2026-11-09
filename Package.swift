// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PMD3Bar",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (parsing, versions, geometry, dates): no UI, testable on its own.
        .target(name: "PMD3BarCore", path: "Sources/PMD3BarCore"),
        .executableTarget(name: "PMD3Bar", dependencies: ["PMD3BarCore"], path: "Sources/PMD3Bar"),
        // `make test`. A plain executable because XCTest and swift-testing ship with Xcode,
        // not with the Command Line Tools this project builds with.
        .executableTarget(name: "PMD3BarCoreTests", dependencies: ["PMD3BarCore"], path: "Tests/PMD3BarCoreTests"),
    ]
)
