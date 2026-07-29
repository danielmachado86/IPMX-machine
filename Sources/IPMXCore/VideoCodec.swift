import Foundation

/// The two compressed video formats IPMX defines on top of the TR-10-7 transport.
///
/// TR-10-15 splits the codec requirements into parts: Part 3 for H.264 (RFC 6184 payload,
/// BCP-006-02) and Part 2 for H.265 (RFC 7798 payload, BCP-006-03). Everything below the
/// payload format — the 90 kHz clock, the traffic shape, the RTP framing — is shared.
public enum VideoCodec: String, Sendable, CaseIterable {
    case h264
    case h265

    public init?(argument: String) {
        switch argument.lowercased() {
        case "h264", "avc", "h.264":  self = .h264
        case "h265", "hevc", "h.265": self = .h265
        default: return nil
        }
    }

    /// The `a=rtpmap` encoding name. RFC 6184 §8.2.1 and RFC 7798 §7.1.
    public var rtpEncodingName: String {
        switch self {
        case .h264: return "H264"
        case .h265: return "H265"
        }
    }

    /// H.264 has a 1-byte NAL unit header; H.265 has 2 (F, Type(6), LayerId(6), TID(3)).
    /// Nearly every difference in the packetization path traces back to this.
    public var nalHeaderSize: Int {
        switch self {
        case .h264: return 1
        case .h265: return 2
        }
    }

    public var specReference: String {
        switch self {
        case .h264: return "TR-10-15 Part 3 / RFC 6184"
        case .h265: return "TR-10-15 Part 2 / RFC 7798"
        }
    }
}
