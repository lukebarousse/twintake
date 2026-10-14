import Testing
@testable import RecorderCore
@testable import MediaWriter
@testable import ScreenCapture

/// Frames in these tests are just labels.
private typealias Grid = CFRGrid<String>

private let origin: UInt64 = 10_000_000_000

private func makeGrid(_ rate: FrameRate = .fps47_952, first: String = "f0") -> Grid {
    Grid(frameRate: rate, originNs: origin, firstFrame: first, firstPtsNs: origin)
}

/// Ends the grid at `end`, decides everything and returns the frame label written to each slot.
private func finish(_ grid: inout Grid, end: Int64) -> [(slot: Int64, frame: String, isRepeat: Bool)] {
    grid.setEnd(slot: end)
    grid.decideToEnd()
    var out: [(Int64, String, Bool)] = []
    while let w = grid.popWrite() { out.append((w.slot, w.frame, w.isRepeat)) }
    return out
}

@Suite struct CFRGridTests {
    @Test func steadyFramesFillEverySlotOnce() {
        for rate in [FrameRate.fps47_952, .fps23_976, .fps59_94] {
            var g = makeGrid(rate)
            for k in 1..<100 { #expect(g.offer("f\(k)", ptsNs: hostNs(origin, Double(k), rate)) == .accepted(slot: Int64(k))) }
            let writes = finish(&g, end: 100)
            #expect(writes.map(\.slot) == Array(0..<100))
            #expect(writes.map(\.frame) == (0..<100).map { "f\($0)" })
            #expect(g.stats == CFRStats(written: 100, repeated: 0, late: 0, superseded: 0))
        }
    }

    @Test func gapsRepeatTheLastFrame() {
        var g = makeGrid()
        g.offer("a", ptsNs: hostNs(origin, 1, .fps47_952))
        g.offer("b", ptsNs: hostNs(origin, 5, .fps47_952))
        g.offer("c", ptsNs: hostNs(origin, 6, .fps47_952))
        let writes = finish(&g, end: 10)
        #expect(writes.map(\.frame) == ["f0", "a", "a", "a", "a", "b", "c", "c", "c", "c"])
        #expect(writes.map(\.isRepeat) == [false, false, true, true, true, false, false, true, true, true])
        #expect(g.stats.repeated == 6)
        #expect(g.stats.written == 10)
    }

    @Test func burstKeepsNewestFramePerSlot() {
        var g = makeGrid()
        #expect(g.offer("a", ptsNs: hostNs(origin, 3.0, .fps47_952)) == .accepted(slot: 3))
        #expect(g.offer("b", ptsNs: hostNs(origin, 3.1, .fps47_952)) == .replaced(slot: 3))
        #expect(g.offer("c", ptsNs: hostNs(origin, 3.2, .fps47_952)) == .replaced(slot: 3))
        let writes = finish(&g, end: 5)
        #expect(writes.map(\.frame) == ["f0", "f0", "f0", "c", "c"])
        #expect(g.stats.superseded == 2)
        #expect(g.stats.late == 0)
    }

    @Test func duplicateTimestampIsNotWrittenTwice() {
        var g = makeGrid()
        let t = hostNs(origin, 2, .fps47_952)
        g.offer("a", ptsNs: t)
        #expect(g.offer("a-again", ptsNs: t) == .replaced(slot: 2))
        let writes = finish(&g, end: 4)
        #expect(writes.map(\.slot) == [0, 1, 2, 3])
        #expect(writes.map(\.frame) == ["f0", "f0", "a-again", "a-again"])
    }

    @Test func lateAndOutOfOrderFramesAreCountedNotWritten() {
        var g = makeGrid()
        g.offer("a", ptsNs: hostNs(origin, 5, .fps47_952))
        // Older than the frame already waiting.
        #expect(g.offer("old", ptsNs: hostNs(origin, 4, .fps47_952)) == .late(slot: 4))
        g.decide(through: 10)
        // Its slot was decided by the timer.
        #expect(g.offer("late", ptsNs: hostNs(origin, 8, .fps47_952)) == .late(slot: 8))
        let writes = finish(&g, end: 12)
        #expect(!writes.contains { $0.frame == "late" || $0.frame == "old" })
        #expect(g.stats.late == 2)
        #expect(writes.map(\.slot) == Array(0..<12))
    }

    @Test func jitterUnderAQuarterFrameLandsOnTheRightSlot() {
        var g = makeGrid()
        let jitter = [0.2, -0.2, 0.1, -0.24, 0.24, 0]
        for k in 1...30 {
            let t = hostNs(origin, Double(k) + jitter[k % jitter.count], .fps47_952)
            #expect(g.offer("f\(k)", ptsNs: t) == .accepted(slot: Int64(k)))
        }
        let writes = finish(&g, end: 31)
        #expect(g.stats.repeated == 0 && g.stats.late == 0 && g.stats.superseded == 0)
        #expect(writes.map(\.frame) == (0...30).map { "f\($0)" })
    }

    @Test func doubleRateFramesNeverLandOnAWindowEdge() {
        // A 47.95 Hz display under a 23.976 grid: frames at k and k + 1/2.
        var g = makeGrid(.fps23_976)
        for half in 1..<40 {
            let x = Double(half) / 2
            g.offer(x == x.rounded() ? "on-\(Int(x))" : "mid", ptsNs: hostNs(origin, x + 0.01, .fps23_976))
        }
        let writes = finish(&g, end: 20)
        #expect(writes.map(\.frame) == ["f0"] + (1..<20).map { "on-\($0)" })
        #expect(g.stats.repeated == 0)
        #expect(g.stats.superseded == 19)
    }

    @Test func sixtyHertzDisplayStillFillsEverySlotAt47952() {
        var g = makeGrid()
        // One second of 60 Hz refreshes.
        for i in 1..<60 {
            let seconds = Double(i) / 60
            g.offer("r\(i)", ptsNs: origin + UInt64(seconds * 1e9))
        }
        let end = GridMath.nearestSlot(elapsedNs: 59 * 1_000_000_000 / 60, frameRate: .fps47_952)
        let writes = finish(&g, end: end)
        #expect(g.stats.repeated == 0)
        #expect(Set(writes.map(\.frame)).count == writes.count)
    }

    @Test func staticScreenIsFilledByTheTimer() {
        var g = makeGrid()
        // Nothing moves for 10 s; the timer decides slots as time passes.
        var written: [Int64] = []
        for tick in 1...100 {
            g.decide(through: GridMath.nearestSlot(elapsedNs: Int64(tick) * 100_000_000, frameRate: .fps47_952) - 1)
            while let w = g.popWrite() { written.append(w.slot) }
        }
        #expect(written == Array(0..<written.count).map(Int64.init))
        #expect(written.count >= 470)
        #expect(g.stats.repeated == Int64(written.count) - 1)
    }

    @Test func prerollFrameFillsSlotZeroAndCanBeReplaced() {
        let rate = FrameRate.fps47_952
        let prerollPts: UInt64 = 4_000_000_000
        let start = prerollPts + 3_000_000_000
        let t0 = GridMath.origin(startNs: start, framePtsNs: prerollPts, frameRate: rate)
        var g = CFRGrid<String>(frameRate: rate, originNs: t0, firstFrame: "preroll", firstPtsNs: prerollPts)
        // A frame captured just before t0 but newer than the preroll frame takes slot 0, uncounted.
        #expect(g.offer("newer", ptsNs: t0 - 30_000_000) == .replaced(slot: 0))
        #expect(g.offer("older", ptsNs: prerollPts - 1) == .beforeOrigin)
        g.offer("next", ptsNs: hostNs(t0, 2, rate))
        let writes = finish(&g, end: 3)
        #expect(writes.map(\.frame) == ["newer", "newer", "next"])
        #expect(g.stats.superseded == 0 && g.stats.late == 0)
    }

    @Test func endCapIgnoresLaterFramesAndNeverShrinksDecidedSlots() {
        var g = makeGrid()
        g.decide(through: 9)
        g.setEnd(slot: 5)
        #expect(g.endSlot == 10)
        #expect(g.offer("after", ptsNs: hostNs(origin, 12, .fps47_952)) == .afterEnd)
        var single = makeGrid()
        single.setEnd(slot: 0)
        #expect(single.endSlot == 1)
        #expect(finish(&single, end: 0).map(\.frame) == ["f0"])
    }

    @Test func randomTimelinesWriteEachSlotExactlyOnce() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        for rate in [FrameRate.fps47_952, .fps23_976, .fps59_94] {
            var g = makeGrid(rate)
            var t = origin
            var slots: [Int64] = []
            for i in 0..<2000 {
                // Gaps from 0 to ~3 frames, sometimes long stalls, sometimes bursts.
                let frameNs = UInt64(GridMath.offsetNs(ofSlot: 1, frameRate: rate))
                let step = next() % 10 == 0 ? frameNs * (next() % 40) : (frameNs * (next() % 300)) / 100
                t += step
                g.offer("f\(i)", ptsNs: t)
                if next() % 7 == 0 {
                    g.decide(through: g.slot(forPtsNs: t) - 12)
                }
                while let w = g.popWrite() { slots.append(w.slot) }
            }
            let end = g.slot(forPtsNs: t) + 3
            g.setEnd(slot: end)
            g.decideToEnd()
            while let w = g.popWrite() { slots.append(w.slot) }
            #expect(slots == Array(0..<end))
            #expect(g.stats.written == end)
        }
    }
}
