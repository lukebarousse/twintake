import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite struct FrameAnchorTests {
    let laptop = CGSize(width: 1512, height: 982)
    let laptopFrame = ScreenFramePreset.laptop16x9.sizing

    @Test func topIsTheDefaultAndStaysUnderTheMenuBar() {
        let implicit = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: laptop, topInsetPt: 37)
        let top = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: laptop, topInsetPt: 37, anchor: .top)
        #expect(implicit == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(top == implicit)
    }

    @Test func bottomFrameOnTheLaptopIsFlushWithTheBottomEdge() {
        // 14" MacBook Pro: 1512x982 pt, 37 pt menu bar.
        let r = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: laptop, topInsetPt: 37, anchor: .bottom)
        #expect(r == CGRect(x: 4, y: 136, width: 1504, height: 846))
        #expect(r.maxY == laptop.height)
        #expect(FrameGeometry.outputPixels(forPoints: r.size, scale: 2) == PixelSize(width: 3008, height: 1692))
    }

    @Test func bottomFrameOnAMonitorIsCentered() {
        let r = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: CGSize(width: 1920, height: 1080),
                                        topInsetPt: 24, anchor: .bottom)
        #expect(r == CGRect(x: 208, y: 234, width: 1504, height: 846))
    }

    @Test func shrunkFrameKeepsItsSizeAndNeverCoversTheMenuBar() {
        let display = CGSize(width: 1280, height: 800)
        let top = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: display, topInsetPt: 25, anchor: .top)
        let bottom = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: display, topInsetPt: 25, anchor: .bottom)
        #expect(bottom.size == top.size)
        #expect(bottom.minX == top.minX)
        #expect(bottom.maxY == 800)
        #expect(bottom.minY >= 25)
    }

    @Test func frameThatFillsTheHeightSitsUnderTheMenuBarForBothAnchors() {
        // 1504x846 under a 37 pt menu bar on a display exactly 883 pt high: no room to move.
        let display = CGSize(width: 1512, height: 883)
        let bottom = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: display, topInsetPt: 37, anchor: .bottom)
        #expect(bottom == CGRect(x: 4, y: 37, width: 1504, height: 846))
    }

    @Test func wholeDisplayIgnoresTheAnchor() {
        let size = CGSize(width: 1920, height: 1080)
        let r = FrameGeometry.frameRect(sizing: .fullDisplay, displaySizePt: size, topInsetPt: 30, anchor: .bottom)
        #expect(r == CGRect(origin: .zero, size: size))
    }

    @Test func roomAboveTheFrame() {
        let bottom = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: laptop, topInsetPt: 37, anchor: .bottom)
        let top = FrameGeometry.frameRect(sizing: laptopFrame, displaySizePt: laptop, topInsetPt: 37, anchor: .top)
        // 99 pt above the bottom frame: room for a 28, 38 or 52 pt toolbar.
        #expect(FrameGeometry.roomAbove(frame: bottom, topInsetPt: 37) == 99)
        #expect(FrameGeometry.roomAbove(frame: top, topInsetPt: 37) == 0)
    }

    @Test func anchorIsCodableAsItsRawValue() throws {
        #expect(FrameAnchor.allCases == [.top, .bottom])
        let json = try JSONEncoder().encode([FrameAnchor.bottom])
        #expect(String(decoding: json, as: UTF8.self) == #"["bottom"]"#)
        #expect(try JSONDecoder().decode([FrameAnchor].self, from: Data(#"["top"]"#.utf8)) == [.top])
        #expect(FrameAnchor(rawValue: "middle") == nil)
        #expect(!FrameAnchor.bottom.label.isEmpty)
    }
}
