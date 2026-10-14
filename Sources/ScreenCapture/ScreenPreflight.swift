import AVFoundation
import CoreGraphics
import Foundation
import RecorderCore

/// What preflight can learn about the Mac without opening any capture. Gathering it shows no
/// permission dialog.
struct ScreenPreflightSnapshot: Sendable, Equatable {
    enum MicAccess: Sendable, Equatable { case authorized, notDetermined, denied }

    var screenCaptureAllowed: Bool
    var displayOnline: Bool
    var displayIsBuiltIn: Bool
    /// Display size in points (`CGDisplayBounds`), nil when offline.
    var displaySizePt: CGSize?
    /// Pixels per point of the current mode, nil when unknown.
    var displayScale: Double?
    /// Current refresh rate in Hz; 0 when the display does not report one (ProMotion, some panels).
    var refreshRateHz: Double
    /// Refresh rates the display offers in any mode.
    var availableRefreshRatesHz: [Double]
    /// Nil in region mode.
    var windowExists: Bool?
    /// Nil when no mic is configured.
    var micFound: Bool?
    var micAccess: MicAccess?

    /// Reads the snapshot for `config`. Calls only non-prompting APIs: `CGPreflightScreenCaptureAccess`,
    /// display queries, the window list and `AVCaptureDevice` lookup and authorization status.
    static func current(for config: ScreenRecorderConfig) -> ScreenPreflightSnapshot {
        let id = config.displayID
        let online = onlineDisplays().contains(id)
        let mode = online ? CGDisplayCopyDisplayMode(id) : nil
        var scale: Double?
        if let mode, mode.width > 0 { scale = Double(mode.pixelWidth) / Double(mode.width) }
        var rates: [Double] = []
        if online, let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
            rates = Array(Set(modes.map(\.refreshRate).filter { $0 > 0 })).sorted()
        }

        var windowExists: Bool?
        if let windowID = config.windowID {
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]]
            windowExists = !(info ?? []).isEmpty
        }

        var micFound: Bool?
        var micAccess: MicAccess?
        if let uid = config.micDeviceUID {
            micFound = AVCaptureDevice(uniqueID: uid) != nil
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: micAccess = .authorized
            case .notDetermined: micAccess = .notDetermined
            default: micAccess = .denied
            }
        }

        return ScreenPreflightSnapshot(
            screenCaptureAllowed: CGPreflightScreenCaptureAccess(),
            displayOnline: online,
            displayIsBuiltIn: online && CGDisplayIsBuiltin(id) != 0,
            displaySizePt: online ? CGDisplayBounds(id).size : nil,
            displayScale: scale,
            refreshRateHz: mode?.refreshRate ?? 0,
            availableRefreshRatesHz: rates,
            windowExists: windowExists,
            micFound: micFound,
            micAccess: micAccess)
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

/// Preflight rules for the screen recorder. Pure, so every rule is unit tested.
enum ScreenPreflight {
    /// Frame rates the recorder is built and tested for.
    static let testedFrameRates: [FrameRate] = [.fps47_952, .fps23_976, .fps59_94]

    static func issues(config: ScreenRecorderConfig, snapshot s: ScreenPreflightSnapshot) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        func blocker(_ id: String, _ message: String) {
            issues.append(PreflightIssue(id: "screen.\(id)", severity: .blocker, message: message))
        }
        func warning(_ id: String, _ message: String) {
            issues.append(PreflightIssue(id: "screen.\(id)", severity: .warning, message: message))
        }

        if !s.screenCaptureAllowed {
            blocker("permission", "Screen Recording permission is off. Turn it on in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }

        let display = s.displayIsBuiltIn ? "the built-in display" : "display \(config.displayID)"
        if !s.displayOnline {
            blocker("display-offline", "The display to record (\(config.displayID)) is not connected. If it is the laptop display, open the lid.")
        }

        let px = config.outputPx
        if px.width <= 0 || px.height <= 0 {
            blocker("output-size", "The output size \(px.width)x\(px.height) is empty.")
        } else if px.width % 2 != 0 || px.height % 2 != 0 {
            blocker("output-size-odd", "The output size \(px.width)x\(px.height) must have even width and height.")
        }

        if config.windowID == nil {
            let rect = config.frameRectPt
            if rect.width <= 0 || rect.height <= 0 {
                blocker("frame-empty", "The recording frame is empty.")
            } else if let size = s.displaySizePt {
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
                if !bounds.contains(rect) {
                    blocker("frame-outside-display", "The recording frame does not fit on \(display) (\(Int(size.width))x\(Int(size.height)) pt). Choose the frame again.")
                }
                if px.width > 0, px.height > 0 {
                    let frameAspect = rect.width / rect.height
                    let outputAspect = Double(px.width) / Double(px.height)
                    if abs(frameAspect - outputAspect) / outputAspect > 0.01 {
                        warning("aspect-mismatch", "The output size \(px.width)x\(px.height) does not match the frame's shape; the picture gets black bars.")
                    }
                    if let scale = s.displayScale, Double(px.width) > rect.width * scale * 1.01 {
                        warning("upscaled", "The output size is larger than the display's pixels; the recording is upscaled and looks soft.")
                    }
                }
            }
        } else if s.windowExists == false {
            blocker("window-missing", "The window to record is closed. Pick the window again.")
        }

        if let found = s.micFound {
            if !found {
                blocker("mic-missing", "The mic for screen.mov is not connected. Plug it in or pick another mic.")
            }
            switch s.micAccess {
            case .denied?:
                blocker("mic-permission", "Microphone permission is off. Turn it on in System Settings > Privacy & Security > Microphone.")
            case .notDetermined?:
                warning("mic-permission-ask", "macOS asks for Microphone permission when recording starts.")
            default:
                break
            }
        }

        if !testedFrameRates.contains(config.frameRate) {
            warning("frame-rate-untested", "Screen frame rate \(config.frameRate.label) is not one of the tested rates (47.952, 23.976, 59.94).")
        }

        if s.displayOnline, let advice = refreshAdvice(display: display, isBuiltIn: s.displayIsBuiltIn,
                                                         currentHz: s.refreshRateHz,
                                                         availableHz: s.availableRefreshRatesHz,
                                                         frameRate: config.frameRate) {
            warning("refresh-rate", advice)
        }
        return issues
    }

    /// How far `refreshHz * 2 / fps` may be from a whole number: 0.5%.
    static let refreshTolerance = 0.005

    /// True when the display refreshes in step with the frame rate, so the constant-rate file shows
    /// even motion: two frames span a whole number of refreshes, within `refreshTolerance`
    /// (`refreshHz * 2 / fps` is near an integer). The cadence then repeats every two frames.
    /// - 120 Hz with 47.952 fps: 5.005 refreshes per 2 frames. Fits.
    /// - 47.95 Hz and 95.9 Hz with 47.952 fps: 2 and 4. Fit.
    /// - 60 Hz with 47.952 fps: 2.5025. Does not fit: one refresh in five never reaches the file.
    static func refreshFits(_ refreshHz: Double, frameRate: FrameRate) -> Bool {
        guard refreshHz > 0, frameRate.framesPerSecond > 0 else { return false }
        let ratio = refreshHz * 2 / frameRate.framesPerSecond
        let n = ratio.rounded()
        return n >= 1 && abs(ratio - n) / n <= refreshTolerance
    }

    /// A warning when the display refresh rate does not fit the screen frame rate
    /// (`refreshFits`), so the constant-rate file would show uneven motion. Nil when it fits.
    /// A variable refresh rate (ProMotion, `currentHz` 0) is judged by the highest rate the display
    /// offers, the rate it runs at for motion: no advice unless that rate fails the rule, and none
    /// when the display lists no rates.
    static func refreshAdvice(display: String, isBuiltIn: Bool, currentHz: Double, availableHz: [Double],
                              frameRate: FrameRate) -> String? {
        let variable = currentHz <= 0
        if variable {
            guard let top = availableHz.max(), !refreshFits(top, frameRate: frameRate) else { return nil }
        } else if refreshFits(currentHz, frameRate: frameRate) {
            return nil
        }
        let fits = availableHz.filter { refreshFits($0, frameRate: frameRate) }
        let fps = frameRate.label
        let now = variable ? "uses a variable refresh rate" : "runs at \(hzLabel(currentHz))"
        let rule = "it needs a whole number of refreshes per two frames"
        guard let best = fits.max() else {
            return "\(display.prefix(1).uppercased() + display.dropFirst()) \(now), which does not fit \(fps) fps (\(rule)), and offers no rate that does. Motion in screen.mov will be slightly uneven."
        }
        let name = isBuiltIn ? "the laptop display" : display
        return "Set \(name) to \(hzLabel(best)) (System Settings > Displays > Refresh Rate). It \(now), which does not fit \(fps) fps (\(rule)), so motion in screen.mov would be uneven."
    }

    /// "47.95 Hz", "60 Hz".
    static func hzLabel(_ hz: Double) -> String {
        var s = String(format: "%.2f", hz)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " Hz"
    }
}
