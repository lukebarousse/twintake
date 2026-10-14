import AppKit
import CoreGraphics

/// The display edge the Dock sits on (`com.apple.dock` `orientation`).
public enum DockEdge: String, Sendable, Hashable, CaseIterable {
    case bottom, left, right

    /// From the raw `orientation` value. Missing or unknown means bottom (the macOS default).
    public init(orientation: String?) {
        switch orientation?.lowercased() {
        case "left": self = .left
        case "right": self = .right
        default: self = .bottom
        }
    }
}

/// The Dock settings that matter for the frame.
public struct DockPrefs: Sendable, Hashable {
    public var edge: DockEdge
    /// "Automatically hide and show the Dock" (`com.apple.dock` `autohide`, ⌥⌘D).
    public var autohide: Bool

    public init(edge: DockEdge = .bottom, autohide: Bool = false) {
        self.edge = edge; self.autohide = autohide
    }

    /// From raw `com.apple.dock` values. A missing `autohide` means off.
    public init(orientation: String?, autohide: Any?) {
        let hide: Bool
        switch autohide {
        case let b as Bool: hide = b
        case let n as NSNumber: hide = n.boolValue
        case let s as String: hide = ["1", "true", "yes"].contains(s.lowercased())
        default: hide = false
        }
        self.init(edge: DockEdge(orientation: orientation), autohide: hide)
    }

    /// Reads `orientation` and `autohide` from the `com.apple.dock` preferences. No prompt.
    public static func current() -> DockPrefs {
        let domain = "com.apple.dock" as CFString
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, domain)
        return DockPrefs(orientation: orientation, autohide: autohide)
    }
}

/// Whether a visible Dock covers part of the frame, so the app can warn before a take.
/// An auto-hidden Dock never counts: it shows only while the pointer is at the display edge.
public struct DockOverlap: Sendable, Hashable {
    public var prefs: DockPrefs
    /// Thickness of the visible Dock on this display in points. 0 when the Dock hides itself or
    /// is on another display.
    public var dockThicknessPt: CGFloat
    /// The Dock strip on this display, display-local points (top-left origin). Nil when 0 thick.
    public var dockRectLocal: CGRect?
    /// The part of the frame under the Dock, display-local points. Nil when the Dock does not
    /// cover the frame.
    public var coveredRectLocal: CGRect?
    /// The Dock is on another display now, but can move to this one (a bottom Dock follows the
    /// pointer to the display whose bottom edge it pushes against).
    public var fromOtherDisplay = false

    public var overlapsFrame: Bool { coveredRectLocal != nil }

    /// How far the Dock reaches into the frame, in points (0 when it does not).
    public var coveredPt: CGFloat {
        guard let c = coveredRectLocal else { return 0 }
        return prefs.edge == .bottom ? c.height : c.width
    }

    /// One line for the user when the Dock covers the frame, else nil.
    /// - Parameter frameAtBottom: the frame is the 16:9 frame at the bottom of its display, so
    ///   Frame position > Top is a fix. For a top or whole-display frame it is not offered.
    public func warning(frameAtBottom: Bool) -> String? {
        guard overlapsFrame else { return nil }
        let n = coveredPt.ptNumber
        let fix = "Turn on “Automatically hide and show the Dock” (⌥⌘D)"
        switch prefs.edge {
        case .bottom:
            let what = fromOtherDisplay
                ? "The Dock can move to this display and cover the bottom \(n) pt of the frame"
                : "The Dock covers the bottom \(n) pt of the frame"
            return "\(what), so it is in the recording. \(fix)" + (frameAtBottom ? ", or put the frame at the top." : ".")
        case .left, .right:
            return "The Dock covers \(n) pt on the \(prefs.edge.rawValue) side of the frame, so it is in the recording. \(fix)."
        }
    }

    /// The pure check.
    /// - Parameters:
    ///   - frameLocal: the frame in display-local points (top-left origin), `DisplayInfo.frameRect(for:anchor:)`.
    ///   - displaySizePt: full display size in points.
    ///   - dockThicknessPt: the Dock strip on this display, from `dockThickness(edge:screenFrame:visibleFrame:)`.
    ///   - prefs: the Dock settings.
    public static func check(frameLocal: CGRect, displaySizePt: CGSize, dockThicknessPt: CGFloat,
                             prefs: DockPrefs) -> DockOverlap {
        let t = prefs.autohide ? 0 : max(0, dockThicknessPt)
        guard t > 0.5 else {
            return DockOverlap(prefs: prefs, dockThicknessPt: 0, dockRectLocal: nil, coveredRectLocal: nil)
        }
        let w = displaySizePt.width, h = displaySizePt.height
        let dock: CGRect
        switch prefs.edge {
        case .bottom: dock = CGRect(x: 0, y: h - t, width: w, height: t)
        case .left: dock = CGRect(x: 0, y: 0, width: t, height: h)
        case .right: dock = CGRect(x: w - t, y: 0, width: t, height: h)
        }
        let i = dock.intersection(frameLocal)
        let covered = !i.isNull && i.width > 0 && i.height > 0 ? i : nil
        return DockOverlap(prefs: prefs, dockThicknessPt: t, dockRectLocal: dock, coveredRectLocal: covered)
    }

    /// The Dock strip on a screen, in points: the gap between `NSScreen.frame` and
    /// `NSScreen.visibleFrame` on the Dock's edge (AppKit coordinates). 0 when the Dock is on
    /// another display.
    public static func dockThickness(edge: DockEdge, screenFrame: CGRect, visibleFrame: CGRect) -> CGFloat {
        let gap: CGFloat
        switch edge {
        case .bottom: gap = visibleFrame.minY - screenFrame.minY
        case .left: gap = visibleFrame.minX - screenFrame.minX
        case .right: gap = screenFrame.maxX - visibleFrame.maxX
        }
        return max(0, gap.rounded())
    }

    /// The Dock thickness that counts for a display: its own, or for a bottom Dock that is on
    /// another display now, the thickness there (it moves to whichever display's bottom edge the
    /// pointer pushes against). A side Dock stays on its display.
    /// - Returns: the thickness, and whether it comes from another display.
    public static func effectiveThickness(edge: DockEdge, onDisplay: CGFloat,
                                          otherDisplays: [CGFloat]) -> (thickness: CGFloat, fromOtherDisplay: Bool) {
        if onDisplay > 0.5 || edge != .bottom { return (onDisplay, false) }
        let elsewhere = otherDisplays.max() ?? 0
        return elsewhere > 0.5 ? (elsewhere, true) : (0, false)
    }

    /// The live check for `frameLocal` on `display`: reads the Dock preferences and the displays'
    /// `NSScreen.visibleFrame`. Reads only; no prompt.
    @MainActor
    public static func current(frameLocal: CGRect, on display: DisplayInfo) -> DockOverlap {
        let prefs = DockPrefs.current()
        func thickness(_ screen: NSScreen) -> CGFloat {
            dockThickness(edge: prefs.edge, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        let screens = NSScreen.screens
        let own = screens.first { Displays.displayID(of: $0) == display.id }.map(thickness) ?? 0
        let others = screens.filter { Displays.displayID(of: $0) != display.id }.map(thickness)
        let effective = effectiveThickness(edge: prefs.edge, onDisplay: own, otherDisplays: others)
        var overlap = check(frameLocal: frameLocal, displaySizePt: display.sizePt, dockThicknessPt: effective.thickness,
                            prefs: prefs)
        overlap.fromOtherDisplay = effective.fromOtherDisplay && overlap.overlapsFrame
        return overlap
    }
}
