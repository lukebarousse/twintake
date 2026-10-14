import AVFoundation
import CoreMedia
import Testing
@testable import MediaWriter
@testable import ScreenCapture

/// A buffer whose sample `i` holds `Float(i) + channel * 10_000`, like ScreenCaptureKit's
/// Float32 non-interleaved audio.
func rampBuffer(frames: Int, channels: Int, sampleRate: Double = 48000, pts: CMTime = .zero,
                interleaved: Bool = false) -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: AVAudioChannelCount(channels), interleaved: interleaved)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = pcm.floatChannelData!
    for c in 0..<channels {
        for i in 0..<frames {
            if interleaved { data[0][i * channels + c] = Float(i) + Float(c) * 10_000 } else {
                data[c][i] = Float(i) + Float(c) * 10_000
            }
        }
    }
    return PCMSampleBuffers.makeSampleBuffer(from: pcm, format: format.formatDescription, at: pts)!
}

/// Reads every sample of a Float32 buffer back, per channel.
func samples(_ buffer: CMSampleBuffer) -> [[Float]] {
    let format = AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(buffer)!)
    let frames = CMSampleBufferGetNumSamples(buffer)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames),
                                                              into: pcm.mutableAudioBufferList)
    precondition(status == noErr)
    let channels = Int(format.channelCount)
    let data = pcm.floatChannelData!
    return (0..<channels).map { c in
        (0..<frames).map { i in format.isInterleaved ? data[0][i * channels + c] : data[c][i] }
    }
}

@Suite struct PCMSampleBuffersTests {
    @Test func silenceMatchesTheSourceFormat() throws {
        let source = rampBuffer(frames: 16, channels: 2)
        let format = try #require(CMSampleBufferGetFormatDescription(source))
        let silence = try #require(PCMSampleBuffers.silence(format: format, frameCount: 4800,
                                                            at: CMTime(value: 960, timescale: 48000)))
        #expect(CMSampleBufferGetNumSamples(silence) == 4800)
        #expect(CMSampleBufferGetPresentationTimeStamp(silence) == CMTime(value: 960, timescale: 48000))
        #expect(CMSampleBufferGetDuration(silence) == CMTime(value: 4800, timescale: 48000))
        #expect(CMFormatDescriptionEqual(CMSampleBufferGetFormatDescription(silence), otherFormatDescription: format))
        #expect(samples(silence).allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func copyCutsAnExactSampleRange() throws {
        for interleaved in [false, true] {
            let source = rampBuffer(frames: 1024, channels: 2, interleaved: interleaved)
            let cut = try #require(PCMSampleBuffers.copy(source, frameOffset: 100, frameCount: 200,
                                                         at: CMTime(value: 5, timescale: 48000)))
            #expect(CMSampleBufferGetNumSamples(cut) == 200)
            #expect(CMSampleBufferGetPresentationTimeStamp(cut) == CMTime(value: 5, timescale: 48000))
            let s = samples(cut)
            #expect(s[0].first == 100 && s[0].last == 299)
            #expect(s[1].first == 10_100 && s[1].last == 10_299)
        }
        let source = rampBuffer(frames: 10, channels: 1)
        #expect(PCMSampleBuffers.copy(source, frameOffset: 8, frameCount: 5, at: .zero) == nil)
    }

    @Test func retimedSharesSamplesAndMovesTheTime() throws {
        let source = rampBuffer(frames: 480, channels: 1, pts: CMTime(value: 123_456_789, timescale: 1_000_000_000))
        let moved = try #require(PCMSampleBuffers.retimed(source, at: CMTime(value: 48_000, timescale: 48000)))
        #expect(CMSampleBufferGetPresentationTimeStamp(moved) == CMTime(value: 48_000, timescale: 48000))
        #expect(CMSampleBufferGetNumSamples(moved) == 480)
        #expect(samples(moved) == samples(source))
    }

    @Test func fallbackFormatIsFloat32() throws {
        let format = try #require(PCMSampleBuffers.fallbackFormat(sampleRate: 48000, channels: 1))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == 48000 && asbd.mChannelsPerFrame == 1 && asbd.mBitsPerChannel == 32)
        #expect(ScreenWriterSettings.audioFormatLabel(format) == "1 ch 48 kHz Float32")
    }
}

@Suite struct HostTimeMapperTests {
    @Test func hostClockPassesTimesThrough() {
        let t = CMTime(value: 1_234_567_890, timescale: 1_000_000_000)
        let host = HostTimeMapper(clock: CMClockGetHostTimeClock())
        #expect(host.isHostClock && host.label == "host_time")
        #expect(host.hostNs(t) == 1_234_567_890)
        let unknown = HostTimeMapper(clock: nil)
        #expect(unknown.label == "host_time_assumed")
        #expect(unknown.hostNs(.invalid) == nil)
    }
}
