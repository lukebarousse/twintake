import Foundation
import WindowTools

/// When the on-screen keystrokes show (the Keystrokes setting).
enum KeystrokeMode: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Only while a take records.
    case whileRecording = "while_recording"
    /// While TwinTake runs, idle and recording (the default).
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .whileRecording: "While recording"
        case .always: "Always"
        }
    }
}

/// The app's rules for the on-screen keystrokes. Plain logic, unit tested; `KeystrokeController`
/// follows them.
enum KeystrokeRules {
    /// TwinTake's own hotkeys never show: they control the recorder (a Flag, Start/Stop), not the
    /// recorded app, so they stay out of screen.mov and events.jsonl.
    static let reserved: Set<HotKey> = Set(HotKeyAction.allCases.map(\.defaultHotKey))

    /// The modifiers of `reserved` (⌃⌥⌘): held without a key they never show, so pressing a
    /// TwinTake hotkey puts no pill on screen or in screen.mov.
    static let hiddenModifierSets: Set<HotKey.Modifiers> = Set(reserved.map(\.modifiers))

    /// The key monitor runs and the pill shows: always for Always, during a take for While
    /// recording (from the first frame to Stop), never for Off.
    static func showsKeystrokes(_ mode: KeystrokeMode, recording: Bool) -> Bool {
        switch mode {
        case .off: false
        case .whileRecording: recording
        case .always: true
        }
    }

    /// At Start: the pill's window goes into the screen stream's filter (screen.mov shows it).
    /// Not with Keystrokes Off, so an Off take records the screen exactly as without the feature
    /// (Hide other windows keeps its single-window capture).
    static func pillInScreenRecording(mode: KeystrokeMode, keystrokesInScreen: Bool) -> Bool {
        mode != .off && keystrokesInScreen
    }

    /// The pill's window is on screen (it draws nothing between keystrokes): while keystrokes
    /// show, and from Start until the take is saved when the take's screen filter holds it
    /// (`takeHasPillWindow`). So a take started with keystrokes in screen.mov keeps the window for
    /// the filter built at prepare, and a mode turned Off and on again mid-take still records.
    /// - Parameter takeActive: a take is starting, recording or saving.
    static func hudOrderedIn(mode: KeystrokeMode, recording: Bool, takeActive: Bool, takeHasPillWindow: Bool) -> Bool {
        showsKeystrokes(mode, recording: recording) || (takeActive && takeHasPillWindow)
    }

    /// Watches in a row (`KeystrokeController.watchInterval` apart) with secure keyboard entry on
    /// before the menu says so: typing a password does not flash a note.
    static let secureInputChecksBeforeNote = 2

    /// Why keystrokes cannot show while secure keyboard entry stays on: macOS keeps every key from
    /// TwinTake then, and an app can leave it on by mistake after its password field closes.
    /// - Parameters:
    ///   - checks: watches in a row that found it on.
    ///   - holder: the app that has it on, when macOS names it.
    static func secureInputNote(checks: Int, holder: String?) -> String? {
        guard checks >= secureInputChecksBeforeNote else { return nil }
        let app = holder.map { $0.isEmpty ? "Another app" : $0 } ?? "Another app"
        return "Keystrokes are hidden: \(app) has secure keyboard entry on (a password field, or Terminal's "
            + "Secure Keyboard Entry). Leave that field, or quit the app."
    }

    /// `data` of a `keystroke` event: `label` (the text the pill shows, without the count),
    /// `mac_label` (the same keys in Mac symbols), `repeat` (1, 2, 3 … for presses in a row) and
    /// `elapsed_s` (take time, like a flag's: seconds since the files began, one decimal).
    static func eventData(label: String, macLabel: String, count: Int, elapsedS: Double) -> [String: String] {
        ["label": label, "mac_label": macLabel, "repeat": String(count), "elapsed_s": String(format: "%.1f", max(0, elapsedS))]
    }

    /// `session_start` data: `keystrokes` (the mode) and, when the take records the screen,
    /// `keystrokes_in_screen` (`on` when the pill's window is in screen.mov's filter).
    static func sessionStartData(mode: KeystrokeMode, inScreen: Bool?) -> [String: String] {
        var data = ["keystrokes": mode.rawValue]
        if let inScreen { data["keystrokes_in_screen"] = inScreen ? "on" : "off" }
        return data
    }

    /// Why keystrokes cannot show, for the menu: both key sources need Accessibility (the AppKit
    /// monitors, and the event tap, which listens with the access Accessibility gives). No note
    /// while a tap that got a key press runs: keystrokes show then.
    static func accessibilityNote(mode: KeystrokeMode, accessibilityGranted: Bool, tapProven: Bool = false) -> String? {
        guard mode != .off, !accessibilityGranted, !tapProven else { return nil }
        return "Keystrokes need Accessibility. Allow it under Permissions."
    }

    // MARK: - Key source

    /// What a key press does to the pill. The same for both key sources: the event tap sees
    /// TwinTake's own hotkeys too, so they are filtered here, not only by macOS.
    enum KeyDownAction: Equatable {
        /// One of TwinTake's hotkeys: it shows nothing, and its held modifiers show nothing either.
        case muteModifiers
        /// A shortcut or a named key: the pill shows it (an auto-repeat only keeps it on).
        case press(KeyCombo, isRepeat: Bool)
        /// Typing, or a key that never shows.
        case none
    }

    /// The pill's answer to a key press (`KeystrokeFilter.combo` with `reserved`).
    /// - Parameters:
    ///   - optionTypes: ⌥ types text with a character key (false in a Parallels Windows VM).
    ///   - character: the key's layout character, read only for a key that shows.
    static func keyDownAction(keyCode: UInt16, isRepeat: Bool, modifiers: HotKey.Modifiers, optionTypes: Bool,
                              character: () -> String?) -> KeyDownAction {
        if reserved.contains(HotKey(keyCode: UInt32(keyCode), modifiers: modifiers)) { return .muteModifiers }
        guard let combo = KeystrokeFilter.combo(keyCode: keyCode, modifiers: modifiers, reserved: reserved,
                                                optionTypes: optionTypes, character: character) else { return .none }
        return .press(combo, isRepeat: isRepeat)
    }

    /// The key sources that run: the event tap alone once it proved itself (it also sees
    /// shortcuts other apps own, such as CleanShot X's ⇧⌘4), else the AppKit monitors with
    /// Accessibility, next to a new tap that has not reported a key press yet (`TapProof`: a tap can
    /// get no keys until a relaunch). Both run only then, and `KeyEventDeduper` counts a press both
    /// report once.
    static func keySources(showing: Bool, tapRunning: Bool, tapProven: Bool, accessibilityGranted: Bool) -> Set<KeySource> {
        guard showing else { return [] }
        if tapRunning, tapProven { return [.tap] }
        var sources: Set<KeySource> = tapRunning ? [.tap] : []
        if accessibilityGranted { sources.insert(.monitors) }
        return sources
    }

    /// How long between tries to create the tap while listening is allowed and it does not run (a
    /// fresh Accessibility grant can reach the tap only after a while, or after a relaunch).
    static let tapRetryS = 3.0

    /// The longest wait between tries once the menu asks for a relaunch.
    static let tapRetryMaxS = 60.0

    /// Seconds between tries: `tapRetryS` until the menu asks for a relaunch (a fresh grant still
    /// starts the tap within seconds), then twice as long after each further failure, at most
    /// `tapRetryMaxS`: until the relaunch, each try fails the same way.
    static func tapRetryInterval(failures: Int) -> Double {
        let steps = min(max(0, failures - tapFailuresBeforeRelaunchNote + 1), 5)
        return min(tapRetryS * Double(1 << steps), tapRetryMaxS)
    }

    /// Listening counts as allowed only with Accessibility, so Accessibility alone turns the tap on
    /// and off. Listen access alone (an old grant of its own, which the menu does not list) never
    /// keeps a tap running.
    /// - Parameters:
    ///   - accessibilityGranted: `KeyMonitor.isTrusted`.
    ///   - listenAccess: `KeyMonitor.isListenAllowed` (`CGPreflightListenEventAccess`). It never asks.
    static func listenAllowed(accessibilityGranted: Bool, listenAccess: Bool) -> Bool {
        accessibilityGranted && listenAccess
    }

    /// Try to create the tap now: keystrokes show, listening is allowed (a key tap created without
    /// it makes macOS ask, so never then), the tap does not run, and the last try was at least
    /// `tapRetryInterval(failures:)` ago.
    /// - Parameters:
    ///   - listenAllowed: `listenAllowed(accessibilityGranted:listenAccess:)`. It never asks.
    ///   - sinceLastTryS: seconds since the last try; nil when there was none.
    ///   - failures: `tapFailures` so far.
    static func shouldTryTap(showing: Bool, listenAllowed: Bool, tapRunning: Bool, sinceLastTryS: Double?,
                             failures: Int = 0) -> Bool {
        guard showing, listenAllowed, !tapRunning else { return false }
        return sinceLastTryS.map { $0 >= tapRetryInterval(failures: failures) } ?? true
    }

    /// The running tap stays: keystrokes show and listening is still allowed. Else it is removed
    /// (Keystrokes Off, or Accessibility was taken away).
    static func keepsTap(showing: Bool, listenAllowed: Bool) -> Bool {
        showing && listenAllowed
    }

    /// Failed tries in a row (`tapRetryS` apart) before the menu asks for a relaunch. A tap that got
    /// no keys while the AppKit monitors did (`TapProof`) counts as this many at once.
    static let tapFailuresBeforeRelaunchNote = 2

    /// The failures after a try or a check: none once a tap proved itself, one more for a tap
    /// macOS refused, and at least `tapFailuresBeforeRelaunchNote` for a deaf tap.
    static func tapFailures(after failures: Int, proven: Bool, refused: Bool, deaf: Bool) -> Int {
        if proven { return 0 }
        var n = failures + (refused ? 1 : 0)
        if deaf { n = max(n + 1, tapFailuresBeforeRelaunchNote) }
        return n
    }

    /// Listening is allowed but macOS gives TwinTake no working tap yet (refused, or deaf): after a
    /// fresh Accessibility grant it often needs a relaunch. The AppKit monitors keep the keystrokes
    /// going meanwhile. It stays while a new tap waits for its first key press, so it does not
    /// flicker.
    /// - Parameter showing: keystrokes show (the tap is only tried then).
    static func tapRelaunchNote(showing: Bool, listenAllowed: Bool, tapProven: Bool, failures: Int) -> String? {
        guard showing, listenAllowed, !tapProven, failures >= tapFailuresBeforeRelaunchNote else { return nil }
        return relaunchNote
    }

    /// The menu's note when the tap needs a relaunch.
    static let relaunchNote = "Quit and reopen TwinTake to show shortcuts other apps own (CleanShot X's ⇧⌘4)."

    /// The warning when the pill's window was not in the screen stream's filter at prepare.
    static let notInScreenMessage = "The keystroke pill's window was not found, so keystrokes are not in screen.mov."
}
