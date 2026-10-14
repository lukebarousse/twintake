import AppKit
import CameraCapture

/// Draws a view that never goes on screen into a 2x bitmap, and frames it like a window on the
/// desktop (rounded corners, a shadow) in a PNG with a transparent background.
///
/// It draws with `cacheDisplay(in:to:)`, which draws AppKit controls too (`ImageRenderer` leaves
/// out the AppKit-backed SwiftUI controls: pickers, switches, buttons). It needs no Screen
/// Recording permission: it reads no pixel from the screen.
@MainActor
enum Render {
    /// Pixels per point in every PNG.
    static let scale: CGFloat = 2
    /// Room around the window for its shadow, in points.
    static let margin: CGFloat = 28

    /// A borderless window that gives its controls the key look (blue switches, tinted buttons),
    /// like the menu panel, which is the key window while it shows. Offscreen, AppKit draws the
    /// inactive look unless the window says it has the key appearance; `hasKeyAppearance` is the
    /// property AppKit checks (no public API sets it for a window that is not on screen).
    final class KeyLookWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        @objc var hasKeyAppearance: Bool { true }
    }

    /// A window that never shows, holding `view` at its size, in `appearance`.
    static func host(_ view: NSView, appearance: NSAppearance.Name, keyLook: Bool) -> NSWindow {
        let rect = CGRect(origin: .zero, size: view.frame.size)
        let window: NSWindow = keyLook
            ? KeyLookWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        return window
    }

    /// Lays out `view` and lets SwiftUI and AppKit finish their updates.
    static func settle(_ view: NSView, seconds: TimeInterval = 0.25) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    /// `view` drawn at `scale`. The view's window sets the appearance.
    static func bitmap(of view: NSView) -> CGImage {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                         pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("Could not make a bitmap \(size)")
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { fatalError("Could not read the bitmap \(size)") }
        return image
    }

    /// How the window sits on the desktop.
    struct Frame {
        var cornerRadius: CGFloat
        /// Painted under the content: a stand-in for a blur material, which only the window
        /// server can draw. Nil: the content is opaque.
        var fill: NSColor?
        var shadowAlpha: CGFloat
        /// A hairline around the window, as macOS draws in dark mode.
        var border: NSColor?
    }

    /// `content` (`size` points) as a window on a transparent background with its shadow.
    static func framed(_ content: CGImage, size: CGSize, _ frame: Frame) -> CGImage {
        let canvas = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not make a canvas \(canvas)")
        }
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = CGPath(roundedRect: rect, cornerWidth: frame.cornerRadius, cornerHeight: frame.cornerRadius, transform: nil)

        // The shadow, from an opaque copy of the shape.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                      color: NSColor.black.withAlphaComponent(frame.shadowAlpha).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor((frame.fill ?? .black).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.clear(rect)
        if let fill = frame.fill {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(rect)
        }
        ctx.interpolationQuality = .high
        ctx.draw(content, in: rect)
        ctx.restoreGState()

        if let border = frame.border {
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: frame.cornerRadius,
                               cornerHeight: frame.cornerRadius, transform: nil))
            ctx.setStrokeColor(border.cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { fatalError("Could not finish the canvas") }
        return image
    }

    /// Writes `image` as a PNG and returns its size in pixels.
    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) throws -> (width: Int, height: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url, options: .atomic)
        return (image.width, image.height)
    }

    // MARK: - Pictures in place of the live video

    /// Every view in `root`'s tree of type `T`.
    static func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let match = view as? T { found.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Puts `image` over a video layer (an AVSampleBufferDisplayLayer only shows frames that the
    /// window server composites, so an offscreen drawing of it is black). Fits it like the
    /// layer's `.resizeAspect`.
    static func cover(_ layer: CALayer, with image: CGImage) {
        let picture = CALayer()
        picture.name = "DocShots.picture"
        picture.frame = layer.bounds
        picture.contents = image
        picture.contentsGravity = .resizeAspect
        picture.contentsScale = scale
        layer.sublayers?.filter { $0.name == picture.name }.forEach { $0.removeFromSuperlayer() }
        layer.addSublayer(picture)
    }

    /// Covers the video in every camera preview view under `root` (the menu's Live preview and
    /// the camera window) with `image`.
    static func coverCameraPreviews(in root: NSView, with image: CGImage) -> Int {
        let previews = views(of: CameraPreviewNSView.self, in: root)
        for preview in previews {
            preview.layoutSubtreeIfNeeded()
            if let layer = preview.layer { cover(layer, with: image) }
        }
        return previews.count
    }
}
