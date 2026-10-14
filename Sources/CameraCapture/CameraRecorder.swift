// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import MediaWriter
import RecorderCore
import Synchronization
import os

/// Why the camera recorder could not prepare or start.
public enum CameraRecorderError: Error, LocalizedError, Sendable, Equatable {
    case cameraNotFound(uid: String)
    case audioDeviceNotFound(uid: String)
    /// The camera offers no format at the configured size and rate, or no format at all (no HDMI
    /// signal) when the config follows the signal. The message says what it offers.
    case noMatchingFormat(message: String)
    case cannotUseDevice(name: String, reason: String)
    case notPrepared
    case sessionNotRunning(reason: String?)
    case fileExists(path: String)
    case recordingFailed(reason: String)
    /// camera.mov had not started this many seconds after Start (no frame, or no start callback).
    case startTimedOut(seconds: Int)
    /// Start could not turn the open preview camera into the recording graph. The session went
    /// back to the preview graph; `prepare` then closes the camera and opens it again for the take.
    case upgradeFailed(reason: String)
    /// `reconnect()` refused: a take is preparing or recording, or another reconnect runs.
    case busy(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .cameraNotFound(uid): "Camera not found (\(uid)). Connect it, then pick it again in Settings."
        case let .audioDeviceNotFound(uid): "Camera audio input not found (\(uid)). Connect it or pick another input."
        case let .noMatchingFormat(message): message
        case let .cannotUseDevice(name, reason): "Cannot use \(name): \(reason)"
        case .notPrepared: "The camera is not prepared. Call prepare() first."
        case let .sessionNotRunning(reason): "The camera session is not running" + (reason.map { ": \($0)" } ?? ".")
        case let .fileExists(path): "\(path) already exists. The recorder never overwrites a file."
        case let .recordingFailed(reason): "camera.mov could not start: \(reason)"
        case let .startTimedOut(seconds): "camera.mov had not started \(seconds) s after Start. Check that the camera sends a picture."
        case let .upgradeFailed(reason): "Could not add the camera audio and the recording outputs to the open camera. \(reason)"
        case let .busy(reason): "The camera cannot reconnect now: \(reason)"
        }
    }
}

/// Records the capture card to camera.mov: video track 0 plus the camera mic (the capture
/// card's HDMI audio) as linear PCM track 1.
///
/// One AVCaptureSession, in one of two graphs (`CameraGraphPlan`), built and changed only on the
/// camera queue:
/// - Preview graph, from `openPreview(_:meters:)`: the video input and a small
///   AVCaptureVideoDataOutput that feeds `CameraPreviewView`s. With `meters` (the idle meters),
///   also the camera audio input and an AVCaptureAudioDataOutput that only meters the camera mic
///   into `levels`, so the meter and the camera mic detector run before Start (macOS then shows
///   its orange microphone indicator too). Without them, only the green camera indicator.
///   `setIdleMeters(_:)` adds or removes the meter on the open preview. No recording outputs and
///   no encoder.
/// - Recording graph, from `prepare(preview:events:)`: the video input, the camera audio input,
///   the recording outputs (a full-size 420v AVCaptureVideoDataOutput and an
///   AVCaptureAudioDataOutput, both delivering to a `CameraWriterController`), and the preview
///   output only when `keepPreviewWhileRecording(_:)` asked to keep it (the camera window shows
///   the take while it records). With a preview graph open, prepare upgrades it in one session
///   configuration and sets the camera's format and rate again (from the metered preview the
///   camera audio input stays, so the session clock does not change at Start); a failed upgrade
///   puts the preview graph back, and prepare then closes the camera and builds the recording
///   graph fresh. With nothing open, prepare opens the devices (and shows the camera and mic
///   permission prompts the first time) and builds the recording graph.
///
/// Format: with no size and rate in the config the camera's own signal decides (its largest
/// format, the rate snapped to the exact rational: the Cam Link's 23.98 is 24000/1001), else the
/// exact configured format. `signal` says what it resolved to.
///
/// camera.mov is written by AVAssetWriter (`CameraWriterController`), not a movie file output:
/// HEVC (or H.264, or ProRes 422 LT) at the configured bitrate with BT.709 tags, a constant frame
/// rate on the exact grid (video timescale = the rate's numerator, 24000 for 23.976) that follows
/// real time even when the camera stamps a nominal frame interval, the camera audio trimmed and
/// padded onto the same timeline, and a movie fragment every 2 s, so a crash leaves a playable
/// file. `start(writingTo:events:at:)` creates the writer and begins the file at the first frame at
/// or after the scheduled start. After `returnToPreviewAfterStop(_:)`, `stop()` goes back to the
/// preview graph once the file has finished: the recording outputs and the camera audio input
/// leave the session.
///
/// Preview while recording: the session feeds the small preview output next to the full-size
/// recording output. The session is never reconfigured while the file is written: the graph
/// changes only at prepare and before the file starts, and after the file has finished
/// (`CameraGraphStep.allowed(whileWritingFile:)`). Every data output drops late frames
/// (`alwaysDiscardsLateVideoFrames`) and its delegate only hands the frame on, so a slow window
/// cannot hold back camera.mov, and camera.mov cannot hold back the capture.
///
/// Health: the camera mic is metered into `levels` (camera.mov A1, from prepare on). A few bytes
/// of every frame in the preview and recording pipelines are sampled for empty frames
/// (`emptyFrames`, `pictureProblem`): a run of all-zero or flat frames is an episode, logged as
/// `empty_frames`; in the idle preview the recorder opens the camera once more by itself. The
/// camera's USB link is read from the IORegistry when it opens (`usbLink`, `usbProblem`), logged
/// at Start as `usb_link`, and a capture card on USB 2 that cannot carry its signal (an Elgato
/// one with any signal, another one with 4K) is a preflight blocker.
/// `reconnect()` closes and opens the idle preview camera.
///
/// Thread rule (CaptureThreads.swift): every session, connection and device call runs on the
/// camera queue, including the notification and KVO handlers, which only hop there with `async`.
/// Public methods are safe to call from the main actor: they await the queue and never block.
public final class CameraRecorder: SessionTrackRecorder, @unchecked Sendable {
    /// Something that happened to a prepared camera after it opened. Reported on the camera queue.
    public enum Event: Sendable, Equatable {
        /// The camera (`.cameraVideo`) or its audio input (`.mic`) went away. A capture card can
        /// also disconnect and reconnect when its HDMI signal changes.
        case deviceDisconnected(name: String, role: TrackInfo.Role)
        /// The session reported a runtime error.
        case sessionError(String)
        /// The session stopped running without `teardown()`.
        case sessionStopped
        /// The camera's signal changed size or rate, e.g. to "3840x2160 29.97". Nil: it offers no format now.
        case signalChanged(String?)
    }

    public let config: CameraRecorderConfig
    /// Where the camera mic's levels and the mic detector's evidence go. Nil: no meter.
    public let levels: AudioLevelMonitor?
    private let onEvent: (@Sendable (Event) -> Void)?

    // startRunning and stopRunning block, so they and all session configuration run here.
    private let sessionQueue = DispatchQueue(label: "TwinTake.camera.session", qos: .userInitiated)
    private let lock = NSLock()
    private var graph: CaptureGraph?
    /// What other threads may know about the graph, copied out on the camera queue.
    private var snapshot: CaptureGraph.Snapshot?
    /// The recording outputs' writer controller while the recording graph is open. It has its own lock.
    private var controller: CameraWriterController?
    private var observers: [NSObjectProtocol] = []
    private var deviceObservations: [NSKeyValueObservation] = []
    private var events: EventLog?
    private var errors: [String] = []
    /// The camera's signal changed size during the current recording.
    private var formatChange: String?
    /// Set before Start: keep the preview output while camera.mov records.
    private var keepsPreview = false
    /// After Start: whether the preview output stayed on while recording.
    private var previewKept: Bool?
    /// Set before Stop: go back to the preview graph that feeds this, once the file has finished.
    private var previewAfterStop: CameraPreviewFeed?
    /// ...with the camera mic meter.
    private var metersAfterStop = false
    /// The preview asked for the camera mic meter (`openPreview(_:meters:)`, `setIdleMeters(_:)`):
    /// a reconnect opens the preview with it again.
    private var previewMeters = false
    private var lastChange: CameraGraphChange?
    /// The feed the preview graph shows, for `reconnect()`.
    private var previewFeed: CameraPreviewFeed?
    /// Counts every graph that opened and every `teardown`, so a reconnect never replaces a newer
    /// graph and never opens a camera its owner closed meanwhile.
    private var openGeneration = 0
    /// A take's prepare runs: no reconnect starts, and a reconnect that ran opens nothing.
    private var preparing = false
    private var reconnecting = false
    /// The automatic reopen for empty frames is used up until a frame with a picture comes.
    private var autoReopenSpent = false
    /// The camera-wide empty-frame state the recorder last acted on (`pictureChanged`). The
    /// getters read the open graph's `pictureCheck` itself.
    private var picture = PictureCheck.Status()
    /// The codec and bitrate the next file uses (`useEncoder`); nil: the config's.
    private var encoder: (codec: VideoCodec, bitrate: Int)?
    /// The codec of the file that `start` began, for its track in session.json.
    private var fileCodec: VideoCodec?

    /// - Parameters:
    ///   - levels: the app's level monitor; the camera mic is metered into it from prepare on.
    ///   - onEvent: called on the camera queue when the camera goes away, fails or changes its
    ///     signal. Hand the event on with `async`; never wait for another queue in it.
    public init(config: CameraRecorderConfig, levels: AudioLevelMonitor? = nil, onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.config = config
        self.levels = levels
        self.onEvent = onEvent
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        let observations = CaptureBox(deviceObservations)
        let queue = sessionQueue
        // This can run on the main thread (the app drops the last reference there), so every
        // capture call goes to the camera queue. The block keeps the graph, and with it the
        // output's unowned delegate, alive until the output is shut down.
        guard let graph else {
            queue.async { observations.value.forEach { $0.invalidate() } }
            return
        }
        queue.async {
            observations.value.forEach { $0.invalidate() }
            graph.shutDown()
        }
        // Keep the controller (the recording delegate) alive until a cut-off file has finished.
        queue.asyncAfter(deadline: .now() + 10) { withExtendedLifetime(graph) {} }
    }

    /// True while a camera session is open, in either graph, until `teardown()`.
    public var isOpen: Bool { locked { graph != nil && snapshot != nil } }

    /// True while `reconnect()` (or the automatic reopen for empty frames) runs. Only takes a lock.
    public var isReconnecting: Bool { locked { reconnecting } }

    /// Waits, at most `limit`, until no reconnect runs, so the caller sees the camera open again
    /// or closed. Polls a lock; never blocks a thread or waits for the camera queue.
    /// - Returns: false when a reconnect still runs after `limit`.
    @discardableResult
    public func waitForReconnect(atMost limit: Duration) async -> Bool {
        await Self.waitUntil({ [self] in !locked { reconnecting } }, atMost: limit)
    }

    /// True while the recording graph is open: after `prepare()` succeeded, until `teardown()` or
    /// the return to the preview graph after Stop.
    public var isPrepared: Bool { locked { graph != nil && snapshot?.plan.shape == .recording } }

    /// The graph the open session holds, or nil when no session is open.
    public var graphShape: CameraGraphShape? { locked { graph == nil ? nil : snapshot?.plan.shape } }

    /// True when the preview graph is open and its session ran after its last change, so the
    /// preview can keep this camera.
    public var isPreviewReady: Bool {
        locked { graph != nil && snapshot?.plan.shape == .preview && snapshot?.running == true }
    }

    /// True while the open preview graph meters the camera mic: it holds the camera audio input
    /// and the meter output (`openPreview(_:meters:)`, `setIdleMeters(_:)`). Only takes a lock.
    /// While it is true, a `MicCheck` samples the camera mic from it (`live: [.cameraMic]`).
    public var idleMetersOn: Bool {
        locked { graph != nil && snapshot?.plan.shape == .preview && snapshot?.plan.hasAudioMeter == true }
    }

    /// The last change of the session's graph: the open, the upgrade at Start, or the return to
    /// the preview graph after Stop.
    public var lastGraphChange: CameraGraphChange? { locked { lastChange } }

    /// The format the camera is delivering after `prepare()`, e.g. "3840x2160 420v 23.976".
    public var negotiatedFormat: String? { locked { snapshot?.negotiatedFormat } }

    /// What the open camera sends and camera.mov records, e.g. 3840x2160 at 24000/1001
    /// (`label` "3840x2160 · 23.976 fps", `is4K`). Nil while no camera is open; before that,
    /// `DeviceInventory.signal(forVideoUID:)` says what the camera offers.
    public var signal: CameraSignal? { locked { snapshot?.signal } }

    /// The open camera's USB link (read when it opened), e.g. "USB 3 · 5 Gb/s". Nil while closed
    /// or for a camera that is not on USB. Before it opens, `DeviceInventory.usbLink(forVideoUID:)`.
    public var usbLink: USBLinkInfo? { locked { snapshot?.usbLink } }

    /// "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3."
    /// when the open capture card runs a 4K signal over USB 2; else nil.
    public var usbProblem: String? {
        locked { snapshot.flatMap { CameraUSB.slowLinkProblem(link: $0.usbLink, signal: $0.signal, cameraName: $0.deviceName) } }
    }

    /// Set while the open camera sends empty frames (all-zero planes, or one flat value).
    public var emptyFrames: EmptyFramePattern? { locked { graph }?.pictureCheck.status.empty }

    /// "No picture: the Cam Link is sending empty frames." while `emptyFrames` is set; else nil.
    public var pictureProblem: String? {
        guard let graph = locked({ graph }), graph.pictureCheck.status.empty != nil else { return nil }
        return CameraMessages.emptyFrames(cameraName: graph.deviceName)
    }

    /// The codec camera.mov uses. It differs from the requested one (`encoderSettings`) only when
    /// this Mac has no encoder for it.
    public var effectiveCodec: VideoCodec {
        let (graph, requested) = locked { (self.graph, encoder?.codec ?? config.codec) }
        if let graph, requested == config.codec { return graph.codec }
        return CameraOutputSettings.effectiveCodec(
            requested: requested, availableEncoders: CameraOutputSettings.availableEncoderCodecTypes())
    }

    /// The codec and bitrate the next camera.mov asks for: the config's, or the last `useEncoder`.
    public var encoderSettings: (codec: VideoCodec, bitrate: Int) {
        locked { encoder ?? (config.codec, config.bitrate) }
    }

    /// The codec and bitrate for the next file, in place of the config's. The camera session does
    /// not use them (only the writer does, from `start` on), so an open preview camera records with
    /// the settings of the moment without opening again. Only takes a lock.
    public func useEncoder(codec: VideoCodec, bitrate: Int) {
        locked { encoder = (codec, bitrate) }
    }

    // MARK: - SessionTrackRecorder

    public func preflight() async -> [PreflightIssue] {
        let (graph, lastError) = locked { (self.graph, errors.last) }
        let empty = graph?.pictureCheck.status.empty
        var asked = config
        asked.codec = encoderSettings.codec
        let config = asked, codec = effectiveCodec
        return await onSessionQueue {
            Self.preflightIssues(config: config, graph: graph, lastError: lastError, codec: codec, emptyFrames: empty)
        }
    }

    /// The preflight checks. Device and session reads, so the camera queue only. The camera audio
    /// input is checked by its uid (connected, and the mic permission) without opening it: the
    /// plain preview graph holds no audio input.
    private static func preflightIssues(config: CameraRecorderConfig, graph: CaptureGraph?, lastError: String?,
                                        codec: VideoCodec, emptyFrames: EmptyFramePattern? = nil) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []

        let videoAccess = AVCaptureDevice.authorizationStatus(for: .video)
        if videoAccess == .denied || videoAccess == .restricted {
            issues.append(PreflightIssue(id: "camera.permission", severity: .blocker, message:
                "Camera access is off. Turn it on in System Settings > Privacy & Security > Camera."))
        }
        if config.audioDeviceUID != nil {
            let micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
            if micAccess == .denied || micAccess == .restricted {
                issues.append(PreflightIssue(id: "camera.mic_permission", severity: .blocker, message:
                    "Microphone access is off, so camera.mov cannot record the camera audio. "
                    + "Turn it on in System Settings > Privacy & Security > Microphone."))
            }
        }

        // A device object from prepare() outlives an unplugged camera; isConnected tells.
        let device = (AVCaptureDevice(uniqueID: config.videoDeviceUID) ?? graph?.videoDevice).flatMap { $0.isConnected ? $0 : nil }
        if let device {
            if device.isInUseByAnotherApplication, graph == nil {
                issues.append(PreflightIssue(id: "camera.in_use", severity: .warning, message:
                    "\(device.localizedName) is in use by another app. Close it (OBS, FaceTime, Zoom) if the picture freezes."))
            }
            if device.isSuspended {
                issues.append(PreflightIssue(id: "camera.suspended", severity: .warning, message:
                    "\(device.localizedName) is suspended and sends no picture."))
            }
            let candidates = CaptureDevices.videoCandidates(of: device)
            if let width = config.width, let height = config.height, let frameRate = config.frameRate {
                if FormatMatcher.bestMatch(in: candidates, width: width, height: height, frameRate: frameRate) == nil {
                    issues.append(PreflightIssue(id: "camera.format", severity: .blocker, message:
                        CameraMessages.formatUnavailable(cameraName: device.localizedName, offered: candidates,
                                                         width: width, height: height, frameRate: frameRate)))
                } else if let graph, let warning = graph.formatWarning {
                    issues.append(PreflightIssue(id: "camera.format", severity: .blocker, message: warning))
                }
            } else if let resolved = CameraSignal.resolve(candidates) {
                // The take records what the camera sends; a capture card short of 4K gets a note.
                if !resolved.signal.is4K, CameraMessages.isCaptureCard(device.localizedName) {
                    issues.append(PreflightIssue(id: "camera.not_4k", severity: .warning, message:
                        CameraMessages.notFourK(cameraName: device.localizedName, signal: resolved.signal)))
                }
                if let graph, let warning = graph.formatWarning {
                    issues.append(PreflightIssue(id: "camera.format", severity: .blocker, message: warning))
                }
            } else {
                issues.append(PreflightIssue(id: "camera.format", severity: .blocker, message:
                    CameraMessages.noSignal(cameraName: device.localizedName)))
            }
            // A capture card on its USB 2 lane still offers 4K but sends empty frames: a blocker,
            // since USB 2 cannot carry the signal (`CameraUSB.slowLinkProblem` says which).
            let signal = graph?.signal ?? CameraSignal.resolve(candidates)?.signal
            let link = CameraUSB.link(forUniqueID: device.uniqueID, name: device.localizedName)
            if let problem = CameraUSB.slowLinkProblem(link: link, signal: signal, cameraName: device.localizedName) {
                issues.append(PreflightIssue(id: "camera.usb2", severity: .blocker, message: problem))
            }
            if let emptyFrames {
                // All-zero frames are never a picture; a flat frame may be a lens cap or a camera menu.
                issues.append(PreflightIssue(id: "camera.empty_frames", severity: emptyFrames == .zero ? .blocker : .warning,
                                             message: CameraMessages.emptyFrames(cameraName: device.localizedName)))
            }
        } else {
            issues.append(PreflightIssue(id: "camera.missing", severity: .blocker, message:
                CameraRecorderError.cameraNotFound(uid: config.videoDeviceUID).errorDescription ?? "Camera not found."))
        }

        if let uid = config.audioDeviceUID {
            if AVCaptureDevice(uniqueID: uid)?.isConnected != true {
                issues.append(PreflightIssue(id: "camera.audio_missing", severity: .blocker, message:
                    CameraRecorderError.audioDeviceNotFound(uid: uid).errorDescription ?? "Camera audio not found."))
            }
        } else {
            issues.append(PreflightIssue(id: "camera.no_audio", severity: .warning, message:
                "No camera audio input is set, so camera.mov will have no audio track."))
        }

        if codec != config.codec {
            issues.append(PreflightIssue(id: "camera.codec", severity: .warning, message:
                "This Mac has no \(config.codec.displayName) encoder; camera.mov will use \(codec.displayName)."))
        }
        if let graph, !graph.session.isRunning {
            issues.append(PreflightIssue(id: "camera.session", severity: .blocker, message:
                "The camera session stopped. " + (lastError ?? "Prepare it again.")))
        }

        issues += VideoEffectsSnapshot.current(device: device, connection: graph?.videoConnection).issues()
        return issues
    }

    public func prepare() async throws {
        try await prepare(preview: nil)
    }

    /// Opens the camera for the preview only: the video input and the small preview output that
    /// feeds `preview`. No audio input and no recording outputs. Same as
    /// `openPreview(preview, meters: false)`.
    public func openPreview(_ preview: CameraPreviewFeed) async throws {
        try await openPreview(preview, meters: false)
    }

    /// Opens the camera for the preview: the video input and the small preview output that feeds
    /// `preview`, and with `meters` the camera mic meter too (the camera audio input and an audio
    /// data output that meters it into `levels`). No recording outputs. `prepare(preview:events:)`
    /// turns it into the recording graph at Start. Does nothing while a camera session is open
    /// (use `setIdleMeters(_:)` to change the meter of an open preview).
    ///
    /// The meter is best effort, the picture never waits for it: without microphone access (this
    /// never shows the permission prompt), without `levels` or a camera audio input in the config,
    /// or when the camera audio is not connected, the preview opens without it (`idleMetersOn`
    /// false).
    public func openPreview(_ preview: CameraPreviewFeed, meters: Bool) async throws {
        if locked({ graph }) != nil { return }
        locked {
            previewFeed = preview
            previewMeters = meters
        }
        try await open(.preview(meters: meters && canMeter), preview: preview, events: nil)
        await applyNewerMeterWish(than: meters)
    }

    /// A `setIdleMeters(_:)` that came while the preview opened (or reconnected) only stored its
    /// wish, and the open used the one it read before. Applies the newest wish now, so the camera
    /// audio input never stays against it (a mic check may hold that input in its own session).
    private func applyNewerMeterWish(than opened: Bool) async {
        let wish = locked { previewMeters }
        guard wish != opened else { return }
        _ = try? await setIdleMeters(wish)
    }

    /// The config has a camera audio input and the recorder has a monitor to meter it into.
    private var canMeter: Bool { levels != nil && config.audioDeviceUID != nil }

    /// Adds (true) or removes (false) the camera mic meter in the open preview graph, in one
    /// session configuration on the camera queue: the camera audio input and the meter output join
    /// or leave together while the picture keeps running. Only on the idle preview graph: while a
    /// take prepares or records, nothing changes. While the preview opens or a reconnect runs, the
    /// wish is stored, and the open applies it once it is done. Adding needs microphone access (no
    /// prompt) and the camera audio connected; else nothing changes.
    /// - Returns: true when the open preview meters the camera mic after the call (`idleMetersOn`).
    /// - Throws: the change's error. A failed change leaves the graph as it was, unless the session
    ///   stopped (the recorder then reports `Event.sessionStopped`).
    @discardableResult
    public func setIdleMeters(_ on: Bool) async throws -> Bool {
        let graph = locked { () -> CaptureGraph? in
            previewMeters = on
            if preparing || reconnecting || controller?.isActive == true || snapshot?.plan.shape != .preview { return nil }
            return self.graph
        }
        guard let graph else { return idleMetersOn }
        let allowed = !on || canMeter
        let (result, snapshot, controller) = await onSessionQueue {
            () -> (Result<CameraGraphChange?, CameraRecorderError>, CaptureGraph.Snapshot, CameraWriterController?) in
            // A take's prepare may have upgraded the graph since the lock was read.
            guard graph.plan.shape == .preview, allowed, !on || graph.mayMeterIdle() else {
                return (.success(nil), graph.snapshot, graph.controller)
            }
            let result = Result { () throws(CameraRecorderError) -> CameraGraphChange? in
                try graph.change(to: graph.plan.withMeters(on), preview: nil)
            }
            return (result, graph.snapshot, graph.controller)
        }
        publish(graph, snapshot: snapshot, controller: controller, change: try? result.get())
        if case let .failure(error) = result { throw error }
        if let change = try? result.get() { Self.log.notice("Camera graph \(change.logLine, privacy: .public)") }
        return idleMetersOn
    }

    /// Makes the recording graph ready, so `start(writingTo:events:)` can begin the file.
    /// - With the preview graph open: adds the camera audio input and the recording outputs in one
    ///   session configuration (and removes the preview output unless `keepPreviewWhileRecording`),
    ///   then sets the camera's format and rate again. If that fails (`upgradeFailed`, logged as a
    ///   warning), the camera closes and opens again in the recording graph, as with nothing open.
    /// - With nothing open: opens the devices and starts the session in the recording graph. With
    ///   `preview` and `keepPreviewWhileRecording(true)`, the session also feeds that preview.
    ///
    /// Then it waits, at most `firstAudioLimit`, for the first camera audio buffer, so camera.mov's
    /// audio starts with its picture: the audio input may have joined the session only now.
    /// - Parameter events: the take's log. The graph change is logged there (`camera_graph`).
    public func prepare(preview: CameraPreviewFeed?, events: EventLog? = nil) async throws {
        // No reconnect starts from here on; one under way gets a moment to finish first.
        let reconnect = locked { () -> Bool in
            preparing = true
            if let preview { previewFeed = preview }
            return reconnecting
        }
        defer { locked { preparing = false } }
        if reconnect { _ = await Self.waitUntil({ [self] in !locked { reconnecting } }, atMost: .seconds(3)) }
        let keep = locked { () -> Bool in
            previewKept = nil
            return keepsPreview
        }
        if let graph = locked({ graph }) {
            do {
                try await upgrade(graph, preview: preview, keepPreview: keep, events: events)
                await waitForFirstCameraAudio(events: events)
                return
            } catch {
                // The proven path: a fresh session built in the recording graph.
                events?.append(.warning, ["source": "camera", "message":
                    "\(error.localizedDescription) The camera closes and opens again for the take."])
                await teardown()
                // What the closed session reported is not the take's trouble.
                locked { errors = []; formatChange = nil }
            }
        }
        let plan = CameraGraphPlan.recording(audioDeviceUID: config.audioDeviceUID, previewOutput: preview != nil && keep)
        try await open(plan, preview: preview, events: events)
        await waitForFirstCameraAudio(events: events)
    }

    /// The longest `prepare` waits for the first camera audio buffer.
    static let firstAudioLimit: Duration = .seconds(1)

    /// Waits, at most `firstAudioLimit`, until the camera audio output has delivered a buffer, so
    /// the camera audio runs before the file starts (else camera.mov's audio would begin with
    /// silence until it does). Never blocks.
    private func waitForFirstCameraAudio(events: EventLog?) async {
        let controller = locked { snapshot?.plan.hasAudioInput == true ? self.controller : nil }
        guard let controller else { return }
        if await Self.waitUntil({ controller.hasSeenAudio }, atMost: Self.firstAudioLimit) { return }
        events?.append(.warning, ["source": "camera", "message":
            "No camera audio arrived within \(Self.firstAudioLimit.components.seconds) s of opening it, "
            + "so camera.mov's audio may start a little after its picture."])
    }

    /// Polls `condition` every 20 ms until it is true (true) or `limit` has passed (false).
    static func waitUntil(_ condition: @Sendable () -> Bool, atMost limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Builds `plan`, starts the session (blocks the camera queue, not the caller) and checks the
    /// camera's format.
    /// - Parameter generation: a reconnect's open: only while no other graph opened or closed
    ///   since it read `openGeneration`, and no take prepares.
    private func open(_ plan: CameraGraphPlan, preview: CameraPreviewFeed?, events: EventLog?,
                      onlyAtGeneration generation: Int? = nil) async throws {
        let config = config, levels = levels
        let began = HostClock.nowNs()
        let graph = try await onSessionQueue {
            try CaptureGraph.build(config: config, plan: plan, preview: preview, levels: levels)
        }
        let accepted = locked { () -> Bool in
            guard self.graph == nil else { return false }
            if let generation, generation != openGeneration || preparing { return false }
            self.graph = graph
            openGeneration &+= 1
            picture = PictureCheck.Status()
            return true
        }
        guard accepted else {
            await onSessionQueue { graph.shutDown() }
            throw CameraRecorderError.busy(reason: "the camera was opened again meanwhile.")
        }
        graph.pictureCheck.setHandler { [weak self, weak graph] change in
            guard let self, let graph else { return }
            self.pictureChanged(change, on: graph)
        }
        installObservers(for: graph)
        do {
            let (snapshot, controller, change) = try await onSessionQueue {
                [self] () throws -> (CaptureGraph.Snapshot, CameraWriterController?, CameraGraphChange) in
                let reset = try graph.startRunning()
                watchDevice(of: graph)
                return (graph.snapshot, graph.controller, graph.describe(from: nil, began: began, formatReset: reset))
            }
            publish(graph, snapshot: snapshot, controller: controller, change: change)
            events?.append(.cameraGraph, change.eventData)
        } catch {
            let reason = locked { errors.last }
            await teardown()
            if case CameraRecorderError.sessionNotRunning = error { throw CameraRecorderError.sessionNotRunning(reason: reason) }
            throw error
        }
    }

    /// The preview graph becomes the recording graph, on the camera queue. A failed change has
    /// already put the preview graph back; this throws `upgradeFailed`, and `prepare` opens the
    /// camera again.
    private func upgrade(_ graph: CaptureGraph, preview: CameraPreviewFeed?, keepPreview: Bool, events: EventLog?) async throws {
        let audioUID = config.audioDeviceUID
        let (result, snapshot, controller) = await onSessionQueue {
            () -> (Result<CameraGraphChange?, CameraRecorderError>, CaptureGraph.Snapshot, CameraWriterController?) in
            let current = graph.plan
            guard current.shape == .preview else { return (.success(nil), graph.snapshot, graph.controller) }
            let wanted = CameraGraphPlan.recording(audioDeviceUID: audioUID,
                                                   previewOutput: (current.hasPreviewOutput || preview != nil) && keepPreview)
            let result = Result { () throws(CameraRecorderError) -> CameraGraphChange? in
                try graph.change(to: wanted, preview: preview)
            }
            return (result, graph.snapshot, graph.controller)
        }
        switch result {
        case let .success(change):
            publish(graph, snapshot: snapshot, controller: controller, change: change)
            if let change { events?.append(.cameraGraph, change.eventData) }
        case let .failure(error):
            publish(graph, snapshot: snapshot, controller: controller, change: nil)
            throw CameraRecorderError.upgradeFailed(reason: error.errorDescription ?? "\(error)")
        }
    }

    /// The recording graph goes back to the preview graph that feeds `feed`: the recording outputs
    /// leave the session, and the camera audio input too (macOS turns its microphone indicator off)
    /// unless `meters` keeps it for the camera mic meter; the preview output joins it unless it
    /// stayed for the take. Only after the file has finished.
    private func returnToPreview(_ graph: CaptureGraph, feed: CameraPreviewFeed, meters: Bool, events: EventLog?) async {
        let (result, snapshot, controller) = await onSessionQueue {
            () -> (Result<CameraGraphChange?, CameraRecorderError>, CaptureGraph.Snapshot, CameraWriterController?) in
            // The meter keeps the take's camera audio input; a take without one gets no meter here.
            let meters = meters && graph.audioDevice != nil && graph.levels != nil
            let result = Result { () throws(CameraRecorderError) -> CameraGraphChange? in
                try graph.change(to: .preview(meters: meters), preview: feed)
            }
            return (result, graph.snapshot, graph.controller)
        }
        switch result {
        case let .success(change):
            publish(graph, snapshot: snapshot, controller: controller, change: change)
            locked {
                previewFeed = feed
                previewMeters = meters
            }
            if let change { events?.append(.cameraGraph, change.eventData) }
        case let .failure(error):
            publish(graph, snapshot: snapshot, controller: controller, change: nil)
            events?.append(.warning, ["source": "camera", "message":
                "The camera could not go back to its preview graph after Stop, so it closes. \(error.errorDescription ?? "\(error)")"])
        }
    }

    /// Copies the graph's state out for other threads, after a build or a change on the camera queue.
    private func publish(_ graph: CaptureGraph, snapshot: CaptureGraph.Snapshot, controller: CameraWriterController?,
                         change: CameraGraphChange?) {
        locked {
            guard self.graph === graph else { return }
            self.snapshot = snapshot
            self.controller = controller
            if let change { lastChange = change }
            // Back on the preview graph: the next take starts without a preview decision.
            if snapshot.plan.shape == .preview { previewKept = nil }
        }
    }

    public var recordingProblem: String? {
        let (controller, formatChange, graph) = locked { (self.controller, self.formatChange, self.graph) }
        if let problem = controller?.recordingProblem() ?? formatChange { return problem }
        // Frames arrive (no stall), but they hold no picture.
        guard let graph, graph.pictureCheck.status.recording != nil, controller?.isActive == true else { return nil }
        return CameraMessages.emptyFrames(cameraName: graph.deviceName)
    }

    /// Keep (true) or remove (false, the default) the preview output in the recording graph. Takes
    /// effect at the next `prepare` (or `start`); the output is never added or removed while a file
    /// is written. Only takes a lock, so the main actor may call it.
    public func keepPreviewWhileRecording(_ keep: Bool) {
        locked { keepsPreview = keep }
    }

    /// Set before `stop()`: once the file has finished, and when the take had no camera trouble,
    /// stop goes back to the preview graph that feeds `feed` (logged as `camera_graph`), with the
    /// camera mic meter when `meters` (the camera audio input then stays in the session). Nil, the
    /// default: the recording graph stays until `teardown()`. `start` clears it. Only takes a lock.
    public func returnToPreviewAfterStop(_ feed: CameraPreviewFeed?, meters: Bool = false) {
        locked {
            previewAfterStop = feed
            metersAfterStop = meters
        }
    }

    /// True when the preview output stayed on for the current recording, false when Start removed
    /// it (or the camera never had one), nil before the first Start and after the camera went back
    /// to its preview graph.
    public var previewDuringRecording: Bool? { locked { previewKept } }

    /// Creates camera.mov at `url` and begins it at the first camera frame at or after
    /// `startHostNs` (host clock; nil: the next frame). Getting ready takes one hop to the camera
    /// queue and the writer's setup (tens of ms), well inside `StartSchedule.marginNs`. Returns
    /// once the first frame is in the file; throws when none comes within 6 s of the start time.
    public func start(writingTo url: URL, events: EventLog, at startHostNs: UInt64?) async throws {
        let prepared = locked { () -> (CaptureGraph, CameraWriterController)? in
            guard let graph, let controller else { return nil }
            return (graph, controller)
        }
        guard let (graph, controller) = prepared else { throw CameraRecorderError.notPrepared }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CameraRecorderError.fileExists(path: url.path) }

        // On the camera queue: drop the preview output first unless it stays for the camera window
        // (prepare normally dropped it already; the session must not add or remove a connection
        // mid-file), then read the clock, which can change while the session reconfigures.
        let keepPreview = locked { keepsPreview }
        let facts = await onSessionQueue { () -> CaptureGraph.StartFacts? in
            if !keepPreview { graph.detachPreview() }
            return graph.session.isRunning ? graph.startFacts() : nil
        }
        guard let facts else { throw CameraRecorderError.sessionNotRunning(reason: locked { errors.last }) }
        locked {
            self.events = events
            formatChange = nil
            previewAfterStop = nil
            snapshot = facts.snapshot
            previewKept = facts.previewAttached
        }
        if let warning = facts.snapshot.formatWarning {
            events.append(.warning, ["source": "camera", "message": warning])
        }
        logUSBLink(facts.snapshot, to: events)
        levels?.beginTake(events: events, startHostNs: startHostNs)

        controller.configure(syncClock: facts.clock)
        // The encoder settings of the moment (`useEncoder`): a preview camera opened before a codec
        // or bitrate change records with the new one.
        let (requested, bitrate) = encoderSettings
        let codec = requested == config.codec && bitrate == config.bitrate ? graph.codec
            : CaptureGraph.codec(requested: requested, bitrate: bitrate, width: graph.width, height: graph.height,
                                 frameRate: controller.frameRate)
        locked { fileCodec = codec }
        let labels = CameraWriterController.TrackLabels(
            videoFormat: facts.snapshot.negotiatedFormat, codec: codec.rawValue,
            videoDevice: facts.videoDeviceName, audioDevice: facts.audioDeviceName,
            syncClock: CaptureGraph.clockLabel(facts.clock), preview: facts.previewAttached ? "on" : "off")
        let plan = CameraWriterController.FilePlan(codec: codec, width: graph.width, height: graph.height,
                                                   frameRate: controller.frameRate, bitrate: bitrate,
                                                   audioChannels: controller.audioChannels)

        let giveUpAfter = 6
        switch await controller.start(url: url, events: events, plan: plan, labels: labels, startHostNs: startHostNs,
                                      giveUpAfter: TimeInterval(giveUpAfter)) {
        case .started:
            return
        case .timedOut:
            // Stop the pending file, so the app can abort the start instead of recording nothing.
            let error = CameraRecorderError.startTimedOut(seconds: giveUpAfter)
            controller.finishEarly(reason: error.errorDescription ?? "camera.mov did not start.")
            throw error
        case let .failed(reason):
            throw CameraRecorderError.recordingFailed(reason: reason)
        }
    }

    public func stop() async -> RecorderResult {
        let prepared = locked { () -> (CaptureGraph, CameraWriterController)? in
            guard let graph, let controller else { return nil }
            return (graph, controller)
        }
        guard let (graph, controller) = prepared else {
            return RecorderResult(errors: ["Camera: stop() was called before prepare()."])
        }
        let finish = await controller.stop(timeout: 15)
        let timing = controller.timing()
        let (events, earlier, previewFeed, meters) = locked { () -> (EventLog?, [String], CameraPreviewFeed?, Bool) in
            defer { errors = [] }
            return (self.events, errors, previewAfterStop, metersAfterStop)
        }
        var errors = earlier
        if let error = finish.error { errors.append("camera.mov: \(error)") }

        guard let url = timing.url, FileManager.default.fileExists(atPath: url.path) else {
            // This file's part of the take is over all the same.
            if let events { levels?.endTake(events: events) }
            return RecorderResult(tracks: [], errors: errors.isEmpty ? ["camera.mov was not written."] : errors)
        }
        // The facts read device names and formats: camera queue.
        let codec = locked { fileCodec } ?? graph.codec
        var facts = await onSessionQueue { graph.facts(timing: timing, codec: codec) }
        // Which mic the camera recorded with, as the detector heard it during the take.
        let micSource = events.flatMap { levels?.endTake(events: $0) }
        if facts.audio != nil { facts.micSource = micSource }
        let tracks = CameraTrackBuilder.tracks(facts)

        if let events {
            for track in tracks {
                var data = CameraTrackReport.trackStopData(track: track, video: timing.video, audio: timing.audio)
                data["playable"] = "\(finish.playable)"
                events.append(.trackStop, data)
            }
            if let warning = CameraTrackReport.rateWarning(timing.video) { events.append(.warning, warning) }
        }
        // The file has finished and the facts are read: the camera may leave the recording graph.
        // A take with camera trouble (a lost device, a session error, a new signal) keeps it, and
        // the app closes the camera instead. A change that hangs does not hold up the result: after
        // `returnToPreviewLimit` the camera still holds the recording graph for the app, which then
        // closes it.
        if let previewFeed, earlier.isEmpty, !finish.timedOut {
            await Self.waitAtMost(Self.returnToPreviewLimit) { [self] in
                await returnToPreview(graph, feed: previewFeed, meters: meters, events: events)
            }
        }
        return RecorderResult(tracks: tracks, errors: errors)
    }

    /// Stops the session and releases the devices, on the camera queue. The caller awaits it; the
    /// main thread is never blocked, so stopRunning can get the main-thread call it waits for.
    public func teardown() async {
        await teardown(only: nil)
    }

    /// `teardown()`, or with `expected` only while that graph is still the open one.
    /// - Returns: the open generation after the close, for a reconnect's open; nil when `expected`
    ///   was no longer open (nothing was closed).
    @discardableResult
    private func teardown(only expected: CaptureGraph?) async -> Int? {
        let taken = locked {
            () -> (CaptureGraph?, CameraWriterController?, [NSObjectProtocol], [NSKeyValueObservation], Int)? in
            if let expected, self.graph !== expected { return nil }
            // Counted even when nothing is open: a reconnect that is opening the camera right now
            // (its graph not accepted yet) is then refused, so the owner's close is the last word.
            openGeneration &+= 1
            defer {
                self.graph = nil; snapshot = nil; self.controller = nil; observers = []; deviceObservations = []
                picture = PictureCheck.Status()
            }
            return (self.graph, self.controller, observers, deviceObservations, openGeneration)
        }
        guard let (graph, controller, tokens, observations, generation) = taken else { return nil }
        graph?.pictureCheck.setHandler(nil)
        // Removed first, so the session's own stop notification is not taken for a failure.
        tokens.forEach(NotificationCenter.default.removeObserver)
        let box = CaptureBox(observations)
        guard let graph else {
            if !observations.isEmpty { sessionQueue.async { box.value.forEach { $0.invalidate() } } }
            return generation
        }
        if let controller, controller.isActive {
            _ = await controller.stop(timeout: 10)
        }
        await onSessionQueue {
            box.value.forEach { $0.invalidate() }
            graph.shutDown()
        }
        return generation
    }

    // MARK: - Reconnect and empty frames

    /// Closes the idle preview camera and opens it again with the same preview feed, on the
    /// camera queue: what a USB replug does for a capture card that sends empty frames, short
    /// of the replug. Refused (`busy`) while a take prepares or records, or while another
    /// reconnect runs; a closed camera with a known preview feed just opens.
    /// - Throws: `busy`, `notPrepared` (the camera never fed a preview), or the open's error (the
    ///   camera then stays closed).
    public func reconnect() async throws {
        try await reconnect(automatic: false)
    }

    private func reconnect(automatic: Bool) async throws {
        // Once `reconnecting` is clear again, so `setIdleMeters` acts on the new graph.
        if let opened = try await reopen(automatic: automatic) { await applyNewerMeterWish(than: opened) }
    }

    /// The close and the open of `reconnect`, while `reconnecting` is set.
    /// - Returns: the camera mic meter wish the new graph opened with; nil when it opened nothing.
    private func reopen(automatic: Bool) async throws -> Bool? {
        let (graph, feed, refusal, current) = locked { () -> (CaptureGraph?, CameraPreviewFeed?, String?, Int) in
            if preparing { return (nil, nil, "a take is starting.", 0) }
            if reconnecting { return (nil, nil, "it is reconnecting already.", 0) }
            if controller?.isActive == true || snapshot?.plan.shape == .recording {
                return (nil, nil, "it is recording. Stop the take first.", 0)
            }
            reconnecting = true
            return (self.graph, previewFeed, nil, openGeneration)
        }
        if let refusal { throw CameraRecorderError.busy(reason: refusal) }
        defer { locked { reconnecting = false } }
        guard let feed else { throw CameraRecorderError.notPrepared }
        Self.log.notice("\(automatic ? "Preview camera sends empty frames; opening it again" : "Reconnecting the preview camera", privacy: .public)")
        // The generation read in the same lock as the close: a `teardown()` by the owner after it
        // (Start, or the preview closing) makes the open below refuse.
        var generation = current
        if let graph {
            guard let closed = await teardown(only: graph) else { return nil }  // Someone else closed or replaced it.
            generation = closed
        }
        // The views drop the last (empty) picture. `Stats.emptyFrames` stays until the new
        // camera's first frames tell either way.
        feed.clear()
        // The newest meter wish, read right before the open: a `setIdleMeters(_:)` during the close counts.
        let meters = locked { previewMeters }
        try await open(.preview(meters: meters && canMeter), preview: feed, events: nil, onlyAtGeneration: generation)
        return meters
    }

    /// The open camera started or stopped sending empty frames, or sent its first picture. On the
    /// reporting pipeline's queue: it only takes the lock, logs, and starts the automatic reopen.
    private func pictureChanged(_ change: PictureCheck.Change, on graph: CaptureGraph) {
        enum Next { case nothing, log(EventLog?, String), reopen(String) }
        let next = locked { () -> Next in
            guard self.graph === graph else { return .nothing }
            let wasEmpty = picture.empty != nil
            picture = change.status
            if change.status.empty == nil, change.status.sawPicture { autoReopenSpent = false }
            guard wasEmpty != (change.status.empty != nil) else { return .nothing }
            let name = snapshot?.deviceName ?? config.videoDeviceUID
            let take = controller?.isActive == true ? events : nil
            if change.status.empty != nil, snapshot?.plan.shape == .preview, !preparing, !reconnecting, !autoReopenSpent {
                autoReopenSpent = true
                return .reopen(name)
            }
            return .log(take, name)
        }
        let name: String
        var eventLog: EventLog?
        var reopen = false
        switch next {
        case .nothing: return
        case let .log(log, n): name = n; eventLog = log
        case let .reopen(n): name = n; reopen = true
        }
        var data = ["pipeline": change.pipeline.rawValue, "device": name]
        if let pattern = change.status.empty {
            data["state"] = "start"
            data["pattern"] = pattern.rawValue
            data["message"] = CameraMessages.emptyFrames(cameraName: name)
            data["frames"] = String(EmptyFrameDetector.framesToFlag)
        } else {
            data["state"] = "end"
            if case let .ended(frames) = change.transition { data["frames"] = String(frames) }
        }
        if reopen { data["action"] = "reopen" }
        eventLog?.append(.emptyFrames, data)
        Self.log.notice("Camera empty frames \(data["state"] ?? "", privacy: .public) (\(change.pipeline.rawValue, privacy: .public), \(data["pattern"] ?? "-", privacy: .public))")
        if reopen {
            Task { [weak self] in
                do { try await self?.reconnect(automatic: true) } catch {
                    Self.log.notice("Preview camera reopen failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// `usb_link` at Start, and a warning when a capture card runs its signal over a link too slow for it.
    private func logUSBLink(_ snapshot: CaptureGraph.Snapshot, to events: EventLog) {
        guard let link = snapshot.usbLink else { return }
        var data = link.eventData
        data["device"] = snapshot.deviceName
        let problem = CameraUSB.slowLinkProblem(link: link, signal: snapshot.signal, cameraName: snapshot.deviceName)
        data["slow_for_signal"] = String(problem != nil)
        events.append(.usbLink, data)
        if let problem {
            events.append(.warning, ["source": "camera", "message": problem, "usb": link.usbGeneration ?? "?",
                                     "speed_mbps": link.bitsPerSecond.map { String($0 / 1_000_000) } ?? "?"])
        }
    }

    // MARK: - Manifest helpers

    /// The macOS camera effects that are on for this camera (Reactions, Portrait, Studio Light,
    /// Center Stage, Background Replacement, Edge Light...), for `CameraInfo.effectsActive`.
    public func activeEffects() async -> [String] {
        let graph = locked { self.graph }, uid = config.videoDeviceUID
        return await onSessionQueue { Self.activeEffects(graph: graph, uid: uid) }
    }

    /// The HDMI signal the capture card reports, e.g. "3840x2160 23.976", for `CameraInfo.hdmiFormat`.
    /// Nil when the camera is not connected.
    public func hdmiFormatDescription() async -> String? {
        let graph = locked { self.graph }, uid = config.videoDeviceUID
        return await onSessionQueue { Self.hdmiFormat(graph: graph, uid: uid) }
    }

    /// `CameraInfo` for session.json.
    public func cameraInfo() async -> CameraInfo {
        let graph = locked { self.graph }, uid = config.videoDeviceUID
        return await onSessionQueue {
            CameraInfo(hdmiFormat: Self.hdmiFormat(graph: graph, uid: uid), effectsActive: Self.activeEffects(graph: graph, uid: uid))
        }
    }

    private static func activeEffects(graph: CaptureGraph?, uid: String) -> [String] {
        let device = graph?.videoDevice ?? AVCaptureDevice(uniqueID: uid)
        return VideoEffectsSnapshot.current(device: device, connection: graph?.videoConnection).activeNames()
    }

    private static func hdmiFormat(graph: CaptureGraph?, uid: String) -> String? {
        if let graph, !graph.videoDevice.formats.isEmpty,
           let active = CaptureDevices.candidate(graph.videoDevice.activeFormat) {
            let rate = StandardFrameRate.rate(forFrameDuration: graph.videoDevice.activeVideoMinFrameDuration) ?? graph.frameRate
            return "\(active.width)x\(active.height) \(rate.label)"
        }
        guard let device = AVCaptureDevice(uniqueID: uid) else { return nil }
        let candidates = CaptureDevices.videoCandidates(of: device)
        return FormatMatcher.bestAvailable(in: candidates).map { FormatLabel.signal(candidates[$0]) }
    }

    // MARK: - Device loss, runtime errors and signal changes

    /// NotificationCenter observers. AVFoundation may post on the main thread, so each handler
    /// only hops to the camera queue (async) and does its work there.
    private func installObservers(for graph: CaptureGraph) {
        let center = NotificationCenter.default
        let queue = sessionQueue
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: graph.session, queue: nil) {
            [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
            queue.async { [weak self] in self?.sessionFailed(message) }
        })
        tokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: graph.session, queue: nil) {
            [weak self] _ in
            queue.async { [weak self] in self?.log(.warning, ["source": "camera", "message": "The camera session was interrupted."]) }
        })
        tokens.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: graph.session, queue: nil) {
            [weak self] _ in
            queue.async { [weak self] in self?.sessionStopped() }
        })
        tokens.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            let box = CaptureBox(device)
            queue.async { [weak self] in self?.deviceDisconnected(box.value) }
        })
        locked { observers = tokens }
    }

    /// KVO on the camera's active format and format list. Registered on the camera queue; the
    /// handlers hop back to it.
    private func watchDevice(of graph: CaptureGraph) {
        let queue = sessionQueue
        let changed: @Sendable () -> Void = { [weak self] in queue.async { [weak self] in self?.signalMayHaveChanged() } }
        let observations = [
            graph.videoDevice.observe(\.activeFormat, options: [.new]) { _, _ in changed() },
            graph.videoDevice.observe(\.formats, options: [.new]) { _, _ in changed() },
        ]
        let stale = locked { () -> [NSKeyValueObservation] in
            guard self.graph === graph else { return observations }
            deviceObservations = observations
            return []
        }
        stale.forEach { $0.invalidate() }
    }

    private func sessionFailed(_ message: String) {
        guard let graph = locked({ graph }) else { return }
        locked { errors.append("Camera session error: \(message)") }
        log(.error, ["source": "camera", "message": message])
        graph.controller?.finishEarly(reason: "Camera session error: \(message)")
        onEvent?(.sessionError(message))
    }

    private func sessionStopped() {
        // teardown() removes this observer before it stops the session, so this stop is not ours.
        guard locked({ graph }) != nil else { return }
        locked { errors.append("The camera session stopped running.") }
        log(.warning, ["source": "camera", "message": "The camera session stopped running."])
        onEvent?(.sessionStopped)
    }

    /// Camera queue. The camera audio input counts only while the session holds it (the recording
    /// graph, or the metered preview): the plain preview does not use it, and preflight checks it
    /// again before Start.
    private func deviceDisconnected(_ device: AVCaptureDevice) {
        guard let graph = locked({ graph }) else { return }
        let uid = device.uniqueID, name = device.localizedName
        let role: TrackInfo.Role
        if uid == config.videoDeviceUID { role = .cameraVideo }
        else if uid == config.audioDeviceUID, graph.audioDevice != nil { role = .mic }
        else { return }
        locked { errors.append("\(name) was disconnected.") }
        log(.deviceLost, ["source": "camera", "device": name, "uid": uid, "role": role.rawValue])
        graph.controller?.finishEarly(reason: "\(name) was disconnected.")
        onEvent?(.deviceDisconnected(name: name, role: role))
    }

    /// The camera's active format or format list changed. Camera queue.
    private func signalMayHaveChanged() {
        guard let graph = locked({ graph }) else { return }
        let device = graph.videoDevice
        guard !device.formats.isEmpty, let now = CaptureDevices.candidate(device.activeFormat) else {
            onEvent?(.signalChanged(nil))
            return
        }
        // A new size, or a new rate at the same size (the a6600 switched 24p to 30p): camera.mov's
        // grid runs the rate the camera opened with, so both are a new signal.
        let sizeChanged = now.width != graph.width || now.height != graph.height
        guard sizeChanged || FormatMatcher.rateChanged(now, from: graph.gridFrameRate) else { return }
        let was = sizeChanged ? "\(graph.width)x\(graph.height)" : "\(graph.width)x\(graph.height) \(graph.gridFrameRate.label)"
        let message = "\(device.localizedName) changed to \(FormatLabel.signal(now)) (was \(was))."
        let first = locked { () -> Bool in
            let label = "signal changed to \(FormatLabel.signal(now))"
            guard formatChange != label else { return false }
            errors.append(message)
            formatChange = label
            return true
        }
        guard first else { return }
        log(.warning, ["source": "camera", "message": message])
        onEvent?(.signalChanged(FormatLabel.signal(now)))
    }

    // MARK: - Helpers

    private func log(_ kind: SessionEvent.Kind, _ data: [String: String]) {
        locked { events }?.append(kind, data)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static let log = Logger(subsystem: "com.lukebarousse.twintake", category: "session")

    /// The longest `stop()` waits for the camera to go back to its preview graph (normally well
    /// under a second).
    static let returnToPreviewLimit: TimeInterval = 5

    /// Awaits `work`, but at most `seconds`; after that `work` goes on by itself. Never blocks.
    static func waitAtMost(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            Task {
                await work()
                once.resume()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { once.resume() }
        }
    }

    /// Runs `work` on the camera queue and awaits its result. The caller suspends; it never blocks.
    private func onSessionQueue<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<T, E>, Never>) in
            sessionQueue.async { cont.resume(returning: Result { () throws(E) -> T in try work() }) }
        }
        return try result.get()
    }
}

/// Resumes a continuation once, from whichever side comes first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = Mutex(continuation) }

    func resume() {
        continuation.withLock { c -> CheckedContinuation<Void, Never>? in
            defer { c = nil }
            return c
        }?.resume()
    }
}

/// The capture objects of one open camera, in the preview or the recording graph. Built, changed
/// and read only on the camera queue. Other threads may hold the reference and read `codec`,
/// `width` and `height` (plain values set at build).
final class CaptureGraph: @unchecked Sendable {
    /// Plain values other threads may read, copied out on the camera queue.
    struct Snapshot: Sendable, Equatable {
        var negotiatedFormat: String
        var formatWarning: String?
        /// What the camera sends and camera.mov records.
        var signal: CameraSignal
        /// The inputs and outputs the session holds.
        var plan: CameraGraphPlan
        /// The session ran when the snapshot was taken.
        var running: Bool
        /// The camera's USB link when it opened.
        var usbLink: USBLinkInfo? = nil
        /// The camera's name.
        var deviceName: String = ""
    }

    /// What `start` needs, read on the camera queue right before the file starts.
    struct StartFacts: @unchecked Sendable {
        var snapshot: Snapshot
        /// The session's synchronizationClock. CMClock is thread-safe.
        var clock: CMClock?
        var videoDeviceName: String
        var audioDeviceName: String?
        /// The preview output is in the session while the file records.
        var previewAttached: Bool
    }

    /// The preview data output and its delegate, while the session feeds a preview.
    private struct PreviewTap {
        let output: AVCaptureVideoDataOutput
        let receiver: PreviewFrameReceiver
    }

    /// The recording outputs and their writer controller: only in the recording graph. `output`
    /// is the full-size video data output; `audioOutput` the camera audio data output, when the
    /// graph holds the camera audio input.
    private struct MovieTap {
        let output: AVCaptureVideoDataOutput
        let audioOutput: AVCaptureAudioDataOutput?
        let controller: CameraWriterController
        let videoConnection: AVCaptureConnection

        var outputs: [AVCaptureOutput] { [output] + (audioOutput.map { [$0] } ?? []) }

        /// Takes the outputs out of `session`. Inside a session configuration.
        func remove(from session: AVCaptureSession) { outputs.forEach(session.removeOutput) }

        /// Stops the outputs calling the controller.
        func detach() {
            output.setSampleBufferDelegate(nil, queue: nil)
            audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    /// The camera audio input: in the recording graph, and in the metered preview graph.
    private struct AudioTap {
        let device: AVCaptureDevice
        let input: AVCaptureDeviceInput
        var channels: Int
    }

    /// The idle camera mic meter: an audio data output on the camera audio input whose delegate
    /// only meters (no file). Only in the metered preview graph.
    private struct MeterTap {
        let output: AVCaptureAudioDataOutput
        let tap: AudioMeterTap

        /// Stops the output calling the meter, and hands on the meter's last block.
        func detach() {
            output.setSampleBufferDelegate(nil, queue: nil)
            tap.flushSoon()
        }
    }

    /// What one change added to the session, so a failed change can take it out again.
    private struct Added {
        var inputs: [AVCaptureInput] = []
        var outputs: [AVCaptureOutput] = []
        var preview: PreviewTap?
        /// The new recording outputs with their settings and controller, set inside the configuration.
        var movie: MovieTap?
        /// The new idle camera mic meter.
        var meter: MeterTap?
    }

    let session: AVCaptureSession
    let videoDevice: AVCaptureDevice
    /// The camera's name and USB link, read at build: plain values any thread may read.
    let deviceName: String
    let usbLink: USBLinkInfo?
    /// Where the camera mic's levels go, for the recording outputs' writer controller.
    let levels: AudioLevelMonitor?
    /// The empty-frame state of both pipelines (the preview output and the recording output).
    let pictureCheck = PictureCheck()
    /// The clock recovery of this session's device stream. The preview output and each take's
    /// recording output feed it, so a take corrects for the drift since the camera opened (or
    /// since its format was last set again), also after the camera ran in the preview.
    let streamClock = StreamClock()
    let codec: VideoCodec
    let width: Int
    let height: Int
    private let config: CameraRecorderConfig
    /// The format and frame duration set on the camera.
    private let deviceFormat: AVCaptureDevice.Format
    private let frameDuration: CMTime
    private let pixelFormat: String
    /// The rate camera.mov's grid runs at: the configured one, or the camera's signal snapped.
    private let wantedFrameRate: FrameRate
    /// `wantedFrameRate`, for the signal check. Plain value set at build.
    var gridFrameRate: FrameRate { wantedFrameRate }
    private(set) var frameRate: FrameRate
    private(set) var negotiatedFormat: String
    /// Set when the camera does not run the format or rate it was set to.
    private(set) var formatWarning: String?
    private var deviceLocked = true
    private var previewTap: PreviewTap?
    private var movie: MovieTap?
    private var audio: AudioTap?
    private var meterTap: MeterTap?

    private init(session: AVCaptureSession, videoDevice: AVCaptureDevice, config: CameraRecorderConfig,
                 codec: VideoCodec, deviceFormat: AVCaptureDevice.Format,
                 candidate: VideoFormatCandidate, frameDuration: CMTime, frameRate: FrameRate,
                 levels: AudioLevelMonitor?, usbLink: USBLinkInfo?) {
        self.session = session; self.videoDevice = videoDevice; self.config = config
        self.deviceName = videoDevice.localizedName; self.usbLink = usbLink; self.levels = levels
        self.codec = codec
        self.deviceFormat = deviceFormat; self.frameDuration = frameDuration
        self.width = candidate.width; self.height = candidate.height; self.pixelFormat = candidate.pixelFormat
        self.wantedFrameRate = frameRate; self.frameRate = frameRate
        self.negotiatedFormat = FormatLabel.negotiated(width: candidate.width, height: candidate.height,
                                                       pixelFormat: candidate.pixelFormat, frameRate: frameRate)
    }

    /// What the session holds now. Camera queue.
    var plan: CameraGraphPlan {
        var parts: Set<CameraGraphPlan.Part> = []
        if audio != nil { parts.insert(.audioInput) }
        if meterTap != nil { parts.insert(.audioMeter) }
        if movie != nil { parts.insert(.movieOutput) }
        if previewTap != nil { parts.insert(.previewOutput) }
        return CameraGraphPlan(parts)
    }

    /// What the camera sends and camera.mov records. Camera queue.
    var signal: CameraSignal { CameraSignal(width: width, height: height, frameRate: frameRate, pixelFormat: pixelFormat) }

    /// Camera queue.
    var snapshot: Snapshot {
        Snapshot(negotiatedFormat: negotiatedFormat, formatWarning: formatWarning, signal: signal, plan: plan,
                 running: session.isRunning, usbLink: usbLink, deviceName: deviceName)
    }

    /// The recording outputs' writer controller, in the recording graph. Camera queue.
    var controller: CameraWriterController? { movie?.controller }

    /// The recording video output's connection, in the recording graph. Camera queue.
    var videoConnection: AVCaptureConnection? { movie?.videoConnection }

    /// The camera audio device, while the session holds its input. Camera queue.
    var audioDevice: AVCaptureDevice? { audio?.device }

    /// The session feeds a preview now. Camera queue.
    var hasPreview: Bool { previewTap != nil }

    /// The idle camera mic meter may join: the graph has a monitor, the config a camera audio
    /// input that is connected, and the microphone is allowed (no prompt). Camera queue.
    func mayMeterIdle() -> Bool {
        levels != nil && config.audioDeviceUID.flatMap(Self.idleMeterDevice(uid:)) != nil
    }

    /// The camera audio device for the idle meter, or nil when it is not connected or the
    /// microphone is not allowed. Reads the permission without asking for it. Camera queue.
    static func idleMeterDevice(uid: String) -> AVCaptureDevice? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = AVCaptureDevice(uniqueID: uid), device.isConnected else { return nil }
        return device
    }

    /// The device format to record and its frame rate: the configured size and rate when the config
    /// names them, else the camera's signal (`CameraSignal.resolve`).
    static func pickFormat(config: CameraRecorderConfig, candidates: [VideoFormatCandidate],
                           cameraName: String) throws(CameraRecorderError) -> (index: Int, frameRate: FrameRate) {
        if let width = config.width, let height = config.height, let frameRate = config.frameRate {
            guard let index = FormatMatcher.bestMatch(in: candidates, width: width, height: height, frameRate: frameRate) else {
                throw .noMatchingFormat(message: CameraMessages.formatUnavailable(
                    cameraName: cameraName, offered: candidates, width: width, height: height, frameRate: frameRate))
            }
            return (index, frameRate)
        }
        guard let resolved = CameraSignal.resolve(candidates) else {
            throw .noMatchingFormat(message: CameraMessages.noSignal(cameraName: cameraName))
        }
        return (resolved.index, resolved.signal.frameRate)
    }

    /// Opens the devices and configures the session with the parts of `plan`. Runs on the camera
    /// queue. On success the camera stays locked for configuration until `startRunning()`.
    static func build(config: CameraRecorderConfig, plan: CameraGraphPlan,
                      preview: CameraPreviewFeed? = nil, levels: AudioLevelMonitor? = nil) throws -> CaptureGraph {
        CaptureThread.assertOffMain("Building the capture session")
        guard let device = AVCaptureDevice(uniqueID: config.videoDeviceUID) else {
            throw CameraRecorderError.cameraNotFound(uid: config.videoDeviceUID)
        }
        let pairs = device.formats.compactMap { f in CaptureDevices.candidate(f).map { (f, $0) } }
        let (index, wanted) = try pickFormat(config: config, candidates: pairs.map(\.1), cameraName: device.localizedName)
        let (format, candidate) = pairs[index]
        // Always inside one of the format's ranges: a duration outside them raises an Objective-C
        // exception that ends the app (a format that runs 29.95 fps for a 30000/1001 signal).
        let duration = FormatMatcher.frameDuration(for: wanted, in: candidate)

        var audioDevice: AVCaptureDevice?
        if plan.hasAudioInput, let uid = config.audioDeviceUID {
            if plan.hasMovieOutput {
                guard let found = AVCaptureDevice(uniqueID: uid) else { throw CameraRecorderError.audioDeviceNotFound(uid: uid) }
                audioDevice = found
            } else if plan.hasAudioMeter, levels != nil {
                // The idle meter is best effort: the picture opens without it when the camera
                // audio is missing or the microphone is not allowed.
                audioDevice = idleMeterDevice(uid: uid)
            }
        }
        // The grid rate is the exact standard rational, whatever the device's own rounding of it
        // (the Cam Link's 1251/30000 s frame duration is 23.98 fps, recorded as 24000/1001).
        let frameRate = wanted
        let codec = Self.codec(requested: config.codec, bitrate: config.bitrate, width: candidate.width,
                               height: candidate.height, frameRate: frameRate)

        // Center Stage crops and pans the picture. Take it from Control Center for this app and keep it off.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let session = AVCaptureSession()
        let link = CameraUSB.link(forUniqueID: device.uniqueID, name: device.localizedName)
        let graph = CaptureGraph(session: session, videoDevice: device, config: config, codec: codec,
                                 deviceFormat: format, candidate: candidate, frameDuration: duration, frameRate: frameRate,
                                 levels: levels, usbLink: link)
        let output = plan.hasMovieOutput ? makeMovieOutput() : nil
        var audioInput: AVCaptureDeviceInput?

        session.beginConfiguration()
        do {
            try add(AVCaptureDeviceInput(device: device), named: device.localizedName, to: session)
            if let audioDevice {
                if output != nil {
                    let input = try AVCaptureDeviceInput(device: audioDevice)
                    try add(input, named: audioDevice.localizedName, to: session)
                    audioInput = input
                } else if let input = try? AVCaptureDeviceInput(device: audioDevice), session.canAddInput(input) {
                    // The idle meter's input: one that cannot join leaves the meter out, not the picture.
                    session.addInput(input)
                    audioInput = input
                }
            }
            if let output {
                guard session.canAddOutput(output) else {
                    throw CameraRecorderError.cannotUseDevice(name: "the recording video output", reason: "the session cannot add it.")
                }
                session.addOutput(output)
                // After the audio input, so the camera audio output gets its connection. Its
                // settings and delegates are set before the session starts.
                let (movie, channels) = try graph.attachMovie(output, audioDevice: audioDevice)
                graph.movie = movie
                if let audioDevice, let audioInput {
                    graph.audio = AudioTap(device: audioDevice, input: audioInput, channels: channels)
                }
            } else if let audioDevice, let audioInput {
                // The idle camera mic meter, after the audio input so its output gets a connection.
                if let meter = graph.makeMeterTap() {
                    graph.meterTap = meter
                    graph.audio = AudioTap(device: audioDevice, input: audioInput,
                                           channels: CaptureDevices.audioFormat(of: audioDevice)?.channels ?? 2)
                } else {
                    session.removeInput(audioInput)
                }
            }

            // Kept locked until startRunning returns: on macOS the session can otherwise reset the
            // format when it starts. Nothing below throws, so the catch never has to unlock.
            try device.lockForConfiguration()
            apply(format: format, duration: duration, to: device)
            // After the format is set, so the preview size follows the format the camera runs.
            if plan.hasPreviewOutput {
                graph.previewTap = preview.flatMap {
                    addPreviewOutput(feed: $0, to: session, device: device, clock: graph.streamClock, picture: graph.pictureCheck)
                }
            }
            if let output { turnOffAutomaticLowLight(output) }
        } catch {
            graph.movie?.detach()
            graph.meterTap?.detach()
            session.commitConfiguration()
            if error is CameraRecorderError { throw error }
            throw CameraRecorderError.cannotUseDevice(name: device.localizedName, reason: error.localizedDescription)
        }
        session.commitConfiguration()
        return graph
    }

    /// The codec camera.mov uses: the requested one when this Mac has its encoder and the writer
    /// takes the settings, else HEVC.
    static func codec(requested: VideoCodec, bitrate: Int, width: Int, height: Int, frameRate: FrameRate) -> VideoCodec {
        let codec = CameraOutputSettings.effectiveCodec(
            requested: requested, availableEncoders: CameraOutputSettings.availableEncoderCodecTypes())
        if codec != .hevc, !CameraOutputSettings.writerAccepts(
            CameraOutputSettings.video(codec: codec, width: width, height: height, frameRate: frameRate, bitrate: bitrate),
            mediaType: .video) {
            return .hevc
        }
        return codec
    }

    /// The full-size recording video output, not yet in a session. It drops a frame that comes
    /// while its delegate still holds the one before (never queues them up), so a slow writer can
    /// never hold back the capture; the writer repeats the last picture for a missing slot.
    private static func makeMovieOutput() -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        return output
    }

    /// videoSettings for the recording output: the camera's full size (no width or height keys,
    /// so nothing is scaled), in 420v when the output offers it (what the Cam Link sends and what
    /// HEVC and H.264 encode natively), else the device's own format.
    static func recordingVideoSettings(availablePixelFormats: [OSType]) -> [String: Any]? {
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard availablePixelFormats.contains(yuv) else { return nil }
        return [kCVPixelBufferPixelFormatTypeKey as String: yuv]
    }

    /// The system's low-light noise reduction filter. It is on by default only for movie file
    /// outputs, but turn the automatic mode off for the recording output too: the HDMI picture
    /// stays as it is. Inside a session configuration.
    private static func turnOffAutomaticLowLight(_ output: AVCaptureOutput) {
        if #available(macOS 27.0, *), let connection = output.connection(with: .video) {
            connection.automaticallyEnablesLowLightVideoNoiseReduction = false
        }
    }

    /// Sets the recording outputs up and makes their writer controller: the full-size video
    /// settings on `output`, and the camera audio data output (added to the session here) when
    /// `audioDevice` is set. After `output` joined the session (the session forms its connections
    /// at addOutput), inside the configuration that adds it, before any file. Camera queue. On a
    /// throw nothing it added stays in the session.
    private func attachMovie(_ output: AVCaptureVideoDataOutput,
                             audioDevice: AVCaptureDevice?) throws(CameraRecorderError) -> (MovieTap, channels: Int) {
        guard let videoConnection = output.connection(with: .video) else {
            throw .cannotUseDevice(name: videoDevice.localizedName, reason: "it gives the recording output no video connection.")
        }
        output.videoSettings = Self.recordingVideoSettings(availablePixelFormats: output.availableVideoPixelFormatTypes)
        if #available(macOS 27.0, *) {
            // Keep the HDMI picture as is. With the automatic mode off, setting false is always allowed.
            videoConnection.automaticallyEnablesLowLightVideoNoiseReduction = false
            if videoConnection.isLowLightVideoNoiseReductionEnabled {
                videoConnection.isLowLightVideoNoiseReductionEnabled = false
            }
        }
        var channels = 0
        var audioOutput: AVCaptureAudioDataOutput?
        if let audioDevice {
            let candidate = AVCaptureAudioDataOutput()
            guard session.canAddOutput(candidate) else {
                throw .cannotUseDevice(name: audioDevice.localizedName, reason: "the session cannot add its audio output.")
            }
            session.addOutput(candidate)
            guard let audioConnection = candidate.connection(with: .audio) else {
                session.removeOutput(candidate)
                throw .cannotUseDevice(name: audioDevice.localizedName, reason: "it gives the audio output no connection.")
            }
            channels = CaptureDevices.audioFormat(of: audioDevice)?.channels ?? audioConnection.audioChannels.count
            channels = channels > 0 ? channels : 2
            audioOutput = candidate
        }
        let controller = CameraWriterController(frameRate: wantedFrameRate, audioChannels: audioOutput == nil ? nil : channels,
                                                streamClock: streamClock, levels: levels, picture: pictureCheck)
        output.setSampleBufferDelegate(controller, queue: controller.videoQueue)
        audioOutput?.setSampleBufferDelegate(controller, queue: controller.audioQueue)
        return (MovieTap(output: output, audioOutput: audioOutput, controller: controller, videoConnection: videoConnection), channels)
    }

    /// Adds a small video data output that feeds `feed`. Inside a session configuration, after the
    /// device format is set. Nil (no preview, recording unaffected) when the session cannot add it.
    /// About 640x360 420v, late frames dropped: the output may stay while camera.mov records 4K.
    /// Its frames also feed `clock`, the stream's clock recovery.
    private static func addPreviewOutput(feed: CameraPreviewFeed, to session: AVCaptureSession,
                                         device: AVCaptureDevice, clock: StreamClock, picture: PictureCheck) -> PreviewTap? {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        // Same aspect ratio as the camera format and never larger than it: on iOS a mismatch
        // throws, and macOS documents no rule, so stay inside both.
        let dims = device.formats.isEmpty ? nil : CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let size = PreviewSize.fit(width: Int(dims?.width ?? 1920), height: Int(dims?.height ?? 1080))
        output.videoSettings = PreviewSize.videoSettings(width: size.width, height: size.height,
                                                         availablePixelFormats: output.availableVideoPixelFormatTypes)
        let receiver = PreviewFrameReceiver(feed: feed, streamClock: clock, picture: picture)
        output.setSampleBufferDelegate(receiver, queue: feed.queue)
        return PreviewTap(output: output, receiver: receiver)
    }

    /// Adds the idle camera mic meter: an audio data output on the camera audio input, delivering to
    /// an `AudioMeterTap` that meters into `levels`. Inside a session configuration, after the
    /// audio input joined. Nil (no meter, nothing else affected) without `levels`, or when the
    /// session cannot add it or gives it no audio connection. Its clock is set after the session
    /// runs (`startRunning`, `change`).
    private func makeMeterTap() -> MeterTap? {
        guard let levels else { return nil }
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        guard output.connection(with: .audio) != nil else {
            session.removeOutput(output)
            return nil
        }
        let tap = AudioMeterTap(meter: AudioLevelMeter(source: .cameraMic, monitor: levels), label: "TwinTake.camera.meter")
        output.setSampleBufferDelegate(tap, queue: tap.queue)
        return MeterTap(output: output, tap: tap)
    }

    /// Changes the running session to `wanted` in one beginConfiguration/commitConfiguration, then
    /// sets the camera's format and rate again if the change reset them. Camera queue; never while
    /// camera.mov is written (`CameraGraphStep.allowed(whileWritingFile:)`).
    ///
    /// Everything that can fail runs before the session changes, or is undone inside the same
    /// configuration (the recording outputs get their settings and delegates there too, so a
    /// missing connection fails before the commit), so the session never commits a half-built
    /// graph. A session that stopped by the commit undoes the change: what it added leaves, and a
    /// preview output it removed comes back. A removed audio input, recording output or idle meter
    /// never comes back: going back to the preview graph fails only when the session stopped, and
    /// the camera then closes.
    ///
    /// The camera audio input stays when both graphs hold it: from the metered preview, Start only
    /// adds the recording outputs (whose audio output joins the kept input) and drops the idle
    /// meter; Stop goes back the same way. The idle meter is best effort: one the session cannot
    /// add is left out, and nothing else fails.
    /// - Parameter feed: the preview to feed when the change adds the preview output.
    /// - Returns: the change, or nil when the session already holds `wanted`.
    func change(to wanted: CameraGraphPlan, preview feed: CameraPreviewFeed?) throws(CameraRecorderError) -> CameraGraphChange? {
        CaptureThread.assertOffMain("Changing the capture session")
        let began = HostClock.nowNs()
        let before = plan
        let step = CameraGraphStep.from(before, to: wanted)
        guard step.allowed(whileWritingFile: movie?.controller.isActive ?? false) else {
            throw .cannotUseDevice(name: "the camera session", reason: "camera.mov is still being written.")
        }
        guard case let .change(add, remove) = step else { return nil }
        guard session.isRunning else {
            throw .sessionNotRunning(reason: "it stopped before the camera could change to the \(wanted.shape.rawValue) graph.")
        }
        // The session clock can change at the commit (the audio input joins or leaves): preview
        // frames stop counting in the stream clock until it is read again.
        streamClock.pausePreview()
        defer { if session.isRunning { streamClock.setPreviewClock(session.synchronizationClock) } }

        // 1. What can fail before the session changes: the camera audio device and its input.
        var newAudio: AudioTap?
        if add.contains(.audioInput) {
            let uid = config.audioDeviceUID ?? ""
            guard let device = AVCaptureDevice(uniqueID: uid), device.isConnected else { throw .audioDeviceNotFound(uid: uid) }
            do {
                newAudio = AudioTap(device: device, input: try AVCaptureDeviceInput(device: device), channels: 0)
            } catch {
                throw .cannotUseDevice(name: device.localizedName, reason: error.localizedDescription)
            }
        }
        // The camera audio the recording outputs and the idle meter get: the input this change
        // adds, or the one the session keeps (the metered preview's at Start, the take's after Stop).
        var removesAudio = remove.contains(.audioInput)
        let movieAudio = newAudio?.device ?? (removesAudio ? nil : audio?.device)
        var movieChannels: Int?

        // 2. One configuration.
        var added = Added()
        var failure: CameraRecorderError?
        session.beginConfiguration()
        if let newAudio {
            if session.canAddInput(newAudio.input) {
                session.addInput(newAudio.input)
                added.inputs.append(newAudio.input)
            } else {
                failure = .cannotUseDevice(name: newAudio.device.localizedName, reason: "the capture session cannot add it.")
            }
        }
        if failure == nil, add.contains(.movieOutput) {
            let output = Self.makeMovieOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                added.outputs.append(output)
                Self.turnOffAutomaticLowLight(output)
                // Before the commit: the outputs join the running session with their settings and
                // their delegates, as in build() where both are set before startRunning. After the
                // audio input, so the camera audio output gets its connection.
                do {
                    let (tap, channels) = try attachMovie(output, audioDevice: movieAudio)
                    added.movie = tap
                    if let audioOutput = tap.audioOutput { added.outputs.append(audioOutput) }
                    movieChannels = channels
                } catch {
                    failure = error
                }
            } else {
                failure = .cannotUseDevice(name: "the recording video output", reason: "the session cannot add it.")
            }
        }
        if failure == nil, add.contains(.previewOutput), let feed {
            // Nil when the session cannot add it: no preview, the take is unaffected (as in build()).
            added.preview = Self.addPreviewOutput(feed: feed, to: session, device: videoDevice, clock: streamClock,
                                                  picture: pictureCheck)
            if let tap = added.preview { added.outputs.append(tap.output) }
        }
        if failure == nil, add.contains(.audioMeter), movieAudio != nil {
            // After the audio input, so the meter's output gets its connection. Nil: no meter.
            added.meter = makeMeterTap()
            if let meter = added.meter { added.outputs.append(meter.output) }
            // No meter: the preview graph holds no camera audio input without it (as in build()),
            // or macOS would show the microphone indicator with nothing metered. The input this
            // change added leaves again in the same configuration; a kept one (the take's, after
            // Stop) leaves too.
            if added.meter == nil, !wanted.hasMovieOutput {
                if let input = newAudio?.input {
                    session.removeInput(input)
                    added.inputs.removeAll { $0 === input }
                    newAudio = nil
                } else if audio != nil {
                    removesAudio = true
                }
            }
        }
        // The idle meter leaves with the camera audio input, never stays without it.
        let removesMeter = remove.contains(.audioMeter) || removesAudio
        var removedPreview: PreviewTap?
        if failure == nil {
            if remove.contains(.previewOutput), let tap = previewTap {
                session.removeOutput(tap.output)
                removedPreview = tap
            }
            if removesMeter, let meterTap { session.removeOutput(meterTap.output) }
            if remove.contains(.movieOutput), let movie { movie.remove(from: session) }
            if removesAudio, let audio { session.removeInput(audio.input) }
        } else {
            // Undone in the same configuration: the session commits no change at all.
            added.outputs.forEach(session.removeOutput)
            added.inputs.forEach(session.removeInput)
            added.preview?.output.setSampleBufferDelegate(nil, queue: nil)
            added.movie?.detach()
            added.meter?.detach()
        }
        // Locked through the commit, as in build(), so the session keeps the camera's format. Set
        // only when the camera runs something else: the preview stream keeps running meanwhile.
        let lockedDevice = (try? videoDevice.lockForConfiguration()) != nil
        let resetBeforeCommit = lockedDevice && !runsWantedConfiguration()
        if resetBeforeCommit { Self.apply(format: deviceFormat, duration: frameDuration, to: videoDevice) }
        session.commitConfiguration()
        if lockedDevice { videoDevice.unlockForConfiguration() }
        if let failure {
            keepWantedConfiguration()
            throw failure
        }

        // A removed recording output, idle meter and audio input are out of the session from here on.
        if remove.contains(.movieOutput), let movie {
            movie.detach()
            self.movie = nil
            pictureCheck.forget(.recording)
        }
        if removesMeter, let meterTap {
            meterTap.detach()
            self.meterTap = nil
        }
        if removesAudio { audio = nil }

        // 3. After the commit: the session must still run.
        guard session.isRunning else {
            undo(added, restoring: removedPreview)
            throw .sessionNotRunning(reason: "it stopped while the camera changed to the \(wanted.shape.rawValue) graph.")
        }

        if let removedPreview {
            removedPreview.output.setSampleBufferDelegate(nil, queue: nil)
            previewTap = nil
            pictureCheck.forget(.preview)
        }
        if let tap = added.preview { previewTap = tap }
        if let newMovie = added.movie { movie = newMovie }
        if let newMeter = added.meter { meterTap = newMeter }
        if var newAudio {
            newAudio.channels = movieChannels ?? CaptureDevices.audioFormat(of: newAudio.device)?.channels ?? 2
            audio = newAudio
        } else if let movieChannels {
            audio?.channels = movieChannels
        }
        // A new session configuration can reset the device format; set it again if it did. A
        // reset found before the commit counts too.
        let reset = keepWantedConfiguration() || resetBeforeCommit
        // The device stream started over with the format set again: a new clock reference, and
        // the empty-frame grace of a starting stream.
        if resetBeforeCommit {
            streamClock.reset()
            pictureCheck.streamRestarted()
        }
        // The audio input can make the session clock an audio device clock. start() reads it again.
        movie?.controller.configure(syncClock: session.synchronizationClock)
        meterTap?.tap.setClock(session.synchronizationClock)
        return describe(from: before, began: began, formatReset: reset)
    }

    /// Takes out what a change added and puts back a preview output it removed. Camera queue.
    private func undo(_ added: Added, restoring removedPreview: PreviewTap?) {
        session.beginConfiguration()
        added.outputs.forEach(session.removeOutput)
        added.inputs.forEach(session.removeInput)
        var restored = false
        if let tap = removedPreview, session.canAddOutput(tap.output) {
            session.addOutput(tap.output)
            restored = true
        }
        session.commitConfiguration()
        added.movie?.detach()
        added.meter?.detach()
        added.preview?.output.setSampleBufferDelegate(nil, queue: nil)
        if let tap = removedPreview, !restored {
            tap.output.setSampleBufferDelegate(nil, queue: nil)
            previewTap = nil
        }
        keepWantedConfiguration()
    }

    /// The change that led to the graph the session holds now. Camera queue.
    func describe(from: CameraGraphPlan?, began: UInt64, formatReset: Bool) -> CameraGraphChange {
        let now = HostClock.nowNs()
        return CameraGraphChange(from: from, to: plan, durationNs: now > began ? now - began : 0, formatReset: formatReset,
                                 negotiatedFormat: negotiatedFormat, audioDevice: audio?.device.localizedName)
    }

    /// Removes the preview output, so the session holds only what camera.mov records. Camera queue,
    /// before the file starts (never while it is written).
    func detachPreview() {
        CaptureThread.assertOffMain("Removing the preview output")
        guard let tap = previewTap, movie?.controller.isActive != true else { return }
        previewTap = nil
        session.beginConfiguration()
        session.removeOutput(tap.output)
        session.commitConfiguration()
        tap.output.setSampleBufferDelegate(nil, queue: nil)
        pictureCheck.forget(.preview)
        // A new session configuration can reset the device format; set it again if it did.
        if session.isRunning { keepWantedConfiguration() }
    }

    /// The session clock and device names, for start. Camera queue.
    func startFacts() -> StartFacts {
        StartFacts(snapshot: snapshot, clock: session.synchronizationClock,
                   videoDeviceName: videoDevice.localizedName, audioDeviceName: audio?.device.localizedName,
                   previewAttached: hasPreview)
    }

    private static func add(_ input: AVCaptureDeviceInput, named name: String, to session: AVCaptureSession) throws {
        guard session.canAddInput(input) else {
            throw CameraRecorderError.cannotUseDevice(name: name, reason: "the capture session cannot add it.")
        }
        session.addInput(input)
    }

    /// Sets the format and a fixed frame rate. The device must be locked for configuration.
    private static func apply(format: AVCaptureDevice.Format, duration: CMTime, to device: AVCaptureDevice) {
        // Setting a format the device no longer lists raises an Objective-C exception.
        guard device.formats.contains(format) else { return }
        if device.activeFormat != format { device.activeFormat = format }
        if format.isAutoVideoFrameRateSupported, device.isAutoVideoFrameRateEnabled {
            device.isAutoVideoFrameRateEnabled = false
        }
        // So does a frame duration outside the format's ranges. Then the format keeps its own
        // rate, and `readBackConfiguration` reports the mismatch.
        let ranges = format.videoSupportedFrameRateRanges.map { (min: $0.minFrameDuration, max: $0.maxFrameDuration) }
        guard FormatMatcher.durationFits(duration, ranges: ranges) else { return }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    /// Starts the session (blocks), then checks that the camera kept the chosen format and rate,
    /// and sets them once more if it did not. Runs on the camera queue.
    /// - Returns: true when the format or rate had to be set again.
    @discardableResult
    func startRunning() throws -> Bool {
        CaptureThread.assertOffMain("Starting the capture session")
        session.startRunning()
        if deviceLocked {
            videoDevice.unlockForConfiguration()
            deviceLocked = false
        }
        guard session.isRunning else { throw CameraRecorderError.sessionNotRunning(reason: nil) }
        let reset = keepWantedConfiguration()
        controller?.configure(syncClock: session.synchronizationClock)
        meterTap?.tap.setClock(session.synchronizationClock)
        streamClock.setPreviewClock(session.synchronizationClock)
        return reset
    }

    /// Sets the chosen format and rate again if the camera does not run them, then reads back what
    /// it runs. Camera queue, session running.
    /// - Returns: true when they had to be set again.
    @discardableResult
    private func keepWantedConfiguration() -> Bool {
        let reset = !runsWantedConfiguration()
        if reset {
            // A failed lock leaves the mismatch, which readBackConfiguration reports.
            session.beginConfiguration()
            if (try? videoDevice.lockForConfiguration()) != nil {
                Self.apply(format: deviceFormat, duration: frameDuration, to: videoDevice)
                videoDevice.unlockForConfiguration()
            }
            session.commitConfiguration()
            // The device stream starts over with the format set again: a new clock reference, and
            // the empty-frame grace of a starting stream.
            streamClock.reset()
            pictureCheck.streamRestarted()
        }
        readBackConfiguration()
        return reset
    }

    private func runsWantedConfiguration() -> Bool {
        !videoDevice.formats.isEmpty && videoDevice.activeFormat == deviceFormat
            && CMTimeCompare(videoDevice.activeVideoMinFrameDuration, frameDuration) == 0
    }

    private func readBackConfiguration() {
        guard !videoDevice.formats.isEmpty, let active = CaptureDevices.candidate(videoDevice.activeFormat) else {
            formatWarning = "\(videoDevice.localizedName) reports no active format."
            return
        }
        if let actual = StandardFrameRate.rate(forFrameDuration: videoDevice.activeVideoMinFrameDuration) { frameRate = actual }
        negotiatedFormat = FormatLabel.negotiated(width: active.width, height: active.height,
                                                  pixelFormat: active.pixelFormat, frameRate: frameRate)
        if active.width != width || active.height != height || frameRate != wantedFrameRate {
            formatWarning = "\(videoDevice.localizedName) runs \(negotiatedFormat), not the \(width)x\(height) "
                + "\(wantedFrameRate.label) it was set to."
        } else {
            // Set again and read back: an earlier mismatch is gone.
            formatWarning = nil
        }
    }

    /// Stops the session and releases the devices. Runs on the camera queue.
    ///
    /// stopRunning can wait for a call on the main thread while it holds the session lock (it does
    /// with a movie file output in the graph). That is safe only because the main thread never
    /// touches the session.
    func shutDown() {
        CaptureThread.assertOffMain("Stopping the capture session")
        if session.isRunning { session.stopRunning() }
        movie?.detach()
        meterTap?.detach()
        meterTap = nil
        if deviceLocked {
            videoDevice.unlockForConfiguration()
            deviceLocked = false
        }
        previewTap?.output.setSampleBufferDelegate(nil, queue: nil)
        previewTap = nil
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
    }

    /// session.json facts for this recording. Camera queue, before the camera leaves the
    /// recording graph (the audio facts come from its audio input).
    /// - Parameter codec: the codec the file was written with (`start`).
    func facts(timing: CameraWriterController.Timing, codec: VideoCodec) -> CameraTrackFacts {
        var facts = CameraTrackFacts(
            videoDevice: DeviceInfo(name: videoDevice.localizedName, uid: videoDevice.uniqueID, negotiatedFormat: negotiatedFormat),
            codec: codec, width: width, height: height, frameRate: movie?.controller.frameRate ?? frameRate)
        var audioDevice: DeviceInfo?
        if let audio {
            let format = CaptureDevices.audioFormat(of: audio.device).map { FormatLabel.audio(sampleRate: $0.sampleRate, channels: $0.channels) }
            audioDevice = DeviceInfo(name: audio.device.localizedName, uid: audio.device.uniqueID, negotiatedFormat: format)
        }
        facts.apply(video: timing.video, audio: timing.audio, audioDevice: audioDevice)
        return facts
    }

    /// "host" when sample timestamps are already on the host clock, else "converted from device clock".
    static func clockLabel(_ clock: CMClock?) -> String {
        guard let clock else { return "unknown (treated as host)" }
        if clock == CMClockGetHostTimeClock() { return "host" }
        let drifts = CMSyncMightDrift(clock, CMClockGetHostTimeClock())
        return drifts ? "device clock, converted to host per sample" : "device clock, locked to host"
    }
}
