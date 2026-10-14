import AVFoundation
import RecorderCore

/// A macOS camera effect that can change the recorded picture.
enum VideoEffect: String, CaseIterable, Sendable {
    case centerStage = "Center Stage"
    case portrait = "Portrait"
    case studioLight = "Studio Light"
    case reactions = "Reactions"
    case backgroundReplacement = "Background Replacement"
    case edgeLight = "Edge Light"
    case lowLightNoiseReduction = "Low Light Noise Reduction"

    /// Snake-case id for PreflightIssue ids, e.g. "studio_light".
    var slug: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "_") }

    /// Why the effect matters for a recording.
    var risk: String {
        switch self {
        case .centerStage: "it crops and pans the camera picture"
        case .portrait: "it blurs the background of the camera picture"
        case .studioLight: "it relights your face in the camera picture"
        case .reactions: "a hand gesture can add balloons, hearts or fireworks to the camera picture"
        case .backgroundReplacement: "it replaces the background of the camera picture"
        case .edgeLight: "it lights the screen edges, which shows in the screen recording and on your face"
        case .lowLightNoiseReduction: "it filters the camera picture"
        }
    }

    /// False for the system filter the recorder turns off itself; a blocker the user cannot clear
    /// would stop every recording.
    var userCanTurnOff: Bool { self != .lowLightNoiseReduction }

    /// Where to turn the effect off.
    var fix: String {
        switch self {
        case .reactions:
            "Turn off Reactions (gestures) in Control Center > Video Effects. The menu shows while the camera is on."
        case .lowLightNoiseReduction:
            "The recorder turns this off on its own connection; if it stays on, report it."
        default:
            "Turn it off in Control Center > Video Effects. The menu shows while the camera is on."
        }
    }
}

/// The state of one effect, read from the class flags (Control Center) and the device.
struct EffectFlags: Sendable, Hashable {
    /// On in Control Center for this app.
    var enabled = false
    /// The camera's active format can render it. Nil when the camera is not known.
    var supported: Bool?
    /// Applied to the camera right now.
    var active = false

    init(enabled: Bool = false, supported: Bool? = nil, active: Bool = false) {
        self.enabled = enabled; self.supported = supported; self.active = active
    }
}

/// macOS camera effects for one camera at one moment. Plain data, so the mapping to names and
/// preflight issues can be tested without a camera.
struct VideoEffectsSnapshot: Sendable, Hashable {
    enum Level: Sendable, Hashable {
        /// Changes (or will change, once the camera streams) the picture of this camera.
        case active
        /// On in Control Center; whether it reaches this camera is unknown.
        case enabled
    }

    var flags: [VideoEffect: EffectFlags] = [:]
    /// Control Center mic mode when it is not Standard, e.g. "Voice Isolation".
    var microphoneMode: String?

    func level(of effect: VideoEffect) -> Level? {
        guard let f = flags[effect] else { return nil }
        if f.active { return .active }
        guard f.enabled else { return nil }
        switch f.supported {
        case .some(true): return .active
        case .some(false): return nil
        case .none: return .enabled
        }
    }

    /// Names for `CameraInfo.effectsActive`, in a stable order.
    func activeNames() -> [String] {
        var names = VideoEffect.allCases.filter { level(of: $0) == .active }.map(\.rawValue)
        if let mode = microphoneMode { names.append("Mic Mode: \(mode)") }
        return names
    }

    /// A blocker for each effect that changes the picture, a warning for each that might.
    func issues() -> [PreflightIssue] {
        var issues: [PreflightIssue] = VideoEffect.allCases.compactMap { effect in
            switch level(of: effect) {
            case .active:
                return PreflightIssue(id: "camera.effect.\(effect.slug)", severity: effect.userCanTurnOff ? .blocker : .warning,
                                      message: "\(effect.rawValue) is on: \(effect.risk). \(effect.fix)")
            case .enabled:
                return PreflightIssue(id: "camera.effect.\(effect.slug)", severity: .warning,
                                      message: "\(effect.rawValue) is on in Control Center. If it reaches the camera, \(effect.risk). \(effect.fix)")
            case nil:
                return nil
            }
        }
        if let mode = microphoneMode {
            issues.append(PreflightIssue(
                id: "camera.mic_mode", severity: .warning,
                message: "Mic Mode is \(mode), so macOS may process the camera audio. Pick Standard in Control Center > Mic Mode."))
        }
        return issues
    }

    static func microphoneModeName(_ mode: AVCaptureDevice.MicrophoneMode) -> String? {
        switch mode {
        case .standard: nil
        case .wideSpectrum: "Wide Spectrum"
        case .voiceIsolation: "Voice Isolation"
        @unknown default: "Mode \(mode.rawValue)"
        }
    }
}

extension VideoEffectsSnapshot {
    /// Reads the effect state for `device` (nil: only the Control Center flags) and, after
    /// prepare, the recording video output's connection.
    static func current(device: AVCaptureDevice?, connection: AVCaptureConnection? = nil) -> VideoEffectsSnapshot {
        // activeFormat is declared nonnull but a device with no formats can return nil.
        let format = device.flatMap { $0.formats.isEmpty ? nil : $0.activeFormat }
        var s = VideoEffectsSnapshot()

        // prepare() takes Center Stage from Control Center and turns it off, so only a camera
        // where it is still active counts.
        s.flags[.centerStage] = EffectFlags(active: device?.isCenterStageActive ?? false)
        s.flags[.portrait] = EffectFlags(
            enabled: AVCaptureDevice.isPortraitEffectEnabled,
            supported: device == nil ? nil : (format?.isPortraitEffectSupported ?? false),
            active: device?.isPortraitEffectActive ?? false)
        s.flags[.studioLight] = EffectFlags(
            enabled: AVCaptureDevice.isStudioLightEnabled,
            supported: device == nil ? nil : (format?.isStudioLightSupported ?? false),
            active: device?.isStudioLightActive ?? false)
        // reactionEffectsEnabled is on for every macOS app by default; reactions render only when
        // gesture detection is on (the recorder never calls performEffect).
        let gestures = AVCaptureDevice.reactionEffectGesturesEnabled
        s.flags[.reactions] = EffectFlags(
            enabled: AVCaptureDevice.reactionEffectsEnabled && gestures,
            supported: device == nil ? nil : (format?.reactionEffectsSupported ?? false),
            active: gestures && (device?.canPerformReactionEffects ?? false))
        s.flags[.backgroundReplacement] = EffectFlags(
            enabled: AVCaptureDevice.isBackgroundReplacementEnabled,
            supported: device == nil ? nil : (format?.isBackgroundReplacementSupported ?? false),
            active: device?.isBackgroundReplacementActive ?? false)
        if #available(macOS 26.2, *) {
            s.flags[.edgeLight] = EffectFlags(
                enabled: AVCaptureDevice.isEdgeLightEnabled,
                supported: device == nil ? nil : (format?.isEdgeLightSupported ?? false),
                active: AVCaptureDevice.isEdgeLightActive)
        }
        if #available(macOS 27.0, *), let connection {
            s.flags[.lowLightNoiseReduction] = EffectFlags(active: connection.isLowLightVideoNoiseReductionEnabled)
        }
        s.microphoneMode = microphoneModeName(AVCaptureDevice.activeMicrophoneMode)
        return s
    }
}
