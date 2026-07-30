import Foundation
import Testing
@testable import IPMXCore

@Suite("Media clock relationship (TR-10-1 §10.5)")
struct MediaClockRelationshipTests {

    /// A synthetic source is timed by the sender itself; a capture card is timed by whatever is
    /// plugged into it. Declaring `direct=0` for the second tells a receiver it can lock to a
    /// relationship that does not exist.
    @Test("The SDP value follows the relationship", arguments: [
        (MediaClockRelationship.direct(), "direct=0"),
        (.direct(offset: 12345), "direct=12345"),
        (.sender, "sender"),
    ])
    func sdpValue(relationship: MediaClockRelationship, expected: String) {
        #expect(relationship.sdpValue == expected)
    }

    @Test("Only the sender form is asynchronous")
    func asynchronous() {
        #expect(!MediaClockRelationship.direct().isAsynchronous)
        #expect(!MediaClockRelationship.direct(offset: 99).isAsynchronous)
        #expect(MediaClockRelationship.sender.isAsynchronous)
    }

    @Test("Values round-trip through the SDP form", arguments: [
        MediaClockRelationship.direct(), .direct(offset: 7), .sender,
    ])
    func roundTrip(relationship: MediaClockRelationship) throws {
        let parsed = try #require(MediaClockRelationship(sdpValue: relationship.sdpValue))
        #expect(parsed == relationship)
    }

    @Test("Nonsense is rejected", arguments: ["", "direct", "direct=", "direct=x", "receiver"])
    func rejectsNonsense(text: String) {
        #expect(MediaClockRelationship(sdpValue: text) == nil)
    }

    /// Both places the value appears have to agree — the SDP attribute and the 12-byte mediaclk
    /// string of the IPMX Info Block.
    @Test("A capture source signals mediaclk:sender end to end")
    func asyncMediaSignalling() throws {
        let video = VideoMediaInfoBlock.nonBaseband(
            sampling: "YCbCr-4:2:0", bitDepth: 8, colorimetry: "BT709",
            width: 1920, height: 1080, frameRate: 60)
        let parameters = VideoFormatParameters.h264(
            H264FormatParameters(profileLevelID: "640028", spropParameterSets: "AA==,BB=="))

        let description = SDPDescription(
            originAddress: "192.168.1.50",
            destinationAddress: "239.10.10.10",
            port: 50000,
            payloadType: 96,
            maxBitrateKbps: 8000,
            video: video,
            formatParameters: parameters,
            mediaClock: MediaClockRelationship.sender.sdpValue
        )
        #expect(description.serialized().contains("a=mediaclk:sender"))
        #expect(!description.serialized().contains("direct=0"))

        let report = RTCPSenderReport(
            ssrc: 1,
            timestamp: PTPTimestamp(seconds: 0, nanoseconds: 0),
            rtpTimestamp: 0,
            packetCount: 0,
            octetCount: 0,
            infoBlock: IPMXInfoBlock(blockVersion: 0,
                                     timestampReferenceClock: "localmac",
                                     mediaClock: MediaClockRelationship.sender.sdpValue,
                                     mediaInfoBlocks: [video]))
        let parsed = try #require(ParsedSenderReport.parse(report.serialized()))
        #expect(parsed.mediaClock == "sender")
        #expect(MediaClockRelationship(sdpValue: parsed.mediaClock) == .sender)
    }

    @Test("A screen source keeps mediaclk:direct=0")
    func synchronousSignalling() throws {
        let video = VideoMediaInfoBlock.nonBaseband(
            sampling: "YCbCr-4:2:0", bitDepth: 8, colorimetry: "BT709",
            width: 1920, height: 1080, frameRate: 60)
        let report = RTCPSenderReport(
            ssrc: 1,
            timestamp: PTPTimestamp(seconds: 0, nanoseconds: 0),
            rtpTimestamp: 0,
            packetCount: 0,
            octetCount: 0,
            infoBlock: IPMXInfoBlock(blockVersion: 0,
                                     timestampReferenceClock: "localmac",
                                     mediaClock: MediaClockRelationship.direct().sdpValue,
                                     mediaInfoBlocks: [video]))
        let parsed = try #require(ParsedSenderReport.parse(report.serialized()))
        #expect(parsed.mediaClock == "direct=0")
    }
}
