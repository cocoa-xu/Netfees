// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetFees",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NetFees", targets: ["NetFees"])],
    targets: [
        .target(name: "NetFeesCore"),
        .executableTarget(name: "NetFees", dependencies: ["NetFeesCore"]),
        .testTarget(name: "NetFeesCoreTests", dependencies: ["NetFeesCore"])
    ]
)
