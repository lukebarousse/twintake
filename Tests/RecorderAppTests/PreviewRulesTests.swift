import CameraCapture
import Foundation
import Testing
@testable import RecorderApp
@testable import RecorderCore

private let camLinkUID = "0x206000000fd90066"
private let config = CameraRecorderConfig(videoDeviceUID: camLinkUID, audioDeviceUID: "camlink-audio")
private let hd = "1920x1080 420v 23.976"
private let uhd = "3840x2160 420v 23.976"

@Suite struct BurstDebouncerTests {
    let ms: UInt64 = 1_000_000

    /// Feeds `events` (ms) to a debouncer, then reports at which of `checks` (ms) it fired.
    /// (#expect cannot call a mutating method, so the steps run here.)
    func run(events: [UInt64], checks: [UInt64]) -> (deadline: UInt64?, fired: [UInt64]) {
        var d = BurstDebouncer(quietNs: 600 * ms, maxWaitNs: 2_500 * ms)
        var deadline: UInt64?
        for e in events { deadline = d.note(atNs: e * ms) }
        let fired = checks.filter { d.fire(atNs: $0 * ms) }
        return (deadline.map { $0 / ms }, fired)
    }

    @Test func nothingWaitingNeverFires() {
        var d = BurstDebouncer()
        let fired = d.fire(atNs: 10_000 * ms)
        #expect(!fired)
        #expect(d.deadlineNs == nil)
    }

    @Test func oneEventFiresOnceAfterTheQuietTime() {
        let r = run(events: [1_000], checks: [1_000, 1_599, 1_600, 1_700, 5_000])
        #expect(r.deadline == 1_600)
        #expect(r.fired == [1_600])
    }

    @Test func aBurstFiresOnceAfterItsLastEvent() {
        // The Cam Link disconnects and reconnects three times in under a second.
        let r = run(events: [0, 300, 800], checks: [700, 1_300, 1_400, 1_500])
        #expect(r.deadline == 1_400)
        #expect(r.fired == [1_400])
    }

    @Test func aLongBurstStillFiresAtTheMaximumWait() {
        let r = run(events: Array(stride(from: UInt64(0), through: 2_400, by: 400)), checks: [2_499, 2_500])
        #expect(r.deadline == 2_500)
        #expect(r.fired == [2_500])
    }

    @Test func theNextEventStartsANewBurst() {
        var d = BurstDebouncer(quietNs: 600 * ms, maxWaitNs: 2_500 * ms)
        d.note(atNs: 0)
        let first = d.fire(atNs: 600 * ms)
        let next = d.note(atNs: 2_800 * ms)
        #expect(first)
        #expect(next == 3_400 * ms)
    }

    @Test func anEventFromThePastDoesNotMoveTheDeadlineBack() {
        let r = run(events: [1_000, 900], checks: [])
        #expect(r.deadline == 1_600)
    }
}

@Suite struct PreviewActionTests {
    let at1080 = PreviewTarget(config: config, signal: hd)
    let at4K = PreviewTarget(config: config, signal: uhd)

    @Test func opensWhenWantedAndConnected() {
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: nil) == .open(at1080))
    }

    @Test func leavesTheSameTargetAlone() {
        // Ready with a picture, still opening, or failed for good (no format): no retry loop.
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: at1080) == .none)
    }

    @Test func retriesTheSameTargetOnlyWhenItsWaitIsOver() {
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: at1080,
                                    retryCurrent: true) == .reopen(at1080))
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: at1080,
                                    retryCurrent: true, mustWait: true) == .none)
        // A closed camera that must wait does not open yet.
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: nil, mustWait: true) == .none)
        // Disconnected or holding still closes, retry or not.
        #expect(PreviewRules.action(wanted: at1080, connected: false, holding: false, current: at1080,
                                    retryCurrent: true) == .close)
    }

    @Test func aNewTargetNeverWaits() {
        // The rule gets mustWait from PreviewRetry.blocks, which is false for another target.
        #expect(PreviewRules.action(wanted: at4K, connected: true, holding: false, current: at1080,
                                    mustWait: true) == .reopen(at4K))
    }

    @Test func reopensWhenTheSignalChanges() {
        // The a6600 switched to 4K: the Cam Link lists other formats.
        #expect(PreviewRules.action(wanted: at4K, connected: true, holding: false, current: at1080) == .reopen(at4K))
    }

    @Test func reopensWhenTheSettingsChange() {
        var other = config
        other.frameRate = .fps29_97
        let target = PreviewTarget(config: other, signal: hd)
        #expect(PreviewRules.action(wanted: target, connected: true, holding: false, current: at1080) == .reopen(target))
    }

    @Test func closesWhenNotWantedDisconnectedOrHolding() {
        #expect(PreviewRules.action(wanted: nil, connected: true, holding: false, current: at1080) == .close)
        #expect(PreviewRules.action(wanted: at1080, connected: false, holding: false, current: at1080) == .close)
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: true, current: at1080) == .close)
        #expect(PreviewRules.action(wanted: nil, connected: false, holding: false, current: nil) == .none)
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: true, current: nil) == .none)
    }
}

@Suite struct PreviewPhaseTests {
    func inputs(showing: Bool = true, blocked: String? = nil, hasCamera: Bool = true, connected: Bool = true,
                hold: PreviewHold? = nil, camera: PreviewCameraState? = .ready, fresh: Bool = true) -> PreviewInputs {
        PreviewInputs(showing: showing, blocked: blocked, hasCamera: hasCamera, connected: connected, hold: hold,
                      camera: camera, pictureFresh: fresh)
    }

    @Test func liveOnlyWithFreshFrames() {
        #expect(PreviewRules.phase(inputs()) == .live)
        #expect(PreviewRules.phase(inputs(fresh: false)) == .noPicture)
        #expect(PreviewPhase.live.message == nil)
        #expect(PreviewPhase.noPicture.message?.contains("HDMI") == true)
    }

    @Test func eachStateHasItsText() {
        #expect(PreviewRules.phase(inputs(showing: false)) == .off)
        #expect(PreviewRules.phase(inputs(blocked: "Allow camera access")) == .blocked("Allow camera access"))
        #expect(PreviewRules.phase(inputs(hasCamera: false)) == .waitingForCamera)
        #expect(PreviewRules.phase(inputs(connected: false)) == .waitingForCamera)
        #expect(PreviewRules.phase(inputs(hold: .disconnected)) == .waitingForCamera)
        #expect(PreviewRules.phase(inputs(hold: .reopening("The camera stopped."))) == .reopening("The camera stopped."))
        #expect(PreviewRules.phase(inputs(camera: nil)) == .opening)
        #expect(PreviewRules.phase(inputs(camera: .opening)) == .opening)
        #expect(PreviewRules.phase(inputs(camera: .failed("No 4K"))) == .failed("No 4K"))
        #expect(PreviewPhase.off.message == nil)
        #expect(PreviewPhase.reopening("The camera stopped.").message == "The camera stopped. Opening the camera again…")
    }

    @Test func pictureFreshness() {
        let s: UInt64 = 1_000_000_000
        // Frames keep coming.
        #expect(PreviewRules.pictureIsFresh(lastFrameNs: 10 * s, readySinceNs: 1 * s, nowNs: 11 * s))
        // HDMI unplugged: the last frame is 2 s old.
        #expect(!PreviewRules.pictureIsFresh(lastFrameNs: 10 * s, readySinceNs: 1 * s, nowNs: 12 * s))
        // Just opened, no frame yet: wait up to 3 s.
        #expect(PreviewRules.pictureIsFresh(lastFrameNs: nil, readySinceNs: 10 * s, nowNs: 12 * s))
        #expect(!PreviewRules.pictureIsFresh(lastFrameNs: nil, readySinceNs: 10 * s, nowNs: 14 * s))
        // A clock read just before the frame arrived is not "old".
        #expect(PreviewRules.pictureIsFresh(lastFrameNs: 10 * s, readySinceNs: 1 * s, nowNs: 9 * s))
    }

    @Test func signalLine() {
        let camLink = CaptureDeviceInfo(uid: camLinkUID, name: "Cam Link 4K", kind: .video, isBuiltIn: false, detail: "3840x2160 23.976")
        let uhd = CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v")
        let line = PreviewRules.signalLine(cameraUID: camLinkUID, device: camLink, signal: uhd)
        #expect(line == CameraSignalLine(text: "4K · 3840×2160 · 23.976 fps"))
        #expect(!line.isWarning && line.fix == nil)

        let fullHD = CameraSignal(width: 1920, height: 1080, frameRate: .fps23_976, pixelFormat: "420v")
        let low = PreviewRules.signalLine(cameraUID: camLinkUID, device: camLink, signal: fullHD)
        #expect(low.text == "1080p · 1920×1080 · 23.976 fps")
        #expect(low.isWarning)
        #expect(low.fix == "Camera sends 1080p. Set the a6600 HDMI output to 4K 24p.")
        // 1080p 59.94 from the a6600: the fix still asks for 4K 24p.
        let fast = CameraSignal(width: 1920, height: 1080, frameRate: .fps59_94, pixelFormat: "420v")
        #expect(PreviewRules.signalLine(cameraUID: camLinkUID, device: camLink, signal: fast).fix?.hasSuffix("4K 24p.") == true)
        let thirty = CameraSignal(width: 1920, height: 1080, frameRate: .fps29_97, pixelFormat: "420v")
        #expect(PreviewRules.signalLine(cameraUID: camLinkUID, device: camLink, signal: thirty).fix?.hasSuffix("4K 30p.") == true)

        // A webcam records its own size: no warning, no a6600 advice.
        let webcam = CaptureDeviceInfo(uid: "web", name: "Logitech BRIO", kind: .video, isBuiltIn: false)
        #expect(PreviewRules.signalLine(cameraUID: "web", device: webcam, signal: fullHD)
            == CameraSignalLine(text: "1080p · 1920×1080 · 23.976 fps"))

        let none = PreviewRules.signalLine(cameraUID: camLinkUID, device: camLink, signal: nil)
        #expect(none.text == "No signal" && none.isWarning && none.fix != nil)
        #expect(PreviewRules.signalLine(cameraUID: camLinkUID, device: nil, signal: nil) == CameraSignalLine(text: "Not connected"))
        #expect(PreviewRules.signalLine(cameraUID: nil, device: nil, signal: nil) == CameraSignalLine(text: "No camera"))
    }
}

@Suite struct PreviewRetryTests {
    let s: UInt64 = 1_000_000_000
    let at1080 = PreviewTarget(config: config, signal: hd)
    let at4K = PreviewTarget(config: config, signal: uhd)

    @Test func theWaitGrowsThenStaysAtTenSeconds() {
        let delays = (1...6).map { PreviewRules.retryDelayNs(attempt: $0) / s }
        #expect(delays == [0, 2, 5, 10, 10, 10])
    }

    @Test func countsInARowPerTarget() {
        let first = PreviewRetry.next(after: nil, target: at1080, reason: "The camera stopped.", nowNs: 10 * s)
        let second = PreviewRetry.next(after: first, target: at1080, reason: "The camera stopped.", nowNs: 12 * s)
        #expect(first.attempts == 1 && first.notBeforeNs == 10 * s)
        #expect(second.attempts == 2 && second.notBeforeNs == 14 * s)
        // Another target starts over.
        let other = PreviewRetry.next(after: second, target: at4K, reason: "x", nowNs: 20 * s)
        #expect(other.attempts == 1)
    }

    @Test func blocksOnlyItsOwnTargetUntilItsTime() {
        let retry = PreviewRetry(target: at1080, attempts: 2, notBeforeNs: 14 * s, reason: "x")
        #expect(retry.blocks(at1080, nowNs: 13 * s))
        #expect(!retry.blocks(at1080, nowNs: 14 * s))
        #expect(!retry.blocks(at4K, nowNs: 13 * s))
        #expect(!retry.blocks(nil, nowNs: 13 * s))
    }

    @Test func whichCamerasOpenAgain() {
        func retry(_ state: PreviewCameraState, retryable: Bool = true, last: UInt64? = nil, ready: UInt64? = 10 * s,
                   now: UInt64) -> Bool {
            PreviewRules.shouldRetry(state, retryableFailure: retryable, lastFrameNs: last, readySinceNs: ready, nowNs: now)
        }
        #expect(!retry(.opening, now: 60 * s))
        #expect(retry(.failed("Cannot use Cam Link 4K"), now: 11 * s))
        // No matching format: only a new format list (a new target) helps.
        #expect(!retry(.failed("No 4K"), retryable: false, now: 60 * s))
        // Frames keep coming.
        #expect(!retry(.ready, last: 30 * s, now: 31 * s))
        // HDMI back at the same format, but the stream did not restart: 5 s without a picture.
        #expect(!retry(.ready, last: 30 * s, now: 35 * s))
        #expect(retry(.ready, last: 30 * s, now: 35 * s + 1))
        // Opened, no frame yet: wait 5 s before opening again.
        #expect(!retry(.ready, now: 15 * s))
        #expect(retry(.ready, now: 15 * s + 1))
    }

    /// The camera window alone (menu closed) may be on all day: a camera that keeps sending no
    /// picture is opened again only a few times, not every ~16 s forever.
    @Test func withOnlyTheCameraWindowTheReopensStop() {
        var retry: PreviewRetry?
        var opens = 1
        var now = 10 * s
        // Each open sends no picture for 5 s, then the pass reopens it once its wait is over.
        while PreviewRules.mayRetry(retry, target: at1080, menuVisible: false), opens < 100 {
            now += 5 * s
            retry = .next(after: retry, target: at1080, reason: "No picture from the camera.", nowNs: now)
            now = retry!.notBeforeNs
            opens += 1
        }
        #expect(opens == PreviewRules.windowOnlyMaxAttempts + 1)
        // The menu open keeps retrying (and opening it resets the count anyway).
        #expect(PreviewRules.mayRetry(retry, target: at1080, menuVisible: true))
        // A new signal is a new target: it opens again.
        #expect(PreviewRules.mayRetry(retry, target: at4K, menuVisible: false))
        #expect(PreviewRules.mayRetry(nil, target: at1080, menuVisible: false))
    }

    @Test func aCameraWorksAfterFiveSecondsOfPicture() {
        #expect(PreviewRules.cameraWorks(lastFrameNs: 15 * s, readySinceNs: 10 * s, nowNs: 15 * s))
        #expect(!PreviewRules.cameraWorks(lastFrameNs: 14 * s, readySinceNs: 10 * s, nowNs: 14 * s))
        #expect(!PreviewRules.cameraWorks(lastFrameNs: nil, readySinceNs: 10 * s, nowNs: 20 * s))
        #expect(!PreviewRules.cameraWorks(lastFrameNs: 12 * s, readySinceNs: 10 * s, nowNs: 20 * s))
    }

    @Test func theWaitShowsItsReason() {
        func phase(hold: PreviewHold? = nil, camera: PreviewCameraState?, reason: String?) -> PreviewPhase {
            PreviewRules.phase(PreviewInputs(showing: true, blocked: nil, hasCamera: true, connected: true, hold: hold,
                                             camera: camera, pictureFresh: true, retryReason: reason))
        }
        #expect(phase(camera: nil, reason: "No picture from the camera.") == .reopening("No picture from the camera."))
        #expect(phase(camera: nil, reason: nil) == .opening)
        #expect(phase(camera: .opening, reason: "x") == .opening)
        #expect(phase(hold: .disconnected, camera: nil, reason: "x") == .waitingForCamera)
    }
}

/// The HDMI unplug and the switch to 4K, step by step through the same rules the coordinator runs.
@Suite struct HotPlugScenarioTests {
    @Test func unplugThenReplugAt4K() {
        let at1080 = PreviewTarget(config: config, signal: hd)
        let at4K = PreviewTarget(config: config, signal: uhd)
        func phase(connected: Bool, hold: PreviewHold?, camera: PreviewCameraState?, fresh: Bool = true) -> PreviewPhase {
            PreviewRules.phase(PreviewInputs(showing: true, blocked: nil, hasCamera: true, connected: connected,
                                             hold: hold, camera: camera, pictureFresh: fresh))
        }

        // 1. Live at 1080p.
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: at1080) == .none)
        #expect(phase(connected: true, hold: nil, camera: .ready) == .live)

        // 2. HDMI out: frames stop before anything else happens.
        #expect(phase(connected: true, hold: nil, camera: .ready, fresh: false) == .noPicture)

        // 3. The Cam Link drops off USB: the camera reports it, the preview closes at once.
        #expect(PreviewRules.action(wanted: at1080, connected: true, holding: true, current: at1080) == .close)
        #expect(phase(connected: true, hold: .disconnected, camera: nil) == .waitingForCamera)

        // 4. The settled device list has no Cam Link: nothing to open.
        #expect(PreviewRules.action(wanted: nil, connected: false, holding: false, current: nil) == .none)
        #expect(phase(connected: false, hold: nil, camera: nil) == .waitingForCamera)

        // 5. It is back, now offering 3840x2160 23.976: open for the new signal.
        #expect(PreviewRules.action(wanted: at4K, connected: true, holding: false, current: nil) == .open(at4K))
        #expect(phase(connected: true, hold: nil, camera: .opening) == .opening)
        #expect(phase(connected: true, hold: nil, camera: .ready) == .live)
    }

    @Test func signalChangeWithoutAReconnect() {
        // The Cam Link stays on USB and only changes its format list.
        let at1080 = PreviewTarget(config: config, signal: hd)
        let at4K = PreviewTarget(config: config, signal: uhd)
        #expect(PreviewRules.action(wanted: at4K, connected: true, holding: false, current: at1080) == .reopen(at4K))
        // A 4K recording config that failed at 1080p is retried once the signal is 4K.
        #expect(PreviewRules.action(wanted: at4K, connected: true, holding: false, current: at1080) != .none)
    }

    @Test func replugAtTheSameSignalRecoversFromAFailedOpen() {
        // The Cam Link is listed again, but the first open fails while it settles. Nothing else
        // changes: same signal, same format list. The preview must still try again by itself.
        let s: UInt64 = 1_000_000_000
        let at1080 = PreviewTarget(config: config, signal: hd)
        var retry = PreviewRetry.next(after: nil, target: at1080, reason: "Cannot use Cam Link 4K", nowNs: 10 * s)
        func next(now: UInt64, failed: Bool = true) -> PreviewAction {
            let again = PreviewRules.shouldRetry(failed ? .failed("Cannot use Cam Link 4K") : .ready, retryableFailure: true,
                                                 lastFrameNs: now, readySinceNs: 0, nowNs: now)
            return PreviewRules.action(wanted: at1080, connected: true, holding: false, current: at1080,
                                       retryCurrent: again, mustWait: retry.blocks(at1080, nowNs: now))
        }
        // First failure: try again at the next pass.
        #expect(next(now: 10 * s + 1) == .reopen(at1080))
        // It fails again: wait 2 s, then retry.
        retry = .next(after: retry, target: at1080, reason: "Cannot use Cam Link 4K", nowNs: 12 * s)
        #expect(next(now: 13 * s) == .none)
        #expect(next(now: 14 * s) == .reopen(at1080))
        // It opens and sends frames: nothing more to do.
        #expect(next(now: 20 * s, failed: false) == .none)
    }

    @Test func aCameraThatKeepsFailingBacksOff() {
        // Each open posts a runtime error at once. The waits grow instead of a loop every second.
        let s: UInt64 = 1_000_000_000
        let at1080 = PreviewTarget(config: config, signal: hd)
        var retry: PreviewRetry?
        var now: UInt64 = 0
        var waits: [UInt64] = []
        for _ in 1...5 {
            retry = .next(after: retry, target: at1080, reason: "Camera error: x.", nowNs: now)
            let open = retry!.notBeforeNs
            waits.append((open - now) / s)
            #expect(PreviewRules.action(wanted: at1080, connected: true, holding: false, current: nil,
                                        mustWait: retry!.blocks(at1080, nowNs: open)) == .open(at1080))
            now = open + s
        }
        #expect(waits == [0, 2, 5, 10, 10])
    }
}

/// After a take, its camera stays open as the preview camera only when nothing speaks against it.
/// Otherwise it closes, and the preview opens the camera again in the preview graph.
@Suite struct TakeCameraTests {
    func keeps(previewWanted: Bool = true, previewReady: Bool = true, broken: Bool = false, sameConfig: Bool = true,
               otherPreviewOpen: Bool = false, mayWait: Bool = true) -> Bool {
        PreviewRules.keepsTakeCamera(previewWanted: previewWanted, previewReady: previewReady, broken: broken,
                                     sameConfig: sameConfig, otherPreviewOpen: otherPreviewOpen, mayWait: mayWait)
    }

    @Test func aHealthyCameraBackOnItsPreviewGraphStays() {
        #expect(keeps())
    }

    @Test func anyProblemClosesIt() {
        // The menu closed and the camera window is off.
        #expect(!keeps(previewWanted: false))
        // Still on the recording graph (with the mic), or its session stopped.
        #expect(!keeps(previewReady: false))
        // A disconnect, an error or a new signal during the take.
        #expect(!keeps(broken: true))
        // The settings changed during the take.
        #expect(!keeps(sameConfig: false))
        #expect(!keeps(otherPreviewOpen: true))
        // The start hung: the camera is released without waiting.
        #expect(!keeps(mayWait: false))
    }
}

@Suite struct PreviewIdentityTests {
    /// A codec or bitrate change is no new preview target: the camera session does not use them,
    /// so the preview camera stays open (no indicator blink, no Cam Link zero-frame burst).
    @Test func theEncoderIsNoPartOfThePreviewTarget() {
        var proRes = config
        proRes.codec = .proRes422LT
        proRes.bitrate = 100_000_000
        #expect(PreviewTarget(config: config, signal: uhd) == PreviewTarget(config: proRes, signal: uhd))
        #expect(PreviewRules.sameCamera(config, proRes))
        #expect(PreviewTarget(config: config, signal: uhd) != PreviewTarget(config: config, signal: hd))
        var otherAudio = config
        otherAudio.audioDeviceUID = "BuiltInMicrophoneDevice"
        #expect(!PreviewRules.sameCamera(config, otherAudio))
        #expect(!PreviewRules.sameCamera(config, nil))
        #expect(PreviewRules.action(wanted: PreviewTarget(config: proRes, signal: uhd), connected: true, holding: false,
                                    current: PreviewTarget(config: config, signal: uhd)) == PreviewAction.none)
    }

    /// Start reuses the claimed preview camera only while it still sends what it opened with.
    @Test func startReusesTheClaimedCameraOnlyForTheSameSignal() {
        let at24 = CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v")
        let at30 = CameraSignal(width: 3840, height: 2160, frameRate: .fps29_97, pixelFormat: "420v")
        let hd24 = CameraSignal(width: 1920, height: 1080, frameRate: .fps23_976, pixelFormat: "420v")
        #expect(PreviewRules.claimStillMatches(targetSignal: uhd, inventorySignal: uhd, cameraSignal: at24, planSignal: at24))
        // The a6600 switched 30p to 24p right before Start: the device list already says so.
        #expect(!PreviewRules.claimStillMatches(targetSignal: "3840x2160 420v 29.97", inventorySignal: uhd,
                                                cameraSignal: at30, planSignal: at24))
        // The list did not change yet, but the open camera runs another rate or size.
        #expect(!PreviewRules.claimStillMatches(targetSignal: uhd, inventorySignal: uhd, cameraSignal: at30, planSignal: at24))
        #expect(!PreviewRules.claimStillMatches(targetSignal: uhd, inventorySignal: uhd, cameraSignal: hd24, planSignal: at24))
        // The camera left the list, or it offers no format now.
        #expect(!PreviewRules.claimStillMatches(targetSignal: uhd, inventorySignal: nil, cameraSignal: at24, planSignal: at24))
        #expect(!PreviewRules.claimStillMatches(targetSignal: uhd, inventorySignal: uhd, cameraSignal: at24, planSignal: nil))
    }
}
