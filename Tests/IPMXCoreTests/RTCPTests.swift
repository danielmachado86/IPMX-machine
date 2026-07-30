import Foundation
import Testing
@testable import IPMXCore

@Suite("Media Info Blocks")
struct MediaInfoBlockTests {

    static let video = VideoMediaInfoBlock.nonBaseband(
        sampling: "YCbCr-4:2:0", bitDepth: 8, colorimetry: "BT709",
        width: 1920, height: 1080, frameRate: 60)

    static let h264 = H264MediaInfoBlock(H264FormatParameters(
        profileLevelID: "640028",
        spropParameterSets: "Z2QAKA==,aM48gA=="))

    static let h265 = H265MediaInfoBlock(H265FormatParameters(
        profileSpace: 0, profileID: 1, tierFlag: 0, levelID: 123,
        profileCompatibilityIndicator: "60000000",
        interopConstraints: "900000000000",
        spropVPS: "QAEMAf//AWAAAA==", spropSPS: "QgEBAWAAAA==", spropPPS: "RAHA8vA="))

    // MARK: 0x0005

    /// TR-10-2 §10 fixes every field width; the content is 88 bytes and the block 92.
    @Test("The video block has the layout TR-10-2 §10 defines")
    func videoLayout() {
        let content = Self.video.serializedContent()
        #expect(content.count == 88, "16+4+12+20+16+4+4+8+4")

        let block = Self.video.serialized()
        #expect(block.count == 92)
        #expect(block[0] == 0x00 && block[1] == 0x05, "TR-10-7 §12 sets the type to 0x0005")
        #expect(UInt16(block[2]) << 8 | UInt16(block[3]) == 22,
                "length is 32-bit words minus one: 92/4 - 1")
    }

    @Test("Strings are zero padded to their fixed widths")
    func videoStringPadding() {
        let content = [UInt8](Self.video.serializedContent())
        #expect(Array(content[0..<11]) == Array("YCbCr-4:2:0".utf8))
        #expect(content[11...15].allSatisfy { $0 == 0 }, "sampling pads to 16 bytes")
        #expect(Array(content[20..<26]) == Array("NARROW".utf8), "range starts at 20")
        #expect(Array(content[32..<37]) == Array("BT709".utf8), "colorimetry starts at 32")
        #expect(Array(content[52..<55]) == Array("SDR".utf8), "TCS starts at 52")
    }

    @Test("The packed word carries depth and the flags in the right bits")
    func videoPackedWord() {
        let content = [UInt8](Self.video.serializedContent())
        // F(1) | bit depth(7) | M(1) | I(1) | S(1) | reserved(5) | PARw(8) | PARh(8)
        #expect(content[16] == 8, "F=0 and depth=8 pack into the first byte")
        #expect(content[17] == 0, "progressive, block packing, not segmented")
        #expect(content[18] == 1, "PAR width defaults to 1 when unknown")
        #expect(content[19] == 1, "PAR height defaults to 1 when unknown")
    }

    @Test("Dimensions, rate and totals land at the documented offsets")
    func videoNumericFields() {
        let content = [UInt8](Self.video.serializedContent())
        func be16(_ i: Int) -> UInt16 { UInt16(content[i]) << 8 | UInt16(content[i + 1]) }

        #expect(be16(68) == 1920, "width")
        #expect(be16(70) == 1080, "height")
        // rate numerator(22) | rate denominator(10)
        let rate = UInt32(content[72]) << 24 | UInt32(content[73]) << 16
                 | UInt32(content[74]) << 8 | UInt32(content[75])
        #expect(rate >> 10 == 60, "rate numerator")
        #expect(rate & 0x3FF == 1, "rate denominator")
        #expect(be16(84) == 1920, "htotal")
        #expect(be16(86) == 1080, "vtotal")
    }

    /// TR-10-9 §10: a sender whose output is not a converted baseband signal cannot measure
    /// blanking, and shall report htotal = width, vtotal = height and
    /// measuredpixclk = width * height * exactframerate.
    @Test("A non-baseband sender follows TR-10-9 §10", arguments: [
        (1920, 1080, 60), (1280, 720, 30), (3840, 2160, 25),
    ])
    func nonBasebandTiming(width: Int, height: Int, frameRate: Int) {
        let block = VideoMediaInfoBlock.nonBaseband(
            sampling: "YCbCr-4:2:0", bitDepth: 8, colorimetry: "BT709",
            width: UInt16(width), height: UInt16(height), frameRate: frameRate)

        #expect(block.htotal == UInt16(width))
        #expect(block.vtotal == UInt16(height))
        #expect(block.measuredPixelClock == UInt64(width * height * frameRate))
        // Internally consistent: pixel clock over the total raster is exactly the frame rate.
        #expect(block.measuredPixelClock / (UInt64(block.htotal) * UInt64(block.vtotal))
                == UInt64(frameRate))
    }

    // MARK: 0x000A

    @Test("The H.264 block has a 28-byte fixed part before the parameter sets")
    func h264Layout() {
        let block = Self.h264.serialized()
        #expect(block[0] == 0x00 && block[1] == 0x0A)
        #expect(block.count >= 28)
        #expect(block.count % 4 == 0, "blocks are padded to a 32-bit boundary")
        #expect(UInt16(block[2]) << 8 | UInt16(block[3]) == UInt16(block.count / 4 - 1))
    }

    @Test("Only the parameters present in the fmtp line are flagged")
    func h264FieldPresentMask() {
        // bit 0 profile-level-id, bit 1 packetization-mode, bit 6 sprop-parameter-sets
        #expect(Self.h264.fieldPresentMask == 0b1000011)

        let absent = H264MediaInfoBlock(profileLevelID: nil, packetizationMode: nil,
                                        spropParameterSets: nil)
        #expect(absent.fieldPresentMask == 0)
        let content = [UInt8](absent.serializedContent())
        #expect(content[4...6].allSatisfy { $0 == 0 },
                "an absent parameter is zero, per TR-10-15 §16")
        #expect(content[20] == 0, "and its N length is zero")
    }

    @Test("profile-level-id is three bytes, big-endian, from the hex in the fmtp")
    func h264ProfileLevelID() {
        let content = [UInt8](Self.h264.serializedContent())
        #expect(content[4] == 0x64 && content[5] == 0x00 && content[6] == 0x28)
        #expect(content[7] == 1, "packetization-mode")
    }

    /// "sprop-parameter-sets and sprop-level-parameter-sets bytes are base64 characters as
    /// represented in the SDP transport file" — the text, not the decoded NAL units.
    @Test("The parameter sets travel as base64 text, not as raw NAL bytes")
    func h264SpropIsText() {
        let content = Self.h264.serializedContent()
        let length = Int(content[content.startIndex + 20])
        #expect(length == "Z2QAKA==,aM48gA==".utf8.count)

        let text = String(decoding: content.dropFirst(24).prefix(length), as: UTF8.self)
        #expect(text == "Z2QAKA==,aM48gA==")
    }

    // MARK: 0x0009

    @Test("The H.265 block has a 44-byte fixed part before the parameter sets")
    func h265Layout() {
        let block = Self.h265.serialized()
        #expect(block[0] == 0x00 && block[1] == 0x09)
        #expect(block.count >= 44)
        #expect(block.count % 4 == 0)
        #expect(UInt16(block[2]) << 8 | UInt16(block[3]) == UInt16(block.count / 4 - 1))
        #expect(Self.h265.serializedContent().count >= 40)
    }

    /// RFC 7798 splits the profile across six attributes, so nine bits are set: the six
    /// profile_tier_level fields plus the three parameter sets.
    @Test("The H.265 mask flags the six profile fields and the three parameter sets")
    func h265FieldPresentMask() {
        #expect(Self.h265.fieldPresentMask == 0xE03F)
        for field: H265MediaInfoBlock.Field in [.profileSpace, .profileID, .levelID, .tierFlag,
                                                .profileCompatibilityIndicator, .interopConstraints,
                                                .spropVPS, .spropSPS, .spropPPS] {
            #expect(Self.h265.fieldPresentMask & (1 << UInt32(field.rawValue)) != 0)
        }
        for field: H265MediaInfoBlock.Field in [.txMode, .spropDepackBufBytes, .extraBytes] {
            #expect(Self.h265.fieldPresentMask & (1 << UInt32(field.rawValue)) == 0)
        }
    }

    @Test("profile_tier_level values land in their documented bytes")
    func h265ProfileFields() {
        let content = [UInt8](Self.h265.serializedContent())
        #expect(content[4] == 0, "profile-space")
        #expect(content[5] == 1, "profile-id, Main")
        #expect(content[6] == 123, "level-id, 123/30 = level 4.1")
        #expect(content[7] == 0, "tier-flag, main tier")
        #expect(Array(content[8...11]) == [0x60, 0x00, 0x00, 0x00], "compatibility indicator")
        #expect(Array(content[12...17]) == [0x90, 0x00, 0x00, 0x00, 0x00, 0x00],
                "interop-constraints is six bytes")
    }

    @Test("The three parameter sets are length-prefixed and concatenated in order")
    func h265ParameterSets() {
        let content = Self.h265.serializedContent()
        let bytes = [UInt8](content)
        let vpsN = Int(bytes[36]), spsN = Int(bytes[37]), ppsN = Int(bytes[38])
        #expect(bytes[39] == 0, "extra-N")

        let payload = content.dropFirst(40)
        #expect(String(decoding: payload.prefix(vpsN), as: UTF8.self) == "QAEMAf//AWAAAA==")
        #expect(String(decoding: payload.dropFirst(vpsN).prefix(spsN), as: UTF8.self)
                == "QgEBAWAAAA==")
        #expect(String(decoding: payload.dropFirst(vpsN + spsN).prefix(ppsN), as: UTF8.self)
                == "RAHA8vA=")
    }

    @Test("Hex strings from the fmtp decode to the right bytes")
    func hexDecoding() {
        #expect(H265MediaInfoBlock.hexBytes("900000000000", count: 6)
                == [0x90, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(H265MediaInfoBlock.hexBytes("B01122334455", count: 6)
                == [0xB0, 0x11, 0x22, 0x33, 0x44, 0x55])
        #expect(H265MediaInfoBlock.hexBytes("", count: 6) == [0, 0, 0, 0, 0, 0])
    }

    @Test("The codec block follows the format parameters", arguments: VideoCodec.allCases)
    func codecBlockSelection(codec: VideoCodec) {
        let parameters: VideoFormatParameters = codec == .h264
            ? .h264(H264FormatParameters(profileLevelID: "640028", spropParameterSets: "AA==,BB=="))
            : .h265(H265FormatParameters(profileSpace: 0, profileID: 1, tierFlag: 0, levelID: 123,
                                         profileCompatibilityIndicator: "60000000",
                                         interopConstraints: "900000000000",
                                         spropVPS: "AA==", spropSPS: "BB==", spropPPS: "CC=="))
        #expect(makeCodecMediaInfoBlock(parameters).type == (codec == .h264 ? 0x000A : 0x0009))
    }
}

@Suite("IPMX Info Block (TR-10-1 §8.7)")
struct IPMXInfoBlockTests {

    static func block(_ blocks: [MediaInfoBlock] = []) -> IPMXInfoBlock {
        IPMXInfoBlock(blockVersion: 0,
                      timestampReferenceClock: "localmac",
                      mediaClock: "direct=0",
                      mediaInfoBlocks: blocks)
    }

    @Test("The header is 84 bytes: tag, length, version, reserved, and two fixed strings")
    func headerLayout() {
        let data = Self.block().serialized()
        #expect(data.count == IPMXInfoBlock.headerByteCount)
        #expect(IPMXInfoBlock.headerByteCount == 84, "4 + 4 + 64 + 12")

        #expect(data[0] == 0x58 && data[1] == 0x31, "the tag is 0x5831, the ASCII 'X1'")
        #expect(UInt16(data[2]) << 8 | UInt16(data[3]) == 20, "84/4 - 1")
        #expect(data[4] == 0, "block version")
        #expect(data[5...7].allSatisfy { $0 == 0 }, "24 reserved bits")
    }

    @Test("ts-refclk is 64 bytes and mediaclk is 12, both zero padded")
    func clockStrings() {
        let data = [UInt8](Self.block().serialized())
        #expect(Array(data[8..<16]) == Array("localmac".utf8))
        #expect(data[16..<72].allSatisfy { $0 == 0 }, "ts-refclk pads to 64 bytes")
        #expect(Array(data[72..<80]) == Array("direct=0".utf8))
        #expect(data[80..<84].allSatisfy { $0 == 0 }, "mediaclk pads to 12 bytes")
    }

    @Test("Media Info Blocks follow the header and are counted in the length")
    func withMediaInfoBlocks() {
        let video = MediaInfoBlockTests.video
        let data = Self.block([video, MediaInfoBlockTests.h264]).serialized()

        let expected = IPMXInfoBlock.headerByteCount
            + video.serialized().count + MediaInfoBlockTests.h264.serialized().count
        #expect(data.count == expected)
        #expect(UInt16(data[2]) << 8 | UInt16(data[3]) == UInt16(data.count / 4 - 1))
        #expect(data[84] == 0x00 && data[85] == 0x05, "the video block comes first")
    }

    @Test("The fingerprint ignores the version byte but nothing else")
    func fingerprint() {
        var a = Self.block([MediaInfoBlockTests.video])
        var b = a
        b.blockVersion = 7
        #expect(a.contentFingerprint() == b.contentFingerprint())

        a.mediaClock = "direct=1"
        #expect(a.contentFingerprint() != b.contentFingerprint())
    }
}

@Suite("RTCP Sender Report")
struct RTCPSenderReportTests {

    static func report(rtpTimestamp: UInt32 = 900_000,
                       blocks: [MediaInfoBlock] = [MediaInfoBlockTests.video]) -> RTCPSenderReport {
        RTCPSenderReport(ssrc: 0x1234_5678,
                         timestamp: PTPTimestamp(seconds: 3254, nanoseconds: 123_456_789),
                         rtpTimestamp: rtpTimestamp,
                         packetCount: 1000,
                         octetCount: 1_400_000,
                         infoBlock: IPMXInfoBlockTests.block(blocks))
    }

    @Test("The header follows RFC 3550 §6.4.1 with the constraints TR-10-1 §8.7 adds")
    func header() {
        let data = Self.report().serialized()
        #expect(data[0] >> 6 == 2, "version 2")
        #expect(data[0] & 0x20 == 0, "no padding")
        #expect(data[0] & 0x1F == 0, "TR-10-1 §8.7: the reception report count should be 0")
        #expect(data[1] == 200, "PT = SR")
        #expect(UInt16(data[2]) << 8 | UInt16(data[3]) == UInt16(data.count / 4 - 1),
                "length is the payload in 32-bit words minus one")
    }

    /// The trap: this field is named NTP but TR-10-1 §8.7 requires the PTP truncated format,
    /// with nanoseconds in the low word rather than an NTP 2^-32 fraction.
    @Test("The NTP timestamp field carries PTP seconds and nanoseconds")
    func ptpTimestamp() {
        let data = [UInt8](Self.report().serialized())
        func be32(_ i: Int) -> UInt32 {
            UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16
                | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
        }
        #expect(be32(8) == 3254, "seconds in the most significant word")
        #expect(be32(12) == 123_456_789, "nanoseconds in the least significant word")
        #expect(be32(12) < 1_000_000_000, "a nanosecond count, not an NTP fraction")
    }

    @Test("A monotonic reading converts to seconds and nanoseconds", arguments: [
        (0.0, UInt32(0), UInt32(0)),
        (1.5, 1, 500_000_000),
        (12.25, 12, 250_000_000),
    ])
    func ptpFromMonotonic(seconds: Double, expectedSeconds: UInt32, expectedNanoseconds: UInt32) {
        let timestamp = PTPTimestamp(monotonicSeconds: seconds)
        #expect(timestamp.seconds == expectedSeconds)
        #expect(abs(Int64(timestamp.nanoseconds) - Int64(expectedNanoseconds)) < 1000)
    }

    @Test("The Info Block sits right after the 28-byte fixed part")
    func extensionOffset() {
        let data = Self.report().serialized()
        #expect(RTCPSenderReport.fixedByteCount == 28, "8 byte header + 20 byte sender info")
        #expect(data[28] == 0x58 && data[29] == 0x31)
    }

    @Test("Everything round-trips through the parser")
    func roundTrip() throws {
        let data = Self.report(blocks: [MediaInfoBlockTests.video, MediaInfoBlockTests.h264])
            .serialized()
        let parsed = try #require(ParsedSenderReport.parse(data))

        #expect(parsed.receptionReportCount == 0)
        #expect(parsed.payloadType == 200)
        #expect(parsed.ssrc == 0x1234_5678)
        #expect(parsed.timestamp == PTPTimestamp(seconds: 3254, nanoseconds: 123_456_789))
        #expect(parsed.rtpTimestamp == 900_000)
        #expect(parsed.packetCount == 1000)
        #expect(parsed.octetCount == 1_400_000)

        #expect(parsed.infoBlockTag == IPMXInfoBlock.tag)
        #expect(parsed.blockVersion == 0)
        #expect(parsed.timestampReferenceClock == "localmac")
        #expect(parsed.mediaClock == "direct=0")
        #expect(parsed.mediaInfoBlocks.map(\.type) == [0x0005, 0x000A])
    }

    @Test("The H.265 report carries 0x0005 then 0x0009")
    func h265Blocks() throws {
        let data = Self.report(blocks: [MediaInfoBlockTests.video, MediaInfoBlockTests.h265])
            .serialized()
        let parsed = try #require(ParsedSenderReport.parse(data))
        #expect(parsed.mediaInfoBlocks.map(\.type) == [0x0005, 0x0009])
    }

    @Test("Non-Sender-Report input is rejected", arguments: [
        Data(),
        Data(repeating: 0x80, count: 10),
        Data([0x80, 201] + [UInt8](repeating: 0, count: 40)),      // receiver report
        Data([0x00, 200] + [UInt8](repeating: 0, count: 40)),      // version 0
    ])
    func rejectsOther(data: Data) {
        #expect(ParsedSenderReport.parse(data) == nil)
    }

    @Test("A report whose extension is not an IPMX Info Block is rejected")
    func rejectsForeignExtension() {
        var data = Self.report().serialized()
        data[28] = 0xAA                                            // corrupt the tag
        #expect(ParsedSenderReport.parse(data) == nil)
    }
}
