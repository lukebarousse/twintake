import AppKit
import RecorderCore
import WindowTools

/// The on-screen keystrokes: the key monitor, the pill near the bottom of the frame, and the
/// `keystroke` events of a take.
///
/// Made at launch only (never in tests or the docs screenshots), so no key monitor runs there.
/// Everything here is UI on the main thread: it never touches a recorder, a writer or a capture
/// queue. The screen recorder only names the pill's window in its filter at prepare.
@MainActor
final class KeystrokeController {
    /// How often a shown pill is moved on in time (its fade) and the held modifiers are read.
    static let tickInterval: Duration = .milliseconds(50)
    /// How often Accessibility, listen access, the tap and secure keyboard entry are read while
    /// keystrokes show.
    static let watchInterval: Duration = .seconds(3)

    private weak var coordinator: SessionCoordinator?
    private let hud = KeystrokeHUD()
    private let monitor = KeyMonitor()
    private var tracker = KeystrokeTracker(hiddenModifierSets: KeystrokeRules.hiddenModifierSets)
    /// The modifiers held, as the last event or poll saw them.
    private var heldModifiers: HotKey.Modifiers = []
    /// Keystrokes show now (the mode and the take).
    private var showing = false
    private var ticker: Task<Void, Never>?
    /// Runs while keystrokes show: `watch()` every `watchInterval`.
    private var watcher: Task<Void, Never>?
    /// Watches in a row that found secure keyboard entry on.
    private var secureInputChecks = 0
    /// Failed tries in a row to get a working event tap while listening was allowed
    /// (`KeystrokeRules.tapFailures`).
    private var tapFailures = 0
    /// When the tap was last tried (`nowS`), so it is tried at most every `KeystrokeRules.tapRetryInterval`.
    private var lastTapTryS: Double?

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        monitor.handler = { [weak self] event in self?.received(event) }
        // The tap proved itself or was found deaf: the sources and the menu follow at once, on the
        // next turn of the main run loop (not inside the event's handling, which may be a monitor's).
        monitor.sourceChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.showing else { return }
                self.applyKeySource()
            }
        }
    }

    /// Follows the settings, the take and the frame.
    /// - Parameters:
    ///   - show: keystrokes show (`KeystrokeRules.showsKeystrokes`).
    ///   - orderedIn: the pill's window is on screen (`KeystrokeRules.hudOrderedIn`).
    ///   - frameGlobal: the frame the pill sits in; nil when there is no display.
    func update(show: Bool, orderedIn: Bool, frameGlobal: CGRect?) {
        showing = show
        if show { startMonitor() } else { stopMonitor() }
        if orderedIn, let frameGlobal {
            hud.place(frameGlobal: frameGlobal)
        } else {
            hud.orderOut()
            tracker.clear()
        }
        if !show {
            tracker.clear()
            hud.clear()
        }
    }

    /// At Start, before the screen recorder prepares: the pill's window goes over the take's frame
    /// (drawing nothing until a keystroke), so ScreenCaptureKit lists it when the stream's filter is
    /// built. Returns its window number for `ScreenRecorderConfig.shownOwnWindowIDs`.
    func prepareForTake(frameGlobal: CGRect) -> UInt32? {
        hud.place(frameGlobal: frameGlobal)
        return hud.windowID
    }

    /// A TwinTake hotkey fired: its modifiers (⌃⌥⌘) show nothing, also while they are released.
    func hotKeyPressed() {
        guard showing else { return }
        let before = (tracker.pill, tracker.phase)
        tracker.muteModifiers()
        render(from: before)
        startTicker()
    }

    /// Quit.
    func close() {
        showing = false
        stopMonitor()
        tracker.clear()
        hud.orderOut()
    }

    // MARK: - Monitor

    /// Installs a key source (`applyKeySource`) and starts the watch.
    private func startMonitor() {
        if !monitor.isRunning { applyKeySource() }
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self, self.showing, !Task.isCancelled else { return }
                self.watch()
            }
        }
    }

    /// Removes both key sources (Keystrokes Off, the take ended in While recording, Quit).
    private func stopMonitor() {
        watcher?.cancel()
        watcher = nil
        monitor.stop()
        secureInputChecks = 0
        tapFailures = 0
        lastTapTryS = nil
        coordinator?.setKeystrokeSecureInputNote(nil)
        coordinator?.setKeystrokeTap(proven: false, note: nil)
    }

    /// Picks the key sources (`KeystrokeRules.keySources`) and installs them. Cheap calls only,
    /// and nothing here makes macOS ask for a permission:
    /// - Listening allowed (`KeystrokeRules.listenAllowed`: Accessibility, and the listen access it
    ///   gives): the event tap is tried (at most every
    ///   `tapRetryInterval`). Its first key press removes the AppKit monitors (`KeyMonitor`). When
    ///   macOS refuses it again and again, or it gets no key presses while the monitors do, the menu
    ///   asks for a relaunch. Taken away, or turned off by macOS for good: the tap is removed.
    /// Also runs right after the tap proved itself or was found deaf (`KeyMonitor.sourceChanged`).
    /// - With Accessibility, the AppKit monitors run while no proven tap does, so allowing it in
    ///   System Settings starts the keystrokes. Taken away while they run: they are removed (they get
    ///   no keys without it), so allowing it again installs fresh ones.
    private func applyKeySource() {
        let wasRunning = monitor.isRunning
        let trusted = KeyMonitor.isTrusted
        let listenAllowed = KeystrokeRules.listenAllowed(accessibilityGranted: trusted, listenAccess: KeyMonitor.isListenAllowed)
        if monitor.tapRunning,
           !(KeystrokeRules.keepsTap(showing: showing, listenAllowed: listenAllowed) && monitor.checkTap()) {
            monitor.stopTap()
        }
        let now = Self.nowS()
        let deaf = monitor.takeTapDeaf()
        if deaf { lastTapTryS = now }
        var refused = false
        if KeystrokeRules.shouldTryTap(showing: showing, listenAllowed: listenAllowed, tapRunning: monitor.tapRunning,
                                       sinceLastTryS: lastTapTryS.map { now - $0 }, failures: tapFailures) {
            lastTapTryS = now
            refused = !monitor.startTap()
        }
        tapFailures = listenAllowed
            ? KeystrokeRules.tapFailures(after: tapFailures, proven: monitor.tapProven, refused: refused, deaf: deaf) : 0
        let sources = KeystrokeRules.keySources(showing: showing, tapRunning: monitor.tapRunning, tapProven: monitor.tapProven,
                                                accessibilityGranted: trusted)
        if sources.contains(.monitors) {
            if !monitor.monitorsRunning { monitor.startMonitors() }
        } else {
            monitor.stopMonitors()
        }
        if wasRunning, !monitor.isRunning {
            tracker.clear()
            hud.clear()
        }
        coordinator?.setKeystrokeTap(
            proven: monitor.tapProven,
            note: KeystrokeRules.tapRelaunchNote(showing: showing, listenAllowed: listenAllowed,
                                                 tapProven: monitor.tapProven, failures: tapFailures))
    }

    /// Every `watchInterval` while keystrokes show (cheap calls only):
    /// - The key source follows Accessibility, listen access and the tap (`applyKeySource`).
    /// - Secure keyboard entry on for `KeystrokeRules.secureInputChecksBeforeNote` watches in a
    ///   row: the menu says which app holds the keys (one can leave it on by mistake).
    private func watch() {
        applyKeySource()
        secureInputChecks = monitor.isRunning && KeyMonitor.isSecureInputOn ? secureInputChecks + 1 : 0
        let holder = secureInputChecks >= KeystrokeRules.secureInputChecksBeforeNote ? KeyMonitor.secureInputHolderName : nil
        coordinator?.setKeystrokeSecureInputNote(KeystrokeRules.secureInputNote(checks: secureInputChecks, holder: holder))
    }

    // MARK: - Events

    private func received(_ event: KeyEventInfo) {
        guard showing, hud.isOrderedIn else { return }
        let before = (tracker.pill, tracker.phase)
        let now = Self.nowS()
        let optionTypes = !windowsVMInFront
        switch event.kind {
        case .modifiersChanged:
            heldModifiers = event.modifiers
            tracker.modifiersChanged(event.modifiers, at: now, optionTypes: optionTypes)
        case let .keyDown(keyCode, isRepeat):
            switch KeystrokeRules.keyDownAction(keyCode: keyCode, isRepeat: isRepeat, modifiers: event.modifiers,
                                                optionTypes: optionTypes, character: event.character) {
            case .muteModifiers:
                // One of TwinTake's hotkeys (the tap always sees it; the AppKit monitors when macOS
                // passes it on): its modifiers show nothing either.
                tracker.muteModifiers()
            case let .press(combo, isRepeat):
                if tracker.press(combo, isRepeat: isRepeat, at: now), let pill = tracker.pill { log(combo, count: pill.count) }
            case .none:
                break
            }
        }
        render(from: before)
        startTicker()
    }

    /// Updates the pill when the tracker changed.
    private func render(from before: (KeystrokeTracker.Pill?, KeystrokeTracker.Phase)) {
        guard tracker.pill != before.0 || tracker.phase != before.1 else { return }
        switch tracker.phase {
        case .shown:
            if let pill = tracker.pill { hud.show(KeystrokeNames.pillText(pill, windows: usesWindowsNames(pill.combo))) }
        case .fading:
            break
        case .hidden:
            hud.clear()
        }
    }

    /// A Parallels Windows VM is the front app: ⌥ is Alt there, so ⌥ with a character shows.
    private var windowsVMInFront: Bool {
        KeystrokeNames.isWindowsVM(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func usesWindowsNames(_ combo: KeyCombo?) -> Bool {
        let style = coordinator?.settings.keyNameStyle ?? .auto
        return KeystrokeNames.usesWindowsNames(style, frontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                               combo: combo)
    }

    /// A new press: a `keystroke` event, while a take records.
    private func log(_ combo: KeyCombo, count: Int) {
        let windows = usesWindowsNames(combo)
        coordinator?.logKeystroke(label: KeystrokeNames.label(combo, windows: windows),
                                  macLabel: KeystrokeNames.label(combo, windows: false), count: count)
    }

    // MARK: - Time

    /// Runs while the tracker has work (a pill shows or fades, held modifiers wait or are muted),
    /// then ends by itself.
    private func startTicker() {
        guard ticker == nil, tracker.needsTicks else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, self.step() else { break }
            }
            self?.ticker = nil
        }
    }

    /// Moves the pill on in time. False when nothing is left to do.
    private func step() -> Bool {
        guard showing else {
            tracker.clear()
            hud.clear()
            return false
        }
        let now = Self.nowS()
        if tracker.followsHeldModifiers {
            if KeyMonitor.isSecureInputOn {
                // Nothing shows during secure keyboard entry, not even held modifiers.
                tracker.clear()
                hud.clear()
                return false
            }
            // Held modifiers follow the keys held now, also when their release went to another
            // app's password field and no event came.
            let held = KeyMonitor.heldModifiers
            if held != heldModifiers {
                heldModifiers = held
                let before = (tracker.pill, tracker.phase)
                tracker.modifiersChanged(held, at: now, optionTypes: !windowsVMInFront)
                render(from: before)
            }
        }
        let before = (tracker.pill, tracker.phase)
        switch tracker.tick(at: now) {
        case .show: render(from: before)
        case .fade: hud.fadeOut()
        case .gone: hud.clear()
        case .none: break
        }
        return tracker.needsTicks
    }

    private static func nowS() -> Double { Double(HostClock.nowNs()) / 1e9 }
}
