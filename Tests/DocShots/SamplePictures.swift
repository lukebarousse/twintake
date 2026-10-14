import AppKit

/// The made-up pictures that stand in for live video in the screenshots: a gray studio backdrop
/// with a plain silhouette (never a real person) for the camera, and a plain desktop with one
/// window for the screen. Drawn with Core Graphics, so no image file is needed.
enum SamplePictures {
    /// 16:9, 1920x1080 pixels.
    static let size = CGSize(width: 1920, height: 1080)

    static func camera() -> CGImage {
        draw { ctx, size in
            let w = size.width, h = size.height
            // Backdrop: a soft gray gradient with a lighter area behind the head.
            linear(ctx, from: NSColor(white: 0.46, alpha: 1), to: NSColor(white: 0.24, alpha: 1),
                   start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0))
            radial(ctx, color: NSColor(white: 0.62, alpha: 0.55), center: CGPoint(x: w * 0.5, y: h * 0.6), radius: h * 0.62)

            let body = NSColor(white: 0.17, alpha: 1).cgColor
            ctx.setFillColor(body)
            // Shoulders: a wide rounded shape that runs off the bottom edge.
            let shoulders = CGRect(x: w * 0.5 - h * 0.46, y: -h * 0.32, width: h * 0.92, height: h * 0.62)
            ctx.addPath(CGPath(roundedRect: shoulders, cornerWidth: h * 0.3, cornerHeight: h * 0.3, transform: nil))
            ctx.fillPath()
            // Neck and head.
            ctx.fill(CGRect(x: w * 0.5 - h * 0.075, y: h * 0.22, width: h * 0.15, height: h * 0.16))
            ctx.fillEllipse(in: CGRect(x: w * 0.5 - h * 0.15, y: h * 0.32, width: h * 0.30, height: h * 0.36))
        }
    }

    static func screen() -> CGImage {
        draw { ctx, size in
            let w = size.width, h = size.height
            // Desktop.
            linear(ctx, from: NSColor(srgbRed: 0.42, green: 0.50, blue: 0.62, alpha: 1),
                   to: NSColor(srgbRed: 0.22, green: 0.27, blue: 0.36, alpha: 1),
                   start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0))

            // One window, most of the frame.
            let window = CGRect(x: w * 0.05, y: h * 0.07, width: w * 0.9, height: h * 0.86)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(CGPath(roundedRect: window, cornerWidth: 22, cornerHeight: 22, transform: nil))
            ctx.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: window, cornerWidth: 22, cornerHeight: 22, transform: nil))
            ctx.clip()
            // Title bar with the three window buttons.
            let bar = CGRect(x: window.minX, y: window.maxY - 64, width: window.width, height: 64)
            ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
            ctx.fill(bar)
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: bar.minX + 26 + CGFloat(i) * 34, y: bar.midY - 11, width: 22, height: 22))
            }
            ctx.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: bar.midX - 260, y: bar.midY - 16, width: 520, height: 32),
                               cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.fillPath()
            // Sidebar.
            let sidebar = CGRect(x: window.minX, y: window.minY, width: 330, height: bar.minY - window.minY)
            ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
            ctx.fill(sidebar)
            ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
            for row in 0..<9 {
                let y = sidebar.maxY - 70 - CGFloat(row) * 56
                ctx.addPath(CGPath(roundedRect: CGRect(x: sidebar.minX + 34, y: y, width: CGFloat(150 + (row * 37) % 110),
                                                       height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil))
            }
            ctx.fillPath()
            // Content: a heading, a chart and lines of text.
            let left = sidebar.maxX + 70
            ctx.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: left, y: bar.minY - 110, width: 560, height: 40),
                               cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
            let chart = CGRect(x: left, y: bar.minY - 470, width: 820, height: 310)
            ctx.setFillColor(NSColor(white: 0.94, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: chart, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()
            let heights: [CGFloat] = [0.35, 0.55, 0.45, 0.7, 0.62, 0.85, 0.78]
            for (i, value) in heights.enumerated() {
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(i == 5 ? 0.95 : 0.55).cgColor)
                let bw: CGFloat = 70
                let bx = chart.minX + 50 + CGFloat(i) * (bw + 42)
                ctx.addPath(CGPath(roundedRect: CGRect(x: bx, y: chart.minY + 30, width: bw, height: (chart.height - 60) * value),
                                   cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.fillPath()
            }
            ctx.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor)
            for row in 0..<5 {
                let y = chart.minY - 70 - CGFloat(row) * 44
                guard y > window.minY + 30 else { break }
                ctx.addPath(CGPath(roundedRect: CGRect(x: left, y: y, width: CGFloat(700 - (row * 83) % 260), height: 16),
                                   cornerWidth: 8, cornerHeight: 8, transform: nil))
            }
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // MARK: - Drawing

    private static func draw(_ body: (CGContext, CGSize) -> Void) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not make a picture context")
        }
        body(ctx, size)
        guard let image = ctx.makeImage() else { fatalError("Could not finish a picture") }
        return image
    }

    private static func linear(_ ctx: CGContext, from: NSColor, to: NSColor, start: CGPoint, end: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ ctx: CGContext, color: NSColor, center: CGPoint, radius: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}
