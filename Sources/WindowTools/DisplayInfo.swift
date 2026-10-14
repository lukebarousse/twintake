// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AppKit
import CoreGraphics
import IOKit
import RecorderCore

/// One connected display, with its geometry in the global CoreGraphics space that
/// `CGDisplayBounds`, `CGWindowList` and the Accessibility API use: points, origin at the
/// top-left of the main display, y down. Displays arranged above the main one therefore have a
/// negative y origin.
///
/// A plain value: build one with `Displays`, or by hand in tests.
public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public var id: CGDirectDisplayID
    /// `CGDisplayCreateUUIDFromDisplayID` as a string. Stable across launches and reboots, so
    /// save this (not `id`) to remember the user's display choice.
    public var uuid: String
    /// `NSScreen.localizedName`, e.g. "Built-in Retina Display" or "PHL 279P1".
    public var name: String
    public var isBuiltin: Bool
    /// True for the display at the global origin (`CGMainDisplayID()`), the one AppKit
    /// coordinates are measured from.
    public var isMain: Bool
    /// Bounds in global CG points (top-left origin, y down).
    public var boundsGlobal: CGRect
    /// Pixels per point: 2 on Retina and on a 4K display at its default "looks like 1920x1080".
    public var scale: CGFloat
    /// Height of the menu bar strip at the top of this display, in points. 0 when this display
    /// shows no menu bar.
    public var menuBarHeightPt: CGFloat
    /// Refresh rate in Hz. 0 when macOS does not report one.
    public var refreshRate: Double
    /// True when the display has a camera housing (notch) at the top.
    public var hasNotch: Bool

    public init(id: CGDirectDisplayID, uuid: String, name: String, isBuiltin: Bool, isMain: Bool,
                boundsGlobal: CGRect, scale: CGFloat, menuBarHeightPt: CGFloat, refreshRate: Double,
                hasNotch: Bool = false) {
        self.id = id; self.uuid = uuid; self.name = name; self.isBuiltin = isBuiltin; self.isMain = isMain
        self.boundsGlobal = boundsGlobal; self.scale = scale; self.menuBarHeightPt = menuBarHeightPt
        self.refreshRate = refreshRate; self.hasNotch = hasNotch
    }

    /// Full display size in points.
    public var sizePt: CGSize { boundsGlobal.size }

    /// Full display size in pixels at the current scale.
    public var sizePx: PixelSize { FrameGeometry.outputPixels(forPoints: sizePt, scale: scale) }

    /// True when the display is 16:9 (within 0.5%), e.g. a 4K monitor at 1920x1080 pt.
    /// The app can then default to the whole-display preset.
    public var isSixteenByNine: Bool {
        guard sizePt.height > 0 else { return false }
        return abs(sizePt.width / sizePt.height - 16.0 / 9.0) <= (16.0 / 9.0) * 0.005
    }

    /// Whole display on a 16:9 display, the fixed laptop frame everywhere else.
    public var defaultPreset: ScreenFramePreset { isSixteenByNine ? .fullDisplay : .laptop16x9 }

    /// The frame for `preset` in display-local points (top-left origin). This is the value for
    /// `ScreenRecorderConfig.frameRectPt` and `SCStreamConfiguration.sourceRect`.
    /// - Parameter anchor: under the menu bar (`.top`) or flush with the bottom edge (`.bottom`).
    public func frameRect(for preset: ScreenFramePreset, anchor: FrameAnchor = .top) -> CGRect {
        FrameGeometry.frameRect(sizing: preset.sizing, displaySizePt: sizePt, topInsetPt: menuBarHeightPt,
                                anchor: anchor)
    }

    /// The frame for `preset` in global CG points: the target for `WindowSnapper` and `FrameOverlay`.
    public func globalFrameRect(for preset: ScreenFramePreset, anchor: FrameAnchor = .top) -> CGRect {
        FrameGeometry.globalRect(fromLocal: frameRect(for: preset, anchor: anchor), displayBoundsGlobal: boundsGlobal)
    }

    /// Output size in pixels (even numbers) for `preset`, e.g. 3008x1692 for the laptop frame at 2x.
    /// The anchor moves the frame but never changes its size.
    public func outputPixels(for preset: ScreenFramePreset) -> PixelSize {
        FrameGeometry.outputPixels(forPoints: frameRect(for: preset).size, scale: scale)
    }

    /// The `session.json` `screen` block for a region capture of `preset` on this display.
    /// Pass `snap.snappedWindow` when a window was snapped, and `capture: "window"` for a
    /// window-only capture. `frame_anchor` is set for a fixed frame (the whole display has none).
    public func screenInfo(for preset: ScreenFramePreset, anchor: FrameAnchor = .top, capture: String = "region",
                           snappedWindow: SnappedWindow? = nil) -> ScreenInfo {
        ScreenInfo(capture: capture, displayId: id, displayName: name, scale: Double(scale), preset: preset.id,
                   frameRectPt: PointRect(frameRect(for: preset, anchor: anchor)), outputPx: outputPixels(for: preset),
                   snappedWindow: snappedWindow, frameAnchor: preset.sizing == .fullDisplay ? nil : anchor)
    }

    /// The lowest y (global CG points) a window's top edge can reach on this display: the
    /// bottom of the menu bar strip (the top of the display when it shows no menu bar).
    public var windowTopLimitGlobal: CGFloat { boundsGlobal.minY + min(menuBarHeightPt, boundsGlobal.height) }

    /// Converts a global CG rect on any display to this display's local points.
    public func localRect(fromGlobal rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -boundsGlobal.minX, dy: -boundsGlobal.minY)
    }

    /// The menu bar strip in global CG points (empty when there is none).
    public var menuBarRectGlobal: CGRect {
        CGRect(x: boundsGlobal.minX, y: boundsGlobal.minY, width: boundsGlobal.width, height: menuBarHeightPt)
    }

    /// Menu bar height for a display, from `NSScreen` values in AppKit coordinates.
    ///
    /// The gap between the tops of `frame` and `visibleFrame` is the menu bar (the Dock never
    /// sits at the top). The gap is 0 when the menu bar hides itself; the frame should still
    /// leave room for it, so fall back to the notch safe area, then the status bar thickness.
    /// The notch safe area is the minimum on every display that has one, menu bar or not: the
    /// strip beside the camera housing is recorded but the user cannot see it.
    /// - Parameter showsMenuBar: false on a secondary display when "Displays have separate
    ///   Spaces" is off, because only the main display has a menu bar then.
    public static func menuBarHeight(frameMaxY: CGFloat, visibleFrameMaxY: CGFloat, safeAreaTop: CGFloat,
                                     statusBarThickness: CGFloat, showsMenuBar: Bool) -> CGFloat {
        let gap = frameMaxY - visibleFrameMaxY
        let notch = max(0, safeAreaTop).rounded()
        if gap > 0.5 { return max(gap.rounded(), notch) }
        if notch > 0 { return notch }
        return showsMenuBar ? statusBarThickness.rounded() : 0
    }

    /// The display that holds the largest part of `rect` (global CG points), or nil when `rect`
    /// is on no display.
    public static func display(containing rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (display: DisplayInfo, area: CGFloat)?
        for d in displays {
            let i = d.boundsGlobal.intersection(rect)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if best == nil || area > best!.area { best = (d, area) }
        }
        return best?.display
    }
}

/// Reads the connected displays. Only displays that are awake and drawing (have an `NSScreen`)
/// are listed, so a closed laptop lid removes the built-in display.
@MainActor
public enum Displays {
    /// Every active display, main display first, then left to right.
    public static func all() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        let thickness = NSStatusBar.system.thickness
        return NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = displayID(of: screen) else { return nil }
            let isMain = id == mainID
            let menuBar = DisplayInfo.menuBarHeight(
                frameMaxY: screen.frame.maxY, visibleFrameMaxY: screen.visibleFrame.maxY,
                safeAreaTop: screen.safeAreaInsets.top, statusBarThickness: thickness,
                showsMenuBar: separateSpaces || isMain)
            return DisplayInfo(
                id: id, uuid: uuidString(for: id) ?? "display-\(id)", name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0, isMain: isMain, boundsGlobal: CGDisplayBounds(id),
                scale: screen.backingScaleFactor, menuBarHeightPt: menuBar,
                refreshRate: refreshRate(of: id, screen: screen), hasNotch: screen.safeAreaInsets.top > 0)
        }
        .sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return a.boundsGlobal.minX < b.boundsGlobal.minX
        }
    }

    /// The built-in laptop display, or nil when the lid is closed or there is none.
    public static func builtin() -> DisplayInfo? { all().first { $0.isBuiltin } }

    /// True when a laptop's lid is closed (`AppleClamshellState` on IOPMrootDomain). False on a
    /// desktop Mac or when the state cannot be read. Reads the I/O Registry only; no prompt.
    public nonisolated static var isLidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// The main display (`CGMainDisplayID()`, the one with the menu bar at the global origin).
    public static func main() -> DisplayInfo? { all().first { $0.isMain } }

    /// The display saved earlier by its `uuid`, if it is connected.
    public static func find(uuid: String) -> DisplayInfo? { all().first { $0.uuid == uuid } }

    public static func find(id: CGDirectDisplayID) -> DisplayInfo? { all().first { $0.id == id } }

    /// Height in points of the main display. Pass it to the `FrameGeometry` AppKit conversions.
    public static var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    /// The display that holds the largest part of `rect` (global CG points).
    public static func display(containing rect: CGRect) -> DisplayInfo? {
        DisplayInfo.display(containing: rect, in: all())
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private static func refreshRate(of id: CGDirectDisplayID, screen: NSScreen) -> Double {
        // Built-in panels often report 0 here; NSScreen still knows the maximum rate.
        if let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 { return mode.refreshRate }
        return Double(screen.maximumFramesPerSecond)
    }
}
