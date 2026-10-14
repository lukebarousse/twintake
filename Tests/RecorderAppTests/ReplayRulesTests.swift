import AppKit
import Foundation
import Testing
@testable import RecorderApp
@testable import Replay
import WindowTools

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
        // Non-activating, with its close button inset; its sound pauses the mic detector's evidence.
        #expect(window.contains { $0.contains(".hudWindow, .nonactivatingPanel]") })
        #expect(window.contains { $0.contains("panel.insetCloseButton()") })
        #expect(window.contains { $0.contains("ReplayRules.pausesMicEvidence(") })
        #expect(window.contains { $0.contains("coordinator?.levels.setEvidencePaused(paused)") })
        // Each poll follows Play: a paused, ended or hidden replay lets the check go on.
        #expect(window.contains { $0.contains("updateEvidencePause(playing: played.playing)") })
        // A mic check hears the speaker only: the replay plays muted while it runs.
        #expect(window.contains { $0.contains("engine?.setSound(on && !micCheckRuns)") })
        let coordinator = try ThreadRuleTests.codeLines(folder.appendingPathComponent("SessionCoordinator.swift")).map(\.1)
        #expect(coordinator.contains { $0.contains("replay?.micCheckChanged(running: true)") })
        #expect(coordinator.contains { $0.contains("replay?.micCheckChanged(running: false)") })
    }

    /// The replay's sound pauses the mic check only while it can come out of the speakers. A saved
    /// take opened again after Stop (paused) with Sound on must not stop the check before the next
    /// take; a mic check runs with the replay muted.
    @Test func theReplayPausesTheMicCheckOnlyWhileItsSoundPlays() {
        func paused(engine: Bool = true, sound: Bool = true, playing: Bool = true, check: Bool = false) -> Bool {
            ReplayRules.pausesMicEvidence(engineOpen: engine, soundOn: sound, playing: playing, micCheckRuns: check)
        }
        #expect(paused())
        #expect(!paused(playing: false))  // Reopened after Stop with play: false, paused, ended, hidden.
        #expect(!paused(sound: false))
        #expect(!paused(engine: false))   // Closed, or the take saves.
        #expect(!paused(check: true))     // Muted during a mic check.
    }

    /// During a mic check the status says why nothing is heard, also while it plays; after the
    /// check, the usual status again.
    @MainActor @Test func aMicCheckMutesTheReplay() {
        let model = ReplayModel(files: [.screen, .camera], live: false, title: "t", speed: 1, skipSilence: false)
        model.snapshot.ready = true
        model.snapshot.playing = true
        model.soundOn = true
        model.micCheckMutes = true
        #expect(model.status == ReplayRules.micCheckMuted)
        model.soundOn = false
        #expect(model.status == nil)
        model.soundOn = true
        model.micCheckMutes = false
        #expect(model.status == nil)
    }

    /// At its default size the window shows the 16:9 picture 960 wide with no bars: the frame
    /// holds the title bar, the picture and the controls.
    @MainActor @Test func theDefaultSizeFitsTheWholePicture() {
        let content = NSPanel.contentRect(forFrameRect: NSRect(origin: .zero, size: ReplayWindowGeometry.defaultSize),
                                          styleMask: ReplayPanel.style)
        #expect(ReplayWindowGeometry.defaultSize.height - content.height == ReplayWindowGeometry.titleBarHeight)
        let picture = CGRect(x: 0, y: ReplayContentView.controlsHeight, width: content.width,
                             height: content.height - ReplayContentView.controlsHeight)
        #expect(picture.size == CGSize(width: 960, height: 540))
        #expect(ReplayWindowGeometry.fitted(CGSize(width: 1920, height: 1080), in: picture) == picture)
    }

    /// Luke: the bottom buttons touched the window's edges. Every control keeps 12 pt from the
    /// left, right and bottom edges and from the picture, and buttons in a row keep 8 pt apart, in
    /// the default window and in the smallest one, with every control showing.
    @MainActor @Test func theControlsKeepTheirInsets() throws {
        let view = ReplayControlsView(controller: nil)
        #expect(ReplayControlsView.height == 108 && ReplayContentView.controlsHeight == 108)
        var state = ReplayControlsState(playing: true, speed: 1.5, showsLive: true, atLive: true, skipSilence: true,
                                        flagsOnly: true, flagCount: 12, soundOn: true, timeText: "12:34 / 56:07")
        state.status = "Live · 3 s behind"
        view.apply(state, force: true)
        for width in [ReplayWindowGeometry.defaultSize.width, ReplayWindowGeometry.minSize.width] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: ReplayControlsView.height)
            view.layout()
            let shown = view.subviews.filter { !$0.isHidden && $0.frame.width > 0 }
            #expect(shown.count == view.subviews.count, "width \(width): every control shows")
            for sub in shown {
                let f = sub.frame
                #expect(f.minX >= 12 && f.maxX <= width - 12 && f.minY >= 12 && f.maxY <= ReplayControlsView.height - 12,
                        "width \(width): \(type(of: sub)) at \(f)")
            }
            let buttons = shown.filter { $0 is BarButton }
            #expect(buttons.count == 12)
            #expect(buttons.map(\.frame.minY).min() == 12)  // The bottom row: 12 pt above the edge.
            for a in buttons {
                for b in buttons where a !== b && a.frame.minY == b.frame.minY && a.frame.minX < b.frame.minX {
                    #expect(b.frame.minX - a.frame.maxX >= 8, "width \(width): \(a.frame) then \(b.frame)")
                }
            }
            // Nothing in a row overlaps anything else in it.
            for a in shown {
                for b in shown where a !== b && a.frame.intersects(b.frame) {
                    Issue.record("width \(width): \(a.frame) overlaps \(b.frame)")
                }
            }
        }
    }

    /// The close button sits 12 pt in from the left edge, centered in the title bar, and stays
    /// there when the window resizes or its title changes. The panel stays non-activating.
    @MainActor @Test func theCloseButtonIsInset() throws {
        _ = NSApplication.shared
        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel]
        let panel = ReplayPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: mask, backing: .buffered,
                                defer: false)
        panel.insetCloseButton()
        let original = try #require(panel.standardWindowButton(.closeButton))
        let bar = try #require(original.superview)
        #expect(original.isHidden)
        let close = try #require(bar.subviews.first { $0 is NSButton && $0 !== original && !$0.isHidden })
        func check(_ what: String) {
            panel.contentView?.superview?.layoutSubtreeIfNeeded()
            #expect(close.frame.minX == 12, "\(what): \(close.frame)")
            #expect(abs(close.frame.midY - bar.bounds.midY) <= 1, "\(what): \(close.frame) in \(bar.bounds)")
            #expect(original.isHidden, "\(what)")
        }
        check("open")
        panel.title = "Replay · 2026-10-14_093840 · recording"
        check("new title")
        panel.setFrame(NSRect(x: 0, y: 0, width: 480, height: 360), display: false)
        check("small")
        panel.insetCloseButton()  // Twice: still one copy.
        #expect(bar.subviews.filter { $0 is NSButton && !$0.isHidden }.count == 1)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel))
        #expect(ReplayWindowGeometry.closeButtonOrigin(button: CGSize(width: 10, height: 10), titleBar: CGSize(width: 960, height: 24))
                    == CGPoint(x: 12, y: 7))
        panel.close()
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
