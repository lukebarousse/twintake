// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import CoreGraphics
import CoreMedia
import CoreVideo
import RecorderCore
import ScreenCaptureKit

/// Maps a `ScreenRecorderConfig` to ScreenCaptureKit stream settings.
///
/// Building an `SCStreamConfiguration` needs no permission, so this mapping is unit tested.
enum ScreenStreamSettings {
    /// BGRA. ScreenCaptureKit hands over full RGB and VideoToolbox makes the one RGB to YCbCr
    /// conversion, using the BT.709 tags the writer puts on the file, so the tags always match the
    /// pixels. With '420v' ScreenCaptureKit converts first and its transfer-function tag (sRGB) can
    /// disagree with the file's BT.709 tag, which makes the writer convert a second time. BGRA also
    /// keeps full chroma for ProRes 422, and text edges keep full chroma until the encoder. The cost
    /// is about 2.7x the memory traffic of '420v' (20 MB per 3008x1692 frame); at most about
    /// three frames are held at once.
    static let pixelFormat: OSType = kCVPixelFormatType_32BGRA

    /// The maximum ScreenCaptureKit allows. The recorder holds the last written frame and the
    /// newest waiting frame, and the encoder holds a few more.
    static let queueDepth = 8

    static let audioSampleRate = 48_000
    static let systemAudioChannels = 2

    /// A single-window filter scopes the stream's audio to that window's app, so window mode
    /// records system audio on a second, display-wide stream.
    static func usesDedicatedSystemAudioStream(_ config: ScreenRecorderConfig) -> Bool {
        config.captureSystemAudio && config.windowID != nil
    }

    /// The throttle for ScreenCaptureKit: 0.49 of one grid frame, so it delivers at most about
    /// twice the grid rate.
    ///
    /// `minimumFrameInterval` is a floor between delivered frames, and frames come on display
    /// refreshes. Set to exactly one grid frame (BetterCapture's choice), it fails in two ways:
    /// a display at or a hair above the grid rate (47.95 or 48 Hz under a 47.952 fps grid) can have
    /// every other refresh rejected as too early, which halves the real rate; and a 60 Hz display
    /// gives only every second refresh, 30 fps. Under half a frame, every refresh up to 2x the grid
    /// rate is delivered (47.95, 60, and every second refresh at 120 Hz), so every slot gets a fresh
    /// frame and the CFR grid keeps the newest one per slot.
    static func minimumFrameInterval(for frameRate: FrameRate) -> CMTime {
        CMTime(value: CMTimeValue(frameRate.den) * 49, timescale: frameRate.num * 100)
    }

    /// Configuration for the main stream: video, plus the mic, plus system audio in region mode.
    static func streamConfiguration(for config: ScreenRecorderConfig) -> SCStreamConfiguration {
        let sc = SCStreamConfiguration()
        sc.width = config.outputPx.width
        sc.height = config.outputPx.height
        sc.pixelFormat = pixelFormat
        sc.colorSpaceName = CGColorSpace.sRGB
        sc.captureDynamicRange = .SDR
        sc.captureResolution = .best
        sc.minimumFrameInterval = minimumFrameInterval(for: config.frameRate)
        sc.queueDepth = queueDepth
        sc.showsCursor = config.showsCursor
        sc.preservesAspectRatio = true
        sc.backgroundColor = CGColor.black
        sc.streamName = SessionFolder.screenFileName

        if config.windowID != nil {
            // Independent-window capture draws the window at its natural size unless told to
            // scale; sourceRect does not apply to it.
            sc.scalesToFit = true
            sc.ignoreShadowsSingleWindow = true
        } else {
            sc.sourceRect = config.frameRectPt
        }

        sc.capturesAudio = config.captureSystemAudio && !usesDedicatedSystemAudioStream(config)
        sc.sampleRate = audioSampleRate
        sc.channelCount = systemAudioChannels
        sc.excludesCurrentProcessAudio = true

        // Always select the mic by uniqueID: with no ID ScreenCaptureKit uses the system default.
        sc.captureMicrophone = config.micDeviceUID != nil
        sc.microphoneCaptureDeviceID = config.micDeviceUID
        return sc
    }

    /// Configuration for the system-audio stream used in window mode. ScreenCaptureKit has no
    /// audio-only mode, so the video side is as small and slow as it accepts.
    static func systemAudioStreamConfiguration() -> SCStreamConfiguration {
        let sc = SCStreamConfiguration()
        sc.capturesAudio = true
        sc.sampleRate = audioSampleRate
        sc.channelCount = systemAudioChannels
        sc.excludesCurrentProcessAudio = true
        sc.width = 2
        sc.height = 2
        sc.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        sc.showsCursor = false
        sc.queueDepth = 3
        sc.streamName = "system-audio"
        return sc
    }
}
