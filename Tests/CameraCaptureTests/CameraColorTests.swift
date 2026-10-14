import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CameraCapture
import MediaWriter
import RecorderCore

// The camera's colors on both paths, with synthetic 420v (video range) frames of known colors:
// the preview (data output frame -> CameraPreviewFeed -> AVSampleBufferDisplayLayer) and camera.mov
// (the same writer handles CameraWriterController uses). No camera involved.

/// A Y'CbCr color as 8-bit video-range code values.
struct SyntheticColor: Sendable, Equatable, CustomStringConvertible {
    var y: UInt8
    var cb: UInt8
    var cr: UInt8

    /// Mid gray: no chroma at all.
    static let midGray = SyntheticColor(y: 126, cb: 128, cr: 128)
    /// A skin tone: Cb below 128, Cr above it. With Cb and Cr swapped it turns blue.
    static let skin = SyntheticColor(y: 150, cb: 110, cr: 150)

    /// Full-range RGB by the BT.709 video-range matrix, as a player decodes a BT.709 file.
    var bt709RGB: (r: Double, g: Double, b: Double) {
        let yy = 1.164 * (Double(y) - 16), u = Double(cb) - 128, v = Double(cr) - 128
        return (yy + 1.793 * v, yy - 0.213 * u - 0.533 * v, yy + 2.112 * u)
    }

    var description: String { "Y\(y) Cb\(cb) Cr\(cr)" }
}

enum SyntheticTags: Sendable {
    case none
    case bt709
    case bt601
}

/// A `width` x `height` 420v frame filled with `color`, with the given color tags on it.
private func yuvFrame(_ color: SyntheticColor, width: Int = 320, height: Int = 180, tags: SyntheticTags) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pb) == kCVReturnSuccess)
    let buffer = try #require(pb)
    CVPixelBufferLockBaseAddress(buffer, [])
    let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
    memset(luma, Int32(color.y), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
    // The chroma plane interleaves Cb then Cr (NV12).
    let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        for pair in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
            chroma[row * rowBytes + 2 * pair] = color.cb
            chroma[row * rowBytes + 2 * pair + 1] = color.cr
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    switch tags {
    case .none:
        break
    case .bt709:
        for tag in CameraPreviewFeed.bt709Tags { CVBufferSetAttachment(buffer, tag.key, tag.value, .shouldPropagate) }
    case .bt601:
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    }
    return buffer
}

/// A sample buffer around `image`, like the preview data output delivers.
private func sample(_ image: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1001, timescale: 24000),
                                    presentationTimeStamp: HostClock.now(), decodeTimeStamp: .invalid)
    var out: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try #require(format),
                                                     sampleTiming: &timing, sampleBufferOut: &out) == noErr)
    return try #require(out)
}

/// The Y, Cb and Cr bytes at the center of a 420v frame.
private func centerYCbCr(_ buffer: CVPixelBuffer) -> SyntheticColor {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let y = luma[(h / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + w / 2]
    let c = (h / 4) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + 2 * (w / 4)
    return SyntheticColor(y: y, cb: chroma[c], cr: chroma[c + 1])
}

private func attachment(_ buffer: CVBuffer, _ key: CFString) -> String? {
    CVBufferCopyAttachment(buffer, key, nil) as? String
}

private func extensionValue(_ format: CMFormatDescription, _ key: CFString) -> String? {
    CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
}

private func isFullRange(_ format: CMFormatDescription) -> Bool {
    (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) == true
}

@Suite struct PreviewColorTests {
    /// An untagged frame gets camera.mov's BT.709 tags, on the same pixel buffer: same bytes, no
    /// copy, no conversion, Cb still before Cr.
    @Test func anUntaggedFrameGetsTheBT709TagsOfCameraMov() throws {
        for color in [SyntheticColor.midGray, .skin] {
            let image = try yuvFrame(color, width: 640, height: 360, tags: .none)
            let original = try sample(image)
            let shown = CameraPreviewFeed.colorTagged(original)
            let shownImage = try #require(CMSampleBufferGetImageBuffer(shown))
            #expect(shownImage === image)
            #expect(CVPixelBufferGetPixelFormatType(shownImage) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            #expect(attachment(shownImage, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            #expect(attachment(shownImage, kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            #expect(attachment(shownImage, kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            let format = try #require(CMSampleBufferGetFormatDescription(shown))
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            #expect(extensionValue(format, kCMFormatDescriptionExtension_YCbCrMatrix) == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
            #expect(extensionValue(format, kCMFormatDescriptionExtension_ColorPrimaries) == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
            #expect(extensionValue(format, kCMFormatDescriptionExtension_TransferFunction)
                == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
            #expect(!isFullRange(format))
            #expect(CMSampleBufferGetPresentationTimeStamp(shown) == CMSampleBufferGetPresentationTimeStamp(original))
            #expect(centerYCbCr(shownImage) == color)
        }
    }

    /// The camera's own tags win: a tagged frame is shown as it came, even with BT.601 tags.
    @Test func aTaggedFrameIsShownAsItCame() throws {
        for tags in [SyntheticTags.bt709, .bt601] {
            let image = try yuvFrame(.skin, width: 640, height: 360, tags: tags)
            let original = try sample(image)
            #expect(CameraPreviewFeed.colorTagged(original) === original)
            let matrix = attachment(image, kCVImageBufferYCbCrMatrixKey)
            #expect(matrix == (tags == .bt601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2) as String)
            #expect(centerYCbCr(image) == .skin)
        }
    }

    /// The real path: an untagged skin frame through the feed's queue to an attached display layer.
    /// The layer gets the tagged frame; the pixel bytes are the camera's.
    @MainActor @Test func theFeedShowsTheCameraBytesWithTags() async throws {
        let feed = CameraPreviewFeed()
        let view = CameraPreviewNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.show(feed, videoGravity: .resizeAspect, mirrored: false)
        let image = try yuvFrame(.skin, width: 640, height: 360, tags: .none)
        let box = CaptureBox(try sample(image))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            feed.queue.async {
                feed.enqueue(box.value)
                cont.resume()
            }
        }
        #expect(feed.stats().pixelFormat == "420v")
        #expect(attachment(image, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        #expect(centerYCbCr(image) == .skin)
        view.stopShowing()
        feed.clear()
    }

    /// The empty-frame sampler that sees every preview and recording frame only reads.
    @Test func theEmptyFrameSamplerOnlyReads() throws {
        let image = try yuvFrame(.skin, width: 640, height: 360, tags: .none)
        let found = try #require(PixelSampler.sample(image))
        #expect(found.pattern == .constant)
        #expect(centerYCbCr(image) == .skin)
        #expect(attachment(image, kCVImageBufferYCbCrMatrixKey) == nil)
    }
}

/// camera.mov's color: 420v frames in, an HEVC file with BT.709 tags out, the same colors back.
@Suite(.serialized) struct CameraMovColorTests {
    static let frames = 12

    /// Writes `frames` frames of each color, in order, with the writer handles camera.mov uses.
    func write(_ colors: [SyntheticColor], tags: SyntheticTags, to url: URL) async throws {
        let rate = FrameRate.fps23_976
        let plan = CameraWriterController.FilePlan(codec: .hevc, width: 320, height: 180, frameRate: rate,
                                                   bitrate: 2_000_000, audioChannels: nil)
        let handles = try CameraWriterHandles.make(url: url, plan: plan)
        #expect(handles.writer.startWriting(), "\(String(describing: handles.writer.error))")
        handles.writer.startSession(atSourceTime: .zero)
        let buffers = try colors.map { try yuvFrame($0, tags: tags) }
        var slot: Int64 = 0
        for buffer in buffers {
            for _ in 0..<Self.frames {
                var waited = 0
                while !handles.video.isReadyForMoreMediaData, waited < 500 {
                    try await Task.sleep(for: .milliseconds(5))
                    waited += 1
                }
                #expect(handles.adaptor.append(buffer, withPresentationTime: rate.time(ofFrame: slot)))
                slot += 1
            }
        }
        handles.video.markAsFinished()
        await WriterBox(writer: handles.writer).finish(endingAt: rate.time(ofFrame: slot))
        #expect(handles.writer.status == .completed, "\(String(describing: handles.writer.error))")
    }

    /// The middle frame of each color's run.
    func time(ofColor index: Int) -> CMTime { FrameRate.fps23_976.time(ofFrame: Int64(index * Self.frames + Self.frames / 2)) }

    /// The RGB at the center of the frame at `time`, as AVAssetImageGenerator gives it (drawn in
    /// the image's own color space when it can be, so no extra color matching).
    func centerRGB(_ asset: AVURLAsset, at time: CMTime) async throws -> (r: Double, g: Double, b: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(drawn)
        let i = ((h / 2) * w + w / 2) * 4
        return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
    }

    @Test(arguments: [SyntheticTags.none, .bt709])
    func grayAndSkinComeBackWithBT709Tags(tags: SyntheticTags) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-color-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("camera.mov")
        let colors = [SyntheticColor.midGray, .skin]
        try await write(colors, tags: tags, to: url)

        // The file's tags: BT.709 primaries, transfer and matrix, video range, HEVC.
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(extensionValue(format, kCMFormatDescriptionExtension_ColorPrimaries) == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(extensionValue(format, kCMFormatDescriptionExtension_TransferFunction) == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(extensionValue(format, kCMFormatDescriptionExtension_YCbCrMatrix) == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        #expect(!isFullRange(format))

        // The decoded bytes: the same Y, Cb and Cr (Cb is still Cb), within the codec's rounding.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var decoded: [(time: CMTime, color: SyntheticColor)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { continue }
            decoded.append((CMSampleBufferGetPresentationTimeStamp(buffer), centerYCbCr(image)))
        }
        #expect(decoded.count == colors.count * Self.frames)
        for (index, color) in colors.enumerated() {
            let got = try #require(decoded.first { $0.time == time(ofColor: index) }?.color)
            #expect(abs(Int(got.y) - Int(color.y)) <= 3 && abs(Int(got.cb) - Int(color.cb)) <= 3
                && abs(Int(got.cr) - Int(color.cr)) <= 3, "wrote \(color), read \(got)")
        }

        // The picture a player shows (on macOS 27.2: exactly 128,128,128 and 195,148,118 in the
        // CoreMedia 709 space). Gray stays gray: a magenta or green cast splits G from R and B.
        // Skin stays warm, R > G > B: swapped chroma makes B the largest.
        let gray = try await centerRGB(asset, at: time(ofColor: 0))
        let grayWant = SyntheticColor.midGray.bt709RGB
        #expect(max(gray.r, gray.g, gray.b) - min(gray.r, gray.g, gray.b) <= 4, "gray came back as \(gray)")
        #expect(abs(gray.g - grayWant.g) <= 8, "gray came back as \(gray), BT.709 gives \(grayWant)")
        let skin = try await centerRGB(asset, at: time(ofColor: 1))
        let skinWant = SyntheticColor.skin.bt709RGB
        #expect(skin.r > skin.g && skin.g > skin.b && skin.r - skin.b >= 50, "skin came back as \(skin), BT.709 gives \(skinWant)")
        #expect(abs(skin.r - skinWant.r) <= 8 && abs(skin.g - skinWant.g) <= 8 && abs(skin.b - skinWant.b) <= 8,
                "skin came back as \(skin), BT.709 gives \(skinWant)")
    }
}
