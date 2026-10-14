import CoreMedia
import Foundation
import MediaWriter
import RecorderCore
import Synchronization

// camera.mov is written on an exact rational grid (1001/24000 s per slot at 23.976) that follows
// real time. Three pure parts, so the timing rules are unit tested without a camera:
//
// 1. FrameClockRecovery puts each frame on real host time. Some devices stamp frames with a
//    nominal interval: the Cam Link 4K stamps exactly 1251/30000 s (41.700 ms, 23.98 fps) per
//    frame while the HDMI signal really runs at 23.976 (41.708 ms). Those stamps drift from real
//    time by 0.7 s an hour, and so would the picture against the 48 kHz camera audio.
// 2. CameraSlotter puts each frame in a grid slot: one frame per slot, a repeat of the last
//    picture for a slot no frame reached, and a skipped frame when two reach the same slot.
// 3. FrameRateMeter measures the rate the timestamps run at and the rate frames really arrive at,
//    for track_stop and the drift warning.

/// Corrects camera frame timestamps for a device clock that runs at another rate than the host.
///
/// A frame's latency is its arrival time minus its timestamp (both on the host clock). Frames can
/// arrive late (USB transfer, scheduling) but never early, so the smallest latency in a block of
/// frames is the clean one, and the median of the last few block minima is the latency now; one
/// odd block does not move it. With a correct device clock it stays put. With a device that stamps
/// a nominal interval it grows (or shrinks) steadily: that change is the drift.
///
/// The reference is the latency when the stream began (the smallest block minimum of its first
/// `referenceBlocks` blocks, so a slow first second does not count), when the device's
/// timestamps still matched real time. The corrected time of a frame is its timestamp plus the
/// change of the latency since then. So the file keeps the device's smooth frame spacing and
/// follows real time, also when the camera ran in the preview for an hour before the take: one
/// recovery follows the whole device stream (`StreamClock`), fed by whichever output delivers
/// its frames.
///
/// Two outputs (the preview output and the recording output) can deliver the same frame. A
/// frame stamped within `sameFrameToleranceNs` of the newest one, or up to `olderFrameWindowNs`
/// before it, is that same frame (or an older one from the slower output): its latency counts
/// in the block minimum, but it is not a new frame.
struct FrameClockRecovery: Sendable, Equatable {
    /// Frames per block (about one second at 23.976).
    static let blockFrames = 24
    /// Blocks in the median (odd). The estimate lags a steady drift by about half of them: 4.5 s,
    /// under 1 ms for the Cam Link's 0.02%.
    static let windowBlocks = 9
    /// The reference is the smallest of the first this many block minima.
    static let referenceBlocks = 5
    /// A frame stamped no more than this after the newest frame is the same frame from another output.
    static let sameFrameToleranceNs: Int64 = 2_000_000
    /// A frame stamped up to this much before the newest frame is an older frame from the slower
    /// output. Further back is a new stream (the device restarted its timestamps).
    static let olderFrameWindowNs: Int64 = 250_000_000

    private(set) var blockMinima: [Int64] = []
    private var blockMin = Int64.max
    private var blockCount = 0
    private var completedBlocks = 0
    /// The latency when the stream began. Nil until the first block is complete.
    private(set) var referenceNs: Int64?
    /// Frames counted, each once (a frame delivered by two outputs counts once).
    private(set) var frames = 0
    private var newestPtsNs: UInt64?

    /// The latency now: the lower median of the last block minima, or the running minimum while
    /// the first block fills. Nil before the first frame. With an even count the lower middle
    /// value is the median, like the minimum-based reference, so a slow first block never moves
    /// the correction while the reference settles (the first `referenceBlocks` blocks).
    var latencyNs: Int64? {
        if blockMinima.isEmpty { return blockCount > 0 ? blockMin : nil }
        let sorted = blockMinima.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// How far real time has moved from the timestamps since the stream began: 0 until the first
    /// block is complete.
    var correctionNs: Int64 {
        guard let referenceNs, let latencyNs else { return 0 }
        return latencyNs - referenceNs
    }

    /// Takes one frame (timestamp and arrival on the host clock) and returns its corrected time.
    mutating func observe(ptsNs: UInt64, arrivalNs: UInt64) -> UInt64 {
        let latency = GridMath.delta(arrivalNs, ptsNs)
        if let newest = newestPtsNs {
            let step = GridMath.delta(ptsNs, newest)
            if step <= Self.sameFrameToleranceNs, step >= -Self.olderFrameWindowNs {
                // The same frame from the other output: its latency counts, the frame does not.
                blockMin = min(blockMin, latency)
                return corrected(ptsNs)
            }
        }
        newestPtsNs = ptsNs
        frames += 1
        blockMin = min(blockMin, latency)
        blockCount += 1
        if blockCount >= Self.blockFrames {
            blockMinima.append(blockMin)
            if blockMinima.count > Self.windowBlocks { blockMinima.removeFirst() }
            if completedBlocks < Self.referenceBlocks { referenceNs = min(referenceNs ?? .max, blockMin) }
            completedBlocks += 1
            blockMin = .max
            blockCount = 0
        }
        return corrected(ptsNs)
    }

    /// `ptsNs` on real time.
    func corrected(_ ptsNs: UInt64) -> UInt64 { GridMath.add(ptsNs, correctionNs) }
}

/// The clock recovery of one open camera stream: one per capture session (`CaptureGraph`),
/// shared by every output that delivers its frames. In the preview graph the preview output feeds
/// it; in the recording graph the recording output does (and the preview output too while it
/// stays). Each take's `CameraVideoPipeline` uses it, so a take that starts after the camera ran
/// in the preview (the camera window on between takes) corrects for all the drift since the
/// stream began, not only for the drift since its recording output joined.
///
/// Thread-safe: the outputs call it on their own queues. Every call holds the lock only for the
/// arithmetic.
final class StreamClock: Sendable {
    private struct State {
        var recovery = FrameClockRecovery()
        /// Maps preview frame timestamps (on the session clock) to host time. Nil while the session
        /// clock is unknown or changing: preview frames are then not counted.
        var previewMapper: HostTimeMapper?
    }

    private let state = Mutex(State())

    init() {}

    /// Takes one frame (timestamp and arrival on the host clock) and returns its corrected time.
    func observe(ptsNs: UInt64, arrivalNs: UInt64) -> UInt64 {
        state.withLock { $0.recovery.observe(ptsNs: ptsNs, arrivalNs: arrivalNs) }
    }

    /// `ptsNs` on real time.
    func corrected(_ ptsNs: UInt64) -> UInt64 { state.withLock { $0.recovery.corrected(ptsNs) } }

    /// Real time minus the timestamps, since the stream began.
    var correctionNs: Int64 { state.withLock { $0.recovery.correctionNs } }

    /// Frames counted since the stream began (or the last reset).
    var frames: Int { state.withLock { $0.recovery.frames } }

    /// The device stream started over (the camera format was set again): a new reference.
    func reset() { state.withLock { $0.recovery = FrameClockRecovery() } }

    /// The session clock preview frames are stamped on (`synchronizationClock`). Camera queue,
    /// after the session started or changed.
    func setPreviewClock(_ clock: CMClock?) {
        let mapper = HostTimeMapper(clock: clock)
        state.withLock { $0.previewMapper = mapper }
    }

    /// Stops counting preview frames until `setPreviewClock`, while the session changes (its clock
    /// can change at the commit). Camera queue.
    func pausePreview() { state.withLock { $0.previewMapper = nil } }

    /// A frame from the preview output, which arrived at `arrivalNs`. On the preview queue.
    func observePreview(_ sampleBuffer: CMSampleBuffer, arrivalNs: UInt64) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        state.withLock { s in
            guard let mapper = s.previewMapper, let ptsNs = mapper.hostNs(pts) else { return }
            _ = s.recovery.observe(ptsNs: ptsNs, arrivalNs: arrivalNs)
        }
    }
}

/// Counts for camera.mov's constant-frame-rate video track.
struct CameraGridStats: Sendable, Equatable {
    /// Slots that got a new frame.
    var framesWritten: Int64 = 0
    /// Slots that repeat the previous picture: a gap in the frames, a stall, the tail at Stop.
    var slotsRepeated: Int64 = 0
    /// Frames that reached a slot that already had one (the camera sent more frames than slots).
    var slotsSkipped: Int64 = 0
    /// Frames that came after the stall timer had already repeated the picture for their slot.
    var lateFrames: Int64 = 0

    /// Every slot in the file.
    var slotsWritten: Int64 { framesWritten + slotsRepeated }
}

/// Puts camera frames into the slots of an exact grid that starts at `originNs`, one frame per slot.
///
/// The next frame normally takes the next slot. Only when its corrected time is more than half a
/// frame plus `hysteresisMilliFrames` away from that slot does the grid catch up: later, it repeats
/// the last picture for the slots in between; earlier, it skips the frame. The hysteresis keeps
/// timestamp jitter at a slot edge from repeating and skipping by turns, and after a catch-up the
/// next frames sit a quarter frame inside the window. A frame is never more than 0.75 frame (31 ms
/// at 23.976) from its slot, so the grid never drifts from real time.
struct CameraSlotter: Sendable, Equatable {
    enum Placement: Sendable, Equatable {
        /// Write the frame at `slot`. First repeat the previous picture for the `repeats` slots before it.
        case write(slot: Int64, repeats: Int64)
        /// The frame's slot already has a frame: more frames than slots. Not written.
        case skip
        /// The stall timer already repeated the picture for this frame's slot. Not written.
        case late
        /// At or after the end slot. Not written.
        case afterEnd
    }

    /// Drift allowed past half a frame before a slot is repeated or a frame skipped: 0.25 frame.
    static let hysteresisMilliFrames: Int64 = 250

    let frameRate: FrameRate
    let originNs: UInt64
    /// The next slot to fill. Every slot before it is written.
    private(set) var nextSlot: Int64 = 0
    /// One past the last slot, once Stop fixed it.
    private(set) var endSlot: Int64?
    private(set) var stats = CameraGridStats()
    /// The first slot the stall timer repeated since the last new frame.
    private var timerFilledFrom: Int64?

    init(frameRate: FrameRate, originNs: UInt64) {
        self.frameRate = frameRate
        self.originNs = originNs
    }

    /// Where a frame with corrected time `correctedNs` goes.
    mutating func place(correctedNs: UInt64) -> Placement {
        let position = GridMath.milliFrames(elapsedNs: GridMath.delta(correctedNs, originNs), frameRate: frameRate)
        let offset = position - nextSlot * 1000
        let limit = 500 + Self.hysteresisMilliFrames
        var slot = nextSlot
        if offset > limit {
            slot = Int64(GridMath.roundedDivide(Int128(position), 1000))
        } else if offset < -limit {
            let nearest = Int64(GridMath.roundedDivide(Int128(position), 1000))
            if let from = timerFilledFrom, nearest >= from {
                stats.lateFrames += 1
                return .late
            }
            stats.slotsSkipped += 1
            return .skip
        }
        if let endSlot, slot >= endSlot { return .afterEnd }
        let repeats = slot - nextSlot
        stats.slotsRepeated += repeats
        stats.framesWritten += 1
        nextSlot = slot + 1
        timerFilledFrom = nil
        return .write(slot: slot, repeats: repeats)
    }

    /// Repeats the last picture through slot `target` (capped at the end), for a camera that
    /// stopped sending frames. Returns how many slots it repeated.
    mutating func fill(through target: Int64) -> Int64 {
        var target = target
        if let endSlot { target = min(target, endSlot - 1) }
        guard target >= nextSlot else { return 0 }
        let count = target - nextSlot + 1
        if timerFilledFrom == nil { timerFilledFrom = nextSlot }
        stats.slotsRepeated += count
        nextSlot = target + 1
        return count
    }

    /// Sets the end: slots `0..<slot` are in the file. Never shorter than what is written, or one frame.
    mutating func setEnd(slot: Int64) {
        endSlot = max(slot, nextSlot, 1)
    }

    /// True when every slot up to the end is written.
    var isComplete: Bool { endSlot.map { nextSlot >= $0 } ?? false }

    /// Repeats the last picture up to the end. Returns how many slots it repeated.
    mutating func fillToEnd() -> Int64 {
        guard let endSlot else { return 0 }
        return fill(through: endSlot - 1)
    }

    /// The slot nearest to a host time.
    func nearestSlot(atNs ns: UInt64) -> Int64 {
        GridMath.nearestSlot(elapsedNs: GridMath.delta(ns, originNs), frameRate: frameRate)
    }

    /// The first slot that starts at or after a host time.
    func slotAtOrAfter(atNs ns: UInt64) -> Int64 {
        GridMath.slotAtOrAfter(elapsedNs: GridMath.delta(ns, originNs), frameRate: frameRate)
    }
}

/// Measures the rate a camera's timestamps run at and the rate its frames really arrive at, by a
/// least-squares line through each against the frame count. Late arrivals only add noise, and a
/// gap counts as the frames it lost, so drops do not change either rate.
struct FrameRateMeter: Sendable, Equatable {
    /// Rates are compared once the frames span this long; shorter takes measure too noisily.
    static let minimumSpanNs: UInt64 = 30_000_000_000
    /// The two rates may differ by this much (0.01%) before the recorder warns.
    static let mismatchLimit = 0.0001

    /// One nominal frame interval, for counting frames across a gap.
    let nominalNs: Double
    private(set) var frames = 0
    private var index: Int64 = 0
    private var firstPts: UInt64 = 0
    private var firstArrival: UInt64 = 0
    private var lastPts: UInt64 = 0
    private var sx = 0.0, sxx = 0.0, sp = 0.0, sxp = 0.0, sa = 0.0, sxa = 0.0

    init(frameRate: FrameRate) {
        nominalNs = 1e9 * Double(frameRate.den) / Double(frameRate.num)
    }

    mutating func add(ptsNs: UInt64, arrivalNs: UInt64) {
        if frames == 0 {
            firstPts = ptsNs
            firstArrival = arrivalNs
        } else {
            let steps = (Double(GridMath.delta(ptsNs, lastPts)) / nominalNs).rounded()
            index += max(1, Int64(steps))
        }
        let x = Double(index)
        let p = Double(GridMath.delta(ptsNs, firstPts))
        let a = Double(GridMath.delta(arrivalNs, firstArrival))
        sx += x; sxx += x * x; sp += p; sxp += x * p; sa += a; sxa += x * a
        lastPts = ptsNs
        frames += 1
    }

    /// Time the timestamps span, first to last frame.
    var spanNs: UInt64 { frames > 1 ? UInt64(max(0, GridMath.delta(lastPts, firstPts))) : 0 }

    private func slope(_ sy: Double, _ sxy: Double) -> Double? {
        let n = Double(frames)
        let denominator = n * sxx - sx * sx
        guard frames >= 2, denominator > 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator
        return slope > 0 ? slope : nil
    }

    /// Frames per second the timestamps run at.
    var ptsFps: Double? { slope(sp, sxp).map { 1e9 / $0 } }
    /// Frames per second the frames arrive at (host clock).
    var arrivalFps: Double? { slope(sa, sxa).map { 1e9 / $0 } }

    /// arrival rate / timestamp rate - 1, once the frames span `minimumSpanNs`; else nil.
    var mismatch: Double? {
        guard spanNs >= Self.minimumSpanNs, let p = ptsFps, let a = arrivalFps else { return nil }
        return a / p - 1
    }

    /// True when the two rates differ by more than `mismatchLimit`.
    var exceedsLimit: Bool { (mismatch.map { abs($0) > Self.mismatchLimit }) ?? false }
}
