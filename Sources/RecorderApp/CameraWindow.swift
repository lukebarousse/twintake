import AppKit
import CameraCapture
import SwiftUI
import WindowTools

/// The floating picture-in-picture camera window: the live camera picture, so the speaker can
/// watch themselves on the Mac while recording.
///
/// - A non-activating panel: clicking it never makes TwinTake the active app, so the front app
///   (the one "Snap the front window" moves) stays in front.
/// - Just above the frame overlay (`FrameOverlay.aboveOverlayLevel`, the floating level + 1), so it
///   is never dimmed, and still above normal windows. Other apps' menu bar menus and popovers open
///   over it; TwinTake's own menu is above it.
/// - Never recorded: `sharingType = .none`, and the screen recorder's region filter leaves out
///   TwinTake's windows (and records what is under them).
/// - It moves and resizes (16:9, at least 240x135) by its own drag code, and remembers its place
///   per display.
///
/// Camera thread rule (CameraCapture/CaptureThreads.swift): this window holds no capture object.
/// It shows `CameraPreviewView(feed:)`, whose view only attaches its display layer to the feed.
@MainActor
final class CameraWindowController {
    private weak var coordinator: SessionCoordinator?
    private var panel: CameraMonitorPanel?
    private var container: CameraMonitorContainer?

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Takes the window off screen for good (Quit).
    func close() {
        hide()
        panel?.close()
        panel = nil
        container = nil
    }

    /// Shows the window at its saved place (or the default place). Does nothing when it shows.
    func show() {
        guard let coordinator else { return }
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            if let frame = openingFrame() { panel.setFrame(frame, display: false) }
            // A new view each time: the hidden window keeps no display layer attached to the feed.
            let view = CameraMonitorView(coordinator: coordinator) { [weak container] placement in
                container?.setReconnect(placement)
            }
            container?.setContent(NSHostingView(rootView: view))
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
    }

    /// Hides the window and drops its view, so its display layer leaves the feed.
    func hide() {
        guard let panel, panel.isVisible || container?.hasContent == true else { return }
        panel.orderOut(nil)
        container?.setContent(nil)
    }

    /// After a display change: keeps the window inside the visible screens, or moves it to its
    /// place on a connected display when its display went away.
    func screensChanged() {
        guard let panel, panel.isVisible else { return }
        let screens = Self.screens()
        if let kept = CameraWindowGeometry.clamped(panel.frame, screens: screens) {
            if kept != panel.frame { panel.setFrame(kept, display: true) }
        } else if let frame = openingFrame() {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    // MARK: - Panel

    private func makePanel() -> CameraMonitorPanel {
        let size = CameraWindowGeometry.SizePreset.medium.size
        let panel = CameraMonitorPanel(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = FrameOverlay.aboveOverlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        // NSPanel hides on deactivate by default; TwinTake is rarely the active app.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = true
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.contentMinSize = CameraWindowGeometry.minSize
        panel.title = "TwinTake Camera"

        let container = CameraMonitorContainer(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        container.onClose = { [weak self] in self?.coordinator?.setCameraWindowShown(false) }
        container.onReconnect = { [weak self] in self?.coordinator?.reconnectCamera() }
        container.makeMenu = { [weak self] in self?.makeMenu() }
        container.onFrameCommitted = { [weak self] in self?.frameCommitted() }
        container.maxSize = { [weak panel] in (panel?.screen ?? NSScreen.main)?.visibleFrame.size }
        panel.contentView = container
        self.panel = panel
        self.container = container
        return panel
    }

    // MARK: - Place

    /// The visible screens as plain geometry.
    static func screens() -> [MonitorScreen] {
        NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            return MonitorScreen(uuid: uuid ?? "display-\(id)", frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    private func openingFrame() -> CGRect? {
        guard let settings = coordinator?.settings else { return nil }
        return CameraWindowGeometry.openingFrame(screens: Self.screens(), saved: settings.cameraWindowFrames,
                                                 lastScreenUUID: settings.cameraWindowLastDisplay,
                                                 frameDisplayUUID: coordinator?.recordingFrameDisplayUUID)?.rect
    }

    /// After the user moved or resized the window: keep it fully on its screen, then save its
    /// place for that screen.
    private func frameCommitted() {
        guard let panel, let settings = coordinator?.settings else { return }
        let screens = Self.screens()
        if let kept = CameraWindowGeometry.clamped(panel.frame, screens: screens), kept != panel.frame {
            panel.setFrame(kept, display: true)
        }
        panel.invalidateShadow()
        guard let screen = CameraWindowGeometry.screen(containing: panel.frame, in: screens) else { return }
        settings.cameraWindowFrames[screen.uuid] = CameraWindowGeometry.local(panel.frame, on: screen)
        settings.cameraWindowLastDisplay = screen.uuid
    }

    private func apply(_ preset: CameraWindowGeometry.SizePreset) {
        guard let panel else { return }
        let screen = CameraWindowGeometry.screen(containing: panel.frame, in: Self.screens())
        panel.setFrame(CameraWindowGeometry.resized(panel.frame, to: preset.size, on: screen), display: true)
        frameCommitted()
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let mirror = MenuAction.item("Mirror") { [weak self] in
            guard let settings = self?.coordinator?.settings else { return }
            settings.cameraWindowMirrored.toggle()
        }
        mirror.state = coordinator?.settings.cameraWindowMirrored == true ? .on : .off
        menu.addItem(mirror)

        let sizes = NSMenu()
        let current = panel.map { CGSize(width: $0.frame.width.rounded(), height: $0.frame.height.rounded()) }
        for preset in CameraWindowGeometry.SizePreset.allCases {
            let item = MenuAction.item(preset.title) { [weak self] in self?.apply(preset) }
            item.state = current == preset.size ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        if coordinator?.micCheck != nil {
            menu.addItem(MenuAction.item("Cancel Mic Check") { [weak self] in self?.coordinator?.cancelMicCheck() })
        } else {
            let check = MenuAction.item("Mic Check") { [weak self] in self?.coordinator?.startMicCheck() }
            let reason = coordinator?.micCheckUnavailableReason
            check.isEnabled = reason == nil
            check.toolTip = reason ?? "Talk for 10 s: checks that the camera hears the \(MicNames.external)."
            menu.addItem(check)
        }
        let reconnect = MenuAction.item("Reconnect Camera") { [weak self] in self?.coordinator?.reconnectCamera() }
        reconnect.isEnabled = coordinator?.canReconnectCamera == true
        reconnect.toolTip = "Closes the camera and opens it again, like a replug. Only while nothing records."
        menu.addItem(reconnect)

        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Hide (\(HotKey.cameraWindow.displayString))") { [weak self] in
            self?.coordinator?.setCameraWindowShown(false)
        })
        // The items say themselves whether they are enabled.
        menu.autoenablesItems = false
        return menu
    }
}

/// A menu item that runs a closure. The camera window never becomes key, so its menu items
/// target their own action object instead of the responder chain.
private final class MenuAction: NSObject {
    private let run: @MainActor () -> Void

    private init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    @MainActor static func item(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(runAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action  // The item keeps its target alive.
        return item
    }

    @MainActor @objc private func runAction() { run() }
}

/// The camera window. It never becomes key or main, so it never takes the keyboard or makes
/// TwinTake active.
final class CameraMonitorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Its place is kept on screen by CameraWindowGeometry; double-click zoom would break 16:9.
    override func zoom(_ sender: Any?) {}
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The window's content: rounded corners, the SwiftUI picture, a close button on hover, the
/// right-click menu, and drag to move or (near the border) resize.
final class CameraMonitorContainer: NSView {
    static let cornerRadius: CGFloat = 12
    /// A mouse-down this close to the border resizes the window.
    static let resizeBand: CGFloat = 10

    var onClose: (() -> Void)?
    var onReconnect: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    var onFrameCommitted: (() -> Void)?
    var maxSize: (() -> CGSize?)?

    private let closeButton = FirstMouseButton()
    /// "Reconnect Camera" under the window's banner, while the camera sends empty frames and
    /// nothing records. A native button, so it takes the first click without activating TwinTake.
    private let reconnectButton = FirstMouseButton()
    private var content: NSView?
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet { if hovering != oldValue { closeButton.isHidden = !hovering } }
    }

    var hasContent: Bool { content != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide the camera window")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        closeButton.image = image
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Hide the camera window (\(HotKey.cameraWindow.displayString))"
        closeButton.frame = NSRect(x: 8, y: frameRect.height - 30, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)

        reconnectButton.title = "Reconnect Camera"
        reconnectButton.bezelStyle = .push
        reconnectButton.controlSize = .small
        reconnectButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reconnectButton.appearance = NSAppearance(named: .darkAqua)
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectClicked)
        reconnectButton.toolTip = "Closes the camera and opens it again, like a replug."
        reconnectButton.sizeToFit()
        reconnectButton.autoresizingMask = [.minXMargin, .maxYMargin]
        reconnectButton.isHidden = true
        addSubview(reconnectButton)
    }

    /// Shows or hides "Reconnect Camera" at the bottom-right corner, above the meter bar when it shows.
    func setReconnect(_ placement: ReconnectPlacement) {
        if placement.shown {
            let size = reconnectButton.fittingSize
            let frame = NSRect(x: bounds.width - size.width - 8, y: placement.bottom, width: size.width, height: size.height)
            if reconnectButton.frame != frame { reconnectButton.frame = frame }
        }
        if reconnectButton.isHidden == placement.shown { reconnectButton.isHidden = !placement.shown }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts `view` (the SwiftUI picture) under the close and reconnect buttons, or removes it.
    func setContent(_ view: NSView?) {
        content?.removeFromSuperview()
        content = view
        guard let view else {
            reconnectButton.isHidden = true
            return
        }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        if let hosting = view as? NSHostingView<CameraMonitorView> {
            // The window sets its own size; the SwiftUI content never resizes it.
            hosting.sizingOptions = []
        }
        // Under both buttons (the close button is the lower one).
        addSubview(view, positioned: .below, relativeTo: closeButton)
    }

    // The picture never takes a click: drags, the menu and hover are handled here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        if !reconnectButton.isHidden, reconnectButton.frame.contains(local) { return reconnectButton }
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func closeClicked() { onClose?() }
    @objc private func reconnectClicked() { onReconnect?() }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Always active: TwinTake is almost never the active app.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = true
        let point = convert(event.locationInWindow, from: nil)
        if let corner = CameraWindowGeometry.corner(at: point, in: bounds, edge: Self.resizeBand) {
            NSCursor.frameResize(position: Self.cursorPosition(corner), directions: .all).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func cursorPosition(_ corner: CameraWindowGeometry.Corner) -> NSCursor.FrameResizePosition {
        switch corner {
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        case .topLeft: .topLeft
        case .topRight: .topRight
        }
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    // MARK: Move and resize

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = makeMenu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let corner = CameraWindowGeometry.corner(at: point, in: bounds, edge: Self.resizeBand) {
            trackResize(from: corner)
        } else {
            trackMove()
        }
    }

    /// Moves the window with the mouse until the button goes up. The drag runs AppKit's
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
        if moved { onFrameCommitted?() }
    }

    /// Resizes from `corner`, 16:9, the opposite corner fixed, until the button goes up.
    private func trackResize(from corner: CameraWindowGeometry.Corner) {
        guard let window else { return }
        let start = window.frame
        let grab = NSEvent.mouseLocation
        let limit = maxSize?()
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let target = CameraWindowGeometry.dragTarget(of: corner, in: start, grab: grab, mouse: NSEvent.mouseLocation)
            let frame = CameraWindowGeometry.resized(start, corner: corner, to: target, maxSize: limit)
            if frame != window.frame { window.setFrame(frame, display: true) }
            if event.type == .leftMouseUp { stop.pointee = true }
        }
        onFrameCommitted?()
    }
}

/// A button that takes the first click on a window of an app that is not active.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the window's native Reconnect Camera button sits: shown or not, and its bottom edge.
struct ReconnectPlacement: Equatable {
    var shown: Bool
    var bottom: CGFloat
}

/// The picture, the status text and, while recording, a red dot and the elapsed time. Whenever
/// the camera mic is metered (the idle preview, a mic check, a take), the camera mic meter runs as
/// a bar along the bottom edge of the picture (decision 3). A banner above it for the camera mic
/// warning and the camera's trouble.
struct CameraMonitorView: View {
    let coordinator: SessionCoordinator
    /// Tells the window where to show its native Reconnect Camera button, or to hide it.
    var reconnectPlacement: @MainActor (ReconnectPlacement) -> Void = { _ in }

    var body: some View {
        let phase = coordinator.cameraWindowPhase
        let alert = coordinator.alerts.first
        let showReconnect = alert?.offersReconnect == true && coordinator.canReconnectCamera
        let meter = coordinator.cameraWindowShowsMeter
        let placement = ReconnectPlacement(shown: showReconnect, bottom: CameraWindowLayout.reconnectBottom(meter: meter))
        ZStack {
            Color.black
            // Holds only the frame feed, so it can come and go at any time.
            CameraPreviewView(feed: coordinator.previewFeed, mirrored: coordinator.settings.cameraWindowMirrored)
                .opacity(phase == .live ? 1 : 0)
            if let message = phase.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(14)
            }
        }
        .overlay(alignment: .topTrailing) {
            Group {
                if coordinator.state == .recording {
                    RecordingBadge(elapsed: coordinator.elapsedText, problem: coordinator.needsAttention)
                } else if let check = coordinator.micCheck {
                    WindowCapsule(systemImage: "mic.fill", tint: .white) { MicCheckCountdownText(progress: check) }
                } else if let note = coordinator.micCheckWindowNote {
                    WindowCapsule(systemImage: note.tone.systemImage, tint: note.tone == .neutral ? .white : note.tone.color) {
                        Text(note.title).lineLimit(2)
                    }
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottom) {
            if meter {
                CameraMicMeter(coordinator: coordinator)
                    .padding(.horizontal, CameraWindowLayout.sideInset)
                    .padding(.bottom, CameraWindowLayout.meterInset)
            }
        }
        .overlay(alignment: .bottom) {
            if let alert {
                WindowAlertBanner(alert: alert, reconnecting: coordinator.cameraReconnecting)
                    .padding(.horizontal, CameraWindowLayout.sideInset)
                    .padding(.bottom, CameraWindowLayout.bannerBottom(meter: meter, reconnect: showReconnect))
            }
        }
        .onChange(of: placement, initial: true) { _, placement in reconnectPlacement(placement) }
        .ignoresSafeArea()
    }
}

/// The camera mic's level as a bar along the bottom edge of the picture: green, yellow above
/// -12 dBFS, red above -3 dBFS, with the 1.5 s peak tick. A dark backing keeps it readable over a
/// bright picture. Its own view, so the 20 Hz poll redraws only the meter.
private struct CameraMicMeter: View {
    let coordinator: SessionCoordinator

    var body: some View {
        LevelMeterBar(level: coordinator.meters?.cameraMic, trackColor: .white.opacity(0.25))
            .frame(height: CameraWindowLayout.meterBarHeight)
            .padding(CameraWindowLayout.meterBackingPadding)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Camera mic level")
    }
}

/// "7 s" for the window's mic check capsule, counting down on its own.
private struct MicCheckCountdownText: View {
    let progress: MicCheckProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(progress.cancelling ? "Mic check · closing" : "Mic check · \(progress.secondsLeft(at: context.date)) s · talk")
                .monospacedDigit()
        }
    }
}

/// A small dark badge with an icon, like the recording badge (a result may take two lines).
private struct WindowCapsule<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content.foregroundStyle(.white)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

/// A red dot and the elapsed time (orange when a file has a problem).
private struct RecordingBadge: View {
    let elapsed: String
    let problem: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(problem ? Color.orange : Color.red).frame(width: 9, height: 9)
            Text(elapsed).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(problem ? "Recording with a problem, \(elapsed)" : "Recording, \(elapsed)")
    }
}
