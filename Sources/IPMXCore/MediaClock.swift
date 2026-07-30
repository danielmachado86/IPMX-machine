import Foundation

/// 90 kHz media clock.
///
/// TR-10-7 §9 fixes the Media Clock and RTP Clock rate at 90 kHz for compressed video,
/// and requires every RTP packet of a progressive frame to carry the same timestamp.
///
/// Phase 0 runs the clock free — the equivalent of `a=ts-refclk:localmac` in TR-10-1 §7.1,
/// which is explicitly allowed when no Common Reference Clock is present. The origin is a
/// random offset per RFC 3550 §5.1.
public struct MediaClock {
    public static let rate: UInt32 = 90_000

    private let originSeconds: Double
    private let randomOffset: UInt32

    public init(originSeconds: Double) {
        self.originSeconds = originSeconds
        self.randomOffset = UInt32.random(in: 0...UInt32.max)
    }

    /// Converts a capture presentation time (seconds, same epoch as `originSeconds`)
    /// into a 90 kHz RTP timestamp.
    public func timestamp(forPresentationTime seconds: Double) -> UInt32 {
        let ticks = (seconds - originSeconds) * Double(MediaClock.rate)
        return randomOffset &+ UInt32(truncatingIfNeeded: Int64(ticks.rounded()))
    }

    /// Timestamp for the nth frame of a constant-cadence sender.
    ///
    /// Preferred over deriving from a capture timestamp once the sender runs on a fixed
    /// schedule: the increment is exact, so successive frames are exactly one frame period
    /// apart in the media clock, with no accumulated rounding.
    public func timestamp(forFrameIndex index: UInt64, ticksPerFrame: UInt32) -> UInt32 {
        randomOffset &+ UInt32(truncatingIfNeeded: index &* UInt64(ticksPerFrame))
    }

    /// The exact number of 90 kHz ticks in one frame period, when there is one.
    /// Every integer rate this project supports divides 90000 evenly.
    public static func ticksPerFrame(frameRate: Int) -> UInt32? {
        guard frameRate > 0, rate % UInt32(frameRate) == 0 else { return nil }
        return rate / UInt32(frameRate)
    }
}

/// Monotonic wall clock that does not jump when the system time is adjusted.
public enum MonotonicClock {
    public static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
    }
}
