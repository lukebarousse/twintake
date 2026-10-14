import Foundation

/// One recording session on disk:
///
///     2026-10-12_174000/
///       camera.mov
///       screen.mov
///       session.json
///       events.jsonl
///       voice.jsonl     (1.4: the voice timeline, written at Stop)
///
/// Raw files are never changed after Stop. Tools that process a session write only to `derived/`.
public struct SessionFolder: Sendable {
    public static let cameraFileName = "camera.mov"
    public static let screenFileName = "screen.mov"
    public static let manifestFileName = "session.json"
    public static let eventsFileName = "events.jsonl"
    /// The voice timeline of the take (`VoiceTimelineFile`), written at Stop. Added in 1.4.
    public static let voiceFileName = "voice.jsonl"
    public static let derivedDirectoryName = "derived"

    public let url: URL
    public var cameraURL: URL { url.appendingPathComponent(Self.cameraFileName) }
    public var screenURL: URL { url.appendingPathComponent(Self.screenFileName) }
    public var manifestURL: URL { url.appendingPathComponent(Self.manifestFileName) }
    public var eventsURL: URL { url.appendingPathComponent(Self.eventsFileName) }
    public var voiceURL: URL { url.appendingPathComponent(Self.voiceFileName) }

    public init(url: URL) { self.url = url }

    /// Folder name for a session: "yyyy-MM-dd_HHmmss", plus "_slug" when given.
    public static func folderName(for date: Date, slug: String? = nil, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        var name = f.string(from: date)
        if let slug = slug.map(sanitize), !slug.isEmpty { name += "_" + slug }
        return name
    }

    /// Creates a new, empty session folder under `root`. Adds "-2", "-3"... if the name exists.
    public static func create(in root: URL, date: Date = Date(), slug: String? = nil) throws -> SessionFolder {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(for: date, slug: slug)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return SessionFolder(url: candidate)
    }

    /// Writes session.json atomically (temp file + rename), so a crash never leaves half a file.
    public func writeManifest(_ manifest: SessionManifest) throws {
        let data = try SessionManifest.encoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> SessionManifest {
        try SessionManifest.decoder().decode(SessionManifest.self, from: Data(contentsOf: manifestURL))
    }

    /// Free space on the volume that holds `url`, in bytes.
    public static func availableCapacity(at url: URL) -> Int64? {
        // A URL caches resource values, so read from a fresh one to get the current number.
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The smaller of the plain free space and the free space for important use, in bytes. Use it
    /// while recording: it never counts purgeable space that a file write may not get.
    public static func conservativeFreeSpace(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys) else { return nil }
        let plain = values.volumeAvailableCapacity.map(Int64.init)
        return [plain, values.volumeAvailableCapacityForImportantUsage].compactMap { $0 }.min()
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
