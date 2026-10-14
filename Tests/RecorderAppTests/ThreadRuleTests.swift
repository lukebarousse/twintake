import Foundation
import Testing
@testable import RecorderApp

/// Guards the camera thread rule (CameraCapture/CaptureThreads.swift) at the source level: the
/// main-actor app code and the preview view never name a capture session, its inputs, outputs or
/// connections, a session-backed preview layer or device locking, and nothing waits for a queue.
@Suite struct ThreadRuleTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let forbidden = [
        "AVCaptureSession", "AVCaptureVideoPreviewLayer", "AVCaptureConnection", "AVCaptureDeviceInput",
        "AVCaptureOutput", "AVCaptureMovieFileOutput", "AVCaptureVideoDataOutput", "AVCaptureDevice(",
        "AVCaptureDevice.DiscoverySession", "lockForConfiguration", "DispatchSemaphore", ".sync {", ".sync(",
        "waitUntilDone", "CaptureDevices.videoDevices", "CaptureDevices.audioDevices", "CaptureDevices.default",
        "CaptureDevices.formats", "CaptureDevices.inventory()",
    ]

    /// Code lines of a file, without comments.
    static func codeLines(_ url: URL) throws -> [(Int, String)] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated().compactMap { i, line in
            let code = line.components(separatedBy: "//").first ?? ""
            return code.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (i + 1, code)
        }
    }

    static func violations(in files: [URL]) throws -> [String] {
        var found: [String] = []
        for file in files {
            for (number, line) in try codeLines(file) {
                for word in forbidden where line.contains(word) {
                    found.append("\(file.lastPathComponent):\(number): \(word)")
                }
            }
        }
        return found
    }

    @Test func appCodeNeverTouchesCaptureObjects() throws {
        let folder = Self.root.appendingPathComponent("Sources/RecorderApp")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 8)
        #expect(try Self.violations(in: files) == [])
    }

    @Test func previewViewHoldsNoCaptureObject() throws {
        let files = ["CameraPreviewView.swift"].map { Self.root.appendingPathComponent("Sources/CameraCapture/\($0)") }
        #expect(try Self.violations(in: files) == [])
    }

    /// The camera window and the device rematch are main-thread code: they are in the scan above,
    /// and this makes sure a rename never drops them from it.
    @Test func cameraWindowCodeIsScanned() throws {
        let folder = Self.root.appendingPathComponent("Sources/RecorderApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        for name in ["CameraWindow.swift", "DeviceRematch.swift", "SessionCoordinator.swift", "MenuContentView.swift",
                     "ControlBar.swift", "ControlBarRules.swift"] {
            #expect(names.contains(name))
        }
        let files = ["CameraWindow.swift", "DeviceRematch.swift", "ControlBar.swift", "ControlBarRules.swift"]
            .map { folder.appendingPathComponent($0) }
        #expect(try Self.violations(in: files) == [])
    }

    /// Window snapping, the overlay, hotkeys and the camera window geometry run on the main thread.
    @Test func windowToolsNeverTouchCaptureObjects() throws {
        let folder = Self.root.appendingPathComponent("Sources/WindowTools")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "CameraWindowGeometry.swift" })
        #expect(try Self.violations(in: files) == [])
    }

    /// The feed's attach and detach run on the main thread and its enqueue on the data output's
    /// queue: neither may wait. (The feed names the capture delegate types, so only the waits are
    /// checked here.)
    @Test func previewFeedNeverWaits() throws {
        let waits = ["DispatchSemaphore", ".sync {", ".sync(", "waitUntilDone", ".wait(", "lockForConfiguration",
                     "AVCaptureSession"]
        let files = ["CameraPreviewFeed.swift", "CameraPreviewView.swift"]
            .map { Self.root.appendingPathComponent("Sources/CameraCapture/\($0)") }
        var found: [String] = []
        for file in files {
            for (number, line) in try Self.codeLines(file) {
                for word in waits where line.contains(word) { found.append("\(file.lastPathComponent):\(number): \(word)") }
            }
        }
        #expect(found == [])
    }

    /// Inputs and outputs join or leave a session only while it is built, in one graph change, in
    /// `detachPreview()` before the file, or at teardown: never while camera.mov is written.
    /// Graph changes run at prepare (the upgrade, before the file), in stop() after the file has
    /// finished (the return to the preview graph), and in setIdleMeters() on the idle preview graph
    /// only; the change itself refuses a file in progress.
    @Test func graphChangesOnlyOutsideAFile() throws {
        let url = Self.root.appendingPathComponent("Sources/CameraCapture/CameraRecorder.swift")
        let code = try Self.codeLines(url).map(\.1)
        let adds = code.filter { $0.contains("addPreviewOutput(") }
        let removes = code.filter { $0.contains("detachPreview()") }
        #expect(adds.count == 3)  // The definition, the call in build() and the one in change(to:preview:).
        #expect(removes.count == 2)  // The definition and the one call in start(), before the file.
        #expect(removes.contains { $0.contains("if !keepPreview { graph.detachPreview() }") })

        let changes = code.filter { $0.contains("graph.change(to:") }
        #expect(changes.count == 3)  // upgrade(), returnToPreview() and setIdleMeters().
        #expect(changes.contains { $0.contains("graph.change(to: wanted, preview: preview)") })
        #expect(changes.contains { $0.contains("graph.change(to: .preview(meters: meters), preview: feed)") })
        #expect(changes.contains { $0.contains("graph.change(to: graph.plan.withMeters(on), preview: nil)") })
        // The idle meters change only the idle preview graph, never a take's.
        let meters = try #require(code.firstIndex { $0.contains("public func setIdleMeters(_ on: Bool) async throws -> Bool") })
        let meterBody = Array(code[meters...].prefix(20))
        #expect(meterBody.contains { $0.contains("if preparing || reconnecting || controller?.isActive == true || snapshot?.plan.shape != .preview") })
        #expect(meterBody.contains { $0.contains("guard graph.plan.shape == .preview, allowed, !on || graph.mayMeterIdle() else {") })
        #expect(code.contains { $0.contains("guard step.allowed(whileWritingFile: movie?.controller.isActive ?? false)") })
        #expect(code.contains { $0.contains("guard let tap = previewTap, movie?.controller.isActive != true") })

        // stop() goes back to the preview graph only after the file has finished.
        let fileDone = try #require(code.firstIndex { $0.contains("let finish = await controller.stop(") })
        let back = try #require(code.firstIndex { $0.contains("await returnToPreview(graph") })
        #expect(fileDone < back)
        #expect(code.filter { $0.contains("returnToPreview(") }.count == 2)  // The definition and stop().
    }

    /// The upgrade adds the recording outputs to a running session. The full-size video output's
    /// settings and its connection are set inside the same configuration, before the commit, so the
    /// outputs join the running session ready for the writer (as build() sets them before
    /// startRunning).
    @Test func theUpgradeSetsTheRecordingOutputsBeforeItsCommit() throws {
        let url = Self.root.appendingPathComponent("Sources/CameraCapture/CameraRecorder.swift")
        let code = try Self.codeLines(url).map(\.1)
        let change = try #require(code.firstIndex { $0.contains("func change(to wanted: CameraGraphPlan") })
        let body = Array(code[change...])
        // `movieAudio`: the camera audio input the change adds, or the one the metered preview keeps.
        let attach = try #require(body.firstIndex { $0.contains("try attachMovie(output, audioDevice: movieAudio)") })
        let addAudio = try #require(body.firstIndex { $0.contains("session.addInput(newAudio.input)") })
        let addMovie = try #require(body.firstIndex { $0.contains("session.addOutput(output)") })
        let commit = try #require(body.firstIndex { $0.contains("session.commitConfiguration()") })
        #expect(addAudio < addMovie && addMovie < attach && attach < commit)
        // A reset of the camera format before the commit counts in format_reset.
        #expect(body.contains { $0.contains("let reset = keepWantedConfiguration() || resetBeforeCommit") })
    }

    /// A failed upgrade does not fail the take: prepare closes the camera and builds the recording
    /// graph fresh (the proven path), then waits for the first camera audio buffer.
    @Test func aFailedUpgradeOpensTheCameraAgain() throws {
        let url = Self.root.appendingPathComponent("Sources/CameraCapture/CameraRecorder.swift")
        let code = try Self.codeLines(url).map(\.1)
        let prepare = try #require(code.firstIndex { $0.contains("public func prepare(preview: CameraPreviewFeed?, events:") })
        let body = Array(code[prepare...])
        let upgrade = try #require(body.firstIndex { $0.contains("try await upgrade(graph, preview: preview, keepPreview: keep") })
        let close = try #require(body.firstIndex { $0.contains("await teardown()") })
        let open = try #require(body.firstIndex { $0.contains("try await open(plan, preview: preview, events: events)") })
        #expect(upgrade < close && close < open)
        #expect(body[upgrade...open].contains { $0.contains("} catch {") })
        #expect(body[upgrade...].prefix(25).filter { $0.contains("await waitForFirstCameraAudio(events: events)") }.count == 2)
    }

    /// Every graph change and build runs on the camera queue and says so in a debug build.
    @Test func graphWorkAssertsTheCameraQueue() throws {
        let url = Self.root.appendingPathComponent("Sources/CameraCapture/CameraRecorder.swift")
        let code = try Self.codeLines(url).map(\.1)
        for what in ["Building the capture session", "Changing the capture session", "Removing the preview output",
                     "Starting the capture session", "Stopping the capture session"] {
            #expect(code.contains { $0.contains("CaptureThread.assertOffMain(\"\(what)\")") }, "\(what)")
        }
    }

    /// The graph plan is plain data: no capture class, no wait.
    @Test func graphPlanIsPure() throws {
        let url = Self.root.appendingPathComponent("Sources/CameraCapture/CameraGraphPlan.swift")
        #expect(try Self.violations(in: [url]) == [])
        #expect(try !Self.codeLines(url).contains { $0.1.contains("import AVFoundation") })
    }

    @Test func theScanFindsAViolation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadRuleProbe-\(UUID().uuidString).swift")
        try "// AVCaptureSession in a comment is fine\nlet layer = AVCaptureVideoPreviewLayer()\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.violations(in: [url]) == ["\(url.lastPathComponent):2: AVCaptureVideoPreviewLayer"])
    }
}

/// While nothing records, the camera session holds the camera audio input only for the idle
/// meters (the metered preview, decision 1: the meters show whenever the camera preview is on);
/// the plain preview holds none, so macOS shows the green camera indicator but not the orange
/// microphone one. Only a take's prepare adds the recording outputs.
@Suite struct IdleMicTests {
    @Test func thePreviewOpensThePreviewGraph() throws {
        let app = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift")
        let appCode = try ThreadRuleTests.codeLines(app).map(\.1)
        // The idle meters (decision 1) ride on the preview graph; the open never prompts.
        #expect(appCode.contains { $0.contains("try await recorder.openPreview(feed, meters: meters)") })
        #expect(appCode.contains { $0.contains("let meters = idleCameraMeterWanted(audioDeviceUID: target.config.audioDeviceUID)") })
        // Only the take prepares (adds the mic and the movie output).
        let prepares = appCode.filter { $0.contains(".prepare(preview:") }
        #expect(prepares.count == 1)
        #expect(prepares.first?.contains("camera.prepare(preview: preview, events: events)") == true)

        let camera = ThreadRuleTests.root.appendingPathComponent("Sources/CameraCapture/CameraRecorder.swift")
        let cameraCode = try ThreadRuleTests.codeLines(camera).map(\.1)
        #expect(cameraCode.contains { $0.contains("try await open(.preview(meters: meters && canMeter), preview: preview, events: nil)") })
        // The idle meter never asks for the microphone: it reads the permission and opens without it.
        #expect(cameraCode.contains { $0.contains("guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,") })
        #expect(!cameraCode.contains { $0.contains("requestAccess") })
    }

    /// Stop keeps the take's camera for the preview only if it reported no trouble up to the
    /// moment it becomes the preview camera: its id stays the take's while `endSession` awaits the
    /// screen recorder, and `keepAsPreviewCamera` checks the rule again.
    @Test func aKeptCameraIsCheckedAgainBeforeItBecomesThePreviewCamera() throws {
        let app = ThreadRuleTests.root.appendingPathComponent("Sources/RecorderApp/SessionCoordinator.swift")
        let code = try ThreadRuleTests.codeLines(app).map(\.1)
        #expect(code.contains { $0.contains("if !keepingCamera { takeCameraID = nil }") })
        // The one plain clear is for a start that never prepared (blocked, cancelled, no folder).
        let early = try #require(code.firstIndex { $0.contains("private func endStartBeforePrepare(") })
        let clears = code.indices.filter { code[$0].trimmingCharacters(in: .whitespaces) == "takeCameraID = nil" }
        #expect(clears.count == 1 && clears.allSatisfy { $0 > early && $0 < early + 6 })
        let keep = try #require(code.firstIndex { $0.contains("private func keepAsPreviewCamera(_ kept: WarmCamera") })
        let body = Array(code[keep...].prefix(8))
        #expect(body.contains { $0.contains("defer { takeCameraID = nil }") })
        #expect(body.contains { $0.contains("guard takeCameraMayStay(kept.recorder, mayWait: mayWait) else {") })
        // An event from the take's camera marks it broken while its id is the take's.
        #expect(code.contains { $0.contains("if id == takeCameraID { takeCameraBroken = true }") })
    }
}

/// No wait on a recorder is without a limit: a camera queue stuck in stopRunning or startRunning
/// must not hold the app in "Starting…" or "Saving…".
@Suite struct BoundedWaitTests {
    @Test func returnsTheValueWhenTheWorkIsQuick() async {
        let value = await SessionCoordinator.waitAtMost(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func givesUpWhenTheWorkHangs() async {
        let clock = ContinuousClock()
        let began = clock.now
        let value = await SessionCoordinator.waitAtMost(.milliseconds(100)) { () async -> Int in
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - began < .seconds(3))
    }
}
