// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreMedia
import MediaWriter
import RecorderCore

/// AVAssetWriter settings for screen.mov. The container, encoder tags and audio format are the
/// ones camera.mov uses too (`WriterSettings`).
enum ScreenWriterSettings {
    static let movieFragmentInterval = WriterSettings.movieFragmentInterval
    static let initialMovieFragmentInterval = WriterSettings.initialMovieFragmentInterval

    /// Output sample rate of every audio track.
    static let audioSampleRate = WriterSettings.audioSampleRate
    static let audioBitDepth = WriterSettings.audioBitDepth

    /// A keyframe every 2 s keeps scrubbing in the editor quick.
    static let keyFrameIntervalSeconds = 2.0

    /// Video output settings: the config's codec and bitrate, BT.709 tags, and the exact
    /// expected frame rate for the encoder's rate control.
    static func video(for config: ScreenRecorderConfig) -> [String: Any] {
        WriterSettings.video(codec: config.codec, width: config.outputPx.width, height: config.outputPx.height,
                             frameRate: config.frameRate, bitrate: config.bitrate,
                             keyFrameIntervalSeconds: keyFrameIntervalSeconds)
    }

    /// Audio output settings: 48 kHz, 24-bit interleaved linear PCM, `channels` channels
    /// (taken from the source so a mono mic stays mono).
    static func audio(channels: Int) -> [String: Any] { WriterSettings.audio(channels: channels) }

    /// Mono, stereo, or n discrete channels in device order (like camera.mov's layout).
    static func channelLayoutTag(channels: Int) -> AudioChannelLayoutTag { WriterSettings.channelLayoutTag(channels: channels) }

    /// Short format label for the manifest, e.g. "3008x1692 BGRA 47.952".
    static func videoFormatLabel(for config: ScreenRecorderConfig) -> String {
        "\(config.outputPx.width)x\(config.outputPx.height) BGRA \(config.frameRate.label)"
    }

    /// Short format label for an audio source, e.g. "1 ch 48 kHz Float32".
    static func audioFormatLabel(_ format: CMAudioFormatDescription) -> String { WriterSettings.audioFormatLabel(format) }
}

/// Track order inside screen.mov. The writer adds inputs in this order, so indexes are fixed:
/// video 0, then the mic, then system audio.
enum ScreenTrackLayout {
    static func roles(mic: Bool, systemAudio: Bool) -> [TrackInfo.Role] {
        var roles: [TrackInfo.Role] = [.screenVideo]
        if mic { roles.append(.mic) }
        if systemAudio { roles.append(.systemAudio) }
        return roles
    }

    static func index(of role: TrackInfo.Role, mic: Bool, systemAudio: Bool) -> Int? {
        roles(mic: mic, systemAudio: systemAudio).firstIndex(of: role)
    }
}
