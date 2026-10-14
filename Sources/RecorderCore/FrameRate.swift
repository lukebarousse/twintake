import CoreMedia
import Foundation

/// An exact frame rate stored as a rational, for example 24000/1001 for 23.976 fps.
///
/// Never store NTSC rates as floating point. Final Cut Pro treats 24.000 and 23.976 as
/// different rates and retimes one to the other, which makes files drift apart.
public struct FrameRate: Codable, Hashable, Sendable, CustomStringConvertible {
    public var num: Int32
    public var den: Int32

    public init(num: Int32, den: Int32) {
        precondition(num > 0 && den > 0, "FrameRate needs a positive numerator and denominator")
        self.num = num
        self.den = den
    }

    public static let fps23_976 = FrameRate(num: 24000, den: 1001)
    public static let fps24 = FrameRate(num: 24, den: 1)
    public static let fps25 = FrameRate(num: 25, den: 1)
    public static let fps29_97 = FrameRate(num: 30000, den: 1001)
    public static let fps30 = FrameRate(num: 30, den: 1)
    public static let fps47_952 = FrameRate(num: 48000, den: 1001)
    public static let fps59_94 = FrameRate(num: 60000, den: 1001)
    public static let fps60 = FrameRate(num: 60, den: 1)

    public var framesPerSecond: Double { Double(num) / Double(den) }

    /// Duration of one frame: 1001/24000 s for 23.976.
    public var frameDuration: CMTime { CMTime(value: CMTimeValue(den), timescale: num) }

    /// A media timescale that represents every frame time exactly (the numerator).
    public var timescale: CMTimeScale { num }

    /// Exact presentation time of frame `index` on this rate's grid.
    public func time(ofFrame index: Int64) -> CMTime {
        CMTime(value: index * CMTimeValue(den), timescale: num)
    }

    /// The grid frame nearest to `time` (time measured from the start of the grid).
    public func nearestFrame(at time: CMTime) -> Int64 {
        let scaled = CMTimeConvertScale(time, timescale: num, method: .roundHalfAwayFromZero)
        let d = Int64(den)
        let v = scaled.value
        return v >= 0 ? (v + d / 2) / d : -((-v + d / 2) / d)
    }

    /// True when `fps` is within `tolerance` of this rate. Use it to match AVFoundation's
    /// floating-point frame-rate ranges to an exact rate.
    public func matches(_ fps: Double, tolerance: Double = 0.01) -> Bool {
        abs(fps - framesPerSecond) <= tolerance
    }

    /// Short label such as "23.976", "47.952" or "30".
    public var label: String {
        if den == 1 { return "\(num)" }
        var s = String(format: "%.3f", framesPerSecond)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public var description: String { "\(label) fps (\(num)/\(den))" }
}
