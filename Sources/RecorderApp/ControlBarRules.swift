import Foundation
import WindowTools

// The control bar's rules over plain data (no window, no running app), so they can be tested:
// the pinned apps (list, storage, overflow, which app "+" pins), the Record button's look, and
// the Flag marker.

/// An app the control bar has a button for. One click brings it forward and snaps its front
/// window into the frame. The user pins apps with "+" on the bar; none is built in.
struct PinnedApp: Codable, Hashable, Identifiable, Sendable {
    /// `NSRunningApplication.bundleIdentifier`, e.g. "company.thebrowser.dia", or the Parallels
    /// VM's Dock helper "com.parallels.winapp.<vm uuid>.VM" (named "Windows 11").
    var bundleID: String
    /// The app's name when it was pinned, e.g. "Dia" or "Windows 11".
    var name: String

    var id: String { bundleID }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
    }

    /// The longest name on a bar button; a longer one is cut with "…".
    static let shortNameLength = 10

    /// The name on the bar, e.g. "Dia", "Windows 11", "Parallels…".
    var shortName: String { Self.shortName(name, maxLength: Self.shortNameLength) }

    static func shortName(_ name: String, maxLength: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength, maxLength > 1 else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The pinned apps, in bar order: add, remove, move, the overflow split and the stored form.
enum PinnedApps {
    /// At most this many apps can be pinned.
    static let maxCount = 12
    /// At most this many apps get a button on the bar; the others go into its overflow menu.
    static let maxVisible = 5

    enum AddOutcome: Equatable, Sendable {
        case added
        case alreadyPinned
        case full
    }

    /// `list` with `app` added at the end, unless it is pinned already or the list is full.
    static func adding(_ app: PinnedApp, to list: [PinnedApp]) -> (list: [PinnedApp], outcome: AddOutcome) {
        if list.contains(where: { $0.bundleID == app.bundleID }) { return (list, .alreadyPinned) }
        guard list.count < maxCount else { return (list, .full) }
        return (cleaned(list + [app]), .added)
    }

    static func removing(_ bundleID: String, from list: [PinnedApp]) -> [PinnedApp] {
        list.filter { $0.bundleID != bundleID }
    }

    /// `list` with the app moved `offset` places (-1: one to the left, toward the Record button).
    /// A move past either end stops at the end.
    static func moving(_ bundleID: String, by offset: Int, in list: [PinnedApp]) -> [PinnedApp] {
        guard let from = list.firstIndex(where: { $0.bundleID == bundleID }) else { return list }
        let to = min(max(from + offset, 0), list.count - 1)
        guard to != from else { return list }
        var moved = list
        moved.insert(moved.remove(at: from), at: to)
        return moved
    }

    /// The apps with a button on the bar, and the ones in its overflow menu: the first
    /// `maxVisible` in bar order get a button.
    static func split(_ list: [PinnedApp], maxVisible: Int = maxVisible) -> (visible: [PinnedApp], overflow: [PinnedApp]) {
        let count = max(0, maxVisible)
        return (Array(list.prefix(count)), Array(list.dropFirst(count)))
    }

    /// Drops entries without a bundle id and repeats (the first wins), names an entry without a
    /// name by its bundle id, and keeps at most `maxCount`.
    static func cleaned(_ list: [PinnedApp]) -> [PinnedApp] {
        var seen = Set<String>()
        var result: [PinnedApp] = []
        for var app in list {
            app.bundleID = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.bundleID.isEmpty, seen.insert(app.bundleID).inserted else { continue }
            app.name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if app.name.isEmpty { app.name = app.bundleID.split(separator: ".").last.map(String.init) ?? app.bundleID }
            result.append(app)
        }
        return Array(result.prefix(maxCount))
    }

    /// The stored form: JSON, `[{"bundle_id": …, "name": …}]`.
    static func encode(_ list: [PinnedApp]) -> Data? {
        try? JSONEncoder().encode(cleaned(list))
    }

    /// The list from `encode`. Empty for missing or unreadable data; bad entries are dropped.
    static func decode(_ data: Data?) -> [PinnedApp] {
        guard let data, let list = try? JSONDecoder().decode([PinnedApp].self, from: data) else { return [] }
        return cleaned(list)
    }

    /// The app "+" pins: the front app. The bar never takes the focus, so the front app is the
    /// one the user worked in before the click. When TwinTake itself is in front (after its
    /// folder picker), the app the user activated last (`recent`, most recent first). Never
    /// TwinTake, an app without a bundle id, system UI (the Dock, Spotlight), or a process that
    /// is not a regular app (no Dock icon: a menu bar app, a helper).
    static func pinCandidate(front: WindowOwner?, recent: [WindowOwner], excludedBundleIDs: Set<String>) -> PinnedApp? {
        func pinnable(_ owner: WindowOwner) -> PinnedApp? {
            guard owner.isRegular, let id = owner.bundleID, !id.isEmpty, !excludedBundleIDs.contains(id),
                  !SnapTargetFinder.systemBundleIDs.contains(id) else { return nil }
            return cleaned([PinnedApp(bundleID: id, name: owner.name ?? "")]).first
        }
        if let front, let app = pinnable(front) { return app }
        // Another app that cannot be pinned is in front (a menu bar app, system UI): nothing, so
        // "+" never pins an app the user did not look at. TwinTake itself: the app before it.
        if let front, let id = front.bundleID, !excludedBundleIDs.contains(id) { return nil }
        return recent.lazy.compactMap(pinnable).first
    }

    /// The pinned app for a running app: its button lights up while it is in front. A Parallels
    /// helper lights the Parallels button (`SnapTargetFinder.isSameApp`).
    static func app(for bundleID: String?, in list: [PinnedApp]) -> PinnedApp? {
        guard let bundleID else { return nil }
        return list.first { $0.bundleID == bundleID } ?? list.first { SnapTargetFinder.isSameApp(bundleID: bundleID, as: $0.bundleID) }
    }
}

/// The control bar's Record button and Flag marker, over plain data.
enum ControlBarRules {
    /// The colors the bar uses: dark (idle), red (recording), orange (a problem), green (done).
    enum Tone: Equatable, Sendable {
        case neutral, recording, problem, good
    }

    /// What the Record button shows.
    struct RecordButton: Equatable, Sendable {
        var title: String
        /// SF Symbol name.
        var symbol: String
        var tone: Tone
        var enabled: Bool
        var help: String
    }

    /// The Record / Stop button for a state:
    /// - idle: "Record"; orange when Start is blocked (`blocker`, why) or something needs
    ///   attention (a camera mic warning, a camera problem), so a click says why.
    /// - preparing: "Starting…"; a click cancels the start.
    /// - recording: "Stop 12:34" in red, orange while a file or the camera mic has a problem.
    /// - stopping: "Saving…", not clickable.
    /// - error: "Record" in orange; the help is the error.
    static func recordButton(state: SessionCoordinator.State, blocker: String?, attention: String?,
                             elapsed: String, shortcut: String = HotKey.startStop.displayString) -> RecordButton {
        switch state {
        case .idle:
            if let blocker {
                return RecordButton(title: "Record", symbol: "exclamationmark.triangle.fill", tone: .problem, enabled: true,
                                    help: "Not ready: \(blocker) Open the menu for the fix.")
            }
            if let attention {
                return RecordButton(title: "Record", symbol: "record.circle.fill", tone: .problem, enabled: true,
                                    help: "\(attention) Start recording (\(shortcut)).")
            }
            return RecordButton(title: "Record", symbol: "record.circle.fill", tone: .neutral, enabled: true,
                                help: "Start recording (\(shortcut)).")
        case let .error(message):
            return RecordButton(title: "Record", symbol: "exclamationmark.triangle.fill", tone: .problem, enabled: true,
                                help: "\(message) Click to start again (\(shortcut)).")
        case .preparing:
            return RecordButton(title: "Starting…", symbol: "hourglass", tone: .neutral, enabled: true,
                                help: "Starting both files. Click to cancel.")
        case .recording:
            return RecordButton(title: "Stop \(elapsed)", symbol: "stop.fill", tone: attention == nil ? .recording : .problem,
                                enabled: true, help: (attention.map { "\($0) " } ?? "") + "Stop recording (\(shortcut)).")
        case .stopping:
            return RecordButton(title: "Saving…", symbol: "hourglass", tone: .neutral, enabled: false,
                                help: "Saving the session.")
        }
    }

    // MARK: - Flag

    /// The `marker` kind of a Flag: something in the last `lookback_s` seconds was wrong.
    static let flagKind = "flag"
    /// The Flag look-back choices in Control Bar settings, in seconds.
    static let lookbackChoices = [30, 60, 120, 180, 300, 600]

    /// "30 s", "1 min", "3 min", "90 s".
    static func lookbackLabel(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// Seconds from host time `startNs` to `nowNs`; negative when `startNs` is still ahead. A
    /// flag's `elapsed_s` counts from the files' shared start (session.json
    /// `started_at_host_ns`), so it is the press's time in camera.mov and screen.mov.
    static func secondsSince(_ startNs: UInt64, nowNs: UInt64) -> Double {
        nowNs >= startNs ? Double(nowNs - startNs) / 1e9 : -Double(startNs - nowNs) / 1e9
    }

    /// `data` of a Flag's `marker` event: `kind` `flag`, `elapsed_s` (since the files began, one
    /// decimal) and `lookback_s`: the mistake is somewhere in the `lookback_s` seconds before the
    /// flag (an editor clamps the start at 0).
    static func flagMarkerData(elapsedS: Double, lookbackS: Int) -> [String: String] {
        ["kind": flagKind, "elapsed_s": String(format: "%.1f", max(0, elapsedS)), "lookback_s": String(lookbackS)]
    }

    /// The bar's short confirmation, e.g. "Flagged · last 3 min".
    static func flagFlash(lookbackS: Int) -> String { "Flagged · last \(lookbackLabel(lookbackS))" }

    /// The menu's notice, e.g. "Flagged at 12:34: something in the last 3 min was wrong."
    static func flagNotice(elapsed: String, lookbackS: Int) -> String {
        "Flagged at \(elapsed): something in the last \(lookbackLabel(lookbackS)) was wrong."
    }

    /// "1 flag", "3 flags".
    static func flagSummary(_ count: Int) -> String { count == 1 ? "1 flag" : "\(count) flags" }

    /// The Flag button's help.
    static func flagHelp(recording: Bool, lookbackS: Int, shortcut: String = HotKey.flag.displayString) -> String {
        let what = "Flag a mistake in the last \(lookbackLabel(lookbackS)) (\(shortcut))."
        return recording ? what : what + " Works while recording."
    }
}

/// A short line the control bar shows for a moment over its app buttons, e.g. "Flagged · last
/// 3 min" or "Opening Dia…". The menu's notice has the long form.
struct ControlBarFlash: Equatable, Sendable {
    /// Tells two flashes with the same text apart, so the newer one gets its full time.
    var id = UUID()
    var text: String
    var tone: ControlBarRules.Tone

    /// How long a flash stays.
    static let lifetime: Duration = .milliseconds(1800)
}
