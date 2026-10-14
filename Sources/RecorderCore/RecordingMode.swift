/// What a session records.
public enum RecordingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case camera
    case screen
    case both

    public var id: String { rawValue }

    public var includesCamera: Bool { self != .screen }
    public var includesScreen: Bool { self != .camera }

    public var displayName: String {
        switch self {
        case .camera: "Camera"
        case .screen: "Screen"
        case .both: "Both"
        }
    }
}

/// Video codec for a recorded file.
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case hevc
    case h264
    case proRes422LT = "prores_422_lt"

    public var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes422LT: "ProRes 422 LT"
        }
    }
}
