import Foundation

/// Reassembles RFC 6184 packets back into access units.
///
/// Access unit boundaries are taken from the RTP marker bit, with a change of RTP
/// timestamp as a fallback in case the marked packet was lost. There is no jitter
/// buffer and no reordering here — Phase 0 assumes in-order delivery on a quiet LAN.
/// Reordering belongs with the receiver buffer model in a later phase.
public final class H264Depacketizer {
    public struct AccessUnit {
        public let units: [NALUnit]
        public let timestamp: UInt32
        /// True when a packet was lost anywhere inside this access unit.
        public let corrupt: Bool
    }

    public private(set) var lostPackets: UInt64 = 0

    private var pending: [NALUnit] = []
    private var pendingTimestamp: UInt32?
    private var pendingCorrupt = false

    private var fuBuffer: Data?
    private var expectedSequence: UInt16?

    public init() {}

    /// Feeds one RTP packet. Returns an access unit once it is complete.
    public func push(payload: Data, timestamp: UInt32, marker: Bool, sequence: UInt16) -> AccessUnit? {
        var completed: AccessUnit?

        // Sequence-number gap detection.
        if let expected = expectedSequence, sequence != expected {
            let gap = Int(sequence &- expected)
            lostPackets += UInt64(gap > 0 && gap < 0x8000 ? gap : 1)
            pendingCorrupt = true
            fuBuffer = nil                       // any half-assembled FU-A is unusable
        }
        expectedSequence = sequence &+ 1

        // Timestamp change without a marker bit means we lost the end of the previous AU.
        if let current = pendingTimestamp, current != timestamp, !pending.isEmpty || pendingCorrupt {
            completed = flush(timestamp: current, corrupt: true)
        }
        pendingTimestamp = timestamp

        guard let first = payload.first else { return completed }
        let type = first & 0x1F

        switch type {
        case 1...23:
            pending.append(NALUnit(bytes: payload))

        case 24:                                  // STAP-A: accepted on ingest, never produced
            var offset = 1
            while offset + 2 <= payload.count {
                let size = Int(payload[payload.startIndex + offset]) << 8
                         | Int(payload[payload.startIndex + offset + 1])
                offset += 2
                guard size > 0, offset + size <= payload.count else { break }
                pending.append(NALUnit(bytes: payload.subdata(in: offset..<(offset + size))))
                offset += size
            }

        case 28:                                  // FU-A
            guard payload.count >= 3 else { break }
            let fuHeader = payload[payload.startIndex + 1]
            let start = (fuHeader & 0x80) != 0
            let end = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x1F

            if start {
                var reconstructed = Data()
                reconstructed.append((first & 0xE0) | originalType)   // rebuild the NAL header
                reconstructed.append(payload.subdata(in: 2..<payload.count))
                fuBuffer = reconstructed
            } else if fuBuffer != nil {
                fuBuffer!.append(payload.subdata(in: 2..<payload.count))
            } else {
                pendingCorrupt = true             // we joined mid-fragment
            }

            if end, let assembled = fuBuffer {
                pending.append(NALUnit(bytes: assembled))
                fuBuffer = nil
            }

        default:
            break                                 // FU-B / MTAP / PACI: not used by this profile
        }

        // Emit on the marker bit even when nothing survived: an access unit whose every
        // packet was lost is still a frame the receiver needs to know about, and swallowing
        // it silently would make the drop invisible in the statistics.
        if marker, !pending.isEmpty || pendingCorrupt {
            completed = flush(timestamp: timestamp, corrupt: pendingCorrupt)
        }
        return completed
    }

    private func flush(timestamp: UInt32, corrupt: Bool) -> AccessUnit {
        let unit = AccessUnit(units: pending, timestamp: timestamp, corrupt: corrupt)
        pending.removeAll(keepingCapacity: true)
        pendingCorrupt = false
        return unit
    }
}
