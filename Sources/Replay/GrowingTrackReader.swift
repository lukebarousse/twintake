import AVFoundation
import CoreMedia

/// One opening of a movie: an AVFragmentedAsset with its duration and tracks loaded. A movie that
/// still grows is opened again for each new fragment (see `FragmentProbe`).
public struct LoadedMovie: @unchecked Sendable {
    public let url: URL
    public let asset: AVFragmentedAsset
    /// Seconds of file time that can be read.
    public let durationS: Double
    /// Every track, in file order (track 0 is the video).
    public let tracks: [AVAssetTrack]
    /// The movie can still get fragments. False once the writer has finished it: AVAssetWriter
    /// then rewrites the fragmented movie as one `mdat` and a new `moov` with no `mvex`. A take's
    /// file that finished early (its camera was disconnected) stops growing while the take goes on.
    public let canGrow: Bool

    public static func load(_ url: URL) async throws -> LoadedMovie {
        let asset = AVFragmentedAsset(url: url, options: nil)
        let (duration, tracks, canGrow) = try await asset.load(.duration, .tracks, .canContainFragments)
        let ordered = tracks.sorted { $0.trackID < $1.trackID }
        return LoadedMovie(url: url, asset: asset, durationS: duration.isNumeric ? duration.seconds : 0, tracks: ordered,
                           canGrow: canGrow)
    }

    /// The track at `index` in file order, if it has `mediaType`.
    public func track(_ index: Int, mediaType: AVMediaType) -> AVAssetTrack? {
        guard tracks.indices.contains(index), tracks[index].mediaType == mediaType else {
            // Fall back to the n-th track of that type (a file whose first track is not video).
            let ofType = tracks.filter { $0.mediaType == mediaType }
            return mediaType == .video ? ofType.first : nil
        }
        return tracks[index]
    }
}

/// Reads one track of a movie that may still grow, sample by sample, for a sample buffer
/// renderer. Confined to one queue (the replay engine's): not thread-safe.
///
/// - Video is read as stored (no decoding here: the display layer decodes it in hardware), in
///   decode order. After a seek it starts at the sync sample before the target; frames that end
///   before the target are decoded but not shown (`kCMSampleAttachmentKey_DoNotDisplay`), and
///   those no other frame depends on are not handed out at all (about a third of them: less to
///   decode while the recorders encode).
/// - A still (`restart(at:in:still:)`, while the timeline is dragged) hands out only that sync
///   sample: one frame to decode per seek.
/// - Audio is decoded to 32-bit float PCM; samples before the target are cut off.
/// - When the movie grows, `grow(to:)` opens the new movie and goes on after the last sample
///   handed out: no frame twice, none missed, so the renderer's decoder never notices. Each
///   sample keeps the first format description (an equal one from the new opening is swapped
///   for it), so the renderer never resets its decoder at a fragment.
/// - Every sample is moved onto take time: file time plus `offsetS`.
final class GrowingTrackReader {
    enum Media { case video, audio }

    enum Next {
        case sample(CMSampleBuffer)
        /// Nothing more in this opening of the movie: wait for it to grow (or its end).
        case needMore
        /// The still was handed out: nothing more until the next restart.
        case done
        case failed(String)
    }

    let media: Media
    let trackIndex: Int
    /// Take time of the file's time 0.
    var offsetS: Double
    private(set) var movie: LoadedMovie?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Video: decode time of the last sample handed out; audio: the end of the last one (file time).
    private(set) var lastS: Double?
    /// File time the picture or the sound starts at after a seek.
    private var showFromS: Double = 0
    private var waitingForSync = true
    /// Hand out the sync sample only (`stillDone` once it is out).
    private var still = false
    private var stillDone = false
    private var format: CMFormatDescription?
    /// The opening reached its end.
    private(set) var atEnd = false

    init(media: Media, trackIndex: Int, offsetS: Double) {
        self.media = media
        self.trackIndex = trackIndex
        self.offsetS = offsetS
    }

    private var mediaType: AVMediaType { media == .video ? .video : .audio }

    /// Starts over at file time `fileS` in `movie` (a seek). `still`: video only, the sync sample
    /// at or before `fileS`, and nothing after it.
    func restart(at fileS: Double, in movie: LoadedMovie, still: Bool = false) {
        cancel()
        lastS = nil
        showFromS = max(0, fileS)
        waitingForSync = media == .video
        self.still = still && media == .video
        stillDone = false
        // The reader begins video at the sync sample before its start; audio at the start itself.
        open(movie, from: media == .video ? max(0, fileS - 0.05) : max(0, fileS))
    }

    /// The movie grew: goes on after the last sample handed out, in the new opening.
    func grow(to movie: LoadedMovie) {
        guard let last = lastS else {
            restart(at: showFromS, in: movie)
            return
        }
        cancel()
        // The reader begins at the sync sample before its start and the samples handed out
        // already are skipped, so starting a little early never loses one (a frame may show
        // before the one decoded ahead of it).
        open(movie, from: max(0, last - 0.5))
    }

    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
        atEnd = false
    }

    private func open(_ movie: LoadedMovie, from startS: Double) {
        self.movie = movie
        atEnd = false
        guard let track = movie.track(trackIndex, mediaType: mediaType), let reader = try? AVAssetReader(asset: movie.asset) else {
            atEnd = true
            return
        }
        let settings: [String: Any]? = media == .video ? nil : [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            atEnd = true
            return
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startS, preferredTimescale: 48_000), end: .positiveInfinity)
        guard reader.startReading() else {
            atEnd = true
            return
        }
        self.reader = reader
        self.output = output
    }

    /// The next sample for the renderer, on take time.
    func next() -> Next {
        if stillDone { return .done }
        guard let reader, let output else { return .needMore }
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    let message = reader.error?.localizedDescription ?? "The movie could not be read."
                    cancel()
                    return .failed(message)
                }
                atEnd = true
                return .needMore
            }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            switch media {
            case .video:
                if let ready = videoSample(sample) { return .sample(ready) }
            case .audio:
                if let ready = audioSample(sample) { return .sample(ready) }
            }
        }
    }

    // MARK: Video

    private func videoSample(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dtsTime = CMSampleBufferGetDecodeTimeStamp(sample)
        let dts = (dtsTime.isNumeric ? dtsTime : pts).seconds
        if let last = lastS, dts <= last + 1e-6 { return nil }  // Handed out before the movie grew.
        if waitingForSync {
            guard SampleBuffers.isSync(sample) else { return nil }
            waitingForSync = false
        }
        lastS = dts
        if still {
            stillDone = true
            cancel()
            // AVAssetReader marks the frames before its time range DoNotDisplay: this one shows.
            let shown = SampleBuffers.adapted(sample, offsetS: offsetS, keepingFormat: &format, doNotDisplay: false)
            if let shown { SampleBuffers.removeAttachment(kCMSampleAttachmentKey_DoNotDisplay, from: shown) }
            return shown
        }
        // Hidden: frames that end before the target. The frame on screen at the target shows, so
        // a paused seek between two frames still shows its picture.
        let duration = CMSampleBufferGetDuration(sample)
        let length = duration.isNumeric && duration.seconds > 0 ? duration.seconds : 1.0 / 60
        let hidden = pts.isNumeric && pts.seconds + length <= showFromS + 0.0005
        // A hidden frame that no other frame needs: never decoded.
        if hidden, !SampleBuffers.isDependedOnByOthers(sample) { return nil }
        return SampleBuffers.adapted(sample, offsetS: offsetS, keepingFormat: &format, doNotDisplay: hidden)
    }

    // MARK: Audio

    private func audioSample(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        guard pts.isNumeric, duration.isNumeric else { return nil }
        let start = pts.seconds, end = start + duration.seconds
        let from = max(showFromS, lastS ?? -.infinity)
        guard end > from + 1e-6 else { return nil }
        var cut = sample
        if start < from - 1e-6 {
            let count = CMSampleBufferGetNumSamples(sample)
            let skip = min(count - 1, max(0, Int(((from - start) / duration.seconds * Double(count)).rounded())))
            guard skip > 0, let trimmed = SampleBuffers.suffix(sample, from: skip) else { return nil }
            cut = trimmed
        }
        lastS = end
        return SampleBuffers.adapted(cut, offsetS: offsetS, keepingFormat: &format, doNotDisplay: false)
    }
}

/// Sample buffer surgery for the replay.
enum SampleBuffers {
    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// False only when the file says no other frame depends on this one (a non-reference
    /// B-frame); without that attachment, true.
    static func isDependedOnByOthers(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool ?? true
    }

    /// The samples of an audio buffer from index `from` on.
    static func suffix(_ sample: CMSampleBuffer, from: Int) -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(sample)
        guard from < count else { return nil }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                            sampleRange: CFRange(location: from, length: count - from),
                                                            sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    /// `sample` moved by `offsetS` onto take time, with the format description handed out first
    /// when the new one is equal to it, and `kCMSampleAttachmentKey_DoNotDisplay` when hidden.
    static func adapted(_ sample: CMSampleBuffer, offsetS: Double, keepingFormat kept: inout CMFormatDescription?,
                        doNotDisplay: Bool) -> CMSampleBuffer? {
        let offset = CMTime(seconds: offsetS, preferredTimescale: 1_000_000_000)
        var timing = timingInfo(sample)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isNumeric {
                timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
            }
            if timing[i].decodeTimeStamp.isNumeric {
                timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        let format = CMSampleBufferGetFormatDescription(sample)
        if let format, let previous = kept, previous !== format, CMFormatDescriptionEqual(previous, otherFormatDescription: format) {
            out = rebuilt(sample, format: previous, timing: timing)
        }
        if out == nil {
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                               sampleTimingEntryCount: timing.count, sampleTimingArray: timing,
                                                               sampleBufferOut: &out)
            guard status == noErr else { return nil }
            kept = format
        }
        guard let result = out else { return nil }
        if doNotDisplay { setAttachment(kCMSampleAttachmentKey_DoNotDisplay, on: result) }
        return result
    }

    private static func timingInfo(_ sample: CMSampleBuffer) -> [CMSampleTimingInfo] {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return [] }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        return timing
    }

    /// A copy of `sample` with another (equal) format description and new timing. Nil when it
    /// cannot be made; the caller then copies the sample as it is.
    private static func rebuilt(_ sample: CMSampleBuffer, format: CMFormatDescription,
                                timing: [CMSampleTimingInfo]) -> CMSampleBuffer? {
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let count = CMSampleBufferGetNumSamples(sample)
        var sizeCount: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: sizeCount)
        if sizeCount > 0 {
            CMSampleBufferGetSampleSizeArray(sample, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: &sizeCount)
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format,
                                               sampleCount: count, sampleTimingEntryCount: timing.count,
                                               sampleTimingArray: timing.isEmpty ? nil : timing,
                                               sampleSizeEntryCount: sizeCount, sampleSizeArray: sizeCount > 0 ? sizes : nil,
                                               sampleBufferOut: &out)
        guard status == noErr, let out else { return nil }
        // Per-sample attachments (sync, dependencies) and the buffer's own attachments.
        if let from = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
           let to = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true) {
            let n = min(CFArrayGetCount(from), CFArrayGetCount(to))
            for i in 0..<n {
                let source = unsafeBitCast(CFArrayGetValueAtIndex(from, i), to: CFDictionary.self)
                let target = unsafeBitCast(CFArrayGetValueAtIndex(to, i), to: CFMutableDictionary.self)
                for (key, value) in (source as NSDictionary) {
                    CFDictionarySetValue(target, Unmanaged.passUnretained(key as AnyObject).toOpaque(),
                                         Unmanaged.passUnretained(value as AnyObject).toOpaque())
                }
            }
        }
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample,
                                                           attachmentMode: kCMAttachmentMode_ShouldPropagate) {
            CMSetAttachments(out, attachments: attachments, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return out
    }

    static func removeAttachment(_ key: CFString, from sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) else { return }
        for i in 0..<CFArrayGetCount(attachments) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionaryRemoveValue(dict, Unmanaged.passUnretained(key).toOpaque())
        }
    }

    static func setAttachment(_ key: CFString, on sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        for i in 0..<CFArrayGetCount(attachments) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
}
