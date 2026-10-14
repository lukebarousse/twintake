import CoreGraphics

/// How big the screen frame is.
public enum FrameSizing: Codable, Hashable, Sendable {
    /// A fixed size in points, centered horizontally, under the menu bar or at the bottom (`FrameAnchor`).
    case fixed(width: Double, height: Double)
    /// The whole display.
    case fullDisplay
}

/// Where a fixed frame sits on its display. The frame is always centered horizontally.
public enum FrameAnchor: String, Codable, Hashable, Sendable, CaseIterable {
    /// Directly under the menu bar. The strip below the frame stays free for the Dock.
    case top
    /// Flush with the bottom edge of the display. The strip above the frame stays free, for
    /// example for a window toolbar that must not be recorded (Parallels Desktop).
    case bottom

    /// Menu label.
    public var label: String {
        switch self {
        case .top: "Top (under the menu bar)"
        case .bottom: "Bottom of the display"
        }
    }
}

/// A named screen-frame size.
public struct ScreenFramePreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sizing: FrameSizing

    public init(id: String, name: String, sizing: FrameSizing) {
        self.id = id
        self.name = name
        self.sizing = sizing
    }

    /// Exact 16:9 on a 14" MacBook Pro: 1504x846 pt = 3008x1692 px.
    public static let laptop16x9 = ScreenFramePreset(
        id: "laptop-16x9", name: "16:9 frame (1504×846 pt)", sizing: .fixed(width: 1504, height: 846))
    /// The whole display. Exact 16:9 on a 16:9 monitor such as a 4K display.
    public static let fullDisplay = ScreenFramePreset(
        id: "full-display", name: "Whole display", sizing: .fullDisplay)

    public static let all: [ScreenFramePreset] = [.laptop16x9, .fullDisplay]
}

/// Places the recording frame on a display and converts between the three coordinate spaces
/// macOS uses. Mixing them up is the classic bug, so every conversion lives here.
///
/// - Display-local points, top-left origin, y down. `SCStreamConfiguration.sourceRect` uses this.
/// - Global CG points, origin at the top-left of the main display, y down. The Accessibility
///   API (`kAXPositionAttribute`), `CGDisplayBounds` and `CGWindowList` use this.
/// - AppKit global points, origin at the bottom-left of the main display, y up. `NSWindow` and
///   `NSScreen.frame` use this.
public enum FrameGeometry {
    /// The frame rect in display-local points (top-left origin).
    ///
    /// A fixed frame is centered horizontally. With `anchor` `.top` it sits directly under the
    /// menu bar, so the strip below it stays free for the Dock. With `.bottom` its bottom edge
    /// is the display's bottom edge, so the strip above it stays free (on the 14" laptop:
    /// x 4, y 136, 1504x846). If it does not fit, it shrinks to the largest rect with the same
    /// aspect ratio that fits under the menu bar; it never covers the menu bar.
    /// - Parameters:
    ///   - sizing: the preset sizing.
    ///   - displaySizePt: full display size in points.
    ///   - topInsetPt: menu bar height on that display (0 for the whole-display preset).
    ///   - anchor: where a fixed frame sits. The whole-display preset ignores it.
    public static func frameRect(sizing: FrameSizing, displaySizePt: CGSize, topInsetPt: CGFloat,
                                 anchor: FrameAnchor = .top) -> CGRect {
        switch sizing {
        case .fullDisplay:
            return CGRect(origin: .zero, size: displaySizePt)
        case let .fixed(width, height):
            let availW = displaySizePt.width
            let availH = max(0, displaySizePt.height - topInsetPt)
            var w = CGFloat(width)
            var h = CGFloat(height)
            if w > availW || h > availH {
                let s = min(availW / w, availH / h)
                w = (w * s).rounded(.down)
                h = (CGFloat(height) / CGFloat(width) * w).rounded(.down)
            }
            let x = ((availW - w) / 2).rounded(.down)
            switch anchor {
            case .top:
                return CGRect(x: x, y: topInsetPt, width: w, height: h)
            case .bottom:
                // h <= availH, so the frame never reaches into the menu bar.
                return CGRect(x: x, y: max(topInsetPt, displaySizePt.height - h), width: w, height: h)
            }
        }
    }

    /// Free points between the bottom of the menu bar and the top of `frame` (display-local).
    /// A window that must keep a strip above the frame (a toolbar) needs at least that strip here.
    public static func roomAbove(frame: CGRect, topInsetPt: CGFloat) -> CGFloat {
        max(0, frame.minY - topInsetPt)
    }

    /// Display-local (top-left) to global CG (top-left of main display).
    public static func globalRect(fromLocal rect: CGRect, displayBoundsGlobal: CGRect) -> CGRect {
        rect.offsetBy(dx: displayBoundsGlobal.minX, dy: displayBoundsGlobal.minY)
    }

    /// Global CG (top-left, y down) to AppKit global (bottom-left, y up).
    /// - Parameter mainDisplayHeight: height in points of the main display (the one with the menu bar
    ///   at the global origin, `CGMainDisplayID()`).
    public static func appKitRect(fromGlobal rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AppKit global (bottom-left, y up) to global CG (top-left, y down).
    public static func globalRect(fromAppKit rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Output pixel size for a frame drawn at `scale` (2 on Retina), rounded down to even
    /// numbers because video encoders need even dimensions.
    public static func outputPixels(forPoints size: CGSize, scale: CGFloat) -> PixelSize {
        func even(_ v: CGFloat) -> Int { let i = Int((v * scale).rounded(.down)); return i - (i % 2) }
        return PixelSize(width: even(size.width), height: even(size.height))
    }
}
