import Foundation
import Testing
@testable import RecorderCore
@testable import Replay

@Suite struct ReplayTakeTests {
    private func event(_ kind: SessionEvent.Kind, at t: UInt64 = 0, _ data: [String: String]? = nil) -> SessionEvent {
        SessionEvent(tHostNs: t, wall: "", type: kind, data: data)
    }

    /// The events of a live take tell the replay where take time 0 is, where each movie begins,
    /// its audio tracks and its flags.
    @Test func takeInfoComesFromTheEvents() {
        var info = ReplayTakeInfo()
        info.apply([
            event(.sessionStart, at: 5_000_000_000, ["mode": "both"]),
            event(.trackStart, ["file": "screen.mov", "role": "screen_video", "track_index": "0", "first_pts_host_ns": "5004000000"]),
            event(.trackStart, ["file": "screen.mov", "role": "mic", "track_index": "1", "first_pts_host_ns": "5004000000"]),
            event(.trackStart, ["file": "screen.mov", "role": "system_audio", "track_index": "2"]),
            event(.trackStart, ["file": "camera.mov", "role": "camera_video", "track_index": "0", "first_pts_host_ns": "5021000000"]),
            event(.trackStart, ["file": "camera.mov", "role": "mic", "track_index": "1"]),
            event(.marker, ["kind": "flag", "elapsed_s": "754.2", "lookback_s": "180"]),
            event(.marker, ["kind": "good", "elapsed_s": "800.0"]),
            event(.marker, ["kind": "flag", "elapsed_s": "900.0"]),
        ])
        #expect(info.startedAtHostNs == 5_000_000_000)
        #expect(info.firstPtsHostNs == [.screen: 5_004_000_000, .camera: 5_021_000_000])
        #expect(abs(info.alignment.offset(.camera) - 0.021) < 1e-12)
        #expect(info.audioTracks == [ReplayAudioTrack(file: .screen, trackIndex: 1, role: .mic),
                                     ReplayAudioTrack(file: .screen, trackIndex: 2, role: .systemAudio),
                                     ReplayAudioTrack(file: .camera, trackIndex: 1, role: .mic)])
        // Only flags count; a flag without lookback_s gets the default 3 min.
        #expect(info.flags == [FlagMark(atS: 754.2, lookbackS: 180), FlagMark(atS: 900, lookbackS: 180)])
        #expect(!info.stopped)
        info.apply(event(.sessionStop))
        #expect(info.stopped)
        // The same event again changes nothing.
        let before = info
        info.apply(event(.marker, ["kind": "flag", "elapsed_s": "754.2", "lookback_s": "180"]))
        #expect(info == before)
    }

    @Test func takeInfoComesFromAFinishedManifest() {
        var manifest = SessionManifest(mode: .camera, recorder: RecorderInfo(name: "TwinTake", version: "test"),
                                       host: HostInfo(model: "Mac", macosVersion: "27.2"))
        manifest.startedAtHostNs = 7_000
        var video = TrackInfo(file: "camera.mov", trackIndex: 0, role: .cameraVideo, dialogue: false)
        video.firstPtsHostNs = 7_500
        let mic = TrackInfo(file: "camera.mov", trackIndex: 1, role: .mic, dialogue: true)
        manifest.tracks = [video, mic]
        manifest.status = .complete
        var info = ReplayTakeInfo()
        info.apply(manifest)
        #expect(info.startedAtHostNs == 7_000 && info.firstPtsHostNs == [.camera: 7_500])
        #expect(info.audioTracks == [ReplayAudioTrack(file: .camera, trackIndex: 1, role: .mic)])
        #expect(info.stopped)
    }

    /// events.jsonl is read as it grows; a line the writer has not finished waits for the next read.
    @Test func theTailReadsOnlyNewCompleteLines() throws {
        let dir = try temporaryFolder("replay-tail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let tail = EventsTail(url: url)
        log.append(.sessionStart, ["mode": "both"], at: 1)
        log.append(.marker, ["kind": "flag", "elapsed_s": "1.0", "lookback_s": "60"], at: 2)
        #expect(tail.readNew().map(\.type) == [.sessionStart, .marker])
        #expect(tail.readNew().isEmpty)
        // Half a line, as a crash or a write in progress leaves it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"t_host_ns":3,"wall":"","type":"mar"#.utf8))
        #expect(tail.readNew().isEmpty)
        try handle.write(contentsOf: Data(#"ker","data":{"kind":"flag","elapsed_s":"2.0"}}"#.utf8 + [0x0A]))
        try handle.close()
        let next = tail.readNew()
        #expect(next.map(\.tHostNs) == [3])
        log.close()
        let more = try FileHandle(forWritingTo: url)
        try more.seekToEnd()
        try more.write(contentsOf: Data(#"{"t_host_ns":4,"wall":"","type":"session_stop"}"#.utf8 + [0x0A]))
        try more.close()
        #expect(tail.readNew().map(\.type) == [.sessionStop])
        #expect(EventsTail(url: dir.appendingPathComponent("missing.jsonl")).readNew().isEmpty)
    }

    @Test func aFinishedTakeLoadsItsFilesAndVoice() throws {
        let dir = try temporaryFolder("replay-finished-files")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = SessionFolder(url: dir)
        FileManager.default.createFile(atPath: folder.screenURL.path, contents: Data())
        let log = try EventLog(url: folder.eventsURL)
        log.append(.sessionStart, nil, at: 10_000_000_000)
        log.append(.marker, ["kind": "flag", "elapsed_s": "3.0", "lookback_s": "30"], at: 13_000_000_000)
        log.close()
        let timeline = VoiceTimeline(screenMic: [VoiceSegment(startNs: 11_000_000_000, endNs: 12_000_000_000)], screenMicVoicedS: 1)
        try VoiceTimelineFile.encode(timeline, originNs: 10_000_000_000).write(to: folder.voiceURL)

        let files = ReplayTakeFiles.find(in: dir)
        #expect(files.files == [.screen])
        let loaded = files.loadFinished()
        #expect(loaded.info.startedAtHostNs == 10_000_000_000)
        #expect(loaded.info.flags == [FlagMark(atS: 3, lookbackS: 30)])
        #expect(loaded.voice?.screenMic == timeline.screenMic)
        #expect(loaded.voiceOriginNs == 10_000_000_000)
    }
}
