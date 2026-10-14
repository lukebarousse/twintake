// Portions adapted from Rectangle (https://github.com/rxhanson/Rectangle), Copyright (c) 2019-2026 Ryan Hanson, MIT License.

import AppKit
import ApplicationServices
import RecorderCore

/// Why a snap did not fill the frame.
public enum SnapFailure: String, Sendable, Hashable {
    /// Accessibility permission is off.
    case notTrusted = "not_trusted"
    /// No app other than the recorder has a window on screen (the frame is on no known display).
    case noTargetApp = "no_target_app"
    /// No app other than the recorder has a window on the recording display.
    case noWindowOnDisplay = "no_window_on_display"
    /// The chosen window is not in its app's Accessibility window list, so it cannot be moved.
    case noWindow = "no_window"
    /// A pinned app (a control bar app button) has no window on any display.
    case noAppWindow = "no_app_window"
    /// Native full screen windows cannot be moved. The user must exit full screen first.
    case fullScreen = "full_screen"
    case minimized
    case notMovable = "not_movable"
    /// The app returned an Accessibility error and the window did not change as asked.
    case axError = "ax_error"
    /// The app kept a different size (minimum or maximum size, or character-cell resizing).
    case sizeMismatch = "size_mismatch"
    case positionMismatch = "position_mismatch"
    /// The app keeps its toolbar above the frame (`SnapPlacement.toolbarAbove`), and the toolbar
    /// does not fit between the menu bar and the frame. The window did not move. The frame must
    /// move down (`SnapResult.frameMoveDownPt`), for example to the bottom of the display.
    case toolbarNoRoom = "toolbar_no_room"
}

/// What `WindowSnapper` did. Frames are global CG points (top-left origin, y down).
public struct SnapResult: Sendable, Equatable {
    /// True when the window (its content area, for `.toolbarAbove`) now covers the requested
    /// frame, within the snapper's tolerance.
    public var success: Bool
    public var failure: SnapFailure?
    public var appName: String?
    public var bundleId: String?
    public var pid: pid_t?
    public var title: String?
    /// Window server id, for window-only capture (`ScreenRecorderConfig.windowID`).
    /// Nil when no on-screen window matched the pid and frame.
    public var windowID: CGWindowID?
    /// The recording frame the app asked for.
    public var requestedFrame: CGRect
    /// The window frame before the snap.
    public var previousFrame: CGRect?
    /// The window frame read back after the snap.
    public var achievedFrame: CGRect?
    /// Raw `AXError` value when an Accessibility call failed.
    public var axErrorCode: Int32?
    /// One line for the user, e.g. "Snapped Safari to 1504×846 pt."
    public var message: String
    /// How the window was placed: `.fill`, or `.toolbarAbove` for an app with that profile.
    public var placement: SnapPlacement
    /// `SnapProfile.id` of the app's profile ("standard" for most apps).
    public var profileID: String
    /// The toolbar strip used for `.toolbarAbove` (nil for `.fill`).
    public var toolbar: ToolbarMeasurement?
    /// The window frame the snapper asked for: `requestedFrame` for `.fill`; the frame plus the
    /// toolbar strip above it for `.toolbarAbove`. `SnappedWindowMonitor` compares against it.
    public var windowTargetFrame: CGRect
    /// For `.toolbarAbove`: the window's content area read back (the window minus the toolbar strip).
    public var achievedContentFrame: CGRect?
    /// For `.toolbarNoRoom`: how many points the frame must move down so the toolbar fits.
    public var frameMoveDownPt: CGFloat?
    /// The name in the notices, e.g. "Windows 11 (Parallels)" (`SnapCandidate.targetName`).
    public var targetName: String?
    /// The recording display the window was looked for on, e.g. "Built-in Retina Display".
    public var displayName: String?
    /// How the window was chosen (`SnapTargetFinder`). Nil when no window was chosen.
    public var pick: SnapPick?
    /// How many windows on the recording display could have been snapped.
    public var candidateCount: Int?
    var windowRef: AXWindowRef?

    public init(success: Bool, failure: SnapFailure?, appName: String?, bundleId: String?, pid: pid_t?,
                title: String?, windowID: CGWindowID?, requestedFrame: CGRect, previousFrame: CGRect?,
                achievedFrame: CGRect?, axErrorCode: Int32? = nil, message: String,
                placement: SnapPlacement = .fill, profileID: String = SnapProfile.standard.id,
                toolbar: ToolbarMeasurement? = nil, windowTargetFrame: CGRect? = nil,
                achievedContentFrame: CGRect? = nil, frameMoveDownPt: CGFloat? = nil, targetName: String? = nil,
                displayName: String? = nil, pick: SnapPick? = nil, candidateCount: Int? = nil) {
        self.success = success; self.failure = failure; self.appName = appName; self.bundleId = bundleId
        self.pid = pid; self.title = title; self.windowID = windowID; self.requestedFrame = requestedFrame
        self.previousFrame = previousFrame; self.achievedFrame = achievedFrame; self.axErrorCode = axErrorCode
        self.message = message; self.placement = placement; self.profileID = profileID; self.toolbar = toolbar
        self.windowTargetFrame = windowTargetFrame ?? requestedFrame
        self.achievedContentFrame = achievedContentFrame; self.frameMoveDownPt = frameMoveDownPt
        self.targetName = targetName; self.displayName = displayName; self.pick = pick
        self.candidateCount = candidateCount
    }

    public var requestedSize: CGSize { requestedFrame.size }
    public var achievedSize: CGSize? { achievedFrame?.size }

    /// The part of the window that is meant to cover the frame, read back: the content area for
    /// `.toolbarAbove`, the whole window for `.fill`.
    public var achievedRecordedFrame: CGRect? {
        placement == .toolbarAbove ? achievedContentFrame : achievedFrame
    }

    /// The manifest value (`session.json` `screen.snapped_window`). Nil when no window was found.
    /// `achieved_pt` is the size of `achievedRecordedFrame`, so it compares with `requested_pt`
    /// for every placement. `placement` is always set; `toolbar_pt` only for `.toolbarAbove`.
    /// The app fills in the display-local frames (`achieved_frame_pt`, `window_frame_pt`).
    public var snappedWindow: SnappedWindow? {
        guard let achievedFrame else { return nil }
        let achieved = achievedRecordedFrame ?? achievedFrame
        return SnappedWindow(appName: appName, bundleId: bundleId, title: title,
                             requestedPt: PointSize(requestedSize), achievedPt: PointSize(achieved.size),
                             placement: placement.rawValue,
                             toolbarPt: placement == .toolbarAbove ? toolbar.map { Double($0.heightPt) } : nil)
    }

    /// `data` for a `window_snap` event in events.jsonl: `target`, `display`, `picked_by` and
    /// `candidates` say which window was chosen and why. A `.toolbarAbove` snap adds
    /// `placement`, `profile`, `toolbar_pt`, `toolbar_source`, `toolbar_fine_tune_pt`,
    /// `window_target`, `content` and, for `toolbar_no_room`, `move_down_pt`.
    public var eventData: [String: String] {
        var d: [String: String] = ["success": success ? "true" : "false", "requested": requestedFrame.eventString]
        d["failure"] = failure?.rawValue
        d["app"] = appName
        d["bundle_id"] = bundleId
        d["title"] = title
        d["window_id"] = windowID.map(String.init)
        d["previous"] = previousFrame?.eventString
        d["achieved"] = achievedFrame?.eventString
        d["ax_error"] = axErrorCode.map(String.init)
        d["target"] = targetName
        d["display"] = displayName
        d["picked_by"] = pick?.rawValue
        d["candidates"] = candidateCount.map(String.init)
        if placement == .toolbarAbove {
            d["placement"] = placement.rawValue
            d["profile"] = profileID
            d["toolbar_pt"] = toolbar?.heightPt.ptNumber
            d["toolbar_source"] = toolbar?.source.rawValue
            d["toolbar_fine_tune_pt"] = toolbar?.fineTunePt.ptNumber
            d["window_target"] = windowTargetFrame.eventString
            d["content"] = achievedContentFrame?.eventString
            d["move_down_pt"] = frameMoveDownPt?.ptNumber
        }
        return d
    }

    /// Decides success from the read-back frame. Size is checked before position, because a
    /// window that kept a smaller size is centered in the frame on purpose.
    static func evaluate(requested: CGRect, achieved: CGRect?, tolerance: CGFloat) -> SnapFailure? {
        guard let achieved else { return .axError }
        if achieved.isClose(to: requested, tolerance: tolerance) { return nil }
        if abs(achieved.width - requested.width) > tolerance || abs(achieved.height - requested.height) > tolerance {
            return .sizeMismatch
        }
        return .positionMismatch
    }

    /// The user-facing message for an outcome. For `.toolbarAbove`, `achieved` is the content
    /// area and `toolbarPt` the strip above the frame. `displayName` is the recording display.
    static func message(for failure: SnapFailure?, appName: String?, title: String?, requested: CGRect,
                        achieved: CGRect?, axErrorCode: Int32?, placement: SnapPlacement = .fill,
                        toolbarPt: CGFloat? = nil, moveDownPt: CGFloat? = nil, displayName: String? = nil) -> String {
        let app = appName ?? "The app"
        let part = placement == .toolbarAbove ? "content area" : "window"
        switch failure {
        case nil:
            if placement == .toolbarAbove, let t = toolbarPt, t > 0 {
                return "Snapped \(app) to \(requested.size.ptString), with its toolbar (\(t.ptNumber) pt) above the frame."
            }
            return "Snapped \(app) to \(requested.size.ptString)."
        case .notTrusted:
            return "Accessibility permission is off. Allow it in System Settings > Privacy & Security > Accessibility, then snap again."
        case .noTargetApp:
            return "No app window to snap. Click the window you want to record, then snap again."
        case .noWindowOnDisplay:
            let display = displayName ?? "the recording display"
            return "No window to snap on \(display). Move the window you want to record onto it, then snap again."
        case .noAppWindow:
            return "\(app) has no window to snap. Open one, then click its button again."
        case .noWindow:
            guard let displayName else { return "\(app) has no window that can be moved." }
            return "The \(app) window on \(displayName) cannot be moved: Accessibility does not list it."
        case .fullScreen:
            let name = title.map { "“\($0)”" } ?? "The \(app) window"
            return "\(name) is in full screen. Exit full screen (⌃⌘F), then snap again."
        case .minimized:
            return "The \(app) window is minimized. Restore it, then snap again."
        case .notMovable:
            return "\(app) does not let its window move."
        case .axError:
            if axErrorCode == AXError.cannotComplete.rawValue { return "\(app) did not respond. Try again." }
            return "\(app) did not accept the new frame (Accessibility error \(axErrorCode.map(String.init) ?? "unknown"))."
        case .sizeMismatch:
            let got = achieved?.size.ptString ?? "another size"
            return "\(app) kept its \(part) at \(got) instead of \(requested.size.ptString)."
        case .positionMismatch:
            let got = achieved.map { "(\($0.minX.ptNumber), \($0.minY.ptNumber))" } ?? "another place"
            return "\(app) placed its \(part) at \(got) instead of (\(requested.minX.ptNumber), \(requested.minY.ptNumber))."
        case .toolbarNoRoom:
            let strip = toolbarPt.map { " (\($0.ptNumber) pt)" } ?? ""
            let down = moveDownPt.map { " It needs \($0.ptNumber) pt more." } ?? ""
            return "\(app) keeps its toolbar\(strip) above the frame, and the toolbar does not fit under the menu bar.\(down) Move the frame to the bottom of the display, then snap again."
        }
    }

    static func failed(_ failure: SnapFailure, requested: CGRect, owner: WindowOwner? = nil, targetName: String? = nil,
                       title: String? = nil, previous: CGRect? = nil, axErrorCode: Int32? = nil,
                       displayName: String? = nil) -> SnapResult {
        let name = targetName ?? owner?.name
        return SnapResult(success: false, failure: failure, appName: owner?.name, bundleId: owner?.bundleID,
                          pid: owner?.pid, title: title, windowID: nil, requestedFrame: requested,
                          previousFrame: previous, achievedFrame: nil, axErrorCode: axErrorCode,
                          message: message(for: failure, appName: name, title: title, requested: requested,
                                           achieved: nil, axErrorCode: axErrorCode, displayName: displayName),
                          targetName: name, displayName: displayName)
    }
}

/// Moves and resizes another app's window to the recording frame, through the Accessibility API.
///
/// Needs Accessibility permission (System Settings > Privacy & Security > Accessibility).
/// The app cannot be sandboxed.
@MainActor
public final class WindowSnapper {
    /// How close (points, every edge) the read-back frame must be to count as a success.
    public var tolerancePt: CGFloat = 1
    /// Longest wait for one Accessibility call to a busy app, in seconds.
    public var messagingTimeout: Float = 1
    /// Per-app placement. An app not listed fills the frame. Set `[]` to fill for every app.
    public var profiles: [SnapProfile] = SnapProfile.all
    /// At most this many window-list windows are looked up in the Accessibility API per snap,
    /// and for at most `lookupBudget`, so busy apps cannot hold up the main thread for long.
    public var maxLookups = 5
    public var lookupBudget: Duration = .seconds(2)
    /// The apps the user activated, most recent first: the tie-breaker of `SnapTargetFinder`.
    public let activations = AppActivationHistory()

    public init() {}

    /// True when this process has Accessibility permission. Never prompts.
    public var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS Accessibility permission prompt when permission is off.
    /// Call it from a user action; it returns the current state without waiting for the user.
    @discardableResult
    public func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([AXName.trustedCheckOptionPrompt: true] as CFDictionary)
    }

    /// Opens System Settings at Privacy & Security > Accessibility.
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The windows a snap to `globalRect` would move, best first (`SnapTargetFinder`). Reads the
    /// window list only: no Accessibility call, no permission needed, cheap enough for the menu.
    /// - Parameters:
    ///   - display: the recording display; nil: the display that holds most of `globalRect`.
    ///   - excludingBundleID: another bundle id to skip (normally the recorder's own).
    public func targets(for globalRect: CGRect, excludingBundleID: String?, display: DisplayInfo? = nil) -> SnapTargets {
        let displays = Displays.all()
        let recording = display ?? DisplayInfo.display(containing: globalRect, in: displays)
        let excluded = Set([excludingBundleID, Bundle.main.bundleIdentifier].compactMap { $0 })
        return SnapTargetFinder.find(in: WindowList.onScreen(), owners: { WindowOwner.running(pid: $0) },
                                     display: recording, displays: displays,
                                     excludedPIDs: [ProcessInfo.processInfo.processIdentifier],
                                     excludedBundleIDs: excluded, recentPIDs: activations.recentPIDs)
    }

    /// Snaps the window the user is looking at on the recording display to `globalRect`.
    ///
    /// The window comes from the window list (`targets(for:excludingBundleID:display:)`), not
    /// from the frontmost app: the recorder's menu, Finder with no window, or a Parallels helper
    /// can be frontmost without a window there. A window on another display never moves.
    /// - Parameters:
    ///   - globalRect: target frame in global CG points, e.g. `DisplayInfo.globalFrameRect(for:anchor:)`.
    ///   - excludingBundleID: another bundle id to skip (normally the recorder's own).
    ///   - toolbarFineTunePt: points added to the detected toolbar height for an app with the
    ///     `.toolbarAbove` placement (Parallels Desktop). Can be negative. Other apps ignore it.
    ///   - display: the recording display; nil: the display that holds most of `globalRect`.
    public func snapFrontmostWindow(to globalRect: CGRect, excludingBundleID: String?,
                                    toolbarFineTunePt: CGFloat = 0, display: DisplayInfo? = nil) -> SnapResult {
        guard isTrusted else { return .failed(.notTrusted, requested: globalRect) }
        let found = targets(for: globalRect, excludingBundleID: excludingBundleID, display: display)
        guard !found.candidates.isEmpty else {
            return .failed(found.displayName == nil ? .noTargetApp : .noWindowOnDisplay, requested: globalRect,
                           displayName: found.displayName)
        }
        return snap(found, to: globalRect, toolbarFineTunePt: toolbarFineTunePt)
    }

    /// The windows a pinned app's button would snap, best first (`SnapTargetFinder.findApp`).
    /// Reads the window list only: no Accessibility call.
    /// - Parameter appName: the pinned app's name, e.g. "Windows 11": the title of its VM window.
    public func appTargets(bundleID: String, appName: String? = nil, for globalRect: CGRect, excludingBundleID: String?,
                           display: DisplayInfo? = nil) -> SnapTargets {
        let displays = Displays.all()
        let recording = display ?? DisplayInfo.display(containing: globalRect, in: displays)
        let excluded = Set([excludingBundleID, Bundle.main.bundleIdentifier].compactMap { $0 })
        return SnapTargetFinder.findApp(bundleID: bundleID, appName: appName, in: WindowList.onScreen(),
                                        owners: { WindowOwner.running(pid: $0) },
                                        display: recording, displays: displays,
                                        excludedPIDs: [ProcessInfo.processInfo.processIdentifier],
                                        excludedBundleIDs: excluded)
    }

    /// Snaps the front window of one app (a control bar app button) to `globalRect`, with the
    /// app's profile (Parallels Desktop keeps its toolbar above the frame), then raises it.
    ///
    /// The window is the app's front-most one on the recording display, else its front-most one
    /// on another display (`SnapTargetFinder.findApp`): the button names the app, so its window
    /// may come from another display. Activate the app first; this only moves the window.
    /// - Parameters:
    ///   - bundleID: the pinned app's bundle id. A Parallels helper finds the Parallels Desktop window.
    ///   - appName: the pinned app's name: the title of its VM window ("Windows 11"), and the name
    ///     for the notices when the app has no window.
    public func snapFrontWindow(ofAppWithBundleID bundleID: String, appName: String?, to globalRect: CGRect,
                                excludingBundleID: String?, toolbarFineTunePt: CGFloat = 0,
                                display: DisplayInfo? = nil) -> SnapResult {
        guard isTrusted else { return .failed(.notTrusted, requested: globalRect) }
        let found = appTargets(bundleID: bundleID, appName: appName, for: globalRect, excludingBundleID: excludingBundleID,
                               display: display)
        guard !found.candidates.isEmpty else {
            var r = SnapResult.failed(.noAppWindow, requested: globalRect, targetName: appName, displayName: found.displayName)
            r.appName = appName
            r.bundleId = bundleID
            r.pick = .pinnedApp
            r.candidateCount = 0
            return r
        }
        let r = snap(found, to: globalRect, toolbarFineTunePt: toolbarFineTunePt)
        // In front of the other apps' windows over the frame. The app was activated, but a
        // window of a helper process (the Parallels VM window) may not have come forward with it.
        if r.achievedFrame != nil { r.windowRef?.axWindow.raise() }
        return r
    }

    /// Looks up the first candidate of `found` that Accessibility can move, and snaps it.
    private func snap(_ found: SnapTargets, to globalRect: CGRect, toolbarFineTunePt: CGFloat) -> SnapResult {
        let first = found.candidates[0]
        let clock = ContinuousClock()
        let deadline = clock.now + lookupBudget
        let timeout = messagingTimeout
        let choice = SnapLookup.choose(found.candidates, maxLookups: maxLookups, inBudget: { clock.now < deadline }) { c in
            AXWindow.matching(pid: c.owner.pid, bounds: c.window.bounds, title: c.window.name, timeout: timeout)
        }
        switch choice {
        case let .failed(candidate, failure, axErrorCode):
            var r = SnapResult.failed(failure, requested: globalRect, owner: candidate.owner,
                                      targetName: candidate.targetName, title: candidate.window.name,
                                      axErrorCode: axErrorCode, displayName: found.displayName)
            r.pick = candidate == first || found.pick == .pinnedApp ? found.pick : .front
            r.candidateCount = found.candidates.count
            return r
        case let .window(candidate, w):
            var r = snap(w, owner: candidate.owner, targetName: candidate.targetName, windowID: candidate.window.id,
                         to: globalRect, toolbarFineTunePt: toolbarFineTunePt)
            r.displayName = found.displayName
            r.pick = candidate == first || found.pick == .pinnedApp ? found.pick : .front
            r.candidateCount = found.candidates.count
            return r
        }
    }

    /// Snaps the focused (or main) window of `app` to `globalRect`.
    ///
    /// An app with the `.toolbarAbove` profile (Parallels Desktop) is placed so its content area
    /// covers `globalRect` and its toolbar sits just above it. When the toolbar does not fit under
    /// the menu bar, the window does not move and the result fails with `.toolbarNoRoom`.
    public func snap(app: NSRunningApplication, to globalRect: CGRect, toolbarFineTunePt: CGFloat = 0) -> SnapResult {
        let owner = WindowOwner(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName,
                                isRegular: app.activationPolicy == .regular)
        guard isTrusted else { return .failed(.notTrusted, requested: globalRect, owner: owner) }
        guard let w = AXWindow.target(pid: owner.pid, timeout: messagingTimeout) else {
            return .failed(.noWindow, requested: globalRect, owner: owner)
        }
        return snap(w, owner: owner, targetName: owner.name, windowID: nil, to: globalRect,
                    toolbarFineTunePt: toolbarFineTunePt)
    }

    /// Moves `w` onto `globalRect`. `windowID` is the window server id when known; else it is
    /// looked up by pid and frame after the move.
    private func snap(_ w: AXWindow, owner: WindowOwner, targetName: String?, windowID: CGWindowID?,
                      to globalRect: CGRect, toolbarFineTunePt: CGFloat) -> SnapResult {
        let pid = owner.pid
        let name = targetName ?? owner.name
        AXUIElementSetMessagingTimeout(w.window, messagingTimeout)
        let title = w.title
        let previous = w.frame
        func failed(_ f: SnapFailure) -> SnapResult {
            .failed(f, requested: globalRect, owner: owner, targetName: name, title: title, previous: previous)
        }
        // Moving a full screen window either fails or throws it out of its Space.
        if w.isFullScreen { return failed(.fullScreen) }
        if w.isMinimized { return failed(.minimized) }
        if !w.isMovable { return failed(.notMovable) }

        let profile = SnapProfile.profile(forBundleID: owner.bundleID, in: profiles)
        if profile.placement == .toolbarAbove {
            return snapToolbarAbove(w, owner: owner, name: name, windowID: windowID, to: globalRect, profile: profile,
                                    fineTunePt: toolbarFineTunePt, title: title, previous: previous)
        }

        let err = w.isResizable ? w.setFrame(globalRect) : w.setPosition(globalRect.origin)
        var achieved = w.frame
        // A window that kept a smaller size goes to the middle of the frame, so the gaps are even.
        if let a = achieved, a.width < globalRect.width - tolerancePt || a.height < globalRect.height - tolerancePt,
           a.width <= globalRect.width, a.height <= globalRect.height {
            let origin = SnapGeometry.centeredOrigin(size: a.size, in: globalRect)
            if abs(a.minX - origin.x) > 0.5 || abs(a.minY - origin.y) > 0.5 {
                w.setPosition(origin)
                achieved = w.frame
            }
        }

        let id = windowID ?? WindowList.match(pid: pid, frames: [achieved, previous].compactMap { $0 }, title: title,
                                              in: WindowList.onScreen())?.id
        var failure = SnapResult.evaluate(requested: globalRect, achieved: achieved, tolerance: tolerancePt)
        let axCode: Int32? = err == .success ? nil : err.rawValue
        if failure != nil, let previous, let achieved, previous.isClose(to: achieved, tolerance: 0.5), err != .success {
            failure = .axError
        }
        var result = SnapResult(
            success: failure == nil, failure: failure, appName: owner.name, bundleId: owner.bundleID,
            pid: pid, title: title, windowID: id, requestedFrame: globalRect, previousFrame: previous,
            achievedFrame: achieved, axErrorCode: axCode,
            message: SnapResult.message(for: failure, appName: name, title: title, requested: globalRect,
                                        achieved: achieved, axErrorCode: axCode),
            targetName: name)
        result.windowRef = AXWindowRef(w)
        return result
    }

    /// `.toolbarAbove`: the content area covers `frame`; the toolbar strip sits above it.
    ///
    /// 1. Measure the strip (Accessibility tree, else the profile's fallback) and add the fine-tune.
    /// 2. Refuse when the strip would reach into the menu bar.
    /// 3. Move the window, read it back, measure the strip again at the new size.
    /// 4. When a content edge is off by more than `tolerancePt`, ask once more, then read back.
    private func snapToolbarAbove(_ w: AXWindow, owner: WindowOwner, name: String?, windowID: CGWindowID?,
                                  to frame: CGRect, profile: SnapProfile, fineTunePt: CGFloat, title: String?,
                                  previous: CGRect?) -> SnapResult {
        let pid = owner.pid
        let topLimit = Displays.display(containing: frame)?.windowTopLimitGlobal
        var toolbar = measureToolbar(w, profile: profile, fineTunePt: fineTunePt)

        func noRoom(_ down: CGFloat, achieved: CGRect?, content: CGRect?, target: CGRect) -> SnapResult {
            var r = SnapResult(
                success: false, failure: .toolbarNoRoom, appName: owner.name, bundleId: owner.bundleID,
                pid: pid, title: title, windowID: nil, requestedFrame: frame, previousFrame: previous,
                achievedFrame: achieved, message: SnapResult.message(
                    for: .toolbarNoRoom, appName: name, title: title, requested: frame, achieved: content,
                    axErrorCode: nil, placement: .toolbarAbove, toolbarPt: toolbar.heightPt, moveDownPt: down),
                placement: .toolbarAbove, profileID: profile.id, toolbar: toolbar, windowTargetFrame: target,
                achievedContentFrame: content, frameMoveDownPt: down, targetName: name)
            if achieved != nil { r.windowRef = AXWindowRef(w) }
            return r
        }

        var target: CGRect
        switch ToolbarAbovePlan.make(frame: frame, toolbarPt: toolbar.heightPt, topLimitY: topLimit) {
        case let .noRoom(down):
            return noRoom(down, achieved: nil, content: nil,
                          target: ToolbarAboveGeometry.windowFrame(for: frame, toolbarPt: toolbar.heightPt))
        case let .place(window):
            target = window
        }

        func apply(_ rect: CGRect) -> AXError { w.isResizable ? w.setFrame(rect) : w.setPosition(rect.origin) }
        var err = apply(target)
        var achieved = w.frame
        if let a = achieved {
            // The strip can change with the window size, and a reading beats the fallback. An empty
            // tree read during a resize ("no title bar") never replaces a real reading.
            let after = measureToolbar(w, profile: profile, fineTunePt: fineTunePt)
            if after.isMeasured || toolbar.source == .fallback { toolbar = after }
            if let fix = ToolbarAbovePlan.correction(frame: frame, achievedWindow: a, toolbarPt: toolbar.heightPt,
                                                     tolerance: tolerancePt) {
                if let topLimit, let down = ToolbarAboveGeometry.roomNeeded(frame: frame, toolbarPt: toolbar.heightPt,
                                                                           topLimitY: topLimit) {
                    return noRoom(down, achieved: a,
                                  content: ToolbarAboveGeometry.contentFrame(ofWindow: a, toolbarPt: toolbar.heightPt),
                                  target: fix)
                }
                target = fix
                let second = apply(fix)
                if err == .success { err = second }
                achieved = w.frame
            }
        }

        let content = achieved.map { ToolbarAboveGeometry.contentFrame(ofWindow: $0, toolbarPt: toolbar.heightPt) }
        let id = windowID ?? WindowList.match(pid: pid, frames: [achieved, previous].compactMap { $0 }, title: title,
                                              in: WindowList.onScreen())?.id
        var failure = SnapResult.evaluate(requested: frame, achieved: content, tolerance: tolerancePt)
        let axCode: Int32? = err == .success ? nil : err.rawValue
        if failure != nil, let previous, let achieved, previous.isClose(to: achieved, tolerance: 0.5), err != .success {
            failure = .axError
        }
        var result = SnapResult(
            success: failure == nil, failure: failure, appName: owner.name, bundleId: owner.bundleID,
            pid: pid, title: title, windowID: id, requestedFrame: frame, previousFrame: previous,
            achievedFrame: achieved, axErrorCode: axCode,
            message: SnapResult.message(for: failure, appName: name, title: title, requested: frame,
                                        achieved: content, axErrorCode: axCode, placement: .toolbarAbove,
                                        toolbarPt: toolbar.heightPt),
            placement: .toolbarAbove, profileID: profile.id, toolbar: toolbar, windowTargetFrame: target,
            achievedContentFrame: content, targetName: name)
        result.windowRef = AXWindowRef(w)
        return result
    }

    /// The toolbar strip of `w` now: from its Accessibility tree, else the profile's fallback.
    private func measureToolbar(_ w: AXWindow, profile: SnapProfile, fineTunePt: CGFloat) -> ToolbarMeasurement {
        guard let frame = w.frame else {
            return ToolbarMeasurement(detectedPt: profile.fallbackToolbarHeightPt, source: .fallback, fineTunePt: fineTunePt)
        }
        let elements = w.elementSnapshot(timeout: min(messagingTimeout, 0.25))
        return ToolbarDetection.measure(window: frame, elements: elements, fallbackPt: profile.fallbackToolbarHeightPt,
                                        fineTunePt: fineTunePt)
    }

    /// The snapped window's frame now (global CG points), or nil when it is gone.
    public func currentFrame(of result: SnapResult) -> CGRect? {
        result.windowRef?.axWindow.frame
    }

    /// Puts the window back where it was before the snap.
    @discardableResult
    public func restore(_ result: SnapResult) -> Bool {
        guard isTrusted, let previous = result.previousFrame, let w = result.windowRef?.axWindow else { return false }
        return w.setFrame(previous) == .success
    }
}

/// Maps the snap candidates (front to back) to an Accessibility window. Plain logic: the
/// Accessibility calls come in through `lookUp`.
///
/// Rules:
/// - The first standard window found wins. A dialog or sheet counts only when its app has no
///   standard window further back.
/// - Another app's window never replaces a window of the user's app that cannot be moved. When
///   the lookup of a regular app's window (or a window with a built-in profile, such as a
///   Parallels Coherence window) fails, only that app's other windows are tried. If none works,
///   the snap fails for that window: `.noWindow` when the app does not list it, `.axError`
///   (`cannotComplete`, "did not respond") when the app does not answer. Nothing else moves.
/// - A window of a helper that is not a regular app (no Dock icon, no profile) that cannot be
///   looked up is passed over: it is not a window the user works in.
/// - An app that does not answer is asked once only.
enum SnapLookup {
    /// What one lookup of a window-list window found.
    enum Outcome<Window> {
        case found(Window, isStandard: Bool)
        /// The app answered, but lists no window at that place.
        case notListed
        /// The app did not answer in time (`AXError.cannotComplete`).
        case noAnswer(AXError)
    }

    enum Choice<Window> {
        case window(SnapCandidate, Window)
        /// Nothing can be moved. `candidate` is the window the snap was meant for.
        case failed(SnapCandidate, SnapFailure, axErrorCode: Int32?)
    }

    /// - Parameters:
    ///   - candidates: `SnapTargets.candidates`, best first. Not empty.
    ///   - maxLookups: most lookups in one snap.
    ///   - inBudget: false once the time for lookups is used up.
    static func choose<Window>(_ candidates: [SnapCandidate], maxLookups: Int, inBudget: () -> Bool,
                               lookUp: (SnapCandidate) -> Outcome<Window>) -> Choice<Window> {
        var dialog: (SnapCandidate, Window)?
        var failure: (candidate: SnapCandidate, failure: SnapFailure, code: Int32?, isUsersApp: Bool)?
        /// After a dialog, or after a window of the user's app failed: only this app's windows.
        var onlyPID: pid_t?
        var unresponsive: Set<pid_t> = []
        var lookups = 0

        func note(_ c: SnapCandidate, _ f: SnapFailure, _ code: Int32?, _ usersApp: Bool) {
            if failure == nil || (usersApp && failure?.isUsersApp == false) { failure = (c, f, code, usersApp) }
        }

        scan: for c in candidates {
            if let onlyPID, c.owner.pid != onlyPID { continue }
            if unresponsive.contains(c.owner.pid) { continue }
            guard lookups < maxLookups, inBudget() else { break }
            lookups += 1
            let usersApp = isUsersApp(c.owner)
            switch lookUp(c) {
            case let .found(w, isStandard):
                if isStandard { return .window(c, w) }
                if dialog == nil {
                    dialog = (c, w)
                    onlyPID = c.owner.pid
                }
            case .notListed:
                note(c, .noWindow, nil, usersApp)
                if usersApp, onlyPID == nil { onlyPID = c.owner.pid }
            case let .noAnswer(err):
                note(c, .axError, err.rawValue, usersApp)
                if usersApp { break scan }
                unresponsive.insert(c.owner.pid)
            }
        }
        if let dialog { return .window(dialog.0, dialog.1) }
        if let failure { return .failed(failure.candidate, failure.failure, axErrorCode: failure.code) }
        return .failed(candidates[0], .noWindow, axErrorCode: nil)
    }

    /// An app the user works in: a regular app, or a process with a built-in profile (the
    /// Parallels Coherence helper owns the Windows app windows but is not a regular app).
    static func isUsersApp(_ owner: WindowOwner) -> Bool {
        owner.isRegular || SnapProfile.all.contains { $0.matches(owner.bundleID) }
    }
}

enum SnapGeometry {
    /// Origin that centers a rect of `size` inside `frame`, rounded down to whole points.
    static func centeredOrigin(size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(x: (frame.minX + (frame.width - size.width) / 2).rounded(.down),
                y: (frame.minY + (frame.height - size.height) / 2).rounded(.down))
    }
}

extension CGFloat {
    /// "1504" or "1504.5".
    var ptNumber: String {
        let r = (self * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", Double(r))
    }
}

extension CGSize {
    /// "1504×846 pt".
    var ptString: String { "\(width.ptNumber)×\(height.ptNumber) pt" }
}

extension CGRect {
    /// "x,y,w,h" in points, for event data.
    var eventString: String { [minX, minY, width, height].map(\.ptNumber).joined(separator: ",") }
}
