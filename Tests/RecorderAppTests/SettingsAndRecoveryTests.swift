import AppKit
import CoreGraphics
import Foundation
import Testing
import WindowTools
@testable import RecorderApp
@testable import RecorderCore

@Suite struct DeviceChoiceTests {
    @Test func storageRoundTrips() {
        for choice in [DeviceChoice.automatic, .none, .device(uid: "0x206000000fd90066")] {
            #expect(DeviceChoice(storage: choice.storage) == choice)
        }
        #expect(DeviceChoice(storage: nil) == .automatic)
        #expect(DeviceChoice(storage: "garbage") == .automatic)
        #expect(DeviceChoice(storage: "uid:") == .automatic)
    }

    @Test func resolve() {
        #expect(DeviceChoice.automatic.resolve { "auto-uid" } == "auto-uid")
        #expect(DeviceChoice.none.resolve { "auto-uid" } == nil)
        #expect(DeviceChoice.device(uid: "x").resolve { "auto-uid" } == "x")
    }

    @Test func frameRateStorage() {
        #expect(FrameRate(storage: "24000/1001") == .fps23_976)
        #expect(FrameRate(storage: FrameRate.fps47_952.storage) == .fps47_952)
        #expect(FrameRate(storage: "24") == nil)
        #expect(FrameRate(storage: "0/1") == nil)
        #expect(FrameRate(storage: nil) == nil)
    }
}

@MainActor
@Suite struct RecorderSettingsTests {
    func makeDefaults() -> (UserDefaults, String) {
        let name = "RecorderAppTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsMatchTheSpec() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        #expect(s.mode == .both)
        #expect(s.camera == .automatic && s.cameraAudio == .automatic && s.screenMic == .automatic)
        #expect(s.lastCameraFrameRate == .fps23_976)
        #expect(s.frameAnchors.isEmpty)
        #expect(s.hideParallelsToolbar && s.parallelsToolbarOffsetPt == 0)
        #expect(!s.cameraWindowOptionsShown && !s.screenOptionsShown)
        #expect(s.systemAudio && s.snapOnStart && s.dimOutsideFrame)
        #expect(!s.windowOnly && !s.showCameraPreview && !s.revealInFinder)
        #expect(s.codec == .hevc)
        #expect(s.cameraBitrateMbps == 60 && s.screenBitrateMbps == 30)
        #expect(s.outputFolder.path.hasSuffix("/Movies/TwinTake"))
        #expect(s.displayUUID == nil && s.framePresetID == nil)
    }

    @Test func changesPersist() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        s.mode = .screen
        s.camera = .device(uid: "cam")
        s.cameraAudio = .none
        s.lastCameraFrameRate = .fps29_97
        s.screenMic = .device(uid: "BuiltInMicrophoneDevice")
        s.frameAnchors = ["LAPTOP": "top"]
        s.hideParallelsToolbar = false
        s.parallelsToolbarOffsetPt = -3
        s.screenOptionsShown = true
        s.displayUUID = "DISPLAY-UUID"
        s.framePresetID = ScreenFramePreset.fullDisplay.id
        s.windowOnly = true
        s.codec = .proRes422LT
        s.screenBitrateMbps = 40
        s.outputFolder = URL(fileURLWithPath: "/Volumes/Media/Takes", isDirectory: true)

        let back = RecorderSettings(defaults: defaults)
        #expect(back.mode == .screen)
        #expect(back.camera == .device(uid: "cam"))
        #expect(back.cameraAudio == DeviceChoice.none)
        #expect(back.lastCameraFrameRate == .fps29_97)
        #expect(back.screenMic == .device(uid: "BuiltInMicrophoneDevice"))
        #expect(back.frameAnchors == ["LAPTOP": "top"])
        #expect(!back.hideParallelsToolbar && back.parallelsToolbarOffsetPt == -3)
        #expect(back.screenOptionsShown)
        #expect(back.displayUUID == "DISPLAY-UUID")
        #expect(back.framePresetID == "full-display")
        #expect(back.windowOnly)
        #expect(back.codec == .proRes422LT)
        #expect(back.screenBitrateMbps == 40)
        #expect(back.outputFolder.path == "/Volumes/Media/Takes")
        #expect(back.fingerprint == s.fingerprint)
    }

    @Test func fingerprintFollowsRecorderSettings() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        let before = s.fingerprint
        s.lastCameraFrameRate = .fps29_97
        #expect(s.fingerprint != before)
        let rate = s.fingerprint
        s.frameAnchors["LAPTOP"] = "top"
        #expect(s.fingerprint != rate)
        // The Parallels settings change a snap: a change clears the offered snap fix.
        let anchors = s.fingerprint
        s.hideParallelsToolbar.toggle()
        #expect(s.fingerprint != anchors)
        let hide = s.fingerprint
        s.parallelsToolbarOffsetPt = 2
        #expect(s.fingerprint != hide)
    }

    /// The camera Size/Rate pickers and the screen Rate picker are gone: their saved values are
    /// removed at launch and never apply. Everything else stays.
    @Test func oldRateAndSizePicksAreRemoved() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("1920x1080", forKey: "camera.resolution")
        defaults.set("30000/1001", forKey: "camera.frameRate")
        defaults.set("60000/1001", forKey: "screen.frameRate")
        defaults.set("screen", forKey: RecorderSettings.Key.mode)
        defaults.set("uid:cam", forKey: RecorderSettings.Key.camera)
        let s = RecorderSettings(defaults: defaults)
        for key in RecorderSettings.Key.retired { #expect(defaults.object(forKey: key) == nil, "\(key)") }
        #expect(s.mode == .screen && s.camera == .device(uid: "cam"))
        // The screen rate follows the camera from now on: 47.952 until a camera is seen.
        #expect(s.lastCameraFrameRate == .fps23_976)
        #expect(SessionRules.screenFrameRate(cameraSignalRate: nil, lastCameraRate: s.lastCameraFrameRate) == .fps47_952)
        // A second launch finds nothing to remove.
        _ = RecorderSettings(defaults: defaults)
        #expect(defaults.string(forKey: RecorderSettings.Key.camera) == "uid:cam")
    }

    @Test func frameAnchorDefaultsToTheBottomOfTheLaptop() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = RecorderSettings(defaults: defaults)
        let laptop = DisplayInfo(id: 1, uuid: "LAPTOP", name: "Built-in Retina Display", isBuiltin: true, isMain: true,
                                 boundsGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2,
                                 menuBarHeightPt: 37, refreshRate: 120)
        let monitor = DisplayInfo(id: 2, uuid: "PHILIPS", name: "PHL 279P1", isBuiltin: false, isMain: false,
                                  boundsGlobal: CGRect(x: 1512, y: -98, width: 1920, height: 1080), scale: 2,
                                  menuBarHeightPt: 24, refreshRate: 60)
        #expect(s.frameAnchor(for: laptop) == .bottom)
        #expect(s.frameAnchor(for: monitor) == .top)
        s.setFrameAnchor(.top, for: laptop)
        #expect(s.frameAnchor(for: laptop) == .top)
        #expect(s.frameAnchor(for: monitor) == .top)
        s.setFrameAnchor(.bottom, for: monitor)
        let back = RecorderSettings(defaults: defaults)
        #expect(back.frameAnchor(for: laptop) == .top && back.frameAnchor(for: monitor) == .bottom)
        // A value that is not an anchor is dropped.
        defaults.set(["LAPTOP": "middle"], forKey: RecorderSettings.Key.frameAnchors)
        #expect(RecorderSettings(defaults: defaults).frameAnchor(for: laptop) == .bottom)
    }

    @Test func toolbarOffsetIsClamped() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(40.0, forKey: RecorderSettings.Key.parallelsToolbarOffset)
        #expect(RecorderSettings(defaults: defaults).parallelsToolbarOffsetPt == 10)
        defaults.set(-40.0, forKey: RecorderSettings.Key.parallelsToolbarOffset)
        #expect(RecorderSettings(defaults: defaults).parallelsToolbarOffsetPt == -10)
        #expect(RecorderSettings.clampedToolbarOffset(.nan) == 0)
        #expect(RecorderSettings.clampedToolbarOffset(2.5) == 2.5)
    }
}

@Suite struct SessionRecoveryTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recovery-tests-\(UUID().uuidString)")
    }

    func session(in root: URL, name: String, status: SessionManifest.Status) throws -> SessionFolder {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = SessionFolder(url: url)
        var m = SessionManifest(mode: .both, recorder: RecorderInfo(name: "TwinTake", version: "0.1.0"))
        m.status = status
        try folder.writeManifest(m)
        return folder
    }

    @Test func marksOnlyUnfinishedSessions() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let crashed = try session(in: root, name: "2026-10-12_174000", status: .recording)
        let done = try session(in: root, name: "2026-10-12_180000", status: .complete)
        let active = try session(in: root, name: "2026-10-12_190000", status: .recording)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("derived-notes"), withIntermediateDirectories: true)

        let recovered = SessionRecovery.recoverInterrupted(in: root, skipping: [active.url])
        #expect(recovered.map(\.lastPathComponent) == ["2026-10-12_174000"])

        let fixed = try crashed.readManifest()
        #expect(fixed.status == .recovered)
        #expect(fixed.errors == [SessionRecovery.recoveredError])
        let events = try EventLog.read(crashed.eventsURL)
        #expect(events.map(\.type) == [.warning])
        #expect(events.first?.data?["source"] == "app")

        #expect(try done.readManifest().status == .complete)
        #expect(try active.readManifest().status == .recording)

        // A second launch finds nothing new.
        #expect(SessionRecovery.recoverInterrupted(in: root, skipping: [active.url]).isEmpty)
        #expect(try EventLog.read(crashed.eventsURL).count == 1)
    }

    @Test func missingRootIsFine() {
        #expect(SessionRecovery.recoverInterrupted(in: tempRoot()).isEmpty)
    }

    @Test func launchChecksOnlyTheSessionLeftInProgress() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "recovery-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let crashed = try session(in: root, name: "2026-10-12_174000", status: .recording)
        let other = try session(in: root, name: "2026-10-12_180000", status: .recording)
        #expect(SessionRecovery.takeInProgress(defaults: defaults) == nil)

        SessionRecovery.markInProgress(crashed.url, defaults: defaults)
        let pending = try #require(SessionRecovery.takeInProgress(defaults: defaults))
        #expect(pending.standardizedFileURL.path == crashed.url.standardizedFileURL.path)
        #expect(SessionRecovery.takeInProgress(defaults: defaults) == nil)
        #expect(SessionRecovery.recoverIfInterrupted(pending))
        #expect(try crashed.readManifest().status == .recovered)
        #expect(try other.readManifest().status == .recording)
        #expect(!SessionRecovery.recoverIfInterrupted(pending))

        SessionRecovery.markInProgress(other.url, defaults: defaults)
        SessionRecovery.clearInProgress(defaults: defaults)
        #expect(SessionRecovery.takeInProgress(defaults: defaults) == nil)
    }
}

@Suite struct PermissionPromptTests {
    @Test func promptsOncePerBuild() {
        #expect(PermissionCenter.shouldPrompt(askedFor: nil, build: "abc"))
        #expect(!PermissionCenter.shouldPrompt(askedFor: "abc", build: "abc"))
        // A rebuild has a new signature, and the old Bool flag reads back as "1".
        #expect(PermissionCenter.shouldPrompt(askedFor: "abc", build: "def"))
        #expect(PermissionCenter.shouldPrompt(askedFor: "1", build: "abc"))
        #expect(!PermissionCenter.buildID.isEmpty)
    }
}

@Suite struct MenuBarIconTests {
    @Test func widthIsStableWhileTimeTicks() {
        let a = MenuBarIcon.recording(elapsed: "0:07")
        let b = MenuBarIcon.recording(elapsed: "59:59")
        #expect(a.size == b.size)
        #expect(MenuBarIcon.recording(elapsed: "0:07", problem: true).size == a.size)
        #expect(!a.isTemplate)
        #expect(MenuBarIcon.recording(elapsed: "1:00:00").size.width > a.size.width)
    }
}
