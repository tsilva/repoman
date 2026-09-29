// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RepoMan",
    products: [
        .library(name: "RepoManCore", targets: ["RepoManCore"])
    ],
    targets: [
        .target(name: "RepoManCore", path: "RepoManCore"),
        .testTarget(name: "RepoManCoreTests", dependencies: ["RepoManCore"], path: "Tests/RepoManCoreTests")
    ]
)
