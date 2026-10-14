// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwinTake",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TwinTake", targets: ["RecorderApp"]),
    ],
    targets: [
        // Shared models, session folder, event log, geometry. No capture code.
        .target(name: "RecorderCore"),
        // What camera.mov and screen.mov share: the exact frame-rate grid math, the audio
        // aligner and pipeline, and the AVAssetWriter settings. No capture devices.
        .target(name: "MediaWriter", dependencies: ["RecorderCore"]),
        // Camera (capture card) to camera.mov.
        .target(name: "CameraCapture", dependencies: ["RecorderCore", "MediaWriter"]),
        // Screen frame + mic + system audio to screen.mov.
        .target(name: "ScreenCapture", dependencies: ["RecorderCore", "MediaWriter"]),
        // Window snapping (Accessibility), frame overlay, global hotkeys.
        .target(name: "WindowTools", dependencies: ["RecorderCore"]),
        // Replay while recording: reads the growing camera.mov and screen.mov (never writes them),
        // plays them on one timebase, Skip silence and Flags only. No capture code.
        .target(name: "Replay", dependencies: ["RecorderCore"]),
        // Menu-bar app that ties the pieces together.
        .executableTarget(
            name: "RecorderApp",
            dependencies: ["RecorderCore", "CameraCapture", "ScreenCapture", "WindowTools", "Replay"]
        ),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
        .testTarget(name: "MediaWriterTests", dependencies: ["MediaWriter", "RecorderCore"]),
        .testTarget(name: "CameraCaptureTests", dependencies: ["CameraCapture", "MediaWriter"]),
        .testTarget(name: "ScreenCaptureTests", dependencies: ["ScreenCapture", "MediaWriter"]),
        .testTarget(name: "WindowToolsTests", dependencies: ["WindowTools"]),
        .testTarget(name: "ReplayTests", dependencies: ["Replay", "RecorderCore", "MediaWriter"]),
        .testTarget(name: "RecorderAppTests", dependencies: ["RecorderApp", "RecorderCore", "ScreenCapture", "WindowTools", "Replay"]),
        // Dev only, never in TwinTake.app: renders the app's own views with sample data to
        // docs/images (scripts/render-docs-images.sh). A test target, because only a test target
        // can import the app's executable target. Skipped unless TWINTAKE_DOCSHOTS_DIR is set.
        .testTarget(
            name: "DocShots",
            dependencies: ["RecorderApp", "RecorderCore", "CameraCapture", "WindowTools", "Replay"]
        ),
    ]
)
