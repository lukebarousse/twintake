import AppKit
import CoreGraphics
import Foundation
import Testing
import WindowTools
@testable import RecorderApp
@testable import RecorderCore

/// The pinned apps: Luke records with Dia and the Parallels "Windows 11" VM, and pins both with
/// "+". Nothing is built in.
@Suite struct PinnedAppsTests {
    static let dia = PinnedApp(bundleID: "company.thebrowser.dia", name: "Dia")
    static let windows = PinnedApp(bundleID: "com.parallels.winapp.4b8e9a2b2cf949cda272e0db0cfe4c34.VM", name: "Windows 11")
    static let finder = PinnedApp(bundleID: "com.apple.finder", name: "Finder")

    static func apps(_ count: Int) -> [PinnedApp] {
        (1...count).map { PinnedApp(bundleID: "com.example.app\($0)", name: "App \($0)") }
    }

    @Test func addingKeepsTheOrderAndRefusesRepeats() {
        var list: [PinnedApp] = []
        var outcome: PinnedApps.AddOutcome
        (list, outcome) = PinnedApps.adding(Self.dia, to: list)
        #expect(outcome == .added)
        (list, outcome) = PinnedApps.adding(Self.windows, to: list)
        #expect(outcome == .added)
        #expect(list == [Self.dia, Self.windows])
        // Dia again (another name it had then): no second button.
        (list, outcome) = PinnedApps.adding(PinnedApp(bundleID: Self.dia.bundleID, name: "Dia Browser"), to: list)
        #expect(outcome == .alreadyPinned)
        #expect(list == [Self.dia, Self.windows])

        let full = Self.apps(PinnedApps.maxCount)
        let refused = PinnedApps.adding(Self.dia, to: full)
        #expect(refused.outcome == .full)
        #expect(refused.list == full)
    }

    @Test func removingAndMoving() {
        let list = [Self.dia, Self.windows, Self.finder]
        #expect(PinnedApps.removing(Self.windows.bundleID, from: list) == [Self.dia, Self.finder])
        #expect(PinnedApps.removing("not.pinned", from: list) == list)
        #expect(PinnedApps.moving(Self.finder.bundleID, by: -1, in: list) == [Self.dia, Self.finder, Self.windows])
        #expect(PinnedApps.moving(Self.dia.bundleID, by: 1, in: list) == [Self.windows, Self.dia, Self.finder])
        // Past either end: it stops at the end.
        #expect(PinnedApps.moving(Self.dia.bundleID, by: -1, in: list) == list)
        #expect(PinnedApps.moving(Self.finder.bundleID, by: 5, in: list) == list)
        #expect(PinnedApps.moving(Self.dia.bundleID, by: 9, in: list) == [Self.windows, Self.finder, Self.dia])
        #expect(PinnedApps.moving("not.pinned", by: 1, in: list) == list)
    }

    /// Up to five buttons; from the sixth on, the apps go into the overflow menu.
    @Test func moreThanFiveGoIntoTheOverflowMenu() {
        #expect(PinnedApps.maxVisible == 5)
        let none = PinnedApps.split([])
        #expect(none.visible.isEmpty && none.overflow.isEmpty)
        let five = PinnedApps.split(Self.apps(5))
        #expect(five.visible.count == 5 && five.overflow.isEmpty)
        let six = PinnedApps.split(Self.apps(6))
        #expect(six.visible == Array(Self.apps(6).prefix(5)))
        #expect(six.overflow.map(\.name) == ["App 6"])
        let twelve = PinnedApps.split(Self.apps(12))
        #expect(twelve.visible.count == 5 && twelve.overflow.count == 7)
        #expect(twelve.overflow.first?.name == "App 6")
        #expect(PinnedApps.split(Self.apps(3), maxVisible: 2).overflow.map(\.name) == ["App 3"])
    }

    @Test func storageRoundTripsAndDropsBadEntries() throws {
        let list = [Self.dia, Self.windows]
        let data = try #require(PinnedApps.encode(list))
        #expect(PinnedApps.decode(data) == list)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"bundle_id\":\"company.thebrowser.dia\""))

        #expect(PinnedApps.decode(nil) == [])
        #expect(PinnedApps.decode(Data("garbage".utf8)) == [])
        let messy = Data("""
            [{"bundle_id": " company.thebrowser.dia ", "name": "Dia"}, {"bundle_id": "", "name": "Nothing"},
             {"bundle_id": "company.thebrowser.dia", "name": "Again"}, {"bundle_id": "com.example.tool", "name": ""}]
            """.utf8)
        #expect(PinnedApps.decode(messy) == [Self.dia, PinnedApp(bundleID: "com.example.tool", name: "tool")])
        #expect(PinnedApps.cleaned(Self.apps(20)).count == PinnedApps.maxCount)
    }

    @Test func shortNamesFitTheBar() {
        #expect(Self.dia.shortName == "Dia")
        #expect(Self.windows.shortName == "Windows 11")
        #expect(PinnedApp(bundleID: "com.parallels.desktop.console", name: "Parallels Desktop").shortName == "Parallels…")
        #expect(PinnedApp.shortName("Final Cut Pro", maxLength: 10) == "Final Cut…")
        #expect(PinnedApp.shortName("  Dia  ", maxLength: 10) == "Dia")
    }

    /// "+" pins the app that was in front before the click (the bar never takes the focus).
    @Test func plusPinsTheFrontApp() {
        let own: Set<String> = ["com.lukebarousse.twintake"]
        let dia = WindowOwner(pid: 18346, bundleID: "company.thebrowser.dia", name: "Dia")
        let dockHelper = WindowOwner(pid: 32589, bundleID: Self.windows.bundleID, name: "Windows 11")
        let coherence = WindowOwner(pid: 32591, bundleID: Self.windows.bundleID, name: "Windows 11 Coherence Helper",
                                    isRegular: false)
        let twinTake = WindowOwner(pid: 57880, bundleID: "com.lukebarousse.twintake", name: "TwinTake", isRegular: false)
        let menuBarApp = WindowOwner(pid: 700, bundleID: "com.elgato.ControlCenter", name: "Control Center", isRegular: false)
        let dock = WindowOwner(pid: 600, bundleID: "com.apple.dock", name: "Dock", isRegular: false)
        let spotlight = WindowOwner(pid: 601, bundleID: "com.apple.Spotlight", name: "Spotlight")

        #expect(PinnedApps.pinCandidate(front: dia, recent: [], excludedBundleIDs: own) == Self.dia)
        // The VM in front: the menu bar shows its Dock helper, "Windows 11".
        #expect(PinnedApps.pinCandidate(front: dockHelper, recent: [dia], excludedBundleIDs: own) == Self.windows)
        // TwinTake in front (after its folder picker): the app the user worked in before it.
        #expect(PinnedApps.pinCandidate(front: twinTake, recent: [coherence, dock, dia], excludedBundleIDs: own) == Self.dia)
        #expect(PinnedApps.pinCandidate(front: nil, recent: [spotlight, dockHelper], excludedBundleIDs: own) == Self.windows)
        // A menu bar app or system UI in front: nothing, the bar says to click the app first.
        #expect(PinnedApps.pinCandidate(front: menuBarApp, recent: [dia], excludedBundleIDs: own) == nil)
        #expect(PinnedApps.pinCandidate(front: spotlight, recent: [dia], excludedBundleIDs: own) == nil)
        #expect(PinnedApps.pinCandidate(front: twinTake, recent: [], excludedBundleIDs: own) == nil)
        #expect(PinnedApps.pinCandidate(front: WindowOwner(pid: 9, bundleID: nil, name: "Tool"), recent: [],
                                        excludedBundleIDs: own) == nil)
    }

    /// The button of the front app lights up. Parallels Desktop and its helpers light the
    /// "Windows 11" button.
    @Test func theFrontAppLightsItsButton() {
        let list = [Self.dia, Self.windows]
        #expect(PinnedApps.app(for: "company.thebrowser.dia", in: list) == Self.dia)
        #expect(PinnedApps.app(for: Self.windows.bundleID, in: list) == Self.windows)
        #expect(PinnedApps.app(for: "com.parallels.desktop.console", in: list) == Self.windows)
        #expect(PinnedApps.app(for: "com.apple.Safari", in: list) == nil)
        #expect(PinnedApps.app(for: nil, in: list) == nil)
    }
}

/// The Record button's states and the Flag marker.
@Suite struct ControlBarRulesTests {
    typealias Rules = ControlBarRules

    @Test func recordButtonStates() {
        let idle = Rules.recordButton(state: .idle, blocker: nil, attention: nil, elapsed: "0:00")
        #expect(idle.title == "Record" && idle.tone == .neutral && idle.enabled)
        #expect(idle.help == "Start recording (⌃⌥⌘R).")

        let blocked = Rules.recordButton(state: .idle, blocker: "No camera is connected.", attention: nil, elapsed: "0:00")
        #expect(blocked.title == "Record" && blocked.tone == .problem && blocked.enabled)
        #expect(blocked.help.hasPrefix("Not ready: No camera is connected."))

        let warned = Rules.recordButton(state: .idle, blocker: nil, attention: "Rode not detected.", elapsed: "0:00")
        #expect(warned.tone == .problem && warned.help.hasPrefix("Rode not detected."))

        let starting = Rules.recordButton(state: .preparing, blocker: nil, attention: nil, elapsed: "0:00")
        #expect(starting.title == "Starting…" && starting.enabled && starting.tone == .neutral)

        let recording = Rules.recordButton(state: .recording, blocker: nil, attention: nil, elapsed: "12:34")
        #expect(recording.title == "Stop 12:34" && recording.tone == .recording && recording.symbol == "stop.fill")
        let problem = Rules.recordButton(state: .recording, blocker: nil, attention: "Camera: no picture.", elapsed: "1:02:03")
        #expect(problem.title == "Stop 1:02:03" && problem.tone == .problem)
        // A blocker never shows while recording (only idle has one).
        #expect(Rules.recordButton(state: .recording, blocker: "x", attention: nil, elapsed: "0:01").tone == .recording)

        let saving = Rules.recordButton(state: .stopping, blocker: nil, attention: nil, elapsed: "12:35")
        #expect(saving.title == "Saving…" && !saving.enabled)

        let failed = Rules.recordButton(state: .error("Start failed."), blocker: nil, attention: nil, elapsed: "0:00")
        #expect(failed.title == "Record" && failed.tone == .problem && failed.enabled && failed.help.hasPrefix("Start failed."))
    }

    /// A Flag is a `marker` of kind `flag` with `lookback_s`: something in that time before it
    /// was wrong.
    @Test func flagMarkerData() {
        #expect(Rules.flagMarkerData(elapsedS: 123.44, lookbackS: 180)
            == ["kind": "flag", "elapsed_s": "123.4", "lookback_s": "180"])
        #expect(Rules.flagMarkerData(elapsedS: -0.2, lookbackS: 60)["elapsed_s"] == "0.0")
        #expect(Rules.flagKind == "flag")
    }

    /// The flag goes into events.jsonl like any marker and reads back.
    @Test func aFlagReadsBackFromEventsJsonl() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flag-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try EventLog(url: url)
        log.append(.marker, Rules.flagMarkerData(elapsedS: 95, lookbackS: 180), at: 42)
        log.close()
        let events = try EventLog.read(url)
        #expect(events.count == 1)
        #expect(events.first?.type == .marker)
        #expect(events.first?.tHostNs == 42)
        #expect(events.first?.data == ["kind": "flag", "elapsed_s": "95.0", "lookback_s": "180"])
        let line = try String(contentsOf: url, encoding: .utf8)
        #expect(line.contains("\"type\":\"marker\""))
    }

    /// A flag's `elapsed_s` counts from the files' shared start (`started_at_host_ns`), not from
    /// the end of Start (which also waited for the camera info).
    @Test func flagElapsedCountsFromTheFilesStart() {
        let start: UInt64 = 5_000_000_000
        #expect(Rules.secondsSince(start, nowNs: start + 754_250_000_000) == 754.25)
        #expect(Rules.secondsSince(start, nowNs: start) == 0)
        // The start is still ahead (the scheduled start margin): negative, and the marker clamps at 0.
        #expect(Rules.secondsSince(start, nowNs: start - 500_000_000) == -0.5)
        #expect(Rules.flagMarkerData(elapsedS: Rules.secondsSince(start, nowNs: start - 1), lookbackS: 180)["elapsed_s"] == "0.0")
    }

    @Test func flagTexts() {
        #expect(Rules.lookbackLabel(180) == "3 min")
        #expect(Rules.lookbackLabel(30) == "30 s")
        #expect(Rules.lookbackLabel(90) == "90 s")
        #expect(Rules.lookbackChoices.contains(RecorderSettings.defaultFlagLookbackSeconds))
        #expect(Rules.flagFlash(lookbackS: 180) == "Flagged · last 3 min")
        #expect(Rules.flagNotice(elapsed: "12:34", lookbackS: 120) == "Flagged at 12:34: something in the last 2 min was wrong.")
        #expect(Rules.flagSummary(1) == "1 flag" && Rules.flagSummary(0) == "0 flags" && Rules.flagSummary(3) == "3 flags")
        #expect(Rules.flagHelp(recording: true, lookbackS: 180) == "Flag a mistake in the last 3 min (⌃⌥⌘B).")
        #expect(Rules.flagHelp(recording: false, lookbackS: 180).hasSuffix("Works while recording."))
    }
}

@MainActor
@Suite struct ControlBarSettingsTests {
    func makeDefaults() -> (UserDefaults, String) {
        let name = "ControlBarTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        #expect(s.showControlBar)
        #expect(s.pinnedApps.isEmpty)
        #expect(s.flagLookbackSeconds == 180)
        #expect(s.controlBarPlaces.isEmpty && s.controlBarLastDisplay == nil)
    }

    @Test func pinnedAppsPlacesAndLookbackPersist() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        s.showControlBar = false
        s.pinnedApps = [PinnedAppsTests.dia, PinnedAppsTests.windows]
        s.flagLookbackSeconds = 120
        s.controlBarPlaces = ["LAPTOP": CGPoint(x: 756, y: 916), "PHL": CGPoint(x: 960.5, y: 1030)]
        s.controlBarLastDisplay = "PHL"

        let back = RecorderSettings(defaults: defaults)
        #expect(!back.showControlBar)
        #expect(back.pinnedApps == [PinnedAppsTests.dia, PinnedAppsTests.windows])
        #expect(back.flagLookbackSeconds == 120)
        #expect(back.controlBarPlaces == ["LAPTOP": CGPoint(x: 756, y: 916), "PHL": CGPoint(x: 960.5, y: 1030)])
        #expect(back.controlBarLastDisplay == "PHL")

        // A reorder and a removal are saved too.
        back.pinnedApps = PinnedApps.moving(PinnedAppsTests.windows.bundleID, by: -1, in: back.pinnedApps)
        #expect(RecorderSettings(defaults: defaults).pinnedApps == [PinnedAppsTests.windows, PinnedAppsTests.dia])
        back.pinnedApps = PinnedApps.removing(PinnedAppsTests.dia.bundleID, from: back.pinnedApps)
        #expect(RecorderSettings(defaults: defaults).pinnedApps == [PinnedAppsTests.windows])
    }

    @Test func badStoredValuesFallBack() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(5, forKey: RecorderSettings.Key.flagLookback)
        defaults.set(Data("not json".utf8), forKey: RecorderSettings.Key.pinnedApps)
        defaults.set(["LAPTOP": [1.0], "PHL": [10.0, 20.0]], forKey: RecorderSettings.Key.controlBarPlaces)
        let s = RecorderSettings(defaults: defaults)
        #expect(s.flagLookbackSeconds == RecorderSettings.flagLookbackRange.lowerBound)
        #expect(s.pinnedApps.isEmpty)
        #expect(s.controlBarPlaces == ["PHL": CGPoint(x: 10, y: 20)])
        #expect(RecorderSettings.clampedFlagLookback(99_999) == RecorderSettings.flagLookbackRange.upperBound)
    }
}

/// The bar's window settings, on a real (never shown) panel.
@Suite struct ControlBarPanelTests {
    /// Never in screen.mov, never the focus, never dimmed, under other apps' menus and popovers,
    /// under TwinTake's own menu.
    @MainActor @Test func theBarNeverTakesTheFocusAndIsNeverRecorded() {
        let panel = ControlBarPanel.make(size: CGSize(width: 300, height: ControlBarView.height))
        defer { panel.close() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.sharingType == .none)
        #expect(panel.level == FrameOverlay.aboveOverlayLevel)
        #expect(panel.level.rawValue < NSWindow.Level.statusBar.rawValue)
        let menu = MenuPanel.make(size: CGSize(width: 10, height: 10))
        defer { menu.close() }
        #expect(panel.level.rawValue < menu.level.rawValue)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
        #expect(!panel.isVisible)
    }

    /// A flash sits right of the Record button when it fits there; a longer one reaches over the
    /// Record button (never past its left edge), so it is not cut.
    @Test func theFlashTakesTheRoomItsTextNeeds() {
        // Two pinned apps: room beside Record.
        let wide = ControlBarView.flashSpan(recordMinX: 18, recordMaxX: 130, barWidth: 400, textWidth: 107)
        #expect(wide.x == 136 && wide.width == 258)
        // No pinned app (227 pt): 73 pt beside Record is too little for 134 pt of text.
        let short = ControlBarView.flashSpan(recordMinX: 18, recordMaxX: 130, barWidth: 227, textWidth: 134)
        #expect(short.x < 130 && short.x >= 18)
        #expect(short.width - 2 * FlashView.textInset >= 134)
        #expect(short.x + short.width == 221)
        // Longer than the whole bar: from the Record button's left edge to the right.
        let long = ControlBarView.flashSpan(recordMinX: 18, recordMaxX: 130, barWidth: 227, textWidth: 400)
        #expect(long.x == 18 && long.width == 203)
    }

    /// Every flash text fits on the shortest bar (no pinned app), measured with the bar's font.
    @MainActor @Test func everyFlashFitsTheShortestBar() {
        let bar = ControlBarView(coordinator: nil)
        let width = bar.fittingContentSize.width
        let texts = ["Click an app first, then +", "Flagged · last 10 min", "Flag works while recording",
                     "Not ready: open the menu", "Start failed: open the menu", "12 apps pinned: remove one",
                     "Windows 11 not in front", "Windows 11 not snapped", "Opening Windows 11…",
                     "Windows 11 is not installed", "Windows 11: no window", "Accessibility is off"]
        for text in texts {
            let flash = FlashView()
            flash.show(text, fill: .black)
            let span = ControlBarView.flashSpan(recordMinX: 18, recordMaxX: 18 + ControlBarView.recordWidth,
                                                barWidth: width, textWidth: flash.textWidth)
            #expect(span.width - 2 * FlashView.textInset >= flash.textWidth, "\(text): \(flash.textWidth) pt in \(span.width) pt")
        }
    }

    /// Every button takes the first click in a window of an app that is not active.
    @MainActor @Test func barButtonsTakeTheFirstClick() {
        let button = BarButton()
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(button.refusesFirstResponder)
        let bar = ControlBarView(coordinator: nil)
        #expect(bar.acceptsFirstMouse(for: nil))
        // Record, the separators, "+", Flag: the bar is never narrower than this.
        #expect(bar.fittingContentSize.height == ControlBarView.height)
        #expect(bar.fittingContentSize.width > ControlBarView.recordWidth)
    }
}
