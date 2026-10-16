// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MRAMenuBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MRACore", targets: ["MRACore"]),
        .executable(name: "MRAMenuBar", targets: ["MRAMenuBar"]),
    ],
    targets: [
        .target(name: "MRACore"),
        .executableTarget(name: "MRAMenuBar", dependencies: ["MRACore"]),
        .testTarget(name: "MRACoreTests", dependencies: ["MRACore"]),
    ],
    swiftLanguageModes: [.v6]
)
