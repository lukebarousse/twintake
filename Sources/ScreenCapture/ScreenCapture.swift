// ScreenCapture: the screen frame, a Mac mic and system audio to screen.mov.
//
// ScreenRecorder (SessionTrackRecorder) runs one SCStream (plus a system-audio stream in window
// mode) into one AVAssetWriter. The video is forced to a constant frame rate on an exact rational
// grid (CFRGrid); each audio track is trimmed and padded onto the same timeline (AudioAligner).
// The grid math, the audio path and the writer settings live in MediaWriter, shared with camera.mov.
// With a scheduled start (`start(writingTo:events:at:)`) the file begins at the first point of
// the screen's frame lattice at or after that host time.

import CoreGraphics
import Foundation

/// Errors from `ScreenRecorder.prepare()` and `ScreenRecorder.start(writingTo:events:)`.
public enum ScreenRecorderError: Error, LocalizedError, Sendable, Equatable {
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(UInt32)
    /// `start` was called before `prepare` finished.
    case notPrepared
    /// Another `prepare` or `start` is running, or a recording is in progress.
    case busy
    /// The capture stream stopped before recording began.
    case streamStopped(String)
    case outputExists(String)
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .displayNotFound(id): "Display \(id) is not available for capture."
        case let .windowNotFound(id): "Window \(id) is not available for capture. It may have closed."
        case .notPrepared: "The screen recorder is not prepared."
        case .busy: "The screen recorder is busy."
        case let .streamStopped(reason): "Screen capture stopped: \(reason)"
        case let .outputExists(path): "A file already exists at \(path)."
        case let .writerFailed(reason): "Could not write screen.mov: \(reason)"
        }
    }
}
