import Foundation

/// Hand-rolled SDP for Phase 0.
///
/// The shape follows ST 2110-22 §7 as required by TR-10-7 §11, and carries the
/// TR-10-15 attributes we can already honour (`TP=2110TPW`, 90 kHz clock,
/// `packetization-mode=1`, `ts-refclk:localmac`). It is NOT conformant yet — the
/// video parameters below are cosmetic until Phase 2 wires up RTCP, because IPMX
/// expects them to agree with the Media Info Blocks in the Sender Reports.
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
    public var profileLevelID: String       // 6 hex digits: profile_idc | constraints | level_idc
    public var spropParameterSets: String   // base64(SPS),base64(PPS)
    public var ttl: Int = 64

    public init(sessionName: String = "IPMX Phase 0",
                originAddress: String,
                destinationAddress: String,
                port: UInt16,
                payloadType: UInt8,
                width: Int,
                height: Int,
                frameRate: Int,
                maxBitrateKbps: Int,
                profileLevelID: String,
                spropParameterSets: String) {
        self.sessionName = sessionName
        self.originAddress = originAddress
        self.destinationAddress = destinationAddress
        self.port = port
        self.payloadType = payloadType
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.maxBitrateKbps = maxBitrateKbps
        self.profileLevelID = profileLevelID
        self.spropParameterSets = spropParameterSets
    }

    public func serialized() -> String {
        let sessionID = UInt32.random(in: 1...UInt32.max)
        let multicast = IPv4.isMulticast(destinationAddress)
        let connection = multicast
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
        a=rtpmap:\(payloadType) H264/90000
        a=fmtp:\(payloadType) width=\(width); height=\(height); exactframerate=\(frameRate); \
        sampling=YCbCr-4:2:0; depth=8; colorimetry=BT709; TCS=SDR; RANGE=NARROW; \
        TP=2110TPW; MAXUDP=1460; profile-level-id=\(profileLevelID); packetization-mode=1; \
        sprop-parameter-sets=\(spropParameterSets)
        a=ts-refclk:localmac
        a=mediaclk:direct=0
        a=mid:VID
        a=sendonly

        """
    }

    /// Pulls out just what the decoder needs to start before the first in-band IDR:
    /// the destination, the port, and the parameter sets.
    public static func parseTransport(_ text: String) -> (address: String?, port: UInt16?, sprop: String?) {
        var address: String?
        var port: UInt16?
        var sprop: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("c=IN IP4 ") {
                address = String(line.dropFirst("c=IN IP4 ".count)).split(separator: "/").first.map(String.init)
            } else if line.hasPrefix("m=video ") {
                let fields = line.split(separator: " ")
                if fields.count > 1 { port = UInt16(fields[1]) }
            } else if line.hasPrefix("a=fmtp:") {
                for parameter in line.split(separator: ";") {
                    let trimmed = parameter.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("sprop-parameter-sets=") {
                        sprop = String(trimmed.dropFirst("sprop-parameter-sets=".count))
                    }
                }
            }
        }
        return (address, port, sprop)
    }
}

public enum ParameterSets {
    /// `profile-level-id` per RFC 6184 §8.1: the three bytes following the SPS NAL header.
    public static func profileLevelID(sps: NALUnit) -> String {
        let bytes = [UInt8](sps.bytes)
        guard bytes.count >= 4 else { return "42E01F" }
        return String(format: "%02X%02X%02X", bytes[1], bytes[2], bytes[3])
    }

    /// `sprop-parameter-sets` per RFC 6184 §8.1: comma-separated base64 NAL units.
    public static func sprop(sps: NALUnit, pps: NALUnit) -> String {
        "\(sps.bytes.base64EncodedString()),\(pps.bytes.base64EncodedString())"
    }

    public static func decodeSprop(_ text: String) -> [NALUnit] {
        text.split(separator: ",").compactMap { element in
            Data(base64Encoded: String(element).trimmingCharacters(in: .whitespaces)).map(NALUnit.init(bytes:))
        }
    }
}
