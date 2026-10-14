import CoreGraphics
import Foundation
import Testing
@testable import WindowTools

@Suite struct HotCornerTests {
    let laptop = CGSize(width: 1512, height: 982)
    let bottomFrame = CGRect(x: 4, y: 136, width: 1504, height: 846)
    let topFrame = CGRect(x: 4, y: 33, width: 1504, height: 846)

    /// Luke's Mac: bottom right is Quick Note (14), the others are not set.
    let luke = [HotCorner(position: .topLeft, action: 0), HotCorner(position: .topRight, action: 0),
                HotCorner(position: .bottomLeft, action: 0), HotCorner(position: .bottomRight, action: 14)]

    @Test func actionNames() {
        #expect(HotCorner(position: .bottomRight, action: 14).actionName == "Quick Note")
        #expect(HotCorner(position: .bottomLeft, action: 2).actionName == "Mission Control")
        #expect(HotCorner(position: .topLeft, action: 1).actionName == nil)
        // Disable Screen Saver shows nothing.
        #expect(HotCorner(position: .topLeft, action: 6).actionName == nil)
        #expect(HotCorner(position: .topLeft, action: 99).actionName == "a hot corner action")
        // With a key to hold, the pointer alone does nothing.
        #expect(!HotCorner(position: .bottomRight, action: 14, modifier: 1_048_576).triggersOnPointer)
    }

    @Test func theBottomFrameMeetsTheBottomCorners() {
        let found = HotCorner.atFrameEdge(luke, frameLocal: bottomFrame, displaySizePt: laptop)
        #expect(found == [HotCorner(position: .bottomRight, action: 14)])
        #expect(HotCorner.warning(for: found) == "The bottom right (Quick Note) hot corner is at the edge of the frame: "
            + "the pointer there shows it in the recording. Turn it off in System Settings > Desktop & Dock > Hot Corners, "
            + "or set a key to hold.")
    }

    @Test func theTopFrameKeepsClearOfTheBottomCorners() {
        #expect(HotCorner.atFrameEdge(luke, frameLocal: topFrame, displaySizePt: laptop).isEmpty)
        #expect(HotCorner.warning(for: []) == nil)
    }

    @Test func theWholeDisplayMeetsAllFourCorners() {
        let all = HotCorner.Position.allCases.map { HotCorner(position: $0, action: 2) }
        let found = HotCorner.atFrameEdge(all, frameLocal: CGRect(origin: .zero, size: laptop), displaySizePt: laptop)
        #expect(found.count == 4)
        #expect(HotCorner.warning(for: Array(found.prefix(2)))?.hasPrefix(
            "The top left (Mission Control), top right (Mission Control) hot corners are at the edge of the frame: the pointer there shows them") == true)
    }

    /// Reads the real preferences. Reads only; no prompt.
    @Test func liveReadGivesFourCorners() {
        #expect(HotCorner.current().map(\.position) == HotCorner.Position.allCases)
    }
}
