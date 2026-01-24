// swift-tools-version: 5.9
//
// IMPORTANT: Before running `swift build`, you must build the Rust core library:
//   cd <project-root> && cargo build -p hud-core --release
//
// The linkerSettings below reference ../../target/release/ where cargo places
// the libhud_core.dylib. Running swift build without the Rust build will fail
// with "library not found for -lhud_core".
//
// For first-time setup, run: ./scripts/dev/setup.sh
// For normal dev iteration: ./scripts/dev/restart-app.sh
//
import PackageDescription

let package = Package(
    name: "Capacitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Capacitor", targets: ["Capacitor"])
    ],
    dependencies: [
        .package(url: "https://github.com/daprice/Variablur.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin.git", branch: "main")
    ],
    targets: [
        // System library wrapper for the Rust FFI
        .systemLibrary(
            name: "hud_coreFFI",
            path: "Sources/HudCoreFFI"
        ),
        // Main Swift app
        .executableTarget(
            name: "Capacitor",
            dependencies: [
                "hud_coreFFI",
                .product(name: "Variablur", package: "Variablur"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Capacitor",
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/logomark.pdf")
            ],
            linkerSettings: [
                .linkedLibrary("hud_core"),
                .unsafeFlags(["-L", "../../target/release"])
            ],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ]
        ),
        // Unit tests
        .testTarget(
            name: "CapacitorTests",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Tests/CapacitorTests"
        )
    ]
)
