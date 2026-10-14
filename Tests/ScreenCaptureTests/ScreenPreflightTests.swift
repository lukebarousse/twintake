import CoreGraphics
import Testing
@testable import RecorderCore
@testable import MediaWriter
@testable import ScreenCapture

/// The 14" laptop display at its default 1512x982 pt, 2x, set to 47.95 Hz; everything allowed.
private func healthy() -> ScreenPreflightSnapshot {
    ScreenPreflightSnapshot(screenCaptureAllowed: true, displayOnline: true, displayIsBuiltIn: true,
                            displaySizePt: CGSize(width: 1512, height: 982), displayScale: 2,
                            refreshRateHz: 47.952, availableRefreshRatesHz: [47.952, 48, 50, 59.94, 60, 120],
                            windowExists: nil, micFound: true, micAccess: .authorized)
}

private func ids(_ issues: [PreflightIssue]) -> [String] { issues.map(\.id) }

@Suite struct ScreenPreflightTests {
    @Test func healthySetupHasNoIssues() {
        #expect(ScreenPreflight.issues(config: laptopConfig(), snapshot: healthy()).isEmpty)
    }

    @Test func missingScreenPermissionBlocks() {
        var s = healthy()
        s.screenCaptureAllowed = false
        let issues = ScreenPreflight.issues(config: laptopConfig(), snapshot: s)
        #expect(ids(issues) == ["screen.permission"])
        #expect(issues[0].severity == .blocker)
        #expect(issues[0].message.contains("Screen Recording"))
    }

    @Test func offlineDisplayBlocks() {
        var s = healthy()
        s.displayOnline = false
        s.displaySizePt = nil
        #expect(ids(ScreenPreflight.issues(config: laptopConfig(), snapshot: s)) == ["screen.display-offline"])
    }

    @Test func frameOutsideDisplayBlocks() {
        var config = laptopConfig()
        config.frameRectPt = CGRect(x: 100, y: 37, width: 1504, height: 846)
        let issues = ScreenPreflight.issues(config: config, snapshot: healthy())
        #expect(ids(issues) == ["screen.frame-outside-display"])
        #expect(issues[0].severity == .blocker)
    }

    @Test func oddOrEmptyOutputSizeBlocks() {
        var config = laptopConfig()
        config.outputPx = PixelSize(width: 3007, height: 1692)
        #expect(ids(ScreenPreflight.issues(config: config, snapshot: healthy())).contains("screen.output-size-odd"))
        config.outputPx = PixelSize(width: 0, height: 0)
        #expect(ids(ScreenPreflight.issues(config: config, snapshot: healthy())).contains("screen.output-size"))
    }

    @Test func aspectMismatchAndUpscaleWarn() {
        var config = laptopConfig()
        config.outputPx = PixelSize(width: 3840, height: 1692)
        let issues = ScreenPreflight.issues(config: config, snapshot: healthy())
        #expect(Set(ids(issues)) == ["screen.aspect-mismatch", "screen.upscaled"])
        #expect(issues.allSatisfy { $0.severity == .warning })
    }

    @Test func micProblems() {
        var s = healthy()
        s.micFound = false
        #expect(ids(ScreenPreflight.issues(config: laptopConfig(), snapshot: s)) == ["screen.mic-missing"])
        s = healthy()
        s.micAccess = .denied
        #expect(ids(ScreenPreflight.issues(config: laptopConfig(), snapshot: s)) == ["screen.mic-permission"])
        s.micAccess = .notDetermined
        let ask = ScreenPreflight.issues(config: laptopConfig(), snapshot: s)
        #expect(ids(ask) == ["screen.mic-permission-ask"] && ask[0].severity == .warning)
    }

    @Test func closedWindowBlocksInWindowMode() {
        var s = healthy()
        s.windowExists = false
        #expect(ids(ScreenPreflight.issues(config: laptopConfig(windowID: 77), snapshot: s)) == ["screen.window-missing"])
        // The frame rect is not checked in window mode.
        var config = laptopConfig(windowID: 77)
        config.frameRectPt = .zero
        s.windowExists = true
        #expect(ScreenPreflight.issues(config: config, snapshot: s).isEmpty)
    }

    @Test func untestedFrameRateWarns() {
        #expect(ids(ScreenPreflight.issues(config: laptopConfig(rate: .fps30), snapshot: healthy()))
            .contains("screen.frame-rate-untested"))
    }

    /// The rule: `refreshHz * 2 / fps` within 0.5% of a whole number.
    @Test func twoFramesMustSpanAWholeNumberOfRefreshes() {
        // 47.952 fps (Luke's screen rate): 47.95 and 95.9 give 2 and 4; 120 Hz gives 5.005.
        #expect(ScreenPreflight.refreshFits(47.952, frameRate: .fps47_952))
        #expect(ScreenPreflight.refreshFits(47.95, frameRate: .fps47_952))
        #expect(ScreenPreflight.refreshFits(95.9, frameRate: .fps47_952))
        #expect(ScreenPreflight.refreshFits(120, frameRate: .fps47_952))
        #expect(ScreenPreflight.refreshFits(119.88, frameRate: .fps47_952))
        #expect(ScreenPreflight.refreshFits(48, frameRate: .fps47_952))  // 2.002: 0.1% off
        #expect(ScreenPreflight.refreshFits(96, frameRate: .fps47_952))
        #expect(ScreenPreflight.refreshFits(144, frameRate: .fps47_952))  // 6.006
        #expect(!ScreenPreflight.refreshFits(60, frameRate: .fps47_952))  // 2.5025
        #expect(!ScreenPreflight.refreshFits(59.94, frameRate: .fps47_952))  // 2.5
        #expect(!ScreenPreflight.refreshFits(50, frameRate: .fps47_952))  // 2.085: 4.3% off
        #expect(!ScreenPreflight.refreshFits(90, frameRate: .fps47_952))
        #expect(!ScreenPreflight.refreshFits(100, frameRate: .fps47_952))
        // 23.976 fps.
        #expect(ScreenPreflight.refreshFits(47.952, frameRate: .fps23_976))
        #expect(ScreenPreflight.refreshFits(59.94, frameRate: .fps23_976))  // 5
        #expect(ScreenPreflight.refreshFits(60, frameRate: .fps23_976))  // 5.005
        #expect(ScreenPreflight.refreshFits(119.88, frameRate: .fps23_976))
        #expect(!ScreenPreflight.refreshFits(30, frameRate: .fps23_976))  // 2.5025
        #expect(ScreenPreflight.refreshFits(119.88, frameRate: .fps59_94))
        // No rate, or a rate far below the frame rate.
        #expect(!ScreenPreflight.refreshFits(0, frameRate: .fps59_94))
        #expect(!ScreenPreflight.refreshFits(10, frameRate: .fps47_952))
        // The tolerance edge: 0.4% fits, 0.6% does not.
        #expect(ScreenPreflight.refreshFits(120 * 1.004 / 1.001, frameRate: .fps47_952))
        #expect(!ScreenPreflight.refreshFits(120 * 1.006 / 1.001, frameRate: .fps47_952))
    }

    /// Luke keeps the laptop display at 120 Hz: no advice to set it to 47.95 Hz.
    @Test func laptopAt120HzHasNoRefreshAdvice() {
        var s = healthy()
        s.refreshRateHz = 120
        #expect(ScreenPreflight.issues(config: laptopConfig(), snapshot: s).isEmpty)
        // ProMotion reports no fixed rate; it goes up to 120 Hz.
        s.refreshRateHz = 0
        #expect(ScreenPreflight.issues(config: laptopConfig(), snapshot: s).isEmpty)
        // A display that lists no rates says nothing either.
        s.availableRefreshRatesHz = []
        #expect(ScreenPreflight.issues(config: laptopConfig(), snapshot: s).isEmpty)
    }

    /// Luke's first take: preflight told him to set the display to 47.95 Hz while it ran at 120 Hz.
    @Test func noRefreshAdviceAt120HzOr47_95Hz() {
        for hz in [120.0, 47.952, 95.904] {
            #expect(ScreenPreflight.refreshAdvice(display: "the built-in display", isBuiltIn: true, currentHz: hz,
                                                  availableHz: [47.952, 60, 120], frameRate: .fps47_952) == nil, "\(hz)")
        }
    }

    @Test func laptopAt60HzIsToldToSwitchTo120() {
        var s = healthy()
        s.refreshRateHz = 60
        let issues = ScreenPreflight.issues(config: laptopConfig(), snapshot: s)
        #expect(ids(issues) == ["screen.refresh-rate"])
        #expect(issues[0].severity == .warning)
        #expect(issues[0].message.hasPrefix("Set the laptop display to 120 Hz"))
        // A variable refresh rate that does not reach twice the frame rate still gets the advice.
        s.refreshRateHz = 0
        s.availableRefreshRatesHz = [47.952, 60]
        #expect(ScreenPreflight.issues(config: laptopConfig(), snapshot: s).first?.message
            .contains("variable refresh rate") == true)
    }

    @Test func externalDisplayWithoutAFittingRateGetsAPlainWarning() {
        var s = healthy()
        s.displayIsBuiltIn = false
        s.displaySizePt = CGSize(width: 1920, height: 1080)
        s.refreshRateHz = 60
        s.availableRefreshRatesHz = [50, 59.94, 60]
        var config = laptopConfig()
        config.displayID = 3
        config.frameRectPt = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        config.outputPx = PixelSize(width: 3840, height: 2160)
        let issues = ScreenPreflight.issues(config: config, snapshot: s)
        #expect(ids(issues) == ["screen.refresh-rate"])
        #expect(issues[0].message.contains("offers no rate that does"))
        // 47.952 needs 47.95 or at least 95.9; at 60 Hz the external offers 119.88.
        #expect(ScreenPreflight.refreshAdvice(display: "display 3", isBuiltIn: false, currentHz: 60,
                                              availableHz: [60, 119.88], frameRate: .fps47_952)?
            .hasPrefix("Set display 3 to 119.88 Hz") == true)
        // 60 Hz is 2.5 refreshes per 23.976 frame: it fits.
        #expect(ScreenPreflight.refreshAdvice(display: "display 3", isBuiltIn: false, currentHz: 60,
                                              availableHz: [60], frameRate: .fps23_976) == nil)
        #expect(ScreenPreflight.hzLabel(47.952) == "47.95 Hz" && ScreenPreflight.hzLabel(60) == "60 Hz")
    }
}
