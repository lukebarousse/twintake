import CameraCapture
import CoreGraphics
import Foundation
import Testing
@testable import RecorderApp
@testable import RecorderCore
import ScreenCapture
import WindowTools

/// The 14" laptop: 1512x982 pt, 2x, menu bar 37 pt.
private let laptop = DisplayInfo(id: 1, uuid: "LAPTOP", name: "Built-in Retina Display", isBuiltin: true, isMain: true,
                                 boundsGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2,
                                 menuBarHeightPt: 37, refreshRate: 120)

@Suite struct ScreenRateTests {
    /// The screen rate is 2x the camera rate, not a user choice.
    @Test func screenRateFollowsTheCamera() {
        #expect(SessionRules.screenFrameRate(cameraSignalRate: .fps23_976, lastCameraRate: .fps29_97) == .fps47_952)
        #expect(SessionRules.screenFrameRate(cameraSignalRate: .fps24, lastCameraRate: .fps23_976) == FrameRate(num: 48, den: 1))
        #expect(SessionRules.screenFrameRate(cameraSignalRate: .fps29_97, lastCameraRate: .fps23_976) == .fps59_94)
        // Above 30 fps the screen records at the camera rate.
        #expect(SessionRules.screenFrameRate(cameraSignalRate: .fps59_94, lastCameraRate: .fps23_976) == .fps59_94)
        // No signal (Screen mode, or the camera is unplugged): the last camera rate.
        #expect(SessionRules.screenFrameRate(cameraSignalRate: nil, lastCameraRate: .fps23_976) == .fps47_952)
        #expect(SessionRules.screenFrameRate(cameraSignalRate: nil, lastCameraRate: .fps25) == FrameRate(num: 50, den: 1))
    }

    @Test func rateLine() {
        #expect(SessionRules.screenRateText(screen: .fps47_952, cameraRate: .fps23_976, cameraLive: true)
            == "47.952 fps · 2× the camera's 23.976")
        #expect(SessionRules.screenRateText(screen: .fps47_952, cameraRate: .fps23_976, cameraLive: false)
            == "47.952 fps · 2× 23.976, the last camera rate")
        #expect(SessionRules.screenRateText(screen: .fps59_94, cameraRate: .fps59_94, cameraLive: true)
            == "59.94 fps · same as the camera")
    }

    /// The disk estimate uses what the camera sends when it is known.
    @Test func diskEstimateUsesTheSignal() {
        let camera = CameraRecorderConfig(videoDeviceUID: "cam", audioDeviceUID: nil, codec: .proRes422LT)
        let uhd = SessionRules.bytesPerSecond(camera: camera, screen: nil)
        let hd = SessionRules.bytesPerSecond(camera: camera, cameraSignal: CameraSignal(
            width: 1920, height: 1080, frameRate: .fps23_976, pixelFormat: "420v"), screen: nil)
        #expect(abs(uhd / hd - 4) < 0.01)
    }
}

@Suite struct FramePositionTests {
    func plan(_ anchor: FrameAnchor, _ preset: ScreenFramePreset = .laptop16x9) -> ScreenPlan {
        ScreenPlan(display: laptop, preset: preset,
                   config: ScreenRecorderConfig(displayID: 1, frameRectPt: laptop.frameRect(for: preset, anchor: anchor),
                                                outputPx: laptop.outputPixels(for: preset), micDeviceUID: nil),
                   frameGlobal: laptop.globalFrameRect(for: preset, anchor: anchor), anchor: anchor)
    }

    /// Luke's frame: the bottom of the laptop, with 99 pt free under the menu bar for the
    /// Parallels toolbar.
    @Test func bottomFrameOnTheLaptop() {
        let p = plan(.bottom)
        #expect(p.config.frameRectPt == CGRect(x: 4, y: 136, width: 1504, height: 846))
        #expect(p.snapTarget == p.frameGlobal)
        #expect(FrameGeometry.roomAbove(frame: p.config.frameRectPt, topInsetPt: 37) == 99)
        #expect(laptop.screenInfo(for: .laptop16x9, anchor: .bottom).frameAnchor == .bottom)
        #expect(laptop.screenInfo(for: .fullDisplay, anchor: .bottom).frameAnchor == nil)
    }

    /// The auto-hidden Dock gives no warning; a visible one over the bottom frame does.
    @Test func dockWarning() {
        let frame = laptop.frameRect(for: .laptop16x9, anchor: .bottom)
        let visible = DockOverlap.check(frameLocal: frame, displaySizePt: laptop.sizePt, dockThicknessPt: 70,
                                        prefs: DockPrefs(edge: .bottom, autohide: false))
        let issue = SessionRules.dockIssue(visible, frameAtBottom: true)
        #expect(issue?.id == "app.dock_covers_frame")
        #expect(issue?.severity == .warning)
        #expect(issue?.message.contains("70 pt") == true)
        #expect(issue?.message.hasSuffix("or put the frame at the top.") == true)
        // Also with "Hide other windows" on: no setting here, because a Parallels window with its
        // toolbar above the frame, or no window to snap, records the region under the Dock.
        let whole = DockOverlap.check(frameLocal: laptop.frameRect(for: .fullDisplay), displaySizePt: laptop.sizePt,
                                      dockThicknessPt: 70, prefs: DockPrefs(edge: .bottom, autohide: false))
        #expect(SessionRules.dockIssue(whole, frameAtBottom: false)?.message.hasSuffix("(⌥⌘D).") == true)

        let hidden = DockOverlap.check(frameLocal: frame, displaySizePt: laptop.sizePt, dockThicknessPt: 70,
                                       prefs: DockPrefs(edge: .bottom, autohide: true))
        #expect(SessionRules.dockIssue(hidden, frameAtBottom: true) == nil)
        // The top frame ends at y 883; a 70 pt Dock starts at 912.
        let top = DockOverlap.check(frameLocal: laptop.frameRect(for: .laptop16x9), displaySizePt: laptop.sizePt,
                                    dockThicknessPt: 70, prefs: DockPrefs(edge: .bottom, autohide: false))
        #expect(SessionRules.dockIssue(top, frameAtBottom: false) == nil)
    }

    /// A hot corner at the bottom edge warns for the bottom frame only (Luke's Quick Note).
    @Test func hotCornerWarning() {
        let corners = [HotCorner(position: .bottomRight, action: 14), HotCorner(position: .topLeft, action: 0)]
        let bottom = SessionRules.hotCornerIssue(corners, frameLocal: laptop.frameRect(for: .laptop16x9, anchor: .bottom),
                                                 displaySizePt: laptop.sizePt)
        #expect(bottom?.id == "app.hot_corner" && bottom?.severity == .warning)
        #expect(bottom?.message.contains("bottom right (Quick Note)") == true)
        #expect(SessionRules.hotCornerIssue(corners, frameLocal: laptop.frameRect(for: .laptop16x9, anchor: .top),
                                            displaySizePt: laptop.sizePt) == nil)
    }
}

@Suite struct ParallelsSnapRulesTests {
    let frame = CGRect(x: 4, y: 37, width: 1504, height: 846)

    func noRoom() -> SnapResult {
        SnapResult(success: false, failure: .toolbarNoRoom, appName: "Parallels Desktop",
                   bundleId: "com.parallels.desktop.console", pid: 13004, title: "Windows 11", windowID: nil,
                   requestedFrame: frame, previousFrame: nil, achievedFrame: nil, message: "snapper message",
                   placement: .toolbarAbove, profileID: "parallels",
                   toolbar: ToolbarMeasurement(detectedPt: 38, source: .fallback), frameMoveDownPt: 38)
    }

    @Test func noRoomOffersToMoveTheFrame() {
        #expect(SessionRules.snapFix(failure: .toolbarNoRoom, preset: .laptop16x9, anchor: .top) == .moveFrameToBottom)
        // At the bottom already: moving cannot help.
        #expect(SessionRules.snapFix(failure: .toolbarNoRoom, preset: .laptop16x9, anchor: .bottom) == nil)
        // The whole display has no strip above it: the 16:9 frame at the bottom has one.
        #expect(SessionRules.snapFix(failure: .toolbarNoRoom, preset: .fullDisplay, anchor: .bottom) == .useSixteenByNineAtBottom)
        #expect(SessionRules.snapFix(failure: .sizeMismatch, preset: .laptop16x9, anchor: .top) == nil)
        #expect(SessionRules.snapFix(failure: nil, preset: .laptop16x9, anchor: .top) == nil)
        #expect(SessionRules.SnapFix.moveFrameToBottom.buttonTitle == "Move Frame to Bottom")
    }

    @Test func noticeForTheWholeDisplay() {
        let snap = noRoom()
        #expect(SessionRules.snapNotice(snap, fix: .moveFrameToBottom) == "snapper message")
        let notice = SessionRules.snapNotice(snap, fix: .useSixteenByNineAtBottom)
        #expect(notice.hasPrefix("Parallels Desktop keeps its toolbar (38 pt) above the frame"))
        #expect(notice.contains("16:9 frame at the bottom"))
    }

    /// A window capture records the whole window: with the toolbar above the frame, the region is
    /// recorded instead.
    @Test func hideOtherWindowsSkipsAToolbarAboveWindow() {
        var snap = noRoom()
        snap.windowID = 88
        #expect(!SessionRules.windowOnlyApplies(to: snap))
        snap.placement = .fill
        #expect(SessionRules.windowOnlyApplies(to: snap))
        snap.windowID = nil
        #expect(!SessionRules.windowOnlyApplies(to: snap))
        #expect(!SessionRules.windowOnlyApplies(to: nil))
    }

    @Test func offsetLabel() {
        #expect(SessionRules.offsetLabel(0) == "0 pt")
        #expect(SessionRules.offsetLabel(2) == "+2 pt")
        #expect(SessionRules.offsetLabel(-3) == "−3 pt")
        #expect(SessionRules.offsetLabel(1.5) == "+1.5 pt")
    }
}

/// Both files begin at one scheduled time (StartSchedule): the app passes the same `startHostNs`
/// to both recorders, and session.json's start is that time.
@Suite struct ScheduledStartSourceTests {
    @Test func bothRecordersGetTheScheduledStart() throws {
        let url = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift")
        let code = try ThreadRuleTests.codeLines(url).map(\.1)
        #expect(code.contains { $0.contains("let startNs = StartSchedule.startHostNs()") })
        #expect(code.contains { $0.contains("session.manifest.startedAtHostNs = startNs") })
        #expect(code.contains { $0.contains("session.events.append(.sessionStart, startData, at: startNs)") })
        #expect(code.contains { $0.contains("folder: session.folder, events: session.events, at: startNs)") })
        #expect(code.contains { $0.contains("try await recorder.start(writingTo: url, events: events, at: startHostNs)") })
        // No recorder starts without the scheduled time.
        #expect(!code.contains { $0.contains("recorder.start(writingTo: url, events: events)") })
        #expect(StartSchedule.marginNs == 500_000_000)
    }

    /// The screen rate in Screen mode follows the camera of the last take, not whatever camera the
    /// device list picks automatically while the menu is open (an iPhone, a webcam, a short-lived
    /// HDMI rate).
    @Test func theCameraRateIsSavedOnlyFromATake() throws {
        let url = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift")
        let code = try ThreadRuleTests.codeLines(url).map(\.1)
        let calls = code.filter { $0.contains("rememberCameraRate(") && !$0.contains("func rememberCameraRate(") }
        #expect(calls.count == 1)
        #expect(calls.first?.contains("rememberCameraRate(signal)") == true)
        let refresh = try #require(code.firstIndex { $0.contains("func refreshDevices() async {") })
        let end = try #require(code[refresh...].firstIndex { $0.contains("func rememberCameraRate(") })
        #expect(!code[refresh..<end].contains { $0.contains("rememberCameraRate(") })
    }

    /// The camera config follows the signal: the app never sets a camera size or rate.
    @Test func theCameraConfigHasNoSizeOrRate() throws {
        let url = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift")
        let code = try ThreadRuleTests.codeLines(url).map(\.1).joined(separator: "\n")
        let start = try #require(code.range(of: "cameraConfig = CameraRecorderConfig("))
        let call = code[start.upperBound...].prefix { $0 != ")" }
        #expect(!call.contains("width:") && !call.contains("height:") && !call.contains("frameRate:"))
    }
}
