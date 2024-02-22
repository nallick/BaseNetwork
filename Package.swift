// swift-tools-version:5.3

import PackageDescription

#if os(Linux)

let package = Package(
    name: "BaseNetwork",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(
            name: "BaseNetwork",
            targets: ["BaseNetwork"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nallick/BaseSwift.git",  from: "1.0.0"),
        .package(url: "https://github.com/nallick/dns_sd.git",  from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "BaseNetwork",
            dependencies: ["BaseSwift", "dns_sd"]),
    ]
)

#else

let package = Package(
    name: "BaseNetwork",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(
            name: "BaseNetwork",
            targets: ["BaseNetwork"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nallick/BaseSwift.git",  from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "BaseNetwork",
            dependencies: ["BaseSwift"]),
    ]
)

#endif
