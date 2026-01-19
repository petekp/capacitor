// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeHUD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeHUD", targets: ["ClaudeHUD"])
    ],
    dependencies: [
        .package(url: "https://github.com/daprice/Variablur.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        // System library wrapper for the Rust FFI
        .systemLibrary(
            name: "hud_coreFFI",
            path: "Sources/HudCoreFFI"
        ),
        // Main Swift app
        .executableTarget(
            name: "ClaudeHUD",
            dependencies: [
                "hud_coreFFI",
                .product(name: "Variablur", package: "Variablur"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ClaudeHUD",
            linkerSettings: [
                .linkedLibrary("hud_core"),
                .unsafeFlags(["-L", "../../target/release"])
            ]
        ),
        // Unit tests
        .testTarget(
            name: "ClaudeHUDTests",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Tests/ClaudeHUDTests"
        )
    ]
)
