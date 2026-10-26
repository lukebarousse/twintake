import CoreVideo
import Foundation
import Testing
@testable import CameraCapture
import RecorderCore

/// A 420v (or other biplanar) frame with a noisy luma plane: every byte depends on `seed`, like
/// sensor noise, so two seeds never give the same picture. Row padding is filled with `padding`.
func noisyFrame(width: Int = 321, height: Int = 181, seed: UInt64,
                format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, padding: UInt8 = 0) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let used = CVPixelBufferGetWidthOfPlane(buffer, 0) * (FrameFingerprinter.lumaBytes(format: format) ?? 1)
    var x = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
        for i in 0..<rowBytes {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            y[row * rowBytes + i] = i < used ? UInt8(64 + (x >> 33) % 128) : padding
        }
    }
    let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// A copy of `source`'s planes in a new buffer (a camera that sends the same picture again in a
/// new buffer), with `change` applied to the copy's luma plane.
func copyFrame(_ source: CVPixelBuffer, change: (UnsafeMutablePointer<UInt8>, Int) -> Void = { _, _ in }) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                        CVPixelBufferGetPixelFormatType(source),
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let copy = pb!
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(source) {
        let from = CVPixelBufferGetBaseAddressOfPlane(source, plane)!, to = CVPixelBufferGetBaseAddressOfPlane(copy, plane)!
        let fromRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane), toRow = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
        for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
            memcpy(to + row * toRow, from + row * fromRow, min(fromRow, toRow))
        }
    }
    change(CVPixelBufferGetBaseAddressOfPlane(copy, 0)!.assumingMemoryBound(to: UInt8.self),
           CVPixelBufferGetBytesPerRowOfPlane(copy, 0))
    CVPixelBufferUnlockBaseAddress(copy, [])
    CVPixelBufferUnlockBaseAddress(source, .readOnly)
    return copy
}

private func fingerprint(_ buffer: CVPixelBuffer) -> FrameFingerprint? {
    var grid: FingerprintGrid?
    return FrameFingerprinter.fingerprint(buffer, grid: &grid)
}

/// The fingerprint and the sampled values of `buffer`.
private func read(_ buffer: CVPixelBuffer, grid: inout FingerprintGrid?) -> (FrameFingerprint?, [UInt16]) {
    var samples = FrameSamples().values
    let f = FrameFingerprinter.fingerprint(buffer, grid: &grid, samples: &samples)
    return (f, samples)
}

@Suite struct FingerprintGridTests {
    @Test func positionsStayInsideOddAndTinySizes() {
        for count in [1, 2, 17, 31, 32, 33, 181, 321, 1079, 2161, 3841] {
            let p = FingerprintGrid.positions(count: count)
            #expect(p.count == FingerprintGrid.side)
            #expect(p.allSatisfy { (0..<count).contains($0) }, "count \(count): \(p)")
            #expect(p == p.sorted())
        }
        // Spread over the whole size: the first cell's center near the start, the last near the end.
        #expect(FingerprintGrid.positions(count: 3840).first == 60 && FingerprintGrid.positions(count: 3840).last == 3780)
        #expect(Set(FingerprintGrid.positions(count: 2160)).count == 32)
        #expect(FingerprintGrid.positions(count: 0).isEmpty)
    }

    /// 1024 samples, every one inside the plane and never in a row's padding.
    @Test(arguments: [(3840, 2160, 3840, 1), (3841, 2161, 3904, 1), (321, 181, 384, 1), (1920, 1080, 4096, 2), (7, 5, 16, 1)])
    func offsetsStayInsideThePlane(width: Int, height: Int, rowBytes: Int, pixelBytes: Int) throws {
        let grid = try #require(FingerprintGrid(width: width, height: height, rowBytes: rowBytes, pixelBytes: pixelBytes))
        #expect(grid.offsets.count == 1024)
        #expect(grid.lastByteEnd <= height * rowBytes)
        #expect(grid.offsets.allSatisfy { $0 % rowBytes + pixelBytes <= width * pixelBytes })
        #expect(grid.offsets.allSatisfy { $0 % pixelBytes == 0 })
    }

    @Test func aPlaneThatCannotHoldTheSamplesHasNoGrid() {
        #expect(FingerprintGrid(width: 0, height: 10, rowBytes: 64, pixelBytes: 1) == nil)
        #expect(FingerprintGrid(width: 10, height: 0, rowBytes: 64, pixelBytes: 1) == nil)
        #expect(FingerprintGrid(width: 100, height: 10, rowBytes: 64, pixelBytes: 1) == nil)
        #expect(FingerprintGrid(width: 40, height: 10, rowBytes: 64, pixelBytes: 2) == nil)
        #expect(FingerprintGrid(width: 10, height: 10, rowBytes: 64, pixelBytes: 0) == nil)
    }

    @Test func onlyBiplanarFourTwoZeroIsRead() {
        #expect(FrameFingerprinter.lumaBytes(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) == 1)
        #expect(FrameFingerprinter.lumaBytes(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) == 1)
        #expect(FrameFingerprinter.lumaBytes(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) == 2)
        #expect(FrameFingerprinter.lumaBytes(format: kCVPixelFormatType_32BGRA) == nil)
        #expect(FrameFingerprinter.lumaBytes(format: kCVPixelFormatType_422YpCbCr8) == nil)
    }
}

@Suite struct FrameFingerprintTests {
    @Test func theSamePictureInAnotherBufferIsARepeat() throws {
        let a = noisyFrame(seed: 1)
        let again = copyFrame(a)
        let fa = try #require(fingerprint(a)), fb = try #require(fingerprint(again))
        #expect(fa == fb && !fa.flat)
        #expect(fingerprint(noisyFrame(seed: 2)) != fa)
        var counter = RepeatedFrameCounter()
        let first = counter.arrived(fa), second = counter.arrived(fb)
        #expect(!first && second)
        #expect(counter.repeatedOnArrival == 1 && counter.checked == 2)
    }

    /// One luma byte at a sampled position differs by 1 (sensor noise): a new picture.
    @Test func oneChangedSampleIsANewPicture() throws {
        let a = noisyFrame(seed: 7)
        var grid: FingerprintGrid?
        let fa = try #require(FrameFingerprinter.fingerprint(a, grid: &grid))
        let sampled = try #require(grid?.offsets[517])
        let b = copyFrame(a) { luma, _ in luma[sampled] &+= 1 }
        let fb = try #require(FrameFingerprinter.fingerprint(b, grid: &grid))
        #expect(fa != fb)
        var counter = RepeatedFrameCounter()
        counter.arrived(fa)
        let repeated = counter.arrived(fb)
        #expect(!repeated && counter.repeatedOnArrival == 0)
    }

    /// bytesPerRow is wider than the picture: what sits in the padding is never read.
    @Test func rowPaddingIsNotRead() throws {
        let a = noisyFrame(width: 321, height: 181, seed: 3, padding: 0)
        let b = noisyFrame(width: 321, height: 181, seed: 3, padding: 0xAA)
        #expect(CVPixelBufferGetBytesPerRowOfPlane(a, 0) > 321)
        #expect(fingerprint(a) != nil && fingerprint(a) == fingerprint(b))
    }

    @Test func tenBitFramesAreRead() throws {
        let format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let a = noisyFrame(width: 64, height: 36, seed: 5, format: format)
        let fa = try #require(fingerprint(a))
        #expect(fa == fingerprint(copyFrame(a)))
        #expect(fa != fingerprint(noisyFrame(width: 64, height: 36, seed: 6, format: format)))
    }

    @Test func packedFormatsAreSkipped() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA, nil, &pb)
        #expect(fingerprint(pb!) == nil)
        var counter = RepeatedFrameCounter()
        let repeated = counter.arrived(nil)
        #expect(!repeated && counter.checked == 0)
    }

    /// One value everywhere (a lens cap, an empty frame): flat, and never counted as a repeat.
    @Test func flatPicturesAreNotCounted() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let flat = pb!
        CVPixelBufferLockBaseAddress(flat, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(flat, 0), 16,
               CVPixelBufferGetBytesPerRowOfPlane(flat, 0) * CVPixelBufferGetHeightOfPlane(flat, 0))
        CVPixelBufferUnlockBaseAddress(flat, [])
        let f = try #require(fingerprint(flat))
        #expect(f.flat)
        var counter = RepeatedFrameCounter()
        counter.arrived(f)
        let repeated = counter.arrived(f)
        #expect(!repeated)
        #expect(counter.checked == 0 && counter.repeatedOnArrival == 0 && counter.uniqueFrameRatio == nil)
    }

    /// The grid is built once per geometry and rebuilt when the frame size changes.
    @Test func theGridFollowsTheGeometry() throws {
        var grid: FingerprintGrid?
        _ = FrameFingerprinter.fingerprint(noisyFrame(width: 320, height: 180, seed: 1), grid: &grid)
        let first = try #require(grid)
        _ = FrameFingerprinter.fingerprint(noisyFrame(width: 320, height: 180, seed: 2), grid: &grid)
        #expect(grid == first)
        _ = FrameFingerprinter.fingerprint(noisyFrame(width: 640, height: 360, seed: 3), grid: &grid)
        #expect(grid?.width == 640 && grid?.height == 360)
    }
}

@Suite struct RepeatedFrameCounterTests {
    func fp(_ n: UInt64) -> FrameFingerprint { FrameFingerprint(hash: n, flat: false) }

    /// The pattern seen in camera.mov: 4 new pictures, then the last one held for 3 slots.
    @Test func countsRepeatsRunsAndTheRatio() {
        var c = RepeatedFrameCounter()
        for n: UInt64 in [1, 2, 3, 4, 4, 4, 4, 5, 6, 7, 8, 8, 8, 8] { c.arrived(fp(n)) }
        #expect(c.checked == 14 && c.repeatedOnArrival == 6 && c.longestRepeatRun == 3)
        #expect(c.uniqueFrameRatio == 8.0 / 14)
        // An unreadable frame breaks a run: the frame after it is never a repeat of it.
        c.arrived(nil)
        let afterGap = c.arrived(fp(8))
        #expect(!afterGap && c.checked == 15 && c.repeatedOnArrival == 6)
        // A repeat compares with the frame right before, not an older one.
        let older = c.arrived(fp(1))
        #expect(!older)
    }

    @Test func aFrameThatChangedBeforeItsWriteIsCounted() {
        var c = RepeatedFrameCounter()
        let same = c.beforeWrite(atArrival: fp(1), now: fp(1))
        let changed = c.beforeWrite(atArrival: fp(1), now: fp(2))
        // Nothing to compare: not counted.
        let noArrival = c.beforeWrite(atArrival: nil, now: fp(2))
        let noNow = c.beforeWrite(atArrival: fp(1), now: nil)
        #expect(!same && changed && !noArrival && !noNow)
        #expect(c.changedBeforeWrite == 1)
    }

    @Test func aWrittenFrameThatChangedWhileHeldIsCounted() {
        var c = RepeatedFrameCounter()
        let same = c.whileHeld(atWrite: fp(1), now: fp(1))
        let changed = c.whileHeld(atWrite: fp(1), now: fp(2))
        let unread = c.whileHeld(atWrite: fp(1), now: nil)
        #expect(!same && changed && !unread)
        #expect(c.changedWhileHeld == 1 && c.changedBeforeWrite == 0)
    }

    /// The same buffer as the frame before: the capture stack delivered it again. A new buffer with
    /// the same picture: the camera or the card. A held buffer is counted on any checked frame.
    @Test func repeatsKnowWhichBufferTheyCameIn() {
        var c = RepeatedFrameCounter()
        let a = FrameBufferID.surface(10), b = FrameBufferID.surface(11)
        c.arrived(fp(1), buffer: a)
        c.arrived(fp(1), buffer: a, held: true)  // the same buffer again
        c.arrived(fp(1), buffer: b)              // the same picture in a new buffer
        c.arrived(fp(2), buffer: b, held: true)  // a new picture in a buffer still held
        #expect(c.repeatedOnArrival == 2 && c.sameBufferRepeats == 1 && c.heldBufferArrivals == 2)
        // Flat and unreadable frames are not counted, whatever their buffer.
        c.arrived(FrameFingerprint(hash: 9, flat: true), buffer: a, held: true)
        c.arrived(nil, buffer: a, held: true)
        #expect(c.heldBufferArrivals == 2 && c.checked == 4)
    }

    /// Repeats in runs of at most 4 are short (choppy motion); a longer run is a still picture.
    @Test func shortAndLongRuns() {
        var c = RepeatedFrameCounter()
        // Runs of 1, 3, 4, then 10 (long), then 2 still open at the end.
        var n: UInt64 = 0
        for run in [1, 3, 4, 10] {
            n += 1
            for _ in 0...run { c.arrived(fp(n)) }
        }
        n += 1
        for _ in 0...2 { c.arrived(fp(n)) }
        #expect(c.repeatedOnArrival == 20 && c.longestRepeatRun == 10)
        #expect(c.shortRunRepeats == 1 + 3 + 4 + 2)
        // An unreadable frame closes the open run.
        c.arrived(nil)
        #expect(c.shortRunRepeats == 10)
    }

    /// Non-repeated frames are sorted by how much they changed; bucket 0 are the near repeats.
    @Test func nearRepeatsAndDifferenceBuckets() {
        var c = RepeatedFrameCounter()
        func diff(_ mean: Double, moved: Int = 0) -> SampleDifference { SampleDifference(moved: moved, mean: mean, count: 1024) }
        c.arrived(fp(1), difference: diff(0.01))            // no frame before: not sorted
        c.arrived(fp(2), difference: diff(0.01, moved: 5))  // near repeat: an overlay changed
        c.arrived(fp(3), difference: diff(0.3))
        c.arrived(fp(4), difference: diff(1.0))
        c.arrived(fp(5), difference: diff(3.0))
        c.arrived(fp(6), difference: diff(0.01, moved: 300)) // a hand moved: a new picture
        c.arrived(fp(6), difference: diff(0))                // exact repeat: only in repeatedOnArrival
        c.arrived(fp(7))                                     // no difference measured
        #expect(c.nearRepeatOnArrival == 1 && c.repeatedOnArrival == 1)
        #expect(c.differenceBuckets == [1, 1, 1, 2])
    }

    @Test func theWarningNeedsTenSecondsAndMoreThanFivePercent() {
        #expect(RepeatedFrameRule.minimumFrames(.fps23_976) == 240)
        #expect(RepeatedFrameRule.minimumFrames(FrameRate(num: 30000, den: 1001)) == 300)
        #expect(RepeatedFrameRule.minimumFrames(FrameRate(num: 24, den: 1)) == 240)
        #expect(!RepeatedFrameRule.tooMany(repeated: 12, checked: 240, frameRate: .fps23_976))
        #expect(RepeatedFrameRule.tooMany(repeated: 13, checked: 240, frameRate: .fps23_976))
        #expect(!RepeatedFrameRule.tooMany(repeated: 100, checked: 239, frameRate: .fps23_976))
        #expect(RepeatedFrameRule.percent(repeated: 104, checked: 240) == 43)
        #expect(RepeatedFrameRule.percent(repeated: 0, checked: 0) == 0)
        #expect(RepeatedFrameRule.uniqueRatio(repeated: 104, checked: 240) == 136.0 / 240)
        #expect(RepeatedFrameRule.uniqueRatio(repeated: 0, checked: 0) == nil)
        #expect(RepeatedFrameRule.verdict(checked: 240, repeated: 12, shortRunRepeats: 12, sameBufferRepeats: 0,
                                          frameRate: .fps23_976) == nil)
    }

    /// Choppy only for short runs; the camera or the card only when the repeats came in new buffers.
    @Test func theVerdictNamesThePatternAndTheCause() throws {
        func verdict(short: Int64, same: Int64) throws -> RepeatedFrameRule.Verdict {
            try #require(RepeatedFrameRule.verdict(checked: 1000, repeated: 430, shortRunRepeats: short,
                                                   sameBufferRepeats: same, frameRate: .fps23_976))
        }
        let camera = try verdict(short: 430, same: 0)
        #expect(camera == RepeatedFrameRule.Verdict(percent: 43, choppy: true, cause: .camera))
        #expect(RepeatedFrameRule.warning(camera) == "The camera sends the same picture again in 43% of frames, so "
            + "camera.mov looks choppy. A capture card on a shared USB port (a dock or a hub) does this at 4K: "
            + "plug it into the Mac or a Thunderbolt port.")
        #expect(RepeatedFrameRule.menuNote(camera) == "camera.mov looks choppy: 43% of its frames repeat. Plug the "
            + "capture card into the Mac or a Thunderbolt port, not a dock's or hub's USB port.")

        let stack = try verdict(short: 430, same: 300)
        #expect(stack.cause == .captureStack && stack.choppy)
        #expect(RepeatedFrameRule.warning(stack).hasPrefix("macOS delivers the same camera buffer again in 43% of frames"))
        #expect(RepeatedFrameRule.warning(stack).contains("not the camera"))
        #expect(RepeatedFrameRule.menuNote(stack)?.contains("the capture stack repeats frames, not the camera") == true)
        // Half or fewer in the same buffer: the camera or the card.
        #expect(try verdict(short: 430, same: 215).cause == .camera)

        // A still picture (a slide through a capture card): repeats in long runs, no "choppy", no note.
        let still = try verdict(short: 50, same: 0)
        #expect(!still.choppy)
        #expect(RepeatedFrameRule.warning(still) == "The camera sent the same picture again in 43% of frames, "
            + "mostly in long runs: a still picture.")
        #expect(RepeatedFrameRule.menuNote(still) == nil)
        #expect(!RepeatedFrameRule.warning(try verdict(short: 50, same: 400)).contains("choppy"))
        for v in [camera, stack, still] {
            #expect(!RepeatedFrameRule.warning(v).contains("shutter") && RepeatedFrameRule.menuNote(v)?.contains("shutter") != true)
        }
    }
}

@Suite struct SampleDifferenceTests {
    /// The same picture in a new buffer with a few sampled values changed a lot (an overlay that
    /// blinked): not bit-identical, but a near repeat.
    @Test func aRepeatWithAChangedOverlayIsANearRepeat() throws {
        let a = noisyFrame(seed: 11)
        var grid: FingerprintGrid?
        let (fa, sa) = read(a, grid: &grid)
        let offsets = try #require(grid?.offsets)
        let b = copyFrame(a) { luma, _ in for i in 0..<10 { luma[offsets[100 * i]] &+= 90 } }
        let (fb, sb) = read(b, grid: &grid)
        #expect(fa != nil && fa != fb)
        let d = try #require(SampleDifference(sb, sa))
        #expect(d.moved == 10 && d.mean == 0 && d.isNearRepeat && d.bucket == 0)
        #expect(SampleDifference(sa, sa)?.isNearRepeat == true)
    }

    /// Every sample one step off (noise on a still scene): a new picture. A new noisy frame is too.
    @Test func noiseIsANewPicture() throws {
        let a = noisyFrame(seed: 12)
        var grid: FingerprintGrid?
        let (_, sa) = read(a, grid: &grid)
        let offsets = try #require(grid?.offsets)
        let b = copyFrame(a) { luma, _ in for o in offsets { luma[o] &+= 1 } }
        let (_, sb) = read(b, grid: &grid)
        let d = try #require(SampleDifference(sb, sa))
        #expect(d.moved == 0 && d.mean == 1 && !d.isNearRepeat && d.bucket == 2)
        let (_, sc) = read(noisyFrame(seed: 13), grid: &grid)
        let other = try #require(SampleDifference(sc, sa))
        #expect(other.mostlyMoved && !other.isNearRepeat && other.bucket == 3)
        #expect(SampleDifference([1, 2], [1]) == nil && SampleDifference([], []) == nil)
    }

    /// 10-bit values compare in the same 8-bit steps: one 10-bit code is a quarter step.
    @Test func tenBitSamplesUseEightBitSteps() throws {
        let format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let a = noisyFrame(width: 64, height: 36, seed: 14, format: format)
        var grid: FingerprintGrid?
        let (_, sa) = read(a, grid: &grid)
        let offsets = try #require(grid?.offsets)
        // Raise every sampled 16-bit word by one 10-bit code (64 in the stored word: the 10 bits sit at the top).
        let b = copyFrame(a) { luma, _ in
            for o in offsets {
                let word = UInt16(luma[o]) | UInt16(luma[o + 1]) << 8
                let raised = word &+ 64
                luma[o] = UInt8(raised & 0xFF)
                luma[o + 1] = UInt8(raised >> 8)
            }
        }
        let (_, sb) = read(b, grid: &grid)
        let d = try #require(SampleDifference(sb, sa))
        #expect(d.moved == 0 && d.mean == 0.25 && d.bucket == 1)
    }

    /// The buffer ID is the IOSurface's when there is one.
    @Test func bufferIDs() {
        let a = noisyFrame(width: 32, height: 18, seed: 1), b = copyFrame(a)
        #expect(FrameBufferID(a) == FrameBufferID(a) && FrameBufferID(a) != FrameBufferID(b))
        if case .surface = FrameBufferID(a) {} else { Issue.record("no IOSurface ID") }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        if case .object = FrameBufferID(pb!) {} else { Issue.record("expected an object ID") }
    }
}

@Suite struct RepeatedFrameReportTests {
    func video(_ check: RepeatedFrameCounter) -> CameraVideoResult {
        var v = CameraVideoResult(originNs: 7, endSlot: 300, stats: CameraGridStats(framesWritten: 300))
        v.frameCheck = check
        return v
    }

    func fp(_ n: Int) -> FrameFingerprint { FrameFingerprint(hash: UInt64(n), flat: false) }

    func counter(new: Int, repeats: Int, changed: Int = 0, held: Int = 0, sameBuffer: Bool = false) -> RepeatedFrameCounter {
        var c = RepeatedFrameCounter()
        for n in 0..<new {
            c.arrived(fp(n), difference: SampleDifference(moved: 0, mean: n % 2 == 0 ? 0.05 : 1, count: 1024),
                      buffer: .surface(UInt32(2 * n)))
            if n < repeats { c.arrived(fp(n), buffer: .surface(UInt32(2 * n + (sameBuffer ? 0 : 1)))) }
        }
        for _ in 0..<changed { c.beforeWrite(atArrival: fp(1), now: fp(2)) }
        for _ in 0..<held { c.whileHeld(atWrite: fp(1), now: fp(2)) }
        return c
    }

    @Test func sessionJsonAndTrackStopCarryTheCounts() throws {
        let check = counter(new: 171, repeats: 129, changed: 2, held: 1)
        #expect(check.checked == 300 && check.repeatedOnArrival == 129 && check.longestRepeatRun == 1)
        var facts = CameraTrackFacts(videoDevice: DeviceInfo(name: "Cam Link 4K", uid: "camlink"), codec: .hevc,
                                     width: 3840, height: 2160, frameRate: .fps23_976)
        facts.apply(video: video(check), audio: nil, audioDevice: nil)
        let track = CameraTrackBuilder.tracks(facts)[0]
        #expect(track.framesChecked == 300 && track.repeatedOnArrival == 129 && track.longestRepeatRun == 1)
        #expect(track.changedBeforeWrite == 2 && track.changedWhileHeld == 1 && track.uniqueFrameRatio == 0.57)
        #expect(track.shortRunRepeats == 129 && track.sameBufferRepeats == 0 && track.heldBufferArrivals == 0)
        // The frames after a repeat compare with a repeat; the first one has nothing before it.
        #expect(track.nearRepeatOnArrival == 85)

        let json = String(decoding: try SessionManifest.encoder().encode(track), as: UTF8.self)
        for key in ["\"frames_checked\" : 300", "\"repeated_on_arrival\" : 129", "\"longest_repeat_run\" : 1",
                    "\"changed_before_write\" : 2", "\"unique_frame_ratio\" : 0.57", "\"near_repeat_on_arrival\" : 85",
                    "\"short_run_repeats\" : 129", "\"same_buffer_repeats\" : 0", "\"held_buffer_arrivals\" : 0",
                    "\"changed_while_held\" : 1"] {
            #expect(json.contains(key), "\(key) in \(json)")
        }
        let data = CameraTrackReport.trackStopData(track: track, video: video(check), audio: nil)
        #expect(data["frames_checked"] == "300" && data["repeated_on_arrival"] == "129")
        #expect(data["longest_repeat_run"] == "1" && data["changed_before_write"] == "2")
        #expect(data["unique_frame_ratio"] == "0.5700" && data["near_repeat_on_arrival"] == "85")
        #expect(data["short_run_repeats"] == "129" && data["same_buffer_repeats"] == "0")
        #expect(data["held_buffer_arrivals"] == "0" && data["changed_while_held"] == "1")
        #expect(data["difference_buckets"] == "85,0,85,0")
    }

    /// The warning comes at Stop, on the file's totals, with the same verdict as the menu's note.
    @Test func theWarningUsesTheTotalsAtStop() throws {
        let check = counter(new: 171, repeats: 129)
        let warning = try #require(CameraTrackReport.repeatWarning(video(check), frameRate: .fps23_976))
        #expect(warning["message"] == "The camera sends the same picture again in 43% of frames, so "
            + "camera.mov looks choppy. A capture card on a shared USB port (a dock or a hub) does this at 4K: "
            + "plug it into the Mac or a Thunderbolt port.")
        #expect(warning["frames_checked"] == "300" && warning["repeated_on_arrival"] == "129")
        #expect(warning["repeated_percent"] == "43" && warning["choppy"] == "true" && warning["cause"] == "camera")
        #expect(warning["source"] == "camera" && warning["file"] == "camera.mov" && warning["track"] == "camera_video")
        var facts = CameraTrackFacts(videoDevice: DeviceInfo(name: "Cam Link 4K", uid: "camlink"), codec: .hevc,
                                     width: 3840, height: 2160, frameRate: .fps23_976)
        facts.apply(video: video(check), audio: nil, audioDevice: nil)
        #expect(RepeatedFrameRule.verdict(CameraTrackBuilder.tracks(facts)[0]) == check.verdict(frameRate: .fps23_976))

        let stack = try #require(CameraTrackReport.repeatWarning(video(counter(new: 171, repeats: 129, sameBuffer: true)),
                                                                 frameRate: .fps23_976))
        #expect(stack["cause"] == "capture_stack" && stack["same_buffer_repeats"] == "129")
        #expect(CameraTrackReport.repeatWarning(video(counter(new: 300, repeats: 10)), frameRate: .fps23_976) == nil)
        #expect(CameraTrackReport.repeatWarning(nil, frameRate: .fps23_976) == nil)
    }

    /// The camera picture froze for the first 15 s of a 20-minute take: no warning, since the take
    /// as a whole repeats 1.25% of its frames (a running total would have warned at 100%).
    @Test func anEarlyBurstInALongTakeDoesNotWarn() {
        var c = RepeatedFrameCounter()
        for _ in 0..<360 { c.arrived(fp(0)) }
        for n in 1...28_440 { c.arrived(fp(n)) }
        #expect(c.checked == 28_800 && c.repeatedOnArrival == 359)
        #expect(CameraTrackReport.repeatWarning(video(c), frameRate: .fps23_976) == nil)
    }

    /// A format the check cannot read: zero counts and no ratio, in both places.
    @Test func noCheckedFramesMeansNoRatio() {
        var facts = CameraTrackFacts(videoDevice: DeviceInfo(name: "Cam", uid: "cam"), codec: .hevc,
                                     width: 320, height: 180, frameRate: .fps23_976)
        facts.apply(video: video(RepeatedFrameCounter()), audio: nil, audioDevice: nil)
        let track = CameraTrackBuilder.tracks(facts)[0]
        #expect(track.framesChecked == 0 && track.uniqueFrameRatio == nil)
        let data = CameraTrackReport.trackStopData(track: track, video: video(RepeatedFrameCounter()), audio: nil)
        #expect(data["frames_checked"] == "0" && data["unique_frame_ratio"] == nil)
    }

    /// The fields are additive (1.7): a 1.6 track without them still reads.
    @Test func olderTracksStillRead() throws {
        let old = #"{"file":"camera.mov","track_index":0,"role":"camera_video","dialogue":false,"slots_repeated":2}"#
        let track = try SessionManifest.decoder().decode(TrackInfo.self, from: Data(old.utf8))
        #expect(track.slotsRepeated == 2 && track.framesChecked == nil && track.repeatedOnArrival == nil)
        #expect(track.uniqueFrameRatio == nil && track.changedBeforeWrite == nil && track.longestRepeatRun == nil)
        #expect(track.nearRepeatOnArrival == nil && track.shortRunRepeats == nil && track.sameBufferRepeats == nil)
        #expect(track.heldBufferArrivals == nil && track.changedWhileHeld == nil && RepeatedFrameRule.verdict(track) == nil)
        #expect(SessionManifest.currentSchemaVersion == "1.7")
    }
}
