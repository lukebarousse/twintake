import Foundation
import RecorderCore
import Synchronization

/// What the replay knows about a take from its events.jsonl (and, for a finished take, from
/// session.json and voice.jsonl): when take time 0 is, where each movie begins, its audio tracks
/// and its flags. Plain data, filled event by event, so a live take's file can be read as it grows.
public struct ReplayTakeInfo: Sendable, Equatable {
    /// session.json `started_at_host_ns`: the `session_start` event's time.
    public var startedAtHostNs: UInt64?
    /// `first_pts_host_ns` of each movie's video track (its `track_start`).
    public var firstPtsHostNs: [ReplayFileKind: UInt64] = [:]
    /// The audio tracks, from their `track_start` events.
    public var audioTracks: [ReplayAudioTrack] = []
    /// Flag markers, in take time.
    public var flags: [FlagMark] = []
    /// `session_stop` was logged.
    public var stopped = false

    public init() {}

    /// Take time 0 and the files' offsets.
    public var alignment: MediaAlignment {
        MediaAlignment(startedAtHostNs: startedAtHostNs, firstPtsHostNs: firstPtsHostNs)
    }

    public mutating func apply(_ event: SessionEvent) {
        let data = event.data ?? [:]
        switch event.type {
        case .sessionStart:
            startedAtHostNs = event.tHostNs
        case .sessionStop:
            stopped = true
        case .trackStart:
            guard let file = data["file"].flatMap(Self.kind(file:)), let role = data["role"].flatMap(TrackInfo.Role.init) else { return }
            if role == file.videoRole, let pts = data["first_pts_host_ns"].flatMap(UInt64.init) {
                firstPtsHostNs[file] = pts
            } else if role == .mic || role == .systemAudio, let index = data["track_index"].flatMap(Int.init) {
                let track = ReplayAudioTrack(file: file, trackIndex: index, role: role)
                if !audioTracks.contains(track) { audioTracks.append(track) }
            }
        case .marker:
            guard data["kind"] == "flag", let at = data["elapsed_s"].flatMap(Double.init) else { return }
            let flag = FlagMark(atS: at, lookbackS: data["lookback_s"].flatMap(Double.init) ?? 180)
            if !flags.contains(flag) { flags.append(flag) }
        default:
            break
        }
    }

    public mutating func apply(_ events: [SessionEvent]) { for event in events { apply(event) } }

    /// The tracks of a finished take, from session.json (a crash-recovered take may have none:
    /// its events still tell).
    public mutating func apply(_ manifest: SessionManifest) {
        if let started = manifest.startedAtHostNs { startedAtHostNs = started }
        for track in manifest.tracks {
            guard let file = Self.kind(file: track.file) else { continue }
            if track.role == file.videoRole, let pts = track.firstPtsHostNs {
                firstPtsHostNs[file] = pts
            } else if track.role == .mic || track.role == .systemAudio {
                let audio = ReplayAudioTrack(file: file, trackIndex: track.trackIndex, role: track.role)
                if !audioTracks.contains(audio) { audioTracks.append(audio) }
            }
        }
        if manifest.status != .recording { stopped = true }
    }

    static func kind(file: String) -> ReplayFileKind? {
        ReplayFileKind.allCases.first { $0.fileName == file }
    }
}

/// Reads the lines appended to a JSON-lines file since the last read: events.jsonl while the take
/// writes it. A line cut at the end of the file (the writer is mid-line) waits for the next read.
/// Thread-safe; one small read per call.
public final class EventsTail: Sendable {
    public let url: URL
    private struct State {
        var offset: UInt64 = 0
        var partial = Data()
    }
    private let state = Mutex(State())

    public init(url: URL) { self.url = url }

    /// The events appended since the last call (all of them the first time).
    public func readNew() -> [SessionEvent] {
        state.withLock { s in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: s.offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
                return []
            }
            s.offset += UInt64(data.count)
            var bytes = s.partial
            bytes.append(data)
            guard let lastNewline = bytes.lastIndex(of: 0x0A) else {
                s.partial = bytes
                return []
            }
            s.partial = Data(bytes[bytes.index(after: lastNewline)...])
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return bytes[..<lastNewline].split(separator: 0x0A).compactMap { try? decoder.decode(SessionEvent.self, from: Data($0)) }
        }
    }
}

/// A take on disk, as the replay opens it.
public struct ReplayTakeFiles: Sendable, Equatable {
    public var folder: URL
    /// The movies that exist (camera mode: camera.mov only; screen mode: screen.mov only).
    public var files: [ReplayFileKind]

    public init(folder: URL, files: [ReplayFileKind]) {
        self.folder = folder
        self.files = files
    }

    /// The movies in `folder`.
    public static func find(in folder: URL) -> ReplayTakeFiles {
        let found = ReplayFileKind.allCases.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
        }
        return ReplayTakeFiles(folder: folder, files: found)
    }

    public func url(_ kind: ReplayFileKind) -> URL { folder.appendingPathComponent(kind.fileName) }

    /// Reads everything a finished take has: session.json, events.jsonl and voice.jsonl.
    public func loadFinished() -> (info: ReplayTakeInfo, voice: VoiceTimeline?, voiceOriginNs: UInt64?) {
        let session = SessionFolder(url: folder)
        var info = ReplayTakeInfo()
        if let events = try? EventLog.read(session.eventsURL) { info.apply(events) }
        if let manifest = try? session.readManifest() { info.apply(manifest) }
        let voice = (try? Data(contentsOf: session.voiceURL)).flatMap(VoiceTimelineFile.decode)
        return (info, voice?.timeline, voice?.originNs)
    }
}
