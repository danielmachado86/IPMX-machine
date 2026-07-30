import Foundation
import Testing
@testable import IPMXCore

@Suite("Bit reader and writer")
struct BitstreamTests {

    @Test("Fixed-width fields round-trip", arguments: [
        (UInt32(0), 1), (1, 1), (5, 3), (0xFF, 8), (0xDEAD, 16),
        (0xDEADBEEF, 32), (0, 32), (0xFFFFFFFF, 32),
    ])
    func fixedWidthRoundTrip(value: UInt32, bits: Int) throws {
        var writer = BitWriter()
        writer.write(value, bits: bits)
        writer.writeRBSPTrailingBits()

        var reader = BitReader(writer.data)
        #expect(try reader.u(bits) == value)
    }

    @Test("Exp-Golomb round-trips", arguments: [
        UInt32(0), 1, 2, 3, 4, 7, 8, 100, 1000, 65535, 100_000,
    ])
    func expGolombRoundTrip(value: UInt32) throws {
        var writer = BitWriter()
        writer.writeUE(value)
        writer.writeRBSPTrailingBits()

        var reader = BitReader(writer.data)
        #expect(try reader.ue() == value)
    }

    /// The canonical encodings from H.264 Table 9-1, so a subtle off-by-one in the writer
    /// cannot hide behind a symmetric bug in the reader.
    @Test("ue(v) matches the canonical bit patterns")
    func expGolombEncoding() {
        var writer = BitWriter()
        writer.writeUE(0)                       // 1
        writer.writeUE(1)                       // 010
        writer.writeUE(2)                       // 011
        writer.writeUE(3)                       // 00100
        // 1 010 011 00100 -> 1010 0110 0100 , padded to 16 bits
        #expect([UInt8](writer.data) == [0b10100110, 0b01000000])
    }

    @Test("se(v) round-trips over negatives and positives", arguments: [
        Int32(0), 1, -1, 2, -2, 3, -3, 128, -128, 30000, -30000,
    ])
    func signedExpGolombRoundTrip(value: Int32) throws {
        // se(v) is derived from ue(v): 0, 1, -1, 2, -2, ...
        let mapped = value > 0 ? UInt32(value) * 2 - 1 : UInt32(-value) * 2
        var writer = BitWriter()
        writer.writeUE(mapped)
        writer.writeRBSPTrailingBits()

        var reader = BitReader(writer.data)
        #expect(try reader.se() == value)
    }

    @Test("Reads past the end throw instead of returning junk")
    func outOfBounds() {
        var reader = BitReader(Data([0xFF]))
        #expect(throws: BitstreamError.self) { try reader.u(9) }
    }

    @Test("A run of zero bits never terminates an Exp-Golomb code")
    func malformedExpGolomb() {
        var reader = BitReader(Data(repeating: 0x00, count: 8))
        #expect(throws: BitstreamError.self) { try reader.ue() }
    }

    @Test("bitPosition tracks unaligned reads")
    func bitPositionTracking() throws {
        var reader = BitReader(Data([0b10110010, 0b11000000]))
        _ = try reader.u(3)
        #expect(reader.bitPosition == 3)
        _ = try reader.u(7)
        #expect(reader.bitPosition == 10)
        #expect(reader.bitsRemaining == 6)
    }

    @Test("Copying bits verbatim preserves an unaligned prefix")
    func copyBits() throws {
        let source = Data([0b10110010, 0b11010101, 0b00001111])
        var reader = BitReader(source)
        var writer = BitWriter()
        try writer.copy(bits: 13, from: &reader)

        var check = BitReader(writer.data)
        var original = BitReader(source)
        for _ in 0..<13 {
            #expect(try check.u(1) == (try original.u(1)))
        }
    }

    @Test("rbsp_trailing_bits writes a stop bit then pads to the byte")
    func trailingBits() {
        var writer = BitWriter()
        writer.write(0b101, bits: 3)
        writer.writeRBSPTrailingBits()
        #expect([UInt8](writer.data) == [0b10110000])
        #expect(writer.data.count == 1)
    }
}

@Suite("Emulation prevention")
struct RBSPTests {

    @Test("Escaping inserts 0x03 where the start code scanner would trip", arguments: [
        ([0x00, 0x00, 0x00] as [UInt8], [0x00, 0x00, 0x03, 0x00] as [UInt8]),
        ([0x00, 0x00, 0x01], [0x00, 0x00, 0x03, 0x01]),
        ([0x00, 0x00, 0x02], [0x00, 0x00, 0x03, 0x02]),
        ([0x00, 0x00, 0x03], [0x00, 0x00, 0x03, 0x03]),
        ([0x00, 0x00, 0x04], [0x00, 0x00, 0x04]),          // 0x04 is safe, no EPB needed
        ([0xAA, 0xBB], [0xAA, 0xBB]),
        ([0x00, 0x01], [0x00, 0x01]),                      // one zero is not enough
    ])
    func escaping(rbsp: [UInt8], expected: [UInt8]) {
        #expect([UInt8](RBSP.escape(Data(rbsp))) == expected)
    }

    @Test("Unescaping removes them again", arguments: [
        ([0x00, 0x00, 0x03, 0x01] as [UInt8], [0x00, 0x00, 0x01] as [UInt8]),
        ([0x00, 0x00, 0x03, 0x00], [0x00, 0x00, 0x00]),
        ([0xAA, 0xBB, 0xCC], [0xAA, 0xBB, 0xCC]),
        ([0x00, 0x03, 0x01], [0x00, 0x03, 0x01]),          // only one zero, not an EPB
        ([0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x01], [0x00, 0x00, 0x00, 0x00, 0x01]),
    ])
    func unescaping(escaped: [UInt8], expected: [UInt8]) {
        #expect([UInt8](RBSP.unescape(Data(escaped))) == expected)
    }

    @Test("escape and unescape are inverses over adversarial payloads", arguments: [
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00] as [UInt8],
        [0x00, 0x00, 0x01, 0x00, 0x00, 0x02],
        [0x00, 0x00, 0x03, 0x00, 0x00, 0x03],
        [0xFF, 0x00, 0x00, 0x00, 0xFF],
        Array(repeating: 0x00, count: 32),
    ])
    func roundTrip(rbsp: [UInt8]) {
        let escaped = RBSP.escape(Data(rbsp))
        #expect([UInt8](RBSP.unescape(escaped)) == rbsp)

        // H.265 §7.4.2 forbids 00 00 00, 00 00 01 and 00 00 02 inside a NAL. 00 00 03 is
        // legal — it *is* the escape sequence — so the bound is 0x02, not 0x03.
        let bytes = [UInt8](escaped)
        for index in 0..<max(0, bytes.count - 2) {
            let forbidden = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] <= 0x02
            #expect(!forbidden, "escaped payload still trips the start code scanner at \(index)")
        }
    }
}

@Suite("H.265 VPS timing (TR-10-15 Part 2 §10)")
struct HEVCVideoParameterSetTests {

    /// Builds a minimal but syntactically valid VPS, with vps_max_sub_layers_minus1 = 0.
    static func makeVPS(timingPresent: Bool,
                        numUnitsInTick: UInt32 = 1,
                        timeScale: UInt32 = 60,
                        extensionFlag: Bool = false) -> NALUnit {
        var writer = BitWriter()
        writer.write(0, bits: 4)                    // vps_video_parameter_set_id
        writer.write(0b11, bits: 2)                 // base layer internal / available
        writer.write(0, bits: 6)                    // vps_max_layers_minus1
        writer.write(0, bits: 3)                    // vps_max_sub_layers_minus1
        writer.write(1, bits: 1)                    // vps_temporal_id_nesting_flag
        writer.write(0xFFFF, bits: 16)              // vps_reserved_0xffff_16bits

        // profile_tier_level(1, 0): 8 + 32 + 48 + 8 bits, Main profile at level 4.1.
        writer.write(0, bits: 2)                    // general_profile_space
        writer.write(0, bits: 1)                    // general_tier_flag
        writer.write(1, bits: 5)                    // general_profile_idc = Main
        writer.write(0x60000000, bits: 32)          // compatibility flags
        writer.write(1, bits: 1)                    // progressive_source_flag
        writer.write(0, bits: 1)                    // interlaced_source_flag
        writer.write(0, bits: 1)                    // non_packed_constraint_flag
        writer.write(1, bits: 1)                    // frame_only_constraint_flag
        writer.write(0, bits: 22)                   // reserved
        writer.write(0, bits: 22)                   // reserved + inbld
        writer.write(123, bits: 8)                  // general_level_idc

        writer.write(1, bits: 1)                    // vps_sub_layer_ordering_info_present_flag
        writer.writeUE(1)                           // vps_max_dec_pic_buffering_minus1
        writer.writeUE(0)                           // vps_max_num_reorder_pics
        writer.writeUE(0)                           // vps_max_latency_increase_plus1
        writer.write(0, bits: 6)                    // vps_max_layer_id
        writer.writeUE(0)                           // vps_num_layer_sets_minus1

        writer.write(timingPresent ? 1 : 0, bits: 1)
        if timingPresent {
            writer.write(numUnitsInTick, bits: 32)
            writer.write(timeScale, bits: 32)
            writer.write(0, bits: 1)                // vps_poc_proportional_to_timing_flag
            writer.writeUE(0)                       // vps_num_hrd_parameters
        }
        writer.write(extensionFlag ? 1 : 0, bits: 1)
        writer.writeRBSPTrailingBits()

        var bytes = Data([0x40, 0x01])              // NAL header, type 32
        bytes.append(RBSP.escape(writer.data))
        return NALUnit(bytes: bytes, codec: .h265)
    }

    @Test("Timing is read back out of a VPS that carries it", arguments: [
        (UInt32(1), UInt32(60)), (1, 50), (1, 30), (1001, 60000),
    ])
    func readsTiming(numUnitsInTick: UInt32, timeScale: UInt32) throws {
        let vps = Self.makeVPS(timingPresent: true,
                               numUnitsInTick: numUnitsInTick, timeScale: timeScale)
        let timing = try #require(HEVCVideoParameterSet.timingInfo(vps))
        #expect(timing.numUnitsInTick == numUnitsInTick)
        #expect(timing.timeScale == timeScale)
    }

    @Test("A VPS without timing reads as nil")
    func readsAbsentTiming() {
        #expect(HEVCVideoParameterSet.timingInfo(Self.makeVPS(timingPresent: false)) == nil)
    }

    /// The whole point: x265 emits no VPS timing, so it has to be inserted, and the fields sit
    /// 66 bits from the end of an unaligned syntax.
    @Test("Rewriting inserts timing that reads back correctly", arguments: [30, 50, 60])
    func rewriteInsertsTiming(frameRate: Int) throws {
        let original = Self.makeVPS(timingPresent: false)
        #expect(HEVCVideoParameterSet.timingInfo(original) == nil)

        guard case .rewritten(let patched) = HEVCVideoParameterSet.ensuringTimingInfo(
            original, numUnitsInTick: 1, timeScale: UInt32(frameRate)) else {
            Issue.record("expected a rewrite")
            return
        }

        let timing = try #require(HEVCVideoParameterSet.timingInfo(patched))
        #expect(timing.numUnitsInTick == 1)
        #expect(timing.timeScale == UInt32(frameRate))
        #expect(timing.frameRate == Double(frameRate),
                "H.265 has no factor of two, unlike the H.264 VUI")

        #expect(patched.typeValue == H265NALType.vps.rawValue, "still a VPS")
        #expect(patched.bytes.prefix(2) == original.bytes.prefix(2), "NAL header untouched")
        #expect(patched.bytes.count > original.bytes.count, "66 bits of payload were added")
    }

    @Test("Everything before the timing flag survives the rewrite bit for bit")
    func rewritePreservesPrefix() throws {
        let original = Self.makeVPS(timingPresent: false)
        guard case .rewritten(let patched) = HEVCVideoParameterSet.ensuringTimingInfo(
            original, numUnitsInTick: 1, timeScale: 60) else {
            Issue.record("expected a rewrite")
            return
        }

        // The prefix runs to vps_num_layer_sets_minus1; comparing the first 120 bits of RBSP
        // covers the whole profile_tier_level and the ordering info.
        var before = BitReader(RBSP.unescape(original.bytes.dropFirst(2)))
        var after = BitReader(RBSP.unescape(patched.bytes.dropFirst(2)))
        for bit in 0..<120 {
            #expect(try before.u(1) == (try after.u(1)), "bit \(bit) changed")
        }
    }

    @Test("A VPS that already has timing is left alone")
    func alreadyPresent() {
        let vps = Self.makeVPS(timingPresent: true, numUnitsInTick: 1, timeScale: 50)
        guard case .alreadyPresent(let timing) = HEVCVideoParameterSet.ensuringTimingInfo(
            vps, numUnitsInTick: 1, timeScale: 60) else {
            Issue.record("expected alreadyPresent")
            return
        }
        #expect(timing.timeScale == 50, "the existing value is reported, not the requested one")
    }

    /// Extension data would have to be carried across the insertion. Refusing beats mangling.
    @Test("A VPS with vps_extension_flag set is refused rather than mangled")
    func refusesExtension() {
        let vps = Self.makeVPS(timingPresent: false, extensionFlag: true)
        guard case .unsupported(let reason) = HEVCVideoParameterSet.ensuringTimingInfo(
            vps, numUnitsInTick: 1, timeScale: 60) else {
            Issue.record("expected unsupported")
            return
        }
        #expect(reason.contains("vps_extension_flag"))
    }

    @Test("Non-VPS NAL units are refused", arguments: [
        H265NALType.sps.rawValue, H265NALType.pps.rawValue, H265NALType.idrWRADL.rawValue,
    ])
    func refusesNonVPS(type: UInt8) {
        let unit = TestNAL.h265(type: type)
        #expect(HEVCVideoParameterSet.timingInfo(unit) == nil)
        guard case .unsupported = HEVCVideoParameterSet.ensuringTimingInfo(
            unit, numUnitsInTick: 1, timeScale: 60) else {
            Issue.record("expected unsupported for NAL type \(type)")
            return
        }
    }

    @Test("An H.264 NAL is refused even if its bytes look like a VPS")
    func refusesWrongCodec() {
        let unit = NALUnit(bytes: Self.makeVPS(timingPresent: false).bytes, codec: .h264)
        guard case .unsupported = HEVCVideoParameterSet.ensuringTimingInfo(
            unit, numUnitsInTick: 1, timeScale: 60) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("Truncated input is refused instead of crashing")
    func refusesTruncated() {
        for length in 2...12 {
            let truncated = NALUnit(bytes: Self.makeVPS(timingPresent: false).bytes.prefix(length),
                                    codec: .h265)
            _ = HEVCVideoParameterSet.timingInfo(truncated)      // must not trap
            _ = HEVCVideoParameterSet.ensuringTimingInfo(truncated, numUnitsInTick: 1, timeScale: 60)
        }
    }

    /// timeScale = 1 puts three zero bytes into the payload, which forces the escaper to add an
    /// emulation prevention byte inside the region we just wrote.
    @Test("The rewrite stays valid when the inserted bytes need emulation prevention")
    func rewriteHandlesEmulationPrevention() throws {
        let original = Self.makeVPS(timingPresent: false)
        guard case .rewritten(let patched) = HEVCVideoParameterSet.ensuringTimingInfo(
            original, numUnitsInTick: 1, timeScale: 1) else {
            Issue.record("expected a rewrite")
            return
        }

        let bytes = [UInt8](patched.bytes)
        for index in 0..<max(0, bytes.count - 2) {
            let forbidden = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] <= 0x02
            #expect(!forbidden, "the patched VPS trips the start code scanner at \(index)")
        }

        let timing = try #require(HEVCVideoParameterSet.timingInfo(patched))
        #expect(timing.numUnitsInTick == 1)
        #expect(timing.timeScale == 1)
    }
}
