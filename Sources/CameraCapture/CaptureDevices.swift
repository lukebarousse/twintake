// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreAudio
import RecorderCore

/// Every camera and microphone the app can record from, for the UI pickers.
///
/// Listing devices does not open them, so it never shows a permission prompt. Select devices by
/// `uid` (`AVCaptureDevice.uniqueID`); never use the system default input.
///
/// Thread rule (CaptureThreads.swift): device reads never run on the main thread. The app calls
/// `loadInventory()`, which reads everything on `queue`, and works with the plain-data result.
public enum CaptureDevices {
    /// Serial queue for device lists and device KVO.
    static let queue = DispatchQueue(label: "TwinTake.camera.devices", qos: .userInitiated)

    /// Every camera and audio input with its formats, read on the device queue.
    public static func loadInventory() async -> DeviceInventory {
        await withCheckedContinuation { (cont: CheckedContinuation<DeviceInventory, Never>) in
            queue.async { cont.resume(returning: inventory()) }
        }
    }

    /// Reads every camera and audio input now. Not on the main thread: use `loadInventory()`.
    public static func inventory() -> DeviceInventory {
        CaptureThread.assertOffMain("Reading capture devices")
        var result = DeviceInventory()
        for device in videoCaptureDevices() {
            let candidates = videoCandidates(of: device)
            result.videoDevices.append(info(forVideo: device, candidates: candidates))
            result.videoFormats[device.uniqueID] = listing(candidates)
            result.signals[device.uniqueID] = CameraSignal.resolve(candidates)?.signal
            result.linkedAudio[device.uniqueID] = device.linkedDevices.filter { $0.hasMediaType(.audio) }.map(\.uniqueID)
            if device.isContinuityCamera { result.continuityCameraUIDs.insert(device.uniqueID) }
            if device.deviceType == .external, let link = CameraUSB.link(forUniqueID: device.uniqueID, name: device.localizedName) {
                result.usbLinks[device.uniqueID] = link
            }
        }
        result.audioDevices = audioCaptureDevices().map(info(forAudio:))
        return result
    }

    /// External cameras (capture cards, USB webcams) and built-in cameras. `detail` is the best
    /// format the camera offers now, e.g. "1920x1080 23.976". A capture card offers only the
    /// format of its incoming HDMI signal. Not on the main thread.
    public static func videoDevices() -> [CaptureDeviceInfo] { inventory().videoDevices }

    /// Microphones and other audio inputs, external ones included (a capture card's HDMI audio,
    /// USB interfaces). `detail` is the input format, e.g. "2 ch, 48 kHz". Not on the main thread.
    public static func audioDevices() -> [CaptureDeviceInfo] {
        CaptureThread.assertOffMain("Reading audio devices")
        return audioCaptureDevices().map(info(forAudio:))
    }

    /// The capture card: a camera named "Cam Link...", else the first external camera, else nil.
    /// Not on the main thread.
    public static func defaultCameraUID() -> String? { inventory().defaultCameraUID }

    /// The audio input that belongs to the camera. Not on the main thread.
    public static func defaultCameraAudioUID(forCameraUID cameraUID: String) -> String? {
        inventory().defaultCameraAudioUID(forCameraUID: cameraUID)
    }

    /// The Mac's built-in mic for screen.mov track A1. Not on the main thread.
    public static func defaultScreenMicUID() -> String? {
        DeviceDefaults.screenMicUID(in: audioDevices())
    }

    /// Every format a camera offers, one line each: "1920x1080 420v 23.976". Empty when the
    /// camera is not connected. Not on the main thread.
    public static func formats(forVideoUID uid: String) -> [String] {
        CaptureThread.assertOffMain("Reading camera formats")
        guard let device = AVCaptureDevice(uniqueID: uid) else { return [] }
        return listing(videoCandidates(of: device))
    }

    /// Opens the Video Effects menu (Control Center), where the user turns off Reactions,
    /// Portrait, Studio Light and the others. macOS shows it only while the app uses a camera.
    /// A request to the system UI: it opens no device and touches no session.
    public static func showVideoEffectsControls() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    /// Opens the Mic Mode menu (Control Center).
    public static func showMicrophoneModeControls() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// Calls `onChange` when a camera or audio input is connected or disconnected, or a camera's
    /// format list changes (a capture card changes it with its HDMI signal). Calls come on an
    /// arbitrary thread, often several in a row: debounce them. Keep the returned observer alive
    /// for as long as you need updates.
    public static func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> DeviceChangeObserver {
        let observer = DeviceChangeObserver(onChange: onChange)
        observer.start()
        return observer
    }

    // MARK: - AVFoundation

    static func videoCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func audioCaptureDevices() -> [AVCaptureDevice] {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified).devices
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uniqueID).inserted }
    }

    static func info(forVideo device: AVCaptureDevice, candidates: [VideoFormatCandidate]) -> CaptureDeviceInfo {
        let detail = FormatMatcher.bestAvailable(in: candidates).map { FormatLabel.signal(candidates[$0]) }
        return CaptureDeviceInfo(uid: device.uniqueID, name: device.localizedName, kind: .video,
                                 isBuiltIn: device.deviceType == .builtInWideAngleCamera, detail: detail,
                                 modelID: device.modelID.isEmpty ? nil : device.modelID)
    }

    static func info(forAudio device: AVCaptureDevice) -> CaptureDeviceInfo {
        let detail = audioFormat(of: device).map { FormatLabel.audio(sampleRate: $0.sampleRate, channels: $0.channels) }
        return CaptureDeviceInfo(uid: device.uniqueID, name: device.localizedName, kind: .audio,
                                 isBuiltIn: isBuiltInTransport(device), detail: detail)
    }

    static func isBuiltInTransport(_ device: AVCaptureDevice) -> Bool {
        UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeBuiltIn
    }

    static func videoCandidates(of device: AVCaptureDevice) -> [VideoFormatCandidate] {
        device.formats.compactMap(candidate)
    }

    /// One line per distinct format, in device order.
    static func listing(_ candidates: [VideoFormatCandidate]) -> [String] {
        var seen = Set<String>()
        return candidates.map(FormatLabel.listing).filter { seen.insert($0).inserted }
    }

    static func candidate(_ format: AVCaptureDevice.Format) -> VideoFormatCandidate? {
        let desc = format.formatDescription
        guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let spans = format.videoSupportedFrameRateRanges.map {
            FrameRateSpan(minFps: $0.minFrameRate, maxFps: $0.maxFrameRate,
                          minFrameDuration: $0.minFrameDuration, maxFrameDuration: $0.maxFrameDuration)
        }
        return VideoFormatCandidate(width: Int(dims.width), height: Int(dims.height),
                                    pixelFormat: FormatLabel.fourCC(CMFormatDescriptionGetMediaSubType(desc)),
                                    frameRates: spans)
    }

    /// Sample rate and channel count of an audio input's active format.
    static func audioFormat(of device: AVCaptureDevice) -> (sampleRate: Double, channels: Int)? {
        // activeFormat is declared nonnull but a device with no formats can return nil.
        guard !device.formats.isEmpty,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee,
              asbd.mChannelsPerFrame > 0 else { return nil }
        return (asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
    }
}

/// The cameras and audio inputs at one moment, read on the device queue. Plain data, so the app
/// can use it on the main thread and the default-pick rules can be tested without devices.
public struct DeviceInventory: Sendable, Equatable {
    public var videoDevices: [CaptureDeviceInfo]
    public var audioDevices: [CaptureDeviceInfo]
    /// Every format each camera offers, one line each ("1920x1080 420v 23.976"), by uid.
    public var videoFormats: [String: [String]]
    /// The audio inputs macOS links to each camera, by camera uid.
    public var linkedAudio: [String: [String]]
    /// iPhones (Continuity Camera). They count as external but come after real external cameras.
    public var continuityCameraUIDs: Set<String>
    /// What each camera sends now, as a recorder that follows the signal records it, by uid.
    /// Missing for a camera that offers no format (a capture card with no HDMI signal).
    public var signals: [String: CameraSignal]
    /// Each USB camera's link (speed), from the IORegistry, by uid.
    public var usbLinks: [String: USBLinkInfo]

    public init(videoDevices: [CaptureDeviceInfo] = [], audioDevices: [CaptureDeviceInfo] = [],
                videoFormats: [String: [String]] = [:], linkedAudio: [String: [String]] = [:],
                continuityCameraUIDs: Set<String> = [], signals: [String: CameraSignal] = [:],
                usbLinks: [String: USBLinkInfo] = [:]) {
        self.videoDevices = videoDevices; self.audioDevices = audioDevices; self.videoFormats = videoFormats
        self.linkedAudio = linkedAudio; self.continuityCameraUIDs = continuityCameraUIDs; self.signals = signals
        self.usbLinks = usbLinks
    }

    /// A USB camera's link, e.g. "USB 3 · 5 Gb/s". Nil for a camera that is not on USB.
    public func usbLink(forVideoUID uid: String) -> USBLinkInfo? { usbLinks[uid] }

    /// "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3."
    /// when a capture card with a 4K signal is on a link slower than 5 Gb/s; else nil.
    public func usbProblem(forVideoUID uid: String) -> String? {
        guard let camera = videoDevices.first(where: { $0.uid == uid }) else { return nil }
        return CameraUSB.slowLinkProblem(link: usbLinks[uid], signal: signals[uid], cameraName: camera.name)
    }

    /// What the camera sends now, e.g. 3840x2160 at 24000/1001 ("3840x2160 · 23.976 fps", is4K):
    /// what camera.mov records when the config follows the signal. Nil when the camera is not
    /// connected or offers no format. The screen rate to go with it is `screenFrameRate`.
    public func signal(forVideoUID uid: String) -> CameraSignal? { signals[uid] }

    /// The capture card: a camera named "Cam Link...", else the first external camera, else nil.
    public var defaultCameraUID: String? {
        let ordered = videoDevices.filter { !continuityCameraUIDs.contains($0.uid) }
            + videoDevices.filter { continuityCameraUIDs.contains($0.uid) }
        return DeviceDefaults.cameraUID(in: ordered)
    }

    /// The audio input that belongs to the camera, e.g. "Cam Link 4K" audio for the "Cam Link 4K"
    /// camera (the camera mic over HDMI). Nil when the camera has no matching audio input.
    public func defaultCameraAudioUID(forCameraUID cameraUID: String) -> String? {
        guard let camera = videoDevices.first(where: { $0.uid == cameraUID }) else { return nil }
        return DeviceDefaults.cameraAudioUID(cameraName: camera.name, linkedAudioUIDs: linkedAudio[cameraUID] ?? [],
                                             in: audioDevices)
    }

    /// The Mac's built-in mic ("MacBook Pro Microphone") for screen.mov track A1.
    public var defaultScreenMicUID: String? { DeviceDefaults.screenMicUID(in: audioDevices) }

    public func isConnected(videoUID uid: String) -> Bool { videoDevices.contains { $0.uid == uid } }

    /// What a camera offers now, as one string that changes when its signal changes (a capture
    /// card lists only the format of its HDMI input). Nil when the camera is not connected.
    public func signalSignature(forVideoUID uid: String) -> String? {
        guard isConnected(videoUID: uid) else { return nil }
        return (videoFormats[uid] ?? []).sorted().joined(separator: "; ")
    }
}

extension CaptureDeviceInfo {
    /// True for an HDMI capture card (Cam Link, Elgato, "HDMI"/"Capture" in the name): its formats
    /// mirror the incoming signal, so a wrong size is fixed on the camera, not in the app.
    public var isCaptureCard: Bool { kind == .video && CameraMessages.isCaptureCard(name) }
}

/// Keeps device notifications coming: connect, disconnect, and every camera's format list (KVO,
/// registered and removed on the device queue). Stops when cancelled or released.
public final class DeviceChangeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let onChange: @Sendable () -> Void
    private var tokens: [NSObjectProtocol] = []
    private var formatObservations: [NSKeyValueObservation] = []
    private var cancelled = false

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    deinit { cancel() }

    func start() {
        let center = NotificationCenter.default
        // The handlers may run on the main thread: they only call onChange and hop to the device queue.
        let tokens = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map {
            center.addObserver(forName: $0, object: nil, queue: nil) { [weak self] _ in
                self?.onChange()
                self?.watchFormats()
            }
        }
        lock.withLock { self.tokens = tokens }
        watchFormats()
    }

    public func cancel() {
        let (removed, observations) = lock.withLock { () -> ([NSObjectProtocol], [NSKeyValueObservation]) in
            defer { tokens = []; formatObservations = []; cancelled = true }
            return (tokens, formatObservations)
        }
        removed.forEach(NotificationCenter.default.removeObserver)
        let box = CaptureBox(observations)
        CaptureDevices.queue.async { box.value.forEach { $0.invalidate() } }
    }

    /// Observes the format list of every camera connected now. Runs on the device queue.
    private func watchFormats() {
        CaptureDevices.queue.async { [weak self] in
            guard let self else { return }
            let onChange = self.onChange
            let fresh = CaptureDevices.videoCaptureDevices().map {
                $0.observe(\.formats, options: [.new]) { _, _ in onChange() }
            }
            let stale = self.lock.withLock { () -> [NSKeyValueObservation] in
                if self.cancelled { return fresh }
                defer { self.formatObservations = fresh }
                return self.formatObservations
            }
            stale.forEach { $0.invalidate() }
        }
    }
}
