// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import Synchronization

/// What one audio track ended up with.
package struct AudioTrackResult: Sendable, Equatable {
    package var role: TrackInfo.Role
    package var trackIndex: Int
    /// Host time of the track's first sample (t0: the head is padded or trimmed to it). Nil when
    /// the track holds no sample. Never the time of a buffer that was cut before t0.
    package var firstPtsHostNs: UInt64?
    /// Host time of the first captured buffer that reached the file, before padding or trimming.
    package var firstCaptureHostNs: UInt64?
    /// Samples in the track, silence included.
    package var frames: Int64
    /// Rate of the captured samples (the file is always 48 kHz).
    package var sourceSampleRate: Int
    /// Channels written to the file.
    package var channels: Int
    /// e.g. "1 ch 48 kHz Float32".
    package var sourceFormat: String?
    package var gapPaddedFrames: Int64
    package var overlapTrimmedFrames: Int64
    package var droppedBuffers: Int
    package var failed: Bool

    package init(role: TrackInfo.Role, trackIndex: Int, firstPtsHostNs: UInt64?, firstCaptureHostNs: UInt64?,
                 frames: Int64, sourceSampleRate: Int, channels: Int, sourceFormat: String?, gapPaddedFrames: Int64,
                 overlapTrimmedFrames: Int64, droppedBuffers: Int, failed: Bool) {
        self.role = role; self.trackIndex = trackIndex; self.firstPtsHostNs = firstPtsHostNs
        self.firstCaptureHostNs = firstCaptureHostNs; self.frames = frames; self.sourceSampleRate = sourceSampleRate
        self.channels = channels; self.sourceFormat = sourceFormat; self.gapPaddedFrames = gapPaddedFrames
        self.overlapTrimmedFrames = overlapTrimmedFrames; self.droppedBuffers = droppedBuffers; self.failed = failed
    }

    /// Duration of the track in seconds.
    package var durationS: Double? { sourceSampleRate > 0 ? Double(frames) / Double(sourceSampleRate) : nil }

    /// track_stop data for this track: silence inserted for gaps, samples cut for overlaps, buffers dropped.
    package var trackStopData: [String: String] {
        let rate = max(1, sourceSampleRate)
        return [
            "gap_silence_ms": GridMath.ms(GridMath.ns(ofAudioFrames: gapPaddedFrames, sampleRate: rate)),
            "overlap_trim_ms": GridMath.ms(GridMath.ns(ofAudioFrames: overlapTrimmedFrames, sampleRate: rate)),
            "dropped_buffers": String(droppedBuffers),
        ]
    }
}

/// The path for one audio track (a mic, system audio, the camera audio): samples in, aligned PCM out.
///
/// Confined to `queue`, like the video pipelines. Before Start it keeps the last half second of
/// samples, so the head of the track is real audio rather than silence. Until the video fixes
/// t0 it holds samples back, then trims (before t0) or pads (gaps, with silence) them onto the grid.
package final class AudioPipeline: @unchecked Sendable {
    /// Audio kept while prepared, so the track can start exactly at t0.
    package static let prerollNs: Int64 = 500_000_000
    /// Audio held while waiting for the first video frame.
    package static let holdNs: Int64 = 5_000_000_000
    /// Gaps longer than this are logged as warnings.
    package static let reportedGapNs: Int64 = 50_000_000
    /// At most one gap warning this often (it counts the gaps since the last one). The log
    /// flushes each line, so a run of glitches must not write a line per buffer.
    package static let gapReportIntervalNs: Int64 = 2_000_000_000
    package static let finishTimeout: DispatchTimeInterval = .seconds(10)

    package let queue: DispatchQueue
    package let role: TrackInfo.Role
    /// The file this track belongs to, for events.jsonl.
    package let fileName: String
    /// Measures every buffer that arrives (levels, clips, the camera mic detector), before and
    /// during the file. Confined to `queue` like the pipeline.
    package let meter: AudioLevelMeter?

    private let formatLock = NSLock()
    private var firstFormat: CMAudioFormatDescription?

    private var mapper: HostTimeMapper?
    /// The clock `mapper` was built for.
    private var clock: CMClock?
    private var clockChangeLogged = false
    /// Sample time of the last gap warning, and the reported gaps since it.
    private var lastGapWarningPtsNs: UInt64?
    private var unreportedGaps = 0
    private var held: [(buffer: CMSampleBuffer, ptsNs: UInt64)] = []
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var timing: SessionTiming?
    private var events: EventLog?
    private var trackIndex = 0
    private var outputChannels = 1
    private var format: CMAudioFormatDescription?
    private var sampleRate = WriterSettings.audioSampleRate
    /// Host time just past the newest sample seen, for a Stop that waits for the tail.
    private let latestEnd = Mutex<UInt64>(0)
    private var aligner: AudioAligner?
    private var fifo: [CMSampleBuffer] = []
    private var finishing = false
    private var inputFinished = false
    private var appendFailed = false
    private var retryScheduled = false
    private var firstCaptureNs: UInt64?
    private var formatChangeDrops = 0
    private var finishContinuation: CheckedContinuation<AudioTrackResult, Never>?

    package init(queue: DispatchQueue, role: TrackInfo.Role, fileName: String, meter: AudioLevelMeter? = nil) {
        self.queue = queue
        self.role = role
        self.fileName = fileName
        self.meter = meter
    }

    /// Format of the first buffer seen, once one arrived. Thread-safe.
    package var observedFormat: CMAudioFormatDescription? { formatLock.withLock { firstFormat } }

    /// True once a buffer has arrived, before or during a file. Thread-safe.
    package var hasSeenAudio: Bool { observedFormat != nil }

    /// Host time just past the newest sample that arrived, or 0 before any. Thread-safe.
    package var latestSampleEndNs: UInt64 { latestEnd.withLock { $0 } }

    // MARK: Called on `queue` by the capture output

    /// - Parameter clock: the clock the buffer is stamped on (the stream's or the capture
    ///   session's `synchronizationClock`). When it changes (the camera session's clock can change
    ///   when its audio input joins), later buffers are mapped with the new one, like the video.
    package func handle(_ sampleBuffer: CMSampleBuffer, clock: CMClock?) {
        if mapper == nil || !HostTimeMapper.sameClock(clock, self.clock) {
            if mapper != nil, aligner != nil, !clockChangeLogged {
                clockChangeLogged = true
                events?.append(.warning, [
                    "track": role.rawValue, "file": fileName,
                    "message": "The audio clock changed during recording; later audio is mapped with the new clock.",
                ])
            }
            self.clock = clock
            mapper = HostTimeMapper(clock: clock)
        }
        guard let ptsNs = mapper?.hostNs(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { return }
        receive(sampleBuffer, ptsNs: ptsNs)
    }

    /// Takes one PCM buffer whose first sample is stamped `ptsNs` (host clock). On `queue`.
    package func receive(_ sampleBuffer: CMSampleBuffer, ptsNs: UInt64) {
        guard let bufferFormat = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(bufferFormat) == kCMMediaType_Audio,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0
        else { return }
        meter?.process(sampleBuffer, ptsNs: ptsNs)
        formatLock.withLock { if firstFormat == nil { firstFormat = bufferFormat } }
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(bufferFormat)?.pointee, asbd.mSampleRate > 0 {
            let end = ptsNs + UInt64(Double(CMSampleBufferGetNumSamples(sampleBuffer)) / asbd.mSampleRate * 1e9)
            latestEnd.withLock { $0 = max($0, end) }
        }
        guard !finishing else { return }

        if aligner == nil {
            if writer != nil, let origin = timing?.originNs {
                setUpAligner(originNs: origin, currentFormat: bufferFormat)
            } else {
                hold(sampleBuffer, ptsNs: ptsNs, limitNs: writer == nil ? Self.prerollNs : Self.holdNs)
                return
            }
        }
        process(sampleBuffer, ptsNs: ptsNs)
        drain()
    }

    // MARK: Lifecycle (any thread)

    package func attach(writer: AVAssetWriter, input: AVAssetWriterInput, trackIndex: Int, channels: Int,
                        timing: SessionTiming, events: EventLog) async {
        let box = WriterInputBox(writer: writer, input: input)
        await queue.run { [self] in
            self.writer = box.writer
            self.input = box.input
            self.trackIndex = trackIndex
            outputChannels = channels
            self.timing = timing
            self.events = events
        }
    }

    /// Pads the track to the video end, writes everything queued and marks the input finished.
    /// Call after the stream stopped and its queue drained.
    package func finish() async -> AudioTrackResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishing = true
                finishContinuation = continuation
                guard input != nil, let timing else {
                    markFinished()
                    return
                }
                if aligner == nil { setUpAligner(originNs: timing.audioOriginNs, currentFormat: nil) }
                if let end = timing.audioEndFrame(sampleRate: sampleRate) { aligner?.endFrame = end }
                if let tail = aligner?.planTail() { enqueueSilence(frames: tail.padFrames, at: tail.position) }
                drain()
                queue.asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
                    guard let self, !self.inputFinished else { return }
                    self.appendFailed = true
                    self.markFinished()
                }
            }
        }
    }

    package func releaseBuffers() async {
        await queue.run { [self] in
            held.removeAll()
            fifo.removeAll()
        }
    }

    // MARK: Private, on `queue`

    private func hold(_ buffer: CMSampleBuffer, ptsNs: UInt64, limitNs: Int64) {
        held.append((buffer, ptsNs))
        while let first = held.first, GridMath.delta(ptsNs, first.ptsNs) > limitNs { held.removeFirst() }
    }

    /// Fixes the track format (the oldest sample still to write decides) and t0, then replays
    /// the held samples onto the grid.
    private func setUpAligner(originNs: UInt64, currentFormat: CMAudioFormatDescription?) {
        let trackFormat = held.first.flatMap { CMSampleBufferGetFormatDescription($0.buffer) }
            ?? currentFormat
            ?? observedFormat
            ?? PCMSampleBuffers.fallbackFormat(sampleRate: Double(WriterSettings.audioSampleRate),
                                               channels: outputChannels)
        format = trackFormat
        if let trackFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(trackFormat)?.pointee,
           asbd.mSampleRate > 0 {
            sampleRate = Int(asbd.mSampleRate.rounded())
        }
        aligner = AudioAligner(originNs: originNs, sampleRate: sampleRate)
        let replay = held
        held.removeAll()
        for item in replay { process(item.buffer, ptsNs: item.ptsNs) }
    }

    private func process(_ buffer: CMSampleBuffer, ptsNs: UInt64) {
        guard let format, let bufferFormat = CMSampleBufferGetFormatDescription(buffer) else { return }
        guard Self.sameStreamFormat(bufferFormat, format) else {
            // An AVAssetWriterInput cannot change source format mid-track.
            if formatChangeDrops == 0 {
                events?.append(.warning, [
                    "track": role.rawValue,
                    "message": "The audio format changed during recording; later audio is missing from this track.",
                    "format": WriterSettings.audioFormatLabel(bufferFormat),
                ])
            }
            formatChangeDrops += 1
            return
        }
        if let timing, let end = timing.audioEndFrame(sampleRate: sampleRate) { aligner?.endFrame = end }
        let count = Int64(CMSampleBufferGetNumSamples(buffer))
        let isHead = !(aligner?.started ?? false)
        guard let plan = aligner?.plan(ptsNs: ptsNs, frameCount: count) else { return }

        if firstCaptureNs == nil {
            firstCaptureNs = ptsNs
            logTrackStart(plan: plan, captureNs: ptsNs)
        }
        if plan.padFrames > 0 {
            enqueueSilence(frames: plan.padFrames, at: plan.position)
            let gapNs = GridMath.ns(ofAudioFrames: plan.padFrames, sampleRate: sampleRate)
            if !isHead && gapNs > Self.reportedGapNs { reportGap(gapNs: gapNs, ptsNs: ptsNs) }
        }
        if plan.keepFrames > 0 {
            let start = plan.position + plan.padFrames
            let at = time(ofPosition: start)
            let out = plan.trimFrames == 0 && plan.keepFrames == count
                ? PCMSampleBuffers.retimed(buffer, at: at)
                : PCMSampleBuffers.copy(buffer, frameOffset: Int(plan.trimFrames), frameCount: Int(plan.keepFrames), at: at)
            if let out {
                fifo.append(out)
            } else {
                // Keep the timeline intact even if the samples could not be copied.
                enqueueSilence(frames: plan.keepFrames, at: start)
            }
        }
    }

    /// Logs a gap at most every `gapReportIntervalNs`, with the number of gaps since the last line.
    private func reportGap(gapNs: Int64, ptsNs: UInt64) {
        unreportedGaps += 1
        if let last = lastGapWarningPtsNs, GridMath.delta(ptsNs, last) < Self.gapReportIntervalNs { return }
        events?.append(.warning, [
            "track": role.rawValue,
            "message": "Audio gap filled with silence.",
            "gap_ms": GridMath.ms(gapNs),
            "gaps": String(unreportedGaps),
        ])
        lastGapWarningPtsNs = ptsNs
        unreportedGaps = 0
    }

    private func logTrackStart(plan: AudioAligner.Plan, captureNs: UInt64) {
        guard let aligner else { return }
        let firstPts = aligner.originNs + UInt64(GridMath.ns(ofAudioFrames: plan.position, sampleRate: sampleRate))
        var data: [String: String] = [
            "file": fileName,
            "role": role.rawValue,
            "track_index": String(trackIndex),
            "first_pts_host_ns": String(firstPts),
            "first_pts_source": "sample",
            "first_capture_host_ns": String(captureNs),
            "clock": mapper?.label ?? "unknown",
            "arrival_lag_ms": GridMath.ms(GridMath.delta(HostClock.nowNs(), captureNs)),
        ]
        if plan.padFrames > 0 {
            data["head_silence_ms"] = GridMath.ms(GridMath.ns(ofAudioFrames: plan.padFrames, sampleRate: sampleRate))
        }
        if plan.trimFrames > 0 {
            data["head_trim_ms"] = GridMath.ms(GridMath.ns(ofAudioFrames: plan.trimFrames, sampleRate: sampleRate))
        }
        if let format { data["source_format"] = WriterSettings.audioFormatLabel(format) }
        events?.append(.trackStart, data)
    }

    /// Queues silence in chunks of at most one second.
    private func enqueueSilence(frames: Int64, at position: Int64) {
        guard let format else { return }
        var done: Int64 = 0
        while done < frames {
            let chunk = min(frames - done, Int64(sampleRate))
            if let silence = PCMSampleBuffers.silence(format: format, frameCount: Int(chunk),
                                                      at: time(ofPosition: position + done)) {
                fifo.append(silence)
            }
            done += chunk
        }
    }

    private func time(ofPosition position: Int64) -> CMTime {
        CMTime(value: position, timescale: CMTimeScale(sampleRate))
    }

    private func drain() {
        guard let input, !inputFinished else { return }
        if let writer, writer.status != .writing {
            appendFailed = writer.status == .failed
            fifo.removeAll()
            if finishing { markFinished() }
            return
        }
        while input.isReadyForMoreMediaData, !fifo.isEmpty {
            if !input.append(fifo.removeFirst()) {
                appendFailed = true
                break
            }
        }
        // While recording, the next buffer (every ~10 ms) drains again; while finishing, retry.
        guard finishing else { return }
        if appendFailed || fifo.isEmpty {
            markFinished()
        } else if !retryScheduled {
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
        if let input, writer?.status == .writing { input.markAsFinished() }
        fifo.removeAll()
        held.removeAll()
        let frames = aligner?.position ?? 0
        let result = AudioTrackResult(
            role: role,
            trackIndex: trackIndex,
            firstPtsHostNs: frames > 0 ? aligner?.originNs : nil,
            firstCaptureHostNs: firstCaptureNs,
            frames: frames,
            sourceSampleRate: sampleRate,
            channels: outputChannels,
            sourceFormat: format.map(WriterSettings.audioFormatLabel),
            gapPaddedFrames: aligner?.gapPaddedFrames ?? 0,
            overlapTrimmedFrames: aligner?.overlapTrimmedFrames ?? 0,
            droppedBuffers: (aligner?.droppedBuffers ?? 0) + formatChangeDrops,
            failed: appendFailed)
        finishContinuation?.resume(returning: result)
        finishContinuation = nil
    }

    /// Same sample rate, channel count and sample layout.
    package static func sameStreamFormat(_ a: CMAudioFormatDescription, _ b: CMAudioFormatDescription) -> Bool {
        guard let x = CMAudioFormatDescriptionGetStreamBasicDescription(a)?.pointee,
              let y = CMAudioFormatDescriptionGetStreamBasicDescription(b)?.pointee
        else { return false }
        return x.mSampleRate == y.mSampleRate && x.mChannelsPerFrame == y.mChannelsPerFrame
            && x.mFormatID == y.mFormatID && x.mFormatFlags == y.mFormatFlags
            && x.mBitsPerChannel == y.mBitsPerChannel && x.mBytesPerFrame == y.mBytesPerFrame
    }
}
