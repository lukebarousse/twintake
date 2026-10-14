import AVFoundation
import Synchronization
import Testing
@testable import CameraCapture
import MediaWriter
import RecorderCore

/// A 420v frame: `luma` and `chroma` fill the planes, or `noise` gives every byte its own value.
private func pixels(width: Int = 64, height: Int = 36, luma: UInt8 = 0, chroma: UInt8 = 0, noise: Bool = false,
                    format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    func fill(_ base: UnsafeMutableRawPointer, size: Int, value: UInt8, step: Int) {
        guard noise else {
            memset(base, Int32(value), size)
            return
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: i &* step &+ 17) }
    }
    if CVPixelBufferIsPlanar(buffer) {
        for (plane, value) in [(0, luma), (1, chroma)] {
            fill(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!,
                 size: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane),
                 value: value, step: 31)
        }
    } else {
        fill(CVPixelBufferGetBaseAddress(buffer)!, size: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer),
             value: luma, step: 7)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

@Suite struct USBLinkTests {
    @Test func theCamLinkUniqueIDHoldsItsUSBAddress() throws {
        let id = try #require(CameraUSB.identity(fromUniqueID: "0x22000000fd90066"))
        #expect(id.locationID == 0x0220_0000 && id.vendorID == 0x0fd9 && id.productID == 0x0066)
        // The USB 2 lane: another product id.
        #expect(CameraUSB.identity(fromUniqueID: "0x1100000fd90067")?.productID == 0x0067)
        #expect(CameraUSB.identity(fromUniqueID: "6C707041-05AC-0010-0006-000000000001") == nil)
        #expect(CameraUSB.identity(fromUniqueID: "0x0fd9006") == nil)
        #expect(CameraUSB.identity(fromUniqueID: "0xZZ000000fd90066") == nil)
    }

    @Test func linkLabels() {
        let usb3 = USBLinkInfo(vendorID: 0x0fd9, productID: 0x66, locationID: 0x0220_0000, linkSpeedBps: 5_000_000_000, speedCode: 4)
        #expect(usb3.label == "USB 3 · 5 Gb/s" && usb3.isSuperSpeed && usb3.usbGeneration == "3")
        let usb2 = USBLinkInfo(vendorID: 0x0fd9, productID: 0x67, locationID: 0x0110_0000, speedCode: 3)
        #expect(usb2.label == "USB 2 · 480 Mb/s" && !usb2.isSuperSpeed && usb2.bitsPerSecond == 480_000_000)
        #expect(usb2.eventData["speed_mbps"] == "480" && usb2.eventData["product_id"] == "0x0067"
            && usb2.eventData["vendor_id"] == "0x0fd9" && usb2.eventData["usb"] == "2")
        #expect(USBLinkInfo(vendorID: 1, productID: 2, locationID: 3).label == "USB, speed unknown")
        #expect(USBLinkInfo(vendorID: 1, productID: 2, locationID: 3, linkSpeedBps: 10_000_000_000).label == "USB 3 · 10 Gb/s")
    }

    @Test func theRegistryEntryIsMatchedByAddressThenName() {
        let camLink = USBLinkInfo(vendorID: 0x0fd9, productID: 0x66, locationID: 0x0220_0000, productName: "Cam Link 4K",
                                  linkSpeedBps: 5_000_000_000)
        let prompter = USBLinkInfo(vendorID: 0x17e9, productID: 0xff1a, locationID: 0x2110_0000, productName: "Elgato Prompter")
        let devices = [prompter, camLink]
        let id = CameraUSB.identity(fromUniqueID: "0x22000000fd90066")
        #expect(CameraUSB.match(identity: id, name: "Cam Link 4K", in: devices) == camLink)
        // Same spot, other product id (re-enumerated): still found.
        let moved = CameraUSB.Identity(locationID: 0x0220_0000, vendorID: 0x0fd9, productID: 0x67)
        #expect(CameraUSB.match(identity: moved, name: nil, in: devices) == camLink)
        // No address: the one device of that name.
        #expect(CameraUSB.match(identity: nil, name: "Cam Link 4K", in: devices) == camLink)
        #expect(CameraUSB.match(identity: nil, name: "Cam Link 4K", in: devices + [camLink]) == nil)
        #expect(CameraUSB.match(identity: nil, name: nil, in: devices) == nil)
    }

    /// The USB 2 lane with a 4K signal: the exact message. USB 3, no signal or a webcam: nothing.
    /// The Cam Link sends uncompressed video, too much for USB 2 at 1080p too; another capture
    /// card may compress, so only its 4K signal is flagged.
    @Test func aCaptureCardOnUSB2WithA4KSignalIsFlagged() {
        let usb2 = USBLinkInfo(vendorID: 0x0fd9, productID: 0x67, locationID: 1, productName: "Cam Link 4K",
                               linkSpeedBps: 480_000_000)
        let usb3 = USBLinkInfo(vendorID: 0x0fd9, productID: 0x66, locationID: 1, linkSpeedBps: 5_000_000_000)
        let fourK = CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v")
        let hd = CameraSignal(width: 1920, height: 1080, frameRate: .fps23_976, pixelFormat: "420v")
        #expect(CameraUSB.slowLinkProblem(link: usb2, signal: fourK, cameraName: "Cam Link 4K")
            == "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3.")
        #expect(CameraUSB.slowLinkProblem(link: usb3, signal: fourK, cameraName: "Cam Link 4K") == nil)
        #expect(CameraUSB.slowLinkProblem(link: usb2, signal: hd, cameraName: "Cam Link 4K")
            == "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 1080p needs USB 3.")
        #expect(CameraUSB.slowLinkProblem(link: usb2, signal: nil, cameraName: "Cam Link 4K") == nil)
        let webcam = USBLinkInfo(vendorID: 0x046d, productID: 0x085e, locationID: 1, linkSpeedBps: 480_000_000)
        #expect(CameraUSB.slowLinkProblem(link: webcam, signal: fourK, cameraName: "Logitech BRIO") == nil)
        #expect(CameraUSB.slowLinkProblem(link: webcam, signal: fourK, cameraName: "HDMI Capture")?
            .hasPrefix("HDMI Capture is connected at USB 2 speed.") == true)
        #expect(CameraUSB.slowLinkProblem(link: webcam, signal: hd, cameraName: "HDMI Capture") == nil)
    }

    @Test func theInventoryCarriesTheLink() {
        let camLink = CaptureDeviceInfo(uid: "0x22000000fd90066", name: "Cam Link 4K", kind: .video, isBuiltIn: false)
        let fourK = CameraSignal(width: 3840, height: 2160, frameRate: .fps23_976, pixelFormat: "420v")
        let slow = USBLinkInfo(vendorID: 0x0fd9, productID: 0x67, locationID: 1, speedCode: 3)
        let inventory = DeviceInventory(videoDevices: [camLink], signals: [camLink.uid: fourK], usbLinks: [camLink.uid: slow])
        #expect(inventory.usbLink(forVideoUID: camLink.uid) == slow)
        #expect(inventory.usbProblem(forVideoUID: camLink.uid)?.hasPrefix("Cam Link is connected at USB 2 speed") == true)
        #expect(inventory.usbProblem(forVideoUID: "other") == nil)
    }

    /// Reading the registry opens nothing; on this Mac it lists whatever USB devices are plugged in.
    @Test func theRegistryCanBeRead() {
        let devices = CameraUSB.registryDevices()
        #expect(devices.allSatisfy { $0.vendorID >= 0 })
        // With a Cam Link plugged in, its AVFoundation uid finds it.
        if let camLink = devices.first(where: { $0.vendorID == CameraUSB.elgatoVendorID && $0.productName?.contains("Cam Link") == true }) {
            let uid = String(format: "0x%x%04x%04x", camLink.locationID, camLink.vendorID, camLink.productID)
            print("Cam Link in the registry: \(uid) \(camLink.label)")
            #expect(CameraUSB.link(forUniqueID: uid, name: camLink.productName) == camLink)
            #expect(camLink.bitsPerSecond != nil)
        }
        #expect(CameraUSB.link(forUniqueID: "0x7700000ffff0001", name: "No Such Camera") == nil)
    }
}

@Suite struct EmptyFrameTests {
    @Test func allZero420vIsTheGreenFrame() throws {
        let zero = try #require(PixelSampler.sample(pixels()))
        #expect(zero.allZero && zero.uniform && zero.pattern == .zero)
        // Black in video range: flat, not zero.
        let black = try #require(PixelSampler.sample(pixels(luma: 16, chroma: 128)))
        #expect(!black.allZero && black.uniform && black.pattern == .constant)
        let picture = try #require(PixelSampler.sample(pixels(noise: true)))
        #expect(!picture.allZero && !picture.uniform && picture.pattern == nil)
        // A 4K frame is sampled the same way.
        #expect(PixelSampler.sample(pixels(width: 3840, height: 2160))?.pattern == .zero)
        // A packed format.
        #expect(PixelSampler.sample(pixels(luma: 0, format: kCVPixelFormatType_32BGRA))?.pattern == .zero)
        #expect(PixelSampler.sample(pixels(noise: true, format: kCVPixelFormatType_32BGRA))?.pattern == nil)
    }

    @Test func aRunOfEmptyFramesIsAnEpisode() {
        var detector = EmptyFrameDetector()
        let zero = FrameSample(allZero: true, uniform: true), flat = FrameSample(allZero: false, uniform: true)
        let picture = FrameSample(allZero: false, uniform: false)
        for _ in 1..<EmptyFrameDetector.framesToFlag { #expect(detector.add(zero) == nil) }
        #expect(detector.add(zero) == .began(.zero))
        #expect(detector.add(zero) == nil && detector.episode == .zero)
        // Two pictures do not end it, the third does.
        #expect(detector.add(picture) == nil && detector.add(picture) == nil)
        #expect(detector.add(picture) == .ended(frames: 13))
        #expect(detector.episode == nil && detector.sawPicture)
        // A run that mixes zero and flat frames is "constant".
        for k in 1..<EmptyFrameDetector.framesToFlag { _ = detector.add(k % 2 == 0 ? zero : flat) }
        #expect(detector.add(zero) == .began(.constant))
        // A picture in the middle of a run starts the count over.
        var other = EmptyFrameDetector()
        for _ in 0..<6 { _ = other.add(zero) }
        _ = other.add(picture)
        for _ in 0..<6 { #expect(other.add(zero) == nil) }
        #expect(other.sawPicture && other.episode == nil)
    }

    @Test func thePictureCheckReportsTheCameraAsAWhole() {
        let check = PictureCheck()
        let changes = Mutex<[PictureCheck.Change]>([])
        check.setHandler { change in changes.withLock { $0.append(change) } }
        check.report(nil, sawPicture: true, from: .preview)
        check.report(.began(.zero), sawPicture: true, from: .preview)
        check.report(.began(.zero), sawPicture: true, from: .recording)  // Already empty: no change.
        check.report(.ended(frames: 40), sawPicture: true, from: .preview)  // The recording one still is.
        #expect(check.status.empty == .zero)
        check.forget(.recording)
        let seen = changes.withLock { $0 }
        #expect(seen.count == 3)
        #expect(seen.map(\.status.empty) == [nil, .zero, nil])
        #expect(seen.first?.status.sawPicture == true)
        #expect(check.status.empty == nil)
    }

    /// The preview pipeline's probe sets the feed's `emptyFrames` and reports to the check, once
    /// the start-up grace is over.
    @Test func theProbeMarksThePreviewFeed() {
        let feed = CameraPreviewFeed()
        let check = PictureCheck()
        let clock = TestClock()
        let probe = FrameProbe(pipeline: .preview, check: check, feed: feed, now: clock.now)
        let green = pixels()
        let picture = pixels(noise: true)
        probe.observe(picture)
        clock.advance(EmptyFrameDetector.openGraceNs)
        for _ in 0..<EmptyFrameDetector.framesToFlag { probe.observe(green) }
        #expect(feed.stats().emptyFrames == .zero && check.status.preview == .zero)
        for _ in 0..<EmptyFrameDetector.framesToClear { probe.observe(picture) }
        #expect(feed.stats().emptyFrames == nil && check.status.empty == nil && check.status.sawPicture)
        feed.noteEmptyFrames(.constant)
        feed.resetStats()
        #expect(feed.stats().emptyFrames == nil)
    }

    /// The Cam Link sends about 12 all-zero frames (0.5 s at 23.976) each time its stream starts.
    /// They fall in the 1 s grace after the first frame, so a preview open is no episode and the
    /// camera does not reopen for them. Empty frames after the grace still are.
    @Test func theStartUpBurstIsNoEpisode() {
        let frame: UInt64 = 41_708_333  // 1001/24000 s.
        let zero = FrameSample(allZero: true, uniform: true), picture = FrameSample(allZero: false, uniform: false)
        var detector = EmptyFrameDetector(graceNs: EmptyFrameDetector.openGraceNs)
        var t: UInt64 = 5_000_000_000
        for _ in 0..<12 {
            #expect(detector.add(zero, atNs: t) == nil)
            t += frame
        }
        for _ in 0..<12 {
            #expect(detector.add(picture, atNs: t) == nil)
            t += frame
        }
        #expect(detector.episode == nil && detector.sawPicture)
        // A burst as long as the episode rule, but inside the grace: still nothing.
        var long = EmptyFrameDetector(graceNs: EmptyFrameDetector.openGraceNs)
        for k in 0..<23 { #expect(long.add(zero, atNs: UInt64(k) * frame) == nil) }
        // After the grace, 12 empty frames in a row are an episode, as before.
        t += EmptyFrameDetector.openGraceNs
        var began: EmptyFrameDetector.Transition?
        for _ in 0..<EmptyFrameDetector.framesToFlag {
            began = detector.add(zero, atNs: t) ?? began
            t += frame
        }
        #expect(began == .began(.zero) && detector.episode == .zero)
    }

    /// The USB 2 lane sends zero frames for good: the episode begins 12 frames after the grace,
    /// about 1.5 s after the stream starts.
    @Test func endlessEmptyFramesBeginAnEpisodeAfterTheGrace() {
        let frame: UInt64 = 41_708_333
        var detector = EmptyFrameDetector(graceNs: EmptyFrameDetector.openGraceNs)
        let zero = FrameSample(allZero: true, uniform: true)
        var beganAt: Int?
        for k in 0..<100 where beganAt == nil {
            if detector.add(zero, atNs: UInt64(k) * frame) != nil { beganAt = k }
        }
        // Frame 24 is the first one past 1 s; the 12th counted one is frame 35 (1.46 s).
        #expect(beganAt == 35)
    }

    /// Each open of a pipeline makes a new probe with its own grace, and a stream that starts over
    /// (the camera's format set again) gives every probe the grace again.
    @Test func eachOpenAndEachRestartGetTheGrace() {
        let check = PictureCheck()
        let clock = TestClock()
        let green = pixels()
        let preview = FrameProbe(pipeline: .preview, check: check, now: clock.now)
        for _ in 0..<12 {
            preview.observe(green)
            clock.advance(41_708_333)
        }
        #expect(check.status.empty == nil)
        clock.advance(EmptyFrameDetector.openGraceNs)
        for _ in 0..<3 { preview.observe(pixels(noise: true)) }
        // The format is set again: the stream starts over with its burst.
        check.streamRestarted()
        for _ in 0..<12 {
            preview.observe(green)
            clock.advance(41_708_333)
        }
        #expect(check.status.empty == nil)
        // A take's recording output joins later: its own grace from its first frame.
        let recording = FrameProbe(pipeline: .recording, check: check, now: clock.now)
        for _ in 0..<12 { recording.observe(green) }
        #expect(check.status.empty == nil)
        // No grace (the old rule): the burst is an episode.
        let strict = FrameProbe(pipeline: .preview, check: PictureCheck(), graceNs: 0, now: clock.now)
        for _ in 0..<12 { strict.observe(green) }
        #expect(strict.check.status.empty == .zero)
    }

    @Test func theMessageNamesTheCamLink() {
        #expect(CameraMessages.emptyFrames(cameraName: "Cam Link 4K") == "No picture: the Cam Link is sending empty frames.")
        #expect(CameraMessages.emptyFrames(cameraName: "HDMI Capture") == "No picture: HDMI Capture is sending empty frames.")
    }
}

@Suite struct ReconnectAndMicCheckTests {
    /// A camera that never fed a preview has nothing to reconnect to; no device is opened.
    @Test func reconnectNeedsAPreviewFeed() async {
        let recorder = CameraRecorder(config: CameraRecorderConfig(videoDeviceUID: "no-such-camera", audioDeviceUID: nil))
        await #expect(throws: CameraRecorderError.notPrepared) { try await recorder.reconnect() }
        // The refused reconnect is over: Start and the preview's close do not wait for it.
        #expect(!recorder.isReconnecting)
        #expect(await recorder.waitForReconnect(atMost: .milliseconds(10)))
        #expect(recorder.emptyFrames == nil && recorder.pictureProblem == nil && recorder.usbLink == nil)
        #expect(recorder.usbProblem == nil)
        #expect(CameraRecorderError.busy(reason: "it is recording.").errorDescription == "The camera cannot reconnect now: it is recording.")
    }

    /// Calibration on the live idle meters: two samples in a row, each a `MicCheck` that samples
    /// the camera mic and the Mac mic from their live meters (the metered preview and the idle Mac
    /// mic) and opens no session. The meters keep publishing between the samples; the second one
    /// (the built-in mic) measures its own voice.
    @Test func twoCalibrationSamplesInARowFromTheLiveMeters() async throws {
        let monitor = AudioLevelMonitor()
        let feeder = LiveMeterFeeder(monitor: monitor)
        let task = Task.detached { await feeder.run() }
        defer { task.cancel() }

        feeder.set(correlation: 0.99)
        try await Task.sleep(for: .milliseconds(200))
        let plugged = MicCheck(cameraAudioUID: "camlink-audio", screenMicUID: "macbook-mic", levels: monitor,
                               live: [.cameraMic, .screenMic])
        let first = await plugged.run(seconds: 1.5)
        #expect(first.liveSources == [.cameraMic, .screenMic] && first.errors == [])
        #expect(first.cameraMicOpened && first.screenMicOpened && !first.cancelled)
        #expect(first.sample.cameraVoicedSeconds >= 0.3 && abs(first.sample.correlation.mean - 0.99) < 0.005)

        // Unplugged: the built-in mic. The live meters never stopped.
        feeder.set(correlation: 0.78)
        try await Task.sleep(for: .milliseconds(200))
        let unplugged = MicCheck(cameraAudioUID: "camlink-audio", screenMicUID: "macbook-mic", levels: monitor,
                                 live: [.cameraMic, .screenMic])
        let second = await unplugged.run(seconds: 1.5)
        #expect(second.errors == [] && second.cameraMicOpened)
        #expect(second.sample.cameraVoicedSeconds >= 0.3, "sample 2: \(second.sample.cameraVoicedSeconds) s of voice")
        #expect(abs(second.sample.correlation.mean - 0.78) < 0.005)
    }

    /// A live source that delivers nothing (its camera closed meanwhile) is reported, not taken
    /// for silence.
    @Test func aLiveSourceThatSendsNothingIsReported() async {
        let check = MicCheck(cameraAudioUID: "camlink-audio", screenMicUID: nil, levels: AudioLevelMonitor(), live: [.cameraMic])
        let result = await check.run(seconds: 0.1)
        #expect(!result.cameraMicOpened && result.errors == ["The camera audio sent nothing during the check."])
        #expect(result.liveSources == [.cameraMic])
    }

    /// The idle Mac mic opens nothing without microphone access or for a mic that is not there,
    /// and a close of a meter that never opened does nothing.
    @Test func theIdleMacMicNeedsAccessAndADevice() async {
        let meter = MacMicMeter(micUID: "no-such-mic", levels: AudioLevelMonitor())
        await #expect(throws: (any Error).self) { try await meter.open() }
        #expect(!meter.isOpen)
        await meter.close()
        #expect(!meter.isOpen)
    }

    /// The idle Mac mic's session notices a stop it did not ask for (the mic unplugged, a runtime
    /// error): the meter then reads closed, and the app opens a new one. Its own close is no stop.
    @Test func aSessionThatStopsByItselfIsNoticed() {
        let session = NSObject(), device = NSObject(), other = NSObject()
        let watch = CaptureStopWatch(session: session, device: device)
        NotificationCenter.default.post(name: AVCaptureSession.didStopRunningNotification, object: other)
        #expect(watch.stopReason == nil)
        NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: device)
        #expect(watch.stopReason == "the device was disconnected")
        NotificationCenter.default.post(name: AVCaptureSession.runtimeErrorNotification, object: session)
        #expect(watch.stopReason == "the device was disconnected")  // The first reason stays.

        let closing = CaptureStopWatch(session: session, device: nil)
        closing.cancel()  // `CheckSession.close()` cancels before it stops the session.
        NotificationCenter.default.post(name: AVCaptureSession.didStopRunningNotification, object: session)
        #expect(closing.stopReason == nil)
        let failing = CaptureStopWatch(session: session, device: nil)
        NotificationCenter.default.post(name: AVCaptureSession.runtimeErrorNotification, object: session)
        #expect(failing.stopReason?.hasPrefix("runtime error") == true)
    }

    /// With no mic set, the check opens nothing and says why.
    @Test func aMicCheckWithoutMicsOpensNothing() async {
        let check = MicCheck(cameraAudioUID: nil, screenMicUID: nil, levels: AudioLevelMonitor())
        let result = await check.run(seconds: 5)
        #expect(!result.cameraMicOpened && !result.screenMicOpened && !result.cancelled)
        #expect(result.errors == ["No mic is set for the check."])
        #expect(!check.isRunning)
        check.cancel()  // Nothing runs: no effect.
    }

    /// The camera mic's levels flow from the recording audio output's pipeline into the monitor.
    @Test func theWriterControllerMetersTheCameraMic() async throws {
        let monitor = AudioLevelMonitor()
        let controller = CameraWriterController(frameRate: .fps23_976, audioChannels: 2, levels: monitor)
        let audio = try #require(controller.audio)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        pcm.frameLength = 2400
        for c in 0..<2 { for i in 0..<2400 { pcm.floatChannelData![c][i] = i % 2 == 0 ? 0.1 : -0.1 } }
        let box = SampleBuffer(buffer: PCMSampleBuffers.makeSampleBuffer(from: pcm, format: format.formatDescription, at: .zero)!)
        await controller.audioQueue.run { audio.receive(box.buffer, ptsNs: 4_000 * AudioBlock.durationNs) }
        let level = try #require(monitor.snapshot().cameraMic)
        #expect(abs(level.rmsDb - (-20)) < 0.01 && level.channels == 2)
        // No audio input: no meter.
        #expect(CameraWriterController(frameRate: .fps23_976, audioChannels: nil, levels: monitor).audio == nil)
    }

    /// session.json: the detector's report goes on camera.mov's mic track, and track_stop names it.
    @Test func theMicTrackCarriesTheMicSource() throws {
        var facts = CameraTrackFacts(videoDevice: DeviceInfo(name: "Cam Link 4K", uid: "camlink"), codec: .hevc,
                                     width: 3840, height: 2160, frameRate: .fps23_976)
        let audio = AudioTrackResult(role: .mic, trackIndex: 1, firstPtsHostNs: 5, firstCaptureHostNs: 5, frames: 48_000,
                                     sourceSampleRate: 48_000, channels: 2, sourceFormat: nil, gapPaddedFrames: 0,
                                     overlapTrimmedFrames: 0, droppedBuffers: 0, failed: false)
        facts.apply(video: nil, audio: audio, audioDevice: DeviceInfo(name: "Cam Link 4K", uid: "camlink-audio"))
        let report = MicSourceReport(verdict: .builtInMic, verdictsSeen: [.externalMic, .builtInMic], cameraMicSilent: false,
                                     meanCorrelation: 0.82, levelVsScreenMicDb: 1.5, voicedS: 30, screenMicVoicedS: 32,
                                     calibrated: false, correlationThreshold: 0.95)
        facts.micSource = report
        let tracks = CameraTrackBuilder.tracks(facts)
        let mic = try #require(tracks.first { $0.role == .mic })
        #expect(mic.micSource == report && tracks.first?.micSource == nil)
        let data = CameraTrackReport.trackStopData(track: mic, video: nil, audio: audio)
        #expect(data["mic_source"] == "built_in_mic" && data["camera_mic_silent"] == "false")
    }
}

private struct SampleBuffer: @unchecked Sendable { let buffer: CMSampleBuffer }

/// A host clock the test moves by hand.
private final class TestClock: Sendable {
    private let nowNs = Mutex<UInt64>(1_000_000_000_000)
    var now: @Sendable () -> UInt64 { { [self] in nowNs.withLock { $0 } } }
    func advance(_ ns: UInt64) { nowNs.withLock { $0 += ns } }
}

/// Publishes the two live idle meters (the camera mic and the Mac mic) into a monitor, one block
/// each per 50 ms of real time, while someone talks in phrases: what the metered preview and the
/// idle Mac mic do.
private final class LiveMeterFeeder: Sendable {
    let monitor: AudioLevelMonitor
    private let correlation = Mutex(0.99)

    init(monitor: AudioLevelMonitor) { self.monitor = monitor }

    func set(correlation value: Double) { correlation.withLock { $0 = value } }

    func run() async {
        var k: Int64 = 0
        while !Task.isCancelled {
            let index = AudioBlock.index(atNs: HostClock.nowNs())
            // Voice 0.25 s, pause 0.1 s.
            let voiced = k % 7 < 5
            let r = correlation.withLock { $0 }
            monitor.publish(AudioBlock(index: index, frames: 2400, channels: 2, peak: voiced ? 0.05 : 0.0005,
                                       meanSquare: voiced ? 1e-3 : 1e-7, correlation: voiced ? r : 0.1), from: .cameraMic)
            monitor.publish(AudioBlock(index: index, frames: 2400, channels: 1, peak: voiced ? 0.03 : 0.001,
                                       meanSquare: voiced ? 2.5e-4 : 6e-7), from: .screenMic)
            k += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The thread rule for the new paths: the meters, the monitor, the mic check, the frame probe and
/// the USB reader never wait for a queue, and the level and detector logic holds no capture code.
@Suite struct HealthThreadRuleTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func code(_ path: String) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
    }

    @Test func nothingWaits() throws {
        let files = ["Sources/CameraCapture/MicCheck.swift", "Sources/CameraCapture/EmptyFrames.swift",
                     "Sources/CameraCapture/USBLink.swift", "Sources/MediaWriter/AudioLevelMeter.swift",
                     "Sources/RecorderCore/AudioLevels.swift", "Sources/RecorderCore/CameraMicDetector.swift",
                     "Sources/CameraCapture/MacMicMeter.swift", "Sources/CameraCapture/AudioMeterTap.swift",
                     "Sources/RecorderCore/IdleCapture.swift"]
        let waits = ["DispatchSemaphore", ".sync {", ".sync(", "waitUntilDone", "DispatchGroup", "usleep(", "Thread.sleep"]
        var found: [String] = []
        for file in files {
            for (n, line) in try Self.code(file).enumerated() {
                for word in waits where line.contains(word) { found.append("\(file):\(n + 1): \(word)") }
            }
        }
        #expect(found == [])
    }

    @Test func theDetectorIsPure() throws {
        for file in ["Sources/RecorderCore/AudioLevels.swift", "Sources/RecorderCore/CameraMicDetector.swift"] {
            let code = try Self.code(file)
            #expect(!code.contains { $0.contains("import AVFoundation") || $0.contains("import CoreMedia") || $0.contains("AVCapture") })
        }
    }

    /// The check's own sessions face the same end-of-check test as the live meters: a session that
    /// opened but sent nothing is "sent nothing", not "no voice".
    @Test func theMicCheckTestsEverySourceAtTheEnd() throws {
        let code = try Self.code("Sources/CameraCapture/MicCheck.swift")
        #expect(code.contains { $0.contains("for source in sources.sorted(by: { $0.rawValue < $1.rawValue }) {") })
        #expect(!code.contains { $0.contains("var heard = Set(opened.value.map(\\.source))") })
        // The session's stop watch is cancelled before its own stop.
        let close = try #require(code.firstIndex { $0.contains("func close() {") })
        let cancel = try #require(code[close...].firstIndex { $0.contains("stopWatch.cancel()") })
        let stop = try #require(code[close...].firstIndex { $0.contains("session.stopRunning()") })
        #expect(cancel < stop)
    }

    /// The camera audio input never stays in the preview graph without its meter (the orange
    /// indicator with nothing metered), and a meter wish that came during an open or a reconnect
    /// is applied when it is done.
    @Test func theIdleMeterNeverLeavesAnInputBehindOrAWishUnapplied() throws {
        let code = try Self.code("Sources/CameraCapture/CameraRecorder.swift")
        let change = try #require(code.firstIndex { $0.contains("func change(to wanted: CameraGraphPlan") })
        let body = Array(code[change...].prefix(160))
        let meter = try #require(body.firstIndex { $0.contains("added.meter = makeMeterTap()") })
        let drop = try #require(body.firstIndex { $0.contains("if added.meter == nil, !wanted.hasMovieOutput {") })
        let commit = try #require(body.firstIndex { $0.contains("session.commitConfiguration()") })
        #expect(meter < drop && drop < commit)
        #expect(body[drop...].prefix(8).contains { $0.contains("session.removeInput(input)") })
        #expect(body[drop...].prefix(8).contains { $0.contains("removesAudio = true") })

        let open = try #require(code.firstIndex { $0.contains("public func openPreview(_ preview: CameraPreviewFeed, meters: Bool) async throws {") })
        #expect(code[open...].prefix(8).contains { $0.contains("await applyNewerMeterWish(than: meters)") })
        let reconnect = try #require(code.firstIndex { $0.contains("private func reconnect(automatic: Bool) async throws {") })
        #expect(code[reconnect...].prefix(4).contains { $0.contains("if let opened = try await reopen(automatic: automatic) { await applyNewerMeterWish(than: opened) }") })
        let reopen = try #require(code.firstIndex { $0.contains("private func reopen(automatic: Bool) async throws -> Bool? {") })
        let reopenBody = Array(code[reopen...].prefix(35))
        let wish = try #require(reopenBody.firstIndex { $0.contains("let meters = locked { previewMeters }") })
        let close = try #require(reopenBody.firstIndex { $0.contains("await teardown(only: graph)") })
        let reopened = try #require(reopenBody.firstIndex { $0.contains("try await open(.preview(meters: meters && canMeter)") })
        #expect(close < wish && wish < reopened)
    }

    /// Every mic check session is built and stopped in code that says it runs off the main thread.
    @Test func theMicCheckAssertsItsQueue() throws {
        let code = try Self.code("Sources/CameraCapture/MicCheck.swift")
        #expect(code.contains { $0.contains("CaptureThread.assertOffMain(\"Opening a mic check session\")") })
        #expect(code.contains { $0.contains("CaptureThread.assertOffMain(\"Closing a mic check session\")") })
        #expect(code.filter { $0.contains("startRunning()") || $0.contains("stopRunning()") }.count == 2)
        // The idle Mac mic uses the same session code, on its own queue, and never asks for access.
        let idle = try Self.code("Sources/CameraCapture/MacMicMeter.swift")
        #expect(!idle.contains { $0.contains("startRunning()") || $0.contains("stopRunning()") || $0.contains("requestAccess") })
        #expect(idle.contains { $0.contains("CheckSession.open(source: .screenMic") })
        #expect(idle.filter { $0.contains("queue.async") }.count == 2)  // deinit and onQueue.
    }
}
