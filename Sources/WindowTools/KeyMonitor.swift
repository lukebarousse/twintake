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
    /// The key's character on the current keyboard layout, without modifiers (with ⌘ when ⌘ is
    /// held, for layouts such as "Dvorak - QWERTY ⌘"). Nil for a modifier change. Read it only for
    /// a key that shows (`KeystrokeFilter.combo`).
    public var character: () -> String?

    public init(kind: Kind, modifiers: HotKey.Modifiers, character: @escaping () -> String? = { nil }) {
        self.kind = kind
        self.modifiers = modifiers
        self.character = character
    }
}

/// Watches key presses and modifier changes in every app, to show shortcuts on screen. It only
/// listens: `NSEvent` monitors never change or hold back an event.
///
/// - Other apps' keys come from a global monitor, which needs Accessibility (TwinTake has it for
///   window snapping). `start()` installs nothing without it, so it never makes macOS ask.
/// - TwinTake's own keys come from a local monitor.
/// - While secure keyboard entry is on (a password field, Terminal's Secure Keyboard Entry),
///   nothing is passed on.
///
/// Main thread only; the handler runs on the main thread.
@MainActor
public final class KeyMonitor {
    /// Gets each event (not during secure keyboard entry).
    public var handler: ((KeyEventInfo) -> Void)?

    private var global: Any?
    private var local: Any?

    public init() {}

    /// True while the monitors are installed.
    public var isRunning: Bool { global != nil }

    /// Accessibility is allowed, so a global monitor gets other apps' key events.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

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

    /// Installs the monitors. Returns false, and installs nothing, without Accessibility.
    @discardableResult
    public func start() -> Bool {
        if global != nil { return true }
        guard Self.isTrusted else { return false }
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

    public func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    private func received(_ event: NSEvent) {
        guard let handler, !Self.isSecureInputOn else { return }
        let modifiers = HotKey.Modifiers(event.modifierFlags)
        switch event.type {
        case .keyDown:
            let layoutModifiers: NSEvent.ModifierFlags = modifiers.contains(.command) ? [.command] : []
            handler(KeyEventInfo(kind: .keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat), modifiers: modifiers,
                                 character: { event.characters(byApplyingModifiers: layoutModifiers) ?? event.charactersIgnoringModifiers }))
        case .flagsChanged:
            handler(KeyEventInfo(kind: .modifiersChanged, modifiers: modifiers))
        default:
            break
        }
    }
}
