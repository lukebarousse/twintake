import CoreMedia
import RecorderCore

/// Puts capture sample times on the host clock.
///
/// ScreenCaptureKit stamps every buffer of a stream on that stream's `synchronizationClock`, and
/// an AVCaptureSession stamps every buffer on the session's `synchronizationClock` (an audio
/// device clock when the session holds an audio input). The SDK headers do not say which clock
/// ScreenCaptureKit uses; RecorderCore assumes the host time clock (`CMClockGetHostTimeClock`, the
/// same mach time `HostClock.nowNs()` reads). The mapper checks the clock it is given: when it is
/// the host clock (or nil) times pass through unchanged; otherwise every time is converted with
/// `CMSyncConvertTime` when the sample arrives, so clock drift stays out of the result. The
/// recorders also log how long after its PTS the first buffer arrived, which is a few
/// milliseconds when the PTS really is host time and absurd when it is not.
package struct HostTimeMapper: @unchecked Sendable {
    private let clock: CMClock?
    package let isHostClock: Bool

    package init(clock: CMClock?) {
        self.clock = clock
        if let clock {
            isHostClock = CFEqual(clock, CMClockGetHostTimeClock())
        } else {
            isHostClock = true
        }
    }

    /// For events.jsonl: "host_time", "host_time_assumed" (the stream reported no clock) or
    /// "converted" (a different clock, mapped to host time).
    package var label: String {
        if clock == nil { return "host_time_assumed" }
        return isHostClock ? "host_time" : "converted"
    }

    /// True when both are the same clock (or both nil), so a mapper built for one serves the other.
    package static func sameClock(_ a: CMClock?, _ b: CMClock?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): CFEqual(a, b)
        default: false
        }
    }

    /// The host time of `time` in nanoseconds, or nil for an invalid time.
    package func hostNs(_ time: CMTime) -> UInt64? {
        guard time.isValid, time.isNumeric else { return nil }
        guard !isHostClock, let clock else { return HostClock.ns(fromHostTime: time) }
        return HostClock.ns(fromHostTime: CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()))
    }
}
