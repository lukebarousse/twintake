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

    /// Why keystrokes cannot show, for the menu: the global key monitor needs Accessibility.
    static func accessibilityNote(mode: KeystrokeMode, accessibilityGranted: Bool) -> String? {
        guard mode != .off, !accessibilityGranted else { return nil }
        return "Keystrokes need Accessibility. Allow it under Permissions."
    }

    /// The warning when the pill's window was not in the screen stream's filter at prepare.
    static let notInScreenMessage = "The keystroke pill's window was not found, so keystrokes are not in screen.mov."
}
