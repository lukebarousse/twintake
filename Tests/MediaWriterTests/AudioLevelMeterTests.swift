import AVFoundation
import Testing
@testable import MediaWriter
import RecorderCore

/// A PCM sample buffer in `format`, with `fill` writing the samples into its buffer list.
func pcmSampleBuffer(_ format: AVAudioFormat, frames: Int,
                     fill: (UnsafeMutableAudioBufferListPointer) -> Void) -> CMSampleBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    fill(UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList))
    return PCMSampleBuffers.makeSampleBuffer(from: pcm, format: format.formatDescription, at: .zero)!
}

/// Float32 non-interleaved, one closure per channel: sample i of channel c.
func floatBuffer(frames: Int, channels: Int, sampleRate: Double = 48_000,
                 _ value: (_ channel: Int, _ i: Int) -> Float) -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: AVAudioChannelCount(channels), interleaved: false)!
    return pcmSampleBuffer(format, frames: frames) { list in
        for c in 0..<channels {
            let p = list[c].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { p[i] = value(c, i) }
        }
    }
}

/// Collects the meter's blocks. The meter is driven on the test's thread, so no lock is needed.
final class BlockLog: @unchecked Sendable {
    var blocks: [AudioBlock] = []
}

func meter(_ log: BlockLog, source: AudioSource = .cameraMic) -> AudioLevelMeter {
    AudioLevelMeter(source: source) { log.blocks.append($0) }
}

/// A deterministic noise source, uniform in [-1, 1).
struct TestNoise {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
    }
}

let blockNs = AudioBlock.durationNs
/// A host time on a block boundary.
let t0: UInt64 = 2_000 * blockNs

@Suite struct AudioLevelMeterTests {
    /// A 1 kHz sine at half scale on both channels: -6.02 dBFS peak, -9.03 dBFS RMS, correlation 1.
    @Test func sineLevelsPerBlock() throws {
        let log = BlockLog()
        let m = meter(log)
        for k in 0..<10 {
            let buffer = floatBuffer(frames: 480, channels: 2) { _, i in 0.5 * sin(2 * .pi * 1000 * Float(k * 480 + i) / 48_000) }
            m.process(buffer, ptsNs: t0 + UInt64(k) * 10_000_000)
        }
        // 100 ms is two whole blocks, each handed on as soon as it is full.
        #expect(log.blocks.map(\.index) == [2_000, 2_001])
        let block = try #require(log.blocks.first)
        #expect(block.frames == 2400 && block.channels == 2 && block.clipped == 0)
        #expect(abs(block.rmsDb - (-9.031)) < 0.01)
        #expect(abs(block.peakDb - (-6.021)) < 0.01)
        #expect(abs((block.correlation ?? 0) - 1) < 1e-4)
    }

    /// Int16 interleaved stereo: an inverted right channel is -1, an independent one about 0.
    @Test func int16InterleavedCorrelation() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
        for (inverted, expected) in [(true, -1.0), (false, 0.0)] {
            let log = BlockLog()
            let m = meter(log)
            var left = TestNoise(seed: 1), right = TestNoise(seed: 2)
            let buffer = pcmSampleBuffer(format, frames: 2400) { list in
                let p = list[0].mData!.assumingMemoryBound(to: Int16.self)
                for i in 0..<2400 {
                    let l = Int16(left.next() * 16_000)
                    p[2 * i] = l
                    p[2 * i + 1] = inverted ? -l : Int16(right.next() * 16_000)
                }
            }
            m.process(buffer, ptsNs: t0)
            let block = try #require(log.blocks.first)
            #expect(abs((block.correlation ?? 9) - expected) < 0.06, "\(String(describing: block.correlation))")
            // Uniform noise at 16000/32768: RMS 0.282, -11 dBFS.
            #expect(abs(block.rmsDb - 20 * log10(16_000.0 / 32_768 / 3.0.squareRoot())) < 0.3)
        }
    }

    @Test func clippedSamplesAreCounted() throws {
        let log = BlockLog()
        let m = meter(log, source: .screenMic)
        m.process(floatBuffer(frames: 2400, channels: 1) { _, i in i % 500 == 0 ? -0.95 : 0.1 }, ptsNs: t0)
        let block = try #require(log.blocks.first)
        #expect(block.clipped == 5 && block.correlation == nil)
        #expect(abs(block.peakDb - 20 * log10(0.95)) < 0.001)
    }

    /// A buffer that crosses a block boundary is split there.
    @Test func blocksFollowTheHostClock() {
        let log = BlockLog()
        let m = meter(log)
        // Starts 30 ms into a block: 960 samples finish it, 1440 open the next.
        m.process(floatBuffer(frames: 2400, channels: 2) { _, _ in 0.1 }, ptsNs: t0 + 30_000_000)
        #expect(log.blocks.map(\.frames) == [960])
        m.flush()
        #expect(log.blocks.map(\.index) == [2_000, 2_001] && log.blocks.map(\.frames) == [960, 1440])
    }

    /// A buffer stamped a little early never reopens a block that was handed on.
    @Test func earlyStampsDoNotRepeatABlock() {
        let log = BlockLog()
        let m = meter(log)
        var pts = t0
        for k in 0..<40 {
            // Stamps wobble by ±1 ms around 10 ms steps.
            let jitter: Int64 = k % 2 == 0 ? -1_000_000 : 1_000_000
            m.process(floatBuffer(frames: 480, channels: 1) { _, _ in 0.2 }, ptsNs: UInt64(Int64(pts) + jitter))
            pts += 10_000_000
        }
        let indices = log.blocks.map(\.index)
        #expect(indices == Array(Set(indices)).sorted())
        #expect(indices.count >= 6)
    }

    @Test func silenceIsMinus120() throws {
        let log = BlockLog()
        let m = meter(log)
        m.process(floatBuffer(frames: 2400, channels: 2) { _, _ in 0 }, ptsNs: t0)
        let block = try #require(log.blocks.first)
        #expect(block.rmsDb == AudioBlock.silenceDb && block.peakDb == AudioBlock.silenceDb && block.correlation == nil)
    }

    /// Int32, Float64 and packed 24-bit samples are read at their full scale.
    @Test func otherSampleFormats() throws {
        let level = 20 * log10(0.25)
        let int32 = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let float64 = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 48_000, channels: 1, interleaved: false)!
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 3,
            mFramesPerPacket: 1, mBytesPerFrame: 3, mChannelsPerFrame: 1, mBitsPerChannel: 24, mReserved: 0)
        let packed24 = try #require(AVAudioFormat(streamDescription: &asbd))
        let buffers = [
            pcmSampleBuffer(int32, frames: 2400) { list in
                let p = list[0].mData!.assumingMemoryBound(to: Int32.self)
                for i in 0..<2400 { p[i] = i % 2 == 0 ? 536_870_912 : -536_870_912 }
            },
            pcmSampleBuffer(float64, frames: 2400) { list in
                let p = list[0].mData!.assumingMemoryBound(to: Double.self)
                for i in 0..<2400 { p[i] = i % 2 == 0 ? 0.25 : -0.25 }
            },
            pcmSampleBuffer(packed24, frames: 2400) { list in
                let p = list[0].mData!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<2400 {
                    let v = UInt32(bitPattern: i % 2 == 0 ? 2_097_152 : -2_097_152)
                    p[3 * i] = UInt8(v & 0xFF); p[3 * i + 1] = UInt8((v >> 8) & 0xFF); p[3 * i + 2] = UInt8((v >> 16) & 0xFF)
                }
            },
        ]
        for buffer in buffers {
            let log = BlockLog()
            meter(log).process(buffer, ptsNs: t0)
            let block = try #require(log.blocks.first)
            #expect(abs(block.rmsDb - level) < 0.01 && abs(block.peakDb - level) < 0.01, "\(block)")
        }
    }

    /// The audio pipeline meters every buffer, before any file and during one.
    @Test func thePipelineFeedsTheMonitor() async throws {
        let monitor = AudioLevelMonitor()
        let queue = DispatchQueue(label: "test.meter")
        let pipeline = AudioPipeline(queue: queue, role: .mic, fileName: "screen.mov",
                                     meter: AudioLevelMeter(source: .screenMic, monitor: monitor))
        let box = SampleBox(buffer: floatBuffer(frames: 2400, channels: 1) { _, i in i % 2 == 0 ? 0.5 : -0.5 })
        await queue.run { pipeline.receive(box.buffer, ptsNs: t0) }
        let level = try #require(monitor.snapshot().screenMic)
        #expect(abs(level.rmsDb - (-6.02)) < 0.01 && level.isLive && level.channels == 1)
        #expect(monitor.snapshot().cameraMic == nil)
    }
}

private struct SampleBox: @unchecked Sendable { let buffer: CMSampleBuffer }

/// Synthetic takes through the real meters, the monitor and the detector: dual mono (the Rode),
/// decorrelated stereo (the camera's built-in mic), pauses, and a camera mic that hears nothing.
@Suite struct MicDetectorSignalTests {
    enum Camera { case dualMono, builtIn, dead, silent }

    /// Phrases of 0.6 s with 0.2 s between words and a 1.5 s pause every 5 s.
    static func talking(atNs ns: UInt64) -> Bool {
        let block = Int64(ns / blockNs) % 100
        return block < 70 && block % 16 < 12
    }

    /// Feeds `seconds` of the camera (2 ch) and the Mac mic (1 ch) in 10 ms buffers.
    static func run(_ camera: Camera, seconds: Int, monitor: AudioLevelMonitor, talks: Bool = true) {
        let cameraMeter = AudioLevelMeter(source: .cameraMic, monitor: monitor)
        let micMeter = AudioLevelMeter(source: .screenMic, monitor: monitor)
        var voice = TestNoise(seed: 7), room1 = TestNoise(seed: 8), room2 = TestNoise(seed: 9)
        var hissL = TestNoise(seed: 10), hissR = TestNoise(seed: 11), micHiss = TestNoise(seed: 12)
        let frames = 480
        var left = [Float](repeating: 0, count: frames), right = left, mic = left
        for k in 0..<(seconds * 100) {
            let pts = t0 + UInt64(k) * 10_000_000
            let on = talks && talking(atNs: pts)
            for i in 0..<frames {
                let v = on ? 0.06 * voice.next() : 0  // About -30 dBFS while talking.
                let hiss1 = 0.0006 * hissL.next(), hiss2 = 0.0006 * hissR.next()  // About -70 dBFS.
                switch camera {
                case .dualMono:
                    left[i] = v + hiss1; right[i] = v + hiss2
                case .builtIn:
                    // The two capsules share the voice and hear their own room: correlation about 0.8.
                    left[i] = 0.5 * v + 0.25 * (on ? 0.06 * room1.next() : 0) + hiss1
                    right[i] = 0.5 * v + 0.25 * (on ? 0.06 * room2.next() : 0) + hiss2
                case .dead:
                    left[i] = hiss1; right[i] = hiss2
                case .silent:
                    left[i] = 0; right[i] = 0
                }
                mic[i] = 0.5 * v + 0.001 * micHiss.next()
            }
            cameraMeter.process(floatBuffer(frames: frames, channels: 2) { c, i in c == 0 ? left[i] : right[i] }, ptsNs: pts)
            micMeter.process(floatBuffer(frames: frames, channels: 1) { _, i in mic[i] }, ptsNs: pts)
        }
    }

    @Test func theRodeIsTheExternalMic() {
        let monitor = AudioLevelMonitor()
        Self.run(.dualMono, seconds: 16, monitor: monitor)
        let status = monitor.snapshot().detector
        #expect(status.verdict == .externalMic && !status.cameraMicSilent, "\(status)")
        #expect((status.correlation ?? 0) > 0.99)
    }

    @Test func theBuiltInMicIsCaught() {
        let monitor = AudioLevelMonitor()
        Self.run(.builtIn, seconds: 16, monitor: monitor)
        let status = monitor.snapshot().detector
        #expect(status.verdict == .builtInMic && !status.cameraMicSilent, "\(status)")
        #expect(abs((status.correlation ?? 0) - 0.8) < 0.05)
        // Against the Mac mic, the built-in mic is about 1 dB louder here; the Rode would be 6 dB.
        #expect(abs((status.levelDeltaDb ?? 0) - 1) < 0.5)
    }

    @Test func aDeadCameraMicWarns() {
        for camera in [Camera.dead, .silent] {
            let monitor = AudioLevelMonitor()
            Self.run(camera, seconds: 20, monitor: monitor)
            let status = monitor.snapshot().detector
            #expect(status.cameraMicSilent && status.message == MicDetectorStatus.silentMessage, "\(camera): \(status)")
            #expect(status.verdict == .unknown)
        }
    }

    /// Both mics quiet (a long pause, or nobody there): no warning, no verdict.
    @Test func bothQuietIsNoWarning() {
        let monitor = AudioLevelMonitor()
        Self.run(.dead, seconds: 20, monitor: monitor, talks: false)
        let snapshot = monitor.snapshot()
        #expect(!snapshot.detector.cameraMicSilent && snapshot.detector.verdict == .unknown)
        #expect(snapshot.detector.message == nil)
        #expect((snapshot.cameraMic?.rmsDb ?? 0) < -65 && (snapshot.screenMic?.rmsDb ?? 0) < -55)
    }
}
