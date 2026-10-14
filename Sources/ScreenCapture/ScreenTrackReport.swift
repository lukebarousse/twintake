import Foundation
import MediaWriter
import RecorderCore

/// Builds the manifest entries for screen.mov from what the pipelines report.
enum ScreenTrackReport {
    static func tracks(config: ScreenRecorderConfig, video: VideoTrackResult, videoDevice: DeviceInfo?,
                       mic: AudioTrackResult?, micDevice: DeviceInfo?,
                       systemAudio: AudioTrackResult?) -> [TrackInfo] {
        let file = SessionFolder.screenFileName
        var tracks: [TrackInfo] = []

        var v = TrackInfo(file: file, trackIndex: 0, role: .screenVideo, dialogue: false)
        v.device = videoDevice
        v.codec = config.codec.rawValue
        v.width = config.outputPx.width
        v.height = config.outputPx.height
        v.frameRate = config.frameRate
        v.constantFrameRate = true
        v.firstPtsHostNs = video.originNs
        v.firstPtsSource = video.originNs == nil ? nil : "sample"
        v.durationS = Double(video.endSlot) * Double(config.frameRate.den) / Double(config.frameRate.num)
        v.droppedFrames = Int(video.stats.late)
        v.slotsRepeated = Int(video.stats.repeated)
        v.slotsSkipped = Int(video.stats.superseded)
        tracks.append(v)

        func audioTrack(_ r: AudioTrackResult, device: DeviceInfo?) -> TrackInfo {
            var t = TrackInfo(file: file, trackIndex: r.trackIndex, role: r.role, dialogue: false)
            t.device = device
            t.codec = "lpcm"
            t.sampleRate = Double(ScreenWriterSettings.audioSampleRate)
            t.channels = r.channels
            t.firstPtsHostNs = r.firstPtsHostNs
            t.firstPtsSource = r.firstPtsHostNs == nil ? nil : "sample"
            t.durationS = r.durationS
            return t
        }
        if let mic {
            var device = micDevice
            if device != nil, let format = mic.sourceFormat { device?.negotiatedFormat = format }
            tracks.append(audioTrack(mic, device: device))
        }
        if let systemAudio {
            tracks.append(audioTrack(systemAudio, device: nil))
        }
        return tracks.sorted { $0.trackIndex < $1.trackIndex }
    }
}
