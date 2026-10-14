import CoreGraphics
import Foundation
import Testing
@testable import RecorderApp
@testable import RecorderCore
import ScreenCapture
import WindowTools

@Suite struct DiskSpaceTests {
    let folder = URL(fileURLWithPath: "/tmp/TwinTake")

    /// Luke's Both mode: Cam Link 4K at 23.976 with HDMI audio, the laptop frame at 47.952 with
    /// the built-in mic and system audio.
    func both(_ codec: VideoCodec = .hevc) -> (CameraRecorderConfig, ScreenRecorderConfig) {
        let camera = CameraRecorderConfig(videoDeviceUID: "0x206000000fd90066", audioDeviceUID: "camlink-audio", codec: codec)
        let screen = ScreenRecorderConfig(displayID: 1, frameRectPt: CGRect(x: 4, y: 37, width: 1504, height: 846),
                                          outputPx: PixelSize(width: 3008, height: 1692),
                                          micDeviceUID: "BuiltInMicrophoneDevice", codec: codec)
        return (camera, screen)
    }

    var defaultRate: Double { let (c, s) = both(); return SessionRules.bytesPerSecond(camera: c, screen: s) }

    @Test func defaultsWriteAbout43GBAnHour() {
        // 60 + 30 Mbit/s of HEVC plus six channels of 24-bit 48 kHz PCM.
        #expect(abs(defaultRate * 3600 / 1e9 - 43.6) < 0.1)
        #expect(SessionRules.bytesPerSecond(camera: both().0, screen: nil) < defaultRate)
        #expect(SessionRules.bytesPerSecond(camera: nil, screen: nil) == 0)
    }

    @Test func proResIsEstimatedFromPixelsAndRate() {
        let (c, s) = both(.proRes422LT)
        let camera = SessionRules.videoBitsPerSecond(codec: .proRes422LT, bitrate: c.bitrate, width: 3840, height: 2160,
                                                     frameRate: .fps23_976)
        #expect(abs(camera / 1e6 - 328) < 2)
        let screen = SessionRules.videoBitsPerSecond(codec: .proRes422LT, bitrate: s.bitrate, width: 3008, height: 1692,
                                                     frameRate: .fps47_952)
        #expect(abs(screen / 1e6 - 403) < 2)
        // About 5.5 GB a minute together.
        #expect(abs(SessionRules.bytesPerSecond(camera: c, screen: s) * 60 / 1e9 - 5.5) < 0.1)
    }

    @Test func plentyOfSpaceHasNoIssue() {
        #expect(SessionRules.diskIssues(availableBytes: 200_000_000_000, bytesPerSecond: defaultRate, folder: folder).isEmpty)
    }

    @Test func underAnHourWarns() {
        let issues = SessionRules.diskIssues(availableBytes: 42_000_000_000, bytesPerSecond: defaultRate, folder: folder)
        #expect(issues.map(\.severity) == [.warning])
        #expect(issues[0].message.contains("42 GB"))
        #expect(issues[0].message.contains("about 55 min"))
    }

    @Test func underTenMinutesBlocks() {
        let issues = SessionRules.diskIssues(availableBytes: 4_200_000_000, bytesPerSecond: defaultRate, folder: folder)
        #expect(issues.map(\.severity) == [.blocker])
        #expect(issues[0].message.contains("4.2 GB"))
        // 9.5 GB is about 10.3 minutes at the defaults: a warning, not a blocker.
        #expect(SessionRules.diskIssues(availableBytes: 9_500_000_000, bytesPerSecond: defaultRate, folder: folder)
            .map(\.severity) == [.warning])
    }

    @Test func proResWith20GBFreeBlocks() {
        let (c, s) = both(.proRes422LT)
        let rate = SessionRules.bytesPerSecond(camera: c, screen: s)
        let issues = SessionRules.diskIssues(availableBytes: 20_000_000_000, bytesPerSecond: rate, folder: folder)
        #expect(issues.map(\.severity) == [.blocker])
        #expect(issues[0].message.contains("about 3 min"))
    }

    @Test func belowTheStopLevelAlwaysBlocks() {
        #expect(SessionRules.diskIssues(availableBytes: 1_900_000_000, bytesPerSecond: 0, folder: folder)
            .map(\.severity) == [.blocker])
        #expect(SessionRules.diskIssues(availableBytes: 3_000_000_000, bytesPerSecond: 0, folder: folder).isEmpty)
    }

    @Test func unknownSpaceWarns() {
        #expect(SessionRules.diskIssues(availableBytes: nil, bytesPerSecond: defaultRate, folder: folder)
            .map(\.severity) == [.warning])
    }

    @Test func whileRecordingWarnThenStopBeforeTheCameraLimit() {
        let rate = defaultRate
        #expect(SessionRules.diskAction(freeBytes: 10_000_000_000, bytesPerSecond: rate) == .none)
        // 3 GB is 1 GB above the stop level: about 1.4 min at the defaults.
        #expect(SessionRules.diskAction(freeBytes: 3_000_000_000, bytesPerSecond: rate) == .warn(minutesLeft: 2))
        #expect(SessionRules.diskAction(freeBytes: 2_000_000_000, bytesPerSecond: rate) == .stop)
        // The camera stops itself at 1 GiB; the app must stop first.
        #expect(SessionRules.recordingStopBytes > 1 << 30)
    }

    @Test func freeSpaceReadsTheVolume() {
        let dir = FileManager.default.temporaryDirectory
        let conservative = SessionFolder.conservativeFreeSpace(at: dir)
        #expect(conservative != nil)
        if let conservative, let important = SessionFolder.availableCapacity(at: dir) {
            #expect(conservative <= important)
        }
    }

    @Test func missingFolderIsMeasuredAtItsParent() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)/deeper")
        #expect(FileManager.default.fileExists(atPath: SessionRules.existingAncestor(of: missing).path))
        #expect(SessionRules.availableCapacity(for: missing) != nil)
        // Preflight counts what the in-take check counts (no purgeable space).
        let parent = SessionRules.existingAncestor(of: missing)
        if let preflight = SessionRules.availableCapacity(for: missing),
           let conservative = SessionFolder.conservativeFreeSpace(at: parent) {
            #expect(abs(preflight - conservative) < 1_000_000_000)
        }
        // A folder that does not exist yet on a writable disk is fine.
        #expect(SessionRules.folderIssue(for: missing) == nil)
    }

    /// The output folder's disk is not connected (/Volumes/T7/TwinTake with the T7 unplugged):
    /// its nearest existing parent is /Volumes, whose free space is the boot disk's. Start would
    /// fail to create the folder, so preflight blocks it. A parent TwinTake cannot write to blocks too.
    @Test func aFolderOnAMissingDiskBlocksStart() throws {
        let t7 = URL(fileURLWithPath: "/Volumes/T7/TwinTake")
        let missing = try #require(SessionRules.folderIssue(folder: t7, existingAncestor: URL(fileURLWithPath: "/Volumes"),
                                                            ancestorWritable: false))
        #expect(missing.id == "app.folder_missing" && missing.severity == .blocker)
        #expect(missing.message.hasPrefix("The disk T7 is not connected"))
        #expect(SessionRules.folderIssue(folder: t7, existingAncestor: URL(fileURLWithPath: "/Volumes/T7"),
                                         ancestorWritable: true) == nil)
        let locked = try #require(SessionRules.folderIssue(folder: URL(fileURLWithPath: "/Recordings/TwinTake"),
                                                           existingAncestor: URL(fileURLWithPath: "/"), ancestorWritable: false))
        #expect(locked.id == "app.folder_not_writable" && locked.severity == .blocker)
        // The real check, on a disk that is surely missing.
        let gone = URL(fileURLWithPath: "/Volumes/no-such-disk-\(UUID().uuidString)/TwinTake")
        #expect(SessionRules.folderIssue(for: gone)?.id == "app.folder_missing")
    }

    /// A start cancelled before the files began wrote only session.json and events.jsonl.
    @Test func aCancelledStartHoldsOnlyItsStartFiles() {
        #expect(SessionRules.holdsOnlyStartFiles(["session.json", "events.jsonl"]))
        #expect(SessionRules.holdsOnlyStartFiles([]))
        #expect(!SessionRules.holdsOnlyStartFiles(["session.json", "events.jsonl", "camera.mov"]))
        #expect(!SessionRules.holdsOnlyStartFiles(["notes.txt"]))
    }
}

@Suite struct DialogueTests {
    func track(_ file: String, _ index: Int, _ role: TrackInfo.Role) -> TrackInfo {
        TrackInfo(file: file, trackIndex: index, role: role, dialogue: false)
    }

    var both: [TrackInfo] {
        [track(SessionFolder.cameraFileName, 0, .cameraVideo), track(SessionFolder.cameraFileName, 1, .mic),
         track(SessionFolder.screenFileName, 0, .screenVideo), track(SessionFolder.screenFileName, 1, .mic),
         track(SessionFolder.screenFileName, 2, .systemAudio)]
    }

    @Test func cameraMicWinsWhenTheCameraIsRecorded() {
        let out = SessionRules.assigningDialogue(both)
        #expect(out.filter(\.dialogue).count == 1)
        #expect(out[1].dialogue && out[1].file == SessionFolder.cameraFileName)
    }

    @Test func screenMicWhenCameraHasNoAudio() {
        let tracks = both.filter { !($0.file == SessionFolder.cameraFileName && $0.role == .mic) }
        let out = SessionRules.assigningDialogue(tracks)
        #expect(out.filter(\.dialogue).map(\.file) == [SessionFolder.screenFileName])
        #expect(out.first(where: \.dialogue)?.role == .mic)
    }

    @Test func screenOnlySessionUsesTheScreenMic() {
        let out = SessionRules.assigningDialogue(Array(both.suffix(3)))
        #expect(out.filter(\.dialogue).count == 1)
        #expect(out[1].dialogue)
    }

    @Test func noMicMeansNoDialogueTrack() {
        var stale = track(SessionFolder.screenFileName, 1, .systemAudio)
        stale.dialogue = true
        let out = SessionRules.assigningDialogue([track(SessionFolder.screenFileName, 0, .screenVideo), stale])
        #expect(out.allSatisfy { !$0.dialogue })
    }
}

@Suite struct FinishTests {
    func manifest() -> SessionManifest {
        var m = SessionManifest(mode: .both, recorder: RecorderInfo(name: "TwinTake", version: "0.1.0"))
        m.startedAtHostNs = 1_000_000_000
        return m
    }

    @Test func syncCheckNeedsAMicInBothFiles() {
        #expect(SessionRules.syncCheck(cameraHasMic: true, screenHasMic: true) == "shared_voice")
        #expect(SessionRules.syncCheck(cameraHasMic: true, screenHasMic: false) == "none")
        #expect(SessionRules.syncCheck(cameraHasMic: false, screenHasMic: true) == "none")
        var m = manifest()
        SessionRules.finish(&m, results: [RecorderResult(tracks: [
            TrackInfo(file: SessionFolder.screenFileName, trackIndex: 0, role: .screenVideo, dialogue: false),
            TrackInfo(file: SessionFolder.screenFileName, trackIndex: 1, role: .systemAudio, dialogue: false),
        ])], stoppedAtHostNs: 2_000_000_000)
        #expect(m.sync.check == "none")
        #expect(m.tracks.allSatisfy { !$0.dialogue })
    }

    @Test func completeSessionSortsTracksAndSetsTiming() {
        var m = manifest()
        let screen = RecorderResult(tracks: [
            TrackInfo(file: SessionFolder.screenFileName, trackIndex: 1, role: .mic, dialogue: false),
            TrackInfo(file: SessionFolder.screenFileName, trackIndex: 0, role: .screenVideo, dialogue: false),
        ])
        let camera = RecorderResult(tracks: [
            TrackInfo(file: SessionFolder.cameraFileName, trackIndex: 0, role: .cameraVideo, dialogue: false),
            TrackInfo(file: SessionFolder.cameraFileName, trackIndex: 1, role: .mic, dialogue: false),
        ])
        SessionRules.finish(&m, results: [screen, camera], stoppedAtHostNs: 61_500_000_000)
        #expect(m.status == .complete)
        #expect(m.tracks.map(\.file) == [SessionFolder.cameraFileName, SessionFolder.cameraFileName,
                                         SessionFolder.screenFileName, SessionFolder.screenFileName])
        #expect(m.tracks.map(\.trackIndex) == [0, 1, 0, 1])
        #expect(m.tracks.filter(\.dialogue).count == 1 && m.tracks[1].dialogue)
        #expect(m.durationS == 60.5)
        #expect(m.stoppedAtHostNs == 61_500_000_000)
        #expect(m.sync.check == "shared_voice")
    }

    @Test func errorsMakeTheSessionFailed() {
        var m = manifest()
        SessionRules.finish(&m, results: [RecorderResult(errors: ["Cam Link 4K was disconnected."])],
                            extraErrors: ["Camera: could not start"], stoppedAtHostNs: 2_000_000_000)
        #expect(m.status == .failed)
        #expect(m.errors == ["Camera: could not start", "Cam Link 4K was disconnected."])
    }

    @Test func noStartTimeLeavesDurationEmpty() {
        var m = SessionManifest(mode: .camera, recorder: RecorderInfo(name: "TwinTake", version: "0.1.0"))
        SessionRules.finish(&m, results: [], stoppedAtHostNs: 5)
        #expect(m.durationS == nil)
        #expect(m.status == .complete)
    }
}

@Suite struct FormattingTests {
    @Test func elapsed() {
        #expect(SessionRules.elapsedString(7.9) == "0:07")
        #expect(SessionRules.elapsedString(754) == "12:34")
        #expect(SessionRules.elapsedString(3723) == "1:02:03")
        #expect(SessionRules.elapsedString(-3) == "0:00")
    }

    @Test func shortFormatDropsThePixelFormat() {
        #expect(SessionRules.shortFormat("3840x2160 420v 23.976") == "3840×2160 23.976")
        #expect(SessionRules.shortFormat("1920x1080") == "1920×1080")
    }

    @Test func gigabytes() {
        #expect(SessionRules.gigabytes(4_249_000_000) == "4.2 GB")
        #expect(SessionRules.gigabytes(120_400_000_000) == "120 GB")
    }

    @Test func mergedPutsBlockersFirstAndDropsRepeats() {
        let w = PreflightIssue(id: "a", severity: .warning, message: "w")
        let b = PreflightIssue(id: "b", severity: .blocker, message: "b")
        let again = PreflightIssue(id: "a", severity: .blocker, message: "again")
        #expect(SessionRules.merged([w, b, again]).map(\.id) == ["b", "a"])
        #expect(SessionRules.blockers([w, b]).map(\.id) == ["b"])
    }
}

@Suite struct SnapTargetTests {
    func display(menuBar: CGFloat, width: CGFloat = 1920, height: CGFloat = 1080) -> DisplayInfo {
        DisplayInfo(id: 2, uuid: "U", name: "PHL", isBuiltin: false, isMain: true,
                    boundsGlobal: CGRect(x: 0, y: 0, width: width, height: height), scale: 2,
                    menuBarHeightPt: menuBar, refreshRate: 60)
    }

    func plan(_ d: DisplayInfo, _ preset: ScreenFramePreset) -> ScreenPlan {
        ScreenPlan(display: d, preset: preset,
                   config: ScreenRecorderConfig(displayID: d.id, frameRectPt: d.frameRect(for: preset),
                                                outputPx: d.outputPixels(for: preset), micDeviceUID: nil),
                   frameGlobal: d.globalFrameRect(for: preset))
    }

    @Test func wholeDisplaySnapsBelowTheMenuBar() {
        let p = plan(display(menuBar: 30), .fullDisplay)
        #expect(p.frameGlobal == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(p.snapTarget == CGRect(x: 0, y: 30, width: 1920, height: 1050))
    }

    @Test func wholeDisplayWithoutMenuBarSnapsToTheFrame() {
        let p = plan(display(menuBar: 0), .fullDisplay)
        #expect(p.snapTarget == p.frameGlobal)
    }

    @Test func laptopFrameIsAlreadyBelowTheMenuBar() {
        let p = plan(display(menuBar: 37, width: 1512, height: 982), .laptop16x9)
        #expect(p.frameGlobal == CGRect(x: 4, y: 37, width: 1504, height: 846))
        #expect(p.snapTarget == p.frameGlobal)
    }
}

@Suite struct RecordingRulesTests {
    @Test func snapWhileRecordingInRegionModeReplacesTheSnap() {
        #expect(SessionRules.snapReplacesRecordedSnap(foundWindow: true, snappedWindowID: 456, recordedWindowID: nil))
        // A failed snap (full screen, no window) keeps the old snap and its monitor.
        #expect(!SessionRules.snapReplacesRecordedSnap(foundWindow: false, snappedWindowID: nil, recordedWindowID: nil))
    }

    @Test func windowOnlyKeepsTheRecordedWindow() {
        #expect(!SessionRules.snapReplacesRecordedSnap(foundWindow: true, snappedWindowID: 456, recordedWindowID: 123))
        #expect(SessionRules.snapReplacesRecordedSnap(foundWindow: true, snappedWindowID: 123, recordedWindowID: 123))
        #expect(!SessionRules.snapReplacesRecordedSnap(foundWindow: true, snappedWindowID: nil, recordedWindowID: 123))
    }

    /// The preview opens only the camera (its graph holds no audio input), so only the camera
    /// permission can block it; Start checks the microphone permission.
    @Test func previewNeverPromptsForAccess() {
        #expect(SessionRules.previewBlockedMessage(camera: .granted) == nil)
        #expect(SessionRules.previewBlockedMessage(camera: .notDetermined)?.contains("Permissions > Camera") == true)
        #expect(SessionRules.previewBlockedMessage(camera: .denied)?.contains("System Settings") == true)
        #expect(SessionRules.previewBlockedMessage(camera: .notGranted) != nil)
    }

    @Test func closedLidWarnsAboutTheBuiltInMic() {
        let builtIn = CaptureDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", kind: .audio, isBuiltIn: true)
        let devices = [
            CaptureDeviceInfo(uid: "usb-audio", name: "USB Audio Device", kind: .audio, isBuiltIn: false),
            builtIn,
            CaptureDeviceInfo(uid: "camlink-audio", name: "Cam Link 4K", kind: .audio, isBuiltIn: false),
            CaptureDeviceInfo(uid: "caldigit", name: "CalDigit Thunderbolt 3 Audio", kind: .audio, isBuiltIn: false),
        ]
        let issue = SessionRules.closedLidMicIssue(mic: builtIn, lidClosed: true, audioDevices: devices,
                                                   cameraAudioUID: "camlink-audio")
        #expect(issue?.severity == .warning)
        #expect(issue?.message.contains("MacBook Pro Microphone records silence") == true)
        #expect(issue?.message.contains("USB Audio Device, CalDigit Thunderbolt 3 Audio") == true)
        #expect(issue?.message.contains("Cam Link") == false)
        #expect(SessionRules.closedLidMicIssue(mic: builtIn, lidClosed: false, audioDevices: devices, cameraAudioUID: nil) == nil)
        #expect(SessionRules.closedLidMicIssue(mic: devices[0], lidClosed: true, audioDevices: devices, cameraAudioUID: nil) == nil)
    }
}
