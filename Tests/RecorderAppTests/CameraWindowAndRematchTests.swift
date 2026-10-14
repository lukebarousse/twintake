import CoreGraphics
import Foundation
import Testing
@testable import RecorderApp
@testable import RecorderCore
import WindowTools

private let oldCamLink = "0x206000000fd90066"
private let newCamLink = "0x22000000fd90066"
private let camLinkModel = "UVC Camera VendorID_4057 ProductID_102"

private func camera(_ uid: String, _ name: String = "Cam Link 4K", model: String? = camLinkModel) -> CaptureDeviceInfo {
    CaptureDeviceInfo(uid: uid, name: name, kind: .video, isBuiltIn: false, detail: "3840x2160 23.976", modelID: model)
}

private func audio(_ uid: String, _ name: String) -> CaptureDeviceInfo {
    CaptureDeviceInfo(uid: uid, name: name, kind: .audio, isBuiltIn: false)
}

@Suite struct DeviceRematchTests {
    let saved = SavedDevice(uid: oldCamLink, name: "Cam Link 4K", modelID: camLinkModel)
    let facetime = CaptureDeviceInfo(uid: "facetime", name: "MacBook Pro Camera", kind: .video, isBuiltIn: true, modelID: "FaceTime")

    @Test func aConnectedPickNeedsNothing() {
        #expect(DeviceRematch.resolve(saved, in: [facetime, camera(oldCamLink)], role: .camera) == .present)
    }

    /// Luke's case: the Cam Link moved to another USB port, so its uid changed.
    @Test func theCamLinkOnANewPortIsFoundByNameAndModel() {
        let outcome = DeviceRematch.resolve(saved, in: [facetime, camera(newCamLink)], role: .camera)
        #expect(outcome == .moved(SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel)))
        if case let .moved(found) = outcome {
            #expect(DeviceRematch.movedNotice(found, role: .camera) == "Cam Link 4K moved to a new USB port; reconnected.")
        }
    }

    @Test func anotherModelWithTheSameNameIsNotTheSameCamera() {
        #expect(DeviceRematch.resolve(saved, in: [camera(newCamLink, model: "Other model")], role: .camera) == .missing)
        // A device that reports no model matches on the name alone.
        #expect(DeviceRematch.resolve(saved, in: [camera(newCamLink, model: nil)], role: .camera)
            == .moved(SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel)))
    }

    /// Luke's glitch: after an HDMI change the Cam Link came back on its USB 2 lane as product
    /// 0x0067 (ProductID_103) on a new uid. It is still the picked camera, so the USB 2 banner can
    /// show; the replug back to 0x0066 is found again the same way.
    @Test func theCamLinkOnItsUSB2LaneIsTheSameCamera() {
        let usb2Uid = "0x22100000fd90067", usb2Model = "UVC Camera VendorID_4057 ProductID_103"
        let moved = DeviceRematch.resolve(saved, in: [facetime, camera(usb2Uid, model: usb2Model)], role: .camera)
        #expect(moved == .moved(SavedDevice(uid: usb2Uid, name: "Cam Link 4K", modelID: usb2Model)))
        let onUSB2 = SavedDevice(uid: usb2Uid, name: "Cam Link 4K", modelID: usb2Model)
        #expect(DeviceRematch.resolve(onUSB2, in: [camera(newCamLink)], role: .camera)
            == .moved(SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel)))
        // Another maker's camera with the same name is still not it.
        #expect(DeviceRematch.resolve(saved, in: [camera(newCamLink, model: "UVC Camera VendorID_1133 ProductID_102")],
                                      role: .camera) == .missing)
        #expect(DeviceRematch.modelFamily(camLinkModel) == "UVC Camera VendorID_4057")
        #expect(DeviceRematch.modelFamily("FaceTime") == "FaceTime")
        #expect(DeviceRematch.modelFamily("ProductID_102") == "ProductID_102")
    }

    @Test func twoMatchesAreNeverGuessed() {
        let outcome = DeviceRematch.resolve(saved, in: [camera(newCamLink), camera("0x14000000fd90066")], role: .camera)
        #expect(outcome == .ambiguous(count: 2))
        #expect(DeviceRematch.ambiguousNotice(saved, count: 2, role: .camera)
            == "Cam Link 4K is not connected, and 2 devices have that name. Pick one under Camera > Device.")
    }

    @Test func nothingWithTheNameIsMissing() {
        #expect(DeviceRematch.resolve(saved, in: [facetime], role: .camera) == .missing)
        #expect(DeviceRematch.resolve(saved, in: [], role: .camera) == .missing)
        let unnamed = SavedDevice(uid: oldCamLink, name: "  ")
        #expect(DeviceRematch.resolve(unnamed, in: [camera(newCamLink, " ")], role: .camera) == .missing)
    }

    @Test func cameraAudioAndScreenMicMatchOnTheName() {
        let old = "AppleUSBAudioEngine:Elgato:Cam Link 4K:0004530C6F000:2"
        let new = "AppleUSBAudioEngine:Elgato:Cam Link 4K:0004530C6F000:3"
        let savedAudio = SavedDevice(uid: old, name: "Cam Link 4K")
        let mic = audio("BuiltInMicrophoneDevice", "MacBook Pro Microphone")
        let outcome = DeviceRematch.resolve(savedAudio, in: [mic, audio(new, "Cam Link 4K")], role: .cameraAudio)
        #expect(outcome == .moved(SavedDevice(uid: new, name: "Cam Link 4K")))
        #expect(DeviceRematch.movedNotice(SavedDevice(uid: new, name: "Cam Link 4K"), role: .cameraAudio)
            == "Cam Link 4K audio moved to a new USB port; reconnected.")

        let savedMic = SavedDevice(uid: "AppleUSBAudioEngine:Shure:MV7:1", name: "Shure MV7")
        #expect(DeviceRematch.resolve(savedMic, in: [mic, audio("AppleUSBAudioEngine:Shure:MV7:2", "Shure MV7")], role: .screenMic)
            == .moved(SavedDevice(uid: "AppleUSBAudioEngine:Shure:MV7:2", name: "Shure MV7")))
    }

    /// Two Cam Links: A is picked, B is connected next to it. Unplugging A never switches to B.
    @Test func aTwinThatWasConnectedNextToThePickIsNeverTaken() throws {
        let a = camera(oldCamLink), b = camera("0x14000000fd90066")
        let both = [facetime, a, b]
        let saved = DeviceRematch.identity(of: .device(uid: oldCamLink), in: both, role: .camera)
        #expect(saved?.others == ["0x14000000fd90066"])
        let pick = try #require(saved)
        // A unplugged: B is a known other device.
        #expect(DeviceRematch.resolve(pick, in: [facetime, b], role: .camera) == .missing)
        // A back on a new port: found, and B stays a known other device.
        #expect(DeviceRematch.resolve(pick, in: [facetime, b, camera(newCamLink)], role: .camera)
            == .moved(SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel, others: ["0x14000000fd90066"])))
    }

    @Test func knownOtherDevicesAddUpWhileTheUidStays() throws {
        let first = try #require(DeviceRematch.identity(of: .device(uid: oldCamLink),
                                                         in: [camera(oldCamLink), camera("b")], role: .camera))
        // B unplugged, C plugged in: B is still a known other device.
        let next = DeviceRematch.identity(of: .device(uid: oldCamLink), in: [camera(oldCamLink), camera("c")],
                                          role: .camera, previous: first)
        #expect(next?.others == ["b", "c"])
        // A save for another uid starts over.
        let other = DeviceRematch.identity(of: .device(uid: "c"), in: [camera("c")], role: .camera, previous: first)
        #expect(other?.others == [])
        // Devices with another name are not counted.
        #expect(DeviceRematch.identity(of: .device(uid: oldCamLink), in: [camera(oldCamLink), facetime],
                                       role: .camera)?.others == [])
    }

    /// Only a USB audio input can move to a new uid. A Bluetooth or built-in input keeps its uid,
    /// so another input with its name is another device.
    @Test func audioRematchNeedsTheSameUSBMakerAndProduct() {
        let airPods = SavedDevice(uid: "00-11-22-33-44-55:input", name: "AirPods Pro")
        #expect(DeviceRematch.resolve(airPods, in: [audio("66-77-88-99-AA-BB:input", "AirPods Pro")], role: .screenMic)
            == .missing)
        let codec = SavedDevice(uid: "AppleUSBAudioEngine:Generic:USB Audio CODEC:1100000:1", name: "USB Audio CODEC")
        #expect(DeviceRematch.resolve(codec, in: [audio("AppleUSBAudioEngine:Other:USB Audio CODEC:1200000:1", "USB Audio CODEC")],
                                      role: .screenMic) == .missing)
        #expect(DeviceRematch.resolve(codec, in: [audio("AppleUSBAudioEngine:Generic:USB Audio CODEC:1200000:1", "USB Audio CODEC")],
                                      role: .screenMic)
            == .moved(SavedDevice(uid: "AppleUSBAudioEngine:Generic:USB Audio CODEC:1200000:1", name: "USB Audio CODEC")))
        #expect(DeviceRematch.usbAudioProduct("AppleUSBAudioEngine:Elgato:Cam Link 4K:0004530C6F000:2")
            == "AppleUSBAudioEngine:Elgato:Cam Link 4K")
        #expect(DeviceRematch.usbAudioProduct("BuiltInMicrophoneDevice") == nil)
        #expect(DeviceRematch.usbAudioProduct("AppleUSBAudioEngine:Elgato") == nil)
    }

    @Test func onlyAConnectedFixedPickIsSaved() {
        let devices = [facetime, camera(newCamLink)]
        #expect(DeviceRematch.identity(of: .automatic, in: devices, role: .camera) == nil)
        #expect(DeviceRematch.identity(of: .none, in: devices, role: .camera) == nil)
        #expect(DeviceRematch.identity(of: .device(uid: oldCamLink), in: devices, role: .camera) == nil)
        #expect(DeviceRematch.identity(of: .device(uid: newCamLink), in: devices, role: .camera)
            == SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel))
        // Audio picks save no model.
        let input = CaptureDeviceInfo(uid: "in", name: "Cam Link 4K", kind: .audio, isBuiltIn: false, modelID: "x")
        #expect(DeviceRematch.identity(of: .device(uid: "in"), in: [input], role: .cameraAudio)?.modelID == nil)
    }

    @Test func savedDeviceStorageRoundTrips() {
        #expect(SavedDevice(storage: saved.storage) == saved)
        let noModel = SavedDevice(uid: "u", name: "n")
        #expect(noModel.storage["model"] == nil)
        #expect(SavedDevice(storage: noModel.storage) == noModel)
        #expect(noModel.storage["others"] == nil)
        let twins = SavedDevice(uid: "u", name: "Cam Link 4K", modelID: camLinkModel, others: ["0x1", "0x2"])
        #expect(SavedDevice(storage: twins.storage) == twins)
        #expect(SavedDevice(storage: nil) == nil)
        #expect(SavedDevice(storage: ["name": "Cam Link 4K"]) == nil)
        #expect(SavedDevice(storage: ["uid": "", "name": "Cam Link 4K"]) == nil)
    }
}

@MainActor
@Suite struct CameraWindowSettingsTests {
    func makeDefaults() -> (UserDefaults, String) {
        let name = "CameraWindowSettingsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        #expect(!s.cameraWindowShown)
        #expect(s.cameraWindowMirrored)
        #expect(s.cameraWindowWhileRecording)
        #expect(s.previewWhileRecording)
        #expect(s.cameraWindowFrames.isEmpty)
        #expect(s.cameraWindowLastDisplay == nil)
        #expect(s.cameraIdentity == nil && s.cameraAudioIdentity == nil && s.screenMicIdentity == nil)
    }

    @Test func changesPersist() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        s.cameraWindowShown = true
        s.cameraWindowMirrored = false
        s.cameraWindowWhileRecording = false
        s.previewWhileRecording = false
        s.cameraWindowFrames = ["LAPTOP": CGRect(x: 1016, y: 86, width: 480, height: 270),
                                "PHILIPS": CGRect(x: 40, y: 40, width: 640, height: 360)]
        s.cameraWindowLastDisplay = "PHILIPS"
        s.setIdentity(SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel), .camera)
        s.setIdentity(SavedDevice(uid: "a", name: "Cam Link 4K"), .cameraAudio)
        s.setIdentity(SavedDevice(uid: "m", name: "MacBook Pro Microphone"), .screenMic)

        let back = RecorderSettings(defaults: defaults)
        #expect(back.cameraWindowShown)
        #expect(!back.cameraWindowMirrored)
        #expect(!back.cameraWindowWhileRecording)
        #expect(!back.previewWhileRecording)
        #expect(back.cameraWindowFrames == s.cameraWindowFrames)
        #expect(back.cameraWindowLastDisplay == "PHILIPS")
        #expect(back.identity(.camera) == SavedDevice(uid: newCamLink, name: "Cam Link 4K", modelID: camLinkModel))
        #expect(back.identity(.cameraAudio) == SavedDevice(uid: "a", name: "Cam Link 4K"))
        #expect(back.identity(.screenMic)?.uid == "m")

        back.setIdentity(nil, .camera)
        #expect(RecorderSettings(defaults: defaults).cameraIdentity == nil)
    }

    @Test func choicesByRole() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        s.setChoice(.device(uid: newCamLink), .camera)
        s.setChoice(.none, .cameraAudio)
        s.setChoice(.device(uid: "m"), .screenMic)
        #expect(s.camera == .device(uid: newCamLink) && s.choice(.camera) == s.camera)
        #expect(s.cameraAudio == DeviceChoice.none && s.choice(.cameraAudio) == s.cameraAudio)
        #expect(s.screenMic == .device(uid: "m") && s.choice(.screenMic) == s.screenMic)
    }
}

@Suite struct CameraWindowPhaseTests {
    let s: UInt64 = 1_000_000_000

    func phase(_ stage: RecordingStage, kept: Bool?, last: UInt64?, now: UInt64, camera: Bool = true) -> PreviewPhase {
        PreviewRules.recordingPhase(stage: stage, recordsCamera: camera, previewKept: kept, lastFrameNs: last,
                                    sinceNs: 10 * s, nowNs: now)
    }

    @Test func liveWhileThePreviewOutputStays() {
        #expect(phase(.recording, kept: true, last: 20 * s, now: 20 * s + s / 2) == .live)
        // Frames stopped (HDMI pulled): no picture.
        #expect(phase(.recording, kept: true, last: 20 * s, now: 23 * s) == .noPicture)
    }

    @Test func pausedWhenStartRemovedTheOutput() {
        #expect(phase(.recording, kept: false, last: 20 * s, now: 20 * s) == .paused)
        #expect(PreviewPhase.paused.message == "Live picture is off while recording. It comes back after Stop.")
    }

    /// Live picture while recording is on, but the camera window was off at Start: the take has no
    /// preview output, and the window says why instead of blaming the setting.
    @Test func theWindowSaysItWasOffAtStart() {
        let phase = PreviewRules.recordingPhase(stage: .recording, recordsCamera: true, previewKept: false, lastFrameNs: nil,
                                                sinceNs: 10 * s, nowNs: 20 * s, livePictureOn: true)
        #expect(phase == .pausedWindowOffAtStart)
        #expect(phase.message == "The camera window was off at Start, so this take has no live picture. It comes back after Stop.")
    }

    @Test func startingShowsThePreviewCameraUntilTheFileStarts() {
        #expect(phase(.starting, kept: nil, last: 11 * s, now: 11 * s) == .live)
        // Frames from before Start do not count; none yet: opening.
        #expect(phase(.starting, kept: nil, last: 5 * s, now: 10 * s + 1) == .opening)
        #expect(phase(.starting, kept: nil, last: nil, now: 11 * s) == .opening)
        #expect(phase(.recording, kept: nil, last: nil, now: 11 * s) == .opening)
    }

    @Test func savingNeverClaimsTheCameraLostItsPicture() {
        #expect(phase(.stopping, kept: true, last: 30 * s, now: 30 * s) == .live)
        #expect(phase(.stopping, kept: true, last: 30 * s, now: 40 * s) == .opening)
    }

    /// Live picture while recording was off: the window says so until Stop takes the camera back to
    /// its preview graph (`previewDuringRecording` is nil again), then shows the picture while the
    /// take still saves.
    @Test func savingShowsThePictureOnceTheCameraIsBackOnItsPreviewGraph() {
        #expect(phase(.stopping, kept: false, last: nil, now: 30 * s) == .paused)
        #expect(phase(.stopping, kept: nil, last: 30 * s, now: 30 * s + s / 2) == .live)
    }

    @Test func screenModeHasNoCamera() {
        #expect(phase(.recording, kept: nil, last: nil, now: 11 * s, camera: false) == .blocked(PreviewRules.screenModeMessage))
    }

    /// Stop releases the camera recorder before its teardown ends; the window must not then claim
    /// the take records no camera.
    @Test func savingWithTheRecorderReleasedIsNotScreenMode() {
        #expect(PreviewRules.takeRecordsCamera(stage: .stopping, hasRecorder: false))
        #expect(PreviewRules.takeRecordsCamera(stage: .starting, hasRecorder: false))
        #expect(!PreviewRules.takeRecordsCamera(stage: .recording, hasRecorder: false))
        #expect(PreviewRules.takeRecordsCamera(stage: .recording, hasRecorder: true))
        let saving = phase(.stopping, kept: nil, last: 30 * s, now: 40 * s,
                           camera: PreviewRules.takeRecordsCamera(stage: .stopping, hasRecorder: false))
        #expect(saving == .opening)
    }

    /// With Keep the camera window on while recording off, a take hides the window; the hotkey then
    /// changes nothing and says why.
    @Test func aTakeHidesTheWindowOnlyWhenKeepIsOff() {
        #expect(PreviewRules.windowHiddenByTake(idle: false, keepWhileRecording: false))
        #expect(!PreviewRules.windowHiddenByTake(idle: false, keepWhileRecording: true))
        #expect(!PreviewRules.windowHiddenByTake(idle: true, keepWhileRecording: false))
    }
}

@Suite struct OwnWindowsAreNeverRecordedTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theRegionCaptureExcludesTwinTake() {
        #expect(SessionRules.excludedBundleIDs(mainBundleID: "com.lukebarousse.twintake") == ["com.lukebarousse.twintake"])
        // Unbundled (`swift run`) or under a test runner: TwinTake's id is still in the list.
        #expect(SessionRules.excludedBundleIDs(mainBundleID: nil) == ["com.lukebarousse.twintake"])
        #expect(SessionRules.excludedBundleIDs(mainBundleID: "com.apple.dt.xctest.tool")
            == ["com.lukebarousse.twintake", "com.apple.dt.xctest.tool"])
    }

    @Test func theExcludedIDIsTheAppsBundleID() throws {
        let plist = Self.root.appendingPathComponent("App/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        #expect(info["CFBundleIdentifier"] as? String == SessionRules.appBundleID)
    }

    /// The plan the coordinator builds passes the list to the screen recorder, and the region
    /// filter leaves those apps (and this process) out.
    @Test func thePlanAndTheFilterUseTheList() throws {
        let coordinator = try String(contentsOf: Self.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift"),
                                     encoding: .utf8)
        #expect(coordinator.contains("excludedBundleIDs: SessionRules.excludedBundleIDs(mainBundleID: Bundle.main.bundleIdentifier)"))
        let recorder = try String(contentsOf: Self.root.appendingPathComponent("Sources/ScreenCapture/ScreenRecorder.swift"),
                                  encoding: .utf8)
        #expect(recorder.contains("SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])"))
        #expect(recorder.contains("excludedBundleIDs: config.excludedBundleIDs, ownProcessID: ownProcess"))
    }
}
