import Foundation
import Synchronization

// Level meters and the camera mic detector, shared by every audio path.
//
// Each audio source (the camera mic, the screen mic, system audio) is measured in blocks of about
// 50 ms on the queue that delivers its buffers (`AudioLevelMeter` in MediaWriter, Accelerate). A
// block is a small `AudioBlock`. The meter hands it to the one `AudioLevelMonitor`, which keeps
// the levels, the 1.5 s peak hold and the clip counter of each source behind one lock, pairs the
// camera mic and the screen mic block by block on the host clock, and runs the
// `CameraMicDetector`. The UI polls `snapshot()` about 20 times a second: it copies a small
// struct and never waits for a capture queue.

/// One audio source the app meters.
public enum AudioSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// The camera audio: camera.mov A1, the dialogue track (the capture card's HDMI audio).
    case cameraMic = "camera_mic"
    /// The Mac mic: screen.mov A1, the backup and sync reference.
    case screenMic = "screen_mic"
    /// System audio: screen.mov A2.
    case systemAudio = "system_audio"
}

/// What one ~50 ms block of one source measured. Plain data.
public struct AudioBlock: Sendable, Equatable {
    /// Block length on the host clock.
    public static let durationNs: UInt64 = 50_000_000
    /// Blocks per second.
    public static let perSecond = 20.0
    /// The clip level: -1 dBFS. A sample at or above it counts as clipped.
    public static let clipLevel: Float = 0.891_250_9
    /// The level the meters show for digital silence.
    public static let silenceDb: Double = -120

    /// Block number on the host clock: block k covers [k * durationNs, (k + 1) * durationNs).
    public var index: Int64
    /// Samples per channel in the block.
    public var frames: Int
    public var channels: Int
    /// The largest sample magnitude over every channel (1.0 is full scale).
    public var peak: Float
    /// The mean of x² over every channel and sample.
    public var meanSquare: Double
    /// Samples (every channel) at or above `clipLevel`.
    public var clipped: Int
    /// Pearson correlation of channels 1 and 2 over the block; nil for mono or a flat channel.
    public var correlation: Double?

    public init(index: Int64, frames: Int, channels: Int, peak: Float, meanSquare: Double, clipped: Int = 0,
                correlation: Double? = nil) {
        self.index = index; self.frames = frames; self.channels = channels; self.peak = peak
        self.meanSquare = meanSquare; self.clipped = clipped; self.correlation = correlation
    }

    /// RMS level in dBFS (a full-scale square wave is 0 dBFS, a full-scale sine -3 dBFS).
    public var rmsDb: Double { meanSquare > 1e-12 ? 10 * log10(meanSquare) : Self.silenceDb }
    /// Peak level in dBFS.
    public var peakDb: Double { peak > 1e-6 ? 20 * log10(Double(peak)) : Self.silenceDb }

    /// The block that holds host time `ns`.
    public static func index(atNs ns: UInt64) -> Int64 { Int64(ns / durationNs) }
}

/// What a meter shows for one source.
public struct AudioLevel: Sendable, Equatable {
    /// The last block's peak, in dBFS (-120 for silence or a meter that stopped).
    public var peakDb: Double
    /// The last block's RMS, in dBFS.
    public var rmsDb: Double
    /// The highest peak of the last 1.5 s, in dBFS.
    public var peakHoldDb: Double
    /// Samples at or above -1 dBFS since the take (or the mic check) began. Before recording
    /// (idle): in the last 1.5 s only (the peak hold), so one clap does not light CLIP for hours.
    public var clipCount: Int
    public var channels: Int
    /// False when no block came for `AudioLevelMonitor.staleAfterNs`: the levels then read -120.
    public var isLive: Bool

    public init(peakDb: Double, rmsDb: Double, peakHoldDb: Double, clipCount: Int, channels: Int, isLive: Bool) {
        self.peakDb = peakDb; self.rmsDb = rmsDb; self.peakHoldDb = peakHoldDb; self.clipCount = clipCount
        self.channels = channels; self.isLive = isLive
    }
}

/// Every meter and the detector at one moment. Small; the UI polls it about 20 times a second.
public struct AudioLevelsSnapshot: Sendable, Equatable {
    /// Nil for a source that never sent a block since the last reset.
    public var cameraMic: AudioLevel?
    public var screenMic: AudioLevel?
    public var systemAudio: AudioLevel?
    public var detector: MicDetectorStatus

    public subscript(source: AudioSource) -> AudioLevel? {
        switch source {
        case .cameraMic: cameraMic
        case .screenMic: screenMic
        case .systemAudio: systemAudio
        }
    }
}

/// The levels of every audio source and the camera mic detector, behind one lock.
///
/// The app makes one and hands it to `CameraRecorder`, `ScreenRecorder` and `MicCheck`. Their
/// meters call `publish(_:from:)` on their capture queues (a few microseconds under the lock);
/// the UI reads `snapshot()`. Nothing here waits for a capture queue, and nothing here touches a
/// capture object.
///
/// Takes: the recorders call `beginTake(events:)` at Start (the detector starts over, and its
/// changes go to that take's events.jsonl as `mic_detector`) and `endTake(events:)` when their
/// file ends (the camera recorder puts the report on camera.mov's mic track in session.json). The
/// take ends when the last recorder that began it ends it: screen.mov that ends early (the stream
/// stopped) leaves the take running for camera.mov. The app calls `closeTake(events:)` once the
/// whole take is over, which also ends a take a recorder began and never ended (a failed start).
///
/// Idle: the idle meters (the metered camera preview, `MacMicMeter`) publish here while nothing
/// records, so the detector runs before Start too and its status can warn then. Nothing is logged
/// while idle. When the camera mic comes back after `idleRestartAfterNs` without a block (the
/// camera closed and opened again), the idle detector starts over, so an old verdict never
/// speaks for a mic that may have changed meanwhile. Takes and mic checks never start over that way.
public final class AudioLevelMonitor: Sendable {
    /// A meter that sent no block for this long reads -120 dBFS and `isLive` false.
    public static let staleAfterNs: UInt64 = 500_000_000
    /// While idle, a camera mic that sent no block for this long starts the detector over.
    public static let idleRestartAfterNs: UInt64 = 2_000_000_000
    /// The peak hold: 1.5 s, in blocks.
    static let holdBlocks = 30

    /// What the detector's evidence is for.
    private enum Phase { case idle, take, check }

    private struct State {
        var camera = SourceMeter()
        var screenMic = SourceMeter()
        var system = SourceMeter()
        var pairer = BlockPairer()
        var detector: CameraMicDetector
        var calibration: MicCalibration?
        var events: EventLog?
        var phase = Phase.idle
        /// The recorders that began the take with `events` and have not ended it yet.
        var takeParticipants = 0
        /// When the last camera mic block arrived (host time), for the idle restart.
        var lastCameraNs: UInt64?
        /// The voice timeline of the take (the replay's Skip silence): fed while a take records.
        var voice = VoiceTimelineBuilder()
    }

    private let state: Mutex<State>

    /// - Parameter calibration: a calibration saved earlier (`MicCalibration`), or nil for the
    ///   default rule (camera L/R correlation 0.88).
    public init(calibration: MicCalibration? = nil) {
        state = Mutex(State(detector: CameraMicDetector(settings: .standard, calibration: calibration),
                            calibration: calibration))
    }

    // MARK: Meters (capture queues)

    /// Takes one block of `source`. Called by the meters on their capture queues; never blocks.
    public func publish(_ block: AudioBlock, from source: AudioSource, receivedNs: UInt64 = HostClock.nowNs()) {
        let (changes, events) = state.withLock { s -> ([MicDetectorChange], EventLog?) in
            if source == .cameraMic {
                if s.phase == .idle, let last = s.lastCameraNs, receivedNs > last, receivedNs - last > Self.idleRestartAfterNs {
                    s.pairer = BlockPairer()
                    s.detector = CameraMicDetector(settings: .standard, calibration: s.calibration)
                }
                s.lastCameraNs = max(s.lastCameraNs ?? 0, receivedNs)
            }
            switch source {
            case .cameraMic: s.camera.add(block, receivedNs: receivedNs)
            case .screenMic: s.screenMic.add(block, receivedNs: receivedNs)
            case .systemAudio: s.system.add(block, receivedNs: receivedNs)
            }
            guard source != .systemAudio else { return ([], nil) }
            if s.phase == .take { s.voice.add(block, from: source) }
            s.pairer.insert(block, isCamera: source == .cameraMic)
            var changes: [MicDetectorChange] = []
            while let pair = s.pairer.popReady() {
                if let change = s.detector.add(camera: pair.camera, reference: pair.reference) { changes.append(change) }
            }
            return (changes, changes.isEmpty ? nil : s.events)
        }
        guard let events else { return }
        for change in changes { events.append(.micDetector, change.eventData) }
    }

    // MARK: UI (any thread)

    /// The meters and the detector now. Cheap: one lock and a small copy.
    public func snapshot(nowNs: UInt64 = HostClock.nowNs()) -> AudioLevelsSnapshot {
        state.withLock { s in
            // Idle, CLIP means a clip in the last 1.5 s; in a take or a check, a clip since it began.
            let recent = s.phase == .idle
            return AudioLevelsSnapshot(cameraMic: s.camera.level(nowNs: nowNs, recentClipsOnly: recent),
                                       screenMic: s.screenMic.level(nowNs: nowNs, recentClipsOnly: recent),
                                       systemAudio: s.system.level(nowNs: nowNs, recentClipsOnly: recent),
                                       detector: s.detector.status)
        }
    }

    /// The detector's state now.
    public var detectorStatus: MicDetectorStatus { state.withLock { $0.detector.status } }

    /// The voice timeline of the take that records now, or of the last take (until the next Start
    /// or `reset()`): the speech stretches of each mic. The copy is made under the lock, so a
    /// capture queue never copies a shared array. About 20 µs for an hour of talking.
    public func voiceTimeline() -> VoiceTimeline { state.withLock { $0.voice.timeline } }

    /// The calibration in use, nil for the default rule.
    public var calibration: MicCalibration? { state.withLock { $0.calibration } }

    /// Uses `calibration` from now on (nil: the default rule). The evidence heard so far stays.
    public func setCalibration(_ calibration: MicCalibration?) {
        state.withLock { s in
            s.calibration = calibration
            s.detector.setCalibration(calibration)
        }
    }

    /// Sets every clip counter back to 0.
    public func resetClipCounts() {
        state.withLock { s in
            s.camera.clipCount = 0
            s.screenMic.clipCount = 0
            s.system.clipCount = 0
        }
    }

    /// Forgets every meter and the detector's evidence, e.g. after the camera or the mic changed.
    public func reset() {
        state.withLock { s in
            s.camera = SourceMeter()
            s.screenMic = SourceMeter()
            s.system = SourceMeter()
            s.pairer = BlockPairer()
            s.detector = CameraMicDetector(settings: .standard, calibration: s.calibration)
            s.events = nil
            s.phase = .idle
            s.takeParticipants = 0
            s.lastCameraNs = nil
            s.voice = VoiceTimelineBuilder()
        }
    }

    // MARK: Takes (recorders)

    /// A take starts: the detector starts over with the standard settings, the clip counters go
    /// to 0, and detector changes go to `events` (`mic_detector`). Called by both recorders at
    /// Start; the second call with the same log only counts the second recorder in.
    public func beginTake(events: EventLog) {
        state.withLock { s in
            guard s.events !== events || s.phase != .take else {
                s.takeParticipants += 1
                return
            }
            s.events = events
            s.phase = .take
            s.takeParticipants = 1
            s.voice = VoiceTimelineBuilder()
            s.pairer = BlockPairer()
            s.detector = CameraMicDetector(settings: .standard, calibration: s.calibration)
            s.camera.clipCount = 0
            s.screenMic.clipCount = 0
            s.system.clipCount = 0
        }
    }

    /// One recorder's file of the take ended: returns the detector's report for session.json (nil
    /// when no camera audio came during the take). The take itself (the voice timeline, the
    /// `mic_detector` log to `events`) goes on until the last recorder that began it ends it, so a
    /// file that ends early never ends the other file's take. Safe to call from both recorders.
    @discardableResult
    public func endTake(events: EventLog) -> MicSourceReport? {
        state.withLock { s in
            if s.events === events, s.phase == .take {
                s.takeParticipants -= 1
                if s.takeParticipants <= 0 { Self.endTake(&s) }
            }
            return s.detector.report()
        }
    }

    /// The whole take with `events` is over (the app, after Stop or a failed start): it ends now,
    /// also when a recorder began it and never ended it.
    public func closeTake(events: EventLog) {
        state.withLock { s in
            if s.events === events, s.phase == .take { Self.endTake(&s) }
        }
    }

    private static func endTake(_ s: inout State) {
        s.events = nil
        s.phase = .idle
        s.takeParticipants = 0
    }

    /// True while a take collects the voice timeline and logs the detector.
    public var takeRuns: Bool { state.withLock { $0.phase == .take } }

    /// The detector's report for the evidence since the take (or the check) began.
    public func takeReport() -> MicSourceReport? { state.withLock { $0.detector.report() } }

    // MARK: Mic check (MicCheck)

    /// A mic check (or a calibration sample) starts: the detector starts over with the shorter
    /// mic-check settings (`MicDetectorSettings.micCheck`), the clip counters go to 0, and nothing
    /// is logged. Nothing from before counts: a second check right after the first measures only
    /// what comes after its own `beginCheck`, whether the mics opened for it or kept running.
    public func beginCheck() {
        state.withLock { s in
            s.events = nil
            s.phase = .check
            s.takeParticipants = 0
            s.pairer = BlockPairer()
            s.detector = CameraMicDetector(settings: .micCheck, calibration: s.calibration)
            s.camera.clipCount = 0
            s.screenMic.clipCount = 0
            s.system.clipCount = 0
        }
    }

    /// The mic check ended: the detector's state and the feature sample it heard (for
    /// `MicCalibration.make(plugged:unplugged:)`). The state stays on show until the next take or
    /// check; live idle meters keep feeding it.
    public func finishCheck() -> (status: MicDetectorStatus, sample: MicFeatureSample) {
        state.withLock { s in
            if s.phase == .check { s.phase = .idle }
            return (s.detector.status, s.detector.sample)
        }
    }
}

/// The meter state of one source. Inside the monitor's lock.
struct SourceMeter {
    var seen = false
    var peakDb = AudioBlock.silenceDb
    var rmsDb = AudioBlock.silenceDb
    var channels = 0
    var clipCount = 0
    var receivedNs: UInt64 = 0
    var latestIndex: Int64 = .min
    /// The peak of each of the last `holdBlocks` blocks, by `index % holdBlocks`.
    private var holdPeaks = [Double](repeating: AudioBlock.silenceDb, count: AudioLevelMonitor.holdBlocks)
    /// The clipped samples of each of the last `holdBlocks` blocks, by the same slot.
    private var holdClips = [Int](repeating: 0, count: AudioLevelMonitor.holdBlocks)
    private var holdIndex = [Int64](repeating: .min, count: AudioLevelMonitor.holdBlocks)

    mutating func add(_ block: AudioBlock, receivedNs: UInt64) {
        seen = true
        peakDb = block.peakDb
        rmsDb = block.rmsDb
        channels = block.channels
        clipCount += block.clipped
        self.receivedNs = receivedNs
        latestIndex = max(latestIndex, block.index)
        let slot = Int(((block.index % Int64(holdPeaks.count)) + Int64(holdPeaks.count)) % Int64(holdPeaks.count))
        if holdIndex[slot] != block.index {
            holdIndex[slot] = block.index
            holdPeaks[slot] = block.peakDb
            holdClips[slot] = block.clipped
        } else {
            holdPeaks[slot] = max(holdPeaks[slot], block.peakDb)
            holdClips[slot] += block.clipped
        }
    }

    private var oldestHeldIndex: Int64 { latestIndex == .min ? Int64.min : latestIndex - Int64(holdPeaks.count) }

    /// The highest peak of the last 1.5 s of blocks.
    var peakHoldDb: Double {
        var hold = AudioBlock.silenceDb
        let oldest = oldestHeldIndex
        for i in holdPeaks.indices where holdIndex[i] > oldest { hold = max(hold, holdPeaks[i]) }
        return hold
    }

    /// Clipped samples in the last 1.5 s of blocks.
    var recentClipCount: Int {
        let oldest = oldestHeldIndex
        return holdClips.indices.reduce(0) { $0 + (holdIndex[$1] > oldest ? holdClips[$1] : 0) }
    }

    /// - Parameter recentClipsOnly: idle: `clipCount` counts the last 1.5 s only, and 0 once the
    ///   meter stopped; else it counts since the take or the check began.
    func level(nowNs: UInt64, recentClipsOnly: Bool = false) -> AudioLevel? {
        guard seen else { return nil }
        let live = nowNs <= receivedNs || nowNs - receivedNs <= AudioLevelMonitor.staleAfterNs
        let silence = AudioBlock.silenceDb
        let clips = recentClipsOnly ? (live ? recentClipCount : 0) : clipCount
        return AudioLevel(peakDb: live ? peakDb : silence, rmsDb: live ? rmsDb : silence,
                          peakHoldDb: live ? peakHoldDb : silence, clipCount: clips, channels: channels, isLive: live)
    }
}

/// Pairs the camera mic's blocks with the screen mic's blocks of the same host-clock time, in
/// block order. Each source delivers its blocks in order on its own queue, at its own latency;
/// a block is handed on once every source that is running has passed it, or once it is
/// `maxWaitBlocks` behind the newest block (a source that stopped holds nothing up). A source
/// that never sent a block is not waited for.
struct BlockPairer {
    static let capacity = 64
    /// A block waits at most this long (1 s) for the other source.
    static let maxWaitBlocks: Int64 = 20

    struct Pair: Equatable {
        var index: Int64
        var camera: AudioBlock?
        var reference: AudioBlock?
    }

    private var slots = [Pair](repeating: Pair(index: .min), count: capacity)
    private var next: Int64?
    private var latestCamera: Int64?
    private var latestReference: Int64?

    private func slot(_ index: Int64) -> Int {
        Int(((index % Int64(Self.capacity)) + Int64(Self.capacity)) % Int64(Self.capacity))
    }

    mutating func insert(_ block: AudioBlock, isCamera: Bool) {
        if next == nil { next = block.index }
        // Counted even when late, so the next block of this source is waited for.
        if isCamera { latestCamera = max(latestCamera ?? .min, block.index) } else {
            latestReference = max(latestReference ?? .min, block.index)
        }
        guard let first = next, block.index >= first else { return }  // Too late: its time was handed on.
        // A long jump (a source started again after a gap): what still waits is over 3 s old
        // (pairs are handed on at most `maxWaitBlocks` behind the newest block). Skip it.
        if block.index - first >= Int64(Self.capacity) {
            next = block.index
            for i in slots.indices { slots[i] = Pair(index: .min) }
        }
        let i = slot(block.index)
        if slots[i].index != block.index { slots[i] = Pair(index: block.index) }
        if isCamera { slots[i].camera = block } else { slots[i].reference = block }
    }

    /// The next pair whose time every running source has passed, in block order.
    mutating func popReady() -> Pair? {
        guard let index = next else { return nil }
        let newest = max(latestCamera ?? .min, latestReference ?? .min)
        guard newest >= index else { return nil }
        let cameraDone = latestCamera.map { $0 >= index } ?? true
        let referenceDone = latestReference.map { $0 >= index } ?? true
        guard (cameraDone && referenceDone) || newest - index >= Self.maxWaitBlocks else { return nil }
        let i = slot(index)
        let pair = slots[i].index == index ? slots[i] : Pair(index: index)
        slots[i] = Pair(index: .min)
        next = index + 1
        return pair
    }
}
