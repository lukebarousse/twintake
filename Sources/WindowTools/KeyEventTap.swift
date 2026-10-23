import AppKit
import CoreGraphics
import Foundation

// The Input Monitoring key source: a listen-only Quartz event tap. It sees the keys of a shortcut
// another app owns as a global hotkey (CleanShot X's ⇧⌘4), which the AppKit global monitor never
// gets: macOS gives a hotkey's key to the app that registered it, and global monitors only get
// copies of the events routed to other apps. `KeyMonitor` runs this tap alone once it reported
// its first key press (`TapProof`), else the AppKit monitors, and feeds the same `KeyEventInfo` to
// the keystroke pipeline either way.

// MARK: - Pure conversion

extension HotKey.Modifiers {
    /// From Quartz event flags (an event tap's `CGEvent.flags`): the same four keys as from AppKit's
    /// flags. Caps lock, fn, the keypad flag and the left and right key bits are dropped.
    public init(cgFlags flags: CGEventFlags) {
        var m: HotKey.Modifiers = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        self = m
    }
}

extension KeyEventInfo {
    /// A key event the tap saw, as the AppKit monitors report it: the same key code, the same four
    /// modifiers and the same layout character, so names, symbols and Auto's Windows names come out
    /// the same. Nil for any other event type (key up, the tap's "disabled" notices).
    /// - Parameters:
    ///   - type: `.keyDown` or `.flagsChanged`.
    ///   - keyCode: `CGEventField.keyboardEventKeycode`.
    ///   - isRepeat: `CGEventField.keyboardEventAutorepeat` is not 0.
    ///   - timestamp: the event's time as AppKit gives it (`NSEvent.timestamp`), for `KeyEventDeduper`.
    ///   - character: the key's layout character, read only for a key that shows.
    public init?(tapType type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool,
                 timestamp: Double? = nil, character: @escaping () -> String? = { nil }) {
        let modifiers = HotKey.Modifiers(cgFlags: flags)
        switch type {
        case .keyDown:
            self.init(kind: .keyDown(keyCode: keyCode, isRepeat: isRepeat), modifiers: modifiers, timestamp: timestamp,
                      character: character)
        case .flagsChanged:
            self.init(kind: .modifiersChanged, modifiers: modifiers, timestamp: timestamp)
        default:
            return nil
        }
    }
}

/// Where a key event came from.
public enum KeySource: String, Sendable, Equatable {
    /// The AppKit global and local monitors (Accessibility).
    case monitors
    /// The listen-only event tap (Input Monitoring).
    case tap
}

/// A key press reported by both sources counts once. Only one source runs at a time, but events
/// already on their way to the main thread can arrive just after a switch. Both sources report a
/// press with the same event time (AppKit reads it from the same Quartz event), so a press from
/// the other source with the same key, modifiers and repeat flag within `windowS` is the same
/// press. Presses from one source are never dropped, so ⌘Z ⌘Z still counts twice.
public struct KeyEventDeduper: Sendable {
    /// Room for rounding between the two reports of one press (a person cannot press the same key
    /// twice in 50 ms).
    public static let windowS = 0.05
    /// Presses kept to compare with.
    public static let capacity = 16

    private struct Seen: Sendable {
        var source: KeySource
        var keyCode: UInt16
        var isRepeat: Bool
        var modifiers: HotKey.Modifiers
        var t: Double
    }

    private var seen: [Seen] = []

    public init() {}

    /// True when the press counts; false when the other source already reported it.
    /// - Parameter t: the event's time in seconds (`NSEvent.timestamp`).
    public mutating func admit(_ source: KeySource, keyCode: UInt16, isRepeat: Bool, modifiers: HotKey.Modifiers,
                               at t: Double) -> Bool {
        seen.removeAll { abs($0.t - t) > 1 }
        if let i = seen.firstIndex(where: {
            $0.source != source && $0.keyCode == keyCode && $0.isRepeat == isRepeat && $0.modifiers == modifiers
                && abs($0.t - t) <= Self.windowS
        }) {
            seen.remove(at: i)
            return false
        }
        seen.append(Seen(source: source, keyCode: keyCode, isRepeat: isRepeat, modifiers: modifiers, t: t))
        if seen.count > Self.capacity { seen.removeFirst(seen.count - Self.capacity) }
        return true
    }
}

/// Whether a new tap gets key presses. macOS can create a tap that gets no key presses until
/// TwinTake is relaunched (after a fresh Input Monitoring grant), and such a tap can still get
/// modifier changes. So only a key press proves the tap, and the AppKit monitors stay until one
/// comes. When the monitors report `deafAfterMonitorKeyDowns` key presses first, the tap gets
/// none, and it is removed: keystrokes never lose their source.
///
/// Only key presses outside secure keyboard entry count, for either side: modifier changes prove
/// nothing, and during secure keyboard entry the tap and the monitors may get different events.
public struct TapProof: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// No key press from the tap yet.
        case waiting
        /// The tap reported a key press: it alone runs.
        case proven
        /// The monitors reported key presses and the tap none: it gets no keys.
        case deaf
    }

    /// Monitor key presses with no tap key press before the tap counts as deaf. The tap sees a key
    /// where it enters the session, before the monitors, so a working tap reports the first one;
    /// four leave room for the two hand-offs to the main thread arriving out of order.
    public static let deafAfterMonitorKeyDowns = 4

    public private(set) var state: State = .waiting
    /// When the tap was created, in event time (`NSEvent.timestamp`, the same clock as
    /// `ProcessInfo.systemUptime`). Monitor key presses from before it were on their way already
    /// and do not count.
    public let startedAt: Double
    private var monitorKeyDowns = 0

    public init(startedAt: Double = 0) {
        self.startedAt = startedAt
    }

    /// The tap reported an event. True when this proves it (the monitors can go): a key press
    /// outside secure keyboard entry.
    /// - Parameters:
    ///   - keyDown: a key press (false for a modifier change).
    ///   - secureInput: secure keyboard entry is on now.
    public mutating func tapEvent(keyDown: Bool, secureInput: Bool) -> Bool {
        guard keyDown, !secureInput, state == .waiting else { return false }
        state = .proven
        return true
    }

    /// The monitors reported an event at event time `t`. True when this makes the tap deaf (it
    /// must go). Only a key press outside secure keyboard entry from after `startedAt` counts.
    public mutating func monitorEvent(keyDown: Bool, secureInput: Bool, at t: Double) -> Bool {
        guard keyDown, !secureInput, state == .waiting, t >= startedAt else { return false }
        monitorKeyDowns += 1
        guard monitorKeyDowns >= Self.deafAfterMonitorKeyDowns else { return false }
        state = .deaf
        return true
    }
}

/// The tap's event mask, and the check that macOS left the key bits in it.
public enum KeyTapMask {
    /// Key down and modifier changes. Key up is not needed: the pill follows presses and the held
    /// modifiers.
    public static let wanted: CGEventMask = (1 << CGEventMask(CGEventType.keyDown.rawValue))
        | (1 << CGEventMask(CGEventType.flagsChanged.rawValue))

    /// The tap still gets key presses. macOS clears the bits of events a tap may not see (it returns
    /// no tap only when the whole mask is cleared), so a tap with only modifier changes left would
    /// show ⇧⌘ but never ⇧⌘4. `masks` are the masks `CGGetEventTapList` lists for the new tap
    /// (`newTapMasks`); none listed means macOS did not say, and the tap is trusted until
    /// `TapProof` decides.
    public static func seesKeys(_ masks: [CGEventMask]) -> Bool {
        let keyDown: CGEventMask = 1 << CGEventMask(CGEventType.keyDown.rawValue)
        return masks.isEmpty || masks.contains { $0 & keyDown != 0 }
    }

    /// One tap as `CGGetEventTapList` lists it.
    public struct Listed: Sendable, Equatable {
        public var id: UInt32
        public var pid: pid_t
        public var isSessionTap: Bool
        public var mask: CGEventMask

        public init(id: UInt32, pid: pid_t, isSessionTap: Bool, mask: CGEventMask) {
            self.id = id
            self.pid = pid
            self.isSessionTap = isSessionTap
            self.mask = mask
        }
    }

    /// The masks of the taps this process created between the two lists: session taps of `pid`
    /// listed `after` and not `before`. So an older tap of TwinTake still listed is never taken
    /// for the new one.
    public static func newTapMasks(before: [Listed], after: [Listed], pid: pid_t) -> [CGEventMask] {
        let old = Set(before.map(\.id))
        return after.filter { $0.pid == pid && $0.isSessionTap && !old.contains($0.id) }.map(\.mask)
    }
}

// MARK: - The tap

/// A listen-only Quartz event tap for key presses and modifier changes in every app.
///
/// **Where it taps: `kCGSessionEventTap`.** CGEvent.h says a tap at `kCGHIDEventTap` may only be
/// placed by a process running as root (others get NULL), so a normal app uses the session tap.
/// The session tap sees events where they enter the login session, before macOS routes them to an
/// app and before it matches global hotkeys, so a key another app's hotkey takes still reaches it.
/// It also honours secure keyboard entry like the rest of the session. By default it is inserted
/// at the head of the session's taps (`kCGHeadInsertEventTap`), before other apps' session
/// filters: it sees the keys as typed, also when a key remapper's tap (a Hyper key tool) changes
/// or swallows them later. `KeyMonitor.tapPlacement` can put it at the tail instead, after those
/// filters, to see what apps get (a device check decides which one stays).
///
/// **Listen only (`kCGEventTapOptionListenOnly`).** It never changes, holds back or delays an
/// event: a slow listener does not hold up typing (an active filter would, for every app). A
/// listen-only key tap needs Input Monitoring (`CGPreflightListenEventAccess`); `start` creates
/// nothing without it, because creating one without it makes macOS ask.
///
/// **Threads.** The tap is created on the main thread (one quick call to the window server) and
/// runs on its own thread's run loop, so a busy main thread never makes macOS turn it off. The
/// callback only copies the key code, flags and repeat flag (and keeps a copy of a key-down event
/// for its layout character, which is read on the main thread and only for a key that shows), then
/// hands off to the main thread with `DispatchQueue.main.async`. It never logs a character. When
/// macOS turns the tap off (`kCGEventTapDisabledByTimeout`, `kCGEventTapDisabledByUserInput`) the
/// callback turns it on again. Nothing waits on the tap's thread.
@MainActor
final class KeyEventTap {
    /// One event, copied out of the callback.
    ///
    /// `@unchecked Sendable`: `keyDown` is a private copy of the event; after the hand-off only the
    /// main thread reads it.
    struct Event: @unchecked Sendable {
        var type: CGEventType
        var keyCode: UInt16
        var flags: CGEventFlags
        var isRepeat: Bool
        /// A copy of a key-down event, for its layout character and AppKit's event time. Nil for a
        /// modifier change.
        var keyDown: CGEvent?
    }

    private let box: TapBox

    private init(box: TapBox) {
        self.box = box
    }

    deinit { box.stop() }

    /// Creates the tap and starts its thread. Nil, with nothing created, without Input Monitoring
    /// or when macOS gives no working tap (after a grant it can need a relaunch).
    /// - Parameters:
    ///   - place: head (the default) or tail of the session's taps.
    ///   - deliver: runs on the tap's thread for each event; it must only hand off.
    static func start(place: CGEventTapPlacement = .headInsertEventTap,
                      deliver: @escaping @Sendable (Event) -> Void) -> KeyEventTap? {
        // Never without Input Monitoring: creating a key tap without it makes macOS ask.
        guard CGPreflightListenEventAccess() else { return nil }
        let box = TapBox(deliver: deliver)
        let before = listedTaps()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: place, options: .listenOnly,
            eventsOfInterest: KeyTapMask.wanted,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        box.attach(port: port, source: source)
        let masks = KeyTapMask.newTapMasks(before: before, after: listedTaps(),
                                           pid: ProcessInfo.processInfo.processIdentifier)
        guard KeyTapMask.seesKeys(masks) else {
            box.stop()
            return nil
        }
        // The thread holds the box until its run loop ends, so no callback outlives it.
        let thread = Thread { [box] in box.run() }
        thread.name = "TwinTake.keyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return KeyEventTap(box: box)
    }

    /// Turns the tap on again when macOS turned it off. False when it stays off or is gone.
    func ensureEnabled() -> Bool { box.ensureEnabled() }

    /// Removes the tap and ends its thread. Never waits.
    func stop() { box.stop() }

    /// Every tap the window server lists now (read only; empty when it does not say).
    private static func listedTaps() -> [KeyTapMask.Listed] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        // Room for a tap another app adds between the two calls.
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 8)
        var filled: UInt32 = 0
        guard CGGetEventTapList(UInt32(list.count), &list, &filled) == .success else { return [] }
        return list.prefix(Int(min(filled, UInt32(list.count)))).map {
            KeyTapMask.Listed(id: $0.eventTapID, pid: $0.tappingProcess, isSessionTap: $0.tapPoint == .cgSessionEventTap,
                              mask: $0.eventsOfInterest)
        }
    }
}

/// The tap's C callback, on the tap's thread. A file-scope function on purpose: a closure written
/// inside `KeyEventTap.start` inherits the type's `@MainActor`, Swift then checks the thread each
/// time it runs, and the tap's thread traps on the first key (seen on device, a take was lost).
func keyTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                    _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let info { Unmanaged<TapBox>.fromOpaque(info).takeUnretainedValue().received(type, event) }
    return Unmanaged.passUnretained(event)
}

/// The tap's state, shared by the main thread and the tap's thread. A class box: the delivery
/// closure is a plain `let` field (never in a `Mutex` tuple), the rest is behind a lock.
final class TapBox: @unchecked Sendable {
    let deliver: @Sendable (KeyEventTap.Event) -> Void
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(deliver: @escaping @Sendable (KeyEventTap.Event) -> Void) {
        self.deliver = deliver
    }

    /// Main thread, before the tap's thread starts.
    func attach(port: CFMachPort, source: CFRunLoopSource) {
        lock.lock()
        self.port = port
        self.source = source
        lock.unlock()
    }

    /// The tap's thread: runs the tap until `stop`.
    func run() {
        lock.lock()
        guard !stopped, let source else {
            lock.unlock()
            return
        }
        let loop = CFRunLoopGetCurrent()
        runLoop = loop
        CFRunLoopAddSource(loop, source, .defaultMode)
        lock.unlock()
        // Returns when `stop` stops the run loop, or when the tap's source is gone (finished).
        while !isStopped {
            let result = CFRunLoopRunInMode(.defaultMode, 60, false)
            if result == .finished || result == .stopped { break }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// The tap's thread, for each event. Copies and hands off only.
    func received(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            let port = stopped ? nil : port
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            deliver(KeyEventTap.Event(
                type: type, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                keyDown: event.copy()))
        case .flagsChanged:
            deliver(KeyEventTap.Event(
                type: type, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags, isRepeat: false, keyDown: nil))
        default:
            break
        }
    }

    /// Main thread: turns the tap on again when macOS turned it off.
    func ensureEnabled() -> Bool {
        lock.lock()
        let port = stopped ? nil : port
        lock.unlock()
        guard let port, CFMachPortIsValid(port) else { return false }
        if CGEvent.tapIsEnabled(tap: port) { return true }
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port)
    }

    /// Any thread: removes the tap and stops its run loop. Never waits for the tap's thread.
    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let port = port
        let loop = runLoop
        self.port = nil
        source = nil
        runLoop = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            // Also removes the tap's source from the run loop.
            CFMachPortInvalidate(port)
        }
        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        }
    }
}
