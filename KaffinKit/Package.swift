// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KaffinKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "Browser", targets: ["Browser"]),
    ],
    targets: [
        .target(name: "BrowserCore", resources: [.process("Resources")]),
        .target(name: "Tabs", dependencies: ["BrowserCore"]),
        .target(name: "BrowserUI", dependencies: ["BrowserCore", "Tabs"]),
        .target(name: "Browser", dependencies: ["BrowserCore", "Tabs", "BrowserUI"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "TabsTests", dependencies: ["Tabs"]),
    ]
)
