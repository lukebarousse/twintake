import CameraCapture
import Foundation
import Testing
@testable import RecorderApp
@testable import RecorderCore

// The level meters, the mic warning banners and beep, the mic check text and the calibration
// flow: the app's rules over plain data.

/// A block at `db` dBFS RMS (the peak 3 dB above it).
private func block(_ index: Int64, db: Double, correlation: Double? = nil, channels: Int = 2) -> AudioBlock {
    let meanSquare = pow(10, db / 10)
    return AudioBlock(index: index, frames: 2400, channels: channels, peak: Float((2 * meanSquare).squareRoot()),
                      meanSquare: meanSquare, correlation: correlation)
}

/// Talks in phrases: 0.6 s of voice, 0.2 s between words, a 1.5 s pause every 5 s.
private func talking(_ i: Int64) -> Bool {
    let inCycle = i % 100
    return inCycle < 70 && inCycle % 16 < 12
}

/// Drives the app's monitor block by block (the camera mic and the Mac mic) and follows what the
/// app shows: the mic alert and its beeps.
private struct Take {
    let monitor = AudioLevelMonitor()
    var onset = AlertOnset()
    var beeps = 0
    var alerts: [Int64: MicAlert] = [:]
    var next: Int64 = 0

    /// - Parameters:
    ///   - correlation: the camera's L/R correlation while voiced (0.99: the Rode, dual mono).
    ///   - cameraVoiceDb: the camera's voice level; its noise floor is -70 dBFS.
    ///   - speaking: false for the whole stretch: a long pause.
    mutating func run(seconds: Double, correlation: Double, cameraVoiceDb: Double = -30, speaking: Bool = true) {
        let blocks = Int64(seconds * 20)
        for i in next..<(next + blocks) {
            let voice = speaking && talking(i)
            let ns = UInt64(i) * AudioBlock.durationNs
            monitor.publish(block(i, db: voice ? cameraVoiceDb : -70, correlation: voice ? correlation : 0.1),
                            from: .cameraMic, receivedNs: ns)
            monitor.publish(block(i, db: voice ? -36 : -62, channels: 1), from: .screenMic, receivedNs: ns)
            let alert = MicAlert(monitor.detectorStatus)
            if let alert { alerts[i] = alert }
            if onset.update(alert != nil) { beeps += 1 }
        }
        next += blocks
    }

    /// The first block at or after `from` with an alert.
    func firstAlert(after from: Int64) -> Int64? { alerts.keys.filter { $0 >= from }.min() }
}

@Suite struct MicWarningTests {
    /// Rode in, long pauses, then unplugged: one warning within about 10 s of talking, one beep,
    /// nothing during the pauses.
    @Test func unpluggingWarnsOnceAndPausesNever() throws {
        var take = Take()
        take.run(seconds: 20, correlation: 0.995)
        #expect(take.monitor.detectorStatus.verdict == .externalMic)
        // A minute of silence: no warning, no beep.
        take.run(seconds: 60, correlation: 0.995, speaking: false)
        #expect(take.alerts.isEmpty && take.beeps == 0)

        // Unplugged: the a6600's built-in stereo mic, quieter and decorrelated.
        let unplugged = take.next
        take.run(seconds: 20, correlation: 0.8, cameraVoiceDb: -42)
        let warned = try #require(take.firstAlert(after: unplugged))
        #expect(take.alerts[warned] == .builtInMic)
        // Within about 10 s of talking (the voice is about half of the time here).
        #expect(Double(warned - unplugged) / 20 <= 10, "warned after \(Double(warned - unplugged) / 20) s")
        #expect(take.beeps == 1)

        // A pause while unplugged: still on, no new beep.
        take.run(seconds: 30, correlation: 0.8, cameraVoiceDb: -42, speaking: false)
        #expect(take.beeps == 1)
        #expect(MicAlert(take.monitor.detectorStatus) == .builtInMic)

        // Plugged back in: it clears; unplugged again: a second beep.
        take.run(seconds: 20, correlation: 0.995)
        #expect(MicAlert(take.monitor.detectorStatus) == nil)
        take.run(seconds: 20, correlation: 0.8, cameraVoiceDb: -42)
        #expect(take.beeps == 2)
    }

    /// Silence for a whole take: no verdict and no warning.
    @Test func silenceNeverWarns() {
        var take = Take()
        take.run(seconds: 120, correlation: 0.8, speaking: false)
        #expect(take.alerts.isEmpty && take.beeps == 0)
        #expect(take.monitor.detectorStatus.verdict == .unknown)
    }

    @Test func theSilentMicComesFirst() {
        #expect(MicAlert(MicDetectorStatus(verdict: .builtInMic, cameraMicSilent: true)) == .cameraMicSilent)
        #expect(MicAlert(MicDetectorStatus(verdict: .builtInMic)) == .builtInMic)
        #expect(MicAlert(MicDetectorStatus(verdict: .externalMic)) == nil)
        #expect(MicAlert(MicDetectorStatus(verdict: .unknown)) == nil)
    }

    @Test func oneBeepPerOnset() {
        var onset = AlertOnset()
        let steps = [false, true, true, true, false, false, true, true].map { onset.update($0) }
        #expect(steps == [false, true, false, false, false, false, true, false])
        onset.reset()
        let again = onset.update(true)
        #expect(again)
    }
}

@Suite struct CaptureAlertTests {
    let usb = "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3."
    let empty = "No picture: the Cam Link is sending empty frames."

    /// Luke's glitch: USB 2 and empty frames at once. The USB 2 banner (the cause, fixed by a
    /// replug) comes first, and nothing offers Reconnect, which cannot move the Cam Link off USB 2.
    @Test func theMostUrgentComesFirst() {
        let health = CameraHealth(usbProblem: usb, emptyFrames: .zero, pictureProblem: empty)
        let alerts = CaptureAlerts.list(mic: .builtInMic, health: health, idle: true)
        #expect(alerts.map(\.kind) == [.usb2, .emptyFrames, .builtInMic])
        #expect(alerts[0].title == "Cam Link is connected at USB 2 speed.")
        #expect(alerts[0].detail == "Unplug it and plug it back in — 4K needs USB 3.")
        #expect(alerts[0].blocksStart && !alerts[0].offersReconnect)
        #expect(alerts[1].title == empty && alerts[1].blocksStart && !alerts[1].offersReconnect)
        #expect(alerts[1].detail == "Unplug the Cam Link and plug it back in.")
        #expect(alerts[2].title == "Rode not detected — the camera is using its built-in mic.")
        #expect(!alerts[2].blocksStart)
        #expect(alerts.compactMap(\.issueID) == ["camera.usb2", "camera.empty_frames"])
    }

    @Test func reconnectOnlyWhileIdle() {
        let health = CameraHealth(emptyFrames: .zero, pictureProblem: empty)
        let idle = CaptureAlerts.list(mic: nil, health: health, idle: true).first
        #expect(idle?.offersReconnect == true && idle?.blocksStart == true)
        #expect(idle?.detail == "Click Reconnect Camera, or unplug the Cam Link and plug it back in.")
        // While recording: no button, so the text names none; orange, since Start is not the issue.
        let recording = CaptureAlerts.list(mic: nil, health: health, idle: false).first
        #expect(recording?.offersReconnect == false && recording?.blocksStart == false)
        #expect(recording?.detail == "camera.mov has no picture. Stop, then reconnect or replug the Cam Link.")
        // A flat picture (a lens cap) is a warning, not a blocker.
        let flat = CameraHealth(emptyFrames: .constant, pictureProblem: empty)
        #expect(CaptureAlerts.list(mic: nil, health: flat, idle: true).first?.blocksStart == false)
    }

    /// One colon, and the fix, when empty frames block Start. Other blockers keep their text.
    @Test func theStartBlockedNotice() {
        let emptyIssue = PreflightIssue(id: "camera.empty_frames", severity: .blocker, message: empty)
        #expect(SessionRules.startBlockedNotice(emptyIssue)
            == "Not started: no picture. The Cam Link is sending empty frames. Click Reconnect Camera, or unplug it and plug it back in.")
        let usbIssue = PreflightIssue(id: "camera.usb2", severity: .blocker, message: usb)
        #expect(SessionRules.startBlockedNotice(usbIssue) == "Not started: \(usb)")
    }

    @Test func nothingWrongShowsNothing() {
        #expect(CaptureAlerts.list(mic: nil, health: CameraHealth(), idle: true).isEmpty)
        let silent = CaptureAlerts.list(mic: .cameraMicSilent, health: CameraHealth(), idle: true)
        #expect(silent.map(\.title) == ["The camera mic isn't picking up your voice."])
        #expect(silent.first?.detail == "Check that the Rode is switched on and plugged in.")
    }

    @Test func splitsTheFirstSentence() {
        #expect(CaptureAlerts.split("One. Two three.") == ("One.", "Two three."))
        #expect(CaptureAlerts.split("Only one.") == ("Only one.", nil))
    }

    @Test func theLastTakeSaysWhenTheRodeWasMissing() {
        func report(_ verdict: MicVerdict, seen: [MicVerdict], silent: Bool = false) -> MicSourceReport {
            MicSourceReport(verdict: verdict, verdictsSeen: seen, cameraMicSilent: silent, meanCorrelation: nil,
                            levelVsScreenMicDb: nil, voicedS: 30, screenMicVoicedS: 30, calibrated: false,
                            correlationThreshold: 0.95)
        }
        #expect(CaptureAlerts.lastTakeMicNote(nil) == nil)
        #expect(CaptureAlerts.lastTakeMicNote(report(.externalMic, seen: [.externalMic])) == nil)
        #expect(CaptureAlerts.lastTakeMicNote(report(.builtInMic, seen: [.externalMic, .builtInMic]))?
            .hasPrefix("camera.mov was recorded with the camera's built-in mic") == true)
        #expect(CaptureAlerts.lastTakeMicNote(report(.externalMic, seen: [.builtInMic, .externalMic]))?
            .hasPrefix("Part of camera.mov") == true)
        #expect(CaptureAlerts.lastTakeMicNote(report(.externalMic, seen: [.externalMic], silent: true)) != nil)
    }
}

@Suite struct MeterTests {
    @Test func theScaleAndItsColors() {
        #expect(MeterScale.fraction(-60) == 0 && MeterScale.fraction(-120) == 0)
        #expect(MeterScale.fraction(0) == 1 && MeterScale.fraction(6) == 1)
        #expect(abs(MeterScale.fraction(-12) - 0.8) < 1e-9)
        #expect(MeterScale.fraction(-.infinity) == 0)
        #expect(MeterScale.zone(-18) == .green && MeterScale.zone(-12) == .green)
        #expect(MeterScale.zone(-11.9) == .yellow && MeterScale.zone(-3) == .yellow)
        #expect(MeterScale.zone(-2.9) == .red && MeterScale.zone(0) == .red)
        #expect(MeterScale.segments.map(\.zone) == [.green, .yellow, .red])
        #expect(MeterScale.segments.first?.from == 0 && MeterScale.segments.last?.to == 1)
    }

    @Test func theNumberIsThePeakHold() {
        let live = AudioLevel(peakDb: -30, rmsDb: -44, peakHoldDb: -18.4, clipCount: 0, channels: 2, isLive: true)
        #expect(MeterScale.label(live) == "-18")
        var stopped = live
        stopped.isLive = false
        #expect(MeterScale.label(stopped) == "—")
        #expect(MeterScale.label(nil) == "—")
        var silent = live
        silent.peakHoldDb = AudioBlock.silenceDb
        #expect(MeterScale.label(silent) == "—")
    }

    @Test func theSourcesOfATakeAndACheck() {
        #expect(MeterSources.take(cameraAudio: true, screenMic: true, systemAudio: true) == [.cameraMic, .screenMic, .systemAudio])
        #expect(MeterSources.take(cameraAudio: false, screenMic: true, systemAudio: true) == [.screenMic, .systemAudio])
        #expect(MeterSources.take(cameraAudio: true, screenMic: false, systemAudio: false) == [.cameraMic])
        #expect(MeterSources.check(cameraAudio: true, screenMic: true) == [.cameraMic, .screenMic])
        #expect([AudioSource.cameraMic, .screenMic, .systemAudio].map(\.meterTitle) == ["Camera mic", "Mac mic", "Computer sound"])
    }
}

/// A sample of `count` values around `mean` (± `spread`), as a mic check hears it.
private func stats(_ mean: Double, spread: Double, count: Int = 120) -> MicFeatureStats {
    var s = MicFeatureStats()
    for i in 0..<count { s.add(mean + spread * (i.isMultiple(of: 2) ? 1 : -1) * Double(i % 5) / 4) }
    return s
}

private func outcome(correlation: Double?, level: Double? = nil, voiced: Double = 6, verdict: MicVerdict = .unknown,
                     silent: Bool = false, cameraOpened: Bool = true, cancelled: Bool = false,
                     errors: [String] = []) -> MicCheckOutcome {
    let sample = MicFeatureSample(correlation: correlation.map { stats($0, spread: 0.004) } ?? MicFeatureStats(),
                                  levelDeltaDb: level.map { stats($0, spread: 1.5) } ?? MicFeatureStats(),
                                  cameraVoicedSeconds: voiced, referenceVoicedSeconds: voiced)
    return MicCheckOutcome(status: MicDetectorStatus(verdict: verdict, cameraMicSilent: silent, correlation: correlation,
                                                     voicedSeconds: voiced, progress: 1),
                           sample: sample, cameraMicOpened: cameraOpened, screenMicOpened: true,
                           cancelled: cancelled, errors: errors)
}

@Suite struct MicCheckTextTests {
    @Test func theVerdicts() {
        #expect(MicStatusText.outcome(outcome(correlation: 0.991, verdict: .externalMic)).title == "Rode detected.")
        #expect(MicStatusText.outcome(outcome(correlation: 0.991, verdict: .externalMic)).detail
            == "L/R correlation 0.991 · 6.0 s of voice")
        let builtIn = MicStatusText.outcome(outcome(correlation: 0.85, verdict: .builtInMic))
        #expect(builtIn.title == CaptureAlerts.builtInTitle && builtIn.tone == .warning)
        #expect(builtIn.detail?.hasPrefix("L/R correlation 0.850.") == true)
        let silent = MicStatusText.outcome(outcome(correlation: nil, verdict: .externalMic, silent: true))
        #expect(silent.title == CaptureAlerts.silentTitle && silent.tone == .warning)
    }

    @Test func noVoiceAndTrouble() {
        #expect(MicStatusText.outcome(outcome(correlation: nil, voiced: 0.3)).title == "No voice heard.")
        #expect(MicStatusText.outcome(outcome(correlation: nil, cancelled: true)).title == "Mic check cancelled.")
        let closed = MicStatusText.outcome(outcome(correlation: nil, cameraOpened: false, errors: ["Mic not found (x)."]))
        #expect(closed.title == "The camera mic did not open." && closed.detail == "Mic not found (x).")
        let mono = MicStatusText.outcome(outcome(correlation: nil, voiced: 6))
        #expect(mono.detail?.contains("mono") == true)
    }

    @Test func theLiveLine() {
        #expect(MicStatusText.live(MicDetectorStatus()).title == "Talk to check the camera mic")
        #expect(MicStatusText.live(MicDetectorStatus(voicedSeconds: 2, progress: 0.4)).title == "Listening for your voice… 40%")
        #expect(MicStatusText.live(MicDetectorStatus(verdict: .externalMic, correlation: 0.9912)).title == "Rode detected · L/R 0.991")
        #expect(MicStatusText.live(MicDetectorStatus(verdict: .builtInMic, correlation: 0.9)).tone == .warning)
        #expect(MicStatusText.live(MicDetectorStatus(verdict: .externalMic, cameraMicSilent: true)).tone == .warning)
        // A level-only calibration in a take without the Mac mic: it says why no verdict comes.
        let waiting = MicDetectorStatus(voicedSeconds: 3, progress: 0, calibrated: true)
        #expect(MicStatusText.live(waiting, macMicMissing: true).title.hasPrefix("The mic warning needs the Mac mic"))
        #expect(MicStatusText.live(waiting).title == "Listening for your voice… 0%")
    }

    /// A take confirmed the Rode: the line says so and that the check is off; no banner, no beep.
    @Test func aConfirmedTakeShowsNoWarning() {
        let confirmed = MicDetectorStatus(verdict: .externalMic, correlation: 0.9853, voicedSeconds: 6, progress: 1,
                                          confirmed: true)
        let text = MicStatusText.live(confirmed)
        #expect(text.title == "Rode confirmed · L/R 0.985" && text.tone == .good)
        #expect(text.detail == "The mic check is off for the rest of this take.")
        #expect(MicAlert(confirmed) == nil)
        #expect(CaptureAlerts.list(mic: MicAlert(confirmed), health: CameraHealth(), idle: false).isEmpty)
        // Before the confirmation the plain line shows.
        #expect(MicStatusText.live(MicDetectorStatus(verdict: .externalMic, correlation: 0.9853)).title == "Rode detected · L/R 0.985")
    }

    @Test func aLevelOnlyCalibrationNeedsTheMacMic() {
        let level = MicFeatureRule(threshold: 2, hysteresis: 0.8, externalIsHigher: true)
        let levelOnly = MicCalibration(plugged: MicFeatureSample(), unplugged: MicFeatureSample(), correlation: nil, levelDelta: level)
        #expect(MicCalibrationText.needsMacMic(levelOnly))
        var both = levelOnly
        both.correlation = MicFeatureRule(threshold: 0.96, hysteresis: 0.01)
        #expect(!MicCalibrationText.needsMacMic(both) && !MicCalibrationText.needsMacMic(nil))
    }

    @Test func theCountdown() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let progress = MicCheckProgress(purpose: .check, startedAt: start, seconds: 10)
        #expect(progress.secondsLeft(at: start) == 10)
        #expect(progress.secondsLeft(at: start.addingTimeInterval(3.2)) == 7)
        #expect(progress.secondsLeft(at: start.addingTimeInterval(12)) == 0)
        #expect(MicStatusText.decibels(12.04) == "+12.0 dB" && MicStatusText.decibels(-3) == "−3.0 dB")
    }
}

@Suite struct MicCalibrationFlowTests {
    @Test func twoSamplesMakeTheThresholds() throws {
        var flow = MicCalibrationFlow()
        #expect(flow.step == .plugged && flow.purpose == .calibratePlugged)
        flow.record(outcome(correlation: 0.991, level: 12), for: .calibratePlugged)
        #expect(flow.step == .unplugged && flow.error == nil && flow.plugged != nil)
        // A late result for the other step changes nothing.
        flow.record(outcome(correlation: 0.991, level: 12), for: .calibratePlugged)
        #expect(flow.step == .unplugged)
        flow.record(outcome(correlation: 0.90, level: 0), for: .calibrateUnplugged)
        #expect(flow.step == .review && flow.error == nil)
        let calibration = try #require(flow.calibration)
        let threshold = try #require(calibration.correlation?.threshold)
        #expect(threshold > 0.90 && threshold < 0.991)
        let lines = MicCalibrationText.rules(calibration)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("L/R correlation: built-in mic below 0.9"))
        #expect(lines[0].contains("(Rode 0.99"))
        #expect(lines[1].hasPrefix("Level against the Mac mic: built-in mic below +"))
    }

    @Test func aShortOrCancelledSampleStaysOnItsStep() {
        var flow = MicCalibrationFlow()
        flow.record(outcome(correlation: 0.99, voiced: 1.2), for: .calibratePlugged)
        #expect(flow.step == .plugged && flow.error?.hasPrefix("Only 1.2 s of voice") == true)
        flow.record(outcome(correlation: 0.99, cancelled: true), for: .calibratePlugged)
        #expect(flow.step == .plugged && flow.error == "The sample was cancelled. Record it again.")
        flow.record(outcome(correlation: nil, cameraOpened: false, errors: ["Mic not found."]), for: .calibratePlugged)
        #expect(flow.step == .plugged && flow.error == "The camera mic did not open. Mic not found.")
        flow.record(outcome(correlation: 0.99), for: .calibratePlugged)
        #expect(flow.step == .unplugged && flow.error == nil)
    }

    /// Sample 1 recorded with the Rode still unplugged, sample 2 with it in: no inverted rule is
    /// saved; both samples start over.
    @Test func swappedSamplesAreRefused() {
        var flow = MicCalibrationFlow()
        flow.record(outcome(correlation: 0.90, level: 0), for: .calibratePlugged)
        flow.record(outcome(correlation: 0.991, level: 12), for: .calibrateUnplugged)
        #expect(flow.calibration == nil && flow.step == .plugged)
        #expect(flow.plugged == nil && flow.unplugged == nil)
        #expect(flow.error == MicCalibrationError.samplesSwapped.errorDescription)
        // Then the right order works.
        flow.record(outcome(correlation: 0.991, level: 12), for: .calibratePlugged)
        flow.record(outcome(correlation: 0.90, level: 0), for: .calibrateUnplugged)
        #expect(flow.step == .review && flow.calibration?.correlation?.externalIsHigher == true)
    }

    /// The correlations do not differ, the levels do: the review says the warning needs the Mac mic.
    @Test func aLevelOnlyCalibrationSaysItNeedsTheMacMic() throws {
        var flow = MicCalibrationFlow()
        flow.record(outcome(correlation: 0.991, level: 12), for: .calibratePlugged)
        flow.record(outcome(correlation: 0.991, level: 0), for: .calibrateUnplugged)
        let calibration = try #require(flow.calibration)
        #expect(calibration.correlation == nil && calibration.levelDelta?.externalIsHigher == true)
        #expect(flow.instruction.contains("only while TwinTake meters the Mac mic"))
    }

    @Test func samplesThatSoundAlikeMakeNoCalibration() {
        var flow = MicCalibrationFlow()
        flow.record(outcome(correlation: 0.991), for: .calibratePlugged)
        flow.record(outcome(correlation: 0.991), for: .calibrateUnplugged)
        #expect(flow.step == .review && flow.calibration == nil)
        #expect(flow.error == MicCalibrationError.samplesDoNotDiffer.errorDescription)
    }

    /// Take 2026-10-13_205644: step 2 with the Rode unplugged, Luke talking the whole 10 s, but the
    /// a6600 sent silence (-69.4 dBFS flat). The flow says so, instead of "Talk for the whole 10 s".
    @Test func aSilentCameraSampleSaysWhy() throws {
        func silentCamera(_ purpose: MicCheckPurpose) -> MicCheckOutcome {
            MicCheckOutcome(status: MicDetectorStatus(), sample: MicFeatureSample(cameraVoicedSeconds: 0, referenceVoicedSeconds: 8.5),
                            cameraMicOpened: true, screenMicOpened: true, cancelled: false, errors: [],
                            liveSources: [.cameraMic, .screenMic])
        }
        var flow = MicCalibrationFlow()
        flow.record(silentCamera(.calibratePlugged), for: .calibratePlugged)
        #expect(flow.step == .plugged)
        #expect(flow.error?.hasPrefix("The camera mic isn't picking up your voice (Mac mic: 8.5 s of voice, camera: 0.0 s).") == true)
        flow.record(outcome(correlation: 0.975, level: 10), for: .calibratePlugged)
        #expect(flow.step == .unplugged && flow.error == nil)
        flow.record(silentCamera(.calibrateUnplugged), for: .calibrateUnplugged)
        #expect(flow.step == .unplugged && flow.plugged != nil)
        let error = try #require(flow.error)
        #expect(error.hasPrefix("The camera sent no sound (Mac mic: 8.5 s of voice, camera: 0.0 s)."))
        #expect(error.contains("MIC jack") && !error.contains("Talk for the whole 10 s"))
        // Then a sample with the built-in mic works.
        flow.record(outcome(correlation: 0.78, level: 10), for: .calibrateUnplugged)
        #expect(flow.step == .review && flow.error == nil && flow.calibration?.correlation != nil)
        // Too little voice on both mics is still "talk longer".
        var short = MicCalibrationFlow()
        short.record(MicCheckOutcome(status: MicDetectorStatus(), sample: MicFeatureSample(cameraVoicedSeconds: 0, referenceVoicedSeconds: 1),
                                     cameraMicOpened: true, screenMicOpened: true, cancelled: false, errors: []),
                     for: .calibratePlugged)
        #expect(short.error == "Only 0.0 s of voice. Talk for the whole 10 s and record it again.")
    }

    /// The camera heard 7.5 s of voice, the Mac mic only 2 s of it: only voice both mics hear
    /// counts (a click in the camera's mic jack is no voice), so the sample asks for a louder voice.
    @Test func aSampleTheMacMicBarelyHeard() {
        var correlation = MicFeatureStats()
        for _ in 0..<40 { correlation.add(0.98) }
        let sample = MicFeatureSample(correlation: correlation, cameraVoicedSeconds: 7.5, referenceVoicedSeconds: 2.2)
        var flow = MicCalibrationFlow()
        flow.record(MicCheckOutcome(status: MicDetectorStatus(), sample: sample, cameraMicOpened: true, screenMicOpened: true,
                                    cancelled: false, errors: []), for: .calibratePlugged)
        #expect(flow.step == .plugged)
        #expect(flow.error == "Only 2.0 s of voice that the Mac mic heard too (camera: 7.5 s). Talk a little louder for the whole 10 s and record it again.")
    }

    /// A plain check with a silent camera and a Mac mic that heard the voice says the camera mic
    /// does not hear it, not "No voice heard".
    @Test func aPlainCheckWithASilentCamera() {
        let o = MicCheckOutcome(status: MicDetectorStatus(), sample: MicFeatureSample(cameraVoicedSeconds: 0.2, referenceVoicedSeconds: 7),
                                cameraMicOpened: true, screenMicOpened: true, cancelled: false, errors: [])
        #expect(MicStatusText.outcome(o).title == CaptureAlerts.silentTitle)
        #expect(MicStatusText.outcome(o).tone == .warning)
    }

    @Test func theDefaultRule() {
        #expect(MicCalibrationText.rules(nil) == ["Default rule: camera L/R correlation below 0.880 means the built-in mic."])
        #expect(MicCalibrationText.sample(MicFeatureSample(cameraVoicedSeconds: 4)) == "4.0 s of voice")
    }

    @MainActor
    @Test func theCalibrationIsSaved() throws {
        let name = "MicCalibrationFlowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RecorderSettings(defaults: defaults).micCalibration == nil)
        var flow = MicCalibrationFlow()
        flow.record(outcome(correlation: 0.991, level: 12), for: .calibratePlugged)
        flow.record(outcome(correlation: 0.90, level: 0), for: .calibrateUnplugged)
        let calibration = try #require(flow.calibration)
        RecorderSettings(defaults: defaults).micCalibration = calibration
        #expect(RecorderSettings(defaults: defaults).micCalibration == calibration)
        RecorderSettings(defaults: defaults).micCalibration = nil
        #expect(RecorderSettings(defaults: defaults).micCalibration == nil)
        // Junk or another version is ignored.
        #expect(RecorderSettings.decodeCalibration(Data("nope".utf8)) == nil)
        var other = calibration
        other.version = MicCalibration.currentVersion + 1
        #expect(RecorderSettings.decodeCalibration(try JSONEncoder().encode(other)) == nil)
        // Version 2 counted every voiced block; the detector now counts only gated ones.
        #expect(MicCalibration.currentVersion == 3)
        other.version = 2
        #expect(RecorderSettings.decodeCalibration(try JSONEncoder().encode(other)) == nil)
    }
}

@Suite struct EmptyFramePhaseTests {
    let s: UInt64 = 1_000_000_000

    @Test func noGreenBox() {
        let inputs = PreviewInputs(showing: true, blocked: nil, hasCamera: true, connected: true, hold: nil,
                                   camera: .ready, pictureFresh: true, emptyFrames: true)
        #expect(PreviewRules.phase(inputs) == .emptyFrames)
        #expect(PreviewPhase.emptyFrames.message == "No picture")
        var stale = inputs
        stale.pictureFresh = false
        #expect(PreviewRules.phase(stale) == .noPicture)
    }

    @Test func whileRecording() {
        #expect(PreviewRules.recordingPhase(stage: .recording, recordsCamera: true, previewKept: true, lastFrameNs: 20 * s,
                                            sinceNs: 10 * s, nowNs: 20 * s, emptyFrames: true) == .emptyFrames)
        #expect(PreviewRules.recordingPhase(stage: .starting, recordsCamera: true, previewKept: nil, lastFrameNs: 20 * s,
                                            sinceNs: 10 * s, nowNs: 20 * s, emptyFrames: true) == .emptyFrames)
        #expect(PreviewRules.recordingPhase(stage: .recording, recordsCamera: true, previewKept: false, lastFrameNs: 20 * s,
                                            sinceNs: 10 * s, nowNs: 20 * s, emptyFrames: true) == .paused)
    }
}

/// Source-level guards for the wiring the devices need: the take's recorders meter into the
/// app's one monitor, Start ends a mic check before it opens the camera audio, and the mic check
/// is the only idle path that opens a mic.
@Suite struct MicWiringTests {
    static func coordinatorCode() throws -> [String] {
        let url = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift")
        return try ThreadRuleTests.codeLines(url).map(\.1)
    }

    @Test func theRecordersMeterIntoTheMonitor() throws {
        let code = try Self.coordinatorCode()
        #expect(code.contains { $0.contains("CameraRecorder(config: config, levels: levels)") })
        #expect(code.contains { $0.contains("CameraRecorder(config: target.config, levels: levels)") })
        #expect(code.contains { $0.contains("ScreenRecorder(config: $0, levels: levels)") })
        #expect(code.contains { $0.contains("levels = AudioLevelMonitor(calibration: settings.micCalibration)") })
    }

    /// Start ends a mic check before the take opens the camera audio (the recorders' prepare),
    /// and only once preflight has passed: a blocked or cancelled start leaves the check running.
    @Test func startEndsTheMicCheckFirst() throws {
        let code = try Self.coordinatorCode()
        let start = try #require(code.firstIndex { $0.contains("private func runStart(claimed: WarmCamera?) async {") })
        let blocker = try #require(code[start...].firstIndex { $0.contains("if let blocker = SessionRules.blockers(found).first {") })
        let end = try #require(code[blocker...].firstIndex { $0.contains("await endMicCheck()") })
        let prepare = try #require(code[start...].firstIndex { $0.contains("await Self.prepareAll(") })
        #expect(blocker < end && end < prepare)
        #expect(!code[start..<blocker].contains { $0.contains("await endMicCheck()") || $0.contains("calibrationFlow = nil") })
        #expect(code.filter { $0.contains("MicCheck(cameraAudioUID:") }.count == 1)
    }

    /// A reconnect in flight ends before Start decides on the claimed camera and before the
    /// preview's close; the meter ticker runs only for a meter on screen (the menu, the camera
    /// window's camera mic bar, the control bar's Mac mic meter).
    @Test func startAndTheCloseWaitForAReconnect() throws {
        let code = try Self.coordinatorCode()
        #expect(code.filter { $0.contains("waitForReconnect(atMost: Self.reconnectWait)") }.count == 2)
        let start = try #require(code.firstIndex { $0.contains("private func runStart(claimed: WarmCamera?) async {") })
        let body = Array(code[start...].prefix(40))
        let wait = try #require(body.firstIndex { $0.contains("claimed.recorder.waitForReconnect") })
        let decide = try #require(body.firstIndex { $0.contains("claimed.recorder.isOpen") })
        #expect(wait < decide)
        #expect(code.contains {
            $0.contains("(menuVisible || (cameraWindowWanted && cameraWindowShowsMeter) || (controlBarWanted && controlBarShowsMeter))")
        })
    }

    /// A cancel that lands before the mic check opens its mics (the permission prompt) leaves the
    /// monitor and the mics alone.
    @Test func aCancelledMicCheckOpensNothing() throws {
        let url = ThreadRuleTests.root.appendingPathComponent("Sources/CameraCapture/MicCheck.swift")
        let code = try ThreadRuleTests.codeLines(url).map(\.1)
        let guardLine = try #require(code.firstIndex { $0.contains("guard signal.value == nil, !Task.isCancelled else {") })
        let begin = try #require(code.firstIndex { $0.contains("levels.beginCheck()") })
        let prompt = try #require(code.firstIndex { $0.contains("await Self.microphoneAllowed()") })
        #expect(prompt < guardLine && guardLine < begin)
        #expect(code.contains { $0.contains("guard signal.value == nil else { break }") })
    }

    @Test func theNewFilesAreScanned() throws {
        let folder = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        for name in ["MicViews.swift", "MicRules.swift", "CaptureAlerts.swift"] { #expect(names.contains(name)) }
        let files = ["MicViews.swift", "MicRules.swift", "CaptureAlerts.swift"].map { folder.appendingPathComponent($0) }
        #expect(try ThreadRuleTests.violations(in: files) == [])
    }
}
