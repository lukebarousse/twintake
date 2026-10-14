import CameraCapture
import CoreGraphics
import Foundation
@testable import RecorderApp
@testable import RecorderCore
import Replay
import WindowTools

/// The sample setup the screenshots show: a 4K capture card with its HDMI audio, the MacBook mic,
/// the 14" built-in display, two pinned apps, in Both mode. Only made-up plain data.
@MainActor
enum SampleData {
    static let cameraUID = "sample.camlink"
    static let cameraAudioUID = "sample.camlink.audio"
    static let macMicUID = "sample.builtin.mic"

    static let inventory = DeviceInventory(
        videoDevices: [
            CaptureDeviceInfo(uid: cameraUID, name: "Cam Link 4K", kind: .video, isBuiltIn: false, detail: "3840x2160 23.976"),
            CaptureDeviceInfo(uid: "sample.facetime", name: "MacBook Pro Camera", kind: .video, isBuiltIn: true),
        ],
        audioDevices: [
            CaptureDeviceInfo(uid: cameraAudioUID, name: "Cam Link 4K", kind: .audio, isBuiltIn: false, detail: "2 ch, 48 kHz"),
            CaptureDeviceInfo(uid: macMicUID, name: "MacBook Pro Microphone", kind: .audio, isBuiltIn: true, detail: "1 ch, 48 kHz"),
        ],
        videoFormats: [cameraUID: ["3840x2160 420v 23.976"]],
        linkedAudio: [cameraUID: [cameraAudioUID]],
        signals: [cameraUID: CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v")]
    )

    /// A 14" MacBook Pro's built-in display at its default size.
    static let display = DisplayInfo(id: 1, uuid: "sample.display.builtin", name: "Built-in Retina Display", isBuiltin: true,
                                     isMain: true, boundsGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2,
                                     menuBarHeightPt: 38, refreshRate: 120, hasNotch: true)

    static let pinnedApps = [
        PinnedApp(bundleID: "com.example.browser", name: "Browser"),
        PinnedApp(bundleID: "com.example.windows-vm", name: "Windows 11"),
    ]

    /// The Snap button's title for the front window, as `SnapTargets.buttonTitle` names it.
    static let snapButtonTitle = "Snap: \(pinnedApps[0].name)"

    /// The take's folder, as `SessionFolder.folderName` names it.
    static var takeFolder: URL {
        let start = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                   year: 2026, month: 10, day: 14, hour: 9, minute: 30, second: 12).date ?? Date()
        let name = SessionFolder.folderName(for: start, timeZone: TimeZone(identifier: "UTC") ?? .current)
        return RecorderSettings.defaultOutputFolder.appendingPathComponent(name, isDirectory: true)
    }

    /// The sample settings, stored in `defaults` (in memory for the screenshots, never the app's own).
    static func settings(defaults: UserDefaults) -> RecorderSettings {
        let settings = RecorderSettings(defaults: defaults)
        settings.mode = .both
        settings.camera = .automatic
        settings.cameraAudio = .automatic
        settings.screenMic = .automatic
        settings.displayUUID = nil
        settings.framePresetID = nil
        settings.showCameraPreview = true
        settings.cameraWindowShown = true
        settings.cameraWindowMirrored = true
        settings.systemAudio = true
        settings.showControlBar = true
        settings.pinnedApps = pinnedApps
        settings.flagLookbackSeconds = RecorderSettings.defaultFlagLookbackSeconds
        settings.replaySpeed = 1
        settings.replaySkipSilence = true
        return settings
    }

    /// Every permission allowed, without asking macOS.
    static func permissions() -> PermissionCenter {
        PermissionCenter(read: { Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) }) })
    }

    static func level(peak: Double, hold: Double, channels: Int) -> AudioLevel {
        AudioLevel(peakDb: peak, rmsDb: peak - 9, peakHoldDb: hold, clipCount: 0, channels: channels, isLive: true)
    }

    /// Before recording: the Live preview shows the camera, and the camera mic and Mac mic meters
    /// run; the last take is saved.
    static var ready: SessionCoordinator.Sample {
        var sample = SessionCoordinator.Sample()
        sample.state = .idle
        sample.inventory = inventory
        sample.displays = [display]
        sample.preview = .live
        sample.cameraWindowPhase = .live
        sample.meterSources = [.cameraMic, .screenMic]
        sample.meters = AudioLevelsSnapshot(
            cameraMic: level(peak: -15, hold: -11, channels: 2), screenMic: level(peak: -26, hold: -21, channels: 1),
            systemAudio: nil,
            detector: MicDetectorStatus(verdict: .externalMic, correlation: 0.982, voicedSeconds: 12, progress: 1))
        sample.lastSession = LastSession(folder: takeFolder, status: .complete, durationS: 754, errors: [])
        sample.snapButtonTitle = snapButtonTitle
        return sample
    }

    /// A take 3:42 in: both files record, three meters run, one flag, the replay window is open.
    static var recording: SessionCoordinator.Sample {
        var sample = SessionCoordinator.Sample()
        sample.state = .recording
        sample.elapsedS = 222
        sample.inventory = inventory
        sample.displays = [display]
        let screenPx = display.outputPixels(for: display.defaultPreset)
        sample.trackLines = [
            TrackStatusLine(id: "camera", title: "Camera", format: SessionRules.shortFormat("3840x2160 420v 23.976"),
                            status: "recording"),
            TrackStatusLine(id: "screen", title: "Screen",
                            format: "\(screenPx.width)×\(screenPx.height) \(ScreenRecorderConfigRate.screen.label)",
                            status: "recording"),
        ]
        sample.markers = [ControlBarRules.flagKind]
        sample.preview = .off
        sample.cameraWindowPhase = .live
        sample.meterSources = [.cameraMic, .screenMic, .systemAudio]
        sample.meters = AudioLevelsSnapshot(
            cameraMic: level(peak: -14, hold: -9, channels: 2), screenMic: level(peak: -24, hold: -19, channels: 1),
            systemAudio: level(peak: -34, hold: -29, channels: 2),
            detector: MicDetectorStatus(verdict: .externalMic, correlation: 0.987, voicedSeconds: 30, progress: 1, confirmed: true))
        sample.replayShown = true
        sample.snapButtonTitle = snapButtonTitle
        return sample
    }

    // MARK: - Replay

    /// The replay of the take above: playing 2:07 behind live with Skip silence on, two flags.
    static func replayModel() -> ReplayModel {
        let recordedS = 492.0
        let model = ReplayModel(files: [.screen, .camera], live: true,
                                title: ReplayRules.title(folder: takeFolder, live: true), speed: 1, skipSilence: true)
        var snapshot = ReplaySnapshot()
        snapshot.ready = true
        snapshot.playing = true
        snapshot.positionS = 365
        snapshot.edge = LiveEdge(isLive: true, recordedS: recordedS, availableS: recordedS - 2)
        model.snapshot = snapshot
        model.hasVoice = true
        model.speech = speech(until: recordedS - 2)
        let lookback = Double(RecorderSettings.defaultFlagLookbackSeconds)
        model.flags = [FlagMark(atS: 212, lookbackS: lookback), FlagMark(atS: 431, lookbackS: lookback)]
        return model
    }

    /// Speech with short pauses, the same every run.
    static func speech(until end: Double) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        var t = 1.5
        var seed: UInt64 = 0x2B7E_1516
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        while t < end {
            let talk = 2 + next() * 10
            spans.append(TimeSpan(t, min(end, t + talk)))
            t += talk + 0.6 + next() * (next() < 0.15 ? 9 : 2.5)
        }
        return spans
    }
}

/// The screen rate that goes with the sample camera's 23.976: 2x, 47.952.
private enum ScreenRecorderConfigRate {
    static let screen = CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v").screenFrameRate
}
