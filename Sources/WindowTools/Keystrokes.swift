import Carbon.HIToolbox
import CoreGraphics

// On-screen keystrokes: which key presses show, how they are named, how repeats count and where
// the pill sits. Plain values only, so all of it is unit tested. `KeyMonitor` feeds key events in,
// `KeystrokeHUD` draws the pill.

/// A key with a name of its own, or a character key.
public enum KeystrokeKey: Hashable, Sendable {
    case returnKey, enter, tab, space, escape, delete, forwardDelete
    case left, right, up, down, pageUp, pageDown, home, end
    /// F1 to F20.
    case function(Int)
    /// A character key, as the current keyboard layout names it ("P", "7", "Ö").
    case character(String)
}

/// A key press to show: the modifiers held and the key.
public struct KeyCombo: Hashable, Sendable {
    public var modifiers: HotKey.Modifiers
    public var key: KeystrokeKey

    public init(modifiers: HotKey.Modifiers, key: KeystrokeKey) {
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌘Tab and ⇧⌘Tab: the Mac app switcher, which macOS handles even in front of a Parallels VM.
    public var isMacAppSwitcher: Bool {
        key == .tab && modifiers.contains(.command) && modifiers.isSubset(of: [.command, .shift])
    }
}

/// Which key presses show. Typing never shows: a plain character, ⇧ and a character, Space alone,
/// and on a Mac ⌥ (or ⌥⇧) with a character or Space (⌥- types –, ⌥E starts é, and many layouts type
/// @ [ ] { } | ~ with ⌥). A key pressed with ⌘ or ⌃ shows, and so do the named keys (Return, Tab,
/// Esc, Delete, the arrows and the others below) alone or with ⇧ or ⌥. In a Windows VM, ⌥ is Alt,
/// and Alt with a character is a shortcut (`optionTypes` false).
public enum KeystrokeFilter {
    /// The modifiers that make any key a shortcut.
    public static let shortcutModifiers: HotKey.Modifiers = [.control, .option, .command]

    /// The modifiers that still type text with a character key: ⇧, and ⌥ too where it types
    /// (`optionTypes`: on a Mac, not in a Windows VM).
    public static func typingModifiers(optionTypes: Bool) -> HotKey.Modifiers {
        optionTypes ? [.shift, .option] : [.shift]
    }

    /// The named key for a virtual key code (`kVK_*`), or nil for a character key.
    public static func namedKey(keyCode: UInt16) -> KeystrokeKey? {
        switch Int(keyCode) {
        case kVK_Return: .returnKey
        case kVK_ANSI_KeypadEnter: .enter
        case kVK_Tab: .tab
        case kVK_Space: .space
        case kVK_Escape: .escape
        case kVK_Delete: .delete
        case kVK_ForwardDelete: .forwardDelete
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_PageUp: .pageUp
        case kVK_PageDown: .pageDown
        case kVK_Home: .home
        case kVK_End: .end
        default: functionKeys[Int(keyCode)].map(KeystrokeKey.function)
        }
    }

    private static let functionKeys: [Int: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        var map: [Int: Int] = [:]
        for (i, code) in codes.enumerated() { map[code] = i + 1 }
        return map
    }()

    /// The combo to show for a key press, or nil when the press is typing or one of `reserved`.
    /// - Parameters:
    ///   - keyCode: the virtual key code.
    ///   - modifiers: the modifiers held with it.
    ///   - reserved: shortcuts that never show (TwinTake's own hotkeys: they control the recorder,
    ///     not the recorded app).
    ///   - optionTypes: ⌥ types text with a character key (a Mac app); false in a Windows VM,
    ///     where ⌥ is Alt.
    ///   - character: the key's character on the current keyboard layout, without modifiers. It is
    ///     read only for a shortcut, so typing is never even translated.
    public static func combo(keyCode: UInt16, modifiers: HotKey.Modifiers, reserved: Set<HotKey> = [],
                             optionTypes: Bool = true, character: () -> String?) -> KeyCombo? {
        if reserved.contains(HotKey(keyCode: UInt32(keyCode), modifiers: modifiers)) { return nil }
        let named = namedKey(keyCode: keyCode)
        guard !modifiers.isSubset(of: typingModifiers(optionTypes: optionTypes)) else {
            // Text modifiers only: only a named key shows (⇧ Tab, ⌥←, ⌥ Delete). Space is text.
            guard let named, named != .space else { return nil }
            return KeyCombo(modifiers: modifiers, key: named)
        }
        if let named { return KeyCombo(modifiers: modifiers, key: named) }
        guard let name = keyLabel(fromCharacter: character()) ?? HotKey.keyName(for: UInt32(keyCode)) else { return nil }
        return KeyCombo(modifiers: modifiers, key: .character(name))
    }

    /// The modifiers to show while they are held without a key: only those that make a shortcut
    /// with any key (⇧ alone comes before every capital letter, ⌥ before –, é or @ on a Mac). Nil
    /// when nothing shows.
    public static func liveModifiers(_ held: HotKey.Modifiers, optionTypes: Bool = true) -> HotKey.Modifiers? {
        held.isSubset(of: typingModifiers(optionTypes: optionTypes)) ? nil : held
    }

    /// A key's name from its layout character: one character, upper case when that is one
    /// character too ("p" is "P", "ß" stays "ß"). Nil for an empty string, a control character,
    /// white space or AppKit's private function-key characters (U+F700 to U+F8FF).
    public static func keyLabel(fromCharacter text: String?) -> String? {
        guard let first = text?.first else { return nil }
        let character = String(first)
        let unusable = character.unicodeScalars.contains {
            $0.properties.generalCategory == .control || (0xF700...0xF8FF).contains($0.value)
                || $0.properties.isWhitespace
        }
        guard !unusable else { return nil }
        let upper = character.uppercased()
        return upper.count == 1 ? upper : character
    }
}

/// How the pill names keys.
public enum KeyNameStyle: String, CaseIterable, Sendable, Identifiable {
    /// Windows names while a Parallels VM is the front app (Parallels maps ⌘ to Ctrl), else Mac symbols.
    case auto
    /// ⇧⌘P, ⌥⌘7, Return, Esc, Tab, Delete, ← → ↑ ↓.
    case mac
    /// Ctrl+Shift+P, Ctrl+Alt+7, Enter, Backspace.
    case windows

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .mac: "Mac symbols"
        case .windows: "Windows names"
        }
    }
}

/// The text of a keystroke, in Mac symbols or Windows names.
public enum KeystrokeNames {
    /// True when `style` names keys the Windows way now. Auto does for a Parallels VM in front
    /// (`SnapProfile.parallelsDesktop`, but not a macOS VM, `com.parallels.macvm`), except for the
    /// Mac app switcher (⌘Tab), which macOS handles.
    public static func usesWindowsNames(_ style: KeyNameStyle, frontBundleID: String?, combo: KeyCombo? = nil) -> Bool {
        switch style {
        case .mac: return false
        case .windows: return true
        case .auto:
            guard isWindowsVM(frontBundleID) else { return false }
            return !(combo?.isMacAppSwitcher ?? false)
        }
    }

    /// A Parallels Desktop process that shows a Windows VM.
    public static func isWindowsVM(_ bundleID: String?) -> Bool {
        guard let bundleID, bundleID != "com.parallels.macvm" else { return false }
        return SnapProfile.parallelsDesktop.matches(bundleID)
    }

    /// "⇧⌘P", "⌘ Return", "Esc" (Mac), or "Ctrl+Shift+P", "Ctrl+Enter", "Esc" (Windows).
    public static func label(_ combo: KeyCombo, windows: Bool) -> String {
        if windows {
            return (windowsModifierNames(combo.modifiers) + [windowsName(combo.key)]).joined(separator: "+")
        }
        let symbols = combo.modifiers.symbols
        let key = macName(combo.key)
        if symbols.isEmpty { return key }
        // A one-character key joins the symbols ("⇧⌘P"); a word gets a space ("⌘ Return").
        return key.count == 1 ? symbols + key : symbols + " " + key
    }

    /// The modifiers held without a key: "⇧⌘" or "Ctrl+Shift".
    public static func modifiersLabel(_ modifiers: HotKey.Modifiers, windows: Bool) -> String {
        windows ? windowsModifierNames(modifiers).joined(separator: "+") : modifiers.symbols
    }

    /// The pill's text: the combo, with " ×3" for its third press in a row.
    public static func pillText(_ pill: KeystrokeTracker.Pill, windows: Bool) -> String {
        guard let combo = pill.combo else { return modifiersLabel(pill.modifiers, windows: windows) }
        let text = label(combo, windows: windows)
        return pill.count > 1 ? "\(text) ×\(pill.count)" : text
    }

    /// Windows order: Ctrl, Alt, Shift. ⌘ and ⌃ are both Ctrl (Parallels maps ⌘ to Ctrl).
    static func windowsModifierNames(_ m: HotKey.Modifiers) -> [String] {
        var names: [String] = []
        if m.contains(.command) || m.contains(.control) { names.append("Ctrl") }
        if m.contains(.option) { names.append("Alt") }
        if m.contains(.shift) { names.append("Shift") }
        return names
    }

    static func macName(_ key: KeystrokeKey) -> String {
        switch key {
        case .returnKey: "Return"
        case .enter: "Enter"
        case .tab: "Tab"
        case .space: "Space"
        case .escape: "Esc"
        case .delete: "Delete"
        case .forwardDelete: "⌦"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .home: "Home"
        case .end: "End"
        case let .function(n): "F\(n)"
        case let .character(c): c
        }
    }

    static func windowsName(_ key: KeystrokeKey) -> String {
        switch key {
        case .returnKey, .enter: "Enter"
        case .delete: "Backspace"
        case .forwardDelete: "Delete"
        default: macName(key)
        }
    }
}

/// What the pill shows over time: the modifiers while they are held, then the combo when its key
/// lands, for `visibleS`, then a `fadeOutS` fade. A combo pressed again while its pill shows (or
/// fades) counts up ("⌘Z ×3"). One pill at most: a new keystroke replaces it in place.
///
/// Held modifiers without a key show once they stay the same for `modifiersDelayS`, so the sets
/// that pass while a shortcut's modifiers go down (⌃, then ⌃⌥, then ⌃⌥⌘) never flash. A set in
/// `hiddenModifierSets` (⌃⌥⌘: TwinTake's own hotkeys) never shows: once it is held, held modifiers
/// show nothing until ⌘, ⌃ and ⌥ are all up (`modifiersMuted`). A shortcut with those modifiers
/// still shows when its key lands, unless it is one of TwinTake's.
///
/// Times are seconds on one monotonic clock (`HostClock`).
public struct KeystrokeTracker: Sendable {
    /// How long a combo shows after its last press (CleanShot X: about 1.5 s).
    public static let visibleS = 1.5
    /// How long modifiers shown without a key stay after they are released.
    public static let modifiersLingerS = 0.5
    /// How long held modifiers stay the same before they show without a key.
    public static let modifiersDelayS = 0.2
    public static let fadeOutS = 0.3

    public struct Pill: Hashable, Sendable {
        /// Nil while modifiers are held and no key landed yet.
        public var combo: KeyCombo?
        public var modifiers: HotKey.Modifiers
        /// Presses of `combo` in a row while its pill showed.
        public var count: Int

        public init(combo: KeyCombo?, modifiers: HotKey.Modifiers, count: Int) {
            self.combo = combo
            self.modifiers = modifiers
            self.count = count
        }
    }

    public enum Phase: Sendable, Equatable { case hidden, shown, fading }

    /// What `tick` asks the view to do: `.show` when held modifiers start to show.
    public enum Tick: Sendable, Equatable { case none, show, fade, gone }

    /// Modifier sets that never show without a key (TwinTake's hotkeys: ⌃⌥⌘).
    public let hiddenModifierSets: Set<HotKey.Modifiers>

    public private(set) var pill: Pill?
    public private(set) var phase: Phase = .hidden
    /// When the shown pill starts to fade. Nil while modifiers without a key are held.
    public private(set) var fadeAt: Double?
    /// Held modifiers that show at `pendingAt` if they stay the same and no key lands.
    public private(set) var pending: HotKey.Modifiers?
    public private(set) var pendingAt: Double?
    /// One of `hiddenModifierSets` was held: held modifiers show nothing until they are released.
    public private(set) var modifiersMuted = false

    public init(hiddenModifierSets: Set<HotKey.Modifiers> = []) {
        self.hiddenModifierSets = hiddenModifierSets
    }

    /// `tick` has work to do: a pill shows or fades, or held modifiers wait to show or are muted.
    public var needsTicks: Bool { phase != .hidden || pending != nil || modifiersMuted }

    /// What shows (or waits to show) follows the modifiers held now, so the app reads them again
    /// on each tick (a release can go to another app's password field and send no event).
    public var followsHeldModifiers: Bool { pending != nil || modifiersMuted || (phase == .shown && pill?.combo == nil) }

    /// A key press that passed `KeystrokeFilter`. Returns true for a new press, which the app
    /// logs; an auto-repeat (a held key) only keeps its pill on and returns false.
    @discardableResult
    public mutating func press(_ combo: KeyCombo, isRepeat: Bool, at t: Double) -> Bool {
        if isRepeat {
            guard phase != .hidden, pill?.combo == combo else { return false }
            phase = .shown
            fadeAt = t + Self.visibleS
            return false
        }
        cancelPending()
        let count = phase != .hidden && pill?.combo == combo ? (pill?.count ?? 0) + 1 : 1
        pill = Pill(combo: combo, modifiers: combo.modifiers, count: count)
        phase = .shown
        fadeAt = t + Self.visibleS
        return true
    }

    /// The held modifiers changed.
    /// - Shortcut modifiers held (`KeystrokeFilter.liveModifiers`): the combo on show stays when it
    ///   holds them (so ⌘Z, ⌘Z counts while ⌘ is pressed again between). A pill of modifiers on
    ///   show follows them at once. Else they show after `modifiersDelayS` unchanged.
    /// - One of `hiddenModifierSets`: nothing shows for them, and a pill of modifiers goes at once.
    /// - Released: a pill of modifiers only fades after `modifiersLingerS`; a combo keeps its time.
    public mutating func modifiersChanged(_ held: HotKey.Modifiers, at t: Double, optionTypes: Bool = true) {
        guard let live = KeystrokeFilter.liveModifiers(held, optionTypes: optionTypes) else {
            modifiersMuted = false
            cancelPending()
            if phase == .shown, pill?.combo == nil, fadeAt == nil { fadeAt = t + Self.modifiersLingerS }
            return
        }
        if modifiersMuted || hiddenModifierSets.contains(live) {
            muteModifiers()
            return
        }
        if phase != .hidden, let combo = pill?.combo, combo.modifiers.isSuperset(of: live) {
            cancelPending()
            return
        }
        if phase != .hidden, pill?.combo == nil {
            pill = Pill(combo: nil, modifiers: live, count: 1)
            phase = .shown
            fadeAt = nil
            cancelPending()
            return
        }
        // The wait starts over when the set changes.
        if pending != live {
            pending = live
            pendingAt = t + Self.modifiersDelayS
        }
    }

    /// Held modifiers show nothing until ⌘, ⌃ and ⌥ are all up (a TwinTake hotkey was held or
    /// pressed). A pill of modifiers goes at once; a combo keeps its time.
    public mutating func muteModifiers() {
        modifiersMuted = true
        cancelPending()
        if phase != .hidden, pill?.combo == nil {
            pill = nil
            phase = .hidden
            fadeAt = nil
        }
    }

    private mutating func cancelPending() {
        pending = nil
        pendingAt = nil
    }

    /// Moves the pill on in time: `.show` when held modifiers start to show, `.fade` when the pill
    /// starts to fade, `.gone` when the fade ended.
    public mutating func tick(at t: Double) -> Tick {
        if let pending, let pendingAt, t >= pendingAt {
            cancelPending()
            pill = Pill(combo: nil, modifiers: pending, count: 1)
            phase = .shown
            fadeAt = nil
            return .show
        }
        guard let fadeAt else { return .none }
        switch phase {
        case .shown where t >= fadeAt:
            phase = .fading
            return .fade
        case .fading where t >= fadeAt + Self.fadeOutS:
            phase = .hidden
            pill = nil
            self.fadeAt = nil
            return .gone
        default:
            return .none
        }
    }

    /// Drops the pill and the held modifiers at once (keystrokes turned off, secure input, no
    /// Accessibility).
    public mutating func clear() {
        pill = nil
        phase = .hidden
        fadeAt = nil
        cancelPending()
        modifiersMuted = false
    }
}

/// Where the pill sits: centered left to right in the recording frame, its center 14% of the
/// frame's height above the frame's bottom edge (CleanShot X's place), at a size that follows the
/// frame (28 pt type in the 1504x846 pt frame). Global CG points (top-left origin).
public enum KeystrokePlacement {
    /// The pill's center, as a part of the frame height above the frame's bottom edge.
    public static let raiseFraction: CGFloat = 0.14
    /// 28 pt type in an 846 pt tall frame.
    public static let referenceFontSize: CGFloat = 28
    public static let referenceFrameHeight: CGFloat = 846
    public static let fontSizeRange: ClosedRange<CGFloat> = 18...44

    /// The type size for a frame `frameHeight` points tall.
    public static func fontSize(frameHeight: CGFloat) -> CGFloat {
        guard frameHeight > 0 else { return referenceFontSize }
        let size = (referenceFontSize * frameHeight / referenceFrameHeight).rounded()
        return min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// The pill's center.
    public static func pillCenter(frameGlobal f: CGRect) -> CGPoint {
        CGPoint(x: f.midX, y: f.maxY - raiseFraction * f.height)
    }

    /// The HUD window: a transparent strip as wide as the frame, three type sizes tall, centered
    /// on the pill's center and kept inside the frame. The pill is drawn in its middle.
    public static func windowRect(frameGlobal f: CGRect) -> CGRect {
        let height = min(f.height, (fontSize(frameHeight: f.height) * 3).rounded(.up))
        let center = pillCenter(frameGlobal: f)
        let y = min(max(center.y - height / 2, f.minY), f.maxY - height)
        return CGRect(x: f.minX, y: y, width: f.width, height: height)
    }

    /// The pill's corner radius for a type size: 12 pt at 28 pt.
    public static func cornerRadius(fontSize: CGFloat) -> CGFloat { (12 * fontSize / referenceFontSize).rounded() }
}
