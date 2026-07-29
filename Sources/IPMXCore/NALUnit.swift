import Foundation

/// H.264 NAL unit type (Rec. ITU-T H.264 Table 7-1).
public enum H264NALType: UInt8 {
    case unspecified   = 0
    case nonIDRSlice   = 1
    case partitionA    = 2
    case partitionB    = 3
    case partitionC    = 4
    case idrSlice      = 5
    case sei           = 6
    case sps           = 7
    case pps           = 8
    case aud           = 9
    case endOfSequence = 10
    case endOfStream   = 11
    case filler        = 12

    /// Video Coding Layer: the NAL types that actually carry picture samples.
    /// TR-10-15 §9 allows at most one of these per UDP packet.
    public var isVCL: Bool {
        switch self {
        case .nonIDRSlice, .partitionA, .partitionB, .partitionC, .idrSlice: return true
        default: return false
        }
    }
}

/// A single NAL unit *without* its Annex B start code.
public struct NALUnit {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// First byte is the NAL header: forbidden_zero_bit(1) | nal_ref_idc(2) | nal_unit_type(5)
    public var header: UInt8 { bytes.first ?? 0 }
    public var typeValue: UInt8 { header & 0x1F }
    public var type: H264NALType? { H264NALType(rawValue: typeValue) }
    public var refIDC: UInt8 { (header & 0x60) >> 5 }
    public var isVCL: Bool { (1...5).contains(typeValue) }
    public var isKeyframe: Bool { typeValue == H264NALType.idrSlice.rawValue }

    /// Types that belong in the CMVideoFormatDescription rather than in the sample data.
    public var isParameterSet: Bool {
        typeValue == H264NALType.sps.rawValue || typeValue == H264NALType.pps.rawValue
    }
}

public enum AnnexB {
    /// Splits an Annex B byte stream into NAL units, dropping the start codes.
    ///
    /// Accepts both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes, since
    /// x264 emits a mix of the two.
    public static func split(_ stream: Data) -> [NALUnit] {
        var units: [NALUnit] = []
        var starts: [(offset: Int, codeLength: Int)] = []

        stream.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = raw.count
            var i = 0
            while i + 2 < n {
                if base[i] == 0x00 && base[i + 1] == 0x00 {
                    if base[i + 2] == 0x01 {
                        starts.append((i, 3)); i += 3; continue
                    }
                    if i + 3 < n && base[i + 2] == 0x00 && base[i + 3] == 0x01 {
                        starts.append((i, 4)); i += 4; continue
                    }
                }
                i += 1
            }
        }

        for (index, start) in starts.enumerated() {
            let payloadStart = start.offset + start.codeLength
            let payloadEnd = index + 1 < starts.count ? starts[index + 1].offset : stream.count
            guard payloadEnd > payloadStart else { continue }
            units.append(NALUnit(bytes: stream.subdata(in: payloadStart..<payloadEnd)))
        }
        return units
    }

    /// Wraps a NAL unit in a 4-byte start code.
    public static func framed(_ unit: NALUnit) -> Data {
        var out = Data([0x00, 0x00, 0x00, 0x01])
        out.append(unit.bytes)
        return out
    }

    /// AVCC / "length-prefixed" form expected by VideoToolbox sample data.
    /// The prefix width must match `nalUnitHeaderLength` in the format description.
    public static func lengthPrefixed(_ units: [NALUnit]) -> Data {
        var out = Data()
        for unit in units {
            var length = UInt32(unit.bytes.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit.bytes)
        }
        return out
    }
}
