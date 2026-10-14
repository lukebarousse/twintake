import Foundation
import Testing
@testable import CameraCapture

/// Lists this Mac's real cameras and audio inputs. Off by default; run it with
/// `CAMERA_PROBE=1 swift test --filter DeviceProbe`. It only lists devices and reads flags:
/// it never opens a device, so it shows no permission prompt.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CAMERA_PROBE"] == "1"))
struct DeviceProbe {
    @Test func listDevices() {
        let videos = CaptureDevices.videoDevices()
        let audios = CaptureDevices.audioDevices()
        for v in videos {
            print("video  \(v.name) [\(v.uid)] builtIn=\(v.isBuiltIn) \(v.detail ?? "-")")
            for f in CaptureDevices.formats(forVideoUID: v.uid) { print("         \(f)") }
        }
        for a in audios { print("audio  \(a.name) [\(a.uid)] builtIn=\(a.isBuiltIn) \(a.detail ?? "-")") }
        let camera = CaptureDevices.defaultCameraUID()
        print("default camera: \(camera ?? "none")")
        print("default camera audio: \(camera.flatMap(CaptureDevices.defaultCameraAudioUID(forCameraUID:)) ?? "none")")
        print("default screen mic: \(CaptureDevices.defaultScreenMicUID() ?? "none")")
        let device = camera.flatMap { uid in CaptureDevices.videoCaptureDevices().first { $0.uniqueID == uid } }
        let effects = VideoEffectsSnapshot.current(device: device)
        print("effects active: \(effects.activeNames())")
        for issue in effects.issues() { print("  \(issue.severity.rawValue): \(issue.message)") }
        let encoders = CameraOutputSettings.availableEncoderCodecTypes().map(FormatLabel.fourCC).sorted()
        print("video encoders: \(encoders.joined(separator: " "))")
        #expect(Set(videos.map(\.uid)).count == videos.count)
        #expect(Set(audios.map(\.uid)).count == audios.count)
    }
}
