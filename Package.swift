// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Flowriter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flowriter", targets: ["Flowriter"]),
    ],
    targets: [
        // One NSTextView per document. The text storage is the only copy of the text.
        .target(name: "FlowriterKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Flowriter", dependencies: ["FlowriterKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Drives the real app off screen with key and mouse events and saves pictures (README, Testing).
        .executableTarget(name: "FlowriterDrive", dependencies: ["FlowriterKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FlowriterKitTests", dependencies: ["FlowriterKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
