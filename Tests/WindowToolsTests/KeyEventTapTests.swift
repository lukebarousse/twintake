import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import WindowTools

// The event tap's pure parts: Quartz flags and events to the same `KeyEventInfo` the AppKit
// monitors give, the dedupe between the two sources, and the mask check. Nothing here creates a
// tap or a monitor.

/// Every set of ⌃⌥⇧⌘, as Quartz flags and as AppKit flags.
private let modifierSets: [(CGEventFlags, NSEvent.ModifierFlags, HotKey.Modifiers)] = {
    let keys: [(CGEventFlags, NSEvent.ModifierFlags, HotKey.Modifiers)] = [
        (.maskControl, .control, .control), (.maskAlternate, .option, .option),
        (.maskShift, .shift, .shift), (.maskCommand, .command, .command),
    ]
    return (0..<16).map { bits in
        var cg: CGEventFlags = []
        var ns: NSEvent.ModifierFlags = []
        var m: HotKey.Modifiers = []
        for (i, key) in keys.enumerated() where bits & (1 << i) != 0 {
            cg.insert(key.0)
            ns.insert(key.1)
            m.insert(key.2)
        }
        return (cg, ns, m)
    }
}()

/// The filter's combo for an event, with a fixed layout character.
private func combo(_ info: KeyEventInfo, optionTypes: Bool = true, reserved: Set<HotKey> = []) -> KeyCombo? {
    guard case let .keyDown(keyCode, _) = info.kind else { return nil }
    return KeystrokeFilter.combo(keyCode: keyCode, modifiers: info.modifiers, reserved: reserved, optionTypes: optionTypes,
                                 character: info.character)
}

@Suite struct KeyEventTapConversionTests {
    /// Quartz flags give the same four modifiers as AppKit's flags (the monitors' source).
    @Test func flagsMatchAppKit() {
        for (cg, ns, m) in modifierSets {
            #expect(HotKey.Modifiers(cgFlags: cg) == m)
            #expect(HotKey.Modifiers(ns) == m)
            // Their raw bits are the same device-independent masks.
            #expect(cg.rawValue == UInt64(ns.rawValue))
        }
    }

    /// Caps lock, fn, the keypad flag and the left/right key bits never count as modifiers.
    @Test func otherFlagsAreDropped() {
        let noise: CGEventFlags = [.maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskHelp, .maskNonCoalesced]
        #expect(HotKey.Modifiers(cgFlags: noise).isEmpty)
        // NX_DEVICELCMDKEYMASK (0x08) and NX_DEVICELSHIFTKEYMASK (0x02) ride along with ⌘ and ⇧.
        let leftCmdShift = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | 0x0A)
        #expect(HotKey.Modifiers(cgFlags: leftCmdShift.union(noise)) == [.shift, .command])
    }

    /// A key down from the tap is the same press the monitors report: key code, repeat, modifiers,
    /// and so the same combo and label (⇧⌘4 with CleanShot X running is the point of the tap).
    @Test func keyDownIsTheSamePress() throws {
        let info = try #require(KeyEventInfo(tapType: .keyDown, keyCode: UInt16(kVK_ANSI_4),
                                             flags: [.maskShift, .maskCommand], isRepeat: false, timestamp: 12.5,
                                             character: { "4" }))
        #expect(info.kind == .keyDown(keyCode: UInt16(kVK_ANSI_4), isRepeat: false))
        #expect(info.modifiers == [.shift, .command])
        #expect(info.timestamp == 12.5)
        let fromTap = try #require(combo(info))
        let fromMonitor = combo(KeyEventInfo(kind: .keyDown(keyCode: UInt16(kVK_ANSI_4), isRepeat: false),
                                             modifiers: HotKey.Modifiers([.shift, .command] as NSEvent.ModifierFlags),
                                             character: { "4" }))
        #expect(fromTap == fromMonitor)
        #expect(KeystrokeNames.label(fromTap, windows: false) == "⇧⌘4")
        #expect(KeystrokeNames.label(fromTap, windows: true) == "Ctrl+Shift+4")
        let repeatInfo = try #require(KeyEventInfo(tapType: .keyDown, keyCode: UInt16(kVK_RightArrow), flags: [],
                                                   isRepeat: true))
        #expect(repeatInfo.kind == .keyDown(keyCode: UInt16(kVK_RightArrow), isRepeat: true))
    }

    /// Every modifier set and a spread of keys: the tap's event gives the combo the monitors' event
    /// gives, typing stays hidden for both, and the layout is read only for a key that shows.
    @Test func everyComboMatchesTheMonitors() {
        let keys: [(Int, String?)] = [(kVK_ANSI_A, "a"), (kVK_ANSI_Z, "z"), (kVK_ANSI_7, "7"), (kVK_ANSI_Minus, "-"),
                                      (kVK_Space, " "), (kVK_Return, "\r"), (kVK_Tab, "\t"), (kVK_Escape, "\u{1b}"),
                                      (kVK_LeftArrow, "\u{F702}"), (kVK_F5, "\u{F708}")]
        for (cg, ns, _) in modifierSets {
            for (code, char) in keys {
                for optionTypes in [true, false] {
                    var tapReads = 0
                    var monitorReads = 0
                    let tap = KeyEventInfo(tapType: .keyDown, keyCode: UInt16(code), flags: cg, isRepeat: false,
                                           character: { tapReads += 1; return char })
                    let monitor = KeyEventInfo(kind: .keyDown(keyCode: UInt16(code), isRepeat: false),
                                               modifiers: HotKey.Modifiers(ns), character: { monitorReads += 1; return char })
                    let a = tap.flatMap { combo($0, optionTypes: optionTypes) }
                    let b = combo(monitor, optionTypes: optionTypes)
                    #expect(a == b, "key \(code) flags \(cg.rawValue)")
                    #expect(tapReads == monitorReads)
                }
            }
        }
        // Plain typing from the tap: no combo, and the layout is never read.
        var reads = 0
        let typed = KeyEventInfo(tapType: .keyDown, keyCode: UInt16(kVK_ANSI_A), flags: [.maskShift], isRepeat: false,
                                 character: { reads += 1; return "a" })
        #expect(typed.flatMap { combo($0) } == nil)
        #expect(reads == 0)
    }

    /// A modifier change from the tap is a modifier change, with no character.
    @Test func flagsChangedIsAModifierChange() throws {
        let info = try #require(KeyEventInfo(tapType: .flagsChanged, keyCode: UInt16(kVK_Command),
                                             flags: [.maskShift, .maskCommand], isRepeat: false))
        #expect(info.kind == .modifiersChanged)
        #expect(info.modifiers == [.shift, .command])
        #expect(info.character() == nil)
    }

    /// Key up and the tap's "disabled" notices are not key events.
    @Test func otherTypesAreDropped() {
        for type in [CGEventType.keyUp, .tapDisabledByTimeout, .tapDisabledByUserInput, .leftMouseDown, .null] {
            #expect(KeyEventInfo(tapType: type, keyCode: 0, flags: [.maskCommand], isRepeat: false) == nil)
        }
    }

    /// TwinTake's own hotkeys seen by the tap (it sees them, the monitors mostly do not): the filter
    /// drops them with the reserved table, exactly as for the monitors.
    @Test func ownHotKeysFromTheTapAreReserved() throws {
        let reserved = Set(HotKeyAction.allCases.map(\.defaultHotKey))
        for hotKey in reserved {
            let info = try #require(KeyEventInfo(tapType: .keyDown, keyCode: UInt16(hotKey.keyCode),
                                                 flags: [.maskControl, .maskAlternate, .maskCommand], isRepeat: false,
                                                 character: { "x" }))
            #expect(info.modifiers == hotKey.modifiers)
            #expect(reserved.contains(HotKey(keyCode: UInt32(UInt16(hotKey.keyCode)), modifiers: info.modifiers)))
            #expect(combo(info, reserved: reserved) == nil)
        }
        // ⌃⌥⇧⌘B is not a TwinTake hotkey: it shows.
        let extra = try #require(KeyEventInfo(tapType: .keyDown, keyCode: UInt16(kVK_ANSI_B),
                                              flags: [.maskControl, .maskAlternate, .maskShift, .maskCommand],
                                              isRepeat: false, character: { "b" }))
        #expect(combo(extra, reserved: reserved) == KeyCombo(modifiers: [.control, .option, .shift, .command], key: .character("B")))
    }
}

/// The deduper by reference, so `#expect` can call its mutating `admit`.
private final class Deduper {
    var d = KeyEventDeduper()
    func admit(_ source: KeySource, keyCode: UInt16, isRepeat: Bool, modifiers: HotKey.Modifiers, at t: Double) -> Bool {
        d.admit(source, keyCode: keyCode, isRepeat: isRepeat, modifiers: modifiers, at: t)
    }
}

@Suite struct KeyEventDeduperTests {
    let shiftCmd: HotKey.Modifiers = [.shift, .command]

    /// One press reported by both sources (same event time, or within the window) counts once,
    /// whichever arrives first.
    @Test func samePressFromBothSourcesCountsOnce() {
        let d = Deduper()
        #expect(d.admit(.tap, keyCode: 6, isRepeat: false, modifiers: [.command], at: 100.000))
        #expect(!d.admit(.monitors, keyCode: 6, isRepeat: false, modifiers: [.command], at: 100.000))
        #expect(d.admit(.monitors, keyCode: 21, isRepeat: false, modifiers: shiftCmd, at: 101.000))
        #expect(!d.admit(.tap, keyCode: 21, isRepeat: false, modifiers: shiftCmd, at: 101.020))
    }

    /// ⌘Z pressed three times counts three times from one source, also when quick.
    @Test func repeatsFromOneSourceAllCount() {
        let d = Deduper()
        for i in 0..<3 { #expect(d.admit(.tap, keyCode: 6, isRepeat: false, modifiers: [.command], at: 10 + Double(i) * 0.03)) }
        for i in 0..<3 { #expect(d.admit(.monitors, keyCode: 6, isRepeat: false, modifiers: [.command], at: 20 + Double(i) * 0.03)) }
    }

    /// ⌘Z ×3 with both sources reporting each press: three, not six.
    @Test func threePressesFromBothSourcesCountThree() {
        let d = Deduper()
        var counted = 0
        for i in 0..<3 {
            let t = 50 + Double(i) * 0.15
            if d.admit(.tap, keyCode: 6, isRepeat: false, modifiers: [.command], at: t) { counted += 1 }
            if d.admit(.monitors, keyCode: 6, isRepeat: false, modifiers: [.command], at: t) { counted += 1 }
        }
        #expect(counted == 3)
    }

    /// A different key, other modifiers, an auto-repeat, or a time outside the window is another press.
    @Test func differentPressesAllCount() {
        let d = Deduper()
        #expect(d.admit(.tap, keyCode: 6, isRepeat: false, modifiers: [.command], at: 5))
        #expect(d.admit(.monitors, keyCode: 7, isRepeat: false, modifiers: [.command], at: 5))
        #expect(d.admit(.monitors, keyCode: 6, isRepeat: false, modifiers: shiftCmd, at: 5))
        #expect(d.admit(.monitors, keyCode: 6, isRepeat: true, modifiers: [.command], at: 5))
        #expect(d.admit(.monitors, keyCode: 6, isRepeat: false, modifiers: [.command], at: 5 + KeyEventDeduper.windowS + 0.01))
    }

    /// Old presses are forgotten, so memory stays small over a long session.
    @Test func memoryStaysSmall() {
        let d = Deduper()
        for i in 0..<1000 { #expect(d.admit(.tap, keyCode: UInt16(i % 50), isRepeat: false, modifiers: [.command], at: Double(i) * 0.001)) }
        // The last press is still matched.
        #expect(!d.admit(.monitors, keyCode: UInt16(999 % 50), isRepeat: false, modifiers: [.command], at: 0.999))
    }
}

/// The proof by reference, so `#expect` can call its mutating members.
private final class Proof {
    var p: TapProof
    init(startedAt: Double = 0) { p = TapProof(startedAt: startedAt) }
    /// A tap key press (or modifier change), outside secure keyboard entry unless `secure`.
    func tap(keyDown: Bool = true, secure: Bool = false) -> Bool { p.tapEvent(keyDown: keyDown, secureInput: secure) }
    /// A monitor key press (or modifier change) at event time `t`.
    func monitor(keyDown: Bool = true, secure: Bool = false, at t: Double = 100) -> Bool {
        p.monitorEvent(keyDown: keyDown, secureInput: secure, at: t)
    }
}

@Suite struct TapProofTests {
    /// The tap's first key press proves it, once.
    @Test func theFirstTapKeyPressProvesIt() {
        let proof = Proof()
        #expect(proof.p.state == .waiting)
        #expect(proof.tap())
        #expect(proof.p.state == .proven)
        #expect(!proof.tap())
        // Monitor key presses after the proof change nothing.
        for _ in 0..<10 { #expect(!proof.monitor()) }
        #expect(proof.p.state == .proven)
    }

    /// A tap that gets modifier changes but no key presses (it can need a relaunch) is not proven,
    /// however many come, and the monitors' key presses still find it deaf.
    @Test func modifierChangesNeverProveTheTap() {
        let proof = Proof()
        for _ in 0..<50 { #expect(!proof.tap(keyDown: false)) }
        #expect(proof.p.state == .waiting)
        for _ in 1..<TapProof.deafAfterMonitorKeyDowns {
            #expect(!proof.tap(keyDown: false))
            #expect(!proof.monitor())
        }
        #expect(proof.monitor())
        #expect(proof.p.state == .deaf)
    }

    /// The monitors' modifier changes never make a tap deaf: ⌘ and ⇧ held and let go before the
    /// first key press are four modifier changes, and the tap's key press still proves it.
    @Test func monitorModifierChangesNeverMakeItDeaf() {
        let proof = Proof()
        for _ in 0..<20 { #expect(!proof.monitor(keyDown: false)) }
        #expect(proof.p.state == .waiting)
        #expect(proof.tap())
        #expect(proof.p.state == .proven)
    }

    /// During secure keyboard entry nothing counts, for either side.
    @Test func secureInputCountsForNeither() {
        let proof = Proof()
        #expect(!proof.tap(secure: true))
        for _ in 0..<20 { #expect(!proof.monitor(secure: true)) }
        #expect(proof.p.state == .waiting)
        #expect(proof.tap())
        #expect(proof.p.state == .proven)
    }

    /// Monitor key presses from before the tap existed (already on their way) do not count.
    @Test func monitorKeyPressesFromBeforeTheTapDoNotCount() {
        let proof = Proof(startedAt: 500)
        for i in 0..<20 { #expect(!proof.monitor(at: 400 + Double(i))) }
        #expect(!proof.monitor(at: 499.999))
        #expect(proof.p.state == .waiting)
        for _ in 1..<TapProof.deafAfterMonitorKeyDowns { #expect(!proof.monitor(at: 500)) }
        #expect(proof.monitor(at: 501))
        #expect(proof.p.state == .deaf)
    }

    /// The monitors' key presses may come first (both hand off to the main thread): a few are allowed.
    @Test func aFewMonitorKeyPressesFirstAreFine() {
        let proof = Proof()
        for _ in 1..<TapProof.deafAfterMonitorKeyDowns { #expect(!proof.monitor()) }
        #expect(proof.p.state == .waiting)
        #expect(proof.tap())
        #expect(proof.p.state == .proven)
    }

    /// Monitor key presses and no tap key press: the tap gets no keys (a grant that needs a relaunch).
    @Test func noTapKeyPressMeansDeaf() {
        let proof = Proof()
        for _ in 1..<TapProof.deafAfterMonitorKeyDowns { #expect(!proof.monitor()) }
        #expect(proof.monitor())
        #expect(proof.p.state == .deaf)
        #expect(!proof.monitor())
        #expect(!proof.tap())
        #expect(proof.p.state == .deaf)
    }
}

@Suite struct KeyTapMaskTests {
    @Test func wantsKeyDownAndModifierChangesOnly() {
        let keyDown: CGEventMask = 1 << CGEventMask(CGEventType.keyDown.rawValue)
        let flags: CGEventMask = 1 << CGEventMask(CGEventType.flagsChanged.rawValue)
        let keyUp: CGEventMask = 1 << CGEventMask(CGEventType.keyUp.rawValue)
        #expect(KeyTapMask.wanted == keyDown | flags)
        #expect(KeyTapMask.wanted & keyUp == 0)
    }

    /// macOS clears the bits a tap may not see: a tap left with modifier changes only is no use.
    @Test func aTapWithoutKeyDownIsRefused() {
        let flags: CGEventMask = 1 << CGEventMask(CGEventType.flagsChanged.rawValue)
        #expect(KeyTapMask.seesKeys([KeyTapMask.wanted]))
        #expect(!KeyTapMask.seesKeys([flags]))
        #expect(!KeyTapMask.seesKeys([0]))
        #expect(KeyTapMask.seesKeys([flags, KeyTapMask.wanted]))
        // Not listed: macOS did not say, so the tap is trusted (TapProof still decides).
        #expect(KeyTapMask.seesKeys([]))
    }

    /// Only the tap this process just created is checked: an older TwinTake tap still listed, another
    /// app's tap and a tap at another level are not taken for it.
    @Test func onlyTheNewTapIsChecked() {
        let flags: CGEventMask = 1 << CGEventMask(CGEventType.flagsChanged.rawValue)
        let me: pid_t = 4242
        let old = KeyTapMask.Listed(id: 7, pid: me, isSessionTap: true, mask: KeyTapMask.wanted)
        let other = KeyTapMask.Listed(id: 8, pid: 99, isSessionTap: true, mask: KeyTapMask.wanted)
        let new = KeyTapMask.Listed(id: 9, pid: me, isSessionTap: true, mask: flags)
        let hid = KeyTapMask.Listed(id: 10, pid: me, isSessionTap: false, mask: KeyTapMask.wanted)
        let masks = KeyTapMask.newTapMasks(before: [old, other], after: [old, other, new, hid], pid: me)
        #expect(masks == [flags])
        // So a new tap left with modifier changes only is refused, even next to an older full one.
        #expect(!KeyTapMask.seesKeys(masks))
        let full = KeyTapMask.Listed(id: 11, pid: me, isSessionTap: true, mask: KeyTapMask.wanted)
        #expect(KeyTapMask.seesKeys(KeyTapMask.newTapMasks(before: [old], after: [old, full], pid: me)))
        // Nothing new listed: trusted.
        #expect(KeyTapMask.newTapMasks(before: [old], after: [old], pid: me).isEmpty)
    }
}

/// `KeyMonitor` without a source: nothing here installs a monitor or a tap.
@MainActor
@Suite struct KeyMonitorStateTests {
    /// A deaf tap found in one show period does not carry over to the next start (it would block
    /// the tap for 3 s and show a false relaunch note).
    @Test func stopForgetsADeafTap() {
        let monitor = KeyMonitor()
        monitor.tapWasDeaf = true
        monitor.stop()
        #expect(!monitor.takeTapDeaf())
        #expect(!monitor.isRunning)
        // Read once: a second read is false.
        monitor.tapWasDeaf = true
        #expect(monitor.takeTapDeaf())
        #expect(!monitor.takeTapDeaf())
    }
}

/// The tap's C callback runs on the tap's own thread, never on main. A callback that inherited the
/// main actor trapped there on the first key (seen on device, it ended a take), so this calls it
/// from a plain thread, as macOS does.
@Suite struct KeyTapCallbackTests {
    private final class Got: @unchecked Sendable {
        let lock = NSLock()
        private var list: [UInt16] = []
        func append(_ code: UInt16) { lock.withLock { list.append(code) } }
        var codes: [UInt16] { lock.withLock { list } }
    }

    @Test func runsOffTheMainThread() async {
        let got = Got()
        let box = TapBox(deliver: { event in got.append(event.keyCode) })
        let ran = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let thread = Thread {
                guard !Thread.isMainThread,
                      let proxy = OpaquePointer(bitPattern: 1),
                      let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: true)
                else { return done.resume(returning: false) }
                event.flags = .maskCommand
                let info = Unmanaged.passUnretained(box).toOpaque()
                _ = keyTapCallback(proxy, .keyDown, event, info)
                _ = keyTapCallback(proxy, .flagsChanged, event, info)
                _ = keyTapCallback(proxy, .keyUp, event, info)
                done.resume(returning: true)
            }
            thread.start()
        }
        #expect(ran)
        #expect(got.codes == [UInt16(kVK_ANSI_Z), UInt16(kVK_ANSI_Z)])
    }

    /// The tap gets the named file-scope callback, not a closure written inside the main-actor type.
    @Test func tapCreateUsesTheFileScopeCallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/WindowTools/KeyEventTap.swift"),
                                encoding: .utf8)
        let call = try #require(source.range(of: "CGEvent.tapCreate("))
        let rest = source[call.upperBound...].prefix(400)
        #expect(rest.contains("callback: keyTapCallback,"))
        #expect(!rest.contains("callback: {"))
    }
}
