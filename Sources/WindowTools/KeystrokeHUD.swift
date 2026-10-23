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

/// The pill: near-black at 90% (#1E1E1E), rounded, white semibold text. It draws its text itself
/// (no text field, so nothing can cut it to "…"), sized to the whole text each time the text
/// changes, and lays itself out centered in its window. All of it is in the system font's design:
/// its glyphs, and for a key symbol it lacks (⇥) the matching SF Symbol (`symbolImages`).
///
/// A label field sized from its `intrinsicContentSize` truncated the text in the middle ("⇧…P",
/// "R…urn", "…" for ⇧⌘): the field draws inside a 2 pt inset on each side that its intrinsic width
/// leaves out.
final class KeystrokePillView: NSView {
    static let fill = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 0.9)

    /// The type size for the frame (`KeystrokePlacement.fontSize`).
    var fontSize: CGFloat = KeystrokePlacement.referenceFontSize
    var text: String = ""
    /// The type size the text draws at: `fontSize`, or smaller when the pill would not fit its
    /// window (`KeystrokePlacement.fittedPill`).
    private(set) var drawnFontSize: CGFloat = KeystrokePlacement.referenceFontSize
    /// Where the text draws, in the pill's (flipped) coordinates: its whole typographic size.
    private(set) var textRect: CGRect = .zero
    private var drawnText = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.white]
    }

    /// Key symbols the system font has no glyph for, and the SF Symbol drawn in their place. The
    /// font's own key glyphs (⌘ ⌫ ⎋ →) are these symbols at small scale, so ⇥ drawn this way has
    /// the size, weight and baseline of →.
    static let symbolImages: [Character: String] = ["⇥": "arrow.right.to.line"]

    /// `text` as the pill draws it: white semibold system font, and each of `symbolImages` as its
    /// SF Symbol, white, at the type size, on the baseline. A symbol that does not load stays text.
    static func drawnString(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let attributes = attributes(fontSize: fontSize)
        let result = NSMutableAttributedString()
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: attributes))
            run = ""
        }
        for character in text {
            guard let name = symbolImages[character], let symbol = symbolImage(name, fontSize: fontSize) else {
                run.append(character)
                continue
            }
            flush()
            let attachment = NSTextAttachment()
            attachment.image = symbol
            // The symbol's alignment rect is the type's cap height band: its bottom on the baseline.
            attachment.bounds = CGRect(x: 0, y: -symbol.alignmentRect.minY, width: symbol.size.width, height: symbol.size.height)
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
        }
        flush()
        return result
    }

    /// The SF Symbol `name` at the pill's type size and weight, small scale (the scale of the
    /// font's own key glyphs), drawn white.
    static func symbolImage(_ name: String, fontSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .semibold, scale: .small)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// `text`'s typographic size at `fontSize` (one line, any length), as the pill draws it.
    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        drawnString(text, fontSize: fontSize).size()
    }

    /// Sizes the pill to its whole text and centers it in `bounds`. The type gets smaller only
    /// when the pill would not fit `bounds` (a tiny frame).
    func layoutPill(in bounds: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let text = self.text
        let fitted = KeystrokePlacement.fittedPill(fontSize: fontSize, in: bounds.size) { Self.textSize(text, fontSize: $0) }
        let size = CGSize(width: min(bounds.width, fitted.size.width), height: min(bounds.height, fitted.size.height))
        frame = NSRect(x: bounds.minX + ((bounds.width - size.width) / 2).rounded(),
                       y: bounds.minY + ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        drawnFontSize = fitted.fontSize
        drawnText = Self.drawnString(text, fontSize: fitted.fontSize)
        let textSize = drawnText.size()
        textRect = CGRect(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2,
                          width: textSize.width, height: textSize.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(KeystrokePlacement.cornerRadius(fontSize: drawnFontSize), bounds.height / 2, bounds.width / 2)
        Self.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        // At a point, without a width: one line, never wrapped or truncated.
        drawnText.draw(at: textRect.origin)
    }
}
