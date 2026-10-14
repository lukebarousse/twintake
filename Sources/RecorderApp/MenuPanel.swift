import AppKit
import SwiftUI

/// The menu: a status item, and a borderless panel under it that holds `MenuContentView`.
///
/// Why not `MenuBarExtra(.window)`: SwiftUI owns the frame of that window. When the content got
/// shorter (Live preview off, another mode, a closed disclosure arrow), SwiftUI resized the window
/// around its old center, so the top edge dropped below the menu bar, and the shadow of the old,
/// larger window stayed on screen. Code in the window could move it back only after SwiftUI had
/// moved it, and SwiftUI then moved it again. Here this controller is the only code that sets the
/// panel's frame: at every height the top edge stays under the status item, the resize has no
/// animation, and the shadow is computed again after each resize.
///
/// - Non-activating: opening the menu or clicking in it does not make TwinTake the active app, so
///   the front app (the one Snap Front Window moves) stays in front. The panel still becomes the
///   key window, so the keyboard works in it.
/// - It closes on a click outside it (another app, the menu bar, the camera window), on Escape, on
///   a second click on the status item, and when another app or Space becomes active.
/// - Its height limit comes from the visible frame of the screen the status item is on.
@MainActor
final class MenuBarController: NSObject {
    private let coordinator: SessionCoordinator
    private let statusItem: NSStatusItem
    private let model = MenuPanelModel()
    private var panel: MenuPanel?
    /// The height of the menu content, from SwiftUI. Nil until it is measured once.
    private var contentHeight: CGFloat?
    private var placeScheduled = false
    private var label: MenuBarLabel.Kind?
    /// Event monitors and notification observers that close the menu. Only while it is open.
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    var isOpen: Bool { panel?.isVisible == true }

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "TwinTake"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Like a menu: it opens on mouse down.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
        model.closeHandler = { [weak self] in self?.close() }
        model.heightHandler = { [weak self] in self?.contentHeightChanged($0) }
        updateLabel()
    }

    // MARK: - Status item

    /// Shows the icon for the current state, and again each time a value it reads changes (the
    /// elapsed time changes every second while recording).
    private func updateLabel() {
        let coordinator = coordinator
        let kind = withObservationTracking {
            MenuBarLabel.kind(state: coordinator.state, needsAttention: coordinator.needsAttention,
                              elapsed: coordinator.elapsedText)
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.updateLabel() }
        }
        guard kind != label, let button = statusItem.button else { return }
        label = kind
        button.image = kind.image
        button.setAccessibilityLabel(kind.accessibilityLabel)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if isOpen { close() } else { open() }
    }

    /// The status item stays highlighted while the menu is open. The button clears its highlight
    /// when the mouse goes up, so this sets it again after the click's tracking loop ends (that
    /// loop does not run blocks scheduled for the default run loop mode).
    private func keepHighlighted() {
        statusItem.button?.highlight(true)
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.statusItem.button?.highlight(true)
            }
        }
    }

    // MARK: - Open and close

    func open() {
        guard !isOpen else { return }
        let panel = self.panel ?? makePanel()
        model.opened()
        place()
        panel.makeKeyAndOrderFront(nil)
        refreshShadow()
        keepHighlighted()
        watchForClose()
        coordinator.setMenuVisible(true)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        stopWatching()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        coordinator.setMenuVisible(false)
    }

    // MARK: - Place

    /// The status item's window, in global AppKit coordinates. Nil while it is not on a screen.
    private var anchor: CGRect? {
        guard let window = statusItem.button?.window, window.isVisible else { return nil }
        return window.frame
    }

    /// Sets the panel's frame for the current content height: the top edge under the status item,
    /// on the screen the status item is on.
    private func place() {
        guard let panel else { return }
        let screens = NSScreen.screens.map { MenuPanelPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let anchor = anchor
        guard let screen = MenuPanelPlacement.screen(for: anchor, in: screens) else { return }
        let frame = MenuPanelPlacement.frame(contentHeight: contentHeight ?? MenuPanelPlacement.provisionalHeight,
                                             anchor: anchor, screen: screen)
        guard !MenuPanelPlacement.same(frame, panel.frame) else { return }
        panel.setFrame(frame, display: true)
        refreshShadow()
    }

    /// SwiftUI measured new content. The panel follows on the next turn of the run loop, not
    /// inside SwiftUI's layout pass; several changes in one turn give one resize.
    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0 else { return }
        if let contentHeight, abs(contentHeight - height) <= 0.5 { return }
        contentHeight = height
        guard !placeScheduled else { return }
        placeScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.placeScheduled = false
                if self.isOpen { self.place() }
            }
        }
    }

    /// The window shadow follows the window's shape only when it is computed again. Once now, and
    /// once after the resized content has been drawn, so no outline of the old size stays.
    private func refreshShadow() {
        panel?.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.panel?.invalidateShadow() }
        }
    }

    private func makePanel() -> MenuPanel {
        let size = CGSize(width: MenuPanelPlacement.width, height: MenuPanelPlacement.provisionalHeight)
        let panel = MenuPanel.make(size: size)
        panel.onCancel = { [weak self] in self?.close() }

        let radius = MenuPanelPlacement.cornerRadius
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .menu
        background.blendingMode = .behindWindow
        // Always the active look: TwinTake is not the active app while the menu shows.
        background.state = .active
        background.maskImage = Self.roundedMask(radius: radius)
        background.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: MenuContentView(coordinator: coordinator, menu: model))
        // The panel's size comes only from `place()`, never from Auto Layout.
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = radius
        hosting.layer?.masksToBounds = true
        background.addSubview(hosting)
        panel.contentView = background
        self.panel = panel
        // SwiftUI measures the content now, so the first open gets its height.
        background.layoutSubtreeIfNeeded()
        return panel
    }

    /// A stretchable rounded rectangle for the background's mask.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Closing

    private func watchForClose() {
        stopWatching()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A click in another app or in the menu bar.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(monitor) }
        // A click in another TwinTake window (the camera window). The status item's own click
        // toggles the menu in `statusItemClicked`.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clicked(in: event.window) }
            return event
        }) { monitors.append(monitor) }
        // Escape, whatever control has the focus.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.closesOnKey(event) == true } ? nil : event
        }) { monitors.append(monitor) }

        let workspace = NSWorkspace.shared.notificationCenter
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Another app became active (⌘Tab, a Dock click). The app that just became active is the
        // front app now.
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { controller in
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != ownPID { controller.close() }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.close() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.place() }
        // Another window took the keyboard (a system dialog, the folder picker). Checked one turn
        // later, so a short hand-over during a click does not close the menu.
        observe(.default, NSWindow.didResignKeyNotification, object: panel) { controller in
            DispatchQueue.main.async { [weak controller] in
                MainActor.assumeIsolated {
                    guard let controller, let panel = controller.panel, panel.isVisible, !panel.isKeyWindow else { return }
                    controller.close()
                }
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                         _ handler: @escaping @MainActor (MenuBarController) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
    }

    private func clicked(in window: NSWindow?) {
        guard let panel, panel.isVisible else { return }
        // The status item (on any display's menu bar): its action closes the menu.
        if let window, window === statusItem.button?.window || window.level == .statusBar { return }
        if MenuPanelPlacement.belongs(window, to: panel) { return }
        close()
    }

    private func closesOnKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible, MenuPanelPlacement.belongs(event.window, to: panel) else { return false }
        guard event.keyCode == MenuPanelPlacement.escapeKeyCode else { return false }
        close()
        return true
    }
}

/// What the menu view needs from its panel.
@MainActor
@Observable
final class MenuPanelModel {
    /// Goes up by one each time the menu opens.
    private(set) var openCount = 0
    @ObservationIgnored var closeHandler: (@MainActor () -> Void)?
    @ObservationIgnored var heightHandler: (@MainActor (CGFloat) -> Void)?

    func opened() { openCount += 1 }
    /// Closes the menu (for example after Start).
    func close() { closeHandler?() }
    /// The height of the whole menu content, scrolled or not.
    func contentHeightChanged(_ height: CGFloat) { heightHandler?(height) }
}

/// The menu window. It becomes key (keyboard, Escape) but never main, and it never activates
/// TwinTake. AppKit never moves it: only `MenuBarController.place()` does.
final class MenuPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    /// An empty menu panel, `size` big, with every window setting the menu needs.
    @MainActor static func make(size: CGSize) -> MenuPanel {
        let panel = MenuPanel(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the frame overlay and the camera window.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // NSPanel hides on deactivate by default; TwinTake is rarely the active app.
        panel.hidesOnDeactivate = false
        // The `.help` tooltips. TwinTake is not the active app while the menu shows (the panel is
        // non-activating), and AppKit shows no tooltip in an inactive app's window by default.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.title = "TwinTake"
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Where the menu panel goes, over plain rects (AppKit global coordinates: y up).
enum MenuPanelPlacement {
    static let width: CGFloat = 390
    /// Points between the bottom of the menu bar and the top edge of the panel.
    static let gapBelowMenuBar: CGFloat = 5
    /// Room kept free below the panel.
    static let bottomMargin: CGFloat = 24
    /// Room kept free at the left and right edges of the screen.
    static let sideMargin: CGFloat = 8
    static let minHeight: CGFloat = 200
    /// The height before SwiftUI has measured the content once.
    static let provisionalHeight: CGFloat = 600
    static let cornerRadius: CGFloat = 12
    /// kVK_Escape.
    static let escapeKeyCode: UInt16 = 53

    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// The screen the status item is on: the one that holds its center, else the one it overlaps
    /// most, else the first screen (the one with the menu bar). Each display has its own menu bar,
    /// so this is the display the user clicked on.
    static func screen(for anchor: CGRect?, in screens: [Screen]) -> Screen? {
        guard let anchor else { return screens.first }
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let hit = screens.first(where: { $0.frame.contains(center) }) { return hit }
        let overlaps = screens.compactMap { screen -> (Screen, CGFloat)? in
            let shared = screen.frame.intersection(anchor)
            return shared.isNull || shared.isEmpty ? nil : (screen, shared.width * shared.height)
        }
        return overlaps.max { $0.1 < $1.1 }?.0 ?? screens.first
    }

    /// The panel's top edge: `gapBelowMenuBar` under the status item, and never above the bottom
    /// of the menu bar. It does not depend on the content height.
    static func top(anchor: CGRect?, screen: Screen) -> CGFloat {
        let barBottom = min(anchor?.minY ?? screen.visibleFrame.maxY, screen.visibleFrame.maxY, screen.frame.maxY)
        return barBottom - gapBelowMenuBar
    }

    /// The tallest the panel may get under `top`: down to the bottom of the screen's visible frame
    /// (above the Dock), less `bottomMargin`. Taller content scrolls.
    static func maxHeight(top: CGFloat, screen: Screen) -> CGFloat {
        max(minHeight, top - screen.visibleFrame.minY - bottomMargin)
    }

    /// The panel's frame for content `contentHeight` tall: the top edge at `top(...)` whatever the
    /// height (so a shorter or taller menu moves only its bottom edge), centered under the status
    /// item and kept inside the screen's sides. Without a status item: at the right of the screen.
    static func frame(contentHeight: CGFloat, anchor: CGRect?, screen: Screen, width: CGFloat = width) -> CGRect {
        let top = top(anchor: anchor, screen: screen)
        let height = min(max(1, contentHeight.rounded(.up)), maxHeight(top: top, screen: screen))
        let visible = screen.visibleFrame
        let wanted = anchor.map { $0.midX - width / 2 } ?? (visible.maxX - sideMargin - width)
        let x = max(visible.minX + sideMargin, min(wanted, visible.maxX - sideMargin - width)).rounded()
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
            && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    /// True for the panel itself and for windows it opened (their parent chain leads to it).
    @MainActor static func belongs(_ window: NSWindow?, to panel: NSWindow) -> Bool {
        var current = window
        while let window = current {
            if window === panel { return true }
            current = window.parent
        }
        return false
    }
}
