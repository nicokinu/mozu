// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mozu",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Mozu",
            path: "Sources/Mozu"
        )
    ]
)
