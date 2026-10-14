import CoreGraphics
import Testing
@testable import WindowTools

@Suite struct ReplayWindowGeometryTests {
    let laptop = MonitorScreen(uuid: "laptop", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949))
    let monitor = MonitorScreen(uuid: "phl", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    /// First open: the top-right of a display that does not hold the recording frame.
    @Test func itOpensAwayFromTheRecordedDisplay() throws {
        let frame = try #require(ReplayWindowGeometry.openingFrame(screens: [laptop, monitor], saved: [:], lastScreenUUID: nil,
                                                                   frameDisplayUUID: "laptop"))
        #expect(frame.size == ReplayWindowGeometry.defaultSize)
        #expect(frame.maxX == monitor.visibleFrame.maxX - ReplayWindowGeometry.margin)
        #expect(frame.maxY == monitor.visibleFrame.maxY - ReplayWindowGeometry.margin)
        // One display: there, inside its visible frame.
        let only = try #require(ReplayWindowGeometry.openingFrame(screens: [laptop], saved: [:], lastScreenUUID: nil,
                                                                  frameDisplayUUID: "laptop"))
        #expect(laptop.visibleFrame.contains(only))
    }

    /// It remembers its place and size on each display.
    @Test func itReopensWhereItWas() throws {
        let place = CGRect(x: 100, y: 120, width: 700, height: 500)
        let frame = try #require(ReplayWindowGeometry.openingFrame(screens: [laptop, monitor], saved: ["phl": place],
                                                                   lastScreenUUID: "phl", frameDisplayUUID: "laptop"))
        #expect(frame == place.offsetBy(dx: 1512, dy: 0))
        // The display it was on is gone: the saved place on the default display, else its corner.
        let gone = try #require(ReplayWindowGeometry.openingFrame(screens: [laptop], saved: ["laptop": place],
                                                                  lastScreenUUID: "phl", frameDisplayUUID: "laptop"))
        #expect(gone == place)
    }

    @Test func clampKeepsItOnScreenAndAtLeastTheSmallestSize() {
        let tooBig = ReplayWindowGeometry.clamp(CGRect(x: -50, y: 900, width: 3000, height: 2000), into: laptop)
        #expect(tooBig == laptop.visibleFrame)
        let tiny = ReplayWindowGeometry.clamp(CGRect(x: 10, y: 10, width: 100, height: 50), into: laptop)
        #expect(tiny.size == ReplayWindowGeometry.minSize)
        #expect(ReplayWindowGeometry.clamped(CGRect(x: 9000, y: 9000, width: 500, height: 400), screens: [laptop]) == nil)
    }

    /// The camera picture sits in the screen picture's bottom-right corner, 16:9.
    @Test func theCameraSitsInTheScreenPicturesCorner() {
        let area = CGRect(x: 0, y: 96, width: 960, height: 600)
        let screen = ReplayWindowGeometry.fitted(CGSize(width: 16, height: 9), in: area)
        #expect(screen == CGRect(x: 0, y: 126, width: 960, height: 540))
        let camera = ReplayWindowGeometry.cameraInset(in: screen)
        #expect(camera.width == 250 && camera.height == 141)
        #expect(camera.maxX == screen.maxX - 10 && camera.minY == screen.minY + 10)
        #expect(ReplayWindowGeometry.fitted(.zero, in: area) == area)
    }
}
