import Darwin

// The thread rule for camera capture. Every type in this module follows it, and the app relies
// on it.
//
// 1. The main thread never calls into an AVCaptureSession, its inputs, outputs or connections,
//    or an AVCaptureDevice (format reads, KVO registration, lockForConfiguration).
// 2. Session work runs on the recorder's camera queue; device lists and device KVO run on the
//    device queue (`CaptureDevices.queue`).
// 3. Nothing waits for a capture queue with `sync`, a semaphore or any other blocking wait.
//    Callers `await` a continuation, and capture queues hand results back with `async`.
//
// Why: `-[AVCaptureSession stopRunning]` with an AVCaptureMovieFileOutput in the graph performs a
// selector on the main thread and waits for it, while it holds the session lock. A main-thread
// call that needs the same lock (an AVCaptureVideoPreviewLayer losing its session when SwiftUI
// removes the preview, for example) then waits for the camera queue, and the app hangs for good.
// camera.mov is now written from data outputs by AVAssetWriter, but the rule stays: AVFoundation
// documents no main-thread promise for the other outputs either.

enum CaptureThread {
    /// Stops a debug build when capture work runs on the main thread. Compiled out in release.
    static func assertOffMain(_ what: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
        assert(pthread_main_np() == 0, "\(what()) must not run on the main thread (camera thread rule).",
               file: file, line: line)
    }
}

/// Carries a value that is not Sendable (an AVFoundation object) to the one queue that uses it.
struct CaptureBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
