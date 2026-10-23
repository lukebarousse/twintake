import AppKit
import CameraCapture
import Observation
import OSLog
import RecorderCore
import Replay
import ScreenCapture
import WindowTools

/// One status line per file, e.g. "Camera 3840×2160 23.976 · recording".
struct TrackStatusLine: Identifiable, Equatable {
    var id: String
    var title: String
    var format: String
    var status: String
    var isProblem = false

    var text: String { "\(title) \(format) · \(status)" }
}

/// The session the user recorded last, for the "Saved" line.
struct LastSession: Equatable {
    var folder: URL
    var status: SessionManifest.Status
    var durationS: Double?
    var errors: [String]
    /// Which mic the camera recorded with (camera.mov's mic track `mic_source`).
    var micSource: MicSourceReport? = nil
}

/// Where the screen half of a session records.
struct ScreenPlan {
    var display: DisplayInfo
    var preset: ScreenFramePreset
    var config: ScreenRecorderConfig
    /// The frame in global CG points: the overlay and the window snap use it.
    var frameGlobal: CGRect
    /// Where the fixed frame sits on the display (the whole-display preset ignores it).
    var anchor: FrameAnchor = .top

    /// Where the window snap puts the window: the frame, but below the menu bar, because macOS
    /// keeps windows out of the menu bar (this matters only for the whole-display preset).
    var snapTarget: CGRect {
        let bar = display.menuBarRectGlobal
        guard bar.height > 0, frameGlobal.minY < bar.maxY else { return frameGlobal }
        return CGRect(x: frameGlobal.minX, y: bar.maxY, width: frameGlobal.width,
                      height: max(0, frameGlobal.maxY - bar.maxY))
    }
}

/// The recorder configs for the current settings, plus problems found while resolving them.
struct SessionPlan {
    var mode: RecordingMode
    /// Follows the camera's signal: no size or rate.
    var camera: CameraRecorderConfig?
    /// What the camera sends now, when known: camera.mov records this.
    var cameraSignal: CameraSignal?
    var screen: ScreenPlan?
    var issues: [PreflightIssue]
}

/// The automatic device picks for the current devices and settings.
struct AutomaticPicks: Equatable {
    var camera: String?
    var cameraAudio: String?
    var screenMic: String?
}

/// The files, manifest and log of the session being recorded.
@MainActor
private final class ActiveSession {
    let folder: SessionFolder
    var manifest: SessionManifest
    let events: EventLog
    let screenPlan: ScreenPlan?
    /// About how fast both files fill the disk, for the free-space checks while recording.
    let bytesPerSecond: Double
    var snap: SnapResult?
    var diskWarned = false

    init(folder: SessionFolder, manifest: SessionManifest, events: EventLog, screenPlan: ScreenPlan?, bytesPerSecond: Double) {
        self.folder = folder; self.manifest = manifest; self.events = events; self.screenPlan = screenPlan
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Why a preview camera did not open, and whether opening it again can help.
private struct OpenFailure: Sendable {
    var message: String
    /// False when the camera offers no matching format: only a new format list can fix that.
    var retryable: Bool
}

/// The camera opened for the menu's live preview. Start reuses it when its config matches.
@MainActor
private final class WarmCamera {
    /// Tells this camera's events apart from those of a camera that was closed or claimed.
    let id: UUID
    let recorder: CameraRecorder
    let target: PreviewTarget
    /// Prepares the recorder; nil result: ready.
    let prepared: Task<OpenFailure?, Never>
    var state = PreviewCameraState.opening
    var readyAtNs: UInt64?
    /// The open failed for a reason that can pass, so the preview tries again later.
    var retryable = false
    /// The camera reported a disconnect, error, stop or signal change after it opened.
    var broken = false
    var loggedFrames = false
    /// The camera mic meter this camera was last asked for (at its open, or `setIdleMeters`), and when.
    var meterRequest: (on: Bool, atNs: UInt64)?

    init(id: UUID, recorder: CameraRecorder, target: PreviewTarget, prepared: Task<OpenFailure?, Never>) {
        self.id = id; self.recorder = recorder; self.target = target; self.prepared = prepared
    }
}

/// Resumes a continuation once, with whichever value arrives first.
private final class FirstValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}

/// Runs a recording session: preflight, the session folder, the window snap and overlay, both
/// recorders, markers and the final session.json.
///
/// States: idle -> preparing -> recording -> stopping -> idle. A failed start or a manifest that
/// cannot be written ends in `error` (Start works again from there).
///
/// Camera thread rule (CameraCapture/CaptureThreads.swift): this main-actor class never touches a
/// capture session, connection or device. It reads devices through `CaptureDevices.loadInventory()`,
/// calls recorder methods that await the camera queue, and gets camera events with `async`.
@MainActor
@Observable
final class SessionCoordinator {
    enum State: Equatable {
        case idle, preparing, recording, stopping
        case error(String)

        var canStart: Bool {
            switch self {
            case .idle, .error: true
            default: false
            }
        }

        var isRecording: Bool { self == .recording }
    }

    /// Black overlay opacity outside the frame when dimming is on.
    static let dimOpacity = 0.55
    /// Longest wait for both recorders to prepare before the start is given up.
    static let prepareTimeout: Duration = .seconds(20)
    /// Longest wait for a recorder to start its file. The camera's own start limit is 6 s.
    nonisolated static let startTimeout: Duration = .seconds(15)
    /// Longest wait for a recorder to stop and report. The camera's own stop limit is 15 s.
    nonisolated static let stopTimeout: Duration = .seconds(30)
    /// Longest wait for a recorder or the preview camera to release its devices.
    nonisolated static let teardownTimeout: Duration = .seconds(15)
    /// Longest wait for the camera's preflight (device reads on its camera queue, normally a few
    /// ms; a graph change ahead of them takes up to about a second). A camera queue that hangs (the
    /// camera stuck in startRunning) blocks Start instead of freezing preflight.
    nonisolated static let cameraPreflightTimeout: Duration = .seconds(5)
    /// Start and the preview's close wait this long for a camera reconnect that runs.
    static let reconnectWait: Duration = .seconds(3)
    /// A preview pass waits this long, at most, for the camera mic meter to join or leave.
    static let meterChangeTimeout: Duration = .seconds(5)
    /// Free space is checked this often while recording (seconds).
    static let diskCheckEverySeconds = 3
    /// Console: subsystem com.lukebarousse.twintake, category session.
    nonisolated static let log = Logger(subsystem: "com.lukebarousse.twintake", category: "session")

    let settings: RecorderSettings
    let permissions: PermissionCenter

    private(set) var state: State = .idle {
        didSet { if state != oldValue { stateChanged() } }
    }
    private(set) var videoDevices: [CaptureDeviceInfo] = []
    private(set) var audioDevices: [CaptureDeviceInfo] = []
    private(set) var displays: [DisplayInfo] = []
    private(set) var automatic = AutomaticPicks()
    private(set) var issues: [PreflightIssue] = []
    private(set) var trackLines: [TrackStatusLine] = []
    private(set) var startedAt: Date?
    private(set) var now = Date()
    /// Marker kinds ("flag") added during the current recording.
    private(set) var markers: [String] = []
    /// A short line on the control bar for a moment: a flag, a pinned app, an app that does not
    /// come forward. Cleared after `ControlBarFlash.lifetime`.
    private(set) var controlBarFlash: ControlBarFlash?
    /// One line of feedback: a snap result, a marker, a window that moved.
    private(set) var notice: String? {
        didSet { if notice != oldValue { snapFix = nil } }
    }
    /// A fix the menu offers next to the notice: after a snap that found no room for the app's
    /// toolbar above the frame (Parallels Desktop), move the frame to the bottom. Idle only.
    private(set) var snapFix: SessionRules.SnapFix?
    /// The Snap button: the window a snap would move now, e.g. "Snap: Windows 11 (Parallels)".
    /// `refreshSnapTarget()` updates it when the menu opens and while it is open.
    private(set) var snapButtonTitle = "Snap Front Window"
    private(set) var snapButtonHelp = "Moves the front window into the frame (\(HotKey.snapWindow.displayString))."
    private(set) var lastSession: LastSession?
    /// Hotkeys that could not be registered, with the reason.
    private(set) var hotKeyErrors: [HotKeyAction: String] = [:]
    /// The cameras and audio inputs, with their formats, from the last device refresh.
    private(set) var inventory = DeviceInventory()
    /// Frames for the menu's preview view. The view holds only this feed, no capture object.
    let previewFeed = CameraPreviewFeed()
    /// What the preview box shows.
    private(set) var preview = PreviewPhase.off
    /// What the camera window shows: like `preview` while idle, the recording camera's picture
    /// while recording.
    private(set) var cameraWindowPhase = PreviewPhase.off
    /// The overlay is shown while idle, so the user can see the frame before recording.
    private(set) var frameShownWhileIdle = false

    /// The meters and the camera mic detector of every take, mic check and idle meter. The
    /// recorders, the mic check and the idle meters publish into it on their queues; the UI only
    /// reads `snapshot()` (one lock).
    let levels: AudioLevelMonitor
    /// The meters, polled about 20 times a second while they run (a take records, a mic check
    /// runs, or the idle meters run) and the menu or the camera window shows them
    /// (`updateMeterTicker`). Nil otherwise.
    private(set) var meters: AudioLevelsSnapshot?
    /// The sources of the take or the mic check, in meter order.
    private(set) var activeMeterSources: [AudioSource] = []
    /// The idle meters that run now (decision 1): the camera mic meter of the preview graph and
    /// the idle Mac mic. Computer sound has none (it needs the screen stream).
    private(set) var idleMeterSources: [AudioSource] = []
    /// The mic check that runs now.
    private(set) var micCheck: MicCheckProgress?
    /// The last plain mic check's result, until the next check, Dismiss, Start or
    /// `micCheckOutcomeLifetime`: an old "Rode detected" must not vouch for a mic unplugged since.
    private(set) var micCheckOutcome: MicCheckOutcome?
    /// A short result line for the camera window, for a few seconds after a check.
    private(set) var micCheckWindowNote: MicText?
    /// "Calibrate mic warning…" while it is open.
    private(set) var calibrationFlow: MicCalibrationFlow?
    /// The camera mic warning, while a take records or a plain mic check runs.
    private(set) var micAlert: MicAlert?
    /// The camera's USB link and picture trouble, from the open camera or the device list.
    private(set) var cameraHealth = CameraHealth()
    /// Reconnect camera runs.
    private(set) var cameraReconnecting = false

    @ObservationIgnored private var camera: CameraRecorder?
    @ObservationIgnored private var screen: ScreenRecorder?
    @ObservationIgnored private var active: ActiveSession?
    /// Device problems seen from the device lists ("camera disconnected"), by status line id.
    @ObservationIgnored private var lineProblems: [String: String] = [:]
    /// What each recorder last reported through `recordingProblem`, by status line id.
    @ObservationIgnored private var recorderProblems: [String: String] = [:]
    /// Start/Stop was pressed while preparing: stop the start as soon as it can be stopped.
    @ObservationIgnored private var cancelRequested = false
    /// A Start press runs preflight once more before anything changes (the issues list showed a blocker).
    @ObservationIgnored private var startCheckRunning = false
    /// The recording display went away during the take: the frame overlay is hidden until it comes back.
    @ObservationIgnored private var overlayAwaitsDisplay = false
    /// Keeps the display awake and the app out of App Nap while recording.
    @ObservationIgnored private var recordingActivity: NSObjectProtocol?
    /// A camera opened for the preview.
    @ObservationIgnored private var warm: WarmCamera?
    /// The id that the take's camera reports its events with (the claimed preview camera's, or a
    /// new one), from Start until the take has ended.
    @ObservationIgnored private var takeCameraID: UUID?
    /// The take's camera reported a disconnect, error, stop or signal change: after the take it
    /// closes instead of staying open for the preview.
    @ObservationIgnored private var takeCameraBroken = false
    /// The preview camera that is closing, until its session has stopped. Start and Quit wait for it.
    @ObservationIgnored private var warmClosing: Task<Void, Never>?
    /// Trouble with the preview target: how often in a row, and when it may open again.
    @ObservationIgnored private var previewRetry: PreviewRetry?
    /// Why the preview stays closed until a device list newer than `generation` arrives.
    @ObservationIgnored private var previewHold: (reason: PreviewHold, generation: Int)?
    /// The permission message from the last preview pass.
    @ObservationIgnored private var previewBlocked: String?
    @ObservationIgnored private var previewPassRunning = false
    @ObservationIgnored private var previewPassAgain = false
    @ObservationIgnored private var previewTicker: Task<Void, Never>?
    /// Device refreshes started and applied; a list is applied only when it is newer.
    @ObservationIgnored private var deviceGeneration = 0
    @ObservationIgnored private var appliedDeviceGeneration = 0
    @ObservationIgnored private var deviceDebounce = BurstDebouncer()
    @ObservationIgnored private var deviceDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var preflightRunning = false
    @ObservationIgnored private var preflightAgain = false
    @ObservationIgnored private var menuVisible = false
    /// The app is quitting: the preview must not open again.
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var menuTicker: Task<Void, Never>?
    @ObservationIgnored private var clockTicker: Task<Void, Never>?
    @ObservationIgnored private var preflightGeneration = 0
    @ObservationIgnored private let snapper = WindowSnapper()
    @ObservationIgnored private let overlay = FrameOverlay()
    @ObservationIgnored private let hotKeys = GlobalHotKeys()
    @ObservationIgnored private var monitor: SnappedWindowMonitor?
    @ObservationIgnored private var deviceObserver: DeviceChangeObserver?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    /// The floating camera window. Made at launch.
    @ObservationIgnored private var cameraWindow: CameraWindowController?
    /// The floating control bar (Record / Stop, the pinned apps, Flag, the Mac mic meter). Made at launch.
    @ObservationIgnored private var controlBar: ControlBarController?
    @ObservationIgnored private var controlBarFlashTask: Task<Void, Never>?
    /// The replay window (what was just recorded, while the take goes on). Made at launch.
    @ObservationIgnored private var replay: ReplayController?
    /// The on-screen keystrokes (the key monitor and the pill). Made at launch, so no key monitor
    /// runs in tests or the docs screenshots.
    @ObservationIgnored private var keystrokes: KeystrokeController?
    /// The take's screen filter holds the keystroke pill's window (from Start until the take is
    /// saved), so the window stays on screen for the whole take (`KeystrokeRules.hudOrderedIn`).
    @ObservationIgnored private var takeHasPillWindow = false
    /// Why keystrokes are hidden while another app keeps secure keyboard entry on, for the menu.
    private(set) var keystrokeSecureInputNote: String?
    /// The event tap got a key press, so the keystrokes come from it and shortcuts other apps own
    /// show too.
    private(set) var keystrokeTapProven = false
    /// Listening is allowed but the tap does not work yet (it can need a relaunch), for the menu.
    private(set) var keystrokeTapNote: String?
    /// The replay window shows: the Replay buttons light up.
    private(set) var replayShown = false
    /// Runs preflight every `controlBarPreflightInterval` while the bar shows, TwinTake is idle
    /// and the menu is closed (the menu runs its own 2 s refresh), so the bar's orange "Not
    /// ready" Record button follows a permission, the disk or a device without the menu.
    @ObservationIgnored private var controlBarPreflightTicker: Task<Void, Never>?
    /// The newest pinned-app click: an older one that still waits for its app stops there.
    @ObservationIgnored private var pinnedSwitchID: UUID?
    /// Host time when Start was pressed: the camera window's first-frame grace counts from here.
    @ObservationIgnored private var startPressedNs: UInt64 = 0
    /// Device-rematch notes already shown ("role|uid"), so one missing device is reported once.
    @ObservationIgnored private var rematchNotesShown: Set<String> = []
    /// When the camera and the idle mics may be open (decision 2), with the 1.5 s debounce.
    @ObservationIgnored private var idleDemand = IdleCaptureDemand()
    /// The end of the debounce the next pass runs at; nil when none is pending.
    @ObservationIgnored private var idleRecheckAtNs: UInt64?
    /// The idle Mac mic meter (the screen mic), open next to the metered preview.
    @ObservationIgnored private var macMic: MacMicMeter?
    /// The last Mac mic pass; each pass waits for the one before (`syncMacMic`).
    @ObservationIgnored private var macMicTask: Task<Void, Never>?
    @ObservationIgnored private var macMicPending = false
    /// The last Mac mic that did not open, and when: it is tried again after `retryAfterNs`.
    @ObservationIgnored private var macMicFailure: (uid: String, atNs: UInt64)?
    /// The sources the running mic check opens in its own sessions: the idle path leaves those
    /// devices closed until it ends, so no device is held twice.
    @ObservationIgnored private var checkOwnSources: Set<AudioSource> = []
    /// The running mic check samples the idle meters: they stay open until it ends.
    @ObservationIgnored private var checkUsesIdleMeters = false
    /// While a take prepares, records or saves: its plan records the Mac mic in screen.mov, so the
    /// idle Mac mic meter lets the mic go. False (Camera mode): the idle Mac mic meter stays open
    /// as the detector's reference. Nil while idle.
    @ObservationIgnored private var takeRecordsScreenMic: Bool?
    /// What the screen can show (decision 2): a camera window on a sleeping or locked screen, or
    /// in a user session that is switched away, shows nothing.
    @ObservationIgnored private var displaysAsleep = false
    @ObservationIgnored private var systemSleeping = false
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var sessionActive = true
    @ObservationIgnored private var presenceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var runningCheck: MicCheck?
    /// Tells the running mic check apart from a later one.
    @ObservationIgnored private var micCheckID: UUID?
    @ObservationIgnored private var micCheckTask: Task<Void, Never>?
    /// The running `MicCheck.run`, in its own task so a cancel always reaches it.
    @ObservationIgnored private var micCheckRun: Task<MicCheck.Result, Never>?
    @ObservationIgnored private var micCheckNoteTask: Task<Void, Never>?
    @ObservationIgnored private var micCheckOutcomeTask: Task<Void, Never>?
    @ObservationIgnored private var meterTicker: Task<Void, Never>?
    /// One beep when a camera mic warning comes on during a take.
    @ObservationIgnored private var micAlertOnset = AlertOnset()

    init(settings: RecorderSettings = RecorderSettings(), permissions: PermissionCenter = PermissionCenter()) {
        self.settings = settings
        self.permissions = permissions
        levels = AudioLevelMonitor(calibration: settings.micCalibration)
    }

    /// Elapsed recording time, e.g. "12:34": the take time on the host clock, like a flag's
    /// `elapsed_s` (it does not count a system sleep). `now` ticks the views once a second.
    var elapsedText: String {
        guard let startedAt else { return SessionRules.elapsedString(0) }
        let wall = now.timeIntervalSince(startedAt)
        return SessionRules.elapsedString(takeElapsedS.map { max(0, $0) } ?? wall)
    }

    var hasBlockers: Bool { !SessionRules.blockers(issues).isEmpty }

    private var ownBundleID: String? { Bundle.main.bundleIdentifier ?? SessionRules.appBundleID }

    // MARK: - Launch and shutdown

    /// Registers the hotkeys, lists devices and marks an interrupted session as recovered.
    func launch() {
        // Taken before the hotkeys exist, so a session started now is never taken for the crashed one.
        // Checked off the main thread: the folder may be on a slow or missing volume.
        if let pending = SessionRecovery.takeInProgress() {
            Task.detached { [weak self] in
                guard SessionRecovery.recoverIfInterrupted(pending) else { return }
                await self?.recoveredAtLaunch(pending)
            }
        }
        registerHotKeys()
        refreshDisplays()
        cameraWindow = CameraWindowController(coordinator: self)
        syncCameraWindow()
        controlBar = ControlBarController(coordinator: self)
        syncControlBar()
        replay = ReplayController(coordinator: self)
        keystrokes = KeystrokeController(coordinator: self)
        updateKeystrokes()
        Task {
            await refreshDevices()
            await updatePreview()
        }
        // Connects, disconnects and format-list changes, from any thread. They come in bursts.
        deviceObserver = CaptureDevices.observeChanges { [weak self] in
            Task { @MainActor in self?.deviceEventArrived() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        observeScreenPresence()
    }

    /// Display sleep, system sleep, the screen lock and fast user switching: while one of them
    /// holds, no view shows the camera, so the camera and the idle mics close (decision 2), and
    /// they open again when the screen can show the camera again.
    private func observeScreenPresence() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let watches: [(NotificationCenter, Notification.Name, @MainActor @Sendable (SessionCoordinator) -> Void)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, { $0.displaysAsleep = true }),
            (workspace, NSWorkspace.screensDidWakeNotification, { $0.displaysAsleep = false }),
            (workspace, NSWorkspace.willSleepNotification, { $0.systemSleeping = true; $0.systemWillSleep() }),
            (workspace, NSWorkspace.didWakeNotification, { $0.systemSleeping = false }),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true }),
            (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.screenLocked = true }),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.screenLocked = false }),
        ]
        presenceObservers = watches.map { center, name, apply in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let before = self.screenCanShowCamera
                    apply(self)
                    if self.screenCanShowCamera != before { self.screenPresenceChanged() }
                }
            }
        }
    }

    /// A view on screen can show the camera now (`IdleCaptureRules.screenCanShowCamera`).
    private var screenCanShowCamera: Bool {
        IdleCaptureRules.screenCanShowCamera(displaysAsleep: displaysAsleep, systemSleeping: systemSleeping,
                                             screenLocked: screenLocked, sessionActive: sessionActive)
    }

    /// The screen went dark or locked: the camera and the idle mics close now, without the
    /// debounce (nothing comes back within 1.5 s). It can show the camera again: they open again,
    /// at once, like a menu that opens.
    private func screenPresenceChanged() {
        let seen = screenCanShowCamera
        Self.log.notice("The screen \(seen ? "can show the camera again" : "cannot show the camera (asleep, locked or switched away)", privacy: .public)")
        if seen { previewRetry = nil } else { idleDemand.closeNow() }
        refreshPreviewPhase()
        syncMacMic()
        Task {
            await updatePreview()
            // Permissions, disks and displays may have changed while the screen was dark: the
            // control bar's Record button shows the blocker at once.
            if seen { await refreshPreflight() }
        }
    }

    /// The Mac goes to sleep (the lid closed on battery): a take stops now, so both files and
    /// session.json finish, instead of running on capture streams the sleep may break. A start
    /// that runs is cancelled, like a second Start/Stop press.
    private func systemWillSleep() {
        switch state {
        case .preparing:
            cancelRequested = true
        case .recording:
            let message = "The Mac went to sleep, so the take stopped."
            active?.events.append(.warning, ["source": "app", "message": message])
            notice = message
            Self.log.notice("System sleep: stopping the take")
            requestStop()
        default:
            break
        }
    }

    private func recoveredAtLaunch(_ folder: URL) {
        Self.log.notice("Marked \(folder.lastPathComponent, privacy: .public) as recovered")
        notice = "Marked 1 interrupted session as recovered: \(folder.lastPathComponent)."
    }

    /// True when quitting must wait: a recording to finish, or a camera to close.
    var needsCleanShutdown: Bool {
        !state.canStart || warm != nil || warmClosing != nil || micCheckTask != nil || macMic != nil
    }

    /// Finishes a recording in progress (session.json and all), then releases everything.
    func shutDown() async {
        shuttingDown = true
        // First, so the stop below does not open the saved take in the replay.
        replay?.closeForGood()
        idleDemand.closeNow()
        await endMicCheck()
        // Quit while starting is a second Start/Stop press: the start ends as soon as it can (a
        // take whose files began is saved as a short take), and Quit never waits for a whole take.
        if state == .preparing { cancelRequested = true }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while state == .preparing, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if state == .recording { await runStop() }
        while state == .stopping, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        menuTicker?.cancel()
        controlBarPreflightTicker?.cancel()
        controlBarPreflightTicker = nil
        previewTicker?.cancel()
        previewTicker = nil
        meterTicker?.cancel()
        meterTicker = nil
        deviceDebounceTask?.cancel()
        cameraWindow?.close()
        controlBar?.close()
        keystrokes?.close()
        await closeWarmCamera()
        await closeIdleMacMic()
        hotKeys.unregisterAll()
        overlay.hide()
        deviceObserver?.cancel()
    }

    // MARK: - Menu

    /// Called when the menu window opens or closes. While it is open, devices, permissions and
    /// preflight refresh every 2 s, the preview camera and the idle meters run if Live preview is
    /// on, and the preview checks twice a second that frames still come. When it closes and
    /// nothing else shows the camera, the camera and the idle mics close 1.5 s later
    /// (`IdleCaptureDemand`).
    func setMenuVisible(_ visible: Bool) {
        guard visible != menuVisible else { return }
        menuVisible = visible
        menuTicker?.cancel()
        menuTicker = nil
        if visible {
            // Opening the menu tries the camera again at once.
            previewRetry = nil
            menuTicker = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshAll()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        updatePreviewTicker()
        updateMeterTicker()
        refreshPreviewPhase()
        if visible { refreshSnapTarget() }
        // Not only at the end of a preview pass: a camera that hangs while it opens must not keep the Mac mic.
        syncMacMic()
        Task { await updatePreview() }
    }

    /// Checks twice a second that preview frames still come, while the menu or the camera window
    /// shows them. With only the camera window open, it also runs the preview pass every 2 s (the
    /// menu's own 2 s refresh does that while it is open), so a camera that sends no picture opens
    /// again, but at most `PreviewRules.windowOnlyMaxAttempts` times in a row.
    private func updatePreviewTicker() {
        let wanted = menuVisible || cameraWindowWanted
        guard wanted != (previewTicker != nil) else { return }
        previewTicker?.cancel()
        previewTicker = nil
        guard wanted else { return }
        previewTicker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.refreshPreviewPhase()
                tick += 1
                if tick % 4 == 0, let self, !self.menuVisible, self.cameraWindowWanted { await self.updatePreview() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func settingsChanged() {
        // A frame or snap setting changed: the offered snap fix may no longer fit.
        snapFix = nil
        refreshSnapTarget()
        rememberDevicePicks()
        refreshAutomaticPicks()
        if state.canStart, frameShownWhileIdle { showIdleFrame() }
        updateKeystrokes()
        refreshPreviewPhase()
        Task {
            await updatePreview()
            await refreshPreflight()
        }
    }

    func dismissError() {
        if case .error = state { state = .idle }
    }

    func clearNotice() { notice = nil }

    /// The snap fix button: puts the frame at the bottom of its display (with the 16:9 frame when
    /// the whole display left no room), then snaps the front window again.
    func applySnapFix() {
        guard state.canStart, let fix = snapFix, let display = resolvedDisplay()?.display else { return }
        snapFix = nil
        if fix == .useSixteenByNineAtBottom { settings.framePresetID = ScreenFramePreset.laptop16x9.id }
        settings.setFrameAnchor(.bottom, for: display)
        settingsChanged()
        snapNow()
    }

    private func refreshAll() async {
        refreshSnapTarget()
        await refreshDevices()
        permissions.refresh()
        await updatePreview()
        // Not awaited: a busy camera queue must not hold up the device refresh.
        Task { await refreshPreflight() }
    }

    // MARK: - Devices

    /// Reads the device lists on the device queue and applies them here. A list that arrives
    /// after a newer one is dropped.
    func refreshDevices() async {
        deviceGeneration += 1
        let generation = deviceGeneration
        let found = await CaptureDevices.loadInventory()
        guard generation > appliedDeviceGeneration else { return }
        appliedDeviceGeneration = generation
        if found != inventory { inventory = found }
        if found.videoDevices != videoDevices { videoDevices = found.videoDevices }
        if found.audioDevices != audioDevices { audioDevices = found.audioDevices }
        // The list was read after the camera reported its problem, so it shows where the camera is now.
        if let hold = previewHold, generation > hold.generation { previewHold = nil }
        refreshDisplays()
        if state.canStart { rematchDevices() }
        refreshAutomaticPicks()
        refreshPreviewPhase()
    }

    /// Saves the camera's rate, so the screen rate follows it while no camera signal is known
    /// (and in Screen mode). Only a take's camera, after prepare: the device list's automatic pick
    /// can be any camera (an iPhone, a webcam) or a short-lived HDMI rate.
    private func rememberCameraRate(_ signal: CameraSignal?) {
        if let rate = signal?.frameRate, rate != settings.lastCameraFrameRate { settings.lastCameraFrameRate = rate }
    }

    // MARK: - Device rematch

    /// Saves the uid, name and model of every fixed device pick that is connected now, so it can
    /// be found again when its uid changes, and the other devices with its name that are connected
    /// next to it, so a rematch never takes one of them.
    private func rememberDevicePicks() {
        for role in DeviceRematch.Role.allCases {
            let devices = role == .camera ? videoDevices : audioDevices
            if let identity = DeviceRematch.identity(of: settings.choice(role), in: devices, role: role,
                                                     previous: settings.identity(role)) {
                settings.setIdentity(identity, role)
            }
        }
    }

    /// Finds a fixed device pick again when its uid is gone but exactly one connected device has
    /// its name (and model): a capture card moved to another USB port. A device that was connected
    /// next to the saved one is never taken (`SavedDevice.others`). With several candidates it does
    /// not guess; the picker shows "Saved device (not connected)" and a note asks to pick.
    /// - Returns: the notes for the picks that changed.
    @discardableResult
    private func rematchDevices() -> [String] {
        rememberDevicePicks()
        var notes: [String] = []
        for role in DeviceRematch.Role.allCases {
            guard case let .device(uid) = settings.choice(role), let saved = settings.identity(role), saved.uid == uid else {
                continue
            }
            let devices = role == .camera ? videoDevices : audioDevices
            switch DeviceRematch.resolve(saved, in: devices, role: role) {
            case .present, .missing:
                break
            case let .moved(found):
                settings.setChoice(.device(uid: found.uid), role)
                settings.setIdentity(found, role)
                notes.append(DeviceRematch.movedNotice(found, role: role))
                Self.log.notice("Rematched \(role.rawValue, privacy: .public) \(found.name, privacy: .public): \(uid, privacy: .public) -> \(found.uid, privacy: .public)")
            case let .ambiguous(count):
                if rematchNotesShown.insert("\(role.rawValue)|\(uid)").inserted {
                    notice = DeviceRematch.ambiguousNotice(saved, count: count, role: role)
                }
            }
        }
        if !notes.isEmpty {
            notice = notes.joined(separator: " ")
            refreshAutomaticPicks()
            if state.canStart { settingsChanged() }
        }
        return notes
    }

    /// Refreshes the devices, but waits at most `timeout`: a stuck device queue must not hold
    /// Start in "Starting…". A late list is still applied when it arrives.
    private func refreshDevices(waitingAtMost timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let first = FirstValue(continuation)
            Task { @MainActor in
                await self.refreshDevices()
                first.resume(())
            }
            Task {
                try? await Task.sleep(for: timeout)
                first.resume(())
            }
        }
    }

    /// A device notification or a camera event. Waits for the burst to end, then refreshes once.
    private func deviceEventArrived() {
        scheduleDeviceRefresh(at: deviceDebounce.note(atNs: HostClock.nowNs()))
    }

    private func scheduleDeviceRefresh(at deadlineNs: UInt64) {
        deviceDebounceTask?.cancel()
        deviceDebounceTask = Task { [weak self] in
            let now = HostClock.nowNs()
            if deadlineNs > now { try? await Task.sleep(nanoseconds: deadlineNs - now) }
            guard !Task.isCancelled, let self else { return }
            if self.deviceDebounce.fire(atNs: HostClock.nowNs()) {
                await self.devicesSettled()
            } else if let next = self.deviceDebounce.deadlineNs {
                self.scheduleDeviceRefresh(at: next)
            }
        }
    }

    /// The burst of device events is over: read the devices once and follow them.
    private func devicesSettled() async {
        await refreshDevices()
        checkLiveDevices()
        await updatePreview()
        await refreshPreflight()
    }

    private func refreshDisplays() {
        let all = Displays.all()
        if all != displays { displays = all }
    }

    /// The automatic picks, from the last device list (plain data, no device reads).
    private func refreshAutomaticPicks() {
        var picks = AutomaticPicks()
        let inventory = inventory
        picks.camera = inventory.defaultCameraUID
        if let camera = settings.camera.resolve(automatic: { picks.camera }) {
            picks.cameraAudio = inventory.defaultCameraAudioUID(forCameraUID: camera)
        }
        picks.screenMic = inventory.defaultScreenMicUID
        if picks != automatic { automatic = picks }
    }

    private func screensChanged() {
        refreshDisplays()
        cameraWindow?.screensChanged()
        controlBar?.screensChanged()
        replay?.screensChanged()
        updateKeystrokes()
        if state.canStart {
            overlayAwaitsDisplay = false
            if frameShownWhileIdle { showIdleFrame() }
        } else if let plan = active?.screenPlan, overlay.isVisible || overlayAwaitsDisplay {
            if let display = displays.first(where: { $0.id == plan.display.id }) {
                // Same frame on the display, at the display's new place in the global space.
                overlayAwaitsDisplay = false
                let frame = FrameGeometry.globalRect(fromLocal: plan.config.frameRectPt, displayBoundsGlobal: display.boundsGlobal)
                overlay.show(frameGlobal: frame, display: display, dimOpacity: dimOpacity)
            } else {
                // The recording display went away (the lid closed in clamshell mode): its dim must
                // not stay at stale coordinates over another display. Back when the display is.
                overlayAwaitsDisplay = true
                overlay.hide()
            }
        }
        checkLiveDevices()
    }

    /// The display to record: the saved one, else the built-in display, else the main display.
    /// `fellBack` is true when a saved display is not connected.
    func resolvedDisplay() -> (display: DisplayInfo, fellBack: Bool)? {
        let all = displays
        let fallback = all.first(where: \.isBuiltin) ?? all.first(where: \.isMain) ?? all.first
        if let uuid = settings.displayUUID {
            if let saved = all.first(where: { $0.uuid == uuid }) { return (saved, false) }
            return fallback.map { ($0, true) }
        }
        return fallback.map { ($0, false) }
    }

    /// The automatic display (for the picker's "Automatic" entry).
    var automaticDisplay: DisplayInfo? {
        displays.first(where: \.isBuiltin) ?? displays.first(where: \.isMain) ?? displays.first
    }

    func resolvedPreset(for display: DisplayInfo) -> ScreenFramePreset {
        settings.framePresetID.flatMap { id in ScreenFramePreset.all.first { $0.id == id } } ?? display.defaultPreset
    }

    /// What the picked camera sends: the open camera's signal (exact after prepare: the take's
    /// camera, else the preview camera), else what the device list says it offers. Nil when the
    /// camera is not connected or sends nothing. camera.mov records this size and rate.
    func currentCameraSignal() -> CameraSignal? {
        guard let uid = settings.camera.resolve(automatic: { automatic.camera }) else { return nil }
        for recorder in [camera, warm?.recorder].compactMap({ $0 }) where recorder.config.videoDeviceUID == uid {
            if let signal = recorder.signal { return signal }
        }
        return inventory.signal(forVideoUID: uid)
    }

    /// The camera's read-only Signal line, e.g. "4K · 3840×2160 · 23.976 fps".
    var cameraSignalLine: CameraSignalLine {
        let uid = settings.camera.resolve(automatic: { automatic.camera })
        let device = uid.flatMap { uid in videoDevices.first { $0.uid == uid } }
        return PreviewRules.signalLine(cameraUID: uid, device: device, signal: device == nil ? nil : currentCameraSignal())
    }

    /// The camera rate the screen rate follows now, and whether it comes from a live signal.
    var screenRateSource: (cameraRate: FrameRate, live: Bool) {
        if settings.mode.includesCamera, let rate = currentCameraSignal()?.frameRate { return (rate, true) }
        return (settings.lastCameraFrameRate, false)
    }

    /// The menu's read-only screen Rate line.
    var screenRateText: String {
        let source = screenRateSource
        let screen = ScreenRecorderConfig.frameRate(forCameraRate: source.cameraRate)
        return SessionRules.screenRateText(screen: screen, cameraRate: source.cameraRate, cameraLive: source.live)
    }

    /// The frame position on the display Start would record.
    var frameAnchor: FrameAnchor {
        resolvedDisplay().map { settings.frameAnchor(for: $0.display) } ?? .top
    }

    /// The Frame position picker.
    func setFrameAnchor(_ anchor: FrameAnchor) {
        guard let display = resolvedDisplay()?.display else { return }
        settings.setFrameAnchor(anchor, for: display)
    }

    // MARK: - Plan and preflight

    /// The configs Start would use now. Automatic device picks come from the last
    /// `refreshDevices()`, so call that first when the devices may have changed.
    func makePlan() -> SessionPlan {
        var issues: [PreflightIssue] = []
        let mode = settings.mode

        var cameraConfig: CameraRecorderConfig?
        var cameraSignal: CameraSignal?
        if mode.includesCamera {
            if let uid = settings.camera.resolve(automatic: { automatic.camera }) {
                let audio = settings.cameraAudio.resolve { automatic.cameraAudio }
                // No size or rate: camera.mov follows the camera's signal.
                cameraConfig = CameraRecorderConfig(
                    videoDeviceUID: uid, audioDeviceUID: audio, codec: settings.codec,
                    bitrate: settings.cameraBitrateMbps * 1_000_000)
                cameraSignal = currentCameraSignal()
            } else {
                issues.append(PreflightIssue(id: "app.no_camera", severity: .blocker,
                                             message: "No camera is connected. Connect the capture card, or pick Screen."))
            }
        }

        var screenPlan: ScreenPlan?
        if mode.includesScreen {
            if let (display, fellBack) = resolvedDisplay() {
                if fellBack {
                    issues.append(PreflightIssue(id: "app.display_fallback", severity: .warning,
                                                 message: "The saved display is not connected, so Start records \(display.name)."))
                }
                let preset = resolvedPreset(for: display)
                let anchor = settings.frameAnchor(for: display)
                // Not a user choice: 2x the camera rate (47.952 for 23.976).
                let rate = SessionRules.screenFrameRate(cameraSignalRate: cameraSignal?.frameRate,
                                                        lastCameraRate: settings.lastCameraFrameRate)
                let config = ScreenRecorderConfig(
                    displayID: display.id, frameRectPt: display.frameRect(for: preset, anchor: anchor),
                    outputPx: display.outputPixels(for: preset), frameRate: rate,
                    micDeviceUID: settings.screenMic.resolve { automatic.screenMic },
                    captureSystemAudio: settings.systemAudio,
                    excludedBundleIDs: SessionRules.excludedBundleIDs(mainBundleID: Bundle.main.bundleIdentifier),
                    codec: settings.codec, bitrate: settings.screenBitrateMbps * 1_000_000)
                screenPlan = ScreenPlan(display: display, preset: preset, config: config,
                                        frameGlobal: display.globalFrameRect(for: preset, anchor: anchor), anchor: anchor)
            } else {
                issues.append(PreflightIssue(id: "app.no_display", severity: .blocker,
                                             message: "No display is available to record. If the laptop lid is closed, open it or pick another display."))
            }
        }
        return SessionPlan(mode: mode, camera: cameraConfig, cameraSignal: cameraSignal, screen: screenPlan, issues: issues)
    }

    /// Runs preflight. A call while one runs makes it run once more afterwards, instead of a
    /// second one in parallel.
    func refreshPreflight() async {
        if preflightRunning {
            preflightAgain = true
            return
        }
        preflightRunning = true
        defer { preflightRunning = false }
        repeat {
            preflightAgain = false
            await refreshPreflightOnce()
        } while preflightAgain
    }

    private func refreshPreflightOnce() async {
        guard state.canStart else { return }
        preflightGeneration += 1
        let generation = preflightGeneration
        let found = await collectIssues(for: makePlan(), camera: nil)
        guard generation == preflightGeneration, state.canStart, found != issues else { return }
        issues = found
    }

    /// Disk space, app-level permission checks and both recorders' own preflight.
    /// - Parameter camera: a prepared camera to ask instead of a fresh one (its format checks are exact).
    private func collectIssues(for plan: SessionPlan, camera: CameraRecorder?) async -> [PreflightIssue] {
        var found = plan.issues
        let folder = settings.outputFolder
        if let issue = SessionRules.folderIssue(for: folder) {
            // The free space of a missing disk's parent is the boot disk's: no disk line then.
            found.append(issue)
        } else {
            found += SessionRules.diskIssues(availableBytes: SessionRules.availableCapacity(for: folder),
                                             bytesPerSecond: SessionRules.bytesPerSecond(camera: plan.camera, cameraSignal: plan.cameraSignal,
                                                                                         screen: plan.screen?.config),
                                             folder: folder)
        }
        found += permissionIssues(for: plan)
        if let screen = plan.screen {
            let frameAtBottom = screen.preset.sizing != .fullDisplay && screen.anchor == .bottom
            if let issue = SessionRules.dockIssue(DockOverlap.current(frameLocal: screen.config.frameRectPt, on: screen.display),
                                                  frameAtBottom: frameAtBottom) {
                found.append(issue)
            }
            if let issue = SessionRules.hotCornerIssue(HotCorner.current(), frameLocal: screen.config.frameRectPt,
                                                       displaySizePt: screen.display.sizePt) {
                found.append(issue)
            }
        }
        if let uid = plan.screen?.config.micDeviceUID, let issue = SessionRules.closedLidMicIssue(
            mic: audioDevices.first { $0.uid == uid }, lidClosed: Displays.isLidClosed,
            audioDevices: audioDevices, cameraAudioUID: plan.camera?.audioDeviceUID) {
            found.append(issue)
        }
        if let config = plan.camera {
            // An open camera answers exactly; only a preview camera that opened and reported
            // nothing (one that is opening, failed or broke may hang on its queue) and does not
            // reconnect now. Else a fresh recorder, with its own queue.
            let open = camera.flatMap { PreviewRules.sameCamera($0.config, config) ? $0 : nil }
                ?? warm.flatMap { $0.state == .ready && !$0.broken && !$0.recorder.isReconnecting
                    && PreviewRules.sameCamera($0.recorder.config, config) ? $0.recorder : nil }
            open?.useEncoder(codec: config.codec, bitrate: config.bitrate)
            let recorder = open ?? CameraRecorder(config: config)
            if let cameraIssues = await Self.waitAtMost(Self.cameraPreflightTimeout, { await recorder.preflight() }) {
                found += cameraIssues
            } else {
                Self.log.error("Camera preflight did not answer within \(Self.cameraPreflightTimeout.components.seconds) s")
                found.append(PreflightIssue(id: Self.cameraUnresponsiveID, severity: .blocker,
                                            message: "The camera does not answer. Unplug it and plug it back in."))
            }
        }
        if let screen = plan.screen {
            found += await ScreenRecorder(config: screen.config).preflight()
        }
        if found.contains(where: { $0.id == "app.mic_permission" }) {
            found.removeAll { $0.id == "screen.mic-permission-ask" }
        }
        return SessionRules.merged(found)
    }

    /// The preflight blocker of a camera whose queue does not answer.
    static let cameraUnresponsiveID = "camera.unresponsive"

    private func permissionIssues(for plan: SessionPlan) -> [PreflightIssue] {
        permissions.refresh()
        var found: [PreflightIssue] = []
        if plan.camera != nil, permissions.state(.camera) == .notDetermined {
            found.append(PreflightIssue(id: "app.camera_permission", severity: .blocker,
                                        message: "Allow camera access first: Permissions > Camera > Allow."))
        }
        let usesMic = plan.camera?.audioDeviceUID != nil || plan.screen?.config.micDeviceUID != nil
        if usesMic, permissions.state(.microphone) == .notDetermined {
            found.append(PreflightIssue(id: "app.mic_permission", severity: .blocker,
                                        message: "Allow microphone access first: Permissions > Microphone > Allow."))
        }
        if plan.screen != nil {
            if settings.snapOnStart, permissions.state(.accessibility) != .granted {
                found.append(PreflightIssue(id: "app.accessibility", severity: .warning,
                                            message: "Accessibility is off, so Start cannot snap the front window into the frame."))
            }
            if settings.windowOnly, !settings.snapOnStart {
                found.append(PreflightIssue(id: "app.window_only_needs_snap", severity: .warning,
                                            message: "Hide other windows needs “Snap the front window into the frame on Start”. Without it, Start records the frame region."))
            }
        }
        return found
    }

    // MARK: - Start

    /// Start or Stop, for the button and the hotkey.
    func toggleRecording() {
        switch state {
        case .idle, .error: requestStart()
        case .recording: requestStop()
        case .preparing:
            cancelRequested = true
            notice = "Cancelling the start…"
        case .stopping: break
        }
    }

    func requestStart() {
        guard state.canStart, !shuttingDown, !startCheckRunning else { return }
        guard hasBlockers else {
            beginStart()
            return
        }
        // Start shows a blocker (the control bar's orange Record, or the hotkey): a press that does
        // not start changes nothing (the replay, a mic check or calibration, the camera and the mics
        // stay as they are). The blocker may have just cleared (the camera plugged back in), so
        // preflight runs once more first, bounded like every camera wait.
        startCheckRunning = true
        Task {
            await refreshDevices(waitingAtMost: .seconds(3))
            let found = await collectIssues(for: makePlan(), camera: nil)
            startCheckRunning = false
            guard state.canStart, !shuttingDown else { return }
            // Newer than a preflight pass that still runs: that one drops its result.
            preflightGeneration += 1
            if found != issues { issues = found }
            if let blocker = SessionRules.blockers(found).first { startBlocked(blocker) } else { beginStart() }
        }
    }

    private func beginStart() {
        startPressedNs = HostClock.nowNs()
        // The take's Mac mic, from the settings until the plan is made (`runStart`).
        takeRecordsScreenMic = settings.mode.includesScreen && settings.screenMic.resolve { automatic.screenMic } != nil
        state = .preparing
        cancelRequested = false
        notice = nil
        // Claim the preview camera now, before the menu closes and drops it. Its events count for
        // the take from here on (`takeCameraBroken`), so Start never records with a camera that
        // reported trouble (a signal change) while it was claimed.
        let claimed = warm
        warm = nil
        takeCameraID = claimed?.id
        takeCameraBroken = false
        previewFeed.clear()
        refreshPreviewPhase()
        Task { await runStart(claimed: claimed) }
    }

    /// Start was pressed while a blocker holds: says why (a beep and the bar's "Not ready" when
    /// the menu is closed).
    private func startBlocked(_ blocker: PreflightIssue) {
        notice = SessionRules.startBlockedNotice(blocker)
        Self.log.notice("Start blocked: \(blocker.id, privacy: .public)")
        if !menuVisible {
            NSSound.beep()
            flashControlBar("Not ready: open the menu", tone: .problem)
        }
    }

    private func runStart(claimed: WarmCamera?) async {
        // Nothing here changes a mic check, the calibration or the idle Mac mic before preflight
        // has passed: a start that is blocked or cancelled leaves them as they were.
        // A preview camera that is still closing stops before the recording opens the same device.
        await waitForWarmClose()
        await refreshDevices(waitingAtMost: .seconds(3))
        // A capture card moved to another USB port since the last refresh: record from its new uid.
        let rematched = rematchDevices()
        let plan = makePlan()
        let keepPreview = plan.camera != nil && keepsLivePictureWhileRecording
        var warmCamera: CameraRecorder?
        if let claimed, case .failed = claimed.state {
            // Its open failed or did not finish in time, and released the camera then (a hung one
            // without waiting): Start does not wait for it again. A fresh camera opens for the take.
            Self.log.notice("The preview camera had failed to open; the camera opens again for the take")
        } else if let claimed {
            // A reconnect that runs (Reconnect Camera, or the reopen for empty frames) ends first,
            // so the camera is open again or closed when Start decides. Lock-only polling.
            await claimed.recorder.waitForReconnect(atMost: Self.reconnectWait)
            // The preview camera may hang in startRunning: the prepare limit applies to it too.
            let prepared = claimed.prepared
            let outcome = await Self.waitAtMost(Self.prepareTimeout) { await prepared.value }
            // The camera must still send what it opened with: a signal that changed right before
            // Start (the device list read now says so) opens the camera again for the take, so
            // camera.mov and the screen rate follow the new signal.
            let signalHolds = plan.camera.map { config in
                PreviewRules.claimStillMatches(targetSignal: claimed.target.signal,
                                               inventorySignal: inventory.signalSignature(forVideoUID: config.videoDeviceUID),
                                               cameraSignal: claimed.recorder.signal, planSignal: plan.cameraSignal)
            } ?? false
            if case .some(nil) = outcome, !claimed.broken, !takeCameraBroken, signalHolds,
               PreviewRules.sameCamera(claimed.recorder.config, plan.camera), claimed.recorder.isOpen {
                warmCamera = claimed.recorder
            } else if outcome == nil {
                // Still not open: release it without waiting. A fresh camera gets the prepare limit below.
                let recorder = claimed.recorder
                Task.detached { await recorder.teardown() }
            } else {
                if case .some(nil) = outcome, claimed.recorder.isOpen, !signalHolds {
                    Self.log.notice("The camera signal changed right before Start; the camera opens again for the take")
                }
                await Self.teardown(claimed.recorder, waitingAtMost: Self.teardownTimeout)
            }
        }

        // 1. Preflight (its camera part is bounded).
        if cancelRequested {
            await cancelStartBeforePrepare(claimed: claimed, warmCamera: warmCamera)
            return
        }
        let found = await collectIssues(for: plan, camera: warmCamera)
        issues = found
        if cancelRequested {
            await cancelStartBeforePrepare(claimed: claimed, warmCamera: warmCamera)
            return
        }
        if let blocker = SessionRules.blockers(found).first {
            await endStartBeforePrepare(claimed: claimed, warmCamera: warmCamera,
                                        unresponsive: found.contains { $0.id == Self.cameraUnresponsiveID })
            state = .idle
            startBlocked(blocker)
            await updatePreview()
            return
        }

        // The take goes on. A mic check holds the camera audio in its own session: it ends before
        // the take opens it. The screen recorder opens the Mac mic for screen.mov: the idle Mac
        // mic meter lets it go first. A take without a screen mic (Camera mode) keeps it as the
        // detector's reference.
        await endMicCheck()
        takeRecordsScreenMic = plan.screen?.config.micDeviceUID != nil
        await settleMacMicForTake()
        calibrationFlow = nil
        micCheckOutcome = nil

        // 2. Session folder, session.json (status recording) and events.jsonl.
        let session: ActiveSession
        do {
            let folder = try SessionFolder.create(in: settings.outputFolder)
            var manifest = SessionManifest(mode: plan.mode, recorder: SessionRules.recorderInfo())
            if let s = plan.screen { manifest.screen = s.display.screenInfo(for: s.preset, anchor: s.anchor) }
            // Stop sets it from the tracks written; this is the plan, for a session that never stops.
            manifest.sync.check = SessionRules.syncCheck(cameraHasMic: plan.camera?.audioDeviceUID != nil,
                                                         screenHasMic: plan.screen?.config.micDeviceUID != nil)
            try folder.writeManifest(manifest)
            session = ActiveSession(folder: folder, manifest: manifest, events: try EventLog(url: folder.eventsURL),
                                    screenPlan: plan.screen,
                                    bytesPerSecond: SessionRules.bytesPerSecond(camera: plan.camera, cameraSignal: plan.cameraSignal,
                                                                                screen: plan.screen?.config))
        } catch {
            await endStartBeforePrepare(claimed: claimed, warmCamera: warmCamera)
            let message = "Could not create the session in \(settings.outputFolder.path): \(error.localizedDescription)"
            state = .error(message)
            Self.log.error("Start failed: \(message, privacy: .public)")
            // Like every failed start: the take did not begin, and the user must know it.
            if !menuVisible {
                NSSound.beep()
                flashControlBar("Start failed: open the menu", tone: .problem)
            }
            // Closes the idle Mac mic (Camera mode opened it for the take) when nothing shows the camera.
            await updatePreview()
            return
        }
        active = session
        SessionRecovery.markInProgress(session.folder.url)
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "Recording camera and screen")
        for issue in found where issue.severity == .warning {
            session.events.append(.warning, ["source": "preflight", "id": issue.id, "message": issue.message])
        }
        for note in rematched { session.events.append(.warning, ["source": "devices", "message": note]) }

        // 3. Window snap and frame overlay.
        var screenConfig = plan.screen?.config
        if let s = plan.screen {
            if settings.snapOnStart { snapFrontWindow(into: s, session: session) }
            if settings.windowOnly {
                if SessionRules.windowOnlyApplies(to: session.snap), let windowID = session.snap?.windowID {
                    screenConfig?.windowID = windowID
                    session.manifest.screen?.capture = "window"
                } else if session.snap?.placement == .toolbarAbove {
                    // A window capture would record the whole window, its toolbar included.
                    session.events.append(.warning, ["source": "screen", "message":
                        "Hide other windows is on, but \(session.snap?.appName ?? "the app") keeps its toolbar above the frame. "
                        + "Recording the frame region instead, so the toolbar stays out of screen.mov."])
                } else {
                    session.events.append(.warning, ["source": "screen", "message":
                        "Hide other windows is on, but no window was snapped. Recording the frame region instead."])
                }
            }
            overlay.show(frameGlobal: s.frameGlobal, display: s.display, dimOpacity: dimOpacity)
            // The keystroke pill's window over the take's frame before the screen recorder builds its
            // filter: screen.mov shows it, and every other TwinTake window stays out. Not with
            // Keystrokes Off: that take records the screen as without the feature.
            if KeystrokeRules.pillInScreenRecording(mode: settings.keystrokeMode, keystrokesInScreen: settings.keystrokesInScreen),
               let id = keystrokes?.prepareForTake(frameGlobal: s.frameGlobal) {
                takeHasPillWindow = true
                screenConfig?.shownOwnWindowIDs = [id]
            }
        }
        // The snap message replaced the rematch note: show both.
        if !rematched.isEmpty, let snapNote = notice, snapNote != rematched.joined(separator: " ") {
            notice = (rematched + [snapNote]).joined(separator: " ")
        }

        // 4. Prepare both recorders, then start both at once. A claimed preview camera turns into the
        // recording graph here: the camera audio input and the movie output join its session
        // (CameraRecorder.prepare). With the camera window on, the camera keeps its small preview
        // output while camera.mov records (see CameraRecorder).
        let freshCamera = warmCamera == nil
        let takeID = warmCamera == nil ? UUID() : (claimed?.id ?? UUID())
        let cameraRecorder = plan.camera.map { config in
            // Camera events arrive on the camera queue and come here with async, never sync.
            warmCamera ?? CameraRecorder(config: config, levels: levels) { [weak self] event in
                Task { @MainActor in self?.previewCameraEvent(event, id: takeID) }
            }
        }
        takeCameraID = cameraRecorder == nil ? nil : takeID
        // A claimed camera keeps what it reported since Start was pressed.
        if freshCamera { takeCameraBroken = false }
        // The codec and bitrate of the moment: a claimed preview camera opened before a change.
        if let config = plan.camera { cameraRecorder?.useEncoder(codec: config.codec, bitrate: config.bitrate) }
        cameraRecorder?.keepPreviewWhileRecording(keepPreview)
        if keepPreview, freshCamera { previewFeed.resetStats() }
        let screenRecorder = screenConfig.map { ScreenRecorder(config: $0, levels: levels) }
        camera = cameraRecorder
        screen = screenRecorder
        // The meters and the detector start over for the take (the recorders call beginTake at Start).
        levels.reset()
        micAlertOnset.reset()
        activeMeterSources = MeterSources.take(cameraAudio: cameraRecorder?.config.audioDeviceUID != nil,
                                               screenMic: screenConfig?.micDeviceUID != nil,
                                               systemAudio: screenConfig?.captureSystemAudio == true)
        // Camera mode: the Mac mic meter shows while the idle Mac mic meter runs.
        refreshIdleMeterSources()
        lineProblems = [:]
        recorderProblems = [:]
        updateLines("preparing")

        guard let prepareErrors = await Self.prepareAll(camera: cameraRecorder, preview: keepPreview ? previewFeed : nil,
                                                        screen: screenRecorder, events: session.events,
                                                        timeout: Self.prepareTimeout) else {
            let seconds = Self.prepareTimeout.components.seconds
            await abortStart(errors: ["The camera or screen capture did not get ready within \(seconds) s."],
                             cameraStarted: false, screenStarted: false, waitForTeardown: false)
            return
        }
        guard prepareErrors.isEmpty else {
            await abortStart(errors: prepareErrors, cameraStarted: false, screenStarted: false)
            return
        }
        if let screenRecorder, screenConfig?.shownOwnWindowIDs.isEmpty == false, screenRecorder.shownOwnWindowIDs.isEmpty {
            session.events.append(.warning, ["source": "keystrokes", "message": KeystrokeRules.notInScreenMessage])
            Self.log.error("\(KeystrokeRules.notInScreenMessage, privacy: .public)")
            // Not in the filter: the window need not stay on screen for the take.
            takeHasPillWindow = false
        }
        if let change = cameraRecorder?.lastGraphChange {
            // The upgrade of a claimed preview camera (or the build of a fresh one), with its time.
            Self.log.notice("Camera graph \(change.logLine, privacy: .public)")
        }
        if cancelRequested {
            await abortStart(errors: ["Start was cancelled before recording began."], cameraStarted: false,
                             screenStarted: false, cancelled: true)
            return
        }

        // What the camera sends, now that it is open: camera.mov records it, and the screen rate
        // goes with it. The plan took the rate from the device list; they differ only when the
        // signal changed right before Start.
        if let signal = cameraRecorder?.signal {
            if let screenConfig, signal.screenFrameRate != screenConfig.frameRate {
                session.events.append(.warning, ["source": "screen", "message":
                    "The camera sends \(signal.frameRate.label) fps, but screen.mov records \(screenConfig.frameRate.label) fps, "
                    + "not \(signal.screenFrameRate.label): the camera signal changed right before Start."])
            }
            rememberCameraRate(signal)
        }

        // Both files begin at one shared time a little in the future: each recorder gets ready
        // before it and begins at its first frame at or after it (StartSchedule).
        let startNs = StartSchedule.startHostNs()
        session.manifest.startedAtHostNs = startNs
        var startData = ["mode": plan.mode.rawValue, "folder": session.folder.url.lastPathComponent]
        startData["camera_format"] = cameraRecorder?.negotiatedFormat
        startData["camera_signal"] = cameraRecorder?.signal?.label
        startData["screen_output_px"] = screenConfig.map { "\($0.outputPx.width)x\($0.outputPx.height)" }
        startData["screen_frame_rate"] = screenConfig.map { $0.frameRate.storage }
        startData["frame_anchor"] = plan.screen.map { $0.preset.sizing == .fullDisplay ? "none" : $0.anchor.rawValue }
        startData["scheduled_start_margin_ms"] = String(StartSchedule.marginNs / 1_000_000)
        if cameraRecorder != nil { startData["camera_window"] = settings.cameraWindowShown && settings.cameraWindowWhileRecording ? "on" : "off" }
        startData.merge(KeystrokeRules.sessionStartData(mode: settings.keystrokeMode,
                                                        inScreen: screenRecorder.map { !$0.shownOwnWindowIDs.isEmpty })) { _, new in new }
        session.events.append(.sessionStart, startData, at: startNs)

        let outcome = await Self.startAll(camera: cameraRecorder, screen: screenRecorder,
                                          folder: session.folder, events: session.events, at: startNs)
        let startErrors = [outcome.camera, outcome.screen].compactMap { $0 }
        guard startErrors.isEmpty else {
            await abortStart(errors: startErrors, cameraStarted: cameraRecorder != nil && outcome.camera == nil,
                             screenStarted: screenRecorder != nil && outcome.screen == nil)
            return
        }

        if let cameraRecorder {
            // A device read on the camera queue: never let it hold the app in "Starting…".
            session.manifest.camera = await Self.waitAtMost(.seconds(5)) { await cameraRecorder.cameraInfo() } ?? CameraInfo()
        }
        writeManifest(session)
        state = .recording
        // The timer counts from the files' shared start (`startNs`), not from now: Start waited for
        // both files and the camera info, and a flag's `elapsed_s` must be the media time.
        startedAt = Date().addingTimeInterval(-ControlBarRules.secondsSince(startNs, nowNs: HostClock.nowNs()))
        now = Date()
        markers = []
        overlay.setRecording(true)
        updateLines("recording")
        startClock()
        startMonitor(session)
        Self.log.notice("Recording \(plan.mode.rawValue, privacy: .public) to \(session.folder.url.path, privacy: .public)")
        if cancelRequested {
            // Pressed again while starting: the files had already begun, so save them as a short take.
            cancelRequested = false
            await runStop()
            notice = "Stopped right after Start, because Start/Stop was pressed while starting."
        }
    }

    /// Ends a start before anything was prepared (cancelled, blocked, or no session folder): the
    /// claimed preview camera goes back to the preview when it is still open on its preview graph
    /// and reported nothing, so a press that does not record never closes and reopens the camera.
    /// - Parameter unresponsive: the camera did not answer preflight; it is released without waiting.
    private func endStartBeforePrepare(claimed: WarmCamera?, warmCamera: CameraRecorder?, unresponsive: Bool = false) async {
        defer {
            takeCameraID = nil
            takeCameraBroken = false
        }
        guard let warmCamera else { return }
        if let claimed, claimed.recorder === warmCamera, !claimed.broken, !takeCameraBroken, !unresponsive,
           warm == nil, warmCamera.isPreviewReady {
            // The picture never stopped: count its frames from now. A camera claimed while it was
            // still opening opened since (its open saw the claim and left its state as it was).
            previewFeed.resetStats()
            claimed.state = .ready
            claimed.readyAtNs = HostClock.nowNs()
            warm = claimed
            Self.log.notice("Preview camera kept: the start did not go on")
        } else if unresponsive {
            Task.detached { await warmCamera.teardown() }
        } else {
            await Self.teardown(warmCamera, waitingAtMost: Self.teardownTimeout)
        }
    }

    /// Start/Stop (or Quit, or sleep) was pressed while starting, before anything was prepared.
    private func cancelStartBeforePrepare(claimed: WarmCamera?, warmCamera: CameraRecorder?) async {
        await endStartBeforePrepare(claimed: claimed, warmCamera: warmCamera)
        cancelRequested = false
        state = .idle
        notice = "Start cancelled. Nothing was recorded."
        await updatePreview()
    }

    private struct StartOutcome: Sendable {
        var camera: String?
        var screen: String?
    }

    /// Prepares both recorders. Nil when they take longer than `timeout`: a hung camera or stream
    /// must not hold the app in "Starting…", where Start/Stop does nothing.
    nonisolated private static func prepareAll(camera: CameraRecorder?, preview: CameraPreviewFeed?, screen: ScreenRecorder?,
                                               events: EventLog, timeout: Duration) async -> [String]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let first = FirstValue(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { first.resume(nil) }
            }
            Task {
                let errors = await prepareBoth(camera: camera, preview: preview, screen: screen, events: events)
                timer.cancel()
                first.resume(errors)
            }
        }
    }

    /// - Parameters:
    ///   - preview: a camera opened here also feeds this preview (a claimed preview camera is open
    ///     already and keeps its own).
    ///   - events: the take's log, for the camera's graph change.
    nonisolated private static func prepareBoth(camera: CameraRecorder?, preview: CameraPreviewFeed?,
                                                screen: ScreenRecorder?, events: EventLog) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            if let camera {
                group.addTask {
                    do {
                        try await camera.prepare(preview: preview, events: events)
                        return nil
                    } catch {
                        return "Camera: \(error.localizedDescription)"
                    }
                }
            }
            if let screen {
                group.addTask {
                    do { try await screen.prepare(); return nil } catch { return "Screen: \(error.localizedDescription)" }
                }
            }
            var errors: [String] = []
            for await error in group { if let error { errors.append(error) } }
            return errors
        }
    }

    /// Starts both files at once, both scheduled to begin at `startHostNs`.
    nonisolated private static func startAll(camera: CameraRecorder?, screen: ScreenRecorder?,
                                             folder: SessionFolder, events: EventLog, at startHostNs: UInt64) async -> StartOutcome {
        await withTaskGroup(of: (isCamera: Bool, error: String?).self) { group in
            if let camera {
                group.addTask {
                    (true, await start(camera, title: "Camera", writingTo: folder.cameraURL, events: events, at: startHostNs))
                }
            }
            if let screen {
                group.addTask {
                    (false, await start(screen, title: "Screen", writingTo: folder.screenURL, events: events, at: startHostNs))
                }
            }
            var outcome = StartOutcome()
            for await result in group {
                if result.isCamera { outcome.camera = result.error } else { outcome.screen = result.error }
            }
            return outcome
        }
    }

    nonisolated private static func stopAll(camera: CameraRecorder?, screen: ScreenRecorder?) async -> [RecorderResult] {
        await withTaskGroup(of: RecorderResult.self) { group in
            if let camera { group.addTask { await stop(camera, title: "Camera") } }
            if let screen { group.addTask { await stop(screen, title: "Screen") } }
            var results: [RecorderResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Starts a recorder's file at the scheduled `startHostNs`, but waits at most `startTimeout`.
    /// Nil: it started; else the error. A start that comes after the limit is stopped by the
    /// teardown of the aborted start.
    nonisolated private static func start(_ recorder: any SessionTrackRecorder, title: String,
                                          writingTo url: URL, events: EventLog, at startHostNs: UInt64) async -> String? {
        let result = await waitAtMost(startTimeout) { () async -> String? in
            do {
                try await recorder.start(writingTo: url, events: events, at: startHostNs)
                return nil
            } catch {
                return "\(title): \(error.localizedDescription)"
            }
        }
        return result ?? "\(title): the file did not start within \(startTimeout.components.seconds) s."
    }

    /// Stops a recorder, but waits at most `stopTimeout`: a stuck camera queue must not hold the
    /// app in "Saving…". After that the file is reported as not finished.
    nonisolated private static func stop(_ recorder: any SessionTrackRecorder, title: String) async -> RecorderResult {
        await waitAtMost(stopTimeout) { await recorder.stop() }
            ?? RecorderResult(errors: ["\(title): the file did not finish within \(stopTimeout.components.seconds) s."])
    }

    /// Releases a recorder, but waits at most `timeout`. A teardown that takes longer goes on by itself.
    nonisolated private static func teardown(_ recorder: (any SessionTrackRecorder)?, waitingAtMost timeout: Duration) async {
        guard let recorder else { return }
        _ = await waitAtMost(timeout) { await recorder.teardown() }
    }

    /// The result of `work`, or nil when it takes longer than `timeout`. `work` then goes on by itself.
    nonisolated static func waitAtMost<T: Sendable>(_ timeout: Duration,
                                                    _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let first = FirstValue(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { first.resume(nil) }
            }
            Task {
                let value = await work()
                timer.cancel()
                first.resume(value)
            }
        }
    }

    /// Ends a session whose start failed or was cancelled: stops what did start, writes
    /// session.json as failed.
    /// - Parameter waitForTeardown: false when a recorder may be hung, so releasing it cannot hold the app.
    private func abortStart(errors: [String], cameraStarted: Bool, screenStarted: Bool, cancelled: Bool = false,
                            waitForTeardown: Bool = true) async {
        guard let session = active else { return }
        state = .stopping
        cancelRequested = false
        updateLines("stopping")
        returnCameraToPreviewAfterStop()
        let results = await Self.stopAll(camera: cameraStarted ? camera : nil, screen: screenStarted ? screen : nil)
        // A recorder that began the take and did not start its file never ends it itself.
        levels.closeTake(events: session.events)
        for error in errors { session.events.append(.error, ["source": "app", "message": error]) }
        SessionRules.finish(&session.manifest, results: results, extraErrors: errors, stoppedAtHostNs: HostClock.nowNs())
        session.events.append(.sessionStop, ["status": session.manifest.status.rawValue])
        if writeManifest(session) { SessionRecovery.clearInProgress() }
        session.events.close()
        // The take's camera stays open for the preview when it is back on its preview graph: a
        // camera whose file was stopped here. (A failed upgrade opens the camera again in
        // CameraRecorder.prepare, so it no longer ends the start.)
        let kept = cameraKeptForPreview(mayWait: waitForTeardown)
        await endSession(waitForTeardown: waitForTeardown, keepingCamera: kept != nil)
        // Only a start that wrote a movie is a take: else the Saved line and Replay keep the last
        // real take, and a cancelled start leaves no folder behind ("Nothing was recorded").
        let folder = session.folder
        if [folder.cameraURL, folder.screenURL].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            lastSession = LastSession(folder: folder.url, status: session.manifest.status,
                                      durationS: session.manifest.durationS, errors: session.manifest.errors,
                                      micSource: session.manifest.tracks.lazy.compactMap(\.micSource).first)
        } else if cancelled {
            removeCancelledStartFolder(folder)
        }
        if let kept { keepAsPreviewCamera(kept) }
        if cancelled {
            state = .idle
            notice = "Start cancelled. Nothing was recorded."
        } else {
            state = .error(errors.first ?? "Start failed.")
            Self.log.error("Start failed: \(errors.joined(separator: " | "), privacy: .public)")
            if !menuVisible {
                NSSound.beep()
                flashControlBar("Start failed: open the menu", tone: .problem)
            }
        }
        await updatePreview()
    }

    /// Removes the folder of a start cancelled before its files began: it holds only session.json
    /// and events.jsonl, written by this start. Anything else in it, and it stays.
    private func removeCancelledStartFolder(_ folder: SessionFolder) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.url.path), SessionRules.holdsOnlyStartFiles(names) else {
            return
        }
        do {
            try fm.removeItem(at: folder.url)
            SessionRecovery.clearInProgress()
            Self.log.notice("Removed \(folder.url.lastPathComponent, privacy: .public): the start was cancelled before the files began")
        } catch {
            Self.log.error("Could not remove the cancelled start's folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Stop

    func requestStop() {
        guard state == .recording else { return }
        Task { await runStop() }
    }

    private func runStop() async {
        guard state == .recording, let session = active else { return }
        state = .stopping
        let stopNs = HostClock.nowNs()
        monitor?.stop()
        monitor = nil
        updateLines("saving")

        returnCameraToPreviewAfterStop()
        let results = await Self.stopAll(camera: camera, screen: screen)
        // Each recorder ended its part; the take ends here for sure (a stop that timed out).
        levels.closeTake(events: session.events)
        SessionRules.finish(&session.manifest, results: results, stoppedAtHostNs: stopNs)
        writeVoiceTimeline(session)
        var stopData = ["status": session.manifest.status.rawValue, "markers": String(markers.count)]
        stopData["duration_s"] = session.manifest.durationS.map { String(format: "%.3f", $0) }
        stopData["stop_pressed_host_ns"] = String(stopNs)
        session.events.append(.sessionStop, stopData)
        let saved = writeManifest(session)
        // A session.json that still says "recording" is left for recovery at the next launch.
        if saved { SessionRecovery.clearInProgress() }
        session.events.close()
        let kept = cameraKeptForPreview()
        await endSession(keepingCamera: kept != nil)

        lastSession = LastSession(folder: session.folder.url, status: session.manifest.status,
                                  durationS: session.manifest.durationS, errors: session.manifest.errors,
                                  micSource: session.manifest.tracks.lazy.compactMap(\.micSource).first)
        if let kept { keepAsPreviewCamera(kept) }
        state = saved ? .idle : .error("Could not write session.json in \(session.folder.url.lastPathComponent).")
        Self.log.notice("Stopped: \(session.manifest.status.rawValue, privacy: .public), \(session.manifest.errors.count) error(s)")
        if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([session.folder.url]) }
        rematchDevices()
        await updatePreview()
        await refreshPreflight()
    }

    /// Releases the recorders, the overlay and the timers of the session that just ended.
    /// - Parameter keepingCamera: the take's camera stays open as the preview camera
    ///   (`keepAsPreviewCamera`), so it is not torn down here.
    private func endSession(waitForTeardown: Bool = true, keepingCamera: Bool = false) async {
        monitor?.stop()
        monitor = nil
        clockTicker?.cancel()
        clockTicker = nil
        if let activity = recordingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            recordingActivity = nil
        }
        overlay.setRecording(false)
        overlayAwaitsDisplay = false
        let cameraRecorder = keepingCamera ? nil : camera, screenRecorder = screen
        camera = nil
        screen = nil
        // A kept camera keeps its id until `keepAsPreviewCamera`, so trouble it reports while the
        // screen recorder tears down still marks it broken.
        if !keepingCamera { takeCameraID = nil }
        active = nil
        trackLines = []
        recorderProblems = [:]
        startedAt = nil
        activeMeterSources = []
        applyDetector(levels.detectorStatus)
        if frameShownWhileIdle { showIdleFrame() } else { overlay.hide() }
        if waitForTeardown {
            await Self.teardown(cameraRecorder, waitingAtMost: Self.teardownTimeout)
            await Self.teardown(screenRecorder, waitingAtMost: Self.teardownTimeout)
        } else {
            Task.detached {
                await cameraRecorder?.teardown()
                await screenRecorder?.teardown()
            }
        }
    }

    /// Tells the take's camera which graph to hold once its file has finished: the preview graph
    /// when a view will show the camera (with the camera mic meter, decision 1: the camera audio
    /// input then stays, so the orange indicator does not flicker), else the recording graph until
    /// its teardown, so nothing holds the camera after Stop when nothing shows it (decision 2).
    /// Set right before the stop, so it follows the menu and the window.
    private func returnCameraToPreviewAfterStop() {
        let audio = camera?.config.audioDeviceUID
        let afterTake = CameraGraphPlan.wanted(recording: false, previewWanted: previewWantedOnceIdle,
                                               keepPreviewWhileRecording: false, audioDeviceUID: audio,
                                               idleMeters: idleCameraMeterWanted(audioDeviceUID: audio))
        camera?.returnToPreviewAfterStop(afterTake == nil ? nil : previewFeed, meters: afterTake?.hasAudioMeter ?? false)
    }

    /// The take's camera as the preview camera, when it may stay open after the take
    /// (`PreviewRules.keepsTakeCamera`). Nil: it closes, and the preview opens the camera again.
    private func cameraKeptForPreview(mayWait: Bool = true) -> WarmCamera? {
        guard let recorder = camera, let id = takeCameraID, takeCameraMayStay(recorder, mayWait: mayWait),
              let config = makePlan().camera else { return nil }
        let target = PreviewTarget(config: config, signal: inventory.signalSignature(forVideoUID: config.videoDeviceUID) ?? "")
        let kept = WarmCamera(id: id, recorder: recorder, target: target, prepared: Task { nil })
        kept.state = .ready
        kept.meterRequest = (idleCameraMeterWanted(audioDeviceUID: config.audioDeviceUID), HostClock.nowNs())
        return kept
    }

    /// `PreviewRules.keepsTakeCamera` for the take's camera, now.
    private func takeCameraMayStay(_ recorder: CameraRecorder, mayWait: Bool) -> Bool {
        PreviewRules.keepsTakeCamera(previewWanted: previewWantedOnceIdle, previewReady: recorder.isPreviewReady,
                                     broken: takeCameraBroken, sameConfig: PreviewRules.sameCamera(recorder.config, makePlan().camera),
                                     otherPreviewOpen: warm != nil, mayWait: mayWait)
    }

    /// Makes the take's camera the preview camera. Called right before the state leaves stopping,
    /// with no suspension in between, so no preview pass sees it while the take still runs. The
    /// rule is checked again first: the camera may have reported trouble (or the menu closed) while
    /// `endSession` awaited the screen recorder's teardown. Then it closes instead, and Start and
    /// Quit wait for that close (`warmClosing`).
    private func keepAsPreviewCamera(_ kept: WarmCamera, mayWait: Bool = true) {
        defer { takeCameraID = nil }
        guard takeCameraMayStay(kept.recorder, mayWait: mayWait) else {
            Self.log.notice("The take's camera closes after the take: it reported trouble, or no preview wants it now")
            let previous = warmClosing
            warmClosing = Task {
                await previous?.value
                await kept.recorder.teardown()
            }
            return
        }
        // The preview output may have joined the session only now: count frames from here.
        previewFeed.resetStats()
        kept.readyAtNs = HostClock.nowNs()
        warm = kept
        Self.log.notice("Preview camera kept after the take: \(kept.recorder.lastGraphChange?.logLine ?? "no graph change", privacy: .public)")
    }

    /// Writes voice.jsonl at Stop: the take's voice timeline (`AudioLevelMonitor.voiceTimeline`),
    /// so a replay of the saved take can skip its silence. Only when a mic was heard. Logs a
    /// warning when it fails; the take is fine without it.
    private func writeVoiceTimeline(_ session: ActiveSession) {
        guard let origin = session.manifest.startedAtHostNs else { return }
        let timeline = levels.voiceTimeline()
        guard timeline.cameraMicHeard || timeline.screenMicHeard else { return }
        do {
            try VoiceTimelineFile.encode(timeline, originNs: origin).write(to: session.folder.voiceURL, options: .atomic)
        } catch {
            session.events.append(.warning, ["source": "app", "message": "voice.jsonl write failed: \(error.localizedDescription)"])
        }
    }

    /// Writes session.json atomically. Logs an error event when it fails.
    @discardableResult
    private func writeManifest(_ session: ActiveSession) -> Bool {
        do {
            try session.folder.writeManifest(session.manifest)
            return true
        } catch {
            session.events.append(.error, ["source": "app", "message": "session.json write failed: \(error.localizedDescription)"])
            return false
        }
    }

    // MARK: - Markers and window snap

    /// Flag (the control bar's button and ⌃⌥⌘B): a `marker` of kind `flag` in events.jsonl,
    /// meaning "something in the last few minutes was wrong", with `lookback_s` (Control Bar
    /// settings, 3 min by default). A mistake is often noticed a minute or two after it happened,
    /// so the flag points back; the take goes on. Only while recording.
    func flag() {
        let lookback = settings.flagLookbackSeconds
        guard state == .recording, let session = active else {
            flashControlBar("Flag works while recording", tone: .neutral)
            return
        }
        // Media time of the press: host time since the files began (session.json
        // `started_at_host_ns`), the same clock as the marker's `t_host_ns`.
        let nowNs = HostClock.nowNs()
        let elapsedS = session.manifest.startedAtHostNs.map { ControlBarRules.secondsSince($0, nowNs: nowNs) }
            ?? Date().timeIntervalSince(startedAt ?? Date())
        session.events.append(.marker, ControlBarRules.flagMarkerData(elapsedS: elapsedS, lookbackS: lookback), at: nowNs)
        markers.append(ControlBarRules.flagKind)
        notice = ControlBarRules.flagNotice(elapsed: elapsedText, lookbackS: lookback)
        flashControlBar(ControlBarRules.flagFlash(lookbackS: lookback), tone: .good)
        Self.log.notice("Flag at \(elapsedS, format: .fixed(precision: 1)) s, lookback \(lookback) s")
    }

    /// Snaps the front window into the frame now. While recording, every snap is logged, but it
    /// replaces the recorded snap (session.json and the watched window) only when it found a
    /// window and, in window-only mode, that window is the one being recorded.
    func snapNow() {
        let plan = active?.screenPlan ?? makePlan().screen
        guard let plan else {
            notice = "Pick Screen or Both to use the frame."
            return
        }
        guard snapper.isTrusted else {
            notice = "Accessibility is off. Allow it under Permissions to snap windows."
            return
        }
        applySnap(performSnap(into: plan), plan: plan)
    }

    /// The notices, events and session.json for a snap made now (Snap, ⌃⌥⌘F or a pinned app).
    private func applySnap(_ snap: SnapResult, plan: ScreenPlan) {
        guard state == .recording, let session = active else {
            let fix = state.canStart ? SessionRules.snapFix(failure: snap.failure, preset: plan.preset, anchor: plan.anchor) : nil
            notice = SessionRules.snapNotice(snap, fix: fix)
            snapFix = fix
            return
        }
        session.events.append(.windowSnap, snap.eventData)
        let recordedWindow = screen?.config.windowID
        if SessionRules.snapReplacesRecordedSnap(foundWindow: snap.achievedFrame != nil, snappedWindowID: snap.windowID,
                                                 recordedWindowID: recordedWindow) {
            adopt(snap, display: plan.display, in: session)
            startMonitor(session)
            notice = snap.message
        } else if recordedWindow != nil, snap.achievedFrame != nil {
            // Window-only capture records the window chosen at Start; another window never appears.
            let recorded = session.snap?.appName.map { "the \($0) window" } ?? "the window chosen at Start"
            notice = "\(snap.message) Hide other windows keeps recording \(recorded)."
        } else {
            notice = snap.message
        }
    }

    private func snapFrontWindow(into plan: ScreenPlan, session: ActiveSession) {
        guard snapper.isTrusted else {
            let message = "Accessibility is off, so the front window was not snapped."
            session.events.append(.warning, ["source": "window_snap", "message": message])
            notice = message
            return
        }
        let snap = performSnap(into: plan)
        record(snap, display: plan.display, in: session)
    }

    /// Snaps the front window on the plan's display into its frame, or with `app` that app's
    /// front window (`WindowSnapper.snapFrontWindow(ofAppWithBundleID:…)`). Parallels Desktop keeps
    /// its toolbar above the frame while "Hide the Parallels toolbar" is on (`SnapProfile.parallelsDesktop`).
    private func performSnap(into plan: ScreenPlan, app: PinnedApp? = nil) -> SnapResult {
        snapper.profiles = settings.hideParallelsToolbar ? SnapProfile.all : []
        let fineTune = CGFloat(settings.parallelsToolbarOffsetPt)
        let snap = app.map {
            snapper.snapFrontWindow(ofAppWithBundleID: $0.bundleID, appName: $0.name, to: plan.snapTarget,
                                    excludingBundleID: ownBundleID, toolbarFineTunePt: fineTune, display: plan.display)
        } ?? snapper.snapFrontmostWindow(to: plan.snapTarget, excludingBundleID: ownBundleID,
                                         toolbarFineTunePt: fineTune, display: plan.display)
        refreshSnapTarget()
        return snap
    }

    /// Reads which window a snap would move (the window list only: no Accessibility call) and
    /// names it on the Snap button.
    func refreshSnapTarget() {
        let key = HotKey.snapWindow.displayString
        var title = "Snap Front Window"
        var help = "Moves the front window into the frame (\(key))."
        if let plan = active?.screenPlan ?? makePlan().screen {
            let targets = snapper.targets(for: plan.snapTarget, excludingBundleID: ownBundleID, display: plan.display)
            title = targets.buttonTitle
            help = targets.first.map { "Moves \($0.targetName) into the frame (\(key))." } ?? targets.noTargetMessage
        }
        if title != snapButtonTitle { snapButtonTitle = title }
        if help != snapButtonHelp { snapButtonHelp = help }
    }

    private func record(_ snap: SnapResult, display: DisplayInfo, in session: ActiveSession) {
        session.events.append(.windowSnap, snap.eventData)
        adopt(snap, display: display, in: session)
        notice = snap.message
    }

    /// Makes `snap` the session's snap: session.json `snapped_window` and the window to watch.
    private func adopt(_ snap: SnapResult, display: DisplayInfo, in session: ActiveSession) {
        session.snap = snap
        if var window = snap.snappedWindow {
            window.windowId = snap.windowID
            // The recorded part: the content area for a window with its toolbar above the frame.
            window.achievedFramePt = (snap.achievedRecordedFrame ?? snap.achievedFrame)
                .map { PointRect(display.localRect(fromGlobal: $0)) }
            if snap.placement == .toolbarAbove {
                window.windowFramePt = snap.achievedFrame.map { PointRect(display.localRect(fromGlobal: $0)) }
            }
            session.manifest.screen?.snappedWindow = window
        }
    }

    private func startMonitor(_ session: ActiveSession) {
        monitor?.stop()
        monitor = nil
        guard let snap = session.snap, let watcher = SnappedWindowMonitor(snap: snap) else { return }
        watcher.start { [weak self, weak session] move in
            session?.events.append(.windowMove, move.eventData, at: move.tHostNs)
            if move.closed {
                self?.notice = "The snapped window closed."
            } else if !move.fillsFrame {
                self?.notice = "The snapped window left the frame. Press \(HotKey.snapWindow.displayString) to snap it back."
            } else {
                self?.notice = nil
            }
        }
        monitor = watcher
    }

    // MARK: - Frame overlay while idle

    func setFrameShown(_ shown: Bool) {
        frameShownWhileIdle = shown
        guard state.canStart else { return }
        if shown { showIdleFrame() } else { overlay.hide() }
    }

    private var dimOpacity: Double { settings.dimOutsideFrame ? Self.dimOpacity : 0 }

    private func showIdleFrame() {
        guard settings.mode.includesScreen, let plan = makePlan().screen else {
            overlay.hide()
            return
        }
        overlay.show(frameGlobal: plan.frameGlobal, display: plan.display, dimOpacity: dimOpacity)
    }

    // MARK: - Preview camera

    /// Opens, reopens or closes the preview camera to match the menu, the settings and the
    /// devices. One pass at a time: a call during a pass makes it run once more afterwards, so
    /// opening and closing never overlap.
    func updatePreview() async {
        if previewPassRunning {
            previewPassAgain = true
            return
        }
        previewPassRunning = true
        defer { previewPassRunning = false }
        repeat {
            previewPassAgain = false
            await previewPass()
        } while previewPassAgain
    }

    private func previewPass() async {
        // Decision 2: the camera is open only while something shows it (or within the debounce
        // after that), and a closed camera opens only while something shows it now.
        let wantedNow = idleCaptureWantedNow
        let decision = updateIdleDemand(wantedNow: wantedNow)
        var wanted: PreviewTarget?
        previewBlocked = nil
        if state.canStart, IdleCaptureRules.keepsOrOpens(decisionOpen: decision.open, wantedNow: wantedNow, isOpen: warm != nil),
           let config = makePlan().camera {
            permissions.refresh()
            // The camera mic meter is best effort (it never prompts): only the camera permission
            // blocks the preview.
            previewBlocked = SessionRules.previewBlockedMessage(camera: permissions.state(.camera))
            if previewBlocked == nil {
                wanted = PreviewTarget(config: config,
                                       signal: inventory.signalSignature(forVideoUID: config.videoDeviceUID) ?? "")
            }
        }
        let connected = wanted.map { inventory.isConnected(videoUID: $0.config.videoDeviceUID) } ?? false
        let nowNs = HostClock.nowNs()
        let retryCurrent = warm.map { camera in
            PreviewRules.shouldRetry(camera.state, retryableFailure: camera.retryable,
                                     lastFrameNs: previewFeed.stats().lastFrameHostNs, readySinceNs: camera.readyAtNs, nowNs: nowNs)
                && PreviewRules.mayRetry(previewRetry, target: camera.target, menuVisible: menuVisible)
        } ?? false
        switch PreviewRules.action(wanted: wanted, connected: connected, holding: previewHold != nil, current: warm?.target,
                                   retryCurrent: retryCurrent, mustWait: previewRetry?.blocks(wanted, nowNs: nowNs) ?? false) {
        case .none:
            break
        case .close:
            await closeWarmCamera()
        case let .open(target):
            await openWarmCamera(target)
        case let .reopen(target):
            if let camera = warm, camera.target == target, camera.state == .ready {
                // Still listed, but no picture: count it, so a camera that never sends one backs off.
                previewRetry = .next(after: previewRetry, target: target, reason: "No picture from the camera.", nowNs: nowNs)
                Self.log.notice("Preview camera sends no picture; opening it again")
            }
            await closeWarmCamera()
            // Start, Quit or the menu may have changed during the close: decide the open again.
            previewPassAgain = true
        }
        await syncIdleCameraMeter()
        refreshPreviewPhase()
        syncMacMic()
    }

    /// The mode records the camera, nothing records, and the menu shows the preview or the camera
    /// window is on.
    private var previewShowing: Bool { state.canStart && previewWantedOnceIdle }

    // MARK: - Idle capture (decisions 1 and 2)

    /// Something wants the camera and the idle mics now: the camera window is on, the open menu
    /// shows its Live preview, a take prepares, records or saves, or a mic check samples the idle
    /// meters. Only in a mode that records the camera. The window and the menu count only while
    /// the screen can show them (not asleep, not locked, the user's session active).
    private var idleCaptureWantedNow: Bool {
        guard !shuttingDown, settings.mode.includesCamera else { return false }
        let seen = screenCanShowCamera
        return IdleCaptureDemand.wanted(cameraWindowShown: seen && settings.cameraWindowShown,
                                        menuPreviewShown: seen && menuVisible && settings.showCameraPreview,
                                        takeActive: !state.canStart || checkUsesIdleMeters)
    }

    /// Feeds the debounce and schedules the pass at its end. The pending pass is never cancelled
    /// (a cancelled task would cut the waits inside the pass short); a newer wish just makes it do
    /// nothing.
    @discardableResult
    private func updateIdleDemand(wantedNow: Bool) -> IdleCaptureDemand.Decision {
        let decision = idleDemand.update(wanted: wantedNow, nowNs: HostClock.nowNs())
        guard decision.recheckAtNs != idleRecheckAtNs else { return decision }
        idleRecheckAtNs = decision.recheckAtNs
        if let at = decision.recheckAtNs {
            Task { [weak self] in
                let now = HostClock.nowNs()
                if at > now { try? await Task.sleep(nanoseconds: at - now + 1_000_000) }
                guard let self, self.idleRecheckAtNs == at else { return }
                self.idleRecheckAtNs = nil
                // Its own pass: the Mac mic closes even while a camera pass hangs.
                self.syncMacMic()
                await self.updatePreview()
            }
        }
        return decision
    }

    private var micAllowed: Bool { permissions.state(.microphone) == .granted }

    /// The preview graph meters the camera mic (decision 1), unless no mic may open without a
    /// prompt, the config has no camera audio, or a mic check holds that input itself.
    private func idleCameraMeterWanted(audioDeviceUID: String?) -> Bool {
        IdleCaptureRules.cameraMeterWanted(micAllowed: micAllowed, hasCameraAudio: audioDeviceUID != nil,
                                           checkOwnsCameraMic: checkOwnSources.contains(.cameraMic))
    }

    /// Adds or removes the camera mic meter on the open preview camera when the wish changed
    /// (the microphone was allowed, a mic check that held the camera audio ended). One session
    /// change on the camera queue; the picture keeps running.
    private func syncIdleCameraMeter() async {
        guard state.canStart, let camera = warm, camera.state == .ready, !camera.broken else { return }
        let want = idleCameraMeterWanted(audioDeviceUID: camera.target.config.audioDeviceUID)
        let nowNs = HostClock.nowNs()
        guard IdleCaptureRules.shouldRequestMeter(want: want, isOn: camera.recorder.idleMetersOn,
                                                  last: camera.meterRequest, nowNs: nowNs) else { return }
        camera.meterRequest = (want, nowNs)
        let recorder = camera.recorder
        // Bounded like every camera wait: a camera queue that hangs must not hold up the pass.
        let result = await Self.waitAtMost(Self.meterChangeTimeout) { () async -> Result<Bool, any Error> in
            do { return .success(try await recorder.setIdleMeters(want)) } catch { return .failure(error) }
        }
        switch result {
        case let .success(on)?:
            Self.log.notice("Camera mic meter \(want ? "on" : "off", privacy: .public): \(on ? "metering" : "not metering", privacy: .public)")
        case let .failure(error)?:
            Self.log.error("Camera mic meter change failed: \(error.localizedDescription, privacy: .public)")
        case nil:
            Self.log.error("Camera mic meter change did not finish within \(Self.meterChangeTimeout.components.seconds) s")
        }
        refreshIdleMeterSources()
    }

    /// The idle Mac mic's uid while it may be open: nothing records, or the take does not record
    /// the Mac mic (Camera mode: the meter is then the detector's reference), the mode records the
    /// camera, the microphone is allowed (no prompt), no mic check holds the Mac mic itself, and a
    /// screen mic is picked. The debounce and "something shows the camera" are checked by the pass.
    private var idleMacMicUID: String? {
        guard IdleCaptureRules.macMicMayOpen(idle: state.canStart, takeRecordsScreenMic: takeRecordsScreenMic),
              !shuttingDown, settings.mode.includesCamera, micAllowed,
              !checkOwnSources.contains(.screenMic) else { return nil }
        return settings.screenMic.resolve { automatic.screenMic }
    }

    /// Asks for a Mac mic pass. Passes run one after the other; a pass that has not started yet
    /// reads the newest state, so a burst of calls makes one pass.
    private func syncMacMic() {
        guard !macMicPending else { return }
        macMicPending = true
        let previous = macMicTask
        macMicTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.macMicPending = false
            await self.macMicPass()
        }
    }

    /// Opens or closes the idle Mac mic meter to match the rules. Its own audio-only session on
    /// the meter's queue: this only awaits it.
    private func macMicPass() async {
        let wantedNow = idleCaptureWantedNow
        let decision = updateIdleDemand(wantedNow: wantedNow)
        let uid = decision.open ? idleMacMicUID : nil
        let nowNs = HostClock.nowNs()
        if let meter = macMic, meter.micUID != uid || !meter.isOpen {
            // A meter whose session stopped by itself (the mic unplugged, a runtime error) closes
            // too, and a new one opens after `retryAfterNs` (the uid of a picked mic stays the same).
            let stopped = meter.micUID == uid ? meter.stopReason : nil
            macMic = nil
            await meter.close()
            if let stopped, let uid {
                macMicFailure = (uid, nowNs)
                Self.log.notice("Idle Mac mic stopped by itself (\(stopped, privacy: .public)); closed")
            } else {
                Self.log.notice("Idle Mac mic closed")
            }
        }
        if let uid, macMic == nil, IdleCaptureRules.keepsOrOpens(decisionOpen: decision.open, wantedNow: wantedNow, isOpen: false),
           macMicFailure.map({ $0.uid != uid || nowNs >= $0.atNs &+ IdleCaptureRules.retryAfterNs }) ?? true {
            let meter = MacMicMeter(micUID: uid, levels: levels)
            do {
                try await meter.open()
                macMicFailure = nil
                // Start, Quit, a mic check or the menu may have changed during the open.
                if idleMacMicUID == uid, idleDemand.isOpen {
                    macMic = meter
                    Self.log.notice("Idle Mac mic open")
                } else {
                    await meter.close()
                }
            } catch {
                macMicFailure = (uid, nowNs)
                Self.log.notice("Idle Mac mic did not open: \(error.localizedDescription, privacy: .public)")
            }
        }
        refreshIdleMeterSources()
    }

    /// Runs a Mac mic pass now and waits, at most 3 s, until it is done: the idle Mac mic lets the
    /// mic go when the rules close it (Quit, a mic check that opens it itself, a take that records it).
    private func closeIdleMacMic() async {
        syncMacMic()
        let task = macMicTask
        _ = await Self.waitAtMost(.seconds(3)) { await task?.value }
    }

    /// Start: before a take that records the Mac mic in screen.mov, the idle Mac mic lets it go,
    /// and Start waits for that (its ScreenCaptureKit stream opens the same mic). A take without a
    /// screen mic (Camera mode) keeps the idle Mac mic, or opens it, without waiting: its meter is
    /// the detector's reference, so the silent-mic warning works in Camera mode too.
    private func settleMacMicForTake() async {
        if takeRecordsScreenMic == false { syncMacMic() } else { await closeIdleMacMic() }
    }

    /// Reads which idle meters run (lock-only reads), and follows them: the meters, the camera
    /// window's bar and the detector's banner.
    private func refreshIdleMeterSources() {
        let idle = state.canStart
        if !idle, takeRecordsScreenMic == false, let take = camera {
            // A take without a screen mic (Camera mode): its Mac mic meter is the idle Mac mic's.
            let sources = MeterSources.take(cameraAudio: take.config.audioDeviceUID != nil, screenMic: macMic?.isOpen == true,
                                            systemAudio: false)
            if sources != activeMeterSources {
                activeMeterSources = sources
                updateMeterTicker()
            }
        }
        let sources = IdleCaptureRules.idleMeterSources(cameraMeterOn: idle && warm?.recorder.idleMetersOn == true,
                                                        macMicOn: idle && macMic?.isOpen == true)
        guard sources != idleMeterSources else { return }
        idleMeterSources = sources
        applyDetector(levels.detectorStatus)
        updateMeterTicker()
    }

    /// A view shows the camera once nothing records: the mode records the camera, the app is not
    /// quitting, the camera window is on or the open menu shows the preview, and the screen can
    /// show it.
    private var previewWantedOnceIdle: Bool {
        !shuttingDown && settings.mode.includesCamera && screenCanShowCamera
            && ((menuVisible && settings.showCameraPreview) || settings.cameraWindowShown)
    }

    /// Opens the camera in its preview graph: the video input and the small preview output, and
    /// (decision 1) the camera audio input with the camera mic meter, so the meters and the mic
    /// warning run before Start. macOS then shows the orange microphone indicator next to the
    /// green camera one. Without microphone access the preview opens without the meter.
    private func openWarmCamera(_ target: PreviewTarget) async {
        let id = UUID()
        // Camera events arrive on the camera queue and come here with async, never sync.
        // The camera mic is metered into the levels by the idle meter, and from Start on by the take.
        let recorder = CameraRecorder(config: target.config, levels: levels) { [weak self] event in
            Task { @MainActor in self?.previewCameraEvent(event, id: id) }
        }
        previewFeed.resetStats()
        let feed = previewFeed
        let meters = idleCameraMeterWanted(audioDeviceUID: target.config.audioDeviceUID)
        let prepared = Task<OpenFailure?, Never> {
            do {
                try await recorder.openPreview(feed, meters: meters)
                return nil
            } catch {
                var retryable = true
                if case CameraRecorderError.noMatchingFormat = error { retryable = false }
                return OpenFailure(message: error.localizedDescription, retryable: retryable)
            }
        }
        let camera = WarmCamera(id: id, recorder: recorder, target: target, prepared: prepared)
        camera.meterRequest = (meters, HostClock.nowNs())
        warm = camera
        refreshPreviewPhase()
        // The camera may hang in startRunning: the pass (and with it every later one) must not wait
        // for it forever, or nothing would close the camera and the mics when the views go away.
        let outcome = await Self.waitAtMost(Self.prepareTimeout) { await prepared.value }
        guard warm === camera else { return }  // Start claimed it, or a newer pass replaced it.
        let failure = outcome ?? OpenFailure(
            message: "The camera did not open within \(Self.prepareTimeout.components.seconds) s.", retryable: true)
        if let failure {
            // Kept as the failed target. A failure that can pass (a device still settling) is
            // retried with a growing wait; a missing format waits for a new format list.
            camera.state = .failed(failure.message)
            camera.retryable = failure.retryable
            if failure.retryable {
                previewRetry = .next(after: previewRetry, target: target, reason: failure.message, nowNs: HostClock.nowNs())
            }
            if outcome == nil {
                // Still opening: released without waiting, as Start does with a camera that hangs.
                Task.detached { await recorder.teardown() }
            } else {
                await recorder.teardown()
            }
        } else {
            camera.state = .ready
            camera.readyAtNs = HostClock.nowNs()
            Self.log.notice("Preview camera open: \(recorder.negotiatedFormat ?? "?", privacy: .public), camera mic meter \(recorder.idleMetersOn ? "on" : "off", privacy: .public)")
        }
        refreshPreviewPhase()
    }

    /// Closes the preview camera. The session stops on its camera queue; this only awaits it.
    /// `warmClosing` tracks the close until it is done, so Start and Quit can wait for it too.
    private func closeWarmCamera() async {
        if let camera = warm {
            warm = nil
            previewFeed.clear()
            refreshPreviewPhase()
            let previous = warmClosing
            warmClosing = Task {
                await previous?.value
                _ = await camera.prepared.value
                // A reconnect that runs ends first, so it cannot open the camera after this close.
                await camera.recorder.waitForReconnect(atMost: Self.reconnectWait)
                await camera.recorder.teardown()
            }
        }
        await waitForWarmClose()
    }

    /// Waits for the preview camera that is closing, but at most `teardownTimeout`.
    private func waitForWarmClose() async {
        guard let closing = warmClosing else { return }
        _ = await Self.waitAtMost(Self.teardownTimeout) { await closing.value }
        if warmClosing == closing { warmClosing = nil }
    }

    /// An event from a preview camera or the take's camera, on the main actor. A preview camera
    /// closes at once; it opens again when the burst of device events is over and the camera is in
    /// the device list. The take's camera is marked, so it closes after the take.
    private func previewCameraEvent(_ event: CameraRecorder.Event, id: UUID) {
        deviceEventArrived()
        if id == takeCameraID { takeCameraBroken = true }
        guard let camera = warm, camera.id == id else { return }
        let reason: String
        switch event {
        case let .deviceDisconnected(name, _): reason = "\(name) was disconnected."
        case let .sessionError(message): reason = "Camera error: \(message)."
        case .sessionStopped: reason = "The camera stopped."
        case let .signalChanged(signal): reason = signal.map { "The camera signal changed to \($0)." } ?? "The camera lost its signal."
        }
        let hold: PreviewHold
        if case .deviceDisconnected(_, .cameraVideo) = event { hold = .disconnected } else { hold = .reopening(reason) }
        Self.log.notice("Preview camera event: \(String(describing: event), privacy: .public)")
        // One count per camera: a lost device often posts a disconnect, a stop and an error.
        if !camera.broken {
            previewRetry = .next(after: previewRetry, target: camera.target, reason: reason, nowNs: HostClock.nowNs())
        }
        camera.broken = true
        previewHold = (hold, deviceGeneration)
        previewFeed.clear()
        refreshPreviewPhase()
        Task { await updatePreview() }
    }

    /// Sets `preview` from the current state. Cheap: it reads no device and opens nothing.
    private func refreshPreviewPhase() {
        let showing = previewShowing
        let uid = showing ? makePlan().camera?.videoDeviceUID : nil
        var fresh = false
        var empty = false
        let nowNs = HostClock.nowNs()
        refreshCameraHealth()
        if let camera = warm, camera.state == .ready {
            let stats = previewFeed.stats()
            empty = stats.emptyFrames != nil
            fresh = PreviewRules.pictureIsFresh(lastFrameNs: stats.lastFrameHostNs, readySinceNs: camera.readyAtNs ?? 0,
                                                nowNs: nowNs)
            if previewRetry != nil, PreviewRules.cameraWorks(lastFrameNs: stats.lastFrameHostNs,
                                                             readySinceNs: camera.readyAtNs ?? nowNs, nowNs: nowNs) {
                previewRetry = nil
            }
            if !camera.loggedFrames, stats.frames > 0 {
                camera.loggedFrames = true
                Self.log.notice("Preview frames: \(stats.width)x\(stats.height) \(stats.pixelFormat ?? "?", privacy: .public)")
            }
        }
        let phase = PreviewRules.phase(PreviewInputs(
            showing: showing, blocked: previewBlocked, hasCamera: uid != nil,
            connected: uid.map { inventory.isConnected(videoUID: $0) } ?? false,
            hold: previewHold?.reason, camera: warm?.state, pictureFresh: fresh,
            retryReason: previewRetry.flatMap { nowNs < $0.notBeforeNs ? $0.reason : nil }, emptyFrames: empty))
        let inWindow = windowPhase(idle: phase, nowNs: nowNs)
        // Never leave a frozen frame on screen once the picture is not live.
        if (preview == .live && phase != .live) || (cameraWindowPhase == .live && inWindow != .live) {
            previewFeed.clear()
        }
        if phase != preview { preview = phase }
        if inWindow != cameraWindowPhase { cameraWindowPhase = inWindow }
        refreshIdleMeterSources()
    }

    /// The camera window's phase: the menu's preview while idle, the recording camera's picture
    /// while recording. Reads no device.
    private func windowPhase(idle idlePhase: PreviewPhase, nowNs: UInt64) -> PreviewPhase {
        guard cameraWindowWanted else { return .off }
        guard settings.mode.includesCamera else { return .blocked(PreviewRules.screenModeMessage) }
        let stage: RecordingStage
        switch state {
        case .idle, .error: return idlePhase
        case .preparing: stage = .starting
        case .recording: stage = .recording
        case .stopping: stage = .stopping
        }
        let stats = previewFeed.stats()
        return PreviewRules.recordingPhase(stage: stage,
                                           recordsCamera: PreviewRules.takeRecordsCamera(stage: stage, hasRecorder: camera != nil),
                                           previewKept: camera?.previewDuringRecording,
                                           lastFrameNs: stats.lastFrameHostNs,
                                           sinceNs: startPressedNs, nowNs: nowNs,
                                           emptyFrames: stats.emptyFrames != nil || camera?.emptyFrames != nil,
                                           livePictureOn: settings.previewWhileRecording)
    }

    // MARK: - Camera window

    /// The camera window is on, and the app is idle or it stays on while recording.
    var cameraWindowWanted: Bool {
        settings.cameraWindowShown && !shuttingDown
            && !PreviewRules.windowHiddenByTake(idle: state.canStart, keepWhileRecording: settings.cameraWindowWhileRecording)
    }

    /// Start keeps the camera's small preview output while camera.mov records: the camera window
    /// stays on while recording, and Live picture while recording is on.
    private var keepsLivePictureWhileRecording: Bool {
        settings.cameraWindowShown && settings.cameraWindowWhileRecording && settings.previewWhileRecording
    }

    /// The display that holds the recording frame, if the mode records the screen. The camera
    /// window opens on another display when there is one.
    var recordingFrameDisplayUUID: String? {
        if let plan = active?.screenPlan { return plan.display.uuid }
        return settings.mode.includesScreen ? resolvedDisplay()?.display.uuid : nil
    }

    /// The Camera window switch, the window's close button and its Hide item.
    func setCameraWindowShown(_ shown: Bool) {
        if settings.cameraWindowShown != shown {
            // Turning the window on tries the camera again at once, like opening the menu.
            if shown { previewRetry = nil }
            settings.cameraWindowShown = shown
        }
        if shown, PreviewRules.windowHiddenByTake(idle: state.canStart, keepWhileRecording: settings.cameraWindowWhileRecording) {
            notice = PreviewRules.windowHiddenWhileRecordingNotice
        }
        syncCameraWindow()
        refreshPreviewPhase()
        syncMacMic()
        Task { await updatePreview() }
    }

    /// The hotkey. While a take hides the window (Keep the camera window on while recording is
    /// off), it changes nothing it cannot show, so the saved switch never flips unseen; it says why.
    func toggleCameraWindow() {
        if PreviewRules.windowHiddenByTake(idle: state.canStart, keepWhileRecording: settings.cameraWindowWhileRecording) {
            notice = PreviewRules.windowHiddenWhileRecordingNotice
            return
        }
        setCameraWindowShown(!settings.cameraWindowShown)
    }

    /// "Keep the camera window on while recording" changed: show or hide the window now.
    func cameraWindowSettingsChanged() {
        syncCameraWindow()
        refreshPreviewPhase()
    }

    /// Shows or hides the camera window to match the setting and the state.
    private func syncCameraWindow() {
        if cameraWindowWanted { cameraWindow?.show() } else { cameraWindow?.hide() }
        updatePreviewTicker()
        updateMeterTicker()
    }

    private func stateChanged() {
        if state.canStart { takeRecordsScreenMic = nil }
        if state.canStart { takeHasPillWindow = false }
        syncCameraWindow()
        updateKeystrokes()
        refreshPreviewPhase()
        applyDetector(levels.detectorStatus)
        // At .stopping this logs replay_end before session_stop and lets go of the files.
        replay?.takeStateChanged(state)
    }

    // MARK: - Meters, mic check and camera health

    /// The meters run while a take records, a mic check runs, or idle meters run (decision 1:
    /// whenever the camera preview is on).
    private var metersRunning: Bool { state == .recording || micCheck != nil || (state.canStart && !idleMeterSources.isEmpty) }

    /// The sources with a meter now: the take's or the mic check's, else the idle meters.
    var meterSources: [AudioSource] { state.canStart && micCheck == nil ? idleMeterSources : activeMeterSources }

    /// The menu shows the meters under the Start button: while recording, and before recording
    /// while the idle meters run (a mic check shows its own).
    var menuShowsMeters: Bool {
        IdleCaptureRules.menuShowsMeters(recording: state == .recording, idle: state.canStart, checkRuns: micCheck != nil,
                                         sources: meterSources)
    }

    /// Polls the meters about 20 times a second while they run and the menu, or a camera window
    /// that shows the camera mic meter, is on screen; stops otherwise. A poll takes one lock
    /// (`AudioLevelMonitor.snapshot`). The detector's warning and beep do not need it: the 1 s
    /// recorder health check applies them too.
    private func updateMeterTicker() {
        let wanted = metersRunning && !shuttingDown
            && (menuVisible || (cameraWindowWanted && cameraWindowShowsMeter) || (controlBarWanted && controlBarShowsMeter))
        if !wanted, meters != nil { meters = nil }
        guard wanted != (meterTicker != nil) else { return }
        meterTicker?.cancel()
        meterTicker = nil
        guard wanted else { return }
        meterTicker = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollMeters()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func pollMeters() {
        let snapshot = levels.snapshot()
        if snapshot != meters { meters = snapshot }
        applyDetector(snapshot.detector)
    }

    /// Shows the detector's warning while a take records, a plain mic check runs (not while a
    /// calibration sample is taken: the external mic is unplugged on purpose), or, before
    /// recording, the camera mic meter runs; and beeps once when it comes on during a take (never
    /// while idle), never again until it has cleared. Pauses never warn: the detector counts
    /// voiced time only.
    private func applyDetector(_ status: MicDetectorStatus) {
        let watching = IdleCaptureRules.watchesDetector(recording: state == .recording, check: micCheck?.purpose,
                                                        idleCameraMeter: state.canStart && idleMeterSources.contains(.cameraMic))
        let alert = watching ? MicAlert(status) : nil
        if alert != micAlert { micAlert = alert }
        guard state == .recording else {
            micAlertOnset.reset()
            return
        }
        if micAlertOnset.update(alert != nil) {
            NSSound.beep()
            Self.log.notice("Camera mic warning: \(status.message ?? "", privacy: .public)")
        }
    }

    /// Reads the camera's USB link and picture trouble: the open camera's (lock-only reads), else
    /// the device list's USB link.
    private func refreshCameraHealth() {
        var health = CameraHealth()
        if settings.mode.includesCamera, let uid = settings.camera.resolve(automatic: { automatic.camera }) {
            let open = [camera, warm?.recorder].compactMap { $0 }.first { $0.config.videoDeviceUID == uid && $0.isOpen }
            if let open {
                health.usbProblem = open.usbProblem
                health.emptyFrames = open.emptyFrames
                health.pictureProblem = open.pictureProblem
            } else {
                health.usbProblem = inventory.usbProblem(forVideoUID: uid)
            }
        }
        if health != cameraHealth { cameraHealth = health }
    }

    /// The banners for the menu and the camera window, most urgent first.
    var alerts: [CaptureAlert] {
        CaptureAlerts.list(mic: micAlert, health: cameraHealth, idle: state.canStart)
    }

    /// The menu bar icon turns orange: a file has a problem, the camera mic warns, or the camera
    /// has trouble.
    var needsAttention: Bool { trackLines.contains(where: \.isProblem) || !alerts.isEmpty }

    /// The camera window shows the camera mic meter.
    var cameraWindowShowsMeter: Bool { metersRunning && meterSources.contains(.cameraMic) }

    /// The control bar shows the Mac mic meter: whenever the meters run with a Mac mic (the idle
    /// meters while the camera preview is on, a take, a mic check).
    var controlBarShowsMeter: Bool { metersRunning && meterSources.contains(.screenMic) }

    /// The camera audio and the Mac mic a mic check opens: the picks, in every mode.
    private var micCheckDevices: (cameraAudio: String?, screenMic: String?) {
        let cameraAudio = settings.camera.resolve(automatic: { automatic.camera }) == nil
            ? nil : settings.cameraAudio.resolve { automatic.cameraAudio }
        return (cameraAudio, settings.screenMic.resolve { automatic.screenMic })
    }

    /// Why Mic check cannot start now, or nil when it can.
    var micCheckUnavailableReason: String? {
        if !state.canStart { return "Mic check runs only while nothing records." }
        if micCheck != nil { return "A mic check runs already." }
        if micCheckDevices.cameraAudio == nil { return "Pick the camera audio under Camera > Audio first." }
        return nil
    }

    /// Runs the 10 s mic check (or a calibration sample): the meters and the detector run on the
    /// camera mic and the Mac mic; the camera picture is not touched. No device is ever held twice:
    /// - While the camera preview is on (the idle capture is wanted), the check samples the idle
    ///   meters (`MicCheck(live:)`) and opens nothing; the idle capture stays open until it ends. A
    ///   source that does not deliver within `IdleCaptureRules.liveCheckWait` gets its own session.
    /// - Otherwise it opens the camera audio and the Mac mic in their own audio-only sessions for
    ///   the 10 s (the orange microphone indicator shows only then), and the idle path lets those
    ///   devices go first and leaves them closed until the check ends.
    func startMicCheck(_ purpose: MicCheckPurpose = .check) {
        if let reason = micCheckUnavailableReason {
            notice = reason
            return
        }
        let devices = micCheckDevices
        let plan = IdleCaptureRules.checkSources(cameraAudio: devices.cameraAudio != nil, screenMic: devices.screenMic != nil,
                                                 idleCaptureWanted: idleCaptureWantedNow, micAllowed: micAllowed)
        let id = UUID()
        micCheckID = id
        // Set before anything awaits, so no idle meter opens on a device the check opens itself.
        checkOwnSources = plan.own
        checkUsesIdleMeters = !plan.live.isEmpty
        activeMeterSources = MeterSources.check(cameraAudio: devices.cameraAudio != nil, screenMic: devices.screenMic != nil)
        micCheck = MicCheckProgress(purpose: purpose, startedAt: Date(), seconds: MicCheck.defaultSeconds)
        // The replay plays muted until the check ends: the check hears the speaker, not the speakers.
        replay?.micCheckChanged(running: true)
        if purpose == .check { micCheckOutcome = nil }
        let flowID = purpose.isCalibration ? calibrationFlow?.id : nil
        micCheckWindowNote = nil
        updateMeterTicker()
        Self.log.notice("Mic check started (\(String(describing: purpose), privacy: .public)), from the idle meters: \(plan.live.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public)")
        micCheckTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runMicCheck(id: id, devices: devices, plan: plan)
            self.micCheckEnded(outcome, purpose: purpose, id: id, flowID: flowID)
        }
    }

    /// The check itself: waits for the idle meters it samples, lets go of the idle meters on the
    /// devices it opens, then runs `MicCheck`.
    private func runMicCheck(id: UUID, devices: (cameraAudio: String?, screenMic: String?),
                             plan expected: (live: Set<AudioSource>, own: Set<AudioSource>)) async -> MicCheckOutcome {
        var plan = expected
        if !plan.live.isEmpty {
            // The camera may still be opening: the check samples the meters once they run.
            await waitForIdleMeters(plan.live, atMost: IdleCaptureRules.liveCheckWait)
            plan = IdleCaptureRules.settle(expectedLive: plan.live, delivering: Set(idleMeterSources), own: plan.own)
            checkOwnSources = plan.own
            checkUsesIdleMeters = !plan.live.isEmpty
        }
        if micCheckActive(id), !plan.own.isEmpty { await releaseIdleMeters(plan.own) }
        // Cancelled, or Start runs a take by now: the check opens nothing.
        guard micCheckActive(id) else {
            return MicCheckOutcome(status: levels.detectorStatus, sample: MicFeatureSample(), cameraMicOpened: false,
                                   screenMicOpened: false, cancelled: true, errors: [])
        }
        let check = MicCheck(cameraAudioUID: devices.cameraAudio, screenMicUID: devices.screenMic, levels: levels, live: plan.live)
        runningCheck = check
        // A check that samples live meters keeps their levels; its detector starts over in `run`.
        if plan.live.isEmpty { levels.reset() }
        micCheck?.startedAt = Date()
        // Its own task, so a cancel always reaches it, also before the check armed its signal.
        let run = Task { await check.run() }
        micCheckRun = run
        return MicCheckOutcome(await run.value)
    }

    /// The check `id` is the running one, it was not cancelled, and nothing records.
    private func micCheckActive(_ id: UUID) -> Bool {
        micCheckID == id && micCheck?.cancelling != true && state.canStart
    }

    /// Waits, at most `limit`, until the idle meters of `sources` run. Lock-only reads.
    private func waitForIdleMeters(_ sources: Set<AudioSource>, atMost limit: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline, micCheck?.cancelling != true, state.canStart {
            refreshIdleMeterSources()
            if sources.isSubset(of: Set(idleMeterSources)) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The idle path lets go of the devices a mic check opens itself: the camera mic meter leaves
    /// the preview graph (once a camera that is opening has opened), and the idle Mac mic closes.
    /// `checkOwnSources` already keeps them from opening again.
    private func releaseIdleMeters(_ sources: Set<AudioSource>) async {
        if sources.contains(.cameraMic), let camera = warm {
            let prepared = camera.prepared
            _ = await Self.waitAtMost(.seconds(5)) { await prepared.value }
            // Always asked (a graph without the meter does not change), so a camera that opened
            // with its meter meanwhile lets it go too. A camera opened after this has none.
            camera.meterRequest = (false, HostClock.nowNs())
            let recorder = camera.recorder
            _ = await Self.waitAtMost(Self.meterChangeTimeout) { _ = try? await recorder.setIdleMeters(false) }
        }
        if sources.contains(.screenMic) { await closeIdleMacMic() }
        refreshIdleMeterSources()
    }

    /// Ends the running mic check now. Only fires a signal: the check closes its mics on its queue.
    func cancelMicCheck() {
        guard micCheck != nil else { return }
        micCheck?.cancelling = true
        runningCheck?.cancel()
        micCheckRun?.cancel()
    }

    /// Cancels a running mic check and waits, at most 3 s, until its mics have closed.
    private func endMicCheck() async {
        guard let task = micCheckTask else { return }
        cancelMicCheck()
        _ = await Self.waitAtMost(.seconds(3)) { await task.value }
    }

    private func micCheckEnded(_ outcome: MicCheckOutcome, purpose: MicCheckPurpose, id: UUID, flowID: UUID?) {
        guard micCheckID == id else { return }
        micCheckID = nil
        runningCheck = nil
        micCheckRun = nil
        micCheckTask = nil
        micCheck = nil
        replay?.micCheckChanged(running: false)
        checkOwnSources = []
        checkUsesIdleMeters = false
        // A take that starts sets its own sources.
        if state.canStart { activeMeterSources = [] }
        switch purpose {
        case .check:
            micCheckOutcome = outcome
            expireMicCheckOutcome(outcome)
            showMicCheckWindowNote(MicStatusText.outcome(outcome))
        case .calibratePlugged, .calibrateUnplugged:
            // Only into the flow that asked for it (not one started over meanwhile).
            if let flowID, calibrationFlow?.id == flowID { calibrationFlow?.record(outcome, for: purpose) }
        }
        applyDetector(levels.detectorStatus)
        updateMeterTicker()
        Self.log.notice("Mic check ended: \(outcome.status.verdict.rawValue, privacy: .public), \(outcome.sample.cameraVoicedSeconds, format: .fixed(precision: 1)) s of camera voice, \(outcome.sample.referenceVoicedSeconds, format: .fixed(precision: 1)) s of Mac mic voice, problem \(outcome.sample.problem?.rawValue ?? "none", privacy: .public), cancelled \(outcome.cancelled), from the idle meters: \(outcome.liveSources.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public)")
        // The idle meters follow the rules again (a camera mic meter the check held off comes back),
        // and the idle capture closes if nothing shows the camera.
        Task { await updatePreview() }
    }

    /// The check's result on the camera window, for 8 s.
    private func showMicCheckWindowNote(_ text: MicText) {
        micCheckWindowNote = text
        micCheckNoteTask?.cancel()
        micCheckNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.micCheckWindowNote = nil
        }
    }

    func dismissMicCheckOutcome() { micCheckOutcome = nil }

    /// A mic check's result shows in the menu this long at most.
    static let micCheckOutcomeLifetime: Duration = .seconds(300)

    /// Clears `outcome` after `micCheckOutcomeLifetime`, unless a newer one replaced it.
    private func expireMicCheckOutcome(_ outcome: MicCheckOutcome) {
        micCheckOutcomeTask?.cancel()
        micCheckOutcomeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.micCheckOutcomeLifetime)
            guard !Task.isCancelled, let self, self.micCheckOutcome == outcome else { return }
            self.micCheckOutcome = nil
        }
    }

    // MARK: Calibration

    /// Opens "Calibrate mic warning…" at its first step.
    func beginCalibration() {
        guard state.canStart else { return }
        calibrationFlow = MicCalibrationFlow()
    }

    /// Records the current step's sample: a 10 s mic check.
    func recordCalibrationSample() {
        guard let purpose = calibrationFlow?.purpose else { return }
        calibrationFlow?.error = nil
        startMicCheck(purpose)
    }

    func restartCalibration() {
        if micCheck?.purpose.isCalibration == true { cancelMicCheck() }
        calibrationFlow = MicCalibrationFlow()
    }

    func cancelCalibration() {
        if micCheck?.purpose.isCalibration == true { cancelMicCheck() }
        calibrationFlow = nil
    }

    /// Saves the reviewed calibration (JSON in the settings) and uses it from now on.
    func saveCalibration() {
        guard let calibration = calibrationFlow?.calibration else { return }
        settings.micCalibration = calibration
        levels.setCalibration(calibration)
        calibrationFlow = nil
        notice = "Saved the mic warning calibration."
        Self.log.notice("Mic calibration saved: \(MicCalibrationText.rules(calibration).joined(separator: " | "), privacy: .public)")
    }

    /// Back to the default rule (camera L/R correlation below `MicFeatureRule.defaultCorrelation`, 0.88).
    func resetCalibration() {
        settings.micCalibration = nil
        levels.setCalibration(nil)
        notice = "The mic warning uses the default rule again."
    }

    // MARK: Reconnect

    /// Reconnect camera may run: nothing records, the mode records the camera, and no reconnect runs.
    var canReconnectCamera: Bool { state.canStart && settings.mode.includesCamera && !cameraReconnecting }

    /// Closes the idle preview camera and opens it again, on the camera queue: what a USB replug
    /// does for a Cam Link that sends empty frames, short of the replug. With no open camera, it
    /// opens one now, without the retry wait.
    func reconnectCamera() {
        guard canReconnectCamera else { return }
        guard let camera = warm, camera.state == .ready, !camera.broken else {
            previewRetry = nil
            Task { await updatePreview() }
            return
        }
        cameraReconnecting = true
        notice = nil
        Self.log.notice("Reconnect camera")
        let recorder = camera.recorder
        Task { [weak self] in
            // The camera may hang in stopRunning or startRunning: the prepare limit applies here too.
            let outcome = await Self.waitAtMost(Self.prepareTimeout) { () async -> Result<Void, any Error> in
                do { return .success(try await recorder.reconnect()) } catch { return .failure(error) }
            }
            switch outcome {
            case .success?: self?.cameraReconnected(camera, error: nil)
            case let .failure(error)?: self?.cameraReconnected(camera, error: error)
            case nil: self?.cameraReconnectTimedOut(camera)
            }
        }
    }

    /// The reconnect did not finish within `prepareTimeout`: Reconnect works again, and the hung
    /// camera is let go without waiting (its queue may never answer), like a camera that hangs while
    /// it opens. The preview opens a new one once a fresh device list is in.
    private func cameraReconnectTimedOut(_ camera: WarmCamera) {
        cameraReconnecting = false
        defer { refreshPreviewPhase() }
        Self.log.error("Reconnect did not finish within \(Self.prepareTimeout.components.seconds) s")
        // Start claimed it meanwhile (and released it), or the preview closed or replaced it.
        guard warm === camera else { return }
        notice = "The camera did not reopen. Unplug it and plug it back in."
        camera.broken = true
        warm = nil
        previewFeed.clear()
        let recorder = camera.recorder
        Task.detached { await recorder.teardown() }
        previewRetry = nil
        previewHold = (.reopening("The camera did not reopen."), deviceGeneration)
        deviceEventArrived()
        Task { await updatePreview() }
    }

    private func cameraReconnected(_ camera: WarmCamera, error: (any Error)?) {
        cameraReconnecting = false
        defer { refreshPreviewPhase() }
        // Start claimed it, or the preview closed or replaced it meanwhile.
        guard warm === camera else { return }
        guard let error else {
            // The new session counts its first frame from now.
            camera.readyAtNs = HostClock.nowNs()
            notice = "Camera reopened."
            return
        }
        if case CameraRecorderError.busy = error {
            notice = error.localizedDescription
            return
        }
        // The camera stayed closed: close it like a camera that reported trouble, and open it
        // again once a fresh device list is in.
        Self.log.notice("Reconnect failed: \(error.localizedDescription, privacy: .public)")
        camera.broken = true
        previewRetry = nil
        previewHold = (.reopening("The camera did not reopen."), deviceGeneration)
        deviceEventArrived()
        Task { await updatePreview() }
    }

    // MARK: - Control bar

    /// The control bar shows while TwinTake runs, idle and recording, unless it is turned off.
    private var controlBarWanted: Bool { settings.showControlBar && !shuttingDown }

    /// Shows or hides the control bar to match the setting.
    private func syncControlBar() {
        if controlBarWanted { controlBar?.show() } else { controlBar?.hide() }
        updateMeterTicker()
        updateControlBarPreflightTicker()
    }

    /// How often preflight runs for the bar's Record button while the menu is closed.
    static let controlBarPreflightInterval: Duration = .seconds(5)

    private func updateControlBarPreflightTicker() {
        guard controlBarWanted != (controlBarPreflightTicker != nil) else { return }
        controlBarPreflightTicker?.cancel()
        controlBarPreflightTicker = nil
        guard controlBarWanted else { return }
        controlBarPreflightTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.controlBarPreflightInterval)
                guard let self, !Task.isCancelled else { return }
                if self.state.canStart, !self.menuVisible, self.screenCanShowCamera { await self.refreshPreflight() }
            }
        }
    }

    /// "Show control bar" in the menu, and Hide Control Bar on the bar's own menu.
    func setControlBarShown(_ shown: Bool) {
        if settings.showControlBar != shown { settings.showControlBar = shown }
        syncControlBar()
    }

    /// Puts the control bar back at its default place: in the strip above the frame.
    func resetControlBarPosition() { controlBar?.resetPosition() }

    /// Where the control bar opens by default: the display Start records, its frame in AppKit
    /// coordinates, and the strip right above the frame to leave free (the Parallels toolbar,
    /// while "Hide the Parallels toolbar" is on).
    var controlBarFrameHint: (displayUUID: String, frame: CGRect, reservedAbovePt: CGFloat)? {
        let plan = active?.screenPlan
        guard let display = plan?.display ?? resolvedDisplay()?.display else { return nil }
        let preset = plan?.preset ?? resolvedPreset(for: display)
        let global = plan?.frameGlobal ?? display.globalFrameRect(for: preset, anchor: settings.frameAnchor(for: display))
        let frame = FrameGeometry.appKitRect(fromGlobal: global, mainDisplayHeight: Displays.mainDisplayHeight)
        let reserved = settings.hideParallelsToolbar ? SnapProfile.parallelsDesktop.fallbackToolbarHeightPt : 0
        return (display.uuid, frame, reserved)
    }

    /// Why the Record button is orange: a file with a problem, else the first banner (the camera
    /// mic warning, the camera's trouble).
    var attentionText: String? {
        if let line = trackLines.first(where: \.isProblem) { return "\(line.title): \(line.status)." }
        return alerts.first?.title
    }

    /// The app "+" would pin now (`PinnedApps.pinCandidate`).
    func pinCandidate() -> PinnedApp? {
        let front = NSWorkspace.shared.frontmostApplication.flatMap { WindowOwner.running(pid: $0.processIdentifier) }
        let recent = snapper.activations.recentPIDs.compactMap { WindowOwner.running(pid: $0) }
        return PinnedApps.pinCandidate(front: front, recent: recent,
                                       excludedBundleIDs: Set(SessionRules.excludedBundleIDs(mainBundleID: ownBundleID)))
    }

    /// "+" on the control bar: pins the app that was in front before the click (the bar never
    /// takes the focus), at the end of the bar.
    func pinFrontApp() {
        guard let app = pinCandidate() else {
            flashControlBar("Click an app first, then +", tone: .problem)
            notice = "Click the app you want to pin, then click + on the control bar."
            return
        }
        let (list, outcome) = PinnedApps.adding(app, to: settings.pinnedApps)
        switch outcome {
        case .added:
            settings.pinnedApps = list
            flashControlBar("Pinned \(app.shortName)", tone: .good)
            Self.log.notice("Pinned \(app.bundleID, privacy: .public)")
        case .alreadyPinned:
            flashControlBar("\(app.shortName) is pinned", tone: .neutral)
        case .full:
            flashControlBar("\(PinnedApps.maxCount) apps pinned: remove one", tone: .problem)
            notice = "The control bar holds \(PinnedApps.maxCount) apps. Remove one (right-click it), then pin again."
        }
    }

    func removePinnedApp(_ app: PinnedApp) {
        settings.pinnedApps = PinnedApps.removing(app.bundleID, from: settings.pinnedApps)
    }

    /// Moves a pinned app `offset` places (-1: to the left).
    func movePinnedApp(_ app: PinnedApp, by offset: Int) {
        settings.pinnedApps = PinnedApps.moving(app.bundleID, by: offset, in: settings.pinnedApps)
    }

    /// A pinned app's button: brings the app forward (it opens the app when it is not running),
    /// waits until it is the front app, then snaps its front window into the frame with the app's
    /// profile, like Snap (in Camera mode there is no frame: it only switches). An app that does
    /// not come forward is not snapped (the bar says so). A newer click wins over one that still
    /// waits.
    func switchToPinnedApp(_ app: PinnedApp) {
        let id = UUID()
        pinnedSwitchID = id
        Task { await runPinnedSwitch(app, id: id) }
    }

    private func runPinnedSwitch(_ app: PinnedApp, id: UUID) async {
        // The front app at the click: the bar never takes the focus, so it is the app the user
        // worked in. The pinned app came forward when the front app changed to it.
        let before = NSWorkspace.shared.frontmostApplication.flatMap { WindowOwner.running(pid: $0.processIdentifier) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .filter { !$0.isTerminated }
            .sorted { ($0.activationPolicy == .regular ? 0 : 1) < ($1.activationPolicy == .regular ? 0 : 1) }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        var launched = false
        var accepted = true
        if let target = running.first {
            // TwinTake is rarely the active app (the bar does not activate it); when it is, it
            // hands the activation over (macOS 14 cooperative activation).
            NSApp.yieldActivation(to: target)
            // False: macOS turned the request down at once, so the Launch Services open below
            // comes without the full wait.
            accepted = target.activate(options: [])
        } else {
            guard let url else {
                flashControlBar("\(app.shortName) is not installed", tone: .problem)
                notice = "\(app.name) is not installed. Right-click its button on the control bar to remove it."
                return
            }
            flashControlBar("Opening \(app.shortName)…", tone: .neutral)
            notice = "\(app.name) was not running. Opening it…"
            guard await Self.openApplication(at: url) else {
                flashControlBar("\(app.shortName) did not open", tone: .problem)
                notice = "\(app.name) did not open."
                return
            }
            launched = true
        }
        let firstWait: Duration = launched ? .seconds(10) : accepted ? .seconds(1) : .milliseconds(250)
        var front = await waitUntilFrontmost(app, before: before, atMost: firstWait)
        if !front, !launched, let url, pinnedSwitchID == id {
            // macOS did not let the activation through: open it like a click on its Dock icon.
            Self.log.notice("\(app.bundleID, privacy: .public) did not come forward (activate \(accepted ? "accepted" : "refused", privacy: .public)); opening it through Launch Services")
            _ = await Self.openApplication(at: url)
            front = await waitUntilFrontmost(app, before: before, atMost: .seconds(2))
        }
        guard pinnedSwitchID == id else { return }
        if !front {
            let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard SnapTargetFinder.isSameApp(bundleID: frontID, as: app.bundleID) else {
                // Never a snap without the switch: the window would cover the frame while the
                // keyboard stays with the other app.
                pinnedAppDidNotComeForward(app, frontID: frontID)
                return
            }
            // The app was in front at the click already (Parallels Desktop, then the "Windows 11"
            // button) and keeps the keyboard: the snap raises the window.
            Self.log.notice("\(app.bundleID, privacy: .public): the front process did not change; \(frontID ?? "?", privacy: .public) is the same app, snapping")
        }

        // Camera mode has no frame: the switch is all.
        guard let plan = active?.screenPlan ?? makePlan().screen else { return }
        guard snapper.isTrusted else {
            flashControlBar("Accessibility is off", tone: .problem)
            notice = "Accessibility is off, so \(app.name) was not snapped. Allow it under Permissions."
            return
        }
        if launched {
            await waitForWindow(of: app, plan: plan, atMost: .seconds(8))
        } else if await !waitForWindow(of: app, plan: plan, atMost: .milliseconds(1500)), let url, pinnedSwitchID == id {
            // Still no window on screen: it is on another Space (macOS switches there), or
            // minimized. A Dock click's open shows or restores one.
            Self.log.notice("\(app.bundleID, privacy: .public) shows no window; opening it through Launch Services")
            _ = await Self.openApplication(at: url)
            await waitForWindow(of: app, plan: plan, atMost: .seconds(2))
        }
        // A take that is starting snaps the front window itself at Start. This snap waits until the
        // take records (or the start ended), so it is logged, adopted and watched like any snap
        // during the take, never moved unseen while session.json names the Start window.
        if state == .preparing {
            let clock = ContinuousClock()
            let deadline = clock.now + Self.prepareTimeout + Self.startTimeout
            while state == .preparing, pinnedSwitchID == id, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard pinnedSwitchID == id, let snapPlan = active?.screenPlan ?? makePlan().screen else { return }
        let snap = performSnap(into: snapPlan, app: app)
        applySnap(snap, plan: snapPlan)
        if !snap.success {
            flashControlBar(snap.failure == .noAppWindow ? "\(app.shortName): no window" : "\(app.shortName) not snapped",
                            tone: .problem)
        } else if launched {
            controlBarFlash = nil
        }
    }

    /// The pinned app stayed behind the front app: says so on the bar and in the menu, and
    /// during a take logs a `warning` (`source` `control_bar`), so the editor knows the switch
    /// did not happen.
    private func pinnedAppDidNotComeForward(_ app: PinnedApp, frontID: String?) {
        Self.log.notice("\(app.bundleID, privacy: .public) did not come forward (\(frontID ?? "no app", privacy: .public) is in front); not snapped")
        flashControlBar("\(app.shortName) not in front", tone: .problem)
        let message = "macOS did not bring \(app.name) forward, so its window was not snapped."
        notice = "\(message) Click its window or its Dock icon, then click its button again."
        if state == .recording, let session = active {
            var data = ["source": "control_bar", "bundle_id": app.bundleID, "message": message]
            data["front_bundle_id"] = frontID
            session.events.append(.warning, data)
        }
    }

    /// Waits until `app` came forward (`SnapTargetFinder.cameForward`): it is the front app, or
    /// another of its processes became the front app (Parallels Desktop for the "Windows 11"
    /// Dock helper). `before`: the front app at the click.
    private func waitUntilFrontmost(_ app: PinnedApp, before: WindowOwner?, atMost limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            let front = NSWorkspace.shared.frontmostApplication.flatMap { WindowOwner.running(pid: $0.processIdentifier) }
            if SnapTargetFinder.cameForward(front: front, before: before, pinnedBundleID: app.bundleID) { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits until `app` shows a window that can be snapped (window list only). True when it does.
    @discardableResult
    private func waitForWindow(of app: PinnedApp, plan: ScreenPlan, atMost limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            let targets = snapper.appTargets(bundleID: app.bundleID, appName: app.name, for: plan.snapTarget,
                                             excludingBundleID: ownBundleID, display: plan.display)
            if !targets.candidates.isEmpty { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Opens (or brings forward) the app at `url` through Launch Services, like a Dock click.
    private static func openApplication(at url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// Shows `text` on the control bar for `ControlBarFlash.lifetime`.
    private func flashControlBar(_ text: String, tone: ControlBarRules.Tone) {
        let flash = ControlBarFlash(text: text, tone: tone)
        controlBarFlash = flash
        controlBarFlashTask?.cancel()
        controlBarFlashTask = Task { [weak self] in
            try? await Task.sleep(for: ControlBarFlash.lifetime)
            guard !Task.isCancelled, let self, self.controlBarFlash == flash else { return }
            self.controlBarFlash = nil
        }
    }

    // MARK: - Replay

    /// What Replay opens now: the take that records, or the last take.
    var replayTarget: ReplayRules.Target {
        ReplayRules.target(state: state, activeFolder: active?.folder.url, lastFolder: lastSession?.folder)
    }

    /// The Replay buttons (control bar, menu) and ⌃⌥⌘P: open the replay window, or close it.
    /// Closing it never stops the recording.
    func toggleReplay() {
        guard let replay else { return }
        if replay.isShown {
            replay.close()
            return
        }
        switch replayTarget {
        case let .live(folder):
            replay.show(ReplaySource(folder: folder, live: true))
        case let .last(folder):
            replay.show(ReplaySource(folder: folder, live: false))
        case let .none(reason):
            notice = reason
            flashControlBar(reason, tone: .neutral)
        }
    }

    /// The replay window opened or closed.
    func replayShownChanged(_ shown: Bool) {
        if replayShown != shown { replayShown = shown }
    }

    /// Take time now (seconds since session.json `started_at_host_ns`, like a flag's `elapsed_s`)
    /// while a take records or saves.
    var takeElapsedS: Double? {
        guard let start = active?.manifest.startedAtHostNs else { return nil }
        return ControlBarRules.secondsSince(start, nowNs: HostClock.nowNs())
    }

    /// The replay's `replay_start`, `replay_end` and `replay_sound` in the take's events.jsonl.
    func logReplay(_ kind: SessionEvent.Kind, _ data: [String: String]) {
        guard let session = active else { return }
        session.events.append(kind, data)
        Self.log.notice("Replay \(kind.rawValue, privacy: .public) at \(data["elapsed_s"] ?? "?", privacy: .public) s")
    }

    // MARK: - Keystrokes

    /// Shows or hides the keystroke pill and runs or stops its key monitor, for the Keystrokes
    /// setting and the take, over the frame Start records (or the take records).
    func updateKeystrokes() {
        let recording = state == .recording
        let mode = settings.keystrokeMode
        keystrokes?.update(
            show: !shuttingDown && KeystrokeRules.showsKeystrokes(mode, recording: recording),
            orderedIn: !shuttingDown && KeystrokeRules.hudOrderedIn(mode: mode, recording: recording, takeActive: !state.canStart,
                                                                    takeHasPillWindow: takeHasPillWindow),
            frameGlobal: keystrokeFrameGlobal)
    }

    /// The menu's note while another app keeps secure keyboard entry on (`KeystrokeController`).
    func setKeystrokeSecureInputNote(_ note: String?) {
        if note != keystrokeSecureInputNote { keystrokeSecureInputNote = note }
    }

    /// The key source for the menu (`KeystrokeController`): the tap proved itself, and the relaunch note.
    func setKeystrokeTap(proven: Bool, note: String?) {
        if proven != keystrokeTapProven { keystrokeTapProven = proven }
        if note != keystrokeTapNote { keystrokeTapNote = note }
    }

    /// The frame the pill sits in: the take's frame (at its display's place now; nil while that
    /// display is gone), else the frame Start would record. Also in Camera mode, on the display
    /// Start would record. During a take it never moves to another display, so the screen
    /// stream's filter, built at prepare, keeps showing the pill.
    private var keystrokeFrameGlobal: CGRect? {
        if let plan = active?.screenPlan {
            guard let display = displays.first(where: { $0.id == plan.display.id }) else { return nil }
            return FrameGeometry.globalRect(fromLocal: plan.config.frameRectPt, displayBoundsGlobal: display.boundsGlobal)
        }
        guard let display = resolvedDisplay()?.display else { return nil }
        return display.globalFrameRect(for: resolvedPreset(for: display), anchor: settings.frameAnchor(for: display))
    }

    /// A pill the take showed: a `keystroke` event, only while recording.
    func logKeystroke(label: String, macLabel: String, count: Int) {
        guard state == .recording, let session = active, let elapsed = takeElapsedS, elapsed >= 0 else { return }
        session.events.append(.keystroke, KeystrokeRules.eventData(label: label, macLabel: macLabel, count: count,
                                                                   elapsedS: elapsed))
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        for action in HotKeyAction.allCases {
            do {
                try hotKeys.register(action) { [weak self] in self?.handle(action) }
                hotKeyErrors[action] = nil
            } catch {
                hotKeyErrors[action] = error.localizedDescription
            }
        }
    }

    private func handle(_ action: HotKeyAction) {
        // Its modifiers (⌃⌥⌘) put no pill on screen or in screen.mov.
        keystrokes?.hotKeyPressed()
        switch action {
        case .startStop: toggleRecording()
        case .snapWindow: snapNow()
        case .flag: flag()
        case .cameraWindow: toggleCameraWindow()
        case .replay: toggleReplay()
        }
    }

    // MARK: - Status lines

    /// Ticks once a second while recording: the elapsed time, the recorders' health, and every
    /// few seconds the free disk space.
    private func startClock() {
        clockTicker?.cancel()
        clockTicker = Task { [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.now = Date()
                self.checkRecorderHealth()
                seconds += 1
                if seconds % Self.diskCheckEverySeconds == 0 { await self.checkDiskSpace() }
            }
        }
    }

    /// Shows a file that ended early or a camera with no picture: the status line, the menu bar
    /// icon, a notice, a beep and an event. Neither recorder can tell the app any other way.
    private func checkRecorderHealth() {
        guard state == .recording, let session = active else { return }
        // Read every second, so the warning and its beep come also with the menu and window closed.
        applyDetector(levels.detectorStatus)
        refreshCameraHealth()
        let reports: [(id: String, title: String, problem: String?)] = [
            ("camera", "Camera", camera?.recordingProblem), ("screen", "Screen", screen?.recordingProblem),
        ]
        var changed = false
        for report in reports where recorderProblems[report.id] != report.problem {
            recorderProblems[report.id] = report.problem
            changed = true
            if let problem = report.problem {
                session.events.append(.error, ["source": "app", "track": report.id, "message": "\(report.title): \(problem)"])
                notice = "\(report.title): \(problem)"
                NSSound.beep()
                Self.log.error("\(report.title, privacy: .public): \(problem, privacy: .public)")
            } else {
                session.events.append(.warning, ["source": "app", "track": report.id, "message": "\(report.title) is recording normally again."])
            }
        }
        if changed { updateLines("recording") }
    }

    /// Warns when about two minutes of space are left, and stops both recorders at
    /// `SessionRules.recordingStopBytes`, before camera.mov stops at its own limit and screen.mov
    /// runs the disk full.
    private func checkDiskSpace() async {
        guard state == .recording, let session = active else { return }
        let url = session.folder.url
        let free = await Task.detached { SessionFolder.conservativeFreeSpace(at: url) }.value
        guard state == .recording, active === session, let free else { return }
        switch SessionRules.diskAction(freeBytes: free, bytesPerSecond: session.bytesPerSecond) {
        case .none:
            break
        case let .warn(minutes):
            guard !session.diskWarned else { return }
            session.diskWarned = true
            let message = "The recording disk is almost full: about \(minutes) min left. "
                + "Recording stops by itself at \(SessionRules.gigabytes(SessionRules.recordingStopBytes)) free."
            session.events.append(.warning, ["source": "app", "message": message, "free_bytes": String(free)])
            notice = message
            NSSound.beep()
        case .stop:
            let message = "Stopped at \(SessionRules.gigabytes(free)) free on the recording disk, so both files could finish."
            session.events.append(.error, ["source": "app", "message": message, "free_bytes": String(free)])
            session.manifest.errors.append(message)
            notice = message
            NSSound.beep()
            // Its own task: Stop cancels this clock, which must not cut the stop short.
            requestStop()
        }
    }

    private func updateLines(_ status: String) {
        var lines: [TrackStatusLine] = []
        if let config = camera?.config {
            let format = camera?.negotiatedFormat.map(SessionRules.shortFormat)
                ?? camera?.signal.map { "\($0.width)×\($0.height) \($0.frameRate.label)" }
                ?? "\(config.expectedWidth)×\(config.expectedHeight) \(config.expectedFrameRate.label)"
            let problem = recorderProblems["camera"] ?? lineProblems["camera"]
            lines.append(TrackStatusLine(id: "camera", title: "Camera", format: format, status: problem ?? status,
                                         isProblem: problem != nil))
        }
        if let config = screen?.config {
            var format = "\(config.outputPx.width)×\(config.outputPx.height) \(config.frameRate.label)"
            if config.windowID != nil { format += " (window)" }
            let problem = recorderProblems["screen"] ?? lineProblems["screen"]
            lines.append(TrackStatusLine(id: "screen", title: "Screen", format: format, status: problem ?? status,
                                         isProblem: problem != nil))
        }
        if lines != trackLines { trackLines = lines }
    }

    /// Marks a status line when a device it records goes away during a recording.
    private func checkLiveDevices() {
        guard state == .recording else { return }
        let videoUIDs = Set(videoDevices.map(\.uid)), audioUIDs = Set(audioDevices.map(\.uid))
        if let config = camera?.config {
            if !videoUIDs.contains(config.videoDeviceUID) {
                lineProblems["camera"] = "camera disconnected"
            } else if let audio = config.audioDeviceUID, !audioUIDs.contains(audio) {
                lineProblems["camera"] = "camera audio disconnected"
            }
        }
        if let config = screen?.config {
            if !displays.contains(where: { $0.id == config.displayID }) {
                lineProblems["screen"] = "display disconnected"
            } else if let mic = config.micDeviceUID, !audioUIDs.contains(mic) {
                lineProblems["screen"] = "mic disconnected"
            } else if lineProblems["screen"] == nil, let mic = config.micDeviceUID,
                      audioDevices.first(where: { $0.uid == mic })?.isBuiltIn == true, Displays.isLidClosed {
                lineProblems["screen"] = "lid closed, built-in mic is silent"
                active?.events.append(.warning, ["source": "app", "track": "screen",
                                                 "message": "The laptop lid closed; the built-in mic records silence until it opens."])
            }
        }
        updateLines("recording")
    }
}

extension MicCheckOutcome {
    init(_ result: MicCheck.Result) {
        self.init(status: result.status, sample: result.sample, cameraMicOpened: result.cameraMicOpened,
                  screenMicOpened: result.screenMicOpened, cancelled: result.cancelled, errors: result.errors,
                  liveSources: result.liveSources)
    }
}

#if DEBUG
// MARK: - Sample state (docs screenshots)

extension SessionCoordinator {
    /// A made-up state for the docs screenshots (`Tests/DocShots`): devices, a take's track lines
    /// and meters, the preview phase. Plain data only. The app never uses it.
    struct Sample {
        var state: State = .idle
        /// The take's length so far, for the elapsed time.
        var elapsedS: Double = 0
        var inventory = DeviceInventory()
        var displays: [DisplayInfo] = []
        var trackLines: [TrackStatusLine] = []
        var markers: [String] = []
        var preview = PreviewPhase.off
        var cameraWindowPhase = PreviewPhase.off
        /// The meters that run: the idle meters while idle, the take's while recording.
        var meterSources: [AudioSource] = []
        var meters: AudioLevelsSnapshot?
        var lastSession: LastSession?
        var replayShown = false
        /// The Snap button's title, e.g. "Snap: Safari" (`refreshSnapTarget()` reads the window
        /// list, which a sample does not have). Nil keeps the title from before the first read.
        var snapButtonTitle: String?
    }

    /// Shows `sample` in the views. It only sets the values the views read. It marks the
    /// coordinator as quitting first, so no camera, mic, preview pass or ticker starts; call it
    /// on a coordinator that never launched.
    func showSample(_ sample: Sample) {
        shuttingDown = true
        state = sample.state
        let now = Date()
        self.now = now
        startedAt = sample.state.canStart ? nil : now.addingTimeInterval(-sample.elapsedS)
        inventory = sample.inventory
        videoDevices = sample.inventory.videoDevices
        audioDevices = sample.inventory.audioDevices
        refreshAutomaticPicks()
        displays = sample.displays
        issues = []
        trackLines = sample.trackLines
        markers = sample.markers
        preview = sample.preview
        cameraWindowPhase = sample.cameraWindowPhase
        if sample.state.canStart {
            idleMeterSources = sample.meterSources
            activeMeterSources = []
        } else {
            idleMeterSources = []
            activeMeterSources = sample.meterSources
        }
        meters = sample.meters
        micAlert = nil
        cameraHealth = CameraHealth()
        lastSession = sample.lastSession
        replayShown = sample.replayShown
        if let title = sample.snapButtonTitle { snapButtonTitle = title }
    }
}
#endif
