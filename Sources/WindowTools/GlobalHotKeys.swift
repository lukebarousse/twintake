import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus modifiers.
///
/// Key codes are physical key positions (`kVK_*`), so ⌃⌥⌘R means the key where R is on a US
/// layout. Display names follow the US layout.
public struct HotKey: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Modifier keys. The raw value is the Carbon modifier mask, so it can be stored as is.
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: UInt32(controlKey))
        public static let option = Modifiers(rawValue: UInt32(optionKey))
        public static let shift = Modifiers(rawValue: UInt32(shiftKey))
        public static let command = Modifiers(rawValue: UInt32(cmdKey))

        /// Carbon modifier mask for `RegisterEventHotKey`.
        public var carbonFlags: UInt32 { rawValue & Self.all.rawValue }

        /// From a Carbon modifier mask. Unknown bits (caps lock, right-side keys) are dropped.
        public init(carbonFlags: UInt32) { self.init(rawValue: carbonFlags & Self.all.rawValue) }

        /// From AppKit flags, e.g. `NSEvent.modifierFlags` in a shortcut recorder.
        public init(_ flags: NSEvent.ModifierFlags) {
            var m: Modifiers = []
            if flags.contains(.control) { m.insert(.control) }
            if flags.contains(.option) { m.insert(.option) }
            if flags.contains(.shift) { m.insert(.shift) }
            if flags.contains(.command) { m.insert(.command) }
            self = m
        }

        public var eventFlags: NSEvent.ModifierFlags {
            var f: NSEvent.ModifierFlags = []
            if contains(.control) { f.insert(.control) }
            if contains(.option) { f.insert(.option) }
            if contains(.shift) { f.insert(.shift) }
            if contains(.command) { f.insert(.command) }
            return f
        }

        /// Symbols in Apple's order: ⌃⌥⇧⌘.
        public var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
                + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }

        static let all: Modifiers = [.control, .option, .shift, .command]
    }

    /// Virtual key code (`kVK_ANSI_R` and so on).
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// E.g. "⌃⌥⌘R".
    public var displayString: String { modifiers.symbols + (Self.keyName(for: keyCode) ?? "Key \(keyCode)") }

    public var description: String { displayString }

    /// False for shortcuts macOS 15 and later refuse to register: only ⌥, or only ⌥⇧.
    public var isAllowedByMacOS: Bool {
        modifiers != [.option] && modifiers != [.option, .shift]
    }

    /// The app or system feature that already uses this shortcut, if it is a known one.
    public var knownConflict: String? { Self.knownConflicts[self] }

    // MARK: Defaults

    /// ⌃⌥⌘R: start or stop recording.
    public static let startStop = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option, .command])
    /// ⌃⌥⌘F: snap the front window to the frame.
    public static let snapWindow = HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: [.control, .option, .command])
    /// ⌃⌥⌘B: Flag, a `marker` of kind `flag`: something in the last few minutes was wrong.
    /// (⌃⌥⌘G, the old "good take" marker, is gone.)
    public static let flag = HotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: [.control, .option, .command])
    /// ⌃⌥⌘C: show or hide the camera window.
    public static let cameraWindow = HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: [.control, .option, .command])
    /// ⌃⌥⌘P: show or hide the replay window (Play back what was just recorded).
    public static let replay = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: [.control, .option, .command])

    /// Shortcuts the defaults must not take. CleanShot X uses ⇧⌘2–6 and ⇧⌘8.
    public static let knownConflicts: [HotKey: String] = {
        let shiftCmd: Modifiers = [.shift, .command]
        var d: [HotKey: String] = [:]
        for code in [kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_8] {
            d[HotKey(keyCode: UInt32(code), modifiers: shiftCmd)] = "CleanShot X"
        }
        d[HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: [.control, .command])] = "Enter Full Screen"
        d[HotKey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.control, .command])] = "Lock Screen"
        d[HotKey(keyCode: UInt32(kVK_Space), modifiers: [.command])] = "Spotlight"
        d[HotKey(keyCode: UInt32(kVK_Space), modifiers: [.control, .command])] = "Emoji & Symbols"
        d[HotKey(keyCode: UInt32(kVK_Escape), modifiers: [.option, .command])] = "Force Quit"
        d[HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: [.option, .command])] = "Show or hide the Dock"
        return d
    }()

    // MARK: Key names

    /// US-layout name for a key code, or nil when unknown.
    public static func keyName(for keyCode: UInt32) -> String? { keyNames[Int(keyCode)] }

    private static let keyNames: [Int: String] = {
        var n: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { n[code] = "F\(i + 1)" }
        return n
    }()
}

/// The recorder's hotkey actions, with their default shortcuts and registration ids.
public enum HotKeyAction: String, CaseIterable, Sendable, Codable {
    case startStop = "start_stop"
    case snapWindow = "snap_window"
    case flag
    case cameraWindow = "camera_window"
    case replay

    public var defaultHotKey: HotKey {
        switch self {
        case .startStop: .startStop
        case .snapWindow: .snapWindow
        case .flag: .flag
        case .cameraWindow: .cameraWindow
        case .replay: .replay
        }
    }

    /// Id for `GlobalHotKeys.register(id:...)`. 3 was the old "good take" marker.
    public var id: UInt32 {
        switch self {
        case .startStop: 1
        case .snapWindow: 2
        case .flag: 4
        case .cameraWindow: 5
        case .replay: 6
        }
    }

    public var title: String {
        switch self {
        case .startStop: "Start / Stop recording"
        case .snapWindow: "Snap window to frame"
        case .flag: "Flag a mistake in the last few minutes"
        case .cameraWindow: "Show or hide the camera window"
        case .replay: "Show or hide the replay window"
        }
    }
}

public enum HotKeyError: Error, Equatable, Sendable, LocalizedError {
    case notAllowedByMacOS(HotKey)
    case alreadyRegistered(HotKey, id: UInt32)
    case registrationFailed(HotKey, status: OSStatus)
    case handlerInstallFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .notAllowedByMacOS(k):
            "macOS does not allow \(k) as a global shortcut. Add ⌃ or ⌘."
        case let .alreadyRegistered(k, id):
            "\(k) is already used by hotkey \(id) in this app."
        case let .registrationFailed(k, status):
            "macOS refused \(k) (error \(status)). Another app may own it."
        case let .handlerInstallFailed(status):
            "Could not listen for global shortcuts (error \(status))."
        }
    }
}

/// The signature in every `EventHotKeyID` this module registers ("VRHK").
private let hotKeySignature: OSType = 0x5652_484B

/// Global hotkeys through Carbon `RegisterEventHotKey`. They work while any app is frontmost
/// and need no permission (unlike an event tap, which needs listen access).
///
/// Handlers run on the main actor. Keep one instance for the app's lifetime; call
/// `unregisterAll()` before releasing it.
@MainActor
public final class GlobalHotKeys {
    private var handlers: [UInt32: (hotKey: HotKey, handler: @MainActor () -> Void)] = [:]
    // Read in deinit, which is nonisolated. Only touched on the main thread.
    nonisolated(unsafe) private var refs: [UInt32: EventHotKeyRef] = [:]
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?

    public init() {}

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// The hotkeys registered now, by id.
    public var registered: [UInt32: HotKey] { handlers.mapValues(\.hotKey) }

    /// Registers a global hotkey. Registering an id again replaces its old shortcut.
    /// - Parameters:
    ///   - id: your id for this hotkey, e.g. `HotKeyAction.id`.
    ///   - keyCode: virtual key code (`kVK_ANSI_R`).
    ///   - modifiers: modifier keys.
    ///   - handler: runs on the main actor on each key press.
    public func register(id: UInt32, keyCode: UInt32, modifiers: HotKey.Modifiers,
                         handler: @escaping @MainActor () -> Void) throws {
        let hotKey = HotKey(keyCode: keyCode, modifiers: modifiers)
        guard hotKey.isAllowedByMacOS else { throw HotKeyError.notAllowedByMacOS(hotKey) }
        if let other = handlers.first(where: { $0.key != id && $0.value.hotKey == hotKey }) {
            throw HotKeyError.alreadyRegistered(hotKey, id: other.key)
        }
        try installEventHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers.carbonFlags, EventHotKeyID(signature: hotKeySignature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotKeyError.registrationFailed(hotKey, status: status) }
        refs[id] = ref
        handlers[id] = (hotKey, handler)
    }

    public func register(_ hotKey: HotKey, id: UInt32, handler: @escaping @MainActor () -> Void) throws {
        try register(id: id, keyCode: hotKey.keyCode, modifiers: hotKey.modifiers, handler: handler)
    }

    /// Registers `action` with `hotKey`, or with its default shortcut.
    public func register(_ action: HotKeyAction, hotKey: HotKey? = nil, handler: @escaping @MainActor () -> Void) throws {
        try register(hotKey ?? action.defaultHotKey, id: action.id, handler: handler)
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Runs the handler for `id`. Returns false when the id is not ours.
    fileprivate func fire(_ id: UInt32) -> Bool {
        guard let entry = handlers[id] else { return false }
        entry.handler()
        return true
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let s = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard s == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            guard Thread.isMainThread else {
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = owner.fire(id) } }
                return noErr
            }
            return MainActor.assumeIsolated { owner.fire(id) } ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &ref)
        guard status == noErr, let ref else { throw HotKeyError.handlerInstallFailed(status: status) }
        eventHandler = ref
    }
}
