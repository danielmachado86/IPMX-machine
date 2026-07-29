import Foundation

/// Minimal RTP fixed header (RFC 3550 §5.1).
///
/// Phase 0 never emits CSRCs, padding or header extensions, so the header is
/// always exactly 12 bytes.
public struct RTPHeader {
    public static let size = 12

    public var version: UInt8 = 2
    public var padding = false
    public var extensionBit = false
    public var csrcCount: UInt8 = 0
    public var marker = false
    public var payloadType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32

    public init(payloadType: UInt8, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool) {
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.marker = marker
    }

    public func serialized() -> Data {
        var out = Data(capacity: RTPHeader.size)
        var b0 = (version & 0x03) << 6
        if padding { b0 |= 0x20 }
        if extensionBit { b0 |= 0x10 }
        b0 |= (csrcCount & 0x0F)
        out.append(b0)

        var b1 = payloadType & 0x7F
        if marker { b1 |= 0x80 }
        out.append(b1)

        appendBE(&out, sequenceNumber)
        appendBE(&out, timestamp)
        appendBE(&out, ssrc)
        return out
    }

    public static func parse(_ data: Data) -> (header: RTPHeader, payload: Data)? {
        guard data.count > size else { return nil }
        let b = [UInt8](data)
        guard (b[0] >> 6) == 2 else { return nil }

        let csrcCount = b[0] & 0x0F
        let headerLength = size + Int(csrcCount) * 4
        guard data.count > headerLength else { return nil }

        var header = RTPHeader(
            payloadType: b[1] & 0x7F,
            sequenceNumber: readBE16(b, 2),
            timestamp: readBE32(b, 4),
            ssrc: readBE32(b, 8),
            marker: (b[1] & 0x80) != 0
        )
        header.padding = (b[0] & 0x20) != 0
        header.extensionBit = (b[0] & 0x10) != 0
        header.csrcCount = csrcCount

        return (header, data.subdata(in: headerLength..<data.count))
    }
}

@inline(__always) private func appendBE(_ data: inout Data, _ value: UInt16) {
    var v = value.bigEndian
    withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
}

@inline(__always) private func appendBE(_ data: inout Data, _ value: UInt32) {
    var v = value.bigEndian
    withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
}

@inline(__always) private func readBE16(_ b: [UInt8], _ i: Int) -> UInt16 {
    (UInt16(b[i]) << 8) | UInt16(b[i + 1])
}

@inline(__always) private func readBE32(_ b: [UInt8], _ i: Int) -> UInt32 {
    (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
}
