import CoreGraphics
import Foundation

/// Whether a watched window is on screen, from reads of the window list. A change counts after
/// `confirmReads` reads in a row agree, so one odd read logs nothing. Starts on screen (the window
/// was listed when the filter was built).
struct WindowPresence: Equatable, Sendable {
    static let confirmReads = 2

    private(set) var onScreen = true
    private var differing = 0

    /// One read. Returns the new state when it changed.
    mutating func update(onScreen now: Bool) -> Bool? {
        guard now != onScreen else {
            differing = 0
            return nil
        }
        differing += 1
        guard differing >= Self.confirmReads else { return nil }
        differing = 0
        onScreen = now
        return now
    }
}

/// Watches one window in the window list for a window capture that also shows the keystroke
/// pill (`ScreenFilterPlan.Kind.windows`). There the pill keeps the stream active, so
/// ScreenCaptureKit never says the recorded window closed (`streamDidBecomeInactive` comes only
/// when every shared window is gone). Reads `CGWindowListCopyWindowInfo` for that one window on
/// its own utility queue: never a capture queue, never a writer.
final class WindowPresenceWatch: @unchecked Sendable {
    static let interval: DispatchTimeInterval = .milliseconds(500)

    let windowID: UInt32
    private let onChange: @Sendable (Bool) -> Void
    private let queue = DispatchQueue(label: "ScreenRecorder.windowWatch", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var timer: DispatchSourceTimer?
    // Only touched on `queue`.
    private var presence = WindowPresence()

    /// - Parameter onChange: true when the window is on screen again, false when it left; on the
    ///   watch's queue.
    init(windowID: UInt32, onChange: @escaping @Sendable (Bool) -> Void) {
        self.windowID = windowID
        self.onChange = onChange
    }

    deinit { timer?.cancel() }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
            timer.setEventHandler { [weak self] in self?.read() }
            timer.activate()
            self.timer = timer
        }
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    private func read() {
        if let change = presence.update(onScreen: Self.isOnScreen(windowID)) { onChange(change) }
    }

    /// The window is listed and on screen (not closed, minimized, hidden or on another Space).
    static func isOnScreen(_ windowID: UInt32) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let window = info.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return false }
        return (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }
}
