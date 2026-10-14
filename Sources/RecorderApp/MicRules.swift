import Foundation
import RecorderCore

// The app's rules for the level meters, the mic check and the mic warning calibration, over
// plain data (no device, no view), so they can be tested.

/// The name the app uses for the external mic in the camera's mic jack. One place, so another
/// setup changes one word.
enum MicNames {
    static let external = "Rode"
    static let camera = "a6600"
}

// MARK: - Meters

/// The meter scale: -60 to 0 dBFS. Green up to -12 dBFS, yellow up to -3 dBFS, red above.
enum MeterScale {
    static let floorDb = -60.0
    static let yellowDb = -12.0
    static let redDb = -3.0

    enum Zone: Equatable, Sendable {
        case green, yellow, red
    }

    /// One colored stretch of the bar, as fractions of its length.
    struct Segment: Equatable, Sendable {
        var from: Double
        var to: Double
        var zone: Zone
    }

    /// The three zones, from the floor up.
    static let segments = [
        Segment(from: 0, to: fraction(yellowDb), zone: .green),
        Segment(from: fraction(yellowDb), to: fraction(redDb), zone: .yellow),
        Segment(from: fraction(redDb), to: 1, zone: .red),
    ]

    /// Where `db` sits on the bar: 0 at the floor (and below), 1 at 0 dBFS (and above).
    static func fraction(_ db: Double) -> Double {
        guard db.isFinite else { return db > 0 ? 1 : 0 }
        return min(1, max(0, (db - floorDb) / -floorDb))
    }

    /// The color of a level: yellow above -12 dBFS, red above -3 dBFS.
    static func zone(_ db: Double) -> Zone {
        if db > redDb { return .red }
        return db > yellowDb ? .yellow : .green
    }

    /// The number next to a bar, e.g. "-18". "—" for silence or a meter that stopped.
    static func label(_ level: AudioLevel?) -> String {
        guard let level, level.isLive, level.peakHoldDb > floorDb - 30 else { return "—" }
        return "\(Int(level.peakHoldDb.rounded()))"
    }
}

/// Which sources have a meter.
enum MeterSources {
    /// A take: the camera mic when camera.mov has an audio track, the Mac mic and computer sound
    /// when screen.mov records them. A take without a screen mic (Camera mode) shows the Mac mic
    /// while the idle Mac mic meter runs: it is metered for the detector, not recorded.
    static func take(cameraAudio: Bool, screenMic: Bool, systemAudio: Bool) -> [AudioSource] {
        var sources: [AudioSource] = []
        if cameraAudio { sources.append(.cameraMic) }
        if screenMic { sources.append(.screenMic) }
        if systemAudio { sources.append(.systemAudio) }
        return sources
    }

    /// A mic check: the camera mic and the Mac mic it opens.
    static func check(cameraAudio: Bool, screenMic: Bool) -> [AudioSource] {
        take(cameraAudio: cameraAudio, screenMic: screenMic, systemAudio: false)
    }
}

extension AudioSource {
    /// The meter's label in the menu.
    var meterTitle: String {
        switch self {
        case .cameraMic: "Camera mic"
        case .screenMic: "Mac mic"
        case .systemAudio: "Computer sound"
        }
    }
}

// MARK: - Mic check

/// What a mic check is for: a plain check, or one of the two calibration samples.
enum MicCheckPurpose: Equatable, Sendable {
    case check
    case calibratePlugged
    case calibrateUnplugged

    var isCalibration: Bool { self != .check }
}

/// A mic check that runs now.
struct MicCheckProgress: Equatable, Sendable {
    var purpose: MicCheckPurpose
    var startedAt: Date
    var seconds: Double
    /// Cancel was pressed; the check closes its mics.
    var cancelling = false

    /// Whole seconds left, at least 0.
    func secondsLeft(at now: Date) -> Int {
        max(0, Int((seconds - now.timeIntervalSince(startedAt)).rounded(.up)))
    }
}

/// What a finished mic check heard (`MicCheck.Result`, as plain app data).
struct MicCheckOutcome: Equatable, Sendable {
    var status: MicDetectorStatus
    var sample: MicFeatureSample
    var cameraMicOpened: Bool
    var screenMicOpened: Bool
    var cancelled: Bool
    var errors: [String]
    /// The sources the check sampled from the idle meters (it opened no session for them).
    var liveSources: Set<AudioSource> = []
    var finishedAt = Date()
}

/// How a line of mic text is shown.
enum MicTone: Equatable, Sendable {
    case neutral, good, warning
}

/// One or two lines of mic text.
struct MicText: Equatable, Sendable {
    var title: String
    var detail: String?
    var tone: MicTone
}

enum MicStatusText {
    /// "0.991".
    static func correlation(_ value: Double) -> String { String(format: "%.3f", value) }

    /// "+12.5 dB", "−3.0 dB".
    static func decibels(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let number = String(format: "%.1f", abs(rounded))
        return (rounded < 0 ? "−" : "+") + number + " dB"
    }

    /// Under "Rode confirmed" while recording.
    static let confirmedDetail = "The mic check is off for the rest of this take."

    /// The live line under the meters while a take or a check runs. Pauses do not change it:
    /// the detector counts voiced time only.
    /// - Parameter macMicMissing: the calibration tells the mics apart by their level against the
    ///   Mac mic only (`MicCalibrationText.needsMacMic`), and this take or check has no Mac mic.
    static func live(_ status: MicDetectorStatus, macMicMissing: Bool = false) -> MicText {
        let corr = status.correlation.map { " · L/R \(correlation($0))" } ?? ""
        // A take confirmed the external mic: no rule warns for the rest of it.
        if status.confirmed {
            return MicText(title: "\(MicNames.external) confirmed\(corr)", detail: confirmedDetail, tone: .good)
        }
        if status.cameraMicSilent {
            return MicText(title: "The camera mic isn't picking up your voice", tone: .warning)
        }
        if macMicMissing, status.verdict == .unknown {
            return MicText(title: "The mic warning needs the Mac mic: your calibration compares the camera mic with it",
                           tone: .warning)
        }
        switch status.verdict {
        case .externalMic:
            return MicText(title: "\(MicNames.external) detected\(corr)", tone: .good)
        case .builtInMic:
            return MicText(title: "Built-in mic, \(MicNames.external) not detected\(corr)", tone: .warning)
        case .unknown:
            if status.voicedSeconds < 0.05 { return MicText(title: "Talk to check the camera mic", tone: .neutral) }
            if status.progress < 1 {
                return MicText(title: "Listening for your voice… \(Int((status.progress * 100).rounded()))%", tone: .neutral)
            }
            return MicText(title: "Not sure which mic the camera uses\(corr)", tone: .neutral)
        }
    }

    /// The result of a finished mic check.
    static func outcome(_ o: MicCheckOutcome) -> MicText {
        if o.cancelled { return MicText(title: "Mic check cancelled.", tone: .neutral) }
        guard o.cameraMicOpened else {
            return MicText(title: "The camera mic did not open.",
                           detail: o.errors.isEmpty ? nil : o.errors.joined(separator: " "), tone: .warning)
        }
        let s = o.status
        let voice = String(format: "%.1f", o.sample.cameraVoicedSeconds)
        let corr = s.correlation.map { "L/R correlation \(correlation($0))" }
        var text: MicText
        if s.cameraMicSilent {
            text = MicText(title: CaptureAlerts.silentTitle, detail: CaptureAlerts.silentDetail, tone: .warning)
        } else {
            switch s.verdict {
            case .externalMic:
                text = MicText(title: "\(MicNames.external) detected.",
                               detail: [corr, "\(voice) s of voice"].compactMap { $0 }.joined(separator: " · "), tone: .good)
            case .builtInMic:
                text = MicText(title: CaptureAlerts.builtInTitle,
                               detail: [corr.map { $0 + "." }, CaptureAlerts.builtInDetail].compactMap { $0 }.joined(separator: " "),
                               tone: .warning)
            case .unknown:
                if o.sample.problem == .cameraSilent {
                    // The Mac mic heard the voice, the camera audio held hardly any.
                    text = MicText(title: CaptureAlerts.silentTitle, detail: CaptureAlerts.silentDetail, tone: .warning)
                } else if o.sample.cameraVoicedSeconds < 1 {
                    text = MicText(title: "No voice heard.", detail: "Talk during the check: the camera mic needs about 4 s of voice.",
                                   tone: .neutral)
                } else if s.correlation == nil, !s.calibrated {
                    text = MicText(title: "Not sure which mic the camera uses.",
                                   detail: "The camera audio is mono. Calibrate the mic warning (Recording Settings) to tell the mics apart by level.",
                                   tone: .neutral)
                } else {
                    text = MicText(title: "Not sure which mic the camera uses.",
                                   detail: [corr, "\(voice) s of voice. Talk a little longer."].compactMap { $0 }.joined(separator: " · "),
                                   tone: .neutral)
                }
            }
        }
        if !o.screenMicOpened, !o.errors.isEmpty {
            text.detail = [text.detail, o.errors.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
        }
        return text
    }
}

// MARK: - Calibration

/// The "Calibrate mic warning…" steps: a sample with the external mic plugged in, one with it
/// unplugged, then the thresholds to save.
struct MicCalibrationFlow: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case plugged, unplugged, review
    }

    /// Tells a flow apart from one started over meanwhile, so a late sample lands in its own flow.
    var id = UUID()
    var step = Step.plugged
    var plugged: MicFeatureSample?
    var unplugged: MicFeatureSample?
    /// Set on the review step when the samples made a calibration.
    var calibration: MicCalibration?
    /// Why the last sample (or the calibration) did not work.
    var error: String?

    /// The check purpose of the current step, nil on the review step.
    var purpose: MicCheckPurpose? {
        switch step {
        case .plugged: .calibratePlugged
        case .unplugged: .calibrateUnplugged
        case .review: nil
        }
    }

    /// Takes the result of the check for `purpose`. A sample with too little voice, a camera
    /// that sent no sound while the Mac mic heard the voice (`MicFeatureSample.problem`), a
    /// cancelled check or a camera mic that did not open stays on its step with an error.
    mutating func record(_ outcome: MicCheckOutcome, for purpose: MicCheckPurpose) {
        guard purpose == self.purpose else { return }
        if outcome.cancelled {
            error = "The sample was cancelled. Record it again."
            return
        }
        guard outcome.cameraMicOpened else {
            error = (["The camera mic did not open."] + outcome.errors).joined(separator: " ")
            return
        }
        if let problem = outcome.sample.problem {
            error = Self.message(problem, sample: outcome.sample, purpose: purpose)
            return
        }
        error = nil
        switch purpose {
        case .calibratePlugged:
            plugged = outcome.sample
            step = .unplugged
        case .calibrateUnplugged:
            unplugged = outcome.sample
            finish()
        case .check:
            break
        }
    }

    /// Why a sample cannot be used, and what to do.
    static func message(_ problem: MicSampleProblem, sample: MicFeatureSample, purpose: MicCheckPurpose) -> String {
        let camera = String(format: "%.1f", sample.cameraVoicedSeconds)
        let mac = String(format: "%.1f", sample.referenceVoicedSeconds)
        switch problem {
        case .notEnoughVoice where sample.cameraVoicedSeconds >= MicCalibration.minSampleSeconds:
            // The camera heard the voice, the Mac mic too little of it: only voice both hear counts.
            return "Only \(String(format: "%.1f", sample.usableVoicedSeconds)) s of voice that the Mac mic heard too "
                + "(camera: \(camera) s). Talk a little louder for the whole 10 s and record it again."
        case .notEnoughVoice:
            return "Only \(String(format: "%.1f", sample.usableVoicedSeconds)) s of voice. Talk for the whole 10 s and record it again."
        case .cameraSilent where purpose == .calibrateUnplugged:
            // Take 2026-10-13_205644: without the Rode the a6600 sent silence, not its built-in mic.
            return "The camera sent no sound (Mac mic: \(mac) s of voice, camera: \(camera) s). Without the "
                + "\(MicNames.external), the \(MicNames.camera) recorded silence, not its built-in mic. Pull the plug out of the "
                + "\(MicNames.camera)'s MIC jack itself, wait 30 s, then record sample 2 again. If the camera stays silent, "
                + "you need no calibration: TwinTake then warns \"\(CaptureAlerts.silentTitle)\""
        case .cameraSilent:
            return "The camera mic isn't picking up your voice (Mac mic: \(mac) s of voice, camera: \(camera) s). Check that "
                + "the \(MicNames.external) is switched on and plugged into the \(MicNames.camera), then record sample 1 again."
        }
    }

    private mutating func finish() {
        guard let plugged, let unplugged else { return }
        do throws(MicCalibrationError) {
            calibration = try MicCalibration.make(plugged: plugged, unplugged: unplugged)
            step = .review
        } catch {
            switch error {
            case let .notEnoughVoice(sample, _) where sample == "plugged-in":
                self.plugged = nil
                step = .plugged
            case .notEnoughVoice:
                self.unplugged = nil
                step = .unplugged
            case .samplesDoNotDiffer:
                step = .review
                calibration = nil
            case .samplesSwapped:
                // Both samples again, in the right order.
                self.plugged = nil
                self.unplugged = nil
                step = .plugged
            }
            self.error = error.errorDescription
        }
    }

    /// The step's instruction.
    var instruction: String {
        switch step {
        case .plugged: "Step 1 of 2: plug the \(MicNames.external) into the \(MicNames.camera) and switch it on. Click Record Sample, then talk for 10 s."
        case .unplugged: "Step 2 of 2: unplug the \(MicNames.external) from the \(MicNames.camera). Click Record Sample, then talk for 10 s."
        case .review:
            if calibration == nil { "The samples did not make a calibration." }
            else if MicCalibrationText.needsMacMic(calibration) {
                "Save these thresholds for the mic warning. They compare the camera mic with the Mac mic, so the warning works only while TwinTake meters the Mac mic (not with Screen > Mic set to None)."
            } else { "Save these thresholds for the mic warning." }
        }
    }
}

/// The thresholds of the mic warning, as text for the settings.
enum MicCalibrationText {
    static let defaultRule = "Default rule: camera L/R correlation below \(MicStatusText.correlation(MicFeatureRule.defaultCorrelation.threshold)) means the built-in mic."

    /// True when `calibration` tells the mics apart only by the level against the Mac mic: the
    /// warning then needs the Mac mic in the take (not Camera mode, not screen mic None).
    static func needsMacMic(_ calibration: MicCalibration?) -> Bool {
        guard let calibration else { return false }
        return calibration.correlation == nil && calibration.levelDelta != nil
    }

    /// One line per rule, e.g. "L/R correlation: built-in mic below 0.962 (Rode 0.991, built-in 0.912)".
    static func rules(_ calibration: MicCalibration?) -> [String] {
        guard let c = calibration else { return [defaultRule] }
        var lines: [String] = []
        if let rule = c.correlation {
            lines.append(line("L/R correlation", rule: rule, external: c.plugged.correlation.mean,
                              builtIn: c.unplugged.correlation.mean, format: MicStatusText.correlation))
        }
        if let rule = c.levelDelta {
            lines.append(line("Level against the Mac mic", rule: rule, external: c.plugged.levelDeltaDb.mean,
                              builtIn: c.unplugged.levelDeltaDb.mean, format: MicStatusText.decibels))
        }
        return lines.isEmpty ? [defaultRule] : lines
    }

    /// A recorded sample, e.g. "8.2 s of voice · L/R 0.991 · +12.0 dB against the Mac mic".
    static func sample(_ s: MicFeatureSample) -> String {
        var parts = ["\(String(format: "%.1f", s.cameraVoicedSeconds)) s of voice"]
        if s.correlation.count > 0 { parts.append("L/R \(MicStatusText.correlation(s.correlation.mean))") }
        if s.levelDeltaDb.count > 0 { parts.append("\(MicStatusText.decibels(s.levelDeltaDb.mean)) against the Mac mic") }
        return parts.joined(separator: " · ")
    }

    private static func line(_ name: String, rule: MicFeatureRule, external: Double, builtIn: Double,
                             format: (Double) -> String) -> String {
        let side = rule.externalIsHigher ? "below" : "above"
        return "\(name): built-in mic \(side) \(format(rule.threshold)) (\(MicNames.external) \(format(external)), built-in \(format(builtIn)))"
    }
}
