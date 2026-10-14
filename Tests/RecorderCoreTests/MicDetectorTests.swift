import Foundation
import Testing
@testable import RecorderCore

/// A block at `db` dBFS RMS (the peak 3 dB above it).
func audioBlock(_ index: Int64, db: Double, correlation: Double? = nil, channels: Int = 2, clipped: Int = 0) -> AudioBlock {
    let meanSquare = db <= AudioBlock.silenceDb ? 0 : pow(10, db / 10)
    return AudioBlock(index: index, frames: 2400, channels: channels, peak: Float((2 * meanSquare).squareRoot()),
                      meanSquare: meanSquare, clipped: clipped, correlation: correlation)
}

/// Talks in phrases: 0.6 s of voice, 0.2 s between words, and a 1.5 s pause every 5 s.
func talking(_ block: Int64) -> Bool {
    let inCycle = block % 100
    guard inCycle < 70 else { return false }
    return inCycle % 16 < 12
}

/// The camera mic and the Mac mic over `blocks` blocks of time, from `start`.
struct Scene {
    /// Camera voice level and noise floor (dBFS), and its L/R correlation while voiced.
    var cameraVoiceDb = -30.0
    var cameraNoiseDb = -70.0
    var voicedCorrelation: Double? = 0.995
    var noiseCorrelation: Double? = 0.1
    /// The camera hears the voice `cameraLagBlocks` later than the Mac mic.
    var cameraLagBlocks: Int64 = 0
    var cameraPresent = true
    var referenceVoiceDb = -36.0
    var referenceNoiseDb = -62.0
    var referencePresent = true
    var speaking: (Int64) -> Bool = talking

    func run(_ detector: inout CameraMicDetector, from start: Int64 = 0, blocks: Int64,
             onChange: (Int64, MicDetectorChange) -> Void = { _, _ in }) {
        for i in start..<(start + blocks) {
            let cameraTalks = speaking(i - cameraLagBlocks)
            let camera = cameraPresent
                ? audioBlock(i, db: cameraTalks ? cameraVoiceDb : cameraNoiseDb,
                             correlation: cameraTalks ? voicedCorrelation : noiseCorrelation) : nil
            let reference = referencePresent
                ? audioBlock(i, db: speaking(i) ? referenceVoiceDb : referenceNoiseDb, channels: 1) : nil
            if let change = detector.add(camera: camera, reference: reference) { onChange(i, change) }
        }
    }
}

@Suite struct MicDetectorTests {
    @Test func blockLevelsInDecibels() {
        #expect(audioBlock(0, db: -20).rmsDb.rounded() == -20)
        #expect(AudioBlock(index: 0, frames: 1, channels: 1, peak: 1, meanSquare: 1).rmsDb == 0)
        #expect(AudioBlock(index: 0, frames: 1, channels: 1, peak: 0.5, meanSquare: 0).rmsDb == AudioBlock.silenceDb)
        #expect(abs(AudioBlock(index: 0, frames: 1, channels: 1, peak: 0.5, meanSquare: 0).peakDb + 6.02) < 0.01)
        #expect(AudioBlock.index(atNs: 149_999_999) == 2 && AudioBlock.index(atNs: 150_000_000) == 3)
    }

    /// The Rode in the mic jack: dual mono. The verdict waits for 6 s of voice, then says external.
    @Test func dualMonoIsTheExternalMic() {
        var detector = CameraMicDetector()
        var changes: [(Int64, MicDetectorChange)] = []
        Scene().run(&detector, blocks: 600) { changes.append(($0, $1)) }
        #expect(detector.status.verdict == .externalMic)
        #expect(!detector.status.cameraMicSilent)
        #expect(detector.status.message == nil)
        #expect(changes.count == 1)
        // 6 s of voice plus the 1 s hold: never before 7 s of time.
        let first = changes.first?.0 ?? 0
        #expect(first >= 140, "verdict at block \(first)")
        #expect(changes.first?.1.to.verdict == .externalMic)
        #expect((detector.status.correlation ?? 0) > 0.99)
        #expect(detector.status.progress == 1)
    }

    /// The camera's built-in stereo mic: the capsules hear the room differently.
    @Test func decorrelatedStereoIsTheBuiltInMic() {
        var detector = CameraMicDetector()
        Scene(cameraVoiceDb: -42, voicedCorrelation: 0.8).run(&detector, blocks: 600)
        #expect(detector.status.verdict == .builtInMic)
        #expect(detector.status.message == MicDetectorStatus.builtInMessage)
        #expect(!detector.status.cameraMicSilent)
    }

    /// Plain silence and long pauses add no evidence and never warn.
    @Test func silenceAndPausesNeverWarn() {
        var detector = CameraMicDetector()
        var changes = 0
        Scene(speaking: { _ in false }).run(&detector, blocks: 1200) { _, _ in changes += 1 }
        #expect(changes == 0)
        #expect(detector.status == MicDetectorStatus(voicedSeconds: 0))

        // A verdict, then a minute of silence: it stays, with no warning.
        Scene().run(&detector, from: 1200, blocks: 600) { _, _ in changes += 1 }
        #expect(detector.status.verdict == .externalMic)
        Scene(speaking: { _ in false }).run(&detector, from: 1800, blocks: 1200) { _, _ in changes += 1 }
        #expect(changes == 1)
        #expect(detector.status.verdict == .externalMic && !detector.status.cameraMicSilent)
    }

    /// Mono camera audio has no correlation: without a level rule the verdict stays unknown.
    @Test func monoCameraAudioStaysUnknown() {
        var detector = CameraMicDetector()
        Scene(voicedCorrelation: nil, noiseCorrelation: nil).run(&detector, blocks: 800)
        #expect(detector.status.verdict == .unknown)
        #expect(detector.status.correlation == nil)
    }

    /// Correlation near the threshold does not flicker: a decided verdict changes only past the far
    /// edge of the band (0.87 / 0.89 around the default 0.88) and after the hold.
    @Test func hysteresisKeepsTheVerdict() {
        var detector = CameraMicDetector()
        var changes: [MicVerdict] = []
        let record: (Int64, MicDetectorChange) -> Void = { changes.append($1.to.verdict) }
        Scene(voicedCorrelation: 0.97).run(&detector, blocks: 600, onChange: record)
        #expect(changes == [.externalMic])
        // Inside the band (0.875), then wobbling around 0.88 block by block.
        Scene(voicedCorrelation: 0.875).run(&detector, from: 600, blocks: 800, onChange: record)
        #expect(changes == [.externalMic])
        var mixed = detector
        for i in Int64(1400)..<2400 {
            let voiced = talking(i)
            let r = i % 2 == 0 ? 0.865 : 0.895
            _ = mixed.add(camera: audioBlock(i, db: voiced ? -30 : -70, correlation: voiced ? r : 0.1),
                          reference: audioBlock(i, db: voiced ? -36 : -62, channels: 1)).map { record(i, $0) }
        }
        #expect(changes == [.externalMic])
        // Past the far edge: built-in. Back inside the band: still built-in. Past the other edge: external.
        Scene(voicedCorrelation: 0.85).run(&detector, from: 1400, blocks: 600, onChange: record)
        #expect(changes == [.externalMic, .builtInMic])
        Scene(voicedCorrelation: 0.885).run(&detector, from: 2000, blocks: 800, onChange: record)
        #expect(changes == [.externalMic, .builtInMic])
        Scene(voicedCorrelation: 0.905).run(&detector, from: 2800, blocks: 600, onChange: record)
        #expect(changes == [.externalMic, .builtInMic, .externalMic])
        #expect(detector.report()?.verdictsSeen == [.externalMic, .builtInMic, .externalMic])
    }

    /// The default rule against take 2026-10-13_205644. The Rode's 6 s means were 0.966 to 0.992,
    /// and one 5 s stretch of it 0.948: only 0.002 from the old default 0.95. The lowest 6 s means
    /// of that take, 0.737 to 0.785, came from the plug clicks at the unplug and the replug (no
    /// voice: see `plugClicksInTheMicJackAreNotVoice`); the a6600's built-in mic is not measured
    /// yet. They stay here as a decorrelated mic. With 0.88 and its ±0.01 band, each Rode value
    /// says external and each low value built-in.
    @Test func theDefaultRuleWithTheMeasuredValues() {
        #expect(MicFeatureRule.defaultCorrelation.threshold == 0.88 && MicFeatureRule.defaultCorrelation.hysteresis == 0.01)
        #expect(MicFeatureRule.defaultCorrelation.externalIsHigher && CameraMicDetector().correlationThreshold == 0.88)
        for rode in [0.948, 0.966, 0.975, 0.992] {
            var detector = CameraMicDetector()
            Scene(voicedCorrelation: rode).run(&detector, blocks: 600)
            #expect(detector.status.verdict == .externalMic, "Rode \(rode)")
        }
        for low in [0.737, 0.74, 0.785, 0.79] {
            var detector = CameraMicDetector()
            Scene(voicedCorrelation: low).run(&detector, blocks: 600)
            #expect(detector.status.verdict == .builtInMic, "low \(low)")
        }
        // The take's order: the Rode, unplugged, plugged back in. Each change once, after the hold.
        var detector = CameraMicDetector()
        var changes: [MicVerdict] = []
        Scene(voicedCorrelation: 0.966).run(&detector, blocks: 600) { changes.append($1.to.verdict) }
        Scene(voicedCorrelation: 0.785).run(&detector, from: 600, blocks: 800) { changes.append($1.to.verdict) }
        Scene(voicedCorrelation: 0.992).run(&detector, from: 1400, blocks: 800) { changes.append($1.to.verdict) }
        #expect(changes == [.externalMic, .builtInMic, .externalMic])
        // A decided Rode verdict holds inside the band (a 6 s mean of 0.875).
        var rode = CameraMicDetector()
        Scene(voicedCorrelation: 0.966).run(&rode, blocks: 600)
        Scene(voicedCorrelation: 0.875).run(&rode, from: 600, blocks: 800)
        #expect(rode.status.verdict == .externalMic)
        // The level is no default rule: a camera 10 dB above the Mac mic says nothing by itself.
        var mono = CameraMicDetector()
        Scene(cameraVoiceDb: -26, voicedCorrelation: nil, noiseCorrelation: nil).run(&mono, blocks: 600)
        #expect(mono.status.verdict == .unknown && abs((mono.status.levelDeltaDb ?? 0) - 10) < 0.01)
    }

    /// Take 2026-10-13_205644, as measured block by block: the Rode, the click of the unplug, 23 s
    /// of flat silence from the camera (-69.4 dBFS) while the Mac mic hears the voice, the click of
    /// the replug, the Rode again. The clicks are loud on the camera only (L/R -1 to 0.3, the Mac mic
    /// at its floor): they are no voice. The verdict stays external (with the camera's own voiced
    /// blocks counted, the replug click pulled the 6 s mean to 0.737 and flipped it to built-in),
    /// and the silent-mic warning comes on during the silence and goes once the Rode is back.
    @Test func plugClicksInTheMicJackAreNotVoice() {
        var detector = CameraMicDetector()
        var verdicts: [MicVerdict] = []
        var silent: [Bool] = []
        let record: (Int64, MicDetectorChange) -> Void = { _, change in
            if change.to.verdict != change.from.verdict { verdicts.append(change.to.verdict) }
            if change.to.cameraMicSilent != change.from.cameraMicSilent { silent.append(change.to.cameraMicSilent) }
        }
        let clickCorrelations = [-0.98, -0.78, -0.4, 0.18, 0.27, -0.6, -1.0, 0.08]
        func click(from start: Int64) {
            for i in start..<(start + 20) {
                let camera = audioBlock(i, db: -15 - Double(i % 5) * 4, correlation: clickCorrelations[Int(i % 8)])
                if let change = detector.add(camera: camera, reference: audioBlock(i, db: -68 + Double(i % 3), channels: 1)) {
                    record(i, change)
                }
            }
        }
        Scene(voicedCorrelation: 0.98).run(&detector, blocks: 600, onChange: record)
        click(from: 600)
        Scene(cameraVoiceDb: -69.4, cameraNoiseDb: -69.4, voicedCorrelation: 0.88, noiseCorrelation: 0.88,
              referenceVoiceDb: -40, referenceNoiseDb: -68).run(&detector, from: 620, blocks: 460, onChange: record)
        click(from: 1080)
        Scene(voicedCorrelation: 0.99).run(&detector, from: 1100, blocks: 600, onChange: record)
        #expect(verdicts == [.externalMic])
        #expect(silent == [true, false])
        #expect(detector.status.verdict == .externalMic && (detector.status.correlation ?? 0) > 0.97)
        #expect(detector.report()?.verdictsSeen == [.externalMic] && detector.report()?.cameraMicSilent == true)
        // Without a Mac mic (Camera mode, screen mic None) the camera's own voiced blocks count.
        var cameraOnly = CameraMicDetector()
        Scene(voicedCorrelation: 0.98, referencePresent: false).run(&cameraOnly, blocks: 600)
        #expect(cameraOnly.status.verdict == .externalMic)
    }

    /// A camera that sends nothing at all while the Mac mic hears the voice: the sample says the
    /// camera is silent, not that there was too little voice ("Only 0.0 s of voice").
    @Test func aCameraThatSendsNothingIsSilentNotQuiet() {
        var detector = CameraMicDetector(settings: .micCheck)
        Scene(cameraPresent: false).run(&detector, blocks: 200)
        #expect(detector.sample.cameraVoicedSeconds == 0 && detector.sample.referenceVoicedSeconds >= 4)
        #expect(detector.sample.problem == .cameraSilent)
    }

    /// The Mac mic hears clear voice while the camera mic stays at its floor: after 8 s of voice,
    /// "the camera mic isn't picking up your voice". It goes away once the camera hears the voice.
    @Test func aSilentCameraMicWarnsAfterEightSecondsOfVoice() {
        var detector = CameraMicDetector()
        var changes: [(Int64, MicDetectorChange)] = []
        Scene(cameraVoiceDb: -80, cameraNoiseDb: -80).run(&detector, blocks: 800) { changes.append(($0, $1)) }
        #expect(detector.status.cameraMicSilent)
        #expect(detector.status.message == MicDetectorStatus.silentMessage)
        #expect(detector.status.verdict == .unknown)
        let warnedAt = changes.first?.0 ?? 0
        // 8 s of clear voice is 160 voiced blocks: at 54 voiced blocks per 100, past block 260.
        #expect(warnedAt > 260, "warned at block \(warnedAt)")
        #expect(changes.count == 1)

        // The mic is switched on: the warning clears within a few seconds of voice.
        Scene().run(&detector, from: 800, blocks: 200) { changes.append(($0, $1)) }
        #expect(!detector.status.cameraMicSilent)
        #expect(changes.count == 2 && (changes.last?.0 ?? 0) < 900)
        #expect(detector.report()?.cameraMicSilent == true)
    }

    /// Digital silence on the camera (its audio off) warns too.
    @Test func digitalSilenceOnTheCameraWarns() {
        var detector = CameraMicDetector()
        Scene(cameraVoiceDb: AudioBlock.silenceDb, cameraNoiseDb: AudioBlock.silenceDb, voicedCorrelation: nil,
              noiseCorrelation: nil).run(&detector, blocks: 800)
        #expect(detector.status.cameraMicSilent)
    }

    /// A camera that hears the voice 150 ms after the Mac mic is not silent.
    @Test func cameraLagIsTolerated() {
        var detector = CameraMicDetector()
        Scene(cameraLagBlocks: 3).run(&detector, blocks: 1000)
        #expect(!detector.status.cameraMicSilent)
        #expect(detector.status.verdict == .externalMic)
    }

    /// No camera audio at all (Screen mode), or no Mac mic (Camera mode): no silent warning.
    @Test func aMissingSourceNeverWarns() {
        var detector = CameraMicDetector()
        Scene(cameraPresent: false).run(&detector, blocks: 1000)
        #expect(!detector.status.cameraMicSilent && detector.status.verdict == .unknown)
        #expect(detector.report() == nil)

        var cameraOnly = CameraMicDetector()
        Scene(referencePresent: false).run(&cameraOnly, blocks: 600)
        #expect(cameraOnly.status.verdict == .externalMic && !cameraOnly.status.cameraMicSilent)
        #expect(cameraOnly.status.levelDeltaDb == nil)
        let report = cameraOnly.report()
        #expect(report?.levelVsScreenMicDb == nil && report?.screenMicVoicedS == 0)
    }

    /// Typing on the MacBook in a pause: short loud blocks (one or two of 50 ms) on the Mac mic
    /// only, the camera at its floor. Not voice: no silent-mic warning, however long it lasts.
    @Test func typingOnTheMacBookNeverWarns() {
        let patterns: [(Int64) -> Bool] = [{ $0 % 3 == 0 }, { $0 % 5 < 2 }, { $0 % 4 == 0 || $0 % 7 == 0 }]
        for burst in patterns {
            var detector = CameraMicDetector()
            Scene().run(&detector, blocks: 400)
            #expect(detector.status.verdict == .externalMic)
            var changes = 0
            for i in Int64(400)..<1600 {
                _ = detector.add(camera: audioBlock(i, db: -70, correlation: 0.1),
                                 reference: audioBlock(i, db: burst(i) ? -30 : -62, channels: 1)).map { _ in changes += 1 }
            }
            #expect(changes == 0 && !detector.status.cameraMicSilent)
            #expect(detector.status.verdict == .externalMic)
        }
    }

    /// A sound only the Mac mic hears (typing, its speakers) adds no level evidence: with a
    /// level-only calibration, the Rode verdict stays through 10 s of it.
    @Test func macMicOnlySoundsAreNotLevelEvidence() throws {
        let plugged = MicCalibrationTests().wobblySample(correlation: 0.995, spread: 0.003, delta: 8, deltaSpread: 2)
        let unplugged = MicCalibrationTests().wobblySample(correlation: 0.995, spread: 0.003, delta: -4, deltaSpread: 2)
        let calibration = try MicCalibration.make(plugged: plugged, unplugged: unplugged)
        #expect(calibration.correlation == nil && calibration.levelDelta != nil)
        var detector = CameraMicDetector(calibration: calibration)
        Scene(cameraVoiceDb: -28, voicedCorrelation: nil, noiseCorrelation: nil).run(&detector, blocks: 600)
        #expect(detector.status.verdict == .externalMic)
        let deltaBefore = detector.status.levelDeltaDb
        var changes = 0
        for i in Int64(600)..<800 {
            // Loud on the Mac mic (voiced for it), the camera hears nothing.
            _ = detector.add(camera: audioBlock(i, db: -70),
                             reference: audioBlock(i, db: i % 2 == 0 ? -30 : -62, channels: 1)).map { _ in changes += 1 }
        }
        #expect(changes == 0 && detector.status.verdict == .externalMic)
        #expect(detector.status.levelDeltaDb == deltaBefore)
    }

    /// The level against the Mac mic over the Mac mic's voiced blocks.
    @Test func levelDeltaFollowsTheVoice() throws {
        var detector = CameraMicDetector()
        Scene(cameraVoiceDb: -24, referenceVoiceDb: -36).run(&detector, blocks: 600)
        let delta = try #require(detector.status.levelDeltaDb)
        #expect(abs(delta - 12) < 0.01)
        #expect(abs((detector.report()?.levelVsScreenMicDb ?? 0) - 12) < 0.05)
    }
}

@Suite struct MicCalibrationTests {
    /// A sample like a 20 s mic check heard: the correlation and the level against the Mac mic
    /// wobble block by block around `correlation` and `delta`, like real ones.
    func wobblySample(correlation: Double, spread: Double, delta: Double, deltaSpread: Double) -> MicFeatureSample {
        var detector = CameraMicDetector(settings: .micCheck)
        for i in Int64(0)..<400 {
            let voiced = talking(i)
            let k = Double(i % 5) - 2
            let r = correlation + spread * k / 2
            _ = detector.add(camera: audioBlock(i, db: voiced ? -36 + delta + deltaSpread * k / 2 : -70, correlation: voiced ? r : 0.1),
                             reference: audioBlock(i, db: voiced ? -36 : -62, channels: 1))
        }
        return detector.sample
    }

    @Test func thresholdsSitBetweenTheSamples() throws {
        let plugged = wobblySample(correlation: 0.995, spread: 0.003, delta: 8, deltaSpread: 2)
        let unplugged = wobblySample(correlation: 0.90, spread: 0.03, delta: -4, deltaSpread: 2)
        let calibration = try MicCalibration.make(plugged: plugged, unplugged: unplugged)
        let correlation = try #require(calibration.correlation)
        #expect(correlation.externalIsHigher)
        // Inside the middle half of the gap; the band is 10% of the gap on each side.
        let (high, low) = (plugged.correlation.mean, unplugged.correlation.mean)
        #expect(abs(high - 0.995) < 0.001 && abs(low - 0.90) < 0.002)
        let gap = high - low
        #expect(correlation.threshold >= low + 0.25 * gap - 1e-9 && correlation.threshold <= high - 0.25 * gap + 1e-9)
        #expect(abs(correlation.hysteresis - 0.1 * gap) < 1e-9)
        let level = try #require(calibration.levelDelta)
        #expect(level.externalIsHigher && abs(level.threshold - 2) < 0.5)

        // Codable: the app saves it as JSON.
        let data = try JSONEncoder().encode(calibration)
        #expect(try JSONDecoder().decode(MicCalibration.self, from: data) == calibration)
    }

    /// With a calibration, the level rule decides even for mono camera audio.
    @Test func aCalibratedLevelRuleWorksWithoutCorrelation() throws {
        let plugged = wobblySample(correlation: 0.995, spread: 0.003, delta: 8, deltaSpread: 2)
        let unplugged = wobblySample(correlation: 0.90, spread: 0.03, delta: -4, deltaSpread: 2)
        let calibration = try MicCalibration.make(plugged: plugged, unplugged: unplugged)
        var quiet = CameraMicDetector(calibration: calibration)
        Scene(cameraVoiceDb: -40, voicedCorrelation: nil, noiseCorrelation: nil).run(&quiet, blocks: 600)
        #expect(quiet.status.verdict == .builtInMic && quiet.status.calibrated)
        var loud = CameraMicDetector(calibration: calibration)
        Scene(cameraVoiceDb: -28, voicedCorrelation: nil, noiseCorrelation: nil).run(&loud, blocks: 600)
        #expect(loud.status.verdict == .externalMic)
        #expect(loud.report()?.calibrated == true)
    }

    /// A built-in mic whose correlation is high (0.97) is still caught after calibration.
    @Test func calibrationMovesTheThreshold() throws {
        let plugged = wobblySample(correlation: 0.998, spread: 0.001, delta: 0, deltaSpread: 1)
        let unplugged = wobblySample(correlation: 0.975, spread: 0.004, delta: 0, deltaSpread: 1)
        let calibration = try MicCalibration.make(plugged: plugged, unplugged: unplugged)
        #expect(calibration.levelDelta == nil)  // The levels did not differ.
        let threshold = try #require(calibration.correlation?.threshold)
        #expect(threshold > 0.98 && threshold < 0.994)
        var uncalibrated = CameraMicDetector()
        Scene(voicedCorrelation: 0.975).run(&uncalibrated, blocks: 600)
        #expect(uncalibrated.status.verdict == .externalMic)  // The default 0.95 misses it.
        var calibrated = CameraMicDetector(calibration: calibration)
        Scene(voicedCorrelation: 0.975).run(&calibrated, blocks: 600)
        #expect(calibrated.status.verdict == .builtInMic)
        var rode = CameraMicDetector(calibration: calibration)
        Scene(voicedCorrelation: 0.998).run(&rode, blocks: 600)
        #expect(rode.status.verdict == .externalMic)
    }

    @Test func calibrationNeedsVoiceAndADifference() {
        let empty = MicFeatureSample()
        let plugged = wobblySample(correlation: 0.995, spread: 0.003, delta: 8, deltaSpread: 2)
        #expect(throws: MicCalibrationError.notEnoughVoice(sample: "unplugged", seconds: 0)) {
            _ = try MicCalibration.make(plugged: plugged, unplugged: empty)
        }
        #expect(throws: MicCalibrationError.samplesDoNotDiffer) {
            _ = try MicCalibration.make(plugged: plugged, unplugged: plugged)
        }
        #expect(MicCalibrationError.samplesDoNotDiffer.errorDescription?.contains("cannot tell") == true)
    }

    /// Sample 1 taken with the external mic still unplugged, sample 2 with it in: refused, so no
    /// inverted rule is saved. By correlation, else (no correlation rule) by level.
    @Test func swappedSamplesAreRefused() {
        let plugged = wobblySample(correlation: 0.995, spread: 0.003, delta: 8, deltaSpread: 2)
        let unplugged = wobblySample(correlation: 0.90, spread: 0.03, delta: -4, deltaSpread: 2)
        #expect(throws: MicCalibrationError.samplesSwapped) {
            _ = try MicCalibration.make(plugged: unplugged, unplugged: plugged)
        }
        let loud = wobblySample(correlation: 0.995, spread: 0.003, delta: 8, deltaSpread: 2)
        let quiet = wobblySample(correlation: 0.995, spread: 0.003, delta: -4, deltaSpread: 2)
        #expect(throws: MicCalibrationError.samplesSwapped) {
            _ = try MicCalibration.make(plugged: quiet, unplugged: loud)
        }
        // A Rode that is quieter but dual mono is fine: the correlation sets the order.
        let quietRode = wobblySample(correlation: 0.995, spread: 0.003, delta: -6, deltaSpread: 2)
        let builtIn = wobblySample(correlation: 0.90, spread: 0.03, delta: 4, deltaSpread: 2)
        #expect((try? MicCalibration.make(plugged: quietRode, unplugged: builtIn))?.levelDelta?.externalIsHigher == false)
    }

    @Test func welfordStats() {
        var stats = MicFeatureStats()
        for v in [1.0, 2, 3, 4] { stats.add(v) }
        #expect(stats.count == 4 && stats.mean == 2.5)
        #expect(abs(stats.variance - 5.0 / 3) < 1e-12)
    }
}

@Suite struct AudioLevelMonitorTests {
    @Test func metersHoldPeaksAndCountClips() throws {
        let monitor = AudioLevelMonitor()
        let t0: UInt64 = 1_000_000_000_000
        monitor.publish(audioBlock(0, db: -6, clipped: 3), from: .systemAudio, receivedNs: t0)
        for i in Int64(1)...29 { monitor.publish(audioBlock(i, db: -40), from: .systemAudio, receivedNs: t0) }
        var level = try #require(monitor.snapshot(nowNs: t0).systemAudio)
        #expect(abs(level.peakHoldDb - (-6 + 3.0103)) < 0.001)  // The first block's peak, 1.45 s ago.
        #expect(abs(level.rmsDb - (-40)) < 0.01 && level.clipCount == 3 && level.isLive)
        monitor.publish(audioBlock(30, db: -40), from: .systemAudio, receivedNs: t0)
        level = try #require(monitor.snapshot(nowNs: t0).systemAudio)
        #expect(abs(level.peakHoldDb - (-40 + 3.0103)) < 0.001)  // 1.5 s later the hold lets go.
        #expect(monitor.snapshot(nowNs: t0).cameraMic == nil)

        // Idle, CLIP is a clip in the last 1.5 s: the hold let go of block 0, so CLIP is off.
        #expect(level.clipCount == 0)

        // A meter that stopped reads silence.
        let stale = try #require(monitor.snapshot(nowNs: t0 + 600_000_000).systemAudio)
        #expect(!stale.isLive && stale.rmsDb == AudioBlock.silenceDb && stale.clipCount == 0)
    }

    /// In a take, CLIP counts every clip since Start; after Stop (idle again) it shows only a clip
    /// of the last 1.5 s, so the clap for sync does not light CLIP in the idle meters for hours.
    @Test func clipsCountForTheTakeAndOnlyBrieflyWhileIdle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        defer { events.close() }
        let monitor = AudioLevelMonitor()
        let t0: UInt64 = 1_000_000_000_000
        monitor.beginTake(events: events)
        monitor.publish(audioBlock(0, db: -3, clipped: 5), from: .cameraMic, receivedNs: t0)
        for i in Int64(1)...100 { monitor.publish(audioBlock(i, db: -30), from: .cameraMic, receivedNs: t0) }
        #expect(monitor.snapshot(nowNs: t0).cameraMic?.clipCount == 5)
        let stale = try #require(monitor.snapshot(nowNs: t0 + 600_000_000).cameraMic)
        #expect(!stale.isLive && stale.clipCount == 5)  // The take's count stays.
        monitor.resetClipCounts()
        #expect(monitor.snapshot(nowNs: t0).cameraMic?.clipCount == 0)
        monitor.publish(audioBlock(101, db: -3, clipped: 1), from: .cameraMic, receivedNs: t0)
        monitor.endTake(events: events)
        // The kept camera's idle meter goes on: no CLIP at a normal level.
        for i in Int64(102)...140 { monitor.publish(audioBlock(i, db: -30), from: .cameraMic, receivedNs: t0) }
        #expect(monitor.snapshot(nowNs: t0).cameraMic?.clipCount == 0)
        // An idle clip shows for 1.5 s.
        monitor.publish(audioBlock(141, db: -3, clipped: 2), from: .cameraMic, receivedNs: t0)
        #expect(monitor.snapshot(nowNs: t0).cameraMic?.clipCount == 2)
        for i in Int64(142)...171 { monitor.publish(audioBlock(i, db: -30), from: .cameraMic, receivedNs: t0) }
        #expect(monitor.snapshot(nowNs: t0).cameraMic?.clipCount == 0)
    }

    /// screen.mov that ends early (the stream stopped mid-take) ends its file, not the take:
    /// camera.mov still records, so the voice timeline and the detector log go on until the
    /// camera ends too. The app's `closeTake` ends a take a recorder never ended.
    @Test func aFileThatEndsEarlyKeepsTheTakeRunning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("early-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let events = try EventLog(url: url)
        let monitor = AudioLevelMonitor()
        monitor.beginTake(events: events)  // camera.mov
        monitor.beginTake(events: events)  // screen.mov
        monitor.endTake(events: events)    // screen.mov ended early.
        #expect(monitor.takeRuns)
        // Built-in mic on the camera from here: the detector logs it, the timeline collects it.
        for i in Int64(0)..<600 {
            let voiced = talking(i)
            monitor.publish(audioBlock(i, db: voiced ? -30 : -70, correlation: voiced ? 0.8 : 0.1), from: .cameraMic)
            monitor.publish(audioBlock(i, db: voiced ? -36 : -62, channels: 1), from: .screenMic)
        }
        #expect(!monitor.voiceTimeline().cameraMic.isEmpty)
        let report = try #require(monitor.endTake(events: events))  // camera.mov at Stop.
        #expect(report.verdict == .builtInMic)
        #expect(!monitor.takeRuns)
        events.close()
        #expect(try EventLog.read(url).filter { $0.type == .micDetector }.count == 1)

        // A recorder that began a take and never ended it (a file that did not start).
        let next = try EventLog(url: dir.appendingPathComponent("events2.jsonl"))
        monitor.beginTake(events: next)
        monitor.beginTake(events: next)
        monitor.endTake(events: next)
        #expect(monitor.takeRuns)
        monitor.closeTake(events: next)
        #expect(!monitor.takeRuns)
        next.close()
    }

    /// Detector changes go to the take's events.jsonl; the report goes to session.json.
    @Test func aTakeLogsDetectorChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("levels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let events = try EventLog(url: url)
        let monitor = AudioLevelMonitor()
        monitor.beginTake(events: events)
        monitor.beginTake(events: events)  // The second recorder: nothing changes.
        for i in Int64(0)..<600 {
            let voiced = talking(i)
            monitor.publish(audioBlock(i, db: voiced ? -30 : -70, correlation: voiced ? 0.8 : 0.1), from: .cameraMic)
            monitor.publish(audioBlock(i, db: voiced ? -36 : -62, channels: 1), from: .screenMic)
        }
        #expect(monitor.snapshot().detector.verdict == .builtInMic)
        let report = try #require(monitor.endTake(events: events))
        #expect(report.verdict == .builtInMic && report.verdictsSeen == [.builtInMic])
        #expect(abs((report.meanCorrelation ?? 0) - 0.8) < 0.001)
        #expect(report.correlationThreshold == 0.88 && !report.calibrated)
        events.close()
        let logged = try EventLog.read(url).filter { $0.type == .micDetector }
        #expect(logged.count == 1)
        #expect(logged.first?.data?["verdict"] == "built_in_mic" && logged.first?.data?["previous"] == "unknown")
        #expect(logged.first?.data?["message"] == MicDetectorStatus.builtInMessage)

        // session.json keys.
        var track = TrackInfo(file: "camera.mov", trackIndex: 1, role: .mic, dialogue: true)
        track.micSource = report
        let json = try #require(String(data: SessionManifest.encoder().encode(track), encoding: .utf8))
        #expect(json.contains("\"mic_source\"") && json.contains("\"level_vs_screen_mic_db\"")
            && json.contains("\"verdict\" : \"built_in_mic\"") && json.contains("\"verdicts_seen\""))
        let back = try SessionManifest.decoder().decode(TrackInfo.self, from: Data(json.utf8))
        #expect(back.micSource == report)
    }

    /// A mic check starts the detector over with the shorter settings and logs nothing.
    @Test func aMicCheckDecidesSooner() {
        let monitor = AudioLevelMonitor()
        monitor.beginCheck()
        for i in Int64(0)..<300 {
            let voiced = talking(i)
            monitor.publish(audioBlock(i, db: voiced ? -30 : -70, correlation: voiced ? 0.998 : 0.1), from: .cameraMic)
            monitor.publish(audioBlock(i, db: voiced ? -36 : -62, channels: 1), from: .screenMic)
        }
        let (status, sample) = monitor.finishCheck()
        #expect(status.verdict == .externalMic)
        #expect(sample.correlation.count >= 80 && sample.cameraVoicedSeconds >= 4)
    }

    /// The publisher of the live idle stream: one block of each mic per 50 ms of host time.
    struct LiveStream {
        let monitor: AudioLevelMonitor
        var block: Int64 = 100_000
        let t0: UInt64 = 1_000_000_000_000

        mutating func run(_ blocks: Int64, camera: (Int64) -> AudioBlock?, mac: (Int64) -> AudioBlock?) {
            for _ in 0..<blocks {
                let receivedNs = t0 + UInt64(block) * AudioBlock.durationNs
                if let c = camera(block) { monitor.publish(c, from: .cameraMic, receivedNs: receivedNs) }
                if let m = mac(block) { monitor.publish(m, from: .screenMic, receivedNs: receivedNs) }
                block += 1
            }
        }
    }

    /// Calibration on the live idle meters: they keep publishing before, between and after the two
    /// samples. Sample 1 (the Rode: dual mono, close) and sample 2 (the built-in mic: decorrelated,
    /// another level and noise floor, right after a stretch of flat near-silence from the unplug)
    /// each measure their own voice; nothing from sample 1 or the stretch between carries over.
    @Test func twoConsecutiveCalibrationSamplesBothMeasureVoice() throws {
        let monitor = AudioLevelMonitor()
        var live = LiveStream(monitor: monitor)
        let mac: (Int64) -> AudioBlock? = { audioBlock($0, db: talking($0) ? -38 : -62, channels: 1) }
        // Idle, quiet.
        live.run(100, camera: { audioBlock($0, db: -70, correlation: 0.1) }, mac: { audioBlock($0, db: -62, channels: 1) })
        monitor.beginCheck()
        live.run(200, camera: { audioBlock($0, db: talking($0) ? -30 : -70, correlation: talking($0) ? 0.99 : 0.1) }, mac: mac)
        let (first, plugged) = monitor.finishCheck()
        #expect(first.verdict == .externalMic && plugged.problem == nil)
        // The first phrase teaches the fresh detector its noise floor: about 4.8 s of the 5.4 s count.
        #expect(plugged.cameraVoicedSeconds >= 4 && abs(plugged.correlation.mean - 0.99) < 0.001)

        // The Rode comes out: 5 s of flat near-silence while idle, then sample 2 starts on more of it.
        let flat: (Int64) -> AudioBlock? = { audioBlock($0, db: -69.4 + 0.1 * Double($0 % 3), correlation: 0.88) }
        live.run(100, camera: flat, mac: mac)
        monitor.beginCheck()
        live.run(10, camera: flat, mac: mac)
        live.run(190, camera: { audioBlock($0, db: talking($0) ? -40 : -64, correlation: talking($0) ? 0.78 : 0.3) }, mac: mac)
        let (second, unplugged) = monitor.finishCheck()
        #expect(unplugged.problem == nil, "sample 2: \(unplugged.cameraVoicedSeconds) s of voice")
        #expect(unplugged.cameraVoicedSeconds >= MicCalibration.minSampleSeconds)
        #expect(abs(unplugged.correlation.mean - 0.78) < 0.001)
        #expect(second.verdict == .builtInMic)
        let calibration = try MicCalibration.make(plugged: plugged, unplugged: unplugged)
        let rule = try #require(calibration.correlation)
        #expect(rule.externalIsHigher && rule.threshold > 0.78 && rule.threshold < 0.99)

        // A third sample right away with the Rode back measures the Rode again.
        monitor.beginCheck()
        live.run(200, camera: { audioBlock($0, db: talking($0) ? -30 : -70, correlation: talking($0) ? 0.99 : 0.1) }, mac: mac)
        #expect(abs(monitor.finishCheck().sample.correlation.mean - 0.99) < 0.001)
    }

    /// What calibration step 2 heard on 2026-10-13 (twice "Only 0.0 s of voice"): with the Rode
    /// unplugged, the a6600 sent no sound from any mic. In take 2026-10-13_205644 the same state
    /// lasted the 25 s the Rode was out: the camera audio sat flat at -69.4 dBFS (±0.2 dB, L/R 0.85
    /// to 0.92, no trace of the voice), while the Mac mic heard the voice. The sample then holds no
    /// camera voice, the check says the camera mic is silent, and the sample says why.
    @Test func aSilentCameraIsNotTooLittleVoice() {
        let monitor = AudioLevelMonitor()
        var live = LiveStream(monitor: monitor)
        let loud: (Int64) -> Bool = { $0 % 10 < 8 }  // Talking loudly for the whole check.
        monitor.beginCheck()
        live.run(200, camera: { audioBlock($0, db: -69.4 + 0.2 * Double($0 % 3) - 0.2, correlation: 0.85 + 0.035 * Double($0 % 3)) },
                 mac: { audioBlock($0, db: loud($0) ? -40 : -62, channels: 1) })
        let (status, sample) = monitor.finishCheck()
        #expect(sample.cameraVoicedSeconds == 0)
        #expect(sample.referenceVoicedSeconds >= 6)
        #expect(sample.problem == .cameraSilent)
        #expect(status.cameraMicSilent && status.verdict == .unknown)
    }

    /// Decision 1 shows the detector's banner before recording: a replug of the Rode with the
    /// camera window open (its click in the mic jack) must not bring up the built-in mic banner.
    @Test func anIdleReplugClickShowsNoBanner() {
        let monitor = AudioLevelMonitor()
        var live = LiveStream(monitor: monitor)
        let mac: (Int64) -> AudioBlock? = { audioBlock($0, db: talking($0) ? -38 : -66, channels: 1) }
        let rode: (Int64) -> AudioBlock? = { audioBlock($0, db: talking($0) ? -30 : -65, correlation: talking($0) ? 0.98 : 0.3) }
        live.run(400, camera: rode, mac: mac)
        #expect(monitor.detectorStatus.verdict == .externalMic)
        live.run(20, camera: { audioBlock($0, db: -18, correlation: $0 % 2 == 0 ? -0.9 : 0.2) },
                 mac: { audioBlock($0, db: -66, channels: 1) })
        // Checked every second while the click is still in the 6 s window.
        for _ in 0..<8 {
            live.run(20, camera: rode, mac: mac)
            #expect(monitor.detectorStatus.verdict == .externalMic && monitor.detectorStatus.message == nil)
        }
    }

    @Test func whatASampleLacks() {
        /// A sample with `usable` s of correlation evidence (20 blocks a second).
        func sample(camera: Double, reference: Double, usable: Double? = nil) -> MicFeatureSample {
            var correlation = MicFeatureStats()
            for _ in 0..<Int(((usable ?? camera) * AudioBlock.perSecond).rounded()) { correlation.add(0.99) }
            return MicFeatureSample(correlation: correlation, cameraVoicedSeconds: camera, referenceVoicedSeconds: reference)
        }
        #expect(sample(camera: 7.5, reference: 6).problem == nil)
        #expect(sample(camera: 3, reference: 0).problem == nil)
        #expect(sample(camera: 0, reference: 6).problem == .cameraSilent)
        #expect(sample(camera: 0.5, reference: 4).problem == .cameraSilent)
        #expect(sample(camera: 2, reference: 4).problem == .notEnoughVoice)
        #expect(sample(camera: 0, reference: 1).problem == .notEnoughVoice)
        // No Mac mic in the check: never "silent", only too little voice.
        #expect(sample(camera: 0, reference: 0).problem == .notEnoughVoice)
        // The camera heard 7.5 s, but the Mac mic only 2 s of it: the rules can use 2 s, too little.
        let quiet = sample(camera: 7.5, reference: 2.5, usable: 2)
        #expect(quiet.problem == .notEnoughVoice && quiet.usableVoicedSeconds == 2)
        // Usable voice never counts more than the camera's voiced time, and also counts the level.
        #expect(MicFeatureSample(cameraVoicedSeconds: 7.5).usableVoicedSeconds == 0)
        var level = MicFeatureStats()
        for _ in 0..<80 { level.add(10) }
        #expect(MicFeatureSample(levelDeltaDb: level, cameraVoicedSeconds: 3.5, referenceVoicedSeconds: 6).usableVoicedSeconds == 3.5)
    }

    /// The idle detector runs on the idle meters, so it can warn before Start. When the camera mic
    /// comes back after a gap (the camera closed and opened again), it starts over: the old verdict
    /// does not speak for a mic that may have changed meanwhile. A check (or a take) never starts
    /// over that way.
    @Test func theIdleDetectorRunsAndStartsOverAfterAGap() {
        let monitor = AudioLevelMonitor()
        var live = LiveStream(monitor: monitor)
        let mac: (Int64) -> AudioBlock? = { audioBlock($0, db: talking($0) ? -36 : -62, channels: 1) }
        live.run(600, camera: { audioBlock($0, db: talking($0) ? -30 : -70, correlation: talking($0) ? 0.75 : 0.1) }, mac: mac)
        #expect(monitor.detectorStatus.verdict == .builtInMic)
        #expect(monitor.detectorStatus.message == MicDetectorStatus.builtInMessage)
        live.block += 60  // 3 s without blocks: the camera was closed.
        live.run(1, camera: { audioBlock($0, db: -70, correlation: 0.1) }, mac: mac)
        #expect(monitor.detectorStatus.verdict == .unknown && monitor.detectorStatus.voicedSeconds == 0)
        // A gap shorter than idleRestartAfterNs keeps it.
        live.run(600, camera: { audioBlock($0, db: talking($0) ? -30 : -70, correlation: talking($0) ? 0.99 : 0.1) }, mac: mac)
        #expect(monitor.detectorStatus.verdict == .externalMic)
        live.block += 20
        live.run(1, camera: { audioBlock($0, db: -70, correlation: 0.1) }, mac: mac)
        #expect(monitor.detectorStatus.verdict == .externalMic)
        // During a check, a gap keeps the evidence.
        monitor.beginCheck()
        live.run(300, camera: { audioBlock($0, db: talking($0) ? -30 : -70, correlation: talking($0) ? 0.99 : 0.1) }, mac: mac)
        live.block += 100
        live.run(1, camera: { audioBlock($0, db: -70, correlation: 0.1) }, mac: mac)
        let (status, sample) = monitor.finishCheck()
        #expect(status.verdict == .externalMic && sample.cameraVoicedSeconds >= 4)
    }

    @Test func calibrationCanBeSetAndCleared() throws {
        let monitor = AudioLevelMonitor()
        #expect(monitor.calibration == nil && !monitor.detectorStatus.calibrated)
        let calibration = MicCalibration(plugged: MicFeatureSample(), unplugged: MicFeatureSample(),
                                         correlation: MicFeatureRule(threshold: 0.98, hysteresis: 0.005), levelDelta: nil)
        monitor.setCalibration(calibration)
        #expect(monitor.calibration == calibration && monitor.detectorStatus.calibrated)
        monitor.reset()
        #expect(monitor.detectorStatus.calibrated)  // A reset keeps the calibration.
        monitor.setCalibration(nil)
        #expect(!monitor.detectorStatus.calibrated)
    }
}

@Suite struct BlockPairerTests {
    @Test func pairsBlocksOfTheSameTime() {
        var pairer = BlockPairer()
        pairer.insert(audioBlock(10, db: -30), isCamera: true)
        #expect(pairer.popReady()?.index == 10)  // The Mac mic was never seen: no wait.
        pairer.insert(audioBlock(11, db: -30), isCamera: false)
        pairer.insert(audioBlock(11, db: -30), isCamera: true)
        let pair = pairer.popReady()
        #expect(pair?.index == 11 && pair?.camera != nil && pair?.reference != nil)
        // The camera runs ahead: blocks wait for the Mac mic.
        for i in Int64(12)...15 { pairer.insert(audioBlock(i, db: -30), isCamera: true) }
        #expect(pairer.popReady() == nil)
        pairer.insert(audioBlock(12, db: -30), isCamera: false)
        #expect(pairer.popReady()?.reference != nil)
        #expect(pairer.popReady() == nil)
        // A late block (its time was handed on) is dropped.
        pairer.insert(audioBlock(5, db: -30), isCamera: false)
        #expect(pairer.popReady() == nil)
    }

    @Test func aStoppedSourceHoldsNothingUpForLong() {
        var pairer = BlockPairer()
        pairer.insert(audioBlock(0, db: -30), isCamera: false)
        pairer.insert(audioBlock(0, db: -30), isCamera: true)
        #expect(pairer.popReady()?.index == 0)
        var handed: [Int64] = []
        for i in Int64(1)...40 {
            pairer.insert(audioBlock(i, db: -30), isCamera: true)
            while let pair = pairer.popReady() { handed.append(pair.index) }
        }
        // Waits 20 blocks (1 s) for the Mac mic, then hands on without it.
        #expect(handed == Array(1...20))
    }

    /// The Mac mic's block of each time always comes a moment after the camera's: still paired.
    @Test func aSourceThatIsAlwaysALittleLateIsPaired() {
        var pairer = BlockPairer()
        var both = 0
        for i in Int64(0)..<50 {
            for isCamera in [true, false] {
                pairer.insert(audioBlock(i, db: -30), isCamera: isCamera)
                while let pair = pairer.popReady() {
                    if pair.camera != nil && pair.reference != nil { both += 1 }
                }
            }
        }
        // Only the very first block went on before the Mac mic was known.
        #expect(both == 49)
    }

    @Test func aLongJumpSkipsTheGap() {
        var pairer = BlockPairer()
        pairer.insert(audioBlock(0, db: -30), isCamera: true)
        _ = pairer.popReady()
        pairer.insert(audioBlock(10_000, db: -30), isCamera: true)
        #expect(pairer.popReady()?.index == 10_000)
    }
}
