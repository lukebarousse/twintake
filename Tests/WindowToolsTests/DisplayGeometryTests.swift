import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

/// Fake displays with the values of Luke's desk.
enum Fixtures {
    /// 14" MacBook Pro default: 1512x982 pt at 2x, notch, 37 pt menu bar, main display.
    static let laptop = DisplayInfo(
        id: 1, uuid: "LAPTOP", name: "Built-in Retina Display", isBuiltin: true, isMain: true,
        boundsGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, menuBarHeightPt: 37,
        refreshRate: 120, hasNotch: true)

    /// Philips 4K at "looks like 1920x1080", placed relative to the laptop.
    static func monitor(at origin: CGPoint, isMain: Bool = false, menuBar: CGFloat = 24) -> DisplayInfo {
        DisplayInfo(id: 2, uuid: "PHILIPS", name: "PHL 279P1", isBuiltin: false, isMain: isMain,
                    boundsGlobal: CGRect(origin: origin, size: CGSize(width: 1920, height: 1080)), scale: 2,
                    menuBarHeightPt: menuBar, refreshRate: 60)
    }

    /// Right of the laptop, bottom edges aligned.
    static let monitorRight = monitor(at: CGPoint(x: 1512, y: -98))
    /// Left of the laptop, top edges aligned.
    static let monitorLeft = monitor(at: CGPoint(x: -1920, y: 0))
    /// Above the laptop, centered.
    static let monitorAbove = monitor(at: CGPoint(x: -204, y: -1080))
}

@Suite struct DisplayInfoTests {
    @Test func laptopFrameIsExact16x9UnderMenuBar() {
        let d = Fixtures.laptop
        #expect(d.frameRect(for: .laptop16x9) == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(d.outputPixels(for: .laptop16x9) == PixelSize(width: 3008, height: 1692))
        #expect(d.globalFrameRect(for: .laptop16x9) == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(!d.isSixteenByNine)
        #expect(d.defaultPreset == .laptop16x9)
    }

    @Test func laptopWholeDisplayIncludesMenuBar() {
        let d = Fixtures.laptop
        #expect(d.frameRect(for: .fullDisplay) == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(d.outputPixels(for: .fullDisplay) == PixelSize(width: 3024, height: 1964))
        #expect(d.sizePx == PixelSize(width: 3024, height: 1964))
    }

    @Test func monitorDefaultsToWholeDisplay() {
        let d = Fixtures.monitorRight
        #expect(d.isSixteenByNine)
        #expect(d.defaultPreset == .fullDisplay)
        #expect(d.frameRect(for: .fullDisplay) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(d.globalFrameRect(for: .fullDisplay) == CGRect(x: 1512, y: -98, width: 1920, height: 1080))
        #expect(d.outputPixels(for: .fullDisplay) == PixelSize(width: 3840, height: 2160))
    }

    @Test func laptopPresetOnMonitorIsCenteredUnderMenuBar() {
        let d = Fixtures.monitorRight
        #expect(d.frameRect(for: .laptop16x9) == CGRect(x: 208, y: 24, width: 1504, height: 846))
        #expect(d.globalFrameRect(for: .laptop16x9) == CGRect(x: 1720, y: -74, width: 1504, height: 846))
        #expect(d.localRect(fromGlobal: d.globalFrameRect(for: .laptop16x9)) == d.frameRect(for: .laptop16x9))
    }

    @Test func manifestScreenBlock() {
        let s = Fixtures.laptop.screenInfo(for: .laptop16x9)
        #expect(s.capture == "region")
        #expect(s.displayId == 1)
        #expect(s.preset == "laptop-16x9")
        #expect(s.frameRectPt == PointRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(s.outputPx == PixelSize(width: 3008, height: 1692))
        #expect(s.scale == 2)
    }

    @Test func sixteenByNineDetection() {
        func display(_ w: CGFloat, _ h: CGFloat) -> DisplayInfo {
            DisplayInfo(id: 9, uuid: "X", name: "X", isBuiltin: false, isMain: false,
                        boundsGlobal: CGRect(x: 0, y: 0, width: w, height: h), scale: 1, menuBarHeightPt: 24, refreshRate: 60)
        }
        #expect(display(2560, 1440).isSixteenByNine)
        #expect(display(3840, 2160).isSixteenByNine)
        #expect(display(1366, 768).isSixteenByNine) // 1.7786, a common "16:9" laptop panel
        #expect(!display(1728, 1117).isSixteenByNine) // 16" MacBook Pro
        #expect(!display(2560, 1600).isSixteenByNine) // 16:10
        #expect(!display(3440, 1440).isSixteenByNine) // ultrawide
        #expect(!display(100, 0).isSixteenByNine)
    }

    @Test func menuBarHeightFromScreenFrames() {
        // Notch laptop, menu bar shown: frame top 982, visible top 945.
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 982, visibleFrameMaxY: 945, safeAreaTop: 32,
                                          statusBarThickness: 24, showsMenuBar: true) == 37)
        // Menu bar hidden on the notch laptop: fall back to the safe area.
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 982, visibleFrameMaxY: 982, safeAreaTop: 32,
                                          statusBarThickness: 24, showsMenuBar: true) == 32)
        // Menu bar hidden, no notch: status bar thickness.
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 1080, visibleFrameMaxY: 1080, safeAreaTop: 0,
                                          statusBarThickness: 24, showsMenuBar: true) == 24)
        // Luke's desk on macOS 27.2, lid closed: main Philips reports a 30 pt menu bar...
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 1080, visibleFrameMaxY: 1050, safeAreaTop: 0,
                                          statusBarThickness: 22, showsMenuBar: true) == 30)
        // ...and the second Philips has none ("Displays have separate Spaces" off).
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 1080, visibleFrameMaxY: 1080, safeAreaTop: 0,
                                          statusBarThickness: 22, showsMenuBar: false) == 0)
        // Lid open with a Philips as main display: the notched built-in display has no menu bar,
        // but the frame still starts below the notch.
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 982, visibleFrameMaxY: 982, safeAreaTop: 32,
                                          statusBarThickness: 24, showsMenuBar: false) == 32)
        // A gap smaller than the notch never puts the frame under the notch.
        #expect(DisplayInfo.menuBarHeight(frameMaxY: 982, visibleFrameMaxY: 958, safeAreaTop: 32,
                                          statusBarThickness: 24, showsMenuBar: true) == 32)
    }

    @Test func displayContainingPicksLargestOverlap() {
        let all = [Fixtures.laptop, Fixtures.monitorRight]
        let mostlyOnMonitor = CGRect(x: 1400, y: 100, width: 800, height: 600)
        #expect(DisplayInfo.display(containing: mostlyOnMonitor, in: all)?.uuid == "PHILIPS")
        let mostlyOnLaptop = CGRect(x: 1000, y: 100, width: 800, height: 600)
        #expect(DisplayInfo.display(containing: mostlyOnLaptop, in: all)?.uuid == "LAPTOP")
        #expect(DisplayInfo.display(containing: CGRect(x: 9000, y: 9000, width: 10, height: 10), in: all) == nil)
    }
}

/// Global CG (top-left, y down) <-> AppKit (bottom-left, y up) for multi-display layouts.
@Suite struct MultiDisplayConversionTests {
    let laptopHeight: CGFloat = 982

    @Test func monitorRightOfLaptop() {
        let m = Fixtures.monitorRight
        let appKit = FrameGeometry.appKitRect(fromGlobal: m.boundsGlobal, mainDisplayHeight: laptopHeight)
        #expect(appKit == CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let frame = FrameGeometry.appKitRect(fromGlobal: m.globalFrameRect(for: .laptop16x9), mainDisplayHeight: laptopHeight)
        // Top of the monitor is AppKit y 1080; frame top is 24 pt lower.
        #expect(frame == CGRect(x: 1720, y: 1080 - 24 - 846, width: 1504, height: 846))
        #expect(FrameGeometry.globalRect(fromAppKit: frame, mainDisplayHeight: laptopHeight)
                == m.globalFrameRect(for: .laptop16x9))
    }

    @Test func monitorLeftOfLaptop() {
        let m = Fixtures.monitorLeft
        let appKit = FrameGeometry.appKitRect(fromGlobal: m.boundsGlobal, mainDisplayHeight: laptopHeight)
        #expect(appKit == CGRect(x: -1920, y: -98, width: 1920, height: 1080))
        let frame = m.globalFrameRect(for: .fullDisplay)
        #expect(frame == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        #expect(FrameGeometry.globalRect(fromAppKit: appKit, mainDisplayHeight: laptopHeight) == m.boundsGlobal)
    }

    @Test func monitorAboveLaptop() {
        let m = Fixtures.monitorAbove
        let appKit = FrameGeometry.appKitRect(fromGlobal: m.boundsGlobal, mainDisplayHeight: laptopHeight)
        #expect(appKit == CGRect(x: -204, y: 982, width: 1920, height: 1080))
        let frameGlobal = m.globalFrameRect(for: .laptop16x9)
        #expect(frameGlobal == CGRect(x: 4, y: -1056, width: 1504, height: 846))
        let frame = FrameGeometry.appKitRect(fromGlobal: frameGlobal, mainDisplayHeight: laptopHeight)
        #expect(frame == CGRect(x: 4, y: 1192, width: 1504, height: 846))
    }

    @Test func monitorIsMainAndLaptopBelow() {
        // Lid open, monitor set as main display, laptop below it.
        let monitorHeight: CGFloat = 1080
        var laptop = Fixtures.laptop
        laptop.isMain = false
        laptop.boundsGlobal = CGRect(x: 204, y: 1080, width: 1512, height: 982)
        let frameGlobal = laptop.globalFrameRect(for: .laptop16x9)
        #expect(frameGlobal == CGRect(x: 208, y: 1117, width: 1504, height: 846))
        let appKit = FrameGeometry.appKitRect(fromGlobal: frameGlobal, mainDisplayHeight: monitorHeight)
        #expect(appKit == CGRect(x: 208, y: -883, width: 1504, height: 846))
        #expect(FrameGeometry.appKitRect(fromGlobal: laptop.boundsGlobal, mainDisplayHeight: monitorHeight)
                == CGRect(x: 204, y: -982, width: 1512, height: 982))
    }
}

/// Reads the real display list. Discovery only: no capture, no permission prompt.
@Suite struct LiveDisplayTests {
    @MainActor @Test func liveDisplaysAreConsistent() {
        let all = Displays.all()
        guard !all.isEmpty else { return } // headless machine
        #expect(all.filter(\.isMain).count <= 1)
        if let main = all.first(where: \.isMain) {
            #expect(all.first == main)
            #expect(main.boundsGlobal.origin == .zero)
            #expect(Displays.mainDisplayHeight == main.sizePt.height)
        }
        for d in all {
            #expect(!d.uuid.isEmpty)
            #expect(d.scale >= 1)
            #expect(d.menuBarHeightPt >= 0 && d.menuBarHeightPt < 100)
            #expect(Displays.find(uuid: d.uuid)?.id == d.id)
        }
    }
}
