// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TeamsLite",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "TeamsLite", targets: ["TeamsLite"])
    ],
    targets: [
        .executableTarget(
            name: "TeamsLite",
            path: "Sources/TeamsLite"
        )
    ]
)
