--
-- Wireshark dissector for the IPMX RTCP Sender Report extension.
--
-- Wireshark decodes the RTCP Sender Report itself, but the IPMX Info Block is a
-- profile-specific extension and shows up as an undifferentiated blob. This dissects it:
--
--   IPMX Info Block, tag 0x5831        TR-10-1 §8.7
--   Media Info Block 0x0005, video     TR-10-7 §12 + TR-10-2 §10
--   Media Info Block 0x000A, H.264     TR-10-15 Part 3 §16
--   Media Info Block 0x0009, H.265     TR-10-15 Part 2 §16
--
-- Install:
--   cp scripts/ipmx-rtcp.lua ~/.config/wireshark/plugins/     (or ~/.wireshark/plugins/)
-- then Analyze > Reload Lua Plugins.
--
-- It registers as a UDP heuristic, so no "Decode As" is needed: any datagram that looks like
-- an RTCP Sender Report carrying the 0x5831 tag is claimed. Filter with `ipmx`.
--

local ipmx = Proto("ipmx", "IPMX RTCP Sender Report")

local IPMX_TAG = 0x5831
local SR_PAYLOAD_TYPE = 200
local INFO_BLOCK_HEADER_BYTES = 84
local SR_FIXED_BYTES = 28

-- RTCP Sender Report ---------------------------------------------------------------------
local f_version      = ProtoField.uint8("ipmx.version", "Version", base.DEC, nil, 0xC0)
local f_padding      = ProtoField.uint8("ipmx.padding", "Padding", base.DEC, nil, 0x20)
local f_rc           = ProtoField.uint8("ipmx.rc", "Reception report count", base.DEC, nil, 0x1F)
local f_pt           = ProtoField.uint8("ipmx.pt", "Payload type", base.DEC)
local f_length       = ProtoField.uint16("ipmx.length", "Length (32-bit words - 1)", base.DEC)
local f_ssrc         = ProtoField.uint32("ipmx.ssrc", "SSRC", base.HEX)
local f_ptp_seconds  = ProtoField.uint32("ipmx.ptp.seconds", "PTP seconds", base.DEC)
local f_ptp_nanos    = ProtoField.uint32("ipmx.ptp.nanoseconds", "PTP nanoseconds", base.DEC)
local f_rtp_ts       = ProtoField.uint32("ipmx.rtp_timestamp", "RTP timestamp", base.DEC)
local f_packets      = ProtoField.uint32("ipmx.packet_count", "Sender's packet count", base.DEC)
local f_octets       = ProtoField.uint32("ipmx.octet_count", "Sender's octet count", base.DEC)

-- IPMX Info Block ------------------------------------------------------------------------
local f_tag          = ProtoField.uint16("ipmx.tag", "IPMX tag", base.HEX)
local f_info_length  = ProtoField.uint16("ipmx.info_length", "Info Block length", base.DEC)
local f_block_ver    = ProtoField.uint8("ipmx.block_version", "Block version", base.DEC)
local f_ts_refclk    = ProtoField.string("ipmx.ts_refclk", "ts-refclk")
local f_mediaclk     = ProtoField.string("ipmx.mediaclk", "mediaclk")

-- Media Info Block header ----------------------------------------------------------------
local f_mib_type     = ProtoField.uint16("ipmx.mib.type", "Media Info Block type", base.HEX)
local f_mib_length   = ProtoField.uint16("ipmx.mib.length", "Media Info Block length", base.DEC)

-- 0x0005 video ---------------------------------------------------------------------------
local f_sampling     = ProtoField.string("ipmx.video.sampling", "Sampling")
local f_float        = ProtoField.uint8("ipmx.video.floating_point", "Floating point", base.DEC, nil, 0x80)
local f_depth        = ProtoField.uint8("ipmx.video.bit_depth", "Bit depth", base.DEC, nil, 0x7F)
local f_packing      = ProtoField.uint8("ipmx.video.packing_mode", "General packing mode", base.DEC, nil, 0x80)
local f_interlaced   = ProtoField.uint8("ipmx.video.interlaced", "Interlaced", base.DEC, nil, 0x40)
local f_segmented    = ProtoField.uint8("ipmx.video.segmented", "Segmented", base.DEC, nil, 0x20)
local f_par_w        = ProtoField.uint8("ipmx.video.par_width", "PAR width", base.DEC)
local f_par_h        = ProtoField.uint8("ipmx.video.par_height", "PAR height", base.DEC)
local f_range        = ProtoField.string("ipmx.video.range", "Range")
local f_colorimetry  = ProtoField.string("ipmx.video.colorimetry", "Colorimetry")
local f_tcs          = ProtoField.string("ipmx.video.tcs", "TCS")
local f_width        = ProtoField.uint16("ipmx.video.width", "Width", base.DEC)
local f_height       = ProtoField.uint16("ipmx.video.height", "Height", base.DEC)
local f_rate_num     = ProtoField.uint32("ipmx.video.rate_numerator", "Rate numerator", base.DEC)
local f_rate_den     = ProtoField.uint32("ipmx.video.rate_denominator", "Rate denominator", base.DEC)
local f_pixclk       = ProtoField.uint64("ipmx.video.pixel_clock", "Measured pixel clock", base.DEC)
local f_htotal       = ProtoField.uint16("ipmx.video.htotal", "htotal", base.DEC)
local f_vtotal       = ProtoField.uint16("ipmx.video.vtotal", "vtotal", base.DEC)

-- 0x000A H.264 ---------------------------------------------------------------------------
local f_h264_mask    = ProtoField.uint32("ipmx.h264.mask", "FIELD-PRESENT-MASK", base.HEX)
local f_h264_pli     = ProtoField.bytes("ipmx.h264.profile_level_id", "profile-level-id")
local f_h264_pktmode = ProtoField.uint8("ipmx.h264.packetization_mode", "packetization-mode", base.DEC)
local f_h264_sprop   = ProtoField.string("ipmx.h264.sprop_parameter_sets", "sprop-parameter-sets")

-- 0x0009 H.265 ---------------------------------------------------------------------------
local f_h265_mask    = ProtoField.uint32("ipmx.h265.mask", "FIELD-PRESENT-MASK", base.HEX)
local f_h265_space   = ProtoField.uint8("ipmx.h265.profile_space", "profile-space", base.DEC)
local f_h265_id      = ProtoField.uint8("ipmx.h265.profile_id", "profile-id", base.DEC)
local f_h265_level   = ProtoField.uint8("ipmx.h265.level_id", "level-id", base.DEC)
local f_h265_tier    = ProtoField.uint8("ipmx.h265.tier_flag", "tier-flag", base.DEC)
local f_h265_compat  = ProtoField.bytes("ipmx.h265.compatibility", "profile-compatibility-indicator")
local f_h265_interop = ProtoField.bytes("ipmx.h265.interop_constraints", "interop-constraints")
local f_h265_vps     = ProtoField.string("ipmx.h265.sprop_vps", "sprop-vps")
local f_h265_sps     = ProtoField.string("ipmx.h265.sprop_sps", "sprop-sps")
local f_h265_pps     = ProtoField.string("ipmx.h265.sprop_pps", "sprop-pps")

local ef_bad_length  = ProtoExpert.new("ipmx.bad_length", "Length field disagrees with the datagram",
                                       expert.group.MALFORMED, expert.severity.ERROR)
local ef_bad_rc      = ProtoExpert.new("ipmx.bad_rc", "TR-10-1 §8.7: reception report count should be 0",
                                       expert.group.PROTOCOL, expert.severity.WARN)
local ef_bad_nanos   = ProtoExpert.new("ipmx.bad_nanoseconds",
                                       "TR-10-1 §8.7 requires the PTP truncated format: the low word is nanoseconds, not an NTP fraction",
                                       expert.group.PROTOCOL, expert.severity.WARN)

ipmx.fields = {
    f_version, f_padding, f_rc, f_pt, f_length, f_ssrc,
    f_ptp_seconds, f_ptp_nanos, f_rtp_ts, f_packets, f_octets,
    f_tag, f_info_length, f_block_ver, f_ts_refclk, f_mediaclk,
    f_mib_type, f_mib_length,
    f_sampling, f_float, f_depth, f_packing, f_interlaced, f_segmented, f_par_w, f_par_h,
    f_range, f_colorimetry, f_tcs, f_width, f_height, f_rate_num, f_rate_den,
    f_pixclk, f_htotal, f_vtotal,
    f_h264_mask, f_h264_pli, f_h264_pktmode, f_h264_sprop,
    f_h265_mask, f_h265_space, f_h265_id, f_h265_level, f_h265_tier,
    f_h265_compat, f_h265_interop, f_h265_vps, f_h265_sps, f_h265_pps,
}
ipmx.experts = { ef_bad_length, ef_bad_rc, ef_bad_nanos }

-- Fixed-width fields are zero padded; show only the text before the first NUL.
local function padded_string(tvb, offset, length)
    local raw = tvb(offset, length):string()
    local terminator = raw:find("\0")
    if terminator then raw = raw:sub(1, terminator - 1) end
    return raw
end

local function dissect_video(tvb, tree, offset, length)
    if length < 88 then
        tree:add(ipmx, tvb(offset, length), "Truncated video Media Info Block")
        return
    end
    local block = tree:add(ipmx, tvb(offset, length), "Video (0x0005)")
    block:add(f_sampling, tvb(offset, 16), padded_string(tvb, offset, 16))
    block:add(f_float, tvb(offset + 16, 1))
    block:add(f_depth, tvb(offset + 16, 1))
    block:add(f_packing, tvb(offset + 17, 1))
    block:add(f_interlaced, tvb(offset + 17, 1))
    block:add(f_segmented, tvb(offset + 17, 1))
    block:add(f_par_w, tvb(offset + 18, 1))
    block:add(f_par_h, tvb(offset + 19, 1))
    block:add(f_range, tvb(offset + 20, 12), padded_string(tvb, offset + 20, 12))
    block:add(f_colorimetry, tvb(offset + 32, 20), padded_string(tvb, offset + 32, 20))
    block:add(f_tcs, tvb(offset + 52, 16), padded_string(tvb, offset + 52, 16))
    block:add(f_width, tvb(offset + 68, 2))
    block:add(f_height, tvb(offset + 70, 2))

    -- rate numerator(22) | rate denominator(10) share one word.
    local rate = tvb(offset + 72, 4):uint()
    block:add(f_rate_num, tvb(offset + 72, 4), bit.rshift(rate, 10))
    block:add(f_rate_den, tvb(offset + 72, 4), bit.band(rate, 0x3FF))

    block:add(f_pixclk, tvb(offset + 76, 8))
    block:add(f_htotal, tvb(offset + 84, 2))
    block:add(f_vtotal, tvb(offset + 86, 2))
end

local function dissect_h264(tvb, tree, offset, length)
    if length < 24 then
        tree:add(ipmx, tvb(offset, length), "Truncated H.264 Media Info Block")
        return
    end
    local block = tree:add(ipmx, tvb(offset, length), "H.264 (0x000A)")
    block:add(f_h264_mask, tvb(offset, 4))
    block:add(f_h264_pli, tvb(offset + 4, 3))
    block:add(f_h264_pktmode, tvb(offset + 7, 1))

    local param_sets_n = tvb(offset + 20, 1):uint()
    if param_sets_n > 0 and 24 + param_sets_n <= length then
        block:add(f_h264_sprop, tvb(offset + 24, param_sets_n),
                  tvb(offset + 24, param_sets_n):string())
    end
end

local function dissect_h265(tvb, tree, offset, length)
    if length < 40 then
        tree:add(ipmx, tvb(offset, length), "Truncated H.265 Media Info Block")
        return
    end
    local block = tree:add(ipmx, tvb(offset, length), "H.265 (0x0009)")
    block:add(f_h265_mask, tvb(offset, 4))
    block:add(f_h265_space, tvb(offset + 4, 1))
    block:add(f_h265_id, tvb(offset + 5, 1))
    block:add(f_h265_level, tvb(offset + 6, 1))
    block:add(f_h265_tier, tvb(offset + 7, 1))
    block:add(f_h265_compat, tvb(offset + 8, 4))
    block:add(f_h265_interop, tvb(offset + 12, 6))

    local vps_n = tvb(offset + 36, 1):uint()
    local sps_n = tvb(offset + 37, 1):uint()
    local pps_n = tvb(offset + 38, 1):uint()
    local cursor = offset + 40
    if vps_n > 0 and cursor + vps_n <= offset + length then
        block:add(f_h265_vps, tvb(cursor, vps_n), tvb(cursor, vps_n):string())
        cursor = cursor + vps_n
    end
    if sps_n > 0 and cursor + sps_n <= offset + length then
        block:add(f_h265_sps, tvb(cursor, sps_n), tvb(cursor, sps_n):string())
        cursor = cursor + sps_n
    end
    if pps_n > 0 and cursor + pps_n <= offset + length then
        block:add(f_h265_pps, tvb(cursor, pps_n), tvb(cursor, pps_n):string())
    end
end

function ipmx.dissector(tvb, pinfo, tree)
    local length = tvb:len()
    if length < SR_FIXED_BYTES + 4 then return 0 end

    pinfo.cols.protocol = "IPMX"
    local root = tree:add(ipmx, tvb(), "IPMX RTCP Sender Report")

    local header = root:add(ipmx, tvb(0, SR_FIXED_BYTES), "Sender Report")
    header:add(f_version, tvb(0, 1))
    header:add(f_padding, tvb(0, 1))
    local rc = tvb(0, 1):bitfield(3, 5)
    local rc_item = header:add(f_rc, tvb(0, 1))
    if rc ~= 0 then rc_item:add_proto_expert_info(ef_bad_rc) end
    header:add(f_pt, tvb(1, 1))

    local declared = tvb(2, 2):uint()
    local length_item = header:add(f_length, tvb(2, 2))
    if declared ~= math.floor(length / 4) - 1 then
        length_item:add_proto_expert_info(ef_bad_length)
    end

    header:add(f_ssrc, tvb(4, 4))
    header:add(f_ptp_seconds, tvb(8, 4))
    local nanos = tvb(12, 4):uint()
    local nanos_item = header:add(f_ptp_nanos, tvb(12, 4))
    if nanos >= 1000000000 then nanos_item:add_proto_expert_info(ef_bad_nanos) end
    header:add(f_rtp_ts, tvb(16, 4))
    header:add(f_packets, tvb(20, 4))
    header:add(f_octets, tvb(24, 4))

    pinfo.cols.info = string.format("Sender Report  SSRC=0x%08X  RTP=%d",
                                    tvb(4, 4):uint(), tvb(16, 4):uint())

    if length < SR_FIXED_BYTES + INFO_BLOCK_HEADER_BYTES then return length end

    local info = root:add(ipmx, tvb(SR_FIXED_BYTES, length - SR_FIXED_BYTES), "IPMX Info Block")
    info:add(f_tag, tvb(28, 2))
    local info_length = tvb(30, 2):uint()
    info:add(f_info_length, tvb(30, 2))
    info:add(f_block_ver, tvb(32, 1))
    info:add(f_ts_refclk, tvb(36, 64), padded_string(tvb, 36, 64))
    info:add(f_mediaclk, tvb(100, 12), padded_string(tvb, 100, 12))

    local extension_end = math.min(length, SR_FIXED_BYTES + (info_length + 1) * 4)
    local offset = SR_FIXED_BYTES + INFO_BLOCK_HEADER_BYTES
    while offset + 4 <= extension_end do
        local block_type = tvb(offset, 2):uint()
        local block_words = tvb(offset + 2, 2):uint()
        local block_bytes = (block_words + 1) * 4
        if block_bytes < 4 or offset + block_bytes > extension_end then break end

        local content_offset = offset + 4
        local content_length = block_bytes - 4
        if block_type == 0x0005 then
            dissect_video(tvb, info, content_offset, content_length)
        elseif block_type == 0x000A then
            dissect_h264(tvb, info, content_offset, content_length)
        elseif block_type == 0x0009 then
            dissect_h265(tvb, info, content_offset, content_length)
        else
            local unknown = info:add(ipmx, tvb(offset, block_bytes),
                                     string.format("Media Info Block 0x%04X", block_type))
            unknown:add(f_mib_type, tvb(offset, 2))
            unknown:add(f_mib_length, tvb(offset + 2, 2))
        end
        offset = offset + block_bytes
    end

    return length
end

-- Claim any UDP datagram that is an RTCP Sender Report carrying the IPMX tag. Registering as a
-- heuristic rather than on a fixed port means no "Decode As" step, and it works whatever media
-- port the stream happens to use.
local function heuristic(tvb, pinfo, tree)
    if tvb:len() < SR_FIXED_BYTES + INFO_BLOCK_HEADER_BYTES then return false end
    if tvb(0, 1):bitfield(0, 2) ~= 2 then return false end
    if tvb(1, 1):uint() ~= SR_PAYLOAD_TYPE then return false end
    if tvb(28, 2):uint() ~= IPMX_TAG then return false end
    ipmx.dissector(tvb, pinfo, tree)
    return true
end

ipmx:register_heuristic("udp", heuristic)
