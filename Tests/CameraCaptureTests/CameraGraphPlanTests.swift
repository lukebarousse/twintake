import Testing
@testable import CameraCapture

private let camLinkAudio = "camlink-audio"

private func wanted(recording: Bool, preview: Bool, keep: Bool, audio: String? = camLinkAudio,
                    meters: Bool = false) -> CameraGraphPlan? {
    CameraGraphPlan.wanted(recording: recording, previewWanted: preview, keepPreviewWhileRecording: keep, audioDeviceUID: audio,
                           idleMeters: meters)
}

private func step(_ from: CameraGraphPlan?, _ to: CameraGraphPlan?) -> CameraGraphStep {
    CameraGraphStep.from(from, to: to)
}

/// Which inputs and outputs the camera session holds. The orange microphone indicator follows the
/// audio input: while idle, only the metered preview holds it (the meters run whenever a view shows
/// the camera, and the microphone is allowed); a take always does when the config names one.
@Suite struct CameraGraphPlanTests {
    /// The idle meters off (no microphone access yet, or no meters wanted): the plain preview.
    @Test func idleWithAViewAndNoMetersIsThePreviewGraphWithoutAudio() {
        for keep in [true, false] {
            let plan = wanted(recording: false, preview: true, keep: keep)
            #expect(plan == .preview)
            #expect(plan?.hasAudioInput == false && plan?.hasAudioMeter == false)
            #expect(plan?.hasMovieOutput == false)
            #expect(plan?.hasPreviewOutput == true)
            #expect(plan?.shape == .preview)
        }
    }

    /// Luke's rule: the meters show before recording whenever the camera preview is on, so the
    /// idle graph holds the camera audio input (the Cam Link's HDMI audio) and the meter.
    @Test func idleWithAViewAndMetersHoldsTheCameraAudio() {
        for keep in [true, false] {
            let plan = wanted(recording: false, preview: true, keep: keep, meters: true)
            #expect(plan == .meteredPreview)
            #expect(plan == CameraGraphPlan([.previewOutput, .audioInput, .audioMeter]))
            #expect(plan?.hasAudioInput == true && plan?.hasAudioMeter == true)
            #expect(plan?.hasMovieOutput == false)
            #expect(plan?.shape == .preview)
        }
        // No camera audio input in the config: nothing to meter.
        #expect(wanted(recording: false, preview: true, keep: false, audio: nil, meters: true) == .preview)
        #expect(CameraGraphPlan.preview(meters: true) == .meteredPreview && CameraGraphPlan.preview(meters: false) == .preview)
    }

    @Test func idleWithoutAViewClosesTheCamera() {
        #expect(wanted(recording: false, preview: false, keep: true) == nil)
        #expect(wanted(recording: false, preview: false, keep: false, audio: nil) == nil)
        // The meters never keep the camera open by themselves.
        #expect(wanted(recording: false, preview: false, keep: false, meters: true) == nil)
    }

    /// The meters are an idle part: a take records the camera mic through its own outputs.
    @Test func aTakeNeverHoldsTheIdleMeter() {
        for keep in [true, false] {
            for meters in [true, false] {
                let plan = wanted(recording: true, preview: true, keep: keep, meters: meters)
                #expect(plan?.hasAudioMeter == false && plan?.hasAudioInput == true && plan?.shape == .recording)
            }
        }
    }

    @Test func theMeterJoinsAndLeavesWithTheAudioInput() {
        #expect(CameraGraphPlan.preview.withMeters(true) == .meteredPreview)
        #expect(CameraGraphPlan.meteredPreview.withMeters(false) == .preview)
        #expect(CameraGraphPlan.meteredPreview.withMeters(true) == .meteredPreview)
        // A preview whose preview output could not be added keeps that.
        #expect(CameraGraphPlan([]).withMeters(true) == CameraGraphPlan([.audioInput, .audioMeter]))
        // A recording graph never changes its meters.
        let take = CameraGraphPlan.recording(audioDeviceUID: camLinkAudio, previewOutput: true)
        #expect(take.withMeters(true) == take && take.withMeters(false) == take)
        #expect(CameraGraphStep.from(.preview, to: .meteredPreview) == .change(add: [.audioInput, .audioMeter], remove: []))
        #expect(CameraGraphStep.from(.meteredPreview, to: .preview) == .change(add: [], remove: [.audioInput, .audioMeter]))
    }

    @Test func recordingAddsTheAudioInputAndTheMovieOutput() {
        let dropped = wanted(recording: true, preview: true, keep: false)
        #expect(dropped == CameraGraphPlan([.audioInput, .movieOutput]))
        #expect(dropped?.shape == .recording)
        // The camera window stays live during the take.
        #expect(wanted(recording: true, preview: true, keep: true) == CameraGraphPlan([.audioInput, .movieOutput, .previewOutput]))
        // Keep is on, but no view shows the camera: no preview output.
        #expect(wanted(recording: true, preview: false, keep: true) == CameraGraphPlan([.audioInput, .movieOutput]))
        // Audio is No audio: no audio input, so no mic indicator even while recording.
        #expect(wanted(recording: true, preview: true, keep: false, audio: nil) == CameraGraphPlan([.movieOutput]))
    }

    @Test func recordingPlanMatchesWanted() {
        for keep in [true, false] {
            for audio in [camLinkAudio, nil] {
                #expect(CameraGraphPlan.recording(audioDeviceUID: audio, previewOutput: keep)
                    == wanted(recording: true, preview: true, keep: keep, audio: audio))
            }
        }
    }

    @Test func descriptionNamesEveryPart() {
        #expect(CameraGraphPlan.preview.description == "preview (video_input, preview_output)")
        #expect(CameraGraphPlan.meteredPreview.description == "preview (video_input, audio_input, audio_meter, preview_output)")
        #expect(CameraGraphPlan([.previewOutput, .movieOutput, .audioInput]).description
            == "recording (video_input, audio_input, movie_output, preview_output)")
    }
}

/// How the session goes from one graph to the next: Start upgrades the open preview camera, a
/// failed upgrade goes back, and Stop goes back to the preview graph.
@Suite struct CameraGraphStepTests {
    let take = CameraGraphPlan.recording(audioDeviceUID: camLinkAudio, previewOutput: false)
    let liveTake = CameraGraphPlan.recording(audioDeviceUID: camLinkAudio, previewOutput: true)

    @Test func upgradeAtStartIsOneChange() {
        #expect(step(.preview, take) == .change(add: [.audioInput, .movieOutput], remove: [.previewOutput]))
        #expect(step(.preview, liveTake) == .change(add: [.audioInput, .movieOutput], remove: []))
        let silent = CameraGraphPlan.recording(audioDeviceUID: nil, previewOutput: false)
        #expect(step(.preview, silent) == .change(add: [.movieOutput], remove: [.previewOutput]))
    }

    /// From the metered preview, Start keeps the camera audio input (no clock change at Start):
    /// it adds only the recording outputs and drops the idle meter. Stop goes back the same way.
    @Test func theMeteredPreviewKeepsTheAudioInputAcrossTheTake() {
        #expect(step(.meteredPreview, take) == .change(add: [.movieOutput], remove: [.audioMeter, .previewOutput]))
        #expect(step(.meteredPreview, liveTake) == .change(add: [.movieOutput], remove: [.audioMeter]))
        #expect(step(liveTake, .meteredPreview) == .change(add: [.audioMeter], remove: [.movieOutput]))
        #expect(step(take, .meteredPreview) == .change(add: [.audioMeter, .previewOutput], remove: [.movieOutput]))
        for from in [take, liveTake] {
            guard case let .change(add, remove) = step(.meteredPreview, from), case let .change(back, _) = step(from, .meteredPreview) else {
                Issue.record("expected changes")
                continue
            }
            #expect(!add.contains(.audioInput) && !remove.contains(.audioInput) && back.contains(.audioMeter))
        }
        // A failed upgrade goes back to the metered preview.
        #expect(step(.meteredPreview, take).undo == step(take, .meteredPreview))
    }

    @Test func aFailedUpgradeGoesBackToThePreviewGraph() {
        let upgrade = step(.preview, take)
        #expect(upgrade.undo == step(take, .preview))
        #expect(upgrade.undo == .change(add: [.previewOutput], remove: [.audioInput, .movieOutput]))
        #expect(step(.preview, liveTake).undo == .change(add: [], remove: [.audioInput, .movieOutput]))
        #expect(CameraGraphStep.none.undo == .none)
        #expect(CameraGraphStep.tearDown.undo == .none)
        #expect(CameraGraphStep.build(.preview).undo == .none)
    }

    @Test func stopGoesBackWithoutTheMic() {
        // The camera window stayed live during the take: only the mic and the movie output leave.
        #expect(step(liveTake, .preview) == .change(add: [], remove: [.audioInput, .movieOutput]))
        // Start dropped the preview output: it joins again.
        #expect(step(take, .preview) == .change(add: [.previewOutput], remove: [.audioInput, .movieOutput]))
        for from in [take, liveTake] {
            guard case let .change(add, remove) = step(from, .preview) else {
                Issue.record("expected a change")
                continue
            }
            #expect(remove.contains(.audioInput) && !add.contains(.audioInput))
        }
    }

    @Test func openAndClose() {
        #expect(step(nil, .preview) == .build(.preview))
        #expect(step(nil, take) == .build(take))
        #expect(step(.preview, nil) == .tearDown)
        #expect(step(take, nil) == .tearDown)
        #expect(step(nil, nil) == .none)
        #expect(step(.preview, .preview) == .none)
        #expect(step(take, take) == .none)
    }

    @Test func neverChangesWhileTheFileIsWritten() {
        let back = step(take, .preview)
        #expect(!back.allowed(whileWritingFile: true))
        #expect(back.allowed(whileWritingFile: false))
        #expect(!step(.preview, take).allowed(whileWritingFile: true))
        #expect(CameraGraphStep.none.allowed(whileWritingFile: true))
        // A teardown stops the file first.
        #expect(CameraGraphStep.tearDown.allowed(whileWritingFile: true))
    }

    /// Idle, then a take, then idle again with the camera window on. Without the idle meters the
    /// audio input exists only for the take; with them it stays from the preview through the take
    /// and after it. Either way Stop undoes exactly what Start did.
    @Test func theMicIsInTheSessionForTheTakeAndTheIdleMeters() {
        for keep in [true, false] {
            for meters in [true, false] {
                let idle = wanted(recording: false, preview: true, keep: keep, meters: meters)
                let recording = wanted(recording: true, preview: true, keep: keep, meters: meters)
                let after = wanted(recording: false, preview: true, keep: keep, meters: meters)
                #expect(idle?.hasAudioInput == meters)
                #expect(recording?.hasAudioInput == true)
                #expect(after?.hasAudioInput == meters)
                #expect(step(recording, after) == step(idle, recording).undo)
            }
        }
        // The window was hidden during the take and nothing wants the camera after it: it closes.
        let recording = wanted(recording: true, preview: false, keep: false)
        #expect(step(recording, wanted(recording: false, preview: false, keep: false)) == .tearDown)
    }
}

@Suite struct CameraGraphChangeTests {
    @Test func upgradeEvent() {
        let change = CameraGraphChange(from: .preview, to: .recording(audioDeviceUID: camLinkAudio, previewOutput: false),
                                       durationNs: 312_400_000, formatReset: false,
                                       negotiatedFormat: "3840x2160 420v 23.976", audioDevice: "Cam Link 4K")
        #expect(change.milliseconds == 312)
        #expect(change.eventData == ["source": "camera", "from": "preview", "to": "recording", "ms": "312",
                                     "audio_input": "on", "audio_meter": "off", "preview_output": "off",
                                     "format": "3840x2160 420v 23.976", "format_reset": "false", "audio_device": "Cam Link 4K"])
        #expect(change.logLine
            == "preview -> recording in 312 ms: recording (video_input, audio_input, movie_output), 3840x2160 420v 23.976")
    }

    @Test func downgradeAndBuildEvents() {
        let back = CameraGraphChange(from: .recording(audioDeviceUID: camLinkAudio, previewOutput: true), to: .preview,
                                     durationNs: 80_000_000, formatReset: true, negotiatedFormat: "3840x2160 420v 23.976")
        #expect(back.eventData["from"] == "recording" && back.eventData["to"] == "preview")
        #expect(back.eventData["audio_input"] == "off" && back.eventData["preview_output"] == "on")
        #expect(back.eventData["format_reset"] == "true")
        #expect(back.eventData["audio_device"] == nil)
        #expect(back.logLine.hasSuffix("(format set again)"))
        let built = CameraGraphChange(from: nil, to: .preview, durationNs: 1_500_000_000, formatReset: false,
                                      negotiatedFormat: "1920x1080 420v 23.976")
        #expect(built.eventData["from"] == "closed")
        #expect(built.eventData["ms"] == "1500")
        #expect(built.eventData["audio_meter"] == "off")
        let metered = CameraGraphChange(from: .recording(audioDeviceUID: camLinkAudio, previewOutput: true), to: .meteredPreview,
                                        durationNs: 50_000_000, formatReset: false, negotiatedFormat: "3840x2160 420v 23.976",
                                        audioDevice: "Cam Link 4K")
        #expect(metered.eventData["audio_input"] == "on" && metered.eventData["audio_meter"] == "on"
            && metered.eventData["to"] == "preview" && metered.eventData["audio_device"] == "Cam Link 4K")
        #expect(metered.logLine == "recording -> preview in 50 ms: preview (video_input, audio_input, audio_meter, preview_output), "
            + "3840x2160 420v 23.976")
    }
}

/// Stop waits for the return to the preview graph, but never without a limit: a camera queue stuck
/// in a session change must not hold the app in "Saving…".
@Suite struct ReturnToPreviewLimitTests {
    actor Flag {
        var done = false
        func set() { done = true }
    }

    @Test func waitsForAQuickChange() async {
        let flag = Flag()
        await CameraRecorder.waitAtMost(5) { await flag.set() }
        #expect(await flag.done)
    }

    @Test func givesUpWhenTheChangeHangs() async {
        let clock = ContinuousClock()
        let began = clock.now
        await CameraRecorder.waitAtMost(0.1) { try? await Task.sleep(for: .seconds(5)) }
        #expect(clock.now - began < .seconds(3))
        #expect(CameraRecorder.returnToPreviewLimit <= 5)
    }
}
