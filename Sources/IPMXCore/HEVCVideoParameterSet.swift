import Foundation

/// Reads and, when necessary, rewrites the timing info in an H.265 Video Parameter Set.
///
/// Why this exists: TR-10-15 Part 2 §10 requires
///
///   "vps_timing_info_present_flag shall equal 1 and vps_num_units_in_tick shall be equal to
///    the frame rate denominator, vps_time_scale shall be equal to the frame rate numerator"
///
/// and libx265 has no public API for VPS timing at all — only the VUI equivalents. So the only
/// way to ship a conformant H.265 sender on top of x265 is to patch the VPS after the encoder
/// emits it. The fields land 66 bits from the end of the syntax, which is not byte aligned, so
/// the whole RBSP has to be rebuilt with a bit writer rather than spliced.
public enum HEVCVideoParameterSet {

    public struct TimingInfo: Equatable, Sendable {
        public let numUnitsInTick: UInt32
        public let timeScale: UInt32

        public init(numUnitsInTick: UInt32, timeScale: UInt32) {
            self.numUnitsInTick = numUnitsInTick
            self.timeScale = timeScale
        }

        /// The frame rate this timing describes. Unlike H.264's VUI, there is no factor of two.
        public var frameRate: Double {
            numUnitsInTick == 0 ? 0 : Double(timeScale) / Double(numUnitsInTick)
        }
    }

    public enum RewriteResult {
        /// The encoder already signalled timing; nothing to do.
        case alreadyPresent(TimingInfo)
        case rewritten(NALUnit)
        /// Left untouched, with the reason. Never a hard failure: a stream with no VPS timing
        /// still decodes, it just is not conformant.
        case unsupported(String)
    }

    /// Returns the timing info if the VPS carries it.
    public static func timingInfo(_ vps: NALUnit) -> TimingInfo? {
        guard vps.codec == .h265, vps.typeValue == H265NALType.vps.rawValue else { return nil }
        var reader = BitReader(RBSP.unescape(vps.bytes.dropFirst(2)))
        do {
            _ = try consumeUpToTimingFlag(&reader)
            guard try reader.flag() else { return nil }
            return TimingInfo(numUnitsInTick: try reader.u(32), timeScale: try reader.u(32))
        } catch {
            return nil
        }
    }

    /// Guarantees `vps_timing_info_present_flag = 1` with the given values.
    public static func ensuringTimingInfo(_ vps: NALUnit,
                                          numUnitsInTick: UInt32,
                                          timeScale: UInt32) -> RewriteResult {
        guard vps.codec == .h265, vps.typeValue == H265NALType.vps.rawValue else {
            return .unsupported("not an H.265 VPS")
        }

        let header = vps.bytes.prefix(2)
        let rbsp = RBSP.unescape(vps.bytes.dropFirst(2))

        do {
            var reader = BitReader(rbsp)
            let prefixBits = try consumeUpToTimingFlag(&reader)

            if try reader.flag() {
                let existing = TimingInfo(numUnitsInTick: try reader.u(32),
                                          timeScale: try reader.u(32))
                return .alreadyPresent(existing)
            }

            // With timing absent, the only field left is vps_extension_flag. If an encoder did
            // put extension data there we would have to carry it across the insertion, so bail
            // out instead of risking a mangled VPS. x265 never sets it.
            guard try !reader.flag() else {
                return .unsupported("vps_extension_flag is set, refusing to rewrite")
            }

            var writer = BitWriter()
            var source = BitReader(rbsp)
            try writer.copy(bits: prefixBits, from: &source)

            writer.write(bit: 1)                       // vps_timing_info_present_flag
            writer.write(numUnitsInTick, bits: 32)
            writer.write(timeScale, bits: 32)
            writer.write(bit: 0)                       // vps_poc_proportional_to_timing_flag
            writer.writeUE(0)                          // vps_num_hrd_parameters
            writer.write(bit: 0)                       // vps_extension_flag
            writer.writeRBSPTrailingBits()

            var rewritten = Data(header)
            rewritten.append(RBSP.escape(writer.data))
            return .rewritten(NALUnit(bytes: rewritten, codec: .h265))

        } catch {
            return .unsupported("could not parse the VPS: \(error)")
        }
    }

    /// Walks video_parameter_set_rbsp (H.265 §7.3.2.1) up to, but not including,
    /// `vps_timing_info_present_flag`, and returns how many bits that took.
    private static func consumeUpToTimingFlag(_ reader: inout BitReader) throws -> Int {
        try reader.skip(4)                             // vps_video_parameter_set_id
        try reader.skip(2)                             // base layer internal / available flags
        try reader.skip(6)                             // vps_max_layers_minus1
        let maxSubLayersMinus1 = Int(try reader.u(3))
        try reader.skip(1)                             // vps_temporal_id_nesting_flag
        try reader.skip(16)                            // vps_reserved_0xffff_16bits

        try consumeProfileTierLevel(&reader, maxSubLayersMinus1: maxSubLayersMinus1)

        let orderingInfoPresent = try reader.flag()
        let firstLayer = orderingInfoPresent ? 0 : maxSubLayersMinus1
        for _ in firstLayer...maxSubLayersMinus1 {
            _ = try reader.ue()                        // vps_max_dec_pic_buffering_minus1
            _ = try reader.ue()                        // vps_max_num_reorder_pics
            _ = try reader.ue()                        // vps_max_latency_increase_plus1
        }

        let maxLayerID = Int(try reader.u(6))
        let numLayerSetsMinus1 = Int(try reader.ue())
        if numLayerSetsMinus1 > 0 {
            for _ in 1...numLayerSetsMinus1 {
                for _ in 0...maxLayerID {
                    try reader.skip(1)                 // layer_id_included_flag
                }
            }
        }
        return reader.bitPosition
    }

    /// profile_tier_level(1, maxNumSubLayersMinus1), H.265 §7.3.3.
    private static func consumeProfileTierLevel(_ reader: inout BitReader,
                                                maxSubLayersMinus1: Int) throws {
        try reader.skip(2)                             // general_profile_space
        try reader.skip(1)                             // general_tier_flag
        try reader.skip(5)                             // general_profile_idc
        try reader.skip(32)                            // general_profile_compatibility_flag[32]
        // 4 named constraint flags, then 43 reserved bits and general_inbld_flag.
        try reader.skip(48)
        try reader.skip(8)                             // general_level_idc

        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        if maxSubLayersMinus1 > 0 {
            for _ in 0..<maxSubLayersMinus1 {
                profilePresent.append(try reader.flag())
                levelPresent.append(try reader.flag())
            }
            for _ in maxSubLayersMinus1..<8 {
                try reader.skip(2)                     // reserved_zero_2bits
            }
            for index in 0..<maxSubLayersMinus1 {
                if profilePresent[index] {
                    try reader.skip(8 + 32 + 48)       // the sub-layer profile block
                }
                if levelPresent[index] {
                    try reader.skip(8)                 // sub_layer_level_idc
                }
            }
        }
    }
}
