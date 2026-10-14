import ApplicationServices
import CoreGraphics
import RecorderCore

/// A change to the snapped window, seen by `SnappedWindowMonitor`. Frames are global CG points.
public struct WindowMove: Sendable, Equatable {
    public var previousFrame: CGRect
    /// The new frame, or nil when the window closed.
    public var frame: CGRect?
    /// Host-clock time of the poll that saw the change (see `HostClock`).
    public var tHostNs: UInt64
    public var moved: Bool
    public var resized: Bool
    /// True when the window is still where it was snapped (`SnapResult.windowTargetFrame`).
    public var fillsFrame: Bool

    public var closed: Bool { frame == nil }

    /// `data` for a `window_move` event in events.jsonl.
    public var eventData: [String: String] {
        var d = ["previous": previousFrame.eventString, "moved": String(moved), "resized": String(resized),
                 "fills_frame": String(fillsFrame), "closed": String(closed)]
        d["frame"] = frame?.eventString
        return d
    }

    /// What changed between two frames, or nil when nothing moved more than `tolerance` points.
    static func change(from old: CGRect, to new: CGRect, tolerance: CGFloat) -> (moved: Bool, resized: Bool)? {
        let moved = abs(old.minX - new.minX) > tolerance || abs(old.minY - new.minY) > tolerance
        let resized = abs(old.width - new.width) > tolerance || abs(old.height - new.height) > tolerance
        return moved || resized ? (moved, resized) : nil
    }
}

/// Polls the snapped window about once a second while recording and reports moves, resizes
/// and closing, so the app can log `window_move` and warn that the frame shows something else.
@MainActor
public final class SnappedWindowMonitor {
    public let snap: SnapResult
    public let interval: Duration
    /// Changes smaller than this (points) are ignored.
    public var tolerancePt: CGFloat = 1
    /// The last frame seen, in global CG points.
    public private(set) var lastFrame: CGRect?
    public var isRunning: Bool { task != nil }

    private let window: AXWindowRef
    private var task: Task<Void, Never>?

    /// The longest an Accessibility read of the window waits for its app, on the main thread.
    static let messagingTimeout: Float = 0.25

    /// Nil when the snap found no window to watch.
    public init?(snap: SnapResult, interval: Duration = .seconds(1)) {
        guard let ref = snap.windowRef else { return nil }
        self.snap = snap
        self.interval = interval
        self.window = ref
        self.lastFrame = snap.achievedFrame
        // A poll must never stall the main thread for long on a busy app (a Parallels VM under load).
        AXUIElementSetMessagingTimeout(ref.window, Self.messagingTimeout)
    }

    /// Starts polling. `onChange` runs on the main actor for each change, and once with
    /// `closed == true` when the window goes away (polling then stops).
    public func start(onChange: @escaping @MainActor (WindowMove) -> Void) {
        stop()
        let interval = interval
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if let move = self.poll() {
                    onChange(move)
                    if move.closed { self.task = nil; return }
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Reads the frame once. Returns a change, or nil when nothing changed or the read failed.
    func poll() -> WindowMove? {
        let now = HostClock.nowNs()
        guard let previous = lastFrame else {
            lastFrame = currentFrame()
            return nil
        }
        guard let frame = currentFrame() else {
            guard isGone() else { return nil }
            lastFrame = nil
            return WindowMove(previousFrame: previous, frame: nil, tHostNs: now, moved: false, resized: false,
                              fillsFrame: false)
        }
        guard let c = WindowMove.change(from: previous, to: frame, tolerance: tolerancePt) else { return nil }
        lastFrame = frame
        return WindowMove(previousFrame: previous, frame: frame, tHostNs: now, moved: c.moved, resized: c.resized,
                          fillsFrame: frame.isClose(to: snap.windowTargetFrame, tolerance: tolerancePt))
    }

    private func currentFrame() -> CGRect? {
        let listed = snap.windowID.flatMap(WindowList.entry(for:))?.bounds
        return Self.frame(listed: listed, last: lastFrame, tolerance: tolerancePt) { window.window.frame }
    }

    /// The window's frame now. The window list never waits for the app; an Accessibility read
    /// does (up to `messagingTimeout`, on the main thread, every second). So while the list shows
    /// the window where it was, that is the answer, and Accessibility is asked only when the list
    /// shows a change or does not have the window. When the AX read fails (timed out), the list's
    /// frame stands in.
    static func frame(listed: CGRect?, last: CGRect?, tolerance: CGFloat, accessibility: () -> CGRect?) -> CGRect? {
        if let listed, let last, WindowMove.change(from: last, to: listed, tolerance: tolerance) == nil { return last }
        return accessibility() ?? listed
    }

    private func isGone() -> Bool {
        var role: AnyObject?
        let err = AXUIElementCopyAttributeValue(window.window, kAXRoleAttribute as CFString, &role)
        if err == .invalidUIElement { return true }
        if let id = snap.windowID { return WindowList.entry(for: id) == nil }
        return false
    }
}
