import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import RecorderCore

@Suite struct FrameRateTests {
    @Test func ntscRatesAreExact() {
        #expect(FrameRate.fps23_976.frameDuration == CMTime(value: 1001, timescale: 24000))
        #expect(FrameRate.fps47_952.frameDuration == CMTime(value: 1001, timescale: 48000))
        #expect(FrameRate.fps23_976.label == "23.976")
        #expect(FrameRate.fps47_952.label == "47.952")
        #expect(FrameRate.fps30.label == "30")
    }

    @Test func gridTimesAndNearestFrame() {
        let r = FrameRate.fps23_976
        #expect(r.time(ofFrame: 24) == CMTime(value: 24 * 1001, timescale: 24000))
        // One hour of 23.976 is 86313.6 frames; nearest is 86314.
        #expect(r.nearestFrame(at: CMTime(seconds: 3600, preferredTimescale: 1_000_000)) == 86314)
        #expect(r.nearestFrame(at: r.time(ofFrame: 1000)) == 1000)
        #expect(r.matches(23.976023))
        #expect(!r.matches(24.0))
    }

    @Test func screenRateIsTwiceCameraRate() {
        let cam = FrameRate.fps23_976, scr = FrameRate.fps47_952
        #expect(scr.frameDuration.seconds * 2 == cam.frameDuration.seconds)
    }
}

@Suite struct FrameGeometryTests {
    @Test func laptopFrameSitsUnderMenuBar() {
        // 14" MacBook Pro default: 1512x982 pt, menu bar 37 pt (notch).
        let r = FrameGeometry.frameRect(sizing: ScreenFramePreset.laptop16x9.sizing,
                                        displaySizePt: CGSize(width: 1512, height: 982), topInsetPt: 37)
        #expect(r == CGRect(x: 4, y: 37, width: 1504, height: 846))
        let px = FrameGeometry.outputPixels(forPoints: r.size, scale: 2)
        #expect(px == PixelSize(width: 3008, height: 1692))
    }

    @Test func fixedFrameShrinksOnSmallDisplay() {
        let r = FrameGeometry.frameRect(sizing: .fixed(width: 1504, height: 846),
                                        displaySizePt: CGSize(width: 1280, height: 800), topInsetPt: 25)
        #expect(r.width <= 1280 && r.maxY <= 800)
        #expect(abs(r.width / r.height - 16.0 / 9.0) < 0.01)
    }

    @Test func fullDisplayIsWholeDisplay() {
        let r = FrameGeometry.frameRect(sizing: .fullDisplay, displaySizePt: CGSize(width: 1920, height: 1080), topInsetPt: 30)
        #expect(r == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func coordinateConversionsRoundTrip() {
        let local = CGRect(x: 4, y: 37, width: 1504, height: 846)
        let display = CGRect(x: 1920, y: 0, width: 1512, height: 982)
        let global = FrameGeometry.globalRect(fromLocal: local, displayBoundsGlobal: display)
        #expect(global == CGRect(x: 1924, y: 37, width: 1504, height: 846))
        let appKit = FrameGeometry.appKitRect(fromGlobal: global, mainDisplayHeight: 1080)
        let expectedMinY: CGFloat = 1080 - 37 - 846
        #expect(appKit.minY == expectedMinY)
        #expect(FrameGeometry.globalRect(fromAppKit: appKit, mainDisplayHeight: 1080) == global)
    }

    @Test func outputPixelsAreEven() {
        let px = FrameGeometry.outputPixels(forPoints: CGSize(width: 1511.7, height: 850.5), scale: 2)
        #expect(px.width % 2 == 0 && px.height % 2 == 0)
    }
}

@Suite struct SessionTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recorder-tests-\(UUID().uuidString)")
    }

    @Test func folderNameFormat() {
        let date = ISO8601DateFormatter().date(from: "2026-10-12T22:40:05Z")!
        let name = SessionFolder.folderName(for: date, slug: "SQL Joins!", timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "2026-10-12_224005_sql-joins")
    }

    @Test func createAvoidsCollisions() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let a = try SessionFolder.create(in: root, date: date)
        let b = try SessionFolder.create(in: root, date: date)
        #expect(a.url != b.url)
        #expect(b.url.lastPathComponent.hasSuffix("-2"))
    }

    @Test func manifestRoundTripsWithSnakeCaseKeys() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SessionFolder.create(in: root)
        var m = SessionManifest(mode: .both, recorder: RecorderInfo(name: "TwinTake", version: "0.1.0", gitSha: "abc1234"))
        var t = TrackInfo(file: SessionFolder.screenFileName, trackIndex: 1, role: .mic, dialogue: false)
        t.firstPtsHostNs = 123_456_789
        t.frameRate = .fps47_952
        t.device = DeviceInfo(name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice")
        m.tracks = [t]
        m.screen = ScreenInfo(capture: "region", displayId: 1, displayName: "Built-in", scale: 2, preset: "laptop-16x9",
                              frameRectPt: PointRect(x: 4, y: 37, width: 1504, height: 846),
                              outputPx: PixelSize(width: 3008, height: 1692))
        try folder.writeManifest(m)

        let json = try String(contentsOf: folder.manifestURL, encoding: .utf8)
        #expect(json.contains("\"first_pts_host_ns\""))
        #expect(json.contains("\"schema_version\""))
        #expect(json.contains("\"git_sha\""))
        #expect(json.contains("\"macos_version\""))

        let back = try folder.readManifest()
        #expect(back.tracks.first?.firstPtsHostNs == 123_456_789)
        #expect(back.tracks.first?.frameRate == .fps47_952)
        #expect(back.recorder.gitSha == "abc1234")
        #expect(back.screen?.outputPx == PixelSize(width: 3008, height: 1692))
        #expect(back.status == .recording)
    }

    @Test func eventLogAppendsAndReads() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SessionFolder.create(in: root)
        let log = try EventLog(url: folder.eventsURL)
        log.append(.sessionStart)
        log.append(.marker, ["kind": "retake"])
        log.close()
        log.append(.sessionStop) // ignored after close
        let events = try EventLog.read(folder.eventsURL)
        #expect(events.map(\.type) == [.sessionStart, .marker])
        #expect(events[1].data?["kind"] == "retake")
        #expect(events[0].tHostNs <= events[1].tHostNs)
    }

    /// Lines are in the file as soon as append returns (the flush to the disk runs later, on its
    /// own queue), also when several capture queues log at once.
    @Test func eventLogLinesAreReadableBeforeClose() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SessionFolder.create(in: root)
        let log = try EventLog(url: folder.eventsURL)
        await withTaskGroup(of: Void.self) { group in
            for queue in 0..<4 {
                group.addTask {
                    for i in 0..<50 { log.append(.droppedFrames, ["queue": "\(queue)", "i": "\(i)"]) }
                }
            }
        }
        let events = try EventLog.read(folder.eventsURL)
        #expect(events.count == 200)
        #expect(Set(events.compactMap { $0.data.map { "\($0["queue"]!)-\($0["i"]!)" } }).count == 200)
        log.close()
        log.append(.sessionStop)
        #expect(try EventLog.read(folder.eventsURL).count == 200)
    }

    @Test func cameraGraphEventsRoundTrip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SessionFolder.create(in: root)
        let log = try EventLog(url: folder.eventsURL)
        log.append(.cameraGraph, ["from": "preview", "to": "recording", "ms": "312"])
        log.close()
        let text = try String(contentsOf: folder.eventsURL, encoding: .utf8)
        #expect(text.contains("\"type\":\"camera_graph\""))
        let events = try EventLog.read(folder.eventsURL)
        #expect(events.map(\.type) == [.cameraGraph])
        #expect(events.first?.data?["to"] == "recording")
    }

    @Test func hostClockConvertsHostTime() {
        let now = HostClock.now()
        let ns = HostClock.ns(fromHostTime: now)!
        let direct = HostClock.nowNs()
        #expect(direct >= ns)
        #expect(direct - ns < 1_000_000_000)
        #expect(HostClock.ns(fromHostTime: .invalid) == nil)
    }
}
