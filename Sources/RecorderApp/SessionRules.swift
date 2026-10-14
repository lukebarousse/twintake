import CameraCapture
import CoreGraphics
import Foundation
import RecorderCore
import WindowTools

/// The session rules that need no device: disk space, the one dialogue track, the final
/// manifest. Kept apart from the coordinator so they can be tested.
enum SessionRules {
    /// While recording, both recorders stop at this much free space, so both files end together
    /// and session.json and events.jsonl still have room. (AVAssetWriter has no limit of its own.)
    static let recordingStopBytes: Int64 = 2_000_000_000
    /// Start is blocked with less recording time than this left on the disk.
    static let diskBlockerMinutes = 10.0
    /// Start warns with less recording time than this left on the disk.
    static let diskWarningMinutes = 60.0
    /// While recording, warn once when this much recording time is left.
    static let diskLowMinutes = 2.0
    /// ProRes 422 LT takes no bitrate; Apple's target rates are about 1.65 bits per pixel per frame
    /// (82 Mbit/s for 1080p 23.976, 328 Mbit/s for 2160p 23.976).
    static let proRes422LTBitsPerPixel = 1.65
    /// 48 kHz 24-bit linear PCM, per channel.
    static let pcmBytesPerSecondPerChannel = 48_000.0 * 3

    /// About how many bytes per second both files write together at these settings. Audio is
    /// counted as 2 channels per source, the most the recorders usually see.
    /// - Parameter cameraSignal: what the camera sends, when known; else the config's expected
    ///   size and rate (3840x2160 at 23.976 when it follows the signal).
    static func bytesPerSecond(camera: CameraRecorderConfig?, cameraSignal: CameraSignal? = nil,
                               screen: ScreenRecorderConfig?) -> Double {
        var bits = 0.0
        var audioChannels = 0.0
        if let c = camera {
            bits += videoBitsPerSecond(codec: c.codec, bitrate: c.bitrate,
                                       width: cameraSignal?.width ?? c.expectedWidth,
                                       height: cameraSignal?.height ?? c.expectedHeight,
                                       frameRate: cameraSignal?.frameRate ?? c.expectedFrameRate)
            if c.audioDeviceUID != nil { audioChannels += 2 }
        }
        if let s = screen {
            bits += videoBitsPerSecond(codec: s.codec, bitrate: s.bitrate, width: s.outputPx.width,
                                       height: s.outputPx.height, frameRate: s.frameRate)
            if s.micDeviceUID != nil { audioChannels += 2 }
            if s.captureSystemAudio { audioChannels += 2 }
        }
        return bits / 8 + audioChannels * pcmBytesPerSecondPerChannel
    }

    static func videoBitsPerSecond(codec: VideoCodec, bitrate: Int, width: Int, height: Int, frameRate: FrameRate) -> Double {
        switch codec {
        case .hevc, .h264: Double(bitrate)
        case .proRes422LT: Double(width * height) * frameRate.framesPerSecond * proRes422LTBitsPerPixel
        }
    }

    /// Recording time left before the recorders stop at `recordingStopBytes`, in minutes.
    static func minutesLeft(freeBytes: Int64, bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return .infinity }
        return Double(max(0, freeBytes - recordingStopBytes)) / bytesPerSecond / 60
    }

    static func diskIssues(availableBytes: Int64?, bytesPerSecond: Double, folder: URL) -> [PreflightIssue] {
        guard let bytes = availableBytes else {
            return [PreflightIssue(id: "app.disk_unknown", severity: .warning,
                                   message: "Cannot read the free space for \(folder.path).")]
        }
        let free = gigabytes(bytes)
        let minutes = minutesLeft(freeBytes: bytes, bytesPerSecond: bytesPerSecond)
        let left = minutes.isFinite ? "about \(Int(minutes)) min at these settings" : "too little to record"
        if bytes <= recordingStopBytes || minutes < diskBlockerMinutes {
            return [PreflightIssue(id: "app.disk", severity: .blocker,
                                   message: "Only \(free) free on the recording disk: \(left). Free some space, or pick another folder.")]
        }
        if minutes < diskWarningMinutes {
            return [PreflightIssue(id: "app.disk", severity: .warning,
                                   message: "Only \(free) free on the recording disk: \(left).")]
        }
        return []
    }

    /// What a free-space check during a recording asks for.
    enum DiskAction: Equatable {
        case none
        /// About this many whole minutes are left.
        case warn(minutesLeft: Int)
        /// Stop both recorders now, so both files finish cleanly.
        case stop
    }

    static func diskAction(freeBytes: Int64, bytesPerSecond: Double) -> DiskAction {
        if freeBytes <= recordingStopBytes { return .stop }
        let minutes = minutesLeft(freeBytes: freeBytes, bytesPerSecond: bytesPerSecond)
        return minutes < diskLowMinutes ? .warn(minutesLeft: max(1, Int(minutes.rounded(.up)))) : .none
    }

    /// Free space for a folder that may not exist yet: measured at its nearest existing parent.
    /// The same measure as the checks while recording (`SessionFolder.conservativeFreeSpace`: no
    /// purgeable space), so a Start that looks fine never stops at 2 GB a minute later.
    static func availableCapacity(for folder: URL) -> Int64? {
        SessionFolder.conservativeFreeSpace(at: existingAncestor(of: folder))
    }

    /// A blocker when Start cannot create the session folder in `folder`: its disk is not
    /// connected (a folder under /Volumes whose volume is missing: the nearest existing parent is
    /// /Volumes itself, whose free space is the boot disk's), or its nearest existing parent is not
    /// writable. Nil when Start can create it.
    static func folderIssue(folder: URL, existingAncestor: URL, ancestorWritable: Bool) -> PreflightIssue? {
        let parts = folder.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes", existingAncestor.standardizedFileURL.path == "/Volumes" {
            return PreflightIssue(id: "app.folder_missing", severity: .blocker, message:
                "The disk \(parts[2]) is not connected, so Start cannot create the session folder in \(folder.path). "
                + "Connect it, or pick another folder.")
        }
        guard ancestorWritable else {
            return PreflightIssue(id: "app.folder_not_writable", severity: .blocker, message:
                "TwinTake cannot write to \(existingAncestor.path), so Start cannot create the session folder there. "
                + "Pick another folder.")
        }
        return nil
    }

    /// `folderIssue` for `folder` now.
    static func folderIssue(for folder: URL) -> PreflightIssue? {
        let ancestor = existingAncestor(of: folder)
        return folderIssue(folder: folder, existingAncestor: ancestor,
                           ancestorWritable: FileManager.default.isWritableFile(atPath: ancestor.path))
    }

    /// True when a session folder holds nothing but what Start writes before the files begin
    /// (session.json, events.jsonl): a start cancelled then leaves no folder behind.
    static func holdsOnlyStartFiles(_ fileNames: [String]) -> Bool {
        Set(fileNames).isSubset(of: [SessionFolder.manifestFileName, SessionFolder.eventsFileName])
    }

    static func existingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    /// "4.2 GB", "120 GB".
    static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        return gb < 10 ? String(format: "%.1f GB", gb) : "\(Int(gb.rounded())) GB"
    }

    /// Index of the track an editor cuts on: the camera mic when camera.mov has one, else the
    /// screen mic. Nil when the session has no mic track.
    static func dialogueIndex(in tracks: [TrackInfo]) -> Int? {
        tracks.firstIndex { $0.file == SessionFolder.cameraFileName && $0.role == .mic }
            ?? tracks.firstIndex { $0.file == SessionFolder.screenFileName && $0.role == .mic }
    }

    /// The tracks with `dialogue` true on exactly one of them (none when there is no mic track).
    static func assigningDialogue(_ tracks: [TrackInfo]) -> [TrackInfo] {
        let pick = dialogueIndex(in: tracks)
        return tracks.enumerated().map { i, track in
            var t = track
            t.dialogue = i == pick
            return t
        }
    }

    /// `sync.check`: "shared_voice" only when camera.mov and screen.mov both have a mic track.
    static func syncCheck(cameraHasMic: Bool, screenHasMic: Bool) -> String {
        cameraHasMic && screenHasMic ? "shared_voice" : "none"
    }

    static func syncCheck(for tracks: [TrackInfo]) -> String {
        func hasMic(_ file: String) -> Bool { tracks.contains { $0.file == file && $0.role == .mic } }
        return syncCheck(cameraHasMic: hasMic(SessionFolder.cameraFileName), screenHasMic: hasMic(SessionFolder.screenFileName))
    }

    /// Fills the manifest at Stop: tracks (camera.mov first), the dialogue flag, the sync check,
    /// timing, errors and status. Any error makes the status `failed`; the files are still kept.
    static func finish(_ manifest: inout SessionManifest, results: [RecorderResult], extraErrors: [String] = [],
                       stoppedAtHostNs: UInt64) {
        let tracks = results.flatMap(\.tracks).sorted { a, b in
            (fileOrder(a.file), a.trackIndex) < (fileOrder(b.file), b.trackIndex)
        }
        manifest.tracks = assigningDialogue(tracks)
        manifest.sync.check = syncCheck(for: manifest.tracks)
        manifest.errors += extraErrors + results.flatMap(\.errors)
        manifest.stoppedAtHostNs = stoppedAtHostNs
        if let start = manifest.startedAtHostNs, stoppedAtHostNs >= start {
            manifest.durationS = Double(stoppedAtHostNs - start) / 1e9
        }
        manifest.status = manifest.errors.isEmpty ? .complete : .failed
    }

    private static func fileOrder(_ file: String) -> Int {
        switch file {
        case SessionFolder.cameraFileName: 0
        case SessionFolder.screenFileName: 1
        default: 2
        }
    }

    /// "0:07", "12:34", "1:02:03".
    static func elapsedString(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "3840x2160 420v 23.976" to "3840×2160 23.976" for the status lines.
    static func shortFormat(_ negotiated: String) -> String {
        let parts = negotiated.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return negotiated.replacingOccurrences(of: "x", with: "×") }
        let size = parts[0].replacingOccurrences(of: "x", with: "×")
        return "\(size) \(parts[parts.count - 1])"
    }

    /// TwinTake's bundle identifier (App/Info.plist `CFBundleIdentifier`).
    static let appBundleID = "com.lukebarousse.twintake"

    /// The apps a region capture leaves out: TwinTake itself, so its windows (the camera window,
    /// the frame overlay, the menu) never appear in screen.mov; the content under them is recorded.
    /// `appBundleID` is always in the list, also when the app runs unbundled from `swift run`.
    static func excludedBundleIDs(mainBundleID: String?) -> [String] {
        var ids = [appBundleID]
        if let mainBundleID, !mainBundleID.isEmpty, mainBundleID != appBundleID { ids.append(mainBundleID) }
        return ids
    }

    /// The `recorder` block: version from `CFBundleShortVersionString`, git sha from `RecorderGitSha`.
    static func recorderInfo(bundle: Bundle = .main) -> RecorderInfo {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let sha = (info["RecorderGitSha"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RecorderInfo(name: "TwinTake", version: version, gitSha: sha)
    }

    /// True when a snap made during a recording replaces the recorded one (session.json and the
    /// window monitor): it found a window and, in window-only mode, it is the window being recorded.
    /// Otherwise the snap is only logged.
    static func snapReplacesRecordedSnap(foundWindow: Bool, snappedWindowID: UInt32?, recordedWindowID: UInt32?) -> Bool {
        guard foundWindow else { return false }
        guard let recordedWindowID else { return true }
        return snappedWindowID == recordedWindowID
    }

    /// Why the live preview cannot open yet, or nil when it can. Opening a device macOS never asked
    /// about shows a permission prompt the user did not click for. Only the camera permission
    /// blocks the preview: its camera mic meter and the idle Mac mic open only when the microphone
    /// is allowed already (they never prompt), and Start checks the microphone permission before
    /// it records the camera audio.
    static func previewBlockedMessage(camera: PermissionState) -> String? {
        switch camera {
        case .granted: nil
        case .notDetermined: "Allow camera access to see the preview: Permissions > Camera > Allow."
        case .denied, .notGranted: "Camera access is off. Turn it on in System Settings > Privacy & Security > Camera."
        }
    }

    /// A warning when the screen mic is the built-in mic and the laptop lid is closed: Apple
    /// silicon laptops cut the built-in mic in hardware then, so the track records silence.
    static func closedLidMicIssue(mic: CaptureDeviceInfo?, lidClosed: Bool, audioDevices: [CaptureDeviceInfo],
                                  cameraAudioUID: String?) -> PreflightIssue? {
        guard lidClosed, let mic, mic.isBuiltIn else { return nil }
        let others = audioDevices.filter { !$0.isBuiltIn && $0.uid != cameraAudioUID }.prefix(3).map(\.name)
        let pick = others.isEmpty ? "Pick another Mic under Screen" : "Pick another Mic under Screen (\(others.joined(separator: ", ")))"
        return PreflightIssue(id: "app.mic_lid_closed", severity: .warning, message:
            "The laptop lid is closed, so \(mic.name) records silence (macOS turns it off in hardware). \(pick), or open the lid.")
    }

    // MARK: - Screen rate, frame and snap

    /// The screen rate: 2x the camera rate up to 30 fps (47.952 for 23.976), else the camera rate
    /// (`ScreenRecorderConfig.frameRate(forCameraRate:)`). It follows the camera's signal when one
    /// is known, else the last rate the app saw from the camera (also in Screen mode), which is
    /// 23.976 until a camera was seen. Not a user choice.
    static func screenFrameRate(cameraSignalRate: FrameRate?, lastCameraRate: FrameRate) -> FrameRate {
        ScreenRecorderConfig.frameRate(forCameraRate: cameraSignalRate ?? lastCameraRate)
    }

    /// The menu's read-only Rate line, e.g. "47.952 fps · 2× the camera's 23.976".
    /// - Parameter cameraLive: the rate comes from the camera's signal now (else the last one seen).
    static func screenRateText(screen: FrameRate, cameraRate: FrameRate, cameraLive: Bool) -> String {
        let doubled = screen != cameraRate
        switch (doubled, cameraLive) {
        case (true, true): return "\(screen.label) fps · 2× the camera's \(cameraRate.label)"
        case (true, false): return "\(screen.label) fps · 2× \(cameraRate.label), the last camera rate"
        case (false, true): return "\(screen.label) fps · same as the camera"
        case (false, false): return "\(screen.label) fps · the last camera rate"
        }
    }

    /// The preflight warning when a visible Dock covers part of the frame (it would be in
    /// screen.mov). Also with "Hide other windows" on: before Start the app cannot know that a
    /// window capture applies (a Parallels window with its toolbar above the frame, or no window
    /// to snap, records the frame region).
    /// - Parameter frameAtBottom: the 16:9 frame sits at the bottom of its display, so moving it
    ///   to the top is a fix the warning can offer.
    static func dockIssue(_ overlap: DockOverlap, frameAtBottom: Bool) -> PreflightIssue? {
        guard let warning = overlap.warning(frameAtBottom: frameAtBottom) else { return nil }
        return PreflightIssue(id: "app.dock_covers_frame", severity: .warning, message: warning)
    }

    /// The preflight warning for hot corners at an edge the frame reaches: moving the pointer
    /// there (for example to the Windows taskbar of a Parallels VM in the bottom frame) runs the
    /// action, and screen.mov records it.
    static func hotCornerIssue(_ corners: [HotCorner], frameLocal: CGRect, displaySizePt: CGSize) -> PreflightIssue? {
        guard let warning = HotCorner.warning(for: HotCorner.atFrameEdge(corners, frameLocal: frameLocal,
                                                                         displaySizePt: displaySizePt)) else { return nil }
        return PreflightIssue(id: "app.hot_corner", severity: .warning, message: warning)
    }

    /// What the menu offers after a snap that found no room for an app's toolbar above the frame.
    enum SnapFix: Equatable, Sendable {
        /// Put the 16:9 frame at the bottom of its display, then snap again.
        case moveFrameToBottom
        /// The whole-display frame leaves no strip above it: use the 16:9 frame at the bottom.
        case useSixteenByNineAtBottom

        var buttonTitle: String {
            switch self {
            case .moveFrameToBottom: "Move Frame to Bottom"
            case .useSixteenByNineAtBottom: "Use 16:9 Frame at Bottom"
            }
        }
    }

    /// The fix for a `toolbar_no_room` snap, or nil for any other result (or when the frame is at
    /// the bottom already, so moving it cannot help).
    static func snapFix(failure: SnapFailure?, preset: ScreenFramePreset, anchor: FrameAnchor) -> SnapFix? {
        guard failure == .toolbarNoRoom else { return nil }
        if preset.sizing == .fullDisplay { return .useSixteenByNineAtBottom }
        return anchor == .bottom ? nil : .moveFrameToBottom
    }

    /// The notice for a snap. For `useSixteenByNineAtBottom` the snapper's own advice ("move the
    /// frame to the bottom") cannot help, so it says what does.
    static func snapNotice(_ snap: SnapResult, fix: SnapFix?) -> String {
        guard fix == .useSixteenByNineAtBottom else { return snap.message }
        let app = snap.appName ?? "The app"
        let strip = snap.toolbar.map { " (\(Double($0.heightPt).formatted()) pt)" } ?? ""
        return "\(app) keeps its toolbar\(strip) above the frame, and the whole-display frame leaves no room for it. "
            + "Use the 16:9 frame at the bottom of the display, or turn off Hide the Parallels toolbar."
    }

    /// "+2 pt", "0 pt", "−1.5 pt" for the Parallels toolbar offset.
    static func offsetLabel(_ points: Double) -> String {
        let rounded = (points * 2).rounded() / 2
        let number = rounded == rounded.rounded() ? String(Int(abs(rounded))) : String(format: "%.1f", abs(rounded))
        if rounded > 0 { return "+\(number) pt" }
        if rounded < 0 { return "−\(number) pt" }
        return "0 pt"
    }

    /// True when "Hide other windows" may record the snapped window alone. A window placed with its
    /// toolbar above the frame (Parallels) is not: a window capture records the whole window,
    /// toolbar included, so the frame region is recorded instead.
    static func windowOnlyApplies(to snap: SnapResult?) -> Bool {
        guard let snap, snap.windowID != nil else { return false }
        return snap.placement != .toolbarAbove
    }

    /// Only the issues that block Start.
    static func blockers(_ issues: [PreflightIssue]) -> [PreflightIssue] {
        issues.filter { $0.severity == .blocker }
    }

    /// The notice when `blocker` stopped Start, e.g. "Not started: Cam Link is connected at USB 2
    /// speed. …". Empty frames get their fix, and no second colon after "No picture".
    static func startBlockedNotice(_ blocker: PreflightIssue) -> String {
        guard blocker.id == "camera.empty_frames" else { return "Not started: \(blocker.message)" }
        let prefix = "No picture: "
        var rest = blocker.message.hasPrefix(prefix) ? String(blocker.message.dropFirst(prefix.count)) : blocker.message
        if let first = rest.first { rest = first.uppercased() + rest.dropFirst() }
        return "Not started: no picture. \(rest) Click Reconnect Camera, or unplug it and plug it back in."
    }

    /// Drops repeated ids (first wins) and sorts blockers first, keeping the original order otherwise.
    static func merged(_ issues: [PreflightIssue]) -> [PreflightIssue] {
        var seen = Set<String>()
        let unique = issues.filter { seen.insert($0.id).inserted }
        return unique.filter { $0.severity == .blocker } + unique.filter { $0.severity == .warning }
    }
}
