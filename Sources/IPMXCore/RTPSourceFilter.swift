import Foundation

/// Keeps a receiver locked to one synchronization source.
///
/// A multicast group is a shared medium: nothing stops a second sender — a forgotten encoder on
/// another machine, a duplicate process, an SSRC collision — from putting its packets on the
/// same address and port. RFC 3550 §5.1 makes the sequence number and timestamp meaningful only
/// *within* an SSRC, so feeding two interleaved sources into one reassembler does not degrade
/// gracefully: the sequence tracking reads every alternation as a gap and the picture never
/// recovers.
///
/// This was found the hard way, with two encoders left running on 239.10.10.10. The receiver
/// reported 6.1 billion lost packets and decoded nothing, with no indication of the real cause.
///
/// The lock is released when the chosen source falls silent, so restarting a sender — which
/// gives it a fresh SSRC — does not require restarting the receiver.
public struct RTPSourceFilter: Sendable {
    /// How long the locked source may be silent before another one may take over.
    public let relockAfter: TimeInterval

    /// Bounded so a broken network full of sources cannot grow this without limit.
    public static let maximumTrackedForeignSources = 8

    public private(set) var lockedSource: UInt32?
    public private(set) var acceptedPackets: UInt64 = 0
    public private(set) var rejectedPackets: UInt64 = 0
    public private(set) var foreignSources: Set<UInt32> = []
    public private(set) var relocks: UInt64 = 0

    private var lastAcceptedAt: Double = 0

    public init(relockAfter: TimeInterval = 2.0) {
        precondition(relockAfter > 0)
        self.relockAfter = relockAfter
    }

    /// True when this packet belongs to the source being followed.
    ///
    /// `now` is injectable so the relock behaviour can be tested without waiting.
    public mutating func accept(ssrc: UInt32, now: Double = MonotonicClock.now()) -> Bool {
        guard let locked = lockedSource else {
            lock(to: ssrc, at: now)
            return true
        }

        if ssrc == locked {
            lastAcceptedAt = now
            acceptedPackets &+= 1
            return true
        }

        // The locked source stopped; let this one take over rather than stay deaf forever.
        if now - lastAcceptedAt >= relockAfter {
            relocks &+= 1
            lock(to: ssrc, at: now)
            return true
        }

        rejectedPackets &+= 1
        if foreignSources.count < Self.maximumTrackedForeignSources {
            foreignSources.insert(ssrc)
        }
        return false
    }

    private mutating func lock(to ssrc: UInt32, at now: Double) {
        lockedSource = ssrc
        lastAcceptedAt = now
        acceptedPackets &+= 1
    }

    /// A one-line description of the interference, for the log.
    public var conflictDescription: String? {
        guard !foreignSources.isEmpty, let locked = lockedSource else { return nil }
        let others = foreignSources
            .sorted()
            .map { "0x\(String($0, radix: 16))" }
            .joined(separator: ", ")
        return "following SSRC 0x\(String(locked, radix: 16)), ignoring \(others). "
             + "More than one sender is using this address and port."
    }
}
