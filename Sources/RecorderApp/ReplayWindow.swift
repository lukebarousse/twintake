import AppKit
import AVFoundation
import RecorderCore
import Replay
import WindowTools

/// What the replay window plays: the take that records now (`live`), or a saved take.
struct ReplaySource: Equatable {
    var folder: URL
    var live: Bool
}

/// The replay window: what was just said, with the screen, while the take goes on.
///
/// - screen.mov is the main picture and camera.mov sits in its bottom-right corner, like the
///   camera window over the screen. A Camera or Screen take shows its one picture.
/// - The timeline covers the whole take so far; the replay opens at its last 60 s and stays about
///   one movie fragment (2 s) behind live (`LiveEdge`). Play, ±10 s, 1x / 1.5x / 2x, Live, Skip
///   silence, Flags only with the next and previous flag, and Sound.
/// - Muted by default: the speakers would be in the Rode and the MacBook mic. Sound on shows
///   "Use headphones". During a take, `replay_start`, `replay_end` and `replay_sound` go to
///   events.jsonl, so the editor cuts the stretch spent in the replay. While it plays with Sound
///   on, the camera mic detector takes no evidence (`ReplayRules.pausesMicEvidence`). During a mic
///   check it plays muted (Sound stays on for after the check).
/// - It only reads the files (`ReplayEngine`): no writer, capture or session change. At Stop it
///   lets go of the files while they are finished, and opens the saved take again after Saving.
/// - A non-activating panel that never becomes key: opening it or clicking it never takes the
///   focus from the recorded app. At the camera window's level (`FrameOverlay.aboveOverlayLevel`).
///   Never in screen.mov: `sharingType = .none`, and the screen recorder leaves TwinTake out (its
///   audio too: `excludesCurrentProcessAudio`). It remembers its place and size on each display.
///   Closing it closes only the replay: the recording goes on.
/// - Hidden (the display asleep or the screen locked): nothing plays or decodes. Closed: the
///   players are released. While the timeline is dragged, only keyframes are decoded.
/// - The recording comes first: when a recorder logs `dropped_frames` while the replay plays, the
///   replay pauses and says so.
///
/// Camera thread rule (CameraCapture/CaptureThreads.swift): this window holds no capture object.
@MainActor
final class ReplayController: NSObject, NSWindowDelegate {
    private weak var coordinator: SessionCoordinator?
    private var panel: ReplayPanel?
    private var container: ReplayContentView?
    private var picture: ReplayPictureView?
    private var controls: ReplayControlsView?
    private var engine: ReplayEngine?
    private(set) var model: ReplayModel?
    private(set) var source: ReplaySource?
    private var tail: EventsTail?
    private var info = ReplayTakeInfo()
    private var poll: Task<Void, Never>?
    /// The replay's stretch of a take that records, for `replay_start` / `replay_end`.
    private var stretch: Stretch?
    /// The take is being saved: the files are let go until it is.
    private var saving = false
    private var positionBeforeSave: Double?
    private var scrub: (wasPlaying: Bool, lastSeekNs: UInt64)?
    /// Host time the replay of a live take opened: its `dropped_frames` events count from here.
    private var openedAtNs: UInt64 = 0
    /// A mic check runs: the replay plays without its sound (`micCheckChanged(running:)`).
    private var micCheckRuns = false
    /// What this window last told the camera mic detector (`updateEvidencePause`).
    private var evidencePaused = false

    private struct Stretch {
        var openedAtS: Double
        var soundOnSinceS: Double?
        var soundOnS: Double
    }

    /// While scrubbing, a seek at most this often.
    static let scrubSeekIntervalNs: UInt64 = 120_000_000

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    var isShown: Bool { panel?.isVisible == true }

    // MARK: - Open and close

    /// Shows the replay of `source`. A replay of another take closes first.
    func show(_ source: ReplaySource) {
        if isShown, self.source == source {
            panel?.orderFrontRegardless()
            return
        }
        if engine != nil || model != nil { tearDown(reason: .closed) }
        let panel = self.panel ?? makePanel()
        open(source, at: nil, play: true)
        if !panel.isVisible {
            if let frame = openingFrame() { panel.setFrame(frame, display: false) }
            // Never key, never activating: the recorded app keeps the keyboard.
            panel.orderFrontRegardless()
        }
        coordinator?.replayShownChanged(true)
    }

    /// Closes the replay. The recording, if any, goes on.
    func close() {
        guard panel?.isVisible == true || model != nil else { return }
        saveFrame()
        tearDown(reason: .closed)
        panel?.orderOut(nil)
        coordinator?.replayShownChanged(false)
    }

    /// Quit: closes the window for good.
    func closeForGood() {
        close()
        panel?.close()
        panel = nil
        container = nil
    }

    /// The take started, stopped or was saved.
    func takeStateChanged(_ state: SessionCoordinator.State) {
        guard model != nil, let source else { return }
        switch state {
        case .preparing:
            // A new take starts: a replay of the last one closes.
            close()
        case .stopping where source.live:
            // replay_end goes in before session_stop; then the files are let go while they finish.
            endStretch(.stop)
            positionBeforeSave = engine?.snapshot.positionS
            poll?.cancel()
            poll = nil
            engine?.close()
            engine = nil
            updateEvidencePause()
            saving = true
            model?.saving = true
            model?.snapshot.playing = false
            render()
        case .idle, .error:
            guard saving else { return }
            saving = false
            open(ReplaySource(folder: source.folder, live: false), at: positionBeforeSave, play: false)
        default:
            break
        }
    }

    private func open(_ source: ReplaySource, at position: Double?, play: Bool) {
        guard let coordinator, let container else { return }
        let settings = coordinator.settings
        let files = ReplayTakeFiles.find(in: source.folder)
        let previous = model
        let model = ReplayModel(files: files.files, live: source.live,
                                title: ReplayRules.title(folder: source.folder, live: source.live),
                                speed: previous?.speed ?? settings.replaySpeed,
                                skipSilence: previous?.skipSilence ?? settings.replaySkipSilence)
        model.flagsOnly = previous?.flagsOnly ?? false
        model.soundOn = previous?.soundOn ?? false
        model.micCheckMutes = micCheckRuns
        self.model = model
        self.source = source
        panel?.title = model.title
        let picture = ReplayPictureView(files: files.files)
        picture.onClick = { [weak self] in self?.togglePlay() }
        container.setPicture(picture)
        let controls = ReplayControlsView(controller: self)
        container.setControls(controls)
        self.picture = picture
        self.controls = controls
        info = ReplayTakeInfo()
        if source.live {
            openedAtNs = HostClock.nowNs()
            let tail = EventsTail(url: SessionFolder(url: source.folder).eventsURL)
            self.tail = tail
            info.apply(tail.readNew())
            // The speech so far, before the engine starts, so Skip silence applies from the start.
            if let started = info.startedAtHostNs {
                let timeline = coordinator.levels.voiceTimeline()
                model.speech = SkipSilence.speech(timeline, startedAtHostNs: started)
                model.hasVoice = timeline.preferredSource != nil
            }
            start(files: files, live: true, at: position, play: play)
            beginStretch()
        } else {
            tail = nil
            Task { [weak self] in
                let loaded = await Task.detached(priority: .userInitiated) { files.loadFinished() }.value
                guard let self, self.source == source, self.model === model else { return }
                self.info = loaded.info
                if let voice = loaded.voice, let origin = loaded.info.startedAtHostNs ?? loaded.voiceOriginNs {
                    model.speech = SkipSilence.speech(voice, startedAtHostNs: origin)
                    model.hasVoice = voice.preferredSource != nil
                }
                model.flags = loaded.info.flags
                self.start(files: files, live: false, at: position, play: play)
                self.render()
            }
        }
        render()
    }

    private func start(files: ReplayTakeFiles, live: Bool, at position: Double?, play: Bool) {
        guard let model, let picture else { return }
        let engine = ReplayEngine(files: files, isLive: live, info: info, video: picture.outputs)
        self.engine = engine
        engine.setSpeed(model.speed)
        engine.setPlan(plan(model))
        if model.soundOn, !micCheckRuns { engine.setSound(true) }
        engine.start(at: position, play: play)
        if let panel { engine.setVisible(panel.occlusionState.contains(.visible) || !panel.isVisible) }
        model.flags = info.flags
        updateEvidencePause(playing: play)
        startPolling()
    }

    /// The replay's sound from the speakers reaches the Rode and the MacBook mic: while it plays
    /// with Sound on, the camera mic detector takes no evidence (before recording and in a take).
    /// Called on each poll, so a pause, the end of the take or a hidden window lets the check
    /// go on.
    /// - Parameter playing: Play as just asked or read; nil reads the engine's snapshot.
    private func updateEvidencePause(playing: Bool? = nil) {
        let paused = ReplayRules.pausesMicEvidence(engineOpen: engine != nil, soundOn: model?.soundOn == true,
                                                   playing: playing ?? (engine?.snapshot.playing == true),
                                                   micCheckRuns: micCheckRuns)
        guard paused != evidencePaused else { return }
        evidencePaused = paused
        coordinator?.levels.setEvidencePaused(paused)
    }

    /// A mic check started or ended (idle only: a check never runs during a take). While it runs,
    /// the replay plays without its sound, so the check (and a calibration sample) hears only the
    /// speaker, not the speakers; Sound stays on and comes back after it.
    func micCheckChanged(running: Bool) {
        guard micCheckRuns != running else { return }
        micCheckRuns = running
        model?.micCheckMutes = running
        if let model { engine?.setSound(model.soundOn && !running) }
        updateEvidencePause()
        render()
    }

    private func tearDown(reason: ReplayEvents.EndReason) {
        endStretch(reason)
        poll?.cancel()
        poll = nil
        engine?.close()
        engine = nil
        container?.setPicture(nil)
        container?.setControls(nil)
        picture = nil
        controls = nil
        model = nil
        source = nil
        tail = nil
        saving = false
        positionBeforeSave = nil
        scrub = nil
        updateEvidencePause()
    }

    // MARK: - Updates

    /// About 10 times a second: the engine's position for the window. Once a second for a live
    /// take: new events (the files' first frames, flags) and the voice timeline.
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.refresh(readTake: tick % 10 == 0)
                tick += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func refresh(readTake: Bool) {
        guard let model, let engine else { return }
        let played = engine.snapshot
        var snapshot = played
        // While the timeline is dragged the engine pauses; the button keeps what it was.
        if let scrub { snapshot.playing = scrub.wasPlaying }
        if model.snapshot != snapshot { model.snapshot = snapshot }
        updateEvidencePause(playing: played.playing)
        render()
        guard readTake, let source, source.live, let tail else { return }
        Task { [weak self] in
            let events = await Task.detached(priority: .utility) { tail.readNew() }.value
            self?.applyLiveTake(events, source: source)
        }
    }

    private func applyLiveTake(_ events: [SessionEvent], source: ReplaySource) {
        guard self.source == source, let model, let engine, let coordinator else { return }
        if !events.isEmpty {
            info.apply(events)
            engine.setTakeInfo(info)
            if model.flags != info.flags { model.flags = info.flags }
            // A recorder dropped frames while the replay played: pause it, the recording comes first.
            let dropped = ReplayEvents.droppedFrames(events, sinceNs: openedAtNs)
            if !dropped.isEmpty, engine.snapshot.playing, scrub == nil {
                engine.pause()
                model.notice = ReplayEvents.droppedFramesNotice(dropped)
            }
        }
        if let started = info.startedAtHostNs {
            let timeline = coordinator.levels.voiceTimeline()
            let speech = SkipSilence.speech(timeline, startedAtHostNs: started)
            if speech != model.speech { model.speech = speech }
            let voiced = timeline.preferredSource != nil
            if voiced != model.hasVoice { model.hasVoice = voiced }
        }
        engine.setPlan(plan(model))
        render()
    }

    /// The controls and the timeline for the model now (each skips a redraw when nothing changed).
    private func render() {
        guard let model, let controls else { return }
        controls.apply(model.controlsState)
        controls.timeline.apply(model.timelineData, positionS: model.position)
    }

    private func plan(_ model: ReplayModel) -> ReplayEngine.Plan {
        ReplayEngine.Plan(speech: model.speech, flags: model.flags, skipSilence: model.skipSilence, flagsOnly: model.flagsOnly)
    }

    // MARK: - Controls

    func togglePlay() {
        guard let engine, !saving else { return }
        model?.notice = nil
        let wasPlaying = engine.snapshot.playing
        engine.togglePlay()
        // Playing from here: no evidence from now (the poll would see it up to 0.1 s later).
        if !wasPlaying { updateEvidencePause(playing: true) }
    }

    func skip(_ seconds: Double) {
        model?.notice = nil
        engine?.skip(by: seconds)
    }

    func jumpToLive() {
        model?.notice = nil
        engine?.jumpToLive()
    }

    func nextFlag() { engine?.nextFlag() }
    func previousFlag() { engine?.previousFlag() }

    func setSpeed(_ speed: Double) {
        guard let model else { return }
        model.speed = RecorderSettings.validReplaySpeed(speed)
        coordinator?.settings.replaySpeed = model.speed
        engine?.setSpeed(model.speed)
        render()
    }

    func setSkipSilence(_ on: Bool) {
        guard let model else { return }
        model.skipSilence = on
        coordinator?.settings.replaySkipSilence = on
        engine?.setPlan(plan(model))
        render()
    }

    func setFlagsOnly(_ on: Bool) {
        guard let model else { return }
        model.flagsOnly = on
        engine?.setPlan(plan(model))
        // Into the first flag stretch at or after the picture (the transport jumps there on play).
        if on, let first = FlagsOnly.spans(model.flags).first(where: { $0.end > model.position })?.start,
           first > model.position {
            engine?.seek(to: first)
        }
        render()
    }

    /// Sound on or off. Logged during a take: the replay's sound may be in the mics.
    func setSound(_ on: Bool) {
        guard let model, model.soundOn != on else { return }
        model.soundOn = on
        engine?.setSound(on && !micCheckRuns)
        updateEvidencePause()
        render()
        guard source?.live == true, !saving, let elapsed = coordinator?.takeElapsedS else { return }
        coordinator?.logReplay(.replaySound, ReplayEvents.soundData(on: on, elapsedS: elapsed))
        if var s = stretch {
            if on {
                s.soundOnSinceS = elapsed
            } else if let since = s.soundOnSinceS {
                s.soundOnS += max(0, elapsed - since)
                s.soundOnSinceS = nil
            }
            stretch = s
        }
    }

    /// The timeline is dragged: the picture follows, at most every 120 ms, with keyframes only
    /// (one frame to decode per step); the exact frame comes at the end, and it plays on then when
    /// it played before.
    func scrub(to positionS: Double) {
        guard let engine, let model else { return }
        let now = HostClock.nowNs()
        if scrub == nil {
            scrub = (model.snapshot.playing, 0)
            engine.pause()
        }
        model.scrubPosition = positionS
        render()
        guard let last = scrub, now &- last.lastSeekNs > Self.scrubSeekIntervalNs else { return }
        scrub?.lastSeekNs = now
        engine.preview(at: positionS)
    }

    func endScrub(at positionS: Double) {
        guard let engine, let model else { return }
        let resume = scrub?.wasPlaying ?? model.snapshot.playing
        scrub = nil
        model.notice = nil
        model.scrubPosition = nil
        model.snapshot.positionS = positionS
        engine.seek(to: positionS, play: resume)
        render()
    }

    // MARK: - Events

    private func beginStretch() {
        guard let source, source.live, let coordinator, let model, let elapsed = coordinator.takeElapsedS else { return }
        let opening = LiveEdge(isLive: true, recordedS: elapsed, availableS: elapsed).openingPosition()
        stretch = Stretch(openedAtS: elapsed, soundOnSinceS: model.soundOn ? elapsed : nil, soundOnS: 0)
        coordinator.logReplay(.replayStart, ReplayEvents.startData(elapsedS: elapsed, positionS: opening, sound: model.soundOn,
                                                                   skipSilence: model.skipSilence, flagsOnly: model.flagsOnly))
    }

    private func endStretch(_ reason: ReplayEvents.EndReason) {
        guard let s = stretch else { return }
        stretch = nil
        guard let coordinator, let elapsed = coordinator.takeElapsedS else { return }
        let soundOn = s.soundOnS + (s.soundOnSinceS.map { max(0, elapsed - $0) } ?? 0)
        coordinator.logReplay(.replayEnd, ReplayEvents.endData(elapsedS: elapsed, openS: max(0, elapsed - s.openedAtS),
                                                               soundOnS: soundOn, reason: reason))
    }

    // MARK: - Panel

    private func makePanel() -> ReplayPanel {
        let size = NSPanel.contentRect(forFrameRect: NSRect(origin: .zero, size: ReplayWindowGeometry.defaultSize),
                                       styleMask: ReplayPanel.style).size
        let panel = ReplayPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: ReplayPanel.style,
                                backing: .buffered, defer: false)
        // The camera window's level: above the dim around the frame, under other apps' menus.
        panel.level = FrameOverlay.aboveOverlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Never in screen.mov, also for a capture that does not leave TwinTake out.
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.contentMinSize = ReplayWindowGeometry.minSize
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "Replay"
        panel.delegate = self
        panel.insetCloseButton()
        let container = ReplayContentView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        self.panel = panel
        self.container = container
        return panel
    }

    private func openingFrame() -> CGRect? {
        guard let coordinator else { return nil }
        let settings = coordinator.settings
        return ReplayWindowGeometry.openingFrame(screens: CameraWindowController.screens(), saved: settings.replayWindowFrames,
                                                 lastScreenUUID: settings.replayWindowLastDisplay,
                                                 frameDisplayUUID: coordinator.recordingFrameDisplayUUID)
    }

    /// Keeps the window on its screen and saves its place there.
    private func saveFrame() {
        guard let panel, panel.isVisible, let settings = coordinator?.settings else { return }
        let screens = CameraWindowController.screens()
        if let kept = ReplayWindowGeometry.clamped(panel.frame, screens: screens), kept != panel.frame {
            panel.setFrame(kept, display: true)
        }
        guard let screen = CameraWindowGeometry.screen(containing: panel.frame, in: screens) else { return }
        settings.replayWindowFrames[screen.uuid] = CameraWindowGeometry.local(panel.frame, on: screen)
        settings.replayWindowLastDisplay = screen.uuid
    }

    /// After a display change: keeps the window on screen, or moves it to its place on a
    /// connected display when its display went away.
    func screensChanged() {
        guard let panel, panel.isVisible else { return }
        if let kept = ReplayWindowGeometry.clamped(panel.frame, screens: CameraWindowController.screens()) {
            if kept != panel.frame { panel.setFrame(kept, display: true) }
        } else if let frame = openingFrame() {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: NSWindowDelegate

    /// The close button only closes the replay (the panel is kept for the next open).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    /// Fully covered, or the display asleep: nothing decodes until it shows again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let panel else { return }
        engine?.setVisible(panel.occlusionState.contains(.visible))
    }
}

// MARK: - Model

/// What the replay window shows. The controller fills it and pushes it to the controls.
@MainActor
final class ReplayModel {
    let files: [ReplayFileKind]
    var live: Bool
    var title: String
    var snapshot = ReplaySnapshot()
    /// Speech stretches in take time (the voice timeline), for Skip silence and the timeline.
    var speech: [TimeSpan] = []
    var hasVoice = false
    var flags: [FlagMark] = []
    var skipSilence: Bool
    var flagsOnly = false
    var soundOn = false
    var speed: Double
    var saving = false
    /// Why the replay paused by itself (a recorder dropped frames), until the next play or seek.
    var notice: String?
    /// A mic check runs: the replay plays without its sound (`ReplayController.micCheckChanged`).
    var micCheckMutes = false
    /// The timeline's position while it is dragged.
    var scrubPosition: Double?

    init(files: [ReplayFileKind], live: Bool, title: String, speed: Double, skipSilence: Bool) {
        self.files = files; self.live = live; self.title = title; self.speed = speed; self.skipSilence = skipSilence
    }

    var position: Double { scrubPosition ?? snapshot.positionS }
    /// The timeline's length in whole seconds, so its drawing changes once a second, not with
    /// every position update.
    var timelineEnd: Double { max(1, snapshot.edge.timelineEndS.rounded(.up)) }

    var status: String? {
        ReplayRules.status(snapshot, live: live && !saving, saving: saving, flagsOnly: flagsOnly, flagCount: flags.count,
                           skipSilence: skipSilence, hasVoice: hasVoice,
                           notice: micCheckMutes && soundOn ? ReplayRules.micCheckMuted : snapshot.playing ? nil : notice)
    }

    var timeText: String { "\(ReplayClock.string(position)) / \(ReplayClock.string(snapshot.edge.timelineEndS))" }
}

// MARK: - Window

/// The replay window. It never becomes key or main, so it never takes the keyboard or makes
/// TwinTake active; its buttons take the first click. Its close button sits 12 pt in from the
/// left edge (`ReplayWindowGeometry.closeButtonOrigin`), not in the window's rounded corner.
final class ReplayPanel: NSPanel {
    /// A small HUD title bar with only the close button; resizable; never activates TwinTake.
    static let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel]

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The close button in its place: a copy of the title bar's own (same look), since AppKit puts
    /// the original back in the corner each time it lays out the title bar (a resize, a new title).
    private var insetClose: NSButton?

    /// Hides the title bar's close button and shows the same button 12 pt in from the left edge.
    func insetCloseButton() {
        guard insetClose == nil, let original = standardWindowButton(.closeButton), let bar = original.superview,
              let button = NSWindow.standardWindowButton(.closeButton, for: styleMask) else { return }
        original.isHidden = true
        button.setFrameOrigin(ReplayWindowGeometry.closeButtonOrigin(button: button.frame.size, titleBar: bar.bounds.size))
        // Keeps its distance from the left and the top edge when the window resizes.
        button.autoresizingMask = [.maxXMargin, .minYMargin]
        button.target = self
        button.action = #selector(closeClicked(_:))
        button.toolTip = "Close the replay. The recording goes on."
        button.setAccessibilityRole(.button)
        button.setAccessibilitySubrole(.closeButton)
        button.setAccessibilityLabel("Close")
        bar.addSubview(button)
        insetClose = button
    }

    /// Like the title bar's own button: the delegate decides (the replay closes, the panel stays).
    @objc private func closeClicked(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }
}

/// The picture on top, the controls under it.
final class ReplayContentView: NSView {
    static let controlsHeight: CGFloat = ReplayControlsView.height
    private var picture: NSView?
    private var controls: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPicture(_ view: NSView?) {
        picture?.removeFromSuperview()
        picture = view
        guard let view else { return }
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: controls)
        needsLayout = true
    }

    func setControls(_ view: NSView?) {
        controls?.removeFromSuperview()
        controls = view
        guard let view else { return }
        view.autoresizingMask = [.width, .maxYMargin]
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = min(Self.controlsHeight, bounds.height)
        controls?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        picture?.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    }
}

/// The two pictures on AVSampleBufferDisplayLayers: screen.mov fills the view, camera.mov sits in
/// its bottom-right corner. A click plays or pauses.
final class ReplayPictureView: NSView {
    private let screenLayer: AVSampleBufferDisplayLayer?
    private let cameraLayer: AVSampleBufferDisplayLayer?
    var onClick: (() -> Void)?

    init(files: [ReplayFileKind]) {
        screenLayer = files.contains(.screen) ? AVSampleBufferDisplayLayer() : nil
        cameraLayer = files.contains(.camera) ? AVSampleBufferDisplayLayer() : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for display in [screenLayer, cameraLayer].compactMap({ $0 }) {
            display.videoGravity = .resizeAspect
            display.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(display)
        }
        if let cameraLayer, screenLayer != nil {
            cameraLayer.cornerRadius = 8
            cameraLayer.masksToBounds = true
            cameraLayer.borderWidth = 1
            cameraLayer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
        toolTip = "Click to play or pause."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The renderers for the engine, one per picture.
    var outputs: [ReplayEngine.VideoOutput] {
        var out: [ReplayEngine.VideoOutput] = []
        if let screenLayer { out.append(ReplayEngine.VideoOutput(file: .screen, renderer: screenLayer.sampleBufferRenderer)) }
        if let cameraLayer { out.append(ReplayEngine.VideoOutput(file: .camera, renderer: cameraLayer.sampleBufferRenderer)) }
        return out
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let screenLayer {
            screenLayer.frame = bounds
            let shown = ReplayWindowGeometry.fitted(CGSize(width: 16, height: 9), in: bounds)
            cameraLayer?.frame = ReplayWindowGeometry.cameraInset(in: shown)
        } else {
            cameraLayer?.frame = bounds
        }
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Controls

/// What the controls show: plain data, compared before each redraw.
struct ReplayControlsState: Equatable {
    var enabled = true
    var playing = false
    var speed = 1.0
    var showsLive = false
    var atLive = false
    var skipSilence = false
    var skipSilenceHelp = ""
    var flagsOnly = false
    var flagCount = 0
    var soundOn = false
    var timeText = "0:00 / 0:00"
    var status: String?
}

/// The timeline's data: changes about once a second.
struct ReplayTimelineData: Equatable {
    var speech: [TimeSpan] = []
    var flags: [FlagMark] = []
    var availableS = 0.0
    var endS = 1.0
}

extension ReplayModel {
    var controlsState: ReplayControlsState {
        ReplayControlsState(enabled: !saving, playing: snapshot.playing, speed: speed, showsLive: live && !saving,
                            atLive: snapshot.atLive, skipSilence: skipSilence,
                            skipSilenceHelp: hasVoice ? "Skip silence: jumps over pauses longer than 1 s and keeps 0.25 s around speech."
                                : "Skip silence: no voice timeline for this take yet, so everything plays.",
                            flagsOnly: flagsOnly, flagCount: flags.count, soundOn: soundOn, timeText: timeText, status: status)
    }

    var timelineData: ReplayTimelineData {
        ReplayTimelineData(speech: speech, flags: flags, availableS: snapshot.edge.availableS.rounded(.down), endS: timelineEnd)
    }
}

/// The timeline and the buttons under the picture, in AppKit like the control bar: every button
/// is a `BarButton`, which takes the first click in this panel that never becomes key.
final class ReplayControlsView: NSView {
    /// The timeline and two rows of buttons, 12 pt in from every edge (`ReplayControlsLayout`).
    static let height: CGFloat = ReplayControlsLayout.height

    private weak var controller: ReplayController?
    let timeline = ReplayTimelineView()
    private let back = BarButton()
    private let play = BarButton()
    private let forward = BarButton()
    private let speeds: [(speed: Double, button: BarButton)]
    private let live = BarButton()
    private let skipSilence = BarButton()
    private let flagsOnly = BarButton()
    private let previousFlag = BarButton()
    private let nextFlag = BarButton()
    private let flagCount = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let headphones = NSTextField(labelWithString: "Use headphones")
    private let sound = BarButton()
    private var state = ReplayControlsState()

    /// - Parameter controller: nil in tests (the buttons then do nothing).
    init(controller: ReplayController?) {
        self.controller = controller
        speeds = RecorderSettings.replaySpeeds.map { ($0, BarButton()) }
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        timeline.onScrub = { [weak self] t in self?.controller?.scrub(to: t) }
        timeline.onScrubEnd = { [weak self] t in self?.controller?.endScrub(at: t) }
        addSubview(timeline)

        configure(back, symbol: "gobackward.10", help: "Back 10 s", action: #selector(backClicked))
        configure(play, symbol: "play.fill", help: "Play", action: #selector(playClicked))
        configure(forward, symbol: "goforward.10", help: "Forward 10 s", action: #selector(forwardClicked))
        for (speed, button) in speeds {
            button.text = speed == 1.5 ? "1.5x" : "\(Int(speed))x"
            button.toolTip = "Play at \(button.text)"
            button.target = self
            button.action = #selector(speedClicked(_:))
            addSubview(button)
        }
        configure(live, symbol: "dot.radiowaves.left.and.right", help: "Jump to about \(Int(LiveEdge.liveDelayS.rounded())) s behind "
                  + "the recording: the newest part that can be played.", action: #selector(liveClicked))
        live.text = "Live"
        configure(skipSilence, symbol: nil, help: "", action: #selector(skipSilenceClicked))
        skipSilence.text = "Skip silence"
        configure(flagsOnly, symbol: nil, help: "Flags only: plays only the stretch each flag points at, its look-back and 10 s after it.",
                  action: #selector(flagsOnlyClicked))
        flagsOnly.text = "Flags only"
        configure(previousFlag, symbol: "backward.end.fill", help: "Previous flag", action: #selector(previousFlagClicked))
        configure(nextFlag, symbol: "forward.end.fill", help: "Next flag", action: #selector(nextFlagClicked))
        configure(sound, symbol: "speaker.slash.fill", help: "", action: #selector(soundClicked))
        sound.text = "Sound"
        for label in [flagCount, time, status, headphones] {
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.65)
        flagCount.font = .systemFont(ofSize: 11)
        flagCount.textColor = NSColor.white.withAlphaComponent(0.65)
        headphones.font = .systemFont(ofSize: 11, weight: .semibold)
        headphones.textColor = .systemOrange
        headphones.toolTip = ReplaySound.hint
        apply(ReplayControlsState(), force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(_ button: BarButton, symbol: String?, help: String, action: Selector) {
        if let symbol { button.setSymbol(symbol, size: 12) }
        button.toolTip = help
        button.target = self
        button.action = action
        addSubview(button)
    }

    func apply(_ next: ReplayControlsState, force: Bool = false) {
        guard force || next != state else { return }
        state = next
        play.setSymbol(next.playing ? "pause.fill" : "play.fill", size: 12)
        play.toolTip = next.playing ? "Pause" : "Play"
        for (speed, button) in speeds { button.selected = speed == next.speed }
        live.isHidden = !next.showsLive
        live.fill = next.atLive ? NSColor.systemRed.withAlphaComponent(0.75) : .clear
        skipSilence.selected = next.skipSilence
        skipSilence.toolTip = next.skipSilenceHelp
        flagsOnly.selected = next.flagsOnly
        previousFlag.isEnabled = next.enabled && next.flagCount > 0
        nextFlag.isEnabled = next.enabled && next.flagCount > 0
        flagCount.stringValue = next.flagCount == 1 ? "1 flag" : "\(next.flagCount) flags"
        sound.selected = next.soundOn
        sound.setSymbol(next.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill", size: 12)
        sound.toolTip = next.soundOn ? ReplaySound.hint : "Muted. \(ReplaySound.hint)"
        headphones.isHidden = !next.soundOn
        time.stringValue = next.timeText
        status.stringValue = next.status ?? ""
        for button in [back, play, forward, live, skipSilence, flagsOnly, sound] + speeds.map(\.button) {
            button.isEnabled = next.enabled
        }
        needsLayout = true
    }

    /// Every button keeps 12 pt from the window's edges and 8 pt from the next button
    /// (`ReplayControlsLayout`); groups of buttons sit 16 pt apart.
    override func layout() {
        super.layout()
        let grid = ReplayControlsLayout(size: bounds.size)
        let gap = ReplayControlsLayout.gap
        timeline.frame = grid.timeline
        /// Places `groups` of buttons from the left of `row` (hidden ones take no room).
        func place(_ groups: [[(view: NSView, width: CGFloat)]], row: Int) -> CGFloat {
            let shown = groups.map { $0.filter { !$0.view.isHidden } }
            let (frames, end) = grid.fromLeft(shown.map { $0.map(\.width) }, row: row)
            for (group, rects) in zip(shown, frames) {
                for (item, rect) in zip(group, rects) { item.view.frame = rect }
            }
            return end
        }
        // Row 0: transport, speeds, Live; the time and the status on the right.
        let transport: [(view: NSView, width: CGFloat)] = [(back, 30), (play, 34), (forward, 30)]
        let rates = speeds.map { (view: $0.button as NSView, width: $0.button.contentWidth(padding: 7)) }
        let end = place([transport, rates, [(live, live.contentWidth(padding: 8))]], row: 0)
        let timeWidth = ceil(time.intrinsicContentSize.width) + 2
        let statusWidth = max(0, min(ceil(status.intrinsicContentSize.width) + 2, grid.right - timeWidth - gap - (end + gap)))
        status.frame = grid.label(x: grid.right - statusWidth, width: statusWidth, row: 0)
        time.frame = grid.label(x: grid.right - statusWidth - (statusWidth > 0 ? gap : 0) - timeWidth, width: timeWidth, row: 0)
        // Row 1: Skip silence, Flags only, the flag arrows and the count; Sound on the right.
        let modes: [(view: NSView, width: CGFloat)] = [(skipSilence, skipSilence.contentWidth(padding: 8)),
                                                       (flagsOnly, flagsOnly.contentWidth(padding: 8))]
        let arrows = place([modes, [(previousFlag, 28), (nextFlag, 28)]], row: 1)
        let soundFrame = grid.fromRight([sound.contentWidth(padding: 8)], row: 1).frames[0]
        sound.frame = soundFrame
        let countWidth = max(0, min(ceil(flagCount.intrinsicContentSize.width) + 2, soundFrame.minX - gap - (arrows + gap)))
        flagCount.frame = grid.label(x: arrows + gap, width: countWidth, row: 1)
        // "Use headphones" between the count and Sound, cut short ("Use head…") in a narrow window.
        let hintRoom = soundFrame.minX - gap - (flagCount.frame.maxX + gap)
        let hintWidth = max(0, min(ceil(headphones.intrinsicContentSize.width) + 2, hintRoom))
        headphones.frame = grid.label(x: soundFrame.minX - gap - hintWidth, width: hintWidth, row: 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func backClicked() { controller?.skip(-10) }
    @objc private func playClicked() { controller?.togglePlay() }
    @objc private func forwardClicked() { controller?.skip(10) }
    @objc private func liveClicked() { controller?.jumpToLive() }
    @objc private func skipSilenceClicked() { controller?.setSkipSilence(!state.skipSilence) }
    @objc private func flagsOnlyClicked() { controller?.setFlagsOnly(!state.flagsOnly) }
    @objc private func previousFlagClicked() { controller?.previousFlag() }
    @objc private func nextFlagClicked() { controller?.nextFlag() }
    @objc private func soundClicked() { controller?.setSound(!state.soundOn) }

    @objc private func speedClicked(_ sender: BarButton) {
        guard let speed = speeds.first(where: { $0.button === sender })?.speed else { return }
        controller?.setSpeed(speed)
    }
}

/// The whole take so far: what can be played, speech (green), flag stretches and flags (orange),
/// and the picture's position. Click or drag to go there. Takes the first click.
final class ReplayTimelineView: NSView {
    var onScrub: ((Double) -> Void)?
    var onScrubEnd: ((Double) -> Void)?
    private var data = ReplayTimelineData()
    private let playhead = NSView()
    private var positionS = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playhead.wantsLayer = true
        playhead.layer?.backgroundColor = NSColor.white.cgColor
        playhead.layer?.cornerRadius = 1.5
        addSubview(playhead)
        setAccessibilityLabel("Replay timeline")
        toolTip = "Click or drag to go to that moment of the take."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The drawing changes only with its data (about once a second); the playhead moves on its own.
    func apply(_ next: ReplayTimelineData, positionS: Double) {
        if next != data {
            data = next
            needsDisplay = true
        }
        self.positionS = positionS
        placePlayhead()
    }

    override func layout() {
        super.layout()
        placePlayhead()
    }

    private func placePlayhead() {
        let x = CGFloat(max(0, min(positionS, data.endS)) / max(data.endS, 1)) * bounds.width
        let frame = CGRect(x: min(max(0, x - 1.5), max(0, bounds.width - 3)), y: 0, width: 3, height: bounds.height)
        if playhead.frame != frame { playhead.frame = frame }
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.size
        let end = max(data.endS, 1)
        func x(_ t: Double) -> CGFloat { CGFloat(max(0, min(t, end)) / end) * size.width }
        let bar = CGRect(x: 0, y: size.height * 0.3, width: size.width, height: size.height * 0.4)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: bar.minY, width: x(data.availableS), height: bar.height), xRadius: 3, yRadius: 3).fill()
        // Speech, merged to whole points, so an hour of talking draws a few hundred rects.
        NSColor.systemGreen.withAlphaComponent(0.5).setFill()
        var run: (CGFloat, CGFloat)?
        for span in data.speech {
            let a = x(span.start).rounded(.down), b = max(x(span.end).rounded(.up), a + 1)
            if let r = run, a <= r.1 {
                run = (r.0, max(r.1, b))
            } else {
                if let r = run { CGRect(x: r.0, y: bar.minY, width: r.1 - r.0, height: bar.height).fill() }
                run = (a, b)
            }
        }
        if let r = run { CGRect(x: r.0, y: bar.minY, width: r.1 - r.0, height: bar.height).fill() }
        NSColor.systemOrange.withAlphaComponent(0.8).setFill()
        for span in FlagsOnly.spans(data.flags) {
            CGRect(x: x(span.start), y: size.height - 4, width: max(1, x(span.end) - x(span.start)), height: 4).fill()
        }
        NSColor.systemOrange.setFill()
        for flag in data.flags { CGRect(x: x(flag.atS) - 1, y: 0, width: 2, height: size.height).fill() }
    }

    private func time(at event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return max(0, min(1, Double(point.x / max(bounds.width, 1)))) * max(data.endS, 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onScrub?(time(at: event)) }
    override func mouseDragged(with event: NSEvent) { onScrub?(time(at: event)) }
    override func mouseUp(with event: NSEvent) { onScrubEnd?(time(at: event)) }
}
