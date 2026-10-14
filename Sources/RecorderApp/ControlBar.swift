import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers
import WindowTools

/// The control bar: a small floating bar, like CleanShot X's recording controls, that the user
/// parks anywhere (on the laptop: the gray strip above the bottom 16:9 frame). Left to right:
/// - Record / Stop with the elapsed time: the main Start and Stop.
/// - The pinned apps: one click brings the app forward and snaps its front window into the
///   frame (with its profile: Parallels keeps its toolbar above the frame). "+" pins the app that
///   was in front; more than `PinnedApps.maxVisible` go into an overflow menu.
/// - Flag: something in the last few minutes was wrong (a `marker` of kind `flag`).
/// - Replay: what was just recorded, with the screen, while the take goes on (ReplayWindow.swift).
/// - A thin vertical meter of the Mac mic, while the meters run (the camera window shows the
///   camera mic along its bottom edge).
///
/// - A non-activating panel that never becomes key: a click on it never makes TwinTake the
///   active app or takes the keyboard. An app button activates that app, not TwinTake.
/// - Never recorded: `sharingType = .none`, and the screen recorder leaves out TwinTake's windows.
/// - Just above the frame overlay (`FrameOverlay.aboveOverlayLevel`): never dimmed, and other
///   apps' menus and popovers open over it.
/// - It remembers its place on each display (`ControlBarGeometry`); it is kept on screen when
///   the displays change.
///
/// Camera thread rule (CameraCapture/CaptureThreads.swift): the bar holds no capture object. Its
/// meter reads the coordinator's `meters` copy.
@MainActor
final class ControlBarController {
    private weak var coordinator: SessionCoordinator?
    private var panel: ControlBarPanel?
    private var bar: ControlBarView?
    private let presence = AppPresence()
    private var content: ControlBarContent?
    /// The bar should show: `show()` was called and `hide()` was not.
    private var wanted = false
    private var renderScheduled = false

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the bar at its saved place (or the default place). Does nothing when it shows.
    func show() {
        wanted = true
        presence.start()
        let panel = self.panel ?? makePanel()
        render()
        guard !panel.isVisible else { return }
        if let frame = openingFrame(size: panel.frame.size) { panel.setFrame(frame, display: false) }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        wanted = false
        presence.stop()
        panel?.orderOut(nil)
    }

    /// Takes the bar off screen for good (Quit).
    func close() {
        hide()
        panel?.close()
        panel = nil
        bar = nil
    }

    /// After a display change: keeps the bar inside the visible screens, or moves it to its
    /// place on a connected display when its display went away.
    func screensChanged() {
        guard let panel, panel.isVisible else { return }
        let screens = CameraWindowController.screens()
        if let kept = ControlBarGeometry.clamped(panel.frame, screens: screens) {
            if kept != panel.frame { panel.setFrame(kept, display: true) }
        } else if let frame = openingFrame(size: panel.frame.size) {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    /// Forgets the saved place on the bar's display and on the recording display, and puts the
    /// bar at the default place.
    func resetPosition() {
        guard let coordinator else { return }
        let settings = coordinator.settings
        let screens = CameraWindowController.screens()
        if let panel, let screen = CameraWindowGeometry.screen(containing: panel.frame, in: screens) {
            settings.controlBarPlaces[screen.uuid] = nil
        }
        if let uuid = coordinator.controlBarFrameHint?.displayUUID { settings.controlBarPlaces[uuid] = nil }
        settings.controlBarLastDisplay = nil
        guard let panel, panel.isVisible, let frame = openingFrame(size: panel.frame.size) else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: - Content

    /// Reads what the bar shows, applies it, and reads it again when a value it read changes
    /// (the elapsed time changes every second while recording). The meter is its own SwiftUI
    /// view, so the 20 Hz meter poll never comes here.
    private func render() {
        guard wanted, let coordinator, let bar else { return }
        let presence = presence
        let next = withObservationTracking {
            ControlBarContent(coordinator: coordinator, presence: presence)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRender() }
        }
        guard next != content else { return }
        content = next
        bar.apply(next)
        fitToContent()
    }

    /// One render for any number of changes in one turn of the run loop.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    /// The bar grew or shrank (an app pinned or removed, the meter): same center, kept on screen.
    private func fitToContent() {
        guard let panel, let bar else { return }
        let size = bar.fittingContentSize
        guard size != panel.frame.size else { return }
        let screen = CameraWindowGeometry.screen(containing: panel.frame, in: CameraWindowController.screens())
        let frame = panel.isVisible ? ControlBarGeometry.resized(panel.frame, to: size, on: screen)
            : CGRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: - Panel

    private func makePanel() -> ControlBarPanel {
        let bar = ControlBarView(coordinator: coordinator)
        let panel = ControlBarPanel.make(size: CGSize(width: 240, height: ControlBarView.height))
        bar.frame = CGRect(origin: .zero, size: panel.frame.size)
        bar.autoresizingMask = [.width, .height]
        bar.onRecord = { [weak self] in self?.coordinator?.toggleRecording() }
        bar.onFlag = { [weak self] in self?.coordinator?.flag() }
        bar.onReplay = { [weak self] in self?.coordinator?.toggleReplay() }
        bar.onPin = { [weak self] in self?.coordinator?.pinFrontApp() }
        bar.onApp = { [weak self] app in self?.coordinator?.switchToPinnedApp(app) }
        bar.makeAppMenu = { [weak self] app in self?.appMenu(app) }
        bar.makeBarMenu = { [weak self] in self?.barMenu() }
        bar.onMoved = { [weak self] in self?.frameCommitted() }
        panel.contentView = bar
        self.panel = panel
        self.bar = bar
        return panel
    }

    private func openingFrame(size: CGSize) -> CGRect? {
        guard let coordinator else { return nil }
        let hint = coordinator.controlBarFrameHint
        return ControlBarGeometry.openingFrame(size: size, screens: CameraWindowController.screens(),
                                               saved: coordinator.settings.controlBarPlaces,
                                               lastScreenUUID: coordinator.settings.controlBarLastDisplay,
                                               recordingScreenUUID: hint?.displayUUID, frame: hint?.frame,
                                               reservedAbovePt: hint?.reservedAbovePt ?? 0)?.rect
    }

    /// After the user dragged the bar: keep it on its screen, then save its place for that screen.
    private func frameCommitted() {
        guard let panel, let settings = coordinator?.settings else { return }
        let screens = CameraWindowController.screens()
        if let kept = ControlBarGeometry.clamped(panel.frame, screens: screens), kept != panel.frame {
            panel.setFrame(kept, display: true)
        }
        panel.invalidateShadow()
        guard let screen = CameraWindowGeometry.screen(containing: panel.frame, in: screens) else { return }
        settings.controlBarPlaces[screen.uuid] = ControlBarGeometry.localCenter(of: panel.frame, on: screen)
        settings.controlBarLastDisplay = screen.uuid
    }

    // MARK: - Menus

    /// Right-click on an app button.
    private func appMenu(_ app: PinnedApp) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(BarMenuAction.item("Switch to \(app.name)") { [weak self] in self?.coordinator?.switchToPinnedApp(app) })
        menu.addItem(.separator())
        let list = coordinator?.settings.pinnedApps ?? []
        let left = BarMenuAction.item("Move Left") { [weak self] in self?.coordinator?.movePinnedApp(app, by: -1) }
        left.isEnabled = list.first != app
        menu.addItem(left)
        let right = BarMenuAction.item("Move Right") { [weak self] in self?.coordinator?.movePinnedApp(app, by: 1) }
        right.isEnabled = list.last != app
        menu.addItem(right)
        menu.addItem(BarMenuAction.item("Remove \(app.name)") { [weak self] in self?.coordinator?.removePinnedApp(app) })
        menu.addItem(.separator())
        addBarItems(to: menu)
        menu.autoenablesItems = false
        return menu
    }

    /// Right-click on the bar.
    private func barMenu() -> NSMenu {
        let menu = NSMenu()
        let pin = BarMenuAction.item(coordinator?.pinCandidate().map { "Pin \($0.name)" } ?? "Pin the Front App") { [weak self] in
            self?.coordinator?.pinFrontApp()
        }
        menu.addItem(pin)
        menu.addItem(.separator())
        addBarItems(to: menu)
        menu.autoenablesItems = false
        return menu
    }

    private func addBarItems(to menu: NSMenu) {
        menu.addItem(BarMenuAction.item("Move to the Default Place") { [weak self] in self?.resetPosition() })
        menu.addItem(BarMenuAction.item("Hide Control Bar") { [weak self] in self?.coordinator?.setControlBarShown(false) })
    }
}

/// What the bar shows: plain data, compared before each redraw.
struct ControlBarContent: Equatable {
    struct App: Equatable {
        var app: PinnedApp
        var running: Bool
        /// The app (or, for Parallels, one of its processes) is the front app.
        var front: Bool
    }

    var record: ControlBarRules.RecordButton
    var apps: [App]
    var overflow: [App]
    var pinHelp: String
    var flagEnabled: Bool
    var flagHelp: String
    var replayEnabled: Bool
    var replayShown: Bool
    var replayHelp: String
    var meterShown: Bool
    var flash: ControlBarFlash?

    @MainActor
    init(coordinator c: SessionCoordinator, presence: AppPresence) {
        let blocker = c.state == .idle ? SessionRules.blockers(c.issues).first?.message : nil
        record = ControlBarRules.recordButton(state: c.state, blocker: blocker, attention: c.attentionText,
                                              elapsed: c.elapsedText)
        let pinned = c.settings.pinnedApps
        let front = PinnedApps.app(for: presence.front, in: pinned)
        func state(_ app: PinnedApp) -> App {
            App(app: app, running: presence.running.contains(app.bundleID), front: front == app)
        }
        let split = PinnedApps.split(pinned)
        apps = split.visible.map(state)
        overflow = split.overflow.map(state)
        // `presence.front` was read above, so the help follows the front app.
        if let candidate = c.pinCandidate() {
            pinHelp = pinned.contains(where: { $0.bundleID == candidate.bundleID })
                ? "\(candidate.name) is pinned. Click another app, then + to pin it."
                : "Pin \(candidate.name): one click on its button then brings it forward and snaps it into the frame."
        } else {
            pinHelp = "Click the app you want to pin, then +."
        }
        let recording = c.state == .recording
        flagEnabled = recording
        flagHelp = ControlBarRules.flagHelp(recording: recording, lookbackS: c.settings.flagLookbackSeconds)
        let replay = c.replayTarget
        replayShown = c.replayShown
        replayEnabled = replayShown || replay.folder != nil
        replayHelp = ReplayRules.help(replay, shown: replayShown)
        meterShown = c.controlBarShowsMeter
        flash = c.controlBarFlash
    }
}

/// The running apps and the front app, for the app buttons (dimmed when not running, lit while
/// in front). Follows NSWorkspace's launch, quit and activation notifications while the bar shows.
@MainActor
@Observable
final class AppPresence {
    private(set) var running: Set<String> = []
    private(set) var front: String?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    func start() {
        guard tokens.isEmpty else { return }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    private func refresh() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.isTerminated ? nil : $0.bundleIdentifier })
        if ids != running { running = ids }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontID != front { front = frontID }
    }
}

/// App icons by bundle id, for the bar and the settings list.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// The app's icon `side` points square: from its bundle on disk, else from the running app,
    /// else the generic app icon.
    static func icon(for bundleID: String, side: CGFloat = 18) -> NSImage {
        let image = cached(bundleID) ?? NSWorkspace.shared.icon(for: .application)
        let sized = (image.copy() as? NSImage) ?? image
        sized.size = NSSize(width: side, height: side)
        return sized
    }

    private static func cached(_ bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        var found: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            found = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).lazy.compactMap(\.icon).first
        }
        // A miss is not cached: the app may be installed or started later.
        if let found { cache[bundleID] = found }
        return found
    }
}

// MARK: - Window

/// The bar's window. It never becomes key or main, so it never takes the keyboard or makes
/// TwinTake active. Only `ControlBarController` and the bar's own drag move it.
final class ControlBarPanel: NSPanel {
    @MainActor static func make(size: CGSize) -> ControlBarPanel {
        let panel = ControlBarPanel(contentRect: CGRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Just above the frame overlay: never dimmed; other apps' menus and popovers open over it.
        panel.level = FrameOverlay.aboveOverlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Never in screen.mov, also for a capture that does not leave TwinTake out.
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        // NSPanel hides on deactivate by default; TwinTake is rarely the active app.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // The button tooltips, while another app is active.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "TwinTake Control Bar"
        return panel
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The bar's views, laid out by hand from left to right (no Auto Layout: the panel takes the
/// size the layout gives). A drag anywhere outside a button moves the bar.
final class ControlBarView: NSView {
    static let height: CGFloat = 34
    static let cornerRadius: CGFloat = 10
    static let recordWidth: CGFloat = 112
    static let buttonHeight: CGFloat = 26

    var onRecord: (() -> Void)?
    var onFlag: (() -> Void)?
    var onReplay: (() -> Void)?
    var onPin: (() -> Void)?
    var onApp: ((PinnedApp) -> Void)?
    var makeAppMenu: ((PinnedApp) -> NSMenu?)?
    var makeBarMenu: (() -> NSMenu?)?
    var onMoved: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let grip = GripView()
    private let record = BarButton()
    private let firstSeparator = SeparatorView()
    private let secondSeparator = SeparatorView()
    private var appButtons: [(app: PinnedApp, button: BarButton)] = []
    private let overflowButton = BarButton()
    private let pinButton = BarButton()
    private let flagButton = BarButton()
    private let replayButton = BarButton()
    private let meter: NSView
    private let flashView = FlashView()
    private var overflowApps: [ControlBarContent.App] = []

    init(coordinator: SessionCoordinator?) {
        if let coordinator {
            let hosting = PassThroughHostingView(rootView: ControlBarMicMeter(coordinator: coordinator))
            hosting.sizingOptions = []
            meter = hosting
        } else {
            meter = NSView()
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: Self.height))
        wantsLayer = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)

        for view in [grip, record, firstSeparator, overflowButton, pinButton, secondSeparator, flagButton, replayButton,
                     meter] as [NSView] {
            addSubview(view)
        }
        meter.isHidden = true

        record.textFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        record.target = self
        record.action = #selector(recordClicked)

        overflowButton.setSymbol("chevron.down", size: 10)
        overflowButton.toolTip = "More pinned apps"
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        overflowButton.isHidden = true

        pinButton.setSymbol("plus", size: 12)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pinButton.setAccessibilityLabel("Pin the front app")

        flagButton.setSymbol("flag.fill", size: 12)
        flagButton.target = self
        flagButton.action = #selector(flagClicked)
        flagButton.setAccessibilityLabel("Flag a mistake")

        replayButton.setSymbol("play.rectangle.fill", size: 12)
        replayButton.target = self
        replayButton.action = #selector(replayClicked)
        replayButton.setAccessibilityLabel("Replay")

        addSubview(flashView)
        flashView.isHidden = true
        layoutItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    func apply(_ content: ControlBarContent) {
        let look = content.record
        record.text = look.title
        record.setSymbol(look.symbol, size: 11, color: look.tone == .neutral && look.enabled && look.symbol == "record.circle.fill"
                         ? .systemRed : nil)
        record.fill = Self.fill(for: look.tone)
        record.isEnabled = look.enabled
        record.toolTip = look.help
        record.setAccessibilityLabel(look.title)

        let apps = content.apps.map(\.app)
        if apps != appButtons.map(\.app) { rebuildAppButtons(apps) }
        for (state, entry) in zip(content.apps, appButtons) {
            entry.button.dimmed = !state.running
            entry.button.selected = state.front
            entry.button.toolTip = state.running
                ? "\(state.app.name): bring it forward and snap its front window into the frame."
                : "\(state.app.name) is not running. Click to open it and snap it into the frame."
        }
        overflowApps = content.overflow
        overflowButton.isHidden = content.overflow.isEmpty
        overflowButton.selected = content.overflow.contains(where: \.front)

        pinButton.toolTip = content.pinHelp
        flagButton.isEnabled = content.flagEnabled
        flagButton.toolTip = content.flagHelp
        replayButton.isEnabled = content.replayEnabled
        replayButton.selected = content.replayShown
        replayButton.toolTip = content.replayHelp
        meter.isHidden = !content.meterShown
        meter.toolTip = "Mac mic"

        if let flash = content.flash {
            flashView.show(flash.text, fill: Self.fill(for: flash.tone, flash: true))
        } else {
            flashView.isHidden = true
        }
        layoutItems()
    }

    private func rebuildAppButtons(_ apps: [PinnedApp]) {
        appButtons.forEach { $0.button.removeFromSuperview() }
        appButtons = apps.map { app in
            let button = BarButton()
            button.text = app.shortName
            button.image = AppIcons.icon(for: app.bundleID)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(appClicked(_:))
            // Built at the right-click, so Move Left and Move Right follow the list as it is then.
            button.makeMenu = { [weak self] in self?.makeAppMenu?(app) }
            button.setAccessibilityLabel(app.name)
            addSubview(button, positioned: .below, relativeTo: flashView)
            return (app, button)
        }
    }

    /// The size the layout needs.
    var fittingContentSize: CGSize { CGSize(width: layoutItems(apply: false), height: Self.height) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutItems()
    }

    /// Places every visible item from left to right, centered vertically. Returns the width.
    @discardableResult
    private func layoutItems(apply: Bool = true) -> CGFloat {
        var x: CGFloat = 6
        let midY = Self.height / 2
        /// `reserved`: the slot stays while the view is hidden, so the bar does not move.
        func place(_ view: NSView, width: CGFloat, height: CGFloat = ControlBarView.buttonHeight, gapAfter: CGFloat,
                   reserved: Bool = false) {
            guard !view.isHidden || reserved else { return }
            if apply { view.frame = CGRect(x: x, y: (midY - height / 2).rounded(), width: width, height: height) }
            x += width + gapAfter
        }
        place(grip, width: 8, height: 18, gapAfter: 4)
        place(record, width: Self.recordWidth, gapAfter: 6)
        place(firstSeparator, width: 1, height: 18, gapAfter: 6)
        for entry in appButtons { place(entry.button, width: entry.button.contentWidth(padding: 8), gapAfter: 2) }
        place(overflowButton, width: 20, gapAfter: 2)
        place(pinButton, width: 24, gapAfter: 6)
        place(secondSeparator, width: 1, height: 18, gapAfter: 6)
        place(flagButton, width: 28, gapAfter: 2)
        place(replayButton, width: 28, gapAfter: 6)
        // The meter comes and goes with the meters (the camera window, a take): its slot stays.
        place(meter, width: 5, height: 22, gapAfter: 6, reserved: true)
        let width = (x + 2).rounded(.up)
        if apply, !flashView.isHidden {
            let span = Self.flashSpan(recordMinX: record.frame.minX, recordMaxX: record.frame.maxX, barWidth: bounds.width,
                                      textWidth: flashView.textWidth)
            flashView.frame = CGRect(x: span.x, y: (midY - Self.buttonHeight / 2).rounded(), width: span.width,
                                     height: Self.buttonHeight)
            flashView.needsLayout = true
        }
        return width
    }

    /// Where the flash goes, in bar coordinates: over the app buttons, right of the Record
    /// button. When its text needs more room (no or one pinned app: the bar is short), it reaches
    /// left over the Record button, as far as the Record button's left edge, so the text is not
    /// cut. Clicks go through it.
    nonisolated static func flashSpan(recordMinX: CGFloat, recordMaxX: CGFloat, barWidth: CGFloat,
                          textWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let right = barWidth - 6
        let needed = ceil(textWidth) + 2 * FlashView.textInset + 2
        let beside = recordMaxX + 6
        let left = right - beside >= needed ? beside : max(recordMinX, right - needed)
        return (left, max(40, right - left))
    }

    private static func fill(for tone: ControlBarRules.Tone, flash: Bool = false) -> NSColor {
        switch tone {
        case .neutral: flash ? NSColor(white: 0.24, alpha: 0.98) : NSColor.white.withAlphaComponent(0.12)
        case .recording: .systemRed
        case .problem: .systemOrange
        case .good: NSColor.systemGreen.blended(withFraction: 0.35, of: .black) ?? .systemGreen
        }
    }

    // MARK: Clicks

    @objc private func recordClicked() { onRecord?() }
    @objc private func flagClicked() { onFlag?() }
    @objc private func replayClicked() { onReplay?() }
    @objc private func pinClicked() { onPin?() }

    @objc private func appClicked(_ sender: BarButton) {
        guard let app = appButtons.first(where: { $0.button === sender })?.app else { return }
        onApp?(app)
    }

    @objc private func overflowClicked() {
        let menu = NSMenu()
        for state in overflowApps {
            let app = state.app
            let item = BarMenuAction.item(app.name) { [weak self] in self?.onApp?(app) }
            item.image = AppIcons.icon(for: app.bundleID, side: 16)
            item.state = state.front ? .on : .off
            item.toolTip = state.running ? nil : "\(app.name) is not running. Click to open it."
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: overflowButton)
    }

    // A click outside a button moves the bar; the buttons take their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return current }
            view = current.superview
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { makeBarMenu?() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = makeBarMenu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        trackMove()
    }

    /// Moves the bar with the mouse until the button goes up. The drag runs AppKit's
    /// event-tracking loop; it waits for no capture queue.
    private func trackMove() {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let mouse = NSEvent.mouseLocation
            let origin = NSPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y)
            if origin != window.frame.origin {
                window.setFrameOrigin(origin)
                moved = true
            }
            if event.type == .leftMouseUp { stop.pointee = true }
        }
        if moved { onMoved?() }
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
}

/// A bar button: borderless, with its own fill, a hover and a pressed look, white content. It
/// takes the first click in a window of an app that is not active, and never the keyboard focus.
final class BarButton: NSButton {
    var fill: NSColor = .clear { didSet { refresh() } }
    /// Lit: the pinned app that is in front.
    var selected = false { didSet { refresh() } }
    /// Faded: a pinned app that is not running.
    var dimmed = false { didSet { refresh() } }
    /// The title, white, in `textFont`.
    var text = "" { didSet { if text != oldValue { updateTitle() } } }
    /// The right-click menu, built when it opens.
    var makeMenu: (() -> NSMenu?)?
    var textFont = NSFont.systemFont(ofSize: 11, weight: .medium) { didSet { updateTitle() } }
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { refresh() }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        imageHugsTitle = true
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        refusesFirstResponder = true
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        updateTitle()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() ?? super.menu(for: event) }

    func setSymbol(_ name: String, size: CGFloat, color: NSColor? = nil) {
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        if let color { config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color])) }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        // A colored symbol keeps its color; a plain one takes the white tint.
        symbol?.isTemplate = color == nil
        image = symbol
        imagePosition = text.isEmpty ? .imageOnly : .imageLeading
    }

    /// The width for the image, the title and `padding` on each side.
    func contentWidth(padding: CGFloat) -> CGFloat {
        let label = text.isEmpty ? 0 : ceil(attributedTitle.size().width)
        let icon = image.map { $0.size.width } ?? 0
        let gap: CGFloat = icon > 0 && label > 0 ? 4 : 0
        return max(Self.minWidth, ceil(icon + gap + label + 2 * padding))
    }

    private static let minWidth: CGFloat = 24

    private func updateTitle() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: textFont, .foregroundColor: NSColor.white, .paragraphStyle: style,
        ])
        imagePosition = text.isEmpty ? .imageOnly : .imageLeading
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Always active: TwinTake is almost never the active app.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        refresh()
    }

    private func refresh() {
        var color = fill
        if selected, color.alphaComponent < 0.2 { color = NSColor.white.withAlphaComponent(0.2) }
        if isEnabled {
            if pressed {
                color = color.alphaComponent < 0.3 ? NSColor.white.withAlphaComponent(0.28)
                    : color.blended(withFraction: 0.25, of: .black) ?? color
            } else if hovering {
                color = color.alphaComponent < 0.3 ? NSColor.white.withAlphaComponent(0.16)
                    : color.blended(withFraction: 0.15, of: .white) ?? color
            }
        }
        layer?.backgroundColor = color.cgColor
        alphaValue = !isEnabled ? 0.4 : dimmed ? 0.5 : 1
    }
}

/// The short confirmation over the app buttons for a moment ("Flagged · last 3 min"); a longer
/// text also covers the Record button (`ControlBarView.flashSpan`). Clicks go through it to the
/// buttons under it.
final class FlashView: NSView {
    /// Space between the flash's edges and its text.
    nonisolated static let textInset: CGFloat = 6
    private let label = NSTextField(labelWithString: "")

    /// The text's width on one line.
    var textWidth: CGFloat { ceil(label.intrinsicContentSize.width) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, fill: NSColor) {
        label.stringValue = text
        label.setAccessibilityLabel(text)
        layer?.backgroundColor = fill.cgColor
        isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: Self.textInset, y: ((bounds.height - height) / 2).rounded(),
                             width: max(0, bounds.width - 2 * Self.textInset), height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Two columns of dots at the bar's left edge: where to grab it.
private final class GripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.35).setFill()
        let dot: CGFloat = 2, gap: CGFloat = 2
        for column in 0..<2 {
            for row in 0..<4 {
                let x = bounds.midX - dot - gap / 2 + CGFloat(column) * (dot + gap)
                let y = bounds.midY - 2 * dot - 1.5 * gap + CGFloat(row) * (dot + gap)
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A SwiftUI view that never takes a click: a drag on it moves the bar.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Mac mic's level as a thin vertical bar: green, yellow above -12 dBFS, red above -3 dBFS,
/// with the 1.5 s peak tick. Its own view, so the 20 Hz meter poll redraws only it.
struct ControlBarMicMeter: View {
    let coordinator: SessionCoordinator

    var body: some View {
        LevelMeterBar(level: coordinator.meters?.screenMic, vertical: true, trackColor: .white.opacity(0.22))
            .accessibilityLabel("Mac mic level")
    }
}

/// A menu item that runs a closure. The bar never becomes key, so its menu items target their
/// own action object instead of the responder chain.
private final class BarMenuAction: NSObject {
    private let run: @MainActor () -> Void

    private init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    @MainActor static func item(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = BarMenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(runAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action  // The item keeps its target alive.
        return item
    }

    @MainActor @objc private func runAction() { run() }
}
