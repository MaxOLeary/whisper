// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Whisper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisper", targets: ["Whisper"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.7", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "Whisper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: ".",
            exclude: [
                "build.sh",
                "download-model.sh",
                "README.md",
                "SPEC.md",
                "eval",
                "icon",
                "Whisper.app",
                "com.maxoleary.whisper.plist",
                "VERSION",
                "entitlements.plist",
                "RELEASE.md",
                "fonts",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
