// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AppKit

/// The menu bar icon: a record symbol when idle, a red dot and the elapsed time while recording,
/// orange when something needs attention: a file has a problem (it ended early, or the camera
/// sends no picture), the camera mic warns (built-in mic, or it does not hear the voice), or the
/// camera has trouble (USB 2, empty frames). `MenuBarController` puts it on the status item.
enum MenuBarLabel {
    enum Kind: Equatable {
        case idle, idleAttention, preparing
        case recording(elapsed: String, problem: Bool)

        var image: NSImage {
            switch self {
            case .idle: MenuBarIcon.symbol("record.circle", description: accessibilityLabel)
            case .preparing: MenuBarIcon.symbol("record.circle.fill", description: accessibilityLabel)
            case .idleAttention: MenuBarIcon.idleAttention()
            case let .recording(elapsed, problem): MenuBarIcon.recording(elapsed: elapsed, problem: problem)
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: "TwinTake"
            case .idleAttention: "TwinTake, needs attention"
            case .preparing: "TwinTake, starting"
            case let .recording(elapsed, problem): problem ? "Recording with a problem, \(elapsed)" : "Recording, \(elapsed)"
            }
        }
    }

    /// The icon for a state. `needsAttention` and `elapsed` are read only when the icon shows
    /// them, so observation tracks only what the icon uses.
    static func kind(state: SessionCoordinator.State, needsAttention: @autoclosure () -> Bool,
                     elapsed: @autoclosure () -> String) -> Kind {
        switch state {
        case .recording, .stopping: .recording(elapsed: elapsed(), problem: needsAttention())
        case .preparing: .preparing
        case .idle, .error: needsAttention() ? .idleAttention : .idle
        }
    }
}

enum MenuBarIcon {
    /// A red dot and the elapsed time in one image (orange with `problem`). Its width depends only
    /// on the time format, so the status item does not change width every second. Not a template
    /// image, so it keeps its color.
    static func recording(elapsed: String, problem: Bool = false) -> NSImage {
        let color: NSColor = problem ? .systemOrange : .systemRed
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let reference = elapsed.count > 5 ? "0:00:00" : "00:00"
        let textWidth = ceil((reference as NSString).size(withAttributes: attrs).width)
        let textSize = (elapsed as NSString).size(withAttributes: attrs)
        let dot: CGFloat = 9, gap: CGFloat = 4, height: CGFloat = 16
        let size = NSSize(width: dot + gap + textWidth, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: (height - dot) / 2, width: dot, height: dot)).fill()
            let origin = NSPoint(x: dot + gap + (textWidth - textSize.width), y: (height - textSize.height) / 2)
            (elapsed as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The size of the record symbols in the menu bar.
    static var symbolConfiguration: NSImage.SymbolConfiguration { .init(pointSize: 14, weight: .regular) }

    /// A record symbol as a template image, so it takes the menu bar's color.
    static func symbol(_ name: String, description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(symbolConfiguration) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }

    /// The idle record symbol in orange. Not a template image, so it keeps its color.
    static func idleAttention() -> NSImage {
        let config = symbolConfiguration
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "TwinTake, needs attention")?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = false
        return image
    }
}
