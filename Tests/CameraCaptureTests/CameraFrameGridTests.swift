import Foundation
import Testing
@testable import CameraCapture
@testable import MediaWriter
import RecorderCore

/// A simulated capture card: frames really leave the camera every `realPeriodNs` (on the host
/// clock), the device stamps them every `stampPeriodNs`, and they arrive `latencyNs` plus jitter later.
struct SimulatedCamera {
    var baseNs: UInt64 = 1_000_000_000_000
    /// Real frame interval in ns, as a rational: 1001/24000 s is 1_001_000_000_000 / 24_000.
    var realNumerator: Int128 = 1_001_000_000_000
    var realDenominator: Int128 = 24_000
    /// The device stamps this interval: the Cam Link's 1251/30000 s.
    var stampNumerator: Int128 = 1_251_000_000_000
    var stampDenominator: Int128 = 30_000
    var latencyNs: UInt64 = 30_000_000
    /// Arrival jitter: up to this much late, plus a 40 ms spike every 997 frames.
    var jitterNs: UInt64 = 8_000_000

    func realNs(_ n: Int64) -> UInt64 { baseNs + UInt64(Int128(n) * realNumerator / realDenominator) }
    func ptsNs(_ n: Int64) -> UInt64 { baseNs + UInt64(Int128(n) * stampNumerator / stampDenominator) }

    func arrivalNs(_ n: Int64) -> UInt64 {
        // A fixed pseudo-random sequence, so every run is the same.
        var x = UInt64(bitPattern: n) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        x ^= x >> 29
        let jitter = x % (jitterNs + 1)
        let spike: UInt64 = n % 997 == 500 ? 40_000_000 : 0
        return realNs(n) + latencyNs + jitter + spike
    }
}

/// Runs frames `0..<frames` of `camera` through the clock recovery and, from frame `fileStart` on,
/// the slotter. Returns the grid, and the largest distance between a frame's real time and the
/// grid time of the slot it went into (both measured from the file's start).
private func run(_ camera: SimulatedCamera, frames: Int64, fileStart: Int64, rate: FrameRate = .fps23_976,
                 skip: (Int64) -> Bool = { _ in false }, correct: Bool = true)
    -> (grid: CameraSlotter, maxErrorNs: Int64, recovery: FrameClockRecovery, meter: FrameRateMeter) {
    var recovery = FrameClockRecovery()
    var grid: CameraSlotter?
    var meter = FrameRateMeter(frameRate: rate)
    var maxError: Int64 = 0
    var firstReal: UInt64 = 0
    for n in 0..<frames where !skip(n) {
        let pts = camera.ptsNs(n), arrival = camera.arrivalNs(n)
        let corrected = correct ? recovery.observe(ptsNs: pts, arrivalNs: arrival) : pts
        guard n >= fileStart else { continue }
        if grid == nil {
            grid = CameraSlotter(frameRate: rate, originNs: corrected)
            firstReal = camera.realNs(n)
        }
        guard case let .write(slot, _) = grid!.place(correctedNs: corrected) else { continue }
        meter.add(ptsNs: pts, arrivalNs: arrival)
        let slotTime = Int64(GridMath.offsetNs(ofSlot: slot, frameRate: rate))
        let realTime = GridMath.delta(camera.realNs(n), firstReal)
        maxError = max(maxError, abs(slotTime - realTime))
    }
    return (grid!, maxError, recovery, meter)
}

let oneFrameNs: Int64 = 41_708_333

@Suite struct CameraClockDriftTests {
    /// The Cam Link stamps 41.700 ms frames while the HDMI signal really runs at 41.708 ms. After
    /// ten minutes of preview, an hour of camera.mov stays on real time: every frame within a frame
    /// of its slot (in fact within a few ms), with no slot repeated or skipped.
    @Test func anHourOfANominalDeviceClockStaysOnRealTime() {
        let camera = SimulatedCamera()
        let preview: Int64 = 24 * 600
        let hour: Int64 = 86_400
        let (grid, maxError, recovery, meter) = run(camera, frames: preview + hour, fileStart: preview)
        #expect(maxError < oneFrameNs)
        #expect(maxError < 5_000_000, "max error \(maxError) ns")
        #expect(grid.stats.slotsRepeated == 0 && grid.stats.slotsSkipped == 0)
        #expect(grid.nextSlot == hour)
        // Not only relative to the file's start: slot 0 is the first file frame's real time, with
        // the 120 ms the stamps drifted during the preview taken out.
        #expect(GridMath.delta(grid.originNs, camera.realNs(preview)).magnitude < 3_000_000, "origin off by \(GridMath.delta(grid.originNs, camera.realNs(preview))) ns")
        // By the end the timestamps are about 0.84 s behind real time (70 min at 0.02%).
        #expect(abs(recovery.correctionNs - 840_000_000) < 10_000_000, "correction \(recovery.correctionNs)")
        // The meter sees both rates: 23.981 stamped (30000/1251), 23.976 real, 0.02% apart.
        #expect(abs((meter.ptsFps ?? 0) - 30000.0 / 1251) < 0.0001)
        #expect(abs((meter.arrivalFps ?? 0) - 24000.0 / 1001) < 0.0001)
        #expect(meter.exceedsLimit)
    }

    /// The same hour on the raw timestamps drifts about 0.7 s, 17 frames: what camera.mov did before.
    @Test func withoutTheCorrectionTheHourDrifts() {
        let (_, maxError, _, _) = run(SimulatedCamera(), frames: 86_400, fileStart: 0, correct: false)
        #expect(maxError > 15 * oneFrameNs)
    }

    /// A device whose stamps are right needs no correction, and the meter sees no difference.
    @Test func aCorrectDeviceClockIsLeftAlone() {
        var camera = SimulatedCamera()
        camera.stampNumerator = camera.realNumerator
        camera.stampDenominator = camera.realDenominator
        let (grid, maxError, recovery, meter) = run(camera, frames: 24 * 1200, fileStart: 240)
        #expect(maxError < 2_000_000)
        #expect(abs(recovery.correctionNs) < 2_000_000)
        #expect(grid.stats.slotsRepeated == 0 && grid.stats.slotsSkipped == 0)
        #expect(!meter.exceedsLimit)
        #expect(abs(meter.mismatch ?? 1) < 0.000_01)
    }

    /// A slow first second (frames delivered late while the stream starts) does not set the baseline.
    @Test func aSlowStartDoesNotSetTheBaseline() {
        var recovery = FrameClockRecovery()
        let camera = SimulatedCamera()
        for n in Int64(0)..<240 {
            let late: UInt64 = n < 24 ? 60_000_000 : 0
            _ = recovery.observe(ptsNs: camera.ptsNs(n), arrivalNs: camera.arrivalNs(n) + late)
        }
        // Ten seconds in, the drift is 2 ms (the estimate lags it by about 1 ms); the slow first
        // block as the baseline would have made the correction -58 ms.
        #expect(abs(recovery.correctionNs - 2_000_000) < 2_000_000, "correction \(recovery.correctionNs)")
    }

    /// The same slow first second, and a file that begins while the reference still settles
    /// (blocks 2 to 5): the correction never jumps. With the upper median, block 2's minima
    /// [L + 60, L] gave L + 60 against a reference of L: a 60 ms jump, then back.
    @Test func aSlowFirstBlockNeverMovesTheCorrection() {
        var recovery = FrameClockRecovery()
        let camera = SimulatedCamera()
        var worst: Int64 = 0
        for n in Int64(0)..<240 {
            let late: UInt64 = n < 24 ? 60_000_000 : 0
            _ = recovery.observe(ptsNs: camera.ptsNs(n), arrivalNs: camera.arrivalNs(n) + late)
            // The real drift so far: 8.3 µs per frame.
            let drift = GridMath.delta(camera.realNs(n), camera.ptsNs(n))
            if n >= 24 { worst = max(worst, abs(recovery.correctionNs - drift)) }
        }
        #expect(worst < 3_000_000, "worst \(worst) ns")
    }

    /// The preview output and the recording output deliver the same frames: each counts once,
    /// with the lower of its two latencies, so the correction is what one output gives.
    @Test func aFrameFromTwoOutputsCountsOnce() {
        let camera = SimulatedCamera()
        var one = FrameClockRecovery(), two = FrameClockRecovery()
        for n in Int64(0)..<2400 {
            let pts = camera.ptsNs(n), arrival = camera.arrivalNs(n)
            _ = one.observe(ptsNs: pts, arrivalNs: arrival)
            if n % 3 == 0 {
                // The slower output's frame comes after the next frame from the faster one.
                _ = two.observe(ptsNs: pts, arrivalNs: arrival)
                _ = two.observe(ptsNs: camera.ptsNs(n + 1), arrivalNs: camera.arrivalNs(n + 1))
                _ = two.observe(ptsNs: pts, arrivalNs: arrival + 3_000_000)
            } else if n % 3 == 1 {
                _ = two.observe(ptsNs: pts, arrivalNs: arrival + 3_000_000)
            } else {
                _ = two.observe(ptsNs: pts, arrivalNs: arrival + 2_000_000)
                _ = two.observe(ptsNs: pts, arrivalNs: arrival)
            }
        }
        #expect(one.frames == 2400 && two.frames == 2400)
        // A frame folded into the block after its own can shift one block minimum by its 2-3 ms.
        #expect(abs(one.correctionNs - two.correctionNs) < 2_500_000, "\(one.correctionNs) vs \(two.correctionNs)")
        // A jump back further than the window is a new stream, not an old frame.
        _ = two.observe(ptsNs: camera.ptsNs(10), arrivalNs: camera.arrivalNs(2400))
        #expect(two.frames == 2401)
    }

    /// Why the recovery belongs to the stream (StreamClock), not to the take: one that starts with
    /// the take's recording output, after 10 minutes of preview, takes the 120 ms the stamps
    /// drifted meanwhile as its baseline, and puts every frame 120 ms early.
    @Test func aRecoveryThatStartsWithTheTakeMissesTheDriftSoFar() {
        let camera = SimulatedCamera()
        let preview: Int64 = 24 * 600
        let stream = StreamClock()
        var takeOnly = FrameClockRecovery()
        for n in Int64(0)..<(preview + 240) {
            let pts = camera.ptsNs(n), arrival = camera.arrivalNs(n)
            _ = stream.observe(ptsNs: pts, arrivalNs: arrival)
            if n >= preview { _ = takeOnly.observe(ptsNs: pts, arrivalNs: arrival) }
        }
        let n = preview + 239
        let streamError = GridMath.delta(stream.corrected(camera.ptsNs(n)), camera.realNs(n))
        let takeError = GridMath.delta(takeOnly.corrected(camera.ptsNs(n)), camera.realNs(n))
        #expect(abs(streamError) < 3_000_000, "stream clock off by \(streamError) ns")
        #expect(abs(takeError + 120_000_000) < 5_000_000, "take-only recovery off by \(takeError) ns")
        #expect(abs(stream.correctionNs - 122_000_000) < 5_000_000)
        // A format set again starts the stream over.
        stream.reset()
        #expect(stream.frames == 0 && stream.correctionNs == 0)
    }
}

@Suite struct CameraSlotterTests {
    let origin: UInt64 = 50_000_000_000
    let rate = FrameRate.fps23_976

    func at(_ frames: Double) -> UInt64 {
        UInt64(Int64(origin) + Int64((frames * 1001 / 24000 * 1e9).rounded()))
    }

    @Test func steadyFramesFillEverySlotOnce() {
        var g = CameraSlotter(frameRate: rate, originNs: origin)
        for k in 0..<100 { #expect(g.place(correctedNs: at(Double(k))) == .write(slot: Int64(k), repeats: 0)) }
        #expect(g.stats == CameraGridStats(framesWritten: 100))
    }

    @Test func aMissingFrameRepeatsTheLastPicture() {
        var g = CameraSlotter(frameRate: rate, originNs: origin)
        _ = g.place(correctedNs: at(0))
        _ = g.place(correctedNs: at(1))
        #expect(g.place(correctedNs: at(3)) == .write(slot: 3, repeats: 1))
        #expect(g.place(correctedNs: at(9)) == .write(slot: 9, repeats: 5))
        #expect(g.stats.slotsRepeated == 6 && g.stats.framesWritten == 4 && g.stats.slotsWritten == 10)
    }

    @Test func aDuplicateFrameIsSkipped() {
        var g = CameraSlotter(frameRate: rate, originNs: origin)
        _ = g.place(correctedNs: at(0))
        _ = g.place(correctedNs: at(1))
        #expect(g.place(correctedNs: at(1)) == .skip)
        #expect(g.place(correctedNs: at(2)) == .write(slot: 2, repeats: 0))
        #expect(g.stats.slotsSkipped == 1)
    }

    /// Jitter of a few ms at a slot edge neither repeats nor skips: only 0.75 frame does.
    @Test func hysteresisAtTheSlotEdge() {
        var g = CameraSlotter(frameRate: rate, originNs: origin)
        _ = g.place(correctedNs: at(0))
        // Half a frame late, then half a frame early, then back: all in their own slot.
        #expect(g.place(correctedNs: at(1.55)) == .write(slot: 1, repeats: 0))
        #expect(g.place(correctedNs: at(1.45)) == .write(slot: 2, repeats: 0))
        #expect(g.place(correctedNs: at(3.6)) == .write(slot: 3, repeats: 0))
        #expect(g.place(correctedNs: at(4.4)) == .write(slot: 4, repeats: 0))
        // 0.8 frame late: the grid catches up and the next frames sit inside the window again.
        #expect(g.place(correctedNs: at(5.8)) == .write(slot: 6, repeats: 1))
        #expect(g.place(correctedNs: at(6.8)) == .write(slot: 7, repeats: 0))
        #expect(g.stats.slotsRepeated == 1 && g.stats.slotsSkipped == 0)
    }

    /// Frames missing here and there, and a burst: every gap is a repeat, nothing drifts.
    @Test func dropsAreRepeatedAndCounted() {
        let skipped: (Int64) -> Bool = { n in (n % 500 == 250) || (3000...3004).contains(n) }
        let missing = (Int64(0)..<24_000).filter(skipped).count
        let (grid, maxError, _, meter) = run(SimulatedCamera(), frames: 24_000, fileStart: 0, skip: skipped)
        #expect(grid.stats.slotsRepeated == Int64(missing))
        #expect(grid.stats.slotsSkipped == 0)
        #expect(grid.nextSlot == 24_000)
        #expect(maxError < oneFrameNs)
        // Gaps count as the frames they lost, so the rates are the same as without drops.
        #expect(abs((meter.arrivalFps ?? 0) - 24000.0 / 1001) < 0.001)
    }

    /// A signal that really runs at 24.000 under a 23.976 grid: one frame in 1001 is skipped, and
    /// no frame is ever more than a frame from its slot.
    @Test func aFasterSignalSkipsAFrameEvery1001() {
        var camera = SimulatedCamera()
        camera.realNumerator = 1_000_000_000
        camera.realDenominator = 24
        camera.stampNumerator = 1_000_000_000
        camera.stampDenominator = 24
        let frames: Int64 = 24 * 300
        let (grid, maxError, _, _) = run(camera, frames: frames, fileStart: 0)
        #expect((6...8).contains(grid.stats.slotsSkipped), "skipped \(grid.stats.slotsSkipped)")
        #expect(grid.stats.slotsRepeated == 0)
        // At most 0.75 frame (31.3 ms) plus the clock estimate's own error.
        #expect(maxError <= 34_000_000, "max error \(maxError) ns")
    }

    @Test func theStallTimerRepeatsAndALateFrameIsDropped() {
        var g = CameraSlotter(frameRate: rate, originNs: origin)
        _ = g.place(correctedNs: at(0))
        _ = g.place(correctedNs: at(1))
        #expect(g.fill(through: 5) == 4)
        #expect(g.nextSlot == 6)
        // The frame for slot 3 comes after the timer repeated it.
        #expect(g.place(correctedNs: at(3)) == .late)
        #expect(g.place(correctedNs: at(6)) == .write(slot: 6, repeats: 0))
        #expect(g.stats.lateFrames == 1 && g.stats.slotsRepeated == 4)
        #expect(g.fill(through: 6) == 0)
    }

    @Test func theEndIsFilledAndFramesAfterItIgnored() {
        var g = CameraSlotter(frameRate: rate, originNs: origin)
        _ = g.place(correctedNs: at(0))
        _ = g.place(correctedNs: at(1))
        g.setEnd(slot: g.nearestSlot(atNs: at(4.2)))
        #expect(g.endSlot == 4 && !g.isComplete)
        #expect(g.place(correctedNs: at(2)) == .write(slot: 2, repeats: 0))
        #expect(g.place(correctedNs: at(4)) == .afterEnd)
        #expect(g.fillToEnd() == 1)
        #expect(g.isComplete && g.stats.slotsWritten == 4)
        // Never shorter than what is written, or one frame.
        var short = CameraSlotter(frameRate: rate, originNs: origin)
        short.setEnd(slot: 0)
        #expect(short.endSlot == 1)
    }
}

@Suite struct FrameRateMeterTests {
    @Test func shortTakesAreNotCompared() {
        var meter = FrameRateMeter(frameRate: .fps23_976)
        let camera = SimulatedCamera()
        for n in Int64(0)..<240 { meter.add(ptsNs: camera.ptsNs(n), arrivalNs: camera.arrivalNs(n)) }
        #expect(meter.ptsFps != nil && meter.arrivalFps != nil)
        #expect(meter.mismatch == nil && !meter.exceedsLimit)
    }

    @Test func oneFrameMeasuresNothing() {
        var meter = FrameRateMeter(frameRate: .fps23_976)
        meter.add(ptsNs: 5, arrivalNs: 6)
        #expect(meter.ptsFps == nil && meter.spanNs == 0)
    }
}
