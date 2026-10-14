import Foundation
import Testing
@testable import RecorderCore
@testable import Replay

private func spans(_ pairs: [(Double, Double)]) -> [TimeSpan] { pairs.map { TimeSpan($0.0, $0.1) } }

@Suite struct SpanMathTests {
    @Test func mergeSortsAndJoinsOverlapsAndSmallGaps() {
        let input = spans([(5, 6), (0, 1), (0.5, 2), (2.2, 3), (10, 11)])
        #expect(SpanMath.merged(input) == spans([(0, 2), (2.2, 3), (5, 6), (10, 11)]))
        #expect(SpanMath.merged(input, joiningGapsUpTo: 0.5) == spans([(0, 3), (5, 6), (10, 11)]))
        #expect(SpanMath.merged([]) == [])
        #expect(SpanMath.merged(spans([(1, .infinity), (0, 1)])) == spans([(0, 1)]))
    }

    @Test func intersectionKeepsTheTimeBothCover() {
        let a = spans([(0, 5), (8, 12)]), b = spans([(3, 9), (11, 20)])
        #expect(SpanMath.intersection(a, b) == spans([(3, 5), (8, 9), (11, 12)]))
        #expect(SpanMath.intersection(a, []) == [])
    }

    @Test func lookupsUseTheSortedSpans() {
        let s = spans([(1, 2), (4, 6), (9, 10)])
        #expect(SpanMath.span(containing: 5, in: s) == TimeSpan(4, 6))
        #expect(SpanMath.span(containing: 3, in: s) == nil)
        #expect(SpanMath.span(containing: 3.99, in: s, tolerance: 0.02) == TimeSpan(4, 6))
        #expect(SpanMath.span(containing: 6, in: s) == nil)  // The end is open.
        #expect(SpanMath.nextStart(after: 0, in: s) == 1)
        #expect(SpanMath.nextStart(after: 1.5, in: s) == 4)
        #expect(SpanMath.nextStart(after: 7, in: s) == 9)
        #expect(SpanMath.nextStart(after: 9.5, in: s) == nil)
        #expect(SpanMath.total(s) == 4)
    }
}

@Suite struct SkipSilenceTests {
    /// Luke's rule: jump over pauses longer than ~1 s, keep ~0.25 s around speech.
    @Test func pausesOverOneSecondAreSkippedWithAQuarterSecondKept() {
        let speech = spans([(2, 4), (4.6, 6), (9, 10), (10.9, 12)])
        let kept = SkipSilence.keptSpans(speech: speech)
        // 4 -> 4.6 (0.6 s) and 10 -> 10.9 (0.9 s) play; 6 -> 9 (3 s) is cut down to 0.25 s each side.
        #expect(kept == spans([(1.75, 6.25), (8.75, 12.25)]))
        let mask = PlaybackMask.make(silence: kept, flags: nil)
        #expect(mask.decision(at: 5, playableEnd: 100) == .play)
        #expect(mask.decision(at: 6.3, playableEnd: 100) == .jump(to: 8.75))
        #expect(mask.decision(at: 0, playableEnd: 100) == .jump(to: 1.75))
        #expect(mask.decision(at: 13, playableEnd: 100) == .end)
    }

    @Test func aPauseJustOverTheLimitSkipsHalfASecond() {
        let kept = SkipSilence.keptSpans(speech: spans([(0, 1), (2.01, 3)]))
        #expect(kept.count == 2)
        #expect(abs(kept[1].start - kept[0].end - 0.51) < 1e-9)
    }

    @Test func paddingNeverGoesBeforeTheTake() {
        #expect(SkipSilence.keptSpans(speech: spans([(0.1, 1)])) == spans([(0, 1.25)]))
        #expect(SkipSilence.keptSpans(speech: []) == [])
    }

    @Test func speechComesFromTheVoiceTimelineInTakeTime() {
        let origin: UInt64 = 5_000_000_000
        let timeline = VoiceTimeline(cameraMic: [VoiceSegment(startNs: origin + 1_000_000_000, endNs: origin + 2_500_000_000),
                                                 VoiceSegment(startNs: origin - 500_000_000, endNs: origin + 200_000_000)],
                                     cameraMicVoicedS: 2)
        #expect(SkipSilence.speech(timeline, startedAtHostNs: origin) == spans([(1, 2.5), (0, 0.2)]))
    }
}

@Suite struct PlaybackMaskTests {
    /// Skip silence before any speech was heard plays everything, not nothing (it would jump to
    /// live at once); Flags only without a flag plays nothing.
    @Test func theEnginePlanFallsBackWithoutSpeech() {
        #expect(ReplayEngine.Plan(speech: [], skipSilence: true).mask == .everything)
        #expect(ReplayEngine.Plan(speech: spans([(1, 2)]), skipSilence: true).mask == PlaybackMask(spans: spans([(0.75, 2.25)])))
        #expect(ReplayEngine.Plan(flags: [], flagsOnly: true).mask == PlaybackMask(spans: []))
        #expect(PlaybackMask(spans: []).decision(at: 3, playableEnd: 100) == .end)
        let both = ReplayEngine.Plan(speech: spans([(1, 2), (50, 52)]), flags: [FlagMark(atS: 55, lookbackS: 10)],
                                     skipSilence: true, flagsOnly: true)
        #expect(both.mask == PlaybackMask(spans: spans([(49.75, 52.25)])))
    }

    @Test func everythingPlaysWithoutAToggle() {
        #expect(PlaybackMask.make(silence: nil, flags: nil) == .everything)
        #expect(PlaybackMask.everything.decision(at: 12, playableEnd: 13) == .play)
        #expect(PlaybackMask.everything.firstPlayable(atOrAfter: 4) == 4)
        #expect(PlaybackMask.everything.playableSeconds(upTo: 30) == 30)
    }

    @Test func bothTogglesPlayOnlyTheSpeechInsideFlagStretches() {
        let mask = PlaybackMask.make(silence: spans([(0, 10), (20, 30)]), flags: spans([(5, 25)]))
        #expect(mask.spans == spans([(5, 10), (20, 25)]))
        #expect(mask.decision(at: 12, playableEnd: 100) == .jump(to: 20))
        #expect(mask.playableSeconds(upTo: 22) == 7)
    }

    /// Play after the end: on from there when a flag that came in since made its stretch longer
    /// (Flags only on a take that records); else the next part; else from the first part.
    @Test func playAfterTheEndGoesOnWhenMorePlaysNow() {
        // Flag A at 20:00 (3 min look-back): [17:00, 20:10]. The replay ended at 20:10.
        let a = FlagMark(atS: 1200, lookbackS: 180)
        let before = PlaybackMask(spans: FlagsOnly.spans([a]))
        #expect(before.decision(at: 1210.03, playableEnd: 1290) == .end)
        #expect(before.resumeAfterEnd(at: 1210.03, playableEnd: 1290) == .jump(to: 1020))
        // Flag B at 21:30 merges into [17:00, 21:40]: Play goes on at 20:10, not back to 17:00.
        let after = PlaybackMask(spans: FlagsOnly.spans([a, FlagMark(atS: 1290, lookbackS: 180)]))
        #expect(after.resumeAfterEnd(at: 1210.03, playableEnd: 1300) == .here)
        // A later flag that does not overlap: Play goes to its stretch.
        let apart = PlaybackMask(spans: FlagsOnly.spans([a, FlagMark(atS: 1500, lookbackS: 60)]))
        #expect(apart.resumeAfterEnd(at: 1210.03, playableEnd: 1600) == .jump(to: 1440))
        // The end of a finished take: from the start; of a saved take's last speech: the first speech.
        #expect(PlaybackMask.everything.resumeAfterEnd(at: 30, playableEnd: 30) == .jump(to: 0))
        let speech = PlaybackMask(spans: spans([(2, 4), (8, 9)]))
        #expect(speech.resumeAfterEnd(at: 9.01, playableEnd: 12) == .jump(to: 2))
    }

    @Test func aJumpTooSmallPlaysOnAndOnePastTheEndStops() {
        let mask = PlaybackMask(spans: spans([(0, 1), (1.05, 2), (50, 60)]))
        #expect(mask.decision(at: 1.0, playableEnd: 100) == .play)
        // The next span starts after what can be played now (a live take): nothing to jump to yet.
        #expect(mask.decision(at: 3, playableEnd: 40) == .end)
        #expect(mask.decision(at: 3, playableEnd: 100) == .jump(to: 50))
        #expect(mask.firstPlayable(atOrAfter: 2.5) == 50)
        #expect(mask.firstPlayable(atOrAfter: 61) == nil)
    }
}

@Suite struct FlagsOnlyTests {
    @Test func eachFlagPlaysItsLookbackAndTenSecondsAfter() {
        let flags = [FlagMark(atS: 300, lookbackS: 60), FlagMark(atS: 100, lookbackS: 180), FlagMark(atS: 500, lookbackS: 30)]
        // The 100 s flag reaches back past the start: clamped at 0.
        #expect(FlagsOnly.spans(flags) == spans([(0, 110), (240, 310), (470, 510)]))
        let overlapping = [FlagMark(atS: 300, lookbackS: 60), FlagMark(atS: 320, lookbackS: 60)]
        #expect(FlagsOnly.spans(overlapping) == spans([(240, 330)]))
    }

    @Test func nextAndPreviousStepThroughTheFlags() {
        let flags = [FlagMark(atS: 100, lookbackS: 60), FlagMark(atS: 300, lookbackS: 60)]
        #expect(FlagsOnly.next(after: 0, in: flags) == 40)
        #expect(FlagsOnly.next(after: 40, in: flags) == 240)
        #expect(FlagsOnly.next(after: 239.8, in: flags) == nil)
        #expect(FlagsOnly.next(after: 250, in: flags) == nil)
        // Within the first 2 s of a stretch, back goes to the one before; later, to its start.
        #expect(FlagsOnly.previous(before: 250, in: flags) == 240)
        #expect(FlagsOnly.previous(before: 241, in: flags) == 40)
        #expect(FlagsOnly.previous(before: 30, in: flags) == nil)
    }

    /// Flags 30 s apart with a 3 min look-back overlap: Next goes to the first look-back, then to
    /// the first press, where the second flag's new part begins; Previous goes back the same way.
    @Test func nextAndPreviousStepThroughOverlappingFlags() {
        let flags = [FlagMark(atS: 330, lookbackS: 180), FlagMark(atS: 300, lookbackS: 180)]
        #expect(FlagsOnly.starts(flags) == [120, 300])
        #expect(FlagsOnly.next(after: 0, in: flags) == 120)
        // Inside the merged stretch, before both presses: Next still reaches the second flag.
        #expect(FlagsOnly.next(after: 200, in: flags) == 300)
        #expect(FlagsOnly.next(after: 300, in: flags) == nil)
        // Previous never moves forward.
        #expect(FlagsOnly.previous(before: 200, in: flags) == 120)
        #expect(FlagsOnly.previous(before: 320, in: flags) == 300)
        #expect(FlagsOnly.previous(before: 301, in: flags) == 120)
        // A later flag with a short look-back keeps its own start; two presses at once count once.
        let short = [FlagMark(atS: 300, lookbackS: 180), FlagMark(atS: 330, lookbackS: 10)]
        #expect(FlagsOnly.starts(short) == [120, 320])
        #expect(FlagsOnly.starts([FlagMark(atS: 60, lookbackS: 30), FlagMark(atS: 60, lookbackS: 60)]) == [0])
    }

    @Test func aFlagWithoutLookbackPointsAtItself() {
        #expect(FlagMark(atS: 12, lookbackS: -5).spanStart == 12)
        #expect(FlagsOnly.spans([]) == [])
    }
}

@Suite struct LiveEdgeTests {
    @Test func theLiveTargetStaysAboutOneFragmentBehind() {
        // One fragment, a probe interval, the guard and room for the encoder: 3 s.
        #expect(LiveEdge.liveDelayS == 3)
        let edge = LiveEdge(isLive: true, recordedS: 100, availableS: 98.4)
        #expect(abs(edge.playableEndS - 98.15) < 1e-9)
        #expect(edge.liveTargetS == 97)
        #expect(edge.behindS(edge.liveTargetS) == 3)
        #expect(edge.timelineEndS == 100)
        // A late fragment: the target never passes what is readable.
        let late = LiveEdge(isLive: true, recordedS: 100, availableS: 96)
        #expect(late.liveTargetS == 95.75)
    }

    @Test func clampKeepsSeeksInsideWhatCanBePlayed() {
        let edge = LiveEdge(isLive: true, recordedS: 100, availableS: 98)
        #expect(edge.clamp(-3) == 0)
        #expect(edge.clamp(50) == 50)
        #expect(edge.clamp(99) == 97.75)
        #expect(edge.clamp(.nan) == 0)
        let finished = LiveEdge(isLive: false, recordedS: 30, availableS: 30)
        #expect(finished.clamp(31) == 30)
        #expect(finished.liveTargetS == 30)
    }

    @Test func itOpensAtTheLastMinute() {
        #expect(LiveEdge(isLive: true, recordedS: 600, availableS: 599).openingPosition() == 600 - 3 - 60)
        #expect(LiveEdge(isLive: true, recordedS: 20, availableS: 19).openingPosition() == 0)
        #expect(LiveEdge(isLive: false, recordedS: 90, availableS: 90).openingPosition() == 30)
    }

    /// At 1x behind live, the replay waits for a fragment only when the capture and encode latency
    /// is over half a second: a fragment lands about 30 ms after its 2 s of media, and the replay
    /// sees it within one probe interval.
    @Test func atOneXBehindLiveItNeverWaitsForAFragment() {
        let recordedS = 600.0
        let t = recordedS - LiveEdge.liveDelayS
        for latencyS in [0.05, 0.15, 0.3, 0.45] {
            // The worst moment: just before the next fragment is seen. The latency counts from the
            // frame's capture to its fragment in the file.
            let lagS = LiveEdge.fragmentS + LiveEdge.probeIntervalS + latencyS
            let edge = LiveEdge(isLive: true, recordedS: recordedS, availableS: recordedS - lagS)
            #expect(edge.action(at: t, rate: 1, holding: false) == .none, "latency \(latencyS)")
        }
    }

    @Test func theTransportWaitsAtTheEndAndSlowsDownAtLive() {
        let edge = LiveEdge(isLive: true, recordedS: 100, availableS: 98.4)
        #expect(edge.action(at: 90, rate: 2, holding: false) == .none)
        #expect(edge.action(at: 97.3, rate: 2, holding: false) == .realTime)
        #expect(edge.action(at: 97.3, rate: 1, holding: false) == .none)
        #expect(edge.action(at: 98.15, rate: 1, holding: false) == .hold)
        // A late fragment: at 2x it reaches the readable end before the live target slows it
        // down. It waits there (and the engine goes on at 1x: it caught up).
        let late = LiveEdge(isLive: true, recordedS: 100, availableS: 96)
        #expect(late.liveTargetS == late.playableEndS)
        #expect(late.action(at: 95.74, rate: 2, holding: false) == .hold)
        // Waiting: plays on once half a second more is readable.
        #expect(edge.action(at: 98.15, rate: 1, holding: true) == .none)
        let grown = LiveEdge(isLive: true, recordedS: 102, availableS: 100.4)
        #expect(grown.action(at: 98.15, rate: 1, holding: true) == .resume)
        let finished = LiveEdge(isLive: false, recordedS: 30, availableS: 30)
        #expect(finished.action(at: 29.99, rate: 1, holding: false) == .end)
        #expect(finished.action(at: 10, rate: 2, holding: false) == .none)
        #expect(edge.isAtLive(97.0) && !edge.isAtLive(90))
    }
}

@Suite struct MediaAlignmentTests {
    /// Both files begin a few ms after the scheduled start; take time 0 is `started_at_host_ns`.
    @Test func offsetsComeFromTheFirstFrames() {
        let started: UInt64 = 1_000_000_000_000
        let alignment = MediaAlignment(startedAtHostNs: started,
                                       firstPtsHostNs: [.camera: started + 21_000_000, .screen: started + 4_000_000])
        #expect(alignment.originNs == started)
        #expect(abs(alignment.offset(.camera) - 0.021) < 1e-12)
        #expect(abs(alignment.offset(.screen) - 0.004) < 1e-12)
        #expect(abs(alignment.spreadS - 0.017) < 1e-12)
        // Take time 10 s is camera.mov 9.979 s and screen.mov 9.996 s.
        #expect(abs(alignment.fileTime(10, of: .camera) - 9.979) < 1e-9)
        #expect(abs(alignment.takeTime(9.996, of: .screen) - 10) < 1e-9)
        #expect(abs(alignment.takeTime(hostNs: started + 2_500_000_000) - 2.5) < 1e-12)
        #expect(alignment.takeTime(hostNs: started - 1_000_000_000) == -1)
    }

    @Test func unknownStartsFallBack() {
        let noStart = MediaAlignment(startedAtHostNs: nil, firstPtsHostNs: [.camera: 500, .screen: 800])
        #expect(noStart.originNs == 500)
        #expect(noStart.offset(.camera) == 0)
        let none = MediaAlignment(startedAtHostNs: 900, firstPtsHostNs: [:])
        #expect(none.offset(.screen) == 0 && none.spreadS == 0)
    }
}

@Suite struct ReplaySoundTests {
    @Test func soundPlaysTheDialogueAndTheComputerSoundNeverBothMics() {
        let both = [ReplayAudioTrack(file: .screen, trackIndex: 1, role: .mic),
                    ReplayAudioTrack(file: .screen, trackIndex: 2, role: .systemAudio),
                    ReplayAudioTrack(file: .camera, trackIndex: 1, role: .mic)]
        #expect(ReplaySound.tracks(both) == [both[2], both[1]])
        let screenOnly = [both[0], both[1]]
        #expect(ReplaySound.tracks(screenOnly) == screenOnly)
        #expect(ReplaySound.tracks([both[2]]) == [both[2]])
        #expect(ReplaySound.tracks([]) == [])
        #expect(ReplaySound.hint.contains("headphones"))
    }
}

@Suite struct ReplayEventsTests {
    @Test func eventDataUsesOneDecimalSecondsLikeAFlag() {
        #expect(ReplayEvents.startData(elapsedS: 754.24, positionS: 690.0, sound: false, skipSilence: true, flagsOnly: false)
            == ["elapsed_s": "754.2", "position_s": "690.0", "sound": "off", "skip_silence": "on", "flags_only": "off"])
        #expect(ReplayEvents.endData(elapsedS: 800.06, openS: 45.8, soundOnS: 12.04, reason: .closed)
            == ["elapsed_s": "800.1", "open_s": "45.8", "sound_on_s": "12.0", "reason": "closed"])
        #expect(ReplayEvents.soundData(on: true, elapsedS: 760) == ["state": "on", "elapsed_s": "760.0"])
        #expect(ReplayEvents.endData(elapsedS: -1, openS: .nan, soundOnS: 0, reason: .stop)["elapsed_s"] == "0.0")
    }

    /// An editor cuts each replay stretch; a take that stopped with the window open ends at Stop.
    @Test func reviewStretchesPairStartsWithEnds() {
        func event(_ kind: SessionEvent.Kind, _ elapsed: String?) -> SessionEvent {
            SessionEvent(tHostNs: 0, wall: "", type: kind, data: elapsed.map { ["elapsed_s": $0] })
        }
        let events = [event(.sessionStart, nil), event(.replayStart, "60.0"), event(.replaySound, "70.0"),
                      event(.replayEnd, "90.5"), event(.marker, "100.0"), event(.replayStart, "200.0"),
                      event(.sessionStop, nil)]
        #expect(ReplayEvents.reviewStretches(events, endS: 250) == spans([(60, 90.5), (200, 250)]))
        #expect(ReplayEvents.reviewStretches(Array(events.prefix(4))) == spans([(60, 90.5)]))
    }

    /// The recorders' dropped_frames events (camera.mov names its file, screen.mov only its track)
    /// since the replay opened pause it.
    @Test func droppedFramesSinceTheReplayOpened() {
        let camera = SessionEvent(tHostNs: 50, wall: "", type: .droppedFrames,
                                  data: ["file": "camera.mov", "track": "camera_video", "count": "2", "total": "2"])
        let screen = SessionEvent(tHostNs: 80, wall: "", type: .droppedFrames,
                                  data: ["track": "screen_video", "late_frames": "1", "total_late_frames": "1"])
        let other = SessionEvent(tHostNs: 90, wall: "", type: .warning, data: ["track": "screen_video"])
        #expect(ReplayEvents.droppedFrames([camera, screen, other], sinceNs: 0) == [.camera, .screen])
        #expect(ReplayEvents.droppedFrames([camera, screen, other], sinceNs: 60) == [.screen])
        #expect(ReplayEvents.droppedFrames([camera, other], sinceNs: 60) == [])
        #expect(ReplayEvents.droppedFramesNotice([.camera, .screen]) == "Paused: camera.mov and screen.mov dropped frames. Play goes on.")
    }

    @Test func eventKindsAreSnakeCase() {
        #expect(SessionEvent.Kind.replayStart.rawValue == "replay_start")
        #expect(SessionEvent.Kind.replayEnd.rawValue == "replay_end")
        #expect(SessionEvent.Kind.replaySound.rawValue == "replay_sound")
    }

    @Test func clockStrings() {
        #expect(ReplayClock.string(754.9) == "12:34")
        #expect(ReplayClock.string(3723) == "1:02:03")
        #expect(ReplayClock.string(-4) == "0:00")
        #expect(ReplayClock.behindLive(2.8, atLive: false) == "3 s behind live")
        #expect(ReplayClock.behindLive(65, atLive: false) == "1:05 behind live")
    }
}
