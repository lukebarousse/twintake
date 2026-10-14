import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import MediaWriter
@testable import RecorderCore

/// Writes a small fragmented .mov with the recorder's own writer settings (`WriterSettings`:
/// HEVC on a 24000/1001 grid, 24-bit PCM, a movie fragment every 2 s of media, the first after
/// 1 s), as fast as the encoder takes frames. No capture device. Not thread-safe.
final class TestMovieWriter: @unchecked Sendable {
    let url: URL
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: AVAssetWriterInput?
    let rate = FrameRate.fps23_976
    private(set) var frames: Int64 = 0
    private(set) var audioSamples: Int64 = 0
    private var pictures: [CVPixelBuffer] = []

    init(url: URL, withAudio: Bool = true, width: Int = 320, height: Int = 180) throws {
        self.url = url
        writer = try WriterSettings.makeWriter(url: url, frameRate: rate)
        let settings = WriterSettings.video(codec: .hevc, width: width, height: height, frameRate: rate,
                                            bitrate: 1_000_000, keyFrameIntervalSeconds: 1)
        video = WriterSettings.makeVideoInput(settings: settings, frameRate: rate)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        if withAudio {
            let input = WriterSettings.makeAudioInput(channels: 1)
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }
        pictures = (0..<12).map { Self.picture(width: width, height: height, seed: $0) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Media seconds written so far.
    var writtenS: Double { Double(frames) * rate.frameDurationSeconds }

    /// Appends `seconds` of video (and the same span of audio, a 220 Hz tone).
    func write(seconds: Double) {
        let count = Int64((seconds / rate.frameDurationSeconds).rounded())
        for _ in 0..<count {
            while !video.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(pictures[Int(frames % Int64(pictures.count))], withPresentationTime: rate.time(ofFrame: frames))
            frames += 1
            guard let audio else { continue }
            let target = Int64((writtenS * 48_000).rounded())
            while audioSamples < target {
                let chunk = Int(min(1024, target - audioSamples))
                while !audio.isReadyForMoreMediaData { usleep(500) }
                if let buffer = Self.tone(frames: chunk, startSample: audioSamples) { audio.append(buffer) }
                audioSamples += Int64(chunk)
            }
        }
    }

    func finish() async {
        video.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: rate.time(ofFrame: frames))
        await writer.finishWriting()
    }

    /// A picture that differs per seed, so the encoder makes real P and B frames.
    static func picture(width: Int, height: Int, seed: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * row + x * 4
                p[0] = UInt8((x + seed * 9) & 0xFF)
                p[1] = UInt8((y * 2 + seed * 5) & 0xFF)
                p[2] = UInt8(((x ^ y) + seed * 17) & 0xFF)
                p[3] = 0xFF
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func tone(frames: Int, startSample: Int64) -> CMSampleBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = pcm.floatChannelData![0]
        for i in 0..<frames { data[i] = 0.25 * sin(2 * .pi * 220 * Float(startSample + Int64(i)) / 48_000) }
        return PCMSampleBuffers.makeSampleBuffer(from: pcm, format: format.formatDescription,
                                                 at: CMTime(value: startSample, timescale: 48_000))
    }
}

extension FrameRate {
    var frameDurationSeconds: Double { Double(den) / Double(num) }
}

/// A fresh folder in the temporary directory, removed by the caller.
func temporaryFolder(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls `condition` every 50 ms for at most `seconds`.
func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
