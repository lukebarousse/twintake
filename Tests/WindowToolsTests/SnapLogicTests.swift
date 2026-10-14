import CoreGraphics
import Foundation
import Testing
import RecorderCore
@testable import WindowTools

@Suite struct SnapLogicTests {
    let frame = CGRect(x: 4, y: 37, width: 1504, height: 846)

    @Test func evaluateOutcomes() {
        #expect(SnapResult.evaluate(requested: frame, achieved: frame, tolerance: 1) == nil)
        #expect(SnapResult.evaluate(requested: frame, achieved: frame.offsetBy(dx: 0.5, dy: -0.5), tolerance: 1) == nil)
        #expect(SnapResult.evaluate(requested: frame, achieved: CGRect(x: 6, y: 40, width: 1500, height: 840),
                                    tolerance: 1) == .sizeMismatch)
        #expect(SnapResult.evaluate(requested: frame, achieved: frame.offsetBy(dx: 0, dy: 25), tolerance: 1) == .positionMismatch)
        #expect(SnapResult.evaluate(requested: frame, achieved: nil, tolerance: 1) == .axError)
    }

    @Test func smallerWindowIsCentered() {
        #expect(SnapGeometry.centeredOrigin(size: CGSize(width: 1500, height: 840), in: frame) == CGPoint(x: 6, y: 40))
        #expect(SnapGeometry.centeredOrigin(size: frame.size, in: frame) == frame.origin)
    }

    @Test func messages() {
        let ok = SnapResult.message(for: nil, appName: "Safari", title: nil, requested: frame, achieved: frame, axErrorCode: nil)
        #expect(ok == "Snapped Safari to 1504×846 pt.")
        let size = SnapResult.message(for: .sizeMismatch, appName: "Terminal", title: nil, requested: frame,
                                      achieved: CGRect(x: 6, y: 40, width: 1500, height: 840), axErrorCode: nil)
        #expect(size == "Terminal kept its window at 1500×840 pt instead of 1504×846 pt.")
        let full = SnapResult.message(for: .fullScreen, appName: "Keynote", title: "Talk", requested: frame,
                                      achieved: nil, axErrorCode: nil)
        #expect(full.contains("“Talk” is in full screen"))
        let busy = SnapResult.message(for: .axError, appName: "Xcode", title: nil, requested: frame, achieved: nil,
                                      axErrorCode: -25204)
        #expect(busy == "Xcode did not respond. Try again.")
    }

    @Test func failedResultCarriesReason() {
        let r = SnapResult.failed(.notTrusted, requested: frame)
        #expect(!r.success)
        #expect(r.failure == .notTrusted)
        #expect(r.message.contains("Accessibility"))
        #expect(r.snappedWindow == nil)
        #expect(r.eventData["failure"] == "not_trusted")
    }

    @Test func manifestAndEventValues() {
        let achieved = CGRect(x: 6, y: 40, width: 1500, height: 840)
        let r = SnapResult(success: false, failure: .sizeMismatch, appName: "Terminal", bundleId: "com.apple.Terminal",
                           pid: 42, title: "zsh", windowID: 777, requestedFrame: frame,
                           previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600), achievedFrame: achieved,
                           message: "")
        #expect(r.snappedWindow == SnappedWindow(appName: "Terminal", bundleId: "com.apple.Terminal", title: "zsh",
                                                 requestedPt: PointSize(width: 1504, height: 846),
                                                 achievedPt: PointSize(width: 1500, height: 840), placement: "fill"))
        let d = r.eventData
        #expect(d["requested"] == "4,37,1504,846")
        #expect(d["achieved"] == "6,40,1500,840")
        #expect(d["previous"] == "100,100,800,600")
        #expect(d["window_id"] == "777")
        #expect(d["success"] == "false")
        #expect(d["failure"] == "size_mismatch")
        #expect(d["bundle_id"] == "com.apple.Terminal")
        #expect(d["ax_error"] == nil)
    }

    @Test func pointFormatting() {
        #expect(CGFloat(1504).ptNumber == "1504")
        #expect(CGFloat(1504.5).ptNumber == "1504.5")
        #expect(CGFloat(-74).ptNumber == "-74")
        #expect(CGRect(x: 1720, y: -74, width: 1504, height: 846).eventString == "1720,-74,1504,846")
    }
}

@Suite struct WindowListTests {
    let target = CGRect(x: 4, y: 37, width: 1504, height: 846)

    @Test func matchByPidAndFrame() {
        let entries = [
            WindowListEntry(id: 10, pid: 7, layer: 25, bounds: target), // status item of the same app
            WindowListEntry(id: 11, pid: 8, bounds: target), // another app on top
            WindowListEntry(id: 12, pid: 7, bounds: target.offsetBy(dx: 1, dy: 1)),
            WindowListEntry(id: 13, pid: 7, bounds: CGRect(x: 0, y: 0, width: 300, height: 200)),
        ]
        #expect(WindowList.match(pid: 7, frames: [target], in: entries)?.id == 12)
        #expect(WindowList.match(pid: 7, frames: [target], tolerance: 0.5, in: entries) == nil)
    }

    @Test func matchFallsBackToOldFrameThenTitleThenOnlyWindow() {
        let old = CGRect(x: 100, y: 100, width: 800, height: 600)
        let lagging = [WindowListEntry(id: 20, pid: 7, bounds: old), WindowListEntry(id: 21, pid: 7, bounds: .init(x: 0, y: 0, width: 50, height: 50))]
        #expect(WindowList.match(pid: 7, frames: [target, old], in: lagging)?.id == 20)

        let titled = [WindowListEntry(id: 30, pid: 7, name: "Notes", bounds: old),
                      WindowListEntry(id: 31, pid: 7, name: "Doc", bounds: old.offsetBy(dx: 50, dy: 0))]
        #expect(WindowList.match(pid: 7, frames: [target], title: "Doc", in: titled)?.id == 31)

        let single = [WindowListEntry(id: 40, pid: 7, bounds: old), WindowListEntry(id: 41, pid: 9, bounds: target)]
        #expect(WindowList.match(pid: 7, frames: [target], in: single)?.id == 40)
        #expect(WindowList.match(pid: 7, frames: [target], in: titled) == nil)
    }

    @Test func parseWindowInfoDictionaries() {
        let raw: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 55), kCGWindowOwnerPID as String: NSNumber(value: 7),
             kCGWindowOwnerName as String: "Safari", kCGWindowLayer as String: NSNumber(value: 0),
             kCGWindowAlpha as String: NSNumber(value: 1.0),
             kCGWindowBounds as String: target.dictionaryRepresentation as NSDictionary],
            [kCGWindowOwnerPID as String: NSNumber(value: 7)], // no id or bounds: skipped
        ]
        let entries = WindowList.parse(raw)
        #expect(entries == [WindowListEntry(id: 55, pid: 7, ownerName: "Safari", bounds: target)])
    }
}

@Suite struct WindowMoveTests {
    @Test func detectsMovesAndResizes() {
        let a = CGRect(x: 4, y: 37, width: 1504, height: 846)
        #expect(WindowMove.change(from: a, to: a, tolerance: 1) == nil)
        #expect(WindowMove.change(from: a, to: a.offsetBy(dx: 0.5, dy: 0), tolerance: 1) == nil)
        let moved = WindowMove.change(from: a, to: a.offsetBy(dx: 40, dy: 0), tolerance: 1)
        #expect(moved?.moved == true && moved?.resized == false)
        let resized = WindowMove.change(from: a, to: CGRect(x: 4, y: 37, width: 1200, height: 846), tolerance: 1)
        #expect(resized?.moved == false && resized?.resized == true)
    }

    @Test func eventData() {
        let m = WindowMove(previousFrame: CGRect(x: 4, y: 37, width: 1504, height: 846), frame: nil, tHostNs: 1,
                           moved: false, resized: false, fillsFrame: false)
        #expect(m.closed)
        #expect(m.eventData["closed"] == "true")
        #expect(m.eventData["frame"] == nil)
        #expect(m.eventData["previous"] == "4,37,1504,846")
    }

    @MainActor @Test func monitorNeedsAWindow() {
        let r = SnapResult.failed(.noWindow, requested: .zero)
        #expect(SnappedWindowMonitor(snap: r) == nil)
    }

    /// The poll reads the window list first: while it shows the window where it was, no
    /// Accessibility read runs, so a busy app (a Parallels VM under load) never stalls the main
    /// thread once a second. A change, or a window the list does not have, asks Accessibility.
    @MainActor @Test func thePollAsksAccessibilityOnlyForAChange() {
        let a = CGRect(x: 4, y: 37, width: 1504, height: 846)
        let moved = a.offsetBy(dx: 40, dy: 0)
        var reads = 0
        func ax(_ frame: CGRect?) -> () -> CGRect? { { reads += 1; return frame } }
        #expect(SnappedWindowMonitor.frame(listed: a, last: a, tolerance: 1, accessibility: ax(a)) == a)
        #expect(SnappedWindowMonitor.frame(listed: a.offsetBy(dx: 0.5, dy: 0), last: a, tolerance: 1, accessibility: ax(a)) == a)
        #expect(reads == 0)
        #expect(SnappedWindowMonitor.frame(listed: moved, last: a, tolerance: 1, accessibility: ax(moved)) == moved)
        #expect(SnappedWindowMonitor.frame(listed: nil, last: a, tolerance: 1, accessibility: ax(moved)) == moved)
        #expect(SnappedWindowMonitor.frame(listed: a, last: nil, tolerance: 1, accessibility: ax(a)) == a)
        #expect(reads == 3)
        // The AX read timed out: the window list's frame stands in.
        #expect(SnappedWindowMonitor.frame(listed: moved, last: a, tolerance: 1, accessibility: ax(nil)) == moved)
        #expect(SnappedWindowMonitor.messagingTimeout <= 0.25)
    }
}
