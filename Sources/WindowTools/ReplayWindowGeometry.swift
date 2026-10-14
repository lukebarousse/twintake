import CoreGraphics

/// Where the replay window opens, and how it stays on screen. Plain geometry, like
/// `CameraWindowGeometry`, but the window is not locked to 16:9 (its controls sit under the
/// picture). All rects are in AppKit coordinates (y up).
public enum ReplayWindowGeometry {
    /// A 16:9 picture 960 wide with the controls under it.
    public static let defaultSize = CGSize(width: 960, height: 640)
    public static let minSize = CGSize(width: 480, height: 360)
    /// Gap between the window and the edge of the visible frame for the default place.
    public static let margin: CGFloat = 24

    /// `rect` moved (and shrunk when needed, never under `minSize` unless the screen is smaller)
    /// to lie inside the screen's visible frame.
    public static func clamp(_ rect: CGRect, into screen: MonitorScreen) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(max(rect.width, minSize.width), visible.width)
        let height = min(max(rect.height, minSize.height), visible.height)
        let x = min(max(rect.minX, visible.minX), visible.maxX - width)
        let y = min(max(rect.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Keeps a shown window on screen after a display change or a drag. Nil when its display went away.
    public static func clamped(_ rect: CGRect, screens: [MonitorScreen]) -> CGRect? {
        CameraWindowGeometry.screen(containing: rect, in: screens).map { clamp(rect, into: $0) }
    }

    /// `size` at the top-right of the screen's visible frame, `margin` in, shrunk to fit.
    public static func topRight(size: CGSize, on screen: MonitorScreen) -> CGRect {
        let visible = screen.visibleFrame
        let rect = CGRect(x: visible.maxX - margin - size.width, y: visible.maxY - margin - size.height,
                          width: size.width, height: size.height)
        return clamp(rect, into: screen)
    }

    /// Where the window opens:
    /// 1. its saved place on the screen it was last put on, when that screen is connected;
    /// 2. else its saved place on the default screen (one that does not hold the recording frame);
    /// 3. else the top-right of the default screen at `defaultSize`.
    public static func openingFrame(screens: [MonitorScreen], saved: [String: CGRect], lastScreenUUID: String?,
                                    frameDisplayUUID: String?) -> CGRect? {
        if let uuid = lastScreenUUID, let screen = screens.first(where: { $0.uuid == uuid }), let place = saved[uuid] {
            return clamp(CameraWindowGeometry.global(place, on: screen), into: screen)
        }
        guard let screen = CameraWindowGeometry.defaultScreen(screens, frameDisplayUUID: frameDisplayUUID) else { return nil }
        if let place = saved[screen.uuid] {
            return clamp(CameraWindowGeometry.global(place, on: screen), into: screen)
        }
        return topRight(size: defaultSize, on: screen)
    }

    /// `content` scaled to fit inside `area`, centered (the screen picture with bars).
    public static func fitted(_ content: CGSize, in area: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / content.width, area.height / content.height)
        let size = CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
        return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Where the camera picture sits over the screen picture (`area`: the screen picture's rect):
    /// the bottom-right corner, about a quarter of its width, 16:9, like the camera window.
    public static func cameraInset(in area: CGRect, share: CGFloat = 0.26, inset: CGFloat = 10) -> CGRect {
        let width = (area.width * share).rounded()
        let height = (width * 9 / 16).rounded()
        return CGRect(x: area.maxX - inset - width, y: area.minY + inset, width: width, height: height)
    }
}
