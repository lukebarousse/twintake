import AVFoundation
import CoreMedia
import RecorderCore
import Synchronization

/// What the replay shows now. Plain data; the window polls it about 10 times a second.
public struct ReplaySnapshot: Sendable, Equatable {
    /// The movies are open and the picture is there.
    public var ready = false
    /// Take time of the picture.
    public var positionS = 0.0
    /// Play is on (the replay may still wait: `holding`, or a seek that loads).
    public var playing = false
    /// Waiting at the end of what can be read, for the next movie fragment.
    public var holding = false
    /// Played to the end of a finished take, or past the last flag stretch.
    public var ended = false
    /// Skip silence on a take that records: everything said so far was played; it plays on as
    /// soon as more speech can be played.
    public var waitingForSpeech = false
    /// The speed picked (1, 1.5 or 2) and the one it plays at (1 while it keeps up with live).
    public var speed = 1.0
    public var playingSpeed = 1.0
    public var edge = LiveEdge(isLive: false, recordedS: 0, availableS: 0)
    public var soundOn = false
    /// A movie could not be read.
    public var problem: String?

    public init() {}

    public var atLive: Bool { edge.isAtLive(positionS) }
}

/// Plays a take's camera.mov and screen.mov while they are written, on one timebase.
///
/// - Reading only: AVAssetReaders on AVFragmentedAssets. Nothing here writes a file, holds a
///   capture object or waits for a capture queue. All work runs on one serial queue at utility
///   QoS, below the recorders' user-interactive capture and writer queues.
/// - One `AVSampleBufferRenderSynchronizer`: the screen picture, the camera picture and (with
///   Sound on) the audio renderers share its timebase, on take time (each sample moved by its
///   file's offset, `MediaAlignment`), so the two pictures never drift apart.
/// - Video goes to the display layers as stored and is decoded there in hardware; nothing is
///   decoded while the replay is paused, hidden or closed.
/// - A live take: every 0.25 s (`LiveEdge.probeIntervalS`) a `FragmentProbe` looks for new movie
///   fragments; for each, the movie is opened again and the readers go on where they stopped
///   (`GrowingTrackReader`). An AVFragmentedAssetMinder minds the newest opening, and its duration
///   notification (where the system posts one) triggers the same reopen.
/// - A movie that stops growing while the take goes on (its writer finished it early: the camera
///   was disconnected; or it stalls while the other one grows) no longer holds the replay back:
///   the other picture plays on, and its own goes black past its end.
/// - A renderer that fails, or an audio renderer that flushes by itself (a speed change, a new
///   output), is fed again from the picture's time.
/// - The transport (every 50 ms): Skip silence and Flags only jumps (`PlaybackMask`), and the live
///   edge (`LiveEdge`): it waits at the end of what is readable and drops to 1x when it caught up.
///   Skip silence on a take that records waits after the last speech so far, and plays on when
///   more speech can be played.
///
/// Thread rule: every method is safe from any thread and never waits; the work runs on `queue`.
public final class ReplayEngine: @unchecked Sendable {
    /// A display layer's renderer for one picture. Made on the main thread with its layer.
    public struct VideoOutput: @unchecked Sendable {
        public let file: ReplayFileKind
        public let renderer: AVSampleBufferVideoRenderer
        public init(file: ReplayFileKind, renderer: AVSampleBufferVideoRenderer) {
            self.file = file
            self.renderer = renderer
        }
    }

    /// Skip silence and Flags only, with what they need.
    public struct Plan: Sendable, Equatable {
        public var speech: [TimeSpan]
        public var flags: [FlagMark]
        public var skipSilence: Bool
        public var flagsOnly: Bool

        public init(speech: [TimeSpan] = [], flags: [FlagMark] = [], skipSilence: Bool = false, flagsOnly: Bool = false) {
            self.speech = speech; self.flags = flags; self.skipSilence = skipSilence; self.flagsOnly = flagsOnly
        }

        /// Skip silence without any speech heard (no voice timeline yet, or none for this take)
        /// plays everything rather than nothing.
        public var mask: PlaybackMask {
            PlaybackMask.make(silence: skipSilence && !speech.isEmpty ? SkipSilence.keptSpans(speech: speech) : nil,
                              flags: flagsOnly ? FlagsOnly.spans(flags) : nil)
        }
    }

    public static let tickInterval: DispatchTimeInterval = .milliseconds(50)
    /// How often a live take's files are checked for new fragments, in ticks (0.25 s).
    static let growthEveryTicks = max(1, Int((LiveEdge.probeIntervalS / 0.05).rounded()))
    /// A live movie that has not grown for this long while another one grew is left out of the
    /// end of what is readable (4 fragments).
    static let staleAfterS = 8.0
    /// A finished movie's picture goes black this long past its end.
    static let blankAfterS = 0.25
    /// A play that has not started this long after it was asked for starts without waiting for
    /// the renderers to have enough data.
    static let startWatchdogS = 1.5

    public let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "TwinTake.replay", qos: .utility)
    private let files: ReplayTakeFiles
    private let isLive: Bool
    private let videoOutputs: [VideoOutput]
    private let published = Mutex(ReplaySnapshot())

    // Everything below is confined to `queue`.
    private var info: ReplayTakeInfo
    private var alignment: MediaAlignment
    private var movies: [ReplayFileKind: LoadedMovie] = [:]
    private var probes: [ReplayFileKind: FragmentProbe] = [:]
    private var loading: Set<ReplayFileKind> = []
    private var reloadWanted: Set<ReplayFileKind> = []
    private var minders: [ReplayFileKind: AVFragmentedAssetMinder] = [:]
    private var observers: [NSObjectProtocol] = []
    /// The audio renderers' flush notifications.
    private var audioObservers: [NSObjectProtocol] = []
    /// When each live movie last grew (its readable end moved on).
    private var grewAtNs: [ReplayFileKind: UInt64] = [:]
    private var video: [Feeder] = []
    private var audio: [Feeder] = []
    private var plan = Plan()
    private var mask = PlaybackMask.everything
    private var playing = false
    private var holding = false
    private var ended = false
    private var waitingForSpeech = false
    private var speed = 1.0
    /// Caught up with live at a faster speed: plays at 1x until the next seek or speed change.
    private var liveCapped = false
    private var soundOn = false
    private var visible = true
    private var resumeWhenVisible = false
    private var started = false
    private var closed = false
    private var problem: String?
    /// Where to go once every movie is open, and whether to play.
    private var pending: (target: Double?, play: Bool) = (nil, true)
    /// When play was last asked for, and at which position, for the start watchdog.
    private var playAskedAt: (hostNs: UInt64, positionS: Double)?
    /// The last seek: the synchronizer moves its timebase asynchronously, so for a moment its
    /// time is still the old one. Until it arrives, the position is the seek's target (so the
    /// transport never decides on the old time and seeks again).
    private var seekedTo: (targetS: Double, hostNs: UInt64)?
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    /// When `start` ran: a movie that stays unreadable longer than `beginWithoutS` is left out.
    private var startedAtNs: UInt64 = 0
    static let beginWithoutS = 6.0

    private var playingSpeed: Double { liveCapped ? 1 : speed }

    /// - Parameters:
    ///   - files: the take's folder and movies.
    ///   - isLive: the take records now (the files grow).
    ///   - info: what events.jsonl (and session.json) say so far.
    ///   - video: one renderer per picture the window shows.
    public init(files: ReplayTakeFiles, isLive: Bool, info: ReplayTakeInfo, video: [VideoOutput]) {
        self.files = files
        self.isLive = isLive
        self.info = info
        alignment = info.alignment
        videoOutputs = video.filter { files.files.contains($0.file) }
    }

    deinit { timer?.cancel() }

    /// What the replay shows now. Cheap: one lock and a small copy.
    public var snapshot: ReplaySnapshot { published.withLock { $0 } }

    // MARK: - Commands (any thread, never wait)

    /// Opens the movies and starts at `positionS` (nil: the last 60 s of the take so far).
    public func start(at positionS: Double?, play: Bool) {
        queue.async { [self] in
            guard !closed, timer == nil else { return }
            pending = (positionS, play)
            playing = play
            startedAtNs = HostClock.nowNs()
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
            for output in videoOutputs {
                synchronizer.addRenderer(output.renderer)
                let feeder = Feeder(file: output.file, reader: GrowingTrackReader(media: .video, trackIndex: 0,
                                                                                  offsetS: alignment.offset(output.file)),
                                    renderer: output.renderer)
                video.append(feeder)
            }
            if isLive { observeMinders() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            if !isLive { for kind in files.files { reload(kind) } }
            if files.files.isEmpty {
                problem = "No \(SessionFolder.cameraFileName) or \(SessionFolder.screenFileName) in \(files.folder.lastPathComponent): "
                    + "the take was moved or deleted."
            }
            publish()
        }
    }

    public func play() {
        queue.async { [self] in
            guard !closed else { return }
            resetFailures()
            if ended {
                // On from here when more plays now (a flag came in), else the next part, else from
                // the start.
                switch mask.resumeAfterEnd(at: position, playableEnd: makeEdge().playableEndS) {
                case let .jump(target):
                    seek(to: target, play: true)
                    return
                case .here:
                    ended = false
                }
            }
            if !started { pending.play = true }
            playing = true
            holding = false
            waitingForSpeech = false
            liveCapped = false
            setRate(playingSpeed, at: position)
            publish()
        }
    }

    public func pause() {
        queue.async { [self] in
            guard !closed else { return }
            if !started { pending.play = false }
            pauseHere()
            publish()
        }
    }

    public func togglePlay() {
        queue.async { [self] in
            guard !closed else { return }
            if playing { pause() } else { play() }
        }
    }

    /// Goes to take time `positionS` (kept inside what can be played), playing or paused as now.
    public func seek(to positionS: Double, play: Bool? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            resetFailures()
            liveCapped = false
            seek(to: positionS, play: play ?? playing)
        }
    }

    /// While the timeline is dragged: the picture at the keyframe at or before `positionS`, paused,
    /// with no sound. Only that frame is decoded (a full seek decodes from the keyframe to the
    /// target); the drag ends with `seek(to:play:)`.
    public func preview(at positionS: Double) {
        queue.async { [self] in
            guard !closed else { return }
            liveCapped = false
            let t = makeEdge().clamp(positionS)
            guard started else {
                pending = (t, false)
                playing = false
                return
            }
            pauseHere()
            ended = false
            synchronizer.setRate(0, time: CMTime(seconds: t, preferredTimescale: 90_000))
            seekedTo = (t, HostClock.nowNs())
            for feeder in video { restart(feeder, at: t, still: true) }
            for feeder in audio {
                feeder.stop()
                feeder.reader.cancel()
                feeder.renderer.flush()
                feeder.waiting = false
            }
            publish()
        }
    }

    public func skip(by seconds: Double) {
        queue.async { [self] in
            guard !closed else { return }
            resetFailures()
            liveCapped = false
            seek(to: position + seconds, play: playing)
        }
    }

    public func jumpToLive() {
        queue.async { [self] in
            guard !closed else { return }
            resetFailures()
            seek(to: makeEdge().liveTargetS, play: true)
        }
    }

    public func nextFlag() {
        queue.async { [self] in
            guard !closed, let target = FlagsOnly.next(after: position, in: plan.flags) else { return }
            resetFailures()
            liveCapped = false
            seek(to: target, play: playing)
        }
    }

    public func previousFlag() {
        queue.async { [self] in
            guard !closed, let target = FlagsOnly.previous(before: position, in: plan.flags) else { return }
            resetFailures()
            liveCapped = false
            seek(to: target, play: playing)
        }
    }

    public func setSpeed(_ value: Double) {
        queue.async { [self] in
            guard !closed, value > 0 else { return }
            speed = value
            liveCapped = false
            if playing, !holding, started { setRate(playingSpeed, at: position) }
            publish()
        }
    }

    /// Sound on: the dialogue and the computer sound play (`ReplaySound`). Off: nothing is read.
    public func setSound(_ on: Bool) {
        queue.async { [self] in
            guard !closed, on != soundOn else { return }
            soundOn = on
            if on { startAudio() } else { stopAudio() }
            publish()
        }
    }

    public func setPlan(_ newPlan: Plan) {
        queue.async { [self] in
            guard !closed, newPlan != plan else { return }
            let switched = newPlan.skipSilence != plan.skipSilence || newPlan.flagsOnly != plan.flagsOnly
            plan = newPlan
            mask = newPlan.mask
            if switched {
                ended = false
                if waitingForSpeech, !newPlan.skipSilence {
                    waitingForSpeech = false
                    if playing { setRate(playingSpeed, at: position) }
                }
            }
            publish()
        }
    }

    /// New events of a live take: the files' first frames, the audio tracks, flags.
    public func setTakeInfo(_ newInfo: ReplayTakeInfo) {
        queue.async { [self] in
            guard !closed, newInfo != info else { return }
            info = newInfo
            alignment = newInfo.alignment
            // Offsets come once, about 0.5 s into the take; a reader that started without one
            // shifts its later samples by those few ms.
            for feeder in video + audio { feeder.reader.offsetS = alignment.offset(feeder.file) }
        }
    }

    /// Hidden (fully covered, the display asleep): nothing plays or decodes until it shows again.
    public func setVisible(_ shown: Bool) {
        queue.async { [self] in
            guard !closed, shown != visible else { return }
            visible = shown
            if !shown {
                resumeWhenVisible = playing
                if playing { pauseHere() }
                for feeder in video + audio { feeder.stop() }
            } else {
                for feeder in video + audio where !feeder.waiting { feeder.start(on: queue, engine: self) }
                if resumeWhenVisible {
                    resumeWhenVisible = false
                    playing = true
                    setRate(playingSpeed, at: position)
                }
            }
            publish()
        }
    }

    /// Lets go of every reader, renderer and movie. The pictures keep their last frame. Safe to
    /// call more than once.
    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
            synchronizer.rate = 0
            for feeder in video + audio {
                feeder.stop()
                feeder.reader.cancel()
                feeder.renderer.flush()
            }
            for feeder in video + audio {
                synchronizer.removeRenderer(feeder.renderer, at: .invalid) { _ in }
            }
            video = []
            audio = []
            for (_, minder) in minders { for asset in minder.assets { minder.removeFragmentedAsset(asset) } }
            minders = [:]
            for token in observers + audioObservers { NotificationCenter.default.removeObserver(token) }
            observers = []
            audioObservers = []
            movies = [:]
            published.withLock { $0.playing = false }
        }
    }

    // MARK: - Transport (queue)

    private var position: Double {
        guard started else { return pending.target ?? 0 }
        let time = synchronizer.currentTime()
        let t = time.isNumeric ? time.seconds : 0
        if let seek = seekedTo {
            let age = Double(HostClock.nowNs() &- seek.hostNs) / 1e9
            if abs(t - seek.targetS) > 0.25 + age * playingSpeed, age < 0.5 { return seek.targetS }
            seekedTo = nil
        }
        return t
    }

    private func tick() {
        guard !closed else { return }
        ticks += 1
        if isLive, ticks % Self.growthEveryTicks == 1 { checkGrowth() }
        // One movie never became readable (its recorder failed): play the other one.
        if !started, !movies.isEmpty, Double(HostClock.nowNs() &- startedAtNs) / 1e9 > Self.beginWithoutS { begin() }
        if started, visible {
            checkRenderers()
            blankEndedPictures()
        }
        if started, playing, visible { drive() }
        publish()
    }

    private func drive() {
        let t = position
        let edge = makeEdge()
        if waitingForSpeech {
            switch mask.decision(at: t, playableEnd: edge.playableEndS) {
            case let .jump(target):
                waitingForSpeech = false
                seek(to: target, play: true)
            case .play:
                waitingForSpeech = false
                setRate(playingSpeed, at: t)
            case .end:
                break
            }
            return
        }
        if holding {
            if edge.action(at: t, rate: playingSpeed, holding: true) == .resume {
                holding = false
                setRate(playingSpeed, at: t)
            }
            return
        }
        switch mask.decision(at: t, playableEnd: edge.playableEndS) {
        case let .jump(target):
            seek(to: target, play: true)
            return
        case .end:
            if plan.flagsOnly || !edge.isLive {
                pauseHere()
                ended = true
            } else {
                // Skip silence on a take that records: everything said so far has played (the
                // speaker is likely watching this replay). Wait here for more speech.
                waitingForSpeech = true
                playAskedAt = nil
                synchronizer.rate = 0
            }
            return
        case .play:
            break
        }
        switch edge.action(at: t, rate: playingSpeed, holding: false) {
        case .hold:
            holding = true
            if speed > 1 { liveCapped = true }
            playAskedAt = nil
            synchronizer.rate = 0
        case .realTime:
            liveCapped = true
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = renderersCanStart(at: t)
            synchronizer.rate = 1
        case .end:
            pauseHere()
            ended = true
        case .none, .resume:
            break
        }
        startWatchdog(t)
    }

    /// A play that should have started by now but has not: the renderers may never say they have
    /// enough (an audio track that ends a little early), so start without waiting for them.
    private func startWatchdog(_ t: Double) {
        guard let asked = playAskedAt else { return }
        let rate = CMTimebaseGetRate(synchronizer.timebase)
        if rate != 0 {
            playAskedAt = nil
            return
        }
        let waited = Double(HostClock.nowNs() &- asked.hostNs) / 1e9
        guard waited > Self.startWatchdogS else { return }
        playAskedAt = nil
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(Float(playingSpeed), time: CMTime(seconds: max(0, t), preferredTimescale: 90_000))
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
    }

    private func setRate(_ rate: Double, at t: Double) {
        guard started else { return }
        // Waiting for every renderer to have enough is right only when each one gets data here: a
        // picture left out, failed, or past the end of its movie would hold every start back
        // until the watchdog.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = renderersCanStart(at: t)
        synchronizer.setRate(Float(rate), time: CMTime(seconds: max(0, t), preferredTimescale: 90_000))
        playAskedAt = rate > 0 ? (HostClock.nowNs(), t) : nil
    }

    private func pauseHere() {
        playing = false
        holding = false
        waitingForSpeech = false
        playAskedAt = nil
        if started { synchronizer.rate = 0 }
    }

    private func seek(to target: Double, play: Bool) {
        let edge = makeEdge()
        let t = edge.clamp(target)
        guard started else {
            pending = (t, play)
            playing = play
            return
        }
        synchronizer.setRate(0, time: CMTime(seconds: t, preferredTimescale: 90_000))
        seekedTo = (t, HostClock.nowNs())
        holding = false
        ended = false
        waitingForSpeech = false
        for feeder in video + audio { restart(feeder, at: t) }
        playing = play
        if play { setRate(playingSpeed, at: t) } else { playAskedAt = nil }
    }

    /// Starts `feeder` over at take time `t`: its renderer is flushed and its reader opens there.
    /// A feeder that failed tries again, at most `Feeder.maxFailures` times in a row (a user's
    /// seek or play allows that many more).
    private func restart(_ feeder: Feeder, at t: Double, still: Bool = false) {
        feeder.stop()
        feeder.renderer.flush()
        feeder.waiting = false
        feeder.blanked = false
        if feeder.failed != nil {
            guard feeder.failures < Feeder.maxFailures else { return }
            feeder.failed = nil
        }
        guard let movie = movies[feeder.file] else { return }
        feeder.reader.offsetS = alignment.offset(feeder.file)
        let fileT = alignment.fileTime(t, of: feeder.file)
        if feeder.reader.media == .video {
            // Past the end of a movie that grows no more: black. Just past it, its last frame.
            if isFinished(feeder.file), fileT > movie.durationS + Self.blankAfterS {
                blank(feeder)
                feeder.reader.cancel()
                return
            }
            feeder.reader.restart(at: min(fileT, max(0, movie.durationS - 0.1)), in: movie, still: still)
        } else {
            feeder.reader.restart(at: fileT, in: movie)
        }
        if visible { feeder.start(on: queue, engine: self) }
    }

    /// A user's seek or play: every feeder that gave up may try again.
    private func resetFailures() {
        for feeder in video + audio { feeder.failures = 0 }
    }

    /// Every renderer gets data at take time `t`: its movie is open, it has not failed, and `t`
    /// is inside what can be read of it.
    private func renderersCanStart(at t: Double) -> Bool {
        (video + audio).allSatisfy { feeder in
            guard feeder.failed == nil, let end = endS(feeder.file) else { return false }
            return t < end - 0.1
        }
    }

    /// The picture goes black (a movie that ended before the others).
    private func blank(_ feeder: Feeder) {
        feeder.blanked = true
        (feeder.renderer as? AVSampleBufferVideoRenderer)?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Played past the end of a movie that grows no more: its picture goes black.
    private func blankEndedPictures() {
        let t = position
        for feeder in video where feeder.waiting && !feeder.blanked && isFinished(feeder.file) {
            if let end = endS(feeder.file), t > end + Self.blankAfterS { blank(feeder) }
        }
    }

    /// A renderer that failed (a decode error, or decoding no longer allowed) shows nothing until
    /// it is flushed: it starts over where the picture is, at most `Feeder.maxFailures` times.
    private func checkRenderers() {
        for feeder in video + audio where feeder.failed == nil {
            guard let error = Self.failure(of: feeder.renderer) else { continue }
            feeder.failures += 1
            if feeder.failures >= Feeder.maxFailures {
                feeder.stop()
                feeder.renderer.flush()
                feeder.failed = "\(feeder.file.fileName) could not be decoded: \(error)"
            } else {
                restart(feeder, at: position)
            }
        }
    }

    /// Why `renderer` stopped rendering, or nil while it works.
    static func failure(of renderer: any AVQueuedSampleBufferRendering) -> String? {
        if let video = renderer as? AVSampleBufferVideoRenderer {
            if video.requiresFlushToResumeDecoding { return "decoding was interrupted" }
            if video.status == .failed { return video.error?.localizedDescription ?? "unknown error" }
        } else if let audio = renderer as? AVSampleBufferAudioRenderer, audio.status == .failed {
            return audio.error?.localizedDescription ?? "unknown error"
        }
        return nil
    }

    // MARK: - What can be read (queue)

    /// The movie grows no more: a finished take, or a live take's file that its writer finished
    /// (Stop, or a recorder that ended early while the take goes on). AVAssetWriter then rewrites
    /// it without fragments (`LoadedMovie.canGrow`), with a second `moov` (`FragmentProbe`).
    private func isFinished(_ kind: ReplayFileKind) -> Bool {
        guard isLive else { return true }
        return probes[kind]?.finished == true || movies[kind]?.canGrow == false
    }

    /// The live movie has not grown for `staleAfterS` while another one did: its writer hangs.
    private func isStale(_ kind: ReplayFileKind, nowNs: UInt64) -> Bool {
        let limit = UInt64(Self.staleAfterS * 1e9)
        guard let last = grewAtNs[kind], nowNs &- last > limit else { return false }
        return files.files.contains { other in
            other != kind && !isFinished(other) && grewAtNs[other].map { nowNs &- $0 <= limit } == true
        }
    }

    /// Take time of the end of what can be read in `kind`.
    private func endS(_ kind: ReplayFileKind) -> Double? {
        movies[kind].map { $0.durationS + alignment.offset(kind) }
    }

    /// The end of what can be read, and how far the take has got. Only the movies that still grow
    /// hold the replay back (their earliest end): one that finished or stalls does not, so a
    /// camera disconnected at 10:00 does not stop the replay of screen.mov there. With none
    /// growing (a finished take), everything plays: the longest movie's end. A movie never opened
    /// (`beginWithoutS`) holds nothing back.
    private func makeEdge() -> LiveEdge {
        let now = HostClock.nowNs()
        let loaded = files.files.filter { movies[$0] != nil }
        let growing = isLive ? loaded.filter { !isFinished($0) && !isStale($0, nowNs: now) } : []
        let available = (growing.isEmpty ? loaded.compactMap(endS).max() : growing.compactMap(endS).min()) ?? 0
        // Live while a movie grows, or may still come.
        let live = isLive && (!growing.isEmpty || loaded.count < files.files.count)
        let recorded = live ? alignment.takeTime(hostNs: now) : available
        return LiveEdge(isLive: live, recordedS: recorded, availableS: available)
    }

    private func publish() {
        var s = ReplaySnapshot()
        s.ready = started
        s.positionS = position
        s.playing = playing
        s.holding = holding
        s.ended = ended
        s.waitingForSpeech = waitingForSpeech
        s.speed = speed
        s.playingSpeed = playingSpeed
        s.edge = makeEdge()
        s.soundOn = soundOn
        s.problem = problem ?? (video + audio).lazy.compactMap(\.failed).first
        published.withLock { $0 = s }
    }

    // MARK: - Audio (queue)

    private func startAudio() {
        guard audio.isEmpty else { return }
        for track in ReplaySound.tracks(audioTracks()) where files.files.contains(track.file) {
            let renderer = AVSampleBufferAudioRenderer()
            renderer.audioTimePitchAlgorithm = .timeDomain
            synchronizer.addRenderer(renderer)
            observeFlushes(of: renderer)
            let feeder = Feeder(file: track.file, reader: GrowingTrackReader(media: .audio, trackIndex: track.trackIndex,
                                                                             offsetS: alignment.offset(track.file)),
                                renderer: renderer)
            audio.append(feeder)
            if started { restart(feeder, at: position) }
        }
    }

    private func stopAudio() {
        let now = synchronizer.currentTime()
        for feeder in audio {
            feeder.stop()
            feeder.reader.cancel()
            feeder.renderer.flush()
            synchronizer.removeRenderer(feeder.renderer, at: now) { _ in }
        }
        audio = []
        for token in audioObservers { NotificationCenter.default.removeObserver(token) }
        audioObservers = []
    }

    /// AVSampleBufferAudioRenderer.h: the renderer may drop what it has queued by itself, at a
    /// rate change (1x to 2x, the drop to 1x at live, a pause then another speed) or a new output
    /// (headphones plugged in), and when the output's format no longer fits. The reader has read
    /// past that audio, so the speech queued there would never be heard: start it over where the
    /// sound is now, as the header advises.
    private func observeFlushes(of renderer: AVSampleBufferAudioRenderer) {
        let id = ObjectIdentifier(renderer)
        for name in [Notification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
                     .AVSampleBufferAudioRendererOutputConfigurationDidChange] {
            audioObservers.append(NotificationCenter.default.addObserver(forName: name, object: renderer, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.audioFlushed(id) }
            })
        }
    }

    private func audioFlushed(_ id: ObjectIdentifier) {
        guard !closed, started, let feeder = audio.first(where: { ObjectIdentifier($0.renderer) == id }) else { return }
        restart(feeder, at: position)
    }

    /// The audio tracks from the events, else from the movies themselves: camera.mov's audio is
    /// the camera mic; screen.mov's first audio track the Mac mic, its second the computer sound.
    private func audioTracks() -> [ReplayAudioTrack] {
        if !info.audioTracks.isEmpty { return info.audioTracks }
        var found: [ReplayAudioTrack] = []
        for (kind, movie) in movies {
            let indices = movie.tracks.indices.filter { movie.tracks[$0].mediaType == .audio }
            for (n, index) in indices.enumerated() {
                let role: TrackInfo.Role = kind == .screen && n == 1 ? .systemAudio : .mic
                found.append(ReplayAudioTrack(file: kind, trackIndex: index, role: role))
            }
        }
        return found
    }

    // MARK: - Growing files (queue)

    private func checkGrowth() {
        for kind in files.files {
            var probe = probes[kind] ?? FragmentProbe(url: files.url(kind))
            let grew = probe.scan()
            probes[kind] = probe
            if grew || (movies[kind] == nil && probe.hasMovie) { reload(kind) }
        }
    }

    /// Opens the movie again (off this queue), then hands the new opening to its readers.
    private func reload(_ kind: ReplayFileKind) {
        guard !loading.contains(kind) else {
            reloadWanted.insert(kind)
            return
        }
        loading.insert(kind)
        reloadWanted.remove(kind)
        let url = files.url(kind)
        let queue = queue
        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.open(url)
            queue.async { [weak self] in self?.loaded(result, kind) }
        }
    }

    private static func open(_ url: URL) async -> Result<LoadedMovie, any Error> {
        do { return .success(try await LoadedMovie.load(url)) } catch { return .failure(error) }
    }

    private func loaded(_ result: Result<LoadedMovie, any Error>, _ kind: ReplayFileKind) {
        loading.remove(kind)
        guard !closed else { return }
        switch result {
        case let .success(movie):
            let previous = movies[kind]?.durationS ?? -1
            // A finished file is the final word, even if its end is a frame shorter.
            if movie.durationS >= previous || !movie.canGrow {
                if movie.durationS > previous + 0.001 { grewAtNs[kind] = HostClock.nowNs() }
                movies[kind] = movie
                mind(movie, kind)
                for feeder in video + audio where feeder.file == kind {
                    if feeder.failed != nil {
                        // A new opening: a reader that failed tries again (`restart` counts the tries).
                        if started { restart(feeder, at: position) }
                    } else if feeder.waiting {
                        goOn(feeder, in: movie)
                    } else if started, feeder.reader.movie == nil {
                        // Its movie was left out at the start and is readable now.
                        restart(feeder, at: position)
                    }
                }
            }
            if !started, files.files.allSatisfy({ movies[$0] != nil }) { begin() }
        case let .failure(error):
            // A live movie may be mid-write: the next fragment opens it again.
            if !isLive { problem = "\(kind.fileName) could not be opened: \(error.localizedDescription)" }
        }
        if reloadWanted.contains(kind) { reload(kind) }
        publish()
    }

    /// Every movie is open: show the picture at the opening position.
    private func begin() {
        started = true
        let edge = makeEdge()
        let target = pending.target ?? edge.openingPosition()
        seek(to: target, play: pending.play)
        if pending.play, let first = mask.firstPlayable(atOrAfter: edge.clamp(target)), first > edge.clamp(target) + 0.1 {
            seek(to: first, play: true)
        }
    }

    /// Keeps an AVFragmentedAssetMinder on the newest opening of a live movie (none once the
    /// movie is finished).
    private func mind(_ movie: LoadedMovie, _ kind: ReplayFileKind) {
        guard isLive else { return }
        guard movie.canGrow else {
            if let minder = minders.removeValue(forKey: kind) {
                for asset in minder.assets { minder.removeFragmentedAsset(asset) }
            }
            return
        }
        if let minder = minders[kind] {
            for asset in minder.assets { minder.removeFragmentedAsset(asset) }
            minder.addFragmentedAsset(movie.asset)
        } else {
            minders[kind] = AVFragmentedAssetMinder(asset: movie.asset, mindingInterval: LiveEdge.fragmentS)
        }
    }

    private func observeMinders() {
        let center = NotificationCenter.default
        for name in [Notification.Name.AVAssetDurationDidChange, .AVAssetContainsFragmentsDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let asset = note.object as? AVFragmentedAsset else { return }
                let id = ObjectIdentifier(asset)
                self?.queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    for (kind, movie) in self.movies where ObjectIdentifier(movie.asset) == id { self.reload(kind) }
                }
            })
        }
    }

    /// A reader reached the end of its movie's opening.
    fileprivate func feederWaiting(_ feeder: Feeder) {
        guard let movie = movies[feeder.file], let reading = feeder.reader.movie else { return }
        // A newer opening came in while it read: go on in it at once.
        if movie.durationS > reading.durationS + 0.001 {
            goOn(feeder, in: movie)
        } else if isLive, !isFinished(feeder.file) {
            reloadWanted.insert(feeder.file)
        }
    }

    /// A waiting feeder's movie grew: it goes on after its last sample, or, when the picture is
    /// more than 1 s past that (the movie stalled while the other played on), where the picture is.
    private func goOn(_ feeder: Feeder, in movie: LoadedMovie) {
        feeder.waiting = false
        let behind = feeder.reader.lastS.map { alignment.takeTime($0, of: feeder.file) < position - 1 } ?? true
        if started, behind {
            restart(feeder, at: position)
            return
        }
        feeder.reader.grow(to: movie)
        if visible { feeder.start(on: queue, engine: self) }
    }
}

/// Feeds one renderer from one track reader. Confined to the engine's queue.
final class Feeder: @unchecked Sendable {
    let file: ReplayFileKind
    let reader: GrowingTrackReader
    let renderer: any AVQueuedSampleBufferRendering
    private var requesting = false
    /// Reached the end of the movie's current opening: waits for it to grow.
    var waiting = false
    var failed: String?
    /// Failures in a row (the reader, or the renderer), for `maxFailures`.
    var failures = 0
    static let maxFailures = 3
    /// Its picture was made black (past the end of its movie).
    var blanked = false

    init(file: ReplayFileKind, reader: GrowingTrackReader, renderer: any AVQueuedSampleBufferRendering) {
        self.file = file
        self.reader = reader
        self.renderer = renderer
    }

    func start(on queue: DispatchQueue, engine: ReplayEngine) {
        guard !requesting, failed == nil else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.feed(engine)
        }
    }

    func stop() {
        guard requesting else { return }
        requesting = false
        renderer.stopRequestingMediaData()
    }

    private func feed(_ engine: ReplayEngine) {
        while requesting, renderer.isReadyForMoreMediaData {
            switch reader.next() {
            case let .sample(sample):
                renderer.enqueue(sample)
            case .needMore:
                stop()
                waiting = true
                engine.feederWaiting(self)
                return
            case .done:
                stop()
                return
            case let .failed(message):
                stop()
                failed = message
                failures += 1
                return
            }
        }
    }
}
