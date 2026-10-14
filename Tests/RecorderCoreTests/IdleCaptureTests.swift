import Testing
@testable import RecorderCore

/// Decision 2: the camera and the idle mics are open only while something shows the camera or a
/// take runs, and close a short debounce (1.5 s) after none applies, after Stop too.
@Suite struct IdleCaptureDemandTests {
    let s: UInt64 = 1_000_000_000

    @Test func whatWantsTheCamera() {
        #expect(IdleCaptureDemand.wanted(cameraWindowShown: true, menuPreviewShown: false, takeActive: false))
        #expect(IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: true, takeActive: false))
        #expect(IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: true))
        // The menu closed (or open with Live preview off), the window hidden, nothing records.
        #expect(!IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: false))
        #expect(IdleCaptureDemand.defaultCloseDelayNs >= s && IdleCaptureDemand.defaultCloseDelayNs <= 2 * s)
    }

    @Test func opensAtOnceAndClosesAfterTheDebounce() {
        var demand = IdleCaptureDemand()
        #expect(demand.update(wanted: false, nowNs: 0) == .init(open: false))
        #expect(demand.update(wanted: true, nowNs: 10 * s) == .init(open: true))
        // ⌃⌥⌘C hides the window: still open for 1.5 s, then released.
        #expect(demand.update(wanted: false, nowNs: 20 * s) == .init(open: true, recheckAtNs: 20 * s + 1_500_000_000))
        #expect(demand.update(wanted: false, nowNs: 21 * s) == .init(open: true, recheckAtNs: 20 * s + 1_500_000_000))
        #expect(demand.isOpen && demand.unwantedSinceNs == 20 * s)
        #expect(demand.update(wanted: false, nowNs: 20 * s + 1_500_000_000) == .init(open: false))
        #expect(!demand.isOpen && demand.unwantedSinceNs == nil)
        #expect(demand.update(wanted: false, nowNs: 30 * s) == .init(open: false))
    }

    /// The menu closes and opens again within the debounce: the camera stays open (no reopen).
    @Test func aQuickCloseAndOpenKeepsTheCamera() {
        var demand = IdleCaptureDemand()
        _ = demand.update(wanted: true, nowNs: 0)
        #expect(demand.update(wanted: false, nowNs: 1 * s).open)
        #expect(demand.update(wanted: true, nowNs: 2 * s) == .init(open: true))
        // The debounce counts from the moment nothing wants the camera any more.
        #expect(demand.update(wanted: false, nowNs: 3 * s) == .init(open: true, recheckAtNs: 3 * s + 1_500_000_000))
    }

    /// After Stop with nothing showing the camera: the take wanted it until Stop, then it closes.
    @Test func afterStopItCloses() {
        var demand = IdleCaptureDemand()
        let take = IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: true)
        _ = demand.update(wanted: take, nowNs: 0)
        _ = demand.update(wanted: take, nowNs: 60 * s)  // Stop: saving ends here.
        let idle = IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: false)
        #expect(demand.update(wanted: idle, nowNs: 60 * s + 1).open)
        #expect(!demand.update(wanted: idle, nowNs: 62 * s).open)
    }

    @Test func closeNowSkipsTheDebounce() {
        var demand = IdleCaptureDemand(closeDelayNs: 2 * s)
        _ = demand.update(wanted: true, nowNs: 0)
        demand.closeNow()
        #expect(demand.update(wanted: false, nowNs: 1) == .init(open: false))
    }
}
