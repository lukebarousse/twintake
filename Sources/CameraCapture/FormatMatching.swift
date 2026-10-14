import CoreMedia
import Foundation
import RecorderCore

/// One frame-rate range of a device format, as AVFrameRateRange reports it.
struct FrameRateSpan: Sendable, Equatable {
    var minFps: Double
    var maxFps: Double
    /// Exact durations from AVFrameRateRange. `minFrameDuration` is 1 / `maxFps`.
    var minFrameDuration: CMTime?
    var maxFrameDuration: CMTime?

    init(minFps: Double, maxFps: Double, minFrameDuration: CMTime? = nil, maxFrameDuration: CMTime? = nil) {
        self.minFps = minFps; self.maxFps = maxFps
        self.minFrameDuration = minFrameDuration; self.maxFrameDuration = maxFrameDuration
    }

    /// A span that holds exactly one rate, e.g. 23.976...23.976 on a capture card.
    init(fps: Double) { self.init(minFps: fps, maxFps: fps) }

    var isSingleRate: Bool { abs(maxFps - minFps) < 0.001 }

    func contains(_ fps: Double, tolerance: Double) -> Bool {
        fps >= minFps - tolerance && fps <= maxFps + tolerance
    }
}

/// A device video format reduced to what format matching needs. Built from
/// `AVCaptureDevice.Format`; plain data so the matching rules can be tested without a device.
struct VideoFormatCandidate: Sendable, Equatable {
    var width: Int
    var height: Int
    /// Pixel format FourCC, e.g. "420v" (8-bit 4:2:0) or "yuvs" (8-bit 4:2:2).
    var pixelFormat: String
    var frameRates: [FrameRateSpan]

    var maxFps: Double { frameRates.map(\.maxFps).max() ?? 0 }
}

/// Picks the device format to record from.
enum FormatMatcher {
    /// Frame-rate tolerance in fps. Wide enough for AVFoundation's floating-point ranges,
    /// narrow enough to tell 23.976 from 24.
    static let defaultTolerance = 0.01

    /// Lower is better. 420v is what HEVC and H.264 encode natively, so it needs no conversion.
    static func pixelFormatRank(_ fourCC: String) -> Int {
        switch fourCC {
        case "420v": 0
        case "420f": 1
        case "x420": 2
        case "2vuy", "yuvs": 3
        default: 4
        }
    }

    /// Index of the best candidate with exactly `width` x `height` that supports `frameRate`,
    /// or nil when the device offers none. Prefers 420v, then a span that holds only that rate,
    /// then device order.
    static func bestMatch(in candidates: [VideoFormatCandidate], width: Int, height: Int,
                          frameRate: FrameRate, tolerance: Double = defaultTolerance) -> Int? {
        let fps = frameRate.framesPerSecond
        let matches = candidates.indices.filter { i in
            let c = candidates[i]
            return c.width == width && c.height == height && c.frameRates.contains { $0.contains(fps, tolerance: tolerance) }
        }
        func key(_ i: Int) -> (Int, Int, Int) {
            let exact = candidates[i].frameRates.contains { $0.isSingleRate && $0.contains(fps, tolerance: tolerance) }
            return (pixelFormatRank(candidates[i].pixelFormat), exact ? 0 : 1, i)
        }
        return matches.min { key($0) < key($1) }
    }

    /// The span of `candidate` that holds `frameRate`. Prefers a single-rate span.
    static func matchingSpan(in candidate: VideoFormatCandidate, frameRate: FrameRate,
                             tolerance: Double = defaultTolerance) -> FrameRateSpan? {
        let fps = frameRate.framesPerSecond
        let spans = candidate.frameRates.filter { $0.contains(fps, tolerance: tolerance) }
        return spans.first(where: \.isSingleRate) ?? spans.first
    }

    /// Index of the format with the most pixels, then the highest rate, then the best pixel format.
    /// This is what a capture card is getting over HDMI (it lists only the incoming signal).
    static func bestAvailable(in candidates: [VideoFormatCandidate]) -> Int? {
        func key(_ i: Int) -> (Int, Double, Int) {
            let c = candidates[i]
            return (c.width * c.height, c.maxFps, -pixelFormatRank(c.pixelFormat))
        }
        return candidates.indices.max { key($0) < key($1) }
    }

    /// The frame duration to set for `frameRate` on `candidate`, always inside one of its ranges.
    /// The span that holds the rate within the tolerance `StandardFrameRate.snap` uses (0.1%, so
    /// a format that runs 29.95 fps holds the 30000/1001 it snaps to), else the span nearest to it;
    /// then the exact duration clamped to that span (`frameDuration(for:in:)`). The exact duration
    /// only when the format lists no range at all.
    static func frameDuration(for frameRate: FrameRate, in candidate: VideoFormatCandidate) -> CMTime {
        let fps = frameRate.framesPerSecond
        let tolerance = max(defaultTolerance, fps * StandardFrameRate.tolerance)
        func distance(_ span: FrameRateSpan) -> Double {
            fps < span.minFps ? span.minFps - fps : fps > span.maxFps ? fps - span.maxFps : 0
        }
        let span = matchingSpan(in: candidate, frameRate: frameRate, tolerance: tolerance)
            ?? candidate.frameRates.min { distance($0) < distance($1) }
        return span.map { frameDuration(for: frameRate, in: $0) } ?? frameRate.frameDuration
    }

    /// True when `duration` lies inside one of `ranges` (a format's min and max frame durations),
    /// so AVFoundation takes it as activeVideoMin/MaxFrameDuration without an exception.
    static func durationFits(_ duration: CMTime, ranges: [(min: CMTime, max: CMTime)]) -> Bool {
        guard duration.isNumeric else { return false }
        return ranges.contains { CMTimeCompare(duration, $0.min) >= 0 && CMTimeCompare(duration, $0.max) <= 0 }
    }

    /// True when the format the camera runs now no longer holds `rate` (the rate camera.mov's grid
    /// runs): its highest rate snaps to another standard rate and no span holds `rate` (within
    /// `defaultTolerance`). A webcam's 1-30 span still holds 24; the Cam Link's 23.98 still holds
    /// 23.976; a capture card that now lists only 29.97 does not.
    static func rateChanged(_ now: VideoFormatCandidate, from rate: FrameRate) -> Bool {
        guard let sent = StandardFrameRate.rate(forFps: now.maxFps), sent != rate else { return false }
        return !now.frameRates.contains { $0.contains(rate.framesPerSecond, tolerance: defaultTolerance) }
    }

    /// The frame duration to set as both activeVideoMinFrameDuration and activeVideoMaxFrameDuration.
    ///
    /// Returns the exact rate when the span allows it, otherwise the nearest bound of the span.
    /// AVFoundation throws an Objective-C exception (which crashes the app) for a duration outside
    /// the active format's ranges, and a device may store 23.976 with its own rounding.
    static func frameDuration(for frameRate: FrameRate, in span: FrameRateSpan) -> CMTime {
        let exact = frameRate.frameDuration
        guard let lo = span.minFrameDuration, let hi = span.maxFrameDuration, lo.isNumeric, hi.isNumeric else {
            return exact
        }
        if CMTimeCompare(exact, lo) < 0 { return lo }
        if CMTimeCompare(exact, hi) > 0 { return hi }
        return exact
    }
}

/// Human-readable format strings for the UI, preflight messages and session.json.
enum FormatLabel {
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08x", code)
    }

    /// "23.976", "29.97", "30", "59.94".
    static func fps(_ fps: Double) -> String {
        FrameRateSnap.rate(forFps: fps)?.label ?? String(format: "%.3f", fps)
    }

    /// "23.976" for a single rate, "1-30" for a range.
    static func span(_ span: FrameRateSpan) -> String {
        span.isSingleRate ? fps(span.maxFps) : "\(fps(span.minFps))-\(fps(span.maxFps))"
    }

    /// "1920x1080 23.976": the signal as a capture card reports it (highest rate of the format).
    static func signal(_ c: VideoFormatCandidate) -> String {
        "\(c.width)x\(c.height) \(fps(c.maxFps))"
    }

    /// "1920x1080 420v 23.976" or "1280x720 420v 1-30,60": one line per device format.
    static func listing(_ c: VideoFormatCandidate) -> String {
        let rates = c.frameRates.map(span).joined(separator: ",")
        return "\(c.width)x\(c.height) \(c.pixelFormat) \(rates.isEmpty ? "?" : rates)"
    }

    /// "3840x2160 420v 23.976": what the recorder actually negotiated.
    static func negotiated(width: Int, height: Int, pixelFormat: String, frameRate: FrameRate) -> String {
        "\(width)x\(height) \(pixelFormat) \(frameRate.label)"
    }

    /// "2 ch, 48 kHz".
    static func audio(sampleRate: Double, channels: Int) -> String {
        "\(channels) ch, \(kHz(sampleRate)) kHz"
    }

    private static func kHz(_ sampleRate: Double) -> String {
        let k = sampleRate / 1000
        return k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
    }
}

/// Turns AVFoundation's floating-point rates into exact rationals.
enum FrameRateSnap {
    /// 23.976... (or a rounded 23.98) gives 24000/1001, 30.0 gives 30/1. Other rates keep
    /// millisecond precision. NTSC rates sit at least 0.024 fps from the whole rate, so the
    /// 0.005 window cannot mix them up.
    static func rate(forFps fps: Double) -> FrameRate? {
        guard fps.isFinite, fps > 0, fps < 100_000 else { return nil }
        let whole = fps.rounded()
        if whole >= 1, abs(whole - fps) < 0.002 {
            return FrameRate(num: Int32(whole), den: 1)
        }
        let ntsc = (fps * 1.001).rounded()
        if ntsc >= 1, abs(ntsc * 1000 / 1001 - fps) < 0.005 {
            return FrameRate(num: Int32(ntsc * 1000), den: 1001)
        }
        let milli = (fps * 1000).rounded()
        return milli >= 1 ? FrameRate(num: Int32(milli), den: 1000) : nil
    }

    /// The rate for one frame duration, e.g. 1001/24000 s gives 24000/1001.
    static func rate(forFrameDuration duration: CMTime) -> FrameRate? {
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0 else { return nil }
        return rate(forFps: Double(duration.timescale) / Double(duration.value))
    }
}
