import Foundation

// The voice timeline of a take: when the speaker talks, from the same 50 ms meter blocks the
// camera mic detector uses (`AudioLevelMonitor`). A block is voiced when its RMS is 10 dB above
// that mic's noise floor (the lowest block level of the last 3 s) and above -65 dBFS, the
// detector's rule. Voiced blocks less than 200 ms apart join into one stretch of speech; a
// stretch needs 3 voiced blocks (150 ms), so a keystroke or a click is no speech.
//
// The replay's Skip silence uses it: it jumps over pauses. The monitor collects it during a take
// (one builder per mic, inside the monitor's lock, a few microseconds per block), keeps it in
// memory for the live take, and the app writes it to voice.jsonl at Stop.

/// One stretch of speech on the host clock: from the start of its first voiced block to the end
/// of its last one.
public struct VoiceSegment: Sendable, Equatable, Hashable {
    public var startNs: UInt64
    public var endNs: UInt64

    public init(startNs: UInt64, endNs: UInt64) {
        self.startNs = startNs
        self.endNs = max(startNs, endNs)
    }

    public var durationNs: UInt64 { endNs - startNs }
}

/// The voice rule. The defaults match the camera mic detector's voiced blocks
/// (`MicDetectorSettings.standard`).
public struct VoiceActivityRule: Sendable, Equatable {
    /// A block is voiced this far above its mic's noise floor...
    public var voiceMarginDb: Double
    /// ...and above this level.
    public var minVoiceDb: Double
    /// The noise floor is the lowest block level of this much time.
    public var noiseFloorSeconds: Double
    /// Voiced blocks at most this many unvoiced blocks apart join into one stretch (4: 200 ms).
    public var joinGapBlocks: Int64
    /// A stretch counts as speech with at least this many voiced blocks (3: 150 ms).
    public var minVoicedBlocks: Int

    public init(voiceMarginDb: Double = 10, minVoiceDb: Double = -65, noiseFloorSeconds: Double = 3,
                joinGapBlocks: Int64 = 4, minVoicedBlocks: Int = 3) {
        self.voiceMarginDb = voiceMarginDb; self.minVoiceDb = minVoiceDb; self.noiseFloorSeconds = noiseFloorSeconds
        self.joinGapBlocks = joinGapBlocks; self.minVoicedBlocks = minVoicedBlocks
    }

    public static let standard = VoiceActivityRule()

    /// One line for voice.jsonl's header.
    public var summary: String {
        String(format: "rms %.0f dB above the %.0f s noise floor and above %.0f dBFS; joined across %d ms; at least %d ms of voice",
               voiceMarginDb, noiseFloorSeconds, minVoiceDb, Int(joinGapBlocks) * 50, minVoicedBlocks * 50)
    }
}

/// Builds the speech stretches of one mic, block by block. Pure: blocks in, segments out.
public struct VoiceTrackBuilder: Sendable {
    public let rule: VoiceActivityRule
    private var floor: NoiseFloor
    private(set) public var segments: [VoiceSegment] = []
    /// The stretch that is still open: its first and last voiced block, and how many were voiced.
    private var run: (first: Int64, last: Int64, voiced: Int)?
    private var lastIndex: Int64?
    /// Blocks seen and voiced blocks, for the source choice.
    private(set) public var blocks = 0
    private(set) public var voicedBlocks = 0

    public init(rule: VoiceActivityRule = .standard) {
        self.rule = rule
        floor = NoiseFloor(blocks: MicDetectorSettings.blocks(rule.noiseFloorSeconds))
    }

    /// One block of this mic. A block that is not newer than the last one is ignored.
    public mutating func add(_ block: AudioBlock) {
        if let lastIndex, block.index <= lastIndex { return }
        lastIndex = block.index
        blocks += 1
        let level = block.rmsDb
        let low = floor.add(level)
        let voiced = level > low + rule.voiceMarginDb && level > rule.minVoiceDb
        if voiced {
            voicedBlocks += 1
            if var open = run, block.index - open.last - 1 <= rule.joinGapBlocks {
                open.last = block.index
                open.voiced += 1
                run = open
            } else {
                close()
                run = (block.index, block.index, 1)
            }
        } else if let open = run, block.index - open.last > rule.joinGapBlocks {
            close()
        }
    }

    /// Ends the open stretch (keeps it when it is speech).
    private mutating func close() {
        if let segment = Self.segment(run, rule: rule) { segments.append(segment) }
        run = nil
    }

    private static func segment(_ run: (first: Int64, last: Int64, voiced: Int)?, rule: VoiceActivityRule) -> VoiceSegment? {
        guard let run, run.voiced >= rule.minVoicedBlocks, run.first >= 0 else { return nil }
        return VoiceSegment(startNs: UInt64(run.first) * AudioBlock.durationNs,
                            endNs: UInt64(run.last + 1) * AudioBlock.durationNs)
    }

    /// Every stretch so far, the open one included (up to its last voiced block). Always a new
    /// array: the monitor builds it under its lock, so the next block's append never has to copy
    /// a shared array on a capture queue.
    public var timeline: [VoiceSegment] {
        var all: [VoiceSegment] = []
        all.reserveCapacity(segments.count + 1)
        all.append(contentsOf: segments)
        if let open = Self.segment(run, rule: rule) { all.append(open) }
        return all
    }

    /// Voiced time in seconds.
    public var voicedSeconds: Double { Double(voicedBlocks) / AudioBlock.perSecond }
}

/// The speech stretches of a take, per mic: the camera mic (camera.mov A1) and the Mac mic
/// (screen.mov A1, or the metered Mac mic in Camera mode).
public struct VoiceTimeline: Sendable, Equatable {
    public var cameraMic: [VoiceSegment]
    public var screenMic: [VoiceSegment]
    /// Voiced time of each mic, in seconds.
    public var cameraMicVoicedS: Double
    public var screenMicVoicedS: Double
    /// The mic sent blocks during the take.
    public var cameraMicHeard: Bool
    public var screenMicHeard: Bool

    public init(cameraMic: [VoiceSegment] = [], screenMic: [VoiceSegment] = [], cameraMicVoicedS: Double = 0,
                screenMicVoicedS: Double = 0, cameraMicHeard: Bool? = nil, screenMicHeard: Bool? = nil) {
        self.cameraMic = cameraMic; self.screenMic = screenMic
        self.cameraMicVoicedS = cameraMicVoicedS; self.screenMicVoicedS = screenMicVoicedS
        self.cameraMicHeard = cameraMicHeard ?? !cameraMic.isEmpty
        self.screenMicHeard = screenMicHeard ?? !screenMic.isEmpty
    }

    public static let empty = VoiceTimeline()

    /// The camera mic hears the voice when the Mac mic has heard at least this much...
    static let fallbackCheckSeconds = 5.0
    /// ...and the camera mic less than this share of it: it is silent (an unplugged mic, a camera
    /// that sends silence), so the Mac mic speaks for the take.
    static let fallbackShare = 0.25

    /// The mic the timeline follows: the camera mic (the dialogue) when it sent audio and hears
    /// the voice, else the Mac mic. Nil when neither mic was heard.
    public var preferredSource: AudioSource? {
        if cameraMicHeard {
            let cameraSilent = screenMicHeard && screenMicVoicedS >= Self.fallbackCheckSeconds
                && cameraMicVoicedS < Self.fallbackShare * screenMicVoicedS
            return cameraSilent ? .screenMic : .cameraMic
        }
        return screenMicHeard ? .screenMic : nil
    }

    public func segments(_ source: AudioSource) -> [VoiceSegment] {
        switch source {
        case .cameraMic: cameraMic
        case .screenMic: screenMic
        case .systemAudio: []
        }
    }

    /// The other mic stands in where the preferred mic heard no voice for this long on either
    /// side of one of its stretches (2 s).
    static let standInGapNs: UInt64 = 2_000_000_000

    /// What the replay's Skip silence plays: the preferred mic's stretches, plus each stretch of
    /// the other mic with no stretch of the preferred mic within `standInGapNs` of it. So the
    /// replay follows the Mac mic while the camera mic is silent for a while (the Rode unplugged
    /// for 5 minutes of a 30-minute take), and the camera mic leads everywhere else.
    public var speech: [VoiceSegment] {
        guard let preferred = preferredSource else { return [] }
        let main = segments(preferred)
        let other = segments(preferred == .cameraMic ? .screenMic : .cameraMic)
        let standIns = Self.standIns(other, outside: main, gapNs: Self.standInGapNs)
        guard !standIns.isEmpty else { return main }
        return (main + standIns).sorted { ($0.startNs, $0.endNs) < ($1.startNs, $1.endNs) }
    }

    /// The stretches of `other` with no stretch of `main` within `gapNs` of them.
    static func standIns(_ other: [VoiceSegment], outside main: [VoiceSegment], gapNs: UInt64) -> [VoiceSegment] {
        guard !other.isEmpty else { return [] }
        guard !main.isEmpty else { return other }
        // One source's stretches never overlap: sorted by start, their ends are sorted too.
        let sorted = main.sorted { $0.startNs < $1.startNs }
        return other.filter { s in
            let from = s.startNs > gapNs ? s.startNs - gapNs : 0, to = s.endNs &+ gapNs
            // The first main stretch that ends after `from`: it is near when it starts before `to`.
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].endNs <= from { low = mid + 1 } else { high = mid }
            }
            return low == sorted.count || sorted[low].startNs >= to
        }
    }

    /// Stretches in seconds since `originNs` (a take's `started_at_host_ns`), cut at 0.
    public static func seconds(_ segments: [VoiceSegment], since originNs: UInt64) -> [(start: Double, end: Double)] {
        segments.compactMap { s in
            guard s.endNs > originNs else { return nil }
            let start = s.startNs > originNs ? Double(s.startNs - originNs) / 1e9 : 0
            return (start, Double(s.endNs - originNs) / 1e9)
        }
    }
}

/// Collects the voice timeline of a take from both mics. Lives inside `AudioLevelMonitor`'s lock.
public struct VoiceTimelineBuilder: Sendable {
    public private(set) var cameraMic: VoiceTrackBuilder
    public private(set) var screenMic: VoiceTrackBuilder

    public init(rule: VoiceActivityRule = .standard) {
        cameraMic = VoiceTrackBuilder(rule: rule)
        screenMic = VoiceTrackBuilder(rule: rule)
    }

    /// One block from a mic. System audio is no voice: it is ignored.
    public mutating func add(_ block: AudioBlock, from source: AudioSource) {
        switch source {
        case .cameraMic: cameraMic.add(block)
        case .screenMic: screenMic.add(block)
        case .systemAudio: break
        }
    }

    public var timeline: VoiceTimeline {
        VoiceTimeline(cameraMic: cameraMic.timeline, screenMic: screenMic.timeline,
                      cameraMicVoicedS: cameraMic.voicedSeconds, screenMicVoicedS: screenMic.voicedSeconds,
                      cameraMicHeard: cameraMic.blocks > 0, screenMicHeard: screenMic.blocks > 0)
    }
}

/// voice.jsonl: the voice timeline of a take, written at Stop next to events.jsonl. One JSON
/// object per line. The first line is the header (`type` `header`); each other line is one
/// stretch of speech (`type` `speech`) of one mic, in seconds since session.json
/// `started_at_host_ns` (like a flag's `elapsed_s`, so it is the time in camera.mov and
/// screen.mov). See docs/SCHEMA.md.
public enum VoiceTimelineFile {
    public static let version = "1"

    struct Line: Codable {
        var type: String
        var version: String?
        var originHostNs: String?
        var blockMs: String?
        var rule: String?
        var preferred: String?
        var cameraMicVoicedS: String?
        var screenMicVoicedS: String?
        var cameraMicHeard: String?
        var screenMicHeard: String?
        var source: String?
        var startS: Double?
        var endS: Double?
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Seconds with two decimals (a block is 50 ms).
    static func rounded(_ s: Double) -> Double { (s * 100).rounded() / 100 }

    /// The file's bytes for `timeline`, with times in seconds since `originNs`.
    public static func encode(_ timeline: VoiceTimeline, originNs: UInt64, rule: VoiceActivityRule = .standard) -> Data {
        let encoder = encoder()
        var out = Data()
        func put(_ line: Line) {
            guard let data = try? encoder.encode(line) else { return }
            out.append(data)
            out.append(0x0A)
        }
        put(Line(type: "header", version: version, originHostNs: String(originNs), blockMs: "50", rule: rule.summary,
                 preferred: timeline.preferredSource?.rawValue,
                 cameraMicVoicedS: String(format: "%.2f", timeline.cameraMicVoicedS),
                 screenMicVoicedS: String(format: "%.2f", timeline.screenMicVoicedS),
                 cameraMicHeard: String(timeline.cameraMicHeard), screenMicHeard: String(timeline.screenMicHeard)))
        for source in [AudioSource.cameraMic, .screenMic] {
            for span in VoiceTimeline.seconds(timeline.segments(source), since: originNs) {
                put(Line(type: "speech", source: source.rawValue, startS: rounded(span.start), endS: rounded(span.end)))
            }
        }
        return out
    }

    /// The timeline and its origin from the file's bytes. Lines that do not parse are skipped;
    /// nil without a header.
    public static func decode(_ data: Data) -> (timeline: VoiceTimeline, originNs: UInt64)? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var origin: UInt64?
        var header: Line?
        var camera: [VoiceSegment] = [], screen: [VoiceSegment] = []
        for raw in data.split(separator: 0x0A) {
            guard let line = try? decoder.decode(Line.self, from: Data(raw)) else { continue }
            if line.type == "header" {
                header = line
                origin = line.originHostNs.flatMap(UInt64.init)
                continue
            }
            guard line.type == "speech", let origin, let start = line.startS, let end = line.endS,
                  start.isFinite, end.isFinite, start >= 0, end >= start else { continue }
            let segment = VoiceSegment(startNs: origin + UInt64((start * 1e9).rounded()),
                                       endNs: origin + UInt64((end * 1e9).rounded()))
            switch line.source {
            case AudioSource.cameraMic.rawValue: camera.append(segment)
            case AudioSource.screenMic.rawValue: screen.append(segment)
            default: break
            }
        }
        guard let origin, let header else { return nil }
        let timeline = VoiceTimeline(cameraMic: camera, screenMic: screen,
                                     cameraMicVoicedS: header.cameraMicVoicedS.flatMap(Double.init) ?? 0,
                                     screenMicVoicedS: header.screenMicVoicedS.flatMap(Double.init) ?? 0,
                                     cameraMicHeard: header.cameraMicHeard.map { $0 == "true" } ?? !camera.isEmpty,
                                     screenMicHeard: header.screenMicHeard.map { $0 == "true" } ?? !screen.isEmpty)
        return (timeline, origin)
    }
}
