import Foundation

/// One coded picture, reassembled from RTP.
public struct AccessUnit: Sendable {
    public let units: [NALUnit]
    public let timestamp: UInt32
    /// True when a packet was lost anywhere inside this access unit.
    public let corrupt: Bool

    public init(units: [NALUnit], timestamp: UInt32, corrupt: Bool) {
        self.units = units
        self.timestamp = timestamp
        self.corrupt = corrupt
    }
}

/// Reassembles RFC 6184 / RFC 7798 packets back into access units.
///
/// Access unit boundaries come from the RTP marker bit, with a change of RTP timestamp as a
/// fallback in case the marked packet was lost. There is no jitter buffer and no reordering:
/// Phase 0 assumes in-order delivery on a quiet LAN. Reordering belongs with the receiver
/// buffer model in a later phase.
///
/// One class rather than one per codec on purpose. The assembly, loss detection and flushing
/// are identical between the two payload formats; only the per-packet parsing differs. Two
/// copies of the assembly logic would drift.
public final class VideoDepacketizer {
    public let codec: VideoCodec
    public private(set) var lostPackets: UInt64 = 0

    private var pending: [NALUnit] = []
    private var pendingTimestamp: UInt32?
    private var pendingCorrupt = false

    private var fragmentBuffer: Data?
    private var expectedSequence: UInt16?

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    /// Feeds one RTP packet. Returns an access unit once it is complete.
    public func push(payload: Data, timestamp: UInt32, marker: Bool, sequence: UInt16) -> AccessUnit? {
        var completed: AccessUnit?

        // Sequence-number gap detection.
        if let expected = expectedSequence, sequence != expected {
            let gap = Int(sequence &- expected)
            lostPackets += UInt64(gap > 0 && gap < 0x8000 ? gap : 1)
            pendingCorrupt = true
            fragmentBuffer = nil                     // any half-assembled fragment is unusable
        }
        expectedSequence = sequence &+ 1

        // Timestamp change without a marker bit means we lost the end of the previous AU.
        if let current = pendingTimestamp, current != timestamp, !pending.isEmpty || pendingCorrupt {
            completed = flush(timestamp: current, corrupt: true)
        }
        pendingTimestamp = timestamp

        parse(payload: payload)

        // Emit on the marker bit even when nothing survived: an access unit whose every packet
        // was lost is still a frame the receiver needs to know about, and swallowing it
        // silently would make the drop invisible in the statistics.
        if marker, !pending.isEmpty || pendingCorrupt {
            completed = flush(timestamp: timestamp, corrupt: pendingCorrupt)
        }
        return completed
    }

    private func parse(payload: Data) {
        switch codec {
        case .h264: parseH264(payload)
        case .h265: parseH265(payload)
        }
    }

    // MARK: - RFC 6184

    private func parseH264(_ payload: Data) {
        guard let first = payload.first else { return }
        let type = first & 0x1F

        switch type {
        case 1...23:
            pending.append(NALUnit(bytes: payload, codec: .h264))

        case PayloadFormat.H264.stapA:               // accepted on ingest, never produced
            var offset = 1
            while offset + 2 <= payload.count {
                let size = Int(payload[payload.startIndex + offset]) << 8
                         | Int(payload[payload.startIndex + offset + 1])
                offset += 2
                guard size > 0, offset + size <= payload.count else { break }
                pending.append(NALUnit(bytes: payload.subdata(in: offset..<(offset + size)), codec: .h264))
                offset += size
            }

        case PayloadFormat.H264.fuA:
            guard payload.count >= 3 else { break }
            let fuHeader = payload[payload.startIndex + 1]
            let originalType = fuHeader & 0x1F
            // Rebuild the one-byte header: F and NRI from the FU indicator, type from FU header.
            let rebuiltHeader = Data([(first & 0xE0) | originalType])
            accumulateFragment(header: rebuiltHeader,
                               body: payload.subdata(in: 2..<payload.count),
                               start: (fuHeader & 0x80) != 0,
                               end: (fuHeader & 0x40) != 0)

        default:
            break                                     // FU-B, MTAP: not used by this profile
        }
    }

    // MARK: - RFC 7798

    private func parseH265(_ payload: Data) {
        guard payload.count >= 2 else { return }
        let b0 = payload[payload.startIndex]
        let b1 = payload[payload.startIndex + 1]
        let type = (b0 >> 1) & 0x3F

        switch type {
        case 0...47:
            pending.append(NALUnit(bytes: payload, codec: .h265))

        case PayloadFormat.H265.aggregationPacket:    // accepted on ingest, never produced
            var offset = 2                            // skip the PayloadHdr
            while offset + 2 <= payload.count {
                let size = Int(payload[payload.startIndex + offset]) << 8
                         | Int(payload[payload.startIndex + offset + 1])
                offset += 2
                guard size > 0, offset + size <= payload.count else { break }
                pending.append(NALUnit(bytes: payload.subdata(in: offset..<(offset + size)), codec: .h265))
                offset += size
            }

        case PayloadFormat.H265.fragmentationUnit:
            guard payload.count >= 4 else { break }
            let fuHeader = payload[payload.startIndex + 2]
            let originalType = fuHeader & 0x3F
            // Rebuild the two-byte header: keep F and nuh_layer_id/TID from the PayloadHdr,
            // restore the original 6-bit type.
            let rebuiltHeader = Data([(b0 & 0x81) | (originalType << 1), b1])
            accumulateFragment(header: rebuiltHeader,
                               body: payload.subdata(in: 3..<payload.count),
                               start: (fuHeader & 0x80) != 0,
                               end: (fuHeader & 0x40) != 0)

        case PayloadFormat.H265.paci:
            // TR-10-15 Part 2 §9 forbids senders from producing PACI. Dropping it rather than
            // attempting to unwrap keeps a non-conformant sender from corrupting our stream.
            pendingCorrupt = true

        default:
            break
        }
    }

    // MARK: - Shared fragment assembly

    private func accumulateFragment(header: Data, body: Data, start: Bool, end: Bool) {
        if start {
            var reconstructed = header
            reconstructed.append(body)
            fragmentBuffer = reconstructed
        } else if fragmentBuffer != nil {
            fragmentBuffer!.append(body)
        } else {
            pendingCorrupt = true                     // we joined mid-fragment
        }

        if end, let assembled = fragmentBuffer {
            pending.append(NALUnit(bytes: assembled, codec: codec))
            fragmentBuffer = nil
        }
    }

    private func flush(timestamp: UInt32, corrupt: Bool) -> AccessUnit {
        let unit = AccessUnit(units: pending, timestamp: timestamp, corrupt: corrupt)
        pending.removeAll(keepingCapacity: true)
        pendingCorrupt = false
        return unit
    }
}
