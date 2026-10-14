import Foundation
import RecorderCore

// The replay's rules over plain data, so they can be tested without a window or a movie:
// - take time: seconds since session.json `started_at_host_ns`, the clock of the control bar's
//   timer and of a flag's `elapsed_s`. camera.mov and screen.mov each begin a few ms after it
//   (`MediaAlignment`).
// - Skip silence: the stretches of speech, joined across short pauses and padded (`SkipSilence`).
// - Flags only: the stretch around each flag (`FlagsOnly`).
// - The live edge: how close to "now" the replay of a growing file may play (`LiveEdge`).
// - The events the replay logs, and the sound it plays.

/// A stretch of take time, in seconds.
public struct TimeSpan: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var start: Double
    public var end: Double

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    public var description: String { String(format: "[%.2f, %.2f]", start, end) }
}

/// Sorted, merged span lists.
public enum SpanMath {
    /// `spans` sorted, with spans that overlap, touch, or lie at most `gap` apart joined.
    public static func merged(_ spans: [TimeSpan], joiningGapsUpTo gap: Double = 0) -> [TimeSpan] {
        let sorted = spans.filter { $0.start.isFinite && $0.end.isFinite }.sorted { $0.start < $1.start }
        var out: [TimeSpan] = []
        out.reserveCapacity(sorted.count)
        for span in sorted {
            if let last = out.last, span.start - last.end <= gap {
                out[out.count - 1].end = max(last.end, span.end)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// The time both merged lists cover.
    public static func intersection(_ a: [TimeSpan], _ b: [TimeSpan]) -> [TimeSpan] {
        var out: [TimeSpan] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let start = max(a[i].start, b[j].start), end = min(a[i].end, b[j].end)
            if end > start { out.append(TimeSpan(start, end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    /// The index of the first span whose end is after `t` (binary search), or `spans.count`.
    static func firstEnding(after t: Double, in spans: [TimeSpan]) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].end <= t { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The merged span that holds `t` (from `tolerance` before its start up to its end).
    public static func span(containing t: Double, in spans: [TimeSpan], tolerance: Double = 0) -> TimeSpan? {
        let i = firstEnding(after: t, in: spans)
        guard i < spans.count, spans[i].start - tolerance <= t else { return nil }
        return spans[i]
    }

    /// The start of the first merged span that begins after `t`.
    public static func nextStart(after t: Double, in spans: [TimeSpan]) -> Double? {
        let i = firstEnding(after: t, in: spans)
        guard i < spans.count else { return nil }
        if spans[i].start > t { return spans[i].start }
        return i + 1 < spans.count ? spans[i + 1].start : nil
    }

    /// Total time covered.
    public static func total(_ spans: [TimeSpan]) -> Double { spans.reduce(0) { $0 + $1.duration } }
}

// MARK: - Skip silence

/// Skip silence: the replay jumps over pauses longer than `maxPauseS` and keeps `paddingS` of
/// the pause on each side of the speech, so words are never cut.
public enum SkipSilence {
    public static let maxPauseS = 1.0
    public static let paddingS = 0.25

    /// The spans the replay plays: speech stretches less than `maxPauseS` apart are joined (the
    /// pause plays), then each span gets `paddingS` before and after it.
    public static func keptSpans(speech: [TimeSpan], maxPauseS: Double = maxPauseS,
                                 paddingS: Double = paddingS) -> [TimeSpan] {
        let joined = SpanMath.merged(speech, joiningGapsUpTo: maxPauseS)
        return SpanMath.merged(joined.map { TimeSpan(max(0, $0.start - paddingS), $0.end + paddingS) })
    }

    /// Speech from a voice timeline, in take time (seconds since `startedAtHostNs`).
    public static func speech(_ timeline: VoiceTimeline, startedAtHostNs: UInt64) -> [TimeSpan] {
        VoiceTimeline.seconds(timeline.speech, since: startedAtHostNs).map { TimeSpan($0.start, $0.end) }
    }
}

// MARK: - Flags only

/// A Flag marker in take time: "something in the `lookbackS` seconds before `atS` was wrong".
public struct FlagMark: Sendable, Equatable, Hashable {
    public var atS: Double
    public var lookbackS: Double

    public init(atS: Double, lookbackS: Double) {
        self.atS = atS
        self.lookbackS = max(0, lookbackS)
    }

    /// Where the stretch this flag points at begins.
    public var spanStart: Double { max(0, atS - lookbackS) }
}

/// Flags only: the replay plays [flag − `lookback_s`, flag + `afterS`] around each flag.
public enum FlagsOnly {
    /// How long after the press the stretch goes on.
    public static let afterS = 10.0

    public static func spans(_ flags: [FlagMark], afterS: Double = afterS) -> [TimeSpan] {
        SpanMath.merged(flags.map { TimeSpan($0.spanStart, $0.atS + afterS) })
    }

    /// The next flag's start after `t` (more than half a second ahead). See `starts`.
    public static func next(after t: Double, in flags: [FlagMark]) -> Double? {
        starts(flags).first { $0 > t + 0.5 }
    }

    /// The previous flag's start: the start of the flag `t` is in, unless `t` is within its first
    /// 2 s (then the one before), like a music player's back button. See `starts`.
    public static func previous(before t: Double, in flags: [FlagMark]) -> Double? {
        starts(flags).last { $0 < t - 2 }
    }

    /// Where Next and Previous go: one place for each flag, in the order of the presses. A flag
    /// begins at its look-back start, or at the press of the flag before it when its look-back
    /// reaches back over that press: what the earlier flag points at, the earlier flag covers. So
    /// with flags 30 s apart and a 3 min look-back, Next goes to the first flag's look-back, then
    /// to its press, where the second flag's new part begins.
    static func starts(_ flags: [FlagMark]) -> [Double] {
        var out: [Double] = []
        var previousPress = -Double.infinity
        for flag in flags.sorted(by: { ($0.atS, $0.spanStart) < ($1.atS, $1.spanStart) }) {
            guard flag.atS > previousPress + 0.001 else { continue }  // The same press again.
            let start = max(flag.spanStart, previousPress)
            if out.last.map({ start > $0 + 0.001 }) ?? true { out.append(start) }
            previousPress = flag.atS
        }
        return out
    }
}

// MARK: - Mask

/// What the transport does at a moment, under Skip silence and Flags only.
public enum MaskDecision: Equatable, Sendable {
    case play
    /// Jump forward to the next span that plays.
    case jump(to: Double)
    /// Nothing more to play up to the end of what can be played.
    case end
}

/// The parts of the take the replay plays: everything, or the spans of Skip silence, Flags only,
/// or both at once (the time both keep).
public struct PlaybackMask: Sendable, Equatable {
    /// Nil: everything plays.
    public var spans: [TimeSpan]?

    public init(spans: [TimeSpan]?) { self.spans = spans }

    public static let everything = PlaybackMask(spans: nil)

    public static func make(silence: [TimeSpan]?, flags: [TimeSpan]?) -> PlaybackMask {
        switch (silence, flags) {
        case (nil, nil): .everything
        case let (s?, nil): PlaybackMask(spans: s)
        case let (nil, f?): PlaybackMask(spans: f)
        case let (s?, f?): PlaybackMask(spans: SpanMath.intersection(s, f))
        }
    }

    /// A jump shorter than this is not worth it: play on.
    public static let minJumpS = 0.1

    /// - Parameter playableEnd: the end of what can be played now (`LiveEdge.playableEndS`).
    public func decision(at t: Double, playableEnd: Double) -> MaskDecision {
        guard let spans else { return .play }
        if SpanMath.span(containing: t, in: spans, tolerance: 0.02) != nil { return .play }
        guard let next = SpanMath.nextStart(after: t, in: spans), next < playableEnd - 0.05 else { return .end }
        return next - t < Self.minJumpS ? .play : .jump(to: next)
    }

    /// The first time that plays at or after `t`, or `t` when everything plays.
    public func firstPlayable(atOrAfter t: Double) -> Double? {
        guard let spans else { return t }
        if SpanMath.span(containing: t, in: spans) != nil { return t }
        return SpanMath.nextStart(after: t, in: spans)
    }

    /// How much of [0, end] plays.
    public func playableSeconds(upTo end: Double) -> Double {
        guard let spans else { return max(0, end) }
        return SpanMath.total(SpanMath.intersection(spans, [TimeSpan(0, max(0, end))]))
    }

    /// Play after the replay ended at `t` (the end of a finished take, the last flag stretch, or
    /// the last speech of a saved take): on from `t` when it plays now (a flag that came in since
    /// made its stretch longer), else to the next part that plays, else from the first one.
    public func resumeAfterEnd(at t: Double, playableEnd: Double) -> ResumeAfterEnd {
        if let next = firstPlayable(atOrAfter: t), next < playableEnd - 0.1 {
            return next > t + 0.05 ? .jump(to: next) : .here
        }
        return .jump(to: firstPlayable(atOrAfter: 0) ?? 0)
    }
}

/// See `PlaybackMask.resumeAfterEnd(at:playableEnd:)`.
public enum ResumeAfterEnd: Equatable, Sendable {
    /// Play on from where it stopped.
    case here
    case jump(to: Double)
}

// MARK: - Live edge

/// How close to "now" the replay plays while the files still grow. A movie fragment lands every
/// 2 s (`WriterSettings.movieFragmentInterval`, about 30 ms after its last frame), and the replay
/// sees it at its next check (`probeIntervalS`), so what can be read is up to `fragmentS` +
/// `probeIntervalS` + the capture and encode latency behind the recording. The replay stays
/// `liveDelayS` behind it: at 1x it waits for a fragment only when that latency is over
/// `latencyMarginS`.
public struct LiveEdge: Sendable, Equatable {
    public static let fragmentS = 2.0
    /// How often the replay checks a growing file for a new fragment.
    public static let probeIntervalS = 0.25
    /// The replay never plays closer than this to the end of what is readable.
    public static let guardS = 0.25
    /// Room for the capture and encode latency (a frame reaches the file 0.05 to 0.2 s after it
    /// was captured).
    public static let latencyMarginS = 0.5
    /// Jump to live goes this far behind the recording: 3 s.
    public static let liveDelayS = fragmentS + probeIntervalS + guardS + latencyMarginS
    /// After waiting at the end, it plays on once this much more can be read.
    public static let resumeMarginS = 0.5

    /// The take records now: the files grow.
    public var isLive: Bool
    /// Take time now (live) or the take's length (finished).
    public var recordedS: Double
    /// Take time up to which every file can be read now.
    public var availableS: Double

    public init(isLive: Bool, recordedS: Double, availableS: Double) {
        self.isLive = isLive
        self.recordedS = max(0, recordedS)
        self.availableS = max(0, availableS)
    }

    /// The end of what may be played now.
    public var playableEndS: Double { isLive ? max(0, availableS - Self.guardS) : availableS }

    /// "Jump to live": about one fragment behind the recording, and never past what is readable.
    public var liveTargetS: Double {
        isLive ? max(0, min(recordedS - Self.liveDelayS, playableEndS)) : playableEndS
    }

    /// The timeline's length: the whole take so far.
    public var timelineEndS: Double { max(recordedS, availableS) }

    /// `t` kept inside what may be played.
    public func clamp(_ t: Double) -> Double { min(max(0, t.isFinite ? t : 0), playableEndS) }

    /// How far `t` is behind the recording.
    public func behindS(_ t: Double) -> Double { max(0, recordedS - t) }

    /// `t` is at the live point (within `tolerance`).
    public func isAtLive(_ t: Double, tolerance: Double = 0.75) -> Bool { isLive && t >= liveTargetS - tolerance }

    /// Where the replay opens: the last `seconds` of the take so far.
    public func openingPosition(lastSeconds seconds: Double = 60) -> Double { max(0, liveTargetS - seconds) }

    /// What the transport does while it plays (or waits) at `t` with `rate`.
    public func action(at t: Double, rate: Double, holding: Bool) -> LiveAction {
        if holding { return playableEndS >= t + Self.resumeMarginS || !isLive ? .resume : .none }
        guard isLive else { return t >= playableEndS - 0.05 ? .end : .none }
        // At the end of what is readable (at 2x too: then it caught up, and goes on at 1x).
        if t >= playableEndS - 0.02 { return .hold }
        if rate > 1.0001, t >= liveTargetS - 0.05 { return .realTime }
        return .none
    }
}

/// See `LiveEdge.action(at:rate:holding:)`.
public enum LiveAction: Equatable, Sendable {
    case none
    /// Caught up with live at a faster speed: go on at 1x.
    case realTime
    /// At the end of what is readable: wait for the next fragment, then go on at 1x (a faster
    /// speed got there first when a fragment came late: it caught up with live too).
    case hold
    /// Enough was written while waiting: play on.
    case resume
    /// A finished take reached its end.
    case end
}

// MARK: - Two files on one timeline

/// The two movies of a take.
public enum ReplayFileKind: String, Sendable, CaseIterable, Hashable {
    case screen, camera

    public var fileName: String { self == .screen ? SessionFolder.screenFileName : SessionFolder.cameraFileName }
    public var videoRole: TrackInfo.Role { self == .screen ? .screenVideo : .cameraVideo }
}

/// Lines camera.mov and screen.mov up on take time. Each file's time 0 is its first frame, at its
/// `first_pts_host_ns` (track_start in events.jsonl, or session.json `tracks[]`); both begin a few
/// ms after `started_at_host_ns`, the take's time 0.
public struct MediaAlignment: Sendable, Equatable {
    /// Host time of take time 0.
    public var originNs: UInt64
    /// Take time of each file's time 0.
    public var offsetsS: [ReplayFileKind: Double]

    public init(startedAtHostNs: UInt64?, firstPtsHostNs: [ReplayFileKind: UInt64]) {
        let origin = startedAtHostNs ?? firstPtsHostNs.values.min() ?? 0
        originNs = origin
        offsetsS = firstPtsHostNs.mapValues { Self.seconds($0, since: origin) }
    }

    static func seconds(_ ns: UInt64, since origin: UInt64) -> Double {
        ns >= origin ? Double(ns - origin) / 1e9 : -Double(origin - ns) / 1e9
    }

    /// Take time of `kind`'s time 0 (0 when its start is not known yet).
    public func offset(_ kind: ReplayFileKind) -> Double { offsetsS[kind] ?? 0 }

    public func fileTime(_ takeTime: Double, of kind: ReplayFileKind) -> Double { takeTime - offset(kind) }
    public func takeTime(_ fileTime: Double, of kind: ReplayFileKind) -> Double { fileTime + offset(kind) }
    public func takeTime(hostNs: UInt64) -> Double { Self.seconds(hostNs, since: originNs) }

    /// How far apart the files begin (about 25 ms at most for an on-time start).
    public var spreadS: Double {
        guard let low = offsetsS.values.min(), let high = offsetsS.values.max() else { return 0 }
        return high - low
    }
}

// MARK: - Sound

/// An audio track of a take's movies.
public struct ReplayAudioTrack: Sendable, Equatable, Hashable {
    public var file: ReplayFileKind
    /// Index in the file, in file order (video is 0).
    public var trackIndex: Int
    public var role: TrackInfo.Role

    public init(file: ReplayFileKind, trackIndex: Int, role: TrackInfo.Role) {
        self.file = file; self.trackIndex = trackIndex; self.role = role
    }
}

/// What the Sound switch plays: the dialogue (the camera mic, else the Mac mic) and the computer
/// sound. Never both mics: the Mac mic would echo the camera mic a few ms apart.
public enum ReplaySound {
    public static func tracks(_ available: [ReplayAudioTrack]) -> [ReplayAudioTrack] {
        let mics = available.filter { $0.role == .mic }
        let dialogue = mics.first { $0.file == .camera } ?? mics.first { $0.file == .screen }
        let system = available.first { $0.role == .systemAudio }
        return [dialogue, system].compactMap { $0 }
    }

    /// The hint next to the switch.
    public static let hint = "Use headphones: the speakers would be in the mics."
}

// MARK: - Events

/// `data` of the replay's events in events.jsonl (schema 1.4). An editor cuts the take from each
/// `replay_start` to its `replay_end`: the speaker reviewed instead of talking to the camera.
public enum ReplayEvents {
    public enum EndReason: String, Sendable {
        /// The window closed.
        case closed
        /// The take stopped with the window open.
        case stop
    }

    static func seconds(_ s: Double) -> String { String(format: "%.1f", max(0, s.isFinite ? s : 0)) }

    /// - Parameters:
    ///   - elapsedS: take time of the open (seconds since `started_at_host_ns`, like a flag).
    ///   - positionS: where the replay opened, in take time.
    public static func startData(elapsedS: Double, positionS: Double, sound: Bool, skipSilence: Bool,
                                 flagsOnly: Bool) -> [String: String] {
        ["elapsed_s": seconds(elapsedS), "position_s": seconds(positionS), "sound": sound ? "on" : "off",
         "skip_silence": skipSilence ? "on" : "off", "flags_only": flagsOnly ? "on" : "off"]
    }

    /// - Parameters:
    ///   - openS: how long the window was open during the take.
    ///   - soundOnS: how long of that the Sound switch was on.
    public static func endData(elapsedS: Double, openS: Double, soundOnS: Double, reason: EndReason) -> [String: String] {
        ["elapsed_s": seconds(elapsedS), "open_s": seconds(openS), "sound_on_s": seconds(soundOnS), "reason": reason.rawValue]
    }

    public static func soundData(on: Bool, elapsedS: Double) -> [String: String] {
        ["state": on ? "on" : "off", "elapsed_s": seconds(elapsedS)]
    }

    /// The stretches of a take that were spent in the replay, from its events: each
    /// `replay_start` to the next `replay_end`, or to `session_stop` (or `endS`) when none came.
    public static func reviewStretches(_ events: [SessionEvent], endS: Double? = nil) -> [TimeSpan] {
        var out: [TimeSpan] = []
        var open: Double?
        for event in events {
            let at = event.data?["elapsed_s"].flatMap(Double.init)
            switch event.type {
            case .replayStart:
                if open == nil { open = at }
            case .replayEnd:
                if let start = open, let end = at { out.append(TimeSpan(start, end)) }
                open = nil
            case .sessionStop:
                if let start = open, let end = endS { out.append(TimeSpan(start, end)) }
                open = nil
            default:
                break
            }
        }
        if let start = open, let end = endS { out.append(TimeSpan(start, end)) }
        return out
    }

    /// The movies that dropped frames at or after host time `sinceNs`, from the recorders'
    /// `dropped_frames` events (each logs one at most every 2 s while it drops). The replay pauses
    /// when one comes in while it plays: the recording comes first.
    public static func droppedFrames(_ events: [SessionEvent], sinceNs: UInt64) -> [ReplayFileKind] {
        var out: [ReplayFileKind] = []
        for event in events where event.type == .droppedFrames && event.tHostNs >= sinceNs {
            let data = event.data ?? [:]
            let kind = data["file"].flatMap(ReplayTakeInfo.kind(file:))
                ?? ReplayFileKind.allCases.first { $0.videoRole.rawValue == data["track"] }
            if let kind, !out.contains(kind) { out.append(kind) }
        }
        return out.sorted { $0.rawValue < $1.rawValue }
    }

    /// The status line after such a pause.
    public static func droppedFramesNotice(_ files: [ReplayFileKind]) -> String {
        let names = files.map(\.fileName).joined(separator: " and ")
        return "Paused: \(names.isEmpty ? "the recording" : names) dropped frames. Play goes on."
    }
}

/// "12:34" or "1:02:03" for take time; "−0:02" style for how far behind live.
public enum ReplayClock {
    public static func string(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "2 s behind live", "live", "1:05 behind live".
    public static func behindLive(_ seconds: Double, atLive: Bool) -> String {
        if atLive { return "live" }
        return seconds < 60 ? "\(Int(seconds.rounded())) s behind live" : "\(string(seconds)) behind live"
    }
}
