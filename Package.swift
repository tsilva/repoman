// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RepoMan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RepoManCore", targets: ["RepoManCore"])
    ],
    targets: [
        .target(name: "RepoManCore", path: "RepoManCore", resources: [.process("Resources")]),
        .testTarget(name: "RepoManCoreTests", dependencies: ["RepoManCore"], path: "Tests/RepoManCoreTests")
    ]
)
