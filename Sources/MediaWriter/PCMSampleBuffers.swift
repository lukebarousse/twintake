// Portions adapted from BetterCapture (https://github.com/jsattler/BetterCapture), Copyright (c) 2026 Joshua Sattler, MIT License.

import AVFoundation
import CoreMedia

/// Builds linear PCM sample buffers: silence, a range of samples cut from a captured buffer, and
/// a captured buffer moved to a new time. Every result keeps the source format description, so the
/// writer input never sees a format change.
package enum PCMSampleBuffers {
    /// `frameCount` samples of silence in `format`, stamped `pts`.
    /// Returns nil when the format is not linear PCM or `frameCount` is not positive.
    package static func silence(format: CMAudioFormatDescription, frameCount: Int, at pts: CMTime) -> CMSampleBuffer? {
        guard frameCount > 0, let pcm = makePCMBuffer(format: format, frameCount: frameCount) else { return nil }
        // AVAudioPCMBuffer does not promise zeroed memory.
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return makeSampleBuffer(from: pcm, format: format, at: pts)
    }

    /// Samples `frameOffset ..< frameOffset + frameCount` of `source`, stamped `pts`.
    package static func copy(_ source: CMSampleBuffer, frameOffset: Int, frameCount: Int, at pts: CMTime) -> CMSampleBuffer? {
        guard frameCount > 0, frameOffset >= 0,
              frameOffset + frameCount <= CMSampleBufferGetNumSamples(source),
              let format = CMSampleBufferGetFormatDescription(source),
              let pcm = makePCMBuffer(format: format, frameCount: frameCount)
        else { return nil }
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            source, at: Int32(frameOffset), frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return makeSampleBuffer(from: pcm, format: format, at: pts)
    }

    /// `source` with its first sample moved to `pts`. Shares the sample data; nothing is copied.
    package static func retimed(_ source: CMSampleBuffer, at pts: CMTime) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(source),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0
        else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate.rounded())),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: source,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    /// A stand-in format for a track that never received a buffer: Float32, non-interleaved.
    package static func fallbackFormat(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(max(1, channels)))?
            .formatDescription
    }

    private static func makePCMBuffer(format: CMFormatDescription, frameCount: Int) -> AVAudioPCMBuffer? {
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: format)
        guard audioFormat.sampleRate > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        return pcm
    }

    /// Wraps the samples of `pcm` (whose format matches `format`) in a sample buffer stamped `pts`.
    package static func makeSampleBuffer(from pcm: AVAudioPCMBuffer, format: CMFormatDescription,
                                 at pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate.rounded())),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer)
        guard createStatus == noErr, let sampleBuffer else { return nil }
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: pcm.audioBufferList)
        return attachStatus == noErr ? sampleBuffer : nil
    }
}
