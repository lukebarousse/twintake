import AVFoundation
import Testing
@testable import CameraCapture
import RecorderCore

private func video(_ uid: String, _ name: String, builtIn: Bool = false) -> CaptureDeviceInfo {
    CaptureDeviceInfo(uid: uid, name: name, kind: .video, isBuiltIn: builtIn)
}

private func audio(_ uid: String, _ name: String, builtIn: Bool = false) -> CaptureDeviceInfo {
    CaptureDeviceInfo(uid: uid, name: name, kind: .audio, isBuiltIn: builtIn)
}

@Suite struct DeviceDefaultsTests {
    // Luke's desk, in the order macOS lists it.
    let cameras = [
        video("built-in-cam", "MacBook Pro Camera", builtIn: true),
        video("usb-cam", "Logitech BRIO"),
        video("0x206000000fd90066", "Cam Link 4K"),
    ]
    let mics = [
        audio("usb-audio", "USB Audio Device"),  // the system default input: never picked
        audio("caldigit", "CalDigit Thunderbolt 3 Audio"),
        audio("camlink-audio", "Cam Link 4K"),
        audio("BuiltInMicrophoneDevice", "MacBook Pro Microphone", builtIn: true),
        audio("iphone", "Luke's iPhone Microphone"),
    ]

    @Test func camLinkWinsOverOtherExternalCameras() {
        #expect(DeviceDefaults.cameraUID(in: cameras) == "0x206000000fd90066")
    }

    @Test func firstExternalCameraWithoutCamLink() {
        #expect(DeviceDefaults.cameraUID(in: Array(cameras.prefix(2))) == "usb-cam")
        #expect(DeviceDefaults.cameraUID(in: [cameras[0]]) == nil)
    }

    @Test func cameraAudioMatchesByName() {
        #expect(DeviceDefaults.cameraAudioUID(cameraName: "Cam Link 4K", linkedAudioUIDs: [], in: mics) == "camlink-audio")
        #expect(DeviceDefaults.cameraAudioUID(cameraName: "cam link 4k", linkedAudioUIDs: [], in: mics) == "camlink-audio")
        #expect(DeviceDefaults.cameraAudioUID(cameraName: "Logitech BRIO", linkedAudioUIDs: [], in: mics) == nil)
    }

    @Test func linkedAudioWinsAndContainsMatchIsLast() {
        #expect(DeviceDefaults.cameraAudioUID(cameraName: "Cam Link 4K", linkedAudioUIDs: ["caldigit"], in: mics) == "caldigit")
        let withSuffix = [audio("a", "Cam Link 4K Audio")]
        #expect(DeviceDefaults.cameraAudioUID(cameraName: "Cam Link 4K", linkedAudioUIDs: [], in: withSuffix) == "a")
        #expect(DeviceDefaults.cameraAudioUID(cameraName: "  ", linkedAudioUIDs: [], in: mics) == nil)
    }

    @Test func screenMicIsTheBuiltInMicNeverTheDefaultInput() {
        #expect(DeviceDefaults.screenMicUID(in: mics) == "BuiltInMicrophoneDevice")
        let noBuiltIn = mics.filter { !$0.isBuiltIn }
        #expect(DeviceDefaults.screenMicUID(in: noBuiltIn) == nil)
        let unflagged = [audio("usb-audio", "USB Audio Device"), audio("BuiltInMicrophoneDevice", "MacBook Pro Microphone")]
        #expect(DeviceDefaults.screenMicUID(in: unflagged) == "BuiltInMicrophoneDevice")
    }
}

@Suite struct VideoEffectsTests {
    @Test func enabledAndSupportedIsActive() {
        var s = VideoEffectsSnapshot()
        s.flags[.portrait] = EffectFlags(enabled: true, supported: true)
        s.flags[.studioLight] = EffectFlags(enabled: true, supported: false)
        #expect(s.activeNames() == ["Portrait"])
        let issues = s.issues()
        #expect(issues.map(\.id) == ["camera.effect.portrait"])
        #expect(issues.first?.severity == .blocker)
    }

    @Test func activeOnTheDeviceWinsOverFlags() {
        var s = VideoEffectsSnapshot()
        s.flags[.centerStage] = EffectFlags(active: true)
        s.flags[.backgroundReplacement] = EffectFlags(enabled: false, supported: true, active: false)
        #expect(s.activeNames() == ["Center Stage"])
    }

    @Test func unknownCameraGivesWarnings() {
        var s = VideoEffectsSnapshot()
        s.flags[.reactions] = EffectFlags(enabled: true, supported: nil)
        #expect(s.level(of: .reactions) == .enabled)
        #expect(s.activeNames().isEmpty)
        #expect(s.issues().map(\.severity) == [.warning])
        #expect(s.issues().first?.message.contains("Reactions") == true)
    }

    @Test func namesFollowOneOrderAndIncludeMicMode() {
        var s = VideoEffectsSnapshot()
        for effect in VideoEffect.allCases { s.flags[effect] = EffectFlags(active: true) }
        s.microphoneMode = "Voice Isolation"
        #expect(s.activeNames() == [
            "Center Stage", "Portrait", "Studio Light", "Reactions", "Background Replacement", "Edge Light",
            "Low Light Noise Reduction", "Mic Mode: Voice Isolation",
        ])
        let issues = s.issues()
        #expect(issues.last?.id == "camera.mic_mode")
        #expect(issues.last?.severity == .warning)
        // The recorder turns this filter off itself; the user cannot clear it, so it only warns.
        #expect(issues.first { $0.id == "camera.effect.low_light_noise_reduction" }?.severity == .warning)
        #expect(issues.first { $0.id == "camera.effect.edge_light" }?.severity == .blocker)
    }

    @Test func slugsAndMicModeNames() {
        #expect(VideoEffect.backgroundReplacement.slug == "background_replacement")
        #expect(VideoEffect.studioLight.slug == "studio_light")
        #expect(VideoEffectsSnapshot.microphoneModeName(.standard) == nil)
        #expect(VideoEffectsSnapshot.microphoneModeName(.voiceIsolation) == "Voice Isolation")
        #expect(VideoEffectsSnapshot.microphoneModeName(.wideSpectrum) == "Wide Spectrum")
    }

    @Test func nothingOnMeansNoIssues() {
        var s = VideoEffectsSnapshot()
        for effect in VideoEffect.allCases { s.flags[effect] = EffectFlags(enabled: false, supported: true) }
        #expect(s.activeNames().isEmpty)
        #expect(s.issues().isEmpty)
    }
}
