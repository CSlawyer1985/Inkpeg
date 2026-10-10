// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Inkpeg",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Inkpeg", targets: ["Inkpeg"])],
    targets: [
        .target(name: "InkpegCore", resources: [.process("Resources")]),
        .executableTarget(name: "Inkpeg", dependencies: ["InkpegCore"], path: "Sources/Tendedero"),
        .testTarget(name: "InkpegCoreTests", dependencies: ["InkpegCore"]),
        .testTarget(name: "InkpegAppTests", dependencies: ["Inkpeg", "InkpegCore"])
    ]
)
