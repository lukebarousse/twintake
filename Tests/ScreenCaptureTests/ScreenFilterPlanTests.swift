import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore
@testable import ScreenCapture

/// The screen stream's filter: TwinTake's keystroke pill is in screen.mov, every other TwinTake
/// window (camera window, control bar, menu, overlay) stays out.
@Suite struct ScreenFilterPlanTests {
    static let own: pid_t = 100
    static let safari: pid_t = 200
    static let apps = [ScreenFilterPlan.App(processID: own, bundleID: "com.lukebarousse.twintake"),
                       ScreenFilterPlan.App(processID: safari, bundleID: "com.apple.Safari")]
    // TwinTake's windows: 11 camera window, 12 control bar, 13 overlay, 14 keystroke pill. Safari: 21.
    static let windows = [ScreenFilterPlan.Window(id: 11, processID: own), .init(id: 12, processID: own),
                          .init(id: 13, processID: own), .init(id: 14, processID: own), .init(id: 21, processID: safari)]

    func plan(_ config: ScreenRecorderConfig, windows: [ScreenFilterPlan.Window] = windows) throws -> ScreenFilterPlan {
        try ScreenFilterPlan.make(config: config, apps: Self.apps, windows: windows, ownProcessID: Self.own)
    }

    @Test func regionShowsThePillAndLeavesTwinTakeOut() throws {
        var config = laptopConfig()
        config.shownOwnWindowIDs = [14]
        let p = try plan(config)
        #expect(p.kind == .display && p.usesSourceRect)
        #expect(p.excludedProcessIDs == [Self.own])
        // Only the pill is an exception: the camera window, the bar and the overlay stay excluded.
        #expect(p.windowIDs == [14])
        #expect(p.shownOwnWindowIDs == [14])
    }

    /// Without the pill the filter is the one from before: TwinTake out, no exception.
    @Test func regionWithoutThePillIsUnchanged() throws {
        let p = try plan(laptopConfig())
        #expect(p == ScreenFilterPlan(kind: .display, excludedProcessIDs: [Self.own], windowIDs: [], shownOwnWindowIDs: []))
    }

    /// A pill window ScreenCaptureKit does not list is left out; the take records without it.
    @Test func aMissingPillIsLeftOut() throws {
        var config = laptopConfig()
        config.shownOwnWindowIDs = [99, 14, 14]
        #expect(try plan(config).windowIDs == [14])
        #expect(try plan(config, windows: Array(Self.windows.prefix(3))).shownOwnWindowIDs == [])
    }

    /// An exception hides a window of an app that is not excluded, so only excluded apps' windows
    /// are named; the others show anyway.
    @Test func onlyExcludedAppsWindowsAreExceptions() throws {
        var config = laptopConfig()
        config.shownOwnWindowIDs = [14, 21]
        let p = try plan(config)
        #expect(p.windowIDs == [14])
        #expect(p.shownOwnWindowIDs == [14, 21])
        // Unbundled (swift run): the own process is excluded by its pid, whatever its bundle id.
        let unbundled = try ScreenFilterPlan.make(
            config: config, apps: [.init(processID: Self.own, bundleID: ""), .init(processID: Self.safari, bundleID: "com.apple.Safari")],
            windows: Self.windows, ownProcessID: Self.own)
        #expect(unbundled.excludedProcessIDs == [Self.own] && unbundled.windowIDs == [14])
    }

    /// Hide other windows: the window alone as before, or the frame region with only the window
    /// and the pill when the pill is in screen.mov.
    @Test func windowCapture() throws {
        let single = try plan(laptopConfig(windowID: 21))
        #expect(single.kind == .singleWindow && !single.usesSourceRect)
        #expect(single.windowIDs == [21] && single.shownOwnWindowIDs == [])

        var config = laptopConfig(windowID: 21)
        config.shownOwnWindowIDs = [14]
        let withPill = try plan(config)
        #expect(withPill.kind == .windows && withPill.usesSourceRect)
        #expect(withPill.windowIDs == [21, 14])
        #expect(!withPill.windowIDs.contains(11) && !withPill.windowIDs.contains(12) && !withPill.windowIDs.contains(13))

        // The pill is not listed: the window alone, as before.
        #expect(try plan(config, windows: Array(Self.windows.prefix(3)) + [.init(id: 21, processID: Self.safari)]).kind == .singleWindow)
        // The window to record is gone.
        #expect(throws: ScreenRecorderError.windowNotFound(42)) { try plan(laptopConfig(windowID: 42)) }
    }

    /// A window capture that shows the pill crops the display to the frame like a region capture.
    @Test func windowsKindUsesTheFrameRegion() {
        let config = laptopConfig(windowID: 21)
        let region = ScreenStreamSettings.streamConfiguration(for: config, singleWindow: false)
        #expect(region.sourceRect == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(!region.scalesToFit)
        #expect(region.width == 3008 && region.height == 1692)
        let single = ScreenStreamSettings.streamConfiguration(for: config)
        #expect(single.scalesToFit)
        // System audio still comes from its own display-wide stream in both window kinds.
        #expect(ScreenStreamSettings.usesDedicatedSystemAudioStream(config))
        #expect(!region.capturesAudio)
    }
}

/// A window capture with the keystroke pill: the pill keeps the stream active, so the recorded
/// window is watched in the window list, and its warning says what screen.mov shows.
@Suite struct WindowPresenceTests {
    /// Two reads in a row decide; one odd read changes nothing.
    @Test func twoReadsInARowDecide() {
        var p = WindowPresence()
        #expect(p.onScreen)
        #expect(p.update(onScreen: true) == nil)
        #expect(p.update(onScreen: false) == nil)
        #expect(p.update(onScreen: true) == nil)  // One odd read: forgotten.
        #expect(p.update(onScreen: false) == nil)
        #expect(p.update(onScreen: false) == false)
        #expect(!p.onScreen)
        #expect(p.update(onScreen: false) == nil)
        #expect(p.update(onScreen: true) == nil)
        #expect(p.update(onScreen: true) == true)
        #expect(p.onScreen)
    }

    @Test func theWarningSaysWhatScreenMovShows() {
        #expect(ScreenRecorder.windowActivityMessage(active: false, lastFrameRepeats: true)
                == "The recorded window closed; the last frame repeats until it returns.")
        #expect(ScreenRecorder.windowActivityMessage(active: false, lastFrameRepeats: false).contains("screen.mov is black"))
        #expect(ScreenRecorder.windowActivityMessage(active: true, lastFrameRepeats: false) == "The recorded window is back.")
        #expect(ScreenRecorder.windowActivityMessage(active: true, lastFrameRepeats: true) == "The recorded window is back.")
    }

    /// Source check: ScreenCaptureKit's activity callbacks are used for the window alone, the
    /// window-list watch for the window with the pill, and the watch stops with the capture.
    @Test func eachWindowKindHasOneWatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/ScreenCapture/ScreenRecorder.swift"), encoding: .utf8)
        #expect(code.contains("if plan.kind == .singleWindow {\n            router.onActivity ="))
        #expect(code.contains("} else if plan.kind == .windows, let windowID = config.windowID {\n            windowWatch = WindowPresenceWatch("))
        #expect(code.contains("func stopCapture() async {\n        windowWatch?.stop()"))
        #expect(code.components(separatedBy: "router.onActivity =").count == 2)
    }
}
