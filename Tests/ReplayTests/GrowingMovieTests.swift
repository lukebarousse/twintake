import AVFoundation
import CoreMedia
import Testing
@testable import RecorderCore
@testable import Replay

/// The growing-file reader against real fragmented movies, written in a temp folder with the
/// recorder's writer settings while they are read. No device.
@Suite(.serialized) struct GrowingMovieTests {
    /// Writes until the probe has seen `fragments` more complete fragments (at most 3 s of media
    /// per fragment: one fragment is 2 s).
    private func writeFragments(_ movie: TestMovieWriter, _ probe: inout FragmentProbe, more fragments: Int) async -> Bool {
        let goal = probe.fragments + fragments
        for _ in 0..<(6 * fragments + 2) {
            movie.write(seconds: 0.5)
            var p = probe
            let done = await waitFor(0.3) { p.scan(); return p.fragments >= goal }
            probe = p
            if done { return true }
        }
        return probe.fragments >= goal
    }

    /// What the SDK promises (AVAsset.h: fragment minding for QuickTime movies with an `mvex`
    /// box) holds for the recorder's .mov: it can contain fragments, and does while it is written.
    /// The probe sees each fragment land, and each new opening reads further.
    @Test func theProbeSeesFragmentsLandAndANewOpeningReadsFurther() async throws {
        let dir = try temporaryFolder("replay-probe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent("screen.mov"))
        var probe = FragmentProbe(url: movie.url)
        let foundAtFirst = probe.scan()
        #expect(!foundAtFirst && !probe.hasMovie)

        #expect(await writeFragments(movie, &probe, more: 1))
        #expect(probe.hasMovie)
        let first = try await LoadedMovie.load(movie.url)
        #expect(try await first.asset.load(.canContainFragments))
        #expect(try await first.asset.load(.containsFragments))
        #expect(first.durationS > 0.5)
        #expect(first.tracks.map(\.mediaType) == [.video, .audio])

        let before = probe.fragments
        #expect(await writeFragments(movie, &probe, more: 2))
        #expect(probe.fragments >= before + 2)
        let second = try await LoadedMovie.load(movie.url)
        #expect(second.durationS >= first.durationS + 3.5, "\(first.durationS) -> \(second.durationS)")
        #expect(first.canGrow && second.canGrow)
        // A scan with nothing new finds nothing and stays where it was.
        let offset = probe.offset
        let foundAgain = probe.scan()
        #expect(!foundAgain)
        #expect(probe.offset == offset)
        #expect(!probe.finished)
        // The writer finishes the file (Stop, or a recorder that ended early): it is rewritten with
        // a second moov at its end and no fragments. The probe and a new opening both tell.
        await movie.finish()
        let foundAtFinish = probe.scan()
        #expect(foundAtFinish)
        #expect(probe.finished)
        let foundAfterFinish = probe.scan()
        #expect(!foundAfterFinish)
        let finished = try await LoadedMovie.load(movie.url)
        #expect(!finished.canGrow)
        #expect(finished.durationS >= second.durationS)
    }

    /// Video read across three openings of the growing movie: every frame once, in decode order,
    /// one frame apart, all with the first format description (so a display layer never resets
    /// its decoder at a fragment), moved onto take time by the offset.
    @Test func videoReadsOnAcrossFragmentsWithoutAGapOrARepeat() async throws {
        let dir = try temporaryFolder("replay-video")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent("camera.mov"), withAudio: false)
        var probe = FragmentProbe(url: movie.url)
        #expect(await writeFragments(movie, &probe, more: 1))

        let offset = 0.0125
        let reader = GrowingTrackReader(media: .video, trackIndex: 0, offsetS: offset)
        var opening = try await LoadedMovie.load(movie.url)
        reader.restart(at: 0, in: opening)
        var samples: [CMSampleBuffer] = []
        func drain() {
            while case let .sample(sample) = reader.next() { samples.append(sample) }
        }
        drain()
        #expect(!samples.isEmpty)
        for _ in 0..<2 {
            #expect(await writeFragments(movie, &probe, more: 1))
            let grown = try await LoadedMovie.load(movie.url)
            #expect(grown.durationS > opening.durationS)
            opening = grown
            reader.grow(to: grown)
            drain()
        }

        let frame = movie.rate.frameDurationSeconds
        let decode = samples.map { s -> Double in
            let dts = CMSampleBufferGetDecodeTimeStamp(s)
            return (dts.isNumeric ? dts : CMSampleBufferGetPresentationTimeStamp(s)).seconds
        }
        let steps = zip(decode, decode.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { abs($0 - frame) < 1e-4 }, "steps \(Set(steps.map { ($0 * 1e4).rounded() / 1e4 }))")
        // Every frame the last opening holds, once. (Its duration runs a little past them: with
        // frame reordering, a B-frame shown before the newest frame lands in the next fragment.)
        let fresh = GrowingTrackReader(media: .video, trackIndex: 0, offsetS: offset)
        fresh.restart(at: 0, in: opening)
        var all: [Double] = []
        var allSync: [Bool] = []
        while case let .sample(sample) = fresh.next() {
            all.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            allSync.append(SampleBuffers.isSync(sample))
        }
        #expect(samples.count == all.count, "\(samples.count) frames across openings, \(all.count) in one")
        #expect(samples.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } == all)
        // The swapped format description keeps each frame's sync flag (a keyframe every second).
        #expect(samples.map(SampleBuffers.isSync) == allSync)
        #expect(allSync.filter { $0 }.count >= 6)
        #expect(Double(samples.count) * frame > opening.durationS - 0.25)
        let presentation = samples.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }.sorted()
        #expect(abs(presentation[0] - offset) < 1e-6)
        let format = CMSampleBufferGetFormatDescription(samples[0])
        #expect(samples.allSatisfy { CMSampleBufferGetFormatDescription($0) === format })
        #expect(SampleBuffers.isSync(samples[0]))
        await movie.finish()
    }

    /// A seek starts at the sync sample before the target; the frames that end before the target
    /// are decoded but not shown.
    @Test func aSeekStartsAtTheKeyframeAndHidesTheFramesBeforeTheTarget() async throws {
        let dir = try temporaryFolder("replay-seek")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent("screen.mov"), withAudio: false)
        movie.write(seconds: 4)
        await movie.finish()
        let opening = try await LoadedMovie.load(movie.url)
        let reader = GrowingTrackReader(media: .video, trackIndex: 0, offsetS: 0)
        reader.restart(at: 2.3, in: opening)
        var samples: [CMSampleBuffer] = []
        while case let .sample(sample) = reader.next() { samples.append(sample) }
        let first = try #require(samples.first)
        #expect(SampleBuffers.isSync(first))
        #expect(CMSampleBufferGetPresentationTimeStamp(first).seconds <= 2.3)
        func hidden(_ s: CMSampleBuffer) -> Bool {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
            return attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool ?? false
        }
        let frame = movie.rate.frameDurationSeconds
        for sample in samples {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Hidden when the frame ends before the target: the frame on screen at 2.3 s shows.
            #expect(hidden(sample) == (pts + frame <= 2.3 + 0.0005), "pts \(pts)")
        }
        let shown = samples.filter { !hidden($0) }.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        #expect(abs((shown.min() ?? 0) - (2.3 / frame).rounded(.down) * frame) < 1e-6)
        // Hidden frames that no other frame needs are not handed out (nothing to decode for them);
        // every frame from the target on still shows.
        #expect(!samples.contains { hidden($0) && !SampleBuffers.isDependedOnByOthers($0) })
        let everyFrame = GrowingTrackReader(media: .video, trackIndex: 0, offsetS: 0)
        everyFrame.restart(at: 0, in: opening)
        var all: [CMSampleBuffer] = []
        while case let .sample(sample) = everyFrame.next() { all.append(sample) }
        #expect(all.contains { !SampleBuffers.isDependedOnByOthers($0) }, "the encoder makes non-reference frames")
        let fromTarget = all.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
            .filter { $0 + frame > 2.3 + 0.0005 }.sorted()
        #expect(shown.sorted() == fromTarget)
        // Fewer frames to decode than from the keyframe on.
        let keyframe = CMSampleBufferGetDecodeTimeStamp(first).seconds
        #expect(samples.count < all.filter { CMSampleBufferGetDecodeTimeStamp($0).seconds >= keyframe - 1e-6 }.count)
        // A finished movie has nothing more: the reader says so and stays at its end.
        #expect({ if case .needMore = reader.next() { true } else { false } }())
        #expect(reader.atEnd)
    }

    /// While the timeline is dragged: only the keyframe at or before the target, shown, and then
    /// nothing until the next restart.
    @Test func aStillIsTheKeyframeAlone() async throws {
        let dir = try temporaryFolder("replay-still")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent("screen.mov"), withAudio: false)
        movie.write(seconds: 4)
        await movie.finish()
        let opening = try await LoadedMovie.load(movie.url)
        let reader = GrowingTrackReader(media: .video, trackIndex: 0, offsetS: 0)
        reader.restart(at: 2.6, in: opening, still: true)
        guard case let .sample(still) = reader.next() else {
            Issue.record("no still")
            return
        }
        #expect(SampleBuffers.isSync(still))
        let pts = CMSampleBufferGetPresentationTimeStamp(still).seconds
        #expect(pts <= 2.6 && pts > 2.6 - 1.05, "keyframe at \(pts)")
        let attachments = CMSampleBufferGetSampleAttachmentsArray(still, createIfNecessary: false) as? [[CFString: Any]]
        #expect(attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool != true)
        #expect({ if case .done = reader.next() { true } else { false } }())
        #expect({ if case .done = reader.next() { true } else { false } }())
        // A normal restart reads on as before.
        reader.restart(at: 2.6, in: opening)
        var count = 0
        while case .sample = reader.next() { count += 1 }
        #expect(count > 10)
    }

    /// Audio across openings: one continuous run of samples, no overlap and no hole, starting at
    /// the target after a seek.
    @Test func audioReadsOnAcrossFragmentsAsOneRun() async throws {
        let dir = try temporaryFolder("replay-audio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent("camera.mov"))
        var probe = FragmentProbe(url: movie.url)
        #expect(await writeFragments(movie, &probe, more: 1))
        let reader = GrowingTrackReader(media: .audio, trackIndex: 1, offsetS: 0)
        reader.restart(at: 0.4, in: try await LoadedMovie.load(movie.url))
        var buffers: [CMSampleBuffer] = []
        func drain() { while case let .sample(sample) = reader.next() { buffers.append(sample) } }
        drain()
        #expect(await writeFragments(movie, &probe, more: 1))
        let grown = try await LoadedMovie.load(movie.url)
        reader.grow(to: grown)
        drain()
        let starts = buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        let ends = buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds + CMSampleBufferGetDuration($0).seconds }
        #expect(abs(starts[0] - 0.4) < 1.0 / 48_000 + 1e-9)
        let joints = zip(ends, starts.dropFirst()).map { abs($1 - $0) }
        #expect(joints.allSatisfy { $0 < 1.5 / 48_000 }, "largest joint \(joints.max() ?? 0)")
        let format = try #require(CMSampleBufferGetFormatDescription(buffers[0]))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32)
        let audioRange = try await grown.tracks[1].load(.timeRange)
        #expect((ends.last ?? 0) > audioRange.end.seconds - 0.05, "audio ends \(ends.last ?? 0), track \(audioRange.end.seconds), movie \(grown.durationS)")
        await movie.finish()
    }

    /// The engine on a growing movie: it opens once the movie has its header, reads what is
    /// written as fragments land, and never plays past what can be read.
    @Test func theEngineFollowsAGrowingMovie() async throws {
        let dir = try temporaryFolder("replay-engine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let startedAt = HostClock.nowNs()
        let movie = try TestMovieWriter(url: dir.appendingPathComponent(SessionFolder.screenFileName))
        var info = ReplayTakeInfo()
        info.startedAtHostNs = startedAt
        info.firstPtsHostNs = [.screen: startedAt + 10_000_000]
        let engine = ReplayEngine(files: ReplayTakeFiles(folder: dir, files: [.screen]), isLive: true, info: info,
                                  video: [])
        engine.start(at: 0, play: false)
        var probe = FragmentProbe(url: movie.url)
        #expect(await writeFragments(movie, &probe, more: 1))
        #expect(await waitFor(3) { engine.snapshot.ready })
        let first = engine.snapshot.edge.availableS
        #expect(first > 0.5)
        #expect(await writeFragments(movie, &probe, more: 2))
        #expect(await waitFor(3) { engine.snapshot.edge.availableS >= first + 3.5 })
        let snapshot = engine.snapshot
        #expect(snapshot.edge.isLive)
        #expect(snapshot.edge.playableEndS == snapshot.edge.availableS - LiveEdge.guardS)
        // A seek past what is readable stops at the end of it. (A fragment of the media the writer
        // still had may land later: the end only moves on.)
        let endBefore = engine.snapshot.edge.playableEndS
        engine.seek(to: 10_000, play: false)
        #expect(await waitFor(2) { engine.snapshot.positionS >= endBefore - 0.05 }, "\(engine.snapshot)")
        #expect(engine.snapshot.positionS <= engine.snapshot.edge.playableEndS + 0.01)
        engine.close()
        await movie.finish()
    }

    /// Both mode, the camera disconnected mid-take: camera.mov is finished while screen.mov goes on.
    /// The finished movie no longer holds the replay back, and once both are finished the take
    /// plays to the end of the longer one.
    @Test func aMovieThatEndsEarlyDoesNotHoldTheReplayBack() async throws {
        let dir = try temporaryFolder("replay-ends-early")
        defer { try? FileManager.default.removeItem(at: dir) }
        let screen = try TestMovieWriter(url: dir.appendingPathComponent(SessionFolder.screenFileName), withAudio: false)
        let camera = try TestMovieWriter(url: dir.appendingPathComponent(SessionFolder.cameraFileName), withAudio: false)
        var screenProbe = FragmentProbe(url: screen.url)
        var cameraProbe = FragmentProbe(url: camera.url)
        #expect(await writeFragments(screen, &screenProbe, more: 1))
        #expect(await writeFragments(camera, &cameraProbe, more: 1))
        var info = ReplayTakeInfo()
        info.startedAtHostNs = HostClock.nowNs()
        let engine = ReplayEngine(files: ReplayTakeFiles(folder: dir, files: [.screen, .camera]), isLive: true, info: info,
                                  video: [])
        engine.start(at: 0, play: false)
        #expect(await waitFor(3) { engine.snapshot.ready })
        // The camera's file finishes early.
        await camera.finish()
        let cameraEnd = camera.writtenS
        #expect(await writeFragments(screen, &screenProbe, more: 3))
        #expect(screen.writtenS > cameraEnd + 4)
        #expect(await waitFor(3) { engine.snapshot.edge.availableS > cameraEnd + 3 }, "\(engine.snapshot.edge)")
        #expect(engine.snapshot.edge.isLive)
        // A seek past the camera's end plays screen.mov there.
        engine.seek(to: cameraEnd + 2.5, play: false)
        #expect(await waitFor(2) { abs(engine.snapshot.positionS - (cameraEnd + 2.5)) < 0.05 })
        // Both finished: nothing grows, the replay plays to the end of screen.mov.
        await screen.finish()
        #expect(await waitFor(3) { !engine.snapshot.edge.isLive && abs(engine.snapshot.edge.availableS - screen.writtenS) < 0.1 },
                "\(engine.snapshot.edge), screen \(screen.writtenS)")
        engine.close()
    }

    /// A take whose folder holds no movie (moved or deleted) says so instead of opening forever.
    @Test func aTakeWithoutMoviesSaysSo() async throws {
        let dir = try temporaryFolder("replay-no-movies")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = ReplayTakeFiles.find(in: dir.appendingPathComponent("moved"))
        #expect(files.files.isEmpty)
        let engine = ReplayEngine(files: files, isLive: false, info: ReplayTakeInfo(), video: [])
        engine.start(at: nil, play: true)
        #expect(await waitFor(2) { engine.snapshot.problem != nil })
        #expect(engine.snapshot.problem?.contains("moved or deleted") == true)
        #expect(!engine.snapshot.ready)
        engine.close()
    }

    /// A finished take opens at once, at the asked position, and its edge is the whole movie.
    @Test func theEngineOpensAFinishedTake() async throws {
        let dir = try temporaryFolder("replay-finished")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent(SessionFolder.cameraFileName))
        movie.write(seconds: 3)
        await movie.finish()
        let engine = ReplayEngine(files: ReplayTakeFiles.find(in: dir), isLive: false, info: ReplayTakeInfo(), video: [])
        #expect(ReplayTakeFiles.find(in: dir).files == [.camera])
        engine.start(at: 1.25, play: false)
        #expect(await waitFor(3) { engine.snapshot.ready })
        let snapshot = engine.snapshot
        #expect(!snapshot.edge.isLive)
        #expect(abs(snapshot.edge.availableS - movie.writtenS) < 0.1)
        #expect(abs(snapshot.positionS - 1.25) < 0.01)
        #expect(!snapshot.playing && snapshot.problem == nil)
        engine.setSound(true)
        #expect(await waitFor(1) { engine.snapshot.soundOn })
        engine.close()
    }

    /// The transport on a saved take at 2x with Skip silence: it starts at the first speech,
    /// jumps over the pause, and stops at the end of the last speech.
    @Test func theTransportSkipsSilenceAndStopsAtTheEnd() async throws {
        let dir = try temporaryFolder("replay-transport")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent(SessionFolder.screenFileName), withAudio: false)
        movie.write(seconds: 8)
        await movie.finish()
        let engine = ReplayEngine(files: ReplayTakeFiles.find(in: dir), isLive: false, info: ReplayTakeInfo(), video: [])
        engine.setPlan(ReplayEngine.Plan(speech: [TimeSpan(0.5, 1.5), TimeSpan(5, 6)], skipSilence: true))
        engine.setSpeed(2)
        engine.start(at: 0, play: true)
        var seen: [Double] = []
        let done = await waitFor(6) {
            let s = engine.snapshot
            if s.ready { seen.append(s.positionS) }
            return s.ended
        }
        #expect(done)
        let snapshot = engine.snapshot
        #expect(!snapshot.playing)
        #expect(abs(snapshot.positionS - 6.25) < 0.3, "stopped at \(snapshot.positionS)")
        // Never inside the skipped pause [1.75, 4.75] (a tick of slack on each side).
        #expect(!seen.contains { $0 > 2.0 && $0 < 4.6 }, "\(seen)")
        #expect(seen.contains { $0 >= 4.75 })
        engine.close()
    }

    /// A take that records, played at 2x from its start: the replay catches up, goes on at 1x
    /// behind live, waits at the end of what is written, and plays on once the next fragment lands.
    @Test func theTransportCatchesUpWaitsAtTheEdgeAndPlaysOn() async throws {
        let dir = try temporaryFolder("replay-live-transport")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try TestMovieWriter(url: dir.appendingPathComponent(SessionFolder.screenFileName), withAudio: false)
        var probe = FragmentProbe(url: movie.url)
        #expect(await writeFragments(movie, &probe, more: 3))
        // The take began as long ago as the media written: the recording is "now".
        var info = ReplayTakeInfo()
        info.startedAtHostNs = HostClock.nowNs() - UInt64(movie.writtenS * 1e9)
        let engine = ReplayEngine(files: ReplayTakeFiles(folder: dir, files: [.screen]), isLive: true, info: info, video: [])
        engine.setSpeed(2)
        engine.start(at: 0, play: true)
        #expect(await waitFor(3) { engine.snapshot.ready })
        // Caught up: plays at 1x although 2x is picked. (Here the readable end is the limit, as
        // with a late fragment: the media was written faster than real time.)
        #expect(await waitFor(6) { let s = engine.snapshot; return s.speed == 2 && s.playingSpeed == 1 })
        // At the end of what is written: it waits.
        #expect(await waitFor(6) { engine.snapshot.holding })
        let waitedAt = engine.snapshot.positionS
        #expect(waitedAt <= engine.snapshot.edge.playableEndS + 0.05)
        #expect(engine.snapshot.playing)
        // The next fragment lands: it plays on.
        #expect(await writeFragments(movie, &probe, more: 1))
        #expect(await waitFor(4) { let s = engine.snapshot; return !s.holding && s.positionS > waitedAt + 0.3 })
        engine.close()
        await movie.finish()
    }
}
