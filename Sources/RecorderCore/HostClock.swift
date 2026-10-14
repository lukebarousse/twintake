import CoreMedia
import Darwin

/// One clock for every file in a session: the host clock (mach absolute time) in nanoseconds.
///
/// AVFoundation and ScreenCaptureKit stamp sample buffers on the host time clock
/// (`CMClockGetHostTimeClock`). Recording each track's first presentation time in this
/// domain lets the editor line files up without guessing.
public enum HostClock {
    /// Current host time in nanoseconds.
    public static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Converts a presentation time on the host time clock to nanoseconds.
    /// Returns nil for invalid or non-numeric times.
    public static func ns(fromHostTime time: CMTime) -> UInt64? {
        guard time.isValid, time.isNumeric, time.value >= 0 else { return nil }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        return UInt64(scaled.value)
    }

    /// Current host time as a CMTime on the host time clock.
    public static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
