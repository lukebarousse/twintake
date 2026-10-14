import CoreGraphics
import Foundation

/// One macOS hot corner (System Settings > Desktop & Dock > Hot Corners): `com.apple.dock`
/// `wvous-<corner>-corner` is the action, `wvous-<corner>-modifier` the key that must be held.
///
/// A frame that reaches a display edge puts that edge's corners next to what is recorded: with
/// the bottom frame, the Windows taskbar of a Parallels VM ends in the bottom corners, and the
/// action (Quick Note's thumbnail, Mission Control, the Desktop) shows in screen.mov.
public struct HotCorner: Sendable, Hashable {
    public enum Position: String, Sendable, Hashable, CaseIterable {
        case topLeft = "tl", topRight = "tr", bottomLeft = "bl", bottomRight = "br"

        public var name: String {
            switch self {
            case .topLeft: "top left"
            case .topRight: "top right"
            case .bottomLeft: "bottom left"
            case .bottomRight: "bottom right"
            }
        }

        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    public var position: Position
    /// The `wvous-*-corner` value. 0 and 1 mean no action.
    public var action: Int
    /// The `wvous-*-modifier` value: 0 when no key must be held.
    public var modifier: Int

    public init(position: Position, action: Int, modifier: Int = 0) {
        self.position = position; self.action = action; self.modifier = modifier
    }

    /// What the corner shows, or nil when it shows nothing (no action, Disable Screen Saver).
    public var actionName: String? {
        switch action {
        case 0, 1, 6: nil
        case 2: "Mission Control"
        case 3: "Application Windows"
        case 4: "Desktop"
        case 5: "Start Screen Saver"
        case 7: "Dashboard"
        case 10: "Put Display to Sleep"
        case 11: "Launchpad"
        case 12: "Notification Center"
        case 13: "Lock Screen"
        case 14: "Quick Note"
        default: "a hot corner action"
        }
    }

    /// True when moving the pointer into the corner runs a visible action (no key to hold).
    public var triggersOnPointer: Bool { actionName != nil && modifier == 0 }

    /// Reads the four corners from the `com.apple.dock` preferences. Reads only; no prompt.
    public static func current() -> [HotCorner] {
        let domain = "com.apple.dock" as CFString
        func int(_ key: String) -> Int {
            (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.intValue ?? 0
        }
        return Position.allCases.map {
            HotCorner(position: $0, action: int("wvous-\($0.rawValue)-corner"), modifier: int("wvous-\($0.rawValue)-modifier"))
        }
    }

    /// The corners that run a visible action at an edge the frame reaches: the bottom corners when
    /// the frame ends at the display's bottom edge, the top corners when it starts at the top edge.
    /// - Parameters:
    ///   - frameLocal: the frame in display-local points (top-left origin).
    ///   - displaySizePt: full display size in points.
    public static func atFrameEdge(_ corners: [HotCorner], frameLocal: CGRect, displaySizePt: CGSize) -> [HotCorner] {
        let touchesBottom = frameLocal.maxY >= displaySizePt.height - 1
        let touchesTop = frameLocal.minY <= 1
        return corners.filter { $0.triggersOnPointer && ($0.position.isBottom ? touchesBottom : touchesTop) }
    }

    /// One line for the user, or nil when no corner is listed.
    public static func warning(for corners: [HotCorner]) -> String? {
        guard !corners.isEmpty else { return nil }
        let list = corners.map { "\($0.position.name) (\($0.actionName ?? "action"))" }.joined(separator: ", ")
        let one = corners.count == 1
        return "The \(list) hot corner\(one ? " is" : "s are") at the edge of the frame: the pointer there shows "
            + "\(one ? "it" : "them") in the recording. Turn \(one ? "it" : "them") off in System Settings > "
            + "Desktop & Dock > Hot Corners, or set a key to hold."
    }
}
