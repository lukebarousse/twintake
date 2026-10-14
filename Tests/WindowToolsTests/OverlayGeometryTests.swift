import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

@Suite struct OverlayGeometryTests {
    /// Overlap area of two rects (0 when they only touch).
    func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    func rect(_ pieces: [OverlayPiece], _ edge: OverlayEdge) -> CGRect? { pieces.first { $0.edge == edge }?.rect }

    @Test func fourDimRectsAroundACenteredFrame() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let dims = OverlayGeometry.dimRects(frame: frame, area: area)
        #expect(dims.count == 4)
        #expect(rect(dims, .top) == CGRect(x: 0, y: 0, width: 1000, height: 50))
        #expect(rect(dims, .bottom) == CGRect(x: 0, y: 650, width: 1000, height: 150))
        #expect(rect(dims, .left) == CGRect(x: 0, y: 50, width: 100, height: 600))
        #expect(rect(dims, .right) == CGRect(x: 900, y: 50, width: 100, height: 600))
        // The dims and the frame tile the area exactly: no gaps, no overlap with the frame.
        let dimArea = dims.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(dimArea + frame.width * frame.height == area.width * area.height)
        for d in dims { #expect(overlap(d.rect, frame) == 0) }
    }

    @Test func laptopFrameUnderMenuBarLeavesNoTopDim() {
        let d = Fixtures.laptop
        let frame = d.globalFrameRect(for: .laptop16x9)
        let area = OverlayGeometry.dimArea(display: d, coverMenuBar: false)
        #expect(area == CGRect(x: 0, y: 37, width: 1512, height: 945))
        let dims = OverlayGeometry.dimRects(frame: frame, area: area)
        #expect(dims.map(\.edge) == [.bottom, .left, .right])
        #expect(rect(dims, .bottom) == CGRect(x: 0, y: 883, width: 1512, height: 99))
        #expect(rect(dims, .left) == CGRect(x: 0, y: 37, width: 4, height: 846))
        #expect(rect(dims, .right) == CGRect(x: 1508, y: 37, width: 4, height: 846))
    }

    @Test func frameOnSecondaryDisplayUsesGlobalCoordinates() {
        let m = Fixtures.monitorAbove
        let frame = m.globalFrameRect(for: .laptop16x9) // (4, -1056, 1504, 846)
        let dims = OverlayGeometry.dimRects(frame: frame, area: OverlayGeometry.dimArea(display: m, coverMenuBar: false))
        #expect(rect(dims, .left) == CGRect(x: -204, y: -1056, width: 208, height: 846))
        #expect(rect(dims, .right) == CGRect(x: 1508, y: -1056, width: 208, height: 846))
        #expect(rect(dims, .bottom) == CGRect(x: -204, y: -210, width: 1920, height: 210))
        for p in dims { #expect(m.boundsGlobal.contains(p.rect)) }
    }

    @Test func frameOffTheAreaDimsEverything() {
        let area = CGRect(x: 0, y: 0, width: 100, height: 100)
        let dims = OverlayGeometry.dimRects(frame: CGRect(x: 500, y: 500, width: 10, height: 10), area: area)
        #expect(dims == [OverlayPiece(edge: .top, rect: area)])
    }

    @Test func borderSitsJustOutsideTheFrame() {
        let frame = CGRect(x: 4, y: 37, width: 1504, height: 846)
        let borders = OverlayGeometry.borderRects(frame: frame, width: 2)
        #expect(rect(borders, .top) == CGRect(x: 2, y: 35, width: 1508, height: 2))
        #expect(rect(borders, .bottom) == CGRect(x: 2, y: 883, width: 1508, height: 2))
        #expect(rect(borders, .left) == CGRect(x: 2, y: 37, width: 2, height: 846))
        #expect(rect(borders, .right) == CGRect(x: 1508, y: 37, width: 2, height: 846))
        for b in borders { #expect(overlap(b.rect, frame) == 0) }
    }

    @Test func panelsWithoutMenuBarCover() {
        let d = Fixtures.laptop
        let panels = OverlayGeometry.panels(frame: d.globalFrameRect(for: .laptop16x9), display: d,
                                            coverMenuBar: false, borderWidth: 2)
        #expect(panels.count == 3)
        #expect(panels.allSatisfy { !$0.coversMenuBar })
        let left = panels.first { $0.edge == .left }
        #expect(left?.borderRectsLocal == [CGRect(x: 2, y: 0, width: 2, height: 846)])
        let bottom = panels.first { $0.edge == .bottom }
        #expect(bottom?.borderRectsLocal == [CGRect(x: 2, y: 0, width: 1508, height: 2)])
        let right = panels.first { $0.edge == .right }
        #expect(right?.borderRectsLocal == [CGRect(x: 0, y: 0, width: 2, height: 846)])
    }

    @Test func panelsWithMenuBarCoverAddTheMenuBarStrip() {
        let d = Fixtures.laptop
        let panels = OverlayGeometry.panels(frame: d.globalFrameRect(for: .laptop16x9), display: d,
                                            coverMenuBar: true, borderWidth: 2)
        #expect(panels.count == 4)
        let bar = panels.first { $0.coversMenuBar }
        #expect(bar?.rectGlobal == CGRect(x: 0, y: 0, width: 1512, height: 37))
        // The top border edge lands inside the menu bar strip.
        #expect(bar?.borderRectsLocal == [CGRect(x: 2, y: 35, width: 1508, height: 2)])
    }

    @Test func wholeDisplayFrameNeedsNoPanels() {
        let m = Fixtures.monitorRight
        let frame = m.globalFrameRect(for: .fullDisplay)
        #expect(OverlayGeometry.panels(frame: frame, display: m, coverMenuBar: false, borderWidth: 2).isEmpty)
        #expect(OverlayGeometry.panels(frame: frame, display: m, coverMenuBar: true, borderWidth: 2).isEmpty)
    }

    @Test func panelsNeverCoverTheFrame() {
        for d in [Fixtures.laptop, Fixtures.monitorLeft, Fixtures.monitorRight, Fixtures.monitorAbove] {
            for cover in [false, true] {
                let frame = d.globalFrameRect(for: .laptop16x9)
                for p in OverlayGeometry.panels(frame: frame, display: d, coverMenuBar: cover, borderWidth: 3) {
                    #expect(overlap(p.rectGlobal, frame) == 0)
                    #expect(d.boundsGlobal.contains(p.rectGlobal))
                }
            }
        }
    }

    @Test func panelAppKitRectOnMonitorRight() throws {
        let m = Fixtures.monitorRight
        let panels = OverlayGeometry.panels(frame: m.globalFrameRect(for: .laptop16x9), display: m,
                                            coverMenuBar: false, borderWidth: 2)
        let bottom = try #require(panels.first { $0.edge == .bottom })
        // Global (1512, 772, 1920, 210) is the bottom strip of the monitor: AppKit y 0...210.
        #expect(bottom.rectGlobal == CGRect(x: 1512, y: 772, width: 1920, height: 210))
        #expect(FrameGeometry.appKitRect(fromGlobal: bottom.rectGlobal, mainDisplayHeight: 982)
                == CGRect(x: 1512, y: 0, width: 1920, height: 210))
    }
}
