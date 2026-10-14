import Foundation
import Testing
@testable import RecorderApp
@testable import Replay

@Suite struct ReplayRulesTests {
    let take = URL(fileURLWithPath: "/tmp/2026-10-14_120000")
    let last = URL(fileURLWithPath: "/tmp/2026-10-14_110000")

    /// While recording, Replay opens the take that records; idle, the last take; never while a
    /// take starts or saves (its files are being made or finished).
    @Test func replayOpensTheLiveTakeOrTheLastOne() {
        #expect(ReplayRules.target(state: .recording, activeFolder: take, lastFolder: last) == .live(take))
        #expect(ReplayRules.target(state: .idle, activeFolder: nil, lastFolder: last) == .last(last))
        #expect(ReplayRules.target(state: .error("x"), activeFolder: nil, lastFolder: last) == .last(last))
        #expect(ReplayRules.target(state: .idle, activeFolder: nil, lastFolder: nil) == .none(ReplayRules.nothingYet))
        #expect(ReplayRules.target(state: .preparing, activeFolder: take, lastFolder: last) == .none(ReplayRules.starting))
        #expect(ReplayRules.target(state: .stopping, activeFolder: take, lastFolder: last) == .none(ReplayRules.saving))
        #expect(ReplayRules.Target.live(take).isLive && !ReplayRules.Target.last(last).isLive)
        #expect(ReplayRules.Target.none("x").folder == nil)
    }

    @Test func theHelpSaysWhatAClickDoes() {
        #expect(ReplayRules.help(.live(take), shown: false).contains("while the take goes on (⌃⌥⌘P)"))
        #expect(ReplayRules.help(.live(take), shown: false).contains("Muted"))
        #expect(ReplayRules.help(.last(last), shown: false).contains("2026-10-14_110000"))
        #expect(ReplayRules.help(.live(take), shown: true).contains("The recording goes on."))
        #expect(ReplayRules.help(.none("Record a take first."), shown: false) == "Record a take first.")
        #expect(ReplayRules.title(folder: take, live: true) == "Replay · 2026-10-14_120000 · recording")
    }

    @Test func theStatusLineSaysWhatTheReplayWaitsFor() {
        var s = ReplaySnapshot()
        func status(live: Bool = true, saving: Bool = false, flagsOnly: Bool = false, flags: Int = 1,
                    skip: Bool = false, voice: Bool = true, notice: String? = nil) -> String? {
            ReplayRules.status(s, live: live, saving: saving, flagsOnly: flagsOnly, flagCount: flags, skipSilence: skip,
                               hasVoice: voice, notice: notice)
        }
        #expect(status(saving: true) == "Saving the take…")
        #expect(status() == "Waiting for the first movie fragment…")
        #expect(status(live: false) == "Opening…")
        s.ready = true
        s.edge = LiveEdge(isLive: true, recordedS: 100, availableS: 98.5)
        s.positionS = 97.25
        #expect(status() == "Live · 3 s behind")
        s.positionS = 40
        #expect(status() == "1:00 behind live")
        // Paused by itself because a recorder dropped frames: says so.
        let dropped = ReplayEvents.droppedFramesNotice([.camera])
        #expect(status(notice: dropped) == "Paused: camera.mov dropped frames. Play goes on.")
        #expect(status(flagsOnly: true, flags: 0) == "No flags yet.")
        #expect(status(skip: true, voice: false) == "No voice timeline: Skip silence plays everything.")
        s.waitingForSpeech = true
        #expect(status(skip: true) == "All speech so far played. Waiting for more…")
        s.waitingForSpeech = false
        s.holding = true
        #expect(status() == "Waiting for the next fragment…")
        s.holding = false
        s.ended = true
        #expect(status(flagsOnly: true) == "End of the flagged parts.")
        s.ended = false
        #expect(status(live: false) == nil)
        s.problem = "screen.mov could not be opened"
        #expect(status() == "screen.mov could not be opened")
    }

    @Test func replaySpeedsAreKeptToTheThreeChoices() {
        #expect(RecorderSettings.replaySpeeds == [1, 1.5, 2])
        #expect(RecorderSettings.validReplaySpeed(1.5) == 1.5)
        #expect(RecorderSettings.validReplaySpeed(3) == 1)
        #expect(RecorderSettings.validReplaySpeed(nil) == 1)
    }

    /// The replay window is main-thread app code: it is in the thread rule's scan, and it reads
    /// the movies only through the Replay module (no writer, no capture object).
    @Test func theReplayWindowOnlyReads() throws {
        let folder = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp")
        let files = ["ReplayWindow.swift", "ReplayRules.swift"].map { folder.appendingPathComponent($0) }
        #expect(try ThreadRuleTests.violations(in: files) == [])
        let code = try files.flatMap { try ThreadRuleTests.codeLines($0).map(\.1) }
        for word in ["AVAssetWriter", "AVCapture", "SCStream", "startWriting", "finishWriting"] {
            #expect(!code.contains { $0.contains(word) }, "\(word)")
        }
        let replay = ThreadRuleTests.root.appendingPathComponent("Sources/Replay")
        let replayFiles = try FileManager.default.contentsOfDirectory(at: replay, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(replayFiles.count >= 4)
        let replayCode = try replayFiles.flatMap { try ThreadRuleTests.codeLines($0).map(\.1) }
        for word in ["AVAssetWriter", "AVCapture", "SCStream", "DispatchSemaphore", ".sync {", ".sync(", ".wait("] {
            #expect(!replayCode.contains { $0.contains(word) }, "\(word)")
        }
        // The replay work runs below the recorders' user-interactive capture and writer queues.
        #expect(replayCode.contains { $0.contains(#"DispatchQueue(label: "TwinTake.replay", qos: .utility)"#) })
        #expect(replayCode.contains { $0.contains("panel.sharingType") } == false)
        let window = try ThreadRuleTests.codeLines(files[0]).map(\.1)
        #expect(window.contains { $0.contains("panel.sharingType = .none") })
        #expect(window.contains { $0.contains("panel.level = FrameOverlay.aboveOverlayLevel") })
        #expect(window.contains { $0.contains("override var canBecomeKey: Bool { false }") })
    }

    /// The controls follow the model: muted by default, Live only for a take that records, all
    /// greyed while the take saves; the timeline's length moves in whole seconds.
    @MainActor @Test func theControlsFollowTheModel() {
        let model = ReplayModel(files: [.screen, .camera], live: true, title: "t", speed: 1.5, skipSilence: true)
        var state = model.controlsState
        #expect(state.showsLive && state.enabled && state.speed == 1.5 && state.skipSilence && !state.soundOn)
        #expect(state.skipSilenceHelp.contains("no voice timeline"))
        model.hasVoice = true
        #expect(model.controlsState.skipSilenceHelp.contains("pauses longer than 1 s"))
        model.saving = true
        state = model.controlsState
        #expect(!state.enabled && !state.showsLive && state.status == "Saving the take…")
        model.saving = false
        model.live = false
        #expect(!model.controlsState.showsLive)
        model.flags = [FlagMark(atS: 10, lookbackS: 5)]
        #expect(model.controlsState.flagCount == 1)
        model.snapshot.edge = LiveEdge(isLive: false, recordedS: 120.4, availableS: 120.4)
        model.snapshot.positionS = 61
        #expect(model.timeText == "1:01 / 2:00")
        #expect(model.timelineData.endS == 121)
        #expect(model.timelineData.availableS == 120)
        model.scrubPosition = 5
        #expect(model.position == 5)
        // A pause for dropped frames shows until it plays again.
        model.snapshot.ready = true
        model.notice = ReplayEvents.droppedFramesNotice([.screen])
        #expect(model.status == "Paused: screen.mov dropped frames. Play goes on.")
        model.snapshot.playing = true
        #expect(model.status == nil)
    }
}
