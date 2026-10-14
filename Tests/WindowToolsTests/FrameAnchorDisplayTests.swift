import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

/// The bottom frame on Luke's displays (see `Fixtures`).
@Suite struct FrameAnchorDisplayTests {
    @Test func laptopBottomFrame() {
        let d = Fixtures.laptop
        #expect(d.frameRect(for: .laptop16x9, anchor: .bottom) == CGRect(x: 4, y: 136, width: 1504, height: 846))
        #expect(d.globalFrameRect(for: .laptop16x9, anchor: .bottom) == CGRect(x: 4, y: 136, width: 1504, height: 846))
        #expect(d.outputPixels(for: .laptop16x9) == PixelSize(width: 3008, height: 1692))
        // Old callers keep the top frame.
        #expect(d.frameRect(for: .laptop16x9) == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(d.frameRect(for: .fullDisplay, anchor: .bottom) == d.frameRect(for: .fullDisplay))
    }

    @Test func manifestScreenBlockCarriesTheBottomFrame() {
        let s = Fixtures.laptop.screenInfo(for: .laptop16x9, anchor: .bottom)
        #expect(s.frameRectPt == PointRect(x: 4, y: 136, width: 1504, height: 846))
        #expect(s.outputPx == PixelSize(width: 3008, height: 1692))
        #expect(Fixtures.laptop.screenInfo(for: .laptop16x9).frameRectPt == PointRect(x: 4, y: 37, width: 1504, height: 846))
    }

    @Test func monitorBottomFrameInGlobalPoints() {
        let m = Fixtures.monitorRight // origin (1512, -98), bottom edges aligned with the laptop
        #expect(m.frameRect(for: .laptop16x9, anchor: .bottom) == CGRect(x: 208, y: 234, width: 1504, height: 846))
        #expect(m.globalFrameRect(for: .laptop16x9, anchor: .bottom) == CGRect(x: 1720, y: 136, width: 1504, height: 846))
        #expect(m.localRect(fromGlobal: m.globalFrameRect(for: .laptop16x9, anchor: .bottom))
                == m.frameRect(for: .laptop16x9, anchor: .bottom))
    }

    @Test func laptopBelowAMainMonitor() {
        var laptop = Fixtures.laptop
        laptop.isMain = false
        laptop.boundsGlobal = CGRect(x: 204, y: 1080, width: 1512, height: 982)
        let frame = laptop.globalFrameRect(for: .laptop16x9, anchor: .bottom)
        #expect(frame == CGRect(x: 208, y: 1216, width: 1504, height: 846))
        #expect(frame.maxY == laptop.boundsGlobal.maxY)
        #expect(FrameGeometry.appKitRect(fromGlobal: frame, mainDisplayHeight: 1080) == CGRect(x: 208, y: -982, width: 1504, height: 846))
        #expect(laptop.windowTopLimitGlobal == 1117)
    }

    @Test func windowTopLimitIsTheMenuBarBottom() {
        #expect(Fixtures.laptop.windowTopLimitGlobal == 37)
        #expect(Fixtures.monitorRight.windowTopLimitGlobal == -74)
        #expect(Fixtures.monitorAbove.windowTopLimitGlobal == -1056)
        let noBar = Fixtures.monitor(at: CGPoint(x: 1512, y: 0), menuBar: 0)
        #expect(noBar.windowTopLimitGlobal == 0)
    }

    @Test func overlayAroundTheBottomFrameHasNoBottomPanel() {
        let d = Fixtures.laptop
        let frame = d.globalFrameRect(for: .laptop16x9, anchor: .bottom)
        let dims = OverlayGeometry.dimRects(frame: frame, area: OverlayGeometry.dimArea(display: d, coverMenuBar: false))
        #expect(dims.map(\.edge) == [.top, .left, .right])
        #expect(dims.first { $0.edge == .top }?.rect == CGRect(x: 0, y: 37, width: 1512, height: 99))
        #expect(dims.first { $0.edge == .left }?.rect == CGRect(x: 0, y: 136, width: 4, height: 846))
        let panels = OverlayGeometry.panels(frame: frame, display: d, coverMenuBar: false, borderWidth: 2)
        for p in panels {
            let i = p.rectGlobal.intersection(frame)
            #expect(i.isNull || i.width == 0 || i.height == 0)
        }
        // The top panel draws the border strip along the frame's top edge.
        let top = panels.first { $0.edge == .top }
        #expect(top?.borderRectsLocal.contains(CGRect(x: 2, y: 97, width: 1508, height: 2)) == true)
    }
}
