import Foundation
import Testing
@testable import RecorderApp
@testable import RecorderCore

/// Decisions 1 to 3 in the app: the idle meters run whenever the camera preview is on, the camera
/// and the idle mics are open only while something shows the camera (with a short debounce), and
/// the camera window's meter is a bar along its bottom edge.
@Suite struct IdleCaptureRulesTests {
    let s: UInt64 = 1_000_000_000

    @Test func anOpenCameraStaysForTheDebounceButAClosedOneNeverOpensForIt() {
        // Wanted now: open, or stay open.
        #expect(IdleCaptureRules.keepsOrOpens(decisionOpen: true, wantedNow: true, isOpen: false))
        #expect(IdleCaptureRules.keepsOrOpens(decisionOpen: true, wantedNow: true, isOpen: true))
        // Within the debounce: an open camera stays, a closed one stays closed.
        #expect(IdleCaptureRules.keepsOrOpens(decisionOpen: true, wantedNow: false, isOpen: true))
        #expect(!IdleCaptureRules.keepsOrOpens(decisionOpen: true, wantedNow: false, isOpen: false))
        // After the debounce: closed.
        #expect(!IdleCaptureRules.keepsOrOpens(decisionOpen: false, wantedNow: false, isOpen: true))
    }

    /// ⌃⌥⌘C hides the window with the menu closed: the camera stays 1.5 s, then it is released.
    @Test func hidingTheWindowReleasesTheCamera() {
        var demand = IdleCaptureDemand()
        let shown = IdleCaptureDemand.wanted(cameraWindowShown: true, menuPreviewShown: false, takeActive: false)
        _ = demand.update(wanted: shown, nowNs: 0)
        let hidden = IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: false)
        let during = demand.update(wanted: hidden, nowNs: 10 * s)
        #expect(IdleCaptureRules.keepsOrOpens(decisionOpen: during.open, wantedNow: hidden, isOpen: true))
        #expect(during.recheckAtNs == 10 * s + IdleCaptureDemand.defaultCloseDelayNs)
        let after = demand.update(wanted: hidden, nowNs: during.recheckAtNs ?? 0)
        #expect(!IdleCaptureRules.keepsOrOpens(decisionOpen: after.open, wantedNow: hidden, isOpen: true))
    }

    /// Stop with nothing on screen: the take's camera closes, and the debounce never opens a
    /// preview camera again (no green indicator after the take).
    @Test func stopWithNothingOnScreenOpensNothing() {
        var demand = IdleCaptureDemand()
        _ = demand.update(wanted: IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: true),
                          nowNs: 0)
        let idle = IdleCaptureDemand.wanted(cameraWindowShown: false, menuPreviewShown: false, takeActive: false)
        let decision = demand.update(wanted: idle, nowNs: 60 * s)
        #expect(decision.open)
        #expect(!IdleCaptureRules.keepsOrOpens(decisionOpen: decision.open, wantedNow: idle, isOpen: false))
    }

    /// The menu closes and opens again within 1.5 s with Live preview on: the camera stays open.
    @Test func aQuickMenuReopenKeepsTheCamera() {
        var demand = IdleCaptureDemand()
        _ = demand.update(wanted: true, nowNs: 0)
        let closed = demand.update(wanted: false, nowNs: 5 * s)
        #expect(IdleCaptureRules.keepsOrOpens(decisionOpen: closed.open, wantedNow: false, isOpen: true))
        let reopened = demand.update(wanted: true, nowNs: 5 * s + 800_000_000)
        #expect(reopened == .init(open: true))
    }

    @Test func theCameraMicMeterNeedsTheMicAndNoCheckOnIt() {
        #expect(IdleCaptureRules.cameraMeterWanted(micAllowed: true, hasCameraAudio: true, checkOwnsCameraMic: false))
        // Never a permission prompt: without access the preview opens without the meter.
        #expect(!IdleCaptureRules.cameraMeterWanted(micAllowed: false, hasCameraAudio: true, checkOwnsCameraMic: false))
        #expect(!IdleCaptureRules.cameraMeterWanted(micAllowed: true, hasCameraAudio: false, checkOwnsCameraMic: false))
        // A mic check that opened the camera audio in its own session: no second holder.
        #expect(!IdleCaptureRules.cameraMeterWanted(micAllowed: true, hasCameraAudio: true, checkOwnsCameraMic: true))
    }

    @Test func theMeterRequestIsNotRepeatedEveryPass() {
        #expect(!IdleCaptureRules.shouldRequestMeter(want: true, isOn: true, last: nil, nowNs: 0))
        #expect(IdleCaptureRules.shouldRequestMeter(want: true, isOn: false, last: nil, nowNs: 0))
        #expect(IdleCaptureRules.shouldRequestMeter(want: true, isOn: false, last: (false, 5 * s), nowNs: 6 * s))
        // Asked for and still off (the camera audio is missing): again only after 10 s.
        #expect(!IdleCaptureRules.shouldRequestMeter(want: true, isOn: false, last: (true, 5 * s), nowNs: 9 * s))
        #expect(IdleCaptureRules.shouldRequestMeter(want: true, isOn: false, last: (true, 5 * s), nowNs: 15 * s))
        #expect(IdleCaptureRules.shouldRequestMeter(want: false, isOn: true, last: (true, 5 * s), nowNs: 6 * s))
        // Dropping it is never held back: a meter that joined while the camera opened or reconnected,
        // against a request to drop it (a mic check holds the camera audio), leaves at once.
        #expect(IdleCaptureRules.shouldRequestMeter(want: false, isOn: true, last: (false, 5 * s), nowNs: 5 * s + 1))
    }

    /// The idle Mac mic meter during a take: kept in Camera mode (the detector's reference for the
    /// silent-mic warning), closed for a take that records the Mac mic in screen.mov, and closed
    /// while the take's plan is not known.
    @Test func theMacMicMeterStaysForATakeWithoutAScreenMic() {
        #expect(IdleCaptureRules.macMicMayOpen(idle: true, takeRecordsScreenMic: nil))
        #expect(IdleCaptureRules.macMicMayOpen(idle: false, takeRecordsScreenMic: false))
        #expect(!IdleCaptureRules.macMicMayOpen(idle: false, takeRecordsScreenMic: true))
        #expect(!IdleCaptureRules.macMicMayOpen(idle: false, takeRecordsScreenMic: nil))
    }

    /// A camera window on a sleeping or locked screen shows nothing: it does not keep the camera
    /// and the mics open. A take keeps them.
    @Test func aSleepingOrLockedScreenShowsNoCamera() {
        #expect(IdleCaptureRules.screenCanShowCamera(displaysAsleep: false, systemSleeping: false, screenLocked: false, sessionActive: true))
        #expect(!IdleCaptureRules.screenCanShowCamera(displaysAsleep: true, systemSleeping: false, screenLocked: false, sessionActive: true))
        #expect(!IdleCaptureRules.screenCanShowCamera(displaysAsleep: false, systemSleeping: true, screenLocked: false, sessionActive: true))
        #expect(!IdleCaptureRules.screenCanShowCamera(displaysAsleep: false, systemSleeping: false, screenLocked: true, sessionActive: true))
        #expect(!IdleCaptureRules.screenCanShowCamera(displaysAsleep: false, systemSleeping: false, screenLocked: false, sessionActive: false))
        // The window stays on overnight; the display sleeps: the camera closes at once (no debounce).
        var demand = IdleCaptureDemand()
        _ = demand.update(wanted: IdleCaptureDemand.wanted(cameraWindowShown: true, menuPreviewShown: false, takeActive: false),
                          nowNs: 0)
        let seen = IdleCaptureRules.screenCanShowCamera(displaysAsleep: true, systemSleeping: false, screenLocked: false,
                                                        sessionActive: true)
        demand.closeNow()
        let asleep = demand.update(wanted: IdleCaptureDemand.wanted(cameraWindowShown: seen, menuPreviewShown: false,
                                                                    takeActive: false), nowNs: 1)
        #expect(!asleep.open && asleep.recheckAtNs == nil)
        #expect(demand.update(wanted: IdleCaptureDemand.wanted(cameraWindowShown: seen, menuPreviewShown: false,
                                                               takeActive: true), nowNs: 2).open)
    }

    /// The mic check never holds a device a second time: it samples the idle meters while the
    /// preview is on, and otherwise opens its own sessions (the idle path then leaves them closed).
    @Test func theMicCheckSamplesTheIdleMetersOrOpensItsOwn() {
        let live = IdleCaptureRules.checkSources(cameraAudio: true, screenMic: true, idleCaptureWanted: true, micAllowed: true)
        #expect(live.live == [.cameraMic, .screenMic] && live.own.isEmpty)
        let own = IdleCaptureRules.checkSources(cameraAudio: true, screenMic: true, idleCaptureWanted: false, micAllowed: true)
        #expect(own.live.isEmpty && own.own == [.cameraMic, .screenMic])
        // Without microphone access the idle meters never run: the check asks (its prompt) and opens its own.
        let noMic = IdleCaptureRules.checkSources(cameraAudio: true, screenMic: false, idleCaptureWanted: true, micAllowed: false)
        #expect(noMic.live.isEmpty && noMic.own == [.cameraMic])
        // A camera meter that did not come within the wait gets its own session; the Mac mic stays live.
        let settled = IdleCaptureRules.settle(expectedLive: [.cameraMic, .screenMic], delivering: [.screenMic], own: [])
        #expect(settled.live == [.screenMic] && settled.own == [.cameraMic])
    }

    /// Two calibration samples in a row from the idle meters: each check samples the live stream
    /// again; nothing from the first one is held open or left in the plan.
    @Test func twoSamplesInARowBothSampleTheIdleMeters() {
        for _ in 0..<2 {
            let plan = IdleCaptureRules.checkSources(cameraAudio: true, screenMic: true, idleCaptureWanted: true, micAllowed: true)
            let settled = IdleCaptureRules.settle(expectedLive: plan.live, delivering: [.cameraMic, .screenMic], own: plan.own)
            #expect(settled.live == [.cameraMic, .screenMic] && settled.own.isEmpty)
        }
    }

    @Test func theIdleMetersAndTheirBanner() {
        #expect(IdleCaptureRules.idleMeterSources(cameraMeterOn: true, macMicOn: true) == [.cameraMic, .screenMic])
        #expect(IdleCaptureRules.idleMeterSources(cameraMeterOn: false, macMicOn: true) == [.screenMic])
        #expect(IdleCaptureRules.idleMeterSources(cameraMeterOn: false, macMicOn: false).isEmpty)
        // The warning shows before recording while the camera mic is metered, never during a calibration sample.
        #expect(IdleCaptureRules.watchesDetector(recording: false, check: nil, idleCameraMeter: true))
        #expect(!IdleCaptureRules.watchesDetector(recording: false, check: nil, idleCameraMeter: false))
        #expect(IdleCaptureRules.watchesDetector(recording: false, check: .check, idleCameraMeter: true))
        #expect(!IdleCaptureRules.watchesDetector(recording: false, check: .calibrateUnplugged, idleCameraMeter: true))
        #expect(IdleCaptureRules.watchesDetector(recording: true, check: nil, idleCameraMeter: false))
    }

    @Test func theMenuShowsTheMetersBeforeAndWhileRecording() {
        let idle: [AudioSource] = [.cameraMic, .screenMic]
        #expect(IdleCaptureRules.menuShowsMeters(recording: false, idle: true, checkRuns: false, sources: idle))
        // A mic check shows its own meters.
        #expect(!IdleCaptureRules.menuShowsMeters(recording: false, idle: true, checkRuns: true, sources: idle))
        #expect(!IdleCaptureRules.menuShowsMeters(recording: false, idle: true, checkRuns: false, sources: []))
        #expect(IdleCaptureRules.menuShowsMeters(recording: true, idle: false, checkRuns: false,
                                                 sources: [.cameraMic, .screenMic, .systemAudio]))
        // Starting and saving show none.
        #expect(!IdleCaptureRules.menuShowsMeters(recording: false, idle: false, checkRuns: false, sources: idle))
    }

    /// Decision 3: the meter runs along the bottom edge; the Reconnect button and the banner sit
    /// above it and never cover it.
    @Test func theWindowMeterIsAtTheBottomEdge() {
        let meterTop = CameraWindowLayout.meterInset + CameraWindowLayout.meterBarHeight + 2 * CameraWindowLayout.meterBackingPadding
        #expect(CameraWindowLayout.meterInset <= 8 && CameraWindowLayout.meterBarHeight >= 5)
        #expect(CameraWindowLayout.reconnectBottom(meter: true) > meterTop)
        #expect(CameraWindowLayout.bannerBottom(meter: true, reconnect: false) > meterTop)
        #expect(CameraWindowLayout.bannerBottom(meter: true, reconnect: true)
            >= CameraWindowLayout.reconnectBottom(meter: true) + CameraWindowLayout.reconnectSpace)
        // Without the meter, the old places.
        #expect(CameraWindowLayout.reconnectBottom(meter: false) == 8)
        #expect(CameraWindowLayout.bannerBottom(meter: false, reconnect: false) == 8)
        #expect(CameraWindowLayout.bannerBottom(meter: false, reconnect: true) == 38)
    }
}

/// Source-level guards for the idle capture wiring in the coordinator.
@Suite struct IdleCaptureWiringTests {
    static func code(_ name: String) throws -> [String] {
        let url = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/\(name)")
        return try ThreadRuleTests.codeLines(url).map(\.1)
    }

    /// Every preview pass feeds the debounce, and a closed camera opens only while something
    /// shows it now.
    @Test func thePreviewPassFollowsTheDemand() throws {
        let code = try Self.code("SessionCoordinator.swift")
        let pass = try #require(code.firstIndex { $0.contains("private func previewPass() async {") })
        let body = Array(code[pass...].prefix(12))
        #expect(body.contains { $0.contains("let decision = updateIdleDemand(wantedNow: wantedNow)") })
        #expect(body.contains { $0.contains("IdleCaptureRules.keepsOrOpens(decisionOpen: decision.open, wantedNow: wantedNow, isOpen: warm != nil)") })
        #expect(code.contains { $0.contains("takeActive: !state.canStart || checkUsesIdleMeters)") })
        // The pass ends with the camera mic meter and the idle Mac mic.
        let end = try #require(code[pass...].firstIndex { $0.contains("syncMacMic()") })
        #expect(code[pass..<end].contains { $0.contains("await syncIdleCameraMeter()") })
        // The debounce's pass is never cancelled: a cancelled task would cut the waits inside short.
        #expect(!code.contains { $0.contains("idleRecheck?.cancel()") })
    }

    /// Start closes the idle Mac mic before the screen recorder opens the same mic, with the
    /// plan's screen mic (the device refresh at Start may have changed it). A take without a screen
    /// mic (Camera mode) keeps it as the detector's reference. A start that preflight blocks
    /// leaves the idle Mac mic as it was: the settle comes after the blocker check.
    @Test func startClosesTheIdleMacMicFirst() throws {
        let code = try Self.code("SessionCoordinator.swift")
        let start = try #require(code.firstIndex { $0.contains("private func runStart(claimed: WarmCamera?) async {") })
        let plan = try #require(code[start...].firstIndex { $0.contains("let plan = makePlan()") })
        let blocker = try #require(code[start...].firstIndex { $0.contains("if let blocker = SessionRules.blockers(found).first {") })
        let follow = try #require(code[blocker...].firstIndex { $0.contains("await settleMacMicForTake()") })
        let prepare = try #require(code[start...].firstIndex { $0.contains("await Self.prepareAll(") })
        #expect(plan < blocker && blocker < follow && follow < prepare)
        #expect(!code[start..<blocker].contains { $0.contains("await settleMacMicForTake()") })
        #expect(code[blocker...follow].contains { $0.contains("takeRecordsScreenMic = plan.screen?.config.micDeviceUID != nil") })
        // The helper waits for the close unless the take has no screen mic.
        let helper = try #require(code.firstIndex { $0.contains("private func settleMacMicForTake() async {") })
        #expect(code[helper...].prefix(2).contains { $0.contains("if takeRecordsScreenMic == false { syncMacMic() } else { await closeIdleMacMic() }") })
        // The estimate is set before the state leaves idle, and cleared when it is idle again.
        let request = try #require(code.firstIndex { $0.contains("func requestStart() {") })
        let estimate = try #require(code[request...].firstIndex { $0.contains("takeRecordsScreenMic = settings.mode.includesScreen") })
        let preparing = try #require(code[request...].firstIndex { $0.contains("state = .preparing") })
        #expect(estimate < preparing)
        #expect(code.contains { $0.contains("if state.canStart { takeRecordsScreenMic = nil }") })
        // The idle Mac mic opens only while nothing records, or in a take without a screen mic.
        let uid = try #require(code.firstIndex { $0.contains("private var idleMacMicUID: String? {") })
        #expect(code[uid...].prefix(3).contains { $0.contains("guard IdleCaptureRules.macMicMayOpen(idle: state.canStart, takeRecordsScreenMic: takeRecordsScreenMic),") })
    }

    /// The mic check marks the devices it opens before anything awaits, and lets the idle path go
    /// of them before it opens its own sessions.
    @Test func theMicCheckNeverHoldsADeviceTwice() throws {
        let code = try Self.code("SessionCoordinator.swift")
        let start = try #require(code.firstIndex { $0.contains("func startMicCheck(_ purpose: MicCheckPurpose = .check) {") })
        let mark = try #require(code[start...].firstIndex { $0.contains("checkOwnSources = plan.own") })
        let task = try #require(code[start...].firstIndex { $0.contains("micCheckTask = Task {") })
        #expect(mark < task)
        let run = try #require(code.firstIndex { $0.contains("private func runMicCheck(id: UUID") })
        let release = try #require(code[run...].firstIndex { $0.contains("await releaseIdleMeters(plan.own)") })
        let check = try #require(code[run...].firstIndex { $0.contains("MicCheck(cameraAudioUID:") })
        #expect(release < check)
        #expect(code[run...].prefix(30).contains { $0.contains("live: plan.live)") })
        // The idle meters leave the devices the check holds alone.
        #expect(code.contains { $0.contains("checkOwnsCameraMic: checkOwnSources.contains(.cameraMic))") })
        #expect(code.contains { $0.contains("!checkOwnSources.contains(.screenMic) else { return nil }") })
    }

    /// After Stop the take's camera goes back to the metered preview only when a view shows the
    /// camera; otherwise it closes with the take.
    @Test func afterStopTheCameraKeepsItsMeterOnlyForAView() throws {
        let code = try Self.code("SessionCoordinator.swift")
        let back = try #require(code.firstIndex { $0.contains("private func returnCameraToPreviewAfterStop() {") })
        let body = Array(code[back...].prefix(8))
        #expect(body.contains { $0.contains("previewWanted: previewWantedOnceIdle") })
        #expect(body.contains { $0.contains("idleMeters: idleCameraMeterWanted(audioDeviceUID: audio))") })
        #expect(body.contains { $0.contains("meters: afterTake?.hasAudioMeter ?? false)") })
    }

    /// Display sleep, the screen lock and fast user switching close the camera and the idle mics:
    /// the window and the menu count only while the screen can show them.
    @Test func aSleepingScreenReleasesTheCamera() throws {
        let code = try Self.code("SessionCoordinator.swift")
        let launch = try #require(code.firstIndex { $0.contains("func launch() {") })
        #expect(code[launch...].prefix(40).contains { $0.contains("observeScreenPresence()") })
        for name in ["NSWorkspace.screensDidSleepNotification", "NSWorkspace.screensDidWakeNotification",
                     "NSWorkspace.willSleepNotification", "NSWorkspace.didWakeNotification",
                     "NSWorkspace.sessionDidResignActiveNotification", "NSWorkspace.sessionDidBecomeActiveNotification",
                     "\"com.apple.screenIsLocked\"", "\"com.apple.screenIsUnlocked\""] {
            #expect(code.contains { $0.contains(name) }, "\(name)")
        }
        #expect(code.contains { $0.contains("return IdleCaptureDemand.wanted(cameraWindowShown: seen && settings.cameraWindowShown,") })
        #expect(code.contains { $0.contains("menuPreviewShown: seen && menuVisible && settings.showCameraPreview,") })
        #expect(code.contains { $0.contains("!shuttingDown && settings.mode.includesCamera && screenCanShowCamera") })
        let changed = try #require(code.firstIndex { $0.contains("private func screenPresenceChanged() {") })
        let body = Array(code[changed...].prefix(8))
        #expect(body.contains { $0.contains("if seen { previewRetry = nil } else { idleDemand.closeNow() }") })
        #expect(body.contains { $0.contains("syncMacMic()") } && body.contains { $0.contains("await updatePreview()") })
    }

    /// The idle Mac mic does not wait for the camera's pass, and no wait in that pass is unbounded:
    /// a camera that hangs while it opens never keeps the Mac mic, or itself, open after the views go.
    @Test func noPreviewPassWaitsForeverAndTheMacMicHasItsOwnPass() throws {
        let code = try Self.code("SessionCoordinator.swift")
        for function in ["func setMenuVisible(_ visible: Bool) {", "func setCameraWindowShown(_ shown: Bool) {"] {
            let start = try #require(code.firstIndex { $0.contains(function) })
            #expect(code[start...].prefix(30).contains { $0.contains("syncMacMic()") }, "\(function)")
        }
        let debounce = try #require(code.firstIndex { $0.contains("self.idleRecheckAtNs = nil") })
        #expect(code[debounce...].prefix(3).contains { $0.contains("self.syncMacMic()") })
        let open = try #require(code.firstIndex { $0.contains("private func openWarmCamera(_ target: PreviewTarget) async {") })
        let body = Array(code[open...].prefix(50))
        #expect(body.contains { $0.contains("let outcome = await Self.waitAtMost(Self.prepareTimeout) { await prepared.value }") })
        #expect(body.contains { $0.contains("Task.detached { await recorder.teardown() }") })
        #expect(!body.contains { $0.contains("let failure = await prepared.value") })
        let meter = try #require(code.firstIndex { $0.contains("private func syncIdleCameraMeter() async {") })
        #expect(code[meter...].prefix(15).contains { $0.contains("await Self.waitAtMost(Self.meterChangeTimeout)") })
        let release = try #require(code.firstIndex { $0.contains("private func releaseIdleMeters(_ sources: Set<AudioSource>) async {") })
        #expect(code[release...].prefix(12).contains { $0.contains("await Self.waitAtMost(Self.meterChangeTimeout)") })
    }

    /// An idle Mac mic whose session stopped by itself (the mic unplugged) closes and opens again,
    /// and a Camera-mode take shows its meter.
    @Test func aStoppedMacMicIsReopenedAndShownInCameraMode() throws {
        let code = try Self.code("SessionCoordinator.swift")
        let pass = try #require(code.firstIndex { $0.contains("private func macMicPass() async {") })
        #expect(code[pass...].prefix(8).contains { $0.contains("if let meter = macMic, meter.micUID != uid || !meter.isOpen {") })
        #expect(code[pass...].prefix(16).contains { $0.contains("macMicFailure = (uid, nowNs)") })
        let refresh = try #require(code.firstIndex { $0.contains("private func refreshIdleMeterSources() {") })
        let body = Array(code[refresh...].prefix(10))
        #expect(body.contains { $0.contains("if !idle, takeRecordsScreenMic == false, let take = camera {") })
        #expect(body.contains { $0.contains("screenMic: macMic?.isOpen == true,") })
    }

    /// The camera window's meter is the bottom bar, not the old right-edge one.
    @Test func theWindowMeterIsHorizontal() throws {
        let code = try Self.code("CameraWindow.swift")
        #expect(code.contains { $0.contains("LevelMeterBar(level: coordinator.meters?.cameraMic, trackColor:") })
        #expect(!code.contains { $0.contains("vertical: true") })
        #expect(try ThreadRuleTests.violations(in: [ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/IdleCaptureRules.swift")]) == [])
    }
}
