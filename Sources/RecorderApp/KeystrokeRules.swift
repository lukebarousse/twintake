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

    /// Why keystrokes cannot show, for the menu: the AppKit key monitors need Accessibility, and no
    /// event tap (Input Monitoring) proved itself with a key press. With Input Monitoring allowed
    /// and no Accessibility, nothing can tell a tap that waits for its first key from one that
    /// gets no keys until a relaunch (no monitor runs to compare with), so the note says what to
    /// do if nothing shows.
    static func accessibilityNote(mode: KeystrokeMode, accessibilityGranted: Bool, inputMonitoringGranted: Bool = false,
                                  tapProven: Bool = false) -> String? {
        guard mode != .off, !accessibilityGranted, !tapProven else { return nil }
        return inputMonitoringGranted
            ? "If no keystrokes show, allow Accessibility under Permissions, or quit and reopen TwinTake."
            : "Keystrokes need Accessibility. Allow it under Permissions."
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

    /// How long between tries to create the tap while Input Monitoring is allowed and it does not
    /// run (a grant can reach the tap only after a while, or after a relaunch).
    static let tapRetryS = 3.0

    /// Try to create the tap now: keystrokes show, Input Monitoring is allowed (a key tap created
    /// without it makes macOS ask, so never then), the tap does not run, and the last try was at
    /// least `tapRetryS` ago.
    /// - Parameter sinceLastTryS: seconds since the last try; nil when there was none.
    static func shouldTryTap(showing: Bool, inputMonitoringGranted: Bool, tapRunning: Bool, sinceLastTryS: Double?) -> Bool {
        guard showing, inputMonitoringGranted, !tapRunning else { return false }
        return sinceLastTryS.map { $0 >= tapRetryS } ?? true
    }

    /// The running tap stays: keystrokes show and Input Monitoring is still allowed. Else it is
    /// removed (Keystrokes Off, or the permission was taken away) and the AppKit monitors take over.
    static func keepsTap(showing: Bool, inputMonitoringGranted: Bool) -> Bool {
        showing && inputMonitoringGranted
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

    /// Input Monitoring is allowed but macOS gives TwinTake no working tap yet: it often needs a
    /// relaunch. It stays while a new tap waits for its first key press, so it does not flicker.
    /// - Parameter showing: keystrokes show (the tap is only tried then).
    static func tapRelaunchNote(showing: Bool, inputMonitoringGranted: Bool, tapProven: Bool, failures: Int) -> String? {
        guard showing, inputMonitoringGranted, !tapProven, failures >= tapFailuresBeforeRelaunchNote else { return nil }
        return "Input Monitoring is allowed, but macOS has not given it to TwinTake yet. Quit and reopen TwinTake "
            + "to show shortcuts other apps own (⇧⌘4)."
    }

    /// The line under Keystrokes that says whether shortcuts other apps own show: from the tap
    /// (it got a key press), else from the permission, which also holds while keystrokes do not
    /// show and while a new tap waits for its first key press.
    static func sourceCaption(inputMonitoringGranted: Bool, tapProven: Bool) -> String {
        if tapProven { return "Input Monitoring is on, so shortcuts other apps own show too (CleanShot X's ⇧⌘4)." }
        if inputMonitoringGranted {
            return "Input Monitoring is allowed. Shortcuts other apps own (CleanShot X's ⇧⌘4) show whole once "
                + "TwinTake gets keys through it."
        }
        return "Shortcuts another app owns (CleanShot X's ⇧⌘4) show only their ⇧⌘. Allow Input Monitoring under "
            + "Permissions to show them whole."
    }

    /// `defaults` key (Bool) that puts the event tap at the tail of the session's taps instead of
    /// the head, for a device check (see docs/TESTING.md, Input Monitoring). Read at launch.
    static let tapAtTailDefaultsKey = "keystrokeTapAtTail"

    /// The warning when the pill's window was not in the screen stream's filter at prepare.
    static let notInScreenMessage = "The keystroke pill's window was not found, so keystrokes are not in screen.mov."
}
