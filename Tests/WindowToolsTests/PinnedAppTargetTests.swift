import CoreGraphics
import Testing
import RecorderCore
@testable import WindowTools

/// The window a control bar app button snaps (`SnapTargetFinder.findApp`), on Luke's desk
/// (`Desk` in SnapTargetTests): Dia and the Parallels "Windows 11" VM on the laptop.
@Suite struct PinnedAppTargetTests {
    static let dockHelperID = Desk.dockHelper.bundleID!
    /// Dia over the frame on the laptop, in front of the VM window.
    static let diaWindow = WindowListEntry(id: 4772, pid: 18346, ownerName: "Dia", name: "Docs",
                                           bounds: CGRect(x: 2332, y: 1216, width: 1504, height: 846))
    /// A second Dia window, on the monitor.
    static let diaOnMonitor = WindowListEntry(id: 4780, pid: 18346, ownerName: "Dia", name: "Mail",
                                              bounds: CGRect(x: 2100, y: 100, width: 1200, height: 800))

    static func findApp(_ bundleID: String, _ entries: [WindowListEntry], name: String? = nil,
                        display: DisplayInfo? = Desk.laptop, owners: [pid_t: WindowOwner] = Desk.owners) -> SnapTargets {
        SnapTargetFinder.findApp(bundleID: bundleID, appName: name, in: entries, owners: { owners[$0] }, display: display,
                                 displays: Desk.displays, excludedPIDs: [Desk.twinTake.pid],
                                 excludedBundleIDs: [Desk.twinTake.bundleID!])
    }

    /// The Parallels Control Center, a Parallels Desktop window, on the laptop.
    static let controlCenter = WindowListEntry(id: 5040, pid: 13004, ownerName: "Parallels Desktop", name: "Control Center",
                                               bounds: CGRect(x: 2600, y: 1300, width: 800, height: 500))
    /// A second VM: its Dock helper, and its window (Parallels Desktop owns it) on the monitor.
    static let ubuntuHelper = WindowOwner(pid: 32700, bundleID: "com.parallels.winapp.9c1d0e4f7a2b4c3d8e5f6a7b8c9d0e1f.VM",
                                          name: "Ubuntu")
    static let ubuntuWindow = WindowListEntry(id: 5050, pid: 13004, ownerName: "Parallels Desktop", name: "Ubuntu",
                                              bounds: CGRect(x: 2100, y: 100, width: 1200, height: 800))
    static var ownersWithUbuntu: [pid_t: WindowOwner] {
        Desk.owners.merging([ubuntuHelper.pid: ubuntuHelper]) { a, _ in a }
    }

    /// Luke pinned "Windows 11" while the VM was in front: the menu bar showed the Dock helper,
    /// which owns no window. Its button snaps the VM window that Parallels Desktop owns, also with
    /// Dia in front of it.
    @Test func theWindows11ButtonFindsTheParallelsVMWindow() {
        let entries = [Desk.background[0], Self.diaWindow, Desk.vmWindow] + Desk.background.dropFirst()
        let t = Self.findApp(Self.dockHelperID, entries)
        #expect(t.candidates.map(\.window.id) == [5032])
        #expect(t.first?.owner == Desk.parallels)
        #expect(t.first?.targetName == "Windows 11 (Parallels)")
        #expect(t.pick == .pinnedApp)
        #expect(t.displayName == "Built-in Retina Display")
        // Pinned as Parallels Desktop itself: the same window.
        #expect(Self.findApp("com.parallels.desktop.console", entries).candidates.map(\.window.id) == [5032])
    }

    /// The Dia button with the VM in front: Dia's window, never the VM window.
    @Test func theDiaButtonFindsDiaBehindTheVM() {
        let entries = [Desk.background[0], Desk.vmWindow, Self.diaWindow] + Desk.background.dropFirst()
        let t = Self.findApp("company.thebrowser.dia", entries)
        #expect(t.candidates.map(\.window.id) == [4772])
        #expect(t.first?.owner == Desk.dia)
        #expect(t.otherDisplayWindows == 0)
    }

    /// The app's window on the recording display comes first, even when its window on the monitor
    /// is in front; with none on the laptop, the monitor window moves into the frame.
    @Test func aWindowOnTheRecordingDisplayComesFirst() {
        let both = [Self.diaOnMonitor, Desk.vmWindow, Self.diaWindow] + Desk.background
        let t = Self.findApp("company.thebrowser.dia", both)
        #expect(t.candidates.map(\.window.id) == [4772, 4780])
        #expect(t.otherDisplayWindows == 1)

        let monitorOnly = [Self.diaOnMonitor, Desk.vmWindow] + Desk.background
        let m = Self.findApp("company.thebrowser.dia", monitorOnly)
        #expect(m.candidates.map(\.window.id) == [4780])
        #expect(m.pick == .pinnedApp)
    }

    /// An app with no window, TwinTake's own windows, and the desktop are never candidates.
    @Test func nothingElseIsEverTheTarget() {
        let entries = [Desk.background[0], Desk.vmWindow, Self.diaWindow] + Desk.background.dropFirst()
        #expect(Self.findApp("com.apple.Safari", entries).candidates.isEmpty)
        #expect(Self.findApp(Desk.twinTake.bundleID!, entries).candidates.isEmpty)
        // Finder has only its desktop on the laptop.
        #expect(Self.findApp("com.apple.finder", entries).candidates.isEmpty)
        #expect(Self.findApp("", entries).candidates.isEmpty)
    }

    @Test func parallelsProcessesCountAsOneApp() {
        #expect(SnapTargetFinder.isSameApp(bundleID: "com.parallels.desktop.console", as: Self.dockHelperID))
        #expect(SnapTargetFinder.isSameApp(bundleID: Self.dockHelperID, as: "com.parallels.desktop.console"))
        #expect(SnapTargetFinder.isSameApp(bundleID: "company.thebrowser.dia", as: "company.thebrowser.dia"))
        #expect(!SnapTargetFinder.isSameApp(bundleID: "com.apple.Safari", as: "company.thebrowser.dia"))
        // Parallels Toolbox is another product: not grouped with the VM.
        #expect(!SnapTargetFinder.isSameApp(bundleID: "com.parallels.toolbox", as: "com.parallels.desktop.console"))
        #expect(!SnapTargetFinder.isSameApp(bundleID: nil, as: "company.thebrowser.dia"))
        #expect(!SnapTargetFinder.isSameApp(bundleID: "company.thebrowser.dia", as: ""))
    }

    /// The Control Center in front of the VM window: the "Windows 11" button snaps the window
    /// titled "Windows 11", not the front-most Parallels window.
    @Test func theVMWindowComesBeforeTheControlCenter() {
        let entries = [Desk.background[0], Self.controlCenter, Self.diaWindow, Desk.vmWindow] + Desk.background.dropFirst()
        let t = Self.findApp(Self.dockHelperID, entries, name: "Windows 11")
        #expect(t.candidates.map(\.window.id) == [5032, 5040])
        #expect(t.ownWindows == 1)
        #expect(t.first?.targetName == "Windows 11 (Parallels)")
        // The title compare ignores case and spaces at the ends.
        #expect(Self.findApp(Self.dockHelperID, entries, name: " windows 11 ").candidates.first?.window.id == 5032)
        // Without window titles (no Screen Recording permission): every Parallels window, front to back.
        let untitled = entries.map { e -> WindowListEntry in
            var copy = e
            if copy.pid == Desk.parallels.pid { copy.name = nil }
            return copy
        }
        let u = Self.findApp(Self.dockHelperID, untitled, name: "Windows 11")
        #expect(u.candidates.map(\.window.id) == [5040, 5032])
        #expect(u.ownWindows == 0)
    }

    /// Two VMs: with Windows 11 over the frame, the "Ubuntu" button snaps the Ubuntu window from
    /// the monitor, not the Windows 11 window that is in front on the laptop.
    @Test func eachVMButtonFindsItsOwnVM() {
        let entries = [Desk.background[0], Desk.vmWindow, Self.ubuntuWindow, Self.diaWindow] + Desk.background.dropFirst()
        let ubuntu = Self.findApp(Self.ubuntuHelper.bundleID!, entries, name: "Ubuntu", owners: Self.ownersWithUbuntu)
        #expect(ubuntu.candidates.map(\.window.id) == [5050, 5032])
        #expect(ubuntu.ownWindows == 1)
        #expect(ubuntu.otherDisplayWindows == 1)
        let windows = Self.findApp(Self.dockHelperID, entries, name: "Windows 11", owners: Self.ownersWithUbuntu)
        #expect(windows.candidates.map(\.window.id) == [5032, 5050])
        // Dia: every window is its own.
        let dia = Self.findApp("company.thebrowser.dia", [Self.diaOnMonitor, Self.diaWindow] + Desk.background, name: "Dia")
        #expect(dia.candidates.map(\.window.id) == [4772, 4780])
        #expect(dia.ownWindows == 2)
    }

    /// The button snaps only after its app came forward. Another process of the same app counts
    /// (the "Windows 11" activation can leave Parallels Desktop in front), but only when it was
    /// not in front at the click already: with Windows 11 in front, the "Ubuntu" button waits
    /// for a change.
    @Test func thePinnedAppCameForward() {
        let dia = Desk.dia, helper = Desk.dockHelper, console = Desk.parallels
        let pinned = Self.dockHelperID
        #expect(SnapTargetFinder.cameForward(front: helper, before: dia, pinnedBundleID: pinned))
        #expect(SnapTargetFinder.cameForward(front: console, before: dia, pinnedBundleID: pinned))
        #expect(SnapTargetFinder.cameForward(front: helper, before: helper, pinnedBundleID: pinned))
        #expect(SnapTargetFinder.cameForward(front: console, before: nil, pinnedBundleID: pinned))
        #expect(!SnapTargetFinder.cameForward(front: dia, before: dia, pinnedBundleID: pinned))
        #expect(!SnapTargetFinder.cameForward(front: nil, before: dia, pinnedBundleID: pinned))
        #expect(SnapTargetFinder.cameForward(front: dia, before: helper, pinnedBundleID: "company.thebrowser.dia"))
        #expect(!SnapTargetFinder.cameForward(front: helper, before: dia, pinnedBundleID: "company.thebrowser.dia"))

        let ubuntu = Self.ubuntuHelper.bundleID!
        // Windows 11 in front, then "Ubuntu": the old front process says nothing.
        #expect(!SnapTargetFinder.cameForward(front: helper, before: helper, pinnedBundleID: ubuntu))
        #expect(!SnapTargetFinder.cameForward(front: console, before: console, pinnedBundleID: ubuntu))
        #expect(SnapTargetFinder.cameForward(front: console, before: helper, pinnedBundleID: ubuntu))
        #expect(SnapTargetFinder.cameForward(front: Self.ubuntuHelper, before: helper, pinnedBundleID: ubuntu))
    }

    /// The failure when the app has no window, for the notice and events.jsonl.
    @Test func noWindowMessage() {
        #expect(SnapFailure.noAppWindow.rawValue == "no_app_window")
        #expect(SnapPick.pinnedApp.rawValue == "pinned_app")
        let message = SnapResult.message(for: .noAppWindow, appName: "Dia", title: nil, requested: .zero, achieved: nil,
                                         axErrorCode: nil)
        #expect(message == "Dia has no window to snap. Open one, then click its button again.")
    }
}
