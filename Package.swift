// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RepoMan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RepoManCore", targets: ["RepoManCore"]),
        .executable(name: "repoman", targets: ["RepoManCLI"])
    ],
    targets: [
        .target(name: "RepoManCore", path: "RepoManCore"),
        .executableTarget(name: "RepoManCLI", dependencies: ["RepoManCore"], path: "RepoManCLI"),
        .testTarget(name: "RepoManCoreTests", dependencies: ["RepoManCore"], path: "Tests/RepoManCoreTests")
    ]
)
