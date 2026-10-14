import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Testing
@testable import RecorderCore
@testable import MediaWriter
@testable import ScreenCapture

/// Luke's laptop frame: 1504x846 pt at (4, 37) on the 14" display, 3008x1692 px.
func laptopConfig(mic: String? = "BuiltInMicrophoneDevice", systemAudio: Bool = true, windowID: UInt32? = nil,
                  codec: VideoCodec = .hevc, rate: FrameRate = .fps47_952) -> ScreenRecorderConfig {
    ScreenRecorderConfig(displayID: 1, frameRectPt: CGRect(x: 4, y: 37, width: 1504, height: 846),
                         outputPx: PixelSize(width: 3008, height: 1692), frameRate: rate, micDeviceUID: mic,
                         captureSystemAudio: systemAudio, showsCursor: true,
                         excludedBundleIDs: ["com.lukebarousse.twintake"], windowID: windowID, codec: codec)
}

@Suite struct ScreenStreamSettingsTests {
    @Test func regionModeMapsEveryField() {
        let c = ScreenStreamSettings.streamConfiguration(for: laptopConfig())
        #expect(c.width == 3008 && c.height == 1692)
        #expect(c.sourceRect == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(c.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(c.colorSpaceName == CGColorSpace.sRGB)
        #expect(c.queueDepth == 8)
        #expect(c.showsCursor)
        #expect(!c.scalesToFit)
        #expect(c.captureResolution == .best)
        #expect(c.capturesAudio)
        #expect(c.sampleRate == 48000 && c.channelCount == 2)
        #expect(c.excludesCurrentProcessAudio)
        #expect(c.captureMicrophone)
        #expect(c.microphoneCaptureDeviceID == "BuiltInMicrophoneDevice")
    }

    @Test func throttleLetsUpToTwiceTheGridRateThrough() {
        for rate in [FrameRate.fps47_952, .fps23_976, .fps59_94] {
            let c = ScreenStreamSettings.streamConfiguration(for: laptopConfig(rate: rate))
            let interval = c.minimumFrameInterval
            #expect(interval == CMTime(value: CMTimeValue(rate.den) * 49, timescale: rate.num * 100))
            #expect(interval.seconds < rate.frameDuration.seconds / 2)
            #expect(interval.seconds > rate.frameDuration.seconds * 0.45)
        }
        // Every refresh of a 47.95 Hz and a 60 Hz display passes a 47.952 grid's throttle.
        let interval = ScreenStreamSettings.minimumFrameInterval(for: .fps47_952).seconds
        #expect(interval < 1 / 60.0)
        #expect(interval < 1001 / 48000.0)
    }

    @Test func windowModeScalesTheWindowAndMovesSystemAudioToItsOwnStream() {
        let config = laptopConfig(windowID: 4242)
        let c = ScreenStreamSettings.streamConfiguration(for: config)
        #expect(c.scalesToFit)
        #expect(c.preservesAspectRatio)
        #expect(c.ignoreShadowsSingleWindow)
        #expect(ScreenStreamSettings.usesDedicatedSystemAudioStream(config))
        #expect(!c.capturesAudio)
        #expect(c.captureMicrophone)

        let audio = ScreenStreamSettings.systemAudioStreamConfiguration()
        #expect(audio.capturesAudio && audio.excludesCurrentProcessAudio)
        #expect(audio.sampleRate == 48000 && audio.channelCount == 2)
        #expect(audio.width == 2 && audio.height == 2)
    }

    @Test func noMicMeansNoMicCapture() {
        let c = ScreenStreamSettings.streamConfiguration(for: laptopConfig(mic: nil, systemAudio: false))
        #expect(!c.captureMicrophone)
        #expect(c.microphoneCaptureDeviceID == nil)
        #expect(!c.capturesAudio)
        #expect(!ScreenStreamSettings.usesDedicatedSystemAudioStream(laptopConfig(systemAudio: false, windowID: 1)))
    }
}

@Suite struct ScreenWriterSettingsTests {
    @Test func hevcVideoSettings() {
        let s = ScreenWriterSettings.video(for: laptopConfig())
        #expect(s[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        #expect(s[AVVideoWidthKey] as? Int == 3008)
        #expect(s[AVVideoHeightKey] as? Int == 1692)
        let compression = s[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[AVVideoAverageBitRateKey] as? Int == 30_000_000)
        #expect(compression?[AVVideoExpectedSourceFrameRateKey] as? Double == 48000.0 / 1001.0)
        #expect(compression?[AVVideoMaxKeyFrameIntervalKey] as? Int == 96)
        let color = s[AVVideoColorPropertiesKey] as? [String: String]
        #expect(color?[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(color?[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_709_2)
        #expect(color?[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    @Test func proResHasNoBitrate() {
        let s = ScreenWriterSettings.video(for: laptopConfig(codec: .proRes422LT))
        #expect(s[AVVideoCodecKey] as? AVVideoCodecType == .proRes422LT)
        #expect(s[AVVideoCompressionPropertiesKey] == nil)
        let h264 = ScreenWriterSettings.video(for: laptopConfig(codec: .h264))
        #expect(h264[AVVideoCodecKey] as? AVVideoCodecType == .h264)
    }

    @Test func audioIs48kHz24BitPCMWithSourceChannels() {
        for channels in [1, 2, 4, 6] {
            let s = ScreenWriterSettings.audio(channels: channels)
            #expect(s[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM)
            #expect(s[AVSampleRateKey] as? Int == 48000)
            #expect(s[AVNumberOfChannelsKey] as? Int == channels)
            #expect(s[AVLinearPCMBitDepthKey] as? Int == 24)
            #expect(s[AVLinearPCMIsFloatKey] as? Bool == false)
            #expect(s[AVChannelLayoutKey] is Data)
        }
        #expect(ScreenWriterSettings.channelLayoutTag(channels: 1) == kAudioChannelLayoutTag_Mono)
        #expect(ScreenWriterSettings.channelLayoutTag(channels: 2) == kAudioChannelLayoutTag_Stereo)
        #expect(ScreenWriterSettings.channelLayoutTag(channels: 4) == kAudioChannelLayoutTag_DiscreteInOrder | 4)
    }

    /// A 4-channel USB interface as the screen mic: the writer must accept it (it raised an
    /// Objective-C exception before the channel layout was set for more than 2 channels).
    @Test func writerAcceptsMultichannelMic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multich-\(UUID().uuidString).mov")
        for channels in [4, 6, 8] {
            let h = try ScreenWriterHandles.make(url: url, config: laptopConfig(), micChannels: channels, systemAudioChannels: 2)
            #expect(h.writer.inputs.count == 3)
            #expect(h.mic?.outputSettings?[AVNumberOfChannelsKey] as? Int == channels)
        }
    }

    @Test func writerAddsInputsInTrackOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString).mov")
        for (mic, system) in [(true, true), (false, true), (true, false), (false, false)] {
            let h = try ScreenWriterHandles.make(url: url, config: laptopConfig(), micChannels: mic ? 1 : nil,
                                                 systemAudioChannels: system ? 2 : nil)
            let types = h.writer.inputs.map(\.mediaType)
            let expected = ScreenTrackLayout.roles(mic: mic, systemAudio: system)
                .map { $0 == .screenVideo ? AVMediaType.video : .audio }
            #expect(types == expected)
            #expect(h.writer.movieTimeScale == 48000)
            #expect(h.video.mediaTimeScale == 48000)
            #expect(h.writer.movieFragmentInterval == CMTime(value: 2, timescale: 1))
            #expect(h.writer.initialMovieFragmentInterval == CMTime(value: 1, timescale: 1))
            if mic { #expect(h.mic === h.writer.inputs[1]) }
            if system { #expect(h.systemAudio === h.writer.inputs.last) }
        }
    }
}

@Suite struct ScreenTrackReportTests {
    @Test func manifestEntriesFollowTheLayout() {
        let config = laptopConfig()
        let video = VideoTrackResult(originNs: 123, endSlot: 4796,
                                     stats: CFRStats(written: 4796, repeated: 900, late: 3, superseded: 10),
                                     clockLabel: "host_time", failed: false)
        func audio(_ role: TrackInfo.Role, _ index: Int, _ channels: Int) -> AudioTrackResult {
            AudioTrackResult(role: role, trackIndex: index, firstPtsHostNs: 123, firstCaptureHostNs: 200,
                             frames: 4796 * 1001, sourceSampleRate: 48000, channels: channels,
                             sourceFormat: "\(channels) ch 48 kHz Float32", gapPaddedFrames: 0,
                             overlapTrimmedFrames: 0, droppedBuffers: 0, failed: false)
        }
        let tracks = ScreenTrackReport.tracks(
            config: config, video: video, videoDevice: DeviceInfo(name: "Built-in display", uid: "display-1"),
            mic: audio(.mic, 1, 1), micDevice: DeviceInfo(name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"),
            systemAudio: audio(.systemAudio, 2, 2))
        #expect(tracks.map(\.trackIndex) == [0, 1, 2])
        #expect(tracks.map(\.role) == [.screenVideo, .mic, .systemAudio])
        #expect(tracks.allSatisfy { $0.file == "screen.mov" && !$0.dialogue })
        let v = tracks[0]
        #expect(v.width == 3008 && v.height == 1692)
        #expect(v.frameRate == .fps47_952 && v.constantFrameRate == true)
        #expect(v.droppedFrames == 3)
        #expect(v.firstPtsHostNs == 123 && v.firstPtsSource == "sample")
        #expect(abs((v.durationS ?? 0) - 4796 * 1001 / 48000.0) < 1e-9)
        #expect(tracks[1].channels == 1 && tracks[1].sampleRate == 48000 && tracks[1].codec == "lpcm")
        #expect(tracks[1].device?.negotiatedFormat == "1 ch 48 kHz Float32")
        #expect(tracks[1].durationS == v.durationS)
        #expect(tracks[2].channels == 2 && tracks[2].device == nil)
    }
}
