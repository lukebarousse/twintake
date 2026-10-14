import AVFoundation
import MediaWriter
import RecorderCore

/// A short mic check while nothing records: the meters and the camera mic detector for the
/// camera audio and the screen mic, without touching the camera's video session. Also the two
/// samples of the mic warning calibration.
///
/// Sources: a source in `live` already meters into `levels` (the camera mic meter of the idle
/// preview graph, `CameraRecorder.idleMetersOn`; the idle Mac mic, `MacMicMeter.isOpen`). The
/// check then only samples that live stream: it opens no session, so it can never hold a device
/// a second time next to the camera graph or the idle mic. Every other source with a uid gets its
/// own audio-only AVCaptureSession for the check (`defaultSeconds`), which then closes again, so
/// the orange microphone indicator shows only during the check.
///
/// Use: `let result = await MicCheck(cameraAudioUID:screenMicUID:levels:live:).run()`; poll
/// `levels.snapshot()` meanwhile for the meters and the live verdict. `cancel()` (or cancelling
/// the task that awaits `run`) ends it early. Two results, one with the external mic plugged in
/// and one without, make a calibration: `MicCalibration.make(plugged:unplugged:)`; check
/// `result.sample.problem` first (`cameraSilent`: the camera sent no voice while the Mac mic heard
/// it, so the camera did not switch to its built-in mic).
///
/// Thread rule (CaptureThreads.swift): the check's own sessions are built, started and stopped on
/// the check's own queue; `run` awaits it and `cancel` only fires a signal, so the main thread
/// never touches a capture object or waits for a capture queue. Cancel the check before Start: a
/// take opens the camera audio in the camera session.
public final class MicCheck: @unchecked Sendable {
    public struct Result: Sendable, Equatable {
        /// The detector at the end of the check.
        public var status: MicDetectorStatus
        /// What the check heard: one calibration sample.
        public var sample: MicFeatureSample
        /// The camera audio delivered up to the end of the check, from its own session or its live
        /// meter. False also for a session that opened but sent nothing (see `errors`).
        public var cameraMicOpened: Bool
        public var screenMicOpened: Bool
        /// Ended early by `cancel()` or task cancellation.
        public var cancelled: Bool
        /// Devices that could not open, permission, or "already running".
        public var errors: [String]
        /// The sources the check sampled from their live meters (it opened no session for them).
        public var liveSources: Set<AudioSource> = []
    }

    public static let defaultSeconds = 10.0

    public let cameraAudioUID: String?
    public let screenMicUID: String?
    public let levels: AudioLevelMonitor
    /// Sources that already meter into `levels`: the check opens no session for them.
    public let live: Set<AudioSource>

    private let queue = DispatchQueue(label: "TwinTake.miccheck", qos: .userInitiated)
    private let lock = NSLock()
    private var stopSignal: OneShot<Bool>?

    /// - Parameters:
    ///   - cameraAudioUID: the camera audio input (`CameraRecorderConfig.audioDeviceUID`), nil to skip it.
    ///   - screenMicUID: the screen mic (`ScreenRecorderConfig.micDeviceUID`), nil to skip it.
    ///   - levels: the app's monitor; the check starts its detector over with `MicDetectorSettings.micCheck`.
    ///   - live: the sources that meter into `levels` now (`.cameraMic` while
    ///     `CameraRecorder.idleMetersOn`, `.screenMic` while `MacMicMeter.isOpen`). Keep them open
    ///     until `run` returns.
    public init(cameraAudioUID: String?, screenMicUID: String?, levels: AudioLevelMonitor, live: Set<AudioSource> = []) {
        self.cameraAudioUID = cameraAudioUID
        self.screenMicUID = screenMicUID
        self.levels = levels
        self.live = live.intersection([.cameraMic, .screenMic])
    }

    /// True while `run` runs.
    public var isRunning: Bool { lock.withLock { stopSignal != nil } }

    /// Ends a running check now; `run` returns once its own sessions closed. Never waits.
    public func cancel() {
        lock.withLock { stopSignal }?.fire(true)
    }

    /// Samples the live sources and opens the other mics for `seconds`, meters them, closes what it
    /// opened, and returns what it heard.
    public func run(seconds: Double = MicCheck.defaultSeconds) async -> Result {
        let signal = OneShot<Bool>()
        let started = lock.withLock { () -> Bool in
            guard stopSignal == nil else { return false }
            stopSignal = signal
            return true
        }
        guard started else {
            return Result(status: levels.detectorStatus, sample: MicFeatureSample(), cameraMicOpened: false,
                          screenMicOpened: false, cancelled: false, errors: ["A mic check is already running."])
        }
        defer { lock.withLock { stopSignal = nil } }

        let live = live
        // A live source is never opened a second time.
        let wanted = [(AudioSource.cameraMic, cameraAudioUID), (.screenMic, screenMicUID)]
            .compactMap { source, uid in uid.map { (source, $0) } }
            .filter { !live.contains($0.0) }
        let levels = levels
        func failed(_ message: String) -> Result {
            Result(status: levels.detectorStatus, sample: MicFeatureSample(), cameraMicOpened: false,
                   screenMicOpened: false, cancelled: false, errors: [message])
        }
        guard !wanted.isEmpty || !live.isEmpty else { return failed("No mic is set for the check.") }
        // Only a mic the check opens itself needs the permission (and may show its prompt).
        if !wanted.isEmpty {
            guard await Self.microphoneAllowed() else {
                return failed("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
            }
        }
        // Cancelled while the permission prompt was up (Start may run a take by now): the check
        // neither resets the monitor nor opens a mic.
        guard signal.value == nil, !Task.isCancelled else {
            return Result(status: levels.detectorStatus, sample: MicFeatureSample(), cameraMicOpened: false,
                          screenMicOpened: false, cancelled: true, errors: [])
        }
        levels.beginCheck()
        let (opened, openErrors): (CaptureBox<[CheckSession]>, [String]) = wanted.isEmpty ? (CaptureBox([]), []) : await onQueue {
            var sessions: [CheckSession] = []
            var errors: [String] = []
            for (source, uid) in wanted {
                // A cancel that came while the first mic opened: the second one stays closed.
                guard signal.value == nil else { break }
                do { sessions.append(try CheckSession.open(source: source, uid: uid, levels: levels)) } catch {
                    errors.append(error.localizedDescription)
                }
            }
            return (CaptureBox(sessions), errors)
        }
        var errors = openErrors
        let sources = Set(opened.value.map(\.source)).union(live)

        // Cancelled while the mics opened, maybe before any opened.
        var cancelled = signal.value == true
        if !sources.isEmpty {
            let timer = Task {
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                signal.fire(false)
            }
            cancelled = await withTaskCancellationHandler {
                await signal.wait()
            } onCancel: {
                signal.fire(true)
            }
            timer.cancel()
        }
        // A source that delivers nothing by the end: a live one whose camera or mic closed
        // meanwhile, or a session of the check's own that opened but sent no buffer (it would
        // otherwise read as "no voice": a camera that sends nothing is not a quiet talker).
        let now = levels.snapshot()
        var heard: Set<AudioSource> = []
        for source in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
            if now[source]?.isLive == true || cancelled { heard.insert(source) } else {
                errors.append(source == .cameraMic ? "The camera audio sent nothing during the check."
                                                   : "The Mac mic sent nothing during the check.")
            }
        }
        if !opened.value.isEmpty { await onQueue { opened.value.forEach { $0.close() } } }
        let (status, sample) = levels.finishCheck()
        return Result(status: status, sample: sample, cameraMicOpened: heard.contains(.cameraMic),
                      screenMicOpened: heard.contains(.screenMic), cancelled: cancelled, errors: errors, liveSources: live)
    }

    /// True when the app may open a mic. Asks once (the system prompt) when nobody has decided yet.
    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Why a mic check session could not open.
enum MicCheckError: Error, LocalizedError {
    case notFound(uid: String)
    case cannotOpen(name: String, reason: String)
    /// Microphone access is not given (an idle meter never shows the permission prompt).
    case notAllowed

    var errorDescription: String? {
        switch self {
        case let .notFound(uid): "Mic not found (\(uid)). Connect it or pick another input."
        case let .cannotOpen(name, reason): "Cannot open \(name) for the mic check: \(reason)"
        case .notAllowed: "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
        }
    }
}

/// One audio-only capture session of a mic check or of the idle Mac mic (`MacMicMeter`). Built,
/// started and stopped on its owner's queue.
final class CheckSession: @unchecked Sendable {
    let source: AudioSource
    let session: AVCaptureSession
    let output: AVCaptureAudioDataOutput
    let tap: AudioMeterTap
    /// Notices a stop that `close()` did not ask for: the mic unplugged, or a runtime error.
    let stopWatch: CaptureStopWatch

    private init(source: AudioSource, session: AVCaptureSession, output: AVCaptureAudioDataOutput, tap: AudioMeterTap,
                 stopWatch: CaptureStopWatch) {
        self.source = source; self.session = session; self.output = output; self.tap = tap; self.stopWatch = stopWatch
    }

    /// The session stopped by itself (the mic went away, or a runtime error) after it opened.
    /// Only takes a lock, so any thread may ask.
    var hasStopped: Bool { stopWatch.stopReason != nil }

    static func open(source: AudioSource, uid: String, levels: AudioLevelMonitor) throws -> CheckSession {
        CaptureThread.assertOffMain("Opening a mic check session")
        guard let device = AVCaptureDevice(uniqueID: uid), device.isConnected else { throw MicCheckError.notFound(uid: uid) }
        let name = device.localizedName
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw MicCheckError.cannotOpen(name: name, reason: error.localizedDescription)
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let tap = AudioMeterTap(meter: AudioLevelMeter(source: source, monitor: levels), label: "TwinTake.miccheck.audio")
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicCheckError.cannotOpen(name: name, reason: "the capture session cannot add it.")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            session.commitConfiguration()
            throw MicCheckError.cannotOpen(name: name, reason: "the capture session cannot add its audio output.")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(tap, queue: tap.queue)
        session.commitConfiguration()
        // Watched before it starts, so a stop right after the start is not missed.
        let watch = CaptureStopWatch(session: session, device: device)
        session.startRunning()
        let check = CheckSession(source: source, session: session, output: output, tap: tap, stopWatch: watch)
        guard session.isRunning else {
            check.close()
            throw MicCheckError.cannotOpen(name: name, reason: "the capture session did not start.")
        }
        // Buffers are stamped on the session clock (the audio device's): converted to host time.
        tap.setClock(session.synchronizationClock)
        return check
    }

    /// Stops the session and lets the device go. On the check's queue.
    func close() {
        CaptureThread.assertOffMain("Closing a mic check session")
        // First, so the session's own stop notification is not taken for a failure.
        stopWatch.cancel()
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        tap.flushSoon()
    }
}

/// Notices when a capture session stops without being asked: a runtime error, a stop, or its
/// device disconnected. AVFoundation may post these on any thread (the main thread too): the
/// handlers only take a lock and touch no capture object (thread rule, CaptureThreads.swift).
final class CaptureStopWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    private var tokens: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - session: the session to watch (the notifications' object).
    ///   - device: its device, for the disconnect; nil to skip it.
    init(session: AnyObject, device: AnyObject?) {
        let center = NotificationCenter.default
        var tokens = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
                self?.stopped("runtime error: \(message)")
            },
            center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) { [weak self] _ in
                self?.stopped("the session stopped")
            },
        ]
        if let device {
            tokens.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
                [weak self] _ in self?.stopped("the device was disconnected")
            })
        }
        lock.withLock { self.tokens = tokens }
    }

    deinit { cancel() }

    /// Why the session stopped by itself, or nil while it runs (or after `cancel()` only).
    var stopReason: String? { lock.withLock { reason } }

    /// Stops watching (before an owner stops the session itself). The reason seen so far stays.
    func cancel() {
        let removed = lock.withLock { () -> [NSObjectProtocol] in
            defer { tokens = [] }
            return tokens
        }
        removed.forEach(NotificationCenter.default.removeObserver)
    }

    private func stopped(_ why: String) {
        lock.withLock { if reason == nil { reason = why } }
    }
}
