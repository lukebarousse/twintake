import AVFoundation
import MediaWriter
import RecorderCore
import Synchronization

/// Writes camera.mov from the recording graph's data outputs: the full-size video data output and
/// the camera audio data output, into one AVAssetWriter .mov.
///
/// It is the delegate of both outputs. AVFoundation calls it on the video pipeline's queue for
/// frames and on the audio pipeline's queue for audio, and each pipeline is confined to its
/// queue, so a delegate call only hands the buffer on and never blocks. State shared with other
/// threads sits behind one lock.
///
/// The video track is constant frame rate on the exact grid of `frameRate` (timescale `num`,
/// 24000 for 23.976), following real time (`CameraVideoPipeline`); the audio track is 48 kHz
/// 24-bit PCM trimmed and padded onto the same timeline (`AudioPipeline`), so both start at t0,
/// the first frame at or after the scheduled start, and end together. The file gets a movie
/// fragment every 2 s like screen.mov, so a crash keeps everything up to the last fragment.
final class CameraWriterController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    enum StartOutcome: Sendable, Equatable {
        case started
        case failed(String)
        case timedOut
    }

    struct Finish: Sendable, Equatable {
        /// The file finished cleanly (AVAssetWriter completed).
        var playable: Bool
        var error: String?
        var timedOut = false
    }

    /// The file's format, fixed before the writer starts.
    struct FilePlan: Sendable, Equatable {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var frameRate: FrameRate
        var bitrate: Int
        /// Channels of the camera audio track; nil writes no audio track.
        var audioChannels: Int?
    }

    /// Text for the track_start events.
    struct TrackLabels: Sendable {
        var videoFormat: String
        var codec: String
        var videoDevice: String
        var audioDevice: String?
        /// "host" when the session clock is the host clock, else how it was converted.
        var syncClock: String
        /// "on" when the small preview output stays in the session while recording, else "off".
        var preview: String? = nil

        var videoTrackStartData: [String: String] {
            var data = ["format": videoFormat, "codec": codec, "device": videoDevice, "sync_clock": syncClock]
            data["preview"] = preview
            return data
        }
    }

    /// What the file ended up with, for session.json and track_stop.
    struct Timing: Sendable {
        var url: URL?
        var scheduledStartNs: UInt64?
        /// How long start took to get the writer ready.
        var warmupNs: UInt64?
        var video: CameraVideoResult?
        var audio: AudioTrackResult?
    }

    private enum Phase: Equatable { case idle, arming, recording, stopping, finished }

    /// While writing, no video frame for this long means the camera lost its picture (an HDMI
    /// signal drop or a format change). At 23.976 fps that is about 48 missing frames.
    static let stallAfterNs: UInt64 = 2_000_000_000
    /// At Stop, frames and audio captured just before it still arrive for this long at most.
    static let tailWait: Duration = .milliseconds(600)
    /// Start and stop limits fire here, not on a capture queue, so a blocked capture queue cannot
    /// hold back the timer that ends the wait for it.
    private static let watchdogQueue = DispatchQueue(label: "TwinTake.camera.watchdog", qos: .userInitiated)

    let frameRate: FrameRate
    let video: CameraVideoPipeline
    /// Channels of the camera audio input, nil without one.
    let audioChannels: Int?
    let videoQueue = DispatchQueue(label: "TwinTake.camera.video", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "TwinTake.camera.audio", qos: .userInteractive)
    /// Meters the camera mic for every take on this graph. Confined to `audioQueue`.
    private let meter: AudioLevelMeter?
    /// Samples the full-size frames for empty frames. Confined to `videoQueue`.
    private let probe: FrameProbe?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var phase = Phase.idle
    private var syncClock: CMClock?
    /// False until `configure(syncClock:)`: buffers stamped on a clock not known yet are dropped,
    /// so they cannot spoil the clock recovery's baseline or the audio timing.
    private var configured = false
    /// Fired when `start` has armed the pipelines (or given up before), so a Stop that comes
    /// while it arms waits for that instead of racing it.
    private var armedSignal: OneShot<Bool>?
    private var url: URL?
    private var writer: AVAssetWriter?
    private var events: EventLog?
    private var beginSignal: OneShot<StartOutcome>?
    private var finishTask: Task<Finish, Never>?
    private var finish: Finish?
    private var earlyStopReason: String?
    private var writingSinceNs: UInt64?
    private var results = Timing()
    /// The camera audio path of the current (or next) file. Each file gets a fresh one.
    private var currentAudio: AudioPipeline?
    /// The current file's timing (its t0 and end slot), for the tail wait at Stop.
    private var fileTiming: SessionTiming?

    /// - Parameters:
    ///   - audioChannels: channels of the camera audio input; nil records no audio.
    ///   - streamClock: the camera stream's clock recovery (`CaptureGraph.streamClock`), shared with
    ///     the preview output and earlier takes; a new one for a stream of its own.
    ///   - levels: where the camera mic's levels go (`AudioLevelMonitor`), nil for none.
    ///   - picture: where empty frames are reported (`CaptureGraph.pictureCheck`), nil for none.
    ///   - now: host time now, for the stall timer (tests that feed recorded timestamps pass their own).
    init(frameRate: FrameRate, audioChannels: Int?, streamClock: StreamClock = StreamClock(),
         levels: AudioLevelMonitor? = nil, picture: PictureCheck? = nil,
         now: @escaping @Sendable () -> UInt64 = { HostClock.nowNs() }) {
        self.frameRate = frameRate
        self.audioChannels = audioChannels
        video = CameraVideoPipeline(queue: videoQueue, frameRate: frameRate, streamClock: streamClock, now: now)
        meter = audioChannels == nil ? nil : levels.map { AudioLevelMeter(source: .cameraMic, monitor: $0) }
        probe = picture.map { FrameProbe(pipeline: .recording, check: $0) }
        super.init()
        currentAudio = makeAudioPipeline()
    }

    private func makeAudioPipeline() -> AudioPipeline? {
        audioChannels == nil ? nil : AudioPipeline(queue: audioQueue, role: .mic, fileName: SessionFolder.cameraFileName,
                                                   meter: meter)
    }

    /// The camera audio path of the current file.
    var audio: AudioPipeline? { locked { currentAudio } }

    /// Sets the clock sample timestamps are on (the session's synchronizationClock). Call after
    /// the session starts running and again before a file starts; it can change when the audio
    /// input joins.
    func configure(syncClock: CMClock?) {
        locked {
            self.syncClock = syncClock
            configured = true
        }
    }

    /// True once the audio output has delivered a buffer, before or during a file.
    var hasSeenAudio: Bool { audio?.hasSeenAudio ?? false }

    /// True from start until the file has finished.
    var isActive: Bool { locked { [.arming, .recording, .stopping].contains(phase) } }

    /// What the app shows for camera.mov while recording; nil while it is written normally.
    func recordingProblem(nowNs: UInt64 = HostClock.nowNs()) -> String? {
        let (early, writing, since, writer) = locked { (earlyStopReason, phase == .recording, writingSinceNs, self.writer) }
        if early == nil, writing, let writer, writer.status == .failed {
            return "writing failed: \(writer.error?.localizedDescription ?? "unknown error")"
        }
        return Self.problem(earlyStop: early, writing: writing, lastFrameNs: video.lastWrittenArrivalNs,
                            writingSinceNs: since, nowNs: nowNs)
    }

    /// The rule behind `recordingProblem`: an early stop wins; else a file being written with no
    /// new video frame in it for more than `stallAfterNs` (counted from start when none since).
    /// `lastFrameNs` is the arrival of the last frame written into the file: frames that came too
    /// late for their slot (the stall timer had repeated it) or that had another size do not count,
    /// so a file that shows one frozen picture is a problem even while frames keep arriving.
    static func problem(earlyStop: String?, writing: Bool, lastFrameNs: UInt64?, writingSinceNs: UInt64?,
                        nowNs: UInt64, stallAfterNs: UInt64 = stallAfterNs) -> String? {
        if let earlyStop { return "ended early: \(earlyStop)" }
        guard writing, let since = writingSinceNs else { return nil }
        let last = max(lastFrameNs ?? since, since)
        guard nowNs > last, nowNs - last > stallAfterNs else { return nil }
        return "no camera picture for over \(stallAfterNs / 1_000_000_000) s"
    }

    func timing() -> Timing { locked { results } }

    // MARK: - Start and stop

    /// Creates camera.mov at `url` and begins it at the first frame at or after `startHostNs`
    /// (now when nil). Returns when the first frame is in, when it failed, or after `giveUpAfter`
    /// seconds from the later of now and the scheduled start.
    func start(url: URL, events: EventLog, plan: FilePlan, labels: TrackLabels, startHostNs: UInt64?,
               giveUpAfter: TimeInterval = 6) async -> StartOutcome {
        let calledNs = HostClock.nowNs()
        let signal = OneShot<StartOutcome>()
        let armed = OneShot<Bool>()
        let fresh = makeAudioPipeline()
        let gate = locked { () -> Bool in
            guard phase == .idle || phase == .finished else { return false }
            phase = .arming
            // A second take on the same recording graph: the last take's audio path is finished.
            if results.url != nil { currentAudio = fresh }
            self.url = url
            self.events = events
            writer = nil
            finishTask = nil
            finish = nil
            earlyStopReason = nil
            writingSinceNs = nil
            beginSignal = signal
            armedSignal = armed
            results = Timing(url: url, scheduledStartNs: startHostNs)
            fileTiming = nil
            return true
        }
        guard gate else { return .failed("camera.mov is already being recorded.") }

        let handles: CameraWriterHandles
        do {
            handles = try CameraWriterHandles.make(url: url, plan: plan)
        } catch {
            locked { phase = .finished }
            armed.fire(false)
            return .failed(error.localizedDescription)
        }
        guard handles.writer.startWriting() else {
            locked { phase = .finished }
            armed.fire(false)
            return .failed(handles.writer.error?.localizedDescription ?? "The writer did not start.")
        }
        // File time 0 is t0: every frame time is an exact tick of the frame-rate timescale.
        handles.writer.startSession(atSourceTime: .zero)
        let stillArming = locked { () -> Bool in
            guard phase == .arming else { return false }
            writer = handles.writer
            return true
        }
        guard stillArming else {
            // Stopped while the writer was being made: leave no file behind.
            handles.writer.cancelWriting()
            armed.fire(false)
            return signal.value ?? .failed("Stopped before camera.mov began.")
        }
        let audio = self.audio

        let timing = SessionTiming(frameRate: plan.frameRate,
                                   startNs: ScheduledStart.startNs(scheduledNs: startHostNs, nowNs: HostClock.nowNs()))
        locked { fileTiming = timing }
        // Audio first: it only holds samples until the video fixes t0.
        if let audio, let input = handles.audio, let channels = plan.audioChannels {
            await audio.attach(writer: handles.writer, input: input, trackIndex: 1, channels: channels,
                               timing: timing, events: events)
        }
        var trackStart = labels.videoTrackStartData
        trackStart["warmup_ms"] = GridMath.ms(GridMath.delta(HostClock.nowNs(), calledNs))
        await video.arm(writer: handles.writer, input: handles.video, adaptor: handles.adaptor, timing: timing,
                        events: events, trackStartData: trackStart) { [weak self] originNs in
            self?.didBegin(originNs)
            signal.fire(.started)
        }
        armed.fire(true)
        let readyNs = HostClock.nowNs()
        locked { results.warmupNs = readyNs > calledNs ? readyNs - calledNs : 0 }
        let late = ScheduledStart.lateNs(scheduledNs: startHostNs, readyNs: readyNs)
        if late > 0 {
            events.append(.warning, ["source": "camera", "file": SessionFolder.cameraFileName,
                                     "message": "camera.mov got ready \(GridMath.ms(Int64(late))) ms after the scheduled start, "
                                         + "so it begins at the next camera frame.",
                                     "scheduled_start_host_ns": String(startHostNs ?? 0)])
        }

        let untilStart = Double(GridMath.delta(timing.startNs, readyNs)) / 1e9
        Self.watchdogQueue.asyncAfter(deadline: .now() + max(0, untilStart) + giveUpAfter) { signal.fire(.timedOut) }
        return await signal.wait()
    }

    /// The first frame is in: the file is being written.
    private func didBegin(_ originNs: UInt64) {
        locked {
            if phase == .arming { phase = .recording }
            writingSinceNs = HostClock.nowNs()
        }
    }

    /// Stops writing at `stopNs` (now) and waits for the file to finish, at most `timeout` seconds.
    /// Never throws; a timeout returns a non-playable Finish while the writer may still finish in
    /// the background.
    func stop(timeout: TimeInterval, stopNs: UInt64 = HostClock.nowNs()) async -> Finish {
        let task = locked { () -> Task<Finish, Never>? in
            if let finishTask { return finishTask }
            switch phase {
            case .idle:
                return nil
            case .finished:
                return nil
            case .arming, .recording, .stopping:
                return beginFinishing(stopNs: stopNs, reason: nil)
            }
        }
        guard let task else {
            return locked { finish } ?? Finish(playable: false, error: "camera.mov was never started.")
        }
        let box = TaskBox(task: task)
        return await Self.waitAtMost(timeout) { await box.task.value }
            ?? Finish(playable: false, error: "camera.mov did not finish within \(Int(timeout)) s.", timedOut: true)
    }

    /// Finishes the file after a device loss or a session error, so it stays playable. A start
    /// that is still waiting for its first frame fails with `reason`. Never blocks.
    func finishEarly(reason: String) {
        locked {
            guard [.arming, .recording].contains(phase), finishTask == nil else { return }
            earlyStopReason = reason
            beginFinishing(stopNs: HostClock.nowNs(), reason: reason)
        }
    }

    /// Starts the one finishing task. Call with `lock` held.
    @discardableResult
    private func beginFinishing(stopNs: UInt64, reason: String?) -> Task<Finish, Never> {
        if let finishTask { return finishTask }
        let began = phase == .recording || video.hasBegun
        phase = .stopping
        let signal = beginSignal
        let task = Task { [self] () -> Finish in
            if !began {
                signal?.fire(.failed(reason ?? "Stopped before the first camera frame arrived; camera.mov was not written."))
            }
            return await finishFile(stopNs: stopNs, began: began)
        }
        finishTask = task
        return task
    }

    private func finishFile(stopNs: UInt64, began: Bool) async -> Finish {
        // A Stop while start arms the pipelines comes after the arm, never between its steps.
        if let armed = locked({ armedSignal }) { _ = await armed.wait() }
        let (writer, audio, timing) = locked { (self.writer, currentAudio, fileTiming) }
        if !began { await video.disarm() }
        await video.requestStop(stopNs: stopNs)
        if began {
            // Frames and audio captured before Stop are still on their way. The audio must reach
            // the video's end (the first slot boundary at or after Stop), else its tail is silence.
            let video = video
            let audioEndNs = Self.audioTailTargetNs(originNs: timing?.originNs, endSlot: timing?.endSlot,
                                                    frameRate: frameRate, stopNs: stopNs)
            _ = await Self.waitUntil({
                video.hasReachedEnd && (audio.map { $0.latestSampleEndNs >= audioEndNs || !$0.hasSeenAudio } ?? true)
            }, atMost: Self.tailWait)
        }
        async let videoResult = video.finish()
        async let audioResult = audio?.finish()
        let (v, a) = await (videoResult, audioResult)

        var result: Finish
        if let writer, v.originNs != nil, v.endSlot > 0 {
            let box = WriterBox(writer: writer)
            await box.finish(endingAt: frameRate.time(ofFrame: v.endSlot))
            let completed = writer.status == .completed
            result = Finish(playable: completed, error: completed ? nil : (writer.error?.localizedDescription ?? "the writer did not finish"))
        } else {
            // No frame ever reached the file: leave no empty camera.mov behind.
            writer?.cancelWriting()
            result = Finish(playable: false, error: "No camera frame arrived after Start; camera.mov was not written.")
        }
        await video.releaseFrames()
        await audio?.releaseBuffers()
        let audioTrack = a.flatMap { $0.frames > 0 ? $0 : nil }
        locked {
            results.video = v
            results.audio = audioTrack
            finish = result
            phase = .finished
        }
        return result
    }

    // MARK: - Capture delegate (video and audio queues)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let (ready, clock, audio) = locked { (configured, syncClock, currentAudio) }
        guard ready else { return }
        switch CMFormatDescriptionGetMediaType(format) {
        case kCMMediaType_Video:
            if let probe, let image = CMSampleBufferGetImageBuffer(sampleBuffer) { probe.observe(image) }
            video.handle(sampleBuffer, clock: clock)
        case kCMMediaType_Audio:
            audio?.handle(sampleBuffer, clock: clock)
        default:
            break
        }
    }

    // MARK: - Helpers

    /// Host time the camera audio must reach before the file finishes: the video's end (t0 plus
    /// `endSlot` frames), less 0.1 ms for the rounding of buffer ends. Stop when the end is not
    /// fixed yet.
    static func audioTailTargetNs(originNs: UInt64?, endSlot: Int64?, frameRate: FrameRate, stopNs: UInt64) -> UInt64 {
        guard let originNs, let endSlot else { return stopNs }
        let endNs = GridMath.add(originNs, GridMath.offsetNs(ofSlot: endSlot, frameRate: frameRate))
        return GridMath.add(max(endNs, stopNs), -100_000)
    }

    /// A sample timestamp (on the session clock) as host-clock nanoseconds.
    static func hostNs(_ pts: CMTime, clock: CMClock?) -> UInt64? {
        HostTimeMapper(clock: clock).hostNs(pts)
    }

    /// Polls `condition` every 10 ms until it is true (true) or `limit` has passed (false).
    static func waitUntil(_ condition: @Sendable () -> Bool, atMost limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The result of `work`, or nil when it takes longer than `seconds`. `work` then goes on by itself.
    static func waitAtMost<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        let signal = OneShot<T?>()
        Task { signal.fire(await work()) }
        watchdogQueue.asyncAfter(deadline: .now() + seconds) { signal.fire(nil) }
        return await signal.wait()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The writer and its inputs for one camera.mov: video track 0, the camera audio track 1.
struct CameraWriterHandles: @unchecked Sendable {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: AVAssetWriterInput?

    static func make(url: URL, plan: CameraWriterController.FilePlan) throws -> CameraWriterHandles {
        let writer = try WriterSettings.makeWriter(url: url, frameRate: plan.frameRate)
        let settings = CameraOutputSettings.video(codec: plan.codec, width: plan.width, height: plan.height,
                                                  frameRate: plan.frameRate, bitrate: plan.bitrate)
        let video = WriterSettings.makeVideoInput(settings: settings, frameRate: plan.frameRate)
        guard writer.canAdd(video) else { throw CameraRecorderError.recordingFailed(reason: "the writer cannot add the video track.") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        var audio: AVAssetWriterInput?
        if let channels = plan.audioChannels {
            let input = WriterSettings.makeAudioInput(channels: channels)
            guard writer.canAdd(input) else { throw CameraRecorderError.recordingFailed(reason: "the writer cannot add the audio track.") }
            writer.add(input)
            audio = input
        }
        return CameraWriterHandles(writer: writer, video: video, adaptor: adaptor, audio: audio)
    }
}

/// A value set once, from whichever side comes first, that any number of tasks can wait for.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    init() {}

    /// Sets the value and wakes every waiter. Later calls do nothing.
    func fire(_ value: Value) {
        let waiters = state.withLock { s -> [CheckedContinuation<Value, Never>] in
            guard s.value == nil else { return [] }
            s.value = value
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume(returning: value) }
    }

    var value: Value? { state.withLock { $0.value } }

    func wait() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let ready = state.withLock { s -> Value? in
                if let value = s.value { return value }
                s.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

private struct TaskBox<T: Sendable>: Sendable { let task: Task<T, Never> }
