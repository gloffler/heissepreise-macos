// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeissePreise",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HeissePreise", targets: ["HeissePreise"]),
        .executable(name: "pricebench", targets: ["pricebench"]),
    ],
    targets: [
        .target(
            name: "PriceCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(name: "HeissePreise", dependencies: ["PriceCore"]),
        .executableTarget(name: "pricebench", dependencies: ["PriceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
