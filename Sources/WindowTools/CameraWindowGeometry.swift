import CoreGraphics

/// One screen as the camera window sees it. AppKit coordinates: origin at the bottom-left of the
/// main display, y up (`NSScreen.frame` and `NSScreen.visibleFrame`).
public struct MonitorScreen: Sendable, Equatable {
    /// `DisplayInfo.uuid`: stable across launches, so saved places are keyed by it.
    public var uuid: String
    public var frame: CGRect
    /// The frame minus the menu bar and the Dock.
    public var visibleFrame: CGRect

    public init(uuid: String, frame: CGRect, visibleFrame: CGRect) {
        self.uuid = uuid; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

/// Where the camera window opens, how it resizes and how it stays on screen. Plain geometry, so
/// it can be tested without a window. All rects are in AppKit coordinates (y up).
public enum CameraWindowGeometry {
    /// The camera picture is 16:9; the window keeps that shape.
    public static let aspect: CGFloat = 16.0 / 9.0
    public static let minSize = CGSize(width: 240, height: 135)
    /// Gap between the window and the edge of the visible frame for the default place.
    public static let margin: CGFloat = 16

    /// The sizes in the window's menu.
    public enum SizePreset: String, CaseIterable, Sendable {
        case small, medium, large

        public var size: CGSize {
            switch self {
            case .small: CGSize(width: 320, height: 180)
            case .medium: CGSize(width: 480, height: 270)
            case .large: CGSize(width: 640, height: 360)
            }
        }

        public var title: String {
            switch self {
            case .small: "Small (320×180)"
            case .medium: "Medium (480×270)"
            case .large: "Large (640×360)"
            }
        }
    }

    /// The corner a resize drag moves. The opposite corner stays where it is.
    public enum Corner: Sendable, Equatable {
        case bottomLeft, bottomRight, topLeft, topRight

        var isRight: Bool { self == .bottomRight || self == .topRight }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    // MARK: - Size

    /// A 16:9 size `width` wide, at least `minSize`, and no larger than `limit` (when given).
    public static func lockedSize(width: CGFloat, limit: CGSize? = nil) -> CGSize {
        var w = max(width, minSize.width)
        // A screen smaller than `minSize` wins over the minimum.
        if let limit, limit.width > 0, limit.height > 0 { w = min(w, limit.width, limit.height * aspect) }
        return CGSize(width: w.rounded(), height: (w / aspect).rounded())
    }

    // MARK: - Screens

    /// The screen that holds the largest part of `rect`, or nil when `rect` is on no screen.
    public static func screen(containing rect: CGRect, in screens: [MonitorScreen]) -> MonitorScreen? {
        var best: (screen: MonitorScreen, area: CGFloat)?
        for screen in screens {
            let i = screen.frame.intersection(rect)
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            let area = i.width * i.height
            if best == nil || area > best!.area { best = (screen, area) }
        }
        return best?.screen
    }

    /// The screen the window opens on when no saved place applies: the first screen that does not
    /// hold the recording frame, so the window never sits over what is recorded; else the frame's
    /// screen; else the first screen (the main display comes first).
    public static func defaultScreen(_ screens: [MonitorScreen], frameDisplayUUID: String?) -> MonitorScreen? {
        guard let frameDisplayUUID else { return screens.first }
        return screens.first { $0.uuid != frameDisplayUUID } ?? screens.first { $0.uuid == frameDisplayUUID } ?? screens.first
    }

    /// `size` at the bottom-right of the screen's visible frame, `margin` in. Shrinks to fit.
    public static func bottomRight(size: CGSize, on screen: MonitorScreen) -> CGRect {
        let visible = screen.visibleFrame
        let room = CGSize(width: max(0, visible.width - 2 * margin), height: max(0, visible.height - 2 * margin))
        let fitted = lockedSize(width: size.width, limit: room)
        return CGRect(x: visible.maxX - margin - fitted.width, y: visible.minY + margin,
                      width: fitted.width, height: fitted.height)
    }

    /// A window rect as saved for `screen`: offset from the screen's bottom-left corner, and size.
    /// Saved this way, a place survives a new display arrangement.
    public static func local(_ rect: CGRect, on screen: MonitorScreen) -> CGRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    /// The window rect for a place saved with `local(_:on:)`.
    public static func global(_ saved: CGRect, on screen: MonitorScreen) -> CGRect {
        saved.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    /// `rect` moved (and shrunk, 16:9 kept, when needed) to lie inside the screen's visible frame.
    public static func clamp(_ rect: CGRect, into screen: MonitorScreen) -> CGRect {
        let visible = screen.visibleFrame
        let size = lockedSize(width: rect.width, limit: visible.size)
        let x = min(max(rect.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(rect.minY, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Keeps a shown window on screen after a display change or a drag: inside the visible frame of
    /// the screen that holds most of it. Nil when it is on no screen anymore (its display went away).
    public static func clamped(_ rect: CGRect, screens: [MonitorScreen]) -> CGRect? {
        screen(containing: rect, in: screens).map { clamp(rect, into: $0) }
    }

    /// Where the window opens, and the screen it opens on:
    /// 1. the saved place on the screen it was last put on, when that screen is connected;
    /// 2. else the saved place on the default screen (`defaultScreen`);
    /// 3. else the bottom-right of the default screen at `fallbackSize`.
    /// The result always lies inside that screen's visible frame.
    public static func openingFrame(screens: [MonitorScreen], saved: [String: CGRect], lastScreenUUID: String?,
                                    frameDisplayUUID: String?,
                                    fallbackSize: CGSize = SizePreset.medium.size) -> (rect: CGRect, screenUUID: String)? {
        if let uuid = lastScreenUUID, let screen = screens.first(where: { $0.uuid == uuid }), let place = saved[uuid] {
            return (clamp(global(place, on: screen), into: screen), uuid)
        }
        guard let screen = defaultScreen(screens, frameDisplayUUID: frameDisplayUUID) else { return nil }
        if let place = saved[screen.uuid] {
            return (clamp(global(place, on: screen), into: screen), screen.uuid)
        }
        return (bottomRight(size: fallbackSize, on: screen), screen.uuid)
    }

    /// `rect` at a new size, keeping its center where it can, then kept on `screen`.
    public static func resized(_ rect: CGRect, to size: CGSize, on screen: MonitorScreen?) -> CGRect {
        let fitted = lockedSize(width: size.width, limit: screen?.visibleFrame.size)
        let moved = CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                           width: fitted.width, height: fitted.height)
        return screen.map { clamp(moved, into: $0) } ?? moved
    }

    // MARK: - Resize by dragging

    /// The corner a mouse-down resizes: a point within `edge` of the border resizes from the corner
    /// of its quarter of the window. Nil: the point is inside, so the drag moves the window.
    /// `point` is in the window's own coordinates (y up), `bounds` its content bounds.
    public static func corner(at point: CGPoint, in bounds: CGRect, edge: CGFloat) -> Corner? {
        let nearBorder = point.x <= bounds.minX + edge || point.x >= bounds.maxX - edge
            || point.y <= bounds.minY + edge || point.y >= bounds.maxY - edge
        guard nearBorder else { return nil }
        let right = point.x >= bounds.midX, top = point.y >= bounds.midY
        switch (right, top) {
        case (true, true): return .topRight
        case (true, false): return .bottomRight
        case (false, true): return .topLeft
        case (false, false): return .bottomLeft
        }
    }

    /// The point of `rect` at `corner`.
    public static func point(of corner: Corner, in rect: CGRect) -> CGPoint {
        CGPoint(x: corner.isRight ? rect.maxX : rect.minX, y: corner.isTop ? rect.maxY : rect.minY)
    }

    /// Where `corner` of the window goes while the mouse is at `mouse`: it keeps the offset it had
    /// from the mouse-down point `grab`, so a grab inside the resize band never makes it jump.
    public static func dragTarget(of corner: Corner, in start: CGRect, grab: CGPoint, mouse: CGPoint) -> CGPoint {
        let p = point(of: corner, in: start)
        return CGPoint(x: p.x + mouse.x - grab.x, y: p.y + mouse.y - grab.y)
    }

    /// The window rect while `corner` of `start` follows the mouse at `mouse` (screen points): 16:9,
    /// at least `minSize`, at most `maxSize`, with the opposite corner fixed. Pass the corner's own
    /// target (`dragTarget`), not the raw mouse, so the corner does not jump to the pointer.
    public static func resized(_ start: CGRect, corner: Corner, to mouse: CGPoint, maxSize: CGSize? = nil) -> CGRect {
        let anchor = CGPoint(x: corner.isRight ? start.minX : start.maxX, y: corner.isTop ? start.minY : start.maxY)
        let dx = corner.isRight ? mouse.x - anchor.x : anchor.x - mouse.x
        let dy = corner.isTop ? mouse.y - anchor.y : anchor.y - mouse.y
        let size = lockedSize(width: max(dx, dy * aspect), limit: maxSize)
        let x = corner.isRight ? anchor.x : anchor.x - size.width
        let y = corner.isTop ? anchor.y : anchor.y - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Storage

    /// A rect as four numbers for UserDefaults.
    public static func encode(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    /// The rect from `encode`, or nil for anything else.
    public static func decode(_ values: [Double]?) -> CGRect? {
        guard let v = values, v.count == 4, v.allSatisfy(\.isFinite), v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}
