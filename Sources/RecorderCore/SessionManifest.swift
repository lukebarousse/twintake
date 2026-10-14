import CoreGraphics
import Foundation

// The session.json contract. See docs/SCHEMA.md.
//
// Property names are camelCase with no acronym runs (gitSha, not gitSHA) so the snake_case
// JSON keys round-trip through JSONEncoder/JSONDecoder key conversion.

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct PointSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
}

public struct PointRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A capture device as recorded in the manifest.
public struct DeviceInfo: Codable, Hashable, Sendable {
    public var name: String
    public var uid: String
    /// What the device actually delivered, e.g. "3840x2160 420v 23.976".
    public var negotiatedFormat: String?
    public init(name: String, uid: String, negotiatedFormat: String? = nil) {
        self.name = name; self.uid = uid; self.negotiatedFormat = negotiatedFormat
    }
}

/// One track inside camera.mov or screen.mov.
public struct TrackInfo: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case cameraVideo = "camera_video"
        case screenVideo = "screen_video"
        case mic
        case systemAudio = "system_audio"
    }

    public var file: String
    /// Index of the track inside its file, in file order. Video is 0; audio tracks follow.
    public var trackIndex: Int
    public var role: Role
    /// The voice the editor cuts on. True on at most one track per session; none when the session
    /// has no mic track.
    public var dialogue: Bool
    public var device: DeviceInfo?
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: FrameRate?
    public var constantFrameRate: Bool?
    public var sampleRate: Double?
    public var channels: Int?
    /// Host-clock time (ns) of this track's first sample in the file: file time 0 of the track.
    /// Never the time of a frame or buffer that came before the file began. See HostClock.
    public var firstPtsHostNs: UInt64?
    /// How firstPtsHostNs was measured: "sample" (exact buffer PTS) or "callback" (approximate).
    public var firstPtsSource: String?
    public var durationS: Double?
    public var droppedFrames: Int?
    /// Constant-frame-rate video: written slots that repeat the previous picture because no new
    /// frame came for them (a camera that missed a frame, a static screen).
    public var slotsRepeated: Int?
    /// Constant-frame-rate video: frames that arrived but took no slot (a camera that sent more
    /// frames than the grid has slots, or a screen frame replaced by a newer one for its slot).
    public var slotsSkipped: Int?
    /// Camera video: the frame rate the buffer timestamps run at, and the rate the frames really
    /// arrived at (host clock). They differ when the device stamps a nominal frame interval.
    public var measuredPtsFps: Double?
    public var measuredArrivalFps: Double?
    /// camera.mov's mic track: which mic the camera recorded with, as the camera mic detector
    /// heard it during the take (`CameraMicDetector`). Added in 1.2.
    public var micSource: MicSourceReport?

    public init(file: String, trackIndex: Int, role: Role, dialogue: Bool) {
        self.file = file; self.trackIndex = trackIndex; self.role = role; self.dialogue = dialogue
    }
}

public struct RecorderInfo: Codable, Hashable, Sendable {
    public var name: String
    public var version: String
    public var gitSha: String?
    public init(name: String, version: String, gitSha: String? = nil) {
        self.name = name; self.version = version; self.gitSha = gitSha
    }
}

public struct HostInfo: Codable, Hashable, Sendable {
    public var model: String
    public var macosVersion: String
    public init(model: String, macosVersion: String) { self.model = model; self.macosVersion = macosVersion }

    public static func current() -> HostInfo {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return HostInfo(model: model, macosVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
}

public struct SnappedWindow: Codable, Hashable, Sendable {
    public var appName: String?
    public var bundleId: String?
    public var title: String?
    public var requestedPt: PointSize
    public var achievedPt: PointSize
    /// Window server id (`CGWindowID`) of the window. A window-only capture records this window.
    public var windowId: UInt32?
    /// Where the recorded part of the window landed, in display-local points (top-left origin),
    /// like `frameRectPt`: the whole window, or its content area for `placement` "toolbar_above".
    public var achievedFramePt: PointRect?
    /// How the window was placed: "fill" (the whole window covers the frame) or "toolbar_above"
    /// (its content area covers the frame and its toolbar sits above it, outside the recording:
    /// Parallels Desktop). Added in 1.1.
    public var placement: String?
    /// For "toolbar_above": the height of the strip above the frame, in points.
    public var toolbarPt: Double?
    /// For "toolbar_above": the whole window, toolbar included, display-local points.
    public var windowFramePt: PointRect?
    public init(appName: String?, bundleId: String?, title: String?, requestedPt: PointSize, achievedPt: PointSize,
                windowId: UInt32? = nil, achievedFramePt: PointRect? = nil, placement: String? = nil,
                toolbarPt: Double? = nil, windowFramePt: PointRect? = nil) {
        self.appName = appName; self.bundleId = bundleId; self.title = title
        self.requestedPt = requestedPt; self.achievedPt = achievedPt
        self.windowId = windowId; self.achievedFramePt = achievedFramePt
        self.placement = placement; self.toolbarPt = toolbarPt; self.windowFramePt = windowFramePt
    }
}

public struct ScreenInfo: Codable, Hashable, Sendable {
    /// "region" (the frame area of a display) or "window" (one window only).
    public var capture: String
    public var displayId: UInt32
    public var displayName: String?
    public var scale: Double
    public var preset: String
    /// Frame in display-local points, top-left origin.
    public var frameRectPt: PointRect
    /// Where a fixed frame sits: `top` (under the menu bar) or `bottom` (flush with the display's
    /// bottom edge). Nil for the whole-display preset. Added in 1.1.
    public var frameAnchor: FrameAnchor?
    public var outputPx: PixelSize
    public var snappedWindow: SnappedWindow?
    public init(capture: String, displayId: UInt32, displayName: String?, scale: Double, preset: String,
                frameRectPt: PointRect, outputPx: PixelSize, snappedWindow: SnappedWindow? = nil,
                frameAnchor: FrameAnchor? = nil) {
        self.capture = capture; self.displayId = displayId; self.displayName = displayName; self.scale = scale
        self.preset = preset; self.frameRectPt = frameRectPt; self.outputPx = outputPx; self.snappedWindow = snappedWindow
        self.frameAnchor = frameAnchor
    }
}

public struct CameraInfo: Codable, Hashable, Sendable {
    /// The HDMI signal the capture card reported, e.g. "3840x2160 23.976".
    public var hdmiFormat: String?
    /// macOS video effects that were on at start (Reactions, Portrait, Studio Light...).
    public var effectsActive: [String]
    public init(hdmiFormat: String? = nil, effectsActive: [String] = []) {
        self.hdmiFormat = hdmiFormat; self.effectsActive = effectsActive
    }
}

public struct SyncInfo: Codable, Hashable, Sendable {
    /// Clock domain of every firstPtsHostNs value.
    public var reference: String
    /// How an editor can confirm sync: "shared_voice" (camera.mov and screen.mov both have a mic
    /// track, so both hear the speaker), else "none".
    public var check: String
    public init(reference: String = "host_clock", check: String = "shared_voice") {
        self.reference = reference; self.check = check
    }
}

/// session.json. Written with status "recording" at start and rewritten at stop.
/// A file that still says "recording" after the app quit needs recovery.
public struct SessionManifest: Codable, Sendable {
    public static let currentSchemaVersion = "1.5"

    public enum Status: String, Codable, Sendable {
        case recording
        case complete
        case recovered
        case failed
    }

    public var schemaVersion: String
    public var sessionId: String
    /// ISO 8601 with time zone, e.g. 2026-10-12T17:40:00-05:00.
    public var createdAt: String
    public var status: Status
    public var mode: RecordingMode
    public var recorder: RecorderInfo
    public var host: HostInfo
    public var tracks: [TrackInfo]
    public var screen: ScreenInfo?
    public var camera: CameraInfo?
    public var sync: SyncInfo
    public var startedAtHostNs: UInt64?
    public var stoppedAtHostNs: UInt64?
    public var durationS: Double?
    public var errors: [String]

    public init(sessionId: String = UUID().uuidString, createdAt: Date = Date(), mode: RecordingMode,
                recorder: RecorderInfo, host: HostInfo = .current()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionId = sessionId
        self.createdAt = Self.isoString(createdAt)
        self.status = .recording
        self.mode = mode
        self.recorder = recorder
        self.host = host
        self.tracks = []
        self.sync = SyncInfo()
        self.errors = []
    }

    public static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
