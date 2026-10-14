import Testing
@testable import MediaWriter
@testable import ScreenCapture

private let t0: UInt64 = 50_000_000_000
private let ms: UInt64 = 1_000_000

private func at(_ offsetNs: Int64) -> UInt64 { UInt64(Int64(t0) + offsetNs) }

@Suite struct AudioAlignerTests {
    @Test func headIsPaddedWithSilenceWhenAudioStartsLate() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        let plan = a.plan(ptsNs: t0 + 300 * ms, frameCount: 1024)
        #expect(plan == .init(padFrames: 14_400, trimFrames: 0, keepFrames: 1024, position: 0))
        #expect(a.position == 15_424)
        // Head padding is not a gap.
        #expect(a.gapPaddedFrames == 0)
    }

    @Test func headIsTrimmedWhenAudioStartsEarly() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        let plan = a.plan(ptsNs: at(-10_000_000), frameCount: 1024)
        #expect(plan == .init(padFrames: 0, trimFrames: 480, keepFrames: 544, position: 0))
        #expect(a.position == 544)
    }

    @Test func buffersBeforeTheOriginAreDropped() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        #expect(a.plan(ptsNs: at(-100_000_000), frameCount: 1024) == nil)
        #expect(!a.started)
        // The next buffer still starts the track exactly at t0.
        let plan = a.plan(ptsNs: at(-5_000_000), frameCount: 1024)
        #expect(plan?.trimFrames == 240)
        #expect(plan?.position == 0)
    }

    @Test func jitterWithinToleranceKeepsSamplesBackToBack() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        _ = a.plan(ptsNs: t0, frameCount: 480)
        // 2 ms late and 3 ms early: both inside the 10 ms tolerance.
        let late = a.plan(ptsNs: t0 + 12 * ms, frameCount: 480)
        #expect(late == .init(padFrames: 0, trimFrames: 0, keepFrames: 480, position: 480))
        let early = a.plan(ptsNs: t0 + 17 * ms, frameCount: 480)
        #expect(early == .init(padFrames: 0, trimFrames: 0, keepFrames: 480, position: 960))
        #expect(a.position == 1440)
    }

    @Test func gapsArePaddedAndOverlapsTrimmed() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        _ = a.plan(ptsNs: t0, frameCount: 4800)  // 0-100 ms
        let gap = a.plan(ptsNs: t0 + 200 * ms, frameCount: 4800)  // 100 ms of nothing
        #expect(gap == .init(padFrames: 4800, trimFrames: 0, keepFrames: 4800, position: 4800))
        let overlap = a.plan(ptsNs: t0 + 250 * ms, frameCount: 4800)  // 50 ms over what is written
        #expect(overlap == .init(padFrames: 0, trimFrames: 2400, keepFrames: 2400, position: 14_400))
        #expect(a.gapPaddedFrames == 4800)
        #expect(a.overlapTrimmedFrames == 2400)
        // Entirely inside what is already written.
        #expect(a.plan(ptsNs: t0 + 100 * ms, frameCount: 480) == nil)
        #expect(a.droppedBuffers == 1)
    }

    @Test func endFrameCapsTheTrackAndTailPadsToIt() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        a.endFrame = 2000
        #expect(a.plan(ptsNs: t0, frameCount: 1024)?.keepFrames == 1024)
        #expect(a.plan(ptsNs: t0 + 21_333_333, frameCount: 1024)?.keepFrames == 976)
        #expect(a.plan(ptsNs: t0 + 42_666_667, frameCount: 1024) == nil)
        #expect(a.planTail() == nil)
        #expect(a.position == 2000)

        var short = AudioAligner(originNs: t0, sampleRate: 48000)
        _ = short.plan(ptsNs: t0, frameCount: 1024)
        // 10 video frames at 47.952 fps is exactly 10010 samples.
        short.endFrame = GridMath.audioFrames(atSlot: 10, frameRate: .fps47_952, sampleRate: 48000)
        #expect(short.planTail() == .init(padFrames: 10_010 - 1024, trimFrames: 0, keepFrames: 0, position: 1024))
        #expect(short.position == 10_010)
    }

    @Test func trackWithNoAudioBecomesSilenceOfTheVideoLength() {
        var a = AudioAligner(originNs: t0, sampleRate: 48000)
        a.endFrame = 48_048
        #expect(a.planTail() == .init(padFrames: 48_048, trimFrames: 0, keepFrames: 0, position: 0))
    }

    @Test func deviceClockDriftNeverExceedsTheTolerance() {
        // A mic whose clock runs 100 ppm slow and one 100 ppm fast, for 10 minutes.
        for ppm in [-100.0, 100.0] {
            var a = AudioAligner(originNs: t0, sampleRate: 48000)
            let frames: Int64 = 480
            let bufferNs = 10_000_000.0 * (1 + ppm / 1e6)
            for i in 0..<60_000 {
                let pts = t0 + UInt64((Double(i) * bufferNs).rounded())
                guard let plan = a.plan(ptsNs: pts, frameCount: frames) else { continue }
                let expected = GridMath.audioFrames(elapsedNs: Int64(pts - t0), sampleRate: 48000)
                // The first kept sample sits within the tolerance of where its timestamp says.
                #expect(abs(plan.position + plan.padFrames - (expected + plan.trimFrames)) <= a.toleranceFrames)
            }
            let elapsed = Int64(60_000.0 * bufferNs)
            let drift = a.position - GridMath.audioFrames(elapsedNs: elapsed, sampleRate: 48000)
            #expect(abs(drift) <= a.toleranceFrames)
            // A fast device overlaps; with 480-sample buffers the overlap removes whole buffers.
            if ppm > 0 { #expect(a.gapPaddedFrames > 0) } else { #expect(a.overlapTrimmedFrames + Int64(a.droppedBuffers) > 0) }
        }
    }
}
