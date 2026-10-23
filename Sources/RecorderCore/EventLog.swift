import Foundation

/// One line of events.jsonl.
public struct SessionEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case sessionStart = "session_start"
        case sessionStop = "session_stop"
        case trackStart = "track_start"
        case trackStop = "track_stop"
        /// data["kind"]: "flag" (with "lookback_s": something in that many seconds before it was
        /// wrong). Older recordings also have "retake" and "good"; "chapter" and "note" are reserved.
        case marker
        case windowSnap = "window_snap"
        case windowMove = "window_move"
        case droppedFrames = "dropped_frames"
        case deviceLost = "device_lost"
        /// The camera session changed its graph: preview (no recording outputs; the camera audio
        /// input only with the idle meters, `audio_meter` on) to recording at Start, recording back
        /// to preview after Stop.
        case cameraGraph = "camera_graph"
        /// The camera mic detector changed its verdict (`external_mic`, `built_in_mic`, `unknown`)
        /// or its "camera mic isn't picking up your voice" warning. See `MicDetectorChange`.
        case micDetector = "mic_detector"
        /// The camera mic detector confirmed the external mic in the take (1.5): the mic rules
        /// stop for the rest of it. Once per take at most. See `MicDetectorChange.confirmationData`.
        case micConfirmed = "mic_confirmed"
        /// The camera's USB link at Start: speed, USB generation, vendor and product id.
        case usbLink = "usb_link"
        /// The camera sent empty frames (all-zero planes or one flat value), or a picture again:
        /// `data.state` is `start` or `end`.
        case emptyFrames = "empty_frames"
        /// The replay window opened during the take (1.4): the speaker reviews what was recorded,
        /// so an editor cuts from here to `replay_end`. `data`: `elapsed_s`, `position_s`,
        /// `sound`, `skip_silence`, `flags_only`.
        case replayStart = "replay_start"
        /// The replay window closed, or the take stopped with it open (1.4). `data`: `elapsed_s`,
        /// `open_s`, `sound_on_s`, `reason` (`closed` or `stop`).
        case replayEnd = "replay_end"
        /// The replay's Sound switch changed during the take (1.4): its sound may be in the mics.
        /// `data`: `state` (`on` or `off`), `elapsed_s`.
        case replaySound = "replay_sound"
        /// A keystroke the on-screen pill showed during the take (1.6): a shortcut or a named key,
        /// never a typed character. `data`: `label` (as shown), `mac_label`, `repeat`, `elapsed_s`.
        case keystroke
        case warning
        case error
    }

    public var tHostNs: UInt64
    /// Wall-clock time, ISO 8601 with time zone.
    public var wall: String
    public var type: Kind
    public var data: [String: String]?

    public init(tHostNs: UInt64, wall: String, type: Kind, data: [String: String]? = nil) {
        self.tHostNs = tHostNs; self.wall = wall; self.type = type; self.data = data
    }
}

/// Append-only event log. Safe to call from any thread, and it never waits for the disk.
///
/// `append` writes the line to the file before it returns (one write call, into the system's
/// file cache), so a crash or a `kill -9` of the app keeps every event written so far. The flush
/// to the disk itself (fsync, tens of ms while two encoders write) runs on a background queue, at
/// most one at a time: the capture queues that log events never block on it.
public final class EventLog: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    /// Flushes to the disk and closes the file, in order, off the caller's thread.
    private let diskQueue = DispatchQueue(label: "TwinTake.events.fsync", qos: .utility)
    private let flush = FlushState()
    private var closed = false

    public init(url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { close() }

    /// Appends one event stamped with the current host time.
    public func append(_ type: SessionEvent.Kind, _ data: [String: String]? = nil, at tHostNs: UInt64 = HostClock.nowNs()) {
        let event = SessionEvent(tHostNs: tHostNs, wall: SessionManifest.isoString(Date()), type: type, data: data)
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            try handle.write(contentsOf: line)
        } catch {
            // Logging must never take a recording down.
            return
        }
        scheduleFlush()
    }

    /// Flushes and closes the file on the disk queue, after any flush still waiting there. Lines
    /// appended before `close` are already in the file.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let handle = handle
        diskQueue.async {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    /// One fsync at a time: a line written while one waits rides along with it. Call with `lock` held.
    private func scheduleFlush() {
        guard flush.claim() else { return }
        let fd = handle.fileDescriptor, flush = flush
        diskQueue.async {
            // Cleared first: a line written during the fsync schedules the next one.
            flush.release()
            _ = fsync(fd)
        }
    }

    /// Reads every event in a log file. Skips lines that do not parse (for example a line cut by a crash).
    public static func read(_ url: URL) throws -> [SessionEvent] {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? d.decode(SessionEvent.self, from: Data($0.utf8)) }
    }
}

/// Whether a flush is waiting on the disk queue. Its own lock, so the disk queue never takes the log's.
private final class FlushState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    /// True when the caller should schedule a flush (none was waiting).
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending { return false }
        pending = true
        return true
    }

    func release() { lock.withLock { pending = false } }
}
