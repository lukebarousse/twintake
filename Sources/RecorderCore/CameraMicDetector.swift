import Foundation

// The camera mic detector: which mic the camera records with, and whether it hears the voice.
//
// Setup it was made for: an external mic (a Rode) in the camera's 3.5 mm mic jack. Unplugged,
// the camera may fall back to its built-in stereo mic without a sound, or send no sound at all
// (in take 2026-10-13_205644 the a6600's audio stayed flat at -69.4 dBFS for the 23 s between
// the unplug click and the replug click, while the Mac mic heard the voice: the silent-mic
// warning below). A mono mic in a stereo jack gives the two channels the same signal (dual mono:
// L/R correlation near 1, 0.966 to 0.992 per 6 s of voice in that take); the built-in mic's two
// capsules hear the room differently, so their correlation is lower (not measured on the a6600
// yet). A close external mic may also be louder, next to the room, than the built-in one, so its
// voice level relative to the Mac mic (which never changes) can tell them apart too; only a
// calibration uses that.
//
// The detector looks at voiced blocks only: a block whose level is `voiceMarginDb` above that
// source's running noise floor (the lowest block level of the last `noiseFloorSeconds`) and above
// `minVoiceDb`. Silence and pauses add no evidence, so they never change the verdict and never
// warn. Every feature is a mean over a window of voiced time, and a verdict changes only after
// the evidence stays past the far edge of a hysteresis band for `holdVoicedSeconds` of voice.
//
// Sounds that only the MacBook hears (typing on its keyboard, its speakers) are not the voice:
// the level against the Mac mic counts only blocks where both mics hear it, and the silent-mic
// check counts only clear sound on the Mac mic that lasts `clearVoiceRunBlocks` blocks in a row
// (a keystroke or a click is shorter). Sounds that only the camera hears are not the voice
// either: while the Mac mic runs, the correlation counts only blocks it hears too. In take
// 2026-10-13_205644 the unplug and replug clicks in the mic jack (under 1 s each, L/R -1 to 0.3,
// about 50 dB above the camera's floor, the Mac mic at its floor) pulled the 6 s mean down to
// 0.785 and 0.737, and the verdict flipped to the built-in mic although the camera sent silence
// in between.

/// Which mic the camera audio comes from.
public enum MicVerdict: String, Codable, Sendable, Hashable, CaseIterable {
    /// The external mic in the camera's mic jack (dual mono, a loud voice).
    case externalMic = "external_mic"
    /// The camera's built-in mic: the external mic is unplugged (or the camera ignores it).
    case builtInMic = "built_in_mic"
    /// Not enough voice heard yet, or the camera audio gives no clue (mono and no level rule).
    case unknown
}

/// The detector's thresholds and windows. The defaults are `standard`; a mic check uses the
/// shorter `micCheck`.
public struct MicDetectorSettings: Codable, Sendable, Hashable {
    /// A block is voiced when its RMS is this far above the source's noise floor...
    public var voiceMarginDb: Double
    /// ...and above this absolute level.
    public var minVoiceDb: Double
    /// The Mac mic hears "clear voice" (for the silent camera mic check) this far above its floor,
    /// for at least `CameraMicDetector.clearVoiceRunBlocks` blocks in a row.
    public var clearVoiceMarginDb: Double
    /// The camera mic answers a voice when it rises this far above its own floor...
    public var responseMarginDb: Double
    /// ...and above this absolute level.
    public var minResponseDb: Double
    /// The noise floor is the lowest block level of this much time.
    public var noiseFloorSeconds: Double
    /// Voiced camera time the verdict needs, and the window its features are averaged over.
    public var verdictVoicedSeconds: Double
    /// A new verdict must hold for this much voiced time before it shows.
    public var holdVoicedSeconds: Double
    /// Clear voice on the Mac mic the silent-mic check needs, and its window.
    public var silentMicVoicedSeconds: Double
    /// The camera mic counts as silent when it answers at most this share of those voiced blocks.
    public var silentResponseFraction: Double
    /// The silent warning goes away when the camera answers at least this share...
    public var recoverResponseFraction: Double
    /// ...of the last this much clear voice.
    public var recoverVoicedSeconds: Double
    /// The camera audio may lag (or lead) the Mac mic by up to this many blocks (50 ms each).
    public var lagToleranceBlocks: Int

    public init(voiceMarginDb: Double = 10, minVoiceDb: Double = -65, clearVoiceMarginDb: Double = 15,
                responseMarginDb: Double = 6, minResponseDb: Double = -90, noiseFloorSeconds: Double = 3,
                verdictVoicedSeconds: Double = 6, holdVoicedSeconds: Double = 1, silentMicVoicedSeconds: Double = 8,
                silentResponseFraction: Double = 0.1, recoverResponseFraction: Double = 0.5,
                recoverVoicedSeconds: Double = 2, lagToleranceBlocks: Int = 4) {
        self.voiceMarginDb = voiceMarginDb; self.minVoiceDb = minVoiceDb; self.clearVoiceMarginDb = clearVoiceMarginDb
        self.responseMarginDb = responseMarginDb; self.minResponseDb = minResponseDb
        self.noiseFloorSeconds = noiseFloorSeconds; self.verdictVoicedSeconds = verdictVoicedSeconds
        self.holdVoicedSeconds = holdVoicedSeconds; self.silentMicVoicedSeconds = silentMicVoicedSeconds
        self.silentResponseFraction = silentResponseFraction; self.recoverResponseFraction = recoverResponseFraction
        self.recoverVoicedSeconds = recoverVoicedSeconds; self.lagToleranceBlocks = lagToleranceBlocks
    }

    /// While recording: a verdict after 6 s of voice, the silent warning after 8 s of clear voice.
    public static let standard = MicDetectorSettings()
    /// A 10 s mic check: a verdict after 4 s of voice, the silent warning after 5 s of clear voice.
    public static let micCheck = MicDetectorSettings(verdictVoicedSeconds: 4, holdVoicedSeconds: 0.5,
                                                     silentMicVoicedSeconds: 5)

    static func blocks(_ seconds: Double) -> Int { max(1, Int((seconds * AudioBlock.perSecond).rounded())) }
}

/// What the detector says now. Plain data for the UI.
public struct MicDetectorStatus: Sendable, Equatable {
    public var verdict: MicVerdict
    /// The Mac mic hears clear voice but the camera mic stays at its noise floor.
    public var cameraMicSilent: Bool
    /// Mean L/R correlation of the camera audio over the voiced window; nil before any voice or for mono.
    public var correlation: Double?
    /// Mean camera mic level minus Mac mic level over the window of blocks where both hear the voice, in dB.
    public var levelDeltaDb: Double?
    /// Voiced camera time in the verdict window, in seconds (up to the window length).
    public var voicedSeconds: Double
    /// 0 to 1: how much of the voiced time the verdict needs has been heard.
    public var progress: Double
    /// True when a saved calibration sets the rules, false for the default rule.
    public var calibrated: Bool

    public init(verdict: MicVerdict = .unknown, cameraMicSilent: Bool = false, correlation: Double? = nil,
                levelDeltaDb: Double? = nil, voicedSeconds: Double = 0, progress: Double = 0, calibrated: Bool = false) {
        self.verdict = verdict; self.cameraMicSilent = cameraMicSilent; self.correlation = correlation
        self.levelDeltaDb = levelDeltaDb; self.voicedSeconds = voicedSeconds; self.progress = progress
        self.calibrated = calibrated
    }

    /// The silent camera mic warning.
    public static let silentMessage = "The camera mic isn't picking up your voice. Check that the mic is on and plugged in."
    /// The built-in mic warning.
    public static let builtInMessage =
        "The camera is recording with its built-in mic. Plug the external mic into the camera's mic jack."

    /// What the UI shows, or nil when there is nothing to say. The silent mic comes first.
    public var message: String? {
        if cameraMicSilent { return Self.silentMessage }
        return verdict == .builtInMic ? Self.builtInMessage : nil
    }
}

/// A verdict or warning change, for events.jsonl (`mic_detector`).
public struct MicDetectorChange: Sendable, Equatable {
    public var from: MicDetectorStatus
    public var to: MicDetectorStatus
    /// The correlation threshold in use (nil when no correlation rule applies).
    public var correlationThreshold: Double?

    public var eventData: [String: String] {
        var data = ["verdict": to.verdict.rawValue, "previous": from.verdict.rawValue,
                    "camera_mic_silent": String(to.cameraMicSilent), "voiced_s": String(format: "%.1f", to.voicedSeconds),
                    "calibrated": String(to.calibrated)]
        data["correlation"] = to.correlation.map { String(format: "%.3f", $0) }
        data["level_vs_screen_mic_db"] = to.levelDeltaDb.map { String(format: "%.1f", $0) }
        data["correlation_threshold"] = correlationThreshold.map { String(format: "%.3f", $0) }
        data["message"] = to.message
        return data
    }
}

/// Count, mean and variance of one feature (Welford), Codable so a calibration can be saved.
public struct MicFeatureStats: Codable, Sendable, Hashable {
    public var count: Int
    public var mean: Double
    /// Sum of squared differences from the mean.
    public var m2: Double

    public init(count: Int = 0, mean: Double = 0, m2: Double = 0) { self.count = count; self.mean = mean; self.m2 = m2 }

    public mutating func add(_ value: Double) {
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        m2 += delta * (value - mean)
    }

    public var variance: Double { count > 1 ? max(0, m2 / Double(count - 1)) : 0 }
    public var standardDeviation: Double { variance.squareRoot() }
}

/// The features the detector heard over a stretch of time: one calibration sample, or a take.
public struct MicFeatureSample: Codable, Sendable, Hashable {
    /// Camera L/R correlation over the voiced blocks (the ones both mics hear while the Mac mic runs).
    public var correlation: MicFeatureStats
    /// Camera level minus Mac mic level over the blocks where both mics hear the voice, in dB.
    public var levelDeltaDb: MicFeatureStats
    /// Voiced camera time, in seconds.
    public var cameraVoicedSeconds: Double
    /// Voiced Mac mic time, in seconds, with or without camera audio at the same time.
    public var referenceVoicedSeconds: Double

    public init(correlation: MicFeatureStats = MicFeatureStats(), levelDeltaDb: MicFeatureStats = MicFeatureStats(),
                cameraVoicedSeconds: Double = 0, referenceVoicedSeconds: Double = 0) {
        self.correlation = correlation; self.levelDeltaDb = levelDeltaDb
        self.cameraVoicedSeconds = cameraVoicedSeconds; self.referenceVoicedSeconds = referenceVoicedSeconds
    }

    /// The voiced time a calibration rule can use, in seconds: the blocks with an L/R correlation or
    /// a level against the Mac mic. While the Mac mic runs, those are blocks both mics hear.
    public var usableVoicedSeconds: Double {
        min(cameraVoicedSeconds, Double(max(correlation.count, levelDeltaDb.count)) / AudioBlock.perSecond)
    }

    /// Nil when the sample has enough usable voice for a calibration (`MicCalibration.minSampleSeconds`).
    /// `cameraSilent` when the Mac mic heard at least that much voice but the camera less than a
    /// quarter of it (or nothing at all); else `notEnoughVoice`.
    public var problem: MicSampleProblem? {
        let needed = MicCalibration.minSampleSeconds
        guard usableVoicedSeconds < needed else { return nil }
        if referenceVoicedSeconds >= needed, cameraVoicedSeconds < 0.25 * referenceVoicedSeconds { return .cameraSilent }
        return .notEnoughVoice
    }
}

/// One feature's rule: values on the external side of `threshold` vote for the external mic.
public struct MicFeatureRule: Codable, Sendable, Hashable {
    public var threshold: Double
    /// Half the width of the band a decided verdict must cross to change.
    public var hysteresis: Double
    /// How much this feature counts next to the other one (its separation, capped at 4).
    public var weight: Double
    /// True when higher values mean the external mic (correlation), false when lower ones do.
    public var externalIsHigher: Bool

    public init(threshold: Double, hysteresis: Double, weight: Double = 1, externalIsHigher: Bool = true) {
        self.threshold = threshold; self.hysteresis = hysteresis; self.weight = weight
        self.externalIsHigher = externalIsHigher
    }

    /// The default: L/R correlation below 0.88 means the built-in mic, with a band of ±0.01. The
    /// Rode's 6 s means were 0.966 to 0.992 in take 2026-10-13_205644 (one 5 s stretch 0.948), too
    /// close to the earlier 0.95. The built-in mic's side is not measured yet: the low means of that
    /// take (0.737 to 0.785) came from plug clicks, which no longer count. The level against the
    /// Mac mic is no default rule (the Rode was +9 to +11 dB there, the built-in mic is not
    /// measured), so only a calibration sets one.
    public static let defaultCorrelation = MicFeatureRule(threshold: 0.88, hysteresis: 0.01)

    /// How far `value` sits on the external side, in hysteresis widths, clamped to ±3.
    func score(_ value: Double) -> Double {
        let s = (value - threshold) / max(hysteresis, 1e-9) * (externalIsHigher ? 1 : -1)
        return min(3, max(-3, s))
    }
}

/// Why a mic check sample cannot be a calibration sample (`MicFeatureSample.problem`).
public enum MicSampleProblem: String, Sendable, Hashable {
    /// Less usable voice than a calibration sample needs, and the camera was not silent: talk for
    /// the whole check (while the Mac mic runs, it must hear the voice too).
    case notEnoughVoice = "not_enough_voice"
    /// The Mac mic heard the voice, but the camera audio held hardly any: the camera sends no
    /// sound from a mic. With the external mic unplugged, the camera did not switch to its built-in
    /// mic (a plug still in its mic jack keeps the external input; or the camera mutes it).
    case cameraSilent = "camera_silent"
}

/// Why `MicCalibration.make(plugged:unplugged:)` failed.
public enum MicCalibrationError: Error, Sendable, Equatable, LocalizedError {
    /// A sample has less usable voice than a rule needs (`seconds`: `MicFeatureSample.usableVoicedSeconds`).
    case notEnoughVoice(sample: String, seconds: Double)
    /// The two samples sound alike: no feature tells them apart.
    case samplesDoNotDiffer
    /// The plugged-in sample sounds like the built-in mic and the unplugged one like the external
    /// mic: lower L/R correlation (or, with no correlation rule, a lower level) with the mic plugged in.
    case samplesSwapped

    public var errorDescription: String? {
        switch self {
        case let .notEnoughVoice(sample, seconds):
            "The \(sample) sample has \(String(format: "%.1f", seconds)) s of voice. Talk for at least "
                + "\(String(format: "%.0f", MicCalibration.minSampleSeconds)) s and try again."
        case .samplesDoNotDiffer:
            "The two samples sound the same, so the app cannot tell the mics apart. Check that the external mic "
                + "was plugged in for the first sample and unplugged for the second."
        case .samplesSwapped:
            "The first sample sounds like the built-in mic and the second like the external mic. Plug the "
                + "external mic in for the first sample, unplug it for the second, and record both again."
        }
    }
}

/// The rules from a "mic plugged in" and a "mic unplugged" sample. Small and Codable: the app
/// saves it (JSON) and hands it to `AudioLevelMonitor`.
///
/// Each feature gets a threshold between the two samples' means, where both are the same number
/// of standard deviations away (kept inside the middle half of the gap), and a hysteresis of 10%
/// of the gap. A feature whose means are less than one pooled standard deviation apart is not used.
///
/// The samples must point the way the mics work: a mono external mic gives dual mono, so its L/R
/// correlation is the higher one. Swapped samples would save an inverted rule (a warning with the
/// external mic in, none without it), so they are refused.
public struct MicCalibration: Codable, Sendable, Hashable {
    /// 2: the level against the Mac mic counts only blocks where both mics hear the voice.
    public static let currentVersion = 2
    /// Voiced time each sample needs for a rule.
    public static let minSampleSeconds = 3.0
    /// Smallest mean difference that counts.
    static let minCorrelationGap = 0.003
    static let minLevelGapDb = 2.0

    public var version: Int
    public var plugged: MicFeatureSample
    public var unplugged: MicFeatureSample
    /// Nil when correlation does not tell the samples apart (or a sample was mono).
    public var correlation: MicFeatureRule?
    /// Nil when the level against the Mac mic does not tell them apart (or there was no Mac mic).
    public var levelDelta: MicFeatureRule?

    public init(version: Int = MicCalibration.currentVersion, plugged: MicFeatureSample, unplugged: MicFeatureSample,
                correlation: MicFeatureRule?, levelDelta: MicFeatureRule?) {
        self.version = version; self.plugged = plugged; self.unplugged = unplugged
        self.correlation = correlation; self.levelDelta = levelDelta
    }

    /// Builds the rules from two mic check samples (`MicCheck.Result.sample`).
    public static func make(plugged: MicFeatureSample, unplugged: MicFeatureSample) throws(MicCalibrationError) -> MicCalibration {
        let minBlocks = MicDetectorSettings.blocks(minSampleSeconds)
        for (name, sample) in [("plugged-in", plugged), ("unplugged", unplugged)]
        where sample.correlation.count < minBlocks && sample.levelDeltaDb.count < minBlocks {
            throw .notEnoughVoice(sample: name, seconds: sample.usableVoicedSeconds)
        }
        let correlation = rule(plugged.correlation, unplugged.correlation, minCount: minBlocks, minGap: minCorrelationGap)
        let level = rule(plugged.levelDeltaDb, unplugged.levelDeltaDb, minCount: minBlocks, minGap: minLevelGapDb)
        guard correlation != nil || level != nil else { throw .samplesDoNotDiffer }
        // The correlation decides the order when it tells the samples apart; else the level (a
        // close external mic is louder than the built-in one).
        if let decisive = correlation ?? level, !decisive.externalIsHigher { throw .samplesSwapped }
        return MicCalibration(plugged: plugged, unplugged: unplugged, correlation: correlation, levelDelta: level)
    }

    static func rule(_ p: MicFeatureStats, _ u: MicFeatureStats, minCount: Int, minGap: Double) -> MicFeatureRule? {
        guard p.count >= minCount, u.count >= minCount else { return nil }
        let gap = p.mean - u.mean
        guard abs(gap) >= minGap else { return nil }
        let sp = p.standardDeviation, su = u.standardDeviation
        let pooled = ((sp * sp + su * su) / 2).squareRoot()
        let separation = pooled > 1e-12 ? abs(gap) / pooled : 4
        guard separation >= 1 else { return nil }
        // Equal z-scores from both means, inside the middle half of the gap.
        var threshold = sp + su > 1e-12 ? (u.mean * sp + p.mean * su) / (sp + su) : (p.mean + u.mean) / 2
        let low = min(p.mean, u.mean) + 0.25 * abs(gap), high = max(p.mean, u.mean) - 0.25 * abs(gap)
        threshold = min(high, max(low, threshold))
        return MicFeatureRule(threshold: threshold, hysteresis: 0.1 * abs(gap), weight: min(4, separation),
                              externalIsHigher: gap > 0)
    }
}

/// The detector's verdict for one take, for session.json (on camera.mov's mic track, `mic_source`).
public struct MicSourceReport: Codable, Sendable, Hashable {
    /// The verdict at Stop.
    public var verdict: MicVerdict
    /// Every verdict the take reached, in order (`unknown` left out).
    public var verdictsSeen: [MicVerdict]
    /// The silent camera mic warning was on at some point.
    public var cameraMicSilent: Bool
    /// Mean camera L/R correlation over the take's voiced camera blocks.
    public var meanCorrelation: Double?
    /// Mean camera level minus Mac mic level over the take's blocks where both mics hear the voice, in dB.
    public var levelVsScreenMicDb: Double?
    /// Voiced camera time in the take, in seconds.
    public var voicedS: Double
    /// Voiced Mac mic time in the take, in seconds.
    public var screenMicVoicedS: Double
    /// True when a saved calibration set the rules.
    public var calibrated: Bool
    /// The correlation threshold used, nil when no correlation rule applied.
    public var correlationThreshold: Double?

    public init(verdict: MicVerdict, verdictsSeen: [MicVerdict], cameraMicSilent: Bool, meanCorrelation: Double?,
                levelVsScreenMicDb: Double?, voicedS: Double, screenMicVoicedS: Double, calibrated: Bool,
                correlationThreshold: Double?) {
        self.verdict = verdict; self.verdictsSeen = verdictsSeen; self.cameraMicSilent = cameraMicSilent
        self.meanCorrelation = meanCorrelation; self.levelVsScreenMicDb = levelVsScreenMicDb; self.voicedS = voicedS
        self.screenMicVoicedS = screenMicVoicedS; self.calibrated = calibrated
        self.correlationThreshold = correlationThreshold
    }
}

/// The lowest block level of the last `capacity` blocks: a running noise floor. Speech has dips
/// between words within a few seconds, so the floor stays at the room noise while one talks.
struct NoiseFloor: Sendable {
    private var levels: [Double]
    private var next = 0
    private var count = 0
    private(set) var floorDb = AudioBlock.silenceDb

    init(blocks: Int) { levels = [Double](repeating: AudioBlock.silenceDb, count: max(1, blocks)) }

    @discardableResult
    mutating func add(_ db: Double) -> Double {
        levels[next] = db
        next = (next + 1) % levels.count
        count = min(count + 1, levels.count)
        var low = Double.infinity
        for i in 0..<count { low = min(low, levels[i]) }
        floorDb = low
        return low
    }
}

/// A running mean over the last `capacity` values.
struct RunningMean: Sendable {
    private var values: [Double]
    private var next = 0
    private(set) var count = 0
    private var sum = 0.0

    init(capacity: Int) { values = [Double](repeating: 0, count: max(1, capacity)) }

    var capacity: Int { values.count }
    var isFull: Bool { count == values.count }
    var mean: Double? { count > 0 ? sum / Double(count) : nil }

    mutating func add(_ value: Double) {
        if count == values.count { sum -= values[next] } else { count += 1 }
        values[next] = value
        sum += value
        next = (next + 1) % values.count
        // Sum again once per lap, so rounding never builds up.
        if next == 0 { sum = values[0..<count].reduce(0, +) }
    }
}

/// The last `capacity` yes/no answers.
struct AnswerWindow: Sendable {
    private var answers: [Bool]
    private var next = 0
    private(set) var count = 0
    private(set) var yes = 0

    init(capacity: Int) { answers = [Bool](repeating: false, count: max(1, capacity)) }

    var capacity: Int { answers.count }
    var isFull: Bool { count == answers.count }

    mutating func add(_ answer: Bool) {
        if count == answers.count { if answers[next] { yes -= 1 } } else { count += 1 }
        answers[next] = answer
        if answer { yes += 1 }
        next = (next + 1) % answers.count
    }

    /// The share of yes among the last `n` answers (fewer when fewer came).
    func recentShare(_ n: Int) -> Double {
        let n = min(n, count)
        guard n > 0 else { return 0 }
        var hits = 0
        for k in 1...n where answers[(next - k + answers.count) % answers.count] { hits += 1 }
        return Double(hits) / Double(n)
    }
}

/// Decides, block by block, which mic the camera records with and whether it hears the voice.
/// Pure: it takes paired `AudioBlock`s (camera mic, Mac mic) in time order and keeps no clock.
public struct CameraMicDetector: Sendable {
    /// Clear sound on the Mac mic counts as voice for the silent-mic check only in a run of this
    /// many blocks (150 ms): a keystroke on the MacBook is a block or two, a spoken word longer.
    public static let clearVoiceRunBlocks = 3

    public private(set) var settings: MicDetectorSettings
    public private(set) var status: MicDetectorStatus
    /// Everything heard since the detector started (a take, or a mic check's calibration sample).
    public private(set) var sample = MicFeatureSample()

    private var correlationRule: MicFeatureRule?
    private var levelRule: MicFeatureRule?
    private var cameraFloor: NoiseFloor
    private var referenceFloor: NoiseFloor
    private var correlations: RunningMean
    private var deltas: RunningMean
    /// The last 2L+1 blocks, for the silent mic check: does the camera answer near a clear voice block?
    private var recent: [Probe]
    private var recentNext = 0
    private var recentCount = 0
    private var answers: AnswerWindow
    private var pending: (verdict: MicVerdict, count: Int)?
    private var verdictsSeen: [MicVerdict] = []
    private var silentSeen = false
    private var cameraBlocks = 0
    private var cameraVoicedBlocks = 0
    private var referenceVoicedBlocks = 0

    private struct Probe: Sendable {
        var clearVoice = false
        var cameraPresent = false
        var cameraAnswers = false
    }

    public init(settings: MicDetectorSettings = .standard, calibration: MicCalibration? = nil) {
        self.settings = settings
        status = MicDetectorStatus()
        let floorBlocks = MicDetectorSettings.blocks(settings.noiseFloorSeconds)
        cameraFloor = NoiseFloor(blocks: floorBlocks)
        referenceFloor = NoiseFloor(blocks: floorBlocks)
        correlations = RunningMean(capacity: MicDetectorSettings.blocks(settings.verdictVoicedSeconds))
        deltas = RunningMean(capacity: MicDetectorSettings.blocks(settings.verdictVoicedSeconds))
        recent = [Probe](repeating: Probe(), count: 2 * max(0, settings.lagToleranceBlocks) + 1)
        answers = AnswerWindow(capacity: MicDetectorSettings.blocks(settings.silentMicVoicedSeconds))
        setCalibration(calibration)
    }

    /// The rules from `calibration`, or the default correlation rule. Keeps the evidence.
    public mutating func setCalibration(_ calibration: MicCalibration?) {
        if let calibration {
            correlationRule = calibration.correlation
            levelRule = calibration.levelDelta
        } else {
            correlationRule = .defaultCorrelation
            levelRule = nil
        }
        status.calibrated = calibration != nil
    }

    /// The correlation threshold in use.
    public var correlationThreshold: Double? { correlationRule?.threshold }

    /// One block of time: the camera mic's block and the Mac mic's block (either may be missing).
    /// Returns the change when the verdict or the silent warning changed.
    public mutating func add(camera: AudioBlock?, reference: AudioBlock?) -> MicDetectorChange? {
        let before = status
        var cameraVoiced = false
        var cameraAnswers = false
        if let camera {
            cameraBlocks += 1
            let level = camera.rmsDb
            let floor = cameraFloor.add(level)
            cameraVoiced = level > floor + settings.voiceMarginDb && level > settings.minVoiceDb
            cameraAnswers = level > floor + settings.responseMarginDb && level > settings.minResponseDb
        }
        var referenceVoiced = false
        var clearVoice = false
        if let reference {
            let level = reference.rmsDb
            let floor = referenceFloor.add(level)
            referenceVoiced = level > floor + settings.voiceMarginDb && level > settings.minVoiceDb
            clearVoice = level > floor + settings.clearVoiceMarginDb && level > settings.minVoiceDb
        }

        var evidence = false
        if cameraVoiced { cameraVoicedBlocks += 1 }
        // Counted with or without a camera block: a camera that sends nothing is "silent", not "too
        // little voice" (`MicFeatureSample.problem`).
        if referenceVoiced { referenceVoicedBlocks += 1 }
        // The correlation counts only the voice. With the Mac mic running, that is a block both mics
        // hear: a sound only the camera hears (the click of a plug in its mic jack, handling noise)
        // is no voice. Without a Mac mic block (Camera mode with no Mac mic, screen mic None), the
        // camera's own voiced blocks count.
        if cameraVoiced, reference == nil || referenceVoiced, let r = camera?.correlation, r.isFinite {
            correlations.add(r)
            sample.correlation.add(r)
            evidence = true
        }
        // Only when the camera hears it too: a sound only the MacBook hears (its keyboard, its
        // speakers) says nothing about the camera's mic.
        if referenceVoiced, cameraVoiced, let camera, let reference {
            let delta = camera.rmsDb - reference.rmsDb
            deltas.add(delta)
            sample.levelDeltaDb.add(delta)
            if levelRule != nil { evidence = true }
        }
        sample.cameraVoicedSeconds = Double(cameraVoicedBlocks) / AudioBlock.perSecond
        sample.referenceVoicedSeconds = Double(referenceVoicedBlocks) / AudioBlock.perSecond

        checkSilentMic(Probe(clearVoice: clearVoice, cameraPresent: camera != nil, cameraAnswers: cameraAnswers))
        if evidence { decide() }

        status.correlation = correlations.mean
        status.levelDeltaDb = deltas.mean
        status.voicedSeconds = Double(correlations.count) / AudioBlock.perSecond
        let needed = Double(correlations.capacity)
        if correlationRule != nil {
            status.progress = min(1, Double(correlations.count) / needed)
        } else {
            status.progress = levelRule == nil ? 0 : min(1, Double(deltas.count) / needed)
        }
        guard status.verdict != before.verdict || status.cameraMicSilent != before.cameraMicSilent else { return nil }
        return MicDetectorChange(from: before, to: status, correlationThreshold: correlationRule?.threshold)
    }

    /// The silent camera mic: the Mac mic hears clear voice for `silentMicVoicedSeconds` and the
    /// camera mic hardly ever rises above its floor within the lag tolerance of those blocks.
    private mutating func checkSilentMic(_ probe: Probe) {
        recent[recentNext] = probe
        recentNext = (recentNext + 1) % recent.count
        recentCount = min(recentCount + 1, recent.count)
        guard recentCount == recent.count else { return }
        // The middle of the window: `lagToleranceBlocks` before and after it are known.
        let half = recent.count / 2
        let window = recent, oldest = recentNext
        func held(_ k: Int) -> Probe { window[(oldest + k) % window.count] }
        let middle = held(half)
        guard middle.clearVoice, middle.cameraPresent else { return }
        // Part of a run of clear blocks, not a keystroke or a click on the MacBook.
        var run = 1
        var k = half - 1
        while k >= 0, held(k).clearVoice { run += 1; k -= 1 }
        k = half + 1
        while k < window.count, held(k).clearVoice { run += 1; k += 1 }
        guard run >= min(Self.clearVoiceRunBlocks, recent.count) else { return }
        answers.add(recent.contains { $0.cameraAnswers })
        if !status.cameraMicSilent {
            if answers.isFull, Double(answers.yes) <= settings.silentResponseFraction * Double(answers.capacity) {
                status.cameraMicSilent = true
                silentSeen = true
            }
        } else if answers.recentShare(MicDetectorSettings.blocks(settings.recoverVoicedSeconds))
                    >= settings.recoverResponseFraction {
            status.cameraMicSilent = false
        }
    }

    /// Combines the features over full windows into a verdict, with hysteresis and a hold.
    private mutating func decide() {
        var weighted = 0.0, weights = 0.0
        if let rule = correlationRule, correlations.isFull, let mean = correlations.mean {
            weighted += rule.weight * rule.score(mean)
            weights += rule.weight
        }
        if let rule = levelRule, deltas.isFull, let mean = deltas.mean {
            weighted += rule.weight * rule.score(mean)
            weights += rule.weight
        }
        guard weights > 0 else { return }
        let z = weighted / weights
        let candidate: MicVerdict
        switch status.verdict {
        case .unknown: candidate = z >= 0 ? .externalMic : .builtInMic
        case .externalMic: candidate = z <= -1 ? .builtInMic : .externalMic
        case .builtInMic: candidate = z >= 1 ? .externalMic : .builtInMic
        }
        guard candidate != status.verdict else {
            pending = nil
            return
        }
        let count = (pending?.verdict == candidate ? pending?.count ?? 0 : 0) + 1
        if count >= MicDetectorSettings.blocks(settings.holdVoicedSeconds) {
            status.verdict = candidate
            pending = nil
            if verdictsSeen.last != candidate { verdictsSeen.append(candidate) }
        } else {
            pending = (candidate, count)
        }
    }

    /// The report for session.json, or nil when no camera audio came.
    public func report() -> MicSourceReport? {
        guard cameraBlocks > 0 else { return nil }
        return MicSourceReport(
            verdict: status.verdict, verdictsSeen: verdictsSeen, cameraMicSilent: silentSeen,
            meanCorrelation: sample.correlation.count > 0 ? Self.round(sample.correlation.mean, 4) : nil,
            levelVsScreenMicDb: sample.levelDeltaDb.count > 0 ? Self.round(sample.levelDeltaDb.mean, 1) : nil,
            voicedS: Self.round(sample.cameraVoicedSeconds, 2), screenMicVoicedS: Self.round(sample.referenceVoicedSeconds, 2),
            calibrated: status.calibrated, correlationThreshold: correlationRule.map { Self.round($0.threshold, 4) })
    }

    static func round(_ value: Double, _ digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }
}
