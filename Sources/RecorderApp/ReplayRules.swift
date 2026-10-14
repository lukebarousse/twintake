import Foundation
import Replay
import WindowTools

// The Replay button's rules over plain data: what it opens, its help, and the replay window's
// status line. The window itself is ReplayWindow.swift; the playback is the Replay module.

enum ReplayRules {
    /// What Replay opens now.
    enum Target: Equatable {
        /// The take that records now: its files grow while the replay plays them.
        case live(URL)
        /// The last take, saved.
        case last(URL)
        /// Nothing, and why.
        case none(String)

        var folder: URL? {
            switch self {
            case let .live(url), let .last(url): url
            case .none: nil
            }
        }

        var isLive: Bool { if case .live = self { true } else { false } }
    }

    static let nothingYet = "Nothing to replay yet: record a take first."
    static let starting = "Replay works once the take records."
    static let saving = "Saving the take. Replay it once it is saved."

    /// While recording, the take that records; while idle, the last take. Never while a take
    /// starts or saves (its files are being created or finished then).
    static func target(state: SessionCoordinator.State, activeFolder: URL?, lastFolder: URL?) -> Target {
        switch state {
        case .recording:
            if let activeFolder { return .live(activeFolder) }
            return .none(starting)
        case .preparing:
            return .none(starting)
        case .stopping:
            return .none(saving)
        case .idle, .error:
            if let lastFolder { return .last(lastFolder) }
            return .none(nothingYet)
        }
    }

    /// The Replay button's help.
    static func help(_ target: Target, shown: Bool, shortcut: String = HotKey.replay.displayString) -> String {
        if shown { return "Close the replay window (\(shortcut)). The recording goes on." }
        switch target {
        case .live:
            return "Replay what you just recorded, with the screen, while the take goes on (\(shortcut)). Muted until you turn Sound on."
        case let .last(url):
            return "Replay the last take, \(url.lastPathComponent) (\(shortcut))."
        case let .none(reason):
            return reason
        }
    }

    /// The status while a mic check runs with Sound on: the replay plays without its sound.
    static let micCheckMuted = "Muted while the mic check runs."

    /// The replay's sound can come out of the speakers, which both mics hear, so the camera mic
    /// detector takes no evidence (`AudioLevelMonitor.setEvidencePaused`): Sound on and Play on,
    /// also while it waits at the live edge or for more speech (it may play any moment). Paused,
    /// ended, hidden or closed, nothing comes out: a saved take opened again after Stop with Sound
    /// on, but paused, must not stop the check before the next take. During a mic check the
    /// replay plays muted, so the check hears only the speaker.
    static func pausesMicEvidence(engineOpen: Bool, soundOn: Bool, playing: Bool, micCheckRuns: Bool) -> Bool {
        engineOpen && soundOn && playing && !micCheckRuns
    }

    /// The window's title.
    static func title(folder: URL, live: Bool) -> String {
        live ? "Replay · \(folder.lastPathComponent) · recording" : "Replay · \(folder.lastPathComponent)"
    }

    /// The line next to the time: what the replay waits for, or how far behind live it is.
    /// - Parameter notice: why the replay paused by itself (a recorder dropped frames).
    static func status(_ snapshot: ReplaySnapshot, live: Bool, saving: Bool, flagsOnly: Bool, flagCount: Int,
                       skipSilence: Bool, hasVoice: Bool, notice: String? = nil) -> String? {
        if saving { return "Saving the take…" }
        if let problem = snapshot.problem { return problem }
        if !snapshot.ready { return live ? "Waiting for the first movie fragment…" : "Opening…" }
        if let notice { return notice }
        if flagsOnly, flagCount == 0 { return "No flags yet." }
        if skipSilence, !hasVoice { return "No voice timeline: Skip silence plays everything." }
        if snapshot.ended { return flagsOnly ? "End of the flagged parts." : "End of the take." }
        if snapshot.waitingForSpeech { return "All speech so far played. Waiting for more…" }
        if snapshot.holding { return "Waiting for the next fragment…" }
        guard live else { return nil }
        let behind = snapshot.edge.behindS(snapshot.positionS)
        return snapshot.atLive ? "Live · \(Int(behind.rounded())) s behind" : ReplayClock.behindLive(behind, atLive: false)
    }
}
