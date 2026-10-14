import Foundation
import IOKit
import RecorderCore

/// A camera's USB connection, read from the IORegistry (`IOUSBHostDevice`). Plain data.
///
/// Why: after an HDMI change the Cam Link 4K once came back on the USB 2 lane of its port
/// (product id 0x0067 at 480 Mb/s instead of 0x0066 at 5 Gb/s). It still offered 3840x2160 but
/// sent empty frames. A replug fixed it.
public struct USBLinkInfo: Sendable, Hashable {
    public var vendorID: Int
    public var productID: Int
    public var locationID: UInt32
    public var productName: String?
    public var serialNumber: String?
    /// IORegistry "UsbLinkSpeed", in bits per second (5_000_000_000 for USB 3 at 5 Gb/s).
    public var linkSpeedBps: UInt64?
    /// IORegistry "USBSpeed": 1 full (12 Mb/s), 2 low, 3 high (USB 2, 480 Mb/s), 4 super (5 Gb/s),
    /// 5 super+ (10 Gb/s), 6 super+ 2x2 (20 Gb/s).
    public var speedCode: Int?

    public init(vendorID: Int, productID: Int, locationID: UInt32, productName: String? = nil, serialNumber: String? = nil,
                linkSpeedBps: UInt64? = nil, speedCode: Int? = nil) {
        self.vendorID = vendorID; self.productID = productID; self.locationID = locationID
        self.productName = productName; self.serialNumber = serialNumber
        self.linkSpeedBps = linkSpeedBps; self.speedCode = speedCode
    }

    /// The link speed in bits per second: "UsbLinkSpeed", else from the speed code.
    public var bitsPerSecond: UInt64? {
        if let linkSpeedBps, linkSpeedBps > 0 { return linkSpeedBps }
        return speedCode.flatMap(Self.bitsPerSecond(speedCode:))
    }

    /// True at 5 Gb/s or more (USB 3).
    public var isSuperSpeed: Bool { (bitsPerSecond ?? 0) >= CameraUSB.superSpeedBps }

    /// "3", "2" or "1", nil when the speed is unknown.
    public var usbGeneration: String? {
        guard let bps = bitsPerSecond else { return nil }
        if bps >= CameraUSB.superSpeedBps { return "3" }
        return bps >= 480_000_000 ? "2" : "1"
    }

    /// "USB 3 · 5 Gb/s", "USB 2 · 480 Mb/s".
    public var label: String {
        guard let bps = bitsPerSecond, let generation = usbGeneration else { return "USB, speed unknown" }
        let speed = bps >= 1_000_000_000 ? "\(Self.trim(Double(bps) / 1e9)) Gb/s" : "\(Self.trim(Double(bps) / 1e6)) Mb/s"
        return "USB \(generation) · \(speed)"
    }

    /// events.jsonl data (`usb_link`).
    public var eventData: [String: String] {
        var data = ["vendor_id": String(format: "0x%04x", vendorID), "product_id": String(format: "0x%04x", productID),
                    "location_id": String(format: "0x%08x", locationID), "label": label]
        data["speed_mbps"] = bitsPerSecond.map { String($0 / 1_000_000) }
        data["usb"] = usbGeneration
        data["speed_code"] = speedCode.map(String.init)
        data["product"] = productName
        return data
    }

    static func bitsPerSecond(speedCode: Int) -> UInt64? {
        switch speedCode {
        case 1: 12_000_000
        case 2: 1_500_000
        case 3: 480_000_000
        case 4: 5_000_000_000
        case 5: 10_000_000_000
        case 6: 20_000_000_000
        default: nil
        }
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Finds a camera's USB link in the IORegistry and says when it is too slow for its signal.
public enum CameraUSB {
    public static let elgatoVendorID = 0x0fd9
    public static let superSpeedBps: UInt64 = 5_000_000_000

    /// The USB address in a UVC camera's `AVCaptureDevice.uniqueID`.
    public struct Identity: Sendable, Hashable {
        public var locationID: UInt32
        public var vendorID: Int
        public var productID: Int
    }

    /// "0x22000000fd90066" (the Cam Link 4K) is location 0x02200000, vendor 0x0fd9, product
    /// 0x0066: the location id, then four hex digits each of vendor and product. Nil for any
    /// other shape (a built-in camera's uid is a UUID).
    public static func identity(fromUniqueID uid: String) -> Identity? {
        guard uid.hasPrefix("0x") || uid.hasPrefix("0X") else { return nil }
        let hex = uid.dropFirst(2)
        guard hex.count >= 9, hex.count <= 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        let ids = hex.suffix(8)
        guard let vendor = Int(ids.prefix(4), radix: 16), let product = Int(ids.suffix(4), radix: 16),
              let location = UInt64(hex.dropLast(8), radix: 16), location <= UInt64(UInt32.max) else { return nil }
        return Identity(locationID: UInt32(location), vendorID: vendor, productID: product)
    }

    /// The link of the camera with `uid` (and `name`, its `localizedName`), read from the
    /// IORegistry now. Nil when it is not a USB device or not found. Not on the main thread
    /// (it walks the registry): the app reads it in `DeviceInventory`.
    public static func link(forUniqueID uid: String, name: String?) -> USBLinkInfo? {
        CaptureThread.assertOffMain("Reading the USB registry")
        return match(identity: identity(fromUniqueID: uid), name: name, in: registryDevices())
    }

    /// The device that is the camera: the same location, vendor and product; else the same
    /// location and vendor; else the one device of the vendor with the camera's name.
    static func match(identity: Identity?, name: String?, in devices: [USBLinkInfo]) -> USBLinkInfo? {
        if let identity {
            if let exact = devices.first(where: {
                $0.locationID == identity.locationID && $0.vendorID == identity.vendorID && $0.productID == identity.productID
            }) { return exact }
            let sameSpot = devices.filter { $0.locationID == identity.locationID && $0.vendorID == identity.vendorID }
            if sameSpot.count == 1 { return sameSpot[0] }
        }
        guard let name, !name.isEmpty else { return nil }
        let vendor = identity?.vendorID
        let named = devices.filter { device in
            (vendor.map { $0 == device.vendorID } ?? true) && device.productName.map { $0 == name } == true
        }
        return named.count == 1 ? named[0] : nil
    }

    /// The problem when a capture card runs its signal over a link slower than 5 Gb/s, e.g.
    /// "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3."
    ///
    /// An Elgato device (the Cam Link 4K) sends uncompressed video: 1080p at 23.976 is about
    /// 600 Mb/s, more than USB 2 carries, so any signal is flagged. Another capture card on USB 2
    /// may compress (MJPEG) up to 1080p, so only its 4K signal is flagged.
    public static func slowLinkProblem(link: USBLinkInfo?, signal: CameraSignal?, cameraName: String) -> String? {
        guard let link, let bps = link.bitsPerSecond, bps < superSpeedBps, let signal,
              link.vendorID == elgatoVendorID || CameraMessages.isCaptureCard(cameraName),
              signal.is4K || link.vendorID == elgatoVendorID else { return nil }
        return slowLinkMessage(cameraName: cameraName, link: link, signal: signal)
    }

    static func slowLinkMessage(cameraName: String, link: USBLinkInfo, signal: CameraSignal) -> String {
        let camLink = cameraName.localizedCaseInsensitiveContains("Cam Link")
            || (link.productName?.localizedCaseInsensitiveContains("Cam Link") ?? false)
        let name = camLink ? "Cam Link" : cameraName
        let speed = link.usbGeneration == "1" ? "USB 1" : "USB 2"
        return "\(name) is connected at \(speed) speed. Unplug it and plug it back in — \(signal.sizeName) needs USB 3."
    }

    /// Every USB device in the IORegistry, with its speed.
    static func registryDevices() -> [USBLinkInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [USBLinkInfo] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let device = read(service) { devices.append(device) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }

    private static func read(_ service: io_service_t) -> USBLinkInfo? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func number(_ key: String) -> NSNumber? { property(key) as? NSNumber }
        func string(_ key: String) -> String? { property(key) as? String }
        guard let vendor = number("idVendor"), let product = number("idProduct"), let location = number("locationID") else {
            return nil
        }
        // "USBSpeed" uses the IOUSBHost codes; the older "Device Speed" counts from 0 (low).
        var code = number("USBSpeed")?.intValue
        if code == nil, let legacy = number("Device Speed")?.intValue {
            code = [0: 2, 1: 1, 2: 3, 3: 4, 4: 5, 5: 6][legacy]
        }
        return USBLinkInfo(vendorID: vendor.intValue, productID: product.intValue, locationID: location.uint32Value,
                           productName: string("USB Product Name") ?? string("kUSBProductString"),
                           serialNumber: string("USB Serial Number") ?? string("kUSBSerialNumberString"),
                           linkSpeedBps: number("UsbLinkSpeed")?.uint64Value, speedCode: code)
    }
}
