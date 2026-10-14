import CoreMedia
import Testing
@testable import CameraCapture
import RecorderCore

/// 23.976 the way AVFoundation reports it for the Cam Link 4K.
private let ntsc24 = 24000.0 / 1001.0

private func format(_ w: Int, _ h: Int, _ pixel: String, _ spans: [FrameRateSpan]) -> VideoFormatCandidate {
    VideoFormatCandidate(width: w, height: h, pixelFormat: pixel, frameRates: spans)
}

@Suite struct FormatMatcherTests {
    /// What the Cam Link 4K offers today: the a6600 sends 1080p 23.976.
    let camLinkToday = [
        format(1920, 1080, "420v", [FrameRateSpan(fps: ntsc24)]),
        format(1920, 1080, "yuvs", [FrameRateSpan(fps: ntsc24)]),
    ]

    @Test func camLinkTodayHasNo4K() {
        #expect(FormatMatcher.bestMatch(in: camLinkToday, width: 3840, height: 2160, frameRate: .fps23_976) == nil)
        #expect(FormatMatcher.bestMatch(in: camLinkToday, width: 1920, height: 1080, frameRate: .fps23_976) == 0)
    }

    @Test func camLinkAfterA6600SwitchPicks4K() {
        let formats = [format(3840, 2160, "420v", [FrameRateSpan(fps: ntsc24)])] + camLinkToday
        #expect(FormatMatcher.bestMatch(in: formats, width: 3840, height: 2160, frameRate: .fps23_976) == 0)
    }

    @Test func prefers420vOverYuvsWhateverTheOrder() {
        let formats = Array(camLinkToday.reversed())
        #expect(formats[FormatMatcher.bestMatch(in: formats, width: 1920, height: 1080, frameRate: .fps23_976)!].pixelFormat == "420v")
        #expect(FormatMatcher.pixelFormatRank("420v") < FormatMatcher.pixelFormatRank("420f"))
        #expect(FormatMatcher.pixelFormatRank("x420") < FormatMatcher.pixelFormatRank("yuvs"))
    }

    @Test func twentyFourIsNotTwentyThreeNineSevenSix() {
        let formats = [format(3840, 2160, "420v", [FrameRateSpan(fps: 24)])]
        #expect(FormatMatcher.bestMatch(in: formats, width: 3840, height: 2160, frameRate: .fps23_976) == nil)
        #expect(FormatMatcher.bestMatch(in: formats, width: 3840, height: 2160, frameRate: .fps24) == 0)
    }

    @Test func rangeContainsRateAndSingleRateWins() {
        let webcam = [
            format(1920, 1080, "420v", [FrameRateSpan(minFps: 1, maxFps: 30)]),
            format(1920, 1080, "420v", [FrameRateSpan(fps: ntsc24)]),
        ]
        #expect(FormatMatcher.bestMatch(in: webcam, width: 1920, height: 1080, frameRate: .fps23_976) == 1)
        #expect(FormatMatcher.bestMatch(in: [webcam[0]], width: 1920, height: 1080, frameRate: .fps23_976) == 0)
        #expect(FormatMatcher.matchingSpan(in: webcam[0], frameRate: .fps23_976) == FrameRateSpan(minFps: 1, maxFps: 30))
        #expect(FormatMatcher.matchingSpan(in: webcam[0], frameRate: .fps60) == nil)
    }

    @Test func bestAvailableIsLargestThenFastest() {
        let formats = [
            format(1280, 720, "420v", [FrameRateSpan(fps: 60)]),
            format(1920, 1080, "yuvs", [FrameRateSpan(fps: 30)]),
            format(1920, 1080, "420v", [FrameRateSpan(fps: 30)]),
            format(1920, 1080, "420v", [FrameRateSpan(fps: 15)]),
        ]
        #expect(FormatMatcher.bestAvailable(in: formats) == 2)
        #expect(FormatMatcher.bestAvailable(in: []) == nil)
    }

    @Test func frameDurationIsExactInsideTheSpan() {
        let span = FrameRateSpan(minFps: 1, maxFps: 30,
                                 minFrameDuration: CMTime(value: 1, timescale: 30), maxFrameDuration: CMTime(value: 1, timescale: 1))
        #expect(FormatMatcher.frameDuration(for: .fps23_976, in: span) == CMTime(value: 1001, timescale: 24000))
    }

    @Test func frameDurationUsesTheDeviceValueWhenItRoundsDifferently() {
        // A device that stores 23.976 as 417083/10000000 s: the exact 1001/24000 is a hair longer,
        // and setting it would throw. Use the device's own value.
        let device = CMTime(value: 417_083, timescale: 10_000_000)
        let span = FrameRateSpan(minFps: ntsc24, maxFps: ntsc24, minFrameDuration: device, maxFrameDuration: device)
        #expect(FormatMatcher.frameDuration(for: .fps23_976, in: span) == device)
    }

    @Test func frameDurationWithoutDeviceDurationsIsExact() {
        #expect(FormatMatcher.frameDuration(for: .fps23_976, in: FrameRateSpan(fps: ntsc24)) == FrameRate.fps23_976.frameDuration)
    }

    /// A format whose only rate is 29.95 fps: its signal snaps to 30000/1001 (0.067% off), but the
    /// exact 1001/30000 s is shorter than the format allows, and setting it would raise an
    /// Objective-C exception. The duration stays inside the format's range.
    @Test func frameDurationStaysInsideAnOffNominalFormat() {
        let d = CMTime(value: 100, timescale: 2995)  // 1 / 29.95 s
        let offNominal = format(1920, 1080, "420v", [FrameRateSpan(minFps: 29.95, maxFps: 29.95, minFrameDuration: d,
                                                                   maxFrameDuration: d)])
        #expect(CameraSignal.resolve([offNominal])?.signal.frameRate == .fps29_97)
        #expect(FormatMatcher.matchingSpan(in: offNominal, frameRate: .fps29_97) == nil)  // 0.02 fps off: the old path.
        let duration = FormatMatcher.frameDuration(for: .fps29_97, in: offNominal)
        #expect(duration == d)
        #expect(FormatMatcher.durationFits(duration, ranges: [(d, d)]))
        #expect(!FormatMatcher.durationFits(FrameRate.fps29_97.frameDuration, ranges: [(d, d)]))
        // No span near the rate at all: the nearest span's bound, never a duration outside it.
        let slow = CMTime(value: 1, timescale: 15)
        let fifteen = format(1280, 720, "420v", [FrameRateSpan(minFps: 15, maxFps: 15, minFrameDuration: slow,
                                                               maxFrameDuration: slow)])
        #expect(FormatMatcher.frameDuration(for: .fps23_976, in: fifteen) == slow)
        // The Cam Link's own 1251/30000 s for 23.976 stays as it is.
        let camLink = CMTime(value: 1251, timescale: 30000)
        let cam = format(3840, 2160, "420v", [FrameRateSpan(minFps: 30000.0 / 1251, maxFps: 30000.0 / 1251,
                                                            minFrameDuration: camLink, maxFrameDuration: camLink)])
        #expect(FormatMatcher.frameDuration(for: .fps23_976, in: cam) == camLink)
    }

    /// A rate-only HDMI change (the a6600 switched 24p to 30p at 4K) is a new signal; the Cam
    /// Link's 23.98 for 23.976 and a webcam's 1-30 range are not.
    @Test func rateChangeAtTheSameSize() {
        let at2997 = format(3840, 2160, "420v", [FrameRateSpan(fps: 30000.0 / 1001)])
        #expect(FormatMatcher.rateChanged(at2997, from: .fps23_976))
        let camLink = format(3840, 2160, "420v", [FrameRateSpan(fps: 30000.0 / 1251)])
        #expect(!FormatMatcher.rateChanged(camLink, from: .fps23_976))
        let webcam = format(1920, 1080, "420v", [FrameRateSpan(minFps: 1, maxFps: 30)])
        #expect(!FormatMatcher.rateChanged(webcam, from: .fps24))
        #expect(!FormatMatcher.rateChanged(webcam, from: .fps30))
        let offNominal = format(1920, 1080, "420v", [FrameRateSpan(fps: 29.95)])
        #expect(!FormatMatcher.rateChanged(offNominal, from: .fps29_97))
    }
}

@Suite struct FormatLabelTests {
    @Test func fourCC() {
        #expect(FormatLabel.fourCC(0x3432_3076) == "420v")
        #expect(FormatLabel.fourCC(0x7975_7673) == "yuvs")
        #expect(FormatLabel.fourCC(0x0000_0001) == "0x00000001")
    }

    @Test func fpsLabels() {
        #expect(FormatLabel.fps(ntsc24) == "23.976")
        #expect(FormatLabel.fps(23.976_023_976) == "23.976")
        #expect(FormatLabel.fps(29.97) == "29.97")
        #expect(FormatLabel.fps(30) == "30")
        #expect(FormatLabel.fps(59.94) == "59.94")
    }

    @Test func formatLines() {
        let camLink = format(1920, 1080, "420v", [FrameRateSpan(fps: ntsc24)])
        #expect(FormatLabel.signal(camLink) == "1920x1080 23.976")
        #expect(FormatLabel.listing(camLink) == "1920x1080 420v 23.976")
        let webcam = format(1280, 720, "420v", [FrameRateSpan(minFps: 1, maxFps: 30), FrameRateSpan(fps: 60)])
        #expect(FormatLabel.listing(webcam) == "1280x720 420v 1-30,60")
        #expect(FormatLabel.negotiated(width: 3840, height: 2160, pixelFormat: "420v", frameRate: .fps23_976) == "3840x2160 420v 23.976")
    }

    @Test func audioLabels() {
        #expect(FormatLabel.audio(sampleRate: 48_000, channels: 2) == "2 ch, 48 kHz")
        #expect(FormatLabel.audio(sampleRate: 44_100, channels: 1) == "1 ch, 44.1 kHz")
    }
}

@Suite struct FrameRateSnapTests {
    @Test func ntscRatesBecomeExactRationals() {
        #expect(FrameRateSnap.rate(forFps: ntsc24) == .fps23_976)
        #expect(FrameRateSnap.rate(forFps: 23.98) == .fps23_976)
        #expect(FrameRateSnap.rate(forFps: 7.5) == FrameRate(num: 7500, den: 1000))
        #expect(FrameRateSnap.rate(forFps: 29.97) == .fps29_97)
        #expect(FrameRateSnap.rate(forFps: 47.952) == .fps47_952)
        #expect(FrameRateSnap.rate(forFps: 59.940_06) == .fps59_94)
    }

    @Test func wholeRatesStayWhole() {
        #expect(FrameRateSnap.rate(forFps: 24) == .fps24)
        #expect(FrameRateSnap.rate(forFps: 30.000_3) == .fps30)
        #expect(FrameRateSnap.rate(forFps: 0) == nil)
        #expect(FrameRateSnap.rate(forFps: .nan) == nil)
    }

    @Test func frameDurations() {
        #expect(FrameRateSnap.rate(forFrameDuration: CMTime(value: 1001, timescale: 24000)) == .fps23_976)
        #expect(FrameRateSnap.rate(forFrameDuration: CMTime(value: 41_708, timescale: 1_000_000)) == .fps23_976)
        #expect(FrameRateSnap.rate(forFrameDuration: CMTime(value: 1, timescale: 30)) == .fps30)
        #expect(FrameRateSnap.rate(forFrameDuration: .invalid) == nil)
    }
}

/// The camera follows its signal: the rate it reports (or a measured one) snaps to a standard
/// exact rational.
@Suite struct StandardFrameRateTests {
    @Test(arguments: [
        (23.976, FrameRate.fps23_976), (ntsc24, .fps23_976), (23.98, .fps23_976), (23.9761, .fps23_976),
        (24.0, .fps24), (23.999, .fps24), (25.0, .fps25), (24.99, .fps25),
        (29.97, .fps29_97), (29.970_03, .fps29_97), (30.0, .fps30), (30.01, .fps30),
        (47.952, .fps47_952), (48.0, FrameRate(num: 48, den: 1)), (50.0, FrameRate(num: 50, den: 1)),
        (59.94, .fps59_94), (59.940_06, .fps59_94), (60.0, .fps60),
    ])
    func snapsToTheStandardRate(fps: Double, expected: FrameRate) {
        #expect(StandardFrameRate.snap(fps) == expected)
    }

    @Test func farFromEveryStandardRateIsNotSnapped() {
        #expect(StandardFrameRate.snap(27) == nil)
        #expect(StandardFrameRate.snap(15) == nil)
        #expect(StandardFrameRate.snap(0) == nil)
        #expect(StandardFrameRate.snap(.nan) == nil)
        // Not standard, but still an exact rational for the grid.
        #expect(StandardFrameRate.rate(forFps: 15) == FrameRate(num: 15, den: 1))
    }

    /// The Cam Link 4K reports a 1251/30000 s frame duration (23.98 fps) for the a6600's 23.976.
    @Test func camLinkFrameDurationIsNTSC() {
        #expect(StandardFrameRate.rate(forFrameDuration: CMTime(value: 1251, timescale: 30000)) == .fps23_976)
        #expect(StandardFrameRate.rate(forFrameDuration: CMTime(value: 1001, timescale: 24000)) == .fps23_976)
        #expect(StandardFrameRate.rate(forFrameDuration: CMTime(value: 1, timescale: 24)) == .fps24)
        #expect(StandardFrameRate.rate(forFrameDuration: .invalid) == nil)
    }
}

@Suite struct CameraSignalTests {
    /// The Cam Link with the a6600 at 4K 24p, as AVFoundation lists it.
    let camLink4K = [
        format(3840, 2160, "yuvs", [FrameRateSpan(fps: 23.98)]),
        format(3840, 2160, "420v", [FrameRateSpan(fps: 23.98)]),
    ]

    @Test func camLinkResolvesToUHD23976In420v() throws {
        let resolved = try #require(CameraSignal.resolve(camLink4K))
        #expect(resolved.index == 1)
        #expect(resolved.signal == CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v"))
        #expect(resolved.signal.label == "3840x2160 · 23.976 fps")
        #expect(resolved.signal.shortLabel == "3840x2160 23.976")
        #expect(resolved.signal.is4K)
        #expect(resolved.signal.screenFrameRate == .fps47_952)
    }

    @Test func theLargestSizeWins() throws {
        let webcam = [
            format(1280, 720, "420v", [FrameRateSpan(fps: 60)]),
            format(1920, 1080, "420v", [FrameRateSpan(minFps: 1, maxFps: 30)]),
        ]
        let signal = try #require(CameraSignal.resolve(webcam)).signal
        #expect(signal.width == 1920 && signal.height == 1080 && signal.frameRate == .fps30)
        #expect(!signal.is4K)
        #expect(signal.screenFrameRate == FrameRate(num: 60, den: 1))
    }

    @Test func noFormatIsNoSignal() {
        #expect(CameraSignal.resolve([]) == nil)
    }

    /// A config with no size and rate follows the signal; one with all three requires them.
    @Test func theConfigPicksTheFormat() throws {
        let follow = CameraRecorderConfig(videoDeviceUID: "camlink", audioDeviceUID: "camlink-audio")
        #expect(follow.followsSignal)
        #expect(follow.expectedWidth == 3840 && follow.expectedHeight == 2160 && follow.expectedFrameRate == .fps23_976)
        let picked = try CaptureGraph.pickFormat(config: follow, candidates: camLink4K, cameraName: "Cam Link 4K")
        #expect(picked.index == 1 && picked.frameRate == .fps23_976)

        let fixed = CameraRecorderConfig(videoDeviceUID: "camlink", audioDeviceUID: nil, width: 1920, height: 1080,
                                         frameRate: .fps23_976)
        #expect(!fixed.followsSignal)
        #expect(throws: CameraRecorderError.self) {
            try CaptureGraph.pickFormat(config: fixed, candidates: camLink4K, cameraName: "Cam Link 4K")
        }
        #expect(throws: CameraRecorderError.self) {
            try CaptureGraph.pickFormat(config: follow, candidates: [], cameraName: "Cam Link 4K")
        }
    }

    /// The screen runs at twice the camera rate up to 30 fps, and at the camera rate above that.
    @Test func screenRateFollowsTheCamera() {
        #expect(ScreenRecorderConfig.frameRate(forCameraRate: .fps23_976) == .fps47_952)
        #expect(ScreenRecorderConfig.frameRate(forCameraRate: .fps24) == FrameRate(num: 48, den: 1))
        #expect(ScreenRecorderConfig.frameRate(forCameraRate: .fps29_97) == .fps59_94)
        #expect(ScreenRecorderConfig.frameRate(forCameraRate: .fps59_94) == .fps59_94)
    }

    @Test func inventoryCarriesTheSignal() {
        let signal = CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v")
        let inventory = DeviceInventory(signals: ["camlink": signal])
        #expect(inventory.signal(forVideoUID: "camlink") == signal)
        #expect(inventory.signal(forVideoUID: "other") == nil)
    }
}
