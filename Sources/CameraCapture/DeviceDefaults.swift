import Foundation
import RecorderCore

/// The rules for default device picks, over plain device lists so they can be tested.
///
/// None of them ever falls back to the system default input. On a desk with a USB interface,
/// the default input is rarely the mic you want, and it changes when devices come and go.
enum DeviceDefaults {
    /// The capture card: a camera whose name contains "Cam Link", else the first external camera.
    static func cameraUID(in videos: [CaptureDeviceInfo]) -> String? {
        if let camLink = videos.first(where: { $0.name.localizedCaseInsensitiveContains("Cam Link") }) {
            return camLink.uid
        }
        return videos.first(where: { !$0.isBuiltIn })?.uid
    }

    /// The audio input that belongs to a camera: a device macOS links to it, else one with the
    /// same name ("Cam Link 4K" video and "Cam Link 4K" audio), else one whose name contains the
    /// other's.
    static func cameraAudioUID(cameraName: String, linkedAudioUIDs: [String], in audio: [CaptureDeviceInfo]) -> String? {
        if let linked = audio.first(where: { linkedAudioUIDs.contains($0.uid) }) {
            return linked.uid
        }
        let name = cameraName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let same = audio.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return same.uid
        }
        return audio.first(where: {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        })?.uid
    }

    /// The Mac's own mic ("MacBook Pro Microphone") for screen.mov track A1.
    static func screenMicUID(in audio: [CaptureDeviceInfo]) -> String? {
        let builtIn = audio.filter(\.isBuiltIn)
        if let mic = builtIn.first(where: { $0.name.localizedCaseInsensitiveContains("Microphone") }) {
            return mic.uid
        }
        if let mic = builtIn.first { return mic.uid }
        return audio.first(where: { $0.uid == builtInMicrophoneUID })?.uid
    }

    /// The uniqueID macOS gives the built-in microphone on Apple silicon Macs.
    static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"
}
