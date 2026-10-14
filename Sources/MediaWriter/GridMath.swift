// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import CoreMedia
import RecorderCore

/// Exact arithmetic on a rational frame-rate grid, in host-clock nanoseconds.
///
/// BetterCapture snaps frames with an integer frame rate and a 600 timescale, so 23.976 becomes 23.
/// Here slot `k` starts exactly `k * den / num` seconds after the grid origin, and 128-bit
/// intermediates keep the math exact for recordings of any realistic length.
package enum GridMath {
    package static let nsPerSecond: Int128 = 1_000_000_000

    /// `a - b` for two host times, negative when `a` is earlier.
    package static func delta(_ a: UInt64, _ b: UInt64) -> Int64 {
        a >= b ? Int64(a - b) : -Int64(b - a)
    }

    /// `base + offset`, clamped at 0.
    package static func add(_ base: UInt64, _ offset: Int64) -> UInt64 {
        offset >= 0 ? base + UInt64(offset) : base - min(base, UInt64(-offset))
    }

    /// The slot nearest to a time measured from the grid origin. Negative before the origin.
    package static func nearestSlot(elapsedNs: Int64, frameRate: FrameRate) -> Int64 {
        Int64(roundedDivide(Int128(elapsedNs) * Int128(frameRate.num), Int128(frameRate.den) * nsPerSecond))
    }

    /// A time measured from the grid origin in thousandths of a frame, rounded. 1000 is one frame.
    package static func milliFrames(elapsedNs: Int64, frameRate: FrameRate) -> Int64 {
        Int64(roundedDivide(Int128(elapsedNs) * Int128(frameRate.num) * 1000, Int128(frameRate.den) * nsPerSecond))
    }

    /// The slot a frame captured at `elapsedNs` (from the origin) belongs to: slot `k` takes frames
    /// from `k - 3/4` to `k + 1/4` frames. Negative before the origin.
    ///
    /// A frame on the grid lattice lands mid-window, so jitter of up to a quarter frame either way
    /// is harmless. Frames that arrive at twice the grid rate (a 47.95 Hz display under a 23.976
    /// grid, or ScreenCaptureKit's up-to-2x delivery) fall at `k` and `k - 1/2`, never on a window
    /// edge, so slot `k` always gets the frame captured at `k`. Nearest rounding would put the
    /// `k + 1/2` frames on the edge and let jitter pick the slot.
    package static func captureSlot(elapsedNs: Int64, frameRate: FrameRate) -> Int64 {
        let scale = Int128(frameRate.den) * nsPerSecond
        return Int64(ceilingDivide(4 * Int128(elapsedNs) * Int128(frameRate.num) - scale, 4 * scale))
    }

    /// The first slot that starts at or after a time measured from the grid origin.
    package static func slotAtOrAfter(elapsedNs: Int64, frameRate: FrameRate) -> Int64 {
        Int64(ceilingDivide(Int128(elapsedNs) * Int128(frameRate.num), Int128(frameRate.den) * nsPerSecond))
    }

    /// Start of slot `slot` measured from the origin, rounded to the nearest nanosecond.
    package static func offsetNs(ofSlot slot: Int64, frameRate: FrameRate) -> Int64 {
        Int64(roundedDivide(Int128(slot) * Int128(frameRate.den) * nsPerSecond, Int128(frameRate.num)))
    }

    /// Audio samples from the origin to the start of video slot `slot`, rounded to the nearest
    /// sample. Exactly 1001 samples per frame at 47.952 fps and 48 kHz, 2002 at 23.976.
    package static func audioFrames(atSlot slot: Int64, frameRate: FrameRate, sampleRate: Int) -> Int64 {
        Int64(roundedDivide(Int128(slot) * Int128(frameRate.den) * Int128(sampleRate), Int128(frameRate.num)))
    }

    /// Samples from the origin to a time measured from the origin, rounded to the nearest sample.
    package static func audioFrames(elapsedNs: Int64, sampleRate: Int) -> Int64 {
        Int64(roundedDivide(Int128(elapsedNs) * Int128(sampleRate), nsPerSecond))
    }

    /// Duration of `frames` samples in nanoseconds, rounded to the nearest nanosecond.
    package static func ns(ofAudioFrames frames: Int64, sampleRate: Int) -> Int64 {
        Int64(roundedDivide(Int128(frames) * nsPerSecond, Int128(sampleRate)))
    }

    /// Picks the grid origin (t0) from the newest frame seen before or at Start.
    ///
    /// ScreenCaptureKit sends a frame only when the screen changes, so on a static screen the
    /// first frame after Start can be seconds late. The newest earlier frame is what the screen
    /// showed at Start, so the grid starts at the first point of that frame's vsync lattice at or
    /// after Start and that frame fills slot 0. Staying on the lattice keeps later frames, which
    /// arrive on the same vsync lattice, in phase with the grid. A frame stamped at or after Start
    /// is itself the origin.
    package static func origin(startNs: UInt64, framePtsNs: UInt64, frameRate: FrameRate) -> UInt64 {
        guard startNs > framePtsNs else { return framePtsNs }
        let k = slotAtOrAfter(elapsedNs: Int64(startNs - framePtsNs), frameRate: frameRate)
        return framePtsNs + UInt64(offsetNs(ofSlot: k, frameRate: frameRate))
    }

    package static func roundedDivide(_ n: Int128, _ d: Int128) -> Int128 {
        n >= 0 ? (n + d / 2) / d : -((-n + d / 2) / d)
    }

    package static func ceilingDivide(_ n: Int128, _ d: Int128) -> Int128 {
        n >= 0 ? (n + d - 1) / d : -(-n / d)
    }

    /// Nanoseconds as milliseconds with one decimal, for events.jsonl: "12.5".
    package static func ms(_ ns: Int64) -> String { String(format: "%.1f", Double(ns) / 1_000_000) }
}
