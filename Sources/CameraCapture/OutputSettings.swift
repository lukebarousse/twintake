// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreAudio
import MediaWriter
import RecorderCore
import VideoToolbox

/// Encoder settings for camera.mov, given to its AVAssetWriter inputs. The container, BT.709
/// tags and audio format are the ones screen.mov uses too (`WriterSettings`).
enum CameraOutputSettings {
    /// Linear PCM bit depth for the camera audio track. 24-bit holds the HDMI audio without loss.
    static let audioBitDepth = WriterSettings.audioBitDepth
    static let audioSampleRate = Double(WriterSettings.audioSampleRate)
    /// A keyframe every second keeps scrubbing in Final Cut Pro fast.
    static let keyFrameIntervalSeconds = 1.0

    static func codecType(_ codec: VideoCodec) -> AVVideoCodecType { WriterSettings.codecType(codec) }

    static func codecFourCC(_ codec: VideoCodec) -> FourCharCode {
        switch codec {
        case .hevc: kCMVideoCodecType_HEVC
        case .h264: kCMVideoCodecType_H264
        case .proRes422LT: kCMVideoCodecType_AppleProRes422LT
        }
    }

    /// The codec to record with: the requested one when this Mac has an encoder for it, else HEVC,
    /// else H.264. An empty `availableEncoders` means the list could not be read; keep the request.
    /// An unsupported codec raises an Objective-C exception in the writer, so check VideoToolbox first.
    static func effectiveCodec(requested: VideoCodec, availableEncoders: Set<FourCharCode>) -> VideoCodec {
        guard !availableEncoders.isEmpty else { return requested }
        for codec in [requested, .hevc, .h264] where availableEncoders.contains(codecFourCC(codec)) {
            return codec
        }
        return requested
    }

    /// Codec types of every video encoder installed on this Mac (hardware and software).
    static func availableEncoderCodecTypes() -> Set<FourCharCode> {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let entries = list as? [[String: Any]] else { return [] }
        let key = kVTVideoEncoderList_CodecType as String
        return Set(entries.compactMap { ($0[key] as? NSNumber)?.uint32Value })
    }

    /// True when AVAssetWriter accepts `settings` for a .mov file. Opens no device and writes no
    /// file. True when the check cannot run.
    static func writerAccepts(_ settings: [String: Any], mediaType: AVMediaType) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-settings-check-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return true }
        return writer.canApply(outputSettings: settings, forMediaType: mediaType)
    }

    /// Video settings. Width and height equal the source, so nothing is scaled. BT.709 tags, the
    /// exact expected rate, a keyframe every second. ProRes is fixed-quality: it takes no bitrate
    /// or keyframe settings.
    static func video(codec: VideoCodec, width: Int, height: Int, frameRate: FrameRate, bitrate: Int) -> [String: Any] {
        WriterSettings.video(codec: codec, width: width, height: height, frameRate: frameRate, bitrate: bitrate,
                             keyFrameIntervalSeconds: keyFrameIntervalSeconds)
    }

    /// Interleaved little-endian 24-bit integer PCM at 48 kHz. The track is never mixed or downmixed.
    static func audio(channels: Int) -> [String: Any] { WriterSettings.audio(channels: channels) }

    /// Mono, stereo, or n discrete channels in device order.
    static func channelLayoutTag(channels: Int) -> AudioChannelLayoutTag { WriterSettings.channelLayoutTag(channels: channels) }
}
