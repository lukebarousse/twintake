// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import CoreMedia
import MediaWriter
import RecorderCore

// GridMath (the exact rational grid arithmetic) lives in MediaWriter, shared with camera.mov.

/// Frame counts for a constant-frame-rate track.
struct CFRStats: Sendable, Equatable {
    /// Grid slots written to the file.
    var written: Int64 = 0
    /// Written slots that repeat the previous picture because no new frame arrived for them.
    var repeated: Int64 = 0
    /// Frames that arrived after their slot was decided (or behind a newer frame). These are real
    /// losses: the manifest's `dropped_frames`.
    var late: Int64 = 0
    /// Frames replaced by a newer frame for the same slot. Expected when the display refreshes
    /// faster than the grid; not a loss.
    var superseded: Int64 = 0
}

/// Turns ScreenCaptureKit's variable-rate frames into a constant-frame-rate sequence.
///
/// Slot `k` is shown at host time `origin + k * frameDuration`. Each captured frame claims a slot
/// (see `GridMath.captureSlot`); a newer frame for the same slot replaces it; slots no frame
/// claims repeat the previous picture. A slot is decided once a later frame
/// arrives or the caller calls `decide(through:)` (a timer, so a static screen still fills the
/// file in real time), and no slot is ever written twice.
///
/// Pure value type: `Frame` is a `CVPixelBuffer` in the recorder and a plain value in tests.
struct CFRGrid<Frame> {
    struct Write {
        let slot: Int64
        let frame: Frame
        let isRepeat: Bool
    }

    enum Offer: Equatable {
        /// The frame now holds this slot.
        case accepted(slot: Int64)
        /// The frame replaced an earlier frame for the same slot.
        case replaced(slot: Int64)
        /// The slot was already decided, or a newer frame is already waiting. Counted as late.
        case late(slot: Int64)
        /// Before the origin and older than the picture for slot 0. Ignored.
        case beforeOrigin
        /// At or after the end slot. Ignored.
        case afterEnd
    }

    private struct Pending {
        var slot: Int64
        var frame: Frame
        var ptsNs: UInt64
        /// A frame from before the origin standing in for slot 0. Replacing it is not a drop.
        var isPreroll: Bool
    }

    private struct Run {
        var start: Int64
        var count: Int64
        var frame: Frame
        var firstIsNew: Bool
    }

    let frameRate: FrameRate
    let originNs: UInt64
    /// One past the last slot of the track, once known.
    private(set) var endSlot: Int64?
    /// Every slot up to and including this one has a picture assigned.
    private(set) var decidedThrough: Int64 = -1
    private(set) var stats = CFRStats()

    private var pending: Pending?
    private var current: Frame?
    private var runs: [Run] = []

    /// - Parameters:
    ///   - originNs: host time of slot 0 (t0).
    ///   - firstFrame: the picture for slot 0, stamped `firstPtsNs`. Pass a frame stamped before
    ///     the origin (see `GridMath.origin`) as a preroll frame.
    init(frameRate: FrameRate, originNs: UInt64, firstFrame: Frame, firstPtsNs: UInt64) {
        self.frameRate = frameRate
        self.originNs = originNs
        pending = Pending(slot: 0, frame: firstFrame, ptsNs: firstPtsNs, isPreroll: firstPtsNs < originNs)
    }

    /// The slot a frame stamped `ptsNs` belongs to.
    func slot(forPtsNs ptsNs: UInt64) -> Int64 {
        GridMath.captureSlot(elapsedNs: GridMath.delta(ptsNs, originNs), frameRate: frameRate)
    }

    /// Offers a newly captured frame. Frames must be offered in capture order.
    @discardableResult
    mutating func offer(_ frame: Frame, ptsNs: UInt64) -> Offer {
        let slot = slot(forPtsNs: ptsNs)
        if let endSlot, slot >= endSlot { return .afterEnd }
        if slot < 0 {
            // A frame from just before t0 that is newer than the preroll picture is a better slot 0.
            guard decidedThrough < 0, let p = pending, p.slot == 0, p.isPreroll, ptsNs > p.ptsNs else {
                return .beforeOrigin
            }
            pending = Pending(slot: 0, frame: frame, ptsNs: ptsNs, isPreroll: true)
            return .replaced(slot: 0)
        }
        if slot <= decidedThrough {
            stats.late += 1
            return .late(slot: slot)
        }
        if let p = pending {
            if slot == p.slot {
                if !p.isPreroll { stats.superseded += 1 }
                pending = Pending(slot: slot, frame: frame, ptsNs: ptsNs, isPreroll: false)
                return .replaced(slot: slot)
            }
            if slot < p.slot {
                stats.late += 1
                return .late(slot: slot)
            }
        }
        decide(through: slot - 1)
        pending = Pending(slot: slot, frame: frame, ptsNs: ptsNs, isPreroll: false)
        return .accepted(slot: slot)
    }

    /// Assigns a picture to every slot up to and including `target` (capped at the end slot).
    /// Call it from a timer with a target safely behind "now", so late frames still find their slot.
    mutating func decide(through target: Int64) {
        var target = target
        if let endSlot { target = min(target, endSlot - 1) }
        guard target > decidedThrough else { return }
        let first = decidedThrough + 1
        if let p = pending, p.slot <= target {
            if p.slot > first {
                if let current {
                    runs.append(Run(start: first, count: p.slot - first, frame: current, firstIsNew: false))
                } else {
                    // Nothing earlier to repeat: back-fill with this frame so the track stays CFR.
                    runs.append(Run(start: first, count: p.slot - first, frame: p.frame, firstIsNew: true))
                }
            }
            let isNew = !(current == nil && p.slot > first)
            runs.append(Run(start: p.slot, count: target - p.slot + 1, frame: p.frame, firstIsNew: isNew))
            current = p.frame
            pending = nil
        } else if let current {
            runs.append(Run(start: first, count: target - first + 1, frame: current, firstIsNew: false))
        } else {
            return
        }
        decidedThrough = target
    }

    /// Sets the end of the track: slots `0..<slot` are written. Never shorter than one frame or
    /// than what is already decided.
    mutating func setEnd(slot: Int64) {
        endSlot = max(slot, decidedThrough + 1, 1)
    }

    /// Decides every remaining slot. Call after `setEnd(slot:)`.
    mutating func decideToEnd() {
        if let endSlot { decide(through: endSlot - 1) }
    }

    /// True when decided slots are waiting to be written.
    var hasWrites: Bool { !runs.isEmpty }

    /// Number of decided slots waiting to be written.
    var queuedWrites: Int64 { runs.reduce(0) { $0 + $1.count } }

    /// The next slot to write, in order. Counts it as written.
    mutating func popWrite() -> Write? {
        guard var run = runs.first else { return nil }
        let write = Write(slot: run.start, frame: run.frame, isRepeat: !run.firstIsNew)
        run.start += 1
        run.count -= 1
        run.firstIsNew = false
        if run.count == 0 { runs.removeFirst() } else { runs[0] = run }
        stats.written += 1
        if write.isRepeat { stats.repeated += 1 }
        return write
    }
}
