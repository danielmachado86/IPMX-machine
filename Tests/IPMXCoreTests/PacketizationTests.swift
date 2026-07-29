import Foundation
import Testing
@testable import IPMXCore

@Suite("NAL unit header interpretation")
struct NALHeaderTests {

    @Test("H.264 reads the type from the low 5 bits of one byte", arguments: [
        (UInt8(0x67), H264NALType.sps, false, true),
        (UInt8(0x68), H264NALType.pps, false, true),
        (UInt8(0x65), H264NALType.idrSlice, true, false),
        (UInt8(0x41), H264NALType.nonIDRSlice, true, false),
        (UInt8(0x06), H264NALType.sei, false, false),
        (UInt8(0x09), H264NALType.aud, false, false),
    ])
    func h264Classification(header: UInt8, expected: H264NALType, isVCL: Bool, isParameterSet: Bool) {
        let unit = NALUnit(bytes: Data([header, 0x00]), codec: .h264)
        #expect(unit.h264Type == expected)
        #expect(unit.isVCL == isVCL)
        #expect(unit.isParameterSet == isParameterSet)
    }

    /// The whole reason NALUnit carries its codec: the same first byte means different things.
    /// 0x40 is an H.264 non-IDR slice with nal_ref_idc 2, and an H.265 VPS.
    @Test("H.265 reads the type from bits 6..1 of a two-byte header", arguments: [
        (H265NALType.vps, false, true),
        (H265NALType.sps, false, true),
        (H265NALType.pps, false, true),
        (H265NALType.idrWRADL, true, false),
        (H265NALType.craNUT, true, false),
        (H265NALType.trailR, true, false),
        (H265NALType.prefixSEI, false, false),
        (H265NALType.aud, false, false),
    ])
    func h265Classification(type: H265NALType, isVCL: Bool, isParameterSet: Bool) {
        let unit = TestNAL.h265(type: type.rawValue)
        #expect(unit.h265Type == type)
        #expect(unit.typeValue == type.rawValue)
        #expect(unit.isVCL == isVCL)
        #expect(unit.isParameterSet == isParameterSet)
    }

    @Test("The same first byte is read differently by each codec")
    func codecChangesInterpretation() {
        let bytes = Data([0x40, 0x01, 0xAA])
        #expect(NALUnit(bytes: bytes, codec: .h264).typeValue == 0)      // 0x40 & 0x1F
        #expect(NALUnit(bytes: bytes, codec: .h265).typeValue == 32)     // (0x40 >> 1) & 0x3F -> VPS
        #expect(NALUnit(bytes: bytes, codec: .h265).h265Type == .vps)
    }

    @Test("IRAP types are the H.265 random access points", arguments: [
        (H265NALType.blaWLP.rawValue, true),
        (H265NALType.idrWRADL.rawValue, true),
        (H265NALType.idrNLP.rawValue, true),
        (H265NALType.craNUT.rawValue, true),
        (UInt8(23), true),                              // reserved IRAP
        (UInt8(24), false),                             // reserved non-IRAP VCL
        (H265NALType.trailR.rawValue, false),
    ])
    func h265RandomAccess(type: UInt8, isKeyframe: Bool) {
        #expect(TestNAL.h265(type: type).isKeyframe == isKeyframe)
    }

    @Test("nuh_layer_id and nuh_temporal_id_plus1 are decoded from the second byte")
    func h265LayerAndTemporalID() {
        let unit = TestNAL.h265(type: 19, layerID: 37, temporalIDPlus1: 5)
        #expect(unit.layerID == 37)
        #expect(unit.temporalIDPlus1 == 5)
        #expect(unit.typeValue == 19)
    }

    @Test("A NAL shorter than its own header is rejected rather than misread")
    func malformedUnits() {
        #expect(!NALUnit(bytes: Data(), codec: .h264).isWellFormed)
        #expect(!NALUnit(bytes: Data([0x26]), codec: .h265).isWellFormed, "H.265 needs two header bytes")
        #expect(NALUnit(bytes: Data([0x65]), codec: .h264).isWellFormed)
        #expect(!NALUnit(bytes: Data([0x26]), codec: .h265).isVCL)
    }
}

@Suite("Annex B bitstream handling")
struct AnnexBTests {

    @Test("Both 3-byte and 4-byte start codes are recognised", arguments: VideoCodec.allCases)
    func mixedStartCodes(codec: VideoCodec) {
        let sets = TestNAL.parameterSets(codec: codec)
        var stream = Data()
        for (index, unit) in sets.enumerated() {
            // Alternate the start code length the way a real encoder does.
            stream.append(index % 2 == 0 ? Data([0, 0, 0, 1]) : Data([0, 0, 1]))
            stream.append(unit.bytes)
        }

        let recovered = AnnexB.split(stream, codec: codec)
        #expect(recovered.count == sets.count)
        #expect(recovered.map(\.bytes) == sets.map(\.bytes))
        #expect(recovered.allSatisfy { $0.isParameterSet })
    }

    @Test("A stream with no start code yields nothing")
    func noStartCode() {
        #expect(AnnexB.split(Data([0x67, 0xAA, 0xBB]), codec: .h264).isEmpty)
        #expect(AnnexB.split(Data(), codec: .h265).isEmpty)
    }

    @Test("The AVCC/HVCC length prefix is 4 bytes big-endian, matching nalUnitHeaderLength")
    func lengthPrefix() {
        let avcc = AnnexB.lengthPrefixed([NALUnit(bytes: Data([0x65, 0x01, 0x02]), codec: .h264)])
        #expect([UInt8](avcc) == [0x00, 0x00, 0x00, 0x03, 0x65, 0x01, 0x02])
    }

    @Test("Framing and splitting are inverse operations", arguments: VideoCodec.allCases)
    func framingRoundTrip(codec: VideoCodec) {
        let original = TestNAL.slice(codec: codec, size: 64)
        let recovered = AnnexB.split(AnnexB.framed(original), codec: codec)
        #expect(recovered.count == 1)
        #expect(recovered.first?.bytes == original.bytes)
    }
}

@Suite("RFC 6184 / RFC 7798 packetization")
struct PacketizerTests {

    @Test("A NAL at or under the MTU travels as a Single NAL Unit packet",
          arguments: VideoCodec.allCases, [8, 100, 1399, 1400])
    func singleNALUnitPacket(codec: VideoCodec, size: Int) {
        let unit = TestNAL.slice(codec: codec, size: size)
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: 1400).packetize(accessUnit: [unit])

        #expect(payloads.count == 1)
        #expect(payloads[0] == unit.bytes, "a single NAL packet is the NAL verbatim, no headers added")
    }

    @Test("A NAL over the MTU is fragmented and never exceeds it",
          arguments: VideoCodec.allCases, [1401, 3000, 9000, 65_000])
    func fragmentationRespectsMTU(codec: VideoCodec, size: Int) {
        let mtu = 1400
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: mtu)
            .packetize(accessUnit: [TestNAL.slice(codec: codec, size: size)])

        #expect(payloads.count > 1)
        #expect(payloads.allSatisfy { $0.count <= mtu })
    }

    /// FU-A: one-byte FU indicator (F/NRI copied, type 28) plus a one-byte FU header.
    @Test("H.264 FU-A framing is correct on every fragment")
    func h264FragmentFraming() {
        let payloads = VideoPacketizer(codec: .h264, maxPayloadSize: 1400)
            .packetize(accessUnit: [TestNAL.slice(codec: .h264, size: 5000)])

        for (index, payload) in payloads.enumerated() {
            #expect(payload[0] & 0x1F == 28, "FU indicator type must be 28")
            #expect(payload[0] & 0xE0 == 0x60, "F and NRI are copied from the NAL header")
            #expect(payload[1] & 0x1F == H264NALType.idrSlice.rawValue, "the FU header carries the original type")
            #expect(payload[1] & 0x20 == 0, "the reserved bit must be zero")
            #expect(((payload[1] & 0x80) != 0) == (index == 0), "S is set on the first fragment only")
            #expect(((payload[1] & 0x40) != 0) == (index == payloads.count - 1), "E is set on the last only")
        }
    }

    /// FU: two-byte PayloadHdr (type replaced by 49, F/LayerId/TID preserved) plus a
    /// one-byte FU header. One byte more overhead than H.264.
    @Test("H.265 FU framing preserves layer and temporal id")
    func h265FragmentFraming() {
        let original = TestNAL.h265(type: H265NALType.idrWRADL.rawValue,
                                    layerID: 0, temporalIDPlus1: 1, payloadBytes: 5000)
        let payloads = VideoPacketizer(codec: .h265, maxPayloadSize: 1400).packetize(accessUnit: [original])

        for (index, payload) in payloads.enumerated() {
            #expect((payload[0] >> 1) & 0x3F == 49, "PayloadHdr type must be 49")
            #expect(payload[0] & 0x80 == 0, "the forbidden bit is carried through as zero")
            #expect(payload[1] == original.bytes[1], "nuh_layer_id and TID must survive untouched")
            #expect(payload[2] & 0x3F == H265NALType.idrWRADL.rawValue, "the FU header carries the original type")
            #expect(((payload[2] & 0x80) != 0) == (index == 0), "S is set on the first fragment only")
            #expect(((payload[2] & 0x40) != 0) == (index == payloads.count - 1), "E is set on the last only")
        }
    }

    @Test("H.265 fragmentation costs one byte more per packet than H.264")
    func fragmentOverheadDiffers() {
        let size = 60_000
        let h264 = VideoPacketizer(codec: .h264, maxPayloadSize: 1400)
            .packetize(accessUnit: [TestNAL.slice(codec: .h264, size: size)])
        let h265 = VideoPacketizer(codec: .h265, maxPayloadSize: 1400)
            .packetize(accessUnit: [TestNAL.slice(codec: .h265, size: size)])

        #expect(h264[0].count == 1400)
        #expect(h265[0].count == 1400)
        // Same MTU, one more header byte, so H.265 carries slightly less payload per packet.
        #expect(h265.count >= h264.count)
    }

    /// TR-10-15 §9, both parts: "A UDP/IP packet shall not contain more than one VCL NAL
    /// Unit." We never aggregate, so this holds by construction — asserted so a future
    /// STAP-A/AP optimisation trips the wire instead of silently breaking conformance.
    @Test("Two VCL NALs never share a packet (TR-10-15 §9)", arguments: VideoCodec.allCases)
    func oneVCLPerPacket(codec: VideoCodec) {
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: 1400).packetize(accessUnit: [
            TestNAL.slice(codec: codec, size: 20),
            TestNAL.slice(codec: codec, size: 20),
        ])
        #expect(payloads.count == 2)
    }

    @Test("Malformed NAL units are skipped rather than emitted", arguments: VideoCodec.allCases)
    func skipsMalformedUnits(codec: VideoCodec) {
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: 1400).packetize(accessUnit: [
            NALUnit(bytes: Data(), codec: codec),
            NALUnit(bytes: Data([0x26]), codec: codec),      // too short for an H.265 header
            TestNAL.slice(codec: codec, size: 20),
        ])
        #expect(payloads.count == (codec == .h264 ? 2 : 1))
    }
}

@Suite("Packetizer to depacketizer round trip")
struct RoundTripTests {

    @Test("An access unit survives the round trip byte-identical",
          arguments: VideoCodec.allCases, [500, 1400, 9000, 40_000])
    func roundTrip(codec: VideoCodec, sliceSize: Int) throws {
        let sent = TestNAL.parameterSets(codec: codec) + [TestNAL.slice(codec: codec, size: sliceSize)]
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: 1400).packetize(accessUnit: sent)

        let depacketizer = VideoDepacketizer(codec: codec)
        var recovered: AccessUnit?
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
        #expect(accessUnit.units.map(\.bytes) == sent.map(\.bytes))
        #expect(accessUnit.units.allSatisfy { $0.codec == codec })
        #expect(depacketizer.lostPackets == 0)
    }

    @Test("A fragmented H.265 NAL is reassembled with its original header bit for bit")
    func h265HeaderReconstruction() throws {
        let original = TestNAL.h265(type: H265NALType.craNUT.rawValue,
                                    layerID: 21, temporalIDPlus1: 4, payloadBytes: 7000)
        let payloads = VideoPacketizer(codec: .h265, maxPayloadSize: 1400).packetize(accessUnit: [original])

        let depacketizer = VideoDepacketizer(codec: .h265)
        var recovered: AccessUnit?
        for (index, payload) in payloads.enumerated() {
            if let unit = depacketizer.push(payload: payload, timestamp: 900_000,
                                            marker: index == payloads.count - 1,
                                            sequence: UInt16(index)) {
                recovered = unit
            }
        }

        let unit = try #require(recovered?.units.first)
        #expect(unit.bytes == original.bytes)
        #expect(unit.typeValue == H265NALType.craNUT.rawValue)
        #expect(unit.layerID == 21)
        #expect(unit.temporalIDPlus1 == 4)
    }

    @Test("A dropped fragment marks the access unit corrupt and is counted",
          arguments: VideoCodec.allCases)
    func sequenceGapIsDetected(codec: VideoCodec) throws {
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: 1400)
            .packetize(accessUnit: [TestNAL.slice(codec: codec, size: 5000)])
        #expect(payloads.count > 2)

        let depacketizer = VideoDepacketizer(codec: codec)
        var recovered: AccessUnit?
        for (index, payload) in payloads.enumerated() where index != 1 {
            if let unit = depacketizer.push(payload: payload, timestamp: 900_000,
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
    @Test("An access unit that lost all of its content still surfaces as corrupt",
          arguments: VideoCodec.allCases)
    func totalLossStillReported(codec: VideoCodec) throws {
        let payloads = VideoPacketizer(codec: codec, maxPayloadSize: 1400)
            .packetize(accessUnit: [TestNAL.slice(codec: codec, size: 5000)])
        let depacketizer = VideoDepacketizer(codec: codec)

        _ = depacketizer.push(payload: payloads[0], timestamp: 900_000, marker: false, sequence: 0)
        let recovered = depacketizer.push(payload: payloads[payloads.count - 1],
                                          timestamp: 900_000, marker: true,
                                          sequence: UInt16(payloads.count - 1))

        let accessUnit = try #require(recovered, "a fully lost frame must not vanish silently")
        #expect(accessUnit.corrupt)
        #expect(accessUnit.units.isEmpty)
        #expect(depacketizer.lostPackets > 0)
    }

    @Test("A timestamp change closes the previous access unit when its marker was lost",
          arguments: VideoCodec.allCases)
    func timestampChangeFlushes(codec: VideoCodec) throws {
        let depacketizer = VideoDepacketizer(codec: codec)
        let first = TestNAL.slice(codec: codec, size: 20)
        let second = TestNAL.slice(codec: codec, size: 20)

        _ = depacketizer.push(payload: first.bytes, timestamp: 900_000, marker: false, sequence: 0)
        let recovered = depacketizer.push(payload: second.bytes, timestamp: 901_500, marker: false, sequence: 1)

        let accessUnit = try #require(recovered)
        #expect(accessUnit.timestamp == 900_000, "the flushed unit carries the old timestamp")
        #expect(accessUnit.corrupt, "a missing marker means we cannot vouch for completeness")
    }

    @Test("Sequence numbers wrapping past 65535 are not mistaken for loss",
          arguments: VideoCodec.allCases)
    func sequenceWrap(codec: VideoCodec) {
        let depacketizer = VideoDepacketizer(codec: codec)
        let unit = TestNAL.slice(codec: codec, size: 20)
        _ = depacketizer.push(payload: unit.bytes, timestamp: 900_000, marker: true, sequence: 65535)
        _ = depacketizer.push(payload: unit.bytes, timestamp: 901_500, marker: true, sequence: 0)
        #expect(depacketizer.lostPackets == 0)
    }

    @Test("H.264 STAP-A on ingest is unpacked even though we never produce it")
    func stapAIngest() throws {
        var stapA = Data([0x78])                       // F=0 NRI=3 type=24
        stapA.append(contentsOf: [0x00, 0x04, 0x67, 0x42, 0xE0, 0x1F])
        stapA.append(contentsOf: [0x00, 0x04, 0x68, 0xCE, 0x3C, 0x80])

        let depacketizer = VideoDepacketizer(codec: .h264)
        let accessUnit = try #require(depacketizer.push(payload: stapA, timestamp: 900_000,
                                                        marker: true, sequence: 0))
        #expect(accessUnit.units.count == 2)
        #expect(accessUnit.units[0].typeValue == H264NALType.sps.rawValue)
        #expect(accessUnit.units[1].typeValue == H264NALType.pps.rawValue)
    }

    @Test("H.265 AP on ingest is unpacked even though we never produce it")
    func aggregationPacketIngest() throws {
        let vps = TestNAL.h265(type: H265NALType.vps.rawValue, payloadBytes: 2)
        let sps = TestNAL.h265(type: H265NALType.sps.rawValue, payloadBytes: 2)

        var ap = Data([(48 << 1) as UInt8, 0x01])      // PayloadHdr with type 48
        for unit in [vps, sps] {
            ap.append(UInt8(unit.bytes.count >> 8))
            ap.append(UInt8(unit.bytes.count & 0xFF))
            ap.append(unit.bytes)
        }

        let depacketizer = VideoDepacketizer(codec: .h265)
        let accessUnit = try #require(depacketizer.push(payload: ap, timestamp: 900_000,
                                                        marker: true, sequence: 0))
        #expect(accessUnit.units.count == 2)
        #expect(accessUnit.units[0].bytes == vps.bytes)
        #expect(accessUnit.units[1].bytes == sps.bytes)
    }

    /// TR-10-15 Part 2 §9 forbids a sender from producing PACI. Dropping it rather than
    /// attempting to unwrap keeps a non-conformant sender from corrupting our stream.
    @Test("H.265 PACI is dropped and flags the access unit corrupt")
    func paciIsRejected() throws {
        var paci = Data([(50 << 1) as UInt8, 0x01])
        paci.append(contentsOf: [0x00, 0x00, 0xAA, 0xBB])

        let depacketizer = VideoDepacketizer(codec: .h265)
        let accessUnit = try #require(depacketizer.push(payload: paci, timestamp: 900_000,
                                                        marker: true, sequence: 0))
        #expect(accessUnit.units.isEmpty)
        #expect(accessUnit.corrupt)
    }
}
