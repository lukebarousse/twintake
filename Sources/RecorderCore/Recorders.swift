import CoreGraphics
import Foundation

/// Settings for the camera file (camera.mov).
///
/// Size and rate follow the camera by default: leave `width`, `height` and `frameRate` nil and
/// the recorder records whatever signal the camera sends when it opens (a capture card offers
/// only its HDMI input), at its largest size and its rate snapped to the exact rational
/// (23.98 from the Cam Link is 24000/1001). Set all three to require one format instead.
public struct CameraRecorderConfig: Sendable, Hashable {
    /// `AVCaptureDevice.uniqueID` of the capture card (e.g. Cam Link 4K).
    public var videoDeviceUID: String
    /// `AVCaptureDevice.uniqueID` of the audio input for camera.mov (the camera's mic arrives as
    /// the capture card's HDMI audio). Nil records no audio.
    public var audioDeviceUID: String?
    /// Required width, or nil to follow the camera's signal.
    public var width: Int?
    /// Required height, or nil to follow the camera's signal.
    public var height: Int?
    /// Required frame rate, or nil to follow the camera's signal.
    public var frameRate: FrameRate?
    public var codec: VideoCodec
    /// Target average bitrate in bits per second (ignored for ProRes).
    public var bitrate: Int

    public init(videoDeviceUID: String, audioDeviceUID: String?, width: Int? = nil, height: Int? = nil,
                frameRate: FrameRate? = nil, codec: VideoCodec = .hevc, bitrate: Int = 60_000_000) {
        self.videoDeviceUID = videoDeviceUID; self.audioDeviceUID = audioDeviceUID
        self.width = width; self.height = height; self.frameRate = frameRate
        self.codec = codec; self.bitrate = bitrate
    }

    /// True when the recorder follows the camera's signal (no size or rate is required).
    public var followsSignal: Bool { width == nil || height == nil || frameRate == nil }

    /// Size and rate for estimates made before the camera opens (disk space, labels): the
    /// required ones, else 3840x2160 at 23.976.
    public var expectedWidth: Int { width ?? 3840 }
    public var expectedHeight: Int { height ?? 2160 }
    public var expectedFrameRate: FrameRate { frameRate ?? .fps23_976 }
}

/// Settings for the screen file (screen.mov).
public struct ScreenRecorderConfig: Sendable, Hashable {
    /// `CGDirectDisplayID` of the display to record.
    public var displayID: CGDirectDisplayID
    /// Frame to record, in display-local points with a top-left origin (`sourceRect`).
    public var frameRectPt: CGRect
    /// Output size in pixels (even numbers). 3008x1692 for the laptop 16:9 frame at 2x.
    public var outputPx: PixelSize
    /// Constant frame rate written to the file. Default 47.952 = 2x 23.976.
    public var frameRate: FrameRate
    /// `AVCaptureDevice.uniqueID` of the mic for screen.mov (track A1). Nil records no mic.
    public var micDeviceUID: String?
    /// Record system audio (sound on screen) as track A2.
    public var captureSystemAudio: Bool
    public var showsCursor: Bool
    /// Bundle identifiers whose windows are excluded from the capture (the recorder itself).
    public var excludedBundleIDs: [String]
    /// When set, record only this window (`CGWindowID`), scaled to fit `outputPx`, instead of the
    /// frame region. Other windows, notifications and overlaps never appear, but menus that the
    /// app draws as separate windows may be missing. With `shownOwnWindowIDs` the frame region
    /// is recorded with only this window and those windows in it (where they are on the display).
    public var windowID: UInt32?
    /// Windows of the excluded apps (`CGWindowID`) that screen.mov still shows: TwinTake's
    /// keystroke pill. A region capture names them as exceptions to the exclusion; a window
    /// capture records them with its window. Empty: none (every other TwinTake window, the camera
    /// window, the control bar, the menu and the overlay, always stays out).
    public var shownOwnWindowIDs: [UInt32]
    public var codec: VideoCodec
    public var bitrate: Int

    public init(displayID: CGDirectDisplayID, frameRectPt: CGRect, outputPx: PixelSize,
                frameRate: FrameRate = .fps47_952, micDeviceUID: String?, captureSystemAudio: Bool = true,
                showsCursor: Bool = true, excludedBundleIDs: [String] = [], windowID: UInt32? = nil,
                shownOwnWindowIDs: [UInt32] = [], codec: VideoCodec = .hevc, bitrate: Int = 30_000_000) {
        self.displayID = displayID; self.frameRectPt = frameRectPt; self.outputPx = outputPx
        self.frameRate = frameRate; self.micDeviceUID = micDeviceUID; self.captureSystemAudio = captureSystemAudio
        self.showsCursor = showsCursor; self.excludedBundleIDs = excludedBundleIDs; self.windowID = windowID
        self.shownOwnWindowIDs = shownOwnWindowIDs
        self.codec = codec; self.bitrate = bitrate
    }

    /// The screen rate for a camera rate: twice the camera rate up to 30 fps (47.952 for 23.976,
    /// so a 23.976 timeline uses every other screen frame), the camera rate itself above that
    /// (59.94 stays 59.94). Not a user choice: the UI shows it.
    public static func frameRate(forCameraRate camera: FrameRate) -> FrameRate {
        guard camera.framesPerSecond <= 30.5 else { return camera }
        return FrameRate(num: camera.num * 2, den: camera.den)
    }
}

/// A capture device, for pickers in the UI.
public struct CaptureDeviceInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case video, audio }
    public var id: String { uid }
    /// `AVCaptureDevice.uniqueID`. Stable across launches; select devices by this, never by "default".
    public var uid: String
    public var name: String
    public var kind: Kind
    public var isBuiltIn: Bool
    /// Short description, e.g. "1920x1080 23.976" or "2 ch, 48 kHz".
    public var detail: String?
    /// `AVCaptureDevice.modelID` for cameras, e.g. "UVC Camera VendorID_4057 ProductID_102". It stays
    /// the same when the device moves to another USB port; the uid does not. Nil for audio inputs.
    public var modelID: String?
    public init(uid: String, name: String, kind: Kind, isBuiltIn: Bool, detail: String? = nil, modelID: String? = nil) {
        self.uid = uid; self.name = name; self.kind = kind; self.isBuiltIn = isBuiltIn; self.detail = detail
        self.modelID = modelID
    }
}

/// Something that can block or warn before recording starts.
public struct PreflightIssue: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable { case warning, blocker }
    public var id: String
    public var severity: Severity
    public var message: String
    public init(id: String, severity: Severity, message: String) {
        self.id = id; self.severity = severity; self.message = message
    }
}

/// What a recorder hands back at stop: the tracks it wrote plus any errors.
public struct RecorderResult: Sendable {
    public var tracks: [TrackInfo]
    public var errors: [String]
    public init(tracks: [TrackInfo] = [], errors: [String] = []) { self.tracks = tracks; self.errors = errors }
}

/// The shape both recorders follow, so the app can start and stop them the same way.
///
/// Lifecycle: `prepare()` opens devices and streams (slow, done before the user presses Start),
/// `start(writingTo:events:at:)` creates the file's writer and begins the file at the scheduled
/// host time, `stop()` finishes the file and reports. `stop()` must leave a playable file even
/// after an error, and never throws.
///
/// Scheduled start: pass both recorders the same `startHostNs` (`StartSchedule.startHostNs()`, a
/// little in the future). Each one gets ready before it (writer created, encoder set up) and
/// begins its file at its first frame at or after that time, so camera.mov and screen.mov start
/// within one camera frame of each other. `tracks[].first_pts_host_ns` says exactly where.
public protocol SessionTrackRecorder: AnyObject, Sendable {
    func preflight() async -> [PreflightIssue]
    func prepare() async throws
    /// Creates the file at `url` and begins it at the first frame at or after `startHostNs`
    /// (host clock, `HostClock.nowNs()`); nil begins at the next frame. Returns once the file
    /// has begun (camera) or is ready to begin at that time (screen); throws when it cannot.
    func start(writingTo url: URL, events: EventLog, at startHostNs: UInt64?) async throws
    func stop() async -> RecorderResult
    /// While recording: nil when the file is being written normally, else a short status for the
    /// UI, e.g. "ended early: Cam Link 4K was disconnected." Thread-safe and cheap; the app polls
    /// it about once a second. A file that ended early keeps its problem until the next recording.
    var recordingProblem: String? { get }
    /// Releases devices and streams. Safe to call more than once.
    func teardown() async
}

extension SessionTrackRecorder {
    /// Begins the file at the next frame (no scheduled start).
    public func start(writingTo url: URL, events: EventLog) async throws {
        try await start(writingTo: url, events: events, at: nil)
    }
}

/// The shared start time for both files of a take.
public enum StartSchedule {
    /// How far ahead of now the app schedules the start. It covers the slower recorder's
    /// warm-up: the camera creates its AVAssetWriter and HEVC encoder (about 10-90 ms on an M-series
    /// Mac, measured with a 3840x2160 writer; the first one after launch is the slowest) and makes
    /// one hop to the camera queue; the screen creates its writer and attaches three pipelines
    /// (a few ms). 500 ms leaves room for a busy queue. A recorder that gets ready later still
    /// starts, at its next frame, and logs a warning with how late it was.
    public static let marginNs: UInt64 = 500_000_000

    /// The start time to pass to both recorders: now plus `marginNs`.
    public static func startHostNs(nowNs: UInt64 = HostClock.nowNs(), marginNs: UInt64 = marginNs) -> UInt64 {
        nowNs + marginNs
    }
}
