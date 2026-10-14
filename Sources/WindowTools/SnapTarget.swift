import AppKit
import CoreGraphics

/// The process that owns a window, as the snap target search sees it. Plain data.
public struct WindowOwner: Sendable, Hashable {
    public var pid: pid_t
    public var bundleID: String?
    /// `NSRunningApplication.localizedName`, e.g. "Parallels Desktop".
    public var name: String?
    /// True for an app with a Dock icon and a menu bar (`.regular`). Menu bar apps and helpers,
    /// such as the Parallels Coherence helper, are false.
    public var isRegular: Bool

    public init(pid: pid_t, bundleID: String? = nil, name: String? = nil, isRegular: Bool = true) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.isRegular = isRegular
    }

    /// The running app behind `pid`, or nil for a process that is not an app (the window server).
    @MainActor
    public static func running(pid: pid_t) -> WindowOwner? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return WindowOwner(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName,
                           isRegular: app.activationPolicy == .regular)
    }
}

/// An on-screen window that Snap can move, with its owner.
public struct SnapCandidate: Sendable, Hashable {
    public var window: WindowListEntry
    public var owner: WindowOwner

    public init(window: WindowListEntry, owner: WindowOwner) {
        self.window = window; self.owner = owner
    }

    /// The name the menu and the notices use: the app name, or for a Parallels window the name
    /// of the VM or Windows app, e.g. "Windows 11 (Parallels)".
    public var targetName: String {
        if SnapProfile.parallelsDesktop.matches(owner.bundleID) {
            let title = window.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? SnapProfile.parallelsDesktop.appName : "\(title) (Parallels)"
        }
        return owner.name ?? window.ownerName ?? "The app"
    }
}

/// How the first candidate was chosen.
public enum SnapPick: String, Sendable, Hashable {
    /// The front-most window on the recording display.
    case front
    /// A window of the app the user activated last. Another window was in front of it in the
    /// window order, but no window in front of it covers it, so the order says nothing.
    case recentApp = "recent_app"
    /// The front window of a pinned app (a control bar app button), `SnapTargetFinder.findApp`.
    case pinnedApp = "pinned_app"
}

/// The windows Snap may move, best first. From the window list only: no Accessibility calls.
public struct SnapTargets: Sendable, Equatable {
    /// Windows on the recording display, best first. Empty when nothing can be snapped.
    public var candidates: [SnapCandidate]
    public var pick: SnapPick
    /// The recording display's name, e.g. "Built-in Retina Display". Nil when the frame is on
    /// no known display (then windows on every display count).
    public var displayName: String?
    /// Windows of other apps that were left out because they are on another display.
    public var otherDisplayWindows: Int
    /// For a pinned app (`SnapTargetFinder.findApp`): how many of the first candidates are the
    /// app's own windows. The others belong to other processes of the same app, for example the
    /// Parallels Control Center or another VM's window for a VM's button.
    public var ownWindows: Int

    public init(candidates: [SnapCandidate], pick: SnapPick = .front, displayName: String?, otherDisplayWindows: Int = 0,
                ownWindows: Int = 0) {
        self.candidates = candidates; self.pick = pick; self.displayName = displayName
        self.otherDisplayWindows = otherDisplayWindows; self.ownWindows = ownWindows
    }

    public var first: SnapCandidate? { candidates.first }

    /// Longest target name on the Snap button before it is cut with "…".
    static let maxButtonNameLength = 28

    /// The menu's Snap button: "Snap: Windows 11 (Parallels)", "Snap: Safari", or "Snap: no window".
    public var buttonTitle: String {
        guard let first else { return "Snap: no window" }
        let name = first.targetName
        guard name.count > Self.maxButtonNameLength else { return "Snap: \(name)" }
        return "Snap: \(name.prefix(Self.maxButtonNameLength - 1))…"
    }

    /// Why nothing can be snapped (the notice after a click, the button's help).
    public var noTargetMessage: String {
        SnapResult.message(for: displayName == nil ? .noTargetApp : .noWindowOnDisplay, appName: nil, title: nil,
                           requested: .zero, achieved: nil, axErrorCode: nil, displayName: displayName)
    }
}

/// Picks the window Snap moves: the window the user is looking at on the recording display.
///
/// Rules, in order:
/// 1. Only normal app windows: on screen, layer 0, visible (alpha > 0), at least
///    `minWidthPt` x `minHeightPt`. Menus, the Dock, the menu bar, overlays and floating panels
///    are on other layers.
/// 2. Never the recorder's own windows (its pid and bundle id), never system UI
///    (`systemBundleIDs`), never a desktop: a window that covers a whole display and belongs
///    to Finder or to an app that is not regular.
/// 3. Only windows on the recording display (the display that holds the largest part of the
///    window). A window on another display never moves.
/// 4. Front to back (the window list order is the stacking order).
/// 5. Tie-breaker: the app the user activated last (`AppActivationHistory`). Its front window
///    goes first only when no window in front of it covers it, for example two windows side by
///    side. A Parallels helper counts as Parallels Desktop. When that app's front-most window
///    (on any display) is on another display, the user activated it there, so the window order
///    on the recording display stays. An app with no window is passed over.
public enum SnapTargetFinder {
    public static let minWidthPt: CGFloat = 100
    public static let minHeightPt: CGFloat = 60
    /// A window in front covers another one when they overlap by at least this part of the
    /// window behind.
    static let coverShare: CGFloat = 0.05
    static let finderBundleID = "com.apple.finder"

    /// System processes that can own layer 0 windows but are never what the user records.
    public static let systemBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.wallpaper.agent", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.systemuiserver",
        "com.apple.screencaptureui", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
        "com.apple.TextInputMenuAgent", "com.apple.TextInputSwitcher",
    ]

    /// - Parameters:
    ///   - entries: `WindowList.onScreen()`, front to back.
    ///   - owners: the owner of a pid; nil for a process that is not an app.
    ///   - display: the recording display. Nil: windows on every display count.
    ///   - displays: every connected display, to find the display of each window.
    ///   - excludedPIDs: the recorder's own pid.
    ///   - excludedBundleIDs: the recorder's own bundle id.
    ///   - recentPIDs: apps the user activated, most recent first (`AppActivationHistory`).
    public static func find(in entries: [WindowListEntry], owners: (pid_t) -> WindowOwner?, display: DisplayInfo?,
                            displays: [DisplayInfo], excludedPIDs: Set<pid_t>, excludedBundleIDs: Set<String>,
                            recentPIDs: [pid_t]) -> SnapTargets {
        var cache: [pid_t: WindowOwner?] = [:]
        func owner(_ pid: pid_t) -> WindowOwner? {
            if let known = cache[pid] { return known }
            let found = owners(pid)
            cache[pid] = found
            return found
        }
        // Every window that could be snapped on some display, front to back, for the tie-breaker.
        let everywhere = scan(entries, owner: owner, display: display, displays: displays, excludedPIDs: excludedPIDs,
                              excludedBundleIDs: excludedBundleIDs)
        var here = everywhere.filter(\.isHere).map(\.candidate)
        let elsewhere = everywhere.count - here.count

        var pick = SnapPick.front
        for pid in recentPIDs where !excludedPIDs.contains(pid) {
            let recent = owner(pid)
            // An app that shows no window says nothing: ask the app activated before it.
            guard let front = everywhere.first(where: { isSameApp($0.candidate.owner, pid: pid, recent: recent) })
            else { continue }
            // The user activated it through a window on another display (a click raises only that
            // window). The window order on the recording display decides.
            guard front.isHere, let i = here.firstIndex(of: front.candidate) else { break }
            if i > 0, !here[..<i].contains(where: { covers($0.window.bounds, here[i].window.bounds) }) {
                here.insert(here.remove(at: i), at: 0)
                pick = .recentApp
            }
            break
        }
        return SnapTargets(candidates: here, pick: pick, displayName: display?.name, otherDisplayWindows: elsewhere)
    }

    /// The windows a pinned app's button (on the control bar) snaps, best first:
    /// 1. The app's own windows: windows of its own process, and for a Parallels VM's Dock
    ///    helper ("Windows 11", which owns no window) the window of another Parallels process
    ///    whose title is the pinned name (Parallels Desktop owns the VM window "Windows 11").
    ///    On the recording display first, then on other displays, front to back. So a window on
    ///    another display moves into the frame only when the app has none on the recording display.
    /// 2. Then, as a fallback, the windows of the app's other processes (`isSameApp(bundleID:as:)`:
    ///    the Parallels Control Center, another VM's window), the same way. Window titles need
    ///    the Screen Recording permission; without them, every Parallels window is in this group,
    ///    front to back.
    /// The same filters as `find` apply (normal app windows only, never the recorder's own,
    /// system UI or a desktop).
    /// - Parameters:
    ///   - bundleID: the pinned app's bundle id.
    ///   - appName: the pinned app's name, e.g. "Windows 11": the title of its VM window.
    public static func findApp(bundleID: String, appName: String? = nil, in entries: [WindowListEntry],
                               owners: (pid_t) -> WindowOwner?, display: DisplayInfo?, displays: [DisplayInfo],
                               excludedPIDs: Set<pid_t>, excludedBundleIDs: Set<String>) -> SnapTargets {
        var cache: [pid_t: WindowOwner?] = [:]
        func owner(_ pid: pid_t) -> WindowOwner? {
            if let known = cache[pid] { return known }
            let found = owners(pid)
            cache[pid] = found
            return found
        }
        let windows = scan(entries, owner: owner, display: display, displays: displays, excludedPIDs: excludedPIDs,
                           excludedBundleIDs: excludedBundleIDs)
            .filter { isSameApp(bundleID: $0.candidate.owner.bundleID, as: bundleID) }
        let name = appName.map(normalizedTitle) ?? ""
        func isOwn(_ c: SnapCandidate) -> Bool {
            c.owner.bundleID == bundleID || (!name.isEmpty && c.window.name.map(normalizedTitle) == name)
        }
        let own = windows.filter { isOwn($0.candidate) }
        let related = windows.filter { !isOwn($0.candidate) }
        func ordered(_ group: [(candidate: SnapCandidate, isHere: Bool)]) -> [SnapCandidate] {
            group.filter(\.isHere).map(\.candidate) + group.filter { !$0.isHere }.map(\.candidate)
        }
        return SnapTargets(candidates: ordered(own) + ordered(related), pick: .pinnedApp, displayName: display?.name,
                           otherDisplayWindows: windows.filter { !$0.isHere }.count, ownWindows: own.count)
    }

    /// A window title or app name for comparison: trimmed, case and width insensitive.
    static func normalizedTitle(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// True when a pinned app's button may snap now: the pinned app (`pinnedBundleID`) came
    /// forward after the click. `front` is the front app now, `before` the front app at the click.
    /// - The pinned app itself is in front: yes.
    /// - Another process of the same app (`isSameApp(bundleID:as:)`, e.g. Parallels Desktop for
    ///   the "Windows 11" Dock helper) is in front: yes when the app was not in front at the click.
    ///   When it was (another VM in front, then the "Ubuntu" button), only when the front process
    ///   changed: the old front process says nothing about the activation.
    /// - Any other app: no.
    public static func cameForward(front: WindowOwner?, before: WindowOwner?, pinnedBundleID: String) -> Bool {
        guard let front, let id = front.bundleID else { return false }
        if id == pinnedBundleID { return true }
        guard isSameApp(bundleID: id, as: pinnedBundleID) else { return false }
        guard let before, isSameApp(bundleID: before.bundleID, as: pinnedBundleID) else { return true }
        return front.pid != before.pid
    }

    /// The snappable windows of every app, front to back, each with whether it is on `display`
    /// (always true without a display).
    private static func scan(_ entries: [WindowListEntry], owner: (pid_t) -> WindowOwner?, display: DisplayInfo?,
                             displays: [DisplayInfo], excludedPIDs: Set<pid_t>,
                             excludedBundleIDs: Set<String>) -> [(candidate: SnapCandidate, isHere: Bool)] {
        let allDisplays = display.map { d in displays.contains { $0.id == d.id } ? displays : displays + [d] } ?? displays
        var result: [(candidate: SnapCandidate, isHere: Bool)] = []
        for e in entries where isCandidateWindow(e) && !excludedPIDs.contains(e.pid) {
            guard let o = owner(e.pid) else { continue }
            if let id = o.bundleID, excludedBundleIDs.contains(id) || systemBundleIDs.contains(id) { continue }
            if isDesktop(e.bounds, owner: o, displays: allDisplays) { continue }
            let isHere = display.map { DisplayInfo.display(containing: e.bounds, in: allDisplays)?.id == $0.id } ?? true
            result.append((SnapCandidate(window: e, owner: o), isHere))
        }
        return result
    }

    /// True when a process with `bundleID` belongs to the app `pinnedBundleID` names: the same
    /// bundle id, or two processes of an app with a built-in profile (a Parallels helper such as
    /// the "Windows 11" Dock helper, and Parallels Desktop, which owns the VM window).
    public static func isSameApp(bundleID: String?, as pinnedBundleID: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty, !pinnedBundleID.isEmpty else { return false }
        if bundleID == pinnedBundleID { return true }
        return SnapProfile.all.contains { $0.matches(bundleID) && $0.matches(pinnedBundleID) }
    }

    /// A normal, visible, reasonably sized app window.
    static func isCandidateWindow(_ e: WindowListEntry) -> Bool {
        e.isOnScreen && e.layer == 0 && e.alpha > 0 && e.bounds.width >= minWidthPt && e.bounds.height >= minHeightPt
    }

    /// A window that covers a whole display and belongs to Finder or a non-regular app: a
    /// desktop or an overlay, not a document window. (A full screen app window is kept: the
    /// snap then says to exit full screen.)
    static func isDesktop(_ bounds: CGRect, owner: WindowOwner, displays: [DisplayInfo]) -> Bool {
        guard owner.bundleID == finderBundleID || !owner.isRegular else { return false }
        return displays.contains { bounds.contains($0.boundsGlobal.insetBy(dx: 1, dy: 1)) }
    }

    /// True when `front` overlaps `behind` by at least `coverShare` of `behind`'s area.
    static func covers(_ front: CGRect, _ behind: CGRect) -> Bool {
        let i = front.intersection(behind)
        guard !i.isNull, behind.width > 0, behind.height > 0 else { return false }
        return i.width * i.height >= coverShare * behind.width * behind.height
    }

    /// True when `candidate` belongs to the activated app: the same pid, or both are processes
    /// of an app with a built-in profile (Parallels' Dock helper and Parallels Desktop).
    static func isSameApp(_ candidate: WindowOwner, pid: pid_t, recent: WindowOwner?) -> Bool {
        if candidate.pid == pid { return true }
        guard let recent else { return false }
        return SnapProfile.all.contains { $0.matches(candidate.bundleID) && $0.matches(recent.bundleID) }
    }
}

/// The apps the user activated, most recent first, from
/// `NSWorkspace.didActivateApplicationNotification`. The recorder itself is never listed.
@MainActor
public final class AppActivationHistory {
    public nonisolated static let capacity = 8
    public private(set) var recentPIDs: [pid_t] = []
    private let ownPID: pid_t
    private nonisolated let center: NotificationCenter
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// Starts listening at once. The current frontmost app is the first entry.
    public init(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
        center = NSWorkspace.shared.notificationCenter
        if let front = NSWorkspace.shared.frontmostApplication { noteActivated(front.processIdentifier) }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                      queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.noteActivated(pid) }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    public func noteActivated(_ pid: pid_t) {
        recentPIDs = Self.updated(recentPIDs, activated: pid, ownPID: ownPID)
    }

    /// `list` with `pid` moved to the front, at most `capacity` long. The recorder's own pid is ignored.
    nonisolated static func updated(_ list: [pid_t], activated pid: pid_t, ownPID: pid_t, capacity: Int = capacity) -> [pid_t] {
        guard pid > 0, pid != ownPID else { return list }
        return Array(([pid] + list.filter { $0 != pid }).prefix(capacity))
    }
}
