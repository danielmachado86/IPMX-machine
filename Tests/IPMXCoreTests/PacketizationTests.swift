import Foundation
import Testing
@testable import IPMXCore

@Suite("Annex B bitstream handling")
struct AnnexBTests {

    @Test("Both 3-byte and 4-byte start codes are recognised")
    func mixedStartCodes() {
        var stream = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, 0xBB])    // 4-byte, SPS
        stream.append(Data([0x00, 0x00, 0x01, 0x68, 0xCC]))              // 3-byte, PPS
        stream.append(Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x11, 0x22]))  // 4-byte, IDR

        let units = AnnexB.split(stream)
        #expect(units.count == 3)
        #expect(units[0].typeValue == H264NALType.sps.rawValue)
        #expect(units[1].typeValue == H264NALType.pps.rawValue)
        #expect(units[2].typeValue == H264NALType.idrSlice.rawValue)
        #expect(units[0].bytes == Data([0x67, 0xAA, 0xBB]))
        #expect(units[1].bytes == Data([0x68, 0xCC]))
    }

    @Test("A stream with no start code yields nothing")
    func noStartCode() {
        #expect(AnnexB.split(Data([0x67, 0xAA, 0xBB])).isEmpty)
        #expect(AnnexB.split(Data()).isEmpty)
    }

    @Test("NAL classification matches H.264 Table 7-1", arguments: [
        (UInt8(0x67), H264NALType.sps, false, true),
        (UInt8(0x68), H264NALType.pps, false, true),
        (UInt8(0x65), H264NALType.idrSlice, true, false),
        (UInt8(0x41), H264NALType.nonIDRSlice, true, false),
        (UInt8(0x06), H264NALType.sei, false, false),
        (UInt8(0x09), H264NALType.aud, false, false),
    ])
    func classification(header: UInt8, expected: H264NALType, isVCL: Bool, isParameterSet: Bool) {
        let unit = NALUnit(bytes: Data([header, 0x00]))
        #expect(unit.type == expected)
        #expect(unit.isVCL == isVCL)
        #expect(unit.isParameterSet == isParameterSet)
        #expect(expected.isVCL == isVCL)
    }

    @Test("The AVCC length prefix is 4 bytes, big-endian, matching nalUnitHeaderLength")
    func lengthPrefix() {
        let avcc = AnnexB.lengthPrefixed([NALUnit(bytes: Data([0x65, 0x01, 0x02]))])
        #expect([UInt8](avcc) == [0x00, 0x00, 0x00, 0x03, 0x65, 0x01, 0x02])
    }

    @Test("Multiple NALs concatenate in order")
    func lengthPrefixConcatenation() {
        let avcc = AnnexB.lengthPrefixed([
            NALUnit(bytes: Data([0x67, 0xAA])),
            NALUnit(bytes: Data([0x65, 0xBB, 0xCC])),
        ])
        #expect([UInt8](avcc) == [0, 0, 0, 2, 0x67, 0xAA, 0, 0, 0, 3, 0x65, 0xBB, 0xCC])
    }

    @Test("Framing and splitting are inverse operations")
    func framingRoundTrip() {
        let original = NALUnit(bytes: Data([0x65] + (0..<64).map { UInt8($0) }))
        let recovered = AnnexB.split(AnnexB.framed(original))
        #expect(recovered.count == 1)
        #expect(recovered.first?.bytes == original.bytes)
    }
}

@Suite("RFC 6184 packetization, mode 1")
struct PacketizerTests {

    /// Payload sizes chosen around the FU-A threshold: below, at, just over, and far over.
    @Test("A NAL at or under the MTU travels as a Single NAL Unit packet",
          arguments: [1, 100, 1399, 1400])
    func singleNALUnitPacket(size: Int) {
        let unit = NALUnit(bytes: Data([0x65] + [UInt8](repeating: 0x41, count: size - 1)))
        let payloads = H264Packetizer(maxPayloadSize: 1400).packetize(accessUnit: [unit])

        #expect(payloads.count == 1)
        #expect(payloads[0] == unit.bytes, "a single NAL packet is the NAL verbatim, no headers added")
    }

    @Test("A NAL over the MTU is fragmented with correct FU-A framing",
          arguments: [1401, 3000, 9000, 65_000])
    func fragmentation(size: Int) throws {
        let mtu = 1400
        let unit = NALUnit(bytes: Data([0x65] + [UInt8](repeating: 0x41, count: size - 1)))
        let payloads = H264Packetizer(maxPayloadSize: mtu).packetize(accessUnit: [unit])

        #expect(payloads.count > 1)

        for (index, payload) in payloads.enumerated() {
            #expect(payload.count <= mtu, "fragment \(index) exceeds the MTU")
            #expect(payload[0] & 0x1F == 28, "FU indicator type must be 28")
            #expect(payload[0] & 0xE0 == 0x60, "F and NRI are copied from the original NAL header")
            #expect(payload[1] & 0x1F == 5, "the FU header carries the original nal_unit_type")
            #expect(payload[1] & 0x20 == 0, "the reserved bit must be zero")

            let start = (payload[1] & 0x80) != 0
            let end = (payload[1] & 0x40) != 0
            #expect(start == (index == 0), "S is set on the first fragment only")
            #expect(end == (index == payloads.count - 1), "E is set on the last fragment only")
        }
    }

    /// TR-10-15 §9: "A UDP/IP packet shall not contain more than one VCL NAL Unit."
    /// We never aggregate, so this holds by construction — asserted so a future STAP-A
    /// optimisation trips the wire instead of silently breaking conformance.
    @Test("Two VCL NALs never share a packet (TR-10-15 §9)")
    func oneVCLPerPacket() {
        let payloads = H264Packetizer(maxPayloadSize: 1400).packetize(accessUnit: [
            NALUnit(bytes: Data([0x65, 0x01, 0x02])),
            NALUnit(bytes: Data([0x41, 0x03, 0x04])),
        ])
        #expect(payloads.count == 2)
    }

    @Test("Empty NAL units are skipped rather than emitted as empty packets")
    func skipsEmptyUnits() {
        let payloads = H264Packetizer(maxPayloadSize: 1400).packetize(accessUnit: [
            NALUnit(bytes: Data()),
            NALUnit(bytes: Data([0x65, 0x01])),
        ])
        #expect(payloads.count == 1)
    }
}

@Suite("Packetizer to depacketizer round trip")
struct RoundTripTests {

    private static let sps = NALUnit(bytes: Data([0x67, 0x42, 0xE0, 0x1F]))
    private static let pps = NALUnit(bytes: Data([0x68, 0xCE, 0x3C, 0x80]))

    private static func slice(_ size: Int) -> NALUnit {
        NALUnit(bytes: Data([0x65] + (0..<size).map { UInt8($0 % 251) }))
    }

    @Test("An access unit survives the round trip byte-identical",
          arguments: [500, 1400, 9000, 40_000])
    func roundTrip(sliceSize: Int) throws {
        let slice = Self.slice(sliceSize)
        let payloads = H264Packetizer(maxPayloadSize: 1400)
            .packetize(accessUnit: [Self.sps, Self.pps, slice])

        let depacketizer = H264Depacketizer()
        var recovered: H264Depacketizer.AccessUnit?
        for (index, payload) in payloads.enumerated() {
            if let unit = depacketizer.push(payload: payload,
                                            timestamp: 900_000,
                                            marker: index == payloads.count - 1,
                                            sequence: UInt16(truncatingIfNeeded: index)) {
                recovered = unit
            }
        }

        let accessUnit = try #require(recovered, "the marker bit should have closed the access unit")
        #expect(!accessUnit.corrupt)
        #expect(accessUnit.timestamp == 900_000)
        #expect(accessUnit.units.count == 3)
        #expect(accessUnit.units[0].bytes == Self.sps.bytes)
        #expect(accessUnit.units[1].bytes == Self.pps.bytes)
        #expect(accessUnit.units[2].bytes == slice.bytes)
        #expect(depacketizer.lostPackets == 0)
    }

    @Test("A dropped fragment marks the access unit corrupt and is counted")
    func sequenceGapIsDetected() throws {
        let payloads = H264Packetizer(maxPayloadSize: 1400).packetize(accessUnit: [Self.slice(5000)])
        #expect(payloads.count > 2)

        let depacketizer = H264Depacketizer()
        var recovered: H264Depacketizer.AccessUnit?
        for (index, payload) in payloads.enumerated() where index != 1 {   // drop one fragment
            if let unit = depacketizer.push(payload: payload,
                                            timestamp: 900_000,
                                            marker: index == payloads.count - 1,
                                            sequence: UInt16(index)) {
                recovered = unit
            }
        }

        let accessUnit = try #require(recovered)
        #expect(accessUnit.corrupt)
        #expect(depacketizer.lostPackets == 1)
    }

    /// A frame whose every packet was lost must still surface, otherwise the drop is
    /// invisible to the receiver's statistics.
    @Test("An access unit that lost all of its content still surfaces as corrupt")
    func totalLossStillReported() throws {
        let payloads = H264Packetizer(maxPayloadSize: 1400).packetize(accessUnit: [Self.slice(5000)])
        let depacketizer = H264Depacketizer()

        // Deliver the first fragment, lose everything in between, deliver only the marked one.
        _ = depacketizer.push(payload: payloads[0], timestamp: 900_000, marker: false, sequence: 0)
        let recovered = depacketizer.push(payload: payloads[payloads.count - 1],
                                          timestamp: 900_000,
                                          marker: true,
                                          sequence: UInt16(payloads.count - 1))

        let accessUnit = try #require(recovered, "a fully lost frame must not vanish silently")
        #expect(accessUnit.corrupt)
        #expect(accessUnit.units.isEmpty)
        #expect(depacketizer.lostPackets > 0)
    }

    @Test("A timestamp change closes the previous access unit when its marker was lost")
    func timestampChangeFlushes() throws {
        let depacketizer = H264Depacketizer()

        // First frame, marker bit lost.
        _ = depacketizer.push(payload: Data([0x65, 0x01]), timestamp: 900_000, marker: false, sequence: 0)
        // Second frame begins.
        let recovered = depacketizer.push(payload: Data([0x65, 0x02]), timestamp: 903_000, marker: false, sequence: 1)

        let accessUnit = try #require(recovered)
        #expect(accessUnit.timestamp == 900_000, "the flushed unit carries the old timestamp")
        #expect(accessUnit.corrupt, "a missing marker means we cannot vouch for completeness")
    }

    @Test("Sequence numbers wrapping past 65535 are not mistaken for loss")
    func sequenceWrap() {
        let depacketizer = H264Depacketizer()
        _ = depacketizer.push(payload: Data([0x65, 0x01]), timestamp: 900_000, marker: true, sequence: 65535)
        _ = depacketizer.push(payload: Data([0x65, 0x02]), timestamp: 903_000, marker: true, sequence: 0)
        #expect(depacketizer.lostPackets == 0)
    }

    @Test("STAP-A on ingest is unpacked even though we never produce it")
    func stapAIngest() throws {
        // STAP-A carrying an SPS and a PPS, as many third-party senders emit.
        var stapA = Data([0x78])                       // F=0 NRI=3 type=24
        stapA.append(contentsOf: [0x00, 0x04, 0x67, 0x42, 0xE0, 0x1F])
        stapA.append(contentsOf: [0x00, 0x04, 0x68, 0xCE, 0x3C, 0x80])

        let depacketizer = H264Depacketizer()
        let recovered = depacketizer.push(payload: stapA, timestamp: 900_000, marker: true, sequence: 0)

        let accessUnit = try #require(recovered)
        #expect(accessUnit.units.count == 2)
        #expect(accessUnit.units[0].typeValue == H264NALType.sps.rawValue)
        #expect(accessUnit.units[1].typeValue == H264NALType.pps.rawValue)
    }
}
