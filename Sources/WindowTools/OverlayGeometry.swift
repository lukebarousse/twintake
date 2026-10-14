import CoreGraphics

/// Rects for the frame overlay, in global CG points (top-left origin, y down).
///
/// Nothing here ever covers the frame itself: the dim panels and the border sit outside it,
/// so a region capture of the frame never contains them.
public enum OverlayGeometry {
    /// The four dim rects around `frame`, clipped to `area`.
    ///
    ///     ┌──────────── top ────────────┐
    ///     ├──────┬─────────────┬────────┤
    ///     │ left │    frame    │ right  │
    ///     ├──────┴─────────────┴────────┤
    ///     └─────────── bottom ──────────┘
    ///
    /// Top and bottom span the full width; left and right span only the frame's height.
    /// Empty rects (the frame touches that edge of the area) are left out.
    public static func dimRects(frame: CGRect, area: CGRect) -> [OverlayPiece] {
        let f = frame.intersection(area)
        guard !f.isNull, !f.isEmpty else { return [OverlayPiece(edge: .top, rect: area)] }
        let pieces = [
            OverlayPiece(edge: .top, rect: CGRect(x: area.minX, y: area.minY, width: area.width, height: f.minY - area.minY)),
            OverlayPiece(edge: .bottom, rect: CGRect(x: area.minX, y: f.maxY, width: area.width, height: area.maxY - f.maxY)),
            OverlayPiece(edge: .left, rect: CGRect(x: area.minX, y: f.minY, width: f.minX - area.minX, height: f.height)),
            OverlayPiece(edge: .right, rect: CGRect(x: f.maxX, y: f.minY, width: area.maxX - f.maxX, height: f.height)),
        ]
        return pieces.filter { $0.rect.width > 0 && $0.rect.height > 0 }
    }

    /// Four border strips of `width` just outside `frame`. Top and bottom include the corners.
    public static func borderRects(frame: CGRect, width: CGFloat) -> [OverlayPiece] {
        [
            OverlayPiece(edge: .top, rect: CGRect(x: frame.minX - width, y: frame.minY - width,
                                                  width: frame.width + 2 * width, height: width)),
            OverlayPiece(edge: .bottom, rect: CGRect(x: frame.minX - width, y: frame.maxY,
                                                     width: frame.width + 2 * width, height: width)),
            OverlayPiece(edge: .left, rect: CGRect(x: frame.minX - width, y: frame.minY, width: width, height: frame.height)),
            OverlayPiece(edge: .right, rect: CGRect(x: frame.maxX, y: frame.minY, width: width, height: frame.height)),
        ]
    }

    /// The area to dim on `display`: the whole display, or the part below the menu bar.
    public static func dimArea(display: DisplayInfo, coverMenuBar: Bool) -> CGRect {
        guard !coverMenuBar else { return display.boundsGlobal }
        let b = display.boundsGlobal
        let top = min(display.menuBarHeightPt, b.height)
        return CGRect(x: b.minX, y: b.minY + top, width: b.width, height: b.height - top)
    }

    /// The panels to draw: each dim rect, with the parts of the border that fall inside it, in
    /// the panel's own top-left coordinates. When `coverMenuBar` is true the menu bar strip is
    /// returned as its own top piece, so it can sit at a higher window level.
    public static func panels(frame: CGRect, display: DisplayInfo, coverMenuBar: Bool,
                              borderWidth: CGFloat) -> [OverlayPanelLayout] {
        var dims = dimRects(frame: frame, area: dimArea(display: display, coverMenuBar: false))
        var menuBar: CGRect?
        if coverMenuBar, display.menuBarHeightPt > 0 {
            menuBar = display.menuBarRectGlobal.intersection(display.boundsGlobal)
        }
        // A frame that reaches into the menu bar strip (the whole-display preset) dims around it there too.
        if coverMenuBar, let bar = menuBar, frame.intersects(bar) {
            dims = dimRects(frame: frame, area: display.boundsGlobal)
            menuBar = nil
        }
        let borders = borderRects(frame: frame, width: borderWidth)
        var result = dims.map { piece in
            OverlayPanelLayout(edge: piece.edge, rectGlobal: piece.rect, coversMenuBar: false,
                               borderRectsLocal: localBorders(borders, in: piece.rect))
        }
        if let bar = menuBar, !bar.isEmpty {
            result.append(OverlayPanelLayout(edge: .top, rectGlobal: bar, coversMenuBar: true,
                                             borderRectsLocal: localBorders(borders, in: bar)))
        }
        return result
    }

    private static func localBorders(_ borders: [OverlayPiece], in panel: CGRect) -> [CGRect] {
        borders.compactMap { b in
            let i = b.rect.intersection(panel)
            guard !i.isNull, i.width > 0, i.height > 0 else { return nil }
            return i.offsetBy(dx: -panel.minX, dy: -panel.minY)
        }
    }
}

/// One side of the frame.
public enum OverlayEdge: String, Sendable, Hashable {
    case top, bottom, left, right
}

public struct OverlayPiece: Sendable, Hashable {
    public var edge: OverlayEdge
    /// Global CG points.
    public var rect: CGRect
    public init(edge: OverlayEdge, rect: CGRect) { self.edge = edge; self.rect = rect }
}

/// One overlay panel: where it goes and which border strips it draws.
public struct OverlayPanelLayout: Sendable, Hashable {
    public var edge: OverlayEdge
    /// Panel frame in global CG points.
    public var rectGlobal: CGRect
    /// True for the menu bar strip, which needs a window level above the menu bar.
    public var coversMenuBar: Bool
    /// Border strips in panel-local points, top-left origin.
    public var borderRectsLocal: [CGRect]
}
