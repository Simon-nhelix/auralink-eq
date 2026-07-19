// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Auralink",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AuralinkCore", targets: ["AuralinkCore"]),
        .executable(name: "AuralinkApp", targets: ["AuralinkApp"]),
        .executable(name: "AuralinkBenchmarks", targets: ["AuralinkBenchmarks"])
    ],
    targets: [
        // MARK: Pure-logic core — data model, DSP, presets, knowledge base.
        // No UI / no audio-hardware dependencies, so it is fully unit-testable.
        .target(
            name: "AuralinkCore",
            dependencies: ["AuralinkRT"],
            resources: [
                .copy("Resources/data")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        // MARK: Realtime-safe C primitives — lock-free SPSC ring buffer and
        // atomic meters shared between the capture/render audio threads.
        .target(
            name: "AuralinkRT"
        ),

        // MARK: The menubar app — SwiftUI UI, AVFoundation audio routing,
        // and the local HTTP control server the MCP server talks to.
        .executableTarget(
            name: "AuralinkApp",
            dependencies: ["AuralinkCore", "AuralinkRT"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Work around macOS 26 / SwiftUI executor-check crashes where
                // generated view-builder closures hand the runtime a bogus
                // SerialExecutorRef during dynamic actor isolation checks.
                // AppModel is explicitly @MainActor and all audio callbacks hop
                // back to it, so disabling the runtime check for the UI target
                // avoids the framework crash without weakening the realtime C/DSP targets.
                .unsafeFlags([
                    "-Xfrontend", "-disable-dynamic-actor-isolation",
                    "-Xfrontend", "-disable-actor-data-race-checks"
                ])
            ]
        ),

        // MARK: Reproducible Release-mode callback timing for both DSP rails.
        .executableTarget(
            name: "AuralinkBenchmarks",
            dependencies: ["AuralinkCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        .testTarget(
            name: "AuralinkCoreTests",
            dependencies: ["AuralinkCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        .testTarget(
            name: "AuralinkRTTests",
            dependencies: ["AuralinkRT"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
