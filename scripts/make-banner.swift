// Renders the README banner (logo + name) to docs/images/banner-light.png and banner-dark.png.
// Usage: swift scripts/make-banner.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
guard let logo = NSImage(contentsOf: root.appendingPathComponent("docs/images/logo.svg")) else { fatalError("logo.svg missing") }

let width = 1600, height = 360          // 2x of an 800x180 banner
let iconSide: CGFloat = 280
let font = NSFont.systemFont(ofSize: 210, weight: .bold)
let name = "TwinTake"

func render(textColor: NSColor, to file: String) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: -4]
    let text = NSAttributedString(string: name, attributes: attrs)
    let textSize = text.size()
    let gap: CGFloat = 56
    let total = iconSide + gap + textSize.width
    let x0 = (CGFloat(width) - total) / 2
    logo.draw(in: NSRect(x: x0, y: (CGFloat(height) - iconSide) / 2, width: iconSide, height: iconSide))
    // Center the cap height on the icon's middle.
    let baselineY = CGFloat(height) / 2 - font.capHeight / 2
    text.draw(at: NSPoint(x: x0 + iconSide + gap, y: baselineY + font.descender))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(file))
    print("wrote \(file)")
}

try render(textColor: NSColor(srgbRed: 0.118, green: 0.133, blue: 0.188, alpha: 1), to: "docs/images/banner-light.png")
try render(textColor: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1), to: "docs/images/banner-dark.png")
