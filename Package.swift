// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "edn",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EDNCore", targets: ["EDNCore"]),
        .executable(name: "edn", targets: ["edn"]),
        .executable(name: "edn-menubar", targets: ["EDNMenuBar"])
    ],
    targets: [
        .target(
            name: "EDNCore",
            path: "Sources/EDNCore"
        ),
        .executableTarget(
            name: "edn",
            dependencies: ["EDNCore"],
            path: "Sources/edn"
        ),
        .executableTarget(
            name: "EDNMenuBar",
            dependencies: ["EDNCore"],
            path: "Sources/EDNMenuBar"
        ),
        .testTarget(
            name: "EDNCoreTests",
            dependencies: ["EDNCore"],
            path: "Tests/EDNCoreTests"
        )
    ]
)
