import Foundation
import RecorderCore

/// A fixed device pick as saved in the settings: the uid it records from, plus what identifies the
/// device when its uid changes. A capture card's uid holds its USB location, so the Cam Link 4K
/// gets a new uid on another USB port (0x206000000fd90066 became 0x22000000fd90066); its name and
/// model stay the same.
struct SavedDevice: Equatable, Sendable {
    var uid: String
    var name: String
    /// `AVCaptureDevice.modelID`, for cameras.
    var modelID: String?
    /// The uids of other devices with the same name that were connected while this device was.
    /// They are other devices (a second Cam Link), never this one on a new port, so a rematch
    /// never picks one of them.
    var others: Set<String>

    /// The stored form, a plist dictionary.
    var storage: [String: String] {
        var d = ["uid": uid, "name": name]
        d["model"] = modelID
        if !others.isEmpty { d["others"] = others.sorted().joined(separator: "\n") }
        return d
    }

    init(uid: String, name: String, modelID: String? = nil, others: Set<String> = []) {
        self.uid = uid; self.name = name; self.modelID = modelID; self.others = others
    }

    init?(storage: [String: String]?) {
        guard let storage, let uid = storage["uid"], !uid.isEmpty, let name = storage["name"] else { return nil }
        let others = storage["others"].map { Set($0.components(separatedBy: "\n").filter { !$0.isEmpty }) } ?? []
        self.init(uid: uid, name: name, modelID: storage["model"], others: others)
    }
}

/// Finds a saved device again after its uid changed. Plain data, so it is tested without devices.
enum DeviceRematch {
    /// The three device pickers.
    enum Role: String, Sendable, CaseIterable {
        case camera, cameraAudio, screenMic

        /// Cameras also match on the model; audio inputs carry no model.
        var matchesModel: Bool { self == .camera }

        /// True when `candidate` can be the saved device on a new uid. Cameras: any uid (the name
        /// and model decide). Audio inputs: both uids are USB audio uids of the same maker and
        /// product. A built-in, Bluetooth or virtual input keeps its uid, so a missing one is off,
        /// not moved, and another input with its name is another device.
        func uidCanMove(from saved: String, to candidate: String) -> Bool {
            guard self != .camera else { return true }
            guard let product = DeviceRematch.usbAudioProduct(saved) else { return false }
            return DeviceRematch.usbAudioProduct(candidate) == product
        }

        /// What a notice calls the device, e.g. "Cam Link 4K audio".
        func label(_ name: String) -> String {
            switch self {
            case .camera: name
            case .cameraAudio: "\(name) audio"
            case .screenMic: "\(name) (screen mic)"
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        /// The saved uid is connected; nothing to do.
        case present
        /// Exactly one connected device has the saved name (and model), and it was never connected
        /// next to the saved device: it is the same device on a new uid.
        case moved(SavedDevice)
        /// Several connected devices have the saved name: the app does not guess.
        case ambiguous(count: Int)
        /// No connected device can be the saved one: none has its name, or each one that has it is
        /// a known other device (`SavedDevice.others`).
        case missing
    }

    /// Looks for `saved` in `devices`: by uid, else by name (and model for cameras), leaving out
    /// the devices that were connected next to it (`SavedDevice.others`).
    static func resolve(_ saved: SavedDevice, in devices: [CaptureDeviceInfo], role: Role) -> Outcome {
        if devices.contains(where: { $0.uid == saved.uid }) { return .present }
        let name = trimmed(saved.name)
        guard !name.isEmpty else { return .missing }
        let same = devices.filter { device in
            guard trimmed(device.name) == name, !saved.others.contains(device.uid),
                  role.uidCanMove(from: saved.uid, to: device.uid) else { return false }
            // A saved model must match (but for its USB product id); a device or save without one
            // matches on the name alone.
            guard role.matchesModel, let model = saved.modelID, let other = device.modelID else { return true }
            return modelFamily(model) == modelFamily(other)
        }
        switch same.count {
        case 0: return .missing
        case 1: return .moved(SavedDevice(uid: same[0].uid, name: same[0].name, modelID: same[0].modelID ?? saved.modelID,
                                          others: saved.others))
        default: return .ambiguous(count: same.count)
        }
    }

    /// What to save for a fixed pick that is connected now: its uid, name, (cameras) model, and the
    /// other devices with its name that are connected now or were before (`previous`, same uid).
    /// Nil for Automatic, None, or a device that is not connected (the old save is kept then).
    static func identity(of choice: DeviceChoice, in devices: [CaptureDeviceInfo], role: Role,
                         previous: SavedDevice? = nil) -> SavedDevice? {
        guard case let .device(uid) = choice, let device = devices.first(where: { $0.uid == uid }) else { return nil }
        let name = trimmed(device.name)
        var others = Set(devices.filter { $0.uid != uid && trimmed($0.name) == name }.map(\.uid))
        if let previous, previous.uid == uid { others.formUnion(previous.others) }
        return SavedDevice(uid: uid, name: device.name, modelID: role.matchesModel ? device.modelID : nil, others: others)
    }

    /// A camera model without its USB product id: "UVC Camera VendorID_4057" for "UVC Camera
    /// VendorID_4057 ProductID_102". The Cam Link 4K on its USB 2 lane reports product 0x0067
    /// (ProductID_103) instead of 0x0066 under the same name, and a replug brings 0x0066 back:
    /// both are the same camera. Any other model is kept whole.
    static func modelFamily(_ model: String) -> String {
        guard let range = model.range(of: #"\s*ProductID_[0-9A-Fa-fx]+\s*$"#, options: .regularExpression),
              range.lowerBound > model.startIndex else { return model }
        return String(model[..<range.lowerBound])
    }

    /// The maker and product part of a USB audio uid: "AppleUSBAudioEngine:Elgato:Cam Link 4K" for
    /// "AppleUSBAudioEngine:Elgato:Cam Link 4K:0004530C6F000:2". Nil for any other uid.
    static func usbAudioProduct(_ uid: String) -> String? {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "AppleUSBAudioEngine" else { return nil }
        return parts[0...2].joined(separator: ":")
    }

    private static func trimmed(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces) }

    /// The short note after a rematch, e.g. "Cam Link 4K moved to a new USB port; reconnected."
    static func movedNotice(_ device: SavedDevice, role: Role) -> String {
        "\(role.label(device.name)) moved to a new USB port; reconnected."
    }

    /// The note when several devices have the saved name.
    static func ambiguousNotice(_ saved: SavedDevice, count: Int, role: Role) -> String {
        let picker = switch role {
        case .camera: "Camera > Device"
        case .cameraAudio: "Camera > Audio"
        case .screenMic: "Screen > Mic"
        }
        return "\(role.label(saved.name)) is not connected, and \(count) devices have that name. Pick one under \(picker)."
    }
}
