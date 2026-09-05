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
        .target(
            name: "ScreenshotQuickMarkupCore"
        ),
        .executableTarget(
            name: "ScreenshotQuickMarkup",
            dependencies: ["ScreenshotQuickMarkupCore"],
            path: "Sources/ScreenshotQuickMarkup"
        ),
        .testTarget(
            name: "ScreenshotQuickMarkupCoreTests",
            dependencies: ["ScreenshotQuickMarkupCore"]
        ),
        .testTarget(
            name: "ScreenshotQuickMarkupTests",
            dependencies: ["ScreenshotQuickMarkup"]
        )
    ]
)
