// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KaffinKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "Browser", targets: ["Browser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "BrowserCore", resources: [.process("Resources")]),
        .target(name: "Persistence", dependencies: ["BrowserCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Tabs", dependencies: ["BrowserCore"]),
        .target(name: "BrowserUI", dependencies: ["BrowserCore", "Tabs"]),
        .target(name: "Browser", dependencies: ["BrowserCore", "Persistence", "Tabs", "BrowserUI"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "TabsTests", dependencies: ["Tabs"]),
    ]
)
