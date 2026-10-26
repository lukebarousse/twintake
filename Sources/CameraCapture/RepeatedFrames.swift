import CoreVideo
import IOSurface
import RecorderCore

// Repeated frames: camera.mov from the a6600 through the Cam Link 4K looked choppy. Decoded, 43-46%
// of its consecutive frames were the same picture (about 13 new pictures a second in a 23.976
// file), while the writer had given nearly every arriving frame its own slot. These checks say
// where the repeats come from, per file:
//
// 1. On arrival: a frame whose fingerprint equals the frame before it is the same picture again
//    (`repeated_on_arrival`). Its buffer tells who repeated it: the same buffer as the frame
//    before means macOS's capture stack delivered it again (`same_buffer_repeats`); a new buffer
//    means the camera or the capture card sent the picture again. A frame that arrives in a buffer
//    TwinTake still holds is counted too (`held_buffer_arrivals`): a buffer pool never hands out
//    a buffer that is still held, so any such frame points at the capture stack or the driver.
// 2. Nearly the same: a frame that is not bit-identical, but whose samples moved by almost
//    nothing (`near_repeat_on_arrival`, `SampleDifference`): a repeat that a changed overlay or
//    re-processing made inexact.
// 3. Right before the writer takes a new frame: a fingerprint that differs from the one taken at
//    arrival means the buffer's content changed while it waited (`changed_before_write`).
// 4. While TwinTake still holds the written frame (the encoder reads it later, without waiting):
//    when the next new frame replaces it (about one frame later) and at the end, a fingerprint that
//    differs from the one at the write means its content changed after the write
//    (`changed_while_held`).
//
// A new camera image differs from the last one by sensor noise, so its uncompressed bytes are
// never all the same; a repeated image is bit-identical. The fingerprint compares exactly. A flat
// picture (every sampled byte the same: a lens cap, an empty frame) is never counted: two flat
// frames are the same without anything repeating them.
//
// Cost: three read-only locks of the base address and 3 x 1024 one-byte reads per new frame, on
// the video queue. Measured on 3840x2160 420v buffers (release build, M-series, caches evicted):
// about 31 us per new frame in all (60 us p99) of its 41.7 ms: 18 us on arrival (samples,
// difference and buffer IDs included), 2 us right before the write, 10 us for the held check.
// Nothing is copied; only buffer IDs are kept, never a buffer.

/// 1024 luma bytes of a frame, on a 32x32 grid over plane 0, hashed.
struct FrameFingerprint: Sendable, Hashable {
    /// FNV-1a (64 bit) over the sampled bytes in grid order. One changed byte always changes it.
    var hash: UInt64
    /// Every sampled position held the same value.
    var flat: Bool
}

/// Which memory a frame came in: its IOSurface's ID, or the buffer object's address when it has
/// none. Only the ID is kept, never the buffer.
enum FrameBufferID: Sendable, Hashable {
    case surface(IOSurfaceID)
    case object(UInt)

    init(_ buffer: CVPixelBuffer) {
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            self = .surface(IOSurfaceGetID(surface))
        } else {
            self = .object(UInt(bitPattern: Unmanaged.passUnretained(buffer).toOpaque()))
        }
    }
}

/// The sampled luma values of one frame, on a 16-bit scale (an 8-bit value times 256, a 10-bit
/// sample's stored 16-bit word), so 8-bit and 10-bit frames compare in the same units. The video
/// queue keeps two and swaps them each frame: no allocation per frame.
struct FrameSamples: Sendable {
    var values = [UInt16](repeating: 0, count: FingerprintGrid.side * FingerprintGrid.side)
    /// The values are a frame's (the last read succeeded).
    var valid = false
}

/// How much a frame's samples changed from the frame before. Finds a repeated picture that is not
/// bit-identical: an overlay that changed in a few places, or processing that moves a few values.
struct SampleDifference: Sendable, Equatable {
    /// A sample that changed by more than this many 8-bit steps moved: motion, or a changed overlay.
    static let movedSteps = 16
    /// Near repeat: at most 2% of the samples moved, and the others changed by less than this many
    /// 8-bit steps on average. Sensor noise changes a new picture's samples by about 0.5 step or more.
    static let nearMean = 0.1
    /// The upper limits of the mean change for `bucket`, below the last bucket.
    static let bucketLimits = [nearMean, 0.5, 2.0]

    /// Samples that moved.
    var moved: Int
    /// The mean change of the samples that did not move, in 8-bit steps.
    var mean: Double
    var count: Int

    init(moved: Int, mean: Double, count: Int) {
        self.moved = moved
        self.mean = mean
        self.count = count
    }

    /// Nil when the two frames have different sample counts.
    init?(_ current: [UInt16], _ previous: [UInt16]) {
        guard current.count == previous.count, !current.isEmpty else { return nil }
        let limit = UInt32(Self.movedSteps) << 8
        var moved = 0
        var sum: UInt64 = 0
        for i in current.indices {
            let a = current[i], b = previous[i]
            let d = UInt32(a > b ? a - b : b - a)
            if d > limit { moved += 1 } else { sum += UInt64(d) }
        }
        let kept = current.count - moved
        self.init(moved: moved, mean: kept > 0 ? Double(sum) / 256 / Double(kept) : 0, count: current.count)
    }

    /// More than 2% of the samples moved: a new picture whatever the mean.
    var mostlyMoved: Bool { moved * 50 > count }

    var isNearRepeat: Bool { !mostlyMoved && mean < Self.nearMean }

    /// 0: a near repeat; 1: mean under 0.5 step; 2: under 2 steps; 3: 2 steps or more, or more than
    /// 2% of the samples moved.
    var bucket: Int {
        mostlyMoved ? Self.bucketLimits.count : (Self.bucketLimits.firstIndex { mean < $0 } ?? Self.bucketLimits.count)
    }
}

/// Where the fingerprint reads in plane 0 of one frame geometry. Built once per geometry and
/// reused for every frame of it, so a frame costs no allocation.
struct FingerprintGrid: Sendable, Equatable {
    /// Positions per row and per column: 32 x 32 = 1024 samples.
    static let side = 32

    let width: Int
    let height: Int
    let rowBytes: Int
    /// Bytes per luma sample: 1 for 8-bit, 2 for 10-bit.
    let pixelBytes: Int
    /// Byte offsets of the samples from the start of plane 0, row by row.
    let offsets: [Int]

    /// Nil when the plane cannot hold the samples (no pixels, or rows shorter than the width).
    init?(width: Int, height: Int, rowBytes: Int, pixelBytes: Int) {
        guard width > 0, height > 0, (1...8).contains(pixelBytes), rowBytes >= width * pixelBytes else { return nil }
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.pixelBytes = pixelBytes
        let xs = Self.positions(count: width), ys = Self.positions(count: height)
        var offsets: [Int] = []
        offsets.reserveCapacity(xs.count * ys.count)
        for y in ys {
            for x in xs { offsets.append(y * rowBytes + x * pixelBytes) }
        }
        self.offsets = offsets
    }

    /// The centers of `side` equal cells over `count` pixels: (2i + 1) * count / (2 * side). Every
    /// position is in 0..<count, also for odd sizes and sizes under `side` (positions then repeat).
    static func positions(count: Int, side: Int = side) -> [Int] {
        guard count > 0, side > 0 else { return [] }
        return (0..<side).map { (2 * $0 + 1) * count / (2 * side) }
    }

    /// The end of the last byte the grid reads: never past `height * rowBytes`, the plane's size.
    var lastByteEnd: Int { (offsets.max() ?? 0) + pixelBytes }

    func fits(width: Int, height: Int, rowBytes: Int, pixelBytes: Int) -> Bool {
        self.width == width && self.height == height && self.rowBytes == rowBytes && self.pixelBytes == pixelBytes
    }

    /// Reads the samples from plane 0 at `base` (locked by the caller). With `samples` (at least
    /// `offsets.count` long), also stores each sample there on the 16-bit scale of `FrameSamples`.
    func fingerprint(base: UnsafeRawPointer, samples: UnsafeMutableBufferPointer<UInt16>? = nil) -> FrameFingerprint {
        let store = samples.flatMap { $0.count >= offsets.count ? $0 : nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var flat = true
        var first: UInt64?
        for (i, offset) in offsets.enumerated() {
            var value: UInt64 = 0
            for k in 0..<pixelBytes {
                let byte = base.load(fromByteOffset: offset + k, as: UInt8.self)
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
                value |= UInt64(byte) << (8 * UInt64(k))
            }
            if let first { if value != first { flat = false } } else { first = value }
            if let store { store[i] = pixelBytes == 1 ? UInt16(value) << 8 : UInt16(truncatingIfNeeded: value) }
        }
        return FrameFingerprint(hash: hash, flat: flat)
    }
}

enum FrameFingerprinter {
    /// Bytes per luma sample of the formats the check reads: 4:2:0 biplanar, 8-bit (420v, 420f)
    /// or 10-bit (x420, xf20). Nil for any other format: such frames are not checked.
    static func lumaBytes(format: OSType) -> Int? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: 1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: 2
        default: nil
        }
    }

    /// The fingerprint of `buffer`'s plane 0. `grid` is reused while the geometry stays, else
    /// rebuilt. Nil for a format it does not read or a buffer it cannot lock. Read only.
    static func fingerprint(_ buffer: CVPixelBuffer, grid: inout FingerprintGrid?) -> FrameFingerprint? {
        read(buffer, grid: &grid, samples: nil)
    }

    /// `fingerprint(_:grid:)`, and the sampled values in `samples` (`FrameSamples.values`).
    static func fingerprint(_ buffer: CVPixelBuffer, grid: inout FingerprintGrid?, samples: inout [UInt16]) -> FrameFingerprint? {
        samples.withUnsafeMutableBufferPointer { read(buffer, grid: &grid, samples: $0) }
    }

    private static func read(_ buffer: CVPixelBuffer, grid: inout FingerprintGrid?,
                             samples: UnsafeMutableBufferPointer<UInt16>?) -> FrameFingerprint? {
        guard CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              let pixelBytes = lumaBytes(format: CVPixelBufferGetPixelFormatType(buffer)) else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        if grid?.fits(width: width, height: height, rowBytes: rowBytes, pixelBytes: pixelBytes) != true {
            grid = FingerprintGrid(width: width, height: height, rowBytes: rowBytes, pixelBytes: pixelBytes)
        }
        return grid?.fingerprint(base: UnsafeRawPointer(base), samples: samples)
    }
}

/// Counts, for one file, the camera frames that bring no new picture, who repeated them, and the
/// frames whose content changed after they arrived. Plain data: confined to the video queue.
struct RepeatedFrameCounter: Sendable, Equatable {
    /// Arriving frames with a fingerprint that is not flat: the frames the check counts.
    private(set) var checked: Int64 = 0
    /// Checked frames whose fingerprint equals the frame right before them (checked too).
    private(set) var repeatedOnArrival: Int64 = 0
    /// Checked frames that are not bit-identical to the frame before but nearly
    /// (`SampleDifference.isNearRepeat`). Not in `repeatedOnArrival`.
    private(set) var nearRepeatOnArrival: Int64 = 0
    /// The most repeated frames in a row: 3 means one picture came 4 times.
    private(set) var longestRepeatRun: Int64 = 0
    /// Repeats that came in the same buffer as the frame before: the capture stack delivered it again.
    private(set) var sameBufferRepeats: Int64 = 0
    /// Checked frames that arrived in a buffer TwinTake still held (the last written frame or a
    /// waiting one).
    private(set) var heldBufferArrivals: Int64 = 0
    /// New frames whose fingerprint right before the writer took them differed from the one at arrival.
    private(set) var changedBeforeWrite: Int64 = 0
    /// Written frames whose fingerprint, while TwinTake still held them, differed from the one at the write.
    private(set) var changedWhileHeld: Int64 = 0
    /// Checked frames that were not repeats, by how much they changed from the frame before
    /// (`SampleDifference.bucket`). Bucket 0 is `nearRepeatOnArrival`.
    private(set) var differenceBuckets = [Int64](repeating: 0, count: SampleDifference.bucketLimits.count + 1)
    /// Repeats in runs that ended with at most `RepeatedFrameRule.shortRunMax` repeats.
    private var closedShortRunRepeats: Int64 = 0
    private var run: Int64 = 0
    private var previous: FrameFingerprint?
    private var previousBuffer: FrameBufferID?

    /// Repeats in runs of at most `RepeatedFrameRule.shortRunMax` (one picture held for a moment
    /// between new ones), the run still open included.
    var shortRunRepeats: Int64 { closedShortRunRepeats + (run <= RepeatedFrameRule.shortRunMax ? run : 0) }

    /// One arriving frame (nil: it could not be read). `difference` compares its samples with the
    /// frame before; `buffer` is its memory; `held` is true when TwinTake still held that buffer.
    /// Returns true when it repeats the frame before it.
    @discardableResult
    mutating func arrived(_ fingerprint: FrameFingerprint?, difference: SampleDifference? = nil,
                          buffer: FrameBufferID? = nil, held: Bool = false) -> Bool {
        defer { previousBuffer = buffer }
        guard let fingerprint, !fingerprint.flat else {
            endRun()
            previous = nil
            return false
        }
        checked += 1
        if held { heldBufferArrivals += 1 }
        let before = previous
        previous = fingerprint
        guard fingerprint == before else {
            endRun()
            if before != nil, let difference {
                if difference.isNearRepeat { nearRepeatOnArrival += 1 }
                differenceBuckets[difference.bucket] += 1
            }
            return false
        }
        repeatedOnArrival += 1
        if let buffer, buffer == previousBuffer { sameBufferRepeats += 1 }
        run += 1
        longestRepeatRun = max(longestRepeatRun, run)
        return true
    }

    private mutating func endRun() {
        if run <= RepeatedFrameRule.shortRunMax { closedShortRunRepeats += run }
        run = 0
    }

    /// A new frame right before the writer takes it, with its fingerprints at arrival and now.
    /// Returns true when its content changed in between.
    @discardableResult
    mutating func beforeWrite(atArrival: FrameFingerprint?, now: FrameFingerprint?) -> Bool {
        guard let atArrival, let now, atArrival != now else { return false }
        changedBeforeWrite += 1
        return true
    }

    /// A written frame TwinTake still holds, with its fingerprints at the write and now. Returns
    /// true when its content changed in between.
    @discardableResult
    mutating func whileHeld(atWrite: FrameFingerprint?, now: FrameFingerprint?) -> Bool {
        guard let atWrite, let now, atWrite != now else { return false }
        changedWhileHeld += 1
        return true
    }

    /// New pictures per checked frame: 1 when every frame brought a new picture. Nil before a
    /// frame was checked.
    var uniqueFrameRatio: Double? { RepeatedFrameRule.uniqueRatio(repeated: repeatedOnArrival, checked: checked) }

    /// The verdict on these totals (`RepeatedFrameRule.verdict`).
    func verdict(frameRate: FrameRate) -> RepeatedFrameRule.Verdict? {
        RepeatedFrameRule.verdict(checked: checked, repeated: repeatedOnArrival, shortRunRepeats: shortRunRepeats,
                                  sameBufferRepeats: sameBufferRepeats, frameRate: frameRate)
    }
}

/// When repeated frames are worth a warning, who repeated them, and the words. Decided on a file's
/// totals at Stop, so the take's event and the menu's note on the last take always agree.
public enum RepeatedFrameRule {
    /// More than this share of the checked frames repeating the frame before them warns.
    public static let warnPercent: Int64 = 5
    /// The check needs this much video (in frames at the file's rate) before it warns.
    public static let minimumSeconds: Int64 = 10
    /// A run of at most this many repeats is short: one picture held for at most 5 frames (0.2 s
    /// at 23.976) between new ones, which makes motion choppy. Longer runs are a still picture (a
    /// slide, a paused source, a camera menu).
    public static let shortRunMax: Int64 = 4

    /// Who repeated the pictures, as far as the buffers tell.
    public enum Cause: String, Sendable {
        /// Mostly new buffers with the same picture: the camera or the capture card sent it again.
        case camera
        /// Mostly the same buffer as the frame before: macOS's capture stack delivered it again.
        case captureStack = "capture_stack"
    }

    public struct Verdict: Sendable, Equatable {
        /// Repeated frames in whole percent of the checked frames.
        public var percent: Int
        /// Repeats in short runs are more than `warnPercent` of the checked frames: choppy motion.
        public var choppy: Bool
        public var cause: Cause
    }

    /// `minimumSeconds` in frames, rounded up: 240 at 23.976.
    public static func minimumFrames(_ frameRate: FrameRate) -> Int64 {
        let num = Int64(frameRate.num), den = Int64(max(1, frameRate.den))
        return (minimumSeconds * num + den - 1) / den
    }

    /// True when more than `warnPercent` of at least `minimumFrames` checked frames repeated.
    public static func tooMany(repeated: Int64, checked: Int64, frameRate: FrameRate) -> Bool {
        checked >= minimumFrames(frameRate) && repeated * 100 > checked * warnPercent
    }

    /// The verdict on a file's totals; nil when the repeats are not worth a warning.
    public static func verdict(checked: Int64, repeated: Int64, shortRunRepeats: Int64, sameBufferRepeats: Int64,
                               frameRate: FrameRate) -> Verdict? {
        guard tooMany(repeated: repeated, checked: checked, frameRate: frameRate) else { return nil }
        return Verdict(percent: percent(repeated: repeated, checked: checked),
                       choppy: shortRunRepeats * 100 > checked * warnPercent,
                       cause: sameBufferRepeats * 2 > repeated ? .captureStack : .camera)
    }

    /// The verdict on session.json's camera video track (1.7); nil for an older take.
    public static func verdict(_ track: TrackInfo) -> Verdict? {
        guard let checked = track.framesChecked, let repeated = track.repeatedOnArrival, let rate = track.frameRate else { return nil }
        return verdict(checked: Int64(checked), repeated: Int64(repeated), shortRunRepeats: Int64(track.shortRunRepeats ?? 0),
                       sameBufferRepeats: Int64(track.sameBufferRepeats ?? 0), frameRate: rate)
    }

    /// The repeated share in whole percent, rounded (43 for 104 of 240).
    public static func percent(repeated: Int64, checked: Int64) -> Int {
        guard checked > 0 else { return 0 }
        return Int((Double(repeated) * 100 / Double(checked)).rounded())
    }

    /// New pictures per checked frame; nil without checked frames.
    public static func uniqueRatio(repeated: Int64, checked: Int64) -> Double? {
        guard checked > 0 else { return nil }
        return Double(checked - repeated) / Double(checked)
    }

    /// The take's warning (events.jsonl, at Stop). "Choppy" only for short runs.
    public static func warning(_ v: Verdict) -> String {
        switch (v.cause, v.choppy) {
        case (.camera, true):
            "The camera sends the same picture again in \(v.percent)% of frames, so camera.mov looks choppy. "
                + "A capture card on a shared USB port (a dock or a hub) does this at 4K: "
                + "plug it into the Mac or a Thunderbolt port."
        case (.captureStack, true):
            "macOS delivers the same camera buffer again in \(v.percent)% of frames: "
                + "the capture stack repeats frames, not the camera, so camera.mov looks choppy."
        case (.camera, false):
            "The camera sent the same picture again in \(v.percent)% of frames, mostly in long runs: a still picture."
        case (.captureStack, false):
            "macOS delivered the same camera buffer again in \(v.percent)% of frames, mostly in long runs: a still picture."
        }
    }

    /// The note on the menu's last take: only for choppy repeats (a still picture plays as it should).
    public static func menuNote(_ v: Verdict) -> String? {
        guard v.choppy else { return nil }
        return switch v.cause {
        case .camera:
            "camera.mov looks choppy: \(v.percent)% of its frames repeat. Plug the capture card into the Mac "
                + "or a Thunderbolt port, not a dock's or hub's USB port."
        case .captureStack:
            "camera.mov looks choppy: macOS delivered the same camera buffer again in \(v.percent)% of its frames "
                + "(the capture stack repeats frames, not the camera)."
        }
    }

    /// The take's warning when a frame changed before it was written.
    public static let changedBeforeWriteWarning =
        "Camera frames changed before camera.mov wrote them, so the file can show a picture twice."

    /// The take's warning when a written frame changed while TwinTake still held it.
    public static let changedWhileHeldWarning =
        "Camera frames changed in memory after TwinTake passed them to the encoder, so camera.mov can show a picture twice."
}
