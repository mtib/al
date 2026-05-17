// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Al",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags([
                    "-Wno-implicit-function-declaration",
                    "-Wno-null-dereference",
                ]),
            ]
        ),
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L./build/whisper-prefix/lib",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-blas",
                    "-lggml-metal",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "Al",
            dependencies: ["CRNNoise", "CWhisper"],
            path: "Sources/Al",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
