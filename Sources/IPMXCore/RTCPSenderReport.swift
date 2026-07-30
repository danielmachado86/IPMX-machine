import Foundation

/// The Internal Clock value that goes in the NTP timestamp field.
///
/// TR-10-1 §8.7 does *not* want an NTP timestamp there. It requires the PTP truncated format:
/// the 64 least significant bits of the Internal Clock, with whole seconds in the most
/// significant word and **nanoseconds** — not an NTP 2^-32 fraction — in the least significant
/// word. An implementation that follows RFC 3550 literally puts the wrong value here and
/// nothing complains.
public struct PTPTimestamp: Equatable, Sendable {
    public var seconds: UInt32
    public var nanoseconds: UInt32

    public init(seconds: UInt32, nanoseconds: UInt32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public init(monotonicSeconds: Double) {
        let whole = monotonicSeconds.rounded(.down)
        self.seconds = UInt32(truncatingIfNeeded: Int64(whole))
        self.nanoseconds = UInt32((monotonicSeconds - whole) * 1_000_000_000)
    }

    public static func now() -> PTPTimestamp {
        let nanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return PTPTimestamp(seconds: UInt32(truncatingIfNeeded: nanoseconds / 1_000_000_000),
                            nanoseconds: UInt32(nanoseconds % 1_000_000_000))
    }
}

/// RTCP Sender Report with the IPMX Info Block extension (RFC 3550 §6.4.1, TR-10-1 §8.7).
public struct RTCPSenderReport {
    public static let payloadType: UInt8 = 200
    /// Fixed part: 8 bytes of header plus 20 bytes of sender info.
    public static let fixedByteCount = 28

    public var ssrc: UInt32
    public var timestamp: PTPTimestamp
    public var rtpTimestamp: UInt32
    public var packetCount: UInt32
    public var octetCount: UInt32
    public var infoBlock: IPMXInfoBlock

    public init(ssrc: UInt32,
                timestamp: PTPTimestamp,
                rtpTimestamp: UInt32,
                packetCount: UInt32,
                octetCount: UInt32,
                infoBlock: IPMXInfoBlock) {
        self.ssrc = ssrc
        self.timestamp = timestamp
        self.rtpTimestamp = rtpTimestamp
        self.packetCount = packetCount
        self.octetCount = octetCount
        self.infoBlock = infoBlock
    }

    public func serialized() -> Data {
        let extensionData = infoBlock.serialized()

        var out = Data()
        // V=2, P=0, RC=0. TR-10-1 §8.7: "the reception report count (RC) field ... should be 0".
        out.append(0x80)
        out.append(RTCPSenderReport.payloadType)
        let totalBytes = RTCPSenderReport.fixedByteCount + extensionData.count
        out.appendBigEndian(UInt16(totalBytes / 4 - 1))

        out.appendBigEndian(ssrc)
        out.appendBigEndian(timestamp.seconds)          // NTP timestamp, most significant word
        out.appendBigEndian(timestamp.nanoseconds)      // NTP timestamp, least significant word
        out.appendBigEndian(rtpTimestamp)
        out.appendBigEndian(packetCount)
        out.appendBigEndian(octetCount)

        out.append(extensionData)
        return out
    }
}

// MARK: - Parsing

/// Enough of a reader to validate what the sender produced, and the starting point for the
/// receiver-side work in a later phase.
public struct ParsedSenderReport {
    public struct ParsedMediaInfoBlock {
        public let type: UInt16
        public let content: Data
    }

    public var receptionReportCount: UInt8
    public var payloadType: UInt8
    public var lengthWords: UInt16
    public var ssrc: UInt32
    public var timestamp: PTPTimestamp
    public var rtpTimestamp: UInt32
    public var packetCount: UInt32
    public var octetCount: UInt32

    public var infoBlockTag: UInt16
    public var infoBlockLengthWords: UInt16
    public var blockVersion: UInt8
    public var timestampReferenceClock: String
    public var mediaClock: String
    public var mediaInfoBlocks: [ParsedMediaInfoBlock]

    public static func parse(_ data: Data) -> ParsedSenderReport? {
        let bytes = [UInt8](data)
        guard bytes.count >= RTCPSenderReport.fixedByteCount + 4 else { return nil }
        guard (bytes[0] >> 6) == 2 else { return nil }
        guard bytes[1] == RTCPSenderReport.payloadType else { return nil }

        func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }

        var report = ParsedSenderReport(
            receptionReportCount: bytes[0] & 0x1F,
            payloadType: bytes[1],
            lengthWords: be16(2),
            ssrc: be32(4),
            timestamp: PTPTimestamp(seconds: be32(8), nanoseconds: be32(12)),
            rtpTimestamp: be32(16),
            packetCount: be32(20),
            octetCount: be32(24),
            infoBlockTag: be16(28),
            infoBlockLengthWords: be16(30),
            blockVersion: bytes[32],
            timestampReferenceClock: "",
            mediaClock: "",
            mediaInfoBlocks: []
        )
        guard report.infoBlockTag == IPMXInfoBlock.tag else { return nil }
        guard bytes.count >= 28 + IPMXInfoBlock.headerByteCount else { return nil }

        report.timestampReferenceClock = trimmedASCII(data, from: 36, length: 64)
        report.mediaClock = trimmedASCII(data, from: 100, length: 12)

        // Media Info Blocks run from the end of the Info Block header to the end of the
        // extension, whose extent comes from the Info Block length field.
        var offset = 28 + IPMXInfoBlock.headerByteCount
        let extensionEnd = min(bytes.count, 28 + (Int(report.infoBlockLengthWords) + 1) * 4)
        while offset + 4 <= extensionEnd {
            let type = be16(offset)
            let lengthWords = Int(be16(offset + 2))
            let blockBytes = (lengthWords + 1) * 4
            guard blockBytes >= 4, offset + blockBytes <= extensionEnd else { break }
            report.mediaInfoBlocks.append(ParsedMediaInfoBlock(
                type: type,
                content: data.subdata(in: (offset + 4)..<(offset + blockBytes))
            ))
            offset += blockBytes
        }
        return report
    }
}

private func trimmedASCII(_ data: Data, from offset: Int, length: Int) -> String {
    let slice = data.subdata(in: offset..<min(offset + length, data.count))
    let trimmed = slice.prefix { $0 != 0x00 }
    return String(decoding: trimmed, as: UTF8.self)
}
