import AVFoundation
import Foundation
import Testing
@testable import CameraCapture
@testable import MediaWriter
import RecorderCore
import Synchronization

@Suite struct CameraTrackBuilderTests {
    func facts(audio: Bool = true) -> CameraTrackFacts {
        var f = CameraTrackFacts(
            videoDevice: DeviceInfo(name: "Cam Link 4K", uid: "0x206000000fd90066", negotiatedFormat: "3840x2160 420v 23.976"),
            codec: .hevc, width: 3840, height: 2160, frameRate: .fps23_976)
        f.videoFirstPts = FirstPts(hostNs: 1_000_000_000, source: .sample)
        f.videoDurationS = 61.5
        f.droppedFrames = 2
        f.slotsRepeated = 2
        f.slotsSkipped = 1
        f.measuredPtsFps = 23.98
        f.measuredArrivalFps = 23.976_02
        if audio {
            f.audio = CameraTrackFacts.Audio(
                device: DeviceInfo(name: "Cam Link 4K", uid: "camlink-audio", negotiatedFormat: "2 ch, 48 kHz"),
                sampleRate: 48_000, channels: 2, firstPts: FirstPts(hostNs: 1_000_000_000, source: .sample), durationS: 61.5)
        }
        return f
    }

    @Test func videoAndMicTracks() {
        let tracks = CameraTrackBuilder.tracks(facts())
        #expect(tracks.count == 2)

        let v = tracks[0]
        #expect(v.file == "camera.mov" && v.trackIndex == 0 && v.role == .cameraVideo && !v.dialogue)
        #expect(v.codec == "hevc" && v.width == 3840 && v.height == 2160)
        #expect(v.frameRate == FrameRate(num: 24000, den: 1001))
        #expect(v.constantFrameRate == true)
        #expect(v.firstPtsHostNs == 1_000_000_000 && v.firstPtsSource == "sample")
        #expect(v.device?.negotiatedFormat == "3840x2160 420v 23.976")
        #expect(v.durationS == 61.5 && v.droppedFrames == 2)
        #expect(v.slotsRepeated == 2 && v.slotsSkipped == 1)
        #expect(v.measuredPtsFps == 23.98 && v.measuredArrivalFps == 23.976)
        #expect(v.sampleRate == nil && v.channels == nil)

        let a = tracks[1]
        #expect(a.file == "camera.mov" && a.trackIndex == 1 && a.role == .mic && !a.dialogue)
        #expect(a.codec == "lpcm" && a.sampleRate == 48_000 && a.channels == 2)
        #expect(a.device?.uid == "camlink-audio")
        #expect(a.firstPtsHostNs == 1_000_000_000 && a.firstPtsSource == "sample")
        #expect(a.width == nil && a.frameRate == nil && a.slotsRepeated == nil)
    }

    @Test func noAudioMeansOneTrack() {
        let tracks = CameraTrackBuilder.tracks(facts(audio: false))
        #expect(tracks.map(\.role) == [.cameraVideo])
    }

    @Test func tracksEncodeWithSchemaKeys() throws {
        let json = String(decoding: try SessionManifest.encoder().encode(CameraTrackBuilder.tracks(facts())), as: UTF8.self)
        #expect(json.contains("\"role\" : \"camera_video\""))
        #expect(json.contains("\"first_pts_source\" : \"sample\""))
        #expect(json.contains("\"num\" : 24000"))
        #expect(json.contains("\"dialogue\" : false"))
        #expect(json.contains("\"constant_frame_rate\" : true"))
        #expect(json.contains("\"slots_repeated\" : 2"))
        #expect(json.contains("\"slots_skipped\" : 1"))
        #expect(json.contains("\"measured_pts_fps\" : 23.98"))
        #expect(json.contains("\"measured_arrival_fps\" : 23.976"))
    }
}

/// tracks[].first_pts_host_ns is the host time of the first frame IN camera.mov, for both tracks.
/// The movie-output path once used the frame that asked the output to start: the HEVC output then
/// took 1.85 s more to write its first frame, and session.json put camera.mov 1.85 s early.
@Suite struct FirstPtsSelectionTests {
    let device = DeviceInfo(name: "Cam Link 4K", uid: "camlink", negotiatedFormat: "3840x2160 420v 23.976")
    let audioDevice = DeviceInfo(name: "Cam Link 4K", uid: "camlink-audio")

    func facts() -> CameraTrackFacts {
        CameraTrackFacts(videoDevice: device, codec: .hevc, width: 3840, height: 2160, frameRate: .fps23_976)
    }

    func audio(firstPtsHostNs: UInt64?, firstCapture: UInt64?, frames: Int64) -> AudioTrackResult {
        AudioTrackResult(role: .mic, trackIndex: 1, firstPtsHostNs: firstPtsHostNs, firstCaptureHostNs: firstCapture,
                         frames: frames, sourceSampleRate: 48_000, channels: 2, sourceFormat: "2 ch 48 kHz Float32",
                         gapPaddedFrames: 0, overlapTrimmedFrames: 0, droppedBuffers: 0, failed: false)
    }

    @Test func bothTracksStartAtTheFirstFrameInTheFile() {
        // The camera ran from prepare on: 45 frames (1.9 s) came before the file's first frame.
        let preroll: UInt64 = 100_000_000_000
        let firstInFile: UInt64 = preroll + 1_876_842_321
        var video = CameraVideoResult(originNs: firstInFile, endSlot: 240, stats: CameraGridStats(framesWritten: 240))
        video.preStartFrames = 45
        var f = facts()
        // The audio buffer seen first was captured with the pre-roll; the aligner cut it to t0.
        f.apply(video: video, audio: audio(firstPtsHostNs: firstInFile, firstCapture: preroll, frames: 240 * 2002),
                audioDevice: audioDevice)
        let tracks = CameraTrackBuilder.tracks(f)
        #expect(tracks.map(\.firstPtsHostNs) == [firstInFile, firstInFile])
        #expect(!tracks.contains { $0.firstPtsHostNs == preroll })
        #expect(tracks[0].durationS == 240 * 1001.0 / 24000)
        #expect(tracks[1].durationS == 240 * 2002.0 / 48000)
    }

    @Test func aFileWithoutFramesHasNoFirstPts() {
        var f = facts()
        f.apply(video: CameraVideoResult(originNs: nil, endSlot: 0, stats: CameraGridStats()),
                audio: audio(firstPtsHostNs: nil, firstCapture: 5, frames: 0), audioDevice: audioDevice)
        let tracks = CameraTrackBuilder.tracks(f)
        #expect(tracks.map(\.role) == [.cameraVideo])
        #expect(tracks[0].firstPtsHostNs == nil && tracks[0].firstPtsSource == nil)
    }

    @Test func trackStopReportsTheGridAndTheMeasuredRates() {
        var video = CameraVideoResult(originNs: 7, endSlot: 100,
                                      stats: CameraGridStats(framesWritten: 96, slotsRepeated: 4, slotsSkipped: 2, lateFrames: 1))
        video.ptsFps = 23.98
        video.arrivalFps = 23.976_02
        video.correctionNs = 1_234_567
        video.preStartFrames = 20
        var f = facts()
        f.apply(video: video, audio: nil, audioDevice: nil)
        let track = CameraTrackBuilder.tracks(f)[0]
        let data = CameraTrackReport.trackStopData(track: track, video: video, audio: nil)
        #expect(data["slots_written"] == "100" && data["frames_written"] == "96")
        #expect(data["slots_repeated"] == "4" && data["slots_skipped"] == "2" && data["late_frames"] == "1")
        #expect(data["measured_pts_fps"] == "23.9800" && data["measured_arrival_fps"] == "23.9760")
        #expect(data["clock_correction_ms"] == "1.2" && data["frames_before_start"] == "20")
        #expect(data["dropped_frames"] == "5" && data["first_pts_host_ns"] == "7")
    }

    @Test func aRateMismatchOverTheLimitWarns() {
        var video = CameraVideoResult(originNs: 7, endSlot: 1000, stats: CameraGridStats(framesWritten: 1000))
        video.ptsFps = 23.98
        video.arrivalFps = 24000.0 / 1001
        video.rateMismatch = video.arrivalFps! / video.ptsFps! - 1
        let warning = CameraTrackReport.rateWarning(video)
        #expect(warning?["measured_pts_fps"] == "23.9800" && warning?["measured_arrival_fps"] == "23.9760")
        #expect(warning?["message"]?.contains("camera.mov follows the arrivals") == true)
        video.rateMismatch = 0.000_05
        #expect(CameraTrackReport.rateWarning(video) == nil)
        video.rateMismatch = nil
        #expect(CameraTrackReport.rateWarning(video) == nil)
    }
}

@Suite struct OutputSettingsTests {
    @Test func hevcHasBitrateRateOneSecondKeyframesAndBT709() throws {
        let s = CameraOutputSettings.video(codec: .hevc, width: 3840, height: 2160, frameRate: .fps23_976, bitrate: 60_000_000)
        #expect(s[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        #expect(s[AVVideoWidthKey] as? Int == 3840 && s[AVVideoHeightKey] as? Int == 2160)
        let props = try #require(s[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(props[AVVideoAverageBitRateKey] as? Int == 60_000_000)
        #expect(props[AVVideoMaxKeyFrameIntervalKey] as? Int == 24)
        #expect(abs((props[AVVideoExpectedSourceFrameRateKey] as? Double ?? 0) - 23.976) < 0.001)
        let color = try #require(s[AVVideoColorPropertiesKey] as? [String: String])
        #expect(color[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(color[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    @Test func proResTakesNoCompressionProperties() {
        let s = CameraOutputSettings.video(codec: .proRes422LT, width: 3840, height: 2160, frameRate: .fps23_976, bitrate: 60_000_000)
        #expect(s[AVVideoCodecKey] as? AVVideoCodecType == .proRes422LT)
        #expect(s[AVVideoCompressionPropertiesKey] == nil)
        #expect(CameraOutputSettings.codecType(.h264) == .h264)
    }

    @Test func audioIsInterleaved24BitPCMAt48k() throws {
        let s = CameraOutputSettings.audio(channels: 2)
        #expect(s[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM)
        #expect(s[AVSampleRateKey] as? Int == 48_000)
        #expect(s[AVNumberOfChannelsKey] as? Int == 2)
        #expect(s[AVLinearPCMBitDepthKey] as? Int == 24)
        #expect(s[AVLinearPCMIsFloatKey] as? Bool == false)
        #expect(s[AVLinearPCMIsNonInterleaved] as? Bool == false)
        let layout = try #require(s[AVChannelLayoutKey] as? Data)
        let tag = layout.withUnsafeBytes { $0.load(as: AudioChannelLayout.self).mChannelLayoutTag }
        #expect(tag == kAudioChannelLayoutTag_Stereo)
    }

    @Test func channelLayouts() {
        #expect(CameraOutputSettings.channelLayoutTag(channels: 1) == kAudioChannelLayoutTag_Mono)
        #expect(CameraOutputSettings.channelLayoutTag(channels: 2) == kAudioChannelLayoutTag_Stereo)
        #expect(CameraOutputSettings.channelLayoutTag(channels: 6) == kAudioChannelLayoutTag_DiscreteInOrder | 6)
        #expect(CameraOutputSettings.audio(channels: 0)[AVNumberOfChannelsKey] as? Int == 1)
    }

    @Test func codecFallsBackWhenTheEncoderIsMissing() {
        let hevcAndH264: Set<FourCharCode> = [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264]
        #expect(CameraOutputSettings.effectiveCodec(requested: .proRes422LT, availableEncoders: hevcAndH264) == .hevc)
        #expect(CameraOutputSettings.effectiveCodec(requested: .proRes422LT,
                                                    availableEncoders: hevcAndH264.union([kCMVideoCodecType_AppleProRes422LT])) == .proRes422LT)
        #expect(CameraOutputSettings.effectiveCodec(requested: .hevc, availableEncoders: [kCMVideoCodecType_H264]) == .h264)
        #expect(CameraOutputSettings.effectiveCodec(requested: .hevc, availableEncoders: []) == .hevc)
    }

    /// The recording output asks for 420v at the camera's own size: no width or height keys.
    @Test func recordingOutputKeepsTheFullSize() {
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let settings = CaptureGraph.recordingVideoSettings(availablePixelFormats: [kCVPixelFormatType_32BGRA, yuv])
        #expect(settings?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType == yuv)
        #expect(settings?[kCVPixelBufferWidthKey as String] == nil && settings?[kCVPixelBufferHeightKey as String] == nil)
        #expect(CaptureGraph.recordingVideoSettings(availablePixelFormats: [kCVPixelFormatType_32BGRA]) == nil)
    }
}

@Suite struct CameraMessagesTests {
    let camLinkToday = [
        VideoFormatCandidate(width: 1920, height: 1080, pixelFormat: "420v", frameRates: [FrameRateSpan(fps: 24000.0 / 1001)]),
        VideoFormatCandidate(width: 1920, height: 1080, pixelFormat: "yuvs", frameRates: [FrameRateSpan(fps: 24000.0 / 1001)]),
    ]

    @Test func camLinkMessageSaysWhatItGetsAndHowToFixIt() {
        let m = CameraMessages.formatUnavailable(cameraName: "Cam Link 4K", offered: camLinkToday,
                                                 width: 3840, height: 2160, frameRate: .fps23_976)
        #expect(m.hasPrefix("Cam Link 4K is getting 1920x1080 23.976 from the camera, not 3840x2160 23.976."))
        #expect(m.contains("a6600 HDMI output to 4K 24p"))
        #expect(m.contains("HDMI Only (24p)"))
    }

    @Test func noFormatsMeansNoSignal() {
        let m = CameraMessages.formatUnavailable(cameraName: "Cam Link 4K", offered: [], width: 3840, height: 2160, frameRate: .fps23_976)
        #expect(m.contains("reports no video formats"))
        #expect(CameraMessages.noSignal(cameraName: "Cam Link 4K").contains("reports no video formats"))
    }

    @Test func webcamMessageDoesNotTalkAboutTheA6600() {
        let m = CameraMessages.formatUnavailable(cameraName: "Logitech BRIO", offered: camLinkToday,
                                                 width: 3840, height: 2160, frameRate: .fps23_976)
        #expect(m.hasPrefix("Logitech BRIO offers 1920x1080 23.976"))
        #expect(!m.contains("a6600"))
        #expect(CameraMessages.isCaptureCard("Cam Link 4K"))
        #expect(!CameraMessages.isCaptureCard("MacBook Pro Camera"))
    }

    @Test func aCaptureCardShortOf4KIsNamedInTheWarning() {
        let signal = CameraSignal(width: 1920, height: 1080, frameRate: .fps23_976, pixelFormat: "420v")
        let m = CameraMessages.notFourK(cameraName: "Cam Link 4K", signal: signal)
        #expect(m.hasPrefix("Cam Link 4K is getting 1920x1080 23.976, not 4K"))
        #expect(m.contains("4K 24p"))
    }
}

/// A flag another task sets, for the bounded-wait test.
private final class AudioFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

@Suite struct CameraWriterControllerTests {
    @Test func earlyStopIsAProblem() {
        let p = CameraWriterController.problem(earlyStop: "Cam Link 4K was disconnected.", writing: false,
                                               lastFrameNs: nil, writingSinceNs: nil, nowNs: 10)
        #expect(p == "ended early: Cam Link 4K was disconnected.")
    }

    @Test func noFramesWhileWritingIsAProblem() {
        let s: UInt64 = 1_000_000_000
        func problem(last: UInt64?, now: UInt64, writing: Bool = true) -> String? {
            CameraWriterController.problem(earlyStop: nil, writing: writing, lastFrameNs: last, writingSinceNs: 10 * s, nowNs: now)
        }
        #expect(problem(last: 20 * s, now: 21 * s) == nil)
        #expect(problem(last: 20 * s, now: 22 * s + 1) == "no camera picture for over 2 s")
        // No frame since start counts from start; frames from before start do not count.
        #expect(problem(last: nil, now: 11 * s) == nil)
        #expect(problem(last: 5 * s, now: 13 * s) != nil)
        // Not writing (stopped by the user, or not started): no watchdog.
        #expect(problem(last: 20 * s, now: 60 * s, writing: false) == nil)
    }

    /// No camera frame ever comes: start gives up after its limit, and no camera.mov stays behind.
    /// No device is opened: the controller is fed nothing.
    @Test func startGivesUpWithoutFramesAndLeavesNoFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CameraStartTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let controller = CameraWriterController(frameRate: .fps23_976, audioChannels: 2)
        let url = dir.appendingPathComponent("camera.mov")
        let plan = CameraWriterController.FilePlan(codec: .hevc, width: 320, height: 180, frameRate: .fps23_976,
                                                   bitrate: 1_000_000, audioChannels: 2)
        let labels = CameraWriterController.TrackLabels(videoFormat: "320x180 420v 23.976", codec: "hevc",
                                                        videoDevice: "Test", audioDevice: "Test", syncClock: "host")
        let clock = ContinuousClock()
        let began = clock.now
        let outcome = await controller.start(url: url, events: events, plan: plan, labels: labels,
                                             startHostNs: HostClock.nowNs(), giveUpAfter: 0.2)
        #expect(outcome == .timedOut)
        #expect(clock.now - began < .seconds(2))
        // As CameraRecorder does after a time-out: the pending file ends.
        controller.finishEarly(reason: "test")
        let finish = await controller.stop(timeout: 5)
        #expect(!finish.playable)
        #expect(!controller.isActive)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Stop while the start still waits for its scheduled time: the start fails, no file stays.
    @Test func stopWhileWaitingForTheStartLeavesNoFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CameraStopEarly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let controller = CameraWriterController(frameRate: .fps23_976, audioChannels: nil)
        controller.configure(syncClock: nil)
        let url = dir.appendingPathComponent("camera.mov")
        let plan = CameraWriterController.FilePlan(codec: .hevc, width: 320, height: 180, frameRate: .fps23_976,
                                                   bitrate: 1_000_000, audioChannels: nil)
        let labels = CameraWriterController.TrackLabels(videoFormat: "320x180 420v 23.976", codec: "hevc",
                                                        videoDevice: "Test", syncClock: "host")
        let start = Task {
            await controller.start(url: url, events: events, plan: plan, labels: labels,
                                   startHostNs: HostClock.nowNs() + 2_000_000_000, giveUpAfter: 5)
        }
        #expect(await CameraRecorder.waitUntil({ controller.isActive }, atMost: .seconds(2)))
        let finish = await controller.stop(timeout: 5)
        guard case .failed = await start.value else {
            Issue.record("the start should fail")
            return
        }
        #expect(!finish.playable && !controller.isActive)
        #expect(!controller.video.isArmed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func stopBeforeStartSaysSo() async {
        let controller = CameraWriterController(frameRate: .fps23_976, audioChannels: nil)
        let finish = await controller.stop(timeout: 1)
        #expect(!finish.playable && finish.error == "camera.mov was never started.")
        #expect(controller.audio == nil)
    }

    /// prepare waits for the first camera audio buffer, but never longer than its limit.
    @Test func theWaitForCameraAudioIsBounded() async {
        let controller = CameraWriterController(frameRate: .fps23_976, audioChannels: 2)
        #expect(!controller.hasSeenAudio)
        let clock = ContinuousClock()
        let began = clock.now
        #expect(await CameraRecorder.waitUntil({ controller.hasSeenAudio }, atMost: .milliseconds(100)) == false)
        #expect(clock.now - began < .seconds(2))
        #expect(await CameraRecorder.waitUntil({ true }, atMost: .milliseconds(100)))
        let flag = AudioFlag()
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            flag.set()
        }
        #expect(await CameraRecorder.waitUntil({ flag.isSet }, atMost: .seconds(3)))
        #expect(CameraRecorder.firstAudioLimit <= .seconds(1))
    }

    /// events.jsonl says whether the small preview output stayed in the session while recording.
    @Test func videoTrackStartLogsThePreviewState() {
        var labels = CameraWriterController.TrackLabels(videoFormat: "3840x2160 420v 23.976", codec: "hevc",
                                                        videoDevice: "Cam Link 4K", audioDevice: "Cam Link 4K",
                                                        syncClock: "host", preview: "on")
        #expect(labels.videoTrackStartData["preview"] == "on")
        #expect(labels.videoTrackStartData["format"] == "3840x2160 420v 23.976")
        labels.preview = "off"
        #expect(labels.videoTrackStartData["preview"] == "off")
    }

    @Test func hostClockTimestampsPassThrough() {
        let pts = CMTime(value: 123_456_789, timescale: 1_000_000_000)
        #expect(CameraWriterController.hostNs(pts, clock: nil) == 123_456_789)
        #expect(CameraWriterController.hostNs(pts, clock: CMClockGetHostTimeClock()) == 123_456_789)
        #expect(CameraWriterController.hostNs(.invalid, clock: nil) == nil)
        #expect(CaptureGraph.clockLabel(CMClockGetHostTimeClock()) == "host")
    }

    @Test func aValueSetOnceWakesEveryWaiter() async {
        let shot = OneShot<Int>()
        async let a = shot.wait()
        async let b = shot.wait()
        try? await Task.sleep(for: .milliseconds(20))
        shot.fire(1)
        shot.fire(2)
        let (first, second) = await (a, b)
        #expect(first == 1 && second == 1)
        #expect(await shot.wait() == 1)
    }
}

/// AVAssetWriter raises an Objective-C exception for a bad settings dictionary. Building writer
/// inputs here proves the dictionaries are well-formed without opening any device.
@Suite struct SettingsAcceptedByWriterTests {
    func writer() throws -> AVAssetWriter {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-settings-\(UUID().uuidString).mov")
        return try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    @Test(arguments: [VideoCodec.hevc, .h264, .proRes422LT])
    func videoSettings(codec: VideoCodec) throws {
        let settings = CameraOutputSettings.video(codec: codec, width: 3840, height: 2160, frameRate: .fps23_976, bitrate: 60_000_000)
        let w = try writer()
        #expect(w.canApply(outputSettings: settings, forMediaType: .video))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        #expect(w.canAdd(input))
        #expect(CameraOutputSettings.writerAccepts(settings, mediaType: .video))
    }

    @Test(arguments: [1, 2, 6])
    func audioSettings(channels: Int) throws {
        let settings = CameraOutputSettings.audio(channels: channels)
        let w = try writer()
        #expect(w.canApply(outputSettings: settings, forMediaType: .audio))
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        #expect(w.canAdd(input))
        #expect(CameraOutputSettings.writerAccepts(settings, mediaType: .audio))
    }
}
