import AVFoundation
import MediaWriter
import RecorderCore

/// Meters the Mac mic (the screen mic, screen.mov A1's device) while nothing records, in its own
/// audio-only AVCaptureSession, so the Mac mic meter and the camera mic detector's reference run
/// before Start, next to the camera mic meter of the idle preview graph
/// (`CameraRecorder.openPreview(_:meters:)`).
///
/// Start: `await close()` before a `ScreenRecorder` whose config has a mic prepares. Its
/// ScreenCaptureKit stream opens the same mic for screen.mov and meters it from then on, so the
/// two never hold the mic at once. A take without a screen mic (Camera mode) may keep it open: the
/// detector then still has its reference. After Stop, `open()` again.
///
/// Never shows the microphone permission prompt: without access, `open()` throws. A mic check
/// (`MicCheck`) samples it instead of opening the mic again: pass `.screenMic` in `live` while
/// `isOpen`.
///
/// Thread rule (CaptureThreads.swift): the session is built, started and stopped on this meter's
/// own queue; `open` and `close` await it and never block. Calls run in the order they were made,
/// so the last of an open and a close wins.
public final class MacMicMeter: @unchecked Sendable {
    public let micUID: String
    public let levels: AudioLevelMonitor

    private let queue = DispatchQueue(label: "TwinTake.macmic", qos: .userInitiated)
    private let lock = NSLock()
    /// Set and used on `queue`; behind `lock` so `deinit` can hand it there.
    private var session: CheckSession?
    private var running = false

    /// - Parameters:
    ///   - micUID: the screen mic (`ScreenRecorderConfig.micDeviceUID`).
    ///   - levels: the app's monitor; the mic is metered as `.screenMic`.
    public init(micUID: String, levels: AudioLevelMonitor) {
        self.micUID = micUID
        self.levels = levels
    }

    deinit {
        guard let session = lock.withLock({ session }) else { return }
        let box = CaptureBox(session)
        queue.async { box.value.close() }
    }

    /// True from a successful `open()` until `close()`, while its session runs. False once the
    /// session stopped by itself (the mic was unplugged, or a runtime error): `close()` it and
    /// open a new meter. Only takes locks.
    public var isOpen: Bool {
        guard let session = lock.withLock({ running ? session : nil }) else { return false }
        return !session.hasStopped
    }

    /// Why the open session stopped by itself, or nil while it runs (or while closed). Only takes locks.
    public var stopReason: String? { lock.withLock { session }?.stopWatch.stopReason }

    /// Opens the mic and meters it into `levels`. Does nothing when it is open already.
    /// - Throws: when microphone access is not given (no prompt), the mic is not connected, or its
    ///   session does not start. The meter then stays closed.
    public func open() async throws {
        let uid = micUID, levels = levels
        let result = await onQueue { [self] () -> Result<Void, MicCheckError> in
            if lock.withLock({ session }) != nil { return .success(()) }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return .failure(.notAllowed) }
            do {
                let opened = try CheckSession.open(source: .screenMic, uid: uid, levels: levels)
                lock.withLock {
                    session = opened
                    running = true
                }
                return .success(())
            } catch let error as MicCheckError {
                return .failure(error)
            } catch {
                return .failure(.cannotOpen(name: uid, reason: error.localizedDescription))
            }
        }
        try result.get()
    }

    /// Stops the session and lets the mic go. Does nothing when it is closed.
    public func close() async {
        await onQueue { [self] in
            let closing = lock.withLock { () -> CheckSession? in
                defer { session = nil; running = false }
                return session
            }
            closing?.close()
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
