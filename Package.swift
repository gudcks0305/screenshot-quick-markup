// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenshotQuickMarkup",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "screenshot-quick-markup",
            targets: ["ScreenshotQuickMarkup"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ScreenshotQuickMarkup",
            path: "Sources/ScreenshotQuickMarkup"
        )
    ]
)
