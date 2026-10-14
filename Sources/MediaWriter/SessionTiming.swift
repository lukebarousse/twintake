import Foundation
import RecorderCore

/// Timing shared by the video and audio pipelines of one file. Thread-safe.
///
/// The video pipeline fixes the origin (t0, file time 0) from the first frame at or after the
/// scheduled start, and the end slot at Stop. Audio pipelines read both: they trim and pad their
/// samples onto the same timeline, so every track of the file starts at t0 and ends with the video.
package final class SessionTiming: @unchecked Sendable {
    package let frameRate: FrameRate
    /// Host time when the file may begin: the scheduled start shared by both files, or the moment
    /// writing began. The file begins at the first frame at or after it.
    package let startNs: UInt64

    private let lock = NSLock()
    private var origin: UInt64?
    private var stop: UInt64?
    private var end: Int64?

    package init(frameRate: FrameRate, startNs: UInt64) {
        self.frameRate = frameRate
        self.startNs = startNs
    }

    /// Host time of video slot 0 (t0, file time 0), once the first frame fixed it.
    package var originNs: UInt64? { lock.withLock { origin } }
    /// Host time when Stop was pressed.
    package var stopNs: UInt64? { lock.withLock { stop } }
    /// One past the last video slot, once Stop fixed it.
    package var endSlot: Int64? { lock.withLock { end } }

    package func setOrigin(_ ns: UInt64) { lock.withLock { if origin == nil { origin = ns } } }
    package func setStop(_ ns: UInt64) { lock.withLock { if stop == nil { stop = ns } } }
    package func setEndSlot(_ slot: Int64) { lock.withLock { end = slot } }

    /// Where audio sample 0 sits: t0, or the start time when no video frame ever arrived.
    package var audioOriginNs: UInt64 { originNs ?? startNs }

    /// One past the last audio sample, so audio ends with the video. Nil until Stop.
    package func audioEndFrame(sampleRate: Int) -> Int64? {
        if let endSlot {
            return GridMath.audioFrames(atSlot: endSlot, frameRate: frameRate, sampleRate: sampleRate)
        }
        guard originNs == nil, let stopNs else { return nil }
        return max(0, GridMath.audioFrames(elapsedNs: GridMath.delta(stopNs, startNs), sampleRate: sampleRate))
    }
}

/// The start both files share. The app picks one host time a little in the future; each recorder
/// gets ready before it (writer created, encoder set up) and begins its file at its first frame
/// at or after it, so camera.mov and screen.mov start within one camera frame of each other.
package enum ScheduledStart {
    /// The host time the file may begin at: the scheduled time, or now when none was given. A
    /// time that has already passed stays as it is: the file then begins at the first frame the
    /// ready recorder still has (the newest screen frame, the next camera frame).
    package static func startNs(scheduledNs: UInt64?, nowNs: UInt64) -> UInt64 {
        scheduledNs ?? nowNs
    }

    /// How late a recorder got ready for its scheduled start, in nanoseconds (0 when on time).
    package static func lateNs(scheduledNs: UInt64?, readyNs: UInt64) -> UInt64 {
        guard let scheduledNs, readyNs > scheduledNs else { return 0 }
        return readyNs - scheduledNs
    }
}
