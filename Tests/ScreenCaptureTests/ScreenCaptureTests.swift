import CoreMedia
import Testing
@testable import RecorderCore
@testable import MediaWriter
@testable import ScreenCapture

/// `frames` grid frames (fractions allowed) in ns.
func elapsedNs(_ frames: Double, _ rate: FrameRate) -> Int64 {
    Int64((frames * Double(rate.den) / Double(rate.num) * 1e9).rounded())
}

/// Host time of a point `frames` slots after `origin`, in ns.
func hostNs(_ origin: UInt64, _ frames: Double, _ rate: FrameRate) -> UInt64 {
    UInt64(Int64(origin) + elapsedNs(frames, rate))
}

@Suite struct GridMathTests {
    @Test func slotTimesAreExactRationals() {
        // 47.952: one frame is 1001/48000 s; 23.976: 1001/24000 s.
        #expect(GridMath.offsetNs(ofSlot: 48_000, frameRate: .fps47_952) == 1001 * 1_000_000_000)
        #expect(GridMath.offsetNs(ofSlot: 24_000, frameRate: .fps23_976) == 1001 * 1_000_000_000)
        #expect(FrameRate.fps47_952.time(ofFrame: 3) == CMTime(value: 3003, timescale: 48000))
        // BetterCapture's integer grid made 23.976 into 23; here 24 slots of 23.976 are 1.001 s.
        #expect(GridMath.offsetNs(ofSlot: 24, frameRate: .fps23_976) == 1_001_000_000)
    }

    @Test func captureSlotWindowIsThreeQuartersBeforeToOneQuarterAfter() {
        let r = FrameRate.fps47_952
        func slot(_ frames: Double) -> Int64 {
            GridMath.captureSlot(elapsedNs: elapsedNs(frames, r), frameRate: r)
        }
        #expect(slot(0) == 0)
        #expect(slot(0.24) == 0)
        #expect(slot(0.26) == 1)
        #expect(slot(1) == 1)
        #expect(slot(0.5) == 1)
        #expect(slot(-0.5) == 0)
        #expect(slot(-0.76) == -1)
        #expect(slot(7.2) == 7)
        #expect(slot(6.8) == 7)
    }

    @Test func longRecordingsStayExact() {
        // Ten hours of 23.976 and 47.952: every grid time maps back to its own slot.
        for r in [FrameRate.fps23_976, .fps47_952, .fps59_94] {
            let slot = Int64(10 * 3600) * Int64(r.num) / Int64(r.den)
            let ns = GridMath.offsetNs(ofSlot: slot, frameRate: r)
            #expect(GridMath.captureSlot(elapsedNs: ns, frameRate: r) == slot)
            #expect(GridMath.nearestSlot(elapsedNs: ns, frameRate: r) == slot)
        }
        // One hour of 23.976 is 86313.6 frames.
        #expect(GridMath.nearestSlot(elapsedNs: 3600 * 1_000_000_000, frameRate: .fps23_976) == 86314)
    }

    @Test func audioSamplesPerFrame() {
        #expect(GridMath.audioFrames(atSlot: 1, frameRate: .fps47_952, sampleRate: 48000) == 1001)
        #expect(GridMath.audioFrames(atSlot: 1, frameRate: .fps23_976, sampleRate: 48000) == 2002)
        #expect(GridMath.audioFrames(atSlot: 5, frameRate: .fps59_94, sampleRate: 48000) == 4004)
        #expect(GridMath.audioFrames(atSlot: 1, frameRate: .fps59_94, sampleRate: 48000) == 801)
        #expect(GridMath.audioFrames(elapsedNs: 1_000_000_000, sampleRate: 48000) == 48000)
        #expect(GridMath.audioFrames(elapsedNs: -10_000_000, sampleRate: 48000) == -480)
    }

    @Test func originFromPrerollFrameStaysOnItsLattice() {
        let r = FrameRate.fps47_952
        let frame: UInt64 = 5_000_000_000
        let start = hostNs(frame, 2.5, r)
        let origin = GridMath.origin(startNs: start, framePtsNs: frame, frameRate: r)
        #expect(origin == frame + UInt64(GridMath.offsetNs(ofSlot: 3, frameRate: r)))
        #expect(origin >= start)
        // A frame stamped at or after Start is itself the origin.
        #expect(GridMath.origin(startNs: start, framePtsNs: start + 7, frameRate: r) == start + 7)
        // A preroll frame from minutes ago still lands on its lattice.
        let old = GridMath.origin(startNs: frame + 600_000_000_000, framePtsNs: frame, frameRate: r)
        let k = GridMath.nearestSlot(elapsedNs: Int64(old - frame), frameRate: r)
        #expect(abs(Int64(old - frame) - GridMath.offsetNs(ofSlot: k, frameRate: r)) <= 1)
    }
}

@Suite struct ScreenTrackLayoutTests {
    @Test func videoThenMicThenSystemAudio() {
        #expect(ScreenTrackLayout.roles(mic: true, systemAudio: true) == [.screenVideo, .mic, .systemAudio])
        #expect(ScreenTrackLayout.roles(mic: true, systemAudio: false) == [.screenVideo, .mic])
        #expect(ScreenTrackLayout.roles(mic: false, systemAudio: true) == [.screenVideo, .systemAudio])
        #expect(ScreenTrackLayout.roles(mic: false, systemAudio: false) == [.screenVideo])
        #expect(ScreenTrackLayout.index(of: .systemAudio, mic: true, systemAudio: true) == 2)
        #expect(ScreenTrackLayout.index(of: .systemAudio, mic: false, systemAudio: true) == 1)
        #expect(ScreenTrackLayout.index(of: .mic, mic: false, systemAudio: true) == nil)
    }
}

/// The region filter leaves out TwinTake's own windows (the camera window, the overlay): by bundle
/// id, and by process, so an unbundled run is covered too.
@Suite struct OwnAppExclusionTests {
    @Test func excludesTheListedAppsAndThisProcess() {
        let ids = ["com.lukebarousse.twintake"]
        #expect(ScreenRecorder.isExcluded(bundleID: "com.lukebarousse.twintake", processID: 900, excludedBundleIDs: ids,
                                          ownProcessID: 100))
        #expect(ScreenRecorder.isExcluded(bundleID: "", processID: 100, excludedBundleIDs: ids, ownProcessID: 100))
        #expect(!ScreenRecorder.isExcluded(bundleID: "com.apple.Safari", processID: 900, excludedBundleIDs: ids,
                                           ownProcessID: 100))
        #expect(!ScreenRecorder.isExcluded(bundleID: "com.apple.Safari", processID: 900, excludedBundleIDs: [], ownProcessID: 100))
    }
}
