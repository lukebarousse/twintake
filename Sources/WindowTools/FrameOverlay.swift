// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AppKit
import RecorderCore

/// Dims the display outside the recording frame and draws a thin border just outside it.
///
/// The panels are click-through, on every Space, excluded from window capture
/// (`sharingType = .none`) and never cover the frame, so a region capture of the frame does not
/// contain them. They sit at the floating level: above normal app windows, below the Dock, the
/// menu bar, every app's menus and popovers, and notifications.
///
/// Call `show` again after a display change (`NSApplication.didChangeScreenParametersNotification`)
/// with fresh `Displays` values. Call `hide()` before releasing the overlay.
@MainActor
public final class FrameOverlay {
    /// Border thickness in points. Applies on the next `show`.
    public var borderWidth: CGFloat = 2
    public var idleBorderColor: NSColor = .white
    public var recordingBorderColor: NSColor = .systemRed

    public private(set) var isVisible = false
    public private(set) var isRecording = false
    /// The frame shown now, in global CG points.
    public private(set) var frameGlobal: CGRect?

    private var panels: [NSPanel] = []
    private var views: [OverlayView] = []

    public init() {}

    /// Window numbers of the overlay panels, for an explicit capture exclusion list.
    public var windowNumbers: [Int] { panels.map(\.windowNumber) }

    /// Shows the overlay for `frameGlobal` on `display`, replacing any overlay shown before.
    /// - Parameters:
    ///   - frameGlobal: the recording frame in global CG points (`DisplayInfo.globalFrameRect(for:)`).
    ///   - dimOpacity: black overlay opacity outside the frame, 0...1.
    ///   - coverMenuBar: also dim the menu bar strip. Off keeps the menu bar readable.
    public func show(frameGlobal: CGRect, display: DisplayInfo, dimOpacity: Double = 0.55, coverMenuBar: Bool = false) {
        hide()
        let layouts = OverlayGeometry.panels(frame: frameGlobal, display: display, coverMenuBar: coverMenuBar,
                                             borderWidth: borderWidth)
        let mainHeight = Displays.mainDisplayHeight
        let dim = NSColor.black.withAlphaComponent(CGFloat(min(max(dimOpacity, 0), 1)))
        for layout in layouts {
            let appKitRect = FrameGeometry.appKitRect(fromGlobal: layout.rectGlobal, mainDisplayHeight: mainHeight)
            let view = OverlayView(frame: NSRect(origin: .zero, size: appKitRect.size))
            view.dimColor = dim
            view.borderRects = layout.borderRectsLocal
            view.borderColor = currentBorderColor
            let panel = Self.makePanel(rect: appKitRect, level: layout.coversMenuBar ? Self.menuBarLevel : Self.dimLevel)
            panel.contentView = view
            panel.setFrame(appKitRect, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        self.frameGlobal = frameGlobal
        isVisible = true
    }

    /// Switches the border color: red while recording.
    public func setRecording(_ recording: Bool) {
        isRecording = recording
        for v in views {
            v.borderColor = currentBorderColor
            v.needsDisplay = true
        }
    }

    public func hide() {
        for p in panels {
            p.orderOut(nil)
            p.close()
        }
        panels.removeAll()
        views.removeAll()
        frameGlobal = nil
        isVisible = false
    }

    private var currentBorderColor: NSColor { isRecording ? recordingBorderColor : idleBorderColor }

    /// The dim panels: the floating level, above normal app windows. Every app's menus and
    /// popovers (status item popovers too) are higher, so they open over the dim.
    static let dimLevel = NSWindow.Level.floating
    /// The menu bar strip (only with `coverMenuBar`, which the app never turns on): above the
    /// menu bar and status items, below menus.
    static let menuBarLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    /// Just above the dim panels and still above normal windows: a window here (the camera
    /// window, the control bar) is never dimmed, and other apps' menu bar menus and popovers
    /// (for example a display utility's popover) open over it. TwinTake's own menu panel is at
    /// `.popUpMenu`, above it.
    public static let aboveOverlayLevel = NSWindow.Level(rawValue: dimLevel.rawValue + 1)

    private static func makePanel(rect: NSRect, level: NSWindow.Level) -> NSPanel {
        let panel = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        // NSPanel hides on deactivate by default; the recorder is rarely the active app.
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        return panel
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Keep the exact frame, even where it overlaps the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Fills with the dim color, then draws the border strips. Flipped, so the layout's top-left
/// panel coordinates draw as they are.
private final class OverlayView: NSView {
    var dimColor: NSColor = .clear
    var borderColor: NSColor = .white
    var borderRects: [CGRect] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setFillColor(dimColor.cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(borderColor.cgColor)
        ctx.fill(borderRects)
    }
}
