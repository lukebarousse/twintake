import Foundation

/// When the camera and the idle mics should be open: only while something shows the camera (the
/// camera window, or the open menu with Live preview on) or a take prepares or records. When none
/// applies any more, they close `closeDelayNs` later: a short debounce, so a menu that closes and
/// opens again, or a window hidden and shown again (⌃⌥⌘C twice), does not reopen the camera.
/// Never longer, so macOS shows no green camera indicator while nothing shows the camera.
///
/// Plain data: the app feeds it every change of the inputs and asks again at `recheckAtNs`.
///
///     var demand = IdleCaptureDemand()
///     let d = demand.update(wanted: IdleCaptureDemand.wanted(cameraWindowShown: ..., menuPreviewShown: ...,
///                                                           takeActive: ...), nowNs: HostClock.nowNs())
///     // d.open: open (or keep) the preview with its meters and the idle Mac mic; else close them.
///     // d.recheckAtNs: call update again then (the end of the debounce).
public struct IdleCaptureDemand: Sendable, Equatable {
    /// The debounce: 1.5 s.
    public static let defaultCloseDelayNs: UInt64 = 1_500_000_000

    /// What the app should do now.
    public struct Decision: Sendable, Equatable {
        /// The camera and the idle mics should be open now.
        public var open: Bool
        /// Ask again at this host time (the end of the debounce); nil when nothing is pending.
        public var recheckAtNs: UInt64?

        public init(open: Bool, recheckAtNs: UInt64? = nil) {
            self.open = open
            self.recheckAtNs = recheckAtNs
        }
    }

    public let closeDelayNs: UInt64
    /// The camera and the idle mics should be open (wanted now, or within the debounce).
    public private(set) var isOpen = false
    /// When nothing wanted them any more, while the debounce runs; nil otherwise.
    public private(set) var unwantedSinceNs: UInt64?

    public init(closeDelayNs: UInt64 = IdleCaptureDemand.defaultCloseDelayNs) {
        self.closeDelayNs = closeDelayNs
    }

    /// Something shows the camera or records with it.
    /// - Parameters:
    ///   - cameraWindowShown: the camera window is on screen (also with the menu closed).
    ///   - menuPreviewShown: the menu is open and its Live preview is on.
    ///   - takeActive: a take prepares, records or saves.
    public static func wanted(cameraWindowShown: Bool, menuPreviewShown: Bool, takeActive: Bool) -> Bool {
        cameraWindowShown || menuPreviewShown || takeActive
    }

    /// Takes the current wish at host time `nowNs`. Wanted: open at once. Not wanted: still open
    /// until `closeDelayNs` after the moment nothing wanted them any more, then closed.
    public mutating func update(wanted: Bool, nowNs: UInt64) -> Decision {
        if wanted {
            isOpen = true
            unwantedSinceNs = nil
            return Decision(open: true)
        }
        guard isOpen else { return Decision(open: false) }
        let since = unwantedSinceNs ?? nowNs
        unwantedSinceNs = since
        let closeAt = since &+ closeDelayNs
        if nowNs < closeAt { return Decision(open: true, recheckAtNs: closeAt) }
        isOpen = false
        unwantedSinceNs = nil
        return Decision(open: false)
    }

    /// Closes at once, without the debounce (Quit, or a camera that must be released now).
    public mutating func closeNow() {
        isOpen = false
        unwantedSinceNs = nil
    }
}
