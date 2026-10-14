import AVFoundation
import CoreMedia
import CoreVideo
import Testing
@testable import RecorderCore
@testable import MediaWriter
@testable import ScreenCapture

/// Drives the real pipelines and AVAssetWriter with synthetic frames and audio (no capture
/// device, no permission), then reads screen.mov back.
@Suite struct ScreenWriterEndToEndTests {
    private func frame(_ value: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func writesConstantFrameRateVideoAndAlignedAudio() async throws {
        let rate = FrameRate.fps47_952
        var config = laptopConfig(rate: rate)
        config.outputPx = PixelSize(width: 320, height: 180)
        config.bitrate = 2_000_000

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("screen.mov")
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))

        let handles = try ScreenWriterHandles.make(url: url, config: config, micChannels: 1, systemAudioChannels: 2)
        #expect(handles.writer.startWriting())
        handles.writer.startSession(atSourceTime: .zero)

        // A recording that happened over the last few seconds, fed in one go.
        let startNs = HostClock.nowNs() - 4_000_000_000
        let timing = SessionTiming(frameRate: rate, startNs: startNs)
        let videoQueue = DispatchQueue(label: "test.video")
        let micQueue = DispatchQueue(label: "test.mic")
        let audioQueue = DispatchQueue(label: "test.audio")
        let video = VideoPipeline(queue: videoQueue, frameRate: rate, outputSize: config.outputPx)
        let mic = AudioPipeline(queue: micQueue, role: .mic, fileName: SessionFolder.screenFileName)
        let system = AudioPipeline(queue: audioQueue, role: .systemAudio, fileName: SessionFolder.screenFileName)
        await mic.attach(writer: handles.writer, input: handles.mic!, trackIndex: 1, channels: 1, timing: timing, events: events)
        await system.attach(writer: handles.writer, input: handles.systemAudio!, trackIndex: 2, channels: 2,
                            timing: timing, events: events)
        await video.attach(handles, timing: timing, events: events)

        let t0 = startNs + 20_000_000
        let slots = 96
        let frames = (0..<8).map { frame(UInt8($0 * 30)) }
        let box = FramesBox(frames: frames)
        await videoQueue.run {
            // New frames for slots 0-9 and 30-47; the screen is static in between and after.
            for k in Array(0..<10) + Array(30..<48) {
                let jitter = k == 0 ? 0 : Double((k * 7) % 5 - 2) * 0.05
                video.receive(box.frames[k % 8], ptsNs: hostNs(t0, Double(k) + jitter, rate))
            }
            video.applyStop(stopNs: hostNs(t0, Double(slots), rate))
        }
        #expect(timing.originNs == t0)
        #expect(timing.endSlot == Int64(slots))

        // Mic: starts 30 ms late, runs past the end. System audio: starts 15 ms early, has a
        // 100 ms dropout.
        await micQueue.run {
            var pts = t0 + 30_000_000
            while pts < hostNs(t0, Double(slots) + 5, rate) {
                mic.receive(rampBuffer(frames: 480, channels: 1), ptsNs: pts)
                pts += 10_000_000
            }
        }
        await audioQueue.run {
            var pts = t0 - 15_000_000
            var i = 0
            while pts < hostNs(t0, Double(slots), rate) {
                if !(40...49).contains(i) { system.receive(rampBuffer(frames: 1024, channels: 2), ptsNs: pts) }
                pts += 21_333_333
                i += 1
            }
        }

        async let videoResult = video.finish()
        async let micResult = mic.finish()
        async let systemResult = system.finish()
        let (v, m, s) = await (videoResult, micResult, systemResult)
        handles.writer.endSession(atSourceTime: rate.time(ofFrame: v.endSlot))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            handles.writer.finishWriting { c.resume() }
        }
        #expect(handles.writer.status == .completed, "\(String(describing: handles.writer.error))")
        events.close()
        // Finishing rewrites the fragmented file as an ordinary movie: one moov, no fragments.
        let boxes = topLevelBoxes(url)
        #expect(boxes.contains("moov") && !boxes.contains("moof"), "\(boxes)")

        #expect(v.endSlot == Int64(slots) && !v.failed)
        #expect(v.stats.written == Int64(slots))
        #expect(v.stats.repeated == Int64(slots - 28))
        #expect(v.stats.late == 0)
        let audioFrames = Int64(slots) * 1001
        #expect(m.frames == audioFrames && s.frames == audioFrames)
        #expect(m.firstPtsHostNs == t0 && s.firstPtsHostNs == t0)
        #expect(s.gapPaddedFrames > 0)

        // Read the file back.
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.map(\.mediaType) == [.video, .audio, .audio])
        let videoTrack = tracks[0]
        #expect(try await videoTrack.load(.naturalTimeScale) == 48000)
        #expect(abs(try await videoTrack.load(.nominalFrameRate) - 47.952) < 0.01)
        #expect(try await videoTrack.load(.minFrameDuration) == CMTime(value: 1001, timescale: 48000))

        // FCP-facing tags: HEVC, BT.709 color, 48 kHz 24-bit integer PCM with the source channels.
        let videoFormat = try #require(try await videoTrack.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_HEVC)
        let ext = CMFormatDescriptionGetExtensions(videoFormat) as? [String: Any] ?? [:]
        #expect(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
            == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        for (track, channels) in [(tracks[1], UInt32(1)), (tracks[2], UInt32(2))] {
            let format = try #require(try await track.load(.formatDescriptions).first)
            let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            #expect(asbd.mFormatID == kAudioFormatLinearPCM && asbd.mSampleRate == 48000)
            #expect(asbd.mBitsPerChannel == 24 && asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0)
            #expect(asbd.mChannelsPerFrame == channels)
        }

        // One reader per track: a single reader drained one output at a time stalls on interleaving.
        func output(_ track: AVAssetTrack, _ settings: [String: Any]?) throws -> AVAssetReaderTrackOutput {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(out)
            readers.append(reader)
            #expect(reader.startReading())
            return out
        }
        var readers: [AVAssetReader] = []
        // Passthrough: the stored 24-bit PCM, no decoding.
        let videoOut = try output(videoTrack, nil)
        let micOut = try output(tracks[1], nil)
        let systemOut = try output(tracks[2], nil)

        var videoTimes: [CMTime] = []
        while let sb = videoOut.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { videoTimes.append(CMSampleBufferGetPresentationTimeStamp(sb)) }
        }
        videoTimes.sort { $0 < $1 }
        #expect(videoTimes == (0..<slots).map { rate.time(ofFrame: Int64($0)) })

        /// Frame count, channel count and index of the first frame with a non-zero sample.
        func readAudio(_ out: AVAssetReaderTrackOutput) -> (frames: Int, channels: Int, firstNonZero: Int?) {
            var frames = 0, channels = 0
            var firstNonZero: Int?
            while let sb = out.copyNextSampleBuffer() {
                guard let format = CMSampleBufferGetFormatDescription(sb),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                channels = Int(asbd.mChannelsPerFrame)
                let count = CMSampleBufferGetNumSamples(sb)
                if firstNonZero == nil {
                    var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
                    let stride = Int(asbd.mBytesPerFrame)
                    if let i = (0..<count).first(where: { f in bytes[f * stride..<(f + 1) * stride].contains { $0 != 0 } }) {
                        firstNonZero = frames + i
                    }
                }
                frames += count
            }
            return (frames, channels, firstNonZero)
        }
        let micRead = readAudio(micOut)
        let systemRead = readAudio(systemOut)
        #expect(micRead.frames == Int(audioFrames) && micRead.channels == 1)
        #expect(systemRead.frames == Int(audioFrames) && systemRead.channels == 2)
        // The ramp's sample 0 is 0, so the first non-zero mic sample is 1 after the 30 ms pad.
        #expect(micRead.firstNonZero == 1440 + 1)
        // System audio started 15 ms early: its first 720 samples were cut, so it starts mid-ramp.
        #expect(systemRead.firstNonZero == 0)

        let logged = try EventLog.read(dir.appendingPathComponent("events.jsonl"))
        let starts = logged.filter { $0.type == .trackStart }
        #expect(Set(starts.compactMap { $0.data?["role"] }) == ["screen_video", "mic", "system_audio"])
        #expect(starts.allSatisfy { $0.data?["first_pts_host_ns"] == String(t0) })
        #expect(logged.contains { $0.type == .warning && $0.data?["track"] == "system_audio" })
    }
}

private struct FramesBox: @unchecked Sendable { let frames: [CVPixelBuffer] }

/// Top-level QuickTime box types, in file order.
func topLevelBoxes(_ url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    var types: [String] = []
    var offset = 0
    while offset + 8 <= data.count {
        var size = Int(data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) })
        let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
        if size == 1, offset + 16 <= data.count {
            size = Int(data[offset + 8..<offset + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        types.append(type)
        guard size >= 8 else { break }
        offset += size
    }
    return types
}

extension ScreenWriterEndToEndTests {
    /// A copy of screen.mov taken mid-recording stands in for the file a crash leaves behind:
    /// movie fragments must make it playable up to the last fragment.
    @Test func fileIsPlayableBeforeFinishWriting() async throws {
        let rate = FrameRate.fps47_952
        var config = laptopConfig(mic: nil, systemAudio: false, rate: rate)
        config.outputPx = PixelSize(width: 320, height: 180)
        config.bitrate = 2_000_000
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("screen.mov")
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))

        let handles = try ScreenWriterHandles.make(url: url, config: config, micChannels: nil, systemAudioChannels: nil)
        #expect(handles.writer.startWriting())
        handles.writer.startSession(atSourceTime: .zero)
        let startNs = HostClock.nowNs() - 10_000_000_000
        let timing = SessionTiming(frameRate: rate, startNs: startNs)
        let queue = DispatchQueue(label: "test.crash.video")
        let video = VideoPipeline(queue: queue, frameRate: rate, outputSize: config.outputPx)
        await video.attach(handles, timing: timing, events: events)
        let box = FramesBox(frames: (0..<4).map { frame(UInt8($0 * 60)) })
        await queue.run {
            // 6 s of new frames.
            for k in 0..<288 { video.receive(box.frames[k % 4], ptsNs: hostNs(startNs, Double(k), rate)) }
        }
        try await Task.sleep(for: .milliseconds(1500))

        let crashed = dir.appendingPathComponent("crashed.mov")
        try FileManager.default.copyItem(at: url, to: crashed)
        // Mid-recording the file is a moov header followed by movie fragments.
        #expect(topLevelBoxes(crashed).first(where: { $0 == "moov" || $0 == "moof" }) == "moov")
        let asset = AVURLAsset(url: crashed)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.map(\.mediaType) == [.video])
        let duration = try await asset.load(.duration)
        #expect(duration.seconds >= 1, "playable duration \(duration.seconds) s")
        if let track = tracks.first {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out)
            #expect(reader.startReading())
            var count = 0
            while let sb = out.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sb) }
            #expect(count >= 48)
        }

        await queue.run { video.applyStop(stopNs: hostNs(startNs, 288, rate)) }
        _ = await video.finish()
        handles.writer.endSession(atSourceTime: rate.time(ofFrame: 288))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            handles.writer.finishWriting { c.resume() }
        }
        #expect(handles.writer.status == .completed)
        events.close()
    }
}

extension ScreenWriterEndToEndTests {
    /// No screen frame ever arrives: the file still gets black video of the full length, and the
    /// mic is aligned to the Start time.
    @Test func noScreenFramesGivesBlackVideoAndAlignedAudio() async throws {
        let rate = FrameRate.fps47_952
        var config = laptopConfig(systemAudio: false, rate: rate)
        config.outputPx = PixelSize(width: 320, height: 180)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-black-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("screen.mov")
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let handles = try ScreenWriterHandles.make(url: url, config: config, micChannels: 1, systemAudioChannels: nil)
        #expect(handles.writer.startWriting())
        handles.writer.startSession(atSourceTime: .zero)

        let startNs = HostClock.nowNs() - 3_000_000_000
        let timing = SessionTiming(frameRate: rate, startNs: startNs)
        let videoQueue = DispatchQueue(label: "test.black.video")
        let micQueue = DispatchQueue(label: "test.black.mic")
        let video = VideoPipeline(queue: videoQueue, frameRate: rate, outputSize: config.outputPx)
        let mic = AudioPipeline(queue: micQueue, role: .mic, fileName: SessionFolder.screenFileName)
        await mic.attach(writer: handles.writer, input: handles.mic!, trackIndex: 1, channels: 1, timing: timing, events: events)
        await video.attach(handles, timing: timing, events: events)
        await micQueue.run {
            var pts = startNs + 5_000_000
            while pts < startNs + 1_000_000_000 {
                mic.receive(rampBuffer(frames: 480, channels: 1), ptsNs: pts)
                pts += 10_000_000
            }
        }
        await video.requestStop(stopNs: startNs + 1_000_000_000)
        #expect(timing.originNs == startNs)

        async let videoResult = video.finish()
        async let micResult = mic.finish()
        let (v, m) = await (videoResult, micResult)
        handles.writer.endSession(atSourceTime: rate.time(ofFrame: v.endSlot))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in handles.writer.finishWriting { c.resume() } }
        #expect(handles.writer.status == .completed)
        events.close()

        let slots = GridMath.nearestSlot(elapsedNs: 1_000_000_000, frameRate: rate)
        #expect(v.startedBlack && v.endSlot == slots && v.stats.written == slots)
        #expect(m.frames == slots * 1001 && m.firstPtsHostNs == startNs)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.map(\.mediaType) == [.video, .audio])
        let duration = try await tracks[0].load(.timeRange).duration
        #expect(duration == rate.time(ofFrame: slots))
        let logged = try EventLog.read(dir.appendingPathComponent("events.jsonl"))
        #expect(logged.contains { $0.type == .trackStart && $0.data?["first_frame"] == "black" })
    }
}
