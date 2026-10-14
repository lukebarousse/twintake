import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import WindowTools

@Suite struct HotKeyTests {
    @Test func defaultDisplayStrings() {
        #expect(HotKey.startStop.displayString == "⌃⌥⌘R")
        #expect(HotKey.snapWindow.displayString == "⌃⌥⌘F")
        #expect(HotKey.flag.displayString == "⌃⌥⌘B")
        #expect(HotKey.cameraWindow.displayString == "⌃⌥⌘C")
        #expect(HotKeyAction.startStop.defaultHotKey == .startStop)
        #expect(HotKeyAction.flag.defaultHotKey == .flag)
        #expect(HotKeyAction.cameraWindow.defaultHotKey == .cameraWindow)
    }

    /// Luke's change: ⌃⌥⌘B is Flag ("something in the last few minutes was wrong"); the Good and
    /// Retake markers and ⌃⌥⌘G are gone.
    @Test func theHotKeyTableHasFlagAndNoGoodTakeKey() {
        #expect(HotKeyAction.allCases == [.startStop, .snapWindow, .flag, .cameraWindow, .replay])
        #expect(HotKeyAction.allCases.map(\.defaultHotKey.displayString) == ["⌃⌥⌘R", "⌃⌥⌘F", "⌃⌥⌘B", "⌃⌥⌘C", "⌃⌥⌘P"])
        let goodTake = HotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: [.control, .option, .command])
        #expect(!HotKeyAction.allCases.map(\.defaultHotKey).contains(goodTake))
        #expect(HotKeyAction.flag.rawValue == "flag")
        #expect(HotKeyAction.flag.title.contains("Flag"))
        #expect(!HotKeyAction.allCases.contains { $0.title.contains("good") || $0.title.contains("retake") })
    }

    /// Replay (⌃⌥⌘P) takes none of TwinTake's other keys and none of CleanShot X's ⇧⌘2–6 and ⇧⌘8.
    @Test func theReplayKeyCollidesWithNothing() {
        #expect(HotKey.replay.displayString == "⌃⌥⌘P")
        #expect(HotKeyAction.replay.defaultHotKey == .replay)
        #expect(HotKeyAction.replay.id == 6)
        #expect(HotKeyAction.replay.title.contains("replay"))
        #expect(HotKey.replay.knownConflict == nil && HotKey.replay.isAllowedByMacOS)
        let others: [HotKey] = [.startStop, .snapWindow, .flag, .cameraWindow]
        #expect(!others.contains(.replay))
        let cleanShot = [kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_8]
            .map { HotKey(keyCode: UInt32($0), modifiers: [.shift, .command]) }
        #expect(!cleanShot.contains(.replay))
    }

    @Test func carbonModifierMask() {
        let m: HotKey.Modifiers = [.control, .option, .command]
        #expect(m.carbonFlags == UInt32(controlKey | optionKey | cmdKey))
        #expect(m.carbonFlags == 4096 + 2048 + 256)
        #expect(HotKey.Modifiers.shift.carbonFlags == 512)
        // Caps lock (alphaLock) and other bits are dropped.
        #expect(HotKey.Modifiers(carbonFlags: m.carbonFlags | UInt32(alphaLock)) == m)
    }

    @Test func appKitFlagConversion() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function]
        let m = HotKey.Modifiers(flags)
        #expect(m == [.command, .shift])
        #expect(m.eventFlags == [.command, .shift])
        let all: HotKey.Modifiers = [.control, .option, .shift, .command]
        #expect(HotKey.Modifiers(all.eventFlags) == all)
    }

    @Test func symbolsUseAppleOrder() {
        let m: HotKey.Modifiers = [.command, .shift, .option, .control]
        #expect(m.symbols == "⌃⌥⇧⌘")
        #expect(HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: [.shift, .command]).displayString == "⇧⌘4")
    }

    @Test func keyNames() {
        #expect(HotKey.keyName(for: UInt32(kVK_F13)) == "F13")
        #expect(HotKey.keyName(for: UInt32(kVK_Space)) == "Space")
        #expect(HotKey.keyName(for: UInt32(kVK_ANSI_Slash)) == "/")
        #expect(HotKey.keyName(for: 0xFF) == nil)
        #expect(HotKey(keyCode: 0xFF, modifiers: [.command]).displayString == "⌘Key 255")
    }

    @Test func defaultsAvoidCleanShotAndSystemShortcuts() {
        let defaults = HotKeyAction.allCases.map(\.defaultHotKey)
        for k in defaults {
            #expect(k.knownConflict == nil, "\(k) collides with \(k.knownConflict ?? "")")
            #expect(k.isAllowedByMacOS)
        }
        #expect(Set(defaults).count == defaults.count)
        #expect(Set(HotKeyAction.allCases.map(\.id)).count == HotKeyAction.allCases.count)
        for code in [kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_8] {
            #expect(HotKey(keyCode: UInt32(code), modifiers: [.shift, .command]).knownConflict == "CleanShot X")
        }
        #expect(HotKey(keyCode: UInt32(kVK_ANSI_7), modifiers: [.shift, .command]).knownConflict == nil)
    }

    @Test func macOSRejectsOptionOnlyShortcuts() {
        let r = UInt32(kVK_ANSI_R)
        #expect(!HotKey(keyCode: r, modifiers: [.option]).isAllowedByMacOS)
        #expect(!HotKey(keyCode: r, modifiers: [.option, .shift]).isAllowedByMacOS)
        #expect(HotKey(keyCode: r, modifiers: [.control, .option]).isAllowedByMacOS)
        #expect(HotKey(keyCode: UInt32(kVK_F13), modifiers: []).isAllowedByMacOS)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(HotKey.flag)
        #expect(try JSONDecoder().decode(HotKey.self, from: data) == .flag)
    }

    @Test func errorMessagesNameTheShortcut() {
        let e = HotKeyError.notAllowedByMacOS(HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: [.option]))
        #expect(e.errorDescription?.contains("⌥R") == true)
    }

    /// Registration needs a running app event loop, so only the refusal path runs here. It
    /// returns before any Carbon call.
    @MainActor @Test func registerRefusesOptionOnlyShortcut() {
        let keys = GlobalHotKeys()
        #expect(throws: HotKeyError.self) {
            try keys.register(id: 1, keyCode: UInt32(kVK_ANSI_R), modifiers: [.option]) {}
        }
        #expect(keys.registered.isEmpty)
    }
}
