// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Suica",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SuicaCore", targets: ["SuicaCore"]),
        .executable(name: "Suica", targets: ["Suica"]),
    ],
    targets: [
        .target(name: "SuicaCore"),
        .executableTarget(name: "Suica", dependencies: ["SuicaCore"]),
        .testTarget(name: "SuicaCoreTests", dependencies: ["SuicaCore"]),
    ],
    swiftLanguageModes: [.v6]
)
