import Foundation
import Testing
@testable import IPMXCore

@Suite("RTP fixed header (RFC 3550 §5.1)")
struct RTPHeaderTests {

    @Test("The fixed header is exactly 12 bytes")
    func headerSize() {
        let header = RTPHeader(payloadType: 96, sequenceNumber: 1, timestamp: 1, ssrc: 1, marker: false)
        #expect(header.serialized().count == RTPHeader.size)
        #expect(RTPHeader.size == 12)
    }

    @Test("Every field survives a serialize/parse round trip")
    func roundTrip() throws {
        let original = RTPHeader(payloadType: 96,
                                 sequenceNumber: 65530,
                                 timestamp: 0xDEAD_BEEF,
                                 ssrc: 0x1234_5678,
                                 marker: true)
        var datagram = original.serialized()
        datagram.append(Data([0x65, 0x88, 0x84]))

        let parsed = try #require(RTPHeader.parse(datagram))
        #expect(parsed.header.payloadType == 96)
        #expect(parsed.header.sequenceNumber == 65530)
        #expect(parsed.header.timestamp == 0xDEAD_BEEF)
        #expect(parsed.header.ssrc == 0x1234_5678)
        #expect(parsed.header.marker)
        #expect(parsed.payload == Data([0x65, 0x88, 0x84]))
    }

    @Test("The version field is pinned to 2 and the marker bit does not bleed into the payload type")
    func versionAndMarkerEncoding() {
        let marked = RTPHeader(payloadType: 96, sequenceNumber: 0, timestamp: 0, ssrc: 0, marker: true)
        let plain = RTPHeader(payloadType: 96, sequenceNumber: 0, timestamp: 0, ssrc: 0, marker: false)

        #expect(marked.serialized()[0] >> 6 == 2)
        #expect(marked.serialized()[1] == 0x80 | 96)
        #expect(plain.serialized()[1] == 96)
    }

    @Test("Malformed datagrams are rejected rather than misparsed", arguments: [
        Data(),                                    // empty
        Data([0x80, 0x60]),                        // shorter than the fixed header
        Data(repeating: 0x80, count: 12),          // header present but no payload
        Data(repeating: 0x00, count: 20),          // version 0
        Data([0x40] + [UInt8](repeating: 0, count: 19)),  // version 1
    ])
    func rejectsMalformed(datagram: Data) {
        #expect(RTPHeader.parse(datagram) == nil)
    }

    @Test("CSRC entries shift the payload offset")
    func csrcOffset() throws {
        var header = RTPHeader(payloadType: 96, sequenceNumber: 7, timestamp: 90_000, ssrc: 42, marker: false)
        header.csrcCount = 2

        var datagram = header.serialized()
        datagram.append(Data(repeating: 0xAA, count: 8))    // two CSRC identifiers
        datagram.append(Data([0x65, 0x01]))                 // payload

        let parsed = try #require(RTPHeader.parse(datagram))
        #expect(parsed.header.csrcCount == 2)
        #expect(parsed.payload == Data([0x65, 0x01]))
    }
}

@Suite("90 kHz media clock (TR-10-7 §9)")
struct MediaClockTests {

    @Test("The clock advances at exactly 90 kHz")
    func rate() {
        #expect(MediaClock.rate == 90_000)

        let clock = MediaClock(originSeconds: 1000.0)
        let start = clock.timestamp(forPresentationTime: 1000.0)
        let oneSecondLater = clock.timestamp(forPresentationTime: 1001.0)
        #expect(oneSecondLater &- start == 90_000)
    }

    @Test("A frame interval maps to the expected tick count",
          arguments: [(30, UInt32(3000)), (25, UInt32(3600)), (50, UInt32(1800)), (60, UInt32(1500))])
    func frameIntervals(frameRate: Int, expectedTicks: UInt32) {
        let clock = MediaClock(originSeconds: 0)
        let first = clock.timestamp(forPresentationTime: 0)
        let second = clock.timestamp(forPresentationTime: 1.0 / Double(frameRate))
        #expect(second &- first == expectedTicks)
    }

    @Test("The origin is randomised per RFC 3550 §5.1, so two clocks rarely agree")
    func randomOrigin() {
        let samples = (0..<32).map { _ in MediaClock(originSeconds: 0).timestamp(forPresentationTime: 0) }
        #expect(Set(samples).count > 1, "a constant origin would leak the start time")
    }
}
