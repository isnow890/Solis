// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Solis",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Solis", targets: ["Solis"])
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
            name: "Solis",
            dependencies: ["CDisplayBridge"],
            path: "Sources/Solis",
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
        )
    ]
)
