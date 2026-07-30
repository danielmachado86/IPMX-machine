#!/usr/bin/env python3
"""Parses an H.264 SPS and checks it against the TR-10-15 Part 3 bitstream requirements.

This is the Phase 1 validation step: the encoder settings mean nothing until the SPS is
read back and the flags are confirmed. VUI and hrd_parameters are not byte aligned, so
there is no shortcut around a real Exp-Golomb reader.

Usage:
    scripts/inspect-bitstream.py sdp/h264.sdp            # SPS from sprop-parameter-sets
    scripts/inspect-bitstream.py dump.264                # SPS + SEI scan from an Annex B dump
    scripts/inspect-bitstream.py dump.264 --fps 60

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
                raise EOFError("ran off the end of the SPS")
            bit = (self.data[byte] >> (7 - (self.pos & 7))) & 1
            value = (value << 1) | bit
            self.pos += 1
        return value

    def ue(self) -> int:
        """Unsigned Exp-Golomb."""
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 32:
                raise ValueError("malformed Exp-Golomb code")
        return (1 << zeros) - 1 + (self.u(zeros) if zeros else 0)

    def se(self) -> int:
        """Signed Exp-Golomb."""
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)


# ---------------------------------------------------------------- H.264 SPS

# Profiles whose SPS carries the chroma_format_idc block (H.264 §7.3.2.1.1).
HIGH_PROFILES = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}
PROFILE_NAMES = {66: "Baseline", 77: "Main", 88: "Extended", 100: "High",
                 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4 Predictive"}
CHROMA_NAMES = {0: "monochrome 4:0:0", 1: "4:2:0", 2: "4:2:2", 3: "4:4:4"}


def skip_scaling_list(reader: BitReader, size: int) -> None:
    last_scale, next_scale = 8, 8
    for _ in range(size):
        if next_scale != 0:
            next_scale = (last_scale + reader.se() + 256) % 256
        last_scale = last_scale if next_scale == 0 else next_scale


def parse_hrd(reader: BitReader) -> dict:
    hrd = {"cpb_cnt_minus1": reader.ue(),
           "bit_rate_scale": reader.u(4),
           "cpb_size_scale": reader.u(4),
           "cpb": []}
    for _ in range(hrd["cpb_cnt_minus1"] + 1):
        bit_rate = (reader.ue() + 1)
        cpb_size = (reader.ue() + 1)
        hrd["cpb"].append({
            "bit_rate": bit_rate << (6 + hrd["bit_rate_scale"]),
            "cpb_size": cpb_size << (4 + hrd["cpb_size_scale"]),
            "cbr_flag": reader.u(1),
        })
    hrd["initial_cpb_removal_delay_length_minus1"] = reader.u(5)
    hrd["cpb_removal_delay_length_minus1"] = reader.u(5)
    hrd["dpb_output_delay_length_minus1"] = reader.u(5)
    hrd["time_offset_length"] = reader.u(5)
    return hrd


def parse_vui(reader: BitReader) -> dict:
    vui = {}
    if reader.u(1):                                   # aspect_ratio_info_present_flag
        idc = reader.u(8)
        if idc == 255:
            reader.u(16); reader.u(16)
    if reader.u(1):                                   # overscan_info_present_flag
        reader.u(1)

    vui["video_signal_type_present_flag"] = reader.u(1)
    vui["colour_description_present_flag"] = 0
    if vui["video_signal_type_present_flag"]:
        vui["video_format"] = reader.u(3)
        vui["video_full_range_flag"] = reader.u(1)
        vui["colour_description_present_flag"] = reader.u(1)
        if vui["colour_description_present_flag"]:
            vui["colour_primaries"] = reader.u(8)
            vui["transfer_characteristics"] = reader.u(8)
            vui["matrix_coefficients"] = reader.u(8)

    if reader.u(1):                                   # chroma_loc_info_present_flag
        reader.ue(); reader.ue()

    vui["timing_info_present_flag"] = reader.u(1)
    if vui["timing_info_present_flag"]:
        vui["num_units_in_tick"] = reader.u(32)
        vui["time_scale"] = reader.u(32)
        vui["fixed_frame_rate_flag"] = reader.u(1)

    vui["nal_hrd_parameters_present_flag"] = reader.u(1)
    if vui["nal_hrd_parameters_present_flag"]:
        vui["nal_hrd"] = parse_hrd(reader)

    vui["vcl_hrd_parameters_present_flag"] = reader.u(1)
    if vui["vcl_hrd_parameters_present_flag"]:
        vui["vcl_hrd"] = parse_hrd(reader)

    if vui["nal_hrd_parameters_present_flag"] or vui["vcl_hrd_parameters_present_flag"]:
        vui["low_delay_hrd_flag"] = reader.u(1)

    vui["pic_struct_present_flag"] = reader.u(1)
    vui["bitstream_restriction_flag"] = reader.u(1)
    if vui["bitstream_restriction_flag"]:
        reader.u(1)                                   # motion_vectors_over_pic_boundaries_flag
        reader.ue(); reader.ue(); reader.ue(); reader.ue()
        vui["max_num_reorder_frames"] = reader.ue()
        vui["max_dec_frame_buffering"] = reader.ue()
    return vui


def parse_sps(nal: bytes) -> dict:
    reader = BitReader(unescape_rbsp(nal[1:]))        # drop the 1-byte NAL header
    sps = {"profile_idc": reader.u(8)}
    sps["constraint_flags"] = reader.u(8)             # 6 flags + 2 reserved bits
    sps["level_idc"] = reader.u(8)
    reader.ue()                                       # seq_parameter_set_id

    sps["chroma_format_idc"] = 1                      # 4:2:0 unless stated otherwise
    sps["bit_depth_luma"] = 8
    if sps["profile_idc"] in HIGH_PROFILES:
        sps["chroma_format_idc"] = reader.ue()
        if sps["chroma_format_idc"] == 3:
            reader.u(1)                               # separate_colour_plane_flag
        sps["bit_depth_luma"] = reader.ue() + 8
        sps["bit_depth_chroma"] = reader.ue() + 8
        reader.u(1)                                   # qpprime_y_zero_transform_bypass_flag
        if reader.u(1):                               # seq_scaling_matrix_present_flag
            for i in range(8 if sps["chroma_format_idc"] != 3 else 12):
                if reader.u(1):
                    skip_scaling_list(reader, 16 if i < 6 else 64)

    reader.ue()                                       # log2_max_frame_num_minus4
    pic_order_cnt_type = reader.ue()
    if pic_order_cnt_type == 0:
        reader.ue()
    elif pic_order_cnt_type == 1:
        reader.u(1); reader.se(); reader.se()
        for _ in range(reader.ue()):
            reader.se()

    sps["max_num_ref_frames"] = reader.ue()
    reader.u(1)                                       # gaps_in_frame_num_value_allowed_flag
    width_mbs = reader.ue() + 1
    height_map_units = reader.ue() + 1
    sps["frame_mbs_only_flag"] = reader.u(1)
    if not sps["frame_mbs_only_flag"]:
        reader.u(1)                                   # mb_adaptive_frame_field_flag
    reader.u(1)                                       # direct_8x8_inference_flag

    sps["width"] = width_mbs * 16
    sps["height"] = height_map_units * 16 * (2 - sps["frame_mbs_only_flag"])

    if reader.u(1):                                   # frame_cropping_flag
        left, right = reader.ue(), reader.ue()
        top, bottom = reader.ue(), reader.ue()
        sub_w = 1 if sps["chroma_format_idc"] == 0 else 2
        sub_h = 1 if sps["chroma_format_idc"] in (0, 3) else 2
        if sps["chroma_format_idc"] == 2:
            sub_h = 1
        sps["width"] -= (left + right) * sub_w
        sps["height"] -= (top + bottom) * sub_h * (2 - sps["frame_mbs_only_flag"])

    sps["vui_parameters_present_flag"] = reader.u(1)
    sps["vui"] = parse_vui(reader) if sps["vui_parameters_present_flag"] else {}
    return sps


# ---------------------------------------------------------------- Annex B / SEI


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


def sei_payload_types(nal: bytes):
    """H.264 §7.3.2.3.1: each SEI message is a type and size, both 0xFF-extended."""
    data = unescape_rbsp(nal[1:])
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


# ---------------------------------------------------------------- reporting

failures = []
warnings = []


def check(ok: bool, label: str, detail: str = "", fatal: bool = True) -> None:
    mark = "ok  " if ok else ("FAIL" if fatal else "warn")
    print(f"  [{mark}] {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        (failures if fatal else warnings).append(label)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", help="an .sdp file or an Annex B elementary stream")
    parser.add_argument("--fps", type=int, default=None,
                        help="expected frame rate, to check num_units_in_tick and time_scale")
    args = parser.parse_args()

    raw = open(args.path, "rb").read()
    sei_types, sps_nal = set(), None
    pictures = 0                                      # first_mb_in_slice == 0 starts a picture
    idr_picture_indices = []
    slices_per_picture = []

    if args.path.endswith(".sdp"):
        match = re.search(rb"sprop-parameter-sets=([A-Za-z0-9+/=,]+)", raw)
        if not match:
            print("no sprop-parameter-sets in that SDP", file=sys.stderr)
            return 2
        sps_nal = base64.b64decode(match.group(1).split(b",")[0])
    else:
        for nal in split_annexb(raw):
            nal_type = nal[0] & 0x1F
            if nal_type == 7 and sps_nal is None:
                sps_nal = nal
            elif nal_type == 6:
                sei_types.update(sei_payload_types(nal))
            elif nal_type in (1, 5):                  # VCL: coded slice
                # slice_header() opens with first_mb_in_slice; zero means a new picture.
                # x264's zerolatency tune slices each frame, so this is not one NAL per frame.
                first_mb = BitReader(unescape_rbsp(nal[1:])).ue()
                if first_mb == 0:
                    pictures += 1
                    slices_per_picture.append(1)
                    if nal_type == 5:
                        idr_picture_indices.append(pictures - 1)
                elif slices_per_picture:
                    slices_per_picture[-1] += 1
        if sps_nal is None:
            print("no SPS found in that stream", file=sys.stderr)
            return 2

    sps = parse_sps(sps_nal)
    vui = sps["vui"]

    profile = PROFILE_NAMES.get(sps["profile_idc"], f"profile_idc {sps['profile_idc']}")
    print(f"\nSPS: {profile}, level {sps['level_idc'] / 10:.1f}, "
          f"{sps['width']}x{sps['height']}, {CHROMA_NAMES.get(sps['chroma_format_idc'], '?')}, "
          f"{sps['bit_depth_luma']}-bit\n")

    print("TR-10-15 Part 3 §12 — profile")
    check(sps["profile_idc"] in (77, 100), "High or Main profile", profile)
    check(sps["chroma_format_idc"] == 1, "YCbCr 4:2:0")
    check(sps["bit_depth_luma"] == 8, "8-bit samples")

    print("\nTR-10-15 Part 3 §8 — picture and VUI")
    check(sps["vui_parameters_present_flag"] == 1, "vui_parameters present")
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
              f"cbr_flag={cpb['cbr_flag']} "
              f"({'CBR' if cpb['cbr_flag'] else 'VBR'} per TR-10-15 definitions)")
    if vui.get("timing_info_present_flag"):
        num_units, time_scale = vui["num_units_in_tick"], vui["time_scale"]
        rate = time_scale / (2 * num_units)
        print(f"         num_units_in_tick={num_units} time_scale={time_scale} -> {rate:g} fps")
        if args.fps is not None:
            check(num_units == 1 and time_scale == 2 * args.fps,
                  f"time_scale = 2 x frame rate numerator for {args.fps} fps",
                  f"got num_units_in_tick={num_units}, time_scale={time_scale}")
    reorder = vui.get("max_num_reorder_frames")
    check(reorder == 0, "max_num_reorder_frames = 0 (decode order = output order)",
          "bitstream_restriction_flag is 0, so the value is not signalled"
          if reorder is None else f"got {reorder}",
          fatal=False)

    if not args.path.endswith(".sdp"):
        print("\nTR-10-15 Part 3 §10 — SEI messages")
        check(0 in sei_types, "Buffering Period SEI (payloadType 0) present")
        check(1 in sei_types, "Picture Timing SEI (payloadType 1) present")
        if sei_types:
            print(f"         SEI payload types seen: {sorted(sei_types)}")

        print("\nTR-10-15 Part 3 §11 — random access")
        print(f"         {pictures} pictures, {len(idr_picture_indices)} IDR")
        if args.fps and len(idr_picture_indices) >= 2:
            gaps = [(b - a) / args.fps for a, b in
                    zip(idr_picture_indices, idr_picture_indices[1:])]
            check(max(gaps) <= 5.0, "a random access point at least every 5 s",
                  f"largest gap {max(gaps):.2f} s")
        elif len(idr_picture_indices) < 2:
            check(False, "at least two IDRs in the dump to measure the interval",
                  "capture for longer", fatal=False)

        if slices_per_picture:
            # TR-10-15 §9 caps a packet at one VCL NAL. More slices means more packets, not a
            # violation: the packetizer never aggregates.
            worst = max(slices_per_picture)
            print(f"\n         slices per picture: {min(slices_per_picture)}..{worst} "
                  f"(each one travels in its own packet, TR-10-15 §9)")
    else:
        print("\n  (pass an Annex B dump from --dump to also check the SEI messages)")

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
