import Foundation

/// RTP payload constants for the two payload formats.
enum PayloadFormat {
    /// RFC 6184 §5.2. STAP-A aggregates; FU-A fragments.
    enum H264 {
        static let stapA: UInt8 = 24
        static let fuA: UInt8 = 28
        /// FU indicator + FU header.
        static let fragmentOverhead = 2
    }

    /// RFC 7798 §4.4. AP aggregates; FU fragments; PACI is forbidden by TR-10-15 Part 2 §9.
    enum H265 {
        static let aggregationPacket: UInt8 = 48
        static let fragmentationUnit: UInt8 = 49
        static let paci: UInt8 = 50
        /// Two-byte PayloadHdr + one-byte FU header. One byte more than H.264.
        static let fragmentOverhead = 3
    }
}

/// Packetizes access units for either payload format, in non-interleaved mode.
///
/// Emits Single NAL Unit packets when a NAL fits and fragments when it does not. Aggregation
/// (STAP-A / AP) is deliberately never produced: TR-10-15 §9 forbids more than one VCL NAL
/// per packet in both parts, and keeping parameter sets in their own packets costs nothing at
/// these bitrates.
public struct VideoPacketizer: Sendable {
    public let codec: VideoCodec

    /// Largest RTP payload we will produce, i.e. MTU - IP(20) - UDP(8) - RTP(12).
    /// 1400 leaves room for the usual 1500-byte path MTU without fragmenting at IP level.
    public let maxPayloadSize: Int

    public init(codec: VideoCodec, maxPayloadSize: Int = 1400) {
        precondition(maxPayloadSize > 4, "maxPayloadSize must leave room for the fragmentation headers")
        self.codec = codec
        self.maxPayloadSize = maxPayloadSize
    }

    /// Returns the RTP *payloads* for one access unit, in transmission order.
    /// The caller stamps them with a shared RTP timestamp and sets the marker bit on the last.
    public func packetize(accessUnit units: [NALUnit]) -> [Data] {
        var payloads: [Data] = []
        for unit in units where unit.isWellFormed {
            precondition(unit.codec == codec, "a \(unit.codec) NAL cannot go through a \(codec) packetizer")
            if unit.bytes.count <= maxPayloadSize {
                payloads.append(unit.bytes)          // Single NAL Unit packet
            } else {
                payloads.append(contentsOf: fragment(unit))
            }
        }
        return payloads
    }

    private func fragment(_ unit: NALUnit) -> [Data] {
        switch codec {
        case .h264: return fragmentH264(unit)
        case .h265: return fragmentH265(unit)
        }
    }

    /// FU-A, RFC 6184 §5.8.
    ///
    ///   FU indicator: F | NRI (copied from the NAL header) | type = 28
    ///   FU header:    S | E | R=0 | original nal_unit_type
    private func fragmentH264(_ unit: NALUnit) -> [Data] {
        let bytes = unit.bytes
        let header = bytes[bytes.startIndex]
        let indicator = (header & 0xE0) | PayloadFormat.H264.fuA
        let originalType = header & 0x1F
        let maxFragment = maxPayloadSize - PayloadFormat.H264.fragmentOverhead

        var fragments: [Data] = []
        var offset = 1                                 // skip the 1-byte NAL header
        let total = bytes.count

        while offset < total {
            let count = min(maxFragment, total - offset)
            var fuHeader = originalType
            if offset == 1 { fuHeader |= 0x80 }        // S
            if offset + count == total { fuHeader |= 0x40 }   // E

            var packet = Data(capacity: count + PayloadFormat.H264.fragmentOverhead)
            packet.append(indicator)
            packet.append(fuHeader)
            packet.append(bytes.subdata(in: offset..<(offset + count)))
            fragments.append(packet)

            offset += count
        }
        return fragments
    }

    /// FU, RFC 7798 §4.4.3.
    ///
    ///   PayloadHdr: the original two-byte NAL header with Type replaced by 49. F, LayerId
    ///               and TID must be carried through unchanged so the receiver can rebuild
    ///               the original header exactly.
    ///   FU header:  S | E | FuType (6 bits, the original nal_unit_type)
    private func fragmentH265(_ unit: NALUnit) -> [Data] {
        let bytes = unit.bytes
        let b0 = bytes[bytes.startIndex]
        let b1 = bytes[bytes.startIndex + 1]

        // 0x81 keeps the forbidden_zero_bit and the top bit of nuh_layer_id, which live in
        // byte 0 either side of the 6-bit type field.
        let payloadHeader0 = (b0 & 0x81) | (PayloadFormat.H265.fragmentationUnit << 1)
        let payloadHeader1 = b1
        let originalType = (b0 >> 1) & 0x3F
        let maxFragment = maxPayloadSize - PayloadFormat.H265.fragmentOverhead

        var fragments: [Data] = []
        var offset = 2                                 // skip the 2-byte NAL header
        let total = bytes.count

        while offset < total {
            let count = min(maxFragment, total - offset)
            var fuHeader = originalType
            if offset == 2 { fuHeader |= 0x80 }        // S
            if offset + count == total { fuHeader |= 0x40 }   // E

            var packet = Data(capacity: count + PayloadFormat.H265.fragmentOverhead)
            packet.append(payloadHeader0)
            packet.append(payloadHeader1)
            packet.append(fuHeader)
            packet.append(bytes.subdata(in: offset..<(offset + count)))
            fragments.append(packet)

            offset += count
        }
        return fragments
    }
}
