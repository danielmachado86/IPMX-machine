import Foundation

// MARK: - Codec-specific format parameters

/// RFC 6184 §8.1 media type parameters.
public struct H264FormatParameters: Sendable, Equatable {
    public var profileLevelID: String        // 6 hex digits: profile_idc | constraints | level_idc
    public var spropParameterSets: String    // base64(SPS),base64(PPS)

    public init(profileLevelID: String, spropParameterSets: String) {
        self.profileLevelID = profileLevelID
        self.spropParameterSets = spropParameterSets
    }
}

/// RFC 7798 §7.1 media type parameters, as constrained by TR-10-15 Part 2 §16.
public struct H265FormatParameters: Sendable, Equatable {
    public var profileSpace: UInt8
    public var profileID: UInt8
    public var tierFlag: UInt8
    public var levelID: UInt8
    public var profileCompatibilityIndicator: String   // 8 hex digits (32 flags)
    public var interopConstraints: String              // 12 hex digits (48 constraint bits)
    public var spropVPS: String
    public var spropSPS: String
    public var spropPPS: String

    public init(profileSpace: UInt8, profileID: UInt8, tierFlag: UInt8, levelID: UInt8,
                profileCompatibilityIndicator: String, interopConstraints: String,
                spropVPS: String, spropSPS: String, spropPPS: String) {
        self.profileSpace = profileSpace
        self.profileID = profileID
        self.tierFlag = tierFlag
        self.levelID = levelID
        self.profileCompatibilityIndicator = profileCompatibilityIndicator
        self.interopConstraints = interopConstraints
        self.spropVPS = spropVPS
        self.spropSPS = spropSPS
        self.spropPPS = spropPPS
    }
}

public enum VideoFormatParameters: Sendable, Equatable {
    case h264(H264FormatParameters)
    case h265(H265FormatParameters)

    public var codec: VideoCodec {
        switch self {
        case .h264: return .h264
        case .h265: return .h265
        }
    }

    /// The codec-specific tail of the `a=fmtp` line.
    var fmtpFragment: String {
        switch self {
        case .h264(let p):
            return "profile-level-id=\(p.profileLevelID); packetization-mode=1; "
                 + "sprop-parameter-sets=\(p.spropParameterSets)"
        case .h265(let p):
            return "profile-space=\(p.profileSpace); profile-id=\(p.profileID); "
                 + "tier-flag=\(p.tierFlag); level-id=\(p.levelID); "
                 + "profile-compatibility-indicator=\(p.profileCompatibilityIndicator); "
                 + "interop-constraints=\(p.interopConstraints); "
                 + "sprop-vps=\(p.spropVPS); sprop-sps=\(p.spropSPS); sprop-pps=\(p.spropPPS)"
        }
    }
}

// MARK: - Session description

/// Hand-rolled SDP for Phase 0.
///
/// The shape follows ST 2110-22 §7 as required by TR-10-7 §11, and carries the TR-10-15
/// attributes we can already honour (`TP=2110TPW`, 90 kHz clock, `ts-refclk:localmac`). It is
/// NOT conformant yet — the video parameters are cosmetic until Phase 2 wires up RTCP,
/// because IPMX expects them to agree with the Media Info Blocks in the Sender Reports.
public struct SDPDescription {
    public var sessionName: String
    public var originAddress: String
    public var destinationAddress: String
    public var port: UInt16
    public var payloadType: UInt8
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var maxBitrateKbps: Int
    public var formatParameters: VideoFormatParameters
    public var ttl: Int = 64

    public var codec: VideoCodec { formatParameters.codec }

    public init(sessionName: String = "IPMX Phase 0",
                originAddress: String,
                destinationAddress: String,
                port: UInt16,
                payloadType: UInt8,
                width: Int,
                height: Int,
                frameRate: Int,
                maxBitrateKbps: Int,
                formatParameters: VideoFormatParameters) {
        self.sessionName = sessionName
        self.originAddress = originAddress
        self.destinationAddress = destinationAddress
        self.port = port
        self.payloadType = payloadType
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.maxBitrateKbps = maxBitrateKbps
        self.formatParameters = formatParameters
    }

    public func serialized() -> String {
        let sessionID = UInt32.random(in: 1...UInt32.max)
        let connection = IPv4.isMulticast(destinationAddress)
            ? "c=IN IP4 \(destinationAddress)/\(ttl)"
            : "c=IN IP4 \(destinationAddress)"

        return """
        v=0
        o=- \(sessionID) \(sessionID) IN IP4 \(originAddress)
        s=\(sessionName)
        t=0 0
        \(connection)
        m=video \(port) RTP/AVP \(payloadType)
        b=AS:\(maxBitrateKbps)
        a=rtpmap:\(payloadType) \(codec.rtpEncodingName)/90000
        a=fmtp:\(payloadType) width=\(width); height=\(height); exactframerate=\(frameRate); \
        sampling=YCbCr-4:2:0; depth=8; colorimetry=BT709; TCS=SDR; RANGE=NARROW; \
        TP=2110TPW; MAXUDP=1460; \(formatParameters.fmtpFragment)
        a=ts-refclk:localmac
        a=mediaclk:direct=0
        a=mid:VID
        a=sendonly

        """
    }

    /// What a receiver needs to start before the first in-band random access point: the
    /// destination, the port, the codec, and the out-of-band parameter sets.
    public struct Transport {
        public var address: String?
        public var port: UInt16?
        public var codec: VideoCodec?
        public var parameterSets: [NALUnit]
    }

    public static func parseTransport(_ text: String) -> Transport {
        var address: String?
        var port: UInt16?
        var codec: VideoCodec?
        var fmtpParameters: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("c=IN IP4 ") {
                address = String(line.dropFirst("c=IN IP4 ".count))
                    .split(separator: "/").first.map(String.init)

            } else if line.hasPrefix("m=video ") {
                let fields = line.split(separator: " ")
                if fields.count > 1 { port = UInt16(fields[1]) }

            } else if line.hasPrefix("a=rtpmap:") {
                let encoding = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if encoding.uppercased().hasPrefix("H265") { codec = .h265 }
                else if encoding.uppercased().hasPrefix("H264") { codec = .h264 }

            } else if line.hasPrefix("a=fmtp:") {
                for parameter in line.split(separator: ";") {
                    let trimmed = parameter.trimmingCharacters(in: .whitespaces)
                    guard let separator = trimmed.firstIndex(of: "=") else { continue }
                    let key = String(trimmed[trimmed.startIndex..<separator])
                        .split(separator: " ").last.map(String.init) ?? ""
                    fmtpParameters[key] = String(trimmed[trimmed.index(after: separator)...])
                }
            }
        }

        var parameterSets: [NALUnit] = []
        switch codec {
        case .h264:
            if let sprop = fmtpParameters["sprop-parameter-sets"] {
                parameterSets = ParameterSets.decodeSprop(sprop, codec: .h264)
            }
        case .h265:
            // RFC 7798 keeps the three parameter set types in separate attributes, and the
            // decoder needs them in VPS, SPS, PPS order.
            for key in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                if let sprop = fmtpParameters[key] {
                    parameterSets.append(contentsOf: ParameterSets.decodeSprop(sprop, codec: .h265))
                }
            }
        case nil:
            break
        }

        return Transport(address: address, port: port, codec: codec, parameterSets: parameterSets)
    }
}

// MARK: - Parameter set helpers

public enum ParameterSets {

    /// `profile-level-id` per RFC 6184 §8.1: the three bytes following the SPS NAL header.
    ///
    /// No un-escaping needed here: an emulation prevention byte this early would require
    /// profile_idc and the constraint byte to both be zero, which is not a valid SPS.
    public static func profileLevelID(sps: NALUnit) -> String {
        let bytes = [UInt8](sps.bytes)
        guard bytes.count >= 4 else { return "42E01F" }
        return String(format: "%02X%02X%02X", bytes[1], bytes[2], bytes[3])
    }

    /// `sprop-parameter-sets` per RFC 6184 §8.1: comma-separated base64 NAL units.
    public static func sprop(sps: NALUnit, pps: NALUnit) -> String {
        "\(sps.bytes.base64EncodedString()),\(pps.bytes.base64EncodedString())"
    }

    public static func decodeSprop(_ text: String, codec: VideoCodec) -> [NALUnit] {
        text.split(separator: ",").compactMap { element in
            Data(base64Encoded: String(element).trimmingCharacters(in: .whitespaces))
                .map { NALUnit(bytes: $0, codec: codec) }
        }
    }

    /// Builds the RFC 7798 format parameters by reading profile_tier_level out of the SPS.
    ///
    /// Layout after un-escaping, with the two-byte NAL header at 0..1:
    ///   [2]      sps_video_parameter_set_id(4) sps_max_sub_layers_minus1(3) nesting_flag(1)
    ///   [3]      general_profile_space(2) general_tier_flag(1) general_profile_idc(5)
    ///   [4..7]   general_profile_compatibility_flag[0..31]
    ///   [8..13]  48 constraint flag bits
    ///   [14]     general_level_idc
    /// Everything is byte-aligned from index 3, so no bit reader is needed — but the RBSP still
    /// has to be un-escaped first: profile_tier_level sits right where runs of zero bytes are
    /// common, so an encoder will usually have inserted a 0x03 inside it, and indexing the
    /// escaped bytes yields a plausible but wrong profile.
    public static func hevcFormatParameters(vps: NALUnit, sps: NALUnit, pps: NALUnit) -> H265FormatParameters? {
        let rbsp = [UInt8](RBSP.unescape(sps.bytes))
        guard rbsp.count >= 15 else { return nil }

        let profileSpace = (rbsp[3] & 0xC0) >> 6
        let tierFlag = (rbsp[3] & 0x20) >> 5
        let profileID = rbsp[3] & 0x1F
        let compatibility = rbsp[4...7].map { String(format: "%02X", $0) }.joined()
        let constraints = rbsp[8...13].map { String(format: "%02X", $0) }.joined()
        let levelID = rbsp[14]

        return H265FormatParameters(
            profileSpace: profileSpace,
            profileID: profileID,
            tierFlag: tierFlag,
            levelID: levelID,
            profileCompatibilityIndicator: compatibility,
            interopConstraints: constraints,
            spropVPS: vps.bytes.base64EncodedString(),
            spropSPS: sps.bytes.base64EncodedString(),
            spropPPS: pps.bytes.base64EncodedString()
        )
    }
}
