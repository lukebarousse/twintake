import AVFoundation
import MediaWriter
import RecorderCore

/// The delegate of an audio data output that only meters: it maps each buffer to host time and
/// hands it to an `AudioLevelMeter`. Used by the mic check's own sessions, the idle Mac mic
/// (`MacMicMeter`) and the camera mic meter in the idle preview graph.
///
/// Confined to `queue`, where the output delivers. The session clock is handed over under a lock
/// (`setClock`), after the session runs and again after it changed; until then buffers are
/// skipped, so no time lands on the wrong clock. A new clock gets a new mapper.
final class AudioMeterTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    let meter: AudioLevelMeter
    private let lock = NSLock()
    private var clock: CMClock?
    private var clockSet = false
    /// Confined to `queue`.
    private var mapper: HostTimeMapper?
    private var mapperClock: CMClock?

    init(meter: AudioLevelMeter, label: String = "TwinTake.meter.audio") {
        self.meter = meter
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// The clock the output's buffers are stamped on (the session's `synchronizationClock`).
    func setClock(_ clock: CMClock?) {
        lock.withLock {
            self.clock = clock
            clockSet = true
        }
    }

    /// Hands on the block in progress, on `queue`, e.g. after the output left its session.
    func flushSoon() {
        queue.async { [self] in meter.flush() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (ready, clock) = lock.withLock { (clockSet, self.clock) }
        // Until the session clock is known, a time could land on the wrong clock: skip the buffer.
        guard ready else { return }
        if mapper == nil || !HostTimeMapper.sameClock(clock, mapperClock) {
            mapper = HostTimeMapper(clock: clock)
            mapperClock = clock
        }
        guard let ptsNs = mapper?.hostNs(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { return }
        meter.process(sampleBuffer, ptsNs: ptsNs)
    }
}
