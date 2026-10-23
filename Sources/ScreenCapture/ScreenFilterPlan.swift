import CoreGraphics
import Foundation
import RecorderCore

/// What the screen stream captures, decided from plain window and app facts (so it is unit
/// tested). `ScreenRecorder` builds the `SCContentFilter` from it.
///
/// - Region capture (`display`): the display without the excluded apps' windows (TwinTake: the
///   camera window, the control bar, the menu, the overlay), except `shownOwnWindowIDs` (the
///   keystroke pill), which stay in. `SCContentFilter(display:excludingApplications:exceptingWindows:)`.
/// - Window capture without own windows (`singleWindow`): the window alone at its own size,
///   scaled to fit. `SCContentFilter(desktopIndependentWindow:)`.
/// - Window capture with own windows (`windows`): the frame region with only the window and the
///   own windows in it, where they are on the display. `SCContentFilter(display:including:)`.
struct ScreenFilterPlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case display, singleWindow, windows }

    /// A window ScreenCaptureKit can capture.
    struct Window: Equatable, Sendable {
        var id: UInt32
        /// The owning process; nil when ScreenCaptureKit names no owner.
        var processID: pid_t?
    }

    /// A running app ScreenCaptureKit lists.
    struct App: Equatable, Sendable {
        var processID: pid_t
        var bundleID: String
    }

    var kind: Kind
    /// The processes whose windows a region capture leaves out.
    var excludedProcessIDs: [pid_t]
    /// `display`: the windows of excluded apps that stay in (the exceptions). `singleWindow`: the
    /// window. `windows`: the window, then the own windows.
    var windowIDs: [UInt32]
    /// The asked-for `shownOwnWindowIDs` that the capture shows. One that ScreenCaptureKit does
    /// not list is left out (the app logs it), and the take records without it.
    var shownOwnWindowIDs: [UInt32]

    /// True when the stream crops the display to the frame (`sourceRect`); false for a single
    /// window drawn at its own size.
    var usesSourceRect: Bool { kind != .singleWindow }

    /// The plan for `config` with the windows and apps ScreenCaptureKit lists now.
    /// - Throws: `ScreenRecorderError.windowNotFound` when the window to record is not listed.
    static func make(config: ScreenRecorderConfig, apps: [App], windows: [Window],
                     ownProcessID: pid_t) throws -> ScreenFilterPlan {
        let excluded = apps.filter {
            ScreenRecorder.isExcluded(bundleID: $0.bundleID, processID: $0.processID,
                                      excludedBundleIDs: config.excludedBundleIDs, ownProcessID: ownProcessID)
        }.map(\.processID)
        var shown: [UInt32] = []
        for id in config.shownOwnWindowIDs where !shown.contains(id) && windows.contains(where: { $0.id == id }) {
            shown.append(id)
        }

        if let windowID = config.windowID {
            guard windows.contains(where: { $0.id == windowID }) else { throw ScreenRecorderError.windowNotFound(windowID) }
            let own = shown.filter { $0 != windowID }
            if own.isEmpty {
                return ScreenFilterPlan(kind: .singleWindow, excludedProcessIDs: excluded, windowIDs: [windowID],
                                        shownOwnWindowIDs: [])
            }
            return ScreenFilterPlan(kind: .windows, excludedProcessIDs: excluded, windowIDs: [windowID] + own,
                                    shownOwnWindowIDs: own)
        }

        // An exception shows a window only when its app is excluded (a window of an app that is
        // not excluded would be hidden by it), so only those are named; the others show anyway.
        let exceptions = shown.filter { id in
            windows.first { $0.id == id }?.processID.map(excluded.contains) ?? false
        }
        return ScreenFilterPlan(kind: .display, excludedProcessIDs: excluded, windowIDs: exceptions,
                                shownOwnWindowIDs: shown)
    }
}
