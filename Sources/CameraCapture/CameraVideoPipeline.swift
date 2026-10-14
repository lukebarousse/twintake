import AVFoundation
import CoreMedia
import CoreVideo
import MediaWriter
import RecorderCore
import Synchronization

/// What camera.mov's video track ended up with.
struct CameraVideoResult: Sendable, Equatable {
    /// Host time of slot 0: the first frame in the file. Nil when no frame was written.
    var originNs: UInt64?
    /// Slots in the file (the video is `endSlot` frames long).
    var endSlot: Int64
    var stats: CameraGridStats
    /// New frames written as a repeat of the frame before, because the encoder was not ready.
    var writerBusyFrames: Int64 = 0
    var ptsFps: Double?
    var arrivalFps: Double?
    /// arrival rate / timestamp rate - 1, for takes of 30 s or more.
    var rateMismatch: Double?
    /// Real time minus the frame timestamps at the end, since t0 (the clock correction).
    var correctionNs: Int64 = 0
    var clockLabel: String = "unknown"
    var failed: Bool = false
    /// Frames that arrived before the file began (from prepare on). Never in the file.
    var preStartFrames: Int = 0
    /// Frames of another size than the file's first frame (the camera changed its signal). Not
    /// written: their slots repeat the last picture of the file's size.
    var otherSizeFrames: Int64 = 0

    /// The manifest's `dropped_frames`: slots that had to repeat a picture while frames came in
    /// (the camera or the encoder missed a frame), and frames that came too late for their slot.
    var droppedFrames: Int64 { stats.slotsRepeated + stats.lateFrames + writerBusyFrames }
}

/// The video path of camera.mov: full-size camera frames in, a constant-frame-rate track out.
///
/// Confined to `queue`: the recording video data output delivers frames there, the writer input
/// takes them there, and the stall timer fires there. Other threads use the async methods, which
/// hop onto the queue, and the thread-safe status properties.
///
/// From prepare on, every frame updates the clock recovery (so the latency baseline exists before
/// the file begins). The recovery is the stream's (`StreamClock`), shared with the preview output
/// and with the pipelines of earlier takes on the same camera session, so its baseline is the
/// latency when the device stream began, not when this recording output joined. Once armed, the first frame whose corrected time is at or after the scheduled
/// start is slot 0 and fixes t0; frames before it are never in the file. The delegate never
/// blocks: at most `maxWaitingFrames` new frames wait for the encoder, and a frame beyond that is
/// written as a repeat of the newest waiting one, so the capture's buffer pool never runs dry.
final class CameraVideoPipeline: @unchecked Sendable {
    /// The stall timer repeats the last picture up to this far behind real time, so a camera that
    /// stops sending frames still fills the file in real time and a crash loses at most a fragment.
    /// Frames normally arrive well within it (a USB capture card takes a frame or two).
    static let lateMarginNs: UInt64 = 500_000_000
    static let fillInterval: DispatchTimeInterval = .milliseconds(100)
    static let finishTimeout: DispatchTimeInterval = .seconds(10)
    /// New frames that may wait for the encoder at once.
    static let maxWaitingFrames = 3
    /// At most one dropped_frames event this often.
    static let dropReportIntervalNs: UInt64 = 2_000_000_000
    /// A first frame that arrives more than this after its corrected time means the clock
    /// correction is off (or the capture is very slow): track_start warns. A capture card
    /// normally delivers within 100 ms; at `lateMarginNs` frames are dropped as late.
    static let implausibleArrivalLagNs: Int64 = 150_000_000

    private struct Status {
        var frames = 0
        var lastArrivalNs: UInt64?
        /// Arrival of the last frame that went into the file (a new picture in a slot).
        var lastWrittenArrivalNs: UInt64?
        var armed = false
        var began = false
        var reachedEnd = false
    }

    private struct Write {
        let slot: Int64
        let frame: CVPixelBuffer
        let isNew: Bool
    }

    let queue: DispatchQueue
    let frameRate: FrameRate
    /// Host time now, for the stall timer. Tests that feed recorded timestamps pass their own.
    private let now: @Sendable () -> UInt64
    private let status = Mutex(Status())

    // On `queue`.
    private var clock: CMClock?
    private var mapper = HostTimeMapper(clock: nil)
    /// The device stream's clock recovery. Thread-safe; shared with the preview output.
    let streamClock: StreamClock
    private var meter: FrameRateMeter
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timing: SessionTiming?
    private var events: EventLog?
    private var trackStartData: [String: String] = [:]
    private var onBegin: (@Sendable (UInt64) -> Void)?
    private var slotter: CameraSlotter?
    private var lastFrame: CVPixelBuffer?
    private var backlog: [Write] = []
    private var waitingNewFrames = 0
    private var appendedSlots: Int64 = 0
    private var writerBusyFrames: Int64 = 0
    private var preStartFrames = 0
    /// Width and height of the file's frames, fixed by its first frame.
    private var fileFrameSize: (width: Int, height: Int)?
    private var otherSizeFrames: Int64 = 0
    private var timer: DispatchSourceTimer?
    private var stopRequested = false
    private var finishing = false
    private var inputFinished = false
    private var appendFailed = false
    private var timedOut = false
    private var retryScheduled = false
    private var reportedDrops: Int64 = 0
    private var lastDropReportNs: UInt64 = 0
    private var finishContinuation: CheckedContinuation<CameraVideoResult, Never>?
    /// Counts files, so a time limit set for one file never acts on the next.
    private var fileGeneration = 0

    /// - Parameter streamClock: the camera stream's clock recovery; a new one for a stream of its own.
    init(queue: DispatchQueue, frameRate: FrameRate, streamClock: StreamClock = StreamClock(),
         now: @escaping @Sendable () -> UInt64 = { HostClock.nowNs() }) {
        self.queue = queue
        self.frameRate = frameRate
        self.streamClock = streamClock
        self.now = now
        meter = FrameRateMeter(frameRate: frameRate)
    }

    // MARK: Thread-safe status

    /// Frames received so far, before and during the file.
    var frameCount: Int { status.withLock { $0.frames } }
    /// Host time when the last frame arrived, whether or not it went into the file.
    var lastArrivalNs: UInt64? { status.withLock { $0.lastArrivalNs } }
    /// Host time when the last frame that went into the file arrived. Late frames, skipped frames
    /// and frames of another size do not count: the stall rule uses this one.
    var lastWrittenArrivalNs: UInt64? { status.withLock { $0.lastWrittenArrivalNs } }
    /// True once `arm` gave the pipeline its writer: the next frame at or after the start begins the file.
    var isArmed: Bool { status.withLock { $0.armed } }
    /// True once the file's first frame is in.
    var hasBegun: Bool { status.withLock { $0.began } }
    /// True once every slot up to Stop has its frame (or a frame past the end arrived).
    var hasReachedEnd: Bool { status.withLock { $0.reachedEnd } }

    // MARK: Called on `queue` by the capture output

    /// Takes one frame from the recording output. `clock` is the clock its timestamp is on (the
    /// capture session's synchronizationClock). Every time is converted to the host clock, so the
    /// latency baseline stays valid across a clock change (the audio input joining the session).
    func handle(_ sampleBuffer: CMSampleBuffer, clock: CMClock?) {
        let arrivalNs = HostClock.nowNs()
        if !HostTimeMapper.sameClock(clock, self.clock) {
            self.clock = clock
            mapper = HostTimeMapper(clock: clock)
        }
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer),
              let ptsNs = mapper.hostNs(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { return }
        receive(frame, ptsNs: ptsNs, arrivalNs: arrivalNs)
    }

    /// Takes one frame stamped `ptsNs` that arrived at `arrivalNs` (both host clock). On `queue`.
    func receive(_ frame: CVPixelBuffer, ptsNs: UInt64, arrivalNs: UInt64) {
        status.withLock {
            $0.frames += 1
            $0.lastArrivalNs = arrivalNs
        }
        let corrected = streamClock.observe(ptsNs: ptsNs, arrivalNs: arrivalNs)
        guard !finishing else { return }
        guard var grid = slotter else {
            if writer != nil, let timing, !stopRequested, corrected >= timing.startNs {
                begin(frame, ptsNs: ptsNs, arrivalNs: arrivalNs, timing: timing)
            } else {
                preStartFrames += 1
            }
            return
        }
        if let size = fileFrameSize, CVPixelBufferGetWidth(frame) != size.width || CVPixelBufferGetHeight(frame) != size.height {
            // The encoder takes one size per file; the stall timer repeats the last good picture.
            otherSizeFrames += 1
            return
        }
        let placement = grid.place(correctedNs: corrected)
        slotter = grid
        switch placement {
        case let .write(slot, repeats):
            status.withLock { $0.lastWrittenArrivalNs = arrivalNs }
            meter.add(ptsNs: ptsNs, arrivalNs: arrivalNs)
            if repeats > 0 { enqueueRepeats(from: slot - repeats, count: repeats) }
            enqueue(slot: slot, frame: frame, isNew: true)
            if grid.isComplete { status.withLock { $0.reachedEnd = true } }
        case .afterEnd:
            status.withLock { $0.reachedEnd = true }
        case .skip, .late:
            break
        }
        drain()
    }

    // MARK: Lifecycle (any thread)

    /// Starts feeding `input`: the first frame at or after `timing.startNs` becomes slot 0 and
    /// calls `onBegin` with its host time.
    func arm(writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             timing: SessionTiming, events: EventLog, trackStartData: [String: String],
             onBegin: @escaping @Sendable (UInt64) -> Void) async {
        let box = WriterHandlesBox(writer: writer, input: input, adaptor: adaptor)
        await queue.run { [self] in
            resetForNewFile()
            self.writer = box.writer
            self.input = box.input
            self.adaptor = box.adaptor
            self.timing = timing
            self.events = events
            self.trackStartData = trackStartData
            self.onBegin = onBegin
            status.withLock { $0.armed = true }
        }
    }

    /// Fixes the end of the track: the first slot boundary at or after `stopNs`, so the video
    /// covers everything captured before Stop and the audio (which never runs past Stop) ends
    /// exactly with it. Frames after the end are ignored.
    func requestStop(stopNs: UInt64) async {
        await queue.run { [self] in
            timing?.setStop(stopNs)
            stopRequested = true
            guard var grid = slotter else { return }
            grid.setEnd(slot: grid.slotAtOrAfter(atNs: stopNs))
            slotter = grid
            if let end = grid.endSlot { timing?.setEndSlot(end) }
            if grid.isComplete { status.withLock { $0.reachedEnd = true } }
        }
    }

    /// Repeats the last picture up to the end, writes every waiting slot, marks the input finished
    /// and reports. Gives up after `finishTimeout` if the encoder stalls.
    func finish() async -> CameraVideoResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishing = true
                timer?.cancel()
                timer = nil
                finishContinuation = continuation
                guard input != nil, var grid = slotter else {
                    markFinished()
                    return
                }
                let tail = grid.fillToEnd()
                slotter = grid
                if tail > 0, let end = grid.endSlot { enqueueRepeats(from: end - tail, count: tail) }
                drain()
                let generation = fileGeneration
                queue.asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
                    guard let self, self.fileGeneration == generation, !self.inputFinished else { return }
                    self.timedOut = true
                    self.markFinished()
                }
            }
        }
    }

    /// Takes the writer back from an arm that a Stop overtook before any frame began the file, so
    /// the pipeline never begins a file nobody finishes. No-op once a file has begun or finished.
    func disarm() async {
        await queue.run { [self] in
            guard slotter == nil, finishContinuation == nil, !inputFinished else { return }
            stopRequested = true
            onBegin = nil
            status.withLock { $0.armed = false }
        }
    }

    /// Lets go of every held frame, so the capture gets its buffers back.
    func releaseFrames() async {
        await queue.run { [self] in
            lastFrame = nil
            backlog.removeAll()
            waitingNewFrames = 0
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Private, on `queue`

    /// Forgets the last file, so the recording graph can record another take. The stream clock
    /// keeps its baseline: it describes the stream, not the file.
    private func resetForNewFile() {
        fileGeneration += 1
        timer?.cancel()
        timer = nil
        meter = FrameRateMeter(frameRate: frameRate)
        writer = nil
        input = nil
        adaptor = nil
        timing = nil
        events = nil
        trackStartData = [:]
        onBegin = nil
        slotter = nil
        lastFrame = nil
        backlog.removeAll()
        waitingNewFrames = 0
        appendedSlots = 0
        writerBusyFrames = 0
        fileFrameSize = nil
        otherSizeFrames = 0
        stopRequested = false
        finishing = false
        inputFinished = false
        appendFailed = false
        timedOut = false
        reportedDrops = 0
        lastDropReportNs = 0
        finishContinuation = nil
        status.withLock {
            $0.armed = false
            $0.began = false
            $0.reachedEnd = false
            $0.lastWrittenArrivalNs = nil
        }
    }

    private func begin(_ frame: CVPixelBuffer, ptsNs: UInt64, arrivalNs: UInt64, timing: SessionTiming) {
        // The frame's real time: slot 0 is the first frame at or after the scheduled start.
        let origin = streamClock.corrected(ptsNs)
        var grid = CameraSlotter(frameRate: frameRate, originNs: origin)
        _ = grid.place(correctedNs: origin)
        slotter = grid
        timing.setOrigin(origin)
        fileFrameSize = (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
        meter.add(ptsNs: ptsNs, arrivalNs: arrivalNs)
        enqueue(slot: 0, frame: frame, isNew: true)
        drain()
        status.withLock {
            $0.began = true
            $0.lastWrittenArrivalNs = arrivalNs
        }

        // The frame's arrival after its corrected time: the capture latency, normally under 100 ms.
        let correctedLagNs = GridMath.delta(arrivalNs, origin)
        var data = trackStartData
        data["file"] = SessionFolder.cameraFileName
        data["role"] = TrackInfo.Role.cameraVideo.rawValue
        data["track_index"] = "0"
        data["first_pts_host_ns"] = String(origin)
        data["first_pts_source"] = FirstPts.Source.sample.rawValue
        data["scheduled_start_host_ns"] = String(timing.startNs)
        data["start_lag_ms"] = GridMath.ms(GridMath.delta(origin, timing.startNs))
        data["first_frame_arrival_lag_ms"] = GridMath.ms(GridMath.delta(arrivalNs, ptsNs))
        data["corrected_arrival_lag_ms"] = GridMath.ms(correctedLagNs)
        data["clock_correction_ms"] = GridMath.ms(streamClock.correctionNs)
        data["frames_before_start"] = String(preStartFrames)
        data["frame_size"] = "\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
        data["pixel_format"] = FormatLabel.fourCC(CVPixelBufferGetPixelFormatType(frame))
        data["clock"] = mapper.label
        events?.append(.trackStart, data, at: origin)
        if correctedLagNs > Self.implausibleArrivalLagNs {
            events?.append(.warning, [
                "source": "camera", "file": SessionFolder.cameraFileName,
                "message": "Camera frames arrive \(GridMath.ms(correctedLagNs)) ms after their corrected time. "
                    + "camera.mov may be out of sync with its audio, and frames later than 500 ms are dropped.",
                "corrected_arrival_lag_ms": GridMath.ms(correctedLagNs),
            ])
        }
        onBegin?(origin)
        onBegin = nil
        startTimer()
    }

    private func enqueue(slot: Int64, frame: CVPixelBuffer, isNew: Bool) {
        if isNew, waitingNewFrames >= Self.maxWaitingFrames, let last = lastFrame {
            // The encoder is behind: hold no more capture buffers, repeat the newest waiting one.
            writerBusyFrames += 1
            backlog.append(Write(slot: slot, frame: last, isNew: false))
            return
        }
        backlog.append(Write(slot: slot, frame: frame, isNew: isNew))
        if isNew { waitingNewFrames += 1 }
        lastFrame = frame
    }

    private func enqueueRepeats(from first: Int64, count: Int64) {
        guard count > 0, let last = lastFrame else { return }
        for slot in first..<(first + count) { backlog.append(Write(slot: slot, frame: last, isNew: false)) }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.fillInterval, repeating: Self.fillInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Repeats the last picture up to "now minus the late margin" when the camera stopped sending
    /// frames, and reports repeated slots at most every `dropReportIntervalNs`.
    private func tick() {
        guard var grid = slotter, !finishing else { return }
        let nowNs = self.now()
        guard nowNs > Self.lateMarginNs else { return }
        let filled = grid.fill(through: grid.nearestSlot(atNs: nowNs - Self.lateMarginNs) - 1)
        slotter = grid
        if filled > 0 { enqueueRepeats(from: grid.nextSlot - filled, count: filled) }
        let drops = grid.stats.slotsRepeated + grid.stats.lateFrames + writerBusyFrames
        if drops > reportedDrops, nowNs >= lastDropReportNs + Self.dropReportIntervalNs {
            events?.append(.droppedFrames, [
                "file": SessionFolder.cameraFileName,
                "track": TrackInfo.Role.cameraVideo.rawValue,
                "count": String(drops - reportedDrops),
                "total": String(drops),
            ])
            reportedDrops = drops
            lastDropReportNs = nowNs
        }
        drain()
    }

    /// Writes waiting slots in order while the input accepts them. Runs on every frame and timer
    /// tick, and every few milliseconds while slots wait, so a backlog clears as soon as the
    /// encoder takes more.
    private func drain() {
        guard let input, let adaptor, !inputFinished else { return }
        if let writer, writer.status != .writing {
            appendFailed = writer.status == .failed
            backlog.removeAll()
            waitingNewFrames = 0
            if finishing { markFinished() }
            return
        }
        while input.isReadyForMoreMediaData, !backlog.isEmpty {
            let write = backlog.removeFirst()
            if write.isNew { waitingNewFrames -= 1 }
            if !adaptor.append(write.frame, withPresentationTime: frameRate.time(ofFrame: write.slot)) {
                appendFailed = true
                break
            }
            appendedSlots += 1
        }
        if finishing && (appendFailed || backlog.isEmpty) {
            markFinished()
        } else if !backlog.isEmpty, !retryScheduled {
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                self?.retryScheduled = false
                self?.drain()
            }
        }
    }

    private func markFinished() {
        guard !inputFinished else { return }
        inputFinished = true
        timer?.cancel()
        timer = nil
        if let input, writer?.status == .writing { input.markAsFinished() }
        let clean = !appendFailed && !timedOut
        let grid = slotter
        var result = CameraVideoResult(
            originNs: grid?.originNs,
            // Slots are written in order from 0, so after a failure the file holds `appendedSlots`.
            endSlot: clean ? (grid?.endSlot ?? grid?.nextSlot ?? 0) : appendedSlots,
            stats: grid?.stats ?? CameraGridStats())
        result.writerBusyFrames = writerBusyFrames
        result.otherSizeFrames = otherSizeFrames
        result.ptsFps = meter.ptsFps
        result.arrivalFps = meter.arrivalFps
        result.rateMismatch = meter.mismatch
        result.correctionNs = streamClock.correctionNs
        result.clockLabel = mapper.label
        result.failed = !clean
        result.preStartFrames = preStartFrames
        // The next take counts the frames between this file and its own.
        preStartFrames = 0
        lastFrame = nil
        backlog.removeAll()
        waitingNewFrames = 0
        status.withLock { $0.armed = false }
        finishContinuation?.resume(returning: result)
        finishContinuation = nil
    }
}

/// Carries the writer handles onto the video queue.
private struct WriterHandlesBox: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}
