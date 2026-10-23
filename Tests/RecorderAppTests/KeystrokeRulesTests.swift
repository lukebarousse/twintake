import Foundation
import Testing
import WindowTools
@testable import RecorderApp
@testable import RecorderCore

@Suite struct KeystrokeRulesTests {
    @Test func whenKeystrokesShow() {
        #expect(!KeystrokeRules.showsKeystrokes(.off, recording: true))
        #expect(!KeystrokeRules.showsKeystrokes(.whileRecording, recording: false))
        #expect(KeystrokeRules.showsKeystrokes(.whileRecording, recording: true))
        #expect(KeystrokeRules.showsKeystrokes(.always, recording: false))
        #expect(KeystrokeRules.showsKeystrokes(.always, recording: true))
    }

    /// The pill's window is on screen while keystrokes show, and for the whole take (Start to
    /// saved) when the take's screen filter holds it, so a mode turned Off and on again mid-take
    /// still records.
    @Test func whenThePillsWindowIsOnScreen() {
        func on(_ mode: KeystrokeMode, recording: Bool = false, take: Bool = false, pill: Bool = false) -> Bool {
            KeystrokeRules.hudOrderedIn(mode: mode, recording: recording, takeActive: take, takeHasPillWindow: pill)
        }
        #expect(on(.always))
        #expect(!on(.off))
        #expect(!on(.whileRecording))
        // Starting (prepare builds the filter), recording and saving a take whose filter holds it.
        #expect(on(.whileRecording, take: true, pill: true))
        #expect(on(.off, recording: true, take: true, pill: true))
        // A take without the pill in its filter: only while keystrokes show.
        #expect(!on(.whileRecording, take: true))
        #expect(!on(.off, recording: true, take: true))
        #expect(on(.whileRecording, recording: true, take: true))
        // The flag is only read during a take.
        #expect(!on(.off, pill: true))
    }

    /// Keystrokes Off at Start: the pill stays out of the screen filter, so the take records the
    /// screen as without the feature (Hide other windows keeps its single-window capture).
    @Test func thePillJoinsTheScreenFilterOnlyWhenKeystrokesAreOn() {
        #expect(KeystrokeRules.pillInScreenRecording(mode: .always, keystrokesInScreen: true))
        #expect(KeystrokeRules.pillInScreenRecording(mode: .whileRecording, keystrokesInScreen: true))
        #expect(!KeystrokeRules.pillInScreenRecording(mode: .off, keystrokesInScreen: true))
        #expect(!KeystrokeRules.pillInScreenRecording(mode: .always, keystrokesInScreen: false))
    }

    /// The menu names the app that keeps secure keyboard entry on, after two watches in a row.
    @Test func secureInputNote() {
        #expect(KeystrokeRules.secureInputNote(checks: 0, holder: nil) == nil)
        #expect(KeystrokeRules.secureInputNote(checks: 1, holder: "1Password") == nil)
        let named = KeystrokeRules.secureInputNote(checks: 2, holder: "1Password")
        #expect(named?.hasPrefix("Keystrokes are hidden: 1Password has secure keyboard entry on") == true)
        #expect(KeystrokeRules.secureInputNote(checks: 5, holder: nil)?.contains("Another app has") == true)
        #expect(KeystrokeRules.secureInputNote(checks: 5, holder: "")?.contains("Another app has") == true)
    }

    @Test func eventData() {
        let data = KeystrokeRules.eventData(label: "Ctrl+Shift+P", macLabel: "⇧⌘P", count: 3, elapsedS: 754.26)
        #expect(data == ["label": "Ctrl+Shift+P", "mac_label": "⇧⌘P", "repeat": "3", "elapsed_s": "754.3"])
        #expect(KeystrokeRules.eventData(label: "⌘Z", macLabel: "⌘Z", count: 1, elapsedS: -0.2)["elapsed_s"] == "0.0")
        #expect(SessionEvent.Kind.keystroke.rawValue == "keystroke")
    }

    @Test func sessionStartData() {
        #expect(KeystrokeRules.sessionStartData(mode: .always, inScreen: true) == ["keystrokes": "always", "keystrokes_in_screen": "on"])
        #expect(KeystrokeRules.sessionStartData(mode: .whileRecording, inScreen: false)
                == ["keystrokes": "while_recording", "keystrokes_in_screen": "off"])
        #expect(KeystrokeRules.sessionStartData(mode: .off, inScreen: nil) == ["keystrokes": "off"])
    }

    /// TwinTake's own hotkeys never show (a Flag press stays out of screen.mov), not even their
    /// modifiers while they are held.
    @Test func ownHotKeysAreReserved() {
        for action in HotKeyAction.allCases { #expect(KeystrokeRules.reserved.contains(action.defaultHotKey)) }
        let flag = HotKey.flag
        #expect(KeystrokeFilter.combo(keyCode: UInt16(flag.keyCode), modifiers: flag.modifiers,
                                      reserved: KeystrokeRules.reserved, character: { "b" }) == nil)
        #expect(KeystrokeRules.hiddenModifierSets == [[.control, .option, .command]])
        for action in HotKeyAction.allCases {
            #expect(KeystrokeRules.hiddenModifierSets.contains(action.defaultHotKey.modifiers))
        }
        // ⌃⌥⌘ down within a few frames, held, the hotkey's key taken by the hotkey, the keys up
        // slowly: no pill at any point.
        var tracker = KeystrokeTracker(hiddenModifierSets: KeystrokeRules.hiddenModifierSets)
        var t = 0.0
        let steps: [(HotKey.Modifiers, Double)] = [([.control], 0.05), ([.control, .option], 0.05),
                                                   ([.control, .option, .command], 0.6), ([.option, .command], 0.4),
                                                   ([.command], 0.4), ([], 1)]
        for (held, wait) in steps {
            tracker.modifiersChanged(held, at: t)
            t += wait
            let tick = tracker.tick(at: t)
            #expect(tick == .none && tracker.pill == nil, "\(held.symbols)")
        }
    }

    @Test func accessibilityNote() {
        #expect(KeystrokeRules.accessibilityNote(mode: .always, accessibilityGranted: false) != nil)
        #expect(KeystrokeRules.accessibilityNote(mode: .whileRecording, accessibilityGranted: false) != nil)
        #expect(KeystrokeRules.accessibilityNote(mode: .off, accessibilityGranted: false) == nil)
        #expect(KeystrokeRules.accessibilityNote(mode: .always, accessibilityGranted: true) == nil)
    }

    @Test func schemaIsOneSix() {
        #expect(SessionManifest.currentSchemaVersion == "1.6")
    }
}

@MainActor
@Suite struct KeystrokeSettingsTests {
    @Test func defaultsAndPersistence() {
        let name = "KeystrokeSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        #expect(s.keystrokeMode == .always)
        #expect(s.keystrokesInScreen)
        #expect(s.keyNameStyle == .auto)
        s.keystrokeMode = .whileRecording
        s.keystrokesInScreen = false
        s.keyNameStyle = .windows
        let again = RecorderSettings(defaults: defaults)
        #expect(again.keystrokeMode == .whileRecording && !again.keystrokesInScreen && again.keyNameStyle == .windows)
        defaults.set("bogus", forKey: RecorderSettings.Key.keystrokes)
        defaults.set("bogus", forKey: RecorderSettings.Key.keyNames)
        let bad = RecorderSettings(defaults: defaults)
        #expect(bad.keystrokeMode == .always && bad.keyNameStyle == .auto)
    }
}

/// Source checks: the pill is the only TwinTake window that screen captures may record, the app
/// names it in the screen filter before the recorder is made, and no key monitor starts outside
/// launch (tests and the docs screenshots never run one).
@Suite struct KeystrokeSourceTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func code(_ path: String) throws -> [String] {
        try ThreadRuleTests.codeLines(root.appendingPathComponent(path)).map(\.1)
    }

    @Test func onlyThePillMayBeRecorded() throws {
        var sharing: [String: [String]] = [:]
        for folder in ["Sources/RecorderApp", "Sources/WindowTools"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: Self.root.appendingPathComponent(folder).path)
            for name in names where name.hasSuffix(".swift") {
                let lines = try Self.code("\(folder)/\(name)").filter { $0.contains(".sharingType =") }
                if !lines.isEmpty { sharing[name] = lines }
            }
        }
        #expect(sharing["KeystrokeHUD.swift"]?.allSatisfy { $0.contains(".sharingType = .readOnly") } == true)
        for (name, lines) in sharing where name != "KeystrokeHUD.swift" {
            #expect(lines.allSatisfy { $0.contains(".sharingType = .none") }, "\(name)")
        }
        for name in ["CameraWindow.swift", "ControlBar.swift", "ReplayWindow.swift", "FrameOverlay.swift"] {
            #expect(sharing[name] != nil, "\(name)")
        }
    }

    @Test func thePillIsNamedBeforeTheScreenRecorderIsMade() throws {
        let code = try Self.code("Sources/RecorderApp/SessionCoordinator.swift")
        let start = try #require(code.firstIndex { $0.contains("private func runStart(claimed: WarmCamera?) async {") })
        let body = Array(code[start...])
        let named = try #require(body.firstIndex { $0.contains("keystrokes?.prepareForTake(frameGlobal: s.frameGlobal)") })
        let shown = try #require(body.firstIndex { $0.contains("screenConfig?.shownOwnWindowIDs = [id]") })
        let made = try #require(body.firstIndex { $0.contains("let screenRecorder = screenConfig.map { ScreenRecorder(config: $0, levels: levels) }") })
        let prepared = try #require(body.firstIndex { $0.contains("await Self.prepareAll(camera: cameraRecorder") })
        #expect(named < shown && shown < made && made < prepared)
        // Not with Keystrokes Off (finding: an Off take must record the screen as before).
        let gate = try #require(body.firstIndex { $0.contains("KeystrokeRules.pillInScreenRecording(mode: settings.keystrokeMode") })
        #expect(gate + 1 == named)
        // A TwinTake hotkey mutes the held-modifiers pill before it acts.
        let handle = try #require(code.firstIndex { $0.contains("private func handle(_ action: HotKeyAction) {") })
        #expect(code[handle...].prefix(4).contains { $0.contains("keystrokes?.hotKeyPressed()") })
        // The controller (and its key monitor) is made in launch() only.
        #expect(code.filter { $0.contains("KeystrokeController(coordinator: self)") }.count == 1)
        let launch = try #require(code.firstIndex { $0.contains("func launch() {") })
        #expect(code[launch...].prefix(25).contains { $0.contains("keystrokes = KeystrokeController(coordinator: self)") })
    }

    /// The monitor installs nothing without Accessibility, so it never makes macOS ask, and it
    /// passes nothing on during secure keyboard entry.
    @Test func theMonitorNeedsTrustAndRespectsSecureInput() throws {
        let code = try Self.code("Sources/WindowTools/KeyMonitor.swift")
        let start = try #require(code.firstIndex { $0.contains("public func start() -> Bool {") })
        let trust = try #require(code.firstIndex { $0.contains("guard Self.isTrusted else { return false }") })
        let global = try #require(code.firstIndex { $0.contains("NSEvent.addGlobalMonitorForEvents") })
        #expect(start < trust && trust < global)
        #expect(code.contains { $0.contains("guard let handler, !Self.isSecureInputOn else { return }") })
        #expect(!code.contains { $0.contains("CGEvent.tapCreate") || $0.contains("CGRequestListenEventAccess") })
    }
}
