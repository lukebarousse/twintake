import AppKit

/// TwinTake: a menu-bar app (LSUIElement) that records the camera and the screen into
/// separate files in one session folder.
///
/// An AppKit entry point, not a SwiftUI `App`: the menu is a status item and a panel that
/// `MenuBarController` places itself (see MenuPanel.swift for why not `MenuBarExtra`).
@main
@MainActor
enum TwinTakeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Info.plist says LSUIElement; this also keeps a bare `swift run` out of the Dock.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Owns the coordinator, so hotkeys and crash recovery run from launch, before the menu ever opens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        menuBar = MenuBarController(coordinator: coordinator)
        coordinator.launch()
    }

    /// Quitting while recording first stops and saves the session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.needsCleanShutdown else { return .terminateNow }
        menuBar?.close()
        Task {
            await coordinator.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Only Quit (⌘Q), as the SwiftUI app had while its menu was open. The menu bar shows the
    /// front app's menus, not these.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "TwinTake")
        appMenu.addItem(withTitle: "Quit TwinTake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }
}
