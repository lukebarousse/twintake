import CoreGraphics
import Foundation
import Testing
import RecorderCore
@testable import WindowTools

@Suite struct DockOverlapTests {
    let laptop = CGSize(width: 1512, height: 982)
    let bottomFrame = CGRect(x: 4, y: 136, width: 1504, height: 846)
    let topFrame = CGRect(x: 4, y: 37, width: 1504, height: 846)

    @Test func prefsFromRawDefaults() {
        #expect(DockEdge(orientation: nil) == .bottom)
        #expect(DockEdge(orientation: "bottom") == .bottom)
        #expect(DockEdge(orientation: "left") == .left)
        #expect(DockEdge(orientation: "RIGHT") == .right)
        #expect(DockEdge(orientation: "top") == .bottom)
        // Luke's Mac: autohide = 1, no orientation key.
        #expect(DockPrefs(orientation: nil, autohide: NSNumber(value: 1)) == DockPrefs(edge: .bottom, autohide: true))
        #expect(DockPrefs(orientation: "left", autohide: true) == DockPrefs(edge: .left, autohide: true))
        #expect(DockPrefs(orientation: nil, autohide: "1").autohide)
        #expect(!DockPrefs(orientation: nil, autohide: nil).autohide)
        #expect(!DockPrefs(orientation: nil, autohide: NSNumber(value: 0)).autohide)
    }

    @Test func thicknessFromScreenAndVisibleFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(DockOverlap.dockThickness(edge: .bottom, screenFrame: screen,
                                          visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875)) == 70)
        #expect(DockOverlap.dockThickness(edge: .left, screenFrame: screen,
                                          visibleFrame: CGRect(x: 64, y: 0, width: 1448, height: 945)) == 64)
        #expect(DockOverlap.dockThickness(edge: .right, screenFrame: screen,
                                          visibleFrame: CGRect(x: 0, y: 0, width: 1448, height: 945)) == 64)
        // The Dock is on another display: only the menu bar is cut off.
        #expect(DockOverlap.dockThickness(edge: .bottom, screenFrame: screen,
                                          visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)) == 0)
        // A display left or below the main one has negative AppKit origins.
        let below = CGRect(x: 2328, y: -982, width: 1512, height: 982)
        #expect(DockOverlap.dockThickness(edge: .bottom, screenFrame: below,
                                          visibleFrame: CGRect(x: 2328, y: -912, width: 1512, height: 880)) == 70)
    }

    @Test func visibleDockCoversTheBottomFrame() {
        let o = DockOverlap.check(frameLocal: bottomFrame, displaySizePt: laptop, dockThicknessPt: 70,
                                  prefs: DockPrefs(edge: .bottom, autohide: false))
        #expect(o.overlapsFrame)
        #expect(o.dockRectLocal == CGRect(x: 0, y: 912, width: 1512, height: 70))
        #expect(o.coveredRectLocal == CGRect(x: 4, y: 912, width: 1504, height: 70))
        #expect(o.coveredPt == 70)
        #expect(o.warning(frameAtBottom: true) == "The Dock covers the bottom 70 pt of the frame, so it is in the recording. Turn on “Automatically hide and show the Dock” (⌥⌘D), or put the frame at the top.")
    }

    /// "Put the frame at the top" only when the frame is at the bottom: a top frame under a large
    /// Dock, or the whole display, cannot move up.
    @Test func theTopFixIsOfferedOnlyForTheBottomFrame() {
        let huge = DockOverlap.check(frameLocal: topFrame, displaySizePt: laptop, dockThicknessPt: 120,
                                     prefs: DockPrefs(edge: .bottom, autohide: false))
        #expect(huge.warning(frameAtBottom: false) == "The Dock covers the bottom 21 pt of the frame, so it is in the recording. Turn on “Automatically hide and show the Dock” (⌥⌘D).")
    }

    /// A bottom Dock on another display can move to this one: its thickness there counts.
    @Test func aBottomDockOnAnotherDisplayCanMoveHere() {
        #expect(DockOverlap.effectiveThickness(edge: .bottom, onDisplay: 70, otherDisplays: [0]) == (70, false))
        #expect(DockOverlap.effectiveThickness(edge: .bottom, onDisplay: 0, otherDisplays: [0, 64]) == (64, true))
        #expect(DockOverlap.effectiveThickness(edge: .bottom, onDisplay: 0, otherDisplays: [0]) == (0, false))
        #expect(DockOverlap.effectiveThickness(edge: .left, onDisplay: 0, otherDisplays: [64]) == (0, false))
        var o = DockOverlap.check(frameLocal: bottomFrame, displaySizePt: laptop, dockThicknessPt: 64,
                                  prefs: DockPrefs(edge: .bottom, autohide: false))
        o.fromOtherDisplay = true
        #expect(o.warning(frameAtBottom: true)?.hasPrefix("The Dock can move to this display and cover the bottom 64 pt of the frame") == true)
    }

    @Test func autoHiddenDockNeverWarns() {
        // Luke's setup: autohide on, Dock at the bottom.
        let o = DockOverlap.check(frameLocal: bottomFrame, displaySizePt: laptop, dockThicknessPt: 70,
                                  prefs: DockPrefs(edge: .bottom, autohide: true))
        #expect(!o.overlapsFrame)
        #expect(o.dockThicknessPt == 0)
        #expect(o.dockRectLocal == nil)
        #expect(o.warning(frameAtBottom: true) == nil)
        #expect(o.coveredPt == 0)
    }

    @Test func topFrameClearsANormalDockButNotAHugeOne() {
        let prefs = DockPrefs(edge: .bottom, autohide: false)
        #expect(!DockOverlap.check(frameLocal: topFrame, displaySizePt: laptop, dockThicknessPt: 70, prefs: prefs).overlapsFrame)
        let huge = DockOverlap.check(frameLocal: topFrame, displaySizePt: laptop, dockThicknessPt: 120, prefs: prefs)
        #expect(huge.overlapsFrame)
        #expect(huge.coveredPt == 21) // frame ends at 883, Dock starts at 862
    }

    @Test func sideDockCoversTheLaptopFrameEdge() {
        // The laptop frame leaves only 4 pt on each side.
        let left = DockOverlap.check(frameLocal: bottomFrame, displaySizePt: laptop, dockThicknessPt: 64,
                                     prefs: DockPrefs(edge: .left, autohide: false))
        #expect(left.coveredRectLocal == CGRect(x: 4, y: 136, width: 60, height: 846))
        #expect(left.coveredPt == 60)
        #expect(left.warning(frameAtBottom: true) == "The Dock covers 60 pt on the left side of the frame, so it is in the recording. Turn on “Automatically hide and show the Dock” (⌥⌘D).")
        let right = DockOverlap.check(frameLocal: topFrame, displaySizePt: laptop, dockThicknessPt: 64,
                                      prefs: DockPrefs(edge: .right, autohide: false))
        #expect(right.coveredRectLocal == CGRect(x: 1448, y: 37, width: 60, height: 846))
    }

    @Test func dockOnAnotherDisplayDoesNotCount() {
        let o = DockOverlap.check(frameLocal: bottomFrame, displaySizePt: laptop, dockThicknessPt: 0,
                                  prefs: DockPrefs(edge: .bottom, autohide: false))
        #expect(!o.overlapsFrame)
        #expect(o.dockRectLocal == nil)
    }

    @Test func wholeDisplayFrameMeetsAVisibleDock() {
        let monitor = CGSize(width: 1920, height: 1080)
        let o = DockOverlap.check(frameLocal: CGRect(origin: .zero, size: monitor), displaySizePt: monitor,
                                  dockThicknessPt: 30, prefs: DockPrefs())
        #expect(o.coveredRectLocal == CGRect(x: 0, y: 1050, width: 1920, height: 30))
    }

    /// Reads the real Dock preferences and screens. Reads only; no prompt.
    @MainActor @Test func liveCheckIsConsistent() {
        let prefs = DockPrefs.current()
        for d in Displays.all() {
            let o = DockOverlap.current(frameLocal: d.frameRect(for: .laptop16x9, anchor: .bottom), on: d)
            #expect(o.prefs == prefs)
            #expect(o.dockThicknessPt >= 0 && o.dockThicknessPt < d.sizePt.height)
            if prefs.autohide { #expect(!o.overlapsFrame) }
        }
    }
}
