import AppKit
import CoreGraphics
import Foundation
import Testing
import WindowTools
@testable import RecorderApp

/// The menu panel's placement (AppKit global points, y up). Luke's desk: the PHL (1920x1080,
/// 25 pt menu bar) is the main display at the origin; the 14" laptop (1512x982, 37 pt menu bar)
/// is below it and to the right.
@Suite struct MenuPanelPlacementTests {
    typealias Place = MenuPanelPlacement

    let phl = MenuPanelPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
    let laptop = MenuPanelPlacement.Screen(frame: CGRect(x: 2328, y: -982, width: 1512, height: 982),
                                           visibleFrame: CGRect(x: 2328, y: -982, width: 1512, height: 945))
    /// The status item in each menu bar (its window spans the menu bar's height).
    let phlItem = CGRect(x: 1500, y: 1055, width: 30, height: 25)
    let laptopItem = CGRect(x: 3300, y: -37, width: 30, height: 37)

    /// Luke's report: Live preview off made the menu shorter, and its top dropped ~100 pt. Every
    /// height gets the same top edge, so only the bottom edge moves.
    @Test func theTopStaysWhenTheContentShrinksOrGrows() {
        let heights: [CGFloat] = [880, 680, 420, 700.5, 900]
        let frames = heights.map { Place.frame(contentHeight: $0, anchor: laptopItem, screen: laptop) }
        for frame in frames {
            #expect(frame.maxY == -37 - Place.gapBelowMenuBar)
            #expect(frame.minX == frames[0].minX)
            #expect(frame.width == Place.width)
        }
        #expect(frames.map(\.height) == [880, 680, 420, 701, 900])
        // Shrinking from Live preview on (880) to off (680) moves the bottom edge up 200 pt.
        #expect(frames[1].minY - frames[0].minY == 200)
    }

    /// Content taller than the room under the menu bar is cut to the screen (it scrolls), with
    /// the same top edge.
    @Test func tallContentStopsAboveTheBottomOfTheScreen() {
        let frame = Place.frame(contentHeight: 1400, anchor: laptopItem, screen: laptop)
        #expect(frame.maxY == -42)
        #expect(frame.minY == laptop.visibleFrame.minY + Place.bottomMargin)
        #expect(frame.height == Place.maxHeight(top: -42, screen: laptop))
        #expect(frame.height == 916)
    }

    /// The limit is the screen the status item is on, not the main screen: the tall PHL allows
    /// more than the laptop, and a menu opened on the laptop after the PHL fits on the laptop.
    @Test func eachDisplayHasItsOwnTopAndLimit() {
        let onPHL = Place.frame(contentHeight: 1400, anchor: phlItem, screen: phl)
        #expect(onPHL.maxY == 1050)
        #expect(onPHL.height == 1026)
        #expect(phl.visibleFrame.contains(onPHL))

        let onLaptop = Place.frame(contentHeight: 1400, anchor: laptopItem, screen: laptop)
        #expect(laptop.visibleFrame.contains(onLaptop))
        #expect(onLaptop.height < onPHL.height)
    }

    @Test func theScreenIsTheOneWithTheStatusItem() {
        #expect(Place.screen(for: laptopItem, in: [phl, laptop]) == laptop)
        #expect(Place.screen(for: phlItem, in: [phl, laptop]) == phl)
        // Its center off every screen: the screen it overlaps most.
        let straddling = CGRect(x: 2310, y: -37, width: 30, height: 37)
        #expect(Place.screen(for: straddling, in: [phl, laptop]) == laptop)
        // No status item, or nowhere near a screen: the first screen (the one with the menu bar).
        #expect(Place.screen(for: nil, in: [phl, laptop]) == phl)
        #expect(Place.screen(for: CGRect(x: -5000, y: 5000, width: 30, height: 25), in: [laptop, phl]) == laptop)
        #expect(Place.screen(for: phlItem, in: []) == nil)
    }

    @Test func thePanelIsCenteredUnderTheItemAndKeptOnScreen() {
        let centered = Place.frame(contentHeight: 600, anchor: laptopItem, screen: laptop)
        #expect(centered.midX == laptopItem.midX)
        // An item near the right edge: the panel stays inside the screen's right side.
        let right = CGRect(x: 3800, y: -37, width: 30, height: 37)
        #expect(Place.frame(contentHeight: 600, anchor: right, screen: laptop).maxX
            == laptop.visibleFrame.maxX - Place.sideMargin)
        // Near the left edge.
        let left = CGRect(x: 2330, y: -37, width: 30, height: 37)
        #expect(Place.frame(contentHeight: 600, anchor: left, screen: laptop).minX
            == laptop.visibleFrame.minX + Place.sideMargin)
        // Half points round to whole points.
        let half = CGRect(x: 3300.5, y: -37, width: 30, height: 37)
        let x = Place.frame(contentHeight: 600, anchor: half, screen: laptop).minX
        #expect(x == x.rounded())
    }

    /// With "Automatically hide the menu bar", the visible frame reaches the top of the screen;
    /// the panel goes under the menu bar that slid in, not over it.
    @Test func anAutoHiddenMenuBarStillHasThePanelUnderIt() {
        let hidden = MenuPanelPlacement.Screen(frame: laptop.frame, visibleFrame: laptop.frame)
        let frame = Place.frame(contentHeight: 600, anchor: laptopItem, screen: hidden)
        #expect(frame.maxY == laptopItem.minY - Place.gapBelowMenuBar)
    }

    /// Without a status item window (not on screen yet): under the menu bar, at the right.
    @Test func withoutAStatusItemThePanelGoesTopRight() {
        let frame = Place.frame(contentHeight: 600, anchor: nil, screen: phl)
        #expect(frame.maxY == phl.visibleFrame.maxY - Place.gapBelowMenuBar)
        #expect(frame.maxX == phl.visibleFrame.maxX - Place.sideMargin)
    }

    @Test func frameComparison() {
        let a = CGRect(x: 10, y: 20, width: 390, height: 600)
        #expect(Place.same(a, CGRect(x: 10.3, y: 19.6, width: 390, height: 600.4)))
        #expect(!Place.same(a, CGRect(x: 10, y: 20, width: 390, height: 640)))
    }
}

@Suite struct MenuBarLabelTests {
    @Test func theIconFollowsTheState() {
        #expect(MenuBarLabel.kind(state: .idle, needsAttention: false, elapsed: "") == .idle)
        #expect(MenuBarLabel.kind(state: .error("x"), needsAttention: true, elapsed: "") == .idleAttention)
        #expect(MenuBarLabel.kind(state: .preparing, needsAttention: true, elapsed: "") == .preparing)
        #expect(MenuBarLabel.kind(state: .recording, needsAttention: false, elapsed: "01:02")
            == .recording(elapsed: "01:02", problem: false))
        #expect(MenuBarLabel.kind(state: .stopping, needsAttention: true, elapsed: "1:00:00")
            == .recording(elapsed: "1:00:00", problem: true))
    }

    /// Observation tracks only what the icon shows: idle never reads the elapsed time.
    @Test func idleDoesNotReadTheElapsedTime() {
        var reads = 0
        func elapsed() -> String { reads += 1; return "00:00" }
        _ = MenuBarLabel.kind(state: .idle, needsAttention: false, elapsed: elapsed())
        _ = MenuBarLabel.kind(state: .preparing, needsAttention: false, elapsed: elapsed())
        #expect(reads == 0)
        _ = MenuBarLabel.kind(state: .recording, needsAttention: false, elapsed: elapsed())
        #expect(reads == 1)
    }

    @Test func accessibilityLabels() {
        #expect(MenuBarLabel.Kind.idle.accessibilityLabel == "TwinTake")
        #expect(MenuBarLabel.Kind.idleAttention.accessibilityLabel == "TwinTake, needs attention")
        #expect(MenuBarLabel.Kind.recording(elapsed: "00:05", problem: true).accessibilityLabel
            == "Recording with a problem, 00:05")
    }
}

/// Source guards: the menu is the panel, not a SwiftUI MenuBarExtra (whose window SwiftUI
/// re-centers when the content height changes), and the menu's height limit never comes from
/// the main screen.
@Suite struct MenuHostingSourceTests {
    static func code(_ name: String) throws -> [String] {
        try ThreadRuleTests.codeLines(ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/\(name)")).map(\.1)
    }

    @Test func theMenuIsAStatusItemPanel() throws {
        let app = try Self.code("RecorderApp.swift")
        #expect(!app.contains { $0.contains("MenuBarExtra") })
        #expect(app.contains { $0.contains("menuBar = MenuBarController(coordinator: coordinator)") })
        let panel = try Self.code("MenuPanel.swift")
        #expect(panel.contains { $0.contains("styleMask: [.borderless, .nonactivatingPanel]") })
        #expect(panel.contains { $0.contains("panel.setFrame(frame, display: true)") })
        #expect(panel.contains { $0.contains("panel?.invalidateShadow()") })
        #expect(!panel.contains { $0.contains("animate: true") })
    }

    @Test func theMenuViewNeverUsesTheMainScreen() throws {
        for name in ["MenuContentView.swift", "MenuPanel.swift"] {
            #expect(try !Self.code(name).contains { $0.contains("NSScreen.main") }, "\(name)")
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp").path)
        #expect(!names.contains("MenuWindowAnchor.swift"))
    }
}

/// The menu panel's window settings, on a real (never shown) panel.
@Suite struct MenuPanelWindowTests {
    /// Review finding: the panel is non-activating, so TwinTake is not the active app while the
    /// menu shows. Without this setting AppKit shows no `.help` tooltip in the menu (the Snap
    /// button's help is the only place that says why it reads "Snap: no window").
    @MainActor @Test func tooltipsShowWhileTwinTakeIsInactive() {
        let panel = MenuPanel.make(size: CGSize(width: MenuPanelPlacement.width, height: 300))
        defer { panel.close() }
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.level == .popUpMenu)
        // TwinTake's own menu stays over the camera window and the control bar.
        #expect(panel.level.rawValue > FrameOverlay.aboveOverlayLevel.rawValue)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isVisible)
    }
}
