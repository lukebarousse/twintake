import Foundation
import Testing
@testable import RecorderCore

@Suite struct SnappedWindowTests {
    @Test func newFieldsUseSnakeCaseAndStayOptional() throws {
        var screen = ScreenInfo(capture: "window", displayId: 1, displayName: "Built-in", scale: 2, preset: "laptop-16x9",
                                frameRectPt: PointRect(x: 4, y: 37, width: 1504, height: 846),
                                outputPx: PixelSize(width: 3008, height: 1692))
        screen.snappedWindow = SnappedWindow(appName: "Safari", bundleId: "com.apple.Safari", title: "Docs",
                                             requestedPt: PointSize(width: 1504, height: 846),
                                             achievedPt: PointSize(width: 1504, height: 846),
                                             windowId: 4242, achievedFramePt: PointRect(x: 4, y: 37, width: 1504, height: 846))
        let json = String(decoding: try SessionManifest.encoder().encode(screen), as: UTF8.self)
        #expect(json.contains("\"window_id\" : 4242"))
        #expect(json.contains("\"achieved_frame_pt\""))
        let back = try SessionManifest.decoder().decode(ScreenInfo.self, from: Data(json.utf8))
        #expect(back.snappedWindow == screen.snappedWindow)

        // Files written before these fields existed still decode.
        let old = Data(#"{"app_name":"Safari","requested_pt":{"width":1504,"height":846},"achieved_pt":{"width":1504,"height":846}}"#.utf8)
        let decoded = try SessionManifest.decoder().decode(SnappedWindow.self, from: old)
        #expect(decoded.windowId == nil && decoded.achievedFramePt == nil)
    }

    @Test func hostModelIsReadable() {
        let model = HostInfo.current().model
        #expect(!model.isEmpty && !model.contains("\0"))
    }
}
