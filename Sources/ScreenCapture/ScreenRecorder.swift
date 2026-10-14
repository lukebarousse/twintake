// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import MediaWriter
import RecorderCore
import ScreenCaptureKit

/// Records the screen frame (or one window), a Mac mic and system audio to screen.mov.
///
/// Tracks, in file order: video (0, constant frame rate at `config.frameRate`), the mic (1, only
/// when `micDeviceUID` is set), system audio (next, only when `captureSystemAudio`). Audio is
/// 48 kHz linear PCM, one source per track, never mixed. File time 0 is host time t0 (the video's
/// `firstPtsHostNs`), and every audio track is padded or trimmed to start there too.
///
/// `prepare()` starts the capture stream, which needs Screen Recording permission; nothing is
/// written until `start(writingTo:events:at:)`. With a scheduled start the file begins at the
/// first point of the screen's frame lattice at or after that host time (within one screen frame,
/// 20.9 ms at 47.952), using the newest frame the stream sent before it, so a static screen
/// starts on time too.
///
/// Levels: with `levels`, the mic (`screenMic`) and system audio (`systemAudio`) are metered on
/// their pipeline queues from prepare on. The mic is the camera mic detector's reference. While
/// idle, CameraCapture's `MacMicMeter` meters the same mic in its own session: close it before
/// `prepare()`, so the mic is never held twice, and open it again after `stop()`. System audio has
/// no idle meter (it needs this stream).
public final class ScreenRecorder: SessionTrackRecorder, @unchecked Sendable {
    public let config: ScreenRecorderConfig
    /// Where the mic and system audio levels go. Nil: no meter.
    public let levels: AudioLevelMonitor?

    private enum Phase { case idle, preparing, prepared, starting, recording, finishing, finished }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var phase: Phase = .idle
    private var streams: CaptureStreams?
    private var writer: AVAssetWriter?
    private var events: EventLog?
    private var errors: [String] = []
    private var streamFailure: String?
    /// Why the main stream stopped during a recording (screen.mov then ended early).
    private var stoppedEarly: String?
    private var systemAudioStopped: String?
    private var finishTask: Task<RecorderResult, Never>?

    private let videoQueue = DispatchQueue(label: "ScreenRecorder.video", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "ScreenRecorder.mic", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "ScreenRecorder.systemAudio", qos: .userInteractive)
    private let discardQueue = DispatchQueue(label: "ScreenRecorder.discard", qos: .utility)

    /// How long `prepare()` waits for the first frame and audio buffers, which tell `start` the
    /// exact source formats.
    static let firstSampleTimeout: Duration = .milliseconds(1500)

    public init(config: ScreenRecorderConfig, levels: AudioLevelMonitor? = nil) {
        self.config = config
        self.levels = levels
    }

    // MARK: SessionTrackRecorder

    /// Problems that can be found without opening any capture: permission, display, frame, size,
    /// window, mic, and a display refresh rate that does not fit the frame rate.
    public func preflight() async -> [PreflightIssue] {
        ScreenPreflight.issues(config: config, snapshot: .current(for: config))
    }

    /// Finds the display (or window), builds the content filter and starts the capture stream.
    /// Safe to call again after `stop()` for another take.
    public func prepare() async throws {
        enum Gate { case alreadyPrepared, proceed(previous: CaptureStreams?) }
        let gate: Gate = try lock.withLock {
            switch phase {
            case .prepared:
                return .alreadyPrepared
            case .preparing, .starting, .recording, .finishing:
                throw ScreenRecorderError.busy
            case .idle, .finished:
                phase = .preparing
                let previous = streams
                streams = nil
                writer = nil
                events = nil
                errors = []
                streamFailure = nil
                stoppedEarly = nil
                systemAudioStopped = nil
                finishTask = nil
                return .proceed(previous: previous)
            }
        }
        guard case let .proceed(previous) = gate else { return }
        if let previous { await previous.shutDown() }

        let streams: CaptureStreams
        do {
            streams = try await makeStreams()
        } catch {
            lock.withLock { phase = .idle }
            throw error
        }
        // Stored before the wait, so a stream that stops during it is noticed.
        lock.withLock { self.streams = streams }
        await waitForFirstSamples(streams)
        let failure: String? = lock.withLock {
            if let streamFailure {
                self.streams = nil
                phase = .idle
                return streamFailure
            }
            phase = .prepared
            return nil
        }
        if let failure {
            await streams.shutDown()
            throw ScreenRecorderError.streamStopped(failure)
        }
    }

    /// Creates screen.mov at `url` and gets it ready to write; the file begins at the first
    /// frame-lattice point at or after `startHostNs` (now when nil). Returns once the writer and
    /// the pipelines are ready, which is normally well before a start 500 ms ahead
    /// (`StartSchedule.marginNs`); the video's first frame then fixes t0.
    public func start(writingTo url: URL, events: EventLog, at startHostNs: UInt64?) async throws {
        let calledNs = HostClock.nowNs()
        let streams: CaptureStreams = try lock.withLock {
            guard phase == .prepared, let streams else {
                throw phase == .preparing ? ScreenRecorderError.busy : ScreenRecorderError.notPrepared
            }
            if let streamFailure { throw ScreenRecorderError.streamStopped(streamFailure) }
            phase = .starting
            return streams
        }

        do {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ScreenRecorderError.outputExists(url.path)
            }
            let micChannels = streams.mic.map { _ in
                WriterSettings.channelCount(streams.mic?.observedFormat) ?? Self.deviceChannelCount(config.micDeviceUID) ?? 1
            }
            let systemChannels = streams.systemAudio.map { _ in
                WriterSettings.channelCount(streams.systemAudio?.observedFormat) ?? ScreenStreamSettings.systemAudioChannels
            }
            let handles = try ScreenWriterHandles.make(url: url, config: config, micChannels: micChannels,
                                                       systemAudioChannels: systemChannels)
            guard handles.writer.startWriting() else {
                throw ScreenRecorderError.writerFailed(handles.writer.error?.localizedDescription ?? "startWriting failed")
            }
            // Sample times are written relative to t0, so the file starts at exactly 0 and every
            // video time is an exact tick of the frame-rate timescale.
            handles.writer.startSession(atSourceTime: .zero)

            let timing = SessionTiming(frameRate: config.frameRate,
                                       startNs: ScheduledStart.startNs(scheduledNs: startHostNs, nowNs: HostClock.nowNs()))
            levels?.beginTake(events: events, startHostNs: startHostNs)
            let roles = ScreenTrackLayout.roles(mic: handles.mic != nil, systemAudio: handles.systemAudio != nil)
            // Audio first: it only holds samples until the video fixes t0.
            if let pipeline = streams.mic, let input = handles.mic, let channels = micChannels {
                await pipeline.attach(writer: handles.writer, input: input, trackIndex: roles.firstIndex(of: .mic) ?? 1,
                                      channels: channels, timing: timing, events: events)
            }
            if let pipeline = streams.systemAudio, let input = handles.systemAudio, let channels = systemChannels {
                await pipeline.attach(writer: handles.writer, input: input,
                                      trackIndex: roles.firstIndex(of: .systemAudio) ?? 1,
                                      channels: channels, timing: timing, events: events)
            }
            await streams.video.attach(handles, timing: timing, events: events)
            let readyNs = HostClock.nowNs()
            var ready = ["source": "screen", "file": SessionFolder.screenFileName,
                         "warmup_ms": GridMath.ms(GridMath.delta(readyNs, calledNs))]
            if let startHostNs { ready["scheduled_start_host_ns"] = String(startHostNs) }
            let late = ScheduledStart.lateNs(scheduledNs: startHostNs, readyNs: readyNs)
            if late > 0 {
                ready["message"] = "screen.mov got ready \(GridMath.ms(Int64(late))) ms after the scheduled start, "
                    + "so it begins with the newest screen frame."
                events.append(.warning, ready)
            }

            let failure: String? = lock.withLock {
                writer = handles.writer
                self.events = events
                phase = .recording
                if streamFailure != nil { beginFinishing(stopNs: HostClock.nowNs()) }
                return streamFailure
            }
            if let failure { throw ScreenRecorderError.streamStopped(failure) }
        } catch {
            lock.withLock { if phase == .starting { phase = .prepared } }
            throw error
        }
    }

    public var recordingProblem: String? {
        lock.withLock {
            if let stoppedEarly { return "ended early: \(stoppedEarly)" }
            // AVAssetWriter.status is thread safe. After a failure the pipelines write nothing more.
            if phase == .recording, let writer, writer.status == .failed {
                return "writing failed: \(writer.error?.localizedDescription ?? "unknown error")"
            }
            return systemAudioStopped.map { "system audio stopped: \($0)" }
        }
    }

    /// Stops capture, writes the remaining frames and audio, and finishes screen.mov. Never throws:
    /// problems are in `RecorderResult.errors`, and the file stays playable.
    public func stop() async -> RecorderResult {
        let stopNs = HostClock.nowNs()
        let task: Task<RecorderResult, Never>? = lock.withLock {
            if let finishTask { return finishTask }
            guard phase == .recording else { return nil }
            return beginFinishing(stopNs: stopNs)
        }
        guard let task else { return RecorderResult(errors: lock.withLock { errors }) }
        return await task.value
    }

    /// Stops the streams and releases every buffer. Finishes the file first if still recording.
    /// Safe to call more than once.
    public func teardown() async {
        // Let a prepare or start that is under way settle first (they take at most a few seconds).
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while lock.withLock({ phase == .preparing || phase == .starting }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let recording = lock.withLock { phase == .recording || phase == .finishing }
        if recording { _ = await stop() }
        let streams: CaptureStreams? = lock.withLock {
            let s = self.streams
            self.streams = nil
            writer = nil
            events = nil
            phase = .idle
            return s
        }
        if let streams { await streams.shutDown() }
    }

    // MARK: Prepare

    private func makeStreams() async throws -> CaptureStreams {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == config.displayID }) else {
            throw ScreenRecorderError.displayNotFound(config.displayID)
        }
        // The recorder's own windows (the camera window, the frame overlay) never appear: a region
        // capture leaves the excluded apps out and records what is under their windows.
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter {
            Self.isExcluded(bundleID: $0.bundleIdentifier, processID: $0.processID,
                            excludedBundleIDs: config.excludedBundleIDs, ownProcessID: ownProcess)
        }

        let filter: SCContentFilter
        if let windowID = config.windowID {
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                throw ScreenRecorderError.windowNotFound(windowID)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        }

        let video = VideoPipeline(queue: videoQueue, frameRate: config.frameRate, outputSize: config.outputPx)
        let file = SessionFolder.screenFileName
        let mic = config.micDeviceUID == nil ? nil : AudioPipeline(
            queue: micQueue, role: .mic, fileName: file, meter: levels.map { AudioLevelMeter(source: .screenMic, monitor: $0) })
        let systemAudio = config.captureSystemAudio ? AudioPipeline(
            queue: audioQueue, role: .systemAudio, fileName: file,
            meter: levels.map { AudioLevelMeter(source: .systemAudio, monitor: $0) }) : nil
        let router = StreamRouter(video: video, mic: mic, systemAudio: systemAudio)
        router.onStop = { [weak self] id, error in self?.streamStopped(id, error: error) }
        router.onActivity = { [weak self] active in self?.windowActivityChanged(active: active) }

        let main = SCStream(filter: filter, configuration: ScreenStreamSettings.streamConfiguration(for: config),
                            delegate: router)
        try main.addStreamOutput(router, type: .screen, sampleHandlerQueue: videoQueue)
        if mic != nil {
            try main.addStreamOutput(router, type: .microphone, sampleHandlerQueue: micQueue)
        }
        let dedicatedAudio = ScreenStreamSettings.usesDedicatedSystemAudioStream(config)
        if config.captureSystemAudio && !dedicatedAudio {
            try main.addStreamOutput(router, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await Self.startCapture(main)

        var audioStream: SCStream?
        var discard: DiscardedFrames?
        if dedicatedAudio {
            // Audio is not window-scoped on this stream: any display filter hears the whole system.
            let audioFilter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let stream = SCStream(filter: audioFilter, configuration: ScreenStreamSettings.systemAudioStreamConfiguration(),
                                  delegate: router)
            let sink = DiscardedFrames()
            do {
                try stream.addStreamOutput(router, type: .audio, sampleHandlerQueue: audioQueue)
                // SCStream renders video regardless and logs every frame no .screen output takes.
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: discardQueue)
                try await Self.startCapture(stream)
            } catch {
                await Self.stopCapture(main)
                throw error
            }
            audioStream = stream
            discard = sink
        }

        return CaptureStreams(main: main, systemAudioStream: audioStream, router: router, discard: discard,
                              video: video, mic: mic, systemAudio: systemAudio,
                              videoDevice: videoDevice(), micDevice: micDevice())
    }

    /// Waits briefly for the first frame and audio buffers, so `start` knows the source formats.
    private func waitForFirstSamples(_ streams: CaptureStreams) async {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.firstSampleTimeout
        while clock.now < deadline {
            let ready = streams.video.hasSeenFrame
                && (streams.mic.map { $0.observedFormat != nil } ?? true)
                && (streams.systemAudio.map { $0.observedFormat != nil } ?? true)
            if ready { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func videoDevice() -> DeviceInfo {
        let isBuiltIn = CGDisplayIsBuiltin(config.displayID) != 0
        var name = isBuiltIn ? "Built-in display" : "Display \(config.displayID)"
        if let windowID = config.windowID { name = "Window \(windowID) on \(name)" }
        return DeviceInfo(name: name, uid: "display-\(config.displayID)",
                          negotiatedFormat: ScreenWriterSettings.videoFormatLabel(for: config))
    }

    private func micDevice() -> DeviceInfo? {
        guard let uid = config.micDeviceUID else { return nil }
        return DeviceInfo(name: AVCaptureDevice(uniqueID: uid)?.localizedName ?? uid, uid: uid)
    }

    // MARK: Stop

    /// Starts the one finishing task. Call with `lock` held.
    @discardableResult
    private func beginFinishing(stopNs: UInt64) -> Task<RecorderResult, Never> {
        if let finishTask { return finishTask }
        phase = .finishing
        let task = Task { await self.finishRecording(stopNs: stopNs) }
        finishTask = task
        return task
    }

    private func finishRecording(stopNs: UInt64) async -> RecorderResult {
        let (streams, writer, events) = lock.withLock { (self.streams, self.writer, self.events) }
        guard let streams, let writer else {
            lock.withLock { phase = .finished }
            return RecorderResult(errors: lock.withLock { errors })
        }
        let box = WriterBox(writer: writer)

        await streams.video.requestStop(stopNs: stopNs)
        await streams.stopCapture()
        // Let every buffer ScreenCaptureKit already queued reach its pipeline.
        await videoQueue.run {}
        await micQueue.run {}
        await audioQueue.run {}

        // Together, so a writer that waits to interleave tracks never waits on a track not yet finishing.
        async let videoResult = streams.video.finish()
        async let micResult = streams.mic?.finish()
        async let systemAudioResult = streams.systemAudio?.finish()
        let (video, mic, systemAudio) = await (videoResult, micResult, systemAudioResult)

        if video.stats.written > 0 {
            box.writer.endSession(atSourceTime: config.frameRate.time(ofFrame: video.endSlot))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.writer.finishWriting { continuation.resume() }
        }

        var problems: [String] = []
        if box.writer.status != .completed {
            problems.append("screen.mov did not finish cleanly: \(box.writer.error?.localizedDescription ?? "unknown error"). It plays up to the last movie fragment.")
        }
        if video.stats.written == 0 {
            problems.append("No screen frames were written, so screen.mov has no video.")
        } else if video.startedBlack {
            problems.append("Screen capture sent no frame after Start; screen.mov is black until the first frame.")
        }
        if video.failed {
            problems.append("The screen encoder stopped early; screen.mov holds \(video.endSlot) frames.")
        }
        for track in [mic, systemAudio].compactMap({ $0 }) where track.failed {
            problems.append("The \(track.role.rawValue) track of screen.mov stopped early.")
        }

        let tracks = ScreenTrackReport.tracks(config: config, video: video, videoDevice: streams.videoDevice,
                                              mic: mic, micDevice: streams.micDevice, systemAudio: systemAudio)
        if let events { levels?.endTake(events: events) }
        log(video: video, audio: [mic, systemAudio].compactMap { $0 }, tracks: tracks, to: events)
        await streams.releaseBuffers()

        let errors: [String] = lock.withLock {
            self.errors.append(contentsOf: problems)
            phase = .finished
            return self.errors
        }
        return RecorderResult(tracks: tracks, errors: errors)
    }

    private func log(video: VideoTrackResult, audio: [AudioTrackResult], tracks: [TrackInfo], to events: EventLog?) {
        guard let events else { return }
        if video.stats.late > 0 {
            events.append(.droppedFrames, [
                "track": TrackInfo.Role.screenVideo.rawValue,
                "total_late_frames": String(video.stats.late),
            ])
        }
        for track in tracks {
            var data: [String: String] = [
                "file": track.file,
                "role": track.role.rawValue,
                "track_index": String(track.trackIndex),
            ]
            if let d = track.durationS { data["duration_s"] = String(format: "%.3f", d) }
            if track.role == .screenVideo {
                data["frames_written"] = String(video.stats.written)
                data["frames_repeated"] = String(video.stats.repeated)
                data["frames_late"] = String(video.stats.late)
                data["frames_superseded"] = String(video.stats.superseded)
                data["clock"] = video.clockLabel
            } else if let r = audio.first(where: { $0.role == track.role }) {
                data.merge(r.trackStopData) { _, new in new }
            }
            events.append(.trackStop, data)
        }
    }

    // MARK: Stream events

    private func streamStopped(_ id: ObjectIdentifier, error: any Error) {
        let message = Self.describe(error)
        let code = (error as NSError).code
        enum Source { case main, systemAudio, unknown }
        let (source, events): (Source, EventLog?) = lock.withLock {
            guard let streams else { return (.unknown, nil) }
            if id == streams.systemAudioStreamID {
                errors.append("System audio stopped: \(message). The rest of that track is silence.")
                systemAudioStopped = message
                return (.systemAudio, self.events)
            }
            guard id == streams.mainStreamID else { return (.unknown, nil) }
            switch phase {
            case .recording:
                errors.append("Screen capture stopped: \(message)")
                stoppedEarly = message
                beginFinishing(stopNs: HostClock.nowNs())
            case .preparing, .prepared, .starting:
                streamFailure = message
            default:
                break
            }
            return (.main, self.events)
        }
        guard let events else { return }
        switch source {
        case .systemAudio:
            events.append(.error, ["source": "system_audio_stream", "message": message, "code": String(code)])
        case .main:
            if !ScreenPreflightSnapshot.onlineDisplays().contains(config.displayID) {
                events.append(.deviceLost, ["device": "display", "display_id": String(config.displayID)])
            }
            if let uid = config.micDeviceUID, AVCaptureDevice(uniqueID: uid) == nil {
                events.append(.deviceLost, ["device": "mic", "uid": uid])
            }
            events.append(.error, ["source": "screen_stream", "message": message, "code": String(code)])
        case .unknown:
            break
        }
    }

    private func windowActivityChanged(active: Bool) {
        guard config.windowID != nil, let events = lock.withLock({ self.events }) else { return }
        events.append(.warning, [
            "track": TrackInfo.Role.screenVideo.rawValue,
            "message": active ? "The recorded window is back." : "The recorded window closed; the last frame repeats until it returns.",
        ])
    }

    /// True for an app the region filter leaves out: one of `excludedBundleIDs`, or this process
    /// (its bundle id may be missing or different when it runs unbundled).
    static func isExcluded(bundleID: String, processID: pid_t, excludedBundleIDs: [String], ownProcessID: pid_t) -> Bool {
        processID == ownProcessID || excludedBundleIDs.contains(bundleID)
    }

    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain, let code = SCStreamError.Code(rawValue: ns.code) else {
            return error.localizedDescription
        }
        switch code {
        case .userStopped: return "stopped from the macOS screen-sharing menu"
        case .systemStoppedStream: return "macOS stopped the capture"
        case .noCaptureSource, .noDisplayList: return "the display or window went away"
        case .failedToStartMicrophoneCapture: return "the mic could not start"
        case .failedToStartAudioCapture: return "system audio could not start"
        case .userDeclined: return "Screen Recording permission was declined"
        default: return error.localizedDescription
        }
    }

    // MARK: Helpers

    /// The device's own channel count, read without opening it.
    static func deviceChannelCount(_ uid: String?) -> Int? {
        guard let uid, let device = AVCaptureDevice(uniqueID: uid) else { return nil }
        return WriterSettings.channelCount(device.activeFormat.formatDescription)
    }

    static func startCapture(_ stream: SCStream) async throws {
        let box = StreamBox(stream: stream)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.stream.startCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Stops a stream, ignoring "already stopped". Gives up waiting after 5 s so Stop never hangs.
    static func stopCapture(_ stream: SCStream) async {
        let box = StreamBox(stream: stream)
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.stream.stopCapture { _ in if once.claim() { continuation.resume() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
                if once.claim() { continuation.resume() }
            }
        }
    }
}

// MARK: - Supporting types

/// True for the first caller only.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
private struct StreamBox: @unchecked Sendable { let stream: SCStream }

/// The streams and pipelines of one prepare. Immutable after creation.
private final class CaptureStreams: @unchecked Sendable {
    let main: SCStream
    let systemAudioStream: SCStream?
    let router: StreamRouter
    let discard: DiscardedFrames?
    let video: VideoPipeline
    let mic: AudioPipeline?
    let systemAudio: AudioPipeline?
    let videoDevice: DeviceInfo
    let micDevice: DeviceInfo?
    let mainStreamID: ObjectIdentifier
    let systemAudioStreamID: ObjectIdentifier?

    init(main: SCStream, systemAudioStream: SCStream?, router: StreamRouter, discard: DiscardedFrames?,
         video: VideoPipeline, mic: AudioPipeline?, systemAudio: AudioPipeline?,
         videoDevice: DeviceInfo, micDevice: DeviceInfo?) {
        self.main = main
        self.systemAudioStream = systemAudioStream
        self.router = router
        self.discard = discard
        self.video = video
        self.mic = mic
        self.systemAudio = systemAudio
        self.videoDevice = videoDevice
        self.micDevice = micDevice
        mainStreamID = ObjectIdentifier(main)
        systemAudioStreamID = systemAudioStream.map(ObjectIdentifier.init)
    }

    func stopCapture() async {
        await ScreenRecorder.stopCapture(main)
        if let systemAudioStream { await ScreenRecorder.stopCapture(systemAudioStream) }
    }

    func releaseBuffers() async {
        await video.releaseFrames()
        await mic?.releaseBuffers()
        await systemAudio?.releaseBuffers()
    }

    func shutDown() async {
        await stopCapture()
        await releaseBuffers()
    }
}

/// Receives ScreenCaptureKit callbacks and hands each sample to its pipeline, on the queue it
/// arrived on. Holds no recording state.
private final class StreamRouter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let video: VideoPipeline
    let mic: AudioPipeline?
    let systemAudio: AudioPipeline?
    /// Set once before the stream starts.
    var onStop: (@Sendable (ObjectIdentifier, any Error) -> Void)?
    var onActivity: (@Sendable (Bool) -> Void)?

    init(video: VideoPipeline, mic: AudioPipeline?, systemAudio: AudioPipeline?) {
        self.video = video
        self.mic = mic
        self.systemAudio = systemAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: video.handle(sampleBuffer, clock: stream.synchronizationClock)
        case .microphone: mic?.handle(sampleBuffer, clock: stream.synchronizationClock)
        case .audio: systemAudio?.handle(sampleBuffer, clock: stream.synchronizationClock)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop?(ObjectIdentifier(stream), error)
    }

    @available(macOS 15.2, *)
    func streamDidBecomeInactive(_ stream: SCStream) { onActivity?(false) }

    @available(macOS 15.2, *)
    func streamDidBecomeActive(_ stream: SCStream) { onActivity?(true) }
}

/// Takes and drops the 2x2 frames of the system-audio stream.
private final class DiscardedFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
