import Carbon.HIToolbox
import CoreGraphics
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
        // A tap (Input Monitoring) that got a key press shows keystrokes without Accessibility.
        #expect(KeystrokeRules.accessibilityNote(mode: .always, accessibilityGranted: false, inputMonitoringGranted: true,
                                                 tapProven: true) == nil)
        // Allowed, not proven (waiting for its first key, or getting none until a relaunch, with no
        // monitor to tell which): the note says what to do if nothing shows.
        let hint = KeystrokeRules.accessibilityNote(mode: .always, accessibilityGranted: false, inputMonitoringGranted: true)
        #expect(hint?.contains("If no keystrokes show") == true)
        #expect(hint?.contains("quit and reopen TwinTake") == true)
        #expect(KeystrokeRules.accessibilityNote(mode: .whileRecording, accessibilityGranted: false,
                                                 inputMonitoringGranted: true)?.contains("If no keystrokes show") == true)
        // Without Input Monitoring: Accessibility is the way.
        #expect(KeystrokeRules.accessibilityNote(mode: .always, accessibilityGranted: false)?
                    .contains("Keystrokes need Accessibility") == true)
        // Off, or Accessibility allowed: no note either way.
        #expect(KeystrokeRules.accessibilityNote(mode: .off, accessibilityGranted: false, inputMonitoringGranted: true) == nil)
        #expect(KeystrokeRules.accessibilityNote(mode: .always, accessibilityGranted: true, inputMonitoringGranted: true) == nil)
    }

    /// The proven tap runs alone; a new tap runs next to the AppKit monitors until its first
    /// event; without a tap, the monitors with Accessibility; else none.
    @Test func whichKeySourcesRun() {
        func sources(_ showing: Bool = true, tap: Bool, proven: Bool = false, ax: Bool) -> Set<KeySource> {
            KeystrokeRules.keySources(showing: showing, tapRunning: tap, tapProven: proven, accessibilityGranted: ax)
        }
        #expect(sources(tap: true, proven: true, ax: true) == [.tap])
        #expect(sources(tap: true, proven: true, ax: false) == [.tap])
        #expect(sources(tap: true, ax: true) == [.tap, .monitors])
        #expect(sources(tap: true, ax: false) == [.tap])
        #expect(sources(tap: false, ax: true) == [.monitors])
        #expect(sources(tap: false, ax: false) == [])
        // `proven` only counts for a running tap.
        #expect(sources(tap: false, proven: true, ax: true) == [.monitors])
        for tap in [false, true] {
            for proven in [false, true] {
                for ax in [false, true] { #expect(sources(false, tap: tap, proven: proven, ax: ax).isEmpty) }
            }
        }
    }

    /// Failures reset once a tap proved itself, grow with each refusal, and a deaf tap asks for a
    /// relaunch at once.
    @Test func tapFailures() {
        let note = KeystrokeRules.tapFailuresBeforeRelaunchNote
        #expect(KeystrokeRules.tapFailures(after: 5, proven: true, refused: false, deaf: false) == 0)
        #expect(KeystrokeRules.tapFailures(after: 0, proven: false, refused: true, deaf: false) == 1)
        #expect(KeystrokeRules.tapFailures(after: 1, proven: false, refused: true, deaf: false) == 2)
        #expect(KeystrokeRules.tapFailures(after: 1, proven: false, refused: false, deaf: false) == 1)
        #expect(KeystrokeRules.tapFailures(after: 0, proven: false, refused: false, deaf: true) == note)
        #expect(KeystrokeRules.tapFailures(after: note, proven: false, refused: false, deaf: true) == note + 1)
    }

    /// The tap is created only while keystrokes show and Input Monitoring is allowed (creating a key
    /// tap without it makes macOS ask), at most every `tapRetryS`.
    @Test func whenTheTapIsTried() {
        func tries(_ showing: Bool = true, granted: Bool = true, running: Bool = false, since: Double? = nil) -> Bool {
            KeystrokeRules.shouldTryTap(showing: showing, inputMonitoringGranted: granted, tapRunning: running, sinceLastTryS: since)
        }
        #expect(tries())
        #expect(!tries(granted: false))
        #expect(!tries(false))
        #expect(!tries(running: true))
        #expect(!tries(since: 1))
        #expect(tries(since: KeystrokeRules.tapRetryS))
        #expect(tries(since: 10))
        #expect(!tries(granted: false, since: 10))
        // The running tap goes with Keystrokes Off or the permission taken away.
        #expect(KeystrokeRules.keepsTap(showing: true, inputMonitoringGranted: true))
        #expect(!KeystrokeRules.keepsTap(showing: true, inputMonitoringGranted: false))
        #expect(!KeystrokeRules.keepsTap(showing: false, inputMonitoringGranted: true))
    }

    /// After two failed tries with Input Monitoring allowed, the menu asks for a relaunch, until a
    /// tap proves itself.
    @Test func relaunchNote() {
        func note(_ showing: Bool = true, granted: Bool = true, proven: Bool = false, failures: Int) -> String? {
            KeystrokeRules.tapRelaunchNote(showing: showing, inputMonitoringGranted: granted, tapProven: proven, failures: failures)
        }
        #expect(note(failures: 0) == nil)
        #expect(note(failures: 1) == nil)
        #expect(note(failures: 2)?.contains("Quit and reopen TwinTake") == true)
        #expect(note(granted: false, failures: 5) == nil)
        #expect(note(proven: true, failures: 5) == nil)
        #expect(note(false, failures: 5) == nil)
    }

    /// The caption under the arrow follows the tap that got a key press, else the permission, so
    /// it never asks for Input Monitoring that is allowed (keystrokes not showing, a new tap) and
    /// never says "on" next to the relaunch note.
    @Test func sourceCaption() {
        #expect(KeystrokeRules.sourceCaption(inputMonitoringGranted: true, tapProven: true).contains("Input Monitoring is on"))
        // The menu's permission state can lag the tap: a proven tap wins.
        #expect(KeystrokeRules.sourceCaption(inputMonitoringGranted: false, tapProven: true).contains("Input Monitoring is on"))
        let allowed = KeystrokeRules.sourceCaption(inputMonitoringGranted: true, tapProven: false)
        #expect(allowed.contains("Input Monitoring is allowed"))
        #expect(!allowed.contains("Allow Input Monitoring") && !allowed.contains("is on"))
        #expect(KeystrokeRules.sourceCaption(inputMonitoringGranted: false, tapProven: false).contains("Allow Input Monitoring"))
    }

    /// A key press from either source gets the same answer: TwinTake's own hotkeys mute (the tap
    /// sees them now), shortcuts show, typing shows nothing.
    @Test func keyDownActions() throws {
        func action(_ code: Int, _ flags: CGEventFlags, _ char: String?, isRepeat: Bool = false,
                    optionTypes: Bool = true) throws -> KeystrokeRules.KeyDownAction {
            let info = try #require(KeyEventInfo(tapType: .keyDown, keyCode: UInt16(code), flags: flags, isRepeat: isRepeat,
                                                 character: { char }))
            guard case let .keyDown(keyCode, rep) = info.kind else { return .none }
            return KeystrokeRules.keyDownAction(keyCode: keyCode, isRepeat: rep, modifiers: info.modifiers,
                                                optionTypes: optionTypes, character: info.character)
        }
        let ctrlOptCmd: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        for hotKeyAction in HotKeyAction.allCases {
            #expect(try action(Int(hotKeyAction.defaultHotKey.keyCode), ctrlOptCmd, "x") == .muteModifiers, "\(hotKeyAction)")
        }
        #expect(try action(kVK_ANSI_4, [.maskShift, .maskCommand], "4")
                == .press(KeyCombo(modifiers: [.shift, .command], key: .character("4")), isRepeat: false))
        #expect(try action(kVK_ANSI_Z, [.maskCommand], "z", isRepeat: true)
                == .press(KeyCombo(modifiers: [.command], key: .character("Z")), isRepeat: true))
        #expect(try action(kVK_ANSI_A, [], "a") == .none)
        #expect(try action(kVK_ANSI_A, [.maskShift], "a") == .none)
        #expect(try action(kVK_ANSI_E, [.maskAlternate], "e") == .none)
        #expect(try action(kVK_ANSI_E, [.maskAlternate], "e", optionTypes: false)
                == .press(KeyCombo(modifiers: [.option], key: .character("E")), isRepeat: false))
        // Caps lock and fn never make typing a shortcut.
        #expect(try action(kVK_ANSI_A, [.maskAlphaShift, .maskSecondaryFn], "a") == .none)
    }

    @Test func schemaIsOneSix() {
        #expect(SessionManifest.currentSchemaVersion == "1.6")
    }
}

/// Input Monitoring is an optional permission: it only adds shortcuts other apps own.
@Suite struct InputMonitoringPermissionTests {
    @Test func optionalAndListed() {
        #expect(PermissionKind.allCases.contains(.inputMonitoring))
        #expect(!PermissionKind.inputMonitoring.isRequired)
        for kind in PermissionKind.allCases where kind != .inputMonitoring { #expect(kind.isRequired, "\(kind)") }
        #expect(PermissionKind.inputMonitoring.title == "Input Monitoring")
        #expect(PermissionKind.inputMonitoring.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        #expect(PermissionKind.inputMonitoring.caption(.notGranted)
                == "Optional, for showing shortcuts other apps own (e.g. ⇧⌘4) · Not allowed")
        #expect(PermissionKind.camera.caption(.granted) == "For camera.mov · Allowed")
    }

    /// The Permissions section opens by itself only for a missing required permission.
    @Test func menuOpensPermissionsOnlyForRequiredOnes() throws {
        let code = try KeystrokeSourceTests.code("Sources/RecorderApp/MenuContentView.swift")
        #expect(code.contains { $0.contains("PermissionKind.allCases.contains(where: { $0.isRequired && coordinator.permissions.state($0) != .granted })") })
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

    /// The AppKit monitors install nothing without Accessibility, so they never make macOS ask,
    /// and nothing is passed on during secure keyboard entry.
    @Test func theMonitorNeedsTrustAndRespectsSecureInput() throws {
        let code = try Self.code("Sources/WindowTools/KeyMonitor.swift")
        let start = try #require(code.firstIndex { $0.contains("public func startMonitors() -> Bool {") })
        let trust = try #require(code.firstIndex { $0.contains("guard Self.isTrusted else { return false }") })
        let global = try #require(code.firstIndex { $0.contains("NSEvent.addGlobalMonitorForEvents") })
        #expect(start < trust && trust < global)
        #expect(code.contains { $0.contains("guard let handler, !Self.isSecureInputOn else { return }") })
        #expect(!code.contains { $0.contains("CGEvent.tapCreate") || $0.contains("CGRequestListenEventAccess") })
        // The tap's first key press removes the monitors: one source only from then on. A deaf tap
        // (the monitors get key presses, the tap none) is removed. `TapProof` gets the event kind,
        // secure keyboard entry and the monitors' event time, so its tests cover both rules.
        #expect(code.contains { $0.contains("if proof.tapEvent(keyDown: event.type == .keyDown, secureInput: Self.isSecureInputOn) {") })
        #expect(code.contains {
            $0.contains("proof.monitorEvent(keyDown: event.type == .keyDown, secureInput: Self.isSecureInputOn, at: event.timestamp)")
        })
        #expect(code.contains { $0.contains("guard !tapProven else { return false }") })
        #expect(code.contains { $0.contains("proof = TapProof(startedAt: startedAt)") })
    }

    /// The tap: created only after the Input Monitoring check (creating a key tap without it makes
    /// macOS ask), listen only, at the session level, and its callback only hands off to the main
    /// thread. It never logs.
    @Test func theTapNeedsInputMonitoringAndOnlyListens() throws {
        let code = try Self.code("Sources/WindowTools/KeyEventTap.swift")
        let preflight = try #require(code.firstIndex { $0.contains("guard CGPreflightListenEventAccess() else { return nil }") })
        let create = try #require(code.firstIndex { $0.contains("CGEvent.tapCreate(") })
        #expect(preflight < create)
        #expect(code.filter { $0.contains("CGEvent.tapCreate(") }.count == 1)
        #expect(code.contains { $0.contains("tap: .cgSessionEventTap, place: place, options: .listenOnly") })
        #expect(code.contains { $0.contains("static func start(place: CGEventTapPlacement = .headInsertEventTap,") })
        #expect(!code.contains { $0.contains(".defaultTap") || $0.contains("CGRequestListenEventAccess") })
        for word in ["Logger", "print(", "os_log", "NSLog", ".log."] {
            #expect(!code.contains { $0.contains(word) }, "\(word)")
            #expect(try !Self.code("Sources/WindowTools/KeyMonitor.swift").contains { $0.contains(word) }, "\(word)")
        }
        let monitor = try Self.code("Sources/WindowTools/KeyMonitor.swift")
        #expect(monitor.contains { $0.contains("DispatchQueue.main.async { MainActor.assumeIsolated { self?.receivedTap(") })
        // The only prompt for Input Monitoring is Permissions' request, which runs on a click.
        var asks: [String] = []
        for folder in ["Sources/RecorderApp", "Sources/WindowTools"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: Self.root.appendingPathComponent(folder).path)
            for name in names where name.hasSuffix(".swift") {
                let lines = try Self.code("\(folder)/\(name)")
                if lines.contains(where: { $0.contains("CGRequestListenEventAccess") }) { asks.append(name) }
            }
        }
        #expect(asks == ["Permissions.swift"])
        let permissions = try Self.code("Sources/RecorderApp/Permissions.swift")
        let request = try #require(permissions.firstIndex { $0.contains("func request(_ kind: PermissionKind) async {") })
        let ask = try #require(permissions.firstIndex { $0.contains("CGRequestListenEventAccess()") })
        let next = try #require(permissions[(request + 1)...].firstIndex { $0.contains("func ") })
        #expect(request < ask && ask < next)
    }

    /// The menu trusts the tap only once it got a key press, and hears of the proof (or a deaf
    /// tap) at once, not at the next 3 s watch. Keystrokes stopping forgets a deaf tap.
    @Test func theMenuFollowsTheProvenTap() throws {
        let menu = try Self.code("Sources/RecorderApp/MenuContentView.swift")
        #expect(menu.filter { $0.contains("tapProven: coordinator.keystrokeTapProven") }.count == 2)
        #expect(!menu.contains { $0.contains("keystrokeTapRunning") })
        let controller = try Self.code("Sources/RecorderApp/KeystrokeController.swift")
        let hook = try #require(controller.firstIndex { $0.contains("monitor.sourceChanged = {") })
        // Later, on the main actor: never inside a monitor's own handler.
        #expect(controller[hook + 1].contains("Task { @MainActor [weak self] in"))
        #expect(controller[(hook + 1)...].prefix(4).contains { $0.contains("self.applyKeySource()") })
        #expect(controller.contains { $0.contains("proven: monitor.tapProven,") })
        let monitor = try Self.code("Sources/WindowTools/KeyMonitor.swift")
        let stop = try #require(monitor.firstIndex { $0.contains("public func stop() {") })
        #expect(monitor[stop...].prefix(5).contains { $0.contains("tapWasDeaf = false") })
    }
}
