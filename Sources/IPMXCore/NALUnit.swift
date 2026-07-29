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
}

/// H.265 NAL unit type (Rec. ITU-T H.265 Table 7-1), the subset this profile can produce
/// or has to recognise. VCL types occupy 0...31; 16...23 are the IRAP (random access) range.
public enum H265NALType: UInt8 {
    case trailN    = 0
    case trailR    = 1
    case blaWLP    = 16
    case blaWRADL  = 17
    case blaNLP    = 18
    case idrWRADL  = 19
    case idrNLP    = 20
    case craNUT    = 21
    case vps       = 32
    case sps       = 33
    case pps       = 34
    case aud       = 35
    case endOfSequence = 36
    case endOfBitstream = 37
    case filler    = 38
    case prefixSEI = 39
    case suffixSEI = 40
}

/// A single NAL unit *without* its Annex B start code.
///
/// The codec is carried alongside the bytes rather than inferred, because the header layouts
/// are incompatible: H.264 reads the type from the low 5 bits of one byte, H.265 from bits
/// 6..1 of a two-byte header. Guessing wrong yields a plausible-looking but wrong type.
public struct NALUnit: Equatable, Sendable {
    public let bytes: Data
    public let codec: VideoCodec

    public init(bytes: Data, codec: VideoCodec) {
        self.bytes = bytes
        self.codec = codec
    }

    /// True when the unit is at least large enough to hold its own header.
    public var isWellFormed: Bool { bytes.count >= codec.nalHeaderSize }

    public var typeValue: UInt8 {
        guard let first = bytes.first, isWellFormed else { return 0xFF }
        switch codec {
        case .h264: return first & 0x1F
        case .h265: return (first >> 1) & 0x3F
        }
    }

    public var h264Type: H264NALType? {
        codec == .h264 ? H264NALType(rawValue: typeValue) : nil
    }

    public var h265Type: H265NALType? {
        codec == .h265 ? H265NALType(rawValue: typeValue) : nil
    }

    /// H.265 only: nuh_layer_id. Must be preserved when rebuilding a fragmented header.
    public var layerID: UInt8 {
        guard codec == .h265, bytes.count >= 2 else { return 0 }
        return ((bytes[bytes.startIndex] & 0x01) << 5) | (bytes[bytes.startIndex + 1] >> 3)
    }

    /// H.265 only: nuh_temporal_id_plus1.
    public var temporalIDPlus1: UInt8 {
        guard codec == .h265, bytes.count >= 2 else { return 0 }
        return bytes[bytes.startIndex + 1] & 0x07
    }

    /// Video Coding Layer: the NAL types that carry picture samples.
    /// TR-10-15 §9 allows at most one of these per UDP packet, in both parts.
    public var isVCL: Bool {
        guard isWellFormed else { return false }
        switch codec {
        case .h264: return (1...5).contains(typeValue)
        case .h265: return typeValue <= 31
        }
    }

    /// A random access point the decoder can start on: an IDR in H.264, any IRAP in H.265.
    public var isKeyframe: Bool {
        guard isWellFormed else { return false }
        switch codec {
        case .h264: return typeValue == H264NALType.idrSlice.rawValue
        case .h265: return (16...23).contains(typeValue)   // BLA, IDR, CRA and reserved IRAP
        }
    }

    /// Belongs in the CMVideoFormatDescription rather than in the sample data.
    public var isParameterSet: Bool {
        guard isWellFormed else { return false }
        switch codec {
        case .h264: return typeValue == H264NALType.sps.rawValue || typeValue == H264NALType.pps.rawValue
        case .h265: return (32...34).contains(typeValue)    // VPS, SPS, PPS
        }
    }

    /// Access unit delimiters and filler data: legal in the bitstream, unwanted in an
    /// AVCC/HVCC sample.
    public var isDiscardableFromSampleData: Bool {
        guard isWellFormed else { return true }
        switch codec {
        case .h264: return typeValue == H264NALType.aud.rawValue || typeValue == H264NALType.filler.rawValue
        case .h265: return typeValue == H265NALType.aud.rawValue || typeValue == H265NALType.filler.rawValue
        }
    }
}

public enum AnnexB {
    /// Splits an Annex B byte stream into NAL units, dropping the start codes.
    ///
    /// Accepts both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes, since x264 and
    /// x265 both emit a mix of the two.
    public static func split(_ stream: Data, codec: VideoCodec) -> [NALUnit] {
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
            units.append(NALUnit(bytes: stream.subdata(in: payloadStart..<payloadEnd), codec: codec))
        }
        return units
    }

    /// Wraps a NAL unit in a 4-byte start code.
    public static func framed(_ unit: NALUnit) -> Data {
        var out = Data([0x00, 0x00, 0x00, 0x01])
        out.append(unit.bytes)
        return out
    }

    /// AVCC / HVCC "length-prefixed" form expected by VideoToolbox sample data.
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
