// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MediaWriter
import RecorderCore
import ScreenCaptureKit

/// The writer and its inputs for one screen.mov, created in track order.
struct ScreenWriterHandles: @unchecked Sendable {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let mic: AVAssetWriterInput?
    let systemAudio: AVAssetWriterInput?

    /// Creates the writer with inputs in `ScreenTrackLayout` order: video, mic, system audio.
    static func make(url: URL, config: ScreenRecorderConfig, micChannels: Int?,
                     systemAudioChannels: Int?) throws -> ScreenWriterHandles {
        let writer: AVAssetWriter
        do {
            writer = try WriterSettings.makeWriter(url: url, frameRate: config.frameRate)
        } catch {
            throw ScreenRecorderError.writerFailed(error.localizedDescription)
        }

        // Every slot time k * den / num is an exact tick at timescale num.
        let video = WriterSettings.makeVideoInput(settings: ScreenWriterSettings.video(for: config), frameRate: config.frameRate)
        guard writer.canAdd(video) else { throw ScreenRecorderError.writerFailed("Cannot add the video track") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

        func addAudio(channels: Int) throws -> AVAssetWriterInput {
            let input = WriterSettings.makeAudioInput(channels: channels)
            guard writer.canAdd(input) else { throw ScreenRecorderError.writerFailed("Cannot add an audio track") }
            writer.add(input)
            return input
        }
        let mic = try micChannels.map(addAudio)
        let systemAudio = try systemAudioChannels.map(addAudio)
        return ScreenWriterHandles(writer: writer, video: video, adaptor: adaptor, mic: mic, systemAudio: systemAudio)
    }
}

/// What the video track ended up with.
struct VideoTrackResult: Sendable, Equatable {
    var originNs: UInt64?
    /// Slots in the file (the video is `endSlot` frames long).
    var endSlot: Int64
    var stats: CFRStats
    var clockLabel: String
    var failed: Bool
    /// No frame arrived in time, so the track started black at the Start time.
    var startedBlack: Bool = false
}

/// The video path of one prepared stream: screen samples in, constant-frame-rate frames out.
///
/// Confined to `queue`: ScreenCaptureKit delivers `.screen` samples there, the writer input asks
/// for data there, and the fill timer fires there. Other threads use the async methods, which
/// hop onto the queue.
final class VideoPipeline: @unchecked Sendable {
    /// Slots are decided this far behind real time, so a frame delivered up to this late still
    /// reaches its slot. ScreenCaptureKit normally delivers within a frame or two.
    static let lateMarginNs: UInt64 = 250_000_000
    static let fillInterval: DispatchTimeInterval = .milliseconds(100)
    static let finishTimeout: DispatchTimeInterval = .seconds(10)
    /// A first frame older or newer than this when it arrives means its PTS is not host time.
    static let implausibleLagNs: Int64 = 1_000_000_000
    /// With no frame this long after Start, the track starts black at the Start time, so audio
    /// is not held back and the file always has video.
    static let firstFrameTimeout: DispatchTimeInterval = .seconds(2)

    let queue: DispatchQueue
    private let frameRate: FrameRate
    private let outputSize: PixelSize

    private let statusLock = NSLock()
    private var sawFrame = false

    private var mapper: HostTimeMapper?
    private var preroll: (frame: CVPixelBuffer, ptsNs: UInt64, lagNs: Int64)?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timing: SessionTiming?
    private var events: EventLog?
    private var grid: CFRGrid<CVPixelBuffer>?
    private var timer: DispatchSourceTimer?
    private var stopRequested = false
    private var finishing = false
    private var inputFinished = false
    private var appendFailed = false
    private var timedOut = false
    private var retryScheduled = false
    private var finishContinuation: CheckedContinuation<VideoTrackResult, Never>?
    private var reportedLate: Int64 = 0
    private var lastLateReportNs: UInt64 = 0
    private var startedBlack = false

    init(queue: DispatchQueue, frameRate: FrameRate, outputSize: PixelSize) {
        self.queue = queue
        self.frameRate = frameRate
        self.outputSize = outputSize
    }

    /// True once a complete frame has arrived. Thread-safe.
    var hasSeenFrame: Bool { statusLock.withLock { sawFrame } }

    // MARK: Called on `queue` by ScreenCaptureKit

    /// - Parameter clock: the stream's `synchronizationClock`.
    func handle(_ sampleBuffer: CMSampleBuffer, clock: CMClock?) {
        guard let pixelBuffer = Self.completeFrame(in: sampleBuffer) else { return }
        if mapper == nil { mapper = HostTimeMapper(clock: clock) }
        guard let ptsNs = mapper?.hostNs(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { return }
        receive(pixelBuffer, ptsNs: ptsNs)
    }

    /// Takes one complete frame stamped `ptsNs` (host clock). On `queue`.
    func receive(_ pixelBuffer: CVPixelBuffer, ptsNs: UInt64) {
        statusLock.withLock { sawFrame = true }
        guard !finishing else { return }
        guard writer != nil else {
            preroll = (pixelBuffer, ptsNs, GridMath.delta(HostClock.nowNs(), ptsNs))
            return
        }
        guard grid != nil else {
            begin(frame: pixelBuffer, ptsNs: ptsNs, lagNs: GridMath.delta(HostClock.nowNs(), ptsNs))
            return
        }
        grid?.offer(pixelBuffer, ptsNs: ptsNs)
        drain()
    }

    /// The image of a sample that carries a new frame. Idle, blank and suspended samples carry
    /// none: ScreenCaptureKit sends them when the screen did not change.
    static func completeFrame(in sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[String: Any]],
              let raw = attachments.first?[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .started
        else { return nil }
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }

    // MARK: Lifecycle (any thread)

    /// Starts feeding `handles.video`. Uses the newest frame seen so far as slot 0 when there is one.
    /// The grid origin is the first point of that frame's lattice at or after `timing.startNs`
    /// (the scheduled start), so a start time ahead of now makes the file begin then.
    func attach(_ handles: ScreenWriterHandles, timing: SessionTiming, events: EventLog) async {
        await queue.run { [self] in
            writer = handles.writer
            input = handles.video
            adaptor = handles.adaptor
            self.timing = timing
            self.events = events
            if let preroll {
                begin(frame: preroll.frame, ptsNs: preroll.ptsNs, lagNs: preroll.lagNs)
            } else {
                // Counted from the scheduled start, which may still be ahead.
                let untilStart = GridMath.delta(timing.startNs, HostClock.nowNs())
                let deadline = DispatchTime.now() + Self.firstFrameTimeout + .nanoseconds(Int(max(0, untilStart)))
                queue.asyncAfter(deadline: deadline) { [weak self] in self?.beginBlack() }
            }
        }
    }

    /// Fixes the end of the track at the slot nearest `stopNs`. Frames after it are ignored.
    func requestStop(stopNs: UInt64) async {
        await queue.run { [self] in applyStop(stopNs: stopNs) }
    }

    /// `requestStop` for code already on `queue`.
    func applyStop(stopNs: UInt64) {
        timing?.setStop(stopNs)
        stopRequested = true
        beginBlack()
        applyEnd()
    }

    /// Writes every remaining slot, marks the input finished and reports. Call after the stream
    /// stopped and its queue drained. Gives up after `finishTimeout` if the encoder stalls.
    func finish() async -> VideoTrackResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishing = true
                timer?.cancel()
                timer = nil
                finishContinuation = continuation
                grid?.decideToEnd()
                guard input != nil, grid != nil else {
                    markFinished()
                    return
                }
                drain()
                queue.asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
                    guard let self, !self.inputFinished else { return }
                    self.timedOut = true
                    self.markFinished()
                }
            }
        }
    }

    /// Drops the held preroll frame so ScreenCaptureKit gets its buffer back.
    func releaseFrames() async {
        await queue.run { [self] in
            preroll = nil
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Private, on `queue`

    /// Starts the grid at the Start time with a black frame if no frame has arrived.
    private func beginBlack() {
        guard grid == nil, writer != nil, !finishing, let timing,
              let black = Self.blackFrame(outputSize) else { return }
        startedBlack = true
        begin(frame: black, ptsNs: timing.startNs, lagNs: 0)
        events?.append(.warning, [
            "track": TrackInfo.Role.screenVideo.rawValue,
            "message": "No screen frame arrived after Start; screen.mov is black until the first one.",
        ])
    }

    static func blackFrame(_ size: PixelSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func begin(frame: CVPixelBuffer, ptsNs: UInt64, lagNs: Int64) {
        guard let timing else { return }
        if stopRequested, let stopNs = timing.stopNs, ptsNs >= stopNs, !startedBlack { return }
        let origin = GridMath.origin(startNs: timing.startNs, framePtsNs: ptsNs, frameRate: frameRate)
        grid = CFRGrid(frameRate: frameRate, originNs: origin, firstFrame: frame, firstPtsNs: ptsNs)
        preroll = nil
        timing.setOrigin(origin)
        applyEnd()

        var data: [String: String] = [
            "file": SessionFolder.screenFileName,
            "role": TrackInfo.Role.screenVideo.rawValue,
            "track_index": "0",
            "first_pts_host_ns": String(origin),
            "first_pts_source": "sample",
            "clock": mapper?.label ?? "unknown",
            "start_lag_ms": Self.ms(GridMath.delta(origin, timing.startNs)),
            "scheduled_start_host_ns": String(timing.startNs),
            "first_frame_arrival_lag_ms": Self.ms(lagNs),
        ]
        if ptsNs < origin { data["preroll_frame_age_ms"] = Self.ms(GridMath.delta(origin, ptsNs)) }
        if startedBlack { data["first_frame"] = "black" }
        events?.append(.trackStart, data)
        if !startedBlack && (lagNs < 0 || lagNs > Self.implausibleLagNs) {
            events?.append(.warning, [
                "track": TrackInfo.Role.screenVideo.rawValue,
                "message": "Screen frame times do not look like host time; check sync against the camera.",
                "arrival_lag_ms": Self.ms(lagNs),
            ])
        }
        startTimer()
    }

    private func applyEnd() {
        guard stopRequested, let timing, let stopNs = timing.stopNs, grid != nil else { return }
        let slot = GridMath.nearestSlot(elapsedNs: GridMath.delta(stopNs, grid!.originNs), frameRate: frameRate)
        grid?.setEnd(slot: slot)
        if let end = grid?.endSlot { timing.setEndSlot(end) }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.fillInterval, repeating: Self.fillInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Repeats the last frame up to "now minus the late margin", so a static screen still fills
    /// the file in real time and a crash loses at most one fragment.
    private func tick() {
        guard let originNs = grid?.originNs, !finishing else { return }
        let now = HostClock.nowNs()
        let elapsed = GridMath.delta(now, originNs) - Int64(Self.lateMarginNs)
        let target = GridMath.nearestSlot(elapsedNs: elapsed, frameRate: frameRate) - 1
        grid?.decide(through: target)
        reportLateFrames(now: now)
        drain()
    }

    private func reportLateFrames(now: UInt64) {
        guard let late = grid?.stats.late, late > reportedLate,
              now >= lastLateReportNs + 2_000_000_000 else { return }
        events?.append(.droppedFrames, [
            "track": TrackInfo.Role.screenVideo.rawValue,
            "late_frames": String(late - reportedLate),
            "total_late_frames": String(late),
        ])
        reportedLate = late
        lastLateReportNs = now
    }

    /// Writes decided slots while the input accepts them. Runs on every new frame and timer tick,
    /// and every few milliseconds while finishing, so a backlog clears as soon as the encoder
    /// takes more. (Not `requestMediaDataWhenReady`: its block can be called again and again
    /// while there is nothing new to write.)
    private func drain() {
        guard let input, let adaptor, grid != nil, !inputFinished else { return }
        if let writer, writer.status != .writing {
            appendFailed = writer.status == .failed
            if finishing { markFinished() }
            return
        }
        while input.isReadyForMoreMediaData, let write = grid?.popWrite() {
            if !adaptor.append(write.frame, withPresentationTime: frameRate.time(ofFrame: write.slot)) {
                appendFailed = true
                break
            }
        }
        guard finishing else { return }
        if appendFailed || !(grid?.hasWrites ?? false) {
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
        timer?.cancel()
        timer = nil
        if let input, writer?.status == .writing { input.markAsFinished() }
        let stats = grid?.stats ?? CFRStats()
        // Slots are written in order from 0, so after a failure or timeout the file holds
        // exactly `written` slots.
        let clean = !appendFailed && !timedOut
        let result = VideoTrackResult(
            originNs: grid?.originNs,
            endSlot: clean ? (grid?.endSlot ?? stats.written) : stats.written,
            stats: stats,
            clockLabel: mapper?.label ?? "unknown",
            failed: !clean,
            startedBlack: startedBlack)
        grid = nil
        finishContinuation?.resume(returning: result)
        finishContinuation = nil
    }

    static func ms(_ ns: Int64) -> String { GridMath.ms(ns) }
}
