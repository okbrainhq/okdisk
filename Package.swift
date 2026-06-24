// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OKDisk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "OKDiskCore", targets: ["OKDiskCore"]),
        .executable(name: "OKDiskApp", targets: ["OKDiskApp"]),
        .executable(name: "OKDiskCoreTests", targets: ["OKDiskCoreTests"]),
        .executable(name: "OKDiskE2ETests", targets: ["OKDiskE2ETests"])
    ],
    targets: [
        .target(
            name: "OKDiskCore",
            path: "Sources/OKDiskCore"
        ),
        .executableTarget(
            name: "OKDiskApp",
            dependencies: ["OKDiskCore"],
            path: "Sources/OKDiskApp"
        ),
        .executableTarget(
            name: "OKDiskCoreTests",
            dependencies: ["OKDiskCore"],
            path: "Tests/OKDiskCoreTests"
        ),
        .executableTarget(
            name: "OKDiskE2ETests",
            dependencies: ["OKDiskCore"],
            path: "Tests/OKDiskE2ETests"
        )
    ],
    swiftLanguageModes: [.v5]
)
