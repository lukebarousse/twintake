// Portions adapted from Rectangle (https://github.com/rxhanson/Rectangle), Copyright (c) 2019-2026 Ryan Hanson, MIT License.

import CoreGraphics
import Foundation

/// One entry of `CGWindowListCopyWindowInfo`. Bounds are global CG points (top-left origin).
///
/// Without Screen Recording permission macOS leaves out `name`, but id, owner and bounds are
/// always there. Reading the list never prompts.
public struct WindowListEntry: Sendable, Hashable {
    public var id: CGWindowID
    public var pid: pid_t
    public var ownerName: String?
    public var name: String?
    /// Window layer. 0 is the normal layer for app windows.
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public var isOnScreen: Bool

    public init(id: CGWindowID, pid: pid_t, ownerName: String? = nil, name: String? = nil, layer: Int = 0,
                bounds: CGRect, alpha: Double = 1, isOnScreen: Bool = true) {
        self.id = id; self.pid = pid; self.ownerName = ownerName; self.name = name; self.layer = layer
        self.bounds = bounds; self.alpha = alpha; self.isOnScreen = isOnScreen
    }

    /// A normal, visible app window (not a menu, the Dock, a shield or an invisible helper).
    public var isNormalWindow: Bool { layer == 0 && alpha > 0 && bounds.width > 1 && bounds.height > 1 }
}

public enum WindowList {
    /// On-screen windows, front to back.
    public static func onScreen() -> [WindowListEntry] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return parse(info as? [[String: Any]] ?? [])
    }

    /// Current entry for one window, or nil when it is gone.
    public static func entry(for id: CGWindowID) -> WindowListEntry? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id)
        return parse(info as? [[String: Any]] ?? []).first { $0.id == id }
    }

    static func parse(_ raw: [[String: Any]]) -> [WindowListEntry] {
        raw.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return WindowListEntry(
                id: id, pid: pid,
                ownerName: d[kCGWindowOwnerName as String] as? String,
                name: d[kCGWindowName as String] as? String,
                layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true)
        }
    }

    /// Finds the window server id of an AX window: same pid, bounds within `tolerance` of one of
    /// `frames` (tried in order), front-most first. Falls back to the title, then to the only
    /// normal window of that pid. The window server can lag the AX change by a frame, so pass
    /// both the new and the old frame.
    public static func match(pid: pid_t, frames: [CGRect], title: String? = nil, tolerance: CGFloat = 2,
                             in entries: [WindowListEntry]) -> WindowListEntry? {
        let own = entries.filter { $0.pid == pid && $0.isNormalWindow }
        for frame in frames where !frame.isNull {
            if let hit = own.first(where: { $0.bounds.isClose(to: frame, tolerance: tolerance) }) { return hit }
        }
        if let title, !title.isEmpty, let hit = own.first(where: { $0.name == title }) { return hit }
        return own.count == 1 ? own[0] : nil
    }
}

extension CGRect {
    /// True when every edge is within `tolerance` points of `other`.
    func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
