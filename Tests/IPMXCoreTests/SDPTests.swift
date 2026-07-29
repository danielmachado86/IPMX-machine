import Foundation
import Testing
@testable import IPMXCore

@Suite("SDP generation and parsing")
struct SDPTests {

    private static let sps = NALUnit(bytes: Data([0x67, 0x64, 0x00, 0x28]))
    private static let pps = NALUnit(bytes: Data([0x68, 0xCE, 0x3C, 0x80]))

    private static func description(destination: String = "239.10.10.10") -> SDPDescription {
        SDPDescription(
            originAddress: "192.168.1.50",
            destinationAddress: destination,
            port: 50000,
            payloadType: 96,
            width: 1920,
            height: 1080,
            frameRate: 30,
            maxBitrateKbps: 8000,
            profileLevelID: ParameterSets.profileLevelID(sps: sps),
            spropParameterSets: ParameterSets.sprop(sps: sps, pps: pps)
        )
    }

    /// Each of these is required by a specific clause, so losing one is a conformance
    /// regression rather than a cosmetic diff.
    @Test("The generated SDP carries the attributes the TRs require", arguments: [
        ("a=rtpmap:96 H264/90000", "TR-10-7 §9 fixes the RTP clock at 90 kHz"),
        ("TP=2110TPW",             "TR-10-15 §10 requires the traffic shape declaration"),
        ("a=ts-refclk:localmac",   "TR-10-1 §10.4, no Common Reference Clock present"),
        ("a=mediaclk:direct=0",    "TR-10-1 §10.5 media clock signalling"),
        ("b=AS:8000",              "TR-10-7 §11 bit rate attribute"),
        ("packetization-mode=1",   "RFC 6184 non-interleaved mode"),
        ("sampling=YCbCr-4:2:0",   "TR-10-15 §12 minimum sender profile"),
        ("depth=8",                "TR-10-15 §12 minimum sample depth"),
        ("exactframerate=30",      "ST 2110-20 style frame rate signalling"),
    ])
    func requiredAttributes(fragment: String, clause: String) {
        #expect(Self.description().serialized().contains(fragment), "\(clause)")
    }

    @Test("The transport round-trips back out of the generated SDP")
    func transportRoundTrip() throws {
        let text = Self.description().serialized()
        let transport = SDPDescription.parseTransport(text)

        #expect(transport.address == "239.10.10.10")
        #expect(transport.port == 50000)

        let sets = ParameterSets.decodeSprop(try #require(transport.sprop))
        #expect(sets.count == 2)
        #expect(sets[0].bytes == Self.sps.bytes)
        #expect(sets[1].bytes == Self.pps.bytes)
    }

    @Test("A multicast destination gets a TTL suffix, a unicast one does not")
    func connectionLineForm() {
        #expect(Self.description(destination: "239.10.10.10").serialized().contains("c=IN IP4 239.10.10.10/64"))
        #expect(Self.description(destination: "127.0.0.1").serialized().contains("c=IN IP4 127.0.0.1\n"))
    }

    @Test("The connection address parses whether or not a TTL is present")
    func parsesConnectionWithAndWithoutTTL() {
        #expect(SDPDescription.parseTransport("c=IN IP4 239.1.2.3/32").address == "239.1.2.3")
        #expect(SDPDescription.parseTransport("c=IN IP4 10.0.0.5").address == "10.0.0.5")
    }

    @Test("profile-level-id is the three bytes following the SPS NAL header (RFC 6184 §8.1)")
    func profileLevelID() {
        #expect(ParameterSets.profileLevelID(sps: NALUnit(bytes: Data([0x67, 0x64, 0x00, 0x28, 0xAC]))) == "640028")
        #expect(ParameterSets.profileLevelID(sps: NALUnit(bytes: Data([0x67, 0x42, 0xE0, 0x1F]))) == "42E01F")
    }

    @Test("A truncated SPS falls back rather than crashing")
    func profileLevelIDFallback() {
        #expect(ParameterSets.profileLevelID(sps: NALUnit(bytes: Data([0x67]))) == "42E01F")
    }

    @Test("sprop-parameter-sets is comma-separated base64 and decodes back")
    func spropEncoding() {
        let sprop = ParameterSets.sprop(sps: Self.sps, pps: Self.pps)
        #expect(sprop.contains(","))
        #expect(sprop == "\(Self.sps.bytes.base64EncodedString()),\(Self.pps.bytes.base64EncodedString())")

        let decoded = ParameterSets.decodeSprop(sprop)
        #expect(decoded.count == 2)
        #expect(decoded[0].bytes == Self.sps.bytes)
    }

    @Test("Garbage in sprop is skipped instead of producing bogus NALs")
    func spropRejectsGarbage() {
        #expect(ParameterSets.decodeSprop("").isEmpty)
        #expect(ParameterSets.decodeSprop("!!!not base64!!!").isEmpty)
    }

    /// The port rules the encoder warns about, asserted here so the constants stay honest.
    @Test("The default transport respects the TR-10-7 §7 port rules")
    func portRules() {
        let port = Self.description().port
        #expect(port % 2 == 0, "TR-10-7 §7: the UDP destination port shall be even")
        #expect(port > 5000, "TR-10-7 §7: the port should be above 5000")
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
        let options = CommandLineOptions(["--dest", "239.1.1.1", "--port", "50000", "--verbose", "--hrd"])

        #expect(options.string("dest", default: "x") == "239.1.1.1")
        #expect(options.uint16("port", default: 1) == 50000)
        #expect(options.flag("verbose"))
        #expect(options.flag("hrd"))
        #expect(!options.flag("missing"))
        #expect(options.int("fps", default: 30) == 30, "an absent key falls back to the default")
        #expect(options.optionalString("dest") == "239.1.1.1")
        #expect(options.optionalString("nope") == nil)
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
