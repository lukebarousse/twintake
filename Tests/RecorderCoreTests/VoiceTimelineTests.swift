import Foundation
import Testing
@testable import RecorderCore

/// The voice timeline the replay's Skip silence uses: speech stretches from the meters' 50 ms
/// blocks, with the camera mic detector's voice rule.
@Suite struct VoiceTimelineTests {
    private let ms = UInt64(AudioBlock.durationNs)

    /// Blocks `range` at `voice` dBFS where `talks` says so, else at `noise`.
    private func feed(_ builder: inout VoiceTrackBuilder, _ range: Range<Int64>, voice: Double = -30, noise: Double = -70,
                      talks: (Int64) -> Bool) {
        for i in range { builder.add(audioBlock(i, db: talks(i) ? voice : noise)) }
    }

    @Test func wordsJoinIntoOneStretchAndPausesSplitIt() {
        var builder = VoiceTrackBuilder()
        // 1 s of room, then 1 s of speech with a 150 ms dip, 2 s of pause, 0.5 s of speech.
        feed(&builder, 0..<100) { i in (20..<40).contains(i) && !(28..<31).contains(i) || (80..<90).contains(i) }
        #expect(builder.timeline == [VoiceSegment(startNs: 20 * ms, endNs: 40 * ms), VoiceSegment(startNs: 80 * ms, endNs: 90 * ms)])
        #expect(builder.voicedBlocks == 27)
        #expect(abs(builder.voicedSeconds - 1.35) < 1e-9)
        #expect(builder.blocks == 100)
    }

    @Test func aGapOverTwoHundredMillisecondsSplits() {
        var builder = VoiceTrackBuilder()
        feed(&builder, 0..<60) { i in (20..<25).contains(i) || (30..<35).contains(i) }
        // 5 unvoiced blocks (250 ms) between them: two stretches.
        #expect(builder.timeline.count == 2)
        var joined = VoiceTrackBuilder()
        feed(&joined, 0..<60) { i in (20..<25).contains(i) || (29..<35).contains(i) }
        // 4 unvoiced blocks (200 ms): one.
        #expect(joined.timeline == [VoiceSegment(startNs: 20 * ms, endNs: 35 * ms)])
    }

    /// A keystroke or a click (one or two blocks) is no speech.
    @Test func shortClicksAreNoSpeech() {
        var builder = VoiceTrackBuilder()
        feed(&builder, 0..<80) { i in i == 30 || i == 50 || i == 51 }
        #expect(builder.timeline.isEmpty)
        #expect(builder.voicedBlocks == 3)
    }

    /// The detector's rule: 10 dB over the noise floor and above -65 dBFS.
    @Test func quietRoomsAndLoudFloorsFollowTheDetectorRule() {
        var quiet = VoiceTrackBuilder()
        // Voice at -68 dBFS over a -90 floor is under -65: no speech.
        feed(&quiet, 0..<60, voice: -68, noise: -90) { (20..<40).contains($0) }
        #expect(quiet.timeline.isEmpty)
        var loud = VoiceTrackBuilder()
        // Voice only 8 dB over the floor: no speech.
        feed(&loud, 0..<60, voice: -42, noise: -50) { (20..<40).contains($0) }
        #expect(loud.timeline.isEmpty)
    }

    @Test func theOpenStretchShowsUpToItsLastVoicedBlock() {
        var builder = VoiceTrackBuilder()
        feed(&builder, 0..<45) { $0 >= 30 }
        #expect(builder.timeline == [VoiceSegment(startNs: 30 * ms, endNs: 45 * ms)])
        #expect(builder.segments.isEmpty)
        // Old or repeated blocks change nothing.
        builder.add(audioBlock(10, db: -30))
        builder.add(audioBlock(44, db: -70))
        #expect(builder.timeline == [VoiceSegment(startNs: 30 * ms, endNs: 45 * ms)])
    }

    @Test func theCameraMicLeadsAndTheMacMicStandsInWhenItIsSilent() {
        var both = VoiceTimelineBuilder()
        for i in Int64(0)..<200 {
            let talking = talking(i)
            both.add(audioBlock(i, db: talking ? -30 : -70), from: .cameraMic)
            both.add(audioBlock(i, db: talking ? -36 : -62), from: .screenMic)
            both.add(audioBlock(i, db: -10), from: .systemAudio)  // Never voice.
        }
        #expect(both.timeline.preferredSource == .cameraMic)
        #expect(both.timeline.speech == both.timeline.cameraMic)
        #expect(!both.timeline.cameraMic.isEmpty && !both.timeline.screenMic.isEmpty)

        // The camera sends silence (an unplugged Rode on the a6600): the Mac mic speaks for the take.
        var silentCamera = VoiceTimelineBuilder()
        for i in Int64(0)..<400 {
            silentCamera.add(audioBlock(i, db: -69.4), from: .cameraMic)
            silentCamera.add(audioBlock(i, db: talking(i) ? -36 : -62), from: .screenMic)
        }
        #expect(silentCamera.timeline.preferredSource == .screenMic)
        #expect(silentCamera.timeline.speech == silentCamera.timeline.screenMic)

        // A 30-minute take: the Rode is out for 5 minutes and the camera sends flat silence. The
        // camera mic still leads the take, and the Mac mic stands in for those 5 minutes only;
        // a Mac-only sound next to camera speech (a keystroke between words) is not added.
        let s: UInt64 = 1_000_000_000
        let camera = [VoiceSegment(startNs: 0, endNs: 600 * s), VoiceSegment(startNs: 900 * s, endNs: 1800 * s)]
        let screen = [VoiceSegment(startNs: 10 * s, endNs: 590 * s), VoiceSegment(startNs: 601 * s, endNs: 601 * s + s / 2),
                      VoiceSegment(startNs: 620 * s, endNs: 700 * s), VoiceSegment(startNs: 710 * s, endNs: 880 * s),
                      VoiceSegment(startNs: 905 * s, endNs: 1790 * s)]
        let unplugged = VoiceTimeline(cameraMic: camera, screenMic: screen, cameraMicVoicedS: 1500, screenMicVoicedS: 1500)
        #expect(unplugged.preferredSource == .cameraMic)
        #expect(unplugged.speech == [camera[0], screen[2], screen[3], camera[1]])

        var screenOnly = VoiceTimelineBuilder()
        screenOnly.add(audioBlock(0, db: -60), from: .screenMic)
        #expect(screenOnly.timeline.preferredSource == .screenMic)
        #expect(VoiceTimeline.empty.preferredSource == nil)
        #expect(VoiceTimeline.empty.speech.isEmpty)
    }

    @Test func voiceFileRoundTripsInSecondsSinceTheStart() throws {
        let origin: UInt64 = 1_234_000_000_000
        let timeline = VoiceTimeline(cameraMic: [VoiceSegment(startNs: origin + 1_250_000_000, endNs: origin + 3_400_000_000)],
                                     screenMic: [VoiceSegment(startNs: origin + 1_300_000_000, endNs: origin + 3_350_000_000),
                                                 VoiceSegment(startNs: origin - 200_000_000, endNs: origin + 100_000_000)],
                                     cameraMicVoicedS: 2.1, screenMicVoicedS: 2.3)
        let data = VoiceTimelineFile.encode(timeline, originNs: origin)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].contains(#""type":"header""#) && lines[0].contains(#""origin_host_ns":"1234000000000""#))
        #expect(lines[0].contains(#""preferred":"camera_mic""#))
        #expect(lines[1] == #"{"end_s":3.4,"source":"camera_mic","start_s":1.25,"type":"speech"}"#)
        // A stretch that began before the start is cut at 0.
        #expect(lines[3] == #"{"end_s":0.1,"source":"screen_mic","start_s":0,"type":"speech"}"#)

        let decoded = try #require(VoiceTimelineFile.decode(data))
        #expect(decoded.originNs == origin)
        #expect(decoded.timeline.cameraMic == timeline.cameraMic)
        #expect(decoded.timeline.screenMic.count == 2)
        #expect(decoded.timeline.screenMic.last == VoiceSegment(startNs: origin, endNs: origin + 100_000_000))
        #expect(decoded.timeline.preferredSource == .cameraMic)
        #expect(decoded.timeline.cameraMicVoicedS == 2.1)
        // Garbage lines are skipped; no header is no file.
        #expect(VoiceTimelineFile.decode(Data("nonsense\n".utf8)) == nil)
        let damaged = data + Data("{\"type\":\"speech\",\"source\":\"camera_mic\",\"start_s\":9,\"end_s\":".utf8)
        #expect(VoiceTimelineFile.decode(damaged)?.timeline.cameraMic.count == 1)
    }

    /// The monitor collects the timeline during a take only, from both mics, and starts over
    /// at the next take.
    @Test func theMonitorCollectsVoiceDuringATake() throws {
        let monitor = AudioLevelMonitor()
        // Idle (the metered preview): nothing collected.
        for i in Int64(0)..<40 { monitor.publish(audioBlock(i, db: i >= 20 ? -30 : -70), from: .cameraMic) }
        #expect(monitor.voiceTimeline() == VoiceTimeline(cameraMicHeard: false, screenMicHeard: false))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        monitor.beginTake(events: events)
        for i in Int64(100)..<200 {
            monitor.publish(audioBlock(i, db: (130..<150).contains(i) ? -30 : -70), from: .cameraMic)
            monitor.publish(audioBlock(i, db: (131..<150).contains(i) ? -40 : -62), from: .screenMic)
        }
        let take = monitor.voiceTimeline()
        #expect(take.cameraMic == [VoiceSegment(startNs: 130 * ms, endNs: 150 * ms)])
        #expect(take.screenMic == [VoiceSegment(startNs: 131 * ms, endNs: 150 * ms)])
        #expect(take.preferredSource == .cameraMic)
        // After Stop the last take's timeline stays for the replay; the meters going on add nothing.
        monitor.endTake(events: events)
        for i in Int64(200)..<260 { monitor.publish(audioBlock(i, db: i >= 230 ? -30 : -70), from: .cameraMic) }
        #expect(monitor.voiceTimeline() == take)
        // The next take starts over.
        let next = try EventLog(url: dir.appendingPathComponent("events2.jsonl"))
        monitor.beginTake(events: next)
        #expect(monitor.voiceTimeline().cameraMic.isEmpty)
        events.close()
        next.close()
    }

    /// An hour of talking through the monitor (both mics, 20 blocks a second each, on the capture
    /// queues' path): the voice collection stays cheap, and the timeline stays small.
    @Test func anHourOfTalkingStaysCheap() throws {
        let monitor = AudioLevelMonitor()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-hour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        monitor.beginTake(events: events)
        let clock = ContinuousClock()
        let began = clock.now
        for i in Int64(0)..<72_000 {
            let talks = talking(i)
            monitor.publish(audioBlock(i, db: talks ? -30 : -70, correlation: talks ? 0.99 : 0.1), from: .cameraMic)
            monitor.publish(audioBlock(i, db: talks ? -36 : -62), from: .screenMic)
        }
        let took = clock.now - began
        let copyBegan = clock.now
        let timeline = monitor.voiceTimeline()
        let copyTook = clock.now - copyBegan
        // One stretch per 5 s phrase cycle (the 1.5 s pause splits; the 200 ms word gaps join).
        #expect(timeline.cameraMic.count == 720)
        #expect(timeline.screenMic.count == 720)
        #expect(took < .seconds(20), "\(took) for an hour of blocks")
        #expect(copyTook < .milliseconds(50), "\(copyTook) to copy the timeline")
        events.close()
    }
}
