import AppKit
import RecorderCore

/// The on-screen keystroke pill: a dark rounded pill with white text near the bottom of the
/// recording frame (`KeystrokePlacement`), like CleanShot X's keystrokes.
///
/// - One transparent window, made once and kept: its window number never changes, so a screen
///   capture filter built once holds it for the whole take. Between keystrokes it stays ordered
///   in and draws nothing.
/// - Unlike TwinTake's other windows it is in screen.mov (`sharingType = .readOnly`; the screen
///   recorder names it as an exception to TwinTake's exclusion). It never takes the focus, ignores
///   the mouse, and sits above normal windows (one level above the camera window and the control
///   bar) and below every app's menus.
/// - Always a dark pill, in light and dark mode.
///
/// Main thread only.
@MainActor
public final class KeystrokeHUD {
    /// One above the camera window and the control bar (`FrameOverlay.aboveOverlayLevel`), still
    /// below the menu bar and every app's menus and popovers.
    public static let level = NSWindow.Level(rawValue: FrameOverlay.aboveOverlayLevel.rawValue + 1)
    public static let fadeInS = 0.12

    private var panel: KeystrokePanel?
    private var pill: KeystrokePillView?
    /// The frame the HUD sits in now, global CG points.
    public private(set) var frameGlobal: CGRect?
    /// The text on show, or nil while nothing shows (or it fades).
    public private(set) var text: String?

    public init() {}

    /// The window's number (its `CGWindowID`) once the window exists.
    public var windowID: UInt32? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return UInt32(panel.windowNumber)
    }

    /// The window is on screen (it may draw nothing).
    public var isOrderedIn: Bool { panel?.isVisible ?? false }

    /// Puts the HUD over `frameGlobal` and orders it in, drawing nothing until `show`.
    public func place(frameGlobal: CGRect) {
        let (panel, pill) = parts()
        self.frameGlobal = frameGlobal
        // In AppKit coordinates, which move with the main display: compared every time.
        let rect = FrameGeometry.appKitRect(fromGlobal: KeystrokePlacement.windowRect(frameGlobal: frameGlobal),
                                            mainDisplayHeight: Displays.mainDisplayHeight)
        let fontSize = KeystrokePlacement.fontSize(frameHeight: frameGlobal.height)
        if panel.frame != rect || pill.fontSize != fontSize {
            panel.setFrame(rect, display: false)
            pill.fontSize = fontSize
            pill.layoutPill(in: panel.contentView?.bounds ?? .zero)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Shows `text`, in place of any text on show. Call `place` first.
    public func show(_ text: String) {
        guard let panel, let pill, panel.isVisible else { return }
        let wasShowing = self.text != nil
        self.text = text
        pill.text = text
        pill.layoutPill(in: panel.contentView?.bounds ?? .zero)
        // A fade that runs is replaced: the pill comes back at once.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasShowing ? 0 : Self.fadeInS
            pill.animator().alphaValue = 1
        }
    }

    /// Fades the pill out (`KeystrokeTracker.fadeOutS`). The window stays.
    public func fadeOut() {
        guard let pill, text != nil else { return }
        text = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = KeystrokeTracker.fadeOutS
            pill.animator().alphaValue = 0
        }
    }

    /// Hides the pill at once. The window stays.
    public func clear() {
        text = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            pill?.animator().alphaValue = 0
        }
    }

    /// Takes the window off screen. Its number stays the same for the next `place`.
    public func orderOut() {
        clear()
        panel?.orderOut(nil)
    }

    private func parts() -> (KeystrokePanel, KeystrokePillView) {
        if let panel, let pill { return (panel, pill) }
        let panel = KeystrokePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        // In screen.mov, unlike TwinTake's other windows (`.none`).
        panel.sharingType = .readOnly
        panel.isReleasedWhenClosed = false
        // NSPanel hides on deactivate by default; TwinTake is rarely the active app.
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "TwinTake Keystrokes"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 90))
        content.autoresizingMask = [.width, .height]
        let pill = KeystrokePillView(frame: .zero)
        pill.alphaValue = 0
        content.addSubview(pill)
        panel.contentView = content
        self.panel = panel
        self.pill = pill
        return (panel, pill)
    }
}

private final class KeystrokePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The pill: near-black at 90% (#1E1E1E), rounded, white semibold text. Lays itself out
/// centered in its window.
private final class KeystrokePillView: NSView {
    static let fill = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 0.9)

    private let label = NSTextField(labelWithString: "")
    var fontSize: CGFloat = KeystrokePlacement.referenceFontSize {
        didSet { applyStyle() }
    }
    var text: String = "" {
        didSet { label.stringValue = text }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.fill.cgColor
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyStyle() {
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        layer?.cornerRadius = KeystrokePlacement.cornerRadius(fontSize: fontSize)
    }

    /// Sizes the pill to its text (up to the window's width) and centers it in `bounds`.
    func layoutPill(in bounds: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let padX = (fontSize * 0.6).rounded(), padY = (fontSize * 0.3).rounded()
        let textSize = label.intrinsicContentSize
        let width = min(bounds.width, (textSize.width + 2 * padX).rounded(.up))
        let height = min(bounds.height, (textSize.height + 2 * padY).rounded(.up))
        frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
                       width: width, height: height)
        label.frame = NSRect(x: padX, y: ((height - textSize.height) / 2).rounded(), width: max(0, width - 2 * padX),
                             height: textSize.height)
    }
}
