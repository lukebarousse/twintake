import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

/// The control bar's default place, saved places and clamping (AppKit coordinates, y up).
@Suite struct ControlBarGeometryTests {
    typealias Geo = ControlBarGeometry

    /// The 14" laptop alone: 1512x982 pt, a 33 pt menu bar, the Dock hidden.
    let laptop = MonitorScreen(uuid: "LAPTOP", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949))
    let laptopDisplay = DisplayInfo(id: 1, uuid: "LAPTOP", name: "Built-in Retina Display", isBuiltin: true, isMain: true,
                                    boundsGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2,
                                    menuBarHeightPt: 33, refreshRate: 120)
    let size = CGSize(width: 300, height: 34)

    /// The recording frame in AppKit coordinates, the way the app gets it.
    func frame(_ anchor: FrameAnchor, on display: DisplayInfo, mainHeight: CGFloat) -> CGRect {
        FrameGeometry.appKitRect(fromGlobal: display.globalFrameRect(for: .laptop16x9, anchor: anchor), mainDisplayHeight: mainHeight)
    }

    /// Luke's setup: the 16:9 frame at the bottom leaves a 103 pt gray strip under the menu bar.
    /// The bar goes in the middle of it, over the frame's middle.
    @Test func theDefaultIsCenteredInTheStripAboveABottomFrame() {
        let bottom = frame(.bottom, on: laptopDisplay, mainHeight: 982)
        #expect(bottom == CGRect(x: 4, y: 0, width: 1504, height: 846))
        let place = Geo.defaultFrame(size: size, on: laptop, frame: bottom)
        // Strip 846...949: (103 - 34) / 2 = 34.5 above the frame, rounded down.
        #expect(place == CGRect(x: 606, y: 880, width: 300, height: 34))
        #expect(place.midX == bottom.midX)
        #expect(place.minY >= bottom.maxY + Geo.stripGap && place.maxY <= laptop.visibleFrame.maxY - Geo.stripGap)
    }

    /// With "Hide the Parallels toolbar" on, the 38 pt right above the frame is the Parallels
    /// toolbar: the bar takes the middle of the free part above it.
    @Test func theDefaultLeavesTheParallelsToolbarFree() {
        let bottom = frame(.bottom, on: laptopDisplay, mainHeight: 982)
        let place = Geo.defaultFrame(size: size, on: laptop, frame: bottom, reservedAbovePt: 38)
        #expect(place == CGRect(x: 606, y: 899, width: 300, height: 34))
        #expect(place.minY >= bottom.maxY + 38)
        #expect(place.maxY <= laptop.visibleFrame.maxY)
        // A reserved strip that leaves too little room: the middle of the whole strip.
        #expect(Geo.defaultFrame(size: size, on: laptop, frame: bottom, reservedAbovePt: 70).minY == 880)
    }

    /// No strip (the frame at the top, under the menu bar), no frame, or a frame on another
    /// display: top-center, under the menu bar.
    @Test func theFallbackIsTopCenterUnderTheMenuBar() {
        let top = frame(.top, on: laptopDisplay, mainHeight: 982)
        #expect(top.maxY == laptop.visibleFrame.maxY)
        let expected = CGRect(x: 606, y: 949 - Geo.margin - 34, width: 300, height: 34)
        #expect(Geo.defaultFrame(size: size, on: laptop, frame: top) == expected)
        #expect(Geo.defaultFrame(size: size, on: laptop, frame: nil) == expected)
        let elsewhere = CGRect(x: 4000, y: 0, width: 1504, height: 846)
        #expect(Geo.defaultFrame(size: size, on: laptop, frame: elsewhere) == expected)
        // A strip just too short for the bar and its gaps.
        let tall = CGRect(x: 4, y: 0, width: 1504, height: 949 - 41)
        #expect(Geo.defaultFrame(size: size, on: laptop, frame: tall) == expected)
        #expect(Geo.underMenuBar(size: size, on: laptop) == expected)
    }

    /// Luke's desk: the PHL is the main display, the laptop is below it to the right. The
    /// conversion from the global frame lands in the laptop's strip.
    @Test func theStripOnTheLaptopBelowTheMainDisplay() {
        let display = DisplayInfo(id: 2, uuid: "LAPTOP", name: "Built-in Retina Display", isBuiltin: true, isMain: false,
                                  boundsGlobal: CGRect(x: 2328, y: 1080, width: 1512, height: 982), scale: 2,
                                  menuBarHeightPt: 37, refreshRate: 120)
        let screen = MonitorScreen(uuid: "LAPTOP", frame: CGRect(x: 2328, y: -982, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 2328, y: -982, width: 1512, height: 945))
        let bottom = frame(.bottom, on: display, mainHeight: 1080)
        #expect(bottom == CGRect(x: 2332, y: -982, width: 1504, height: 846))
        let place = Geo.defaultFrame(size: size, on: screen, frame: bottom)
        // Strip -136...-37 (99 pt): 32.5 above the frame, rounded down.
        #expect(place == CGRect(x: 2934, y: -104, width: 300, height: 34))
        #expect(screen.visibleFrame.contains(place))
    }

    @Test func clampKeepsTheBarInsideTheVisibleFrame() {
        // Past the right edge and over the menu bar.
        #expect(Geo.clamp(CGRect(x: 1400, y: 960, width: 300, height: 34), into: laptop)
            == CGRect(x: 1212, y: 915, width: 300, height: 34))
        // Below the bottom and past the left edge.
        #expect(Geo.clamp(CGRect(x: -50, y: -20, width: 300, height: 34), into: laptop)
            == CGRect(x: 0, y: 0, width: 300, height: 34))
        // Inside: unchanged.
        let inside = CGRect(x: 100, y: 500, width: 300, height: 34)
        #expect(Geo.clamp(inside, into: laptop) == inside)
        // Wider than the screen: it starts at the left edge, its size kept.
        #expect(Geo.clamp(CGRect(x: 300, y: 500, width: 1600, height: 34), into: laptop).minX == 0)
        // On no screen (its display went away): nil, so the bar opens at its place elsewhere.
        #expect(Geo.clamped(CGRect(x: 5000, y: 5000, width: 300, height: 34), screens: [laptop]) == nil)
        #expect(Geo.clamped(CGRect(x: 1400, y: 960, width: 300, height: 34), screens: [laptop])?.maxX == 1512)
    }

    /// A saved place is the bar's center on its screen. After the screen got smaller (another
    /// resolution) the bar is kept on it.
    @Test func savedPlacesAreCentersClampedToTheirScreen() {
        let rect = CGRect(x: 1100, y: 880, width: 300, height: 34)
        let center = Geo.localCenter(of: rect, on: laptop)
        #expect(center == CGPoint(x: 1250, y: 897))
        #expect(Geo.frame(size: size, savedCenter: center, on: laptop) == rect)
        // A wider bar (one more pinned app) around the same center.
        #expect(Geo.frame(size: CGSize(width: 360, height: 34), savedCenter: center, on: laptop).midX == 1250)

        let smaller = MonitorScreen(uuid: "LAPTOP", frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 767))
        let kept = Geo.frame(size: size, savedCenter: center, on: smaller)
        #expect(smaller.visibleFrame.contains(kept))
        #expect(kept == CGRect(x: 980, y: 733, width: 300, height: 34))
    }

    /// One saved place per display: the bar opens on the display it was last put on, at its
    /// place there; else on the recording display.
    @Test func eachDisplayHasItsOwnPlace() {
        let phl = MonitorScreen(uuid: "PHL", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        let screens = [laptop, phl]
        let bottom = frame(.bottom, on: laptopDisplay, mainHeight: 982)
        let saved = ["PHL": CGPoint(x: 960, y: 1000), "LAPTOP": CGPoint(x: 200, y: 900)]

        let onPHL = Geo.openingFrame(size: size, screens: screens, saved: saved, lastScreenUUID: "PHL",
                                     recordingScreenUUID: "LAPTOP", frame: bottom)
        #expect(onPHL?.screenUUID == "PHL")
        #expect(onPHL?.rect == CGRect(x: -1110, y: 983, width: 300, height: 34))

        // The PHL unplugged: the laptop's own saved place.
        let unplugged = Geo.openingFrame(size: size, screens: [laptop], saved: saved, lastScreenUUID: "PHL",
                                         recordingScreenUUID: "LAPTOP", frame: bottom)
        #expect(unplugged?.screenUUID == "LAPTOP")
        #expect(unplugged?.rect == CGRect(x: 50, y: 883, width: 300, height: 34))

        // Nothing saved for the laptop: the default place in its strip.
        let fresh = Geo.openingFrame(size: size, screens: screens, saved: ["PHL": CGPoint(x: 960, y: 1000)],
                                     lastScreenUUID: nil, recordingScreenUUID: "LAPTOP", frame: bottom)
        #expect(fresh?.screenUUID == "LAPTOP")
        #expect(fresh?.rect == CGRect(x: 606, y: 880, width: 300, height: 34))

        // The recording display is not connected: the first screen, top-center (its frame is elsewhere).
        let noRecording = Geo.openingFrame(size: size, screens: [phl], saved: [:], lastScreenUUID: nil,
                                           recordingScreenUUID: "LAPTOP", frame: bottom)
        #expect(noRecording?.screenUUID == "PHL")
        #expect(noRecording?.rect == Geo.underMenuBar(size: size, on: phl))
        #expect(Geo.openingFrame(size: size, screens: [], saved: saved, lastScreenUUID: "PHL",
                                 recordingScreenUUID: nil, frame: nil) == nil)
    }

    @Test func aResizeKeepsTheCenter() {
        let rect = CGRect(x: 606, y: 880, width: 300, height: 34)
        let wider = Geo.resized(rect, to: CGSize(width: 400, height: 34), on: laptop)
        #expect(wider == CGRect(x: 556, y: 880, width: 400, height: 34))
        // At the right edge, a wider bar stays on screen.
        let atEdge = Geo.resized(CGRect(x: 1212, y: 880, width: 300, height: 34), to: CGSize(width: 400, height: 34), on: laptop)
        #expect(atEdge.maxX == 1512)
    }

    @Test func savedCentersRoundTrip() {
        let point = CGPoint(x: -1110.5, y: 983)
        #expect(Geo.decode(Geo.encode(point)) == point)
        #expect(Geo.decode(nil) == nil)
        #expect(Geo.decode([1]) == nil)
        #expect(Geo.decode([1, .nan]) == nil)
    }
}
