import AppKit
import CoreGraphics
import Testing
@testable import WindowTools

/// AppKit coordinates (y up). The laptop is the main display at the origin; the monitor sits to
/// its right; a third display is above the laptop.
private let laptop = MonitorScreen(uuid: "LAPTOP", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875))
private let monitor = MonitorScreen(uuid: "PHILIPS", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1056))
private let above = MonitorScreen(uuid: "ABOVE", frame: CGRect(x: -200, y: 982, width: 1280, height: 720),
                                  visibleFrame: CGRect(x: -200, y: 982, width: 1280, height: 696))

@Suite struct CameraWindowGeometryTests {
    func isSixteenByNine(_ size: CGSize) -> Bool { abs(size.width / size.height - 16.0 / 9.0) < 0.01 }

    @Test func presetsAre16by9AndMediumIsTheDefault() {
        #expect(CameraWindowGeometry.SizePreset.small.size == CGSize(width: 320, height: 180))
        #expect(CameraWindowGeometry.SizePreset.medium.size == CGSize(width: 480, height: 270))
        #expect(CameraWindowGeometry.SizePreset.large.size == CGSize(width: 640, height: 360))
        for preset in CameraWindowGeometry.SizePreset.allCases { #expect(isSixteenByNine(preset.size)) }
        #expect(isSixteenByNine(CameraWindowGeometry.minSize))
    }

    @Test func lockedSizeKeeps16by9AndTheMinimum() {
        #expect(CameraWindowGeometry.lockedSize(width: 480) == CGSize(width: 480, height: 270))
        #expect(CameraWindowGeometry.lockedSize(width: 100) == CGSize(width: 240, height: 135))
        // Never larger than the room it has: limited here by the height.
        #expect(CameraWindowGeometry.lockedSize(width: 2000, limit: CGSize(width: 1920, height: 540)) == CGSize(width: 960, height: 540))
    }

    @Test func defaultScreenAvoidsTheRecordingFrame() {
        #expect(CameraWindowGeometry.defaultScreen([laptop, monitor], frameDisplayUUID: "LAPTOP") == monitor)
        #expect(CameraWindowGeometry.defaultScreen([laptop, monitor], frameDisplayUUID: "PHILIPS") == laptop)
        // One display: the frame's own display.
        #expect(CameraWindowGeometry.defaultScreen([laptop], frameDisplayUUID: "LAPTOP") == laptop)
        // No frame (Camera mode), or a frame on a display that went away: the first (main) display.
        #expect(CameraWindowGeometry.defaultScreen([laptop, monitor], frameDisplayUUID: nil) == laptop)
        #expect(CameraWindowGeometry.defaultScreen([], frameDisplayUUID: "LAPTOP") == nil)
    }

    @Test func defaultPlaceIsBottomRightOfTheVisibleFrame() {
        let rect = CameraWindowGeometry.bottomRight(size: CameraWindowGeometry.SizePreset.medium.size, on: monitor)
        #expect(rect == CGRect(x: 1512 + 1920 - 16 - 480, y: 16, width: 480, height: 270))
        let onLaptop = CameraWindowGeometry.bottomRight(size: CameraWindowGeometry.SizePreset.medium.size, on: laptop)
        // Above the Dock: the laptop's visible frame starts at y 70.
        #expect(onLaptop == CGRect(x: 1512 - 16 - 480, y: 70 + 16, width: 480, height: 270))
    }

    @Test func openingFramePrefersTheLastScreenItsPlaceWasSavedOn() {
        let saved = ["LAPTOP": CGRect(x: 100, y: 200, width: 320, height: 180),
                     "PHILIPS": CGRect(x: 40, y: 40, width: 640, height: 360)]
        let last = CameraWindowGeometry.openingFrame(screens: [laptop, monitor], saved: saved, lastScreenUUID: "LAPTOP",
                                                     frameDisplayUUID: "LAPTOP")
        #expect(last?.screenUUID == "LAPTOP")
        #expect(last?.rect == CGRect(x: 100, y: 200, width: 320, height: 180))

        // The last screen is gone: the default screen's saved place, offset by that screen's origin.
        let fallback = CameraWindowGeometry.openingFrame(screens: [laptop, monitor], saved: saved, lastScreenUUID: "GONE",
                                                         frameDisplayUUID: "LAPTOP")
        #expect(fallback?.screenUUID == "PHILIPS")
        #expect(fallback?.rect == CGRect(x: 1512 + 40, y: 40, width: 640, height: 360))
    }

    @Test func openingFrameFallsBackToMediumBottomRight() {
        let first = CameraWindowGeometry.openingFrame(screens: [laptop, monitor], saved: [:], lastScreenUUID: nil,
                                                      frameDisplayUUID: "LAPTOP")
        #expect(first?.screenUUID == "PHILIPS")
        #expect(first?.rect.size == CGSize(width: 480, height: 270))
        #expect(first?.rect.maxX == monitor.visibleFrame.maxX - 16)
        #expect(CameraWindowGeometry.openingFrame(screens: [], saved: [:], lastScreenUUID: nil, frameDisplayUUID: nil) == nil)
    }

    @Test func savedPlaceOffScreenOpensInside() {
        // Saved on a larger arrangement: now partly below the visible frame and off the right edge.
        let saved = ["LAPTOP": CGRect(x: 1400, y: -50, width: 480, height: 270)]
        let rect = CameraWindowGeometry.openingFrame(screens: [laptop], saved: saved, lastScreenUUID: "LAPTOP",
                                                     frameDisplayUUID: nil)?.rect
        #expect(rect == CGRect(x: 1512 - 480, y: 70, width: 480, height: 270))
    }

    @Test func placesAreRelativeToTheirScreen() {
        let window = CGRect(x: -100, y: 1100, width: 480, height: 270)
        let local = CameraWindowGeometry.local(window, on: above)
        #expect(local == CGRect(x: 100, y: 118, width: 480, height: 270))
        #expect(CameraWindowGeometry.global(local, on: above) == window)
        // The display moved in the arrangement: the window keeps its place on it.
        var moved = above
        moved.frame.origin = CGPoint(x: 300, y: 982)
        #expect(CameraWindowGeometry.global(local, on: moved).origin == CGPoint(x: 400, y: 1100))
    }

    @Test func clampingKeepsTheWindowOnTheScreenThatHoldsMostOfIt() {
        // Mostly on the monitor, hanging off its right edge.
        let off = CGRect(x: 3300, y: 500, width: 480, height: 270)
        #expect(CameraWindowGeometry.clamped(off, screens: [laptop, monitor]) == CGRect(x: 3432 - 480, y: 500, width: 480, height: 270))
        // Its display went away: nothing holds it.
        #expect(CameraWindowGeometry.clamped(off, screens: [laptop]) == nil)
        // Larger than the visible frame: shrunk, still 16:9.
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 1125)
        let fitted = CameraWindowGeometry.clamp(huge, into: laptop)
        #expect(laptop.visibleFrame.contains(fitted))
        #expect(isSixteenByNine(fitted.size))
        // Already inside: unchanged.
        let inside = CGRect(x: 200, y: 300, width: 480, height: 270)
        #expect(CameraWindowGeometry.clamped(inside, screens: [laptop, monitor]) == inside)
    }

    @Test func sizePresetKeepsTheCenterAndStaysOnScreen() {
        let rect = CGRect(x: 500, y: 400, width: 480, height: 270)
        let large = CameraWindowGeometry.resized(rect, to: CameraWindowGeometry.SizePreset.large.size, on: laptop)
        #expect(large == CGRect(x: 420, y: 355, width: 640, height: 360))
        let corner = CGRect(x: 1512 - 480, y: 70, width: 480, height: 270)
        let grown = CameraWindowGeometry.resized(corner, to: CameraWindowGeometry.SizePreset.large.size, on: laptop)
        #expect(laptop.visibleFrame.contains(grown))
        #expect(grown.size == CGSize(width: 640, height: 360))
    }

    @Test func aMouseDownNearTheBorderResizesFromItsCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 270)
        #expect(CameraWindowGeometry.corner(at: CGPoint(x: 240, y: 135), in: bounds, edge: 10) == nil)
        #expect(CameraWindowGeometry.corner(at: CGPoint(x: 476, y: 4), in: bounds, edge: 10) == .bottomRight)
        #expect(CameraWindowGeometry.corner(at: CGPoint(x: 4, y: 266), in: bounds, edge: 10) == .topLeft)
        // An edge resizes from the corner of its half.
        #expect(CameraWindowGeometry.corner(at: CGPoint(x: 478, y: 200), in: bounds, edge: 10) == .topRight)
        #expect(CameraWindowGeometry.corner(at: CGPoint(x: 100, y: 2), in: bounds, edge: 10) == .bottomLeft)
    }

    @Test func dragResizeKeeps16by9AndTheOppositeCorner() {
        let start = CGRect(x: 1000, y: 100, width: 480, height: 270)
        // Bottom-right corner dragged right and down: the top-left corner (1000, 370) stays.
        let wider = CameraWindowGeometry.resized(start, corner: .bottomRight, to: CGPoint(x: 1640, y: 10))
        #expect(wider.minX == 1000 && wider.maxY == 370)
        #expect(wider.size == CGSize(width: 640, height: 360))
        // Top-left corner dragged in: the bottom-right corner (1480, 100) stays; never below the minimum.
        let tiny = CameraWindowGeometry.resized(start, corner: .topLeft, to: CGPoint(x: 1470, y: 110))
        #expect(tiny.maxX == 1480 && tiny.minY == 100)
        #expect(tiny.size == CameraWindowGeometry.minSize)
        // Dragged past the fixed corner: still the minimum, on the right side of it.
        let crossed = CameraWindowGeometry.resized(start, corner: .topRight, to: CGPoint(x: 900, y: 50))
        #expect(crossed == CGRect(x: 1000, y: 100, width: 240, height: 135))
        // Height wins when the mouse moves further vertically.
        let taller = CameraWindowGeometry.resized(start, corner: .topRight, to: CGPoint(x: 1490, y: 100 + 450))
        #expect(taller.size == CGSize(width: 800, height: 450))
        // No larger than the screen.
        let capped = CameraWindowGeometry.resized(start, corner: .topRight, to: CGPoint(x: 9000, y: 9000),
                                                  maxSize: CGSize(width: 1512, height: 875))
        #expect(capped.width <= 1512 && capped.height <= 875)
        #expect(isSixteenByNine(capped.size))
    }

    /// A grab 5 pt inside the bottom edge, in the right half, resizes from the bottom-right corner.
    /// The window must not change before the mouse moves, and then follows the mouse.
    @Test func aGrabInsideTheResizeBandNeverJumps() {
        let start = CGRect(x: 1000, y: 100, width: 480, height: 270)
        let grab = CGPoint(x: 1300, y: 105)
        func frame(_ mouse: CGPoint) -> CGRect {
            let target = CameraWindowGeometry.dragTarget(of: .bottomRight, in: start, grab: grab, mouse: mouse)
            return CameraWindowGeometry.resized(start, corner: .bottomRight, to: target)
        }
        #expect(frame(grab) == start)
        // The raw mouse point made it jump to 471x265.
        #expect(CameraWindowGeometry.resized(start, corner: .bottomRight, to: grab).size == CGSize(width: 471, height: 265))
        // 160 pt right: the right edge follows, the top-left corner stays.
        #expect(frame(CGPoint(x: 1460, y: 105)) == CGRect(x: 1000, y: 10, width: 640, height: 360))
        for corner in [CameraWindowGeometry.Corner.bottomLeft, .bottomRight, .topLeft, .topRight] {
            let p = CameraWindowGeometry.point(of: corner, in: start)
            #expect(CameraWindowGeometry.resized(start, corner: corner, to: p) == start)
        }
    }

    @Test func savedRectsRoundTrip() {
        let rect = CGRect(x: -12.5, y: 40, width: 480, height: 270)
        #expect(CameraWindowGeometry.decode(CameraWindowGeometry.encode(rect)) == rect)
        #expect(CameraWindowGeometry.decode(nil) == nil)
        #expect(CameraWindowGeometry.decode([1, 2, 3]) == nil)
        #expect(CameraWindowGeometry.decode([1, 2, 0, 270]) == nil)
        #expect(CameraWindowGeometry.decode([1, 2, .infinity, 270]) == nil)
    }

    /// The camera window (and the control bar) sit just above the dim panels, so they are never
    /// dimmed. Luke's report: an Elgato display utility's menu bar popover opened under the camera
    /// window. The dim is now at the floating level and the camera window just above it, so every
    /// app's menus and popovers (status bar level and up) open over both.
    @MainActor @Test func windowLevelIsAboveTheOverlayAndBelowOtherAppsMenus() {
        #expect(FrameOverlay.dimLevel == .floating)
        #expect(FrameOverlay.aboveOverlayLevel.rawValue == NSWindow.Level.floating.rawValue + 1)
        #expect(FrameOverlay.aboveOverlayLevel.rawValue > FrameOverlay.dimLevel.rawValue)
        #expect(FrameOverlay.aboveOverlayLevel.rawValue > NSWindow.Level.normal.rawValue)
        // Other apps' status item popovers and menu bar menus.
        #expect(FrameOverlay.aboveOverlayLevel.rawValue < NSWindow.Level.statusBar.rawValue)
        #expect(FrameOverlay.aboveOverlayLevel.rawValue < NSWindow.Level.mainMenu.rawValue)
        #expect(FrameOverlay.aboveOverlayLevel.rawValue < NSWindow.Level.popUpMenu.rawValue)
        #expect(FrameOverlay.aboveOverlayLevel.rawValue < Int(CGWindowLevelForKey(.dockWindow)))
        #expect(FrameOverlay.dimLevel.rawValue < Int(CGWindowLevelForKey(.dockWindow)))
        // The menu bar strip (only with coverMenuBar, which the app never turns on) stays above the menu bar.
        #expect(FrameOverlay.menuBarLevel.rawValue > NSWindow.Level.statusBar.rawValue)
    }
}
