import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import CameraCapture
@testable import MediaWriter
import RecorderCore

/// Host time "now" for the stall timer, set by the test to the arrival of the last fed frame.
private final class FakeNow: Sendable {
    private let value = Mutex<UInt64>(0)
    var ns: UInt64 { value.withLock { $0 } }
    func set(_ ns: UInt64) { value.withLock { $0 = ns } }
}

private struct FramesBox: @unchecked Sendable { let frames: [CVPixelBuffer] }

/// 320x180 420v frames whose luma is `value` (chroma neutral).
private func frame(_ value: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    for (plane, fill) in [(0, value), (1, UInt8(128))] {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
        memset(base, Int32(fill), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// Luma of camera frame `n`: a different value for each of 8 frames in a row.
private func luma(_ n: Int64) -> UInt8 { UInt8((n % 8) * 30 + 20) }

/// `frames` samples of 2-channel Float32 at 48 kHz whose value tells their place: sample `a`
/// samples after the camera's base time is (a % 48000) / 48000.
private func countingAudio(firstIndex: Int64, frames: Int) -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    for c in 0..<2 {
        for i in 0..<frames { pcm.floatChannelData![c][i] = Float((firstIndex + Int64(i)) % 48_000) / 48_000 }
    }
    return PCMSampleBuffers.makeSampleBuffer(from: pcm, format: format.formatDescription, at: .zero)!
}

/// Feeds a simulated Cam Link take straight into the controller's pipelines (no capture device,
/// no permission) and reads camera.mov back.
private struct Take {
    let camera: SimulatedCamera
    let controller: CameraWriterController
    let now: FakeNow
    let box = FramesBox(frames: (0..<8).map { frame(luma(Int64($0))) })
    /// Next audio sample to feed, counted from the camera's base time.
    var audioIndex: Int64 = 0
    /// No audio buffer that ends after this is fed (the capture has not delivered it yet at Stop).
    var audioLimitNs = UInt64.max

    func hostNs(ofSample index: Int64) -> UInt64 { camera.baseNs + UInt64(index * 1_000_000_000 / 48_000) }

    /// Feeds frames `range`, and the camera audio up to the end of each frame, like the capture does.
    mutating func feed(_ range: Range<Int64>, pace: Bool) async throws {
        for n in range {
            let pts = camera.ptsNs(n), arrival = camera.arrivalNs(n)
            now.set(arrival)
            let video = controller.video, box = box
            await controller.videoQueue.run { video.receive(box.frames[Int(n % 8)], ptsNs: pts, arrivalNs: arrival) }
            let until = camera.realNs(n + 1)
            if let audio = controller.audio {
                var buffers: [(CMSampleBuffer, UInt64)] = []
                while hostNs(ofSample: audioIndex) < until, hostNs(ofSample: audioIndex + 480) <= audioLimitNs {
                    buffers.append((countingAudio(firstIndex: audioIndex, frames: 480), hostNs(ofSample: audioIndex)))
                    audioIndex += 480
                }
                let carried = AudioBuffersBox(buffers: buffers)
                await controller.audioQueue.run { for (b, t) in carried.buffers { audio.receive(b, ptsNs: t) } }
            }
            // Real time for the encoder, so the writer never falls behind the burst.
            if pace { try await Task.sleep(for: .milliseconds(3)) }
        }
    }

    /// Feeds the camera audio captured up to `untilNs`, like buffers the capture delivers late.
    mutating func feedAudio(untilNs: UInt64) async {
        guard let audio = controller.audio else { return }
        var buffers: [(CMSampleBuffer, UInt64)] = []
        while hostNs(ofSample: audioIndex + 480) <= untilNs {
            buffers.append((countingAudio(firstIndex: audioIndex, frames: 480), hostNs(ofSample: audioIndex)))
            audioIndex += 480
        }
        let carried = AudioBuffersBox(buffers: buffers)
        await controller.audioQueue.run { for (b, t) in carried.buffers { audio.receive(b, ptsNs: t) } }
    }
}

private struct AudioBuffersBox: @unchecked Sendable { let buffers: [(CMSampleBuffer, UInt64)] }

@Suite(.serialized) struct CameraWriterEndToEndTests {
    func plan(audioChannels: Int? = 2) -> CameraWriterController.FilePlan {
        CameraWriterController.FilePlan(codec: .hevc, width: 320, height: 180, frameRate: .fps23_976, bitrate: 2_000_000,
                                        audioChannels: audioChannels)
    }

    func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let labels = CameraWriterController.TrackLabels(videoFormat: "320x180 420v 23.976", codec: "hevc", videoDevice: "Cam Link 4K",
                                                    audioDevice: "Cam Link 4K", syncClock: "host", preview: "off")

    /// A Cam Link that stamps 41.700 ms frames, running for 2 s before the scheduled start (as it
    /// does from prepare on). camera.mov begins with the first frame at or after the start, on the
    /// exact 24000/1001 grid; its first_pts_host_ns is that frame's host time (never a pre-roll
    /// frame: the 1.85 s bug), and its audio starts at the same instant.
    @Test func aTakeBeginsAtTheFirstFrameAtOrAfterTheScheduledStart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("camera.mov")
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let rate = FrameRate.fps23_976

        var camera = SimulatedCamera()
        camera.baseNs = HostClock.nowNs() - 120_000_000_000
        camera.jitterNs = 2_000_000
        let now = FakeNow()
        let controller = CameraWriterController(frameRate: rate, audioChannels: 2, now: { now.ns })
        controller.configure(syncClock: nil)
        var take = Take(camera: camera, controller: controller, now: now)

        // The scheduled start falls between frames 48 and 49.
        let startNs = camera.realNs(48) + 10_000_000
        try await take.feed(0..<36, pace: false)
        let start = Task { await controller.start(url: url, events: events, plan: plan(), labels: labels,
                                                  startHostNs: startNs, giveUpAfter: 10) }
        #expect(await CameraRecorder.waitUntil({ controller.video.isArmed }, atMost: .seconds(5)))
        // Stop comes 5 ms before frame 289 is captured: frames 49...288 are the take.
        let stopNs = camera.realNs(289) - 5_000_000
        take.audioLimitNs = stopNs
        try await take.feed(36..<289, pace: true)
        #expect(await start.value == .started)

        let finish = await controller.stop(timeout: 15, stopNs: stopNs)
        #expect(finish.playable, "\(String(describing: finish.error))")
        events.close()

        let timing = controller.timing()
        let video = try #require(timing.video)
        let audio = try #require(timing.audio)
        let origin = try #require(video.originNs)
        #expect(origin >= startNs && origin - startNs < UInt64(oneFrameNs))
        #expect(GridMath.delta(origin, camera.realNs(49)).magnitude < 3_000_000)
        #expect(video.preStartFrames == 49)
        #expect(video.endSlot == 240)
        #expect(video.stats == CameraGridStats(framesWritten: 240), "\(video.stats)")
        #expect(video.writerBusyFrames == 0 && !video.failed)
        #expect(audio.firstPtsHostNs == origin)
        #expect(audio.frames == 240 * 2002)

        // session.json: both tracks begin at the frame that is in the file.
        var facts = CameraTrackFacts(videoDevice: DeviceInfo(name: "Cam Link 4K", uid: "camlink"), codec: .hevc,
                                     width: 320, height: 180, frameRate: rate)
        facts.apply(video: video, audio: audio, audioDevice: DeviceInfo(name: "Cam Link 4K", uid: "camlink-audio"))
        let tracks = CameraTrackBuilder.tracks(facts)
        #expect(tracks.map(\.firstPtsHostNs) == [origin, origin])
        #expect(tracks.allSatisfy { $0.firstPtsHostNs! > camera.realNs(48) })

        // The file: every frame on the exact grid, timescale 24000, 1001 ticks each.
        let asset = AVURLAsset(url: url)
        let fileTracks = try await asset.load(.tracks)
        #expect(fileTracks.map(\.mediaType) == [.video, .audio])
        let videoTrack = fileTracks[0]
        #expect(try await videoTrack.load(.naturalTimeScale) == 24000)
        #expect(try await videoTrack.load(.minFrameDuration) == CMTime(value: 1001, timescale: 24000))
        #expect(abs(try await videoTrack.load(.nominalFrameRate) - 23.976) < 0.01)

        var readers: [AVAssetReader] = []
        func output(_ track: AVAssetTrack, _ settings: [String: Any]?) throws -> AVAssetReaderTrackOutput {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(out)
            readers.append(reader)
            #expect(reader.startReading())
            return out
        }
        var times: [CMTime] = []
        let compressed = try output(videoTrack, nil)
        while let sb = compressed.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb)) }
        }
        times.sort { $0 < $1 }
        #expect(times == (0..<240).map { rate.time(ofFrame: Int64($0)) })

        // The first picture is frame 49, not a pre-roll frame.
        let decoded = try output(videoTrack, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let first = try #require(decoded.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
        CVPixelBufferLockBaseAddress(first, .readOnly)
        let y = CVPixelBufferGetBaseAddressOfPlane(first, 0)!.load(fromByteOffset: 90 * CVPixelBufferGetBytesPerRowOfPlane(first, 0) + 160,
                                                                     as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(first, .readOnly)
        #expect(abs(Int(y) - Int(luma(49))) <= 4, "first frame luma \(y), frame 49 is \(luma(49))")

        // The first audio sample is the one captured at t0.
        let pcm = try output(fileTracks[1], [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                             AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        let audioBuffer = try #require(pcm.copyNextSampleBuffer())
        let block = try #require(CMSampleBufferGetDataBuffer(audioBuffer))
        var sample: Float = 0
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &sample)
        let expected = Double(GridMath.audioFrames(elapsedNs: GridMath.delta(origin, camera.baseNs), sampleRate: 48_000) % 48_000)
        #expect(abs(Double(sample) * 48_000 - expected) <= 2, "first sample \(Double(sample) * 48_000), expected \(expected)")

        let logged = try EventLog.read(dir.appendingPathComponent("events.jsonl"))
        let videoStart = try #require(logged.first { $0.type == .trackStart && $0.data?["role"] == "camera_video" })
        #expect(videoStart.data?["first_pts_host_ns"] == String(origin))
        #expect(videoStart.data?["scheduled_start_host_ns"] == String(startNs))
        #expect(videoStart.data?["frames_before_start"] == "49")
        #expect(videoStart.data?["preview"] == "off" && videoStart.data?["first_pts_source"] == "sample")
        let audioStart = try #require(logged.first { $0.type == .trackStart && $0.data?["role"] == "mic" })
        #expect(audioStart.data?["first_pts_host_ns"] == String(origin) && audioStart.data?["file"] == "camera.mov")
    }

    /// The camera stops sending frames for a second mid-take: the stall timer repeats the last
    /// picture in real time, the file keeps its length, and a second take on the same recording
    /// graph works.
    @Test func aStallIsFilledAndASecondTakeWorks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-e2e2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = FrameRate.fps23_976
        var camera = SimulatedCamera()
        camera.baseNs = HostClock.nowNs() - 200_000_000_000
        camera.jitterNs = 1_000_000
        let now = FakeNow()
        let controller = CameraWriterController(frameRate: rate, audioChannels: nil, now: { now.ns })
        controller.configure(syncClock: nil)
        var take = Take(camera: camera, controller: controller, now: now)

        var fed: Int64 = 30
        for (index, first) in [Int64(48), 600].enumerated() {
            let url = dir.appendingPathComponent("camera-\(index).mov")
            let events = try EventLog(url: dir.appendingPathComponent("events-\(index).jsonl"))
            // The camera runs on between takes: the frames reach the clock recovery, not a file.
            try await take.feed(fed..<(first - 6), pace: false)
            let startNs = camera.realNs(first) - 10_000_000
            let start = Task { await controller.start(url: url, events: events, plan: plan(), labels: labels,
                                                      startHostNs: startNs, giveUpAfter: 10) }
            #expect(await CameraRecorder.waitUntil({ controller.video.isArmed }, atMost: .seconds(5)))
            try await take.feed((first - 6)..<(first + 48), pace: true)
            #expect(await start.value == .started)
            if index == 0 {
                // No frames for 24 frames (1 s). "Now" moves on: the timer repeats the last picture
                // up to the late margin behind it (slot 71), then frames come back at slot 72.
                now.set(camera.realNs(first + 72) - 10_000_000 + CameraVideoPipeline.lateMarginNs)
                try await Task.sleep(for: .milliseconds(400))
                try await take.feed((first + 72)..<(first + 119), pace: true)
            } else {
                try await take.feed((first + 48)..<(first + 119), pace: true)
            }
            fed = first + 119
            let finish = await controller.stop(timeout: 15, stopNs: camera.realNs(first + 119) - 2_000_000)
            #expect(finish.playable)
            events.close()
            let video = try #require(controller.timing().video)
            #expect(video.endSlot == 119)
            #expect(video.originNs.map { GridMath.delta($0, camera.realNs(first)).magnitude < 3_000_000 } == true)
            if index == 0 {
                // The 24 missing frames were repeats: filled by the timer or by the next frame.
                #expect(video.stats.slotsRepeated == 24 && video.stats.framesWritten == 95, "\(video.stats)")
            } else {
                #expect(video.stats == CameraGridStats(framesWritten: 119), "\(video.stats)")
            }
            let duration = try await AVURLAsset(url: url).load(.tracks)[0].load(.timeRange).duration
            #expect(duration == rate.time(ofFrame: 119))
        }
    }
}

extension CameraWriterEndToEndTests {
    /// The camera ran in the preview for ten minutes (the camera window on) before the take. The
    /// take's recording output joins with a new controller, but the stream clock has followed the
    /// stream since it opened: slot 0 is the first frame's real time, not 120 ms early (the drift
    /// of the Cam Link's stamps meanwhile), and the frames arrive their normal 30 ms after it.
    @Test func aWarmCameraCorrectsForTheDriftSinceItOpened() async throws {
        let dir = try tempDir("camera-warm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = FrameRate.fps23_976
        var camera = SimulatedCamera()
        camera.baseNs = HostClock.nowNs() - 1_000_000_000_000
        camera.jitterNs = 2_000_000
        // The preview output feeds the stream clock (PreviewFrameReceiver).
        let stream = StreamClock()
        let preview: Int64 = 24 * 600
        for n in Int64(0)..<preview { _ = stream.observe(ptsNs: camera.ptsNs(n), arrivalNs: camera.arrivalNs(n)) }

        let now = FakeNow()
        let controller = CameraWriterController(frameRate: rate, audioChannels: nil, streamClock: stream, now: { now.ns })
        controller.configure(syncClock: nil)
        var take = Take(camera: camera, controller: controller, now: now)
        let first = preview + 48
        try await take.feed(preview..<(first - 6), pace: false)
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let url = dir.appendingPathComponent("camera.mov")
        let startNs = camera.realNs(first) - 10_000_000
        let start = Task { await controller.start(url: url, events: events, plan: plan(audioChannels: nil), labels: labels,
                                                  startHostNs: startNs, giveUpAfter: 10) }
        #expect(await CameraRecorder.waitUntil({ controller.video.isArmed }, atMost: .seconds(5)))
        try await take.feed((first - 6)..<(first + 120), pace: true)
        #expect(await start.value == .started)
        let finish = await controller.stop(timeout: 15, stopNs: camera.realNs(first + 120) - 2_000_000)
        #expect(finish.playable)
        events.close()

        let video = try #require(controller.timing().video)
        let origin = try #require(video.originNs)
        #expect(GridMath.delta(origin, camera.realNs(first)).magnitude < 3_000_000,
                "origin off by \(GridMath.delta(origin, camera.realNs(first))) ns")
        #expect(video.stats == CameraGridStats(framesWritten: 120), "\(video.stats)")
        // clock_correction_ms covers the whole stream: 10 min 7 s at 0.02%.
        #expect(abs(video.correctionNs - 122_000_000) < 6_000_000, "correction \(video.correctionNs)")
        let logged = try EventLog.read(dir.appendingPathComponent("events.jsonl"))
        let videoStart = try #require(logged.first { $0.type == .trackStart && $0.data?["role"] == "camera_video" })
        let lag = try #require(videoStart.data?["corrected_arrival_lag_ms"].flatMap(Double.init))
        #expect(lag > 25 && lag < 40, "corrected arrival lag \(lag) ms")
        #expect(!logged.contains { $0.type == .warning && $0.data?["message"]?.contains("after their corrected time") == true })
    }

    /// Frames keep arriving, but too late for their slots (the stall timer repeated them): the
    /// file shows a frozen picture. The stall rule counts only frames that went into the file.
    @Test func lateFramesDoNotHideAStall() async throws {
        let dir = try tempDir("camera-late")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = FrameRate.fps23_976
        var camera = SimulatedCamera()
        camera.baseNs = HostClock.nowNs() - 200_000_000_000
        camera.jitterNs = 1_000_000
        let now = FakeNow()
        let controller = CameraWriterController(frameRate: rate, audioChannels: nil, now: { now.ns })
        controller.configure(syncClock: nil)
        var take = Take(camera: camera, controller: controller, now: now)
        let first: Int64 = 240
        try await take.feed(0..<(first - 6), pace: false)
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let url = dir.appendingPathComponent("camera.mov")
        let startNs = camera.realNs(first) - 10_000_000
        let start = Task { await controller.start(url: url, events: events, plan: plan(audioChannels: nil), labels: labels,
                                                  startHostNs: startNs, giveUpAfter: 10) }
        #expect(await CameraRecorder.waitUntil({ controller.video.isArmed }, atMost: .seconds(5)))
        try await take.feed((first - 6)..<(first + 48), pace: true)
        #expect(await start.value == .started)
        #expect(controller.video.lastWrittenArrivalNs == camera.arrivalNs(first + 47))

        // The timer repeats slots 48-71; their frames then arrive, one second late.
        now.set(camera.realNs(first + 72) - 10_000_000 + CameraVideoPipeline.lateMarginNs)
        try await Task.sleep(for: .milliseconds(400))
        try await take.feed((first + 48)..<(first + 72), pace: false)
        #expect(controller.video.lastArrivalNs == camera.arrivalNs(first + 71))
        #expect(controller.video.lastWrittenArrivalNs == camera.arrivalNs(first + 47))
        let checkNs = camera.arrivalNs(first + 47) + 2_100_000_000
        #expect(CameraWriterController.problem(earlyStop: nil, writing: true, lastFrameNs: controller.video.lastWrittenArrivalNs,
                                               writingSinceNs: camera.arrivalNs(first), nowNs: checkNs) != nil)
        // What the rule saw before: the late frames looked like a live camera.
        #expect(CameraWriterController.problem(earlyStop: nil, writing: true, lastFrameNs: controller.video.lastArrivalNs,
                                               writingSinceNs: camera.arrivalNs(first), nowNs: checkNs) == nil)

        try await take.feed((first + 72)..<(first + 96), pace: true)
        #expect(controller.video.lastWrittenArrivalNs == camera.arrivalNs(first + 95))
        let finish = await controller.stop(timeout: 15, stopNs: camera.realNs(first + 96) - 2_000_000)
        #expect(finish.playable)
        events.close()
        let video = try #require(controller.timing().video)
        #expect(video.stats == CameraGridStats(framesWritten: 72, slotsRepeated: 24, lateFrames: 24), "\(video.stats)")
    }

    /// Stop comes 30 ms before a slot boundary, so the video ends 30 ms after Stop. The camera
    /// audio for those 30 ms arrives after Stop; the file waits for it, so the dialogue track ends
    /// with real sound, not silence.
    @Test func theCameraMicReachesTheVideoEnd() async throws {
        let dir = try tempDir("camera-tail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = FrameRate.fps23_976
        var camera = SimulatedCamera()
        camera.baseNs = HostClock.nowNs() - 120_000_000_000
        camera.jitterNs = 2_000_000
        let now = FakeNow()
        let controller = CameraWriterController(frameRate: rate, audioChannels: 2, now: { now.ns })
        controller.configure(syncClock: nil)
        var take = Take(camera: camera, controller: controller, now: now)
        let url = dir.appendingPathComponent("camera.mov")
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        try await take.feed(0..<36, pace: false)
        let startNs = camera.realNs(48) + 10_000_000
        let start = Task { await controller.start(url: url, events: events, plan: plan(), labels: labels,
                                                  startHostNs: startNs, giveUpAfter: 10) }
        #expect(await CameraRecorder.waitUntil({ controller.video.isArmed }, atMost: .seconds(5)))
        let stopNs = camera.realNs(289) - 30_000_000
        // At Stop the capture has delivered the audio up to just after it.
        take.audioLimitNs = stopNs + 10_000_000
        try await take.feed(36..<289, pace: true)
        #expect(await start.value == .started)

        let stopping = Task { await controller.stop(timeout: 15, stopNs: stopNs) }
        try await Task.sleep(for: .milliseconds(80))
        await take.feedAudio(untilNs: camera.realNs(289) + 20_000_000)
        let finish = await stopping.value
        #expect(finish.playable)
        events.close()

        let timing = controller.timing()
        let video = try #require(timing.video)
        let audio = try #require(timing.audio)
        let origin = try #require(video.originNs)
        #expect(video.endSlot == 240)
        #expect(audio.frames == 240 * 2002)
        #expect(CameraWriterController.audioTailTargetNs(originNs: origin, endSlot: 240, frameRate: rate, stopNs: stopNs)
                    == origin + UInt64(GridMath.offsetNs(ofSlot: 240, frameRate: rate)) - 100_000)

        // The last 1,500 samples are the captured sound (no run of silence at the end).
        let asset = AVURLAsset(url: url)
        let track = try await asset.load(.tracks)[1]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        #expect(reader.startReading())
        var tail: [Float] = []
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &values)
            // Interleaved stereo: keep channel 0.
            tail += stride(from: 0, to: values.count, by: 2).map { values[$0] }
            if tail.count > 4000 { tail.removeFirst(tail.count - 4000) }
        }
        let last = tail.suffix(1500)
        #expect(last.count == 1500)
        #expect(last.filter { $0 == 0 }.count <= 1, "\(last.filter { $0 == 0 }.count) silent samples at the end")
        let originIndex = GridMath.audioFrames(elapsedNs: GridMath.delta(origin, camera.baseNs), sampleRate: 48_000)
        let expected = Double((originIndex + Int64(audio.frames) - 1) % 48_000)
        #expect(abs(Double(tail.last ?? 0) * 48_000 - expected) <= 2, "last sample \(Double(tail.last ?? 0) * 48_000), expected \(expected)")
    }
}

/// The start both files share: each begins at its first frame at or after it.
@Suite struct ScheduledStartTests {
    @Test func theAppSchedulesHalfASecondAhead() {
        #expect(StartSchedule.marginNs == 500_000_000)
        #expect(StartSchedule.startHostNs(nowNs: 1_000) == 500_001_000)
        #expect(ScheduledStart.startNs(scheduledNs: nil, nowNs: 7) == 7)
        #expect(ScheduledStart.startNs(scheduledNs: 9, nowNs: 7) == 9)
        // A time that already passed stays: the recorder begins at its next frame.
        #expect(ScheduledStart.startNs(scheduledNs: 5, nowNs: 7) == 5)
        #expect(ScheduledStart.lateNs(scheduledNs: 10, readyNs: 7) == 0)
        #expect(ScheduledStart.lateNs(scheduledNs: 10, readyNs: 25) == 15)
        #expect(ScheduledStart.lateNs(scheduledNs: nil, readyNs: 25) == 0)
    }

    /// For any phase of the camera frames (23.976) and the display refreshes (120 Hz under a
    /// 47.952 grid), camera.mov and screen.mov begin within one camera frame of each other.
    @Test func bothFilesBeginWithinOneCameraFrame() {
        let start: UInt64 = 10_000_000_000
        let camera = FrameRate.fps23_976, screen = FrameRate.fps47_952
        let cameraFrame = GridMath.offsetNs(ofSlot: 1, frameRate: camera)
        let screenFrame = GridMath.offsetNs(ofSlot: 1, frameRate: screen)
        let refresh: Int64 = 8_333_333
        var worst: Int64 = 0
        for cameraPhase in stride(from: Int64(0), to: cameraFrame, by: 1_300_000) {
            for refreshPhase in stride(from: Int64(0), to: refresh, by: 700_000) {
                // The camera: its first frame at or after the start.
                let k = GridMath.slotAtOrAfter(elapsedNs: Int64(start) - 5_000_000_000 - cameraPhase, frameRate: camera)
                let cameraOrigin = UInt64(5_000_000_000 + cameraPhase + GridMath.offsetNs(ofSlot: k, frameRate: camera))
                // The screen: the newest refresh at or before the start, moved along its lattice to
                // the first point at or after the start.
                let lastRefresh = UInt64(refreshPhase + (Int64(start) - refreshPhase) / refresh * refresh)
                let screenOrigin = GridMath.origin(startNs: start, framePtsNs: lastRefresh, frameRate: screen)
                #expect(cameraOrigin >= start && Int64(cameraOrigin - start) < cameraFrame)
                #expect(screenOrigin >= start && Int64(screenOrigin - start) <= screenFrame)
                worst = max(worst, abs(GridMath.delta(cameraOrigin, screenOrigin)))
            }
        }
        #expect(worst < cameraFrame, "worst \(worst) ns")
    }
}

extension CameraWriterEndToEndTests {
    /// Feeds a 320x180 take of `frames` frames (from camera frame 48 on) straight into the
    /// pipeline: `picture(k, previous)` gives frame k of the file (k < 0 before it), and `after(k, frame)`
    /// runs on the video queue right after frame k went in. Returns the video result and events.jsonl.
    private func repeatTake(_ name: String, frames: Int64 = 280, picture: (Int64, CVPixelBuffer?) -> CVPixelBuffer,
                            after: @escaping @Sendable (Int64, CVPixelBuffer) -> Void = { _, _ in })
        async throws -> (CameraVideoResult, [SessionEvent]) {
        let dir = try tempDir(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        var camera = SimulatedCamera()
        camera.baseNs = HostClock.nowNs() - 200_000_000_000
        camera.jitterNs = 1_000_000
        let now = FakeNow()
        let controller = CameraWriterController(frameRate: .fps23_976, audioChannels: nil, now: { now.ns })
        controller.configure(syncClock: nil)
        let first: Int64 = 48
        var previous: CVPixelBuffer?
        func feed(_ range: Range<Int64>) async throws {
            for n in range {
                let k = n - first
                let frame = picture(k, previous)
                previous = frame
                let pts = camera.ptsNs(n), arrival = camera.arrivalNs(n)
                now.set(arrival)
                let video = controller.video, box = FramesBox(frames: [frame])
                await controller.videoQueue.run {
                    video.receive(box.frames[0], ptsNs: pts, arrivalNs: arrival)
                    if k >= 0 { after(k, box.frames[0]) }
                }
                try await Task.sleep(for: .milliseconds(3))
            }
        }
        try await feed(0..<(first - 6))
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let url = dir.appendingPathComponent("camera.mov"), startNs = camera.realNs(first) - 10_000_000
        let start = Task { await controller.start(url: url, events: events, plan: plan(audioChannels: nil), labels: labels,
                                                  startHostNs: startNs, giveUpAfter: 10) }
        #expect(await CameraRecorder.waitUntil({ controller.video.isArmed }, atMost: .seconds(5)))
        try await feed((first - 6)..<(first + frames))
        #expect(await start.value == .started)
        let finish = await controller.stop(timeout: 15, stopNs: camera.realNs(first + frames) - 2_000_000)
        #expect(finish.playable)
        events.close()
        let video = try #require(controller.timing().video)
        #expect(video.stats == CameraGridStats(framesWritten: frames), "\(video.stats)")
        return (video, try EventLog.read(dir.appendingPathComponent("events.jsonl")))
    }

    /// Frame k of the pattern seen in camera.mov: 4 new pictures, then the last one 3 more times.
    private func isRepeat(_ k: Int64) -> Bool { k >= 0 && k % 7 >= 4 }
    private func newPicture(_ k: Int64) -> CVPixelBuffer {
        let index = k >= 0 ? 4 * (k / 7) + k % 7 : 1000 + k
        return noisyFrame(width: 320, height: 180, seed: UInt64(index % 16 + 1))
    }

    /// The camera sends the pattern, each repeat in a new buffer. The check counts the repeats on
    /// arrival as the camera's (short runs, new buffers), finds no frame that changed after it
    /// arrived, logs no repeat warning during the take, and the file gets every frame in its own
    /// slot as before. The warning at Stop has the totals.
    @Test func repeatedPicturesAreCountedOnArrival() async throws {
        let (video, events) = try await repeatTake("camera-repeats") { k, previous in
            if isRepeat(k), let previous { copyFrame(previous) } else { newPicture(k) }
        }
        let check = video.frameCheck
        #expect(check.checked == 280 && check.repeatedOnArrival == 120 && check.longestRepeatRun == 3, "\(check)")
        #expect(check.shortRunRepeats == 120 && check.sameBufferRepeats == 0 && check.heldBufferArrivals == 0)
        #expect(check.changedBeforeWrite == 0 && check.changedWhileHeld == 0)
        #expect(check.nearRepeatOnArrival == 0 && check.differenceBuckets == [0, 0, 0, 159])
        #expect(check.uniqueFrameRatio == 160.0 / 280)
        let checkKeys = ["repeated_on_arrival", "changed_before_write", "changed_while_held"]
        #expect(!events.contains { e in e.type == .warning && checkKeys.contains { e.data?[$0] != nil } })

        let warning = try #require(CameraTrackReport.repeatWarning(video, frameRate: .fps23_976))
        #expect(warning["frames_checked"] == "280" && warning["repeated_percent"] == "43")
        #expect(warning["choppy"] == "true" && warning["cause"] == "camera")
        #expect(warning["message"]?.hasPrefix("The camera sends the same picture again in 43% of frames") == true)
    }

    /// The capture stack hands over the same buffer again (the pattern, but each repeat is the
    /// buffer before it): counted as the stack's, and as arrivals in a buffer TwinTake still held.
    @Test func aBufferDeliveredAgainIsTheCaptureStacks() async throws {
        let (video, _) = try await repeatTake("camera-same-buffer") { k, previous in
            if isRepeat(k), let previous { previous } else { newPicture(k) }
        }
        let check = video.frameCheck
        #expect(check.repeatedOnArrival == 120 && check.sameBufferRepeats == 120 && check.heldBufferArrivals == 120, "\(check)")
        #expect(check.changedBeforeWrite == 0 && check.changedWhileHeld == 0)
        let warning = try #require(CameraTrackReport.repeatWarning(video, frameRate: .fps23_976))
        #expect(warning["cause"] == "capture_stack" && warning["choppy"] == "true")
        #expect(warning["message"]?.hasPrefix("macOS delivers the same camera buffer again in 43% of frames") == true)
    }

    /// Something overwrites a frame's buffer after the writer took it, while TwinTake still holds
    /// it (the encoder reads it later): found when the next frame arrives, and at the end.
    @Test func aFrameThatChangesWhileHeldIsCounted() async throws {
        let changed: Set<Int64> = [20, 90, 150, 279]
        let (video, events) = try await repeatTake("camera-held-change", picture: { k, _ in newPicture(k) }) { k, frame in
            guard changed.contains(k) else { return }
            CVPixelBufferLockBaseAddress(frame, [])
            let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!
            memset(luma, 99, CVPixelBufferGetBytesPerRowOfPlane(frame, 0) * CVPixelBufferGetHeightOfPlane(frame, 0) / 2)
            CVPixelBufferUnlockBaseAddress(frame, [])
        }
        let check = video.frameCheck
        // Written right away (the encoder keeps up), so the change comes after the write.
        #expect(video.writerBusyFrames == 0)
        #expect(check.changedWhileHeld + check.changedBeforeWrite == 4, "\(check)")
        #expect(check.changedWhileHeld >= 1)
        #expect(check.repeatedOnArrival == 0 && check.heldBufferArrivals == 0)
        let held = events.filter { $0.type == .warning && $0.data?["changed_while_held"] != nil }
        #expect(held.count == 1)
        #expect(held.first?.data?["message"] == RepeatedFrameRule.changedWhileHeldWarning)
        #expect(held.first?.data?["changed_while_held"] == "1")
    }
}
