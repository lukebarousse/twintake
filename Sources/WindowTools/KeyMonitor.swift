import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One key event the monitor saw: a key press, or a change of the held modifiers.
public struct KeyEventInfo {
    public enum Kind: Equatable, Sendable {
        case keyDown(keyCode: UInt16, isRepeat: Bool)
        case modifiersChanged
    }

    public var kind: Kind
    /// ⌃⌥⇧⌘ held (caps lock, fn and the keypad flag are left out).
    public var modifiers: HotKey.Modifiers
    /// The event's time in seconds since startup, as AppKit gives it (`NSEvent.timestamp`), so a
    /// press both key sources report is seen once (`KeyEventDeduper`). Nil when unknown.
    public var timestamp: Double?
    /// The key's character on the current keyboard layout, without modifiers (with ⌘ when ⌘ is
    /// held, for layouts such as "Dvorak - QWERTY ⌘"). Nil for a modifier change. Read it only for
    /// a key that shows (`KeystrokeFilter.combo`).
    public var character: () -> String?

    public init(kind: Kind, modifiers: HotKey.Modifiers, timestamp: Double? = nil,
                character: @escaping () -> String? = { nil }) {
        self.kind = kind
        self.modifiers = modifiers
        self.timestamp = timestamp
        self.character = character
    }
}

/// Watches key presses and modifier changes in every app, to show shortcuts on screen. It only
/// listens: neither source ever changes, holds back or delays an event. One of two sources runs:
///
/// - **The event tap** (`startTap`, listen access): a listen-only session tap (`KeyEventTap`). It
///   sees every app's keys, TwinTake's own too, and also the keys of a shortcut another app owns as
///   a global hotkey (CleanShot X's ⇧⌘4). It is created only when listening is allowed
///   (`isListenAllowed`, which Accessibility gives), so it never makes macOS ask. Its first key
///   press removes the AppKit monitors (`TapProof`); a tap that gets no key presses while they do
///   is removed instead.
/// - **The AppKit monitors** (`startMonitors`, Accessibility): other apps' keys come from a global
///   monitor, which needs Accessibility (TwinTake has it for window snapping), and TwinTake's own
///   keys from a local monitor. They miss keys another app's hotkey takes (only ⇧⌘ shows for
///   ⇧⌘4). Nothing is installed without Accessibility, so they never make macOS ask.
///
/// While a new tap waits for its first key press both run, and a press both report counts once
/// (`KeyEventDeduper`). Once the tap proved itself it alone runs. While secure
/// keyboard entry is on (a password field, Terminal's Secure Keyboard Entry), nothing is passed on.
///
/// Main thread only; the handler runs on the main thread.
@MainActor
public final class KeyMonitor {
    /// Gets each event (not during secure keyboard entry).
    public var handler: ((KeyEventInfo) -> Void)?
    /// Runs on the main thread, from inside an event's handling, when the tap proved itself or was
    /// removed as deaf, so the caller can update the sources and the menu (later, not inside it).
    public var sourceChanged: (() -> Void)?

    private var global: Any?
    private var local: Any?
    private var tap: KeyEventTap?
    /// Counts taps started, so events of a removed tap still on their way are dropped.
    private var tapGeneration = 0
    private var proof = TapProof()
    /// A tap was removed because it got no key presses while the monitors did (`takeTapDeaf`).
    /// Internal for the tests.
    var tapWasDeaf = false
    private var deduper = KeyEventDeduper()

    public init() {}

    /// True while a source is installed.
    public var isRunning: Bool { tapRunning || monitorsRunning }

    /// The event tap runs, proven or still waiting for its first event.
    public var tapRunning: Bool { tap != nil }

    /// The tap runs and reported a key press, so it alone runs.
    public var tapProven: Bool { tap != nil && proof.state == .proven }

    /// The AppKit monitors are installed (Accessibility).
    public var monitorsRunning: Bool { global != nil }

    /// Accessibility is allowed, so a global monitor gets other apps' key events.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Listening to the keyboard is allowed, so the event tap can run. Accessibility gives it, so
    /// TwinTake needs no permission of its own for it. Never asks.
    public static var isListenAllowed: Bool { CGPreflightListenEventAccess() }

    /// Secure keyboard entry is on: a password field (or an app with it on) gets the keys. It is
    /// system wide: true when any process has it on.
    public static var isSecureInputOn: Bool { IsSecureEventInputEnabled() }

    /// The app that has secure keyboard entry on, from the session's `kCGSSessionSecureInputPID`
    /// (not in the SDK headers, but read-only and long-standing). Nil when it is off or macOS
    /// does not name it.
    public static var secureInputHolderName: String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// The modifiers held now, in any app.
    public static var heldModifiers: HotKey.Modifiers { HotKey.Modifiers(NSEvent.modifierFlags) }

    // MARK: - AppKit monitors

    /// Installs the AppKit monitors. Returns false, and installs nothing, without Accessibility or
    /// while a proven tap runs (it already sees every key).
    @discardableResult
    public func startMonitors() -> Bool {
        if global != nil { return true }
        guard Self.isTrusted else { return false }
        guard !tapProven else { return false }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        // AppKit calls both handlers on the main thread.
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { self?.received(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if Thread.isMainThread { MainActor.assumeIsolated { self?.received(event) } }
            return event
        }
        if global == nil, let local {
            NSEvent.removeMonitor(local)
            self.local = nil
        }
        return global != nil
    }

    public func stopMonitors() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    // MARK: - Event tap

    /// Starts the event tap. Returns false, and creates nothing, without listen access, or when
    /// macOS gives no working tap (after a fresh grant it can need a relaunch). The AppKit monitors stay
    /// until the tap reports its first key press, which removes them (the tap sees TwinTake's own
    /// keys too: one source only from then on).
    @discardableResult
    public func startTap() -> Bool {
        if tap != nil { return true }
        tapGeneration &+= 1
        let generation = tapGeneration
        // Event time (the clock of `NSEvent.timestamp`) before the tap exists.
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard let tap = KeyEventTap.start(deliver: { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receivedTap(event, generation: generation) } }
        }) else { return false }
        self.tap = tap
        proof = TapProof(startedAt: startedAt)
        return true
    }

    public func stopTap() {
        tap?.stop()
        tap = nil
        tapGeneration &+= 1
    }

    /// True once after a tap was removed because it got no key presses while the AppKit monitors
    /// did (`TapProof`): after a fresh grant, macOS can give the tap keys only after a relaunch.
    public func takeTapDeaf() -> Bool {
        defer { tapWasDeaf = false }
        return tapWasDeaf
    }

    /// Turns the tap on again when macOS turned it off. When it stays off, it is removed and this
    /// returns false (the caller picks the source again).
    @discardableResult
    public func checkTap() -> Bool {
        guard let tap else { return false }
        if tap.ensureEnabled() { return true }
        stopTap()
        return false
    }

    /// Removes both sources. A deaf tap found before is forgotten: the next start tries afresh.
    public func stop() {
        stopTap()
        stopMonitors()
        tapWasDeaf = false
    }

    // MARK: - Events

    private func received(_ event: NSEvent) {
        // Key presses only (a tap that needs a relaunch can still get modifier changes), not during
        // secure keyboard entry (the tap may get nothing then while a monitor still does), and not
        // from before the tap existed (`TapProof.startedAt`).
        if tap != nil,
           proof.monitorEvent(keyDown: event.type == .keyDown, secureInput: Self.isSecureInputOn, at: event.timestamp) {
            // The tap got none of these key presses: it is no use until a relaunch.
            stopTap()
            tapWasDeaf = true
            sourceChanged?()
        }
        let modifiers = HotKey.Modifiers(event.modifierFlags)
        switch event.type {
        case .keyDown:
            deliver(KeyEventInfo(kind: .keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat), modifiers: modifiers,
                                 timestamp: event.timestamp,
                                 character: { Self.layoutCharacter(event, modifiers: modifiers) }), from: .monitors)
        case .flagsChanged:
            deliver(KeyEventInfo(kind: .modifiersChanged, modifiers: modifiers, timestamp: event.timestamp), from: .monitors)
        default:
            break
        }
    }

    private func receivedTap(_ event: KeyEventTap.Event, generation: Int) {
        guard tap != nil, generation == tapGeneration else { return }
        // A key press outside secure keyboard entry proves the tap: it alone runs from now on. A
        // modifier change proves nothing (a tap that needs a relaunch can still get those).
        if proof.tapEvent(keyDown: event.type == .keyDown, secureInput: Self.isSecureInputOn) {
            stopMonitors()
            sourceChanged?()
        }
        // AppKit's view of the key press: the same layout character and event time the monitors give.
        let appKit = event.keyDown.flatMap { NSEvent(cgEvent: $0) }
        let modifiers = HotKey.Modifiers(cgFlags: event.flags)
        guard let info = KeyEventInfo(tapType: event.type, keyCode: event.keyCode, flags: event.flags,
                                      isRepeat: event.isRepeat, timestamp: appKit?.timestamp,
                                      character: { appKit.flatMap { Self.layoutCharacter($0, modifiers: modifiers) } })
        else { return }
        deliver(info, from: .tap)
    }

    private func deliver(_ info: KeyEventInfo, from source: KeySource) {
        guard let handler, !Self.isSecureInputOn else { return }
        if case let .keyDown(keyCode, isRepeat) = info.kind,
           !deduper.admit(source, keyCode: keyCode, isRepeat: isRepeat, modifiers: info.modifiers,
                          at: info.timestamp ?? ProcessInfo.processInfo.systemUptime) {
            return
        }
        handler(info)
    }

    /// A key press's character on the current layout, without modifiers (with ⌘ when ⌘ is held).
    private static func layoutCharacter(_ event: NSEvent, modifiers: HotKey.Modifiers) -> String? {
        let layoutModifiers: NSEvent.ModifierFlags = modifiers.contains(.command) ? [.command] : []
        return event.characters(byApplyingModifiers: layoutModifiers) ?? event.charactersIgnoringModifiers
    }
}
