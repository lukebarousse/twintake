import CoreGraphics

/// Where the replay window opens, and how it stays on screen. Plain geometry, like
/// `CameraWindowGeometry`, but the window is not locked to 16:9 (its controls sit under the
/// picture). All rects are in AppKit coordinates (y up).
public enum ReplayWindowGeometry {
    /// The replay panel's title bar (a HUD utility panel: `NSPanel.contentRect(forFrameRect:styleMask:)`
    /// takes 19 pt off the frame).
    public static let titleBarHeight: CGFloat = 19
    /// The frame for a 16:9 picture 960 wide (960x540, no bars) with the controls under it and the
    /// title bar on top: 960x667.
    public static let defaultSize = CGSize(width: 960, height: 540 + ReplayControlsLayout.height + titleBarHeight)
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

extension ReplayWindowGeometry {
    /// The close button's inset from the window's left edge: the controls' side inset, so the X
    /// does not sit in the window's rounded corner.
    public static let closeButtonInset: CGFloat = ReplayControlsLayout.inset

    /// Where the title bar's close button goes (in the title bar's coordinates): `closeButtonInset`
    /// from the left edge, centered in the title bar's height.
    public static func closeButtonOrigin(button: CGSize, titleBar: CGSize) -> CGPoint {
        CGPoint(x: closeButtonInset, y: max(0, ((titleBar.height - button.height) / 2).rounded(.down)))
    }
}

/// Where the replay window's controls go, under the picture: the timeline, then two rows of
/// buttons. Plain geometry (AppKit coordinates, y up), so the spacing can be tested. Everything
/// keeps `inset` from the controls' left, right and bottom edges and from the picture above;
/// buttons sit `gap` apart, groups of buttons (transport, speeds, Live) `groupGap` apart.
public struct ReplayControlsLayout: Equatable, Sendable {
    public static let inset: CGFloat = 12
    public static let gap: CGFloat = 8
    public static let groupGap: CGFloat = 16
    public static let rowHeight: CGFloat = 24
    public static let timelineHeight: CGFloat = 20
    /// Text labels (the time, the status) are this tall, centered in their row.
    public static let labelHeight: CGFloat = 16
    /// The controls' height: the timeline and two rows, with their gaps and insets.
    public static let height: CGFloat = inset + timelineHeight + gap + rowHeight + gap + rowHeight + inset

    public var size: CGSize

    public init(size: CGSize) { self.size = size }

    /// The timeline across the top, `inset` from the picture and the sides.
    public var timeline: CGRect {
        CGRect(x: Self.inset, y: size.height - Self.inset - Self.timelineHeight,
               width: max(0, size.width - 2 * Self.inset), height: Self.timelineHeight)
    }

    /// The bottom edge of row 0 (under the timeline) or row 1 (the bottom row, `inset` above the edge).
    public func rowY(_ row: Int) -> CGFloat {
        timeline.minY - Self.gap - Self.rowHeight - CGFloat(row) * (Self.rowHeight + Self.gap)
    }

    /// The right edge the controls may reach.
    public var right: CGFloat { size.width - Self.inset }

    /// Frames for `groups` of widths placed from the left inset in `row`: `gap` apart inside a
    /// group, `groupGap` between groups. `end` is the right edge of the last one (the inset when
    /// there is none).
    public func fromLeft(_ groups: [[CGFloat]], row: Int) -> (frames: [[CGRect]], end: CGFloat) {
        var x = Self.inset
        var end = Self.inset
        var frames: [[CGRect]] = []
        for group in groups {
            guard !group.isEmpty else {
                frames.append([])
                continue
            }
            if end > Self.inset { x = end + Self.groupGap }
            var placed: [CGRect] = []
            for (i, width) in group.enumerated() {
                if i > 0 { x += Self.gap }
                placed.append(CGRect(x: x, y: rowY(row), width: width, height: Self.rowHeight))
                x += width
            }
            end = x
            frames.append(placed)
        }
        return (frames, end)
    }

    /// Frames for `widths` placed from the right inset leftward in `row`, `gap` apart: the first
    /// width is the rightmost. `start` is the left edge of the last one (`right` when there is none).
    public func fromRight(_ widths: [CGFloat], row: Int) -> (frames: [CGRect], start: CGFloat) {
        var x = right
        var frames: [CGRect] = []
        for (i, width) in widths.enumerated() {
            if i > 0 { x -= Self.gap }
            x -= width
            frames.append(CGRect(x: x, y: rowY(row), width: width, height: Self.rowHeight))
        }
        return (frames, x)
    }

    /// A text label's frame in `row` at `x`, centered in the row's height.
    public func label(x: CGFloat, width: CGFloat, row: Int) -> CGRect {
        CGRect(x: x, y: rowY(row) + ((Self.rowHeight - Self.labelHeight) / 2).rounded(.down), width: max(0, width),
               height: Self.labelHeight)
    }
}
