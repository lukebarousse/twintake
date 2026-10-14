import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

@Suite struct SnapProfileTests {
    @Test func parallelsConsoleKeepsTheToolbarAbove() {
        let p = SnapProfile.profile(forBundleID: "com.parallels.desktop.console")
        #expect(p == .parallelsDesktop)
        #expect(p.id == "parallels")
        #expect(p.placement == .toolbarAbove)
        #expect(p.fallbackToolbarHeightPt == 38)
    }

    /// Every Parallels Desktop process that can show a VM window matches: the console, the
    /// per-VM Dock and Coherence helpers (`com.parallels.winapp.<uuid>.VM`) and the Windows app
    /// stubs (`com.parallels.winapp.<app hash>.<vm uuid>`, from Luke's `~/Applications (Parallels)`).
    @Test func parallelsVMProcessesGetTheParallelsProfile() {
        for id in ["com.parallels.desktop.console", "com.parallels.winapp.4b8e9a2b2cf949cda272e0db0cfe4c34.VM",
                   "com.parallels.winapp.680538a4d3885a14140fd5be847bc323.4b8e9a2b2cf949cda272e0db0cfe4c34",
                   "com.parallels.vm", "com.parallels.macvm"] {
            #expect(SnapProfile.profile(forBundleID: id) == .parallelsDesktop, "\(id)")
            #expect(SnapProfile.parallelsDesktop.matches(id), "\(id)")
        }
    }

    /// Review finding: other Parallels products and helpers have no VM toolbar. Their windows
    /// fill the frame, and "Hide other windows" can record them as a window.
    @Test func otherParallelsProductsFillTheFrame() {
        for id in ["com.parallels.toolbox", "com.parallels.client", "com.parallels.desktop.dispatcher",
                   "com.parallels.desktop.mounter", "com.parallels.SharedAppLink.Agent", "com.parallels.desktop",
                   "com.parallels.winapp", "com.parallels.access"] {
            #expect(SnapProfile.profile(forBundleID: id) == .standard, "\(id)")
            #expect(!SnapProfile.parallelsDesktop.matches(id), "\(id)")
        }
    }

    @Test func otherAppsFillTheFrame() {
        for id in ["com.apple.Safari", "com.apple.finder", "com.parallelsx.app", "com.parallels", "parallels", ""] {
            #expect(SnapProfile.profile(forBundleID: id) == .standard, "\(id)")
        }
        #expect(SnapProfile.profile(forBundleID: nil) == .standard)
        #expect(!SnapProfile.parallelsDesktop.matches(nil))
        #expect(SnapProfile.standard.placement == .fill)
        #expect(!SnapProfile.standard.matches("com.apple.Safari"))
    }

    @Test func emptyProfileListFillsForEveryApp() {
        #expect(SnapProfile.profile(forBundleID: "com.parallels.desktop.console", in: []) == .standard)
        #expect(SnapProfile.profile(forBundleID: "com.parallels.winapp.4b8e9a2b2cf949cda272e0db0cfe4c34.VM", in: []) == .standard)
    }
}

/// Synthetic Accessibility trees of a window snapped above the 14" laptop's bottom frame.
@Suite struct ToolbarDetectionTests {
    /// Bottom frame on the laptop, global CG points.
    let frame = CGRect(x: 4, y: 136, width: 1504, height: 846)

    func window(strip t: CGFloat) -> CGRect { ToolbarAboveGeometry.windowFrame(for: frame, toolbarPt: t) }

    /// Traffic lights, centered in a strip `t` high.
    func buttons(_ w: CGRect, strip t: CGFloat) -> [AXElementInfo] {
        ["AXCloseButton", "AXMinimizeButton", "AXZoomButton"].enumerated().map { i, sub in
            AXElementInfo(role: "AXButton", subrole: sub,
                          frame: CGRect(x: w.minX + 13 + CGFloat(i) * 20, y: w.minY + t / 2 - 7, width: 14, height: 14))
        }
    }

    func toolbar(_ w: CGRect, strip t: CGFloat) -> AXElementInfo {
        AXElementInfo(role: "AXToolbar", frame: CGRect(x: w.minX, y: w.minY, width: w.width, height: t))
    }

    func content(_ w: CGRect, top t: CGFloat) -> AXElementInfo {
        AXElementInfo(role: "AXGroup", frame: CGRect(x: w.minX, y: w.minY + t, width: w.width, height: w.height - t))
    }

    @Test(arguments: [CGFloat(28), 38, 52])
    func contentElementGivesTheStrip(t: CGFloat) {
        let w = window(strip: t)
        let m = ToolbarDetection.measure(window: w, elements: buttons(w, strip: t) + [toolbar(w, strip: t), content(w, top: t)],
                                         fallbackPt: 38)
        #expect(m == ToolbarMeasurement(detectedPt: t, source: .contentElement))
        #expect(m.heightPt == t)
        #expect(m.isMeasured)
    }

    @Test(arguments: [CGFloat(28), 38, 52])
    func toolbarElementWhenTheContentIsNotExposed(t: CGFloat) {
        let w = window(strip: t)
        // A container that spans the whole window (offset 0) is not the content area.
        let container = AXElementInfo(role: "AXGroup", frame: w)
        let m = ToolbarDetection.measure(window: w, elements: [container, toolbar(w, strip: t)] + buttons(w, strip: t),
                                         fallbackPt: 38)
        #expect(m == ToolbarMeasurement(detectedPt: t, source: .toolbarElement))
    }

    @Test func nestedContentBelowAFullWindowContainer() {
        let w = window(strip: 38)
        let elements = [AXElementInfo(role: "AXGroup", frame: w), AXElementInfo(role: "AXUnknown", frame: content(w, top: 38).frame)]
            + buttons(w, strip: 38)
        #expect(ToolbarDetection.measure(window: w, elements: elements, fallbackPt: 38).detectedPt == 38)
    }

    @Test func toolbarThatReportsOnlyItsItemsLosesToTheButtons() {
        // Unified 52 pt strip, but the AXToolbar frame covers only the items (y 8...44).
        let w = window(strip: 52)
        let items = AXElementInfo(role: "AXToolbar", frame: CGRect(x: w.minX + 80, y: w.minY + 8, width: 1400, height: 36))
        let m = ToolbarDetection.measure(window: w, elements: [items] + buttons(w, strip: 52), fallbackPt: 38)
        #expect(m == ToolbarMeasurement(detectedPt: 52, source: .titleBarButtons))
    }

    @Test func expandedToolbarUnderTheTitleRow() {
        // Title row 28 pt (buttons centered there), toolbar 50 pt below it.
        let w = window(strip: 78)
        let bar = AXElementInfo(role: "AXToolbar", frame: CGRect(x: w.minX, y: w.minY + 28, width: w.width, height: 50))
        let m = ToolbarDetection.measure(window: w, elements: [bar] + buttons(w, strip: 28), fallbackPt: 38)
        #expect(m == ToolbarMeasurement(detectedPt: 78, source: .toolbarElement))
    }

    @Test func buttonsAloneGiveTheTitleBar() {
        // Toolbar hidden: a plain 28 pt title bar.
        let w = window(strip: 28)
        let m = ToolbarDetection.measure(window: w, elements: buttons(w, strip: 28), fallbackPt: 38)
        #expect(m == ToolbarMeasurement(detectedPt: 28, source: .titleBarButtons))
    }

    @Test func bannerBelowTheToolbarStaysOutOfTheFrame() {
        // A 30 pt notice bar between the toolbar and the VM screen.
        let w = window(strip: 68)
        let banner = AXElementInfo(role: "AXGroup", frame: CGRect(x: w.minX, y: w.minY + 38, width: w.width, height: 30))
        let elements = [toolbar(w, strip: 38), banner, content(w, top: 68)] + buttons(w, strip: 38)
        #expect(ToolbarDetection.measure(window: w, elements: elements, fallbackPt: 38).detectedPt == 68)
    }

    @Test func partialAndNarrowElementsAreNotTheContent() {
        let w = window(strip: 38)
        let topHalf = AXElementInfo(role: "AXGroup", frame: CGRect(x: w.minX, y: w.minY + 38, width: w.width, height: 400))
        let sidebar = AXElementInfo(role: "AXGroup", frame: CGRect(x: w.minX, y: w.minY + 20, width: 300, height: w.height - 20))
        let button = AXElementInfo(role: "AXButton", frame: CGRect(x: w.minX, y: w.minY + 20, width: w.width, height: w.height - 20))
        let m = ToolbarDetection.measure(window: w, elements: [topHalf, sidebar, button, toolbar(w, strip: 38)], fallbackPt: 38)
        #expect(m.source == .toolbarElement)
        #expect(m.detectedPt == 38)
    }

    @Test func unreadableTreeUsesTheFallback() {
        let m = ToolbarDetection.measure(window: window(strip: 38), elements: nil, fallbackPt: 38)
        #expect(m == ToolbarMeasurement(detectedPt: 38, source: .fallback))
        #expect(!m.isMeasured)
    }

    @Test func titleBarWithNothingMeasurableUsesTheFallback() {
        let w = window(strip: 38)
        // A close button at the very top edge gives a strip below the plausible range.
        let odd = AXElementInfo(role: "AXButton", subrole: "AXCloseButton", frame: CGRect(x: w.minX + 13, y: w.minY, width: 4, height: 4))
        let m = ToolbarDetection.measure(window: w, elements: [odd], fallbackPt: 38)
        #expect(m.source == .fallback)
        #expect(m.detectedPt == 38)
    }

    @Test func windowWithoutTitleBarHasNoStrip() {
        // A Coherence window: no window buttons, no toolbar.
        let w = frame
        #expect(ToolbarDetection.measure(window: w, elements: [], fallbackPt: 38)
                == ToolbarMeasurement(detectedPt: 0, source: .noTitleBar))
        #expect(ToolbarDetection.measure(window: w, elements: [AXElementInfo(role: "AXGroup", frame: w)], fallbackPt: 38)
                == ToolbarMeasurement(detectedPt: 0, source: .noTitleBar))
        #expect(!ToolbarMeasurement(detectedPt: 0, source: .noTitleBar).isMeasured)
        #expect(ToolbarMeasurement(detectedPt: 38, source: .toolbarElement).isMeasured)
        #expect(ToolbarMeasurement(detectedPt: 38, source: .titleBarButtons).isMeasured)
    }

    @Test func fineTuneIsAddedAndNeverGoesBelowZero() {
        let w = window(strip: 38)
        let elements = [content(w, top: 38)]
        #expect(ToolbarDetection.measure(window: w, elements: elements, fallbackPt: 38, fineTunePt: 2).heightPt == 40)
        #expect(ToolbarDetection.measure(window: w, elements: elements, fallbackPt: 38, fineTunePt: -3).heightPt == 35)
        #expect(ToolbarDetection.measure(window: w, elements: elements, fallbackPt: 38, fineTunePt: -50).heightPt == 0)
        let m = ToolbarDetection.measure(window: w, elements: nil, fallbackPt: 38, fineTunePt: 1.5)
        #expect(m.detectedPt == 38 && m.fineTunePt == 1.5 && m.heightPt == 39.5)
    }

    @Test func heightsRoundToHalfPoints() {
        let w = CGRect(x: 4, y: 98, width: 1504, height: 884)
        let e = AXElementInfo(role: "AXGroup", frame: CGRect(x: 4, y: 98 + 37.9, width: 1504, height: 884 - 37.9))
        #expect(ToolbarDetection.measure(window: w, elements: [e], fallbackPt: 38).detectedPt == 38)
    }
}

@Suite struct ToolbarAbovePlacementTests {
    /// The 14" laptop: menu bar 37 pt; frames in global CG points (laptop is the main display).
    let bottomFrame = CGRect(x: 4, y: 136, width: 1504, height: 846)
    let topFrame = CGRect(x: 4, y: 37, width: 1504, height: 846)
    let menuBarBottom: CGFloat = 37

    @Test func windowGoesAboveTheFrameByTheStrip() {
        #expect(ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: 28) == CGRect(x: 4, y: 108, width: 1504, height: 874))
        #expect(ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: 38) == CGRect(x: 4, y: 98, width: 1504, height: 884))
        #expect(ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: 52) == CGRect(x: 4, y: 84, width: 1504, height: 898))
        #expect(ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: 0) == bottomFrame)
    }

    @Test(arguments: [CGFloat(28), 38, 52])
    func contentOfThePlacedWindowIsExactlyTheFrame(t: CGFloat) {
        let w = ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: t)
        #expect(ToolbarAboveGeometry.contentFrame(ofWindow: w, toolbarPt: t) == bottomFrame)
        #expect(w.maxY == 982) // the window ends at the display's bottom edge
        #expect(w.minY >= menuBarBottom)
    }

    @Test(arguments: [CGFloat(28), 38, 52])
    func bottomFrameHasRoomForTheToolbar(t: CGFloat) {
        #expect(ToolbarAbovePlan.make(frame: bottomFrame, toolbarPt: t, topLimitY: menuBarBottom)
                == .place(window: ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: t)))
    }

    @Test(arguments: [CGFloat(28), 38, 52])
    func topFrameMustMoveDown(t: CGFloat) {
        #expect(ToolbarAbovePlan.make(frame: topFrame, toolbarPt: t, topLimitY: menuBarBottom) == .noRoom(moveDownPt: t))
    }

    @Test func fineTuneChangesThePlacement() {
        let m = ToolbarMeasurement(detectedPt: 38, source: .contentElement, fineTunePt: -2)
        #expect(ToolbarAbovePlan.make(frame: bottomFrame, toolbarPt: m.heightPt, topLimitY: menuBarBottom)
                == .place(window: CGRect(x: 4, y: 100, width: 1504, height: 882)))
        let up = ToolbarMeasurement(detectedPt: 38, source: .contentElement, fineTunePt: 3)
        #expect(ToolbarAbovePlan.make(frame: bottomFrame, toolbarPt: up.heightPt, topLimitY: menuBarBottom)
                == .place(window: CGRect(x: 4, y: 95, width: 1504, height: 887)))
        // A fine-tune that removes the strip lets the top frame snap like any window.
        let none = ToolbarMeasurement(detectedPt: 38, source: .contentElement, fineTunePt: -38)
        #expect(ToolbarAbovePlan.make(frame: topFrame, toolbarPt: none.heightPt, topLimitY: menuBarBottom)
                == .place(window: topFrame))
    }

    @Test func partialRoomReportsWhatIsMissing() {
        let frame = topFrame.offsetBy(dx: 0, dy: 20)
        #expect(ToolbarAboveGeometry.roomNeeded(frame: frame, toolbarPt: 38, topLimitY: menuBarBottom) == 18)
        #expect(ToolbarAboveGeometry.roomNeeded(frame: frame, toolbarPt: 20, topLimitY: menuBarBottom) == nil)
        #expect(ToolbarAboveGeometry.roomNeeded(frame: frame, toolbarPt: 20.4, topLimitY: menuBarBottom) == nil)
        #expect(ToolbarAboveGeometry.roomNeeded(frame: frame, toolbarPt: 20.6, topLimitY: menuBarBottom) == 1)
        #expect(ToolbarAbovePlan.make(frame: topFrame, toolbarPt: 38, topLimitY: nil)
                == .place(window: ToolbarAboveGeometry.windowFrame(for: topFrame, toolbarPt: 38)))
    }

    @Test func topFrameOnASecondaryMonitorAlsoMustMoveDown() {
        let m = Fixtures.monitorRight
        let frame = m.globalFrameRect(for: .laptop16x9) // (1720, -74, 1504, 846), menu bar 24
        #expect(m.windowTopLimitGlobal == -74)
        #expect(ToolbarAbovePlan.make(frame: frame, toolbarPt: 38, topLimitY: m.windowTopLimitGlobal) == .noRoom(moveDownPt: 38))
        let bottom = m.globalFrameRect(for: .laptop16x9, anchor: .bottom)
        #expect(ToolbarAbovePlan.make(frame: bottom, toolbarPt: 38, topLimitY: m.windowTopLimitGlobal)
                == .place(window: CGRect(x: 1720, y: 98, width: 1504, height: 884)))
    }

    @Test func correctionOnlyWhenAContentEdgeIsOffByMoreThanTheTolerance() {
        let target = ToolbarAboveGeometry.windowFrame(for: bottomFrame, toolbarPt: 38)
        #expect(ToolbarAbovePlan.correction(frame: bottomFrame, achievedWindow: target, toolbarPt: 38, tolerance: 1) == nil)
        #expect(ToolbarAbovePlan.correction(frame: bottomFrame, achievedWindow: target.offsetBy(dx: 0, dy: 0.5),
                                            toolbarPt: 38, tolerance: 1) == nil)
        #expect(ToolbarAbovePlan.correction(frame: bottomFrame, achievedWindow: target.offsetBy(dx: 0, dy: 2),
                                            toolbarPt: 38, tolerance: 1) == target)
        // The strip read after the move is 52 pt, not 38: ask for a taller window, 14 pt higher.
        #expect(ToolbarAbovePlan.correction(frame: bottomFrame, achievedWindow: target, toolbarPt: 52, tolerance: 1)
                == CGRect(x: 4, y: 84, width: 1504, height: 898))
    }

    @Test func parallelsOnTheLaptopBottomFrameEndToEnd() {
        let d = Fixtures.laptop
        let frame = d.globalFrameRect(for: .laptop16x9, anchor: .bottom)
        #expect(frame == bottomFrame)
        // The window before the snap: 1504x846 at the top frame, toolbar inside the frame.
        let before = topFrame
        let elements = [AXElementInfo(role: "AXToolbar", frame: CGRect(x: 4, y: 37, width: 1504, height: 38)),
                        AXElementInfo(role: "AXGroup", frame: CGRect(x: 4, y: 75, width: 1504, height: 808))]
        let m = ToolbarDetection.measure(window: before, elements: elements, fallbackPt: SnapProfile.parallelsDesktop.fallbackToolbarHeightPt)
        #expect(m.heightPt == 38)
        guard case let .place(window) = ToolbarAbovePlan.make(frame: frame, toolbarPt: m.heightPt, topLimitY: d.windowTopLimitGlobal) else {
            Issue.record("expected a placement"); return
        }
        #expect(window == CGRect(x: 4, y: 98, width: 1504, height: 884))
        #expect(ToolbarAboveGeometry.contentFrame(ofWindow: window, toolbarPt: m.heightPt) == frame)
        // The VM screen is then 1504x846 pt = 3008x1692 px at 2x, the size of screen.mov.
        #expect(FrameGeometry.outputPixels(forPoints: frame.size, scale: d.scale) == PixelSize(width: 3008, height: 1692))
    }
}

@Suite struct ToolbarSnapResultTests {
    let frame = CGRect(x: 4, y: 136, width: 1504, height: 846)

    func result(failure: SnapFailure?, achieved: CGRect?, content: CGRect?, moveDown: CGFloat? = nil) -> SnapResult {
        let toolbar = ToolbarMeasurement(detectedPt: 38, source: .contentElement, fineTunePt: 0)
        let msg = SnapResult.message(for: failure, appName: "Parallels Desktop", title: "Windows 11", requested: frame,
                                     achieved: content, axErrorCode: nil, placement: .toolbarAbove,
                                     toolbarPt: toolbar.heightPt, moveDownPt: moveDown)
        return SnapResult(success: failure == nil, failure: failure, appName: "Parallels Desktop",
                          bundleId: "com.parallels.desktop.console", pid: 13004, title: "Windows 11", windowID: 88,
                          requestedFrame: frame, previousFrame: CGRect(x: 4, y: 37, width: 1504, height: 846),
                          achievedFrame: achieved, message: msg, placement: .toolbarAbove, profileID: "parallels",
                          toolbar: toolbar, windowTargetFrame: CGRect(x: 4, y: 98, width: 1504, height: 884),
                          achievedContentFrame: content, frameMoveDownPt: moveDown)
    }

    @Test func successRecordsTheContentArea() {
        let window = CGRect(x: 4, y: 98, width: 1504, height: 884)
        let r = result(failure: nil, achieved: window, content: frame)
        #expect(r.message == "Snapped Parallels Desktop to 1504×846 pt, with its toolbar (38 pt) above the frame.")
        #expect(r.achievedRecordedFrame == frame)
        #expect(r.snappedWindow?.achievedPt == PointSize(width: 1504, height: 846))
        #expect(r.snappedWindow?.requestedPt == PointSize(width: 1504, height: 846))
        #expect(r.snappedWindow?.placement == "toolbar_above")
        #expect(r.snappedWindow?.toolbarPt == 38)
        let d = r.eventData
        #expect(d["placement"] == "toolbar_above")
        #expect(d["profile"] == "parallels")
        #expect(d["toolbar_pt"] == "38")
        #expect(d["toolbar_source"] == "content_element")
        #expect(d["toolbar_fine_tune_pt"] == "0")
        #expect(d["window_target"] == "4,98,1504,884")
        #expect(d["achieved"] == "4,98,1504,884")
        #expect(d["content"] == "4,136,1504,846")
        #expect(d["requested"] == "4,136,1504,846")
        #expect(d["move_down_pt"] == nil)
    }

    @Test func noRoomTellsTheUserToMoveTheFrameDown() {
        let top = CGRect(x: 4, y: 37, width: 1504, height: 846)
        let msg = SnapResult.message(for: .toolbarNoRoom, appName: "Parallels Desktop", title: nil, requested: top,
                                     achieved: nil, axErrorCode: nil, placement: .toolbarAbove, toolbarPt: 38, moveDownPt: 38)
        #expect(msg == "Parallels Desktop keeps its toolbar (38 pt) above the frame, and the toolbar does not fit under the menu bar. It needs 38 pt more. Move the frame to the bottom of the display, then snap again.")
        let r = result(failure: .toolbarNoRoom, achieved: nil, content: nil, moveDown: 38)
        #expect(!r.success)
        #expect(r.snappedWindow == nil)
        #expect(r.eventData["failure"] == "toolbar_no_room")
        #expect(r.eventData["move_down_pt"] == "38")
    }

    @Test func mismatchMessagesNameTheContentArea() {
        let content = CGRect(x: 4, y: 137, width: 1504, height: 845)
        #expect(SnapResult.evaluate(requested: frame, achieved: content, tolerance: 1) == nil)
        let off = CGRect(x: 4, y: 140, width: 1504, height: 842)
        #expect(SnapResult.evaluate(requested: frame, achieved: off, tolerance: 1) == .sizeMismatch)
        let size = SnapResult.message(for: .sizeMismatch, appName: "Parallels Desktop", title: nil, requested: frame,
                                      achieved: off, axErrorCode: nil, placement: .toolbarAbove, toolbarPt: 38)
        #expect(size == "Parallels Desktop kept its content area at 1504×842 pt instead of 1504×846 pt.")
        let moved = SnapResult.message(for: .positionMismatch, appName: "Parallels Desktop", title: nil, requested: frame,
                                       achieved: frame.offsetBy(dx: 0, dy: 5), axErrorCode: nil, placement: .toolbarAbove)
        #expect(moved == "Parallels Desktop placed its content area at (4, 141) instead of (4, 136).")
    }

    @Test func fillSnapsKeepTheirOldEventsAndTarget() {
        let r = SnapResult(success: true, failure: nil, appName: "Safari", bundleId: "com.apple.Safari", pid: 1, title: nil,
                           windowID: nil, requestedFrame: frame, previousFrame: nil, achievedFrame: frame, message: "")
        #expect(r.placement == .fill)
        #expect(r.profileID == "standard")
        #expect(r.windowTargetFrame == frame)
        #expect(r.achievedRecordedFrame == frame)
        #expect(r.toolbar == nil)
        for key in ["placement", "profile", "toolbar_pt", "toolbar_source", "window_target", "content", "move_down_pt"] {
            #expect(r.eventData[key] == nil, "\(key)")
        }
        #expect(SnapResult.failed(.noWindow, requested: frame).windowTargetFrame == frame)
    }

    @MainActor @Test func snapperUsesTheBuiltInProfilesByDefault() {
        let s = WindowSnapper()
        #expect(s.profiles == SnapProfile.all)
    }
}
