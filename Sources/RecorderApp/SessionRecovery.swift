import Foundation
import RecorderCore

/// Finds sessions the app never finished (crash, force quit, power loss) and marks them
/// `recovered`. The movie files are left as they are: movie fragments keep them playable up to
/// the last fragment.
enum SessionRecovery {
    static let recoveredError = "The app stopped while recording (crash, force quit or power loss). "
        + "The files play up to their last movie fragment; tracks and durations were not filled in."

    /// UserDefaults key with the path of the session being recorded. Launch checks only that
    /// folder, so it never lists the output folder: on an external, network or protected volume
    /// that can show a Files & Folders prompt or stall the launch.
    static let inProgressKey = "session.inProgressPath"

    static func markInProgress(_ folder: URL, defaults: UserDefaults = .standard) {
        defaults.set(folder.path, forKey: inProgressKey)
    }

    static func clearInProgress(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: inProgressKey)
    }

    /// The session an earlier run left in progress, removed from the defaults so it is checked once.
    static func takeInProgress(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: inProgressKey), !path.isEmpty else { return nil }
        clearInProgress(defaults: defaults)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Marks every session folder directly under `root` whose session.json still says
    /// `recording`. Logs a warning in each one's events.jsonl. Returns the folders it changed.
    @discardableResult
    static func recoverInterrupted(in root: URL, skipping skipped: Set<URL> = []) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        let skippedPaths = Set(skipped.map(\.standardizedFileURL.path))
        return children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).filter { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !skippedPaths.contains(dir.standardizedFileURL.path) else { return false }
            return recoverIfInterrupted(dir)
        }
    }

    /// Marks one session folder `recovered` when its session.json still says `recording`, and logs
    /// a warning in its events.jsonl. Returns true when it changed the folder.
    @discardableResult
    static func recoverIfInterrupted(_ dir: URL) -> Bool {
        let folder = SessionFolder(url: dir)
        guard var manifest = try? folder.readManifest(), manifest.status == .recording else { return false }
        manifest.status = .recovered
        if !manifest.errors.contains(recoveredError) { manifest.errors.append(recoveredError) }
        do {
            try folder.writeManifest(manifest)
        } catch {
            return false
        }
        if let log = try? EventLog(url: folder.eventsURL) {
            log.append(.warning, ["source": "app",
                                  "message": "Marked recovered at launch: session.json still said recording."])
            log.close()
        }
        return true
    }
}
