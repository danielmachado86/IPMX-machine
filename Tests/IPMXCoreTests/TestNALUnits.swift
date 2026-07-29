import Foundation
@testable import IPMXCore

/// Synthetic NAL units for both codecs.
///
/// H.264 header: forbidden(1) nal_ref_idc(2) nal_unit_type(5)
/// H.265 header: forbidden(1) nal_unit_type(6) nuh_layer_id(6) nuh_temporal_id_plus1(3)
enum TestNAL {

    static func h264(type: UInt8, refIDC: UInt8 = 3, payloadBytes: Int = 8) -> NALUnit {
        var bytes = Data([(refIDC << 5) | (type & 0x1F)])
        bytes.append(contentsOf: (0..<payloadBytes).map { UInt8($0 % 251) })
        return NALUnit(bytes: bytes, codec: .h264)
    }

    static func h265(type: UInt8, layerID: UInt8 = 0, temporalIDPlus1: UInt8 = 1, payloadBytes: Int = 8) -> NALUnit {
        let byte0 = ((type & 0x3F) << 1) | ((layerID >> 5) & 0x01)
        let byte1 = ((layerID & 0x1F) << 3) | (temporalIDPlus1 & 0x07)
        var bytes = Data([byte0, byte1])
        bytes.append(contentsOf: (0..<payloadBytes).map { UInt8($0 % 251) })
        return NALUnit(bytes: bytes, codec: .h265)
    }

    /// A coded slice of the given total size, in bytes, including the NAL header.
    static func slice(codec: VideoCodec, size: Int) -> NALUnit {
        switch codec {
        case .h264: return h264(type: H264NALType.idrSlice.rawValue, payloadBytes: size - 1)
        case .h265: return h265(type: H265NALType.idrWRADL.rawValue, payloadBytes: size - 2)
        }
    }

    static func parameterSets(codec: VideoCodec) -> [NALUnit] {
        switch codec {
        case .h264:
            return [h264(type: H264NALType.sps.rawValue, payloadBytes: 3),
                    h264(type: H264NALType.pps.rawValue, payloadBytes: 3)]
        case .h265:
            return [h265(type: H265NALType.vps.rawValue, payloadBytes: 3),
                    h265(type: H265NALType.sps.rawValue, payloadBytes: 3),
                    h265(type: H265NALType.pps.rawValue, payloadBytes: 3)]
        }
    }
}
