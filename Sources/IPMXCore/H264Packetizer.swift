import Foundation

/// RFC 6184 packetizer, packetization-mode = 1 (non-interleaved).
///
/// Emits Single NAL Unit packets when a NAL fits, FU-A fragments when it does not.
/// STAP-A aggregation is deliberately not implemented: TR-10-15 §9 forbids more than
/// one VCL NAL per packet anyway, and keeping parameter sets in their own packets
/// costs nothing at these bitrates.
public struct H264Packetizer {
    /// Largest RTP payload we will produce, i.e. MTU - IP(20) - UDP(8) - RTP(12).
    /// 1400 leaves room for the usual 1500-byte path MTU without fragmenting at IP level.
    public let maxPayloadSize: Int

    public init(maxPayloadSize: Int = 1400) {
        precondition(maxPayloadSize > 3, "maxPayloadSize must leave room for the FU-A headers")
        self.maxPayloadSize = maxPayloadSize
    }

    /// Returns the RTP *payloads* for one access unit, in transmission order.
    /// The caller stamps them with a shared RTP timestamp and sets the marker bit
    /// on the final packet.
    public func packetize(accessUnit units: [NALUnit]) -> [Data] {
        var payloads: [Data] = []
        for unit in units where !unit.bytes.isEmpty {
            if unit.bytes.count <= maxPayloadSize {
                payloads.append(unit.bytes)          // Single NAL Unit packet
            } else {
                payloads.append(contentsOf: fragment(unit))
            }
        }
        return payloads
    }

    /// FU-A (RFC 6184 §5.8).
    ///
    ///   FU indicator: F | NRI (copied from the NAL header) | type = 28
    ///   FU header:    S | E | R=0 | original nal_unit_type
    private func fragment(_ unit: NALUnit) -> [Data] {
        let indicator = (unit.header & 0xE0) | 28
        let originalType = unit.header & 0x1F
        let maxFragment = maxPayloadSize - 2      // two bytes of FU headers

        var fragments: [Data] = []
        var offset = 1                            // skip the original NAL header byte
        let total = unit.bytes.count

        while offset < total {
            let count = min(maxFragment, total - offset)
            let isFirst = (offset == 1)
            let isLast = (offset + count == total)

            var fuHeader = originalType
            if isFirst { fuHeader |= 0x80 }       // S
            if isLast { fuHeader |= 0x40 }        // E

            var packet = Data(capacity: count + 2)
            packet.append(indicator)
            packet.append(fuHeader)
            packet.append(unit.bytes.subdata(in: offset..<(offset + count)))
            fragments.append(packet)

            offset += count
        }
        return fragments
    }
}
