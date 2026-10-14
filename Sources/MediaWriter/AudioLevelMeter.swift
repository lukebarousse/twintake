import Accelerate
import AudioToolbox
import CoreMedia
import Foundation
import RecorderCore

/// One channel's samples as Float32: `base[i * stride]` is sample i.
package struct ChannelView {
    package var base: UnsafePointer<Float>
    package var stride: Int
    package init(base: UnsafePointer<Float>, stride: Int) { self.base = base; self.stride = stride }
}

/// The sums of one ~50 ms block, filled chunk by chunk with vDSP. Pure.
package struct BlockAccumulator {
    package var index: Int64?
    package private(set) var frames = 0
    package private(set) var channels = 0
    private var peak: Float = 0
    private var sumSquares = 0.0
    private var clipped = 0
    private var sumL = 0.0, sumR = 0.0, sumLL = 0.0, sumRR = 0.0, sumLR = 0.0

    package init() {}

    /// Starts block `index` with nothing in it.
    package mutating func start(index: Int64, channels: Int) {
        self = BlockAccumulator()
        self.index = index
        self.channels = channels
    }

    /// Adds samples `offset ..< offset + count` of every channel in `views`.
    package mutating func add(_ views: UnsafePointer<ChannelView>, channels: Int, offset: Int, count: Int) {
        guard count > 0, channels > 0 else { return }
        let n = vDSP_Length(count)
        for c in 0..<channels {
            let view = views[c]
            let p = view.base + offset * view.stride
            let s = vDSP_Stride(view.stride)
            var magnitude: Float = 0
            vDSP_maxmgv(p, s, &magnitude, n)
            var squares: Float = 0
            vDSP_svesq(p, s, &squares, n)
            peak = max(peak, magnitude)
            sumSquares += Double(squares)
            if magnitude >= AudioBlock.clipLevel {
                // Rare: count the clipped samples one by one only when the peak says there are some.
                for i in 0..<count where abs(p[i * view.stride]) >= AudioBlock.clipLevel { clipped += 1 }
            }
            if c < 2 {
                var total: Float = 0
                vDSP_sve(p, s, &total, n)
                if c == 0 { sumL += Double(total); sumLL += Double(squares) } else { sumR += Double(total); sumRR += Double(squares) }
            }
        }
        if channels >= 2 {
            let l = views[0], r = views[1]
            var dot: Float = 0
            vDSP_dotpr(l.base + offset * l.stride, vDSP_Stride(l.stride), r.base + offset * r.stride, vDSP_Stride(r.stride),
                       &dot, n)
            sumLR += Double(dot)
        }
        frames += count
    }

    /// The finished block.
    package func block() -> AudioBlock? {
        guard let index, frames > 0, channels > 0 else { return nil }
        let samples = Double(frames * channels)
        var correlation: Double?
        if channels >= 2 {
            let n = Double(frames)
            let varL = sumLL - sumL * sumL / n
            let varR = sumRR - sumR * sumR / n
            // A flat channel (digital silence) has no correlation.
            if varL > 1e-12 * n, varR > 1e-12 * n {
                correlation = min(1, max(-1, (sumLR - sumL * sumR / n) / (varL * varR).squareRoot()))
            }
        }
        return AudioBlock(index: index, frames: frames, channels: channels, peak: peak, meanSquare: sumSquares / samples,
                          clipped: clipped, correlation: correlation)
    }
}

/// Measures one audio source in ~50 ms blocks on the host clock (`AudioBlock.durationNs`) and
/// hands each finished block to an `AudioLevelMonitor`: peak, RMS, clipped samples and, for
/// stereo, the L/R correlation, all with Accelerate (vDSP).
///
/// Confined to the queue that delivers the source's buffers (the audio pipeline's queue, or a
/// mic check's). Linear PCM only: Float32, Float64, and signed 16, 24 and 32-bit integers,
/// interleaved or not. After the first buffer it allocates nothing: the buffer list and the
/// conversion buffer are kept and grow only for a larger buffer.
package final class AudioLevelMeter: @unchecked Sendable {
    package let source: AudioSource
    /// Where each finished block goes: the monitor (or a test).
    private let sink: (AudioBlock) -> Void
    /// Channels it reads; more are left out.
    package static let maxChannels = 16

    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let views: UnsafeMutablePointer<ChannelView>
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0
    private var accumulator = BlockAccumulator()
    /// The last block handed on: a buffer stamped a little early never reopens it.
    private var lastPublished: Int64?

    package convenience init(source: AudioSource, monitor: AudioLevelMonitor) {
        self.init(source: source) { [monitor] block in monitor.publish(block, from: source) }
    }

    /// - Parameter sink: takes each finished block, on the meter's queue.
    package init(source: AudioSource, sink: @escaping (AudioBlock) -> Void) {
        self.source = source
        self.sink = sink
        bufferList = AudioBufferList.allocate(maximumBuffers: Self.maxChannels)
        views = UnsafeMutablePointer<ChannelView>.allocate(capacity: Self.maxChannels)
    }

    deinit {
        free(bufferList.unsafeMutablePointer)
        views.deallocate()
        scratch?.deallocate()
    }

    /// Measures one PCM buffer whose first sample is at host time `ptsNs`. On the meter's queue.
    package func process(_ sampleBuffer: CMSampleBuffer, ptsNs: UInt64) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = min(Int(asbd.mChannelsPerFrame), Self.maxChannels)
        guard frames > 0, channels > 0 else { return }

        // The call wants the exact size of the list it fills (a larger one fails with
        // kCMSampleBufferError_ArrayTooSmall), so ask for it first. Neither call allocates.
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            needed > 0, needed <= AudioBufferList.sizeInBytes(maximumBuffers: Self.maxChannels)
        else { return }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        withExtendedLifetime(blockBuffer) {
            guard fillViews(asbd: asbd, frames: frames, channels: channels) else { return }
            measure(frames: frames, channels: channels, sampleRate: asbd.mSampleRate, ptsNs: ptsNs)
        }
    }

    /// Measures `frames` samples per channel already in Float32 views. On the meter's queue.
    package func process(_ views: UnsafePointer<ChannelView>, channels: Int, frames: Int, sampleRate: Double, ptsNs: UInt64) {
        let channels = min(channels, Self.maxChannels)
        guard frames > 0, channels > 0, sampleRate > 0 else { return }
        for c in 0..<channels { self.views[c] = views[c] }
        measure(frames: frames, channels: channels, sampleRate: sampleRate, ptsNs: ptsNs)
    }

    /// Hands on the block in progress, e.g. when the source stops.
    package func flush() {
        if let block = accumulator.block() { publish(block) }
        accumulator = BlockAccumulator()
    }

    // MARK: Private, on the meter's queue

    /// Splits the buffer at the host-clock block boundaries and adds each piece.
    private func measure(frames: Int, channels: Int, sampleRate: Double, ptsNs: UInt64) {
        let nsPerFrame = 1e9 / sampleRate
        let blockNs = AudioBlock.durationNs
        var offset = 0
        while offset < frames {
            let tNs = ptsNs + UInt64((Double(offset) * nsPerFrame).rounded())
            var index = AudioBlock.index(atNs: tNs)
            if let open = accumulator.index, index < open { index = open }
            if accumulator.index == nil, let last = lastPublished, index <= last { index = last + 1 }
            if accumulator.index != index || accumulator.channels != channels {
                flush()
                accumulator.start(index: index, channels: channels)
            }
            // Samples left before the block's end, at least one.
            let endNs = Double(UInt64(index + 1) * blockNs)
            let left = max(0, endNs - Double(tNs))
            let count = max(1, min(frames - offset, Int((left / nsPerFrame).rounded(.up))))
            accumulator.add(views, channels: channels, offset: offset, count: count)
            offset += count
            // The piece reached the boundary: the block is complete.
            if Double(count) * nsPerFrame >= left - nsPerFrame / 2 { flush() }
        }
    }

    private func publish(_ block: AudioBlock) {
        lastPublished = block.index
        sink(block)
    }

    /// Points `views` at Float32 samples: the buffer's own, or converted into `scratch`.
    private func fillViews(asbd: AudioStreamBasicDescription, frames: Int, channels: Int) -> Bool {
        let buffers = bufferList
        let flags = asbd.mFormatFlags
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let interleavedChannels = Int(asbd.mChannelsPerFrame)
        // Bytes of one sample of one channel.
        let sampleBytes = nonInterleaved ? Int(asbd.mBytesPerFrame) : Int(asbd.mBytesPerFrame) / max(1, interleavedChannels)
        guard sampleBytes > 0 else { return false }
        if nonInterleaved {
            guard buffers.count >= channels else { return false }
            for c in 0..<channels where Int(buffers[c].mDataByteSize) < frames * sampleBytes || buffers[c].mData == nil {
                return false
            }
        } else {
            guard buffers.count >= 1, let _ = buffers[0].mData,
                  Int(buffers[0].mDataByteSize) >= frames * interleavedChannels * sampleBytes else { return false }
        }

        // Float32 needs no copy.
        if isFloat && sampleBytes == 4 {
            for c in 0..<channels {
                if nonInterleaved {
                    views[c] = ChannelView(base: UnsafePointer(buffers[c].mData!.assumingMemoryBound(to: Float.self)), stride: 1)
                } else {
                    views[c] = ChannelView(base: UnsafePointer(buffers[0].mData!.assumingMemoryBound(to: Float.self)) + c,
                                           stride: interleavedChannels)
                }
            }
            return true
        }

        // Everything else is converted to Float32 in `scratch`, laid out like the source.
        let total = nonInterleaved ? frames * channels : frames * interleavedChannels
        let out = scratchBuffer(count: total)
        if nonInterleaved {
            for c in 0..<channels {
                let destination = out + c * frames
                guard convert(buffers[c].mData!, count: frames, sampleBytes: sampleBytes, bits: bits, isFloat: isFloat,
                              flags: flags, into: destination) else { return false }
                views[c] = ChannelView(base: UnsafePointer(destination), stride: 1)
            }
        } else {
            guard convert(buffers[0].mData!, count: total, sampleBytes: sampleBytes, bits: bits, isFloat: isFloat,
                          flags: flags, into: out) else { return false }
            for c in 0..<channels { views[c] = ChannelView(base: UnsafePointer(out) + c, stride: interleavedChannels) }
        }
        return true
    }

    /// Converts `count` samples to Float32 full scale ±1.
    private func convert(_ source: UnsafeMutableRawPointer, count: Int, sampleBytes: Int, bits: Int, isFloat: Bool,
                         flags: AudioFormatFlags, into out: UnsafeMutablePointer<Float>) -> Bool {
        let n = vDSP_Length(count)
        switch (isFloat, sampleBytes) {
        case (true, 8):
            vDSP_vdpsp(source.assumingMemoryBound(to: Double.self), 1, out, 1, n)
        case (false, 2):
            vDSP_vflt16(source.assumingMemoryBound(to: Int16.self), 1, out, 1, n)
            var scale: Float = 1 / 32768
            vDSP_vsmul(out, 1, &scale, out, 1, n)
        case (false, 4):
            vDSP_vflt32(source.assumingMemoryBound(to: Int32.self), 1, out, 1, n)
            // 24 bits in the low bytes of 32 (not aligned high) have a full scale of 2^23.
            let lowAligned = bits < 32 && flags & kAudioFormatFlagIsAlignedHigh == 0
            var scale: Float = lowAligned ? 1 / Float(1 << (max(1, bits) - 1)) : 1 / 2_147_483_648
            vDSP_vsmul(out, 1, &scale, out, 1, n)
        case (false, 3):
            // Packed 24-bit, little endian: rare, so a plain loop.
            let bytes = source.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let b = bytes + i * 3
                let value = Int32(bitPattern: UInt32(b[0]) << 8 | UInt32(b[1]) << 16 | UInt32(b[2]) << 24) >> 8
                out[i] = Float(value) / 8_388_608
            }
        default:
            return false
        }
        return true
    }

    private func scratchBuffer(count: Int) -> UnsafeMutablePointer<Float> {
        if let scratch, scratchCapacity >= count { return scratch }
        scratch?.deallocate()
        let fresh = UnsafeMutablePointer<Float>.allocate(capacity: count)
        scratch = fresh
        scratchCapacity = count
        return fresh
    }
}
