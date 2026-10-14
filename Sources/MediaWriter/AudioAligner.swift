import RecorderCore

/// Keeps one audio track aligned to the video grid by trimming and padding whole samples.
///
/// Positions count samples from the grid origin (t0), which is file time 0. A buffer's host-clock
/// PTS says where its first sample belongs; the aligner compares that with where the track has
/// got to. The first buffer is placed exactly: silence fills the head when it starts after t0, and
/// samples before t0 are cut. After that, differences within `toleranceFrames` are timestamp jitter
/// and are ignored (samples are written back to back); a larger gap is filled with silence and a
/// larger overlap is cut. So drift between the audio device clock and the host clock never puts a
/// track more than the tolerance away from the video.
package struct AudioAligner: Sendable, Equatable {
    /// What to write for one buffer: `padFrames` of silence at `position`, then the buffer's
    /// samples `trimFrames ..< trimFrames + keepFrames` right after it.
    package struct Plan: Sendable, Equatable {
        package var padFrames: Int64
        package var trimFrames: Int64
        package var keepFrames: Int64
        package var position: Int64
    }

    package let originNs: UInt64
    package let sampleRate: Int
    package let toleranceFrames: Int64
    /// One past the last sample of the track, once the video end is known.
    package var endFrame: Int64?

    /// Samples written so far, silence included. The next sample goes here.
    package private(set) var position: Int64 = 0
    package private(set) var started = false
    /// Silence inserted after the head, for gaps longer than the tolerance.
    package private(set) var gapPaddedFrames: Int64 = 0
    /// Samples cut after the head, for overlaps longer than the tolerance.
    package private(set) var overlapTrimmedFrames: Int64 = 0
    package private(set) var droppedBuffers = 0

    /// - Parameter toleranceFrames: defaults to 10 ms of samples.
    package init(originNs: UInt64, sampleRate: Int, toleranceFrames: Int64? = nil) {
        self.originNs = originNs
        self.sampleRate = sampleRate
        self.toleranceFrames = toleranceFrames ?? Int64(sampleRate / 100)
    }

    /// Plans one buffer of `frameCount` samples whose first sample is stamped `ptsNs`.
    /// Returns nil when nothing of it belongs in the file.
    package mutating func plan(ptsNs: UInt64, frameCount: Int64) -> Plan? {
        guard frameCount > 0 else { return nil }
        let start = GridMath.audioFrames(elapsedNs: GridMath.delta(ptsNs, originNs), sampleRate: sampleRate)
        var pad: Int64 = 0
        var trim: Int64 = 0
        if !started {
            if start > 0 { pad = start } else { trim = -start }
        } else {
            let gap = start - position
            if gap > toleranceFrames { pad = gap } else if gap < -toleranceFrames { trim = -gap }
        }
        if trim >= frameCount {
            if started { droppedBuffers += 1 }
            return nil
        }
        var keep = frameCount - trim
        if let endFrame {
            let room = max(0, endFrame - position)
            pad = min(pad, room)
            keep = min(keep, room - pad)
            if pad == 0 && keep == 0 { return nil }
        }
        if started {
            gapPaddedFrames += pad
            overlapTrimmedFrames += trim
        }
        let plan = Plan(padFrames: pad, trimFrames: trim, keepFrames: keep, position: position)
        position += pad + keep
        started = true
        return plan
    }

    /// Silence that brings the track up to `endFrame`, so it ends with the video.
    package mutating func planTail() -> Plan? {
        guard let endFrame, position < endFrame else { return nil }
        let plan = Plan(padFrames: endFrame - position, trimFrames: 0, keepFrames: 0, position: position)
        position = endFrame
        started = true
        return plan
    }
}
