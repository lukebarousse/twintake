/// The two shapes of a camera session.
public enum CameraGraphShape: String, Sendable, Hashable {
    /// The video input and the small preview output, and the camera mic meter when the idle
    /// meters are on: nothing records.
    case preview
    /// The recording outputs feed camera.mov's writer.
    case recording
}

/// Which capture objects a camera session holds next to the video input, which it always holds.
/// Plain data, so the graph decisions can be tested without a camera.
///
/// - Preview graph (nothing records; the camera window or the menu's preview is on): the video
///   input and the small preview output. With the idle meters on (`meteredPreview`), also the
///   camera audio input and the camera mic meter (`audioMeter`: an audio data output that only
///   meters into the app's `AudioLevelMonitor`, no file), so the camera mic meter and the mic
///   detector run before Start. macOS shows its orange microphone indicator for as long as a
///   session holds an audio input, so the plain preview shows only the green camera indicator.
///   No recording outputs, so no encoder runs while idle.
/// - Recording graph: the video input, the camera audio input when the config names one, the
///   recording outputs (`movieOutput`: the full-size video data output and the camera audio data
///   output that feed camera.mov's AVAssetWriter, which also meters the camera mic), and the
///   preview output only when the take keeps the live picture. Never the idle meter. The part
///   keeps its name `movie_output` so events.jsonl stays the same.
///
/// From the metered preview, Start keeps the camera audio input: it only adds the recording
/// outputs and drops the idle meter, so the session clock does not change at Start. Stop goes back
/// the same way.
public struct CameraGraphPlan: Sendable, Hashable, CustomStringConvertible {
    public enum Part: String, Sendable, Hashable, CaseIterable, Comparable {
        case audioInput = "audio_input"
        /// The idle camera mic meter: an audio data output on the camera audio input that only
        /// meters. Only in the preview graph, always with `audioInput`.
        case audioMeter = "audio_meter"
        case movieOutput = "movie_output"
        case previewOutput = "preview_output"

        public static func < (a: Part, b: Part) -> Bool {
            (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
        }
    }

    public var parts: Set<Part>

    public init(_ parts: Set<Part> = []) { self.parts = parts }

    /// The idle graph: the video input and the preview output.
    public static let preview = CameraGraphPlan([.previewOutput])

    /// The idle graph with the meters: the preview, plus the camera audio input and its meter.
    public static let meteredPreview = CameraGraphPlan([.previewOutput, .audioInput, .audioMeter])

    /// `meteredPreview` with `meters`, else `preview`.
    public static func preview(meters: Bool) -> CameraGraphPlan { meters ? .meteredPreview : .preview }

    public var hasAudioInput: Bool { parts.contains(.audioInput) }
    public var hasAudioMeter: Bool { parts.contains(.audioMeter) }
    public var hasMovieOutput: Bool { parts.contains(.movieOutput) }
    public var hasPreviewOutput: Bool { parts.contains(.previewOutput) }
    public var shape: CameraGraphShape { hasMovieOutput ? .recording : .preview }

    /// e.g. "recording (video_input, audio_input, movie_output)".
    public var description: String {
        "\(shape.rawValue) (\((["video_input"] + parts.sorted().map(\.rawValue)).joined(separator: ", ")))"
    }

    /// This preview graph with (true) or without (false) the camera mic meter: the camera audio
    /// input and the meter join or leave together, and the preview output stays as it is. A
    /// recording graph comes back unchanged (the meters never change while a take records).
    public func withMeters(_ on: Bool) -> CameraGraphPlan {
        guard shape == .preview else { return self }
        var parts = self.parts
        if on { parts.formUnion([.audioInput, .audioMeter]) } else { parts.subtract([.audioInput, .audioMeter]) }
        return CameraGraphPlan(parts)
    }

    /// The graph the camera session should hold, or nil when no session is wanted (the camera closes).
    /// - Parameters:
    ///   - recording: a take runs, from its prepare until its file has finished.
    ///   - previewWanted: a view shows the camera (the camera window or the menu's preview), or a
    ///     preview feed was handed to the take.
    ///   - keepPreviewWhileRecording: the take keeps the live picture (the camera window stays live).
    ///   - audioDeviceUID: the config's camera audio input; nil records no audio and meters none.
    ///   - idleMeters: while idle, the preview also meters the camera mic (the app's meters are on
    ///     and the microphone is allowed). No effect while recording.
    public static func wanted(recording: Bool, previewWanted: Bool, keepPreviewWhileRecording: Bool,
                              audioDeviceUID: String?, idleMeters: Bool = false) -> CameraGraphPlan? {
        guard recording else { return previewWanted ? .preview(meters: idleMeters && audioDeviceUID != nil) : nil }
        return .recording(audioDeviceUID: audioDeviceUID, previewOutput: previewWanted && keepPreviewWhileRecording)
    }

    /// The recording graph: the recording outputs, the camera audio input when `audioDeviceUID` is
    /// set, and the preview output when the take keeps it.
    public static func recording(audioDeviceUID: String?, previewOutput: Bool) -> CameraGraphPlan {
        var parts: Set<Part> = [.movieOutput]
        if audioDeviceUID != nil { parts.insert(.audioInput) }
        if previewOutput { parts.insert(.previewOutput) }
        return CameraGraphPlan(parts)
    }
}

/// How a camera session goes from one plan to another.
public enum CameraGraphStep: Sendable, Hashable {
    /// The session already holds the wanted graph (or none is open and none is wanted).
    case none
    /// No session is open: build one with this graph.
    case build(CameraGraphPlan)
    /// Change the running session in one beginConfiguration/commitConfiguration.
    case change(add: Set<CameraGraphPlan.Part>, remove: Set<CameraGraphPlan.Part>)
    /// Stop the session and release the devices.
    case tearDown

    public static func from(_ current: CameraGraphPlan?, to wanted: CameraGraphPlan?) -> CameraGraphStep {
        switch (current, wanted) {
        case (nil, nil): return .none
        case let (nil, wanted?): return .build(wanted)
        case (_?, nil): return .tearDown
        case let (current?, wanted?):
            guard current != wanted else { return .none }
            return .change(add: wanted.parts.subtracting(current.parts), remove: current.parts.subtracting(wanted.parts))
        }
    }

    /// The change that puts the session back: a failed upgrade returns to the graph it started from.
    public var undo: CameraGraphStep {
        guard case let .change(add, remove) = self else { return .none }
        return .change(add: remove, remove: add)
    }

    /// False for a change while camera.mov is written: the session never adds or removes an input or
    /// an output mid-file. A teardown stops the file first, so it is always allowed.
    public func allowed(whileWritingFile writing: Bool) -> Bool {
        guard case .change = self else { return true }
        return !writing
    }
}

/// One change of a camera session's graph, for events.jsonl (`camera_graph`) and the log.
public struct CameraGraphChange: Sendable, Equatable {
    /// Nil: no session was open; this one was built.
    public var from: CameraGraphPlan?
    public var to: CameraGraphPlan
    /// How long the change took, the format check included. A change of a running session counts
    /// its time on the camera queue; a build counts from the open call until the session ran.
    public var durationNs: UInt64
    /// The session had reset the camera's format or frame rate, and it was set again.
    public var formatReset: Bool
    /// What the camera runs after the change, e.g. "3840x2160 420v 23.976".
    public var negotiatedFormat: String
    /// The camera audio input in the graph after the change, if any.
    public var audioDevice: String?

    public init(from: CameraGraphPlan?, to: CameraGraphPlan, durationNs: UInt64, formatReset: Bool,
                negotiatedFormat: String, audioDevice: String? = nil) {
        self.from = from; self.to = to; self.durationNs = durationNs; self.formatReset = formatReset
        self.negotiatedFormat = negotiatedFormat; self.audioDevice = audioDevice
    }

    public var milliseconds: Int { Int((Double(durationNs) / 1e6).rounded()) }

    public var eventData: [String: String] {
        var data = ["source": "camera", "from": from?.shape.rawValue ?? "closed", "to": to.shape.rawValue,
                    "ms": "\(milliseconds)", "audio_input": to.hasAudioInput ? "on" : "off",
                    "audio_meter": to.hasAudioMeter ? "on" : "off",
                    "preview_output": to.hasPreviewOutput ? "on" : "off", "format": negotiatedFormat,
                    "format_reset": "\(formatReset)"]
        data["audio_device"] = audioDevice
        return data
    }

    /// e.g. "preview -> recording in 312 ms: recording (video_input, audio_input, movie_output), 3840x2160 420v 23.976".
    public var logLine: String {
        "\(from?.shape.rawValue ?? "closed") -> \(to.shape.rawValue) in \(milliseconds) ms: \(to), \(negotiatedFormat)"
            + (formatReset ? " (format set again)" : "")
    }
}
