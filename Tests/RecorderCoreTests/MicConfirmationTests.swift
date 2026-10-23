import Foundation
import Testing
@testable import RecorderCore

/// Take 2026-10-14_093840 (9 min, Both mode, the Rode in the a6600 the whole time) as synthetic
/// 50 ms blocks. The detector warned twice that the camera used its built-in mic (at 284 s and
/// 455 s), both in long stretches where Luke did not talk: faint room sound, typing and the
/// replay's sound from the speakers (camera median -55 dBFS, 13 dB above its floor, L/R 0.75 to
/// 0.90; their 6 s means 0.857 and 0.853). His speech: camera -16 to -50 dBFS, L/R 0.97 to 0.999.
enum MeasuredTake {
    static let cameraFloorDb = -70.0
    static let macFloorDb = -73.0

    /// Luke talks (the `talking` phrases): the camera loud and dual mono, the Mac mic 6 dB lower.
    static func speech(_ i: Int64) -> (camera: AudioBlock, mac: AudioBlock) {
        let voiced = talking(i)
        let k = Double(i % 7)
        return (audioBlock(i, db: voiced ? -36 + 2 * k - 6 : cameraFloorDb + 0.5 * (k - 3),
                           correlation: voiced ? 0.985 + 0.002 * k : 0.6),
                audioBlock(i, db: voiced ? -42 + 2 * k - 6 : macFloorDb + 0.5 * (k - 3), channels: 1))
    }

    /// A faint stretch: sounds 10 to 18 dB above the camera's floor (-60 to -52 dBFS), which both
    /// mics hear, at the low L/R correlation of broadband sound; the floor between them.
    static func faint(_ i: Int64) -> (camera: AudioBlock, mac: AudioBlock) {
        let levels = [-70.0, -58, -56, -53, -55, -57, -60, -69, -54, -52, -56, -70]
        let correlations = [0.6, 0.78, 0.86, 0.82, 0.9, 0.84, 0.88, 0.6, 0.8, 0.85, 0.87, 0.6]
        let k = Int(i % Int64(levels.count))
        let sound = levels[k] > cameraFloorDb + 5
        return (audioBlock(i, db: levels[k], correlation: correlations[k]),
                audioBlock(i, db: sound ? levels[k] - 1 : macFloorDb, channels: 1))
    }

    /// The a6600 with the Rode unplugged: flat near-silence (take 2026-10-13_205644: -69.4 dBFS).
    static func unpluggedCamera(_ i: Int64) -> AudioBlock {
        audioBlock(i, db: -69.4 + 0.1 * Double(i % 3), correlation: 0.88)
    }

    /// The camera's built-in stereo mic hearing Luke: loud, decorrelated.
    static func builtInCamera(_ i: Int64) -> AudioBlock {
        let voiced = talking(i)
        return audioBlock(i, db: voiced ? -38 : cameraFloorDb, correlation: voiced ? 0.74 : 0.3)
    }

    /// The Mac mic while Luke talks.
    static func macHearsSpeech(_ i: Int64) -> AudioBlock {
        audioBlock(i, db: talking(i) ? -40 : macFloorDb, channels: 1)
    }
}

@Suite struct MicConfirmationTests {
    typealias Block = (camera: AudioBlock?, mac: AudioBlock?)

    /// Runs `blocks` blocks from `start` through `detector`; returns the changes with their block.
    @discardableResult
    func run(_ detector: inout CameraMicDetector, from start: Int64, blocks: Int64, evidence: Bool = true,
             _ make: (Int64) -> Block) -> [(Int64, MicDetectorChange)] {
        var changes: [(Int64, MicDetectorChange)] = []
        for i in start..<(start + blocks) {
            let b = make(i)
            if let change = detector.add(camera: b.camera, reference: b.mac, evidence: evidence) { changes.append((i, change)) }
        }
        return changes
    }

    /// The faint stretches of the take were the evidence for both false warnings. With the old
    /// rule (every voiced block, 10 dB over the floor) they still flip a Rode verdict to the
    /// built-in mic; behind the evidence gate (20 dB over the floor and -50 dBFS) they are no
    /// evidence at all, also before recording, where the rules never stop.
    @Test func faintSoundsAreNoEvidence() {
        let old = MicDetectorSettings(evidenceMarginDb: 10, minEvidenceDb: -65)
        var before = CameraMicDetector(settings: old)
        run(&before, from: 0, blocks: 600) { MeasuredTake.speech($0) }
        #expect(before.status.verdict == .externalMic)
        run(&before, from: 600, blocks: 2400) { MeasuredTake.faint($0) }
        #expect(before.status.verdict == .builtInMic, "the old rule reproduces the false warning")
        #expect((before.status.correlation ?? 1) < 0.87)

        var idle = CameraMicDetector(settings: .standard)
        run(&idle, from: 0, blocks: 600) { MeasuredTake.speech($0) }
        #expect(idle.status.verdict == .externalMic && !idle.status.confirmed)
        let evidenceBefore = idle.sample.correlation.count
        let changes = run(&idle, from: 600, blocks: 4800) { MeasuredTake.faint($0) }
        #expect(changes.isEmpty)
        #expect(idle.status.verdict == .externalMic && idle.status.message == nil)
        #expect(idle.sample.correlation.count == evidenceBefore)
        // A fresh detector that hears only the faint stretches has no verdict and no progress.
        var fresh = CameraMicDetector()
        run(&fresh, from: 0, blocks: 4800) { MeasuredTake.faint($0) }
        #expect(fresh.status.verdict == .unknown && fresh.status.progress == 0 && fresh.status.message == nil)
    }

    /// The gate's numbers: a block counts at 20 dB over the camera's floor and at -50 dBFS, not below.
    @Test func theEvidenceGate() {
        #expect(MicDetectorSettings.standard.evidenceMarginDb == 20 && MicDetectorSettings.standard.minEvidenceDb == -50)
        #expect(MicDetectorSettings.take.stopsWhenConfirmed && !MicDetectorSettings.standard.stopsWhenConfirmed)
        #expect(!MicDetectorSettings.micCheck.stopsWhenConfirmed && MicDetectorSettings.micCheck.evidenceMarginDb == 20)
        func evidence(_ db: Double, floor: Double) -> Int {
            var detector = CameraMicDetector()
            for i in Int64(0)..<60 {
                _ = detector.add(camera: audioBlock(i, db: floor, correlation: 0.5), reference: nil)
            }
            for i in Int64(60)..<80 {
                _ = detector.add(camera: audioBlock(i, db: i % 2 == 0 ? db : floor, correlation: 0.99), reference: nil)
            }
            return detector.sample.correlation.count
        }
        #expect(evidence(-49, floor: -70) == 10)
        #expect(evidence(-51, floor: -75) == 0)   // 24 dB over the floor, but under -50 dBFS.
        #expect(evidence(-41, floor: -60) == 0)   // A noisy room: 19 dB over its floor.
        #expect(evidence(-40, floor: -60) == 10)
        // The voiced time (voice.jsonl, the mic check's seconds of voice) keeps the 10 dB rule.
        var detector = CameraMicDetector()
        for i in Int64(0)..<200 { _ = detector.add(camera: audioBlock(i, db: talking(i) ? -55 : -70, correlation: 0.8), reference: nil) }
        #expect(detector.sample.cameraVoicedSeconds > 4 && detector.sample.correlation.count == 0)
    }

    /// The measured take with the take's rules: Luke talks for 20 s, the Rode is confirmed, and
    /// nothing after it warns: the faint stretches, a loud decorrelated sound (a cough, a clap,
    /// something the built-in mic would give), not even a camera that falls silent while the Mac
    /// mic hears him.
    @Test func aTakeStopsCheckingOnceTheRodeIsConfirmed() throws {
        var detector = CameraMicDetector(settings: .take)
        let start = run(&detector, from: 0, blocks: 400) { MeasuredTake.speech($0) }
        #expect(detector.status.confirmed && detector.status.verdict == .externalMic)
        #expect(start.count == 1)
        let (at, change) = try #require(start.first)
        #expect(change.verdictOrWarningChanged && change.confirmedNow)
        // 6 s of gated voice and the 1 s hold: never before 7 s of time.
        #expect(at >= 140 && at < 300, "confirmed at block \(at)")
        #expect(detector.confirmedAtIndex == at)

        var later: [(Int64, MicDetectorChange)] = []
        later += run(&detector, from: 400, blocks: 4800) { MeasuredTake.faint($0) }
        later += run(&detector, from: 5200, blocks: 600) { (MeasuredTake.builtInCamera($0), MeasuredTake.macHearsSpeech($0)) }
        later += run(&detector, from: 5800, blocks: 600) { (MeasuredTake.unpluggedCamera($0), MeasuredTake.macHearsSpeech($0)) }
        later += run(&detector, from: 6400, blocks: 3000) { _ in (audioBlock(0, db: -70, correlation: 0.5), nil) }
        #expect(later.isEmpty)
        #expect(detector.status.confirmed && detector.status.verdict == .externalMic)
        #expect(!detector.status.cameraMicSilent && detector.status.message == nil)
        let report = try #require(detector.report())
        #expect(report.confirmed == true && report.verdict == .externalMic && report.verdictsSeen == [.externalMic])
        #expect(!report.cameraMicSilent)
        // The report goes on collecting the gated evidence of the whole take.
        #expect(report.voicedS > 20)
    }

    /// The Rode unplugged at the start: the a6600 sends near-silence, and the silent-mic warning
    /// comes after about 8 s of clear voice on the Mac mic. If the camera switches to its built-in
    /// mic instead, the built-in mic warning comes. Neither take is confirmed.
    @Test func anUnpluggedRodeAtTheStartWarns() throws {
        var silent = CameraMicDetector(settings: .take)
        let changes = run(&silent, from: 0, blocks: 800) { (MeasuredTake.unpluggedCamera($0), MeasuredTake.macHearsSpeech($0)) }
        #expect(silent.status.cameraMicSilent && !silent.status.confirmed)
        #expect(silent.status.message == MicDetectorStatus.silentMessage)
        let warnedAt = try #require(changes.first?.0)
        #expect(warnedAt > 260 && warnedAt < 400, "warned at block \(warnedAt)")
        #expect(silent.report()?.confirmed == false)

        var builtIn = CameraMicDetector(settings: .take)
        run(&builtIn, from: 0, blocks: 800) { (MeasuredTake.builtInCamera($0), MeasuredTake.macHearsSpeech($0)) }
        #expect(builtIn.status.verdict == .builtInMic && !builtIn.status.confirmed)
        #expect(builtIn.status.message == MicDetectorStatus.builtInMessage)

        // Plugged in and talking: the warning clears, the Rode is confirmed, the checks stop.
        run(&silent, from: 800, blocks: 600) { MeasuredTake.speech($0) }
        #expect(!silent.status.cameraMicSilent && silent.status.confirmed)
        #expect(silent.report()?.verdictsSeen == [.externalMic] && silent.report()?.cameraMicSilent == true)
    }

    /// A take that is never confirmed checks for as long as it lasts: 3 minutes of faint sound and
    /// silence warn nothing; when Luke then talks with the Rode unplugged, the warning comes.
    @Test func aTakeThatIsNeverConfirmedWarnsWhenHeTalks() {
        var detector = CameraMicDetector(settings: .take)
        let quiet = run(&detector, from: 0, blocks: 3600) { i in
            // The a6600 silent (no Rode); the Mac mic hears the room, never a voice.
            (MeasuredTake.unpluggedCamera(i), audioBlock(i, db: MeasuredTake.macFloorDb + Double(i % 4), channels: 1))
        }
        #expect(quiet.isEmpty && detector.status.message == nil && !detector.status.confirmed)
        let talk = run(&detector, from: 3600, blocks: 800) { (MeasuredTake.unpluggedCamera($0), MeasuredTake.macHearsSpeech($0)) }
        #expect(talk.count == 1 && detector.status.cameraMicSilent)

        // The same with the built-in mic after 3 minutes of faint sound.
        var builtIn = CameraMicDetector(settings: .take)
        let faint = run(&builtIn, from: 0, blocks: 3600) { MeasuredTake.faint($0) }
        #expect(faint.isEmpty && builtIn.status.verdict == .unknown)
        run(&builtIn, from: 3600, blocks: 800) { (MeasuredTake.builtInCamera($0), MeasuredTake.macHearsSpeech($0)) }
        #expect(builtIn.status.verdict == .builtInMic && builtIn.status.message == MicDetectorStatus.builtInMessage)
    }

    /// Paused evidence (the replay's sound on): the speakers' sound adds nothing, not even toward
    /// the silent-mic warning, and nothing confirms. Afterwards the evidence counts again.
    @Test func pausedEvidenceAddsNothing() {
        var detector = CameraMicDetector(settings: .take)
        // The speakers play the take: the Mac mic (next to them) hears it loudly, the camera faintly
        // or decorrelated.
        let paused = run(&detector, from: 0, blocks: 1200, evidence: false) { i in
            (i % 2 == 0 ? MeasuredTake.builtInCamera(i) : MeasuredTake.unpluggedCamera(i), MeasuredTake.macHearsSpeech(i))
        }
        #expect(paused.isEmpty)
        #expect(detector.status.verdict == .unknown && !detector.status.cameraMicSilent && detector.status.progress == 0)
        #expect(detector.sample.correlation.count == 0 && detector.sample.cameraVoicedSeconds == 0)
        run(&detector, from: 1200, blocks: 400) { MeasuredTake.speech($0) }
        #expect(detector.status.confirmed)
    }
}

@Suite struct MicConfirmationMonitorTests {
    /// A take's monitor: blocks on the host clock from `startBlock`, the scheduled start at it.
    struct Take {
        let monitor = AudioLevelMonitor()
        let events: EventLog
        let url: URL
        let startBlock: Int64 = 20_000_000  // 1,000,000 s of host time.
        var block: Int64

        init(dir: URL) throws {
            url = dir.appendingPathComponent("events.jsonl")
            events = try EventLog(url: url)
            block = startBlock
            monitor.beginTake(events: events, startHostNs: UInt64(startBlock) * AudioBlock.durationNs)
            monitor.beginTake(events: events, startHostNs: UInt64(startBlock) * AudioBlock.durationNs)
        }

        mutating func run(_ blocks: Int64, _ make: (Int64) -> (camera: AudioBlock?, mac: AudioBlock?)) {
            for _ in 0..<blocks {
                let b = make(block - startBlock)
                let receivedNs = UInt64(block + 1) * AudioBlock.durationNs
                if var c = b.camera { c.index = block; monitor.publish(c, from: .cameraMic, receivedNs: receivedNs) }
                if var m = b.mac { m.index = block; monitor.publish(m, from: .screenMic, receivedNs: receivedNs) }
                block += 1
            }
        }

        func logged() throws -> [SessionEvent] {
            events.close()
            return try EventLog.read(url).filter { $0.type == .micDetector || $0.type == .micConfirmed }
        }
    }

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The measured take through the monitor: confirmed within the first 20 s of talking, one
    /// `mic_detector` and one `mic_confirmed`, then 8 minutes of faint stretches, the replay's
    /// sound and more talking without a single warning. session.json says so.
    @Test func theMeasuredTakeWarnsNothingAfterTheConfirmation() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var take = try Take(dir: dir)
        take.run(400) { MeasuredTake.speech($0) }
        #expect(take.monitor.detectorStatus.confirmed)
        take.run(1000) { MeasuredTake.faint($0) }                     // 20 s to 70 s.
        take.monitor.setEvidencePaused(true)                          // The replay's sound, 70 s to 320 s.
        take.run(5000) { i in i % 3 == 0 ? MeasuredTake.speech(i) : MeasuredTake.faint(i) }
        take.monitor.setEvidencePaused(false)
        take.run(2000) { MeasuredTake.faint($0) }                     // To 420 s: where the second warning was.
        take.run(400) { MeasuredTake.speech($0) }
        take.run(2000) { MeasuredTake.faint($0) }
        #expect(take.monitor.detectorStatus.message == nil && take.monitor.detectorStatus.confirmed)

        let report = try #require(take.monitor.endTake(events: take.events))
        let logged = try take.logged()
        #expect(logged.map(\.type) == [.micDetector, .micConfirmed])
        #expect(logged.first?.data?["verdict"] == "external_mic" && logged.first?.data?["previous"] == "unknown")
        let confirmed = try #require(logged.last?.data)
        #expect(confirmed["verdict"] == "external_mic" && confirmed["calibrated"] == "false")
        #expect(confirmed["correlation_threshold"] == "0.880" && confirmed["voiced_s"] == "6.0")
        let corr = try #require(confirmed["correlation"].flatMap(Double.init))
        #expect(corr > 0.98)
        let elapsed = try #require(confirmed["elapsed_s"].flatMap(Double.init))
        #expect(elapsed >= 7 && elapsed < 15)

        #expect(report.confirmed == true && report.verdict == .externalMic && report.verdictsSeen == [.externalMic])
        #expect(report.confirmedAtS == elapsed)

        // session.json keys (1.5), and a 1.4 mic_source without them still reads.
        var track = TrackInfo(file: "camera.mov", trackIndex: 1, role: .mic, dialogue: true)
        track.micSource = report
        let json = try #require(String(data: SessionManifest.encoder().encode(track), encoding: .utf8))
        #expect(json.contains("\"confirmed\" : true") && json.contains("\"confirmed_at_s\""))
        #expect(try SessionManifest.decoder().decode(TrackInfo.self, from: Data(json.utf8)).micSource == report)
        let old = json.replacingOccurrences(of: "\"confirmed\" : true,", with: "")
            .replacingOccurrences(of: "\"confirmed_at_s\" : \(elapsed),", with: "")
        #expect(!old.contains("confirmed"))
        let legacy = try SessionManifest.decoder().decode(TrackInfo.self, from: Data(old.utf8))
        #expect(legacy.micSource?.confirmed == nil && legacy.micSource?.verdict == .externalMic)
        #expect(SessionManifest.currentSchemaVersion == "1.6")
    }

    /// While the replay's sound plays, its sound in the mics is no evidence: no warning, no
    /// progress, no confirmation. Once it is off, the Rode is confirmed as usual.
    @Test func replaySoundIsNoEvidence() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var take = try Take(dir: dir)
        take.monitor.setEvidencePaused(true)
        #expect(take.monitor.evidencePaused)
        take.run(1200) { i in
            (i % 2 == 0 ? MeasuredTake.builtInCamera(i) : MeasuredTake.unpluggedCamera(i), MeasuredTake.macHearsSpeech(i))
        }
        let status = take.monitor.detectorStatus
        #expect(status.verdict == .unknown && !status.cameraMicSilent && status.progress == 0 && !status.confirmed)
        // The meters and the voice timeline go on.
        #expect(take.monitor.snapshot().cameraMic != nil && !take.monitor.voiceTimeline().screenMic.isEmpty)
        take.monitor.setEvidencePaused(false)
        take.run(400) { MeasuredTake.speech($0) }
        #expect(take.monitor.detectorStatus.confirmed)
        #expect(try take.logged().map(\.type) == [.micDetector, .micConfirmed])

        // The pause is the replay's, not the take's: a new take does not clear it, and before
        // recording it pauses the idle detector the same way.
        let idle = AudioLevelMonitor()
        idle.setEvidencePaused(true)
        idle.reset()
        #expect(idle.evidencePaused)
        var live = AudioLevelMonitorTests.LiveStream(monitor: idle)
        live.run(800, camera: { MeasuredTake.builtInCamera($0) }, mac: { MeasuredTake.macHearsSpeech($0) })
        #expect(idle.detectorStatus.verdict == .unknown && idle.detectorStatus.message == nil)
    }

    /// Evidence counts again 0.5 s after the replay's sound stops (blocks on their way from the
    /// mics, the room's tail). Saying "not paused" again does not start that wait over, and a
    /// monitor that was never paused has none.
    @Test func evidenceCountsAgainHalfASecondAfterTheReplaySound() throws {
        let monitor = AudioLevelMonitor()
        monitor.setEvidencePaused(false)
        #expect(!monitor.evidencePaused)
        var live = AudioLevelMonitorTests.LiveStream(monitor: monitor)
        let quiet: (Int64) -> AudioBlock? = { audioBlock($0, db: MeasuredTake.cameraFloorDb, correlation: 0.6) }
        let quietMac: (Int64) -> AudioBlock? = { audioBlock($0, db: MeasuredTake.macFloorDb, channels: 1) }
        let loud: (Int64) -> AudioBlock? = { audioBlock($0, db: -30, correlation: 0.99) }
        let loudMac: (Int64) -> AudioBlock? = { audioBlock($0, db: -36, channels: 1) }
        live.run(20, camera: quiet, mac: quietMac)
        monitor.setEvidencePaused(true)
        live.run(20, camera: loud, mac: loudMac)
        #expect(try #require(monitor.takeReport()).voicedS == 0)
        monitor.setEvidencePaused(false)
        #expect(monitor.evidencePaused)
        live.run(Int64(AudioLevelMonitor.evidenceResumeBlocks) - 1, camera: loud, mac: loudMac)
        monitor.setEvidencePaused(false)  // Each poll says it again.
        live.run(1, camera: loud, mac: loudMac)
        #expect(try #require(monitor.takeReport()).voicedS == 0)
        #expect(!monitor.evidencePaused)
        live.run(10, camera: loud, mac: loudMac)
        #expect(try #require(monitor.takeReport()).voicedS == 0.5)
    }

    /// Before recording the checks never stop: the Rode is detected (not confirmed), and when it
    /// is unplugged and Luke talks, the warning comes. A take starts over with its own rules.
    @Test func beforeRecordingTheChecksNeverStop() throws {
        let monitor = AudioLevelMonitor()
        var live = AudioLevelMonitorTests.LiveStream(monitor: monitor)
        live.run(600, camera: { MeasuredTake.speech($0).camera }, mac: { MeasuredTake.speech($0).mac })
        #expect(monitor.detectorStatus.verdict == .externalMic && !monitor.detectorStatus.confirmed)
        live.run(4800, camera: { MeasuredTake.faint($0).camera }, mac: { MeasuredTake.faint($0).mac })
        #expect(monitor.detectorStatus.verdict == .externalMic && monitor.detectorStatus.message == nil)
        live.run(800, camera: { MeasuredTake.unpluggedCamera($0) }, mac: { MeasuredTake.macHearsSpeech($0) })
        #expect(monitor.detectorStatus.cameraMicSilent)
        #expect(monitor.detectorStatus.message == MicDetectorStatus.silentMessage)

        // Start: the take's detector starts over and checks again until it confirms.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        defer { events.close() }
        monitor.beginTake(events: events)
        #expect(monitor.detectorStatus == MicDetectorStatus())
        live.run(800, camera: { MeasuredTake.unpluggedCamera($0) }, mac: { MeasuredTake.macHearsSpeech($0) })
        #expect(monitor.detectorStatus.cameraMicSilent && !monitor.detectorStatus.confirmed)
        // Without a start time the confirmation has no take time; the report still says confirmed.
        live.run(600, camera: { MeasuredTake.speech($0).camera }, mac: { MeasuredTake.speech($0).mac })
        let report = try #require(monitor.endTake(events: events))
        #expect(report.confirmed == true && report.confirmedAtS == nil && report.cameraMicSilent)
    }

    /// After Stop the check runs again before the next take: the take's confirmation does not
    /// carry over into the idle meters, so a Rode unplugged between takes warns.
    @Test func afterATakeTheChecksRunAgain() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var take = try Take(dir: dir)
        take.run(400) { MeasuredTake.speech($0) }
        #expect(take.monitor.detectorStatus.confirmed)
        let first = take.monitor.endTake(events: take.events)   // screen.mov
        #expect(take.monitor.takeRuns && take.monitor.detectorStatus.confirmed)
        let last = try #require(take.monitor.endTake(events: take.events))  // camera.mov: the take is over.
        #expect(!take.monitor.takeRuns)
        #expect(first?.confirmed == true && last.confirmed == true && last.confirmedAtS != nil)
        // Idle: the take's verdict is kept, the rules run again.
        let idle = take.monitor.detectorStatus
        #expect(idle.verdict == .externalMic && !idle.confirmed && idle.message == nil)
        #expect(take.monitor.takeReport()?.confirmed == true)
        take.run(800) { (MeasuredTake.unpluggedCamera($0), MeasuredTake.macHearsSpeech($0)) }
        #expect(take.monitor.detectorStatus.cameraMicSilent)
        #expect(take.monitor.detectorStatus.message == MicDetectorStatus.silentMessage)
        // Nothing is logged while idle.
        #expect(try take.logged().map(\.type) == [.micDetector, .micConfirmed])
    }

    @Test func takeTimeOfABlock() {
        #expect(AudioLevelMonitor.takeTime(blockIndex: 199, startNs: 0) == 10)
        #expect(AudioLevelMonitor.takeTime(blockIndex: 10, startNs: nil) == nil)
        #expect(AudioLevelMonitor.takeTime(blockIndex: 10, startNs: 5_000_000_000) == 0)
        #expect(SessionEvent.Kind(rawValue: "mic_confirmed") == .micConfirmed)
    }
}
