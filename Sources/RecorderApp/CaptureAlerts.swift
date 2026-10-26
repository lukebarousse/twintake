import CameraCapture
import Foundation
import RecorderCore

// The banners in the menu and the camera window: the camera mic warning (from the detector) and
// the camera's own trouble (a Cam Link on USB 2, empty frames). Plain data, so the rules can be
// tested.

/// The camera's health now, from the open camera (or the device list for the USB link).
struct CameraHealth: Equatable, Sendable {
    /// "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3."
    var usbProblem: String?
    /// Set while the open camera sends empty frames.
    var emptyFrames: EmptyFramePattern?
    /// "No picture: the Cam Link is sending empty frames."
    var pictureProblem: String?

    var isEmpty: Bool { usbProblem == nil && pictureProblem == nil }
}

/// What the camera mic detector warns about. Pauses never make one: the detector only counts
/// voiced time.
enum MicAlert: Equatable, Sendable {
    /// The camera records with its built-in mic: the external mic is unplugged.
    case builtInMic
    /// The Mac mic hears the voice, the camera mic does not (the external mic is plugged in but off).
    case cameraMicSilent

    /// The warning in `status`, if any. The silent mic comes first.
    init?(_ status: MicDetectorStatus) {
        if status.cameraMicSilent {
            self = .cameraMicSilent
        } else if status.verdict == .builtInMic {
            self = .builtInMic
        } else {
            return nil
        }
    }
}

/// One banner.
struct CaptureAlert: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case emptyFrames, usb2, cameraMicSilent, builtInMic
    }

    var kind: Kind
    var title: String
    var detail: String?
    /// Red: Start is blocked by it. Orange: a warning.
    var blocksStart: Bool
    /// The banner offers "Reconnect Camera" (idle only). Only for empty frames on a USB 3 link:
    /// reopening the camera cannot move a Cam Link off its USB 2 lane; a replug does.
    var offersReconnect: Bool

    var id: String { kind.rawValue }

    /// The preflight issue the banner stands for, so the issues list does not repeat it.
    var issueID: String? {
        switch kind {
        case .usb2: "camera.usb2"
        case .emptyFrames: "camera.empty_frames"
        case .cameraMicSilent, .builtInMic: nil
        }
    }
}

enum CaptureAlerts {
    static let builtInTitle = "\(MicNames.external) not detected — the camera is using its built-in mic."
    static let builtInDetail = "Plug the \(MicNames.external) into the \(MicNames.camera)'s mic jack."
    static let silentTitle = "The camera mic isn't picking up your voice."
    static let silentDetail = "Check that the \(MicNames.external) is switched on and plugged in."

    static let emptyFramesDetail = "Click Reconnect Camera, or unplug the Cam Link and plug it back in."
    static let emptyFramesOnUSB2Detail = "Unplug the Cam Link and plug it back in."
    static let emptyFramesRecordingDetail = "camera.mov has no picture. Stop, then reconnect or replug the Cam Link."

    /// The banners now, most urgent first: the USB link (the cause, when it is set), no picture,
    /// then the mic.
    /// - Parameters:
    ///   - mic: the detector's warning while a take records or a mic check runs.
    ///   - health: the camera's trouble (nil fields when it has none or the mode records no camera).
    ///   - idle: nothing records, so Reconnect may be offered and a blocker is red.
    static func list(mic: MicAlert?, health: CameraHealth, idle: Bool) -> [CaptureAlert] {
        var alerts: [CaptureAlert] = []
        // A Cam Link on its USB 2 lane sends empty frames: its banner says the fix (a replug), and
        // Reconnect, which cannot move it off that lane, is not offered.
        if let problem = health.usbProblem {
            let (title, detail) = split(problem)
            alerts.append(CaptureAlert(kind: .usb2, title: title, detail: detail, blocksStart: true, offersReconnect: false))
        }
        if let problem = health.pictureProblem {
            let onUSB2 = health.usbProblem != nil
            let detail = !idle ? emptyFramesRecordingDetail : onUSB2 ? emptyFramesOnUSB2Detail : emptyFramesDetail
            alerts.append(CaptureAlert(kind: .emptyFrames, title: problem, detail: detail,
                                       blocksStart: idle && health.emptyFrames != .constant,
                                       offersReconnect: idle && !onUSB2))
        }
        switch mic {
        case .cameraMicSilent?:
            alerts.append(CaptureAlert(kind: .cameraMicSilent, title: silentTitle, detail: silentDetail,
                                       blocksStart: false, offersReconnect: false))
        case .builtInMic?:
            alerts.append(CaptureAlert(kind: .builtInMic, title: builtInTitle, detail: builtInDetail,
                                       blocksStart: false, offersReconnect: false))
        case nil:
            break
        }
        return alerts
    }

    /// Splits "A sentence. The rest." into its first sentence and the rest.
    static func split(_ message: String) -> (title: String, detail: String?) {
        guard let range = message.range(of: ". ") else { return (message, nil) }
        let title = String(message[..<range.lowerBound]) + "."
        let rest = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return (title, rest.isEmpty ? nil : rest)
    }

    /// The note on the last take's line when the camera did not record with the external mic.
    static func lastTakeMicNote(_ report: MicSourceReport?) -> String? {
        guard let report else { return nil }
        if report.verdict == .builtInMic {
            return "camera.mov was recorded with the camera's built-in mic (\(MicNames.external) not detected)."
        }
        if report.verdictsSeen.contains(.builtInMic) {
            return "Part of camera.mov was recorded with the camera's built-in mic (\(MicNames.external) not detected for a while)."
        }
        if report.cameraMicSilent { return "The camera mic did not pick up your voice for a while." }
        return nil
    }

    /// The notes on the last take's line about camera.mov's pictures (session.json's camera
    /// video track, 1.7): repeated pictures made it choppy (`RepeatedFrameRule`, the same verdict
    /// as the take's warning; a still picture gets no note), or frames changed after they arrived.
    static func lastTakeCameraNotes(_ track: TrackInfo?) -> [String] {
        guard let track else { return [] }
        var notes: [String] = []
        if let note = RepeatedFrameRule.verdict(track).flatMap(RepeatedFrameRule.menuNote) { notes.append(note) }
        let changed = (track.changedBeforeWrite ?? 0) + (track.changedWhileHeld ?? 0)
        if changed > 0 {
            let frames = changed == 1 ? "1 camera frame" : "\(changed) camera frames"
            notes.append("\(frames) changed in memory after \(changed == 1 ? "it" : "they") arrived, "
                + "so camera.mov can show a picture twice.")
        }
        return notes
    }
}

/// One beep when a warning comes on, none while it stays on, and again only after it cleared.
struct AlertOnset: Equatable, Sendable {
    private(set) var on = false

    /// Records whether the warning is on now. True when it just came on.
    mutating func update(_ isOn: Bool) -> Bool {
        defer { on = isOn }
        return isOn && !on
    }

    mutating func reset() { on = false }
}
