import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import Security

/// The macOS permissions: the four the recorder needs, and Input Monitoring, which only adds
/// shortcuts other apps own to the on-screen keystrokes.
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case camera, microphone, screenRecording, accessibility, inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "macwindow.on.rectangle"
        case .inputMonitoring: "keyboard"
        }
    }

    /// What the permission is for, in a few words.
    var purpose: String {
        switch self {
        case .camera: "camera.mov"
        case .microphone: "all mic tracks"
        case .screenRecording: "screen.mov and system audio"
        case .accessibility: "snapping the window and keystrokes"
        case .inputMonitoring: "showing shortcuts other apps own (e.g. ⇧⌘4)"
        }
    }

    /// The recorder needs it. Input Monitoring is optional: without it everything works, and only
    /// shortcuts other apps own show as their modifiers alone. A missing optional permission does
    /// not open the Permissions section by itself.
    var isRequired: Bool { self != .inputMonitoring }

    /// The line under the permission's name: "For camera.mov · Allowed", or for an optional one
    /// "Optional, for showing shortcuts other apps own (e.g. ⇧⌘4) · Not allowed".
    func caption(_ state: PermissionState) -> String {
        (isRequired ? "For " : "Optional, for ") + "\(purpose) · \(state.label)"
    }

    /// System Settings > Privacy & Security, at this permission's list.
    var settingsURL: URL? {
        let anchor = switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum PermissionState: Sendable, Equatable {
    case granted
    /// Never asked. Clicking Allow shows the macOS prompt.
    case notDetermined
    case denied
    /// Not granted, and macOS does not say whether it asked before (Screen Recording,
    /// Accessibility, Input Monitoring).
    case notGranted

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .notDetermined: "Not asked yet"
        case .denied: "Denied"
        case .notGranted: "Not allowed"
        }
    }
}

/// Reads permission states without prompting. Prompts only from `request`, which the UI calls
/// when the user clicks a button.
@MainActor
@Observable
final class PermissionCenter {
    private(set) var states: [PermissionKind: PermissionState] = [:]
    /// Reads the states: macOS in the app (`systemStates`), fixed states for the docs screenshots.
    @ObservationIgnored private let read: @MainActor () -> [PermissionKind: PermissionState]

    init(read: @escaping @MainActor () -> [PermissionKind: PermissionState] = PermissionCenter.systemStates) {
        self.read = read
        refresh()
    }

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notGranted }

    func refresh() {
        let s = read()
        if s != states { states = s }
    }

    /// The states as macOS reports them now. Never prompts.
    static func systemStates() -> [PermissionKind: PermissionState] {
        var s: [PermissionKind: PermissionState] = [:]
        s[.camera] = avState(.video)
        s[.microphone] = avState(.audio)
        s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .notGranted
        s[.inputMonitoring] = CGPreflightListenEventAccess() ? .granted : .notGranted
        return s
    }

    /// Shows the macOS prompt (or, when macOS will not ask again, opens System Settings).
    func request(_ kind: PermissionKind) async {
        switch kind {
        case .camera, .microphone:
            let type: AVMediaType = kind == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: type)
            } else {
                openSettings(kind)
            }
        case .screenRecording, .accessibility, .inputMonitoring:
            // macOS prompts only once for these. Its prompt has its own Open System Settings button,
            // so the first click shows only the prompt and later clicks open Settings. macOS ties
            // the grant to the code signature, so a new build (new signature) may prompt again:
            // the flag stores the build it was set for.
            let askedKey = "permissions.asked.\(kind.rawValue)"
            guard Self.shouldPrompt(askedFor: UserDefaults.standard.string(forKey: askedKey), build: Self.buildID) else {
                openSettings(kind)
                break
            }
            UserDefaults.standard.set(Self.buildID, forKey: askedKey)
            switch kind {
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            case .inputMonitoring: _ = CGRequestListenEventAccess()
            default: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        }
        refresh()
    }

    /// True when the macOS prompt was not yet shown for this build.
    nonisolated static func shouldPrompt(askedFor: String?, build: String) -> Bool { askedFor != build }

    /// Identifies this build's code signature: the code directory hash (changes with every build,
    /// ad hoc or not), else the executable's modification time.
    nonisolated static let buildID: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
           let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            return unique.map { String(format: "%02x", $0) }.joined()
        }
        let modified = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return modified.map { "mtime-\($0.timeIntervalSince1970)" } ?? "unknown"
    }()

    func openSettings(_ kind: PermissionKind) {
        if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    }

    private static func avState(_ type: AVMediaType) -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
