import Foundation
import MediaWriter
import RecorderCore

/// The host-clock time of a track's first written sample and how it was measured.
struct FirstPts: Sendable, Hashable {
    enum Source: String, Sendable {
        /// The exact presentation time of the first buffer written to the file.
        case sample
        /// The time of a "did start recording" callback: approximate. camera.mov no longer uses it.
        case callback
    }

    var hostNs: UInt64
    var source: Source
}

/// What the recorder knows about camera.mov when it stops. Plain data, so the session.json
/// tracks can be built and tested without a device.
struct CameraTrackFacts: Sendable {
    struct Audio: Sendable {
        var device: DeviceInfo
        var sampleRate: Double
        var channels: Int
        var firstPts: FirstPts?
        var durationS: Double?
    }

    var file = SessionFolder.cameraFileName
    var videoDevice: DeviceInfo
    var codec: VideoCodec
    var width: Int
    var height: Int
    var frameRate: FrameRate
    var videoFirstPts: FirstPts?
    var videoDurationS: Double?
    var droppedFrames: Int?
    var slotsRepeated: Int?
    var slotsSkipped: Int?
    var measuredPtsFps: Double?
    var measuredArrivalFps: Double?
    /// Nil when camera.mov has no audio track.
    var audio: Audio?
    /// Which mic the camera recorded with (the camera mic detector), for the mic track.
    var micSource: MicSourceReport?
}

extension CameraTrackFacts {
    /// Fills the timing fields from what the writer reports.
    ///
    /// Both tracks' first PTS is the host time of slot 0, the first frame in the file: the audio
    /// track is trimmed and padded to start there too. Frames and audio buffers from before the
    /// file began (the camera runs from prepare on) never count. (The old movie-output path once
    /// took the frame that asked the output to start, 1.85 s before the file really began.)
    mutating func apply(video: CameraVideoResult?, audio: AudioTrackResult?, audioDevice: DeviceInfo?) {
        if let video, let origin = video.originNs, video.endSlot > 0 {
            videoFirstPts = FirstPts(hostNs: origin, source: .sample)
            videoDurationS = Double(video.endSlot) * Double(frameRate.den) / Double(frameRate.num)
            droppedFrames = Int(video.droppedFrames)
            slotsRepeated = Int(video.stats.slotsRepeated)
            slotsSkipped = Int(video.stats.slotsSkipped)
            measuredPtsFps = video.ptsFps
            measuredArrivalFps = video.arrivalFps
        }
        if let audio, let audioDevice, audio.frames > 0 {
            self.audio = Audio(device: audioDevice, sampleRate: Double(WriterSettings.audioSampleRate), channels: audio.channels,
                               firstPts: audio.firstPtsHostNs.map { FirstPts(hostNs: $0, source: .sample) },
                               durationS: audio.durationS)
        }
    }
}

enum CameraTrackBuilder {
    /// camera.mov tracks: video (index 0) and, when recorded, the camera mic (index 1).
    /// `dialogue` is false on both; the app picks the one dialogue track of the session.
    static func tracks(_ f: CameraTrackFacts) -> [TrackInfo] {
        var video = TrackInfo(file: f.file, trackIndex: 0, role: .cameraVideo, dialogue: false)
        video.device = f.videoDevice
        video.codec = f.codec.rawValue
        video.width = f.width
        video.height = f.height
        video.frameRate = f.frameRate
        video.constantFrameRate = true
        video.firstPtsHostNs = f.videoFirstPts?.hostNs
        video.firstPtsSource = f.videoFirstPts?.source.rawValue
        video.durationS = f.videoDurationS
        video.droppedFrames = f.droppedFrames
        video.slotsRepeated = f.slotsRepeated
        video.slotsSkipped = f.slotsSkipped
        video.measuredPtsFps = f.measuredPtsFps.map(Self.rounded)
        video.measuredArrivalFps = f.measuredArrivalFps.map(Self.rounded)
        guard let a = f.audio else { return [video] }

        var mic = TrackInfo(file: f.file, trackIndex: 1, role: .mic, dialogue: false)
        mic.device = a.device
        mic.codec = "lpcm"
        mic.sampleRate = a.sampleRate
        mic.channels = a.channels
        mic.firstPtsHostNs = a.firstPts?.hostNs
        mic.firstPtsSource = a.firstPts?.source.rawValue
        mic.durationS = a.durationS
        mic.micSource = f.micSource
        return [video, mic]
    }

    /// Measured rates with 4 decimals (23.9760), enough to see a 0.01% difference.
    static func rounded(_ fps: Double) -> Double { (fps * 10_000).rounded() / 10_000 }
}

/// events.jsonl data for camera.mov at Stop: one track_stop per track, and a warning when the
/// frame timestamps and the real frame arrivals run at different rates.
enum CameraTrackReport {
    static func fps(_ value: Double) -> String { String(format: "%.4f", value) }

    /// track_stop data for one camera.mov track.
    static func trackStopData(track: TrackInfo, video: CameraVideoResult?, audio: AudioTrackResult?) -> [String: String] {
        var data = ["file": track.file, "role": track.role.rawValue, "track_index": "\(track.trackIndex)"]
        data["duration_s"] = track.durationS.map { String(format: "%.3f", $0) }
        data["dropped_frames"] = track.droppedFrames.map { "\($0)" }
        data["first_pts_host_ns"] = track.firstPtsHostNs.map { "\($0)" }
        switch track.role {
        case .cameraVideo:
            guard let v = video else { break }
            data["slots_written"] = String(v.endSlot)
            data["frames_written"] = String(v.stats.framesWritten)
            data["slots_repeated"] = String(v.stats.slotsRepeated)
            data["slots_skipped"] = String(v.stats.slotsSkipped)
            data["late_frames"] = String(v.stats.lateFrames)
            data["writer_busy_frames"] = String(v.writerBusyFrames)
            if v.otherSizeFrames > 0 { data["other_size_frames"] = String(v.otherSizeFrames) }
            data["measured_pts_fps"] = v.ptsFps.map(fps)
            data["measured_arrival_fps"] = v.arrivalFps.map(fps)
            data["clock_correction_ms"] = GridMath.ms(v.correctionNs)
            data["frames_before_start"] = String(v.preStartFrames)
            data["clock"] = v.clockLabel
        case .mic:
            if let audio { data.merge(audio.trackStopData) { _, new in new } }
            if let source = track.micSource {
                data["mic_source"] = source.verdict.rawValue
                data["camera_mic_silent"] = String(source.cameraMicSilent)
            }
        default:
            break
        }
        return data
    }

    /// A warning when the timestamp rate and the arrival rate differ by more than 0.01% over a take
    /// of 30 s or more: the camera stamps a nominal frame interval. camera.mov follows the arrivals.
    static func rateWarning(_ video: CameraVideoResult?) -> [String: String]? {
        guard let v = video, let mismatch = v.rateMismatch, abs(mismatch) > FrameRateMeter.mismatchLimit,
              let pts = v.ptsFps, let arrival = v.arrivalFps else { return nil }
        let percent = String(format: "%.3f", mismatch * 100)
        return [
            "source": "camera", "file": SessionFolder.cameraFileName,
            "message": "The camera stamps its frames at \(fps(pts)) fps, but they arrive at \(fps(arrival)) fps "
                + "(\(percent)% apart). camera.mov follows the arrivals, so its picture stays with its audio.",
            "measured_pts_fps": fps(pts), "measured_arrival_fps": fps(arrival), "difference_percent": percent,
        ]
    }
}

/// Preflight text, kept apart from device code so the wording can be tested.
enum CameraMessages {
    /// The blocker when the camera offers no format at the configured size and rate.
    static func formatUnavailable(cameraName: String, offered: [VideoFormatCandidate],
                                  width: Int, height: Int, frameRate: FrameRate) -> String {
        let wanted = "\(width)x\(height) \(frameRate.label)"
        guard !offered.isEmpty else {
            return "\(cameraName) reports no video formats. Check that the camera is on and its HDMI cable is in, "
                + "then check again. The recorder needs \(wanted)."
        }
        // Largest first, so the most likely signal leads the message.
        let ranked = offered.indices.sorted { a, b in
            (offered[a].width * offered[a].height, offered[a].maxFps) > (offered[b].width * offered[b].height, offered[b].maxFps)
        }
        let getting = orderedUnique(ranked.map { FormatLabel.signal(offered[$0]) }).joined(separator: ", ")
        guard isCaptureCard(cameraName) else {
            return "\(cameraName) offers \(getting), not \(wanted). "
                + "Pick a camera that offers \(wanted), or change the recording size and rate in Settings."
        }
        // Sony names NTSC rates by their rounded value: 23.976 is "24p".
        let p = "\(Int(frameRate.framesPerSecond.rounded()))p"
        let fix = height == 2160
            ? "Set the a6600 HDMI output to 4K \(p): HDMI Resolution 2160p/1080p (or Auto) and "
                + "4K Output Sel. HDMI Only (\(p)), or record XAVC S 4K \(p) with Memory Card+HDMI."
            : "Set the a6600 HDMI output to \(height)p and its movie frame rate to \(p)."
        return "\(cameraName) is getting \(getting) from the camera, not \(wanted). \(fix) Then check again."
    }

    /// The blocker when a camera that should follow its signal offers no format at all.
    static func noSignal(cameraName: String) -> String {
        "\(cameraName) reports no video formats. Check that the camera is on and its HDMI cable is in, then check again."
    }

    /// The warning when a capture card gets less than 4K: the take records what it gets.
    static func notFourK(cameraName: String, signal: CameraSignal) -> String {
        let p = "\(Int(signal.frameRate.framesPerSecond.rounded()))p"
        return "\(cameraName) is getting \(signal.shortLabel), not 4K, so camera.mov records \(signal.shortLabel). "
            + "For 4K, set the a6600 HDMI output to 4K \(p) (HDMI Resolution Auto, 4K Output Sel. HDMI Only)."
    }

    /// The empty-frame problem: "No picture: the Cam Link is sending empty frames."
    static func emptyFrames(cameraName: String) -> String {
        let name = cameraName.localizedCaseInsensitiveContains("Cam Link") ? "the Cam Link" : cameraName
        return "No picture: \(name) is sending empty frames."
    }

    /// True for HDMI capture cards, whose formats mirror the incoming signal.
    static func isCaptureCard(_ name: String) -> Bool {
        ["Cam Link", "Elgato", "HDMI", "Capture"].contains { name.localizedCaseInsensitiveContains($0) }
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
