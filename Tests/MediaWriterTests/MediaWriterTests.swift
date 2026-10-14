import AVFoundation
import Testing
@testable import MediaWriter
import RecorderCore

/// What camera.mov and screen.mov share: the container, the encoder tags and the grid math.
@Suite struct WriterSettingsTests {
    @Test func bothFilesGetFragmentsAndAnExactTimescale() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID().uuidString).mov")
        let writer = try WriterSettings.makeWriter(url: url, frameRate: .fps23_976)
        #expect(writer.movieTimeScale == 24000)
        #expect(writer.movieFragmentInterval == CMTime(value: 2, timescale: 1))
        #expect(writer.initialMovieFragmentInterval == CMTime(value: 1, timescale: 1))
        let input = WriterSettings.makeVideoInput(
            settings: WriterSettings.video(codec: .hevc, width: 3840, height: 2160, frameRate: .fps23_976,
                                           bitrate: 60_000_000, keyFrameIntervalSeconds: 1),
            frameRate: .fps23_976)
        #expect(input.mediaTimeScale == 24000 && input.expectsMediaDataInRealTime)
        #expect(writer.canAdd(input))
        let audio = WriterSettings.makeAudioInput(channels: 2)
        #expect(audio.expectsMediaDataInRealTime && writer.canAdd(audio))
    }

    @Test func videoSettingsTagBT709AndSetTheKeyframeInterval() throws {
        let s = WriterSettings.video(codec: .hevc, width: 3008, height: 1692, frameRate: .fps47_952, bitrate: 30_000_000,
                                     keyFrameIntervalSeconds: 2)
        let color = try #require(s[AVVideoColorPropertiesKey] as? [String: String])
        #expect(color[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_709_2)
        let props = try #require(s[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(props[AVVideoMaxKeyFrameIntervalKey] as? Int == 96)
        #expect(WriterSettings.video(codec: .proRes422LT, width: 2, height: 2, frameRate: .fps24, bitrate: 1,
                                     keyFrameIntervalSeconds: 1)[AVVideoCompressionPropertiesKey] == nil)
    }
}

@Suite struct SharedTimingTests {
    @Test func milliFramesAndOffsets() {
        let r = FrameRate.fps23_976
        #expect(GridMath.milliFrames(elapsedNs: GridMath.offsetNs(ofSlot: 3, frameRate: r), frameRate: r) == 3000)
        #expect(GridMath.milliFrames(elapsedNs: -20_854_167, frameRate: r) == -500)
        #expect(GridMath.add(10, -4) == 6 && GridMath.add(3, -9) == 0 && GridMath.add(3, 4) == 7)
        #expect(GridMath.ms(1_260_000) == "1.3" && GridMath.ms(-2_000_000) == "-2.0")
    }

    @Test func audioEndsWithTheVideo() {
        let timing = SessionTiming(frameRate: .fps23_976, startNs: 1_000)
        #expect(timing.audioOriginNs == 1_000)
        timing.setOrigin(5_000)
        timing.setOrigin(9_000)
        #expect(timing.originNs == 5_000 && timing.audioOriginNs == 5_000)
        #expect(timing.audioEndFrame(sampleRate: 48_000) == nil)
        timing.setEndSlot(240)
        #expect(timing.audioEndFrame(sampleRate: 48_000) == Int64(240 * 2002))
    }

    @Test func audioTrackStopData() {
        let r = AudioTrackResult(role: .mic, trackIndex: 1, firstPtsHostNs: 5, firstCaptureHostNs: 2, frames: 96_000,
                                 sourceSampleRate: 48_000, channels: 2, sourceFormat: nil, gapPaddedFrames: 480,
                                 overlapTrimmedFrames: 960, droppedBuffers: 1, failed: false)
        #expect(r.durationS == 2)
        #expect(r.trackStopData == ["gap_silence_ms": "10.0", "overlap_trim_ms": "20.0", "dropped_buffers": "1"])
    }
}

@Suite struct AudioPipelineTests {
    @Test func clockComparison() {
        let host = CMClockGetHostTimeClock()
        #expect(HostTimeMapper.sameClock(nil, nil))
        #expect(HostTimeMapper.sameClock(host, host))
        #expect(!HostTimeMapper.sameClock(host, nil))
        #expect(!HostTimeMapper.sameClock(nil, host))
    }

    /// A run of audio glitches writes one warning every 2 s with the number of gaps, not one line
    /// (and one flush) per gap on the audio queue.
    @Test func gapWarningsAreRateLimited() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-gaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try WriterSettings.makeWriter(url: dir.appendingPathComponent("audio.mov"), frameRate: .fps23_976)
        let input = WriterSettings.makeAudioInput(channels: 1)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let events = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        let origin = HostClock.nowNs() - 10_000_000_000
        let timing = SessionTiming(frameRate: .fps23_976, startNs: origin)
        timing.setOrigin(origin)
        let queue = DispatchQueue(label: "test.audio")
        let pipeline = AudioPipeline(queue: queue, role: .mic, fileName: "screen.mov")
        await pipeline.attach(writer: writer, input: input, trackIndex: 0, channels: 1, timing: timing, events: events)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        for i in 0..<480 { pcm.floatChannelData![0][i] = 0.25 }
        // 25 blocks of 200 ms: 140 ms of audio, then a 60 ms gap. 24 gaps after the head.
        var buffers: [(CMSampleBuffer, UInt64)] = []
        for block in 0..<25 {
            for k in 0..<14 {
                let pts = origin + UInt64(block) * 200_000_000 + UInt64(k) * 10_000_000
                buffers.append((PCMSampleBuffers.makeSampleBuffer(from: pcm, format: format.formatDescription, at: .zero)!, pts))
            }
        }
        let box = SampleBuffersBox(items: buffers)
        await queue.run { for (b, t) in box.items { pipeline.receive(b, ptsNs: t) } }
        let result = await pipeline.finish()
        await writer.finishWriting()
        events.close()

        #expect(result.gapPaddedFrames == 24 * 2880)
        let warnings = try EventLog.read(dir.appendingPathComponent("events.jsonl"))
            .filter { $0.type == .warning && $0.data?["message"] == "Audio gap filled with silence." }
        // At 0.2 s, 2.2 s and 4.2 s: 1, then 10 and 10 gaps.
        #expect(warnings.compactMap { $0.data?["gaps"] } == ["1", "10", "10"])
        #expect(warnings.allSatisfy { $0.data?["gap_ms"] == "60.0" })
    }
}

private struct SampleBuffersBox: @unchecked Sendable { let items: [(CMSampleBuffer, UInt64)] }
