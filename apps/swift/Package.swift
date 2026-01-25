// swift-tools-version: 5.9
//
// IMPORTANT: Before running `swift build`, you must build the Rust core library:
//   cd <project-root> && cargo build -p capacitor-core --release
//
// The linkerSettings below reference ../../target/release/ where cargo places
// the libcapacitor_core.dylib. Running swift build without the Rust build will fail
// with "library not found for -lcapacitor_core".
//
// For first-time setup, run: ./scripts/dev/setup.sh
// For normal dev iteration: ./scripts/dev/restart-app.sh
//
import PackageDescription

let package = Package(
    name: "Capacitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Capacitor", targets: ["Capacitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // System library wrapper for the Rust FFI
        .systemLibrary(
            name: "capacitor_coreFFI",
            path: "Sources/CapacitorCoreFFI"
        ),
        .target(
            name: "ReadyChimeObjCExceptionCatcher",
            path: "Sources/ReadyChimeObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        // Main Swift app
        .executableTarget(
            name: "Capacitor",
            dependencies: [
                "capacitor_coreFFI",
                "ReadyChimeObjCExceptionCatcher",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Capacitor",
            exclude: [
                "Shaders",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/logomark.pdf"),
                .process("Resources/logo.pdf"),
                .process("Resources/logo-small.pdf"),
                .copy("Resources/Shaders/default.metallib"),
            ],
            linkerSettings: [
                .linkedLibrary("capacitor_core"),
                .unsafeFlags(["-L", "../../target/release"]),
            ]
        ),
        // Unit tests
        .testTarget(
            name: "CapacitorTests",
            dependencies: [
                "Capacitor",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Tests/CapacitorTests"
        )
    ]
)
