// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPMXPhase0",
    // The real floor for the source is macOS 14 (AVSampleBufferDisplayLayer.sampleBufferRenderer,
    // and ScreenCaptureKit before that). The 26.0 here is imposed by Homebrew's libx264, whose
    // bottle is built with a macOS 26 deployment target: declaring anything lower makes the
    // linker warn that we promise more compatibility than the dylib delivers, and the binary
    // would fail to load on those systems anyway. Build x264 from source with
    // -mmacosx-version-min=14.0 to lower this back. `.v26` is not in PackageDescription yet,
    // hence the string form.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ipmx-encoder", targets: ["ipmx-encoder"]),
        .executable(name: "ipmx-decoder", targets: ["ipmx-decoder"]),
        .library(name: "IPMXCore", targets: ["IPMXCore"]),
    ],
    targets: [
        // x264 from Homebrew. `brew install x264 pkg-config`
        .systemLibrary(
            name: "CX264",
            path: "Sources/CX264",
            pkgConfig: "x264",
            providers: [.brew(["x264"])]
        ),

        // Transport + bitstream plumbing shared by both ends.
        .target(name: "IPMXCore"),

        // ScreenCaptureKit -> x264 -> RFC 6184 -> UDP
        .executableTarget(
            name: "ipmx-encoder",
            dependencies: ["IPMXCore", "CX264"]
        ),

        // UDP -> RFC 6184 -> VideoToolbox -> AVSampleBufferDisplayLayer
        .executableTarget(
            name: "ipmx-decoder",
            dependencies: ["IPMXCore"]
        ),

        // Behaviour lives in swift-testing suites; throughput measurement lives in XCTest,
        // which is still the only one of the two with a performance-measurement API.
        // Both frameworks coexist in a single target.
        .testTarget(name: "IPMXCoreTests", dependencies: ["IPMXCore"]),
    ],
    swiftLanguageModes: [.v5]
)
