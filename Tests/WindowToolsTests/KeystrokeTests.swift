import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import WindowTools

private let cmd: HotKey.Modifiers = [.command]
private let shiftCmd: HotKey.Modifiers = [.shift, .command]

/// Runs the filter with a fixed layout character, and counts the reads of it.
private final class Layout {
    var reads = 0
    let character: String?
    init(_ character: String?) { self.character = character }
    func read() -> String? {
        reads += 1
        return character
    }
}

private func combo(_ keyCode: Int, _ modifiers: HotKey.Modifiers, _ character: String? = nil,
                   reserved: Set<HotKey> = [], optionTypes: Bool = true) -> KeyCombo? {
    let layout = Layout(character)
    return KeystrokeFilter.combo(keyCode: UInt16(keyCode), modifiers: modifiers, reserved: reserved, optionTypes: optionTypes,
                                 character: layout.read)
}

@Suite struct KeystrokeFilterTests {
    /// Typing never shows: plain characters, ⇧ with a character, Space alone or with ⇧. The
    /// layout is not even read for them.
    @Test func typingNeverShows() {
        for (code, char) in [(kVK_ANSI_A, "a"), (kVK_ANSI_7, "7"), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Semicolon, "ö")] {
            for modifiers in [HotKey.Modifiers(), [.shift]] {
                let layout = Layout(char)
                #expect(KeystrokeFilter.combo(keyCode: UInt16(code), modifiers: modifiers, character: layout.read) == nil)
                #expect(layout.reads == 0)
            }
        }
        #expect(combo(kVK_Space, []) == nil)
        #expect(combo(kVK_Space, [.shift]) == nil)
    }

    /// Any key with ⌘ or ⌃ shows, with or without ⇧ and ⌥.
    @Test func shortcutsShow() {
        #expect(combo(kVK_ANSI_P, shiftCmd, "p") == KeyCombo(modifiers: shiftCmd, key: .character("P")))
        #expect(combo(kVK_ANSI_7, [.option, .command], "7") == KeyCombo(modifiers: [.option, .command], key: .character("7")))
        #expect(combo(kVK_ANSI_P, [.control, .shift], "p")?.key == .character("P"))
        #expect(combo(kVK_ANSI_K, [.control, .option], "k")?.key == .character("K"))
        #expect(combo(kVK_Space, cmd) == KeyCombo(modifiers: cmd, key: .space))
        #expect(combo(kVK_Return, cmd) == KeyCombo(modifiers: cmd, key: .returnKey))
    }

    /// On a Mac, ⌥ and ⌥⇧ with a character or Space type text (–, —, é, ©, and @ [ ] { } on
    /// German or French layouts): never shown, the layout not even read. ⌥ with a named key is a
    /// shortcut (⌥←, ⌥ Delete). In a Windows VM ⌥ is Alt, so Alt with a character shows.
    @Test func optionWithACharacterIsTypingOnAMac() {
        for (code, char) in [(kVK_ANSI_Minus, "-"), (kVK_ANSI_E, "e"), (kVK_ANSI_L, "l"), (kVK_ANSI_5, "5")] {
            for modifiers in [HotKey.Modifiers([.option]), [.option, .shift]] {
                let layout = Layout(char)
                #expect(KeystrokeFilter.combo(keyCode: UInt16(code), modifiers: modifiers, character: layout.read) == nil)
                #expect(layout.reads == 0)
            }
        }
        #expect(combo(kVK_Space, [.option]) == nil)
        #expect(combo(kVK_Space, [.option, .shift]) == nil)
        #expect(combo(kVK_LeftArrow, [.option]) == KeyCombo(modifiers: [.option], key: .left))
        #expect(combo(kVK_Delete, [.option]) == KeyCombo(modifiers: [.option], key: .delete))
        #expect(combo(kVK_RightArrow, [.option, .shift]) == KeyCombo(modifiers: [.option, .shift], key: .right))
        // A Windows VM: Alt+F, Alt+Shift+E and Alt+Space are shortcuts; ⇧ with a character is still text.
        #expect(combo(kVK_ANSI_F, [.option], "f", optionTypes: false) == KeyCombo(modifiers: [.option], key: .character("F")))
        #expect(combo(kVK_ANSI_E, [.option, .shift], "e", optionTypes: false)?.key == .character("E"))
        #expect(combo(kVK_Space, [.option], optionTypes: false) == KeyCombo(modifiers: [.option], key: .space))
        #expect(combo(kVK_ANSI_A, [.shift], "a", optionTypes: false) == nil)
    }

    /// The named keys show alone and with ⇧.
    @Test func namedKeysShowAloneAndWithShift() {
        let named: [(Int, KeystrokeKey)] = [
            (kVK_Return, .returnKey), (kVK_ANSI_KeypadEnter, .enter), (kVK_Tab, .tab), (kVK_Escape, .escape),
            (kVK_Delete, .delete), (kVK_ForwardDelete, .forwardDelete), (kVK_LeftArrow, .left), (kVK_RightArrow, .right),
            (kVK_UpArrow, .up), (kVK_DownArrow, .down), (kVK_PageUp, .pageUp), (kVK_PageDown, .pageDown),
            (kVK_Home, .home), (kVK_End, .end), (kVK_F1, .function(1)), (kVK_F5, .function(5)), (kVK_F12, .function(12)),
            (kVK_F19, .function(19)),
        ]
        for (code, key) in named {
            #expect(combo(code, []) == KeyCombo(modifiers: [], key: key), "\(key)")
            #expect(combo(code, [.shift]) == KeyCombo(modifiers: [.shift], key: key), "\(key)")
        }
    }

    /// TwinTake's own hotkeys never show (they control the recorder, not the recorded app).
    @Test func reservedHotKeysNeverShow() {
        let reserved: Set<HotKey> = [.startStop, .flag]
        #expect(combo(kVK_ANSI_R, [.control, .option, .command], "r", reserved: reserved) == nil)
        #expect(combo(kVK_ANSI_B, [.control, .option, .command], "b", reserved: reserved) == nil)
        #expect(combo(kVK_ANSI_R, cmd, "r", reserved: reserved) != nil)
    }

    /// The key's name comes from the current layout, so non-US layouts read right.
    @Test func characterComesFromTheLayout() {
        // German QWERTZ: the US Y key types Z, and ⌘ on it is ⌘Z.
        #expect(combo(kVK_ANSI_Y, cmd, "z")?.key == .character("Z"))
        // French AZERTY: the US Q key types A.
        #expect(combo(kVK_ANSI_Q, cmd, "a")?.key == .character("A"))
        #expect(combo(kVK_ANSI_Semicolon, cmd, "ö")?.key == .character("Ö"))
        #expect(combo(kVK_ANSI_Minus, cmd, "ß")?.key == .character("ß"))
        // No usable character (a dead key, a private function-key character): the US name.
        #expect(combo(kVK_ANSI_Equal, cmd, nil)?.key == .character("="))
        #expect(combo(kVK_ANSI_K, cmd, "\u{F746}")?.key == .character("K"))
        #expect(combo(kVK_ANSI_K, cmd, "")?.key == .character("K"))
        // An unknown key with nothing to show: no pill.
        #expect(combo(0x6E, cmd, nil) == nil)
    }

    @Test func keyLabelNormalizes() {
        #expect(KeystrokeFilter.keyLabel(fromCharacter: "p") == "P")
        #expect(KeystrokeFilter.keyLabel(fromCharacter: "é") == "É")
        #expect(KeystrokeFilter.keyLabel(fromCharacter: "ß") == "ß")
        #expect(KeystrokeFilter.keyLabel(fromCharacter: "[") == "[")
        #expect(KeystrokeFilter.keyLabel(fromCharacter: " ") == nil)
        #expect(KeystrokeFilter.keyLabel(fromCharacter: "\r") == nil)
        #expect(KeystrokeFilter.keyLabel(fromCharacter: "\u{F700}") == nil)
        #expect(KeystrokeFilter.keyLabel(fromCharacter: nil) == nil)
    }

    /// Held modifiers show only when they make a shortcut with any key: ⇧ alone comes before every
    /// capital, and on a Mac ⌥ (or ⌥⇧) before –, é or @.
    @Test func liveModifiers() {
        #expect(KeystrokeFilter.liveModifiers([]) == nil)
        #expect(KeystrokeFilter.liveModifiers([.shift]) == nil)
        #expect(KeystrokeFilter.liveModifiers(cmd) == cmd)
        #expect(KeystrokeFilter.liveModifiers(shiftCmd) == shiftCmd)
        #expect(KeystrokeFilter.liveModifiers([.control]) == [.control])
        #expect(KeystrokeFilter.liveModifiers([.option]) == nil)
        #expect(KeystrokeFilter.liveModifiers([.option, .shift]) == nil)
        #expect(KeystrokeFilter.liveModifiers([.option, .command]) == [.option, .command])
        #expect(KeystrokeFilter.liveModifiers([.option, .shift], optionTypes: false) == [.option, .shift])
        #expect(KeystrokeFilter.liveModifiers([.shift], optionTypes: false) == nil)
    }
}

@Suite struct KeystrokeNamesTests {
    private func mac(_ c: KeyCombo) -> String { KeystrokeNames.label(c, windows: false) }
    private func win(_ c: KeyCombo) -> String { KeystrokeNames.label(c, windows: true) }
    private func c(_ m: HotKey.Modifiers, _ k: KeystrokeKey) -> KeyCombo { KeyCombo(modifiers: m, key: k) }

    @Test func macSymbolsInAppleOrder() {
        #expect(mac(c(shiftCmd, .character("P"))) == "⇧⌘P")
        #expect(mac(c([.command, .option], .character("7"))) == "⌥⌘7")
        #expect(mac(c([.control, .option, .shift, .command], .character("K"))) == "⌃⌥⇧⌘K")
        #expect(mac(c([], .returnKey)) == "Return")
        #expect(mac(c(cmd, .returnKey)) == "⌘ Return")
        #expect(mac(c([], .escape)) == "Esc")
        #expect(mac(c([.shift], .tab)) == "⇧ Tab")
        #expect(mac(c([], .delete)) == "Delete")
        #expect(mac(c([.option], .delete)) == "⌥ Delete")
        #expect(mac(c(cmd, .left)) == "⌘←")
        #expect(mac(c([], .right)) == "→")
        #expect(mac(c([], .up)) == "↑")
        #expect(mac(c([.shift], .down)) == "⇧↓")
        #expect(mac(c([], .forwardDelete)) == "⌦")
        #expect(mac(c([], .function(5))) == "F5")
        #expect(mac(c(cmd, .space)) == "⌘ Space")
        #expect(mac(c([], .pageDown)) == "Page Down")
    }

    @Test func windowsNames() {
        #expect(win(c(shiftCmd, .character("P"))) == "Ctrl+Shift+P")
        #expect(win(c([.command, .option], .character("7"))) == "Ctrl+Alt+7")
        #expect(win(c([.control, .shift], .character("P"))) == "Ctrl+Shift+P")
        // ⌘ and ⌃ are both Ctrl: one Ctrl.
        #expect(win(c([.control, .command], .character("C"))) == "Ctrl+C")
        #expect(win(c([], .returnKey)) == "Enter")
        #expect(win(c([], .enter)) == "Enter")
        #expect(win(c([], .delete)) == "Backspace")
        #expect(win(c([], .forwardDelete)) == "Delete")
        #expect(win(c([.control, .option], .forwardDelete)) == "Ctrl+Alt+Delete")
        #expect(win(c([.shift], .tab)) == "Shift+Tab")
        #expect(win(c([], .escape)) == "Esc")
        #expect(win(c(cmd, .left)) == "Ctrl+←")
        #expect(win(c([.option], .function(4))) == "Alt+F4")
    }

    @Test func modifiersOnly() {
        #expect(KeystrokeNames.modifiersLabel(shiftCmd, windows: false) == "⇧⌘")
        #expect(KeystrokeNames.modifiersLabel(shiftCmd, windows: true) == "Ctrl+Shift")
        #expect(KeystrokeNames.modifiersLabel([.option], windows: true) == "Alt")
    }

    @Test func pillTextCountsRepeats() {
        let undo = c(cmd, .character("Z"))
        #expect(KeystrokeNames.pillText(.init(combo: undo, modifiers: cmd, count: 1), windows: false) == "⌘Z")
        #expect(KeystrokeNames.pillText(.init(combo: undo, modifiers: cmd, count: 3), windows: false) == "⌘Z ×3")
        #expect(KeystrokeNames.pillText(.init(combo: undo, modifiers: cmd, count: 2), windows: true) == "Ctrl+Z ×2")
        #expect(KeystrokeNames.pillText(.init(combo: nil, modifiers: shiftCmd, count: 1), windows: false) == "⇧⌘")
    }

    /// Auto: Windows names while a Parallels Windows VM is in front, else Mac symbols. The Mac
    /// app switcher stays Mac (macOS handles it in front of the VM too).
    @Test func autoFollowsTheFrontApp() {
        let palette = c(shiftCmd, .character("P"))
        for vm in ["com.parallels.desktop.console", "com.parallels.winapp.4f2a.VM", "com.parallels.winapp.ab12.4f2a"] {
            #expect(KeystrokeNames.usesWindowsNames(.auto, frontBundleID: vm, combo: palette), "\(vm)")
        }
        for app in ["com.microsoft.VSCode", "com.apple.Safari", "com.parallels.macvm", "com.parallels.toolbox", ""] {
            #expect(!KeystrokeNames.usesWindowsNames(.auto, frontBundleID: app, combo: palette), "\(app)")
        }
        #expect(!KeystrokeNames.usesWindowsNames(.auto, frontBundleID: nil, combo: palette))
        #expect(!KeystrokeNames.usesWindowsNames(.auto, frontBundleID: "com.parallels.desktop.console", combo: c(cmd, .tab)))
        #expect(!KeystrokeNames.usesWindowsNames(.auto, frontBundleID: "com.parallels.desktop.console", combo: c(shiftCmd, .tab)))
        #expect(KeystrokeNames.usesWindowsNames(.auto, frontBundleID: "com.parallels.desktop.console", combo: c([.control], .tab)))
        #expect(KeystrokeNames.usesWindowsNames(.windows, frontBundleID: "com.apple.Safari", combo: palette))
        #expect(!KeystrokeNames.usesWindowsNames(.mac, frontBundleID: "com.parallels.desktop.console", combo: palette))
    }
}

@Suite struct KeystrokeTrackerTests {
    private let palette = KeyCombo(modifiers: shiftCmd, key: .character("P"))
    private let undo = KeyCombo(modifiers: cmd, key: .character("Z"))
    private let hotKeyModifiers: HotKey.Modifiers = [.control, .option, .command]
    private let delay = KeystrokeTracker.modifiersDelayS

    /// CleanShot X: ⌘ held, then ⇧⌘, then ⇧⌘P when the key lands; 1.5 s, then a 0.3 s fade.
    /// Held modifiers show once they stay the same for `modifiersDelayS`, then follow at once.
    @Test func modifiersThenTheCombo() {
        var t = KeystrokeTracker()
        t.modifiersChanged(cmd, at: 0)
        #expect(t.pill == nil && t.pending == cmd && t.needsTicks)
        let early = t.tick(at: delay - 0.05)
        #expect(early == .none && t.pill == nil)
        let shown = t.tick(at: delay)
        #expect(shown == .show)
        #expect(t.pill == .init(combo: nil, modifiers: cmd, count: 1) && t.phase == .shown && t.fadeAt == nil)
        t.modifiersChanged(shiftCmd, at: 0.3)
        #expect(t.pill?.modifiers == shiftCmd && t.pill?.combo == nil && t.pending == nil)
        let r1 = t.press(palette, isRepeat: false, at: 0.4)
        #expect(r1)
        #expect(t.pill == .init(combo: palette, modifiers: shiftCmd, count: 1))
        // Releasing the modifiers keeps the combo and its time.
        t.modifiersChanged(cmd, at: 0.5)
        t.modifiersChanged([], at: 0.55)
        #expect(t.pill?.combo == palette && abs((t.fadeAt ?? 0) - 1.9) < 1e-9)
        let r2 = t.tick(at: 1.85)
        #expect(r2 == .none)
        let r3 = t.tick(at: 1.95)
        #expect(r3 == .fade && t.phase == .fading)
        let r4 = t.tick(at: 2.15)
        #expect(r4 == .none)
        let r5 = t.tick(at: 2.25)
        #expect(r5 == .gone && t.phase == .hidden && t.pill == nil && !t.needsTicks)
    }

    /// A quick shortcut shows only the combo: the modifiers never flash before it.
    @Test func aQuickShortcutShowsOnlyTheCombo() {
        var t = KeystrokeTracker()
        t.modifiersChanged(cmd, at: 0)
        t.modifiersChanged(shiftCmd, at: 0.05)
        let s1 = t.tick(at: 0.1)
        #expect(s1 == .none)
        t.press(palette, isRepeat: false, at: 0.12)
        #expect(t.pill?.combo == palette && t.pending == nil)
        // The wait for ⇧⌘ was dropped: nothing replaces the combo later.
        let s2 = t.tick(at: 0.5)
        #expect(s2 == .none && t.pill?.combo == palette)
    }

    /// ⌘Z three times while it shows: ⌘Z ×3. ⌘ pressed again between the presses keeps the count.
    @Test func repeatsCountWhileShown() {
        var t = KeystrokeTracker()
        let r6 = t.press(undo, isRepeat: false, at: 0)
        #expect(r6)
        let r7 = t.press(undo, isRepeat: false, at: 0.4)
        #expect(r7)
        t.modifiersChanged([], at: 0.5)
        t.modifiersChanged(cmd, at: 0.6)
        #expect(t.pill?.combo == undo && t.pending == nil)
        let r8 = t.press(undo, isRepeat: false, at: 0.8)
        #expect(r8)
        #expect(t.pill?.count == 3)
        // Another combo starts over.
        let r9 = t.press(palette, isRepeat: false, at: 1.0)
        #expect(r9)
        #expect(t.pill?.count == 1)
    }

    /// A press during the fade still counts; one after the pill is gone starts at 1.
    @Test func fadeCountsGoneResets() {
        var t = KeystrokeTracker()
        t.press(undo, isRepeat: false, at: 0)
        let r10 = t.tick(at: 1.5)
        #expect(r10 == .fade)
        t.press(undo, isRepeat: false, at: 1.6)
        #expect(t.pill?.count == 2 && t.phase == .shown)
        let r11 = t.tick(at: 3.15)
        #expect(r11 == .fade)
        let r12 = t.tick(at: 3.45)
        #expect(r12 == .gone)
        t.press(undo, isRepeat: false, at: 3.5)
        #expect(t.pill?.count == 1)
    }

    /// A held key (auto-repeat) keeps its pill on without counting or logging.
    @Test func autoRepeatKeepsThePillOn() {
        var t = KeystrokeTracker()
        let left = KeyCombo(modifiers: [], key: .left)
        let r13 = t.press(left, isRepeat: false, at: 0)
        #expect(r13)
        for i in 1...40 {
            let logged = t.press(left, isRepeat: true, at: Double(i) * 0.05)
            #expect(!logged)
        }
        #expect(t.pill?.count == 1 && abs((t.fadeAt ?? 0) - 3.5) < 1e-9)
        // A repeat of a key whose pill is gone shows nothing.
        var u = KeystrokeTracker()
        let r14 = u.press(left, isRepeat: true, at: 0)
        #expect(!r14)
        #expect(u.pill == nil && u.phase == .hidden)
    }

    /// ⇧ alone and ⌥ alone (typing on a Mac) show nothing; modifiers released without a key fade
    /// after a short linger.
    @Test func modifiersOnly() {
        var t = KeystrokeTracker()
        t.modifiersChanged([.shift], at: 0)
        t.modifiersChanged([.option], at: 0.1)
        #expect(t.pending == nil)
        let quiet = t.tick(at: 1)
        #expect(quiet == .none && t.pill == nil && t.phase == .hidden)
        t.modifiersChanged([.control], at: 1)
        let s3 = t.tick(at: 1 + delay)
        #expect(s3 == .show)
        #expect(t.pill?.modifiers == [.control] && t.fadeAt == nil)
        let held = t.tick(at: 30)
        #expect(held == .none)  // Held: no fade.
        t.modifiersChanged([], at: 31)
        #expect(t.fadeAt == 31 + KeystrokeTracker.modifiersLingerS)
        let r15 = t.tick(at: 31.5)
        #expect(r15 == .fade)
        // In a Windows VM ⌥ is Alt: it shows.
        var vm = KeystrokeTracker()
        vm.modifiersChanged([.option], at: 0, optionTypes: false)
        let s4 = vm.tick(at: delay)
        #expect(s4 == .show && vm.pill?.modifiers == [.option])
    }

    /// New modifiers held while a combo shows replace it once they show, unless the combo holds them.
    @Test func newModifiersReplaceTheCombo() {
        var t = KeystrokeTracker()
        t.press(undo, isRepeat: false, at: 0)
        t.modifiersChanged(shiftCmd, at: 0.2)
        #expect(t.pill?.combo == undo && t.pending == shiftCmd)
        let s5 = t.tick(at: 0.2 + delay)
        #expect(s5 == .show)
        #expect(t.pill == .init(combo: nil, modifiers: shiftCmd, count: 1))
        t.press(palette, isRepeat: false, at: 0.5)
        t.modifiersChanged(cmd, at: 0.6)
        #expect(t.pill?.combo == palette && t.pending == nil)
        t.clear()
        #expect(t.pill == nil && t.phase == .hidden && t.fadeAt == nil && t.pending == nil && !t.needsTicks)
    }

    /// TwinTake's hotkeys (⌃⌥⌘B): ⌃, ⌃⌥, ⌃⌥⌘ go down, B is taken by the hotkey (no key event),
    /// the keys come up. Nothing shows at any point.
    @Test func hotKeyModifiersNeverShow() {
        var t = KeystrokeTracker(hiddenModifierSets: [hotKeyModifiers])
        t.modifiersChanged([.control], at: 0)
        t.modifiersChanged([.control, .option], at: 0.04)
        t.modifiersChanged(hotKeyModifiers, at: 0.08)
        #expect(t.modifiersMuted && t.pending == nil)
        // Held for a while, then released one by one, slowly.
        let s6 = t.tick(at: 1)
        #expect(s6 == .none && t.pill == nil)
        t.modifiersChanged([.control, .command], at: 1.1)
        let s7 = t.tick(at: 1.5)
        #expect(s7 == .none)
        t.modifiersChanged([.command], at: 1.6)
        let s8 = t.tick(at: 2.0)
        #expect(s8 == .none && t.pill == nil && t.phase == .hidden)
        t.modifiersChanged([], at: 2.1)
        #expect(!t.modifiersMuted && !t.needsTicks)
        // Afterwards, held modifiers show again.
        t.modifiersChanged(cmd, at: 3)
        let s9 = t.tick(at: 3 + delay)
        #expect(s9 == .show && t.pill?.modifiers == cmd)
    }

    /// Slow fingers: ⌃⌥ held long enough to show, then ⌘ makes ⌃⌥⌘: the pill goes at once. A
    /// shortcut with those modifiers that is not TwinTake's still shows when its key lands.
    @Test func hotKeyModifiersClearAShownPill() {
        var t = KeystrokeTracker(hiddenModifierSets: [hotKeyModifiers])
        t.modifiersChanged([.control, .option], at: 0)
        let s10 = t.tick(at: delay)
        #expect(s10 == .show)
        t.modifiersChanged(hotKeyModifiers, at: 0.5)
        #expect(t.pill == nil && t.phase == .hidden && t.modifiersMuted)
        let arrows = KeyCombo(modifiers: hotKeyModifiers, key: .left)
        let s11 = t.press(arrows, isRepeat: false, at: 0.6)
        #expect(s11)
        #expect(t.pill?.combo == arrows)
        // A combo on show keeps its time when the hotkey's modifiers are held.
        t.modifiersChanged(hotKeyModifiers, at: 0.7)
        #expect(t.pill?.combo == arrows && t.phase == .shown)
    }

    /// The app saw a TwinTake hotkey fire: a pill of modifiers goes, nothing shows until release.
    @Test func muteDropsModifiersUntilRelease() {
        var t = KeystrokeTracker()
        t.modifiersChanged([.control, .option], at: 0)
        let s12 = t.tick(at: delay)
        #expect(s12 == .show)
        t.muteModifiers()
        #expect(t.pill == nil && t.phase == .hidden && t.needsTicks && t.followsHeldModifiers)
        t.modifiersChanged([.control], at: 1)
        let s13 = t.tick(at: 2)
        #expect(s13 == .none && t.pill == nil)
        t.modifiersChanged([], at: 2.1)
        #expect(!t.modifiersMuted && !t.followsHeldModifiers)
        // A combo on show is not touched by a mute.
        t.press(undo, isRepeat: false, at: 3)
        t.muteModifiers()
        #expect(t.pill?.combo == undo && t.phase == .shown)
    }
}

@Suite struct KeystrokePlacementTests {
    /// The 16:9 frame at the bottom of Luke's 14" display: x 4, y 136, 1504x846 pt (global, main display).
    let laptopFrame = CGRect(x: 4, y: 136, width: 1504, height: 846)

    @Test func centeredAndRaisedFourteenPercent() {
        let center = KeystrokePlacement.pillCenter(frameGlobal: laptopFrame)
        #expect(center.x == 756)
        #expect(abs(center.y - (982 - 0.14 * 846)) < 0.001)
        let rect = KeystrokePlacement.windowRect(frameGlobal: laptopFrame)
        #expect(rect.minX == laptopFrame.minX && rect.width == laptopFrame.width)
        #expect(abs(rect.midY - center.y) < 0.001)
        #expect(laptopFrame.contains(rect))
        #expect(rect.height == 84)  // 3 x 28 pt.
    }

    @Test func sizeFollowsTheFrame() {
        #expect(KeystrokePlacement.fontSize(frameHeight: 846) == 28)
        #expect(KeystrokePlacement.fontSize(frameHeight: 1080) == 36)  // A whole 4K display at 1920x1080 pt.
        #expect(KeystrokePlacement.fontSize(frameHeight: 200) == 18)
        #expect(KeystrokePlacement.fontSize(frameHeight: 5000) == 44)
        #expect(KeystrokePlacement.cornerRadius(fontSize: 28) == 12)
    }

    /// On a display above or left of the main one (negative global coordinates), and a tiny frame.
    @Test func otherDisplaysAndSmallFrames() {
        let whole = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let rect = KeystrokePlacement.windowRect(frameGlobal: whole)
        #expect(whole.contains(rect))
        #expect(abs(rect.midY - (0 - 0.14 * 1080)) < 0.001)
        let tiny = CGRect(x: 0, y: 0, width: 160, height: 40)
        #expect(tiny.contains(KeystrokePlacement.windowRect(frameGlobal: tiny)))
    }
}
