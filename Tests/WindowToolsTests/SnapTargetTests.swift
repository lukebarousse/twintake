import ApplicationServices
import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

/// Luke's desk on the day of the report, from `CGWindowListCopyWindowInfo` and `lsappinfo`:
/// two Philips monitors side by side, the laptop below the right one.
enum Desk {
    static let monitorMain = DisplayInfo(id: 10, uuid: "PHL-2", name: "PHL 328E1 (2)", isBuiltin: false, isMain: true,
                                         boundsGlobal: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2,
                                         menuBarHeightPt: 30, refreshRate: 60)
    static let monitorRight = DisplayInfo(id: 11, uuid: "PHL-1", name: "PHL 328E1 (1)", isBuiltin: false, isMain: false,
                                          boundsGlobal: CGRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 2,
                                          menuBarHeightPt: 30, refreshRate: 60)
    static let laptop = DisplayInfo(id: 12, uuid: "LAPTOP", name: "Built-in Retina Display", isBuiltin: true, isMain: false,
                                    boundsGlobal: CGRect(x: 2328, y: 1080, width: 1512, height: 982), scale: 2,
                                    menuBarHeightPt: 33, refreshRate: 120, hasNotch: true)
    static let displays = [monitorMain, monitorRight, laptop]

    static let twinTake = WindowOwner(pid: 57880, bundleID: "com.lukebarousse.twintake", name: "TwinTake", isRegular: false)
    static let parallels = WindowOwner(pid: 13004, bundleID: "com.parallels.desktop.console", name: "Parallels Desktop")
    /// "Windows 11 Dock Helper": regular, so the menu bar shows "Windows 11", but it owns no window.
    static let dockHelper = WindowOwner(pid: 32589, bundleID: "com.parallels.winapp.4b8e9a2b2cf949cda272e0db0cfe4c34.VM",
                                        name: "Windows 11")
    static let coherence = WindowOwner(pid: 32591, bundleID: "com.parallels.winapp.4b8e9a2b2cf949cda272e0db0cfe4c34.VM",
                                       name: "Windows 11 Coherence Helper", isRegular: false)
    static let finder = WindowOwner(pid: 1282, bundleID: "com.apple.finder", name: "Finder")
    static let dia = WindowOwner(pid: 18346, bundleID: "company.thebrowser.dia", name: "Dia")
    static let claude = WindowOwner(pid: 70076, bundleID: "com.anthropic.claudefordesktop", name: "Claude")
    static let safari = WindowOwner(pid: 400, bundleID: "com.apple.Safari", name: "Safari")
    static let textEdit = WindowOwner(pid: 401, bundleID: "com.apple.TextEdit", name: "TextEdit")
    static let dock = WindowOwner(pid: 600, bundleID: "com.apple.dock", name: "Dock", isRegular: false)
    static let windowServer: pid_t = 628

    static let owners: [pid_t: WindowOwner] = Dictionary(
        uniqueKeysWithValues: [twinTake, parallels, dockHelper, coherence, finder, dia, claude, safari, textEdit, dock]
            .map { ($0.pid, $0) })

    /// The Parallels VM window on the laptop, as the window list showed it.
    static let vmWindow = WindowListEntry(id: 5032, pid: 13004, ownerName: "Parallels Desktop", name: "Windows 11",
                                          bounds: CGRect(x: 2374, y: 1239, width: 1192, height: 703))
    /// What is always on screen: TwinTake's frame overlay and camera window, the menu bars,
    /// Claude's invisible strip, the desktops and wallpapers (desktop elements are left out by
    /// `WindowList.onScreen()`, but a list with them must not change the answer).
    static let background: [WindowListEntry] = [
        WindowListEntry(id: 6036, pid: 57880, ownerName: "TwinTake", layer: 27, bounds: CGRect(x: 3183, y: 75, width: 642, height: 361)),
        WindowListEntry(id: 4399, pid: windowServer, ownerName: "Window Server", name: "Menubar", layer: 24,
                        bounds: CGRect(x: 2328, y: 1080, width: 1512, height: 33)),
        WindowListEntry(id: 6190, pid: 57880, ownerName: "TwinTake", layer: 19, bounds: CGRect(x: 2328, y: 1113, width: 1512, height: 103)),
        WindowListEntry(id: 1959, pid: 70076, ownerName: "Claude", bounds: CGRect(x: 0, y: -32, width: 1920, height: 32), alpha: 0),
        WindowListEntry(id: 1488, pid: 70076, ownerName: "Claude", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        WindowListEntry(id: 1680, pid: 1282, ownerName: "Finder", layer: -2147483603, bounds: laptop.boundsGlobal),
        WindowListEntry(id: 4401, pid: 1282, ownerName: "Finder", layer: -2147483603, bounds: monitorRight.boundsGlobal),
    ]

    static func find(_ entries: [WindowListEntry], recent: [pid_t] = [], display: DisplayInfo? = laptop) -> SnapTargets {
        SnapTargetFinder.find(in: entries, owners: { owners[$0] }, display: display, displays: displays,
                              excludedPIDs: [twinTake.pid], excludedBundleIDs: [twinTake.bundleID!], recentPIDs: recent)
    }
}

@Suite struct SnapTargetFinderTests {
    /// The report: Parallels in front on the laptop ("Windows 11" in the menu bar), a Finder
    /// window on the other display. Snap must move the VM window, never the Finder window.
    @Test func parallelsInFrontWithAFinderWindowOnAnotherDisplay() {
        let finderWindow = WindowListEntry(id: 7001, pid: 1282, ownerName: "Finder", name: "Downloads",
                                           bounds: CGRect(x: 2200, y: 200, width: 920, height: 560))
        let dia = WindowListEntry(id: 4772, pid: 18346, ownerName: "Dia", bounds: CGRect(x: 2322, y: 1191, width: 1504, height: 846))
        // The Finder window is first in the window list: front-most of all, but on the monitor.
        let entries = [Desk.background[0], finderWindow, Desk.vmWindow, dia] + Desk.background.dropFirst()
        for recent in [[], [Desk.dockHelper.pid, Desk.finder.pid], [Desk.finder.pid]] {
            let t = Desk.find(entries, recent: recent)
            #expect(t.first?.window.id == 5032, "\(recent)")
            #expect(t.first?.owner == Desk.parallels)
            #expect(t.candidates.map(\.window.id) == [5032, 4772])
            #expect(t.pick == .front)
            #expect(t.displayName == "Built-in Retina Display")
            #expect(t.otherDisplayWindows == 2) // the Finder window and Claude's main window
        }
        let t = Desk.find(entries)
        #expect(t.first?.targetName == "Windows 11 (Parallels)")
        #expect(t.buttonTitle == "Snap: Windows 11 (Parallels)")
        #expect(SnapProfile.profile(forBundleID: t.first?.owner.bundleID) == .parallelsDesktop)
    }

    /// After the Finder window closed: Finder is the active app but has only its desktop. The
    /// answer is never Finder.
    @Test func finderDesktopOnly() {
        let dockWindow = WindowListEntry(id: 900, pid: 600, ownerName: "Dock", bounds: Desk.laptop.boundsGlobal)
        let finderFullDisplay = WindowListEntry(id: 901, pid: 1282, ownerName: "Finder", bounds: Desk.laptop.boundsGlobal)
        let t = Desk.find(Desk.background + [dockWindow, finderFullDisplay], recent: [Desk.finder.pid])
        #expect(t.candidates.isEmpty)
        #expect(t.first == nil)
        #expect(t.buttonTitle == "Snap: no window")
        #expect(t.noTargetMessage == "No window to snap on Built-in Retina Display. Move the window you want to record onto it, then snap again.")
        #expect(!t.noTargetMessage.contains("Finder"))
    }

    @Test func twinTakePanelOnTopIsSkipped() {
        let menu = WindowListEntry(id: 1, pid: 57880, ownerName: "TwinTake", bounds: CGRect(x: 3400, y: 1113, width: 420, height: 900))
        let camera = WindowListEntry(id: 2, pid: 57880, ownerName: "TwinTake", layer: 3, bounds: CGRect(x: 3300, y: 1700, width: 480, height: 270))
        // Another process with the recorder's bundle id (a second copy) is skipped as well.
        let copy = WindowListEntry(id: 3, pid: 57881, ownerName: "TwinTake", bounds: CGRect(x: 2400, y: 1200, width: 600, height: 400))
        let safari = WindowListEntry(id: 4, pid: 400, ownerName: "Safari", bounds: CGRect(x: 2332, y: 1216, width: 1504, height: 846))
        var owners = Desk.owners
        owners[57881] = WindowOwner(pid: 57881, bundleID: "com.lukebarousse.twintake", name: "TwinTake", isRegular: false)
        let t = SnapTargetFinder.find(in: [menu, camera, copy, safari], owners: { owners[$0] }, display: Desk.laptop,
                                      displays: Desk.displays, excludedPIDs: [57880],
                                      excludedBundleIDs: ["com.lukebarousse.twintake"], recentPIDs: [57880, 400])
        #expect(t.candidates.map(\.window.id) == [4])
        #expect(t.buttonTitle == "Snap: Safari")
    }

    @Test func windowOnAnotherDisplayOnly() {
        let safari = WindowListEntry(id: 4, pid: 400, ownerName: "Safari", bounds: CGRect(x: 2000, y: 100, width: 1200, height: 800))
        let t = Desk.find([safari] + Desk.background, recent: [Desk.safari.pid])
        #expect(t.candidates.isEmpty)
        #expect(t.otherDisplayWindows == 2)
        #expect(t.noTargetMessage.contains("on Built-in Retina Display"))
        // A window mostly on the monitor, partly on the laptop, belongs to the monitor.
        let straddling = WindowListEntry(id: 5, pid: 400, bounds: CGRect(x: 2400, y: 700, width: 800, height: 500))
        #expect(Desk.find([straddling]).candidates.isEmpty)
        // Mostly on the laptop: it counts.
        let mostlyLaptop = WindowListEntry(id: 6, pid: 400, bounds: CGRect(x: 2400, y: 1000, width: 800, height: 500))
        #expect(Desk.find([mostlyLaptop]).first?.window.id == 6)
        // Without a recording display, every display counts.
        #expect(Desk.find([safari], display: nil).first?.window.id == 4)
        #expect(Desk.find([], display: nil).noTargetMessage == "No app window to snap. Click the window you want to record, then snap again.")
    }

    @Test func oddWindowsAreSkipped() {
        let tiny = WindowListEntry(id: 1, pid: 400, bounds: CGRect(x: 2400, y: 1200, width: 90, height: 40))
        let invisible = WindowListEntry(id: 2, pid: 400, bounds: CGRect(x: 2400, y: 1200, width: 900, height: 400), alpha: 0)
        let floating = WindowListEntry(id: 3, pid: 400, layer: 3, bounds: CGRect(x: 2400, y: 1200, width: 900, height: 400))
        let offScreen = WindowListEntry(id: 4, pid: 400, bounds: CGRect(x: 2400, y: 1200, width: 900, height: 400), isOnScreen: false)
        let noApp = WindowListEntry(id: 5, pid: Desk.windowServer, bounds: CGRect(x: 2400, y: 1200, width: 900, height: 400))
        let real = WindowListEntry(id: 6, pid: 401, bounds: CGRect(x: 2500, y: 1300, width: 700, height: 500))
        #expect(Desk.find([tiny, invisible, floating, offScreen, noApp, real]).candidates.map(\.window.id) == [6])
    }

    /// Coherence windows belong to the Coherence helper (not a regular app). A normal one is a
    /// target and gets the Parallels profile; one that covers the whole display is not.
    @Test func coherenceWindows() {
        let notepad = WindowListEntry(id: 1, pid: 32591, name: "Notepad", bounds: CGRect(x: 2500, y: 1300, width: 800, height: 500))
        let fullDisplay = WindowListEntry(id: 2, pid: 32591, bounds: Desk.laptop.boundsGlobal)
        let t = Desk.find([fullDisplay, notepad])
        #expect(t.candidates.map(\.window.id) == [1])
        #expect(t.first?.targetName == "Notepad (Parallels)")
        #expect(SnapProfile.profile(forBundleID: t.first?.owner.bundleID) == .parallelsDesktop)
        // A full screen window of a regular app stays: the snap then says to exit full screen.
        let fullScreen = WindowListEntry(id: 3, pid: 400, bounds: Desk.laptop.boundsGlobal)
        #expect(Desk.find([fullScreen]).first?.window.id == 3)
        // Without a title the Parallels window is "Parallels Desktop".
        let untitled = WindowListEntry(id: 4, pid: 13004, bounds: Desk.vmWindow.bounds)
        #expect(Desk.find([untitled]).buttonTitle == "Snap: Parallels Desktop")
    }

    @Test func lastActiveAppBreaksATieBetweenWindowsSideBySide() {
        let left = WindowListEntry(id: 1, pid: 401, ownerName: "TextEdit", bounds: CGRect(x: 2332, y: 1216, width: 740, height: 846))
        let right = WindowListEntry(id: 2, pid: 400, ownerName: "Safari", bounds: CGRect(x: 3090, y: 1216, width: 740, height: 846))
        // No history, or TextEdit last: the window order decides.
        #expect(Desk.find([left, right]).first?.window.id == 1)
        #expect(Desk.find([left, right], recent: [401, 400]).pick == .front)
        // Safari last, and nothing covers its window: Safari.
        let t = Desk.find([left, right], recent: [400, 401])
        #expect(t.candidates.map(\.window.id) == [2, 1])
        #expect(t.pick == .recentApp)
        // An app with no window at all is passed over for the next one.
        #expect(Desk.find([left, right], recent: [Desk.finder.pid, 400]).first?.window.id == 2)
        // TextEdit's window covers part of Safari's: the front window wins.
        let covering = WindowListEntry(id: 1, pid: 401, bounds: CGRect(x: 2600, y: 1300, width: 900, height: 600))
        let c = Desk.find([covering, right], recent: [400])
        #expect(c.first?.window.id == 1)
        #expect(c.pick == .front)
    }

    /// Review finding: Luke works in the VM on the laptop, then clicks a Finder window on the
    /// PHL to get a file. The click raises only that window, so a Finder window on the laptop
    /// stays behind the VM window, side by side. The VM window is still the one to snap.
    @Test func anAppActivatedOnAnotherDisplayDoesNotJumpTheQueue() {
        let finderOnPHL = WindowListEntry(id: 7001, pid: 1282, ownerName: "Finder", name: "Downloads",
                                          bounds: CGRect(x: 2200, y: 200, width: 920, height: 560))
        let finderOnLaptop = WindowListEntry(id: 7002, pid: 1282, ownerName: "Finder", name: "Desktop",
                                             bounds: CGRect(x: 3580, y: 1300, width: 250, height: 400))
        #expect(!SnapTargetFinder.covers(Desk.vmWindow.bounds, finderOnLaptop.bounds))
        let entries = [finderOnPHL, Desk.vmWindow, finderOnLaptop] + Desk.background
        for recent in [[Desk.finder.pid, Desk.dockHelper.pid], [Desk.finder.pid]] {
            let t = Desk.find(entries, recent: recent)
            #expect(t.candidates.map(\.window.id) == [5032, 7002], "\(recent)")
            #expect(t.pick == .front, "\(recent)")
            #expect(t.buttonTitle == "Snap: Windows 11 (Parallels)", "\(recent)")
        }
        // An app whose windows are all on the PHL (Dia) is the last one: the laptop's window
        // order decides, and the older activation (Finder) is not used either.
        let diaOnPHL = WindowListEntry(id: 4772, pid: 18346, ownerName: "Dia", bounds: CGRect(x: 1950, y: 40, width: 1500, height: 900))
        let withDia = Desk.find([diaOnPHL] + entries, recent: [Desk.dia.pid, Desk.finder.pid])
        #expect(withDia.first?.window.id == 5032)
        #expect(withDia.pick == .front)
        // Finder activated through its laptop window (its front-most window): the tie-breaker
        // still works for windows side by side on the laptop.
        let clickedOnLaptop = Desk.find([Desk.vmWindow, finderOnLaptop, finderOnPHL], recent: [Desk.finder.pid])
        #expect(clickedOnLaptop.first?.window.id == 7002)
        #expect(clickedOnLaptop.pick == .recentApp)
    }

    @Test func parallelsDockHelperCountsAsParallelsForTheTieBreaker() {
        let textEdit = WindowListEntry(id: 1, pid: 401, bounds: CGRect(x: 2332, y: 1216, width: 300, height: 300))
        let vm = WindowListEntry(id: 5032, pid: 13004, name: "Windows 11", bounds: CGRect(x: 2700, y: 1216, width: 1100, height: 700))
        let t = Desk.find([textEdit, vm], recent: [Desk.dockHelper.pid])
        #expect(t.first?.window.id == 5032)
        #expect(t.pick == .recentApp)
        #expect(SnapTargetFinder.isSameApp(Desk.parallels, pid: Desk.dockHelper.pid, recent: Desk.dockHelper))
        #expect(!SnapTargetFinder.isSameApp(Desk.safari, pid: Desk.dockHelper.pid, recent: Desk.dockHelper))
    }

    @Test func longNamesAreCutOnTheButton() {
        let w = WindowListEntry(id: 1, pid: 13004, name: "Windows 11 on ARM Insider Preview Build", bounds: Desk.vmWindow.bounds)
        let title = Desk.find([w]).buttonTitle
        #expect(title == "Snap: Windows 11 on ARM Insider P…")
        #expect(title.count == "Snap: ".count + SnapTargets.maxButtonNameLength)
    }
}

/// `SnapLookup`: which window the snap moves when Accessibility cannot find one. A fake lookup
/// stands in for the Accessibility calls (the window is its id as text).
@Suite struct SnapLookupTests {
    typealias Outcome = SnapLookup.Outcome<String>

    static let vm = SnapCandidate(window: Desk.vmWindow, owner: Desk.parallels)
    static let controlCenter = SnapCandidate(
        window: WindowListEntry(id: 5040, pid: 13004, name: "Control Center", bounds: CGRect(x: 3300, y: 1600, width: 500, height: 400)),
        owner: Desk.parallels)
    static let dia = SnapCandidate(
        window: WindowListEntry(id: 4772, pid: 18346, ownerName: "Dia", bounds: CGRect(x: 2322, y: 1191, width: 1504, height: 846)),
        owner: Desk.dia)
    static let notepad = SnapCandidate(
        window: WindowListEntry(id: 1, pid: 32591, name: "Notepad", bounds: CGRect(x: 2500, y: 1300, width: 800, height: 500)),
        owner: Desk.coherence)
    static let helperOwner = WindowOwner(pid: 900, bundleID: "com.example.overlay", name: "Overlay", isRegular: false)
    static let helper = SnapCandidate(
        window: WindowListEntry(id: 900, pid: 900, bounds: CGRect(x: 2400, y: 1200, width: 600, height: 400)), owner: helperOwner)
    static let helperSecond = SnapCandidate(
        window: WindowListEntry(id: 901, pid: 900, bounds: CGRect(x: 3000, y: 1500, width: 600, height: 400)), owner: helperOwner)

    /// Runs `choose` with `outcomes` by window id (a window not listed is a standard window),
    /// and returns the result plus the window ids that were looked up, in order.
    static func run(_ candidates: [SnapCandidate], _ outcomes: [CGWindowID: Outcome], maxLookups: Int = 5,
                    inBudget: @escaping () -> Bool = { true }) -> (SnapLookup.Choice<String>, [CGWindowID]) {
        var asked: [CGWindowID] = []
        let choice = SnapLookup.choose(candidates, maxLookups: maxLookups, inBudget: inBudget) { c -> Outcome in
            asked.append(c.window.id)
            return outcomes[c.window.id] ?? .found("\(c.window.id)", isStandard: true)
        }
        return (choice, asked)
    }

    static func moved(_ choice: SnapLookup.Choice<String>) -> String? {
        if case let .window(_, w) = choice { return w }
        return nil
    }

    static func failure(_ choice: SnapLookup.Choice<String>) -> (CGWindowID, SnapFailure, Int32?)? {
        if case let .failed(c, f, code) = choice { return (c.window.id, f, code) }
        return nil
    }

    /// The review's case: Parallels is busy, so the VM window lookup times out. Dia behind it
    /// must not move; the snap says Parallels did not respond.
    @Test func aBusyFrontAppNeverHandsTheSnapToTheNextApp() {
        let (choice, asked) = Self.run([Self.vm, Self.dia], [5032: .noAnswer(.cannotComplete)])
        #expect(Self.moved(choice) == nil)
        #expect(asked == [5032])
        let f = Self.failure(choice)
        #expect(f?.0 == 5032)
        #expect(f?.1 == .axError)
        #expect(f?.2 == AXError.cannotComplete.rawValue)
        let r = SnapResult.failed(.axError, requested: Desk.vmWindow.bounds, owner: Desk.parallels,
                                  targetName: "Windows 11 (Parallels)", axErrorCode: f?.2)
        #expect(r.message == "Windows 11 (Parallels) did not respond. Try again.")
        #expect(r.eventData["failure"] == "ax_error")
    }

    /// The VM window's Accessibility frame does not match (no unique title, little overlap):
    /// still never Dia. Another window of Parallels itself may move.
    @Test func anUnlistedFrontWindowOnlyFallsBackToItsOwnApp() {
        let (choice, asked) = Self.run([Self.vm, Self.dia], [5032: .notListed])
        #expect(Self.moved(choice) == nil)
        #expect(asked == [5032])
        #expect(Self.failure(choice)?.0 == 5032)
        #expect(Self.failure(choice)?.1 == .noWindow)

        let (own, ownAsked) = Self.run([Self.vm, Self.dia, Self.controlCenter], [5032: .notListed])
        #expect(Self.moved(own) == "5040")
        #expect(ownAsked == [5032, 5040])
    }

    /// A Coherence window belongs to a helper that is not a regular app, but it has the Parallels
    /// profile: it is the user's app, so nothing else moves either.
    @Test func aCoherenceWindowCountsAsTheUsersApp() {
        let (choice, asked) = Self.run([Self.notepad, Self.dia], [1: .notListed])
        #expect(Self.moved(choice) == nil)
        #expect(asked == [1])
        #expect(Self.failure(choice)?.1 == .noWindow)
        #expect(SnapLookup.isUsersApp(Desk.coherence))
        #expect(SnapLookup.isUsersApp(Desk.dia))
        #expect(!SnapLookup.isUsersApp(Self.helperOwner))
    }

    /// A helper's window (no Dock icon, no profile) that Accessibility cannot find is passed
    /// over. A helper that does not answer is asked once only.
    @Test func aHelperWindowThatCannotBeFoundIsPassedOver() {
        let (choice, asked) = Self.run([Self.helper, Self.dia], [900: .notListed])
        #expect(Self.moved(choice) == "4772")
        #expect(asked == [900, 4772])

        let (busy, busyAsked) = Self.run([Self.helper, Self.helperSecond, Self.dia], [900: .noAnswer(.cannotComplete)])
        #expect(Self.moved(busy) == "4772")
        #expect(busyAsked == [900, 4772])

        // The helper first, then the user's app fails too: the snap names the user's app.
        let (both, _) = Self.run([Self.helper, Self.dia, Self.vm], [900: .notListed, 4772: .notListed])
        #expect(Self.failure(both)?.0 == 4772)
        #expect(Self.failure(both)?.1 == .noWindow)
    }

    /// A standard window wins over a dialog of the same app; another app's window never does.
    @Test func dialogsAndStandardWindows() {
        let (dialog, asked) = Self.run([Self.vm, Self.dia], [5032: .found("sheet", isStandard: false)])
        #expect(Self.moved(dialog) == "sheet")
        #expect(asked == [5032])
        let (standard, _) = Self.run([Self.vm, Self.dia, Self.controlCenter], [5032: .found("sheet", isStandard: false)])
        #expect(Self.moved(standard) == "5040")
        // The first window found wins.
        #expect(Self.moved(Self.run([Self.vm, Self.dia], [:]).0) == "5032")
    }

    @Test func theLookupLimitsHold() {
        let (none, asked) = Self.run([Self.vm, Self.dia], [:], inBudget: { false })
        #expect(asked.isEmpty)
        #expect(Self.failure(none)?.0 == 5032)
        #expect(Self.failure(none)?.1 == .noWindow)
        var helpers: [SnapCandidate] = []
        var outcomes: [CGWindowID: Outcome] = [:]
        for i in 0..<8 {
            let pid = pid_t(1000 + i)
            let id = CGWindowID(100 + i)
            let window = WindowListEntry(id: id, pid: pid, bounds: CGRect(x: 2400, y: 1200, width: 300, height: 300))
            helpers.append(SnapCandidate(window: window, owner: WindowOwner(pid: pid, bundleID: "com.example.h\(i)", isRegular: false)))
            outcomes[id] = .notListed
        }
        let (limited, limitedAsked) = Self.run(helpers + [Self.dia], outcomes, maxLookups: 5)
        #expect(limitedAsked.count == 5)
        #expect(Self.failure(limited)?.0 == 100)
    }
}

@Suite struct AXWindowMatchTests {
    let target = CGRect(x: 2374, y: 1239, width: 1192, height: 703)

    @Test func theWindowWithTheSameFrame() {
        var reads = 0
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 500, height: 400), target.offsetBy(dx: 1, dy: -1), nil]
        let i = AXWindowMatch.index(for: target, title: "Windows 11", frames: frames) { _ in reads += 1; return nil }
        #expect(i == 1)
        #expect(reads == 0) // one frame matches: no title read
    }

    @Test func titleBreaksATie() {
        let titles = ["Control Center", "Windows 11"]
        #expect(AXWindowMatch.index(for: target, title: "Windows 11", frames: [target, target]) { titles[$0] } == 1)
        #expect(AXWindowMatch.index(for: target, title: "Other", frames: [target, target]) { titles[$0] } == 0)
        #expect(AXWindowMatch.index(for: target, title: nil, frames: [target, target]) { titles[$0] } == 0)
    }

    @Test func titleAloneOnlyWhenItIsUnique() {
        let away = CGRect(x: 10, y: 10, width: 300, height: 200)
        #expect(AXWindowMatch.index(for: target, title: "Windows 11", frames: [away, away]) { ["A", "Windows 11"][$0] } == 1)
        #expect(AXWindowMatch.index(for: target, title: "Doc", frames: [away, away]) { _ in "Doc" } == nil)
        // Last resort: a frame that is a few points off (more than the tolerance) but mostly the same.
        let near = CGRect(x: 2374, y: 1201, width: 1192, height: 741) // 38 pt taller at the top
        #expect(AXWindowMatch.index(for: target, title: nil, frames: [away, near]) { _ in nil } == 1)
        #expect(AXWindowMatch.index(for: target, title: "Doc", frames: [near, near.insetBy(dx: 300, dy: 200)]) { _ in "Doc" } == 0)
        // A much larger or a different window is never taken.
        #expect(AXWindowMatch.index(for: target, title: nil, frames: [target.insetBy(dx: -800, dy: -500)]) { _ in nil } == nil)
        #expect(AXWindowMatch.overlap(target, target) == 1)
        #expect(AXWindowMatch.overlap(target, away) == 0)
        #expect(AXWindowMatch.index(for: target, title: nil, frames: [away]) { _ in nil } == nil)
        #expect(AXWindowMatch.index(for: target, title: "", frames: [away]) { _ in "" } == nil)
        #expect(AXWindowMatch.index(for: target, title: "X", frames: []) { _ in "X" } == nil)
    }
}

@Suite struct ActivationHistoryTests {
    @Test func mostRecentFirstWithoutTheRecorder() {
        var list: [pid_t] = []
        for pid: pid_t in [400, 401, 400, 57880, 13004] {
            list = AppActivationHistory.updated(list, activated: pid, ownPID: 57880)
        }
        #expect(list == [13004, 400, 401])
        #expect(AppActivationHistory.updated(list, activated: 0, ownPID: 57880) == list)
        let long = (1...20).reduce([pid_t]()) { AppActivationHistory.updated($0, activated: pid_t($1), ownPID: 0, capacity: 4) }
        #expect(long == [20, 19, 18, 17])
    }

    @MainActor @Test func historyNeverListsTheRecorder() {
        let h = AppActivationHistory(ownPID: 57880)
        h.noteActivated(57880)
        h.noteActivated(400)
        #expect(h.recentPIDs.first == 400)
        #expect(!h.recentPIDs.contains(57880))
    }
}

@Suite struct SnapTargetMessageTests {
    let frame = CGRect(x: 2332, y: 1216, width: 1504, height: 846)

    @Test func noWindowMessagesNameTheDisplayNotFinder() {
        let none = SnapResult.failed(.noWindowOnDisplay, requested: frame, displayName: "Built-in Retina Display")
        #expect(none.message == "No window to snap on Built-in Retina Display. Move the window you want to record onto it, then snap again.")
        #expect(none.eventData["failure"] == "no_window_on_display")
        #expect(none.eventData["display"] == "Built-in Retina Display")
        let notListed = SnapResult.failed(.noWindow, requested: frame, owner: Desk.dia, targetName: "Dia",
                                          displayName: "Built-in Retina Display")
        #expect(notListed.message == "The Dia window on Built-in Retina Display cannot be moved: Accessibility does not list it.")
    }

    @Test func eventSaysWhichWindowWasChosenAndWhy() {
        let r = SnapResult(success: true, failure: nil, appName: "Parallels Desktop", bundleId: "com.parallels.desktop.console",
                           pid: 13004, title: "Windows 11", windowID: 5032, requestedFrame: frame, previousFrame: nil,
                           achievedFrame: frame, message: "", targetName: "Windows 11 (Parallels)",
                           displayName: "Built-in Retina Display", pick: .front, candidateCount: 2)
        let d = r.eventData
        #expect(d["target"] == "Windows 11 (Parallels)")
        #expect(d["display"] == "Built-in Retina Display")
        #expect(d["picked_by"] == "front")
        #expect(d["candidates"] == "2")
        #expect(d["app"] == "Parallels Desktop")
        // session.json keeps the owner app's name.
        #expect(r.snappedWindow?.appName == "Parallels Desktop")
        let message = SnapResult.message(for: nil, appName: r.targetName, title: r.title, requested: frame, achieved: frame,
                                         axErrorCode: nil, placement: .toolbarAbove, toolbarPt: 38)
        #expect(message == "Snapped Windows 11 (Parallels) to 1504×846 pt, with its toolbar (38 pt) above the frame.")
    }
}
