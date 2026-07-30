#!/usr/bin/env python3
"""Checks an H.264 or H.265 bitstream against the TR-10-15 requirements.

This is the Phase 1 validation step: the encoder settings mean nothing until the parameter
sets are read back and the flags confirmed. VUI and hrd_parameters are not byte aligned, so
there is no shortcut around a real Exp-Golomb reader — and for H.265 the VUI sits behind
st_ref_pic_set(), which has to be walked even though nothing in it is checked.

Usage:
    scripts/inspect-bitstream.py sdp/h264.sdp                  # parameter sets from the SDP
    scripts/inspect-bitstream.py dump.264 --fps 60             # + SEI and random access
    scripts/inspect-bitstream.py dump.265 --fps 60 --codec h265

The codec is auto-detected from the SDP rtpmap, or from the NAL headers of a dump.
Exit code is 1 when a "shall" requirement fails, so it drops into CI.
"""

import argparse
import base64
import re
import sys

# ---------------------------------------------------------------- bitstream primitives


def unescape_rbsp(data: bytes) -> bytes:
    """Removes emulation prevention bytes (0x03 after two zero bytes)."""
    out = bytearray()
    i = 0
    while i < len(data):
        if i + 2 < len(data) and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 3:
            out += b"\x00\x00"
            i += 3
        else:
            out.append(data[i])
            i += 1
    return bytes(out)


class BitReader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0                                  # in bits

    def u(self, n: int) -> int:
        value = 0
        for _ in range(n):
            byte = self.pos >> 3
            if byte >= len(self.data):
                raise EOFError("ran off the end of the parameter set")
            value = (value << 1) | ((self.data[byte] >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return value

    def ue(self) -> int:
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 32:
                raise ValueError("malformed Exp-Golomb code")
        return (1 << zeros) - 1 + (self.u(zeros) if zeros else 0)

    def se(self) -> int:
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)


def split_annexb(stream: bytes):
    starts = []
    i = 0
    while i + 2 < len(stream):
        if stream[i] == 0 and stream[i + 1] == 0:
            if stream[i + 2] == 1:
                starts.append((i, 3)); i += 3; continue
            if i + 3 < len(stream) and stream[i + 2] == 0 and stream[i + 3] == 1:
                starts.append((i, 4)); i += 4; continue
        i += 1
    for index, (offset, code) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(stream)
        if end > offset + code:
            yield stream[offset + code:end]


def sei_payload_types(payload: bytes):
    """Both codecs use the same SEI message framing: type and size, each 0xFF-extended."""
    data = unescape_rbsp(payload)
    i = 0
    while i < len(data) - 1:
        payload_type = 0
        while i < len(data) and data[i] == 0xFF:
            payload_type += 255; i += 1
        if i >= len(data):
            break
        payload_type += data[i]; i += 1

        payload_size = 0
        while i < len(data) and data[i] == 0xFF:
            payload_size += 255; i += 1
        if i >= len(data):
            break
        payload_size += data[i]; i += 1

        yield payload_type
        i += payload_size
        if data[i:i + 1] == b"\x80":                  # rbsp_trailing_bits
            break


# ---------------------------------------------------------------- H.264

H264_HIGH_PROFILES = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}
H264_PROFILES = {66: "Baseline", 77: "Main", 88: "Extended", 100: "High",
                 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4 Predictive"}
CHROMA = {0: "monochrome 4:0:0", 1: "4:2:0", 2: "4:2:2", 3: "4:4:4"}


def skip_h264_scaling_list(r: BitReader, size: int) -> None:
    last, nxt = 8, 8
    for _ in range(size):
        if nxt != 0:
            nxt = (last + r.se() + 256) % 256
        last = last if nxt == 0 else nxt


def parse_h264_hrd(r: BitReader) -> dict:
    hrd = {"cpb_cnt_minus1": r.ue(), "bit_rate_scale": r.u(4), "cpb_size_scale": r.u(4), "cpb": []}
    for _ in range(hrd["cpb_cnt_minus1"] + 1):
        bit_rate = r.ue() + 1
        cpb_size = r.ue() + 1
        hrd["cpb"].append({"bit_rate": bit_rate << (6 + hrd["bit_rate_scale"]),
                           "cpb_size": cpb_size << (4 + hrd["cpb_size_scale"]),
                           "cbr_flag": r.u(1)})
    r.u(5); r.u(5); r.u(5); r.u(5)                    # the four delay length fields
    return hrd


def parse_h264_vui(r: BitReader) -> dict:
    vui = {}
    if r.u(1):                                        # aspect_ratio_info_present_flag
        if r.u(8) == 255:
            r.u(16); r.u(16)
    if r.u(1):                                        # overscan_info_present_flag
        r.u(1)

    vui["video_signal_type_present_flag"] = r.u(1)
    vui["colour_description_present_flag"] = 0
    if vui["video_signal_type_present_flag"]:
        r.u(3)                                        # video_format
        vui["video_full_range_flag"] = r.u(1)
        vui["colour_description_present_flag"] = r.u(1)
        if vui["colour_description_present_flag"]:
            vui["colour_primaries"] = r.u(8)
            vui["transfer_characteristics"] = r.u(8)
            vui["matrix_coefficients"] = r.u(8)

    if r.u(1):                                        # chroma_loc_info_present_flag
        r.ue(); r.ue()

    vui["timing_info_present_flag"] = r.u(1)
    if vui["timing_info_present_flag"]:
        vui["num_units_in_tick"] = r.u(32)
        vui["time_scale"] = r.u(32)
        vui["fixed_frame_rate_flag"] = r.u(1)

    vui["nal_hrd_parameters_present_flag"] = r.u(1)
    if vui["nal_hrd_parameters_present_flag"]:
        vui["nal_hrd"] = parse_h264_hrd(r)
    vui["vcl_hrd_parameters_present_flag"] = r.u(1)
    if vui["vcl_hrd_parameters_present_flag"]:
        vui["vcl_hrd"] = parse_h264_hrd(r)
    if vui["nal_hrd_parameters_present_flag"] or vui["vcl_hrd_parameters_present_flag"]:
        vui["low_delay_hrd_flag"] = r.u(1)

    vui["pic_struct_present_flag"] = r.u(1)
    if r.u(1):                                        # bitstream_restriction_flag
        r.u(1); r.ue(); r.ue(); r.ue(); r.ue()
        vui["max_num_reorder_frames"] = r.ue()
        vui["max_dec_frame_buffering"] = r.ue()
    return vui


def parse_h264_sps(nal: bytes) -> dict:
    r = BitReader(unescape_rbsp(nal[1:]))             # drop the 1-byte NAL header
    sps = {"profile_idc": r.u(8)}
    r.u(8)                                            # constraint flags + reserved
    sps["level_idc"] = r.u(8)
    r.ue()                                            # seq_parameter_set_id

    sps["chroma_format_idc"] = 1
    sps["bit_depth_luma"] = 8
    if sps["profile_idc"] in H264_HIGH_PROFILES:
        sps["chroma_format_idc"] = r.ue()
        if sps["chroma_format_idc"] == 3:
            r.u(1)
        sps["bit_depth_luma"] = r.ue() + 8
        r.ue()                                        # bit_depth_chroma_minus8
        r.u(1)                                        # qpprime_y_zero_transform_bypass_flag
        if r.u(1):                                    # seq_scaling_matrix_present_flag
            for i in range(8 if sps["chroma_format_idc"] != 3 else 12):
                if r.u(1):
                    skip_h264_scaling_list(r, 16 if i < 6 else 64)

    r.ue()                                            # log2_max_frame_num_minus4
    poc_type = r.ue()
    if poc_type == 0:
        r.ue()
    elif poc_type == 1:
        r.u(1); r.se(); r.se()
        for _ in range(r.ue()):
            r.se()

    r.ue()                                            # max_num_ref_frames
    r.u(1)                                            # gaps_in_frame_num_value_allowed_flag
    width_mbs = r.ue() + 1
    height_units = r.ue() + 1
    sps["frame_mbs_only_flag"] = r.u(1)
    if not sps["frame_mbs_only_flag"]:
        r.u(1)
    r.u(1)                                            # direct_8x8_inference_flag

    sps["width"] = width_mbs * 16
    sps["height"] = height_units * 16 * (2 - sps["frame_mbs_only_flag"])
    if r.u(1):                                        # frame_cropping_flag
        left, right, top, bottom = r.ue(), r.ue(), r.ue(), r.ue()
        sub_w = 1 if sps["chroma_format_idc"] == 0 else 2
        sub_h = 1 if sps["chroma_format_idc"] in (0, 3) else (1 if sps["chroma_format_idc"] == 2 else 2)
        sps["width"] -= (left + right) * sub_w
        sps["height"] -= (top + bottom) * sub_h * (2 - sps["frame_mbs_only_flag"])

    sps["vui_present"] = r.u(1)
    sps["vui"] = parse_h264_vui(r) if sps["vui_present"] else {}
    return sps


# ---------------------------------------------------------------- H.265

H265_PROFILES = {1: "Main", 2: "Main 10", 3: "Main Still Picture", 4: "Format Range Extensions"}


def parse_profile_tier_level(r: BitReader, max_sub_layers_minus1: int) -> dict:
    ptl = {"profile_space": r.u(2), "tier_flag": r.u(1), "profile_idc": r.u(5)}
    ptl["compatibility"] = r.u(32)
    # 4 named constraint flags then 43 reserved bits and inbld_flag: 48 bits total.
    ptl["progressive_source_flag"] = r.u(1)
    ptl["interlaced_source_flag"] = r.u(1)
    r.u(1)                                            # non_packed_constraint_flag
    ptl["frame_only_constraint_flag"] = r.u(1)
    r.u(44)                                           # reserved + inbld
    ptl["level_idc"] = r.u(8)

    profile_present, level_present = [], []
    for _ in range(max_sub_layers_minus1):
        profile_present.append(r.u(1))
        level_present.append(r.u(1))
    if max_sub_layers_minus1 > 0:
        for _ in range(max_sub_layers_minus1, 8):
            r.u(2)                                    # reserved_zero_2bits
    for i in range(max_sub_layers_minus1):
        if profile_present[i]:
            r.u(2); r.u(1); r.u(5); r.u(32); r.u(48)
        if level_present[i]:
            r.u(8)
    return ptl


def skip_h265_scaling_list_data(r: BitReader) -> None:
    for size_id in range(4):
        matrix_count = 6 if size_id != 3 else 2
        for _ in range(matrix_count):
            if not r.u(1):                            # scaling_list_pred_mode_flag
                r.ue()                                # scaling_list_pred_matrix_id_delta
            else:
                coef_num = min(64, 1 << (4 + (size_id << 1)))
                if size_id > 1:
                    r.se()                            # scaling_list_dc_coef_minus8
                for _ in range(coef_num):
                    r.se()                            # scaling_list_delta_coef


def skip_st_ref_pic_set(r: BitReader, idx: int, num_sets: int, num_delta_pocs: list) -> int:
    """Walks one st_ref_pic_set. Returns NumDeltaPocs for this index.

    Nothing here is checked; it only has to be consumed exactly, because the VUI — and the
    HRD parameters TR-10-15 Part 2 §10 cares about — sit after it in the SPS.
    """
    inter_pred = r.u(1) if idx != 0 else 0
    if inter_pred:
        if idx == num_sets:
            r.ue()                                    # delta_idx_minus1
        r.u(1)                                        # delta_rps_sign
        r.ue()                                        # abs_delta_rps_minus1
        reference = num_delta_pocs[idx - 1]
        count = 0
        for _ in range(reference + 1):
            used = r.u(1)
            if not used:
                if r.u(1):                            # use_delta_flag
                    count += 1
            else:
                count += 1
        return count
    negative, positive = r.ue(), r.ue()
    for _ in range(negative):
        r.ue(); r.u(1)
    for _ in range(positive):
        r.ue(); r.u(1)
    return negative + positive


def parse_h265_hrd(r: BitReader, common_inf_present: int, max_sub_layers_minus1: int) -> dict:
    hrd = {"nal_hrd_parameters_present_flag": 0, "vcl_hrd_parameters_present_flag": 0}
    sub_pic = 0
    if common_inf_present:
        hrd["nal_hrd_parameters_present_flag"] = r.u(1)
        hrd["vcl_hrd_parameters_present_flag"] = r.u(1)
        if hrd["nal_hrd_parameters_present_flag"] or hrd["vcl_hrd_parameters_present_flag"]:
            sub_pic = r.u(1)
            hrd["sub_pic_hrd_params_present_flag"] = sub_pic
            if sub_pic:
                hrd["tick_divisor_minus2"] = r.u(8)
                r.u(5)                                # du_cpb_removal_delay_increment_length_minus1
                hrd["sub_pic_cpb_params_in_pic_timing_sei_flag"] = r.u(1)
                r.u(5)                                # dpb_output_delay_du_length_minus1
            bit_rate_scale, cpb_size_scale = r.u(4), r.u(4)
            if sub_pic:
                r.u(4)                                # cpb_size_du_scale
            r.u(5); r.u(5); r.u(5)                    # the three delay length fields
        else:
            bit_rate_scale = cpb_size_scale = 0
    else:
        bit_rate_scale = cpb_size_scale = 0

    hrd["layers"] = []
    for _ in range(max_sub_layers_minus1 + 1):
        layer = {}
        fixed_general = r.u(1)
        fixed_within_cvs = 1 if fixed_general else r.u(1)
        low_delay = 0
        cpb_cnt_minus1 = 0
        if fixed_within_cvs:
            r.ue()                                    # elemental_duration_in_tc_minus1
        else:
            low_delay = r.u(1)
        if not low_delay:
            cpb_cnt_minus1 = r.ue()
        layer["low_delay_hrd_flag"] = low_delay
        layer["cpb_cnt_minus1"] = cpb_cnt_minus1
        layer["cpb"] = []

        for _ in range(int(bool(hrd["nal_hrd_parameters_present_flag"]))
                       + int(bool(hrd["vcl_hrd_parameters_present_flag"]))):
            entries = []
            for _ in range(cpb_cnt_minus1 + 1):
                bit_rate = r.ue() + 1
                cpb_size = r.ue() + 1
                if sub_pic:
                    r.ue(); r.ue()                    # cpb_size_du, bit_rate_du
                entries.append({"bit_rate": bit_rate << (6 + bit_rate_scale),
                                "cpb_size": cpb_size << (4 + cpb_size_scale),
                                "cbr_flag": r.u(1)})
            layer["cpb"].extend(entries)
        hrd["layers"].append(layer)
    return hrd


def parse_h265_vui(r: BitReader, max_sub_layers_minus1: int) -> dict:
    vui = {}
    if r.u(1):                                        # aspect_ratio_info_present_flag
        if r.u(8) == 255:
            r.u(16); r.u(16)
    if r.u(1):                                        # overscan_info_present_flag
        r.u(1)

    vui["video_signal_type_present_flag"] = r.u(1)
    vui["colour_description_present_flag"] = 0
    if vui["video_signal_type_present_flag"]:
        r.u(3)                                        # video_format
        vui["video_full_range_flag"] = r.u(1)
        vui["colour_description_present_flag"] = r.u(1)
        if vui["colour_description_present_flag"]:
            vui["colour_primaries"] = r.u(8)
            vui["transfer_characteristics"] = r.u(8)
            vui["matrix_coefficients"] = r.u(8)

    if r.u(1):                                        # chroma_loc_info_present_flag
        r.ue(); r.ue()

    r.u(1)                                            # neutral_chroma_indication_flag
    vui["field_seq_flag"] = r.u(1)
    vui["frame_field_info_present_flag"] = r.u(1)
    if r.u(1):                                        # default_display_window_flag
        r.ue(); r.ue(); r.ue(); r.ue()

    vui["vui_timing_info_present_flag"] = r.u(1)
    vui["vui_hrd_parameters_present_flag"] = 0
    if vui["vui_timing_info_present_flag"]:
        vui["vui_num_units_in_tick"] = r.u(32)
        vui["vui_time_scale"] = r.u(32)
        if r.u(1):                                    # vui_poc_proportional_to_timing_flag
            r.ue()
        vui["vui_hrd_parameters_present_flag"] = r.u(1)
        if vui["vui_hrd_parameters_present_flag"]:
            vui["hrd"] = parse_h265_hrd(r, 1, max_sub_layers_minus1)
    return vui


def parse_h265_sps(nal: bytes) -> dict:
    r = BitReader(unescape_rbsp(nal[2:]))             # drop the 2-byte NAL header
    sps = {}
    r.u(4)                                            # sps_video_parameter_set_id
    max_sub_layers_minus1 = r.u(3)
    sps["max_sub_layers_minus1"] = max_sub_layers_minus1
    r.u(1)                                            # sps_temporal_id_nesting_flag

    sps["ptl"] = parse_profile_tier_level(r, max_sub_layers_minus1)
    r.ue()                                            # sps_seq_parameter_set_id
    sps["chroma_format_idc"] = r.ue()
    if sps["chroma_format_idc"] == 3:
        r.u(1)                                        # separate_colour_plane_flag
    sps["width"] = r.ue()
    sps["height"] = r.ue()
    if r.u(1):                                        # conformance_window_flag
        left, right, top, bottom = r.ue(), r.ue(), r.ue(), r.ue()
        sub_w = 2 if sps["chroma_format_idc"] in (1, 2) else 1
        sub_h = 2 if sps["chroma_format_idc"] == 1 else 1
        sps["width"] -= (left + right) * sub_w
        sps["height"] -= (top + bottom) * sub_h
    sps["bit_depth_luma"] = r.ue() + 8
    r.ue()                                            # bit_depth_chroma_minus8
    log2_max_poc_lsb = r.ue() + 4

    ordering_info_present = r.u(1)
    reorder = []
    for _ in range(0 if ordering_info_present else max_sub_layers_minus1, max_sub_layers_minus1 + 1):
        r.ue()                                        # sps_max_dec_pic_buffering_minus1
        reorder.append(r.ue())                        # sps_max_num_reorder_pics
        r.ue()                                        # sps_max_latency_increase_plus1
    sps["max_num_reorder_pics"] = max(reorder) if reorder else None

    r.ue(); r.ue(); r.ue(); r.ue()                    # the four log2 CB/TB size fields
    r.ue(); r.ue()                                    # max_transform_hierarchy_depth inter/intra
    if r.u(1):                                        # scaling_list_enabled_flag
        if r.u(1):                                    # sps_scaling_list_data_present_flag
            skip_h265_scaling_list_data(r)
    r.u(1)                                            # amp_enabled_flag
    r.u(1)                                            # sample_adaptive_offset_enabled_flag
    if r.u(1):                                        # pcm_enabled_flag
        r.u(4); r.u(4); r.ue(); r.ue(); r.u(1)

    num_sets = r.ue()                                 # num_short_term_ref_pic_sets
    num_delta_pocs = []
    for i in range(num_sets):
        num_delta_pocs.append(skip_st_ref_pic_set(r, i, num_sets, num_delta_pocs))

    if r.u(1):                                        # long_term_ref_pics_present_flag
        for _ in range(r.ue()):                       # num_long_term_ref_pics_sps
            r.u(log2_max_poc_lsb); r.u(1)

    r.u(1)                                            # sps_temporal_mvp_enabled_flag
    r.u(1)                                            # strong_intra_smoothing_enabled_flag

    sps["vui_present"] = r.u(1)
    sps["vui"] = parse_h265_vui(r, max_sub_layers_minus1) if sps["vui_present"] else {}
    return sps


def parse_h265_vps(nal: bytes) -> dict:
    """Only walked as far as the timing info, which TR-10-15 Part 2 §10 constrains."""
    r = BitReader(unescape_rbsp(nal[2:]))
    r.u(4)                                            # vps_video_parameter_set_id
    r.u(2)                                            # base layer flags
    r.u(6)                                            # vps_max_layers_minus1
    max_sub_layers_minus1 = r.u(3)
    r.u(1)                                            # vps_temporal_id_nesting_flag
    r.u(16)                                           # vps_reserved_0xffff_16bits
    parse_profile_tier_level(r, max_sub_layers_minus1)

    ordering_info_present = r.u(1)
    for _ in range(0 if ordering_info_present else max_sub_layers_minus1, max_sub_layers_minus1 + 1):
        r.ue(); r.ue(); r.ue()
    max_layer_id = r.u(6)
    for _ in range(r.ue()):                           # vps_num_layer_sets_minus1
        for _ in range(max_layer_id + 1):
            r.u(1)

    vps = {"vps_timing_info_present_flag": r.u(1)}
    if vps["vps_timing_info_present_flag"]:
        vps["vps_num_units_in_tick"] = r.u(32)
        vps["vps_time_scale"] = r.u(32)
    return vps


# ---------------------------------------------------------------- reporting

failures, warnings = [], []


def check(ok: bool, label: str, detail: str = "", fatal: bool = True) -> None:
    mark = "ok  " if ok else ("FAIL" if fatal else "warn")
    print(f"  [{mark}] {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        (failures if fatal else warnings).append(label)


def report_h264(sps: dict, sei_types: set, has_stream: bool, fps: int | None) -> None:
    vui = sps["vui"]
    profile = H264_PROFILES.get(sps["profile_idc"], f"profile_idc {sps['profile_idc']}")
    print(f"\nH.264 SPS: {profile}, level {sps['level_idc'] / 10:.1f}, "
          f"{sps['width']}x{sps['height']}, {CHROMA.get(sps['chroma_format_idc'], '?')}, "
          f"{sps['bit_depth_luma']}-bit\n")

    print("TR-10-15 Part 3 §12 — profile")
    check(sps["profile_idc"] in (77, 100), "High or Main profile", profile)
    check(sps["chroma_format_idc"] == 1, "YCbCr 4:2:0")
    check(sps["bit_depth_luma"] == 8, "8-bit samples")

    print("\nTR-10-15 Part 3 §8 — picture and VUI")
    check(sps["vui_present"] == 1, "vui_parameters present")
    check(vui.get("video_signal_type_present_flag") == 1, "video_signal_type_present_flag = 1")
    check(vui.get("colour_description_present_flag") == 1, "colour_description_present_flag = 1")
    if vui.get("colour_description_present_flag"):
        print(f"         colour_primaries={vui['colour_primaries']} "
              f"transfer={vui['transfer_characteristics']} matrix={vui['matrix_coefficients']} "
              f"full_range={vui.get('video_full_range_flag')}")
    check(vui.get("timing_info_present_flag") == 1, "timing_info_present_flag = 1")
    check(sps["frame_mbs_only_flag"] == 1, "progressive (frame_mbs_only_flag = 1), PAFF unused")

    print("\nTR-10-15 Part 3 §10 — timing and HRD")
    nal_hrd = vui.get("nal_hrd_parameters_present_flag", 0)
    check(nal_hrd == 1, "nal_hrd_parameters_present_flag = 1 (Type II HRD)")
    if nal_hrd:
        hrd = vui["nal_hrd"]
        check(hrd["cpb_cnt_minus1"] == 0, "cpb_cnt_minus1 = 0")
        cpb = hrd["cpb"][0]
        print(f"         bit_rate={cpb['bit_rate']} cpb_size={cpb['cpb_size']} "
              f"cbr_flag={cpb['cbr_flag']} ({'CBR' if cpb['cbr_flag'] else 'VBR'})")
    if vui.get("timing_info_present_flag"):
        num_units, time_scale = vui["num_units_in_tick"], vui["time_scale"]
        print(f"         num_units_in_tick={num_units} time_scale={time_scale} "
              f"-> {time_scale / (2 * num_units):g} fps")
        if fps is not None:
            # H.264 only: time_scale is TWICE the frame rate numerator. H.265 is not.
            check(num_units == 1 and time_scale == 2 * fps,
                  f"time_scale = 2 x frame rate numerator for {fps} fps",
                  f"got num_units_in_tick={num_units}, time_scale={time_scale}")
    reorder = vui.get("max_num_reorder_frames")
    check(reorder == 0, "max_num_reorder_frames = 0 (decode order = output order)",
          "bitstream_restriction_flag is 0, so the value is not signalled"
          if reorder is None else f"got {reorder}", fatal=False)

    if has_stream:
        print("\nTR-10-15 Part 3 §10 — SEI messages")
        check(0 in sei_types, "Buffering Period SEI (payloadType 0) present")
        check(1 in sei_types, "Picture Timing SEI (payloadType 1) present")
        print(f"         SEI payload types seen: {sorted(sei_types)}")


def report_h265(vps: dict | None, sps: dict, sei_types: set, has_stream: bool,
                fps: int | None) -> None:
    ptl = sps["ptl"]
    vui = sps["vui"]
    profile = H265_PROFILES.get(ptl["profile_idc"], f"profile_idc {ptl['profile_idc']}")
    tier = "high" if ptl["tier_flag"] else "main"
    print(f"\nH.265 SPS: {profile}, level {ptl['level_idc'] / 30:.1f} {tier} tier, "
          f"{sps['width']}x{sps['height']}, {CHROMA.get(sps['chroma_format_idc'], '?')}, "
          f"{sps['bit_depth_luma']}-bit\n")

    print("TR-10-15 Part 2 §12 — profile")
    check(ptl["profile_idc"] in (1, 2), "Main or Main10 profile", profile)
    check(sps["chroma_format_idc"] == 1, "YCbCr 4:2:0")
    check(sps["bit_depth_luma"] in (8, 10), "8 or 10-bit samples",
          f"{sps['bit_depth_luma']}-bit")

    print("\nTR-10-15 Part 2 §8 — picture and VUI")
    check(sps["vui_present"] == 1, "vui_parameters present")
    check(vui.get("video_signal_type_present_flag") == 1, "video_signal_type_present_flag = 1")
    check(vui.get("colour_description_present_flag") == 1, "colour_description_present_flag = 1")
    if vui.get("colour_description_present_flag"):
        print(f"         colour_primaries={vui['colour_primaries']} "
              f"transfer={vui['transfer_characteristics']} matrix={vui['matrix_coefficients']} "
              f"full_range={vui.get('video_full_range_flag')}")
    check(vui.get("vui_timing_info_present_flag") == 1, "vui_timing_info_present_flag = 1")
    check(vui.get("vui_hrd_parameters_present_flag") == 1, "vui_hrd_parameters_present_flag = 1")
    check(ptl["progressive_source_flag"] == 1 and ptl["interlaced_source_flag"] == 0,
          "progressive source", fatal=False)

    print("\nTR-10-15 Part 2 §10 — timing and HRD")
    hrd = vui.get("hrd", {})
    check(hrd.get("nal_hrd_parameters_present_flag") == 1,
          "nal_hrd_parameters_present_flag = 1 (Type II HRD)")
    layers = hrd.get("layers") or []
    if layers:
        check(all(layer["cpb_cnt_minus1"] == 0 for layer in layers), "cpb_cnt_minus1 = 0")
        entries = layers[0]["cpb"]
        if entries:
            cpb = entries[0]
            print(f"         bit_rate={cpb['bit_rate']} cpb_size={cpb['cpb_size']} "
                  f"cbr_flag={cpb['cbr_flag']} ({'CBR' if cpb['cbr_flag'] else 'VBR'})")

    if vui.get("vui_timing_info_present_flag"):
        num_units, time_scale = vui["vui_num_units_in_tick"], vui["vui_time_scale"]
        print(f"         vui_num_units_in_tick={num_units} vui_time_scale={time_scale} "
              f"-> {time_scale / num_units:g} fps")
        if fps is not None:
            # The H.265 trap: vui_time_scale is the frame rate numerator, NOT twice it.
            check(num_units == 1 and time_scale == fps,
                  f"vui_time_scale = frame rate numerator for {fps} fps (no x2, unlike H.264)",
                  f"got vui_num_units_in_tick={num_units}, vui_time_scale={time_scale}")

    if vps is not None:
        check(vps.get("vps_timing_info_present_flag") == 1, "vps_timing_info_present_flag = 1")
        if vps.get("vps_timing_info_present_flag"):
            num_units, time_scale = vps["vps_num_units_in_tick"], vps["vps_time_scale"]
            print(f"         vps_num_units_in_tick={num_units} vps_time_scale={time_scale}")
            if fps is not None:
                check(num_units == 1 and time_scale == fps,
                      f"vps_time_scale = frame rate numerator for {fps} fps",
                      f"got vps_num_units_in_tick={num_units}, vps_time_scale={time_scale}")

    reorder = sps.get("max_num_reorder_pics")
    check(reorder == 0, "sps_max_num_reorder_pics = 0 (decode order = output order)",
          f"got {reorder}", fatal=False)

    if has_stream:
        print("\nTR-10-15 Part 2 §10 — SEI messages")
        check(0 in sei_types, "Buffering Period SEI (payloadType 0) present")
        check(1 in sei_types, "Picture Timing SEI (payloadType 1) present")
        print(f"         SEI payload types seen: {sorted(sei_types)}")


# ---------------------------------------------------------------- driver


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", help="an .sdp file or an Annex B elementary stream")
    parser.add_argument("--fps", type=int, default=None,
                        help="expected frame rate, to check the timing fields")
    parser.add_argument("--codec", choices=["h264", "h265"], default=None,
                        help="override the auto-detected codec")
    args = parser.parse_args()

    raw = open(args.path, "rb").read()
    codec = args.codec
    vps_nal = sps_nal = None
    sei_types = set()
    pictures = 0
    irap_indices = []
    slices_per_picture = []
    from_sdp = args.path.endswith(".sdp")

    if from_sdp:
        if codec is None:
            match = re.search(rb"a=rtpmap:\d+\s+(H26[45])/", raw, re.IGNORECASE)
            codec = match.group(1).decode().lower() if match else "h264"
        if codec == "h264":
            match = re.search(rb"sprop-parameter-sets=([A-Za-z0-9+/=,]+)", raw)
            if not match:
                print("no sprop-parameter-sets in that SDP", file=sys.stderr)
                return 2
            sps_nal = base64.b64decode(match.group(1).split(b",")[0])
        else:
            for key, target in (("sprop-vps", "vps"), ("sprop-sps", "sps")):
                match = re.search(key.encode() + rb"=([A-Za-z0-9+/=]+)", raw)
                if match:
                    decoded = base64.b64decode(match.group(1))
                    if target == "vps":
                        vps_nal = decoded
                    else:
                        sps_nal = decoded
            if sps_nal is None:
                print("no sprop-sps in that SDP", file=sys.stderr)
                return 2
    else:
        nals = list(split_annexb(raw))
        if codec is None:
            lower = args.path.lower()
            if lower.endswith((".265", ".h265", ".hevc")):
                codec = "h265"
            elif lower.endswith((".264", ".h264", ".avc")):
                codec = "h264"
            else:
                # Discriminate on the SPS, not the VPS. An H.265 SPS is type 33, so its first
                # byte is 0x42 or 0x43; read as H.264 those are data-partition slices (types 2
                # and 3), which no practical encoder emits. Testing for the VPS instead would
                # match 0x41 — an ordinary H.264 P slice with nal_ref_idc 2.
                codec = "h265" if any(n[0] in (0x42, 0x43) for n in nals) else "h264"

        for nal in nals:
            if codec == "h264":
                nal_type = nal[0] & 0x1F
                is_sps, is_sei, is_vcl = nal_type == 7, nal_type == 6, nal_type in (1, 5)
                is_irap = nal_type == 5
                header_bytes = 1
            else:
                nal_type = (nal[0] >> 1) & 0x3F
                if nal_type == 32 and vps_nal is None:
                    vps_nal = nal
                is_sps, is_sei = nal_type == 33, nal_type in (39, 40)
                is_vcl, is_irap = nal_type <= 31, 16 <= nal_type <= 23
                header_bytes = 2

            if is_sps and sps_nal is None:
                sps_nal = nal
            elif is_sei:
                sei_types.update(sei_payload_types(nal[header_bytes:]))
            elif is_vcl:
                # H.264 slice_header opens with first_mb_in_slice; H.265 with
                # first_slice_segment_in_pic_flag. Either way it marks a new picture.
                r = BitReader(unescape_rbsp(nal[header_bytes:]))
                new_picture = (r.ue() == 0) if codec == "h264" else (r.u(1) == 1)
                if new_picture:
                    pictures += 1
                    slices_per_picture.append(1)
                    if is_irap:
                        irap_indices.append(pictures - 1)
                elif slices_per_picture:
                    slices_per_picture[-1] += 1

        if sps_nal is None:
            print(f"no {codec.upper()} SPS found in that stream", file=sys.stderr)
            return 2

    try:
        if codec == "h264":
            report_h264(parse_h264_sps(sps_nal), sei_types, not from_sdp, args.fps)
        else:
            vps = parse_h265_vps(vps_nal) if vps_nal else None
            report_h265(vps, parse_h265_sps(sps_nal), sei_types, not from_sdp, args.fps)
    except (EOFError, ValueError) as error:
        print(f"could not parse the parameter sets: {error}", file=sys.stderr)
        return 2

    if not from_sdp:
        part = "Part 3" if codec == "h264" else "Part 2"
        print(f"\nTR-10-15 {part} §11 — random access")
        print(f"         {pictures} pictures, {len(irap_indices)} random access points")
        if args.fps and len(irap_indices) >= 2:
            gaps = [(b - a) / args.fps for a, b in zip(irap_indices, irap_indices[1:])]
            check(max(gaps) <= 5.0, "a random access point at least every 5 s",
                  f"largest gap {max(gaps):.2f} s")
        elif len(irap_indices) < 2:
            check(False, "at least two random access points to measure the interval",
                  "capture for longer", fatal=False)
        if slices_per_picture:
            # TR-10-15 §9 caps a packet at one VCL NAL. More slices means more packets, not a
            # violation: the packetizer never aggregates.
            print(f"\n         slices per picture: {min(slices_per_picture)}.."
                  f"{max(slices_per_picture)} (each one travels in its own packet, §9)")
    else:
        print("\n  (pass an Annex B dump from --dump to also check the SEI and random access)")

    print()
    if failures:
        print(f"FAILED — {len(failures)} requirement(s) not met: {', '.join(failures)}")
        return 1
    if warnings:
        print(f"ok, with {len(warnings)} warning(s): {', '.join(warnings)}")
    else:
        print("ok — every checked requirement is met")
    return 0


if __name__ == "__main__":
    sys.exit(main())
