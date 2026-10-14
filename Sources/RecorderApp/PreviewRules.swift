import CameraCapture
import Foundation
import RecorderCore

/// What the preview camera is built for: a recorder config plus the camera's signal when it
/// opened. A new signal (the a6600 switched 1080p to 4K, so the Cam Link lists other formats)
/// makes a new target, and the preview reopens. The codec and the bitrate are not part of it:
/// the camera session does not use them (`PreviewRules.sameCamera`), so changing them never
/// reopens the camera; the take hands them to the recorder (`CameraRecorder.useEncoder`).
struct PreviewTarget: Equatable, Sendable {
    var config: CameraRecorderConfig
    /// `DeviceInventory.signalSignature(forVideoUID:)` when it opened.
    var signal: String

    static func == (a: PreviewTarget, b: PreviewTarget) -> Bool {
        a.signal == b.signal && PreviewRules.sameCamera(a.config, b.config)
    }
}

/// The state of the open preview camera.
enum PreviewCameraState: Equatable, Sendable {
    case opening
    case ready
    case failed(String)
}

/// Why the preview is closed until a newer device list arrives: the camera reported a problem,
/// and its device may be re-enumerating.
enum PreviewHold: Equatable, Sendable {
    case disconnected
    case reopening(String)
}

/// What the preview should do next.
enum PreviewAction: Equatable, Sendable {
    case none
    case close
    case open(PreviewTarget)
    /// Close the camera that is open, then open this target.
    case reopen(PreviewTarget)
}

/// What the menu's preview box shows.
enum PreviewPhase: Equatable, Sendable {
    /// Not shown: the menu is closed, the preview is off, or a recording runs.
    case off
    case blocked(String)
    case waitingForCamera
    case reopening(String)
    case opening
    case failed(String)
    /// The session runs, but no frame came for a while: no HDMI signal.
    case noPicture
    /// Frames come, but they hold no picture (all-zero or flat planes: a Cam Link on its USB 2
    /// lane shows solid green). The view shows "No picture" instead of the green box; the banner
    /// says why and offers Reconnect.
    case emptyFrames
    /// Recording, and the preview output was removed at Start: Live picture while recording is off.
    case paused
    /// Recording, and the preview output was removed at Start because the camera window was off
    /// then (Live picture while recording is on): this take has no live picture.
    case pausedWindowOffAtStart
    case live

    /// The text over the preview, or nil when the picture shows.
    var message: String? {
        switch self {
        case .off, .live: nil
        case let .blocked(message), let .failed(message): message
        case .waitingForCamera: "Camera not connected. The preview comes back when it reconnects."
        case let .reopening(reason): "\(reason) Opening the camera again…"
        case .opening: "Opening camera…"
        case .noPicture: "No picture from the camera. Check the HDMI cable and the camera's HDMI output."
        case .emptyFrames: "No picture"
        case .paused: "Live picture is off while recording. It comes back after Stop."
        case .pausedWindowOffAtStart: "The camera window was off at Start, so this take has no live picture. It comes back after Stop."
        }
    }
}

/// Inputs for `PreviewRules.phase`, gathered by the coordinator.
struct PreviewInputs: Equatable {
    /// The menu is open, the mode records the camera, the preview is on, and nothing records.
    var showing: Bool
    var blocked: String?
    /// The settings pick a camera.
    var hasCamera: Bool
    /// That camera is in the latest device list.
    var connected: Bool
    var hold: PreviewHold?
    var camera: PreviewCameraState?
    /// A frame arrived recently (see `PreviewRules.pictureIsFresh`).
    var pictureFresh: Bool
    /// Why the preview waits before it opens the camera again (see `PreviewRetry`), if it does.
    var retryReason: String? = nil
    /// The frames that come hold no picture (`CameraPreviewFeed.Stats.emptyFrames`).
    var emptyFrames = false
}

/// Opens of one preview target in a row that went wrong: the open failed, the camera broke, or it
/// sent no picture. Each one makes the next open wait longer (`PreviewRules.retryDelayNs`), so a
/// camera that keeps failing is not opened and closed in a tight loop.
struct PreviewRetry: Equatable, Sendable {
    var target: PreviewTarget
    var attempts: Int
    /// The target does not open again before this host time.
    var notBeforeNs: UInt64
    /// Shown while the preview waits.
    var reason: String

    /// `previous` plus one more open of `target` that went wrong at `nowNs`.
    static func next(after previous: PreviewRetry?, target: PreviewTarget, reason: String, nowNs: UInt64) -> PreviewRetry {
        let attempts = (previous?.target == target ? previous?.attempts ?? 0 : 0) + 1
        return PreviewRetry(target: target, attempts: attempts,
                            notBeforeNs: nowNs + PreviewRules.retryDelayNs(attempt: attempts), reason: reason)
    }

    /// True while `target` must wait. Another target (new settings or a new signal) never waits.
    func blocks(_ target: PreviewTarget?, nowNs: UInt64) -> Bool {
        target == self.target && nowNs < notBeforeNs
    }
}

/// The part of a recording the camera window shows a picture for.
enum RecordingStage: Equatable, Sendable {
    case starting, recording, stopping
}

/// The preview's decisions, over plain data so they can be tested without a camera.
enum PreviewRules {
    /// The camera window's text in Screen mode, which opens no camera.
    static let screenModeMessage = "Screen mode records no camera. Pick Camera or Both to see it here."

    /// A frame older than this means the camera sends no picture.
    static let staleAfterNs: UInt64 = 1_500_000_000
    /// How long a newly opened camera may take to send its first frame.
    static let firstFrameGraceNs: UInt64 = 3_000_000_000
    /// A ready camera that sends no picture for this long is opened again, while it is still in
    /// the device list: after an HDMI signal comes back, a capture card may not restart its stream.
    static let reopenAfterNoPictureNs: UInt64 = 5_000_000_000
    /// A camera that still sends a picture this long after it opened works: its retry count
    /// (`PreviewRetry`) starts over.
    static let workingAfterNs: UInt64 = 5_000_000_000

    /// With the menu closed, only the camera window wants the preview, maybe all day. After this
    /// many opens of one target in a row went wrong, the open camera is not opened again: the window
    /// keeps its message until the target changes (a new signal or new settings), the camera sends
    /// a picture, the menu opens, or the window is turned on again.
    static let windowOnlyMaxAttempts = 4

    /// True when the open camera may open again after `shouldRetry` said it should: always while
    /// the menu is open; with only the camera window, until `windowOnlyMaxAttempts` for `target`.
    static func mayRetry(_ retry: PreviewRetry?, target: PreviewTarget?, menuVisible: Bool) -> Bool {
        guard !menuVisible, let retry, let target, retry.target == target else { return true }
        return retry.attempts < windowOnlyMaxAttempts
    }

    /// How long open number `attempt` of a target waits after the open before it went wrong:
    /// none for the first, then 2 s, 5 s, and 10 s from then on.
    static func retryDelayNs(attempt: Int) -> UInt64 {
        switch attempt {
        case ...1: 0
        case 2: 2_000_000_000
        case 3: 5_000_000_000
        default: 10_000_000_000
        }
    }

    /// Opens, reopens or closes the preview camera.
    /// - Parameters:
    ///   - wanted: the target the preview should show, or nil when no preview is wanted.
    ///   - connected: the wanted camera is in the latest device list.
    ///   - holding: a camera problem was reported and no newer device list has arrived yet.
    ///   - current: the target of the camera that is open (or failed to open), if any.
    ///   - retryCurrent: the open camera should open again (see `shouldRetry`).
    ///   - mustWait: the wanted target waits after earlier trouble (`PreviewRetry.blocks`).
    static func action(wanted: PreviewTarget?, connected: Bool, holding: Bool, current: PreviewTarget?,
                       retryCurrent: Bool = false, mustWait: Bool = false) -> PreviewAction {
        guard let wanted, connected, !holding else { return current == nil ? .none : .close }
        guard let current else { return mustWait ? .none : .open(wanted) }
        // A new target (settings or signal) reopens at once.
        guard current == wanted else { return .reopen(wanted) }
        // Same target: ready, still opening, or failed for this exact signal. It opens again only
        // after a failure that can pass, or a picture that stopped, and only when its wait is over.
        return retryCurrent && !mustWait ? .reopen(wanted) : .none
    }

    /// True when the open camera should open again: its open failed for a reason that can pass
    /// (`retryableFailure`; a missing format is not one), or it is ready and sent no picture for
    /// `reopenAfterNoPictureNs`.
    static func shouldRetry(_ camera: PreviewCameraState, retryableFailure: Bool, lastFrameNs: UInt64?,
                            readySinceNs: UInt64?, nowNs: UInt64) -> Bool {
        switch camera {
        case .opening: false
        case .failed: retryableFailure
        case .ready: !pictureIsFresh(lastFrameNs: lastFrameNs, readySinceNs: readySinceNs ?? nowNs, nowNs: nowNs,
                                     staleAfterNs: reopenAfterNoPictureNs, firstFrameGraceNs: reopenAfterNoPictureNs)
        }
    }

    /// True when a ready camera works: a fresh picture, at least `workingAfterNs` after it opened.
    static func cameraWorks(lastFrameNs: UInt64?, readySinceNs: UInt64, nowNs: UInt64) -> Bool {
        guard let lastFrameNs, nowNs >= readySinceNs + workingAfterNs else { return false }
        return pictureIsFresh(lastFrameNs: lastFrameNs, readySinceNs: readySinceNs, nowNs: nowNs)
    }

    static func phase(_ i: PreviewInputs) -> PreviewPhase {
        guard i.showing else { return .off }
        if let blocked = i.blocked { return .blocked(blocked) }
        if i.hold == .disconnected || !i.hasCamera || !i.connected { return .waitingForCamera }
        if case let .reopening(reason) = i.hold { return .reopening(reason) }
        switch i.camera {
        case nil: return i.retryReason.map { .reopening($0) } ?? .opening
        case .opening?: return .opening
        case let .failed(message)?: return .failed(message)
        case .ready?:
            guard i.pictureFresh else { return .noPicture }
            return i.emptyFrames ? .emptyFrames : .live
        }
    }

    /// What the camera window shows while a recording starts, runs or saves. While idle it shows
    /// `phase(_:)`, like the menu.
    /// - Parameters:
    ///   - recordsCamera: the mode records the camera.
    ///   - previewKept: `CameraRecorder.previewDuringRecording`: nil until the file starts.
    ///   - sinceNs: when Start was pressed (the first-frame grace counts from there).
    ///   - emptyFrames: the frames that come hold no picture.
    ///   - livePictureOn: Live picture while recording is on. Then a take without the preview
    ///     output lost it because the camera window was off at Start, and the window says so.
    static func recordingPhase(stage: RecordingStage, recordsCamera: Bool, previewKept: Bool?, lastFrameNs: UInt64?,
                               sinceNs: UInt64, nowNs: UInt64, emptyFrames: Bool = false,
                               livePictureOn: Bool = false) -> PreviewPhase {
        guard recordsCamera else { return .blocked(screenModeMessage) }
        let fresh = pictureIsFresh(lastFrameNs: lastFrameNs, readySinceNs: sinceNs, nowNs: nowNs)
        let hasFrame = lastFrameNs.map { $0 >= sinceNs } ?? false
        let picture: PreviewPhase = emptyFrames ? .emptyFrames : .live
        switch (stage, previewKept) {
        case (_, false?): return livePictureOn ? .pausedWindowOffAtStart : .paused
        // Saving, or not started yet: frames still come from the camera that is open, if any.
        case (.stopping, _), (.starting, _), (.recording, nil): return fresh && hasFrame ? picture : .opening
        case (.recording, true?): return fresh ? picture : .noPicture
        }
    }

    /// True when the take's camera stays open as the preview camera after the take, instead of
    /// closing and opening again: a preview wants it, it went back to its preview graph (no audio
    /// input, no movie output) and its session runs, it reported no trouble during the take, the
    /// settings still pick its config, no other preview camera is open, and the app may wait for it
    /// (false after a start that hung).
    static func keepsTakeCamera(previewWanted: Bool, previewReady: Bool, broken: Bool, sameConfig: Bool,
                                otherPreviewOpen: Bool, mayWait: Bool) -> Bool {
        previewWanted && previewReady && !broken && sameConfig && !otherPreviewOpen && mayWait
    }

    /// True when a camera open for `a` serves `b`: the same devices and the same size and rate
    /// rules. The codec and the bitrate do not count: only the writer uses them, from Start on.
    static func sameCamera(_ a: CameraRecorderConfig, _ b: CameraRecorderConfig?) -> Bool {
        guard let b else { return false }
        return a.videoDeviceUID == b.videoDeviceUID && a.audioDeviceUID == b.audioDeviceUID
            && a.width == b.width && a.height == b.height && a.frameRate == b.frameRate
    }

    /// True when Start may record with the preview camera it claimed: the camera still sends what
    /// it opened with. The device list read at Start lists the formats the camera opened with
    /// (`targetSignal`, a signature that changes with the HDMI signal), and the open camera's own
    /// signal has the size and rate the plan expects from that list. Else the signal changed in the
    /// moment before Start (the a6600 switched 30p to 24p) and the camera opens again for the take.
    static func claimStillMatches(targetSignal: String, inventorySignal: String?, cameraSignal: CameraSignal?,
                                  planSignal: CameraSignal?) -> Bool {
        guard inventorySignal == targetSignal, let cameraSignal, let planSignal else { return false }
        return cameraSignal.width == planSignal.width && cameraSignal.height == planSignal.height
            && cameraSignal.frameRate == planSignal.frameRate
    }

    /// The note when the camera window hotkey or switch is used while a take hides the window.
    static let windowHiddenWhileRecordingNotice =
        "The camera window stays hidden while recording, because Keep the camera window on while recording is off."

    /// True while a take hides the camera window whatever its switch says: a recording starts,
    /// runs or saves, and Keep the camera window on while recording is off.
    static func windowHiddenByTake(idle: Bool, keepWhileRecording: Bool) -> Bool {
        !idle && !keepWhileRecording
    }

    /// The `recordsCamera` input of `recordingPhase` in a mode that records the camera: a take
    /// without a camera recorder records none. The recorder is not made yet while starting, and is
    /// released before the take is done while stopping (Stop clears it before its teardown), so
    /// only the recording stage tells.
    static func takeRecordsCamera(stage: RecordingStage, hasRecorder: Bool) -> Bool {
        hasRecorder || stage != .recording
    }

    /// True while frames keep coming: the last one is at most `staleAfterNs` old, or none has come
    /// yet and the camera opened less than `firstFrameGraceNs` ago.
    static func pictureIsFresh(lastFrameNs: UInt64?, readySinceNs: UInt64, nowNs: UInt64,
                               staleAfterNs: UInt64 = staleAfterNs, firstFrameGraceNs: UInt64 = firstFrameGraceNs) -> Bool {
        func age(_ t: UInt64) -> UInt64 { nowNs > t ? nowNs - t : 0 }
        if let lastFrameNs { return age(lastFrameNs) <= staleAfterNs }
        return age(readySinceNs) <= firstFrameGraceNs
    }

    /// The camera's read-only Signal line: what camera.mov records (it follows the camera).
    /// - Parameters:
    ///   - cameraUID: the camera the settings pick, or nil.
    ///   - device: that camera in the device list, or nil when it is not connected.
    ///   - signal: what it sends (the open recorder's signal, else the device list's).
    static func signalLine(cameraUID: String?, device: CaptureDeviceInfo?, signal: CameraSignal?) -> CameraSignalLine {
        guard cameraUID != nil else { return CameraSignalLine(text: "No camera") }
        guard let device else { return CameraSignalLine(text: "Not connected") }
        guard let signal else {
            return CameraSignalLine(text: "No signal", fix: "Check that the camera is on and its HDMI cable is in.",
                                    isWarning: true)
        }
        let text = "\(signal.sizeName) · \(signal.width)×\(signal.height) · \(signal.frameRate.label) fps"
        // A webcam's size is its own; only a capture card's size is set on the camera.
        guard !signal.is4K, device.isCaptureCard else { return CameraSignalLine(text: text) }
        // The a6600 sends 4K at 24p or 30p; anything faster comes back to 24p (23.976).
        let rate = signal.frameRate.framesPerSecond <= 30.5 ? signal.sonyRateName : "24p"
        return CameraSignalLine(text: text, fix: "Camera sends \(signal.sizeName). Set the a6600 HDMI output to 4K \(rate).",
                                isWarning: true)
    }
}

/// The menu's Signal line, e.g. "4K · 3840×2160 · 23.976 fps".
struct CameraSignalLine: Equatable, Sendable {
    var text: String
    /// One short fix for the user, shown under the line.
    var fix: String? = nil
    /// Shown in warning style: the take records less than 4K, or no picture.
    var isWarning = false
}

/// Collapses a burst of device notifications into one refresh. A capture card can disconnect and
/// reconnect several times in a second when its HDMI signal changes. The refresh fires `quietNs`
/// after the last event, and never later than `maxWaitNs` after the first event of the burst.
struct BurstDebouncer: Equatable {
    var quietNs: UInt64
    var maxWaitNs: UInt64
    private(set) var firstNs: UInt64?
    private(set) var lastNs: UInt64?

    init(quietNs: UInt64 = 600_000_000, maxWaitNs: UInt64 = 2_500_000_000) {
        self.quietNs = quietNs
        self.maxWaitNs = maxWaitNs
    }

    /// When the current burst is due, or nil when no event is waiting.
    var deadlineNs: UInt64? {
        guard let firstNs, let lastNs else { return nil }
        return min(lastNs + quietNs, firstNs + maxWaitNs)
    }

    /// Records an event and returns when the burst is due.
    @discardableResult
    mutating func note(atNs now: UInt64) -> UInt64 {
        if firstNs == nil { firstNs = now }
        lastNs = max(lastNs ?? now, now)
        return deadlineNs ?? now
    }

    /// True once when the burst is due; the debouncer then waits for the next burst.
    mutating func fire(atNs now: UInt64) -> Bool {
        guard let deadline = deadlineNs, now >= deadline else { return false }
        firstNs = nil
        lastNs = nil
        return true
    }
}
