// Portions adapted from Rectangle (https://github.com/rxhanson/Rectangle), Copyright (c) 2019-2026 Ryan Hanson, MIT License.

import AppKit
import ApplicationServices

/// Attribute names that have no constant in the SDK headers.
enum AXName {
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let fullScreen = "AXFullScreen"
    static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
}

extension AXUIElement {
    func value(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (value(attribute) as? [AXUIElement]) ?? []
    }

    func bool(_ attribute: String) -> Bool? { value(attribute) as? Bool }

    func string(_ attribute: String) -> String? { value(attribute) as? String }

    var point: CGPoint? {
        guard let v = axValue(kAXPositionAttribute, type: .cgPoint) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = axValue(kAXSizeAttribute, type: .cgSize) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    /// Position and size as one rect in global CG points (top-left origin), or nil.
    var frame: CGRect? {
        guard let point, let size else { return nil }
        return CGRect(origin: point, size: size)
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    func isSettable(_ attribute: String) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success else { return nil }
        return settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> AXError {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v)
    }

    @discardableResult
    func setSize(_ s: CGSize) -> AXError {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v)
    }

    /// The attribute's AXValue when it holds `type`.
    private func axValue(_ attribute: String, type: AXValueType) -> AXValue? {
        guard let v = value(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let axv = v as! AXValue
        return AXValueGetType(axv) == type ? axv : nil
    }
}

/// An app's window, as the Accessibility API sees it.
///
/// AXUIElement calls are synchronous IPC to the target app. Keep them on the main actor and
/// cap the wait with `AXUIElementSetMessagingTimeout`, so a hung app cannot freeze the recorder.
struct AXWindow {
    let app: AXUIElement
    let window: AXUIElement

    /// The window to act on for `pid`: focused, then main, then the app's other windows.
    /// A standard window wins over a dialog or floating panel that has focus.
    static func target(pid: pid_t, timeout: Float) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let candidates = ([app.element(kAXFocusedWindowAttribute), app.element(kAXMainWindowAttribute)]
            .compactMap { $0 } + app.elements(kAXWindowsAttribute))
            .filter { $0.string(kAXRoleAttribute) == kAXWindowRole }
        guard let window = candidates.first(where: { $0.string(kAXSubroleAttribute) == kAXStandardWindowSubrole })
            ?? candidates.first else { return nil }
        AXUIElementSetMessagingTimeout(window, timeout)
        return AXWindow(app: app, window: window)
    }

    /// The window of `pid` that the window server shows at `bounds` (global CG points): the AX
    /// window with the same frame, the title breaking a tie (`AXWindowMatch`).
    /// `.noAnswer` when the app does not answer within `timeout`; `.notListed` when it lists no
    /// such window (or does not support Accessibility).
    static func matching(pid: pid_t, bounds: CGRect, title: String?, timeout: Float) -> SnapLookup.Outcome<AXWindow> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if err == .cannotComplete { return .noAnswer(err) }
        let listed = err == .success ? (value as? [AXUIElement]) ?? [] : []
        let windows = listed.filter { w in
            AXUIElementSetMessagingTimeout(w, timeout)
            return w.string(kAXRoleAttribute) == kAXWindowRole
        }
        guard let i = AXWindowMatch.index(for: bounds, title: title, frames: windows.map(\.frame),
                                          titleAt: { windows[$0].string(kAXTitleAttribute) }) else { return .notListed }
        let w = AXWindow(app: app, window: windows[i])
        return .found(w, isStandard: w.isStandard)
    }

    var title: String? { window.string(kAXTitleAttribute) }
    /// True for a standard window (not a dialog, a sheet or a floating panel).
    var isStandard: Bool { window.string(kAXSubroleAttribute) == kAXStandardWindowSubrole }
    var frame: CGRect? { window.frame }
    var isMinimized: Bool { window.bool(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { window.bool(AXName.fullScreen) ?? false }
    var isResizable: Bool { window.isSettable(kAXSizeAttribute) ?? true }
    var isMovable: Bool { window.isSettable(kAXPositionAttribute) ?? true }

    /// Moves and resizes the window to `frame` (global CG points).
    ///
    /// The Accessibility API sets size and position one at a time, and macOS keeps a window's
    /// size within the display it is on. So: size, then position (which may move it to another
    /// display), then size again. Chromium and Electron apps animate or ignore frame changes
    /// while `AXEnhancedUserInterface` is on, so it is off during the change and restored after.
    /// - Returns: the first AX error, or `.success`.
    @discardableResult
    func setFrame(_ frame: CGRect) -> AXError {
        let enhancedUI = app.bool(AXName.enhancedUserInterface)
        if enhancedUI == true { app.set(AXName.enhancedUserInterface, false) }
        defer { if enhancedUI == true { app.set(AXName.enhancedUserInterface, true) } }

        let first = window.setSize(frame.size)
        let move = window.setPosition(frame.origin)
        let last = window.setSize(frame.size)
        // The first size call may fail for a window that only fits after the move.
        if move != .success { return move }
        if last != .success { return first != .success ? first : last }
        return .success
    }

    /// Brings the window in front of its app's other windows (`kAXRaiseAction`).
    @discardableResult
    func raise() -> AXError {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Moves the window without resizing it.
    @discardableResult
    func setPosition(_ origin: CGPoint) -> AXError {
        let enhancedUI = app.bool(AXName.enhancedUserInterface)
        if enhancedUI == true { app.set(AXName.enhancedUserInterface, false) }
        defer { if enhancedUI == true { app.set(AXName.enhancedUserInterface, true) } }
        return window.setPosition(origin)
    }

    /// A bounded read of the window's Accessibility tree: role, subrole and frame of each
    /// element, for `ToolbarDetection`. Nil when the window's children cannot be read.
    ///
    /// Breadth first. Only large container elements (a quarter of the window or more) are
    /// opened, because the content area is large and the toolbar strip is a direct child. One
    /// IPC call per element (`AXUIElementCopyMultipleAttributeValues`), and the walk stops at
    /// `maxElements`, `maxDepth` or `budget`, so a deep tree cannot stall the main thread.
    func elementSnapshot(timeout: Float, maxElements: Int = 80, maxDepth: Int = 4,
                         budget: Duration = .milliseconds(250)) -> [AXElementInfo]? {
        guard let top = window.value(kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        let windowArea = (frame?.width ?? 0) * (frame?.height ?? 0)
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        var result: [AXElementInfo] = []
        var queue: [(element: AXUIElement, depth: Int)] = top.map { ($0, 1) }
        var index = 0
        while index < queue.count, result.count < maxElements, clock.now < deadline {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, timeout)
            guard let (info, children) = Self.snapshot(of: element) else { continue }
            result.append(info)
            let area = info.frame.width * info.frame.height
            if depth < maxDepth, windowArea > 0, area >= windowArea / 4, !ToolbarDetection.controlRoles.contains(info.role) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        // Some apps keep the window buttons out of the children list.
        if !result.contains(where: { $0.subrole == kAXCloseButtonSubrole as String }),
           let close = window.element(kAXCloseButtonAttribute), let (info, _) = Self.snapshot(of: close) {
            result.append(info)
        }
        return result
    }

    private static let snapshotAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute,
                                             kAXSizeAttribute, kAXChildrenAttribute]

    /// Role, subrole, frame and children of one element in one IPC call. Nil without a role or a frame.
    private static func snapshot(of element: AXUIElement) -> (AXElementInfo, [AXUIElement])? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, snapshotAttributes as CFArray,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let list = values as? [AnyObject], list.count == 5, let role = list[0] as? String else { return nil }
        func axValue(_ v: AnyObject, _ type: AXValueType) -> AXValue? {
            guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            let axv = v as! AXValue
            return AXValueGetType(axv) == type ? axv : nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard let p = axValue(list[2], .cgPoint), AXValueGetValue(p, .cgPoint, &point),
              let s = axValue(list[3], .cgSize), AXValueGetValue(s, .cgSize, &size) else { return nil }
        let children = (list[4] as? [AXUIElement]) ?? []
        return (AXElementInfo(role: role, subrole: list[1] as? String, frame: CGRect(origin: point, size: size)), children)
    }
}

/// Maps a window-list window to one of its app's Accessibility windows. Plain logic.
enum AXWindowMatch {
    /// Least overlap (intersection over union) for the last-resort match.
    static let minOverlap: CGFloat = 0.5

    /// The index in `frames` of the AX window shown at `bounds`, in this order:
    /// 1. The only one within `tolerance` points on every edge; when several are, the first
    ///    whose title is `title`, else the first.
    /// 2. The only window titled `title`.
    /// 3. The window that overlaps `bounds` most, when the overlap is at least `minOverlap`.
    /// Titles are read only when needed (`titleAt`), because each read is a call to the app.
    static func index(for bounds: CGRect, title: String?, frames: [CGRect?], tolerance: CGFloat = 2,
                      titleAt: (Int) -> String?) -> Int? {
        let close = frames.indices.filter { frames[$0].map { $0.isClose(to: bounds, tolerance: tolerance) } ?? false }
        let wanted = title.flatMap { $0.isEmpty ? nil : $0 }
        if close.count == 1 { return close[0] }
        if close.count > 1 {
            guard let wanted else { return close[0] }
            return close.first { titleAt($0) == wanted } ?? close[0]
        }
        if let wanted {
            let titled = frames.indices.filter { titleAt($0) == wanted }
            if titled.count == 1 { return titled[0] }
        }
        let best = frames.indices.compactMap { i in frames[i].map { (i, overlap($0, bounds)) } }.max { $0.1 < $1.1 }
        return best.flatMap { $0.1 >= minOverlap ? $0.0 : nil }
    }

    /// Intersection over union of two rects: 1 when equal, 0 when apart.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// An AX window reference that can travel inside a `Sendable` value.
///
/// AXUIElement is an immutable CF handle; the calls made through it are IPC and are only
/// made on the main actor in this module.
final class AXWindowRef: @unchecked Sendable, Hashable {
    let app: AXUIElement
    let window: AXUIElement

    init(_ w: AXWindow) { app = w.app; window = w.window }

    var axWindow: AXWindow { AXWindow(app: app, window: window) }

    static func == (a: AXWindowRef, b: AXWindowRef) -> Bool { CFEqual(a.window, b.window) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(window)) }
}
