// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreMedia
import RecorderCore

/// AVAssetWriter settings shared by camera.mov and screen.mov: the container, the encoder
/// settings and the audio format. One place, so both files get the same tags and crash safety.
package enum WriterSettings {
    /// Movie fragments let a crash keep everything up to the last fragment. The first fragment
    /// comes after 1 s so even a very short take survives.
    package static let movieFragmentInterval = CMTime(value: 2, timescale: 1)
    package static let initialMovieFragmentInterval = CMTime(value: 1, timescale: 1)

    /// Output sample rate of every audio track.
    package static let audioSampleRate = 48_000
    /// 24-bit integer PCM: lossless for the 16/24-bit sources, the format editors expect.
    package static let audioBitDepth = 24

    /// A .mov writer with a movie timescale that holds every frame time of `frameRate` exactly
    /// (24000 for 23.976) and a movie fragment every `movieFragmentInterval`.
    package static func makeWriter(url: URL, frameRate: FrameRate) throws -> AVAssetWriter {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = frameRate.timescale
        writer.movieFragmentInterval = movieFragmentInterval
        writer.initialMovieFragmentInterval = initialMovieFragmentInterval
        return writer
    }

    /// A real-time video input whose media timescale is the rate's numerator, so every slot time
    /// `k * den / num` is an exact tick.
    package static func makeVideoInput(settings: [String: Any], frameRate: FrameRate) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = frameRate.timescale
        return input
    }

    /// A real-time 48 kHz linear PCM input. Audio inputs keep their default media timescale (the
    /// sample rate); AVFoundation refuses any other.
    package static func makeAudioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio(channels: channels))
        input.expectsMediaDataInRealTime = true
        return input
    }

    package static func codecType(_ codec: VideoCodec) -> AVVideoCodecType {
        switch codec {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422LT: .proRes422LT
        }
    }

    /// Video output settings: the codec at the source size (nothing is scaled), the bitrate,
    /// BT.709 tags, the exact expected frame rate for the encoder's rate control, and a keyframe
    /// every `keyFrameIntervalSeconds`. ProRes is fixed quality: no bitrate or keyframe settings.
    package static func video(codec: VideoCodec, width: Int, height: Int, frameRate: FrameRate, bitrate: Int,
                              keyFrameIntervalSeconds: Double) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codecType(codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let fps = frameRate.framesPerSecond
        let keyFrameInterval = max(1, Int((fps * keyFrameIntervalSeconds).rounded()))
        switch codec {
        case .hevc:
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
            ] as [String: Any]
        case .h264:
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any]
        case .proRes422LT:
            break
        }
        return settings
    }

    /// Audio output settings: 48 kHz, 24-bit interleaved little-endian integer PCM, `channels`
    /// channels (taken from the source, so a mono mic stays mono). Never mixed or downmixed.
    package static func audio(channels: Int) -> [String: Any] {
        let channels = max(1, channels)
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: audioBitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            // Required above 2 channels: AVAssetWriterInput raises an exception without it.
            AVChannelLayoutKey: channelLayoutData(channels: channels),
        ]
    }

    /// Mono, stereo, or n discrete channels in device order.
    package static func channelLayoutTag(channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case ...1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        default: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        }
    }

    package static func channelLayoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelLayoutTag(channels: channels)
        return withUnsafeBytes(of: &layout) { Data($0) }
    }

    /// Short format label for an audio source, e.g. "1 ch 48 kHz Float32".
    package static func audioFormatLabel(_ format: CMAudioFormatDescription) -> String {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return "unknown" }
        let khz = asbd.mSampleRate / 1000
        let rate = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let sample = "\(isFloat ? "Float" : "Int")\(asbd.mBitsPerChannel)"
        return "\(asbd.mChannelsPerFrame) ch \(rate) kHz \(sample)"
    }

    /// Channel count of an audio format, or nil when unknown.
    package static func channelCount(_ format: CMAudioFormatDescription?) -> Int? {
        guard let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mChannelsPerFrame > 0 else { return nil }
        return Int(asbd.mChannelsPerFrame)
    }
}

/// Carries a writer and one input onto a pipeline queue.
package struct WriterInputBox: @unchecked Sendable {
    package let writer: AVAssetWriter
    package let input: AVAssetWriterInput
    package init(writer: AVAssetWriter, input: AVAssetWriterInput) { self.writer = writer; self.input = input }
}

/// Carries a writer to whoever finishes it.
package struct WriterBox: @unchecked Sendable {
    package let writer: AVAssetWriter
    package init(writer: AVAssetWriter) { self.writer = writer }

    /// Ends the session at `end` (when anything was written) and finishes the file. Never blocks.
    package func finish(endingAt end: CMTime?) async {
        if let end { writer.endSession(atSourceTime: end) }
        let box = self
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.writer.finishWriting { continuation.resume() }
        }
    }
}

extension DispatchQueue {
    /// Runs `body` on this queue and waits without blocking a Swift concurrency thread.
    package func run(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.async {
                body()
                continuation.resume()
            }
        }
    }
}
