import CoreGraphics
import Foundation
import RecorderCore

// The app's rules for the idle capture, over plain data (no device, no view), so they can be
// tested:
// - Decision 1: the level meters show before recording whenever the camera preview is on. The
//   preview graph then also meters the camera mic (the Cam Link HDMI audio), and the idle Mac mic
//   meter runs next to it. Computer sound has no idle meter: it needs the screen stream.
// - Decision 2: the camera and the idle mics are open only while the camera window shows, the
//   open menu shows its Live preview, a take prepares, records or saves, or a mic check samples
//   the idle meters. `IdleCaptureDemand` (RecorderCore) adds the short debounce. The window and
//   the menu count only while the screen can show them: a sleeping or locked display shows no
//   camera. A take without a screen mic (Camera mode) keeps the idle Mac mic meter as the camera
//   mic detector's reference.

enum IdleCaptureRules {
    /// The idle meters wait this long after a meter that did not open (or a camera meter that did
    /// not join the preview) before they try again.
    static let retryAfterNs: UInt64 = 10_000_000_000
    /// A mic check that samples the idle meters waits at most this long for them to deliver
    /// (the camera may still be opening); a source still silent then gets its own session.
    static let liveCheckWait: Duration = .seconds(4)

    /// True when the preview camera (or the idle Mac mic) should be open after this pass.
    /// - Parameters:
    ///   - decisionOpen: `IdleCaptureDemand.Decision.open`: wanted now, or within the debounce.
    ///   - wantedNow: something wants it now (`IdleCaptureDemand.wanted`).
    ///   - isOpen: it is open (or opening) now.
    /// - Returns: false once the debounce has run out. During the debounce an open one stays, but
    ///   a closed one never opens: after Stop with nothing on screen, or while a reopen runs, the
    ///   camera is not opened again only to close 1.5 s later.
    static func keepsOrOpens(decisionOpen: Bool, wantedNow: Bool, isOpen: Bool) -> Bool {
        decisionOpen && (wantedNow || isOpen)
    }

    /// The camera mic meter of the preview graph: the microphone is allowed (it never prompts),
    /// the config has a camera audio input, and no mic check holds that input in its own session.
    static func cameraMeterWanted(micAllowed: Bool, hasCameraAudio: Bool, checkOwnsCameraMic: Bool) -> Bool {
        micAllowed && hasCameraAudio && !checkOwnsCameraMic
    }

    /// True when the open preview should get (or drop) its camera mic meter now: it differs from
    /// what is wanted, and, to add it, the same request did not go out in the last `retryAfterNs`
    /// (the camera audio may be missing; the meter then stays off without a request every 2 s).
    /// Dropping it is never held back: a meter that is still on against the wish (it joined while
    /// the camera opened or reconnected) must let the camera audio go at once, because a mic check
    /// may hold that input in its own session.
    static func shouldRequestMeter(want: Bool, isOn: Bool, last: (on: Bool, atNs: UInt64)?, nowNs: UInt64) -> Bool {
        guard want != isOn else { return false }
        guard want, let last, last.on == want else { return true }
        return nowNs >= last.atNs &+ retryAfterNs
    }

    /// The idle Mac mic meter may be open: while nothing records, and during a take that does not
    /// record the Mac mic in screen.mov (Camera mode, or no screen mic in the plan). Its meter is
    /// then the camera mic detector's reference: the silent-mic warning (the a6600 sends silence
    /// after an unplug) needs it. A take that records it holds the mic in its ScreenCaptureKit
    /// stream, so the idle meter stays closed then, and while the plan is not known yet (nil).
    static func macMicMayOpen(idle: Bool, takeRecordsScreenMic: Bool?) -> Bool {
        idle || takeRecordsScreenMic == false
    }

    /// A view on screen can show the camera: the displays are awake, the screen is not locked, and
    /// this user's session is the active one. A camera window on a sleeping or locked screen shows
    /// nothing, so it does not keep the camera and the mics open (decision 2).
    static func screenCanShowCamera(displaysAsleep: Bool, systemSleeping: Bool, screenLocked: Bool,
                                    sessionActive: Bool) -> Bool {
        !displaysAsleep && !systemSleeping && !screenLocked && sessionActive
    }

    /// The sources a mic check samples from the idle meters, and the ones it opens in its own
    /// sessions. A device is never held twice: while the idle capture is wanted (and the mic is
    /// allowed, so the idle meters can run), the check samples them; otherwise it opens its own
    /// sessions, and the idle path leaves those devices closed until it ends.
    static func checkSources(cameraAudio: Bool, screenMic: Bool, idleCaptureWanted: Bool,
                             micAllowed: Bool) -> (live: Set<AudioSource>, own: Set<AudioSource>) {
        var picked: Set<AudioSource> = []
        if cameraAudio { picked.insert(.cameraMic) }
        if screenMic { picked.insert(.screenMic) }
        return idleCaptureWanted && micAllowed ? (picked, []) : ([], picked)
    }

    /// After the wait for the idle meters: the expected live sources that deliver stay live; the
    /// others get their own session.
    static func settle(expectedLive: Set<AudioSource>, delivering: Set<AudioSource>,
                       own: Set<AudioSource>) -> (live: Set<AudioSource>, own: Set<AudioSource>) {
        let live = expectedLive.intersection(delivering)
        return (live, own.union(expectedLive.subtracting(live)))
    }

    /// The meters while nothing records and no mic check runs: the ones that run, in meter order.
    static func idleMeterSources(cameraMeterOn: Bool, macMicOn: Bool) -> [AudioSource] {
        MeterSources.check(cameraAudio: cameraMeterOn, screenMic: macMicOn)
    }

    /// The camera mic detector's banner shows: while a take records, while a plain mic check runs
    /// (not a calibration sample: the external mic is unplugged on purpose), and while idle when
    /// the camera mic meter runs (decision 1: the warning comes before recording too).
    static func watchesDetector(recording: Bool, check: MicCheckPurpose?, idleCameraMeter: Bool) -> Bool {
        if recording { return true }
        if let check { return check == .check }
        return idleCameraMeter
    }

    /// The menu shows the level meters under the Start button: while recording, and while idle
    /// when idle meters run and no mic check shows its own.
    static func menuShowsMeters(recording: Bool, idle: Bool, checkRuns: Bool, sources: [AudioSource]) -> Bool {
        guard !sources.isEmpty else { return false }
        return recording || (idle && !checkRuns)
    }
}

/// Where the camera window puts its bottom meter, its native Reconnect button and its banner, in
/// points from the bottom edge (decision 3: the camera mic meter is a bar along the bottom edge).
enum CameraWindowLayout {
    /// The meter bar: its height (the bar inside a dark backing) and its gap to the window edges.
    static let meterBarHeight: CGFloat = 6
    static let meterBackingPadding: CGFloat = 2
    static let meterInset: CGFloat = 6
    static let sideInset: CGFloat = 8
    /// The space the meter takes, its gap above included.
    static var meterSpace: CGFloat { meterInset + meterBarHeight + 2 * meterBackingPadding }
    /// The Reconnect button's height plus its gap.
    static let reconnectSpace: CGFloat = 30

    /// The Reconnect button's bottom edge: above the meter when it shows.
    static func reconnectBottom(meter: Bool) -> CGFloat { meter ? meterSpace + 6 : 8 }

    /// The banner's bottom edge: above the Reconnect button when it shows, else above the meter.
    static func bannerBottom(meter: Bool, reconnect: Bool) -> CGFloat {
        if reconnect { return reconnectBottom(meter: meter) + reconnectSpace }
        return meter ? meterSpace + 6 : 8
    }
}
