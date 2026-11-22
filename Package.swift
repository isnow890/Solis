// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "halo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "halo", targets: ["halo"])
    ],
    targets: [
        .target(
            name: "CDisplayBridge",
            path: "Sources/CDisplayBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "halo",
            dependencies: ["CDisplayBridge"],
            path: "Sources/halo",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "HaloTests", dependencies: ["halo"])
    ]
)
