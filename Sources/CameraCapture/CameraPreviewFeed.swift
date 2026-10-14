import AVFoundation
import RecorderCore
import Synchronization

/// Carries small camera frames from a capture session to the preview views on screen.
///
/// The preview never shares a capture object with the UI. The recorder adds an
/// AVCaptureVideoDataOutput (on its camera queue; in the preview graph it is the session's only
/// output) that calls back on `queue`, and the feed
/// enqueues each frame on the renderer of every attached view's AVSampleBufferDisplayLayer: the
/// menu's preview and the camera window can show the same frames at once. That renderer accepts
/// frames from a background thread (AVSampleBufferDisplayLayer.h, `sampleBufferRenderer`). The
/// views only attach and detach their renderers here, so creating or removing a view never
/// touches a session.
///
/// Neither side waits for the other: one lock guards the renderer list and the frame counters,
/// and it is held only to read or swap them. A renderer that is not ready for more frames skips
/// a frame instead of queueing it, so a hidden view never piles frames up.
///
/// Color: the frames reach the layer as the preview output delivers them, scaled 420v (video
/// range) with the camera's own color tags. The feed never converts, swaps or copies a pixel. A
/// frame without a Y'CbCr matrix gets camera.mov's BT.709 tags (`colorTagged`), so the preview
/// and camera.mov always decode the camera's bytes the same way.
public final class CameraPreviewFeed: Sendable {
    /// Frame counters for "no picture" detection and the log.
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        /// Host time when the last frame arrived.
        public var lastFrameHostNs: UInt64?
        public var width = 0
        public var height = 0
        public var pixelFormat: String?
        /// Set while the frames arrive but hold no picture (all-zero planes or one flat value):
        /// "No picture: the Cam Link is sending empty frames". Frames still count above.
        public var emptyFrames: EmptyFramePattern?
        public init() {}
    }

    /// The feed does not keep a view's renderer alive: a view that goes away without a detach
    /// drops out of the list by itself.
    private struct Attached: Sendable {
        weak var renderer: PreviewRenderer?
    }

    private struct State: Sendable {
        var renderers: [Attached] = []
        var stats = Stats()

        var live: [PreviewRenderer] { renderers.compactMap(\.renderer) }
    }

    /// The data output's callback queue. Every renderer call runs here, one at a time.
    let queue = DispatchQueue(label: "TwinTake.camera.preview", qos: .userInteractive)
    private let state = Mutex(State())

    public init() {}

    public func stats() -> Stats { state.withLock { $0.stats } }

    /// Starts the counters over, for a newly opened camera.
    public func resetStats() { state.withLock { $0.stats = Stats() } }

    /// The preview pipeline found empty frames (`pattern`), or a picture again (nil). Never waits.
    func noteEmptyFrames(_ pattern: EmptyFramePattern?) {
        state.withLock { $0.stats.emptyFrames = pattern }
    }

    /// How many views show this feed now.
    public var attachedViewCount: Int { state.withLock { $0.live.count } }

    /// Removes the picture from every view, e.g. when the camera lost its signal. Never waits.
    public func clear() {
        queue.async { [self] in
            for renderer in state.withLock({ $0.live }) {
                renderer.renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
        }
    }

    /// Shows frames on `renderer` from now on, next to any other attached view. Safe on the main
    /// thread: it only takes the lock.
    func attach(_ renderer: PreviewRenderer) {
        state.withLock { s in
            s.renderers.removeAll { $0.renderer == nil || $0.renderer === renderer }
            s.renderers.append(Attached(renderer: renderer))
        }
    }

    /// Stops showing frames on `renderer`. Other views keep their frames. Safe on the main thread.
    func detach(_ renderer: PreviewRenderer) {
        state.withLock { s in s.renderers.removeAll { $0.renderer == nil || $0.renderer === renderer } }
    }

    /// Shows one frame on every attached view. Called on `queue` by the preview data output; it
    /// never blocks.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let now = HostClock.nowNs()
        let image = CMSampleBufferGetImageBuffer(sampleBuffer)
        let renderers = state.withLock { s -> [PreviewRenderer] in
            s.stats.frames += 1
            s.stats.lastFrameHostNs = now
            if let image {
                s.stats.width = CVPixelBufferGetWidth(image)
                s.stats.height = CVPixelBufferGetHeight(image)
                s.stats.pixelFormat = FormatLabel.fourCC(CVPixelBufferGetPixelFormatType(image))
            }
            return s.live
        }
        guard !renderers.isEmpty else { return }
        let frame = Self.colorTagged(sampleBuffer)
        // Marked once, before any renderer holds the buffer.
        Self.markDisplayImmediately(frame)
        for box in renderers {
            let renderer = box.renderer
            // Raw frames need no decoder, so a failure is rare; a flush resets it.
            if renderer.status == .failed { renderer.flush() }
            // A view that is not on screen may stop taking frames: skip, never queue up.
            guard renderer.isReadyForMoreMediaData else { continue }
            renderer.enqueue(frame)
        }
    }

    /// The BT.709 tags camera.mov gets (`WriterSettings.video`), as image buffer attachments.
    static var bt709Tags: [(key: CFString, value: CFString)] {
        [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
    }

    /// The frame to show for `sampleBuffer`: itself when its picture carries a Y'CbCr matrix (the
    /// camera's own tags win). An untagged frame gets the BT.709 tags camera.mov gets, on its pixel
    /// buffer and in a new format description, so the display layer decodes the preview as
    /// camera.mov is decoded instead of guessing (BT.601 is the usual guess for a 640x360 frame).
    /// The pixels are never copied or changed: the result holds the same pixel buffer.
    static func colorTagged(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) == nil else { return sampleBuffer }
        for tag in bt709Tags where CVBufferCopyAttachment(image, tag.key, nil) == nil {
            CVBufferSetAttachment(image, tag.key, tag.value, .shouldPropagate)
        }
        var format: CMVideoFormatDescription?
        var timing = CMSampleTimingInfo()
        var tagged: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr,
              let format,
              CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &tagged) == noErr,
              let tagged else { return sampleBuffer }
        return tagged
    }

    /// Live frames show as they arrive. The layer has no timebase, and the session clock can be an
    /// audio device clock, so their timestamps would not line up with the layer's time.
    static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

/// The renderer of one preview view's AVSampleBufferDisplayLayer. It is not Sendable in Swift,
/// but the SDK documents that it accepts frames from a background thread; the feed calls it
/// only on its own serial queue.
final class PreviewRenderer: @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
}

/// The preview data output's delegate: counts every frame in the stream's clock recovery (so a
/// take that starts after the preview knows the drift since the camera opened), samples a few
/// bytes of it for empty frames (`FrameProbe`), then hands it to the feed. No step waits.
final class PreviewFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    let feed: CameraPreviewFeed
    let streamClock: StreamClock?
    /// Confined to the feed's queue, where every frame arrives.
    let probe: FrameProbe?

    init(feed: CameraPreviewFeed, streamClock: StreamClock? = nil, picture: PictureCheck? = nil) {
        self.feed = feed
        self.streamClock = streamClock
        probe = picture.map { FrameProbe(pipeline: .preview, check: $0, feed: feed) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        streamClock?.observePreview(sampleBuffer, arrivalNs: HostClock.nowNs())
        if let probe, let image = CMSampleBufferGetImageBuffer(sampleBuffer) { probe.observe(image) }
        feed.enqueue(sampleBuffer)
    }
}

/// The size and pixel format of preview frames: small, so the preview costs little next to a 4K
/// recording.
enum PreviewSize {
    static let maxWidth = 640
    static let maxHeight = 360

    /// Fits the source into `maxWidth` x `maxHeight` with its aspect ratio, never larger than the
    /// source, with even sides (4:2:0 frames need them). 3840x2160 and 1920x1080 give 640x360.
    static func fit(width: Int, height: Int, maxWidth: Int = maxWidth, maxHeight: Int = maxHeight) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(1, Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        func even(_ value: Double, limit: Int) -> Int { min(limit, max(2, Int((value / 2).rounded()) * 2)) }
        return (even(Double(width) * scale, limit: width), even(Double(height) * scale, limit: height))
    }

    /// videoSettings for the preview data output: the scaled size, in 420v (the camera's own
    /// format, so scaling needs no color conversion) when the output offers it.
    static func videoSettings(width: Int, height: Int, availablePixelFormats: [OSType]) -> [String: Any] {
        var settings: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if availablePixelFormats.contains(yuv) { settings[kCVPixelBufferPixelFormatTypeKey as String] = yuv }
        return settings
    }
}
