import CoreMedia
import Foundation
import RecorderCore

/// What the camera sends, as the recorder records it: the largest size the camera offers now and
/// its rate as an exact rational. A capture card offers only its HDMI input, so this is the HDMI
/// signal. Plain data for the UI ("3840x2160 · 23.976 fps", a 4K badge) and session.json.
public struct CameraSignal: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    /// FourCC of the device format the recorder picks for it, e.g. "420v".
    public var pixelFormat: String

    public init(width: Int, height: Int, frameRate: FrameRate, pixelFormat: String) {
        self.width = width; self.height = height; self.frameRate = frameRate; self.pixelFormat = pixelFormat
    }

    /// "3840x2160 · 23.976 fps".
    public var label: String { "\(width)x\(height) · \(frameRate.label) fps" }

    /// "3840x2160 23.976", the short form the menu's Signal line and the old labels use.
    public var shortLabel: String { "\(width)x\(height) \(frameRate.label)" }

    /// True for UHD 4K (3840x2160) or larger.
    public var is4K: Bool { width >= 3840 && height >= 2160 }

    /// "4K", or the height as "1080p", "720p".
    public var sizeName: String { is4K ? "4K" : "\(height)p" }

    /// Sony's name for the rate: 23.976 is "24p", 29.97 is "30p".
    public var sonyRateName: String { "\(Int(frameRate.framesPerSecond.rounded()))p" }

    /// The screen rate that goes with this camera rate (47.952 for 23.976).
    public var screenFrameRate: FrameRate { ScreenRecorderConfig.frameRate(forCameraRate: frameRate) }
}

/// The standard video frame rates, and the rule that snaps a device's floating-point rate (or a
/// measured one) to one of them.
public enum StandardFrameRate {
    public static let all: [FrameRate] = [
        .fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps47_952, FrameRate(num: 48, den: 1),
        FrameRate(num: 50, den: 1), .fps59_94, .fps60,
    ]

    /// Relative distance within which a rate counts as a standard one: 0.1%. 23.98 (the Cam Link's
    /// rounded 23.976) is 0.017% from 23.976 and 0.083% from 24, so the nearest wins.
    public static let tolerance = 0.001

    /// The standard rate nearest to `fps`, when it is within `tolerance`; else nil.
    /// 23.976 and 23.98 give 24000/1001, 24.00 gives 24/1, 29.97 gives 30000/1001, 59.94 gives
    /// 60000/1001; 25, 30, 50 and 60 stay whole.
    public static func snap(_ fps: Double) -> FrameRate? {
        guard fps.isFinite, fps > 0 else { return nil }
        let nearest = all.min { abs($0.framesPerSecond - fps) < abs($1.framesPerSecond - fps) }
        guard let nearest, abs(nearest.framesPerSecond - fps) / nearest.framesPerSecond <= tolerance else { return nil }
        return nearest
    }

    /// `snap(fps)`, else the exact rational `FrameRateSnap` makes (millisecond precision).
    static func rate(forFps fps: Double) -> FrameRate? {
        snap(fps) ?? FrameRateSnap.rate(forFps: fps)
    }

    /// The rate for one device frame duration, e.g. 1251/30000 s (23.98) gives 24000/1001.
    static func rate(forFrameDuration duration: CMTime) -> FrameRate? {
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0 else { return nil }
        return rate(forFps: Double(duration.timescale) / Double(duration.value))
    }
}

extension CameraSignal {
    /// The signal a camera offers, from its formats: the format with the most pixels, then the
    /// highest rate, then the best pixel format (420v first), with that format's highest rate
    /// snapped to a standard rational. Nil when the camera offers no format (no HDMI signal).
    static func resolve(_ candidates: [VideoFormatCandidate]) -> (index: Int, signal: CameraSignal)? {
        guard let index = FormatMatcher.bestAvailable(in: candidates) else { return nil }
        let c = candidates[index]
        guard let rate = StandardFrameRate.rate(forFps: c.maxFps) else { return nil }
        return (index, CameraSignal(width: c.width, height: c.height, frameRate: rate, pixelFormat: c.pixelFormat))
    }
}
