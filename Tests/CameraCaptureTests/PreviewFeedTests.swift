import AVFoundation
import Testing
@testable import CameraCapture
import RecorderCore

/// A synthetic frame like the preview data output delivers, with the camera's BT.709 color tags.
/// No camera involved.
private func frame(width: Int = 640, height: Int = 360,
                   pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    #expect(CVPixelBufferCreate(nil, width, height, pixelFormat, attributes, &pixelBuffer) == kCVReturnSuccess)
    let image = try #require(pixelBuffer)
    for tag in CameraPreviewFeed.bt709Tags { CVBufferSetAttachment(image, tag.key, tag.value, .shouldPropagate) }
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1001, timescale: 24000),
                                    presentationTimeStamp: HostClock.now(), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try #require(format),
                                                     sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

private func displaysImmediately(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
          let first = attachments.first else { return false }
    return (first[kCMSampleAttachmentKey_DisplayImmediately] as? Bool) == true
}

@Suite struct PreviewSizeTests {
    @Test func fourKAndHDBecome640x360() {
        #expect(PreviewSize.fit(width: 3840, height: 2160) == (640, 360))
        #expect(PreviewSize.fit(width: 1920, height: 1080) == (640, 360))
        #expect(PreviewSize.fit(width: 1280, height: 720) == (640, 360))
    }

    @Test func otherShapesKeepTheirAspectRatio() {
        #expect(PreviewSize.fit(width: 640, height: 480) == (480, 360))
        #expect(PreviewSize.fit(width: 4096, height: 2160) == (640, 338))
        #expect(PreviewSize.fit(width: 1080, height: 1920) == (202, 360))
    }

    @Test func neverLargerThanTheSourceAndEvenSides() {
        #expect(PreviewSize.fit(width: 320, height: 180) == (320, 180))
        let odd = PreviewSize.fit(width: 1366, height: 768)
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
        #expect(odd.width <= 640 && odd.height <= 360)
        #expect(PreviewSize.fit(width: 0, height: 0) == (640, 360))
    }

    @Test func settingsAsk420vOnlyWhenOffered() {
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let with = PreviewSize.videoSettings(width: 640, height: 360, availablePixelFormats: [kCVPixelFormatType_32BGRA, yuv])
        #expect(with[kCVPixelBufferWidthKey as String] as? Int == 640)
        #expect(with[kCVPixelBufferHeightKey as String] as? Int == 360)
        #expect(with[kCVPixelBufferPixelFormatTypeKey as String] as? OSType == yuv)
        let without = PreviewSize.videoSettings(width: 640, height: 360, availablePixelFormats: [kCVPixelFormatType_32BGRA])
        #expect(without[kCVPixelBufferPixelFormatTypeKey as String] == nil)
    }
}

@Suite struct PreviewFeedTests {
    @Test func countsFramesWithoutAView() throws {
        let feed = CameraPreviewFeed()
        #expect(feed.stats() == CameraPreviewFeed.Stats())
        let before = HostClock.nowNs()
        feed.enqueue(try frame())
        feed.enqueue(try frame())
        let stats = feed.stats()
        #expect(stats.frames == 2)
        #expect(stats.width == 640 && stats.height == 360)
        #expect(stats.pixelFormat == "420v")
        #expect((stats.lastFrameHostNs ?? 0) >= before)
        feed.resetStats()
        #expect(feed.stats().frames == 0)
        #expect(feed.stats().lastFrameHostNs == nil)
    }

    @Test func liveFramesAreMarkedToShowAtOnce() throws {
        let sample = try frame()
        #expect(!displaysImmediately(sample))
        CameraPreviewFeed.markDisplayImmediately(sample)
        #expect(displaysImmediately(sample))
    }

    /// The real display layer path, with a synthetic frame: the view's renderer accepts frames
    /// enqueued on the feed's background queue, and detaching stops delivery.
    @MainActor @Test func displayLayerRendererAcceptsFramesFromTheFeedQueue() async throws {
        let feed = CameraPreviewFeed()
        let view = CameraPreviewNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.show(feed, videoGravity: .resizeAspect, mirrored: false)
        let sample = CaptureBox(try frame())
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            feed.queue.async {
                feed.enqueue(sample.value)
                cont.resume()
            }
        }
        #expect(displaysImmediately(sample.value))
        #expect(feed.stats().frames == 1)

        view.stopShowing()
        let unshown = try frame()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let box = CaptureBox(unshown)
            feed.queue.async {
                feed.enqueue(box.value)
                cont.resume()
            }
        }
        // Counted, but not handed to a renderer, so it was never marked for display.
        #expect(feed.stats().frames == 2)
        #expect(!displaysImmediately(unshown))
        feed.clear()
    }
}

/// The menu's preview and the camera window show the same feed at once.
@Suite struct PreviewFeedManyViewsTests {
    /// Enqueues one synthetic frame on the feed's own queue and waits for it.
    func deliver(_ feed: CameraPreviewFeed) async throws -> CMSampleBuffer {
        let sample = CaptureBox(try frame())
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            feed.queue.async {
                feed.enqueue(sample.value)
                cont.resume()
            }
        }
        return sample.value
    }

    @MainActor @Test func twoViewsShowOneFeed() async throws {
        let feed = CameraPreviewFeed()
        let menu = CameraPreviewNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = CameraPreviewNSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        menu.show(feed, videoGravity: .resizeAspect, mirrored: false)
        window.show(feed, videoGravity: .resizeAspect, mirrored: true)
        #expect(feed.attachedViewCount == 2)
        // Showing the same feed again does not add the view twice.
        window.show(feed, videoGravity: .resizeAspect, mirrored: true)
        #expect(feed.attachedViewCount == 2)

        #expect(displaysImmediately(try await deliver(feed)))

        // The menu closes: the window keeps its frames.
        menu.stopShowing()
        #expect(feed.attachedViewCount == 1)
        #expect(displaysImmediately(try await deliver(feed)))

        window.stopShowing()
        #expect(feed.attachedViewCount == 0)
        #expect(!displaysImmediately(try await deliver(feed)))
        #expect(feed.stats().frames == 3)
        feed.clear()
    }

    /// A view that goes away without detaching (SwiftUI dropped it) leaves the feed by itself.
    @MainActor @Test func aViewThatGoesAwayLeavesTheFeed() async throws {
        let feed = CameraPreviewFeed()
        autoreleasepool {
            let view = CameraPreviewNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
            view.show(feed, videoGravity: .resizeAspect, mirrored: false)
            #expect(feed.attachedViewCount == 1)
        }
        #expect(feed.attachedViewCount == 0)
        #expect(!displaysImmediately(try await deliver(feed)))
    }
}

@Suite struct DeviceInventoryTests {
    let camLink = CaptureDeviceInfo(uid: "camlink", name: "Cam Link 4K", kind: .video, isBuiltIn: false, detail: "3840x2160 23.976")
    let iPhone = CaptureDeviceInfo(uid: "iphone", name: "Luke's iPhone Camera", kind: .video, isBuiltIn: false)
    let facetime = CaptureDeviceInfo(uid: "facetime", name: "MacBook Pro Camera", kind: .video, isBuiltIn: true)
    let camLinkAudio = CaptureDeviceInfo(uid: "camlink-audio", name: "Cam Link 4K", kind: .audio, isBuiltIn: false)
    let mic = CaptureDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", kind: .audio, isBuiltIn: true)

    @Test func picksTheCaptureCardAndItsAudio() {
        let inventory = DeviceInventory(videoDevices: [facetime, iPhone, camLink], audioDevices: [mic, camLinkAudio])
        #expect(inventory.defaultCameraUID == "camlink")
        #expect(inventory.defaultCameraAudioUID(forCameraUID: "camlink") == "camlink-audio")
        #expect(inventory.defaultCameraAudioUID(forCameraUID: "gone") == nil)
        #expect(inventory.defaultScreenMicUID == "BuiltInMicrophoneDevice")
    }

    @Test func continuityCameraComesAfterRealExternalCameras() {
        let webcam = CaptureDeviceInfo(uid: "webcam", name: "USB Webcam", kind: .video, isBuiltIn: false)
        let inventory = DeviceInventory(videoDevices: [iPhone, webcam], continuityCameraUIDs: ["iphone"])
        #expect(inventory.defaultCameraUID == "webcam")
        #expect(DeviceInventory(videoDevices: [iPhone], continuityCameraUIDs: ["iphone"]).defaultCameraUID == "iphone")
    }

    @Test func linkedAudioWins() {
        let other = CaptureDeviceInfo(uid: "hdmi-audio", name: "HDMI In", kind: .audio, isBuiltIn: false)
        let inventory = DeviceInventory(videoDevices: [camLink], audioDevices: [camLinkAudio, other],
                                        linkedAudio: ["camlink": ["hdmi-audio"]])
        #expect(inventory.defaultCameraAudioUID(forCameraUID: "camlink") == "hdmi-audio")
    }

    @Test func signalSignatureFollowsTheFormatList() {
        let at1080 = DeviceInventory(videoDevices: [camLink], videoFormats: ["camlink": ["1920x1080 420v 23.976", "1920x1080 yuvs 23.976"]])
        let reordered = DeviceInventory(videoDevices: [camLink], videoFormats: ["camlink": ["1920x1080 yuvs 23.976", "1920x1080 420v 23.976"]])
        let at4K = DeviceInventory(videoDevices: [camLink], videoFormats: ["camlink": ["3840x2160 420v 23.976"]])
        let noSignal = DeviceInventory(videoDevices: [camLink], videoFormats: ["camlink": []])
        #expect(at1080.signalSignature(forVideoUID: "camlink") == reordered.signalSignature(forVideoUID: "camlink"))
        #expect(at1080.signalSignature(forVideoUID: "camlink") != at4K.signalSignature(forVideoUID: "camlink"))
        #expect(noSignal.signalSignature(forVideoUID: "camlink") == "")
        #expect(DeviceInventory().signalSignature(forVideoUID: "camlink") == nil)
        #expect(at4K.isConnected(videoUID: "camlink"))
        #expect(!at4K.isConnected(videoUID: "facetime"))
    }
}
