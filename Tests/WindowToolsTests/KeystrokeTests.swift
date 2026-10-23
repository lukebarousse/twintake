import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreText
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
    /// shortcut (⌥←, ⌥⌫). In a Windows VM ⌥ is Alt, so Alt with a character shows.
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
        #expect(mac(c([.control, .option, .shift, .command], .character("4"))) == "⌃⌥⇧⌘4")
        #expect(mac(c(shiftCmd, .character("4"))) == "⇧⌘4")
        #expect(mac(c(cmd, .left)) == "⌘←")
        #expect(mac(c([], .right)) == "→")
        #expect(mac(c([], .up)) == "↑")
        #expect(mac(c([.shift], .down)) == "⇧↓")
        #expect(mac(c([], .function(5))) == "F5")
        #expect(mac(c([.option], .function(4))) == "⌥ F4")
        #expect(mac(c(cmd, .space)) == "⌘ Space")
    }

    /// Luke: "to be consistent when I press return or enter maybe we also use shortcut symbols".
    /// Named keys read as the Mac keyboard symbols the system font draws, joined to the modifiers
    /// with no space. Page Up and Page Down have no SF symbol: they are words, like Space.
    @Test func namedKeysUseMacSymbols() {
        let symbols: [(KeystrokeKey, String)] = [
            (.returnKey, "⏎"), (.enter, "⌅"), (.delete, "⌫"), (.forwardDelete, "⌦"), (.escape, "⎋"), (.tab, "⇥"),
            (.left, "←"), (.right, "→"), (.up, "↑"), (.down, "↓"), (.home, "↖"), (.end, "↘"),
        ]
        for (key, symbol) in symbols {
            #expect(mac(c([], key)) == symbol, "\(key)")
            #expect(mac(c(cmd, key)) == "⌘" + symbol, "\(key)")
        }
        #expect(mac(c(cmd, .returnKey)) == "⌘⏎")
        #expect(mac(c([.shift], .tab)) == "⇧⇥")
        #expect(mac(c([.option], .delete)) == "⌥⌫")
        #expect(mac(c([.control, .option, .shift, .command], .returnKey)) == "⌃⌥⇧⌘⏎")
        #expect(mac(c([], .pageUp)) == "Page Up")
        #expect(mac(c([.option], .pageDown)) == "⌥ Page Down")
        #expect(KeystrokeNames.pillText(.init(combo: c([], .returnKey), modifiers: [], count: 4), windows: false) == "⏎ ×4")
        #expect(KeystrokeNames.pillText(.init(combo: c([], .delete), modifiers: [], count: 2), windows: false) == "⌫ ×2")
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
        #expect(win(c([], .tab)) == "Tab")
        #expect(win(c([], .escape)) == "Esc")
        #expect(win(c(cmd, .returnKey)) == "Ctrl+Enter")
        #expect(win(c([.control, .shift], .delete)) == "Ctrl+Shift+Backspace")
        #expect(win(c(cmd, .space)) == "Ctrl+Space")
        #expect(win(c(cmd, .left)) == "Ctrl+←")
        #expect(win(c([.option], .function(4))) == "Alt+F4")
        #expect(win(c([], .pageUp)) == "Page Up")
        #expect(win(c([], .pageDown)) == "Page Down")
        #expect(win(c([.shift], .home)) == "Shift+Home")
        #expect(win(c([.shift], .end)) == "Shift+End")
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

    /// Luke: "shift is popping up when pressed". ⇧ down and up alone shows nothing, however long
    /// it is held, and leaves nothing to tick; ⇧ during a combo's pill keeps that pill. ⇧ with ⌘
    /// shows ⇧⌘ after the delay (the pill for it is checked in `KeystrokePillTests`).
    @Test func shiftAloneShowsNothing() {
        var t = KeystrokeTracker(hiddenModifierSets: [hotKeyModifiers])
        t.modifiersChanged([.shift], at: 0)
        #expect(t.pending == nil && t.pill == nil && !t.needsTicks && !t.followsHeldModifiers)
        for i in 1...60 {
            let tick = t.tick(at: Double(i) * 0.05)
            #expect(tick == .none && t.pill == nil && t.phase == .hidden)
        }
        t.modifiersChanged([], at: 3.1)
        #expect(t.pill == nil && t.phase == .hidden && !t.needsTicks)
        // ⇧ pressed while ⌘Z shows: ⌘Z stays and keeps its time.
        t.press(undo, isRepeat: false, at: 4)
        t.modifiersChanged([], at: 4.1)
        t.modifiersChanged([.shift], at: 4.5)
        let kept = t.tick(at: 4.5 + delay)
        #expect(kept == .none && t.pill?.combo == undo && t.pending == nil)
        #expect(abs((t.fadeAt ?? 0) - (4 + KeystrokeTracker.visibleS)) < 1e-9)
        // ⌘ released before ⇧ from a ⇧⌘ pill: it lingers as ⇧⌘, never as ⇧.
        var u = KeystrokeTracker()
        u.modifiersChanged(shiftCmd, at: 0)
        let shown = u.tick(at: delay)
        #expect(shown == .show && u.pill?.modifiers == shiftCmd)
        #expect(KeystrokeNames.pillText(u.pill!, windows: false) == "⇧⌘")
        u.modifiersChanged([.shift], at: 1)
        #expect(u.pill?.modifiers == shiftCmd && u.fadeAt == 1 + KeystrokeTracker.modifiersLingerS)
    }

    /// ⇧⌘4 (a macOS screenshot): ⇧⌘ shows while held, then ⇧⌘4 when the key event comes. TwinTake
    /// does not drop it (only its own hotkeys are reserved).
    @Test func screenshotShortcutsShow() {
        for code in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            let digit = String(code == kVK_ANSI_3 ? 3 : code == kVK_ANSI_4 ? 4 : 5)
            let shot = combo(code, shiftCmd, digit, reserved: [.startStop, .flag])
            #expect(shot == KeyCombo(modifiers: shiftCmd, key: .character(digit)))
            var t = KeystrokeTracker(hiddenModifierSets: [hotKeyModifiers])
            t.modifiersChanged(shiftCmd, at: 0)
            _ = t.tick(at: delay)
            if let shot { t.press(shot, isRepeat: false, at: 0.5) }
            #expect(t.pill.map { KeystrokeNames.pillText($0, windows: false) } == "⇧⌘" + digit)
        }
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
        #expect(rect.height == 102)  // 3 x 34 pt.
    }

    /// Luke: "can we make text also slightly bigger". 34 pt in the laptop frame (was 28).
    @Test func sizeFollowsTheFrame() {
        #expect(KeystrokePlacement.fontSize(frameHeight: 846) == 34)
        #expect(KeystrokePlacement.fontSize(frameHeight: 1080) == 43)  // A whole 4K display at 1920x1080 pt.
        #expect(KeystrokePlacement.fontSize(frameHeight: 200) == 22)
        #expect(KeystrokePlacement.fontSize(frameHeight: 5000) == 52)
        #expect(KeystrokePlacement.cornerRadius(fontSize: 34) == 15)
        #expect(KeystrokePlacement.cornerRadius(fontSize: 28) == 12)
        #expect(KeystrokePlacement.padding(fontSize: 34) == CGSize(width: 20, height: 10))
    }

    /// The pill holds the whole text, rounded up, plus its padding; never narrower than tall.
    @Test func pillSizeHoldsTheWholeText() {
        let size = KeystrokePlacement.pillSize(textSize: CGSize(width: 72.2, height: 40.6), fontSize: 34)
        #expect(size == CGSize(width: 73 + 40, height: 41 + 20))
        let narrow = KeystrokePlacement.pillSize(textSize: CGSize(width: 12, height: 40.6), fontSize: 34)
        #expect(narrow == CGSize(width: 61, height: 61))
    }

    /// A pill that fits keeps the frame's type size; one too wide for its window gets smaller type
    /// (the largest whole size that fits), never fewer characters.
    @Test func aPillTooWideShrinksItsType() {
        // A stand-in font: 0.6 pt wide per point of type per character, 1.2 lines.
        func measure(_ characters: Int) -> (CGFloat) -> CGSize {
            { CGSize(width: 0.6 * $0 * CGFloat(characters), height: 1.2 * $0) }
        }
        let room = CGSize(width: 1504, height: 102)
        let fits = KeystrokePlacement.fittedPill(fontSize: 34, in: room, measure: measure(10))
        #expect(fits.fontSize == 34 && fits.size == KeystrokePlacement.pillSize(textSize: measure(10)(34), fontSize: 34))
        let small = CGSize(width: 300, height: 66)
        let shrunk = KeystrokePlacement.fittedPill(fontSize: 22, in: small, measure: measure(30))
        #expect(shrunk.fontSize < 22)
        #expect(shrunk.size.width <= small.width && shrunk.size.height <= small.height)
        let oneUp = KeystrokePlacement.pillSize(textSize: measure(30)(shrunk.fontSize + 1), fontSize: shrunk.fontSize + 1)
        #expect(oneUp.width > small.width || oneUp.height > small.height)  // The largest size that fits.
        // No room at all: the smallest type, and no endless loop.
        let none = KeystrokePlacement.fittedPill(fontSize: 22, in: CGSize(width: 10, height: 10), measure: measure(30))
        #expect(none.fontSize == KeystrokePlacement.minimumFittedFontSize)
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

/// The pill laid out and drawn offscreen (no window on screen, no permission): Luke's take
/// showed "⇧…P", "R…urn", "Del…e ×2" and "…" for ⇧⌘. Every label now draws whole.
@MainActor @Suite struct KeystrokePillTests {
    static let labels = ["⇧⌘P", "⇧⌘", "⌃⌥⇧⌘4", "⇧⌘4", "⌘⏎ ×12", "⏎ ×4", "⌫ ×2", "⇧⇥ ×3", "Ctrl+Shift+Backspace ×3",
                         "Ctrl+Alt+Shift+Page Down ×12", "⌘ Space", "W", "⌥ F4"]
    /// The laptop frame, a whole 4K display (1920x1080 pt), a small frame and the largest type.
    static let frames = [CGRect(x: 4, y: 136, width: 1504, height: 846), CGRect(x: 0, y: 0, width: 1920, height: 1080),
                         CGRect(x: 0, y: 0, width: 800, height: 450), CGRect(x: 0, y: 0, width: 3840, height: 2160)]

    /// A pill laid out as the HUD does: in a window strip of `windowRect`'s size.
    private func pill(_ text: String, frame: CGRect) -> (KeystrokePillView, CGRect) {
        let window = KeystrokePlacement.windowRect(frameGlobal: frame)
        let bounds = CGRect(origin: .zero, size: window.size)
        let pill = KeystrokePillView(frame: .zero)
        pill.fontSize = KeystrokePlacement.fontSize(frameHeight: frame.height)
        pill.text = text
        pill.layoutPill(in: bounds)
        return (pill, bounds)
    }

    @Test func everyLabelGetsItsWholeWidth() {
        for frame in Self.frames {
            let fontSize = KeystrokePlacement.fontSize(frameHeight: frame.height)
            for text in Self.labels {
                let (pill, bounds) = pill(text, frame: frame)
                let needed = KeystrokePillView.textSize(text, fontSize: fontSize)
                let what = "\(text) at \(fontSize) pt"
                #expect(pill.drawnFontSize == fontSize, "\(what): the type stays")
                #expect(pill.textRect.width >= needed.width && pill.textRect.height >= needed.height, "\(what)")
                let pad = KeystrokePlacement.padding(fontSize: fontSize)
                #expect(pill.textRect.minX >= pad.width - 0.5 && pill.textRect.maxX <= pill.bounds.width - pad.width + 0.5,
                        "\(what): \(pill.textRect) in \(pill.bounds)")
                #expect(pill.textRect.minY >= 0 && pill.textRect.maxY <= pill.bounds.height, "\(what)")
                #expect(bounds.contains(pill.frame), "\(what): \(pill.frame) in \(bounds)")
                #expect(abs(pill.frame.midX - bounds.midX) <= 0.5 && abs(pill.frame.midY - bounds.midY) <= 0.5, "\(what)")
            }
        }
    }

    /// The pill follows its text as it changes in place: held modifiers, the combo, the count.
    @Test func thePillResizesWithItsText() {
        let frame = Self.frames[0]
        let (pill, bounds) = pill("⇧⌘", frame: frame)
        var widths: [CGFloat] = [pill.frame.width]
        for text in ["⇧⌘P", "⇧⌘P ×2", "⇧⌘P ×12", "⌘"] {
            pill.text = text
            pill.layoutPill(in: bounds)
            #expect(pill.textRect.width >= KeystrokePillView.textSize(text, fontSize: 34).width, "\(text)")
            #expect(abs(pill.frame.midX - bounds.midX) <= 0.5, "\(text)")
            widths.append(pill.frame.width)
        }
        #expect(widths[0] < widths[1] && widths[1] < widths[2] && widths[2] < widths[3] && widths[4] < widths[1])
    }

    /// Drawn offscreen, the pill shows exactly the ink of its whole text: the same width as the
    /// text drawn alone with no limit (a cut text with "…" is narrower), inside the padding, and
    /// centered up and down.
    @Test func thePillDrawsTheWholeText() throws {
        for text in ["⇧⌘P", "⇧⌘", "⏎ ×4", "⌫ ×2", "⌘⇥", "⌃⌥⇧⌘4", "Ctrl+Shift+Backspace ×3"] {
            let (pill, _) = pill(text, frame: Self.frames[0])
            let drawn = try #require(Self.inkBounds(Self.render(pill)), "\(text)")
            let alone = try #require(Self.inkBounds(Self.renderAlone(text, fontSize: pill.drawnFontSize)), "\(text)")
            #expect(abs(drawn.width - alone.width) <= 1, "\(text): \(drawn.width) px drawn, \(alone.width) px whole")
            let pad = KeystrokePlacement.padding(fontSize: pill.drawnFontSize).width * Self.scale
            let size = CGSize(width: pill.bounds.width * Self.scale, height: pill.bounds.height * Self.scale)
            #expect(drawn.minX >= pad * 0.75 && drawn.maxX <= size.width - pad * 0.75, "\(text): \(drawn) in \(size)")
            #expect(drawn.minY > 0 && drawn.maxY < size.height, "\(text): \(drawn) in \(size)")
            #expect(abs(drawn.midY - size.height / 2) <= 0.2 * pill.drawnFontSize * Self.scale, "\(text): \(drawn) in \(size)")
        }
    }

    /// In a frame too small for a long label, the type shrinks and the text stays whole.
    @Test func aTinyFrameShrinksTheTypeNotTheText() {
        let tiny = CGRect(x: 0, y: 0, width: 320, height: 180)
        let text = "Ctrl+Alt+Shift+Page Down ×12"
        let (pill, bounds) = pill(text, frame: tiny)
        #expect(pill.drawnFontSize < KeystrokePlacement.fontSize(frameHeight: tiny.height))
        #expect(pill.textRect.width >= KeystrokePillView.textSize(text, fontSize: pill.drawnFontSize).width)
        #expect(bounds.contains(pill.frame) && pill.textRect.maxX <= pill.bounds.width)
    }

    /// Every key name the Mac style can show draws in the system font's own design: a glyph of
    /// the font itself (no fallback to Lucida Grande or another font), or a symbol the pill draws
    /// as an SF Symbol. Before, ↩ ⇥ ⌤ ⇞ ⇟ fell back to Lucida Grande, and ⌤ drew at half height.
    @Test func everyMacKeyNameDrawsInTheSystemFont() throws {
        let font = NSFont.systemFont(ofSize: 34, weight: .semibold) as CTFont
        let fontName = CTFontCopyPostScriptName(font) as String
        let keys: [KeystrokeKey] = [.returnKey, .enter, .tab, .space, .escape, .delete, .forwardDelete, .left, .right,
                                    .up, .down, .pageUp, .pageDown, .home, .end, .function(20), .character("P")]
        let modifiers: HotKey.Modifiers = [.control, .option, .shift, .command]
        var texts = keys.map { KeystrokeNames.macName($0) }
        texts.append(KeystrokeNames.pillText(.init(combo: KeyCombo(modifiers: modifiers, key: .returnKey), modifiers: modifiers,
                                                   count: 12), windows: false))
        for text in texts {
            for character in text {
                if let name = KeystrokePillView.symbolImages[character] {
                    #expect(KeystrokePillView.symbolImage(name, fontSize: 34) != nil, "\(character): SF Symbol \(name)")
                    continue
                }
                let string = String(character) as NSString
                let used = CTFontCreateForString(font, string as CFString, CFRange(location: 0, length: string.length))
                let usedName = CTFontCopyPostScriptName(used) as String
                #expect(usedName == fontName, "\(character) in \(text)")
            }
        }
    }

    /// The key symbols sit on the baseline at the font's size, like ⌘: ⏎ as tall as ⌘, and ⇥ (an
    /// SF Symbol) with the same ink top and bottom as the font's →.
    @Test func keySymbolsMatchTheModifiers() throws {
        func ink(_ text: String) throws -> CGRect {
            try #require(Self.inkBounds(Self.renderAlone(text, fontSize: 34)), "\(text)")
        }
        let command = try ink("⌘"), arrow = try ink("→")
        let tab = try ink("⇥"), returnKey = try ink("⏎"), enter = try ink("⌅")
        #expect(abs(tab.minY - arrow.minY) <= 1 && abs(tab.maxY - arrow.maxY) <= 1, "⇥ \(tab), → \(arrow)")
        #expect(abs(returnKey.maxY - command.maxY) <= 1.5 && abs(returnKey.height - command.height) <= 2,
                "⏎ \(returnKey), ⌘ \(command)")
        // ⌅ is a caret under a bar, like ⌃: its top at the cap height, like ⌘'s.
        #expect(abs(enter.minY - command.minY) <= 1.5 && enter.height >= 0.6 * command.height, "⌅ \(enter), ⌘ \(command)")
        // ⇥ joins ⌘ in one pill at the same baseline.
        let both = try ink("⌘⇥")
        #expect(abs(both.maxY - command.maxY) <= 1.5 && both.width > command.width + tab.width, "⌘⇥ \(both)")
    }

    static let scale: CGFloat = 2

    /// `view` drawn at 2x with `cacheDisplay` (reads no screen pixel).
    static func render(_ view: NSView) -> NSBitmapImageRep {
        let rep = bitmap(view.bounds.size)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// `text` drawn alone at a point as the pill draws it, white on clear, with room to spare.
    static func renderAlone(_ text: String, fontSize: CGFloat) -> NSBitmapImageRep {
        let string = KeystrokePillView.drawnString(text, fontSize: fontSize)
        let size = string.size()
        let rep = bitmap(CGSize(width: size.width + 200, height: size.height + 40))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        string.draw(at: NSPoint(x: 100, y: 20))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func bitmap(_ size: CGSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                   pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    /// The pixels of the white text (bright and mostly opaque; the pill's fill is #1E1E1E), in
    /// pixel rows from the top.
    static func inkBounds(_ rep: NSBitmapImageRep) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                var p = [Int](repeating: 0, count: 4)
                rep.getPixel(&p, atX: x, y: y)
                guard p[0] > 128, p[3] > 128 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
