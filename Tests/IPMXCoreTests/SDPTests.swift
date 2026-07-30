import Foundation
import Testing
@testable import IPMXCore

@Suite("SDP generation and parsing")
struct SDPTests {

    private static let h264SPS = NALUnit(bytes: Data([0x67, 0x64, 0x00, 0x28]), codec: .h264)
    private static let h264PPS = NALUnit(bytes: Data([0x68, 0xCE, 0x3C, 0x80]), codec: .h264)

    private static let h264Parameters = VideoFormatParameters.h264(H264FormatParameters(
        profileLevelID: ParameterSets.profileLevelID(sps: h264SPS),
        spropParameterSets: ParameterSets.sprop(sps: h264SPS, pps: h264PPS)
    ))

    private static let h265Parameters = VideoFormatParameters.h265(H265FormatParameters(
        profileSpace: 0, profileID: 1, tierFlag: 0, levelID: 93,
        profileCompatibilityIndicator: "60000000",
        interopConstraints: "B00000000000",
        spropVPS: TestNAL.h265(type: 32).bytes.base64EncodedString(),
        spropSPS: TestNAL.h265(type: 33).bytes.base64EncodedString(),
        spropPPS: TestNAL.h265(type: 34).bytes.base64EncodedString()
    ))

    private static func description(_ parameters: VideoFormatParameters,
                                    destination: String = "239.10.10.10") -> SDPDescription {
        SDPDescription(
            originAddress: "192.168.1.50",
            destinationAddress: destination,
            port: 50000,
            payloadType: 96,
            width: 1920,
            height: 1080,
            frameRate: 60,
            maxBitrateKbps: 8000,
            formatParameters: parameters
        )
    }

    /// Each of these is required by a specific clause, so losing one is a conformance
    /// regression rather than a cosmetic diff. They apply to both codecs.
    @Test("The generated SDP carries the attributes the TRs require",
          arguments: VideoCodec.allCases, [
            ("TP=2110TPW",           "TR-10-15 §10 requires the traffic shape declaration"),
            ("a=ts-refclk:localmac", "TR-10-1 §10.4, no Common Reference Clock present"),
            ("a=mediaclk:direct=0",  "TR-10-1 §10.5 media clock signalling"),
            ("b=AS:8000",            "TR-10-7 §11 bit rate attribute"),
            ("sampling=YCbCr-4:2:0", "TR-10-15 §12 minimum sender profile"),
            ("depth=8",              "TR-10-15 §12 minimum sample depth"),
            ("exactframerate=",      "ST 2110-20 style frame rate signalling"),
          ])
    func requiredAttributes(codec: VideoCodec, expectation: (fragment: String, clause: String)) {
        let parameters = codec == .h264 ? Self.h264Parameters : Self.h265Parameters
        #expect(Self.description(parameters).serialized().contains(expectation.fragment),
                "\(expectation.clause)")
    }

    @Test("The rtpmap encoding name follows the codec", arguments: VideoCodec.allCases)
    func rtpmapEncodingName(codec: VideoCodec) {
        let parameters = codec == .h264 ? Self.h264Parameters : Self.h265Parameters
        let expected = codec == .h264 ? "a=rtpmap:96 H264/90000" : "a=rtpmap:96 H265/90000"
        #expect(Self.description(parameters).serialized().contains(expected),
                "TR-10-7 §9 fixes the RTP clock at 90 kHz for both")
    }

    @Test("H.264 emits the RFC 6184 fmtp parameters")
    func h264FormatParameters() {
        let text = Self.description(Self.h264Parameters).serialized()
        #expect(text.contains("packetization-mode=1"))
        #expect(text.contains("profile-level-id=640028"))
        #expect(text.contains("sprop-parameter-sets="))
        #expect(!text.contains("sprop-vps"), "the H.265 parameters must not leak into an H.264 SDP")
    }

    /// RFC 7798 splits what H.264 packs into profile-level-id across six attributes, and keeps
    /// the three parameter set types in separate ones.
    @Test("H.265 emits the RFC 7798 fmtp parameters")
    func h265FormatParameters() {
        let text = Self.description(Self.h265Parameters).serialized()
        for fragment in ["profile-space=0", "profile-id=1", "tier-flag=0", "level-id=93",
                         "profile-compatibility-indicator=60000000",
                         "interop-constraints=B00000000000",
                         "sprop-vps=", "sprop-sps=", "sprop-pps="] {
            #expect(text.contains(fragment), "missing \(fragment)")
        }
        #expect(!text.contains("sprop-parameter-sets"), "that attribute is H.264 only")
        #expect(!text.contains("profile-level-id"), "that attribute is H.264 only")
    }

    @Test("The transport round-trips back out of the generated SDP", arguments: VideoCodec.allCases)
    func transportRoundTrip(codec: VideoCodec) {
        let parameters = codec == .h264 ? Self.h264Parameters : Self.h265Parameters
        let transport = SDPDescription.parseTransport(Self.description(parameters).serialized())

        #expect(transport.address == "239.10.10.10")
        #expect(transport.port == 50000)
        #expect(transport.codec == codec, "the codec must be recoverable from the rtpmap")
        #expect(transport.parameterSets.count == (codec == .h264 ? 2 : 3))
        #expect(transport.parameterSets.allSatisfy { $0.codec == codec })
        #expect(transport.parameterSets.allSatisfy { $0.isParameterSet })
    }

    @Test("H.265 parameter sets come back in VPS, SPS, PPS order")
    func h265ParameterSetOrder() {
        let transport = SDPDescription.parseTransport(Self.description(Self.h265Parameters).serialized())
        #expect(transport.parameterSets.map(\.typeValue) == [
            H265NALType.vps.rawValue, H265NALType.sps.rawValue, H265NALType.pps.rawValue,
        ], "VideoToolbox requires this order")
    }

    @Test("exactframerate reports the configured frame rate", arguments: [24, 25, 30, 50, 60])
    func exactFrameRate(frameRate: Int) {
        var description = Self.description(Self.h264Parameters)
        description.frameRate = frameRate
        #expect(description.serialized().contains("exactframerate=\(frameRate);"))
    }

    @Test("A multicast destination gets a TTL suffix, a unicast one does not")
    func connectionLineForm() {
        #expect(Self.description(Self.h264Parameters, destination: "239.10.10.10")
            .serialized().contains("c=IN IP4 239.10.10.10/64"))
        #expect(Self.description(Self.h264Parameters, destination: "127.0.0.1")
            .serialized().contains("c=IN IP4 127.0.0.1\n"))
    }

    @Test("The connection address parses whether or not a TTL is present")
    func parsesConnectionWithAndWithoutTTL() {
        #expect(SDPDescription.parseTransport("c=IN IP4 239.1.2.3/32").address == "239.1.2.3")
        #expect(SDPDescription.parseTransport("c=IN IP4 10.0.0.5").address == "10.0.0.5")
    }

    @Test("An SDP with no rtpmap yields no codec and no parameter sets")
    func missingRtpmap() {
        let transport = SDPDescription.parseTransport("c=IN IP4 10.0.0.5\nm=video 50000 RTP/AVP 96")
        #expect(transport.codec == nil)
        #expect(transport.parameterSets.isEmpty)
    }

    @Test("The default transport respects the TR-10-7 §7 port rules")
    func portRules() {
        let port = Self.description(Self.h264Parameters).port
        #expect(port % 2 == 0, "TR-10-7 §7: the UDP destination port shall be even")
        #expect(port > 5000, "TR-10-7 §7: the port should be above 5000")
    }
}

@Suite("Parameter set decoding")
struct ParameterSetTests {

    @Test("profile-level-id is the three bytes following the SPS NAL header (RFC 6184 §8.1)")
    func profileLevelID() {
        #expect(ParameterSets.profileLevelID(
            sps: NALUnit(bytes: Data([0x67, 0x64, 0x00, 0x28, 0xAC]), codec: .h264)) == "640028")
        #expect(ParameterSets.profileLevelID(
            sps: NALUnit(bytes: Data([0x67, 0x42, 0xE0, 0x1F]), codec: .h264)) == "42E01F")
    }

    @Test("A truncated SPS falls back rather than crashing")
    func profileLevelIDFallback() {
        #expect(ParameterSets.profileLevelID(
            sps: NALUnit(bytes: Data([0x67]), codec: .h264)) == "42E01F")
    }

    @Test("sprop round-trips through base64", arguments: VideoCodec.allCases)
    func spropRoundTrip(codec: VideoCodec) {
        let sets = TestNAL.parameterSets(codec: codec)
        let joined = sets.map { $0.bytes.base64EncodedString() }.joined(separator: ",")
        let decoded = ParameterSets.decodeSprop(joined, codec: codec)

        #expect(decoded.count == sets.count)
        #expect(decoded.map(\.bytes) == sets.map(\.bytes))
        #expect(decoded.allSatisfy { $0.codec == codec })
    }

    @Test("Garbage in sprop is skipped instead of producing bogus NALs")
    func spropRejectsGarbage() {
        #expect(ParameterSets.decodeSprop("", codec: .h264).isEmpty)
        #expect(ParameterSets.decodeSprop("!!!not base64!!!", codec: .h265).isEmpty)
    }

    @Test("Emulation prevention bytes are stripped", arguments: [
        ([0x00, 0x00, 0x03, 0x01] as [UInt8], [0x00, 0x00, 0x01] as [UInt8]),
        ([0x00, 0x00, 0x03, 0x00], [0x00, 0x00, 0x00]),
        ([0xAA, 0xBB, 0xCC], [0xAA, 0xBB, 0xCC]),
        ([0x00, 0x03, 0x01], [0x00, 0x03, 0x01]),            // only one zero, not an EPB
        ([0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x01], [0x00, 0x00, 0x00, 0x00, 0x01]),
    ])
    func unescapeRBSP(escaped: [UInt8], expected: [UInt8]) {
        #expect([UInt8](ParameterSets.unescapeRBSP(Data(escaped))) == expected)
    }

    /// profile_tier_level sits exactly where runs of zero bytes are common, so a real SPS
    /// almost always has an emulation prevention byte inside it. Reading the escaped bytes
    /// at fixed offsets yields a plausible but wrong profile — this SPS carries one 0x03 to
    /// prove the un-escaping happens.
    @Test("HEVC format parameters are read past an emulation prevention byte")
    func hevcFormatParameters() throws {
        let escapedSPS = NALUnit(bytes: Data([
            0x42, 0x01,                                     // NAL header, type 33
            0x01,                                           // vps_id, max_sub_layers, nesting
            0x01,                                           // profile_space 0, tier 0, profile_idc 1
            0x60, 0x00, 0x00, 0x03, 0x00,                   // compatibility flags, with the EPB
            0xB0, 0x11, 0x22, 0x33, 0x44, 0x55,             // 48 constraint bits
            0x5D,                                           // general_level_idc = 93 -> level 3.1
        ]), codec: .h265)

        let parameters = try #require(ParameterSets.hevcFormatParameters(
            vps: TestNAL.h265(type: 32), sps: escapedSPS, pps: TestNAL.h265(type: 34)))

        #expect(parameters.profileSpace == 0)
        #expect(parameters.tierFlag == 0)
        #expect(parameters.profileID == 1, "profile_idc 1 is Main")
        #expect(parameters.profileCompatibilityIndicator == "60000000")
        #expect(parameters.interopConstraints == "B01122334455")
        #expect(parameters.levelID == 93, "reading the escaped bytes would have given 0x55 here")
    }

    @Test("An SPS too short to hold profile_tier_level yields nil rather than garbage")
    func hevcFormatParametersTooShort() {
        #expect(ParameterSets.hevcFormatParameters(
            vps: TestNAL.h265(type: 32),
            sps: NALUnit(bytes: Data([0x42, 0x01, 0x01, 0x01]), codec: .h265),
            pps: TestNAL.h265(type: 34)) == nil)
    }
}

@Suite("Video codec identification")
struct VideoCodecTests {

    @Test("Codec names parse from the aliases people actually type", arguments: [
        ("h264", VideoCodec.h264), ("H264", .h264), ("avc", .h264), ("h.264", .h264),
        ("h265", .h265), ("H265", .h265), ("hevc", .h265), ("HEVC", .h265), ("h.265", .h265),
    ])
    func parsing(argument: String, expected: VideoCodec) {
        #expect(VideoCodec(argument: argument) == expected)
    }

    @Test("Unknown codec names are rejected")
    func rejectsUnknown() {
        #expect(VideoCodec(argument: "vp9") == nil)
        #expect(VideoCodec(argument: "") == nil)
    }

    @Test("The NAL header size drives the packetization differences")
    func nalHeaderSize() {
        #expect(VideoCodec.h264.nalHeaderSize == 1)
        #expect(VideoCodec.h265.nalHeaderSize == 2)
    }
}

@Suite("IPv4 addressing")
struct AddressingTests {

    @Test("Multicast detection follows 224.0.0.0/4", arguments: [
        ("224.0.0.1", true),
        ("239.10.10.10", true),
        ("239.255.255.255", true),
        ("223.255.255.255", false),
        ("240.0.0.1", false),
        ("192.168.1.10", false),
        ("127.0.0.1", false),
        ("0.0.0.0", false),
        ("not an address", false),
        ("", false),
    ])
    func multicastDetection(address: String, expected: Bool) {
        #expect(IPv4.isMulticast(address) == expected)
    }

    @Test("Dotted quads parse and garbage does not")
    func parsing() {
        #expect(IPv4.parse("10.0.0.1") != nil)
        #expect(IPv4.parse("255.255.255.255") != nil)
        #expect(IPv4.parse("256.0.0.1") == nil)
        #expect(IPv4.parse("10.0.0") == nil)
        #expect(IPv4.parse("hello") == nil)
    }

    @Test("An egress interface is always chosen, even with no network up")
    func defaultInterface() {
        let address = IPv4.defaultInterfaceAddress()
        #expect(!address.isEmpty)
        #expect(IPv4.parse(address) != nil, "the fallback must still be a usable IPv4 address")
    }
}

@Suite("Command line parsing")
struct CommandLineOptionsTests {

    @Test("Values, flags and defaults are distinguished")
    func parsing() {
        let options = CommandLineOptions(["--codec", "h265", "--dest", "239.1.1.1",
                                          "--port", "50000", "--verbose", "--no-hrd"])

        #expect(options.string("codec", default: "h264") == "h265")
        #expect(options.string("dest", default: "x") == "239.1.1.1")
        #expect(options.uint16("port", default: 1) == 50000)
        #expect(options.flag("verbose"))
        #expect(options.flag("no-hrd"))
        #expect(!options.flag("missing"))
        #expect(options.int("fps", default: 60) == 60, "an absent key falls back to the default")
        #expect(options.optionalString("nope") == nil)
    }

    /// HRD is on unless opted out, so the encoder derives it by negation. Getting this
    /// backwards would silently ship non-conformant streams.
    @Test("A hyphenated negative flag is parsed as a flag, not as a value")
    func negativeFlag() {
        #expect(CommandLineOptions(["--no-hrd"]).flag("no-hrd"))
        #expect(CommandLineOptions(["--no-hrd", "--dest", "127.0.0.1"]).flag("no-hrd"))
        #expect(!CommandLineOptions(["--dest", "127.0.0.1"]).flag("no-hrd"))
        #expect(CommandLineOptions(["--no-hrd"]).optionalString("no-hrd") == nil)
    }

    @Test("A trailing flag with no value is not swallowed by the next argument")
    func trailingFlag() {
        let options = CommandLineOptions(["--verbose"])
        #expect(options.flag("verbose"))
        #expect(options.optionalString("verbose") == nil)
    }

    @Test("Non-numeric input falls back to the default rather than crashing")
    func malformedNumbers() {
        let options = CommandLineOptions(["--fps", "banana", "--port", "99999999"])
        #expect(options.int("fps", default: 30) == 30)
        #expect(options.uint16("port", default: 50000) == 50000, "an out-of-range port falls back")
    }
}
