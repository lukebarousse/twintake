import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import RecorderApp
import WindowTools

/// Renders TwinTake's own views with sample data to PNG files for the docs:
/// `scripts/render-docs-images.sh` runs it with `TWINTAKE_DOCSHOTS_DIR=docs/images`.
///
/// Nothing here opens a camera, a mic or a screen capture, and nothing asks for a permission. The
/// coordinator never launches: `SessionCoordinator.showSample` sets the values the views read.
/// The live video comes from `SamplePictures`. No window goes on screen.
///
/// The menu follows the system appearance, so it gets a light and a dark image (`-dark`). The
/// control bar, the camera window and the replay window are dark in both appearances (the app
/// sets their appearance or draws them black), so each gets one image.
@Suite struct DocShots {
    static let outputPath = ProcessInfo.processInfo.environment["TWINTAKE_DOCSHOTS_DIR"]

    @MainActor
    @Test(.enabled(if: DocShots.outputPath != nil, "Set TWINTAKE_DOCSHOTS_DIR to render the docs images"))
    func renderDocsImages() throws {
        let output = URL(fileURLWithPath: try #require(Self.outputPath), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // The windows take the scale of the main screen: on a 1x screen the 2x PNGs come out soft.
        if (NSScreen.main?.backingScaleFactor ?? 1) < Render.scale {
            print("DocShots: the main screen is not Retina, so the images may look soft")
        }

        let shots = Shots(defaults: MemoryDefaults())

        var written: [String] = []
        func write(_ image: CGImage, _ name: String) throws {
            let size = try Render.writePNG(image, to: output.appendingPathComponent(name))
            written.append("\(name) \(size.width)x\(size.height)")
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
            try write(shots.menu(SampleData.ready, appearance: appearance), "menu\(suffix).png")
            try write(shots.menu(SampleData.recording, appearance: appearance), "menu-recording\(suffix).png")
        }
        try write(shots.controlBar(), "control-bar.png")
        try write(shots.cameraWindow(), "camera-window.png")
        try write(shots.replayWindow(), "replay-window.png")
        for line in written { print("DocShots: wrote \(output.path)/\(line)") }
        #expect(written.count == 7)
    }
}

/// One render per view.
@MainActor
struct Shots {
    let defaults: UserDefaults
    let camera = SamplePictures.camera()
    let screen = SamplePictures.screen()

    /// A coordinator that never launched, showing `sample`.
    func coordinator(_ sample: SessionCoordinator.Sample) -> SessionCoordinator {
        let coordinator = SessionCoordinator(settings: SampleData.settings(defaults: defaults), permissions: SampleData.permissions())
        coordinator.showSample(sample)
        return coordinator
    }

    // MARK: - Menu

    /// The menu panel's content (`MenuContentView`), as tall as its content, on a stand-in for
    /// the menu material.
    func menu(_ sample: SessionCoordinator.Sample, appearance: NSAppearance.Name) -> CGImage {
        let coordinator = coordinator(sample)
        let model = MenuPanelModel()
        let measured = Measured()
        model.heightHandler = { measured.height = $0 }
        let hosting = NSHostingView(rootView: MenuContentView(coordinator: coordinator, menu: model))
        hosting.sizingOptions = []
        let width = MenuPanelPlacement.width
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 1800)
        let window = Render.host(hosting, appearance: appearance, keyLook: true)
        model.opened()
        Render.settle(hosting)
        let height = ceil(measured.height ?? hosting.fittingSize.height)
        window.setContentSize(CGSize(width: width, height: height))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        Render.settle(hosting)
        _ = Render.coverCameraPreviews(in: hosting, with: camera)
        Render.settle(hosting, seconds: 0.05)
        let dark = appearance == .darkAqua
        let image = Render.framed(Render.bitmap(of: hosting), size: hosting.bounds.size, Render.Frame(
            cornerRadius: MenuPanelPlacement.cornerRadius,
            fill: dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.935, alpha: 1),
            shadowAlpha: dark ? 0.5 : 0.28, border: dark ? NSColor.white.withAlphaComponent(0.12) : nil))
        window.close()
        return image
    }

    // MARK: - Control bar

    /// The control bar during the take, with the two pinned apps (the first one in front).
    func controlBar() -> CGImage {
        let coordinator = coordinator(SampleData.recording)
        let bar = ControlBarView(coordinator: coordinator)
        var content = ControlBarContent(coordinator: coordinator, presence: AppPresence())
        content.apps = SampleData.pinnedApps.enumerated().map { index, app in
            ControlBarContent.App(app: app, running: true, front: index == 0)
        }
        bar.apply(content)
        let size = bar.fittingContentSize
        bar.frame = CGRect(origin: .zero, size: size)
        let panel = ControlBarPanel.make(size: size)
        panel.contentView = bar
        // The HUD blur needs the window server: a flat stand-in is painted under the bar instead.
        Render.views(of: NSVisualEffectView.self, in: bar).forEach { $0.isHidden = true }
        let icons = [SampleData.pinnedApps[0].shortName: SampleIcons.browser(), SampleData.pinnedApps[1].shortName: SampleIcons.virtualMachine()]
        for button in Render.views(of: BarButton.self, in: bar) {
            if let icon = icons[button.text] { button.image = icon }
        }
        Render.settle(bar)
        let image = Render.framed(Render.bitmap(of: bar), size: size, Render.Frame(
            cornerRadius: ControlBarView.cornerRadius, fill: NSColor(white: 0.13, alpha: 0.97), shadowAlpha: 0.35, border: nil))
        panel.close()
        return image
    }

    // MARK: - Camera window

    /// The camera window during the take: the picture, the red dot with the time, and the camera
    /// mic meter along the bottom edge.
    func cameraWindow() -> CGImage {
        let coordinator = coordinator(SampleData.recording)
        let size = CameraWindowGeometry.SizePreset.medium.size
        let container = CameraMonitorContainer(frame: CGRect(origin: .zero, size: size))
        container.setContent(NSHostingView(rootView: CameraMonitorView(coordinator: coordinator)))
        let window = Render.host(container, appearance: .darkAqua, keyLook: false)
        Render.settle(container)
        _ = Render.coverCameraPreviews(in: container, with: camera)
        Render.settle(container, seconds: 0.05)
        let image = Render.framed(Render.bitmap(of: container), size: size, Render.Frame(
            cornerRadius: CameraMonitorContainer.cornerRadius, fill: nil, shadowAlpha: 0.4, border: nil))
        window.close()
        return image
    }

    // MARK: - Replay window

    /// The replay window during the take, at its default size: screen.mov with camera.mov in
    /// the corner, the timeline (speech in green, flags in orange) and the controls.
    func replayWindow() -> CGImage {
        let model = SampleData.replayModel()
        let style = ReplayPanel.style
        let contentSize = NSPanel.contentRect(forFrameRect: CGRect(origin: .zero, size: ReplayWindowGeometry.defaultSize),
                                              styleMask: style).size
        let panel = ReplayPanel(contentRect: CGRect(origin: .zero, size: contentSize), styleMask: style, backing: .buffered,
                                defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = model.title
        panel.insetCloseButton()
        let container = ReplayContentView(frame: CGRect(origin: .zero, size: contentSize))
        panel.contentView = container
        let picture = ReplayPictureView(files: model.files)
        container.setPicture(picture)
        let controls = ReplayControlsView(controller: nil)
        container.setControls(controls)
        controls.apply(model.controlsState)
        controls.timeline.apply(model.timelineData, positionS: model.position)
        guard let frameView = container.superview else { fatalError("The replay panel has no frame view") }
        Render.settle(frameView)
        // screen.mov, then camera.mov in the corner (ReplayPictureView adds them in that order).
        let videos = (picture.layer?.sublayers ?? []).compactMap { $0 as? AVSampleBufferDisplayLayer }
        for (layer, image) in zip(videos, [screen, camera]) { Render.cover(layer, with: image) }
        Render.settle(frameView, seconds: 0.05)
        let image = Render.framed(Render.bitmap(of: frameView), size: frameView.bounds.size, Render.Frame(
            cornerRadius: 14, fill: nil, shadowAlpha: 0.4, border: NSColor.white.withAlphaComponent(0.16)))
        panel.close()
        return image
    }
}

/// Settings storage in memory only: the screenshots never read or write a preferences file,
/// and never see the app's own settings.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

/// The menu's content height, from `MenuPanelModel.heightHandler`.
@MainActor
private final class Measured {
    var height: CGFloat?
}

/// Plain stand-ins for the pinned apps' icons (the real bar shows each app's own icon).
@MainActor
enum SampleIcons {
    static func browser() -> NSImage { icon(symbol: "globe", top: NSColor.systemTeal, bottom: NSColor.systemBlue) }

    static func virtualMachine() -> NSImage {
        icon(symbol: "pc", top: NSColor(white: 0.55, alpha: 1), bottom: NSColor(white: 0.32, alpha: 1))
    }

    /// An 18 pt rounded square with a gradient and a white symbol, like an app icon.
    private static func icon(symbol: String, top: NSColor, bottom: NSColor) -> NSImage {
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let square = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: square, xRadius: 4, yRadius: 4)
            NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: CGRect(x: square.midX - g.width / 2, y: square.midY - g.height / 2, width: g.width, height: g.height))
            }
            return true
        }
    }
}
