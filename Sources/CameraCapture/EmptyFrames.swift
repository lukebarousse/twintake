import CoreVideo
import Foundation
import RecorderCore
import Synchronization

// Empty frames: a capture card that delivers frames with no picture in them. Seen with the Cam
// Link 4K on its USB 2 lane: it offered 3840x2160 and sent frames whose 420v planes were all zero
// (a solid green preview), so the frame counters looked healthy. A few bytes of every frame are
// sampled in the preview and the recording pipelines; a run of empty frames is an episode.
//
// The Cam Link also sends about 12 all-zero frames (0.5 s) each time its stream starts, on USB 3
// too. So empty frames count only after a grace period (`EmptyFrameDetector.openGraceNs`, 1 s)
// from each pipeline's first frame, and again after the stream started over (the camera's format
// set again, `PictureCheck.streamRestarted()`); otherwise every preview open would look like an
// episode and the camera would reopen for nothing.

/// What an empty frame holds.
public enum EmptyFramePattern: String, Sendable, Hashable {
    /// Every sampled byte is zero: 420v with Y = 0 and Cb = Cr = 0 shows solid green. Never a
    /// real picture (video range starts at Y = 16).
    case zero
    /// Every sampled position holds the same value: one flat color, no camera noise at all.
    case constant
}

/// A few bytes of one frame.
struct FrameSample: Sendable, Equatable {
    var allZero: Bool
    var uniform: Bool

    var pattern: EmptyFramePattern? { allZero ? .zero : (uniform ? .constant : nil) }
}

/// Reads a 4x4 grid of positions in every plane of a pixel buffer: the luma and chroma bytes of
/// 420v, or the pixels of a packed format. Read only, 16 positions per plane.
enum PixelSampler {
    static let grid = 4

    static func sample(_ buffer: CVPixelBuffer) -> FrameSample? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var builder = Builder()
        if CVPixelBufferIsPlanar(buffer) {
            let planes = CVPixelBufferGetPlaneCount(buffer)
            guard planes > 0 else { return nil }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            for p in 0..<min(planes, 3) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, p) else { return nil }
                let width = CVPixelBufferGetWidthOfPlane(buffer, p), height = CVPixelBufferGetHeightOfPlane(buffer, p)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, p)
                builder.add(base: UnsafeRawPointer(base), rowBytes: rowBytes, width: width, height: height,
                            pixelBytes: pixelBytes(format: format, plane: p, rowBytes: rowBytes, width: width))
            }
        } else {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            builder.add(base: UnsafeRawPointer(base), rowBytes: rowBytes, width: width, height: height,
                        pixelBytes: max(1, min(8, rowBytes / max(1, width))))
        }
        return builder.sample
    }

    /// Bytes per sampled position: 1 (luma) and 2 (CbCr) for 8-bit 4:2:0, twice that for 10-bit.
    static func pixelBytes(format: OSType, plane: Int, rowBytes: Int, width: Int) -> Int {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            plane == 0 ? 1 : 2
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            plane == 0 ? 2 : 4
        default:
            max(1, min(8, rowBytes / max(1, width)))
        }
    }

    struct Builder {
        private(set) var allZero = true
        private(set) var uniform = true
        private var any = false

        var sample: FrameSample? { any ? FrameSample(allZero: allZero, uniform: uniform) : nil }

        mutating func add(base: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int, pixelBytes: Int) {
            guard width > 0, height > 0, rowBytes >= width * pixelBytes, pixelBytes > 0, pixelBytes <= 8 else { return }
            var first: UInt64?
            for j in 0..<PixelSampler.grid {
                let y = (2 * j + 1) * height / (2 * PixelSampler.grid)
                for i in 0..<PixelSampler.grid {
                    let x = (2 * i + 1) * width / (2 * PixelSampler.grid)
                    let p = base + y * rowBytes + x * pixelBytes
                    var value: UInt64 = 0
                    for k in 0..<pixelBytes { value |= UInt64(p.load(fromByteOffset: k, as: UInt8.self)) << (8 * UInt64(k)) }
                    if value != 0 { allZero = false }
                    if let first { if value != first { uniform = false } } else { first = value }
                    any = true
                }
            }
        }
    }
}

/// Finds runs of empty frames: `framesToFlag` empty frames in a row begin an episode (half a
/// second at 23.976), `framesToClear` frames with a picture end it. Empty frames within `graceNs`
/// of the first frame (or of the first frame after `restartGrace()`) are not counted: a stream
/// that starts with a few empty frames is no episode. A frame with a picture always counts.
struct EmptyFrameDetector: Sendable {
    static let framesToFlag = 12
    static let framesToClear = 3
    /// The grace after a stream starts: the Cam Link's start-up burst is about 0.5 s of zero frames.
    static let openGraceNs: UInt64 = 1_000_000_000

    /// Empty frames are not counted for this long after the stream started. 0: no grace.
    let graceNs: UInt64
    /// When the grace began: the first frame, or the last restart. Nil until a frame came.
    private var graceStartNs: UInt64?

    enum Transition: Sendable, Equatable {
        case began(EmptyFramePattern)
        /// `frames` empty frames in the episode.
        case ended(frames: Int)
    }

    /// Set while an episode lasts.
    private(set) var episode: EmptyFramePattern?
    private(set) var episodeFrames = 0
    private var emptyRun = 0
    private var runAllZero = true
    private var pictureRun = 0
    /// True once a frame with a picture came.
    private(set) var sawPicture = false

    init(graceNs: UInt64 = 0) { self.graceNs = graceNs }

    /// The stream started over: a new grace begins with the next frame. An episode that runs
    /// stays until frames with a picture end it.
    mutating func restartGrace() { graceStartNs = nil }

    /// True while an empty frame at `nowNs` is not counted.
    func inGrace(atNs nowNs: UInt64) -> Bool {
        guard graceNs > 0, episode == nil, let start = graceStartNs else { return false }
        return nowNs < start &+ graceNs
    }

    /// One frame, arriving at host time `nowNs` (only the grace uses it).
    mutating func add(_ sample: FrameSample, atNs nowNs: UInt64 = 0) -> Transition? {
        if graceStartNs == nil { graceStartNs = nowNs }
        if sample.pattern != nil, inGrace(atNs: nowNs) {
            // The start-up burst: neither counted nor a picture.
            emptyRun = 0
            return nil
        }
        if let pattern = sample.pattern {
            pictureRun = 0
            if emptyRun == 0 { runAllZero = true }
            emptyRun += 1
            if pattern != .zero { runAllZero = false }
            if episode != nil {
                episodeFrames += 1
                return nil
            }
            guard emptyRun >= Self.framesToFlag else { return nil }
            let found: EmptyFramePattern = runAllZero ? .zero : .constant
            episode = found
            episodeFrames = emptyRun
            return .began(found)
        }
        sawPicture = true
        emptyRun = 0
        guard episode != nil else { return nil }
        pictureRun += 1
        guard pictureRun >= Self.framesToClear else { return nil }
        let frames = episodeFrames
        episode = nil
        episodeFrames = 0
        pictureRun = 0
        return .ended(frames: frames)
    }
}

/// The empty-frame state of one open camera, for both of its pipelines. Thread-safe: the
/// preview queue and the recording video queue report here; the handler runs on the reporting
/// queue, outside the lock, only when the camera as a whole starts or stops sending empty frames.
final class PictureCheck: Sendable {
    enum Pipeline: String, Sendable {
        case preview
        case recording
    }

    struct Status: Sendable, Equatable {
        var preview: EmptyFramePattern?
        var recording: EmptyFramePattern?
        /// True once either pipeline saw a frame with a picture.
        var sawPicture = false

        /// The camera sends empty frames (the recording pipeline wins).
        var empty: EmptyFramePattern? { recording ?? preview }
    }

    /// An overall change: `pipeline` began or ended an episode that changed `empty`.
    struct Change: Sendable, Equatable {
        var pipeline: Pipeline
        var transition: EmptyFrameDetector.Transition?
        var status: Status
    }

    typealias Handler = @Sendable (Change) -> Void

    /// Holds the handler by reference. A closure stored straight in the lock's generic tuple got
    /// wrapped in one more reabstraction thunk on every write to the tuple (every frame), so a long
    /// preview built a chain of thousands of thunks: calling it or freeing it overflowed the stack
    /// (Luke's crashes on 2026-10-13). A class reference is never rewrapped.
    private final class HandlerBox: Sendable {
        let call: Handler
        init(_ call: @escaping Handler) { self.call = call }
    }

    private struct State {
        var status = Status()
        var handler: HandlerBox?
    }

    private let state = Mutex(State())
    /// Counts `streamRestarted()`: each pipeline's probe starts its grace over when it changes.
    private let restarts = Mutex(0)

    init() {}

    var status: Status { state.withLock { $0.status } }

    /// The camera's stream started over (its format was set again): every pipeline gives its next
    /// frames the start-up grace again (`EmptyFrameDetector.openGraceNs`). Never waits.
    func streamRestarted() { restarts.withLock { $0 &+= 1 } }

    /// How many times the stream started over. Read by the probes once per frame.
    var restartCount: Int { restarts.withLock { $0 } }

    func setHandler(_ handler: Handler?) {
        let box = handler.map(HandlerBox.init)
        state.withLock { $0.handler = box }
    }

    /// A pipeline's transition, or a picture (`sawPicture`) with no transition.
    func report(_ transition: EmptyFrameDetector.Transition?, sawPicture: Bool, from pipeline: Pipeline) {
        let fire = state.withLock { s -> (Handler, Change)? in
            let before = s.status
            switch transition {
            case let .began(pattern):
                if pipeline == .preview { s.status.preview = pattern } else { s.status.recording = pattern }
            case .ended:
                if pipeline == .preview { s.status.preview = nil } else { s.status.recording = nil }
            case nil:
                break
            }
            if sawPicture { s.status.sawPicture = true }
            let changed = (before.empty == nil) != (s.status.empty == nil) || before.sawPicture != s.status.sawPicture
            guard changed, let handler = s.handler else { return nil }
            return (handler.call, Change(pipeline: pipeline, transition: transition, status: s.status))
        }
        if let (handler, change) = fire { handler(change) }
    }

    /// A pipeline left the session (its output was removed): its episode no longer counts.
    func forget(_ pipeline: Pipeline) {
        let fire = state.withLock { s -> (Handler, Change)? in
            let before = s.status
            if pipeline == .preview { s.status.preview = nil } else { s.status.recording = nil }
            guard (before.empty == nil) != (s.status.empty == nil), let handler = s.handler else { return nil }
            return (handler.call, Change(pipeline: pipeline, transition: nil, status: s.status))
        }
        if let (handler, change) = fire { handler(change) }
    }
}

/// Samples the frames of one pipeline. Confined to that pipeline's queue. A new probe comes with
/// each open of its pipeline (a preview output or a take's recording output joins the session),
/// so each open gets the start-up grace (`EmptyFrameDetector.openGraceNs`).
final class FrameProbe: @unchecked Sendable {
    let pipeline: PictureCheck.Pipeline
    let check: PictureCheck
    /// The preview feed whose `Stats.emptyFrames` follows this probe (the preview pipeline only).
    private weak var feed: CameraPreviewFeed?
    private var detector: EmptyFrameDetector
    private var reportedPicture = false
    private let now: @Sendable () -> UInt64
    private var restartsSeen: Int

    /// - Parameters:
    ///   - graceNs: empty frames are not counted for this long after the first frame.
    ///   - now: host time now (tests pass their own clock).
    init(pipeline: PictureCheck.Pipeline, check: PictureCheck, feed: CameraPreviewFeed? = nil,
         graceNs: UInt64 = EmptyFrameDetector.openGraceNs, now: @escaping @Sendable () -> UInt64 = { HostClock.nowNs() }) {
        self.pipeline = pipeline
        self.check = check
        self.feed = feed
        self.now = now
        detector = EmptyFrameDetector(graceNs: graceNs)
        restartsSeen = check.restartCount
    }

    func observe(_ buffer: CVPixelBuffer) {
        guard let sample = PixelSampler.sample(buffer) else { return }
        let restarts = check.restartCount
        if restarts != restartsSeen {
            restartsSeen = restarts
            detector.restartGrace()
        }
        let transition = detector.add(sample, atNs: now())
        let firstPicture = detector.sawPicture && !reportedPicture
        guard transition != nil || firstPicture else { return }
        reportedPicture = reportedPicture || detector.sawPicture
        check.report(transition, sawPicture: detector.sawPicture, from: pipeline)
        feed?.noteEmptyFrames(detector.episode)
    }
}
