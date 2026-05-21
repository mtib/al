// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Al",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CSherpa",
            path: "Sources/CSherpa",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L./build/sherpa-prefix/lib",
                    "-lsherpa-onnx-c-api",
                    "-lc++",
                ]),
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "Al",
            dependencies: ["CSherpa"],
            path: "Sources/Al",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
