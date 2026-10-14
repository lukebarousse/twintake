import CoreGraphics

/// Where the control bar opens and how it stays on screen. Plain geometry, so it can be tested
/// without a window. All rects are in AppKit coordinates (origin at the bottom-left of the main
/// display, y up), like `MonitorScreen`.
///
/// The bar is placed by its center: a bar that grows (another pinned app) or shrinks keeps its
/// center, and a saved place is the bar's center on its screen.
public enum ControlBarGeometry {
    /// Gap between the bar and the edge of the visible frame for the fallback place.
    public static let margin: CGFloat = 8
    /// The bar fits in the strip above the frame when the strip has this much room above and
    /// below it.
    public static let stripGap: CGFloat = 4

    // MARK: - Default place

    /// Where the bar goes when no saved place applies:
    /// 1. Centered in the strip between the top of `frame` (the recording frame, anchored at the
    ///    bottom of the display) and the bottom of the menu bar, over the frame's middle. When
    ///    `reservedAbovePt` is set (the Parallels toolbar strip right above the frame), the bar
    ///    goes in the free part above it, when that part is tall enough.
    /// 2. Else (no frame on this screen, a frame at the top, or a strip too short): top-center,
    ///    `margin` under the menu bar.
    /// - Parameters:
    ///   - frame: the recording frame on `screen`, AppKit coordinates; nil when it is elsewhere.
    ///   - reservedAbovePt: points right above the frame that the bar should leave free.
    public static func defaultFrame(size: CGSize, on screen: MonitorScreen, frame: CGRect?,
                                    reservedAbovePt: CGFloat = 0) -> CGRect {
        if let frame, frame.intersects(screen.frame) {
            let top = screen.visibleFrame.maxY
            let need = size.height + 2 * stripGap
            let reserved = max(0, reservedAbovePt)
            for bottom in [frame.maxY + reserved, frame.maxY] where top - bottom >= need {
                let y = (bottom + (top - bottom - size.height) / 2).rounded(.down)
                return clamp(CGRect(x: (frame.midX - size.width / 2).rounded(.down), y: y,
                                    width: size.width, height: size.height), into: screen)
            }
        }
        return underMenuBar(size: size, on: screen)
    }

    /// Top-center of the visible frame, `margin` under the menu bar.
    public static func underMenuBar(size: CGSize, on screen: MonitorScreen) -> CGRect {
        let visible = screen.visibleFrame
        return clamp(CGRect(x: (visible.midX - size.width / 2).rounded(.down), y: visible.maxY - margin - size.height,
                            width: size.width, height: size.height), into: screen)
    }

    // MARK: - On screen

    /// `rect` moved to lie inside the screen's visible frame (never under the menu bar). Its
    /// size never changes: a bar wider than the screen starts at its left edge.
    public static func clamp(_ rect: CGRect, into screen: MonitorScreen) -> CGRect {
        let visible = screen.visibleFrame
        let x = max(visible.minX, min(rect.minX, visible.maxX - rect.width))
        let y = min(visible.maxY - rect.height, max(rect.minY, visible.minY))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Keeps a shown bar on screen after a display change or a drag: inside the visible frame of
    /// the screen that holds most of it. Nil when it is on no screen anymore (its display went away).
    public static func clamped(_ rect: CGRect, screens: [MonitorScreen]) -> CGRect? {
        CameraWindowGeometry.screen(containing: rect, in: screens).map { clamp(rect, into: $0) }
    }

    /// `rect` at a new size around the same center, kept on `screen`.
    public static func resized(_ rect: CGRect, to size: CGSize, on screen: MonitorScreen?) -> CGRect {
        let moved = centered(at: CGPoint(x: rect.midX, y: rect.midY), size: size)
        return screen.map { clamp(moved, into: $0) } ?? moved
    }

    // MARK: - Saved places

    /// The place to save for a bar at `rect` on `screen`: its center, as an offset from the
    /// screen's bottom-left corner, so it survives a new display arrangement.
    public static func localCenter(of rect: CGRect, on screen: MonitorScreen) -> CGPoint {
        CGPoint(x: rect.midX - screen.frame.minX, y: rect.midY - screen.frame.minY)
    }

    /// The bar's rect for a saved center on `screen`, kept inside its visible frame (the screen
    /// may have become smaller, or its menu bar or Dock larger).
    public static func frame(size: CGSize, savedCenter: CGPoint, on screen: MonitorScreen) -> CGRect {
        let center = CGPoint(x: savedCenter.x + screen.frame.minX, y: savedCenter.y + screen.frame.minY)
        return clamp(centered(at: center, size: size), into: screen)
    }

    /// Where the bar opens, and the screen it opens on:
    /// 1. its saved place on the screen it was last put on, when that screen is connected;
    /// 2. else on the recording screen (when connected, else the first screen): its saved place
    ///    there, else `defaultFrame` (with the frame only on the recording screen).
    /// The result always lies inside that screen's visible frame.
    /// - Parameters:
    ///   - saved: saved centers by screen uuid (`localCenter`).
    ///   - frame: the recording frame, AppKit coordinates, on `recordingScreenUUID`.
    public static func openingFrame(size: CGSize, screens: [MonitorScreen], saved: [String: CGPoint],
                                    lastScreenUUID: String?, recordingScreenUUID: String?, frame: CGRect?,
                                    reservedAbovePt: CGFloat = 0) -> (rect: CGRect, screenUUID: String)? {
        if let uuid = lastScreenUUID, let screen = screens.first(where: { $0.uuid == uuid }), let center = saved[uuid] {
            return (Self.frame(size: size, savedCenter: center, on: screen), uuid)
        }
        let recording = recordingScreenUUID.flatMap { uuid in screens.first { $0.uuid == uuid } }
        guard let screen = recording ?? screens.first else { return nil }
        if let center = saved[screen.uuid] {
            return (Self.frame(size: size, savedCenter: center, on: screen), screen.uuid)
        }
        return (defaultFrame(size: size, on: screen, frame: recording == nil ? nil : frame, reservedAbovePt: reservedAbovePt),
                screen.uuid)
    }

    // MARK: - Storage

    /// A saved center as two numbers for UserDefaults.
    public static func encode(_ point: CGPoint) -> [Double] { [Double(point.x), Double(point.y)] }

    /// The point from `encode`, or nil for anything else.
    public static func decode(_ values: [Double]?) -> CGPoint? {
        guard let v = values, v.count == 2, v.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: v[0], y: v[1])
    }

    private static func centered(at center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }
}
