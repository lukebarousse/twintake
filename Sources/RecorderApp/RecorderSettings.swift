import CoreGraphics
import Foundation
import Observation
import RecorderCore
import WindowTools

/// A device picked in the UI: the app's automatic pick, no device, or one fixed device.
enum DeviceChoice: Hashable, Sendable {
    case automatic
    case none
    case device(uid: String)

    /// Reads the stored form: "auto", "none" or "uid:<uniqueID>". Anything else is automatic.
    init(storage: String?) {
        switch storage {
        case "none"?: self = .none
        case let s? where s.hasPrefix("uid:") && s.count > 4: self = .device(uid: String(s.dropFirst(4)))
        default: self = .automatic
        }
    }

    var storage: String {
        switch self {
        case .automatic: "auto"
        case .none: "none"
        case let .device(uid): "uid:" + uid
        }
    }

    /// The uid to record from: the fixed device, the automatic pick, or nil for no device.
    func resolve(automatic: () -> String?) -> String? {
        switch self {
        case .automatic: automatic()
        case .none: nil
        case let .device(uid): uid
        }
    }
}

extension FrameRate {
    /// "24000/1001".
    var storage: String { "\(num)/\(den)" }

    /// Parses "24000/1001". Nil for anything else.
    init?(storage: String?) {
        guard let parts = storage?.split(separator: "/"), parts.count == 2,
              let num = Int32(parts[0]), let den = Int32(parts[1]), num > 0, den > 0 else { return nil }
        self.init(num: num, den: den)
    }
}

/// Every user setting, stored in UserDefaults. Each change is written at once.
///
/// The camera size and rate are not settings: camera.mov follows the camera's signal. The screen
/// rate is not a setting either: it is 2x the camera rate (`SessionRules.screenFrameRate`).
@MainActor
@Observable
final class RecorderSettings {
    static let cameraBitratesMbps = [40, 60, 80, 100, 150]
    static let screenBitratesMbps = [15, 20, 30, 40, 60]

    static var defaultOutputFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("TwinTake", isDirectory: true)
    }

    enum Key {
        static let mode = "mode"
        static let camera = "camera.device"
        static let cameraAudio = "camera.audio"
        static let lastCameraFrameRate = "camera.lastSignalRate"
        static let cameraPreview = "camera.preview"
        static let display = "screen.displayUUID"
        static let framePreset = "screen.framePreset"
        static let screenMic = "screen.mic"
        static let systemAudio = "screen.systemAudio"
        static let frameAnchors = "screen.frameAnchors"
        static let hideParallelsToolbar = "screen.hideParallelsToolbar"
        static let parallelsToolbarOffset = "screen.parallelsToolbarOffsetPt"
        static let snapOnStart = "screen.snapOnStart"
        static let windowOnly = "screen.windowOnly"
        static let dimOutside = "screen.dimOutsideFrame"
        static let codec = "codec"
        static let cameraBitrate = "camera.bitrateMbps"
        static let screenBitrate = "screen.bitrateMbps"
        static let outputFolder = "outputFolder"
        static let revealInFinder = "revealInFinder"
        static let cameraIdentity = "camera.device.saved"
        static let cameraAudioIdentity = "camera.audio.saved"
        static let screenMicIdentity = "screen.mic.saved"
        static let cameraWindow = "cameraWindow.shown"
        static let cameraWindowMirrored = "cameraWindow.mirrored"
        static let cameraWindowWhileRecording = "cameraWindow.whileRecording"
        static let previewWhileRecording = "cameraWindow.livePictureWhileRecording"
        static let cameraWindowFrames = "cameraWindow.frames"
        static let cameraWindowLastDisplay = "cameraWindow.lastDisplayUUID"
        static let cameraWindowOptionsShown = "menu.cameraWindowOptionsShown"
        static let screenOptionsShown = "menu.screenOptionsShown"
        static let micCalibration = "mic.calibration"
        static let showControlBar = "controlBar.shown"
        static let pinnedApps = "controlBar.pinnedApps"
        static let controlBarPlaces = "controlBar.places"
        static let controlBarLastDisplay = "controlBar.lastDisplayUUID"
        static let flagLookback = "markers.flagLookbackS"
        static let replayWindowFrames = "replay.frames"
        static let replayWindowLastDisplay = "replay.lastDisplayUUID"
        static let replaySpeed = "replay.speed"
        static let replaySkipSilence = "replay.skipSilence"
        static let keystrokes = "keystrokes.show"
        static let keystrokesInScreen = "keystrokes.inScreenRecording"
        static let keyNames = "keystrokes.names"

        /// Keys of settings that no longer exist: the camera Size and Rate pickers and the screen
        /// Rate picker (before 0.2). Removed at launch, so an old 1080p or 29.97 pick never applies.
        static let retired = ["camera.resolution", "camera.frameRate", "screen.frameRate"]
    }

    /// The fine-tune range for the Parallels toolbar strip, in points.
    static let parallelsToolbarOffsetRange: ClosedRange<Double> = -10...10
    /// How far back a Flag points by default, in seconds: a mistake is noticed 1 to 2 minutes later.
    nonisolated static let defaultFlagLookbackSeconds = 180
    nonisolated static let flagLookbackRange: ClosedRange<Int> = 10...1800

    @ObservationIgnored private let defaults: UserDefaults

    var mode: RecordingMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    var camera: DeviceChoice { didSet { defaults.set(camera.storage, forKey: Key.camera) } }
    /// Default: the camera's own audio input (the Cam Link HDMI audio).
    var cameraAudio: DeviceChoice { didSet { defaults.set(cameraAudio.storage, forKey: Key.cameraAudio) } }
    /// The rate the camera sent when the app last saw its signal (default 23.976). The screen rate
    /// follows it while no camera signal is known, and in Screen mode.
    var lastCameraFrameRate: FrameRate {
        didSet { defaults.set(lastCameraFrameRate.storage, forKey: Key.lastCameraFrameRate) }
    }
    /// Live camera preview in the menu while not recording. Keeps the camera open while the menu is open.
    var showCameraPreview: Bool { didSet { defaults.set(showCameraPreview, forKey: Key.cameraPreview) } }
    /// `DisplayInfo.uuid`. Nil: the built-in display if it is on, else the main display.
    var displayUUID: String? { didSet { defaults.set(displayUUID, forKey: Key.display) } }
    /// `ScreenFramePreset.id`. Nil: the display's default (laptop 16:9 frame, or the whole 16:9 display).
    var framePresetID: String? { didSet { defaults.set(framePresetID, forKey: Key.framePreset) } }
    /// Default: the built-in "MacBook Pro Microphone", never the system default input.
    var screenMic: DeviceChoice { didSet { defaults.set(screenMic.storage, forKey: Key.screenMic) } }
    var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: Key.systemAudio) } }
    /// Frame position picked per display, by `DisplayInfo.uuid` ("top" or "bottom"). A display
    /// with no entry uses `defaultFrameAnchor(isBuiltin:)`.
    var frameAnchors: [String: String] { didSet { defaults.set(frameAnchors, forKey: Key.frameAnchors) } }
    /// Snap Parallels Desktop with its window toolbar above the frame, so only the VM screen is
    /// recorded (`SnapProfile.parallelsDesktop`). Off: its window fills the frame like any app.
    var hideParallelsToolbar: Bool { didSet { defaults.set(hideParallelsToolbar, forKey: Key.hideParallelsToolbar) } }
    /// Points added to the detected Parallels toolbar height (can be negative), within
    /// `parallelsToolbarOffsetRange`. Positive moves the window up (a taller strip above the frame):
    /// for a strip of toolbar at the top of the recording. Negative moves it down: for a VM screen
    /// whose top is cut off.
    var parallelsToolbarOffsetPt: Double {
        didSet { defaults.set(parallelsToolbarOffsetPt, forKey: Key.parallelsToolbarOffset) }
    }

    /// `value` inside `parallelsToolbarOffsetRange`; 0 for a value that is not a number.
    static func clampedToolbarOffset(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, parallelsToolbarOffsetRange.lowerBound), parallelsToolbarOffsetRange.upperBound)
    }
    var snapOnStart: Bool { didSet { defaults.set(snapOnStart, forKey: Key.snapOnStart) } }
    var windowOnly: Bool { didSet { defaults.set(windowOnly, forKey: Key.windowOnly) } }
    var dimOutsideFrame: Bool { didSet { defaults.set(dimOutsideFrame, forKey: Key.dimOutside) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    var cameraBitrateMbps: Int { didSet { defaults.set(cameraBitrateMbps, forKey: Key.cameraBitrate) } }
    var screenBitrateMbps: Int { didSet { defaults.set(screenBitrateMbps, forKey: Key.screenBitrate) } }
    var outputFolder: URL { didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) } }
    var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: Key.revealInFinder) } }

    /// The camera pick's uid, name and model, so the app finds the camera again when its uid changes
    /// (another USB port). Kept up to date by the coordinator while the device is connected.
    @ObservationIgnored var cameraIdentity: SavedDevice? { didSet { save(cameraIdentity, Key.cameraIdentity) } }
    @ObservationIgnored var cameraAudioIdentity: SavedDevice? { didSet { save(cameraAudioIdentity, Key.cameraAudioIdentity) } }
    @ObservationIgnored var screenMicIdentity: SavedDevice? { didSet { save(screenMicIdentity, Key.screenMicIdentity) } }

    /// The floating camera window is on. It opens the camera while it shows (like Live preview).
    var cameraWindowShown: Bool { didSet { defaults.set(cameraWindowShown, forKey: Key.cameraWindow) } }
    /// Mirror the camera window's picture, like a webcam self-view. Preview only: camera.mov is never mirrored.
    var cameraWindowMirrored: Bool { didSet { defaults.set(cameraWindowMirrored, forKey: Key.cameraWindowMirrored) } }
    /// Keep the camera window on screen while recording. Off: it hides at Start and comes back after Stop.
    var cameraWindowWhileRecording: Bool {
        didSet { defaults.set(cameraWindowWhileRecording, forKey: Key.cameraWindowWhileRecording) }
    }
    /// Keep the small preview output in the camera session while camera.mov records, so the camera
    /// window stays live. Off: Start removes it, and the window shows only the timer.
    var previewWhileRecording: Bool { didSet { defaults.set(previewWhileRecording, forKey: Key.previewWhileRecording) } }
    /// The camera window's place on each display, by display uuid, as an offset from the display's
    /// bottom-left corner plus a size (`CameraWindowGeometry.local`).
    @ObservationIgnored var cameraWindowFrames: [String: CGRect] {
        didSet { defaults.set(cameraWindowFrames.mapValues(CameraWindowGeometry.encode), forKey: Key.cameraWindowFrames) }
    }
    /// The display the camera window was last put on.
    @ObservationIgnored var cameraWindowLastDisplay: String? {
        didSet { defaults.set(cameraWindowLastDisplay, forKey: Key.cameraWindowLastDisplay) }
    }
    /// The menu's disclosure arrows: Camera window options and Screen options.
    var cameraWindowOptionsShown: Bool { didSet { defaults.set(cameraWindowOptionsShown, forKey: Key.cameraWindowOptionsShown) } }
    var screenOptionsShown: Bool { didSet { defaults.set(screenOptionsShown, forKey: Key.screenOptionsShown) } }
    /// The mic warning calibration ("Calibrate mic warning…"), saved as JSON. Nil: the default
    /// rule (camera L/R correlation below 0.88, `MicFeatureRule.defaultCorrelation`).
    var micCalibration: MicCalibration? {
        didSet {
            if let data = micCalibration.flatMap({ try? JSONEncoder().encode($0) }) {
                defaults.set(data, forKey: Key.micCalibration)
            } else {
                defaults.removeObject(forKey: Key.micCalibration)
            }
        }
    }

    /// The control bar (Record / Stop, the pinned apps, Flag, the Mac mic meter) shows while
    /// TwinTake runs.
    var showControlBar: Bool { didSet { defaults.set(showControlBar, forKey: Key.showControlBar) } }
    /// The control bar's app buttons, in bar order. Saved as JSON (`PinnedApps.encode`).
    var pinnedApps: [PinnedApp] { didSet { defaults.set(PinnedApps.encode(pinnedApps), forKey: Key.pinnedApps) } }
    /// How far back a Flag points, in seconds (the marker's `lookback_s`), within `flagLookbackRange`.
    var flagLookbackSeconds: Int { didSet { defaults.set(flagLookbackSeconds, forKey: Key.flagLookback) } }
    /// The control bar's place on each display, by display uuid: its center as an offset from the
    /// display's bottom-left corner (`ControlBarGeometry.localCenter`).
    @ObservationIgnored var controlBarPlaces: [String: CGPoint] {
        didSet { defaults.set(controlBarPlaces.mapValues(ControlBarGeometry.encode), forKey: Key.controlBarPlaces) }
    }
    /// The display the control bar was last put on.
    @ObservationIgnored var controlBarLastDisplay: String? {
        didSet { defaults.set(controlBarLastDisplay, forKey: Key.controlBarLastDisplay) }
    }

    /// The replay window's place and size on each display, by display uuid, as an offset from the
    /// display's bottom-left corner plus a size (`CameraWindowGeometry.local`).
    @ObservationIgnored var replayWindowFrames: [String: CGRect] {
        didSet { defaults.set(replayWindowFrames.mapValues(CameraWindowGeometry.encode), forKey: Key.replayWindowFrames) }
    }
    /// The display the replay window was last put on.
    @ObservationIgnored var replayWindowLastDisplay: String? {
        didSet { defaults.set(replayWindowLastDisplay, forKey: Key.replayWindowLastDisplay) }
    }
    /// The replay speed last picked: 1, 1.5 or 2. (Sound is not kept: the replay opens muted.)
    var replaySpeed: Double { didSet { defaults.set(replaySpeed, forKey: Key.replaySpeed) } }
    /// The replay's Skip silence switch.
    var replaySkipSilence: Bool { didSet { defaults.set(replaySkipSilence, forKey: Key.replaySkipSilence) } }

    /// On-screen keystrokes (shortcuts and named keys in a pill at the bottom of the frame): Off,
    /// While recording, or Always while TwinTake runs (the default).
    var keystrokeMode: KeystrokeMode { didSet { defaults.set(keystrokeMode.rawValue, forKey: Key.keystrokes) } }
    /// The keystroke pill is in screen.mov (on by default). Applies at the next Start.
    var keystrokesInScreen: Bool { didSet { defaults.set(keystrokesInScreen, forKey: Key.keystrokesInScreen) } }
    /// How the pill names keys: Auto (Windows names in front of a Parallels VM), Mac symbols or
    /// Windows names.
    var keyNameStyle: KeyNameStyle { didSet { defaults.set(keyNameStyle.rawValue, forKey: Key.keyNames) } }

    /// The replay speeds.
    nonisolated static let replaySpeeds: [Double] = [1, 1.5, 2]

    /// `value` if it is one of `replaySpeeds`, else 1.
    nonisolated static func validReplaySpeed(_ value: Double?) -> Double {
        guard let value, replaySpeeds.contains(value) else { return 1 }
        return value
    }

    /// `value` inside `flagLookbackRange`.
    nonisolated static func clampedFlagLookback(_ value: Int) -> Int {
        min(max(value, flagLookbackRange.lowerBound), flagLookbackRange.upperBound)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.removeRetiredKeys(from: defaults)
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }

        mode = defaults.string(forKey: Key.mode).flatMap(RecordingMode.init(rawValue:)) ?? .both
        camera = DeviceChoice(storage: defaults.string(forKey: Key.camera))
        cameraAudio = DeviceChoice(storage: defaults.string(forKey: Key.cameraAudio))
        lastCameraFrameRate = FrameRate(storage: defaults.string(forKey: Key.lastCameraFrameRate)) ?? .fps23_976
        showCameraPreview = bool(Key.cameraPreview, false)
        displayUUID = defaults.string(forKey: Key.display)
        framePresetID = defaults.string(forKey: Key.framePreset)
        screenMic = DeviceChoice(storage: defaults.string(forKey: Key.screenMic))
        systemAudio = bool(Key.systemAudio, true)
        frameAnchors = (defaults.dictionary(forKey: Key.frameAnchors) as? [String: String] ?? [:])
            .filter { FrameAnchor(rawValue: $0.value) != nil }
        hideParallelsToolbar = bool(Key.hideParallelsToolbar, true)
        parallelsToolbarOffsetPt = Self.clampedToolbarOffset(defaults.object(forKey: Key.parallelsToolbarOffset) as? Double ?? 0)
        snapOnStart = bool(Key.snapOnStart, true)
        windowOnly = bool(Key.windowOnly, false)
        dimOutsideFrame = bool(Key.dimOutside, true)
        codec = defaults.string(forKey: Key.codec).flatMap(VideoCodec.init(rawValue:)) ?? .hevc
        cameraBitrateMbps = int(Key.cameraBitrate, 60)
        screenBitrateMbps = int(Key.screenBitrate, 30)
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultOutputFolder
        revealInFinder = bool(Key.revealInFinder, false)
        func saved(_ key: String) -> SavedDevice? { SavedDevice(storage: defaults.dictionary(forKey: key) as? [String: String]) }
        cameraIdentity = saved(Key.cameraIdentity)
        cameraAudioIdentity = saved(Key.cameraAudioIdentity)
        screenMicIdentity = saved(Key.screenMicIdentity)
        cameraWindowShown = bool(Key.cameraWindow, false)
        cameraWindowMirrored = bool(Key.cameraWindowMirrored, true)
        cameraWindowWhileRecording = bool(Key.cameraWindowWhileRecording, true)
        previewWhileRecording = bool(Key.previewWhileRecording, true)
        let frames = defaults.dictionary(forKey: Key.cameraWindowFrames) as? [String: [Double]] ?? [:]
        cameraWindowFrames = frames.compactMapValues(CameraWindowGeometry.decode)
        cameraWindowLastDisplay = defaults.string(forKey: Key.cameraWindowLastDisplay)
        cameraWindowOptionsShown = bool(Key.cameraWindowOptionsShown, false)
        screenOptionsShown = bool(Key.screenOptionsShown, false)
        micCalibration = Self.decodeCalibration(defaults.data(forKey: Key.micCalibration))
        showControlBar = bool(Key.showControlBar, true)
        pinnedApps = PinnedApps.decode(defaults.data(forKey: Key.pinnedApps))
        flagLookbackSeconds = Self.clampedFlagLookback(int(Key.flagLookback, Self.defaultFlagLookbackSeconds))
        let places = defaults.dictionary(forKey: Key.controlBarPlaces) as? [String: [Double]] ?? [:]
        controlBarPlaces = places.compactMapValues(ControlBarGeometry.decode)
        controlBarLastDisplay = defaults.string(forKey: Key.controlBarLastDisplay)
        let replayFrames = defaults.dictionary(forKey: Key.replayWindowFrames) as? [String: [Double]] ?? [:]
        replayWindowFrames = replayFrames.compactMapValues(CameraWindowGeometry.decode)
        replayWindowLastDisplay = defaults.string(forKey: Key.replayWindowLastDisplay)
        replaySpeed = Self.validReplaySpeed(defaults.object(forKey: Key.replaySpeed) as? Double)
        replaySkipSilence = bool(Key.replaySkipSilence, false)
        keystrokeMode = defaults.string(forKey: Key.keystrokes).flatMap(KeystrokeMode.init(rawValue:)) ?? .always
        keystrokesInScreen = bool(Key.keystrokesInScreen, true)
        keyNameStyle = defaults.string(forKey: Key.keyNames).flatMap(KeyNameStyle.init(rawValue:)) ?? .auto
    }

    /// A saved calibration, or nil when there is none or it is from an unknown version.
    static func decodeCalibration(_ data: Data?) -> MicCalibration? {
        guard let data, let calibration = try? JSONDecoder().decode(MicCalibration.self, from: data),
              calibration.version == MicCalibration.currentVersion else { return nil }
        return calibration
    }

    /// Removes the settings that no longer exist (`Key.retired`). Safe to run at every launch.
    static func removeRetiredKeys(from defaults: UserDefaults) {
        for key in Key.retired where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
    }

    /// The frame position when the user has not picked one for a display: the bottom of the
    /// built-in display (the strip above stays free for a window toolbar, and the auto-hidden Dock
    /// is below), the top of any other display.
    static func defaultFrameAnchor(isBuiltin: Bool) -> FrameAnchor { isBuiltin ? .bottom : .top }

    /// The frame position on `display`: the user's pick, else the default for the display.
    func frameAnchor(for display: DisplayInfo) -> FrameAnchor {
        frameAnchors[display.uuid].flatMap(FrameAnchor.init(rawValue:)) ?? Self.defaultFrameAnchor(isBuiltin: display.isBuiltin)
    }

    func setFrameAnchor(_ anchor: FrameAnchor, for display: DisplayInfo) {
        if frameAnchors[display.uuid] != anchor.rawValue { frameAnchors[display.uuid] = anchor.rawValue }
    }

    private func save(_ device: SavedDevice?, _ key: String) {
        if let device { defaults.set(device.storage, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The saved identity of a picker's device.
    func identity(_ role: DeviceRematch.Role) -> SavedDevice? {
        switch role {
        case .camera: cameraIdentity
        case .cameraAudio: cameraAudioIdentity
        case .screenMic: screenMicIdentity
        }
    }

    func setIdentity(_ device: SavedDevice?, _ role: DeviceRematch.Role) {
        switch role {
        case .camera: if cameraIdentity != device { cameraIdentity = device }
        case .cameraAudio: if cameraAudioIdentity != device { cameraAudioIdentity = device }
        case .screenMic: if screenMicIdentity != device { screenMicIdentity = device }
        }
    }

    /// A picker's choice.
    func choice(_ role: DeviceRematch.Role) -> DeviceChoice {
        switch role {
        case .camera: camera
        case .cameraAudio: cameraAudio
        case .screenMic: screenMic
        }
    }

    func setChoice(_ choice: DeviceChoice, _ role: DeviceRematch.Role) {
        switch role {
        case .camera: camera = choice
        case .cameraAudio: cameraAudio = choice
        case .screenMic: screenMic = choice
        }
    }

    /// Changes whenever a setting that affects preflight, the recorders or a snap changes (a change
    /// clears the offered snap fix).
    var fingerprint: String {
        let anchors = frameAnchors.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return [mode.rawValue, camera.storage, cameraAudio.storage, lastCameraFrameRate.storage,
                displayUUID ?? "auto", framePresetID ?? "auto", anchors, screenMic.storage, "\(systemAudio)",
                "\(snapOnStart)", "\(windowOnly)", "\(hideParallelsToolbar)", "\(parallelsToolbarOffsetPt)",
                codec.rawValue, "\(cameraBitrateMbps)", "\(screenBitrateMbps)",
                outputFolder.path].joined(separator: "|")
    }
}
