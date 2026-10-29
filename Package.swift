// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mainternance",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Mainternance", targets: ["MainternanceApp"])
    ],
    targets: [
        .target(name: "MainternanceDomain"),
        .target(name: "MainternanceData", dependencies: ["MainternanceDomain"]),
        .target(name: "MainternancePresentation", dependencies: ["MainternanceDomain"]),
        .executableTarget(
            name: "MainternanceApp",
            dependencies: ["MainternanceDomain", "MainternanceData", "MainternancePresentation"]
        ),
        .testTarget(name: "DomainTests", dependencies: ["MainternanceDomain"]),
        .testTarget(name: "DataTests", dependencies: ["MainternanceData"]),
        .testTarget(name: "PresentationTests", dependencies: ["MainternancePresentation"])
    ]
)
