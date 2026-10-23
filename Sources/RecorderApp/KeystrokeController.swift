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
    /// How often Accessibility and secure keyboard entry are read while keystrokes show.
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

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        monitor.handler = { [weak self] event in self?.received(event) }
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

    /// Installs the key monitor (nothing without Accessibility) and starts the watch.
    private func startMonitor() {
        if !monitor.isRunning { monitor.start() }
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self, self.showing, !Task.isCancelled else { return }
                self.watch()
            }
        }
    }

    private func stopMonitor() {
        watcher?.cancel()
        watcher = nil
        monitor.stop()
        secureInputChecks = 0
        coordinator?.setKeystrokeSecureInputNote(nil)
    }

    /// Every `watchInterval` while keystrokes show (cheap calls only):
    /// - Accessibility allowed and no monitor: it is installed, so allowing it in System Settings
    ///   starts the keystrokes. Taken away while the monitor runs: the monitor is removed (it gets
    ///   no keys without it), so allowing it again installs a fresh one.
    /// - Secure keyboard entry on for `KeystrokeRules.secureInputChecksBeforeNote` watches in a
    ///   row: the menu says which app holds the keys (one can leave it on by mistake).
    private func watch() {
        let trusted = KeyMonitor.isTrusted
        if trusted, !monitor.isRunning {
            monitor.start()
        } else if !trusted, monitor.isRunning {
            monitor.stop()
            tracker.clear()
            hud.clear()
        }
        secureInputChecks = trusted && KeyMonitor.isSecureInputOn ? secureInputChecks + 1 : 0
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
            if KeystrokeRules.reserved.contains(HotKey(keyCode: UInt32(keyCode), modifiers: event.modifiers)) {
                // One of TwinTake's hotkeys (when macOS passes it on): its modifiers show nothing either.
                tracker.muteModifiers()
            } else if let combo = KeystrokeFilter.combo(keyCode: keyCode, modifiers: event.modifiers,
                                                        reserved: KeystrokeRules.reserved, optionTypes: optionTypes,
                                                        character: event.character),
                      tracker.press(combo, isRepeat: isRepeat, at: now), let pill = tracker.pill {
                log(combo, count: pill.count)
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
